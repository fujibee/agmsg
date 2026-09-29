#!/usr/bin/env bats
# Isolated scripts and data, without replacing HOME or touching real services.
assert_contains() {
  case "$output" in *"$1"*) return 0 ;; *) printf 'Missing: %s\nOutput: %s\n' "$1" "$output" >&2; return 1 ;; esac
}
assert_lacks() {
  case "$output" in *"$1"*) printf 'Unexpected: %s\n' "$1" >&2; return 1 ;; *) return 0 ;; esac
}
refute() {
  if "$@"; then return 1; fi
  return 0
}
setup() {
  export TEST_SKILL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agmsgd-switch.XXXXXX")"
  TEST_SKILL_DIR="$(cd "$TEST_SKILL_DIR" && pwd -P)"
  cp -R "$BATS_TEST_DIRNAME/../scripts" "$TEST_SKILL_DIR/scripts"
  export SCRIPTS="$TEST_SKILL_DIR/scripts"
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/teams/demo" "$TEST_SKILL_DIR/db" "$TEST_SKILL_DIR/codex-profile"
  export AGMSG_CONFIG="$TEST_SKILL_DIR/config.json"
  export AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/db"
  export CODEX_HOME="$TEST_SKILL_DIR/codex-profile"
  export AGMSG_SELF_NAME=off
  unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH
  unset AGMSG_CODEX_SEAT_KEY AGMSG_CODEX_BRIDGE_APP_SERVER AGMSG_CODEX_SHIM_DISABLE AGMSG_CODEX_BRIDGE
  sqlite3 "$TEST_SKILL_DIR/run/install.db" < "$SCRIPTS/daemon/schema.sql"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE meta SET install_id='switch-test'; UPDATE daemon_intent SET desired='on';"
  printf '{"install_id":"switch-test","gen":1}\n' > "$TEST_SKILL_DIR/run/install-manifest.json"
  printf '{"name":"demo","agents":{"alice":{"registrations":[{"type":"codex","project":"%s"}]},"bob":{"registrations":[{"type":"codex","project":"%s"}]}}}\n' "$TEST_SKILL_DIR" "$TEST_SKILL_DIR" > "$TEST_SKILL_DIR/teams/demo/config.json"
  export CALL_LOG="$TEST_SKILL_DIR/calls"
  export AGMSG_REAL_CODEX="$TEST_SKILL_DIR/real-codex"
  export AGMSG_CODEX_MONITOR_CMD="$TEST_SKILL_DIR/monitor"
  printf '#!/usr/bin/env bash\nprintf "plain %%s\\n" "$*" >> "$CALL_LOG"\n' > "$AGMSG_REAL_CODEX"
  printf '#!/usr/bin/env bash\nprintf "monitor %%s\\n" "$*" >> "$CALL_LOG"\n' > "$AGMSG_CODEX_MONITOR_CMD"
  chmod +x "$AGMSG_REAL_CODEX" "$AGMSG_CODEX_MONITOR_CMD"
  # Monitor mode lets missing/unreadable DB retain the existing launch route.
  mkdir -p "$TEST_SKILL_DIR/project/.codex"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s/session-start.sh"}]}]}}\n' "$SCRIPTS" > "$TEST_SKILL_DIR/project/.codex/hooks.json"
}

@test "enabled shim passes arguments unchanged and launches no monitor even when daemon is stopped" {
  run bash "$SCRIPTS/drivers/types/codex/codex-shim.sh" -C "$TEST_SKILL_DIR/project" resume --last
  [ "$status" -eq 0 ]
  assert_contains 'without a bridge'
  assert_contains 'agmsg daemon start'
  assert_contains "$SCRIPTS/agmsg"
  grep -Fq "plain -C $TEST_SKILL_DIR/project resume --last" "$CALL_LOG"
  refute grep -q '^monitor' "$CALL_LOG"
}

@test "off, missing and unreadable install records retain the existing monitor route" {
  for condition in off missing unreadable; do
    case "$condition" in
      off) sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_intent SET desired='off';" ;;
      missing) mv "$TEST_SKILL_DIR/run/install.db" "$TEST_SKILL_DIR/run/saved.db" ;;
      unreadable) printf 'invalid sqlite data\n' > "$TEST_SKILL_DIR/run/install.db" ;;
    esac
    : > "$CALL_LOG"
    run bash "$SCRIPTS/drivers/types/codex/codex-shim.sh" -C "$TEST_SKILL_DIR/project" resume --last
    [ "$status" -eq 0 ]
    grep -q '^monitor' "$CALL_LOG"
    assert_lacks 'agmsgd handles'
  done
}

@test "direct monitor wrapper also bypasses app-server and dispatcher while enabled" {
  run bash "$SCRIPTS/drivers/types/codex/codex-monitor.sh" --project "$TEST_SKILL_DIR" --codex-command resume -- --last
  [ "$status" -eq 0 ]
  grep -Fq 'plain resume --last' "$CALL_LOG"
  [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" 'SELECT desired FROM daemon_intent;')" = on ]
  local files
  files="$(printf '%s\n' "$TEST_SKILL_DIR/run/"*)"
  [ "${files#*codex-seat}" = "$files" ]
  [ "${files#*codex-bridge-request}" = "$files" ]
}

@test "ordinary operations warn once per install without Node and keep stdout clean" {
  mkdir -p "$TEST_SKILL_DIR/no-node"
  printf '#!/usr/bin/env bash\necho unexpected-node >> "$CALL_LOG"\nexit 1\n' > "$TEST_SKILL_DIR/no-node/node"
  chmod +x "$TEST_SKILL_DIR/no-node/node"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "INSERT INTO daemon_start_attempts VALUES ('2099-01-01','no usable Node recorded',0);"
  PATH="$TEST_SKILL_DIR/no-node:$PATH" run bash "$SCRIPTS/identities.sh" "$TEST_SKILL_DIR" codex
  [ "$status" -eq 0 ]
  assert_contains 'Node >= 22.13.0'
  assert_contains 'agmsg daemon enable'
  assert_contains alice
  PATH="$TEST_SKILL_DIR/no-node:$PATH" run bash "$SCRIPTS/identities.sh" "$TEST_SKILL_DIR" codex
  [ "$status" -eq 0 ]
  assert_lacks 'stopped while enabled'
  [ -f "$TEST_SKILL_DIR/run/agmsgd-warning-at" ]
  [ ! -f "$CALL_LOG" ]
}

@test "warning interval is rolling across clock windows and expires after ten minutes" {
  mkdir -p "$TEST_SKILL_DIR/clock"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$TEST_NOW"\n' > "$TEST_SKILL_DIR/clock/date"
  chmod +x "$TEST_SKILL_DIR/clock/date"
  PATH="$TEST_SKILL_DIR/clock:$PATH" TEST_NOW=1199 run bash "$SCRIPTS/identities.sh" "$TEST_SKILL_DIR" codex
  assert_contains 'stopped while enabled'
  PATH="$TEST_SKILL_DIR/clock:$PATH" TEST_NOW=1201 run bash "$SCRIPTS/identities.sh" "$TEST_SKILL_DIR" codex
  assert_lacks 'stopped while enabled'
  PATH="$TEST_SKILL_DIR/clock:$PATH" TEST_NOW=1799 run bash "$SCRIPTS/identities.sh" "$TEST_SKILL_DIR" codex
  assert_contains 'stopped while enabled'
}

@test "warning cleanup removes only past slots and preserves current and newer claims" {
  mkdir -p "$TEST_SKILL_DIR/clock" "$TEST_SKILL_DIR/run/agmsgd-warning-slot.0" "$TEST_SKILL_DIR/run/agmsgd-warning-slot.2" "$TEST_SKILL_DIR/run/agmsgd-warning-slot.unknown"
  printf '#!/usr/bin/env bash\nprintf "1199\\n"\n' > "$TEST_SKILL_DIR/clock/date"
  chmod +x "$TEST_SKILL_DIR/clock/date"
  PATH="$TEST_SKILL_DIR/clock:$PATH" run bash "$SCRIPTS/identities.sh" "$TEST_SKILL_DIR" codex
  [ "$status" -eq 0 ]
  assert_contains 'stopped while enabled'
  [ ! -d "$TEST_SKILL_DIR/run/agmsgd-warning-slot.0" ]
  [ -d "$TEST_SKILL_DIR/run/agmsgd-warning-slot.1" ]
  [ -d "$TEST_SKILL_DIR/run/agmsgd-warning-slot.2" ]
  [ -d "$TEST_SKILL_DIR/run/agmsgd-warning-slot.unknown" ]
}

@test "status and doctor report enabled failure even without usable Node" {
  mkdir -p "$TEST_SKILL_DIR/no-node"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_SKILL_DIR/no-node/node"
  chmod +x "$TEST_SKILL_DIR/no-node/node"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "INSERT INTO daemon_start_attempts VALUES ('2099-01-01','no usable Node recorded',0);"
  PATH="$TEST_SKILL_DIR/no-node:$PATH" run bash "$SCRIPTS/daemon.sh" status
  [ "$status" -eq 1 ]
  assert_contains 'no usable Node recorded'
  assert_contains 'agmsg daemon enable'
  PATH="$TEST_SKILL_DIR/no-node:$PATH" run bash "$SCRIPTS/doctor.sh" --team demo --type codex --redacted
  [ "$status" -eq 1 ]
  assert_contains 'Codex notices'
  assert_contains 'agmsg daemon start'
  assert_lacks demo/alice
}

@test "concurrent ordinary operations claim only one warning" {
  bash "$SCRIPTS/identities.sh" "$TEST_SKILL_DIR" codex > "$TEST_SKILL_DIR/one.out" 2> "$TEST_SKILL_DIR/one.err" &
  local one=$!
  bash "$SCRIPTS/identities.sh" "$TEST_SKILL_DIR" codex > "$TEST_SKILL_DIR/two.out" 2> "$TEST_SKILL_DIR/two.err" &
  local two=$!
  wait "$one"
  wait "$two"
  [ "$(cat "$TEST_SKILL_DIR/one.err" "$TEST_SKILL_DIR/two.err" | grep -c 'stopped while enabled')" -eq 1 ]
  refute grep -q agmsgd "$TEST_SKILL_DIR/one.out"
  refute grep -q agmsgd "$TEST_SKILL_DIR/two.out"
}

@test "status on a never-started enabled install fails with recovery and missing destinations" {
  run bash "$SCRIPTS/daemon.sh" status
  [ "$status" -eq 1 ]
  assert_contains 'agmsg daemon start'
  assert_contains 'no destination record'
  assert_contains 'demo/alice'
}

@test "executor evidence recognizes a live ready owner and rejects a changed boot" {
  local boot
  case "$(uname -s)" in
    Darwin) boot="$(sysctl -n kern.boottime | sed -n 's/.*sec = \([0-9]*\),.*/\1/p')" ;;
    Linux) boot="$(sed -n 's/^btime //p' /proc/stat)" ;;
    *) skip 'POSIX beta executor evidence' ;;
  esac
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_owner SET state='ready', executor_pid=$$, executor_boot_id='$boot', executor_started_at=strftime('%Y-%m-%dT%H:%M:%fZ','now');"
  run bash -c 'source "$SCRIPTS/lib/daemon-state.sh"; agmsg_daemon_read_state; printf "%s\n" "$AGMSGD_HEALTH"'
  [ "$status" -eq 0 ]
  [ "$output" = ready ]
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_owner SET executor_boot_id='previous-boot';"
  run bash -c 'source "$SCRIPTS/lib/daemon-state.sh"; agmsg_daemon_read_state; printf "%s\n" "$AGMSGD_HEALTH"'
  [ "$output" = stopped ]
}

@test "all enabled failure causes produce recovery notices without losing messages" {
  for reason in 'restart limit reached' 'no usable Node recorded' 'repeated startup failures' crash; do
    sqlite3 "$TEST_SKILL_DIR/run/install.db" "DELETE FROM daemon_start_attempts; INSERT INTO daemon_start_attempts VALUES ('2099-01-01','$reason',0);"
    run bash -c 'source "$SCRIPTS/lib/daemon-state.sh"; agmsg_daemon_warn_if_stopped always'
    [ "$status" -eq 0 ]
    assert_contains "$reason"
    assert_contains 'agmsg daemon start'
    assert_contains 'Unread messages are preserved'
    [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" 'SELECT desired FROM daemon_intent;')" = on ]
  done
}

@test "disable inventory distinguishes bridge sessions and warns about JSONL" {
  printf '{"storage":"jsonl"}\n' > "$AGMSG_CONFIG"
  # Match delivery.sh's current pid/metadata liveness contract.
  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/codex-bridge.demo.alice.pid"
  printf 'pid=%s\ntype=codex\nproject=%s\n' "$$" "$TEST_SKILL_DIR" > "$TEST_SKILL_DIR/run/codex-bridge.demo.alice.meta"
  mkdir -p "$TEST_SKILL_DIR/fake-bin"
  printf '#!/usr/bin/env bash\necho Unsupported\n' > "$TEST_SKILL_DIR/fake-bin/uname"
  chmod +x "$TEST_SKILL_DIR/fake-bin/uname"
  PATH="$TEST_SKILL_DIR/fake-bin:$PATH" run bash "$SCRIPTS/daemon.sh" disable
  [ "$status" -eq 0 ]
  assert_contains 'demo/alice: already using a bridge; no restart needed'
  assert_contains 'demo/bob: no bridge attached; restart Codex'
  assert_contains 'JSONL'
  assert_contains 'unread messages are preserved'
  [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" 'SELECT desired FROM daemon_intent;')" = off ]
}
