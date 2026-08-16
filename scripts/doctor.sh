#!/usr/bin/env bash
set -euo pipefail

# doctor.sh — "who holds what" in one screen. #267/#605.
#
# Usage: doctor.sh [--project <path>] [--type <type>] [--team <team>] [--redacted]
#        doctor.sh --help
#
# Default (no filters): the whole installation -- every team, every project,
# every type. --project / --type / --team narrow it and combine freely. This
# matches how claude/codex/brew/flutter doctor all behave (no scope argument,
# default to everything) rather than requiring a cross-section up front --
# koit's call, made explicit because the earlier <project> <type>-required
# form had it backwards: a reporter who doesn't already know which project/type
# to name can't use a doctor that demands one. Positional <project> <type> is
# not kept for compatibility -- koit judged it not worth carrying (see PR/report
# history for round 2), and a stale positional form alongside flags that mean
# something different by default would be its own source of confusion.
#
# Argument parsing is kept separate from scope-building (the SCOPE loop
# below) so that a future change to what the flags are doesn't have to touch
# how a scope, once decided, gets turned into (project, type) pairs.
#
# Read-only: never claims, releases, or removes a lock, pidfile, or
# registration. A stale lock or dead pidfile is reported, not cleaned up --
# #605's reporter was asked not to remove a lock by hand because it erases
# the evidence; a doctor that cleaned up would do the same thing to itself.
#
# Data sources are the existing helpers this project already has for each
# fact -- identities.sh for registrations, actas-lock.sh/instance-id.sh for
# lock ownership and liveness, delivery.sh for mode and watcher/bridge
# status, agmsg_registered_projects for cross-project/cross-type discovery.
# Nothing here recomputes a verdict those already reach; #605's diagnostic
# duplicated agmsg_instance_alive once and that duplication was exactly
# what review pushed back on.
#
# Exit codes:
#   0  no warnings
#   1  one or more warnings (see WARNINGS section)
#   2  usage or resolution error

_usage() {
  echo "Usage: doctor.sh [--project <path>] [--type <type>] [--team <team>] [--redacted]" >&2
  echo "       doctor.sh --help" >&2
}

# Scanned for --help before anything else is parsed, same reasoning as
# before: a validation error on some other flag must never suppress --help.
for _arg in "${@:-}"; do
  case "$_arg" in
    -h|--help) _usage; exit 0 ;;
  esac
done
unset _arg

# --- argument parsing: produces FILTER_PROJECT / FILTER_TYPE / FILTER_TEAM /
#     REDACTED only. Deliberately does not decide what a scope IS -- that is
#     entirely the SCOPE-building block below, so a future flag change stays
#     a parsing-only change. No positional arguments are accepted -- any
#     bare token is a usage error. -----------------------------------------
REDACTED=0
FILTER_PROJECT="" FILTER_TYPE="" FILTER_TEAM=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      case "${2:-}" in ''|-*) echo "doctor: --project requires a value" >&2; exit 2 ;; esac
      FILTER_PROJECT="$2"; shift 2 ;;
    --type)
      case "${2:-}" in ''|-*) echo "doctor: --type requires a value" >&2; exit 2 ;; esac
      FILTER_TYPE="$2"; shift 2 ;;
    --team)
      case "${2:-}" in ''|-*) echo "doctor: --team requires a value" >&2; exit 2 ;; esac
      FILTER_TEAM="$2"; shift 2 ;;
    --redacted) REDACTED=1; shift ;;
    -*) echo "doctor: unknown option: $1" >&2; exit 2 ;;
    *) echo "doctor: unexpected argument: '$1' (doctor takes flags only -- see --help)" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/validate.sh"

# --project / --type / --team all validated here, before any scope work:
# an unknown --type or --team is a usage error (exit 2), not left to fail
# quietly into an empty scope -- same "no silent empty-looks-clean report"
# reasoning as the original <project> <type> form's type check. An unknown
# --project has no fixed enum to check against; it falls through to the
# generic "no registrations match this scope" exit 2 below instead, which
# reaches the same exit code by the same means every other empty scope does.
if [ -n "$FILTER_TYPE" ] && ! agmsg_is_known_type "$FILTER_TYPE"; then
  echo "doctor: unknown agent type: '$FILTER_TYPE' (supported: $(agmsg_known_types | sort -u | paste -sd, - | sed 's/,/, /g'))" >&2
  exit 2
fi
if [ -n "$FILTER_TEAM" ]; then
  # --team becomes a path segment below (teams/$FILTER_TEAM/config.json,
  # both here and inside agmsg_registered_projects) whether or not it turns
  # out to name a real team -- validate.sh's header names every entry point
  # that does this ("join.sh, leave.sh, team.sh, rename.sh, rename-team.sh")
  # for exactly this reason: an unvalidated value containing "..", "/", or
  # similar can resolve to a config-shaped file outside teams/ entirely. This
  # is doctor.sh's first --team-shaped entry point, so it needs the same
  # validator every other one already runs through -- not a new check, just
  # this file failing to call the existing one. Runs BEFORE the existence
  # check below: a value validate.sh rejects should never even reach a
  # filesystem lookup.
  agmsg_validate_team_name "$FILTER_TEAM" || exit 2
  if [ ! -f "$SKILL_DIR/teams/$FILTER_TEAM/config.json" ]; then
    echo "doctor: unknown team: '$FILTER_TEAM'" >&2
    exit 2
  fi
fi

# Keep only the "<team>\t<agent>" lines belonging to FILTER_TEAM. A no-op
# (prints input unchanged) when no --team was given. Needed in two places:
# narrowing a (project, type) pair's own registration rows to just the
# requested team, and (identically) deciding whether that team has ANY
# registration at a candidate pair while building SCOPE below.
_team_filter_lines() {
  local input="$1" team="$2" t a
  [ -n "$team" ] || { printf '%s' "$input"; return 0; }
  while IFS=$'\t' read -r t a; do
    [ -z "$t" ] && continue
    [ "$t" = "$team" ] && printf '%s\t%s\n' "$t" "$a"
  done <<< "$input"
  # A while loop's own exit status is whatever its LAST executed command
  # left behind -- here, "[ "$t" = "$team" ] && printf ...", whose short-
  # circuiting means a NON-matching final input line leaves exit 1, even
  # though filtering out a non-match is completely normal. Every caller of
  # this function assigns its output via a bare command substitution (no
  # `|| true`), so under set -e that leaked 1 aborted the whole script --
  # silently, with no output at all, whenever --team's target sorted before
  # some other team on the LAST row of a pair's registrations (identities.sh
  # orders by team name, so this depended on which teams happened to share a
  # project/type and how their names compared). Found by running --team
  # against the real installation, where this ordering wasn't in this
  # branch's favor. return 0 makes "ran to completion, matched or not" the
  # function's actual contract, matching what every caller already assumes.
  return 0
}

# --- scope: build the (project, type) pairs to scan --------------------
#
# One output format regardless of which filters were given: newline-separated
# "project<TAB>type". Everything downstream just iterates this list -- the
# per-pair judgment logic (_doctor_scan_pair) is identical regardless of how
# the list was built.
SCOPE=""

while IFS= read -r _type; do
  [ -n "$_type" ] || continue
  if [ -n "$FILTER_PROJECT" ]; then
    # --project given: no single resolve call applies without a type, so this
    # loops it across every type being scanned (all known types, or just
    # FILTER_TYPE), exactly as identities.sh is then used to confirm a real
    # registration exists there. (An earlier version tried to match the input
    # against agmsg_registered_projects by canonicalizing both sides -- wrong
    # on macOS, where agmsg_canonical_path resolves the /var -> /private/var
    # symlink but the registry stores whatever raw path join.sh was given, so
    # a real registration never matched. agmsg_resolve_project already gets
    # this right per type; reusing it here sidesteps reinventing that
    # matching a second time.) FILTER_TEAM, if given, scopes both the
    # resolution's registry fallback AND which registration counts as a hit.
    _resolved="$(agmsg_resolve_project "$FILTER_PROJECT" "$_type" "$FILTER_TEAM")"
    _hit="$("$SCRIPT_DIR/identities.sh" "$_resolved" "$_type")"
    _hit="$(_team_filter_lines "$_hit" "$FILTER_TEAM")"
    if [ -n "$_hit" ]; then
      SCOPE="${SCOPE}${_resolved}"$'\t'"${_type}"$'\n'
    fi
  else
    # No --project: every project registered for this type (agmsg_registered_projects's
    # own team param does the --team narrowing here, at the source, rather than
    # listing everyone's projects and filtering after). sort -u because
    # agmsg_registered_projects dedups WITHIN one team's config.json via SQL
    # DISTINCT, but concatenates every scanned team's config.json results with
    # no cross-file dedup -- a project registered under two different teams (a
    # real shape: two teams sharing one workspace) comes back twice when no
    # --team narrows it to one file, and without sort -u here that turns into
    # the same (project, type) pair scanned and reported twice, with summary
    # counts inflated to match. Confirmed by direct inspection of its raw
    # output before this fix landed.
    while IFS= read -r _proj; do
      [ -n "$_proj" ] || continue
      SCOPE="${SCOPE}${_proj}"$'\t'"${_type}"$'\n'
    done <<< "$(agmsg_registered_projects "$_type" "$FILTER_TEAM" | sort -u)"
  fi
done <<< "$(if [ -n "$FILTER_TYPE" ]; then printf '%s\n' "$FILTER_TYPE"; else agmsg_known_types | sort -u; fi)"
unset _type _proj _resolved _hit

# An empty SCOPE means two different things depending on whether a filter
# narrowed it: an EXPLICIT --project/--type/--team that matched nothing is
# almost certainly a mistake (a typo'd project path, a team that doesn't
# exist) -- exit 2, as before. But no filters at all, on an installation
# that genuinely has zero registrations anywhere, is a VALID whole-install
# scan whose answer happens to be empty -- that is not a usage error, and
# treating it as one meant "diagnose an empty installation" itself failed
# doctor's own exit-code contract. Falls through to the normal report path
# below, which -- with SCOPE empty -- naturally produces a clean "0 team(s),
# 0 registration(s), 0 warning(s)" / "no warnings." / exit 0 with no special
# casing needed there.
if [ -z "$SCOPE" ] && { [ -n "$FILTER_PROJECT" ] || [ -n "$FILTER_TYPE" ] || [ -n "$FILTER_TEAM" ]; }; then
  echo "doctor: no registrations match this scope" >&2
  exit 2
fi

WARNINGS=""
_warn() { WARNINGS="${WARNINGS}$1"$'\n'; }

# --- redaction: consistent pseudonyms, not one-off masking -----------------
#
# One pseudonym table for the WHOLE run, not per (project, type) pair: with
# --all spanning multiple projects, the same team/agent appearing under two
# different projects has to read as the same pseudonym both times, or the
# output stops being cross-referenceable against itself.
#
# A fixed team1/agent1 substitution (not a hash) so the same name reads the
# same way everywhere it appears in one run -- the #605 reporter hand-redacted
# their own report exactly this way (generic team/agent names, home-relative
# project path); this does the same substitution instead of leaving it to
# whoever pastes the output into a bug report.
# Sets _REDACT_OUT in the CALLER's shell rather than printf+$(...): a pair
# assigned inside a command substitution is a subshell, and the whole point
# here is a mutation (_R_TEAM_K/_R_TEAM_V growing) that has to survive past
# the call. role-session.sh's _agmsg_role_session_path_into hit this same
# shape first -- "a cache entry is only kept when the helper runs in the
# caller's own shell" applies just as much to a pseudonym table as a memo.
_R_TEAM_K=(); _R_TEAM_V=(); _R_AGENT_K=(); _R_AGENT_V=()
_redact_team() {
  [ "$REDACTED" = 1 ] || { _REDACT_OUT="$1"; return 0; }
  local i n=${#_R_TEAM_K[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_R_TEAM_K[$i]}" = "$1" ]; then _REDACT_OUT="${_R_TEAM_V[$i]}"; return 0; fi
  done
  _R_TEAM_K[$n]="$1"; _R_TEAM_V[$n]="team$((n + 1))"
  _REDACT_OUT="${_R_TEAM_V[$n]}"
}
_redact_agent() {
  [ "$REDACTED" = 1 ] || { _REDACT_OUT="$1"; return 0; }
  local i n=${#_R_AGENT_K[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_R_AGENT_K[$i]}" = "$1" ]; then _REDACT_OUT="${_R_AGENT_V[$i]}"; return 0; fi
  done
  _R_AGENT_K[$n]="$1"; _R_AGENT_V[$n]="agent$((n + 1))"
  _REDACT_OUT="${_R_AGENT_V[$n]}"
}
# Same idea for project paths as team/agent above: one table for the whole
# run, so the same project reads as the same pseudonym in every (project,
# type) block it appears in under --all, not a fresh placeholder each time.
_R_PROJ_K=(); _R_PROJ_V=()
_redact_project() {
  [ "$REDACTED" = 1 ] || { _REDACT_OUT="$1"; return 0; }
  case "$1" in
    "$HOME"*) _REDACT_OUT="~${1#"$HOME"}"; return 0 ;;
  esac
  local i n=${#_R_PROJ_K[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_R_PROJ_K[$i]}" = "$1" ]; then _REDACT_OUT="${_R_PROJ_V[$i]}"; return 0; fi
  done
  _R_PROJ_K[$n]="$1"; _R_PROJ_V[$n]="<project$((n + 1))>"
  _REDACT_OUT="${_R_PROJ_V[$n]}"
}
# Plain output shows the owner token IN FULL -- #605 was actually resolved by
# matching this exact value against a "codex-bridge: resumed thread <uuid>"
# line in a bridge log, and a shortened token can't be matched that way. This
# only shortens under --redacted, where the point is the opposite (safe to
# paste), and even then splits on the LAST "." rather than a fixed tail
# length: a fixed suffix cuts at a different point depending on how long the
# leading uuid/sid happens to be, while the part after the last "." is the
# pid every composite token carries -- consistently shaped, and still useful
# on its own (`ps -p <pid>`) even with the rest hidden. A bare token (no ".")
# has no such split point, so that case keeps the old fixed-tail form.
_redact_owner() {
  [ "$REDACTED" = 1 ] || { printf '%s' "$1"; return 0; }
  [ -n "$1" ] || return 0
  if agmsg_instance_is_composite "$1"; then
    printf '...%s' "${1##*.}"
  else
    printf '...%s' "${1: -6}"
  fi
}
# Literal (not glob, not regex) substring replace. A quoted portion of a
# case/parameter-expansion pattern matches literally regardless of what it
# contains, so this needs no escaping for team/agent names or paths that
# happen to hold *, ?, [, or other glob/regex metacharacters. Portable to
# bash 3.2 (macOS).
_replace_literal() {
  local rest="$1" needle="$2" repl="$3" out=""
  [ -n "$needle" ] || { printf '%s' "$rest"; return 0; }
  while true; do
    case "$rest" in
      *"$needle"*)
        out="$out${rest%%"$needle"*}$repl"
        rest="${rest#*"$needle"}"
        ;;
      *) break ;;
    esac
  done
  printf '%s%s' "$out" "$rest"
}
# Applies the SAME substitutions as the fields above to a block of TEXT this
# script did not format itself (delivery.sh's own output) -- --redacted's
# only promise is "safe to paste", so text quoted wholesale from elsewhere
# has to go through the same pseudonym table and $HOME masking as everything
# doctor.sh builds by hand, not get echoed as-is. Takes the CURRENT pair's
# resolved project explicitly (not a global) -- under --all this runs once
# per (project, type) block, each with a different project.
#
# No word boundaries: a team/agent name that also occurs as a substring
# elsewhere in the text (e.g. a team named "agmsg" inside a path like
# ~/.agents/skills/agmsg/run/...) gets replaced there too. Deliberately not
# fixed -- the failure direction is over-redaction, not a leak, which is the
# side --redacted is supposed to fail on.
_redact_text() {
  local text="$1" project="$2" i n
  [ "$REDACTED" = 1 ] || { printf '%s' "$text"; return 0; }
  text="$(_replace_literal "$text" "$HOME" "~")"
  # A project outside $HOME survives the substitution above untouched (no
  # $HOME prefix to catch), and delivery.sh's own output names it directly
  # (its settings-hooks-file path is under it) -- so the exact resolved path
  # is masked here too, the same pseudonym _redact_project produces for it.
  _redact_project "$project"
  text="$(_replace_literal "$text" "$project" "$_REDACT_OUT")"
  n=${#_R_TEAM_K[@]}
  for ((i = 0; i < n; i++)); do
    text="$(_replace_literal "$text" "${_R_TEAM_K[$i]}" "${_R_TEAM_V[$i]}")"
  done
  n=${#_R_AGENT_K[@]}
  for ((i = 0; i < n; i++)); do
    text="$(_replace_literal "$text" "${_R_AGENT_K[$i]}" "${_R_AGENT_V[$i]}")"
  done
  printf '%s' "$text"
}

# --- scan one (project, type) pair, buffer its block ------------------------
#
# Buffered into REPORT_BLOCKS rather than printed inline: the summary line
# koit asked for has to come FIRST on screen ("撃った人が最初に見るのはそ
# こ"), but its counts (teams/registrations/warnings) aren't known until
# every pair in the scope has been scanned. Nothing here is large enough for
# buffering to matter -- even the whole install across every team is a
# handful of KB.
REPORT_BLOCKS=""
TOTAL_PAIR_COUNT=0
# The "watch processes: N alive, M stale pidfiles" line the default runtime
# status emits scans the WHOLE run/ directory, not any one (project, type)'s
# own state -- an installation-wide fact, not a per-pair one. Captured ONCE
# here, independent of the scope being scanned, via `delivery.sh status` with
# no <type>/<project> -- do_status's own comment documents this as its
# no-args path: it skips the project-scoped mode line and just reports the
# global watcher state. This independence matters: an earlier version
# captured it opportunistically from whichever pair's own delivery.sh call
# happened to emit it first, which meant it silently never appeared at all
# on an installation whose registrations are ALL a no-delivery type (skips
# the call) and/or codex (overrides runtime status with its own per-role
# bridge lines instead of this one) -- an install like that would lose
# run/watch.*.pid stale-watcher detection entirely, not just deduplicate it.
# Caught in review; the fix is scanning run/ once, unconditionally, not
# deduplicating a per-pair emission that may never happen.
GLOBAL_WATCH_LINE="$(bash "$SCRIPT_DIR/delivery.sh" status 2>&1 | grep '^watch processes: ' | head -1 || true)"
_doctor_scan_pair() {
  local project="$1" type="$2"

  # Whether this type already reports its own per-role runtime status
  # (codex's _delivery.sh does, via the embedded delivery-status block --
  # one "Codex bridge: team/agent ..." line per role). Everything else
  # (currently claude-code, opencode) falls through to the default runtime
  # status, which is a single project-wide count with no per-role
  # breakdown, so those types get the watcher= field built below instead.
  # Detected structurally (does the type's plug override the function)
  # rather than hardcoding "codex", so a future type with its own per-role
  # reporting is picked up automatically.
  local type_has_role_runtime=0 type_plug="$SKILL_DIR/scripts/drivers/types/$type/_delivery.sh"
  if [ -f "$type_plug" ] && grep -q '^agmsg_delivery_runtime_status()' "$type_plug" 2>/dev/null; then
    type_has_role_runtime=1
  fi

  # Whether this type has ANY real delivery to ask about. delivery_modes= in
  # the type's manifest lists every mode the type can be SET to; a type whose
  # list is nothing but "off" (agmsg-app, hermes) has no agmsg-side delivery
  # at all -- agmsg-app is the desktop app's own identity, which owns its
  # own send/receive UI. Querying delivery.sh status for such a type exits 1
  # by design (there's nothing to report), and this doctor was turning that
  # into a WARNING on an otherwise completely healthy installation -- a real
  # installation, run once, came back "9 team(s), 56 registration(s), 5
  # warning(s)" purely from this, violating the exit-code contract this
  # command promised on day one (0 = nothing to report). Checked via the
  # manifest (agmsg_type_get, already used by PR #631 for the same key) so a
  # future no-delivery type is picked up the same way automatically, rather
  # than by name.
  local type_has_delivery=0 _dm_tok
  for _dm_tok in $(agmsg_type_get "$type" delivery_modes); do
    if [ "$_dm_tok" != "off" ]; then
      type_has_delivery=1
      break
    fi
  done
  unset _dm_tok

  # Shelled out to the real CLI (not sourced): delivery.sh dispatches on argv
  # at file scope, so sourcing it would run that dispatch. Reused verbatim
  # (through _redact_text) -- the type-specific per-role bridge liveness
  # this project already has (codex's _delivery.sh) is not worth a second
  # implementation here. Trade-off: MODE and the stale-pidfile warnings
  # below are parsed out of this human-readable text, so if delivery.sh's
  # wording changes, both go silent (no warning, not a wrong one) rather
  # than erroring -- a duplicated implementation would drift instead of
  # going quiet, which is worse. Flagged here so whoever next changes
  # delivery.sh's status wording knows to check.
  local delivery_status=0 delivery_output="" mode_line="" mode="off"
  if [ "$type_has_delivery" -eq 1 ]; then
    delivery_output="$(bash "$SCRIPT_DIR/delivery.sh" status "$type" "$project" 2>&1)" || delivery_status=$?
    mode_line="$(printf '%s\n' "$delivery_output" | head -1)"
    mode="${mode_line#mode: }"

    # This pair's own delivery.sh call may ALSO emit the same global line
    # (default runtime status, when this type doesn't override it) -- always
    # captured independently above now, so here it's only ever stripped out
    # of this pair's own text, never (re-)captured from it. delivery.sh
    # always emits "mode: ..." before this line when given a type/project
    # (do_status runs agmsg_delivery_status first, unconditionally), so this
    # grep -v never filters every line away in practice -- guarded with
    # || true anyway rather than leaning on that ordering under set -e.
    delivery_output="$(printf '%s\n' "$delivery_output" | grep -v '^watch processes: ' || true)"
  fi

  # Tracks whether this pair turned out to have anything worth a full block:
  # a warning count taken before/after (any _warn call below flips this,
  # without needing every call site to also set a flag), plus "any lock held
  # at all" and "delivery has more than a bare idle mode line" below. All
  # three false is exactly the shape a healthy, unconfigured project/type has
  # -- 27 such groups on a real install were each 6 lines to say nothing,
  # which is what made the report unreadable at real scale.
  local _warn_count_before
  _warn_count_before="$(printf '%s\n' "$WARNINGS" | grep -c . || true)"

  local pairs pair_count reg_lines="" first_team="" first_agent="" _any_owner=0
  pairs="$("$SCRIPT_DIR/identities.sh" "$project" "$type")"
  # FILTER_TEAM, when set, narrows the report to that team's own rows -- a
  # pair SCOPE already guaranteed has at least one registration for that
  # team (see the --project branch above / agmsg_registered_projects's team
  # param), so this never empties a pair SCOPE included.
  pairs="$(_team_filter_lines "$pairs" "$FILTER_TEAM")"
  pair_count="$(printf '%s\n' "$pairs" | grep -c . || true)"
  TOTAL_PAIR_COUNT=$((TOTAL_PAIR_COUNT + pair_count))

  local team agent dteam dagent owner alive_word cc_note pid
  local wpidfile wpid watcher_note first_dteam first_dagent
  if [ "$pair_count" -gt 0 ]; then
    while IFS=$'\t' read -r team agent; do
      [ -z "$team" ] && continue
      [ -n "$first_team" ] || { first_team="$team"; first_agent="$agent"; }

      _redact_team "$team"; dteam="$_REDACT_OUT"
      _redact_agent "$agent"; dagent="$_REDACT_OUT"
      owner="$(actas_lock_owner "$team" "$agent")"

      if [ -z "$owner" ]; then
        reg_lines="${reg_lines}$(printf '  %-22s lock=none' "$dteam/$dagent")"$'\n'
        continue
      fi
      _any_owner=1

      if agmsg_instance_alive "$owner"; then
        alive_word="alive"
      else
        alive_word="STALE"
        _redact_project "$project"
        _warn "[$_REDACT_OUT] stale lock: $dteam/$dagent (owner=$(_redact_owner "$owner"))"
      fi

      cc_note=""
      if agmsg_instance_is_composite "$owner"; then
        pid="${owner##*.}"
        if [ -f "$RUN_DIR/cc-instance.$pid" ]; then cc_note=" cc-instance=present"; else cc_note=" cc-instance=absent"; fi
      fi

      # Per-role watcher liveness -- only for types whose runtime status
      # doesn't already break this down per role (see type_has_role_runtime
      # above). The pidfile watch.sh's SessionStart directive writes is
      # keyed on the SAME normalized instance id actas-claim.sh records as
      # the lock owner (both go through agmsg_normalize_instance_id on the
      # same session id), so the owner token IS the watcher's pidfile name
      # -- no separate lookup or correlation needed, and no liveness logic
      # of its own: reuses _agmsg_pid_alive_local, the same helper
      # delivery.sh's own default runtime status calls.
      watcher_note=""
      if [ "$type_has_role_runtime" -eq 0 ]; then
        wpidfile="$RUN_DIR/watch.$owner.pid"
        if [ -f "$wpidfile" ]; then
          wpid="$(cat "$wpidfile" 2>/dev/null || true)"
          if [ -n "$wpid" ] && _agmsg_pid_alive_local "$wpid" 2>/dev/null; then
            watcher_note=" watcher=running"
          else
            watcher_note=" watcher=stale-pidfile"
          fi
        else
          watcher_note=" watcher=none"
          # Only when the lock itself is legitimately live: a stale lock
          # having no watcher is unremarkable (already covered above), but
          # an alive lock with no watcher means the role claims exclusivity
          # and isn't receiving -- the shape #605 and koit's own example
          # both were.
          if [ "$alive_word" = "alive" ]; then
            _redact_project "$project"
            _warn "[$_REDACT_OUT] actas lock held but no watcher: $dteam/$dagent (owner=$(_redact_owner "$owner"))"
          fi
        fi
      fi

      reg_lines="${reg_lines}$(printf '  %-22s lock=owner(%s)=%s%s%s' "$dteam/$dagent" "$alive_word" "$(_redact_owner "$owner")" "$cc_note" "$watcher_note")"$'\n'
    done <<< "$pairs"

    if [ "$pair_count" -gt 1 ] && { [ "$mode" = "turn" ] || [ "$mode" = "both" ]; }; then
      _redact_team "$first_team"; first_dteam="$_REDACT_OUT"
      _redact_agent "$first_agent"; first_dagent="$_REDACT_OUT"
      _redact_project "$project"
      _warn "[$_REDACT_OUT] $pair_count registrations for this (project, type) under turn-mode delivery -- only the first registered ($first_dteam/$first_dagent) receives Stop-hook delivery; the rest are silent under turn"
    fi
  fi

  # codex's per-role lines always carry a parenthetical reason (e.g. "stale
  # pidfile (pid 123 not running)") -- a genuine per-(project, type) fact,
  # unlike the installation-wide "N stale pidfiles" default-runtime-status
  # line (captured independently into GLOBAL_WATCH_LINE above and checked
  # once, globally, after the whole scope has been scanned -- see below the
  # scan loop).
  if printf '%s\n' "$delivery_output" | grep -q "stale pidfile ("; then
    _redact_project "$project"
    _warn "[$_REDACT_OUT] watcher/bridge pidfile present but process not running (see delivery status above)"
  fi

  # type is already validated (or came from the registry) before this is
  # ever called, so this is not the "unknown type" case -- some other
  # failure inside delivery.sh status itself. Surfaced as a warning rather
  # than swallowed: showing error text on screen while still reporting
  # "no warnings." / exit 0 underneath would be a doctor that lies about
  # its own read. type_has_delivery gates this call happening at all now, so
  # this can only fire for a type that DOES have delivery to query.
  if [ "$delivery_status" -ne 0 ]; then
    _redact_project "$project"
    _warn "[$_REDACT_OUT] delivery.sh status exited $delivery_status (see delivery status above)"
  fi

  # "Nothing to report": no lock held (by anyone), no warning raised while
  # scanning this pair, and delivery has nothing beyond a bare idle mode
  # line (no type_has_delivery at all, or mode=off with delivery_output --
  # after the global watch-processes line above was stripped out of it --
  # amounting to just that one "mode: off" line, no hooks/bridge detail
  # worth a look). On a real installation this was 27 of the report's
  # groups, each spending 6 lines to say "nothing here" -- unreadable at
  # real scale even once the exit-code bug above stops making them warnings.
  local _warn_count_after
  _warn_count_after="$(printf '%s\n' "$WARNINGS" | grep -c . || true)"
  local _delivery_line_count
  _delivery_line_count="$(printf '%s\n' "$delivery_output" | grep -c . || true)"
  local _boring=0
  if [ "$_any_owner" -eq 0 ] \
    && [ "$_warn_count_after" -eq "$_warn_count_before" ] \
    && case "$mode" in off\ \(unrecognized:*) false ;; off*) true ;; *) false ;; esac; then
    _boring=1
  fi

  _redact_project "$project"
  # `off` and `off (unrecognized: …)` are not the same state, and only the first
  # one is boring.
  #
  # `off` is a claim about the CONFIGURATION: the settings file was read and no
  # delivery hooks are installed. Nothing to report.
  #
  # `unrecognized` is a claim about THIS CHECK: it could not find or parse the
  # settings file, so it does not know what the configuration is. Collapsing that
  # to "nothing to report" tells the operator their delivery is off when what
  # happened is that we could not tell -- and the annotation it hides ("this
  # project may not be registered") is the one that explains an empty inbox.
  #
  # Measured while merging: this branch's delivery.sh has no bare `off` at all --
  # all four assignments carry an annotation -- so a condition testing for the
  # bare word collapses nothing, and one testing the first word collapses
  # everything including the three unrecognized cases.
  if [ "$_boring" -eq 1 ]; then
    local _noun="registrations"
    [ "$pair_count" -eq 1 ] && _noun="registration"
    # The path stays on the collapsed line. Of the five lines it replaces, four
    # repeat what the summary already says (the mode, and "entries: 0" three
    # times); the path answers a different question -- WHICH file was consulted.
    # That is the difference between "looked and found nothing" and "did not
    # look", and it is the distinction this repo keeps paying for when it goes
    # missing.
    _boring_conf="$(printf '%s\n' "$delivery_output" | sed -n 's/^settings hooks file: //p' | head -1)"
    if [ -n "$_boring_conf" ]; then
      _redact_text_out="$(_redact_text "$_boring_conf" "$project")"
      REPORT_BLOCKS="${REPORT_BLOCKS}$_REDACT_OUT  [$type]  $pair_count $_noun, nothing to report — $_redact_text_out"$'\n'
    else
      REPORT_BLOCKS="${REPORT_BLOCKS}$_REDACT_OUT  [$type]  $pair_count $_noun, nothing to report"$'\n'
    fi
  else
    REPORT_BLOCKS="${REPORT_BLOCKS}project: $_REDACT_OUT"$'\n'
    REPORT_BLOCKS="${REPORT_BLOCKS}type:    $type"$'\n\n'
    REPORT_BLOCKS="${REPORT_BLOCKS}$(_redact_text "$delivery_output" "$project")"$'\n\n'
    REPORT_BLOCKS="${REPORT_BLOCKS}registrations ($pair_count):"$'\n'
    if [ "$pair_count" -eq 0 ]; then
      REPORT_BLOCKS="${REPORT_BLOCKS}  (none for this project/type)"$'\n'
    else
      REPORT_BLOCKS="${REPORT_BLOCKS}${reg_lines}"
    fi
    REPORT_BLOCKS="${REPORT_BLOCKS}"$'\n'
  fi
}

# --- run the whole scope, then print summary -> blocks -> warnings --------
#
# Team count for the summary line is built alongside the scan (every
# distinct team name seen across the scope's registrations, not the count
# of (project, type) pairs) rather than a second pass over SCOPE -- reuses
# the exact identities.sh call _doctor_scan_pair already makes for the same
# pair, instead of querying it twice.
DISTINCT_TEAMS=""
while IFS=$'\t' read -r _proj _type; do
  [ -z "$_proj" ] && continue
  _doctor_scan_pair "$_proj" "$_type"
  while IFS=$'\t' read -r _team _agent; do
    [ -z "$_team" ] && continue
    case $'\n'"$DISTINCT_TEAMS"$'\n' in
      *$'\n'"$_team"$'\n'*) ;;
      *) DISTINCT_TEAMS="${DISTINCT_TEAMS}${_team}"$'\n' ;;
    esac
  done <<< "$(_team_filter_lines "$("$SCRIPT_DIR/identities.sh" "$_proj" "$_type")" "$FILTER_TEAM")"
done <<< "$SCOPE"
TEAM_COUNT="$(printf '%s\n' "$DISTINCT_TEAMS" | grep -c . || true)"

# GLOBAL_WATCH_LINE's own stale-pidfile count is an installation-wide fact
# (see where it's captured in _doctor_scan_pair) -- checked here, ONCE, for
# the whole run, rather than once per pair scanned. Reuses the exact same
# text the per-pair codex check above parses a different (per-role) line
# from; this just applies that same parsing to the one line that is global.
if [ -n "$GLOBAL_WATCH_LINE" ]; then
  GLOBAL_STALE_COUNT="$(printf '%s\n' "$GLOBAL_WATCH_LINE" | sed -n 's/.*, \([0-9]*\) stale pidfiles*$/\1/p')"
  case "$GLOBAL_STALE_COUNT" in ''|*[!0-9]*) GLOBAL_STALE_COUNT=0 ;; esac
  if [ "$GLOBAL_STALE_COUNT" -gt 0 ]; then
    _warn "watcher pidfile present but process not running, installation-wide (see the 'watch processes' line above)"
  fi
fi
WARN_COUNT="$(printf '%s\n' "$WARNINGS" | grep -c . || true)"

echo "$TEAM_COUNT team(s), $TOTAL_PAIR_COUNT registration(s), $WARN_COUNT warning(s)"
echo
if [ -n "$GLOBAL_WATCH_LINE" ]; then
  echo "$GLOBAL_WATCH_LINE"
  echo
fi
printf '%s' "$REPORT_BLOCKS"

if [ -n "$WARNINGS" ]; then
  echo "warnings:"
  printf '%s' "$WARNINGS" | sed 's/^/  - /'
  exit 1
fi
echo "no warnings."
exit 0
