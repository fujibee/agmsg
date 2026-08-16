#!/usr/bin/env bash
set -euo pipefail

# Usage: team-list.sh [--json] [--scope all|project] [<project_path>]
#
# Read-only, secret-free enumeration of every locally known team (ADR 0007
# family addition — a public OSS interface, carried on the same review
# track as `remote status --json` / `remote pending list|abort`). Unlike
# `team.sh <team>` (shows one team's members), this lists every team this
# device knows about, across every registered project.
#
# --json: strict, versioned machine ABI:
#   { schema_version, teams: [{ name, remote_team_id, scope, binding_state }] }
# Every team entry always includes all four fields — none is ever omitted,
# so a consumer never needs to guess whether a missing key means "absent"
# vs "not yet populated" (a required-but-nullable field is null; it is
# never simply left out).
#
#   name             string. The local team name (also its directory name
#                    under teams/).
#   remote_team_id   string | null. Server-assigned id of this team's
#                    CURRENT remote binding (ADR 0007's
#                    remote_binding.remote_team_id) — null when the team
#                    has never connected. Deliberately named
#                    remote_team_id, not team_id: this is a property of the
#                    binding, not a stable local identity anchor for the
#                    team itself (no such anchor exists in the current
#                    schema — every local team's stable identity today
#                    IS its name; there is no separate immutable local
#                    UUID). A future portable/local team id (ADR 0010)
#                    would be a genuinely NEW field (e.g. local_team_id),
#                    never a reinterpretation of this one.
#   scope            exactly "project" | "other". "project": this team has
#                    at least one agent registration for the project this
#                    command was run against. "other": it does not. Always
#                    present regardless of which --scope filter was
#                    requested (see --scope below).
#   binding_state    exactly "active" | "disconnected" | "none".
#                    "none": never connected. "active": connected, not
#                    since disconnected. "disconnected": was connected, has
#                    since been disconnected (remote_team_id is retained
#                    from that binding, as history, not a live claim).
#
# A row whose computed scope/binding_state would fall outside these exact
# enums (should never happen — both are derived from a closed set of
# branches, never read verbatim off disk as a free-form string) is treated
# as invalid and dropped from the list like any other unreadable config —
# fail-closed per-entry, never widening the enum silently to fit.
#
# schema_version increment convention (settled; pin this before ever
# bumping it): adding a NEW field is additive and does NOT bump
# schema_version — a consumer MUST ignore fields it doesn't recognize.
# Only changing or removing an EXISTING field's meaning bumps it. This is
# why the fields above are limited to ones whose meaning is fully settled
# today, rather than shipping a placeholder now and changing what it means
# later (that would be the field-count staying the same while the
# contract silently broke — worse than just not having shipped it yet).
#
# onboarding_state/promote_eligible/blocked_reason are deliberately NOT in
# v1: their real meaning depends on ADR 0010
# (local-first onboarding / roster convergence), which hasn't landed, so
# right now they could only be a fixed/mechanically-derived value with
# zero information a consumer couldn't already get from binding_state —
# exactly the "field exists, meaning undetermined" shape that becomes a
# breaking change the moment ADR 0010 gives them real semantics. Add them
# additively (a new field, not a changed one) once ADR 0010 fixes what
# they mean — do not resurrect a placeholder version of them before then.
# Same reasoning applies to any future local/portable team identity field.
#
# With no --json, prints the equivalent as human-readable text.
#
# --scope (default: all) — all: every locally known team (this is the
#   authority a no-arg cloud `connect` flow must use to decide whether the
#   choice is ambiguous; narrowing to `project` must never be what that
#   decision is based on, since it could silently hide a team that would
#   otherwise make "just pick one" wrong). project: only teams that have at
#   least one agent registration for <project_path> (default: cwd) — a
#   convenience filter for a human looking at their own project, not a
#   substitute for `all` in an automated decision. Every entry's own
#   "scope" field is "project" or "other" regardless of which --scope was
#   requested, so a consumer can always tell which is which even under
#   `all`.
#
# Bounded (never unbounded local enumeration/output): at most
# MAX_TEAMS team dirs are considered, and each config.json read is capped
# at MAX_CONFIG_BYTES. A team whose config fails strict parsing (invalid
# JSON, or a duplicate key at any depth — the same #87/D4 class of hygiene
# this ADR family already applies to server-supplied JSON, held to
# config.json too) is skipped with a stderr warning.
#
# --json fails closed on incompleteness (delta review): if the
# MAX_TEAMS bound was hit, or any team's config was skipped, --format json
# prints NO JSON payload at all and exits 2 — a partial list must never be
# handed to a consumer as if it were the complete, authoritative one (the
# whole point of --scope all is deciding "one team vs several" correctly).
# --format human (no --json) still prints whatever it found plus the
# warnings and exits 0, since a person reading it isn't fooled the way an
# automated ambiguity check would be.
#
# Never mutates local state, and never prints a secret or an absolute
# filesystem path (the "scope" field is a classification, "project" or
# "other" — never the literal project path itself).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$SKILL_DIR/teams"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/require-python3.sh"

agmsg_require_python3 "team list" || exit 1

# An explicitly empty override (AGMSG_TEAM_LIST_MAX_TEAMS=) falls back to
# the 10000 default via bash's `:-`, same as leaving it unset — this is
# the intended behavior, not something rejected below.
MAX_TEAMS="${AGMSG_TEAM_LIST_MAX_TEAMS:-10000}"
readonly _MAX_TEAMS_UPPER_BOUND=10000
# Validated immediately (delta review, two rounds): `[ "$count" -gt
# "$MAX_TEAMS" ]` below is a bash `test` integer comparison inside an `if`
# condition, which `set -e` does NOT abort on — so ANY input `test` can't
# evaluate as an in-range integer (non-numeric, zero, negative, OR an
# all-digit string too large for bash's native fixed-width arithmetic to
# represent, e.g. 30 nines) makes `test` print "integer expression
# expected" to stderr and just never take the truncation branch, silently
# enumerating every team with no bound at all — breaking the bounded-
# enumeration guarantee this script (and --json's fail-closed authority
# contract) depends on. The digit-count check below rejects an oversized
# numeral BEFORE it ever reaches `-lt`/`-gt` arithmetic, rather than
# trying to detect overflow after the fact (bash gives no reliable signal
# to detect it with other than the same silent-if-condition-false
# behavior this is closing).
case "$MAX_TEAMS" in
  ''|*[!0-9]*)
    echo "agmsg: AGMSG_TEAM_LIST_MAX_TEAMS must be a positive integer, got '$MAX_TEAMS'" >&2
    exit 1
    ;;
esac
if [ "${#MAX_TEAMS}" -gt ${#_MAX_TEAMS_UPPER_BOUND} ]; then
  echo "agmsg: AGMSG_TEAM_LIST_MAX_TEAMS must be between 1 and $_MAX_TEAMS_UPPER_BOUND, got '$MAX_TEAMS'" >&2
  exit 1
fi
if [ "$MAX_TEAMS" -lt 1 ] || [ "$MAX_TEAMS" -gt "$_MAX_TEAMS_UPPER_BOUND" ]; then
  echo "agmsg: AGMSG_TEAM_LIST_MAX_TEAMS must be between 1 and $_MAX_TEAMS_UPPER_BOUND, got '$MAX_TEAMS'" >&2
  exit 1
fi

MAX_CONFIG_BYTES=$((10 * 1024 * 1024))

json=0
scope="all"
project_path=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1; shift ;;
    --scope) scope="${2:?--scope requires a value}"; shift 2 ;;
    --scope=*) scope="${1#--scope=}"; shift ;;
    *) project_path="$1"; shift ;;
  esac
done
case "$scope" in
  all|project) ;;
  *) echo "agmsg: --scope must be 'all' or 'project'" >&2; exit 1 ;;
esac
[ -n "$project_path" ] || project_path="$(pwd)"

work_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-team-list-work.XXXXXX")"
chmod 600 "$work_file"
trap 'rm -f "$work_file"' EXIT INT TERM

truncated=0
if [ -d "$TEAMS_DIR" ]; then
  count=0
  for d in "$TEAMS_DIR"/*/; do
    [ -d "$d" ] || continue
    cfg="${d}config.json"
    [ -f "$cfg" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$MAX_TEAMS" ]; then
      echo "agmsg: team list bounded at $MAX_TEAMS teams — some local teams were not enumerated" >&2
      truncated=1
      break
    fi
    name="$(basename "$d")"
    printf '%s\t%s\n' "$name" "$cfg" >> "$work_file"
  done
fi

variants_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-team-list-variants.XXXXXX")"
chmod 600 "$variants_file"
trap 'rm -f "$work_file" "$variants_file"' EXIT INT TERM
agmsg_project_path_variants "$project_path" > "$variants_file"

format="human"
[ "$json" -eq 1 ] && format="json"

if [ "$truncated" -eq 1 ]; then
  python3 "$SCRIPT_DIR/internal/team-list.py" \
    --entries "$work_file" --variants "$variants_file" \
    --scope "$scope" --max-config-bytes "$MAX_CONFIG_BYTES" --format "$format" \
    --truncated
else
  python3 "$SCRIPT_DIR/internal/team-list.py" \
    --entries "$work_file" --variants "$variants_file" \
    --scope "$scope" --max-config-bytes "$MAX_CONFIG_BYTES" --format "$format"
fi
