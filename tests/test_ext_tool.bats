#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  FAKETOOL_DIR="$SCRIPTS/drivers/ext-tools/faketool"
  mkdir -p "$FAKETOOL_DIR"

  printf '%s\n' \
    'name=faketool' \
    'timeout=10' \
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
  [ "$(stat -f '%Lp' "$member_config" 2>/dev/null || stat -c '%a' "$member_config")" = "600" ]

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
}
