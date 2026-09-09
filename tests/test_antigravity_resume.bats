#!/usr/bin/env bats

setup() {
  export ROOT="$(mktemp -d)"
  mkdir -p "$ROOT/scripts/drivers/types/antigravity"
  cp "$BATS_TEST_DIRNAME/../scripts/antigravity-resume.sh" "$ROOT/scripts/"
  cat > "$ROOT/scripts/identities.sh" <<'EOF'
#!/usr/bin/env bash
printf 'demo\talpha\n'
printf 'demo\tbeta\n'
EOF
  cat > "$ROOT/scripts/drivers/types/antigravity/antigravity-tui-monitor.sh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = status ]; then
  case "$*" in
    *'--name alpha'*) echo 'runtime: alpha tui-pty paused' ;;
    *) echo 'runtime: beta tui-pty running' ;;
  esac
  exit 0
fi
printf '%s\n' "$*"
EOF
  chmod +x "$ROOT/scripts/"*.sh "$ROOT/scripts/drivers/types/antigravity/"*.sh
}

teardown() {
  rm -rf "$ROOT"
}

@test "resume: paused なTUIが一件なら既存resumeへidentityを渡す" {
  run bash "$ROOT/scripts/antigravity-resume.sh" /tmp/project
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume --project /tmp/project --team demo --name alpha"* ]]
}

@test "resume: paused なTUIが複数ならfail-closed" {
  # `sed -i` with no suffix is GNU-only; BSD sed (macOS) takes the next word as
  # a backup extension. Write to a temp file and copy back instead. (#1073)
  _mon="$ROOT/scripts/drivers/types/antigravity/antigravity-tui-monitor.sh"
  sed "s/runtime: beta tui-pty running/runtime: beta tui-pty paused/" "$_mon" > "$_mon.portable"
  cat "$_mon.portable" > "$_mon"
  run bash "$ROOT/scripts/antigravity-resume.sh" /tmp/project
  [ "$status" -eq 1 ]
  [[ "$output" == *"paused な Antigravity TUI が複数"* ]]
}

@test "resume: paused なTUIがなければfail-closed" {
  _mon="$ROOT/scripts/drivers/types/antigravity/antigravity-tui-monitor.sh"
  sed "s/runtime: alpha tui-pty paused/runtime: alpha tui-pty running/" "$_mon" > "$_mon.portable"
  cat "$_mon.portable" > "$_mon"
  run bash "$ROOT/scripts/antigravity-resume.sh" /tmp/project
  [ "$status" -eq 1 ]
  [[ "$output" == *"paused な Antigravity TUI が見つかりません"* ]]
}
