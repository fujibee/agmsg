#!/usr/bin/env bats

# scripts/lib/down-notice.sh: a durable "down or degraded" record under
# run/down/<component>.json that status, doctor and the session-start hook show.

load test_helper

setup() {
  setup_test_env
  unset AGMSG_SYNC_CONNECTION_DIR
  mkdir -p "$TEST_SKILL_DIR/run"
  # shellcheck disable=SC1091
  . "$TEST_SKILL_DIR/scripts/lib/down-notice.sh"
  DIR="$TEST_SKILL_DIR/run/down"
}

teardown() { teardown_test_env; }

@test "set writes run/down/<component>.json; list and print show state, reason and recovery" {
  down_notice_set sync.t1 down "the engine is down" "bash remote.sh sync start t1"
  [ -f "$DIR/sync.t1.json" ]
  grep -qF '"state":"down"' "$DIR/sync.t1.json"
  run down_notice_list
  [ "$(printf '%s\n' "$output" | awk -F'\t' '{print $1 "|" $2 "|" $4 "|" $5}')" = "sync.t1|down|the engine is down|bash remote.sh sync start t1" ]
  run down_notice_print
  printf '%s\n' "$output" | grep -qF "sync.t1 is down since"
  printf '%s\n' "$output" | grep -qF "recover with: bash remote.sh sync start t1"
}

@test "the install root is the helper's own, not the caller's SKILL_DIR" {
  export SKILL_DIR="$BATS_TEST_TMPDIR/somewhere-else"
  down_notice_set c0 degraded "r" "c"
  [ -f "$TEST_SKILL_DIR/run/down/c0.json" ]
  [ ! -e "$BATS_TEST_TMPDIR/somewhere-else" ]
}

@test "since is kept while the state is the same, restarts when the state changes; clear removes only that record" {
  down_notice_set c1 degraded "first" "do x"
  down_notice_set other down "x" "y"
  local before after
  before="$(down_notice_list | awk -F'\t' '$1 == "c1" {print $3}')"
  sleep 1
  down_notice_set c1 degraded "second" "do y"
  after="$(down_notice_list | awk -F'\t' '$1 == "c1" {print $3}')"
  [ "$before" = "$after" ]
  grep -qF "second" "$DIR/c1.json"
  sleep 1
  down_notice_set c1 down "worse" "do z"
  [ "$(down_notice_list | awk -F'\t' '$1 == "c1" {print $3}')" != "$before" ]
  down_notice_clear c1
  [ ! -e "$DIR/c1.json" ]
  [ -f "$DIR/other.json" ]
}

@test "free text with quotes, backslashes, newlines and tabs stays one valid JSON line" {
  down_notice_set c2 down $'two\nlines\tand "quotes" and \\ slash' "cmd"
  [ "$(wc -l < "$DIR/c2.json" | tr -d ' ')" -eq 1 ]
  run sqlite_mem "SELECT json_valid(CAST(readfile('$DIR/c2.json') AS TEXT));"
  [ "$output" = 1 ]
  run sqlite_mem "SELECT json_extract(CAST(readfile('$DIR/c2.json') AS TEXT), '\$.component');"
  [ "$output" = c2 ]
}

@test "an invalid component or state is refused with status 2 and writes nothing" {
  run down_notice_set "../evil" down "r" "c"
  [ "$status" -eq 2 ]
  run down_notice_set "Upper" down "r" "c"
  [ "$status" -eq 2 ]
  # the same under a collating locale, where a-z can match uppercase
  LC_ALL=en_US.UTF-8 run down_notice_set "Upper" down "r" "c"
  [ "$status" -eq 2 ]
  run down_notice_set "a b" down "r" "c"
  [ "$status" -eq 2 ]
  run down_notice_set ".hidden" down "r" "c"
  [ "$status" -eq 2 ]
  run down_notice_set ok-key broken "r" "c"
  [ "$status" -eq 2 ]
  run down_notice_clear "../evil"
  [ "$status" -eq 2 ]
  [ ! -e "$DIR" ] || [ -z "$(ls -A "$DIR")" ]
}

@test "down_notice_key makes a valid key from free text" {
  local k
  k="$(down_notice_key sync "My Team/1")"
  case "$k" in sync.my-team-1-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) echo "$k"; return 1 ;; esac
  down_notice_set "$k" down r c
  [ -f "$DIR/$k.json" ]
}

@test "down_notice_key: texts that fold alike get different keys, and the same text the same key" {
  [ "$(down_notice_key sync "My Team")" != "$(down_notice_key sync "my-team")" ]
  [ "$(down_notice_key sync "My Team")" != "$(down_notice_key sync "my team")" ]
  [ "$(down_notice_key sync "My Team")" = "$(down_notice_key sync "My Team")" ]
  down_notice_set "$(down_notice_key sync "My Team")" down r c
  down_notice_set "$(down_notice_key sync "my-team")" down r c
  down_notice_clear "$(down_notice_key sync "my-team")"
  [ -f "$DIR/$(down_notice_key sync "My Team").json" ]
}

@test "down_notice_key: a long or non-ASCII text still yields a valid key of at most 100 characters" {
  local k
  k="$(down_notice_key sync "$(printf 'x%.0s' $(seq 1 300))")"
  [ "${#k}" -le 100 ]
  run down_notice_set "$k" down r c
  [ "$status" -eq 0 ]
  [ -f "$DIR/$k.json" ]
  k="$(down_notice_key sync "チーム")"
  run down_notice_set "$k" down r c
  [ "$status" -eq 0 ]
  [ -f "$DIR/$k.json" ]
}

@test "no ambient variable redirects the records; only AGMSG_DOWN_NOTICE_ROOT, set by the caller, does" {
  export AGMSG_SYNC_CONNECTION_DIR="$BATS_TEST_TMPDIR/elsewhere"
  down_notice_set c9 down r c
  [ -f "$TEST_SKILL_DIR/run/down/c9.json" ]
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]
  AGMSG_DOWN_NOTICE_ROOT="$BATS_TEST_TMPDIR/own" down_notice_set c9 down r c
  [ -f "$BATS_TEST_TMPDIR/own/run/down/c9.json" ]
}

@test "print_once shows a record once, and again only when it changes" {
  down_notice_set c3 down "down" "fix"
  run down_notice_print_once
  printf '%s\n' "$output" | grep -qF "c3 is down since"
  run down_notice_print_once
  [ -z "$output" ]
  down_notice_set c3 down "down differently" "fix"
  run down_notice_print_once
  printf '%s\n' "$output" | grep -qF "down differently"
}

@test "print_once does not show a record again just because it was set again unchanged" {
  down_notice_set c5 down "same reason" "same fix"
  run down_notice_print_once
  printf '%s\n' "$output" | grep -qF "c5 is down since"
  sleep 1
  down_notice_set c5 down "same reason" "same fix"
  run down_notice_print_once
  [ -z "$output" ]
}

@test "set and clear return 0 when done and verified, 1 on an I/O failure, 2 on invalid input" {
  run down_notice_set ok1 down "r" "c"
  [ "$status" -eq 0 ]
  [ -f "$DIR/ok1.json" ]
  run down_notice_clear ok1
  [ "$status" -eq 0 ]
  [ ! -e "$DIR/ok1.json" ]
  run down_notice_clear never-there
  [ "$status" -eq 0 ]
  run down_notice_set "Bad Key" down "r" "c"
  [ "$status" -eq 2 ]
  run down_notice_clear "Bad Key"
  [ "$status" -eq 2 ]
}

@test "set returns 1, with one line on stderr, when the run directory cannot be created" {
  : > "$TEST_SKILL_DIR/run/down"      # a file where the directory should be
  run down_notice_set c4 down "r" "c"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF "could not record that c4 is down"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  run down_notice_print
  [ "$status" -eq 0 ]
}

@test "set returns 1 when the directory exists but cannot be written" {
  [ "$(id -u)" -ne 0 ] || skip "root can write anywhere"
  mkdir -p "$DIR"
  chmod 500 "$DIR"
  run down_notice_set c6 down "r" "c"
  chmod 700 "$DIR"
  [ "$status" -eq 1 ]
  [ ! -e "$DIR/c6.json" ]
}

@test "clear returns 1 when the record cannot be removed" {
  mkdir -p "$DIR/c7.json/inside"      # rm -f cannot remove a non-empty directory
  run down_notice_clear c7
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF "could not clear the record for c7"
}

@test "clear returns 1 when the directory cannot be searched: absence is established, not inferred" {
  [ "$(id -u)" -ne 0 ] || skip "root can search anywhere"
  down_notice_set c9 down "r" "c"
  chmod 000 "$DIR"
  run down_notice_clear c9
  chmod 700 "$DIR"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF "could not clear the record for c9"
  [ -f "$DIR/c9.json" ]
}

@test "a failed write prints exactly one line, whichever way it fails" {
  [ "$(id -u)" -ne 0 ] || skip "root can write anywhere"
  mkdir -p "$DIR"
  chmod 500 "$DIR"
  run down_notice_set c10 down "r" "c"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  run /bin/bash -c '. "$1"; down_notice_set c10 down r c' _ "$SCRIPTS/lib/down-notice.sh"
  chmod 700 "$DIR"
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "with no install root, set and clear fail with one line instead of claiming success" {
  run /bin/bash -c '. "$1"; unset AGMSG_DOWN_NOTICE_ROOT; _AGMSG_DOWN_NOTICE_ROOT=""; down_notice_set c11 down r c; echo "set=$?"; down_notice_clear c11; echo "clear=$?"' _ "$SCRIPTS/lib/down-notice.sh"
  printf '%s\n' "$output" | grep -qF "set=1"
  printf '%s\n' "$output" | grep -qF "clear=1"
  [ "$(printf '%s\n' "$output" | grep -c 'could not')" -eq 2 ]
}

@test "a caller that guards the call with || : keeps going on a failed write" {
  : > "$TEST_SKILL_DIR/run/down"
  run bash -c '. "$1"; down_notice_set c8 down r c 2>/dev/null || :; echo after' _ "$SCRIPTS/lib/down-notice.sh"
  [ "$status" -eq 0 ]
  [ "$output" = after ]
}

@test "agmsg doctor lists every record as a warning, and exits 1" {
  down_notice_set sync.t1 down "the engine is down" "bash remote.sh sync start t1"
  down_notice_set watch.s1 degraded "slow" "restart it"
  run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF "sync.t1 is down since"
  printf '%s\n' "$output" | grep -qF "recover with: bash remote.sh sync start t1"
  printf '%s\n' "$output" | grep -qF "watch.s1 is degraded since"
  printf '%s\n' "$output" | grep -qF "2 warning(s)"
}

@test "agmsg doctor is unchanged when there is no record" {
  run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "no warnings."
}

@test "remote.sh doctor shows its own family only, from the root it passes" {
  down_notice_set sync.t1 down "the engine is down" "bash remote.sh sync start t1"
  down_notice_set watch.s1 degraded "slow" "restart it"
  run bash "$SCRIPTS/remote.sh" doctor
  printf '%s\n' "$output" | grep -qF "AGMSG: sync.t1 is down since"
  refute grep -qF "watch.s1" <<<"$output"
}

@test "remote.sh doctor reads the sync records from its connection root, not the install root" {
  local other="$BATS_TEST_TMPDIR/conn"
  mkdir -p "$other/run/down"
  printf '{"component":"sync.t2","state":"down","reason":"r","recovery":"c","since":"2026-11-04T00:00:00Z","updated":"2026-11-04T00:00:00Z"}\n' > "$other/run/down/sync.t2.json"
  down_notice_set watch.s1 degraded "slow" "restart it"
  run env AGMSG_SYNC_CONNECTION_DIR="$other" bash "$SCRIPTS/remote.sh" doctor
  printf '%s\n' "$output" | grep -qF "AGMSG: sync.t2 is down since"
  refute grep -qF "watch.s1" <<<"$output"
}

@test "the session-start hook shows a record once, and again after it changes" {
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a >/dev/null
  down_notice_set sync.testteam down "the engine is down" "bash remote.sh sync start testteam"
  run bash -c 'printf "{\"session_id\":\"sid-one\"}" | bash "$1" claude-code /tmp/project-a' _ "$SCRIPTS/session-start.sh"
  printf '%s\n' "$output" | grep -qF "AGMSG: sync.testteam is down since"
  run bash -c 'printf "{\"session_id\":\"sid-two\"}" | bash "$1" claude-code /tmp/project-a' _ "$SCRIPTS/session-start.sh"
  refute grep -qF "AGMSG: sync.testteam is down since" <<<"$output"
  down_notice_set sync.testteam down "now for another reason" "bash remote.sh sync start testteam"
  run bash -c 'printf "{\"session_id\":\"sid-three\"}" | bash "$1" claude-code /tmp/project-a' _ "$SCRIPTS/session-start.sh"
  printf '%s\n' "$output" | grep -qF "now for another reason"
}

# Run on the system bash too: bash 3.2 differs from bash 5 in replacement
# quoting and in how it reads a byte above 0x7f.
@test "free text keeps a quoted recovery command intact (system bash and this bash)" {
  local sh
  for sh in /bin/bash bash; do
    run "$sh" -c '. "$1"; _down_notice_clean "bash \"/tmp/a b/tool.sh\" restart"' _ "$SCRIPTS/lib/down-notice.sh"
    [ "$output" = "bash '/tmp/a b/tool.sh' restart" ]
  done
}

@test "every control character in free text becomes a space, so the record is valid JSON" {
  local sh
  for sh in /bin/bash bash; do
    "$sh" -c '. "$1"; down_notice_set esc degraded $'"'"'colored\033[31m error\bx\001y'"'"' "agmsg doctor"' _ "$SCRIPTS/lib/down-notice.sh"
    run sqlite_mem "SELECT json_valid(CAST(readfile('$TEST_SKILL_DIR/run/down/esc.json') AS TEXT));"
    [ "$output" = 1 ]
    run sqlite_mem "SELECT json_extract(CAST(readfile('$TEST_SKILL_DIR/run/down/esc.json') AS TEXT), '\$.reason');"
    [ "$output" = "colored [31m error x y" ]
  done
}

@test "down_notice_key gives the same key on every bash: known FNV-1a vectors, ASCII and non-ASCII" {
  local sh
  for sh in /bin/bash bash; do
    run "$sh" -c '. "$1"; down_notice_key sync "My Team"; down_notice_key sync "チーム"' _ "$SCRIPTS/lib/down-notice.sh"
    [ "${lines[0]}" = "sync.my-team-8a879198" ]
    [ "${lines[1]}" = "sync.----------4da668f2" ]
  done
}

# doctor runs on a PATH with no python3, and so no awk, cat or anything else: the
# readers are shell builtins, and with no record they return at once.
@test "list, print and print_once work on an empty PATH, with and without a record" {
  local lib="$SCRIPTS/lib/down-notice.sh" out
  out="$(env -i PATH=/nonexistent /bin/bash -c '. "$1"; down_notice_list; down_notice_print; down_notice_print sync.; down_notice_print_once; echo rc=$?' _ "$lib" 2>&1)"
  [ "$out" = "rc=0" ]
  down_notice_set sync.t1 down "the engine is down" "bash remote.sh sync start t1"
  down_notice_set watch.s1 degraded "slow" "restart it"
  out="$(env -i PATH=/nonexistent /bin/bash -c '. "$1"; down_notice_list; down_notice_print sync.; down_notice_print_once' _ "$lib" 2>&1)"
  printf '%s\n' "$out" | grep -qF "sync.t1	down	"
  printf '%s\n' "$out" | grep -qF "AGMSG: sync.t1 is down since"
  printf '%s\n' "$out" | grep -qF "recover with: bash remote.sh sync start t1"
  refute grep -qF "command not found" <<<"$out"
}
