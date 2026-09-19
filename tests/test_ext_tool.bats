#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  FAKETOOL_DIR="$SCRIPTS/drivers/ext-tools/faketool"
  mkdir -p "$FAKETOOL_DIR"

  # A few seconds, not the default 30s, so the fast-completion scenario below
  # (checking dispatch is still alive, still waiting on its killer, shortly
  # after the reply lands) does not have to wait long -- but long enough to
  # comfortably outlast the handful of subprocess-spawning assertions
  # between the reply landing and that check.
  printf '%s\n' \
    'name=faketool' \
    'timeout=4' \
    > "$FAKETOOL_DIR/tool.conf"

  printf '%s\n' \
    '# faketool setup' \
    '' \
    'Run this, then `save`, then `test`:' \
    '' \
    '  bash scripts/ext-tool.sh setup <team> <name> faketool save' \
    > "$FAKETOOL_DIR/SETUP.md"

  # A fake, non-interactive setup: save writes the member config directly
  # (the real contract — drivers/ext-tools/README.md), status/check/test are
  # no-ops that just prove the dispatch reaches them.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  status) echo "{\"missing\":[]}" ;;'
    printf '%s\n' '  check) exit 0 ;;'
    printf '%s\n' '  save)'
    printf '%s\n' '    printf "tool=faketool\n" > "${2:?}"'
    printf '%s\n' '    chmod 600 "${2:?}"'
    printf '%s\n' '    ;;'
    printf '%s\n' '  test) exit 0 ;;'
    printf '%s\n' '  *) echo "faketool setup: unknown subcommand ${1:-}" >&2; exit 1 ;;'
    printf '%s\n' 'esac'
  } > "$FAKETOOL_DIR/setup"
  chmod +x "$FAKETOOL_DIR/setup"

  # A fake handle: echoes the received body back with a fixed prefix, so the
  # reply is unambiguous evidence it actually ran with the message this test
  # sent, not some other input.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'input="$(cat)"'
    printf '%s\n' 'body="$(printf %s "$input" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"body\"])")"'
    printf '%s\n' 'echo "faketool reply: $body"'
  } > "$FAKETOOL_DIR/handle"
  chmod +x "$FAKETOOL_DIR/handle"

  # A second tool whose handle never returns, to exercise the timeout path
  # (a 1s tool.conf timeout keeps the test fast). setup/SETUP.md are unused by
  # this scenario but the driver dir needs a valid tool.conf to be joinable.
  SLOWTOOL_DIR="$SCRIPTS/drivers/ext-tools/slowtool"
  mkdir -p "$SLOWTOOL_DIR"
  printf '%s\n' \
    'name=slowtool' \
    'timeout=1' \
    > "$SLOWTOOL_DIR/tool.conf"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  save) printf "tool=slowtool\n" > "${2:?}"; chmod 600 "${2:?}" ;;'
    printf '%s\n' '  *) exit 0 ;;'
    printf '%s\n' 'esac'
  } > "$SLOWTOOL_DIR/setup"
  chmod +x "$SLOWTOOL_DIR/setup"
  # handle backgrounds its own grandchild, which ignores TERM (the way a
  # stubborn real command might) -- proving the watchdog's KILL escalation
  # actually runs, not just that a TERM-obedient child happens to die.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'cat >/dev/null'
    printf '%s\n' 'dir="$(cd "$(dirname "$0")" && pwd)"'
    printf '%s\n' "(trap '' TERM; exec sleep 30) &"
    printf '%s\n' 'echo "$!" > "$dir/sleep.pid"'
    printf '%s\n' 'wait'
  } > "$SLOWTOOL_DIR/handle"
  chmod +x "$SLOWTOOL_DIR/handle"
}

teardown() { teardown_test_env; }

@test "ext-tool: join refuses without config, save then join succeeds, send dispatches handle and the reply arrives" {
  # Expected, written before running (the run below is the ONE regression
  # test for the whole ext-tool foundation, per the maintainer's one-test
  # policy): (i) joining before any config exists is refused and names
  # SETUP.md's location, without creating any registration; (ii) `ext-tool.sh
  # setup ... save` writes the member config; (iii) joining again then
  # succeeds; (iv) `send.sh` to the ext-tool member returns immediately
  # (the sender is never made to wait) and, once the backgrounded dispatch
  # runs, the fake handle's reply lands as an ordinary message back to the
  # original sender, quoting the body it was actually given.

  # A tool name that tries to escape drivers/ext-tools/ is refused before it
  # ever becomes a path (review finding).
  run bash "$SCRIPTS/join.sh" et-team bot ext-tool --tool "../faketool"
  [ "$status" -eq 1 ]

  run bash "$SCRIPTS/join.sh" et-team bot ext-tool --tool faketool
  [ "$status" -eq 1 ]
  grep -qF "SETUP.md" <<<"$output"
  grep -qF "not configured for 'bot'" <<<"$output"
  # Refused, not partially joined: no registration was written.
  [ ! -f "$TEST_SKILL_DIR/teams/et-team/config.json" ] || \
    refute grep -qF '"bot"' "$TEST_SKILL_DIR/teams/et-team/config.json"

  run bash "$SCRIPTS/ext-tool.sh" setup et-team bot faketool save
  [ "$status" -eq 0 ]
  local member_config="$TEST_SKILL_DIR/ext-tools/et-team/bot.conf"
  [ -f "$member_config" ]
  grep -qF 'tool=faketool' "$member_config"
  # 0600, and the secret path stays untouched by `save` (no secret asked for
  # by this fake tool).
  [ "$(stat -c '%a' "$member_config" 2>/dev/null || stat -f '%Lp' "$member_config")" = "600" ]

  run bash "$SCRIPTS/join.sh" et-team bot ext-tool --tool faketool
  [ "$status" -eq 0 ]
  grep -qF "Joined team et-team as bot" <<<"$output"

  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" et-team sender claude-code /tmp/et-team-proj
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/send.sh" et-team sender bot "ping-et-1284"
  [ "$status" -eq 0 ]
  grep -qF "Sent to bot in team et-team" <<<"$output"

  local i reply_seen=""
  for i in $(seq 1 $_WAIT_TICKS); do
    if bash "$SCRIPTS/history.sh" et-team sender 2>/dev/null | grep -qF "faketool reply: ping-et-1284"; then
      reply_seen=1
      break
    fi
    sleep $_WAIT_INTERVAL
  done
  [ -n "$reply_seen" ]

  # The reply is FROM bot, TO sender — a normal message, not a special channel.
  bash "$SCRIPTS/history.sh" et-team sender | grep -qF "bot → sender: faketool reply: ping-et-1284"

  # After a handle that already finished fast, dispatch must stay running
  # (waiting on the killer subshell) rather than exit right after sending
  # the reply -- an earlier version exited immediately, which let its own
  # EXIT trap delete DONE_FILE before the killer, still asleep, ever got to
  # check it; the killer would then always conclude handle had NOT finished
  # and fire a stale TERM/KILL a full timeout= later, on every single fast
  # call, not just some rare boundary case. Checked shortly after the reply
  # already landed, well before tool.conf's own timeout= elapses -- a fixed
  # dispatch is still there; a buggy, already-exited one is not.
  # Two processes share this exact command line while both are alive: the
  # main dispatch script (blocked in `wait "$HPID"`, then `wait
  # "$KILLER_PID"`) and the killer subshell itself (`ps` shows a subshell
  # under the same argv as its parent, since it never execs a new program).
  # Checking for "at least one" would pass even with the bug reintroduced --
  # the orphaned killer alone still matches. Only the count distinguishes
  # them: a dispatch that exited early leaves exactly one (the killer,
  # still asleep); the fix keeps both alive together until the killer
  # itself wakes and finds DONE_FILE.
  local dispatch_procs
  dispatch_procs="$(pgrep -f "ext-tool-dispatch\.sh et-team sender bot faketool" | wc -l | tr -d ' ')"
  [ "$dispatch_procs" -ge 2 ]

  # (v) A handle that never returns times out on tool.conf's own timeout=,
  # and the sender gets a named failure reply instead of waiting forever or
  # getting nothing. The dispatch script's own watchdog is pure bash and
  # must not depend on the `timeout` command at all. A fake `timeout` ahead
  # of the real one on PATH, that fails loudly (and leaves a mark) if ever
  # actually invoked, proves this directly -- stripping timeout's WHOLE
  # PATH directory (an earlier version did this) removed bash itself too on
  # Ubuntu, where /usr/bin holds both (review finding: "env: 'bash': No such
  # file or directory").
  local fake_bin="$BATS_TEST_TMPDIR/no-timeout-bin"
  mkdir -p "$fake_bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "touch '$fake_bin/timeout.invoked'"
    printf '%s\n' 'exit 1'
  } > "$fake_bin/timeout"
  chmod +x "$fake_bin/timeout"

  run bash "$SCRIPTS/ext-tool.sh" setup et-team slowbot slowtool save
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/join.sh" et-team slowbot ext-tool --tool slowtool
  [ "$status" -eq 0 ]

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/send.sh" et-team sender slowbot "ping-et-1284-slow"
  [ "$status" -eq 0 ]

  local j timeout_seen=""
  for j in $(seq 1 $_WAIT_TICKS); do
    if bash "$SCRIPTS/history.sh" et-team sender 2>/dev/null | grep -qF "slowbot → sender: slowbot: processing failed (timed out after 1s)"; then
      timeout_seen=1
      break
    fi
    sleep $_WAIT_INTERVAL
  done
  [ -n "$timeout_seen" ]

  # The timed-out handle's own grandchild (the sleep it backgrounded) must be
  # gone too, not just the handle shell itself (review finding: killing only
  # the immediate pid orphaned this kind of descendant).
  run cat "$SLOWTOOL_DIR/sleep.pid"
  [ "$status" -eq 0 ]
  refute kill -0 "$output" 2>/dev/null

  # Positive evidence, not just an inference from the test having passed:
  # the fake `timeout` was genuinely never invoked.
  [ ! -f "$fake_bin/timeout.invoked" ]
}
