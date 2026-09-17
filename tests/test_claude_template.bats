#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATE="$ROOT/scripts/drivers/types/claude-code/template.md"
  RENDERED="$BATS_TEST_TMPDIR/claude-SKILL.md"
  bash -c 'source "$1/scripts/lib/type-registry.sh"; source "$1/scripts/lib/skill-render.sh"; SCRIPT_DIR="$1" agmsg_render_skill claude-code agmsg "$2"' _ "$ROOT" "$RENDERED"
}

@test "Claude rendered skill distinguishes sandbox enablement from the write allowlist" {
  grep -Fq 'The allowlist does not enable sandboxing by itself.' "$RENDERED"
  grep -Fq '"enabled": true' "$RENDERED"
  grep -Fq '`/sandbox`' "$RENDERED"
}

@test "Claude rendered skill forbids bypassing the scripts with direct SQLite access" {
  grep -Fq 'never construct a database path or invoke `sqlite3` directly' "$RENDERED"
}

@test "Claude rendered skill tells actas and drop not to treat any off wording as silently deliberate except turn (#687 review round 3)" {
  # #684 recovery: a seat read the bare word "off" and reported no delivery
  # as a deliberate configuration, when delivery.sh actually could not find
  # the project. Round 3 went one layer deeper: even a settings file that
  # genuinely has zero agmsg entries can't be asserted deliberate either --
  # `set off` writes no marker distinguishing it from "never configured" --
  # so only `turn` (has_st=1 is positive evidence) may stay silent now. Both
  # off-shaped wordings appear once for actas and once for drop.
  count_unrecognized=$(grep -c 'mode: off (unrecognized: \.\.\.)' "$RENDERED")
  [ "$count_unrecognized" -eq 2 ] \
    || { echo "expected 2 occurrences of the unrecognized wording (actas + drop), found $count_unrecognized" >&2; return 1; }
  count_nohooks=$(grep -c 'mode: off (no agmsg delivery hooks installed for this project)' "$RENDERED")
  [ "$count_nohooks" -eq 2 ] \
    || { echo "expected 2 occurrences of the no-hooks wording (actas + drop), found $count_nohooks" >&2; return 1; }
  # delivery.sh never emits a bare, unannotated "mode: off" anymore -- the
  # template must not describe that exact string as the silent/deliberate
  # case, or a future edit could quietly resurrect the #684 failure.
  run grep -q 'exactly `mode: off`' "$RENDERED"
  [ "$status" -ne 0 ]
  grep -Fq 'Do not report `actas` as complete without saying this' "$RENDERED"
  grep -Fq 'Do not report the drop as complete without mentioning it' "$RENDERED"
}

@test "Claude rendered skill's actas/drop tell the agent to invoke the Monitor tool, not just 'start watch.sh' (#1083 regression)" {
  # #1083's compose-from-root-and-overlay refactor accidentally replaced the
  # detailed actas/drop steps with a short summary that never named the
  # Monitor tool at all -- an agent reading only the rendered skill had no
  # way to know watch.sh must be started THROUGH Monitor rather than, say,
  # Bash. These assertions pin the specific facts that summary dropped.
  grep -Fq 'invoke a fresh Monitor' "$RENDERED"
  grep -Fq 'command: `~/.agents/skills/agmsg/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" claude-code <name>`' "$RENDERED"
  grep -Fq 'description: `agmsg inbox stream (acting as <name>)`' "$RENDERED"
  grep -Fq 'persistent: true' "$RENDERED"
  grep -Fq 'Run TaskList. Find any task whose description begins with "agmsg inbox stream"' "$RENDERED"
  grep -Fq 'status=held team=<team> owner=<sid>' "$RENDERED"
  # drop's own re-subscribe must be equally explicit, not just actas's.
  grep -Fq 'command: `~/.agents/skills/agmsg/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" claude-code`' "$RENDERED"
}

@test "Claude rendered skill's actas ends by confirming the Monitor attached via TaskList, not the UI footer" {
  grep -Fq 'Confirm the Monitor actually attached' "$RENDERED"
  grep -Fq 'run TaskList once more and confirm a task whose description begins with `agmsg inbox stream` is present' "$RENDERED"
  grep -Fq 'Do NOT read this off the terminal UI' "$RENDERED"
}

@test "no rendered skill of any type still carries the unwired 'supplied by the type overlay' placeholder text" {
  # These two lines in the shared root SKILL.md looked like slot markers but
  # were plain comments the renderer's <!-- agmsg:slot NAME --> matcher never
  # recognized, so they passed straight through into every type's output
  # instead of being replaced by that type's real actas/drop content.
  run grep -Fq 'supplied by the type overlay' "$RENDERED"
  [ "$status" -ne 0 ]
}

@test "Claude rendered skill names no terminal driver, so an agent has no name to reach for (#1171)" {
  # Measured on the pre-fix branch: tmux 4, herdr 0. The fix is not balancing
  # that count -- it is dropping terminal names from agent-facing text
  # entirely, so the choice this incident hinged on ("which terminal's
  # syntax do I know") never comes up. Case-insensitive: a capitalized
  # mention would steer just as much as a lowercase one.
  run grep -ic 'tmux\|herdr' "$RENDERED"
  [ "$status" -ne 0 ] || [ "$output" -eq 0 ]
  grep -Fq 'If argument is "where"' "$RENDERED"
  grep -Fq 'this call already asked every driver' "$RENDERED"
}
