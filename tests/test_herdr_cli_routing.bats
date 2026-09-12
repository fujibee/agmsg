#!/usr/bin/env bats
# .github/scripts/check-herdr-cli-routing.sh: every direct `herdr` call in the
# herdr driver is either routed through _herdr_cli <id> or listed by name and
# count. Counted by call position, not by text. Runs in the bats suite as well
# as in CI so that a shard sees it (the same posture as test_unguarded_env_reads).

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  CHECK="$SKILL_DIR/.github/scripts/check-herdr-cli-routing.sh"
  OPS="$SKILL_DIR/scripts/drivers/terminals/herdr/ops.sh"
  ALLOW="$SKILL_DIR/.github/herdr-cli-routing-allowlist"
  # setup_test_env copies scripts/ but not .github/: bring the checker and its
  # allowlist into the copy, so the mutations below touch nothing real
  mkdir -p "$SKILL_DIR/.github/scripts"
  cp "$BATS_TEST_DIRNAME/../.github/scripts/check-herdr-cli-routing.sh" "$CHECK"
  cp "$BATS_TEST_DIRNAME/../.github/herdr-cli-routing-allowlist" "$ALLOW"
}
teardown() { teardown_test_env; }

@test "routing: the real driver sits at its allowlist" {
  run bash "$CHECK"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "routing: a new direct call in a routed function is red, and names the function" {
  printf '\nterminal_peek_extra() {\n  herdr pane read "$1" >/dev/null\n}\n' >> "$OPS"
  run bash "$CHECK"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q 'terminal_peek_extra calls herdr directly 1 time(s) and is not on the allowlist'
}

@test "routing: an extra direct call inside an allowlisted function is red (ABOVE)" {
  # append a second raw call to the first allowlisted function's body
  local fn; fn="$(awk '!/^#/ && NF {print $1; exit}' "$ALLOW")"
  python3 - "$OPS" "$fn" <<'PY'
import sys,re
p,fn=sys.argv[1],sys.argv[2]; s=open(p).read()
i=s.index(fn+"()"); j=s.index("\n}\n",i)
s=s[:j]+'\n  herdr pane list >/dev/null 2>&1 || true'+s[j:]
open(p,"w").write(s)
PY
  run bash "$CHECK"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q -- "$fn: .* -- ABOVE"
}

@test "routing: a direct call that disappeared is red too (BELOW), and says to lower the entry" {
  local fn; fn="$(awk '!/^#/ && NF {print $1; exit}' "$ALLOW")"
  python3 - "$ALLOW" "$fn" <<'PY'
import sys
p,fn=sys.argv[1],sys.argv[2]
lines=open(p).read().splitlines(True)
out=[]
for l in lines:
    if l.startswith(fn+" "):
        n=int(l.split()[1]); l=f"{fn} {n+1}\n"   # the list claims one MORE than exists == a call vanished
    out.append(l)
open(p,"w").write("".join(out))
PY
  run bash "$CHECK"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q -- "$fn: .* -- BELOW: lower the entry"
}

@test "routing: a `herdr:` inside a message string and a `herdr` in a comment are NOT calls" {
  printf '\n_herdr_noise() {\n  # herdr pane get is mentioned here only\n  echo "herdr: could not read pane" >&2\n  printf "%%s\\n" "see: herdr pane list"\n}\n' >> "$OPS"
  run bash "$CHECK"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "routing: the routed driver reaches the id's socket for every pane-addressed op (argv+env logged)" {
  export FAKEBIN="$SKILL_DIR/fakebin"; mkdir -p "$FAKEBIN"
  export ARGV_LOG="$SKILL_DIR/argv.log"; : > "$ARGV_LOG"
  export PATH="$FAKEBIN:$PATH"
  cat > "$FAKEBIN/herdr" <<'FAKE'
#!/usr/bin/env bash
{ printf 'sock=%s |' "${HERDR_SOCKET_PATH:-<unset>}"; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$ARGV_LOG"
case "$1 $2" in
  "pane get")   printf '{"result":{"pane":{"agent_status":"idle","label":"","terminal_title":"t","terminal_id":"term_X"}}}\n' ;;
  "agent list") printf '{"id":"1","result":{"type":"list","agents":[]}}\n' ;;
  "agent get")  printf '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}\n' ;;
  "pane layout") printf '{"result":{"layout":{}}}\n' ;;
  *) : ;;
esac
exit 0
FAKE
  chmod +x "$FAKEBIN/herdr"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"; agmsg_terminal_load herdr
  local id="/run/other.sock:w1:p7"
  HERDR_SOCKET_PATH=/run/ambient.sock terminal_peek "$id" >/dev/null 2>&1 || true
  HERDR_SOCKET_PATH=/run/ambient.sock terminal_team_observe "$id" >/dev/null 2>&1 || true
  HERDR_SOCKET_PATH=/run/ambient.sock terminal_team_input_ready "$id" claude >/dev/null 2>&1 || true
  HERDR_SOCKET_PATH=/run/ambient.sock terminal_poke "$id" hello >/dev/null 2>&1 || true
  HERDR_SOCKET_PATH=/run/ambient.sock terminal_label_of "$id" >/dev/null 2>&1 || true
  HERDR_SOCKET_PATH=/run/ambient.sock terminal_where "$id" >/dev/null 2>&1 || true
  HERDR_SOCKET_PATH=/run/ambient.sock terminal_name "$id" T alice >/dev/null 2>&1 || true
  # every logged call went to the id's socket, with the BARE pane, never to the ambient one
  [ "$(grep -c 'sock=/run/other.sock |' "$ARGV_LOG")" -ge 7 ]
  refute grep -q 'sock=/run/ambient.sock' "$ARGV_LOG"
  refute grep -q '/run/other.sock:w1:p7' "$ARGV_LOG"
  grep -q 'sock=/run/other.sock | \[pane\] \[read\] \[w1:p7\]' "$ARGV_LOG"
}

@test "routing: pane_process_observe on a qualified id reads its OWN socket even when the ambient socket points at another instance holding the same bare pane" {
  # Two instances, both with a w1:p7. The ambient environment names instance B;
  # the id names instance A. The op must answer with A's pids only -- reading B
  # would build a false proved from another seat's process set (review BLOCK).
  export FAKEBIN="$SKILL_DIR/fakebin"; mkdir -p "$FAKEBIN"
  export ARGV_LOG="$SKILL_DIR/argv.log"; : > "$ARGV_LOG"
  export PATH="$FAKEBIN:$PATH"
  cat > "$FAKEBIN/herdr" <<'FAKE'
#!/usr/bin/env bash
{ printf 'sock=%s |' "${HERDR_SOCKET_PATH:-<unset>}"; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$ARGV_LOG"
# the strict record shape terminal_pane_process_observe parses (#1155)
case "${HERDR_SOCKET_PATH:-}" in
  /run/a.sock) printf '{"result":{"process_info":{"pane_id":"w1:p7","shell_pid":1111,"foreground_process_group_id":1111,"foreground_processes":[{"pid":1111}]}}}\n' ;;
  /run/b.sock) printf '{"result":{"process_info":{"pane_id":"w1:p7","shell_pid":2222,"foreground_process_group_id":2222,"foreground_processes":[{"pid":2222}]}}}\n' ;;
  *)           printf '{"result":{"process_info":{"pane_id":"w1:p7","shell_pid":9999,"foreground_process_group_id":9999,"foreground_processes":[{"pid":9999}]}}}\n' ;;
esac
FAKE
  chmod +x "$FAKEBIN/herdr"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"; agmsg_terminal_load herdr
  local out
  out="$(HERDR_SOCKET_PATH=/run/b.sock terminal_pane_process_observe "/run/a.sock:w1:p7" 2>/dev/null)" || true
  grep -Fq 'sock=/run/a.sock | [pane] [process-info] [--pane] [w1:p7]' "$ARGV_LOG"
  refute grep -Fq 'sock=/run/b.sock' "$ARGV_LOG"
  case "$out" in *1111*) : ;; *) echo "expected instance A's pid in: $out" >&2; return 1 ;; esac
  case "$out" in *2222*|*9999*) echo "another instance's pid leaked: $out" >&2; return 1 ;; esac
}
