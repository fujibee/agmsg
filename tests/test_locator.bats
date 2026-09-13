#!/usr/bin/env bats
# The one locator grammar: <kind>:<instance>:<pane> (scripts/lib/terminal-registry.sh),
# and the herdr driver's socket-qualified id it rests on (#1055, #1152).

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
  export FAKEBIN="$SKILL_DIR/fakebin"; mkdir -p "$FAKEBIN"
  export ARGV_LOG="$SKILL_DIR/argv.log"; : > "$ARGV_LOG"
  export PATH="$FAKEBIN:$PATH"
  unset TMUX TMUX_PANE HERDR_SOCKET_PATH
}
teardown() { teardown_test_env; }

# --- compose ---------------------------------------------------------------------

@test "compose: herdr, tmux and plain locators, including a socket path with spaces" {
  run agmsg_locator_compose herdr /run/herdr-a.sock w1:p7
  [ "$status" -eq 0 ]; [ "$output" = "herdr:/run/herdr-a.sock:w1:p7" ]
  run agmsg_locator_compose tmux "/tmp/server with space" %4
  [ "$status" -eq 0 ]; [ "$output" = "tmux:/tmp/server with space:%4" ]
  run agmsg_locator_compose plain iterm /dev/ttys040
  [ "$status" -eq 0 ]; [ "$output" = "plain:iterm:/dev/ttys040" ]
}

@test "compose: refuses by NAME -- an instance with a colon, an unknown kind, a pane outside the grammar, an empty instance" {
  # `run` folds stderr into $output, so the reason IS the output and stdout is empty
  run agmsg_locator_compose herdr "/run/a:b.sock" w1:p7
  [ "$status" -eq 2 ]; [ "$output" = "agmsg: locator: instance_malformed" ]
  run agmsg_locator_compose screen /tmp/x w1:p7
  [ "$status" -eq 2 ]; [ "$output" = "agmsg: locator: unknown_kind" ]
  run agmsg_locator_compose herdr /run/herdr-a.sock "w1"
  [ "$status" -eq 2 ]; [ "$output" = "agmsg: locator: pane_malformed" ]
  run agmsg_locator_compose herdr "" w1:p7
  [ "$status" -eq 2 ]; [ "$output" = "agmsg: locator: instance_malformed" ]
  [ -z "$(agmsg_locator_compose herdr "" w1:p7 2>/dev/null)" ]
}

@test "compose: the reason lands on stderr, one word, and stdout stays empty" {
  local err; err="$(agmsg_locator_compose herdr "/run/a:b.sock" w1:p7 2>&1 >/dev/null)" || true
  [ "$err" = "agmsg: locator: instance_malformed" ]
  err="$(agmsg_locator_compose nosuch /x w1:p7 2>&1 >/dev/null)" || true
  [ "$err" = "agmsg: locator: unknown_kind" ]
  err="$(agmsg_locator_compose tmux /x "w1:p7" 2>&1 >/dev/null)" || true
  [ "$err" = "agmsg: locator: pane_malformed" ]
}

# --- split -----------------------------------------------------------------------

@test "split: every composed locator round-trips, and the herdr pane keeps its own colon" {
  local loc
  for loc in "herdr:/run/herdr-a.sock:w1:p7" "tmux:/tmp/server with space:%4" "plain:iterm:/dev/ttys040" "tmux:/tmp/tmux-a:@12"; do
    run agmsg_locator_split "$loc"
    [ "$status" -eq 0 ]
    case "$loc" in
      herdr:*) [ "$output" = "$(printf 'herdr\t/run/herdr-a.sock\tw1:p7')" ] ;;
      tmux:*space*) [ "$output" = "$(printf 'tmux\t/tmp/server with space\t%%4')" ] ;;
      tmux:*) [ "$output" = "$(printf 'tmux\t/tmp/tmux-a\t@12')" ] ;;
      plain:*) [ "$output" = "$(printf 'plain\titerm\t/dev/ttys040')" ] ;;
    esac
    # and composing the split gives the locator back
    local k i p; k="${output%%$'\t'*}"; i="${output#*$'\t'}"; p="${i#*$'\t'}"; i="${i%%$'\t'*}"
    [ "$(agmsg_locator_compose "$k" "$i" "$p")" = "$loc" ]
  done
}

@test "split: an instance with a colon is refused by name, never mis-split into a different pane" {
  # /run/a:b.sock:w1:p7 -- a naive right split would read instance=/run/a, pane=b.sock:w1:p7 or worse
  run agmsg_locator_split "herdr:/run/a:b.sock:w1:p7"
  [ "$status" -eq 2 ]; [ "$output" = "agmsg: locator: id_malformed" ]
  [ -z "$(agmsg_locator_split "herdr:/run/a:b.sock:w1:p7" 2>/dev/null)" ]
}

@test "split: unknown kind, no instance, bare pane and control characters are refused by name" {
  local err
  err="$(agmsg_locator_split "screen:/x:w1:p7" 2>&1 >/dev/null)" || true; [ "$err" = "agmsg: locator: unknown_kind" ]
  # a bare herdr pane is a VALID driver id with no instance: the registry can tell, and says so
  err="$(agmsg_locator_split "herdr:w1:p7" 2>&1 >/dev/null)" || true;     [ "$err" = "agmsg: locator: instance_malformed" ]
  err="$(agmsg_locator_split "plain:/dev/ttys040" 2>&1 >/dev/null)" || true; [ "$err" = "agmsg: locator: id_malformed" ]
  # the legacy plain sentinel is a valid driver id that names no instance: the registry can tell
  err="$(agmsg_locator_split "plain:-" 2>&1 >/dev/null)" || true;          [ "$err" = "agmsg: locator: instance_malformed" ]
  err="$(agmsg_locator_split "herdr:/x:w1" 2>&1 >/dev/null)" || true;     [ "$err" = "agmsg: locator: id_malformed" ]
  err="$(agmsg_locator_split "$(printf 'herdr:/x\n:w1:p7')" 2>&1 >/dev/null)" || true; [ "$err" = "agmsg: locator: locator_malformed" ]
  err="$(agmsg_locator_split "" 2>&1 >/dev/null)" || true;                [ "$err" = "agmsg: locator: locator_malformed" ]
}

@test "split: the tmux legacy pane id inside a locator is still a pane, and the loaded driver is not replaced" {
  agmsg_terminal_load tmux
  run agmsg_locator_split "herdr:/run/herdr-a.sock:w1:p7"
  [ "$status" -eq 0 ]
  [ "$_AGMSG_TERMINAL_LOADED" = tmux ]
  declare -F terminal_id_ok >/dev/null
  terminal_id_ok "%4"        # still tmux's grammar
}

@test "split: the herdr split relies on the pane grammar having exactly ONE colon -- a three-field pane is refused, never split elsewhere" {
  # `_herdr_sock_of` takes the trailing two colon fields as the pane. That is
  # only right while `w…:p…` has exactly one colon, which terminal_id_ok
  # enforces. If the pane grammar ever grows a field, this is the test that
  # notices: the value must be REFUSED, not silently split one field to the left.
  run agmsg_locator_split "herdr:/run/herdr-a.sock:w1:p7:x9"
  [ "$status" -eq 2 ]
  [ "$output" = "agmsg: locator: id_malformed" ]
  agmsg_terminal_load herdr
  refute terminal_id_ok "/run/herdr-a.sock:w1:p7:x9"
  refute terminal_id_split "/run/herdr-a.sock:w1:p7:x9"
}

# --- the herdr id: bare or socket-qualified -------------------------------------------

_fake_herdr_env_logger() {
  cat > "$FAKEBIN/herdr" <<'FAKE'
#!/usr/bin/env bash
{ printf 'sock=%s |' "${HERDR_SOCKET_PATH:-<unset>}"; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$ARGV_LOG"
printf '{"result":{"pane":{"agent_status":"idle","label":"","terminal_title":"t","terminal_id":"term_X"}}}\n'
FAKE
  chmod +x "$FAKEBIN/herdr"
}

@test "herdr id grammar: bare and socket-qualified ids are accepted; a colon or control char in the socket is refused" {
  agmsg_terminal_load herdr
  terminal_id_ok "w1:p7"
  terminal_id_ok "/run/herdr-a.sock:w1:p7"
  terminal_id_ok "/tmp/server with space:w1:pB"
  refute terminal_id_ok "/run/a:b.sock:w1:p7"
  refute terminal_id_ok "$(printf '/run/x\n:w1:p7')"
  refute terminal_id_ok ":w1:p7"
  refute terminal_id_ok "w1"
  [ "$(_herdr_sock_of "/run/herdr-a.sock:w1:p7")" = "/run/herdr-a.sock" ]
  [ "$(_herdr_bare_of "/run/herdr-a.sock:w1:p7")" = "w1:p7" ]
  [ "$(_herdr_sock_of "w1:p7")" = "" ]
  [ "$(_herdr_bare_of "w1:p7")" = "w1:p7" ]
}

@test "herdr _herdr_cli: a qualified id reaches ITS socket and the CLI is given the bare pane; a bare id keeps the ambient socket" {
  _fake_herdr_env_logger
  agmsg_terminal_load herdr
  _herdr_cli "/run/herdr-a.sock:w1:p7" pane get w1:p7 >/dev/null
  grep -Fqx 'sock=/run/herdr-a.sock | [pane] [get] [w1:p7]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  HERDR_SOCKET_PATH=/run/ambient.sock _herdr_cli "w1:p7" pane get w1:p7 >/dev/null
  grep -Fqx 'sock=/run/ambient.sock | [pane] [get] [w1:p7]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  HERDR_SOCKET_PATH=/run/ambient.sock _herdr_cli "/run/other.sock:w1:p7" pane get w1:p7 >/dev/null
  grep -Fqx 'sock=/run/other.sock | [pane] [get] [w1:p7]' "$ARGV_LOG"   # the id wins over the environment
}

@test "registry: _agmsg_terminal_id_ok for herdr follows the qualified grammar" {
  _agmsg_terminal_id_ok herdr "/run/herdr-a.sock:w1:p7"
  refute _agmsg_terminal_id_ok herdr "/run/a:b.sock:w1:p7"
  _agmsg_terminal_id_ok herdr "w1:p7"
}
