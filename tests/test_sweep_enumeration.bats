#!/usr/bin/env bats

# Every pane every terminal can see, as (kind, instance, pane) triples (#1152).
#
# WHY THE TRIPLE. A pane id is unique inside one instance and nowhere else.
# Measured live on 2026-09-11, not argued: two herdr instances were running and
# enumerating both produced 52 rows in which `w1:p1`, `w1:p2`, `w1:p4`, `w1:p5`
# and `w1:p7` each appeared TWICE -- the same id naming a different team's seat
# in each. Two throwaway tmux servers showed the same with `%0`. So a bare pane
# id never leaves this layer.
#
# The tmux cases here drive a FAKE tmux rather than a real one: the behaviours
# that matter are error TEXTS and exit statuses, and a real server would make
# them the runner's property instead of the test's. The real-tmux measurement is
# reported separately; it agreed with every case below.

setup() {
  load 'test_helper'
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
  export TMUX_TMPDIR="$BATS_TEST_TMPDIR/tt"
  SOCKDIR="$TMUX_TMPDIR/tmux-$(id -u)"; mkdir -p "$SOCKDIR"
}
teardown() { teardown_test_env; }

# A tmux whose answer per socket is written by the test.
#   <sockdir>/<name>          the socket itself (a plain file is enough: the op
#                             tests `-S`, so the test makes real sockets)
#   $BATS_TEST_TMPDIR/ans.<name>   "ok:<pane ids>" | "err:<stderr text>"
_fake_tmux() {
  cat > "$BIN/tmux" <<'TEOF'
#!/usr/bin/env bash
sock=""; prev=""
for a in "$@"; do
  [ "$prev" = "-S" ] && sock="$a"
  prev="$a"
done
name="${sock##*/}"
ans="$(cat "$ANSDIR/ans.$name" 2>/dev/null)"
case "$ans" in
  ok:*) printf '%s\n' "${ans#ok:}" | tr ' ' '\n' | grep . ; exit 0 ;;
  err:*) printf '%s\n' "${ans#err:}" >&2 ; exit 1 ;;
  *) printf 'no server running on %s\n' "$sock" >&2 ; exit 1 ;;
esac
TEOF
  chmod +x "$BIN/tmux"
  export ANSDIR="$BATS_TEST_TMPDIR"
}
_socket() {   # <name> ; make a real unix socket so `[ -S ]` is true
  python3 -c "
import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])
" "$SOCKDIR/$1"
}
_answers() { printf '%s' "$2" > "$BATS_TEST_TMPDIR/ans.$1"; }

_load_tmux_op() {
  unset -f terminal_enumerate_panes
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/drivers/terminals/tmux/ops.sh"
}

# --- tmux: the four outcomes ---------------------------------------------------

@test "tmux: every pane is qualified with the server it was seen in (#1152)" {
  _fake_tmux; _socket A; _socket B
  _answers A 'ok:%0'
  _answers B 'ok:%0 %1'
  _load_tmux_op
  run terminal_enumerate_panes
  [ "$status" -eq 0 ]
  # The SAME pane id in two servers, told apart only by the instance. This is
  # the property the triple exists for.
  [ "$(printf '%s\n' "$output" | grep -c "A"$'\t'"%0")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c "B"$'\t'"%0")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c "B"$'\t'"%1")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 3 ]
  # and no row is a bare pane id
  ! printf '%s\n' "$output" | grep -qE '^%'
}

@test "tmux: a server tmux calls absent is stale, and is skipped silently (#1152)" {
  _fake_tmux; _socket A; _socket DEAD
  _answers A 'ok:%0'
  _answers DEAD 'err:no server running on /whatever'
  _load_tmux_op
  run terminal_enumerate_panes
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  ! printf '%s\n' "$output" | grep -q '^!'
}

@test "tmux: any OTHER failure is a named hole, never a silent drop (#1152)" {
  # Measured against a real tmux: a live NON-tmux listener on the socket answers
  # `server exited unexpectedly`, which is not evidence of death. Permission and
  # protocol mismatches look the same from here. Dropping such a server would
  # report its panes as absent.
  _fake_tmux; _socket A; _socket WEIRD
  _answers A 'ok:%0'
  _answers WEIRD 'err:server exited unexpectedly'
  _load_tmux_op
  run terminal_enumerate_panes
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^!')" -eq 1 ]
  printf '%s\n' "$output" | grep -q "^!"$'\t'".*WEIRD"
  # the readable server is still reported -- one hole does not lose the rest
  printf '%s\n' "$output" | grep -q "A"$'\t'"%0"
}

@test "tmux: no socket directory is zero servers; an unreadable uid is NOT (#1152)" {
  _fake_tmux
  rm -rf "$TMUX_TMPDIR"
  _load_tmux_op
  run terminal_enumerate_panes
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # An `id` that cannot answer must not become "this user has no servers": the
  # directory could not even be NAMED. Measured on this machine while directory
  # services were degraded, `id -un` returned the bare uid and lookups failed.
  cat > "$BIN/id" <<'IEOF'
#!/usr/bin/env bash
exit 1
IEOF
  chmod +x "$BIN/id"
  run terminal_enumerate_panes
  [ "$status" -eq 10 ]
  [ -z "$output" ]
}

# --- the caller's shell state --------------------------------------------------

@test "tmux: a caller's glob options cannot silence the enumeration (#1152)" {
  # Measured, BOTH interpreters: with `shopt -s failglob` and an empty socket
  # directory, a bare `for sock in "$dir"/*` produced NO OUTPUT AT ALL -- the
  # shell died at the expansion. `nullglob` does not cover it; failglob wins over
  # nullglob, so the subshell drops failglob explicitly.
  _fake_tmux; _socket A; _answers A 'ok:%0'
  local st
  for st in nullglob failglob dotglob "nullglob failglob" "failglob dotglob"; do
    run bash -c '
      for t in '"$st"'; do shopt -s "$t"; done
      set -o errexit
      . "'"$SKILL_DIR"'/scripts/drivers/terminals/tmux/ops.sh"
      terminal_enumerate_panes
      printf "__rc=%s\n" "$?"
      printf "__failglob=%s __nullglob=%s\n" \
        "$(shopt -q failglob && echo on || echo off)" \
        "$(shopt -q nullglob && echo on || echo off)"'
    printf '%s\n' "$output" | grep -q "A"$'\t'"%0" || { echo "[$st] lost the pane row: $output"; return 1; }
    printf '%s\n' "$output" | grep -q '__rc=0' || { echo "[$st] no rc line -- the shell died: $output"; return 1; }
  done
  # And the caller's options survive: the subshell's shopt must not leak.
  run bash -c '
    shopt -u failglob; shopt -u nullglob
    . "'"$SKILL_DIR"'/scripts/drivers/terminals/tmux/ops.sh"
    terminal_enumerate_panes >/dev/null
    printf "failglob=%s nullglob=%s\n" \
      "$(shopt -q failglob && echo on || echo off)" \
      "$(shopt -q nullglob && echo on || echo off)"'
  [ "$output" = "failglob=off nullglob=off" ]
}

@test "tmux: an empty directory under failglob still answers (the measured death) (#1152)" {
  _fake_tmux                      # directory exists, no sockets in it
  run bash -c '
    shopt -s failglob
    set -o errexit
    . "'"$SKILL_DIR"'/scripts/drivers/terminals/tmux/ops.sh"
    terminal_enumerate_panes
    printf "__rc=%s\n" "$?"'
  [ "$status" -eq 0 ]
  [ "$output" = "__rc=0" ]
}

# --- herdr: instances come from the session list --------------------------------

_fake_herdr() {   # <sessions-json>
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/sessions.json"
  cat > "$BIN/herdr" <<'HEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "session list") cat "$ANSDIR/sessions.json"; exit 0 ;;
esac
case "$1 $2" in
  "pane list")
    f="$ANSDIR/panes.${HERDR_SOCKET_PATH##*/sessions/}"
    f="${f%/herdr.sock}"
    [ -f "$f" ] || exit 7
    cat "$f"; exit 0 ;;
esac
exit 9
HEOF
  chmod +x "$BIN/herdr"
  export ANSDIR="$BATS_TEST_TMPDIR"
}
_herdr_panes() { printf '%s' "$2" > "$BATS_TEST_TMPDIR/panes.$1"; }
_load_herdr_op() {
  unset -f terminal_enumerate_panes
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/drivers/terminals/herdr/ops.sh"
}
_sessions_json() {
  printf '{"sessions":[%s]}' "$1"
}

@test "herdr: only running instances are visited, and rows carry the socket (#1152)" {
  _fake_herdr "$(_sessions_json '
    {"name":"off","running":false,"socket_path":"/s/sessions/off/herdr.sock"},
    {"name":"one","running":true,"socket_path":"/s/sessions/one/herdr.sock"},
    {"name":"two","running":true,"socket_path":"/s/sessions/two/herdr.sock"}')"
  _herdr_panes one '{"result":{"panes":[{"pane_id":"w1:p1"},{"pane_id":"w1:p7"}]}}'
  _herdr_panes two '{"result":{"panes":[{"pane_id":"w1:p7"}]}}'
  _load_herdr_op
  run terminal_enumerate_panes
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 3 ]
  # w1:p7 in BOTH instances, distinguished only by the socket -- the live shape
  [ "$(printf '%s\n' "$output" | grep -c "one/herdr.sock"$'\t'"w1:p7")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c "two/herdr.sock"$'\t'"w1:p7")" -eq 1 ]
  # the non-running session is a decided fact, not a hole
  ! printf '%s\n' "$output" | grep -q 'off'
}

@test "herdr: a running instance that will not answer is a named hole (#1152)" {
  _fake_herdr "$(_sessions_json '
    {"name":"one","running":true,"socket_path":"/s/sessions/one/herdr.sock"},
    {"name":"gone","running":true,"socket_path":"/s/sessions/gone/herdr.sock"}')"
  _herdr_panes one '{"result":{"panes":[{"pane_id":"w1:p1"}]}}'
  # no panes.gone file -> the fake exits non-zero for it
  _load_herdr_op
  run terminal_enumerate_panes
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^!')" -eq 1 ]
  printf '%s\n' "$output" | grep -q "^!"$'\t'"/s/sessions/gone/herdr.sock"
  printf '%s\n' "$output" | grep -q "one/herdr.sock"$'\t'"w1:p1"
}

@test "herdr: a session entry we cannot parse fails the WHOLE enumeration (#1152)" {
  # A session we could not read might be the one holding the pane the caller
  # wants. Reporting the others as if they were everything is the fold this
  # whole layer exists to refuse.
  local bad
  for bad in \
    '{"name":"one","running":"yes","socket_path":"/s/sessions/one/herdr.sock"}' \
    '{"name":"one","running":true,"socket_path":123}' \
    '{"name":"one","running":true}' \
  ; do
    _fake_herdr "$(_sessions_json "$bad")"
    _load_herdr_op
    run terminal_enumerate_panes
    [ "$status" -ne 0 ] || { echo "accepted a session entry it cannot read: $bad"; return 1; }
    [ -z "$output" ] || { echo "emitted rows anyway: $output"; return 1; }
  done
  # Not vacuous: the well-formed entry enumerates.
  _fake_herdr "$(_sessions_json '{"name":"one","running":true,"socket_path":"/s/sessions/one/herdr.sock"}')"
  _herdr_panes one '{"result":{"panes":[{"pane_id":"w1:p1"}]}}'
  _load_herdr_op
  run terminal_enumerate_panes
  [ "$status" -eq 0 ]
}

@test "herdr: a pane entry we cannot parse makes THAT instance a hole (#1152)" {
  # Scoped differently from a bad session entry on purpose: a payload we do not
  # understand costs us that instance, and the instances that answered are still
  # worth reporting -- but the instance must not come back as a SHORTER list.
  _fake_herdr "$(_sessions_json '
    {"name":"one","running":true,"socket_path":"/s/sessions/one/herdr.sock"},
    {"name":"odd","running":true,"socket_path":"/s/sessions/odd/herdr.sock"}')"
  _herdr_panes one '{"result":{"panes":[{"pane_id":"w1:p1"}]}}'
  _herdr_panes odd '{"result":{"panes":[{"pane_id":"w1:p3"},{"pane_id":99}]}}'
  _load_herdr_op
  run terminal_enumerate_panes
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^!')" -eq 1 ]
  printf '%s\n' "$output" | grep -q "^!"$'\t'"/s/sessions/odd/herdr.sock"
  # and NOT the one pane it could read from that instance
  refute grep -q 'w1:p3' <<<"$output"
  printf '%s\n' "$output" | grep -q 'w1:p1'
}

# --- the registry: four causes, four rows, none folded --------------------------

_load_registry() {
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
}

@test "registry: rows carry the terminal KIND as well as the instance (#1152)" {
  _fake_herdr "$(_sessions_json '{"name":"one","running":true,"socket_path":"/s/sessions/one/herdr.sock"}')"
  _herdr_panes one '{"result":{"panes":[{"pane_id":"w1:p1"}]}}'
  _fake_tmux; _socket A; _answers A 'ok:%0'
  _load_registry
  run agmsg_terminal_enumerate
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^herdr"$'\t'"/s/sessions/one/herdr.sock"$'\t'"w1:p1"
  printf '%s\n' "$output" | grep -q "^tmux"$'\t'".*A"$'\t'"%0"
  # nothing leaves here as a bare pane id or a bare (instance, pane) pair
  ! printf '%s\n' "$output" | grep -vE '^(herdr|tmux|plain|\!|\!\!|\?)' | grep -q .
}

@test "registry: a terminal with no enumeration op is ? -- not an empty world (#1152)" {
  _fake_herdr "$(_sessions_json '{"name":"one","running":true,"socket_path":"/s/sessions/one/herdr.sock"}')"
  _herdr_panes one '{"result":{"panes":[{"pane_id":"w1:p1"}]}}'
  _fake_tmux
  _load_registry
  run agmsg_terminal_enumerate
  [ "$status" -eq 0 ]
  # plain has no op at all: the question has no answer there, and a caller can
  # stop asking. That is NOT the same instruction as "could not read".
  printf '%s\n' "$output" | grep -q "^?"$'\t'"plain"
  refute grep -q "^!"$'\t'"plain" <<<"$output"
  refute grep -q "^!!"$'\t'"plain" <<<"$output"
}

@test "registry: a terminal whose op fails outright is !! -- retry, not give up (#1152)" {
  # `?` and `!!` look identical from outside (no rows for that kind) and mean
  # opposite things to a caller. Folding them is how "we could not look" becomes
  # "there is nobody there".
  cat > "$BIN/herdr" <<'HEOF'
#!/usr/bin/env bash
exit 3
HEOF
  chmod +x "$BIN/herdr"
  _fake_tmux; _socket A; _answers A 'ok:%0'
  _load_registry
  run agmsg_terminal_enumerate
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^!!"$'\t'"herdr"
  refute grep -q "^?"$'\t'"herdr" <<<"$output"
  # and the terminal that DID answer is still reported
  printf '%s\n' "$output" | grep -q "^tmux"$'\t'".*A"$'\t'"%0"
}

@test "registry: the driver the caller had loaded is the one it still has (#1152)" {
  # Enumerating loads every candidate in turn. Loading is a global side effect
  # and this function is a reader, so it must put the caller's back.
  _fake_herdr "$(_sessions_json '{"name":"one","running":true,"socket_path":"/s/sessions/one/herdr.sock"}')"
  _herdr_panes one '{"result":{"panes":[{"pane_id":"w1:p1"}]}}'
  _fake_tmux
  _load_registry
  # NOT `plain`: it is the LAST candidate, so a version with no restore at all
  # would leave `plain` loaded and this test would pass on the ordering rather
  # than on the restore. Measured -- with plain, deleting the restore reddened
  # nothing. `herdr` is first, so only an actual restore puts it back.
  agmsg_terminal_load herdr
  [ "$_AGMSG_TERMINAL_LOADED" = herdr ]
  agmsg_terminal_enumerate >/dev/null
  [ "$_AGMSG_TERMINAL_LOADED" = herdr ]
  # and the candidate order really is the thing that made the weaker version
  # pass, so it is pinned: if plain ever stops being last, this test weakens.
  [ "$(agmsg_terminal_candidates | tail -1)" = plain ]
}

@test "registry: a captured op status, not a piped one (#1152)" {
  # `op | while read` reports the WHILE's status. Written that way, a driver
  # whose op failed outright produced an empty stream and a zero -- reported as
  # "that terminal has no panes", which is the confusion this layer exists to
  # prevent. Derived from the source rather than asserted about behaviour, so it
  # cannot pass by the op happening to succeed.
  local body
  body="$(awk '/^agmsg_terminal_enumerate\(\)/,/^}/' "$SKILL_DIR/scripts/lib/terminal-registry.sh" \
          | grep -v '^[[:space:]]*#')"
  [ -n "$body" ] || { echo "could not read the function"; return 1; }
  # the op's output is captured into a variable before any loop touches it
  printf '%s\n' "$body" | grep -qE 'if out="\$\(terminal_enumerate_panes' \
    || { echo "the op's status is not captured:"; printf '%s\n' "$body"; return 1; }
  # and never piped straight into the reader
  ! printf '%s\n' "$body" | grep -qE 'terminal_enumerate_panes[^|]*\|'
}
