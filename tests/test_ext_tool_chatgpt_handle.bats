#!/usr/bin/env bats

# scripts/drivers/ext-tools/chatgpt — against a fake `orca` on PATH driven by
# a scenario dir (tests/helpers/mock_orca.sh); never a real browser.

load test_helper

setup() {
  setup_test_env
  DRIVER="$SCRIPTS/drivers/ext-tools/chatgpt"

  # Fake orca on PATH, with its scenario dir.
  mkdir -p "$TEST_SKILL_DIR/bin"
  cp "$BATS_TEST_DIRNAME/helpers/mock_orca.sh" "$TEST_SKILL_DIR/bin/orca"
  chmod +x "$TEST_SKILL_DIR/bin/orca"
  export PATH="$TEST_SKILL_DIR/bin:$PATH"
  export FAKE_ORCA_DIR="$TEST_SKILL_DIR/orca-scenario"
  mkdir -p "$FAKE_ORCA_DIR"

  CONFIG_PATH="$TEST_SKILL_DIR/ext-tools-chatgpt-member.conf"
  INPUT="$(jq -cn --arg cp "$CONFIG_PATH" '{
    team: "lab", from: "alice", to: "chatgpt",
    body: "summarise the ticket",
    message_id: "018f0000-0000-7000-8000-000000000003",
    config_path: $cp
  }')"
}

teardown() {
  teardown_test_env
}

# A config the member would carry after `setup save`. watch=no keeps the
# transcript watcher out of unit tests (it has its own lifecycle).
write_config() {  # <mode>
  {
    printf 'worktree=/fake/worktree\n'
    printf 'url_regex=chatgpt\\.com\n'
    printf 'mode=%s\n' "${1:-sync-wait}"
    printf 'watch=no\n'
  } > "$CONFIG_PATH"
  chmod 600 "$CONFIG_PATH"
}

# The canned page: one chatgpt tab; classify says an empty idle composer.
stage_idle_tab() {
  printf '%s\n' '{"tabs":[{"browserPageId":"pg1","url":"https://chatgpt.com/c/abc","title":"chat"}]}' \
    > "$FAKE_ORCA_DIR/tabs.json"
  printf '%s\n' '{"composer":true,"composerEmpty":true,"generating":false,"retry":false,"errorText":false,"url":"https://chatgpt.com/c/abc"}' \
    > "$FAKE_ORCA_DIR/eval.classify"
}

@test "chatgpt setup: save writes a 0600 config that status reports complete" {
  run bash "$DRIVER/setup" save "$CONFIG_PATH" /fake/worktree 'chatgpt\.com' inject-only
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '"ok":true'
  [ "$(stat -f %Lp "$CONFIG_PATH" 2>/dev/null || stat -c %a "$CONFIG_PATH")" = "600" ]

  run bash "$DRIVER/setup" status "$CONFIG_PATH"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '"missing":\[\]'
  printf '%s\n' "$output" | grep -q '"mode":"inject-only"'
}

@test "chatgpt setup: check tab finds a matching tab and reports its page" {
  stage_idle_tab
  run bash "$DRIVER/setup" check tab /fake/worktree 'chatgpt\.com'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '"ok":true'
  printf '%s\n' "$output" | grep -q '"page":"pg1"'
}

@test "chatgpt setup: check tab fails cleanly when nothing matches" {
  stage_idle_tab
  run bash "$DRIVER/setup" check tab /fake/worktree 'example\.com'
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q '"ok":false'
}

@test "chatgpt handle: inject-only enqueues the message and exits without touching orca" {
  write_config inject-only
  run bash "$DRIVER/handle" <<<"$INPUT"
  [ "$status" -eq 0 ]
  [ -n "$(find "$CONFIG_PATH.queue.d" -name 'agm-*.json' 2>/dev/null)" ]
  # No orca call at all: argv.log absent means the mock never ran.
  [ ! -f "$FAKE_ORCA_DIR/argv.log" ]
}

@test "chatgpt handle: sync-wait injects, confirms, and returns the reply" {
  write_config sync-wait
  stage_idle_tab
  printf '%s\n' '{"ok":true}'  > "$FAKE_ORCA_DIR/eval.inject"
  printf '%s\n' '{"ready":true}' > "$FAKE_ORCA_DIR/eval.ready"
  printf '%s\n' '{"ok":true}'  > "$FAKE_ORCA_DIR/eval.click"
  printf '%s\n' '{"confirmed":true}' > "$FAKE_ORCA_DIR/eval.confirmed"
  printf '%s\n' '{"found":true,"reply":"the ticket is about retries","generating":false}' \
    > "$FAKE_ORCA_DIR/eval.reply"

  run bash "$DRIVER/handle" <<<"$INPUT"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'the ticket is about retries'
}

@test "chatgpt handle: reports one failure line when no tab matches" {
  write_config sync-wait
  printf '%s\n' '{"tabs":[]}' > "$FAKE_ORCA_DIR/tabs.json"

  run bash "$DRIVER/handle" <<<"$INPUT"
  [ "$status" -ne 0 ]
  case "$output" in
    *"no tab matching"*) : ;;
    *) echo "unexpected output: $output" >&2; return 1 ;;
  esac
}

@test "chatgpt handle: never overwrites a composer's unfinished draft" {
  write_config sync-wait
  stage_idle_tab
  printf '%s\n' '{"composer":true,"composerEmpty":false,"generating":false,"retry":false,"errorText":false,"url":"https://chatgpt.com/c/abc"}' \
    > "$FAKE_ORCA_DIR/eval.classify"
  # Shrink the driver's internal deadline so the busy-composer wait ends
  # quickly instead of running the real 300s budget.
  printf 'name=chatgpt\ntimeout=40\nrequired_config=worktree\n' > "$DRIVER/tool.conf"

  run bash "$DRIVER/handle" <<<"$INPUT"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'timed out before reaching an idle composer'
  # And nothing was ever injected.
  ! grep -q 'insertText' "$FAKE_ORCA_DIR/argv.log" 2>/dev/null
}
