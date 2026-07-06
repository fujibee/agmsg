#!/usr/bin/env bash
# codex-record-session.sh — record a codex role's resumable session (#339).
#
# claude-code records (team,agent)->session in actas-claim.sh. Codex actas is
# otherwise send-side only and never runs actas-claim, so without this a codex
# role would have no role-session record and could never be resumed (spawn would
# always boot it fresh). This is the codex-side equivalent: the codex actas flow
# calls it, and it writes the record so a later spawn/resume brings the role back
# into its thread.
#
# Usage: codex-record-session.sh <team> <agent> <project>
#
# Thread-id resolution — QUALITY GUARD (#339 review). The recorded id MUST be
# THIS session's codex thread, never another's: a resume mis-fire (resuming the
# wrong conversation) is worse than a fresh boot. So resolution is deliberately
# conservative and biased toward recording NOTHING when unsure (fresh = zero harm):
#   1. Prefer $CODEX_THREAD_ID -- exported on the interactive/--remote path, which
#      is exactly the spawned-codex case this feature targets. Unambiguous.
#   2. Else fall back to a rollout whose session_meta cwd matches the project, but
#      ONLY when that match is UNIQUE among recent rollouts. If two or more recent
#      rollouts share this cwd (concurrent codex sessions in the same directory),
#      we cannot tell which is ours -> record nothing.
# Always best-effort: every failure path is a silent no-op (exit 0).
set -uo pipefail

TEAM="${1:-}"; AGENT="${2:-}"; PROJECT="${3:-}"
[ -n "$TEAM" ] && [ -n "$AGENT" ] && [ -n "$PROJECT" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# types/codex/ -> up 4 (codex -> types -> drivers -> scripts -> skill root).
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export SKILL_DIR
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/resolve-project.sh"
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/storage.sh"
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/role-session.sh"

thread=""
if [ -n "${CODEX_THREAD_ID:-}" ]; then
  thread="$CODEX_THREAD_ID"
else
  # ${HOME:-} so an unset HOME under `set -u` is a silent no-op (empty -> the
  # dir check below fails -> fresh), not an unbound-variable abort (co1 nit).
  sessions_dir="${HOME:-}/.codex/sessions"
  if [ -n "${HOME:-}" ] && [ -d "$sessions_dir" ]; then
    project_phys="$(agmsg_canonical_path "$PROJECT")"
    # Distinct thread ids whose session_meta cwd (canonicalized -- codex records
    # the physical cwd while agmsg may hold a symlinked path, #160) matches the
    # project, among the most recent rollouts. Exactly one => unambiguously ours.
    #
    # The matching loop writes ids to a temp file rather than an outer
    # tids="$( ... while ... )" capture: bash 3.2 (macOS) cannot parse a while
    # loop that itself contains $(...) command substitutions when the whole thing
    # is wrapped in another $() -- the nested-substitution parser mis-tracks and
    # errors. Writing to a file keeps every $(...) un-nested (the same shape the
    # existing agmsg_resolve_codex_thread uses).
    tids_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-codexrec.XXXXXX" 2>/dev/null || true)"
    if [ -n "$tids_file" ]; then
      find "$sessions_dir" -type f -name 'rollout-*.jsonl' 2>/dev/null | sort -r | head -40 \
      | while IFS= read -r f; do
          [ -f "$f" ] || continue
          first="$(head -1 "$f" 2>/dev/null)"
          case "$first" in *'"session_meta"'*) ;; *) continue ;; esac
          esc="$(printf '%s' "$first" | sed "s/'/''/g")"
          cwd="$(agmsg_sqlite_mem "SELECT COALESCE(json_extract('$esc','\$.payload.cwd'),'')" 2>/dev/null)"
          [ -n "$cwd" ] || continue
          [ "$(agmsg_canonical_path "$cwd")" = "$project_phys" ] || continue
          agmsg_sqlite_mem "SELECT COALESCE(json_extract('$esc','\$.payload.id'),'')" 2>/dev/null
        done | grep . | sort -u > "$tids_file"
      # Exactly one distinct matching id => unambiguously ours. 0 (nothing) or
      # >1 (concurrent codex sessions in this cwd -> ambiguous) => record nothing.
      if [ "$(grep -c . "$tids_file" 2>/dev/null || echo 0)" -eq 1 ]; then
        thread="$(head -1 "$tids_file")"
      fi
      rm -f "$tids_file"
    fi
  fi
fi

[ -n "$thread" ] || exit 0
# codex thread ids are already bare UUIDs (no composite pid form), so record as-is.
agmsg_role_session_record "$TEAM" "$AGENT" "$thread" "$PROJECT" codex || true
exit 0
