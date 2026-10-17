#!/usr/bin/env bats

# Claude Code native-channel delivery (2026-10-05, arch-8 §12.1): once
# agmsgd's own executor is verifiably ready, a claude-code seat must stop
# arming the generic Monitor watcher — the daemon delivers to its messaging
# socket directly instead, and a second, redundant receive path serves no
# purpose. But "ready" alone is not enough to skip Monitor (#1577 review):
# the daemon only ever addresses a seat whose role-session record actually
# carries a readable messaging_socket/claude_config_dir, so skipping Monitor
# for a seat that never got that record (never actas-claimed) would leave it
# with no delivery path at all. This file pins both halves of that gate.

load test_helper

setup() {
  setup_test_env
  export AGMSG_PLUGIN_DIRS=""
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  export PROJ="/tmp/agmsg-session-start-native-channel-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
}

teardown() { teardown_test_env; }

_run_session_start() {
  env AGMSG_RESOLVE_PROJECT=0 CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/$1.sock" \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< "{\"session_id\":\"$1\"}"
}

_mark_daemon_ready() {
  sqlite3 "$RUN_DIR/install.db" < "$SCRIPTS/daemon/schema.sql"
  local boot
  case "$(uname -s)" in
    Darwin) boot="$(sysctl -n kern.bootsessionuuid)" ;;
    Linux) boot="$(sed -n 's/^btime //p' /proc/stat)" ;;
    *) skip 'POSIX beta executor evidence' ;;
  esac
  sqlite3 "$RUN_DIR/install.db" "UPDATE meta SET node_path='$(command -v node)'; UPDATE daemon_intent SET desired='on';
    UPDATE daemon_owner SET state='ready', executor_pid=$$, executor_boot_id='$boot', executor_started_at=strftime('%Y-%m-%dT%H:%M:%fZ','now');"
}

# #1577 re-review repro: a conversation that actas'd alice, then
# LATER actas'd bob, leaves BOTH role-session records carrying the same
# session=shared (actas-claim.sh always writes the CURRENT session's bare
# sid into whichever record it claims). A later caller with that same bare
# sid is genuinely resuming only ONE of those roles -- claiming the other's
# lock too would silently seize an actas exclusivity lock nobody asked for,
# with no watcher ever subscribed to use it. Neither role is ever claimed
# here on purpose: the daemon isn't ready (the precondition-first ordering
# this test also pins -- #1577 re-review point 2), so the plug must return
# before ever touching a lock at all, for either pair.
@test "session-start: two roles sharing a stale bare sid are never both claimed (#1577 re-review repro)" {
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  source "$SCRIPTS/lib/role-session.sh"
  agmsg_role_session_record team alice shared "$PROJ" claude-code
  agmsg_role_session_record team bob shared "$PROJ" claude-code

  run _run_session_start "shared"
  [ "$status" -eq 0 ]
  grep -qF "AGMSG monitor mode" <<<"$output"

  if ! command -v actas_lock_path >/dev/null 2>&1; then source "$SCRIPTS/lib/actas-lock.sh"; fi
  bob_lock="$(actas_lock_path team bob)"
  [ ! -e "$bob_lock" ]
  alice_lock="$(actas_lock_path team alice)"
  [ ! -e "$alice_lock" ]
}

@test "session-start: agmsgd ready AND an actas-claimed role-session record -> no Monitor directive" {
  _mark_daemon_ready
  # The SAME live pid on both calls, explicit -- the plug's ownership check
  # (#1577 re-review) is an exact match on the full composite "<sid>.<pid>",
  # so this positive case must prove the lock and the record really are
  # composite-identified, not rely on whatever agmsg_agent_pid's real
  # ancestry walk happens to resolve (or degrade to bare) in this
  # environment, which left this case passing or failing by accident.
  env AGMSG_AGENT_PID=$$ bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code alice "sid-daemon-ready" >/dev/null
  run env AGMSG_AGENT_PID=$$ AGMSG_RESOLVE_PROJECT=0 CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/sid-daemon-ready.sock" \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"sid-daemon-ready"}'
  [ "$status" -eq 0 ]
  refute grep -q "AGMSG monitor mode" <<<"$output"
  refute grep -q "invoke the Monitor tool" <<<"$output"
  grep -qF "agmsgd is running and will deliver" <<<"$output"
}

# actas_lock_claim is the write gate (not a raw read+compare): its own
# liveness check is what lets a genuine --resume (new pid, the OLD pid now
# dead) correctly reclaim the lock and keep delivering natively, while still
# refusing a same-bare-sid collision from a pid that is still alive (the
# test above). Claim first under a pid nothing on this machine will ever be,
# simulating the pre-resume process having already exited; the resumed
# session's own live pid must still be able to take over.
@test "session-start: a genuine --resume (dead old pid, same bare sid) reclaims the lock and still skips Monitor" {
  _mark_daemon_ready
  env AGMSG_AGENT_PID=999999999 bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code alice "sid-resumed" >/dev/null
  run env AGMSG_AGENT_PID=$$ AGMSG_RESOLVE_PROJECT=0 CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/sid-resumed.sock" \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"sid-resumed"}'
  [ "$status" -eq 0 ]
  refute grep -q "AGMSG monitor mode" <<<"$output"
  grep -qF "agmsgd is running and will deliver" <<<"$output"
}

# rc.2: an old record of the same session under a team that is no longer
# registered used to make the seat lookup ambiguous, so the switch to direct
# delivery was dropped without a word. Only registered pairs count now.
@test "session-start: a stale record of an unregistered team does not block the switch to direct delivery" {
  _mark_daemon_ready
  env AGMSG_AGENT_PID=$$ bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code alice "sid-stale-twin" >/dev/null
  source "$SCRIPTS/lib/role-session.sh"
  agmsg_role_session_record gone-team alice "sid-stale-twin" "$PROJ" claude-code
  run env AGMSG_AGENT_PID=$$ AGMSG_RESOLVE_PROJECT=0 CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/sid-stale-twin.sock" \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"sid-stale-twin"}'
  [ "$status" -eq 0 ]
  refute grep -q "AGMSG monitor mode" <<<"$output"
  grep -qF "agmsgd is running and will deliver" <<<"$output"
}

@test "session-start: agmsgd not running -> the usual Monitor directive still fires" {
  run _run_session_start "sid-no-daemon"
  [ "$status" -eq 0 ]
  grep -qF "AGMSG monitor mode" <<<"$output"
}

# #1577 review required a seat with no record to keep Monitor, since the
# daemon cannot address it. rc.2 (the new path is the default)
# reverses that for the one case where the seat is not in doubt: the project
# has a single registered pair of this type, which is the seat the Monitor
# directive itself would watch. Nothing is recorded and no lock exists (the
# shape of a seat never recorded); the switch writes the record and takes the lock.
@test "session-start: agmsgd ready, NO record, NO lock, one registered seat -> switches to direct delivery" {
  _mark_daemon_ready
  run env AGMSG_AGENT_PID=$$ AGMSG_RESOLVE_PROJECT=0 CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/sid-ready-no-record.sock" \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"sid-ready-no-record"}'
  [ "$status" -eq 0 ]
  refute grep -q "AGMSG monitor mode" <<<"$output"
  grep -qF "agmsgd is running and will deliver" <<<"$output"
  source "$SCRIPTS/lib/role-session.sh"
  [ "$(agmsg_role_session_get team alice messaging_socket)" = /tmp/cc-socks/sid-ready-no-record.sock ]
}

# #1577 re-review: comparing only the BARE session id let one process
# overwrite another's record whenever the two happened to share the same
# underlying sid under different pids (two live --resume/--continue
# processes of the same conversation -- same hazard class as #1568). bob
# holds the actas lock as the composite "shared.<a live pid>"; the caller's
# own SESSION_ID is the SAME bare "shared" but a DIFFERENT live pid, so the
# caller's own composite id differs from bob's lock owner even though their
# bare sids are identical. Only an exact composite match may write.
# The seat's record belongs to whoever it names: another live session holding
# the lock must keep its record even when the record lacks a type line.
@test "session-start: a lone seat held by another live session keeps that session's record" {
  _mark_daemon_ready
  source "$SCRIPTS/lib/role-session.sh"
  source "$SCRIPTS/lib/actas-lock.sh"
  agmsg_role_session_record team alice peer "$PROJ" ""
  actas_lock_claim team alice "peer.$$" >/dev/null
  run env AGMSG_AGENT_PID=1 AGMSG_RESOLVE_PROJECT=0 CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/new.sock" \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"new"}'
  [ "$status" -eq 0 ]
  [ "$(agmsg_role_session_uuid team alice)" = peer ]
}

# The daemon's Claude channel blocks any non-sqlite storage, so declaring the
# native channel there would leave the seat with no delivery at all.
@test "actas-claim: a non-sqlite storage config never declares delivery=native" {
  _mark_daemon_ready
  printf '{"storage":"jsonl"}\n' > "$BATS_TEST_TMPDIR/config.json"
  run env AGMSG_CONFIG="$BATS_TEST_TMPDIR/config.json" AGMSG_AGENT_PID=$$ CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/sid-jsonl.sock" \
    bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code alice "sid-jsonl"
  [ "$status" -eq 0 ]
  refute grep -qx "delivery=native" <<<"$output"
  run env AGMSG_CONFIG="$BATS_TEST_TMPDIR/config.json" AGMSG_AGENT_PID=$$ AGMSG_RESOLVE_PROJECT=0 CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/sid-jsonl.sock" \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"sid-jsonl"}'
  grep -qF "AGMSG monitor mode" <<<"$output"
  refute grep -q "agmsgd is running and will deliver" <<<"$output"
}

# The gate asks the daemon's own config reader, so what the daemon refuses
# (here a symlinked config) is refused here too.
@test "native storage gate: a symlinked sqlite config is refused, as the daemon refuses it" {
  _mark_daemon_ready
  source "$SCRIPTS/lib/role-session.sh"
  mkdir -p "$BATS_TEST_TMPDIR/cfg"
  printf '{"storage":"sqlite"}\n' > "$BATS_TEST_TMPDIR/cfg/real.json"
  ln -s "$BATS_TEST_TMPDIR/cfg/real.json" "$BATS_TEST_TMPDIR/cfg/link.json"
  AGMSG_CONFIG="$BATS_TEST_TMPDIR/cfg/real.json" agmsg_claude_code_native_storage_ready
  run env AGMSG_CONFIG="$BATS_TEST_TMPDIR/cfg/link.json" SKILL_DIR="$SKILL_DIR" \
    bash -c '. "$1/scripts/lib/role-session.sh"; agmsg_claude_code_native_storage_ready' _ "$SCRIPTS/.."
  [ "$status" -ne 0 ]
}

# A seat chosen by actas moves to direct delivery on the spot, even when the
# project registers several seats (session-start alone cannot pick one then).
@test "actas-claim: daemon ready and a messaging socket -> records the socket and prints delivery=native" {
  _mark_daemon_ready
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  run env AGMSG_AGENT_PID=$$ CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/sid-actas-native.sock" \
    bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code bob "sid-actas-native"
  [ "$status" -eq 0 ]
  grep -qx "delivery=native" <<<"$output"
  source "$SCRIPTS/lib/role-session.sh"
  [ "$(agmsg_role_session_get team bob messaging_socket)" = /tmp/cc-socks/sid-actas-native.sock ]
}

@test "session-start: a different live pid with the SAME bare session id never overwrites that seat's record" {
  _mark_daemon_ready
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  env AGMSG_AGENT_PID=$$ bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code bob "shared" >/dev/null
  source "$SCRIPTS/lib/role-session.sh"
  agmsg_role_session_set_messaging team bob /tmp/cc-socks/bob-original.sock /home/bob/.claude shared

  # A second, DIFFERENT live pid (this bats test's own subshell, genuinely
  # alive and distinct from $$) claims the SAME bare sid for a different
  # agent -- the scenario this test exists to catch.
  ( env AGMSG_AGENT_PID=$BASHPID bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
    env AGMSG_AGENT_PID=$BASHPID bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code alice "shared" >/dev/null
    env AGMSG_AGENT_PID=$BASHPID AGMSG_RESOLVE_PROJECT=0 CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/shared.$BASHPID.sock" \
      bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"shared"}' ) >/dev/null

  [ "$(agmsg_role_session_get team bob messaging_socket)" = /tmp/cc-socks/bob-original.sock ]
  [ "$(agmsg_role_session_get team bob claude_config_dir)" = /home/bob/.claude ]
  [ "$(agmsg_role_session_uuid team bob)" = shared ]
}

# #1577 review: agmsgd's own Claude Code channel does not send to a Windows
# seat at all yet (named pipe + mandatory auth line is separate work), so the
# plug must never skip Monitor there even with a daemon that is otherwise
# ready and a role-session record that otherwise round-trips cleanly. Faking
# `uname -s` for the whole session-start.sh run (as the full integration tests
# above do for ready/not-ready) is unusable here: compat.sh's OWN platform
# branches change unrelated behavior under a faked Windows uname too, which
# would make this pass or fail for a confounded reason rather than the
# platform check this test exists to pin. Isolate it instead: stub every
# collaborator agmsg_session_start calls so the only real logic under test is
# its own final gate, and set _agmsg_platform directly (compat.sh's own memo
# variable, read, never recomputed, once non-empty).
@test "session-start plug: the Monitor-skip gate itself never fires on Windows, in isolation" {
  run bash -c '
    set -uo pipefail
    SKILL_DIR="'"$TEST_SKILL_DIR"'"
    PROJECT="/tmp/p1"
    TYPE="claude-code"
    SESSION_ID="sid-1"
    PAIRS="T	alice"
    CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/1.sock"
    CLAUDE_CONFIG_DIR="/home/x/.claude"
    # Stubs: every collaborator reports "this pair is fully addressable" --
    # the one thing NOT stubbed is _agmsg_platform/_agmsg_detect_platform and
    # agmsg_daemon_read_state, which together are what this test is pinning.
    agmsg_role_session_set_messaging() { :; }
    agmsg_role_session_get() { printf "%s" "$3" | grep -q socket && echo "/tmp/cc-socks/1.sock" || echo "/home/x/.claude"; }
    agmsg_role_session_uuid() { echo "sid-1"; }
    actas_lock_claim() { echo "ok"; }
    agmsg_instance_bare_sid() { printf "%s" "$1"; }
    agmsg_normalize_instance_id() { echo "sid-1.4242"; }
    agmsg_instance_is_composite() { case "$1" in *.*) return 0 ;; *) return 1 ;; esac; }
    agmsg_daemon_read_state() { AGMSGD_HEALTH=ready; }
    _agmsg_platform=msys
    _agmsg_detect_platform() { :; }   # already set -- compat.sh itself would also no-op here

    SKILL_DIR="$SKILL_DIR" . "'"$TEST_SKILL_DIR"'/scripts/drivers/types/claude-code/_session-start.sh"
    agmsg_session_start
    echo "FELL THROUGH (correct: Windows must not skip Monitor)"
  '
  [ "$status" -eq 0 ]
  grep -qF "FELL THROUGH" <<<"$output"
  refute grep -q "agmsgd is running and will deliver" <<<"$output"
}
