#!/usr/bin/env bats

# terminal-nudge.sh for a seat with no placement record (or a recorded pane
# with no agent left in it): the terminal is asked which pane runs the seat's
# agent in its project, and that pane is used and recorded only when there is
# exactly one. Against a fake herdr; no real pane is touched.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_PLUGIN_DIRS=""
  export FAKEBIN="$TEST_SKILL_DIR/fakebin"
  export ARGV_LOG="$TEST_SKILL_DIR/argv.log"
  mkdir -p "$FAKEBIN" "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/proj"
  : > "$ARGV_LOG"
  unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID AGMSG_TERMINAL AGMSG_TERMINAL_DRIVER
  export AGMSG_PANE_CENSUS_TTL=60
  export AGMSG_NUDGE_TYPE=antigravity
  export AGMSG_NUDGE_PROJECT="$TEST_SKILL_DIR/proj"
  export HERDR_SOCKET_PATH="$FAKEBIN/herdr.sock"
  local rule; rule="$(printf '─%.0s' $(seq 1 60))"
  cat > "$FAKEBIN/herdr" <<EOS
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
case "\$1 \$2" in
  "session list") printf '{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$FAKEBIN/herdr.sock"}]}\n' ;;
  "pane list") [ -f "$FAKEBIN/panes.fail" ] && exit 1; cat "$FAKEBIN/panes.json" ;;
  "pane read") printf '%s\n>\n%s\n' '$rule' '$rule' ;;
  "agent get") [ "\$3" = "\$(cat "$FAKEBIN/gone" 2>/dev/null)" ] && { echo agent_not_found; exit 1; }
              printf '{"result":{"agent":{"agent":"agy","agent_status":"idle"}}}\n' ;;
  "agent prompt") echo ok ;;
esac
exit 0
EOS
  chmod +x "$FAKEBIN/herdr"
  export PATH="$FAKEBIN:$PATH"
}
teardown() { teardown_test_env; }

_panes() {   # <pane_id agent cwd>...
  local first=1 id agent cwd
  printf '{"id":"x","result":{"panes":[' > "$FAKEBIN/panes.json"
  while [ $# -ge 3 ]; do
    [ "$first" = 1 ] || printf ',' >> "$FAKEBIN/panes.json"; first=0
    printf '{"pane_id":"%s","agent":"%s","cwd":"%s","foreground_cwd":"%s"}' "$1" "$2" "$3" "$3" >> "$FAKEBIN/panes.json"
    shift 3
  done
  printf ']}}\n' >> "$FAKEBIN/panes.json"
}
_rec() { bash -c '. "'"$SKILL_DIR"'/scripts/lib/actas-lock.sh"; agmsg_spawn_path testteam '"$1"; }
_nudge() { run bash "$SCRIPTS/internal/terminal-nudge.sh" testteam "${1:-agy1}" --body-file <(printf 'hello'); }
_count() { grep -c "$1" "$ARGV_LOG" || true; }

@test "discovery: one pane runs the seat's agent in its project -> recorded and notified" {
  _panes w1:p4F agy "$AGMSG_NUDGE_PROJECT" w1:p1 claude "$AGMSG_NUDGE_PROJECT" w1:p2 agy /elsewhere
  _nudge
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "state=notified"
  [ "$(cut -f1 "$(_rec agy1)")" = "herdr:$FAKEBIN/herdr.sock:w1:p4F" ]
  [ "$(cut -f3 "$(_rec agy1)")" = antigravity ]
  grep -qF '[agent] [prompt] [w1:p4F]' "$ARGV_LOG"
}

@test "discovery: two panes match -> ambiguous, both listed, nothing typed, nothing recorded" {
  _panes w1:p4F agy "$AGMSG_NUDGE_PROJECT" w1:p5 agy "$AGMSG_NUDGE_PROJECT"
  _nudge
  printf '%s\n' "$output" | grep -qF "state=ambiguous reason="
  printf '%s\n' "$output" | grep -qF "w1:p4F"
  printf '%s\n' "$output" | grep -qF "w1:p5"
  [ ! -f "$(_rec agy1)" ]
  [ "$(_count '\[agent\] \[prompt\]')" -eq 0 ]
}

@test "discovery: no pane runs the agent in the project (other agent, other directory) -> no_pane" {
  _panes w1:p1 claude "$AGMSG_NUDGE_PROJECT" w1:p2 agy /elsewhere
  _nudge
  printf '%s\n' "$output" | grep -qF "state=no_pane"
  [ ! -f "$(_rec agy1)" ]
}

@test "discovery: a pane already recorded for another seat is not a candidate" {
  _panes w1:p4F agy "$AGMSG_NUDGE_PROJECT"
  printf 'herdr:%s:w1:p4F\t%s\tantigravity' "$FAKEBIN/herdr.sock" "$AGMSG_NUDGE_PROJECT" > "$(_rec agy2)"
  _nudge agy1
  printf '%s\n' "$output" | grep -qF "state=no_pane"
  # A record written with the bare id of the default instance counts as taken too.
  printf 'herdr:w1:p4F\t%s\tantigravity' "$AGMSG_NUDGE_PROJECT" > "$(_rec agy2)"
  _nudge agy1
  printf '%s\n' "$output" | grep -qF "state=no_pane"
}

@test "discovery: the project is matched by its physical path too (/tmp vs /private/tmp)" {
  local phys; phys="$(cd "$AGMSG_NUDGE_PROJECT" && pwd -P)"
  _panes w1:p4F agy "$phys"
  export AGMSG_NUDGE_PROJECT="$TEST_SKILL_DIR/./proj"
  _nudge
  printf '%s\n' "$output" | grep -qF "state=notified"
}

@test "discovery: one listing serves several seats with nothing to find in a window" {
  _panes w1:p1 claude "$AGMSG_NUDGE_PROJECT"
  _nudge agy1
  printf '%s\n' "$output" | grep -qF "state=no_pane"
  _nudge agy2
  printf '%s\n' "$output" | grep -qF "state=no_pane"
  [ "$(_count '^herdr \[session\] \[list\]')" -eq 1 ]
  [ "$(_count '^herdr \[pane\] \[list\]')" -eq 1 ]
}

@test "discovery: an instance that cannot be read is unknown, never none, and is not cached" {
  _panes w1:p1 claude "$AGMSG_NUDGE_PROJECT"
  : > "$FAKEBIN/panes.fail"
  _nudge
  printf '%s\n' "$output" | grep -qF "state=unknown:pane_listing_incomplete"
  [ ! -f "$SKILL_DIR/run/pane-census.tsv" ]
  rm -f "$FAKEBIN/panes.fail"
  _panes w1:p4F agy "$AGMSG_NUDGE_PROJECT"
  _nudge
  printf '%s\n' "$output" | grep -qF "state=notified"
}

@test "discovery: without the seat's project (a manual run) nothing is looked up" {
  _panes w1:p4F agy "$AGMSG_NUDGE_PROJECT"
  unset AGMSG_NUDGE_PROJECT AGMSG_NUDGE_TYPE
  _nudge
  printf '%s\n' "$output" | grep -qF "state=no_pane"
  [ ! -s "$ARGV_LOG" ]
}

@test "discovery: a recorded pane with no agent left is replaced by the one pane that runs it now" {
  _panes w1:p9 agy "$AGMSG_NUDGE_PROJECT"
  printf 'herdr:%s:w1:p3\t%s\tantigravity' "$FAKEBIN/herdr.sock" "$AGMSG_NUDGE_PROJECT" > "$(_rec agy1)"
  printf '%s' w1:p3 > "$FAKEBIN/gone"
  _nudge
  printf '%s\n' "$output" | grep -qF "state=notified"
  [ "$(cut -f1 "$(_rec agy1)")" = "herdr:$FAKEBIN/herdr.sock:w1:p9" ]
}

@test "discovery: a recorded pane that is gone with no replacement keeps its own answer" {
  _panes w1:p1 claude "$AGMSG_NUDGE_PROJECT"
  printf 'herdr:%s:w1:p3\t%s\tantigravity' "$FAKEBIN/herdr.sock" "$AGMSG_NUDGE_PROJECT" > "$(_rec agy1)"
  printf '%s' w1:p3 > "$FAKEBIN/gone"
  _nudge
  printf '%s\n' "$output" | grep -qF "state=pane_gone"
  [ "$(cut -f1 "$(_rec agy1)")" = "herdr:$FAKEBIN/herdr.sock:w1:p3" ]
}

@test "discovery: a cached candidate whose directory changed is not adopted; the pane that matches now is" {
  _panes w1:p4F agy "$AGMSG_NUDGE_PROJECT"
  _nudge agy1
  printf '%s\n' "$output" | grep -qF "state=notified"
  rm -f "$(_rec agy1)"
  # Within the census window: p4F moved to another project, p9 is the one in this project now.
  _panes w1:p4F agy /elsewhere w1:p9 agy "$AGMSG_NUDGE_PROJECT"
  _nudge agy1
  printf '%s\n' "$output" | grep -qF "state=notified"
  [ "$(cut -f1 "$(_rec agy1)")" = "herdr:$FAKEBIN/herdr.sock:w1:p9" ]
}

@test "discovery: a terminal that cannot be loaded is a hole -> unknown, never another terminal's single match" {
  _panes w1:p4F agy "$AGMSG_NUDGE_PROJECT"
  run bash -c '
    export SKILL_DIR="'"$SKILL_DIR"'" SCRIPT_DIR="'"$SCRIPTS"'"
    . "$SCRIPT_DIR/lib/actas-lock.sh"; . "$SCRIPT_DIR/lib/terminal-registry.sh"; . "$SCRIPT_DIR/lib/type-registry.sh"
    . "$SCRIPT_DIR/lib/pane-discovery.sh"
    agmsg_terminal_candidates() { echo "herdr broken"; }
    _real_load="$(declare -f agmsg_terminal_load)"; eval "_real_${_real_load#agmsg_terminal_load}"
    agmsg_terminal_load() { [ "$1" = broken ] && return 1; _real_ "$@"; }
    agmsg_discover_agent_pane antigravity "'"$AGMSG_NUDGE_PROJECT"'" "'"$SKILL_DIR"'/run/spawn.x__y"
  '
  [ "$output" = "$(printf 'unknown\tpane_listing_incomplete')" ]
}

@test "discovery: another seat of the same type and project with no pane recorded -> ambiguous, nothing assigned" {
  _panes w1:p4F agy "$AGMSG_NUDGE_PROJECT"
  export AGMSG_NUDGE_PEERS="testteam/agy2"
  _nudge agy1
  printf '%s\n' "$output" | grep -qF "state=ambiguous reason=seats_without_pane:testteam/agy2 pane:herdr:$FAKEBIN/herdr.sock:w1:p4F"
  [ ! -f "$(_rec agy1)" ]
  [ "$(_count '\[agent\] \[prompt\]')" -eq 0 ]
  # Once that seat has a pane of its own recorded, this one is the only candidate.
  printf 'herdr:%s:w1:p7\t%s\tantigravity' "$FAKEBIN/herdr.sock" "$AGMSG_NUDGE_PROJECT" > "$(_rec agy2)"
  _nudge agy1
  printf '%s\n' "$output" | grep -qF "state=notified"
}
