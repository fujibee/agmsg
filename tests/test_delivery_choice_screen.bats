#!/usr/bin/env bats
# The delivery choice screen offers agmsgd first, names the old monitor
# "monitor (legacy)", asks `agmsg daemon offer` before showing agmsgd, and
# keeps the mode values as they were.

refute() {
  if "$@"; then return 1; fi
  return 0
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  for type in claude-code codex; do
    bash -c 'source "$1/scripts/lib/type-registry.sh"; source "$1/scripts/lib/skill-render.sh"; SCRIPT_DIR="$1" agmsg_render_skill "$2" agmsg "$3"' _ "$ROOT" "$type" "$BATS_TEST_TMPDIR/$type.md"
  done
}

_step5() {   # <file>: the delivery step of the join flow
  sed -n '/^  5\. \*\*REQUIRED/,/^  6\. /p' "$1"
}

@test "choice screen: agmsgd comes first, monitor (legacy) second, for Claude Code and Codex" {
  for file in "$BATS_TEST_TMPDIR/claude-code.md" "$BATS_TEST_TMPDIR/codex.md" "$ROOT/SKILL.md"; do
    screen="$(_step5 "$file")"
    grep -Fq 'agmsg daemon offer' <<<"$screen"
    first="$(grep -n 'agmsgd` — notices delivered directly by a background service (recommended)' <<<"$screen" | head -1 | cut -d: -f1)"
    second="$(grep -n '`monitor (legacy)` —' <<<"$screen" | head -1 | cut -d: -f1)"
    [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]
    grep -Fq 'agmsg daemon disable' <<<"$screen"
  done
}

@test "choice screen: every offer answer is handled (on, not-running, unavailable with a reason)" {
  for file in "$BATS_TEST_TMPDIR/claude-code.md" "$BATS_TEST_TMPDIR/codex.md"; do
    screen="$(_step5 "$file")"
    grep -Fq 'agmsgd=on' <<<"$screen"
    grep -Fq 'agmsgd is on: notices are delivered directly' <<<"$screen"
    grep -Fq 'agmsgd=unavailable' <<<"$screen"
    grep -Fq 'agmsgd=not-running' <<<"$screen"
    grep -Fq 'do not say notices are delivered directly' <<<"$screen"
  done
}

@test "choice screen: the choice is applied through agmsg delivery; agmsgd enables the service and has no Monitor fallback" {
  for file in "$BATS_TEST_TMPDIR/claude-code.md" "$BATS_TEST_TMPDIR/codex.md" "$ROOT/SKILL.md"; do
    screen="$(_step5 "$file")"
    grep -Fq 'agmsg delivery <choice>' <<<"$screen"
    grep -Fq 'daemon enable' <<<"$screen"
    grep -Fq 'no Monitor fallback' <<<"$screen"
    grep -Fq 'agmsg daemon disable' <<<"$screen"
  done
}

@test "delivery command: delivery is the name, mode stays an alias, mode values keep their names" {
  for file in "$BATS_TEST_TMPDIR/claude-code.md" "$BATS_TEST_TMPDIR/codex.md" "$ROOT/SKILL.md"; do
    grep -Fq 'If argument is "delivery" (or its alias "mode")' "$file"
    grep -Fq 'agmsg delivery status' "$file"
    grep -Fq '"this project: agmsgd"' "$file"
  done
  grep -Fq 'delivery agmsgd|monitor|turn|both|off' "$BATS_TEST_TMPDIR/claude-code.md"
  grep -Fq 'delivery agmsgd|monitor|turn|off' "$BATS_TEST_TMPDIR/codex.md"
  grep -Fq 'exactly `delivery.sh set <value>`' "$BATS_TEST_TMPDIR/claude-code.md"
}

@test "choice screen: other types are unchanged (no agmsgd offer)" {
  for type in gemini copilot cursor; do
    bash -c 'source "$1/scripts/lib/type-registry.sh"; source "$1/scripts/lib/skill-render.sh"; SCRIPT_DIR="$1" agmsg_render_skill "$2" agmsg "$3"' _ "$ROOT" "$type" "$BATS_TEST_TMPDIR/$type.md"
    refute grep -Fq 'agmsg daemon offer' "$BATS_TEST_TMPDIR/$type.md"
  done
}

@test "README: the delivery modes section names agmsgd and monitor (legacy), in both languages" {
  for readme in README.md README.ja.md; do
    case "$readme" in README.md) heading='^## Delivery modes' ;; *) heading='^## 配信モード' ;; esac
    section="$(sed -n "/$heading/,/^## [^D配]/p" "$ROOT/$readme")"
    grep -Fq 'monitor (legacy)' <<<"$section"
    grep -Fq 'agmsg daemon disable' <<<"$section"
    grep -Fq '/agmsg delivery agmsgd' <<<"$section"
  done
}

@test "delivery setup: existing seats never prompt and an active daemon is reused without a choice" {
  for file in "$BATS_TEST_TMPDIR/claude-code.md" "$BATS_TEST_TMPDIR/codex.md" "$ROOT/SKILL.md"; do
    screen="$(_step5 "$file")"
    grep -Fq 'Ask about delivery only on a human-initiated first join' <<<"$screen"
    grep -Fq 'Never ask on `actas`, `spawn`, or rejoin of an existing seat' <<<"$screen"
    grep -Fq 'even if `join.sh` must restore its registration' <<<"$screen"
    on="$(grep -F '`agmsgd=on`:' <<<"$screen")"
    grep -Fq 'ask nothing. Run' <<<"$on"
    grep -Fq 'agmsg delivery agmsgd --type' <<<"$on"
    grep -Fq 'Only if it succeeds' <<<"$on"
    grep -Fq 'On failure, report the failure' <<<"$on"
    grep -Fq 'and continue without asking or running' <<<"$screen"
    grep -Fq 'explicitly chosen delivery mode; agmsgd does not deliver here' <<<"$screen"
    grep -Fq 'chosen — agmsgd does not deliver here' <<<"$screen"
    refute grep -Fq 'keep using it or switch' <<<"$screen"
    refute grep -Fq 'Show this screen every time' <<<"$screen"
    grep -Fq 'preserve the configured delivery and continue without asking or changing it' <<<"$screen"
    for offer in available not-running unavailable; do
      line="$(grep -F "agmsgd=$offer" <<<"$screen" | head -1)"
      grep -Fq 'only on a human-initiated first join' <<<"$line"
    done
  done
}
