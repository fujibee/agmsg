#!/usr/bin/env bats
# Exercise the update's closing output and its printed commands without an
# installer, HOME substitution, or access to a real service manager.
setup() {
  SKILL="$BATS_TEST_TMPDIR/install with spaces"
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$SKILL" "$PROJECT"
  cp -R "$BATS_TEST_DIRNAME/../scripts" "$SKILL/scripts"
  export CODEX_HOME="$BATS_TEST_TMPDIR/codex-profile"
  export AGMSG_CONFIG="$BATS_TEST_TMPDIR/config.json"
  export AGMSG_STORAGE_PATH="$SKILL/db"
  export AGMSG_SELF_NAME=off
  unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH TMUX TMUX_PANE
  sed -n '/^agmsg_install_update_delivery_hint() {/,/^}/p' "$BATS_TEST_DIRNAME/../install.sh" > "$BATS_TEST_TMPDIR/hint.sh"
  source "$BATS_TEST_TMPDIR/hint.sh"
  # Only service control is stubbed. Delivery parsing and settings are real.
  cat > "$SKILL/scripts/daemon.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  offer) printf 'agmsgd=on\n' ;;
  status) printf 'daemon status fixture: ready\n' ;;
  *) exit 99 ;;
esac
SH
}

@test "update: closing recommendation supplies executable status/switch commands for this install" {
  local type notice check switch verify
  for type in claude-code codex; do
    notice="$(agmsg_install_update_delivery_hint "$SKILL" "$type")"
    [[ "$notice" == *'New in 1.6: agmsgd is the recommended'* ]]
    [[ "$notice" == *'suggest switching to agmsgd to the user'* ]]
    [[ "$notice" == *'actas <existing-agent-name>, or restarts'* ]]
    [[ "$notice" == *'Monitor fallback; stored unread messages are preserved'* ]]
    [[ "$notice" != *'AGMSG-DIRECTIVE'* ]]
    check="$(sed -n 's/^    Check this project: //p' <<< "$notice")"
    switch="$(sed -n 's/^      bash /bash /p' <<< "$notice")"
    verify="$(sed -n 's/^    Check agmsgd afterwards: //p' <<< "$notice")"
    [[ "$check" == *"--type $type"* ]]
    [[ "$check" == *'--project "$(pwd)"'* ]]
    [[ "$switch" == *'delivery agmsgd'* ]]
    run bash -c 'cd "$1"; bash -c "$2"' _ "$PROJECT" "$check"
    [ "$status" -eq 0 ]
    run bash -c 'cd "$1"; bash -c "$2"' _ "$PROJECT" "$switch"
    [ "$status" -eq 0 ]
    [[ "$output" == *'until it restarts or runs actas'* ]]
    if [ "$type" = claude-code ]; then
      [[ "$output" == *'invoke the Monitor tool now'* ]]
    fi
    run bash -c 'cd "$1"; bash -c "$2"' _ "$PROJECT" "$verify"
    [ "$status" -eq 0 ]
    [[ "$output" == *'daemon status fixture: ready'* ]]
  done
}

@test "update: the final output calls the recommendation after Update complete" {
  local tail="$BATS_TEST_TMPDIR/update-tail.sh"
  # Execute the actual closing segment, not a second copy of the print text.
  sed -n '/^  echo "  ✓ Update complete"/,/^  exit 0/p' "$BATS_TEST_DIRNAME/../install.sh" > "$tail"
  export SKILL_DIR="$SKILL"
  export CLAUDE_CODE_SESSION_ID=fixture-session
  export -f agmsg_install_update_delivery_hint
  run bash "$tail"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Update complete'*'agmsgd is the recommended'* ]]
  [[ "$output" == *'delivery status --type claude-code'* ]]
  [[ "$output" == *'delivery agmsgd --type claude-code'* ]]
}
