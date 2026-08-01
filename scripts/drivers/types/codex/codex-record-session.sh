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
# Usage: codex-record-session.sh <team> <agent> [project]
#
# <project> is optional and defaults to this script's own $PWD. The default is
# codex-specific and deliberate: on Windows codex's shell_command tool runs
# through PowerShell, so a "$(pwd)"/"$PWD" argument in the calling prompt is
# expanded -- or mangled: an escaped-double-quote form (\"$PWD\") collapses to
# a lone `\` -- by PowerShell BEFORE bash ever sees it, and the model's quoting
# choice is not controllable. This script itself always runs under bash in the
# session's working directory, so its own $PWD is deterministically the correct
# POSIX form. Other types must keep passing project explicitly -- they don't
# share codex's shell_command cwd guarantee.
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
[ -n "$TEAM" ] && [ -n "$AGENT" ] || exit 0
# No <project> argument -> this script's own $PWD (see header: deterministic
# under bash even when the caller's shell is PowerShell).
[ -n "$PROJECT" ] || PROJECT="$PWD"

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
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/hash.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_app-server.sh"

# Poison-record guard (best-effort bias: record nothing when unsure). A mangled
# <project> argument -- e.g. the lone `\` a PowerShell-parsed \"$PWD\" collapses
# to -- must never be recorded: the launcher's project-mismatch safety valve
# would then exclude the role and silently stop its delivery. Reject anything
# that is not a real directory, and anything whose physical path is a
# filesystem root (`/`, an MSYS drive root like `/c`, or a Windows drive root)
# -- no real project lives there, so such a value can only be quoting damage.
[ -d "$PROJECT" ] || exit 0
project_phys="$(agmsg_canonical_path "$PROJECT")"
case "$project_phys" in
  / | /[A-Za-z] | [A-Za-z]: | [A-Za-z]:/ | [A-Za-z]:\\) exit 0 ;;
esac

thread=""
if [ -n "${CODEX_THREAD_ID:-}" ]; then
  thread="$CODEX_THREAD_ID"
fi

# Past this point every remaining path is an INFERENCE, and an inference may not
# change a seat that already exists -- not the loaded-set subtraction below, and
# not the rollout scan either. The subtraction fails by removing this role's own
# thread and adopting what is left; the rollout scan fails by picking whatever
# happens to be unique in the cwd. Both replace a correct seat with a stranger's
# thread, so the rule belongs to the whole inference, not to one branch of it.
#
# CODEX_THREAD_ID is exempt because it is not an inference: it is either exported
# by the session itself or passed by the bridge with the thread the app-server
# confirmed, which is exactly how a seeded seat gets corrected after arming.
if [ -z "$thread" ] && [ -n "$(agmsg_role_session_uuid "$TEAM" "$AGENT" 2>/dev/null || true)" ]; then
  exit 0
fi

# Ask the app-server which threads it has loaded, and subtract the ones a role
# already sits in (#579). The rollout files below cannot answer "which thread is
# THIS session" on a project that has been worked in before: every past session
# in this cwd matches, the count is never one, and the seat is never written --
# so on such a project the bridge can never arm, in this session or any later
# one.
#
# The subtraction is what makes the remainder unique. A thread stays loaded in
# the app-server after its window is gone, so `loaded` is every thread this
# server has opened, not the live ones; but each of those already has a seat, so
# taking the recorded ids away leaves the session that has not been seated yet.
#
# Exactly one leftover => ours. Zero or several => record nothing, exactly as
# before: this stays biased toward a fresh boot, because a resume mis-fire
# (waking someone else's conversation) is worse than no resume at all.
#
# probe_ran distinguishes "the app-server answered and the answer was ambiguous"
# from "there was no app-server to ask". Only the second may fall through to the
# rollout scan: an ambiguous answer is a firm statement that this session cannot
# be identified, and letting a weaker source overrule it is how a wrong thread
# gets seated.
probe_ran=0
# The URL, not the environment variable. Under codex 0.146 `--remote` this script
# runs inside the app-server process, which is a context codex-monitor.sh cannot
# export into, so gating on the variable meant this probe never ran on the very
# path #579 was about. The port file carries the same string (see _app-server.sh).
app_server="$(_agmsg_codex_app_server_url "$PROJECT")"
if [ -z "$thread" ] && [ -n "$app_server" ]; then
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/node.sh"
  node_bin="$(agmsg_resolve_node 2>/dev/null || true)"
  if [ -n "$node_bin" ] && { command -v "$node_bin" >/dev/null 2>&1 || [ -x "$node_bin" ]; }; then
    loaded_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-codexloaded.XXXXXX" 2>/dev/null || true)"
    seated_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-codexseated.XXXXXX" 2>/dev/null || true)"
    if [ -n "$loaded_file" ] && [ -n "$seated_file" ]; then
      # Exit status, not output: an empty list is a valid answer ("nothing is
      # loaded"), while a failure to reach the app-server is not an answer at all.
      if "$node_bin" "$SCRIPT_DIR/codex-bridge.js" --app-server "$app_server" \
           --print-loaded-threads >"$loaded_file.raw" 2>/dev/null; then
        probe_ran=1
      fi
      grep . "$loaded_file.raw" 2>/dev/null | sort -u > "$loaded_file" || true
      rm -f "$loaded_file.raw"
      # Every recorded codex seat, not just this project's. Over-subtracting can
      # only drop a thread that some role already owns, which is never the one we
      # want to claim; under-subtracting would leave a stale thread in the set and
      # make the count ambiguous.
      agmsg_role_session_recorded_uuids codex 2>/dev/null | grep . | sort -u > "$seated_file" || true
      if [ "$probe_ran" = "1" ]; then
        cand_count="$(comm -23 "$loaded_file" "$seated_file" | grep -c . || true)"
        if [ "${cand_count:-0}" -eq 1 ]; then
          thread="$(comm -23 "$loaded_file" "$seated_file" | grep . | head -1)"
        fi
      fi
    fi
    rm -f "$loaded_file" "$seated_file"
  fi
fi

# An answered-but-ambiguous probe ends here: the app-server has already said this
# session cannot be told apart, and no weaker signal may overturn that.
if [ "$probe_ran" = "1" ]; then
  [ -n "$thread" ] || exit 0
fi

if [ -z "$thread" ]; then
  # No app-server to ask, or it could not be reached -- a codex session outside
  # monitor mode, a missing Node, a server that is not answering. The rollout scan
  # is the only signal left, so it stays as the fallback: it still resolves the
  # single-rollout case it always did, and on a project with history it records
  # nothing, which is what happens today.
  #
  # ${HOME:-} so an unset HOME under `set -u` is a silent no-op (empty -> the
  # dir check below fails -> fresh), not an unbound-variable abort (co1 nit).
  sessions_dir="${HOME:-}/.codex/sessions"
  if [ -n "${HOME:-}" ] && [ -d "$sessions_dir" ]; then
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
      # grep -c already prints 0 on no match (exit 1), so no echo fallback --
      # only the unreadable-file case (no output at all) needs the 0 default.
      tid_count="$(grep -c . "$tids_file" 2>/dev/null || true)"
      if [ "${tid_count:-0}" -eq 1 ]; then
        thread="$(head -1 "$tids_file")"
      fi
      rm -f "$tids_file"
    fi
  fi
fi

[ -n "$thread" ] || exit 0
# codex thread ids are already bare UUIDs (no composite pid form), so record
# as-is. The project is recorded in its canonical (physical) form so records
# carry one path spelling regardless of how the caller spelled the argument.
agmsg_role_session_record "$TEAM" "$AGENT" "$thread" "$project_phys" codex || true
exit 0
