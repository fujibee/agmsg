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

@test "SKILL.md points at capabilities and the per-driver file (#1082)" {
  grep -qF 'capabilities=<list>' "$ROOT/SKILL.md"
  grep -qF 'scripts/drivers/terminals/<terminal>/SKILL.md' "$ROOT/SKILL.md"
  # The byte-count claim in #1082's own PR (measured against its own parent
  # commit at the time: 26829 -> 26400) is a one-time migration fact, not
  # something to pin here as a literal -- SKILL.md legitimately grows for
  # unrelated reasons afterward (a later PR proved that: this exact assertion
  # broke on rebase when #1194 added the no-name peek summary form). What
  # stays true regardless of the file's size is that the per-verb detail this
  # issue moved out does not come back in prose form -- pinned above and in
  # the herdr-specific-detail test.
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

# Review (#1209) found that the first version of these per-driver docs claimed 13
# for herdr's and tmux's own peek/poke -- a code neither driver's own
# terminal_peek/terminal_poke ever returns (a target that never existed is
# refused by the caller's ref parser before any driver loads; 13 belongs to
# plain, whose peek/poke genuinely can be unsupported at the instance level).
# A doc that restates the driver-crossing classification error #1082 exists
# to remove is worse than the doc it replaced. The two tests below are the
# fix for HOW that slipped past review the first time: the earlier version of
# this file only checked that a heading and a verb name were present, never
# that the rc numbers under it were real. These read the actual `return N`
# statements out of each driver's own function body and require the doc's
# claimed set to match exactly -- neither a code the function cannot return,
# nor a missing one it does.

# Every distinct `return N` inside <fn>()'s own body in <ops.sh>, N != 0.
_returns_in_function() {   # <ops.sh path> <function name>
  awk -v fn="$2" '
    $0 ~ "^" fn "\\(\\) \\{" { infn=1; next }
    infn && /^}/ { infn=0 }
    infn {
      line=$0
      while (match(line, /return [0-9]+/)) {
        n = substr(line, RSTART+7, RLENGTH-7)
        if (n != "0") print n
        line = substr(line, RSTART+RLENGTH)
      }
    }
  ' "$1" | sort -un
}

# Every `**N**` bolded number under a "## <heading>" section in <doc>, up to
# the next "## " heading or EOF.
_rcs_in_doc_section() {   # <doc path> <heading text>
  awk -v h="$2" '
    $0 ~ "^## " h { insec=1; next }
    insec && /^## / { insec=0 }
    insec {
      line=$0
      while (match(line, /\*\*[0-9]+\*\*/)) {
        print substr(line, RSTART+2, RLENGTH-4)
        line = substr(line, RSTART+RLENGTH)
      }
    }
  ' "$1" | sort -un
}

@test "each driver's own peek/poke exit codes are exactly what terminal_peek/terminal_poke return, no more and no less (#1209 review)" {
  local driver ops doc fn heading actual claimed
  for driver in herdr tmux plain; do
    ops="$ROOT/scripts/drivers/terminals/$driver/ops.sh"
    doc="$ROOT/scripts/drivers/terminals/$driver/SKILL.md"
    [ -s "$ops" ]; [ -s "$doc" ]
    for fn in terminal_peek terminal_poke; do
      case "$fn" in terminal_peek) heading="peek exit codes" ;; *) heading="poke exit codes" ;; esac
      actual="$(_returns_in_function "$ops" "$fn")"
      claimed="$(_rcs_in_doc_section "$doc" "$heading")"
      [ "$actual" = "$claimed" ] \
        || { echo "$driver/$fn: implementation returns [$(paste -sd, - <<<"$actual")], doc claims [$(paste -sd, - <<<"$claimed")]" >&2; return 1; }
    done
  done
}
