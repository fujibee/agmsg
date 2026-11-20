#!/usr/bin/env bats
#
# team.sh on a roster of many members: the listing is fixed by a golden file taken
# from the code BEFORE the spawn work, and the number of process starts that do not
# depend on the member is pinned. Both halves matter: a fast listing that says
# something else is a different listing, and a listing that says the same thing but
# asks herdr once per member again is the slowness this was written to remove.

load test_helper

SEATS=12

setup() {
  setup_test_env
  export TEAM_FIX_LOG="$BATS_TEST_TMPDIR/herdr.log"
  : > "$TEAM_FIX_LOG"
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/teams/bench" "$BATS_TEST_TMPDIR/fakebin"
  local i type
  {
    printf '{"agents":{'
    for i in $(seq 1 "$SEATS"); do
      [ "$i" -gt 1 ] && printf ','
      case $((i % 3)) in 0) type=codex ;; *) type=claude-code ;; esac
      printf '"s%s":{"registrations":[{"type":"%s","project":"/tmp/agmsg-roster-proj%s"}]}' "$i" "$type" $((i % 4))
    done
    # One member this machine never registered, one with no placement record.
    printf ',"remote1":{"registrations":[]},"norec":{"registrations":[{"type":"claude-code","project":"/tmp/agmsg-roster-proj0"}]}'
    printf '}}\n'
  } > "$TEST_SKILL_DIR/teams/bench/config.json"
  for i in $(seq 1 "$SEATS"); do
    printf 'herdr:w1:p%s\t/tmp/x\tclaude-code\n' "$i" > "$TEST_SKILL_DIR/run/spawn.bench__s$i"
  done
  # A fixed-answer herdr. Pane 3 is absent from the layout answer (the location read
  # fails for it); pane 5's label carries a single quote (the SQL escaping path);
  # pane 7 has no agent-list entry; pane 9 answers an agent with an empty name. The
  # agent list is multi-line, as a pretty-printed answer is.
  cat > "$BATS_TEST_TMPDIR/fakebin/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEAM_FIX_LOG"
case "$1 $2" in
  "pane layout")
    p="$4"
    [ "$p" = w1:p3 ] && { printf '{"result":{"layout":{"tab_id":"t1","panes":[{"pane_id":"w1:p99"}]}}}\n'; exit 0; }
    printf '{"result":{"layout":{"tab_id":"t%s","panes":[{"pane_id":"%s"}]}}}\n' "${p#w1:p}" "$p" ;;
  "pane get")
    p="$3"; n="${p#w1:p}"
    label="bench:s$n"; [ "$n" = 5 ] && label="it's:s5"
    printf '{"result":{"pane":{"agent_status":"idle","label":"%s","terminal_title":"✳ bench-s%s"}}}\n' "$label" "$n" ;;
  "agent list")
    printf '{\n  "result": {\n    "agents": [\n'
    i=1; first=1
    while [ "$i" -le 12 ]; do
      if [ "$i" != 7 ]; then
        name="k$i"; [ "$i" = 9 ] && name=""
        [ "$first" = 1 ] || printf ',\n'
        first=0
        printf '      {"pane_id": "w1:p%s", "name": "%s"}' "$i" "$name"
      fi
      i=$((i + 1))
    done
    printf '\n    ]\n  }\n}\n' ;;
  "pane read") printf 'Thread name: bench-s%s\n' "${3#w1:p}" ;;
  *) echo "fake herdr: unexpected: $*" >&2; exit 2 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/fakebin/herdr"
  export PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"
}

teardown() {
  teardown_test_env
}

golden() { printf '%s/fixtures/team-roster-herdr.%s.golden' "$BATS_TEST_DIRNAME" "$1"; }

# AGMSG_ROSTER_WRITE_GOLDEN=1 rewrites the golden files; the committed ones were
# taken from the code before the spawn work, so a diff here is a changed listing.
@test "team.sh: a roster lists exactly what it listed before the spawn work (human)" {
  run bash "$SCRIPTS/team.sh" bench
  [ "$status" -eq 0 ]
  if [ -n "${AGMSG_ROSTER_WRITE_GOLDEN:-}" ]; then printf '%s\n' "$output" > "$(golden human)"; return 0; fi
  [ "$output" = "$(cat "$(golden human)")" ]
}

@test "team.sh --json: the same roster lists exactly what it listed before (json)" {
  run bash "$SCRIPTS/team.sh" bench --json
  [ "$status" -eq 0 ]
  if [ -n "${AGMSG_ROSTER_WRITE_GOLDEN:-}" ]; then printf '%s\n' "$output" > "$(golden json)"; return 0; fi
  [ "$output" = "$(cat "$(golden json)")" ]
}

@test "team.sh: herdr's agent list is asked for once for the roster, not once per member" {
  run bash "$SCRIPTS/team.sh" bench
  [ "$status" -eq 0 ]
  [ "$(grep -c '^agent list' "$TEAM_FIX_LOG")" -eq 1 ]
  # What is per member stays per member: one layout and one pane read each.
  [ "$(grep -c '^pane layout' "$TEAM_FIX_LOG")" -eq "$SEATS" ]
  [ "$(grep -c '^pane get' "$TEAM_FIX_LOG")" -eq "$SEATS" ]
}

@test "team.sh: delivery status is read once per (type, project), not once per member" {
  # Count the starts with a delivery.sh that only counts and answers.
  cat > "$SCRIPTS/delivery.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$2" "$3" >> "$TEAM_FIX_LOG.delivery"
printf 'mode: monitor\n'
EOF
  chmod +x "$SCRIPTS/delivery.sh"
  run bash "$SCRIPTS/team.sh" bench
  [ "$status" -eq 0 ]
  # 12 seats over 2 types and 4 projects: fewer distinct pairs than seats, every
  # pair read exactly once.
  total="$(wc -l < "$TEAM_FIX_LOG.delivery" | tr -d ' ')"
  distinct="$(sort -u "$TEAM_FIX_LOG.delivery" | wc -l | tr -d ' ')"
  [ "$total" -eq "$distinct" ]
  [ "$total" -lt "$SEATS" ]
}

@test "tmux: the pane listing is asked for once after a prefetch, and answers as before without one" {
  cat > "$BATS_TEST_TMPDIR/fakebin/tmux" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "$TEAM_FIX_LOG.tmux"
case "$*" in
  *list-panes*) printf '%%1|@1\n%%2|@2\n%%3|@2\n' ;;
  *) exit 2 ;;
esac
EOS
  chmod +x "$BATS_TEST_TMPDIR/fakebin/tmux"
  # shellcheck disable=SC1091
  . "$SCRIPTS/lib/terminal-registry.sh"
  agmsg_terminal_load tmux

  # No prefetch: each question goes to tmux, and the answer is the pane's window.
  [ "$(terminal_where '%3')" = '@2' ]
  [ "$(terminal_where '%1')" = '@1' ]
  [ "$(grep -c list-panes "$TEAM_FIX_LOG.tmux")" -eq 2 ]

  : > "$TEAM_FIX_LOG.tmux"
  terminal_team_prefetch '%1'
  terminal_team_prefetch '%2'
  # Asked in command substitutions, as team.sh asks, from a shell that prefetched.
  [ "$(terminal_where '%3')" = '@2' ]
  [ "$(terminal_where '%1')" = '@1' ]
  [ "$(grep -c list-panes "$TEAM_FIX_LOG.tmux")" -eq 1 ]

  # A pane the listing does not contain is still unknown/10, never a guess.
  run terminal_where '%9'
  [ "$status" -eq 10 ]
  [ "${lines[0]}" = unknown ]
}
