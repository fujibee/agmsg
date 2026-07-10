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
