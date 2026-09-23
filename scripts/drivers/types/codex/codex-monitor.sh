#!/usr/bin/env bash
set -euo pipefail

# Launch Codex with agmsg's app-server bridge enabled.
#
# This is a convenience wrapper: it starts this seat's OWN app-server and lets
# session-start.sh launch codex-bridge.js in the background once Codex
# exposes CODEX_THREAD_ID to hooks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# Always RUN_DIR in production. The override exists only so a test can make
# JUST the resume-request write below fail (an unwritable directory) without
# also breaking this launch's seat log/record writes, which share RUN_DIR
# and must keep succeeding so Codex still starts (#1401 review).
RESUME_REQUEST_DIR="${AGMSG_CODEX_TEST_RESUME_REQUEST_DIR:-$RUN_DIR}"
# This starts the codex app-server and the bridge launcher, both of which
# outlive it. The `3>&- 4>&-` on those spawn lines closes the two descriptors
# we can name; the harness's is not one of them. See lib/close-fds.sh.
# shellcheck source=../../../lib/close-fds.sh
source "$SCRIPT_DIR/../../../lib/close-fds.sh"
agmsg_close_inherited_fds
# shellcheck source=../../../lib/hash.sh
source "$SCRIPT_DIR/../../../lib/hash.sh"
# shellcheck source=../../../lib/compat.sh
source "$SCRIPT_DIR/../../../lib/compat.sh"
# _agmsg_pid_alive_local for the port-wait loop below.
# shellcheck source=../../../lib/instance-id.sh
source "$SCRIPT_DIR/../../../lib/instance-id.sh"
# _agmsg_codex_seat_key_new / _agmsg_codex_seat_record_write and friends.
# shellcheck source=./_seat-key.sh
source "$SCRIPT_DIR/_seat-key.sh"
# agmsg_canonical_path, for matching a resume thread's project against role-
# session records in the SAME canonical form they were recorded in (#1401).
# shellcheck source=../../../lib/resolve-project.sh
source "$SCRIPT_DIR/../../../lib/resolve-project.sh"
# agmsg_role_session_match_unique, for the resume-arms-itself check below.
# shellcheck source=../../../lib/role-session.sh
source "$SCRIPT_DIR/../../../lib/role-session.sh"
# agmsg_shq, to safely quote the manual-fallback command in the loud-failure
# diagnostic below (#1401 review: the same naive-interpolation hazard #1392
# already fixed once for a different recovery line).
# shellcheck source=../../../lib/shquote.sh
source "$SCRIPT_DIR/../../../lib/shquote.sh"

PROJECT="$(pwd)"
SOCKET_PATH=""
CODEX_COMMAND="resume"
CODEX_ARGS=()
REAL_CODEX="${AGMSG_REAL_CODEX:-codex}"

usage() {
  cat <<EOF
Usage: codex-monitor.sh [--project <path>] [--codex-command <codex|resume>] [-- <args...>]

Starts this seat's own agmsg-managed Codex app-server on a loopback ws:// port,
enables agmsg Codex bridge delivery for this project, then execs:
  codex resume --remote ws://127.0.0.1:<port>

(--socket-path is accepted for compatibility but ignored: codex 0.141+ requires
a ws:// transport for --remote. See #170.)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --project)
      PROJECT="${2:?--project requires a path}"
      shift 2
      ;;
    --socket-path)
      SOCKET_PATH="${2:?--socket-path requires a path}"
      shift 2
      ;;
    --codex-command)
      CODEX_COMMAND="${2:?--codex-command requires codex or resume}"
      shift 2
      ;;
    --)
      shift
      CODEX_ARGS=("$@")
      break
      ;;
    *)
      CODEX_ARGS+=("$1")
      shift
      ;;
  esac
done

case "$CODEX_COMMAND" in
  codex|resume) ;;
  *)
    echo "codex-monitor: --codex-command must be 'codex' or 'resume'" >&2
    exit 1
    ;;
esac

PROJECT="$(cd "$PROJECT" && pwd)"

# Fail-open: never let a broken bridge block codex. If the agmsg app-server can't
# be brought up — e.g. a codex release changes the app-server interface and the
# launch/port detection fails — hand off to a plain codex session (no --remote
# bridge) instead of erroring out. The user keeps a working codex; only the
# agmsg monitor delivery is skipped for this launch.
#
# This is a LOUD fallback: it only runs on UNEXPECTED failure (the explicit
# AGMSG_CODEX_SHIM_DISABLE=1 bypass is handled in codex-shim.sh and never reaches
# here), so it must tell the user, on screen, that real-time delivery is off —
# otherwise message receipt stops silently. The earlier echoes give the specific
# reason + log path; this prints the one-line summary just before handoff.
exec_plain_codex() {
  # Fail-open is for a PERSON at the keyboard, who reads the banner and keeps a
  # working codex. A seat spawned by agmsg (spawn.sh exports AGMSG_SPAWNED=1)
  # has nobody at its pane: a plain codex there never receives a message, and
  # the banner is read by no one — the outcome looks exactly like the shim
  # bypass this launch path was built to close. So a spawned seat fails CLOSED:
  # say why, leave the pane's shell for whoever comes to look, start nothing.
  if [ "${AGMSG_SPAWNED:-}" = "1" ]; then
    echo "agmsg: Codex monitor bridge unavailable, and this session was spawned by agmsg (AGMSG_SPAWNED=1). Refusing to start a plain Codex: a spawned seat has no person at the pane to read this, and without the bridge it would never receive a message. The reason is printed above; see the app-server log for details." >&2
    exit 1
  fi
  echo "agmsg: Codex monitor bridge unavailable - launching plain Codex. Real-time agmsg delivery is OFF this session (messages still queue; check your inbox manually). Likely cause: the Codex app-server interface changed in 0.142+. Fix in progress." >&2
  cd "$PROJECT" 2>/dev/null || true
  case "$CODEX_COMMAND" in
    codex)  exec "$REAL_CODEX" ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"} ;;
    resume) exec "$REAL_CODEX" resume ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"} ;;
  esac
}

# #1254: one app-server per SEAT, never reused across seats -- a later seat's
# shell commands (which run inside the app-server, not the TUI, under
# --remote) used to inherit whatever pane the FIRST seat to reach a shared,
# project-keyed app-server was born with. There is no more sharing to
# arbitrate, so a fresh key and a fresh server are made on EVERY launch,
# unconditionally -- including a codex launched from inside another codex
# seat's own shell tool call, which must get its OWN seat, not silently
# attach to whatever AGMSG_CODEX_SEAT_KEY it happened to inherit (design
# review). The seat key only has to be unique -- see _seat-key.sh for why it
# is a pid+time+random nonce rather than anything requiring a start-time
# read, and why stopping this server later is a separate, stricter check.
SEAT_KEY="$(_agmsg_codex_seat_key_new)"
_agmsg_codex_seat_key_ok "$SEAT_KEY" || {
  echo "codex-monitor: generated an invalid seat key -- refusing to continue" >&2
  exit 1
}
SEAT_RECORD="$(_agmsg_codex_seat_record_path "$RUN_DIR" "$SEAT_KEY")"
SEAT_LOG="$(_agmsg_codex_seat_log_path "$RUN_DIR" "$SEAT_KEY")"
PROJECT_HASH="$(printf '%s' "$PROJECT" | agmsg_sha1)"
CODEX_VERSION="$("$REAL_CODEX" --version 2>/dev/null || true)"

mkdir -p "$RUN_DIR"

# codex 0.141+ accepts only ws:// (not unix://) for the TUI's --remote, so this
# seat's app-server listens on a loopback ws port instead of a unix socket.
# See #170.
port_alive() {  # $1 = port; succeeds if something is accepting on 127.0.0.1:$1
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# Let the app-server pick a free loopback port (--listen ws://127.0.0.1:0) and
# report it ("listening on: ws://127.0.0.1:<port>"). This keeps codex-monitor.sh
# free of any Node dependency — only the bridge (codex-bridge.js) needs Node, and
# it degrades on its own if Node is missing rather than taking down the TUI. See #170.
: > "$SEAT_LOG"
# fds 3 and 4 are closed for the same reason remote.sh closes them around the
# sync engine: under bats, fd 3 is the TAP pipe, and a daemon that inherits it
# holds the whole test file open until the CI timeout. This app-server is
# built to outlive its caller and is stopped only by codex-bridge-launcher.sh
# once this seat's TUI exits (see _seat-key.sh's stop function).
#
# AGMSG_CODEX_SEAT_KEY is set on the app-server's OWN command, not just
# exported below: its children (the shell-tool-command processes Codex runs
# under --remote) inherit THIS process's environment directly, which is the
# whole point -- no ancestry walk is needed anywhere downstream to find a
# seat's own server (design review, replacing an earlier ancestry-walk design).
AGMSG_CODEX_SEAT_KEY="$SEAT_KEY" \
  "$REAL_CODEX" app-server --listen "ws://127.0.0.1:0" >>"$SEAT_LOG" 2>&1 3>&- 4>&- &
server_bg="$!"

PORT=""
# codex 0.144+ colorizes this banner even when stdout is a redirected file
# (NO_COLOR is ignored), so strip ANSI SGR sequences before matching.
ansi_esc="$(printf '\033')"
for _ in $(seq 1 100); do
  PORT="$(sed -n -e "s/${ansi_esc}\[[0-9;]*m//g" -e 's#.*listening on: ws://127\.0\.0\.1:\([0-9][0-9]*\).*#\1#p' "$SEAT_LOG" | head -1)"
  [ -n "$PORT" ] && break
  # Stop waiting the moment the app-server exits (e.g. a codex release dropped
  # `app-server --listen ws://`): no point burning the full timeout before we
  # fail open.
  #
  # _local, deliberately: this pid came from $! in this shell, so it is numbered
  # in the MSYS pid space, and `tasklist` -- which is what the plain helper asks
  # under MSYSTEM -- has no record of it. It answered "dead" on the first pass
  # here, seconds before the banner, and every Windows launch since 1.1.12 fell
  # back to plain codex with no bridge (#567). Not a bare `kill -0` either: the
  # EPERM reading still has to hold, or a sandbox that cannot signal our own
  # child fails us open the same way (#505).
  _agmsg_pid_alive_local "$server_bg" || break
  sleep 0.1
done
if [ -z "$PORT" ]; then
  echo "codex-monitor: app-server did not report a listening port; starting codex without the agmsg bridge" >&2
  echo "codex-monitor: see $SEAT_LOG" >&2
  kill "$server_bg" 2>/dev/null || true
  exec_plain_codex
fi

if ! port_alive "$PORT"; then
  echo "codex-monitor: app-server not reachable on ws://127.0.0.1:$PORT; starting codex without the agmsg bridge" >&2
  echo "codex-monitor: see $SEAT_LOG" >&2
  kill "$server_bg" 2>/dev/null || true
  exec_plain_codex
fi
SOCKET_URL="ws://127.0.0.1:$PORT"

# Best-effort: a platform that cannot supply a start witness at all
# records witnesssrc/witness empty, and this seat's server is then
# never auto-stopped later -- left running, reported, never guessed at.
_witness_line=""
_witness_line="$(_agmsg_codex_seat_witness "$server_bg" 2>/dev/null || true)"
_witness_src="${_witness_line%%$'\t'*}"
_witness_val=""
case "$_witness_line" in *$'\t'*) _witness_val="${_witness_line#*$'\t'}" ;; esac
_agmsg_codex_seat_record_write "$SEAT_RECORD" "$PROJECT_HASH" "$server_bg" "$PORT" "$_witness_src" "$_witness_val" "$CODEX_VERSION" || {
  echo "codex-monitor: could not record this seat's app-server -- starting codex without the agmsg bridge" >&2
  kill "$server_bg" 2>/dev/null || true
  exec_plain_codex
}

"$SCRIPT_DIR/../../../delivery.sh" set monitor codex "$PROJECT" >/dev/null

export AGMSG_CODEX_BRIDGE=1
export AGMSG_CODEX_BRIDGE_APP_SERVER="$SOCKET_URL"
export AGMSG_CODEX_BRIDGE_LAUNCHER=1
export AGMSG_CODEX_SEAT_KEY="$SEAT_KEY"

# #1401: a resumed seat used to have no bridge until either its own
# SessionStart hook eventually ran (observed taking minutes, and in at least
# one case never, before a person or the model manually re-ran
# codex-record-session.sh) or someone did that by hand. Neither is automatic.
# But the thread being resumed is already known HERE, in $CODEX_ARGS, before
# codex itself has even started -- codex-shim.sh forwards a `codex resume
# <thread>` invocation's arguments through unchanged past the literal "resume"
# token. If that thread is recorded as belonging to EXACTLY ONE (team, agent)
# role in THIS project, arm the bridge request immediately, the same shape
# codex-record-session.sh itself writes -- no need to wait on the hook or a
# human at all in the one case this can be decided without guessing.
#
# Deliberately narrow: only a single bare positional argument (no leading
# '-') is treated as a thread id -- `codex resume` with no argument opens
# Codex's own interactive picker, which is not one specific thread this
# script could commit to yet, and a flag is not a thread id. Zero or more
# than one matching role is silence, exactly like every other inference in
# this family (agmsg_role_session_match_unique's own header, and
# codex-record-session.sh's rollout-scan fallback) -- guessing which role
# owns a resumed thread is worse than leaving it to arm the way it does today.
if [ "$CODEX_COMMAND" = resume ] && [ "${#CODEX_ARGS[@]}" -eq 1 ]; then
  case "${CODEX_ARGS[0]}" in
    -*) : ;;
    *)
      _resume_thread="${CODEX_ARGS[0]}"
      _resume_match=""
      _resume_match="$(agmsg_role_session_match_unique codex "$(agmsg_canonical_path "$PROJECT")" "$_resume_thread" 2>/dev/null || true)"
      if [ -n "$_resume_match" ]; then
        _resume_team="${_resume_match%%$'\t'*}"
        _resume_agent="${_resume_match#*$'\t'}"
        _resume_request_file="$RESUME_REQUEST_DIR/codex-bridge-request.$SEAT_KEY"
        _resume_request_tmp="$_resume_request_file.$$"
        _resume_fail_stage=""
        if ! mkdir -p "$RESUME_REQUEST_DIR" 2>/dev/null; then
          _resume_fail_stage="mkdir $RESUME_REQUEST_DIR"
        elif ! printf 'codex\t%s\t%s\t%s\t%s\n' "$_resume_thread" "$SOCKET_URL" "$_resume_team" "$_resume_agent" > "$_resume_request_tmp" 2>/dev/null; then
          _resume_fail_stage="write $_resume_request_tmp"
        elif ! mv "$_resume_request_tmp" "$_resume_request_file" 2>/dev/null; then
          _resume_fail_stage="rename $_resume_request_tmp -> $_resume_request_file"
          rm -f "$_resume_request_tmp" 2>/dev/null || true
        fi
        # Loud, not fatal (#1401 review): the role match already told us who
        # owns this thread, so a failed write here silently reproduces the
        # exact "resume never gets a bridge" symptom this fix exists to close
        # -- via a different cause. Codex still launches either way; only the
        # diagnostic (and the manual fallback it points at) changes.
        if [ -n "$_resume_fail_stage" ]; then
          echo "codex-monitor: could not arm the bridge request for $_resume_team/$_resume_agent ($_resume_fail_stage failed) -- Codex will still start without the bridge. Run this by hand once Codex is up to bring it: codex-record-session.sh $(agmsg_shq "$_resume_team") $(agmsg_shq "$_resume_agent") $(agmsg_shq "$PROJECT")" >&2
        fi
      fi
      ;;
  esac
fi

launcher_cmd="${AGMSG_CODEX_BRIDGE_LAUNCHER_CMD:-$SCRIPT_DIR/codex-bridge-launcher.sh}"
# Same guard: the launcher is detached on purpose and outlives this script, so
# an inherited fd 3 would outlive the test file that started it.
"$launcher_cmd" codex "$PROJECT" "$SOCKET_URL" "$$" >/dev/null 2>&1 3>&- 4>&- &

cd "$PROJECT"
# Guard the array expansion: under bash 3.2 + `set -u`, "${CODEX_ARGS[@]}" on an
# empty array errors with "unbound variable" (a no-arg `codex`/`codex resume`).
case "$CODEX_COMMAND" in
  codex)
    exec "$REAL_CODEX" --remote "$SOCKET_URL" ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"}
    ;;
  resume)
    exec "$REAL_CODEX" resume --remote "$SOCKET_URL" ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"}
    ;;
esac
