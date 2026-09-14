#!/usr/bin/env bash
# 設定はagmsg専用rulefileのマーカー。monitor設定だけではagyを起動しない。
agmsg_delivery_apply() {
  local type="$1" project="$2" mode="$3"
  # Refuse before any write: an empty SKILL_DIR would render broken guidance
  # paths ("/scripts/where.sh" etc.) into the rule file, and rulefile_apply
  # (below, and this function's own turn-mode migration check) removes the
  # existing rule file before it writes -- an unreadable value must never be
  # treated as "nothing to preserve" (#1234 review).
  [ -n "${SKILL_DIR:-}" ] || { echo "agmsg_delivery_apply (antigravity): SKILL_DIR is not set; refusing rather than writing a broken rule file" >&2; return 1; }
  if [ "$mode" != monitor ]; then
    node "$SKILL_DIR/scripts/drivers/types/antigravity/antigravity-mode.mjs" stop "$project" || return 1
    rulefile_apply "$@"
    return
  fi
  local file; file="$(resolve_hooks_file "$type" "$project")"
  mkdir -p "$(dirname "$file")"
  # 既存の独自ルールは自動上書きしない。既に同じマーカーなら冪等に終了する。
  if [ -f "$file" ] && grep -q '^<!-- agmsg:antigravity:monitor -->$' "$file"; then
    return 0
  fi
  if [ -f "$file" ] && [ -s "$file" ]; then
    # turn が生成した既知の内容だけを monitor marker へ移行する。
    # 独自 rulefile は内容を失わないよう従来どおり拒否する。
    local expected actual
    expected="$(cat <<EOF
# agmsg Integration Rule

## PostToolUse
After each tool call, automatically check the agmsg inbox for unread messages.
- Command: '$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'

## Terminal/pane self-awareness
Asked about your own terminal, pane, or driver — or before using arrange/peek/poke
— run '$SKILL_DIR/scripts/where.sh' first and answer from its terminal=/capabilities=
fields. Never guess from environment variables or a grep/ps command; a driver
that IS present can be wrongly reported absent that way. Per-driver detail:
'$SKILL_DIR/scripts/drivers/terminals/<terminal>/SKILL.md' (terminal= names which).

## Teammates: placement, status, and reaching them
Placement and status for a teammate: '$SKILL_DIR/scripts/team.sh' <team> — never a
stale memory of their last known pane. Act on one with '$SKILL_DIR/scripts/peek.sh'
/ 'poke.sh' / 'arrange.sh' <team> <name> directly, not a guess: its exit code
says whether it worked and, if not, why.
EOF
)"
    actual="$(cat "$file")"
    if [ "$actual" != "$expected" ]; then
      echo '既存rulefileはagmsg形式ではありません' >&2; return 1
    fi
  fi
  {
    printf '%s\n' '<!-- agmsg:antigravity:monitor -->'
    printf '%s\n' '# agmsg Integration Rule'
    printf '%s\n' '受領はAntigravity bridgeが管理します。inbox.sh/check-inbox.shを呼ばないでください。'
  } > "$file"
}
agmsg_delivery_status() {
  local file; file="$(resolve_hooks_file "$1" "$2")"
  if [ -f "$file" ] && grep -q '^<!-- agmsg:antigravity:monitor -->$' "$file"; then echo 'mode: monitor'; else rulefile_status "$@"; fi
}
agmsg_delivery_on_enable() {
  printf 'headless明示起動: bash %q --project %q --team <team> --name <role>\n' "$SKILL_DIR/scripts/drivers/types/antigravity/antigravity-monitor.sh" "$3"
  printf 'TUI明示起動: bash %q --project %q --team <team> --name <role>\n' "$SKILL_DIR/scripts/drivers/types/antigravity/antigravity-tui-monitor.sh" "$3"
}
agmsg_delivery_runtime_status() {
  node "$SKILL_DIR/scripts/drivers/types/antigravity/antigravity-mode.mjs" status "$2"
}
agmsg_delivery_on_disable() { :; }
