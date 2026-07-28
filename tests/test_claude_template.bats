#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATE="$ROOT/scripts/drivers/types/claude-code/template.md"
}

@test "Claude template distinguishes sandbox enablement from the write allowlist" {
  grep -Fq 'The allowlist does not enable sandboxing by itself.' "$TEMPLATE"
  grep -Fq '"enabled": true' "$TEMPLATE"
  grep -Fq '`/sandbox`' "$TEMPLATE"
}

@test "Claude template forbids bypassing the scripts with direct SQLite access" {
  grep -Fq 'never construct a database path or invoke `sqlite3` directly' "$TEMPLATE"
}

@test "Claude template aborts actas on structured claim errors without touching Monitor" {
  grep -Fq 'status=error team=<team> reason=<reason> [rollback=incomplete locked=<pairs>]' "$TEMPLATE"
  grep -Fq 'do NOT TaskStop, relaunch, or otherwise touch the running Monitor' "$TEMPLATE"
  grep -Fq 'report the exact `locked=` pairs that remain held' "$TEMPLATE"
}

@test "Claude template handles incomplete held rollback before peer cleanup" {
  grep -Fq 'status=held team=<team> owner=<sid> [rollback=incomplete locked=<pairs>]' "$TEMPLATE"
  grep -Fq 'Always abort — do NOT TaskStop, relaunch, or otherwise touch the running Monitor' "$TEMPLATE"
  grep -Fq 'dropping the peer role alone is insufficient' "$TEMPLATE"
  grep -Fq 'retry `actas` or run normal session cleanup so checked release can finish' "$TEMPLATE"
}

@test "Claude template gives safe legacy and generic claim recovery guidance" {
  grep -Fq 'stop and restart every process that could still run the old agmsg mutator' "$TEMPLATE"
  grep -Fq 'never age-delete a marker' "$TEMPLATE"
  grep -Fq 'retry only after the reported filesystem/SQLite infrastructure problem has recovered' "$TEMPLATE"
}

@test "Claude template requires quiescence for reclaim protocol transitions" {
  grep -Fq 'Do not operate old and new reclaim mutators together.' "$TEMPLATE"
  grep -Fq 'Before the first new-protocol mutation' "$TEMPLATE"
  grep -Fq 'Before rolling back code, quiesce every new-protocol helper and process' "$TEMPLATE"
  grep -Fq 'Marker detection is diagnostic and fail-closed, not proof that the system is quiescent.' "$TEMPLATE"
}
