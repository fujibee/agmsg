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
  run agmsg_locator_compose orca local term_11111111-2222-3333-4444-555555555555
  [ "$status" -eq 0 ]; [ "$output" = "orca:local:term_11111111-2222-3333-4444-555555555555" ]
}

@test "compose: encodes a colon-bearing herdr instance; other malformed inputs stay named" {
  run agmsg_locator_compose herdr "/run/a:b.sock" w1:p7
  [ "$status" -eq 0 ]; [ "$output" = "herdr:v2:/run/a%3Ab.sock:w1:p7" ]
  run agmsg_locator_compose screen /tmp/x w1:p7
  [ "$status" -eq 2 ]; [ "$output" = "agmsg: locator: unknown_kind" ]
  run agmsg_locator_compose herdr /run/herdr-a.sock "w1"
  [ "$status" -eq 2 ]; [ "$output" = "agmsg: locator: pane_malformed" ]
  run agmsg_locator_compose herdr "$(printf '/run/x\t')" w1:p7
  [ "$status" -eq 2 ]; [ "$output" = "agmsg: locator: instance_malformed" ]
  [ -z "$(agmsg_locator_compose herdr "$(printf '/run/x\t')" w1:p7 2>/dev/null)" ]
}

@test "compose: the reason lands on stderr, one word, and stdout stays empty" {
  local err; err="$(agmsg_locator_compose herdr "$(printf '/run/x\t')" w1:p7 2>&1 >/dev/null)" || true
  [ "$err" = "agmsg: locator: instance_malformed" ]
  err="$(agmsg_locator_compose nosuch /x w1:p7 2>&1 >/dev/null)" || true
  [ "$err" = "agmsg: locator: unknown_kind" ]
  err="$(agmsg_locator_compose tmux /x "w1:p7" 2>&1 >/dev/null)" || true
  [ "$err" = "agmsg: locator: pane_malformed" ]
}

# --- the herdr instance codec: versioning and colon-bearing sockets --------------

@test "locator: a versioned herdr locator is visibly invalid to the legacy grammar" {
  local loc id legacy_sock
  loc="$(agmsg_locator_compose herdr "/run/a:b.sock" w1:p7)"
  id="${loc#herdr:}"; legacy_sock="${id%:*:*}"
  case "$legacy_sock" in *:*) : ;; *) false ;; esac
  # The pre-encoding herdr reader rejects a colon in its socket half, so it
  # cannot reinterpret v2: as a different, reachable socket.
  run /bin/bash -c 'case "${1%:*:*}" in *:*) exit 1 ;; *) exit 0 ;; esac' _ "$id"
  [ "$status" -ne 0 ]
}

@test "record refs: a colon-bearing herdr socket is encoded on write and decoded for the driver" {
  agmsg_terminal_load herdr
  local ref
  ref="$(agmsg_terminal_ref herdr '/run/a:b.sock:w1:p7')"
  [ "$ref" = "herdr:v2:/run/a%3Ab.sock:w1:p7" ]
  [ "$(agmsg_terminal_ref_terminal "$ref")" = herdr ]
  [ "$(agmsg_terminal_ref_id "$ref")" = '/run/a:b.sock:w1:p7' ]
  _agmsg_placement_split "$ref"
  [ "$_AGMSG_PS_TERM" = herdr ]
  [ "$_AGMSG_PS_ID" = '/run/a:b.sock:w1:p7' ]

  # Windows herdr socket path: a drive-letter colon, backslashes, AND a literal
  # "%3A" substring already present in the path (not agmsg's own escaping) --
  # all three at once (#1275). The literal %3A round-trips unchanged rather
  # than being re-decoded into a colon: a backslash landing right after a
  # decoded %-escape used to make the decoder consume the rest of the string
  # as one bogus "code" and refuse the whole id with pane_malformed (#1240
  # regression, fixed by switching to substring expansion).
  local win_id='C:\Users\x\herdr%3A.sock:w1:p7'
  ref="$(agmsg_terminal_ref herdr "$win_id")"
  [ "$ref" = 'herdr:v2:C%3A\Users\x\herdr%253A.sock:w1:p7' ]
  [ "$(agmsg_terminal_ref_terminal "$ref")" = herdr ]
  [ "$(agmsg_terminal_ref_id "$ref")" = "$win_id" ]
  _agmsg_placement_split "$ref"
  [ "$_AGMSG_PS_TERM" = herdr ]
  [ "$_AGMSG_PS_ID" = "$win_id" ]
}

@test "fence codec: legacy instances stay compatible and colon-bearing paths round-trip" {
  local old new
  old="$(agmsg_fence_compose herdr /run/herdr.sock 'term:old')"
  [ "$old" = 'fence=/run/herdr.sock:term:old' ]
  [ "$(agmsg_fence_split herdr "$old")" = "$(printf '/run/herdr.sock\tterm:old')" ]
  new="$(agmsg_fence_compose herdr '/run/a:b.sock' 'term:new:anchor')"
  [ "$new" = 'fence-v2=/run/a%3Ab.sock:term:new:anchor' ]
  [ "$(agmsg_fence_split herdr "$new")" = "$(printf '/run/a:b.sock\tterm:new:anchor')" ]
}

@test "fence codec: a legacy instance beginning with the old marker stays byte-for-byte unchanged" {
  local legacy='fence=v2%3A/run/socket:term_old'
  [ "$(agmsg_fence_split herdr "$legacy")" = "$(printf '%s\t%s' 'v2%3A/run/socket' term_old)" ]
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

@test "herdr id grammar: bare and socket-qualified ids accept colon; control chars remain refused" {
  agmsg_terminal_load herdr
  terminal_id_ok "w1:p7"
  terminal_id_ok "/run/herdr-a.sock:w1:p7"
  terminal_id_ok "/tmp/server with space:w1:pB"
  terminal_id_ok "/run/a:b.sock:w1:p7"
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
  _agmsg_terminal_id_ok herdr "v2:/run/a%3Ab.sock:w1:p7"
  _agmsg_terminal_id_ok herdr "w1:p7"
}
