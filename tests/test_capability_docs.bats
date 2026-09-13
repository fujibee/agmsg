#!/usr/bin/env bats

# #1082: the terminal driver declares its capabilities (terminal.conf); the
# agent-facing text should reflect that, not restate it by hand where it can
# drift. This file pins three things: SKILL.md no longer carries the
# per-driver exit-code detail it used to (that moved out and got shorter,
# not just longer-in-a-new-place), each shipped driver has its own doc file
# that matches what its manifest actually declares, and plain's — the one
# driver missing several verbs — says so rather than describing verbs it does
# not have.

load test_helper

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "SKILL.md no longer carries the herdr-specific peek/poke detail it used to (#1082)" {
  # Measured before this fix: this exact sentence, presented as if every
  # driver worked this way, when only herdr does.
  run grep -qF 'not every driver distinguishes this from 12 yet' "$ROOT/SKILL.md"
  [ "$status" -ne 0 ]
  # It still exists -- correctly scoped to the one driver it is true of.
  grep -qF 'the one' "$ROOT/scripts/drivers/terminals/herdr/SKILL.md"
  grep -qF 'distinguishes 11 from 12' "$ROOT/scripts/drivers/terminals/herdr/SKILL.md"
}

@test "SKILL.md points at capabilities and the per-driver file, and is measurably shorter (#1082)" {
  grep -qF 'capabilities=<list>' "$ROOT/SKILL.md"
  grep -qF 'scripts/drivers/terminals/<terminal>/SKILL.md' "$ROOT/SKILL.md"
  # Measured baseline immediately before this issue's changes: 25276 bytes.
  local size
  size="$(wc -c < "$ROOT/SKILL.md" | tr -d ' ')"
  [ "$size" -lt 25276 ]
}

@test "every shipped terminal driver has its own SKILL.md, and it lists verbs from ITS OWN manifest only (#1082)" {
  local name conf capabilities word
  for conf in "$ROOT"/scripts/drivers/terminals/*/terminal.conf; do
    name="$(basename "$(dirname "$conf")")"
    [ -s "$(dirname "$conf")/SKILL.md" ]
    capabilities="$(grep '^capabilities=' "$conf" | cut -d= -f2-)"
    # A verb NOT in this driver's own ceiling must not appear as a documented
    # heading in its doc (case-sensitive "## <verb>" headings only, so the verb
    # appearing in prose elsewhere is not what this pins).
    for word in where arrange name; do
      if ! grep -qw "$word" <<<"$capabilities"; then
        refute grep -qi "^## $word" "$(dirname "$conf")/SKILL.md"
      fi
    done
  done
}

@test "plain's own doc names peek/poke as CONDITIONAL, and says where/arrange/name are absent, not merely undocumented (#1082)" {
  local doc="$ROOT/scripts/drivers/terminals/plain/SKILL.md"
  [ -s "$doc" ]
  grep -qF 'NOT in that' "$doc"
  grep -qi 'emulator' "$doc"
  refute grep -qi '^## where' "$doc"
  refute grep -qi '^## arrange' "$doc"
}

@test "where.sh's capabilities output for each built-in driver matches its terminal.conf exactly (#1082)" {
  run env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u AGMSG_TERMINAL_DRIVER \
    bash "$ROOT/scripts/where.sh"
  [ "$status" -eq 0 ]
  local plain_caps
  plain_caps="$(grep '^capabilities=' "$ROOT/scripts/drivers/terminals/plain/terminal.conf" | cut -d= -f2-)"
  grep -qF "capabilities=$plain_caps" <<<"$output"

  run env -u TMUX -u TMUX_PANE -u AGMSG_TERMINAL_DRIVER \
    env HERDR_ENV=1 HERDR_PANE_ID=w1:p4 bash "$ROOT/scripts/where.sh"
  [ "$status" -eq 0 ]
  local herdr_caps
  herdr_caps="$(grep '^capabilities=' "$ROOT/scripts/drivers/terminals/herdr/terminal.conf" | cut -d= -f2-)"
  grep -qF "capabilities=$herdr_caps" <<<"$output"
}
