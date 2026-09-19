#!/usr/bin/env bats

# The `-b` requirement, and the refusal that carries it (#829).
#
# A native Windows jq prints CRLF, and the trailing CR rides into the two values
# this driver sends -- the message `wire_id` and the base64 envelope `blob` --
# because `read` takes the LF and `IFS` has no CR. `jq -b` is jq's own answer.
#
# The requirement fails closed rather than degrading: this repository checks that
# jq EXISTS and never which jq it is, so a jq without `-b` would exit 2 on every
# call in here anyway. What the refusal buys is the operator reading "this jq
# cannot do binary output" instead of "Stage-1 sync is broken".

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# A jq that works for everything except `-b`, which is what an older jq is.
stub_jq_without_b() {
  local bin="$TEST_SKILL_DIR/jq-no-b"
  mkdir -p "$bin"
  cat > "$bin/jq" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -b|-b*|--binary) echo "jq: Unknown option $a" >&2; exit 2 ;;
  esac
done
exec /usr/bin/env -i PATH="$REAL_PATH" jq "$@"
STUB
  chmod +x "$bin/jq"
  printf '%s' "$bin"
}

@test "sync: a jq without -b is refused by name, not left to fail later (#829)" {
  local bin; bin="$(stub_jq_without_b)"

  run env REAL_PATH="$PATH" PATH="$bin:$PATH" bash -c '
    . "$1/drivers/storage/sqlite-sync.sh"
    _sqlite_sync_require_jq_binary
  ' _ "$SCRIPTS"

  [ "$status" -ne 0 ]
  # NAMED. The point of failing closed is the sentence, so the sentence is what
  # is asserted -- not merely that something went wrong.
  echo "$output" | grep -q 'requires a jq whose -b (binary output) produces LF-terminated lines'
  echo "$output" | grep -q 'emits CRLF'
}

@test "sync: a jq WITH -b is accepted, so the refusal is not unconditional (#829)" {
  # The negative control. Without it, the case above is satisfied by a probe
  # that refuses every jq.
  run bash -c '
    . "$1/drivers/storage/sqlite-sync.sh"
    _sqlite_sync_require_jq_binary
  ' _ "$SCRIPTS"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sync: the driver's own entry refuses too, so the check is wired (#829)" {
  # THE PROBE BEING RIGHT IS NOT THE PROBE BEING CALLED.
  #
  # The two cases above drive `_sqlite_sync_require_jq_binary` directly, so they
  # hold even if nothing in the driver ever calls it -- measured: removing the
  # call from `_sqlite_sync_schema` reddens neither. This one goes in through the
  # entry that gates the driver, so the wiring is what fails when the wiring is
  # what breaks.
  local bin; bin="$(stub_jq_without_b)"

  # THROUGH THE PATH THAT NEEDS IT. The check was moved out of
  # `_sqlite_sync_schema` -- which gates receiving and status too -- and into the
  # push path, which is the only one producing the two values the CR rides on.
  # So the wiring assertion has to enter there.
  run env REAL_PATH="$PATH" PATH="$bin:$PATH" bash -c '
    export SKILL_DIR="$2" AGMSG_STORAGE_PATH="$3" AGMSG_STORAGE_DRIVER=sqlite
    . "$1/lib/storage.sh"; agmsg_storage_load
    storage_init demo >/dev/null 2>&1
    printf "%s\n" "{\"type\":\"sync_prepare\",\"envelope_v\":1,\"cipher\":\"none\",\"key_id\":null,\"max_blob_bytes\":1048576,\"allow_new\":true}" \
      | storage_sync_prepare_push demo 018f3f7e-0000-7000-8000-000000000000 018f3f7e-0000-7000-8000-000000000001 1 100
  ' _ "$SCRIPTS" "$TEST_SKILL_DIR" "$BATS_TEST_TMPDIR/store3"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'requires a jq whose -b (binary output) produces LF-terminated lines'
}

# A jq that adds CR the way the reporting machine's does -- but only to the
# `@tsv` stages, and that restriction is the honest part.
#
# On the reporting machine EVERY jq line ends CRLF, and the shell there drops the
# trailing CR from a `$( )` capture, so only the `read` sinks are poisoned. This
# test runs on a shell that does NOT drop it, so a faithful stub also poisons
# every `VAR=$(… jq …)` in the driver -- `cipher` becomes `none<CR>`, `version`
# becomes `1<CR>` -- and prepare fails for a reason that cannot happen on the
# platform being simulated. Measured: it returned 13, silently.
#
# So the simulation is scoped to the sink under test: the two final stages that
# end in `@tsv` and are consumed by `while IFS=$'\t' read -r`. That is where the
# field report measured the CR, and it is the only place this change touches.
stub_jq_crlf_without_b() {
  local bin="$TEST_SKILL_DIR/jq-crlf"
  mkdir -p "$bin"
  cat > "$bin/jq" <<STUB
#!/usr/bin/env bash
real="$(command -v jq)"
for a in "\$@"; do
  case "\$a" in -b|-b*) exec "\$real" "\$@" ;; esac
done
tsv=0
for a in "\$@"; do
  case "\$a" in *@tsv*) tsv=1 ;; esac
done
if [ "\$tsv" = 1 ]; then
  "\$real" "\$@" | sed 's/\$/\r/'
  exit "\${PIPESTATUS[0]}"
fi
exec "\$real" "\$@"
STUB
  chmod +x "$bin/jq"
  printf '%s' "$bin"
}

push_fixture() {
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init demo >/dev/null
  SERVER_ID=018f3f7e-0000-7000-8000-000000000000
  TEAM_ID=018f3f7e-0000-7000-8000-000000000001
  PREPARE='{"type":"sync_prepare","envelope_v":1,"cipher":"none","key_id":null,"max_blob_bytes":1048576,"allow_new":true}'
  storage_send demo alice bob "a body that must arrive intact" >/dev/null
}

staged_hex() {
  local col="$1" db
  db="$(printf '%s' "$AGMSG_STORAGE_PATH")/teams/demo/store.db"
  [ -f "$db" ] || db="$(find "$AGMSG_STORAGE_PATH" -name '*.db' -print -quit)"
  sqlite3 "$db" "SELECT hex($col) FROM sync_messages WHERE direction='push' LIMIT 1;"
}

@test "sync: a CRLF jq does not put a trailing CR on the staged wire_id (#829)" {
  # THE FIELD OBSERVATION, REPRODUCED LOCALLY. On the reporting machine
  # `hex(wire_id)` ended `0D`; stripping that byte and resending produced
  # `push.ack … stored`. So the assertion is on the same bytes, in the same
  # column, and NOT shared with the blob -- one assertion covering both values
  # would hide a regression in either.
  push_fixture
  local bin; bin="$(stub_jq_crlf_without_b)"
  # RUN IN THIS SHELL. `storage_sync_prepare_push` is a function that
  # `agmsg_storage_load` defines here; a `bash -c` child does not have it, and
  # invoking it there reports "command not found" rather than exercising the
  # driver. Measured: status 127 from the child, which is what the first draft
  # of this case was actually observing.
  local saved_path="$PATH"
  PATH="$bin:$PATH"
  printf '%s\n' "$PREPARE" \
    | storage_sync_prepare_push demo "$SERVER_ID" "$TEAM_ID" 1 100 >/dev/null
  PATH="$saved_path"

  local hex; hex="$(staged_hex wire_id)"
  [ -n "$hex" ]
  refute grep -qi '0D$' <<< "$hex"
}

@test "sync: a CRLF jq does not put a trailing CR on the staged blob (#829)" {
  # The other half, asserted separately and deliberately: the two values leave
  # two different final-stage jq calls, so they are two contracts.
  push_fixture
  local bin; bin="$(stub_jq_crlf_without_b)"
  # RUN IN THIS SHELL. `storage_sync_prepare_push` is a function that
  # `agmsg_storage_load` defines here; a `bash -c` child does not have it, and
  # invoking it there reports "command not found" rather than exercising the
  # driver. Measured: status 127 from the child, which is what the first draft
  # of this case was actually observing.
  local saved_path="$PATH"
  PATH="$bin:$PATH"
  printf '%s\n' "$PREPARE" \
    | storage_sync_prepare_push demo "$SERVER_ID" "$TEAM_ID" 1 100 >/dev/null
  PATH="$saved_path"

  local hex; hex="$(staged_hex blob)"
  [ -n "$hex" ]
  refute grep -qi '0D$' <<< "$hex"
}

# A jq that prints the right bytes and then fails. Both halves of the contract
# are required: LF-terminated output AND a jq that completed.
stub_jq_clean_but_failing() {
  local bin="$TEST_SKILL_DIR/jq-clean-fail"
  mkdir -p "$bin"
  cat > "$bin/jq" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in -b|-b*) printf 'agmsg-probe\n'; exit 3 ;;
  esac
done
exec "$(command -v jq)" "\$@"
STUB
  chmod +x "$bin/jq"
  printf '%s' "$bin"
}

@test "sync: a jq that prints clean bytes and then fails is refused too (#829)" {
  # THE OTHER HALF OF THE CONTRACT. Reading the sentinel proves the bytes; it
  # does not prove jq finished. Observed through a process substitution the exit
  # status is unreachable, and a jq that wrote the right line and exited 3 was
  # cached as usable (raised in review).
  local bin; bin="$(stub_jq_clean_but_failing)"

  run env PATH="$bin:$PATH" bash -c '
    . "$1/drivers/storage/sqlite-sync.sh"
    _sqlite_sync_require_jq_binary
  ' _ "$SCRIPTS"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'requires a jq whose -b (binary output) produces LF-terminated lines'
}

@test "sync: the second refusal in one shell says it too (#829)" {
  # A CACHED NO USED TO BE SILENT. The result is cached because probing costs a
  # process, but the engine retries on its cycle: the first attempt explained
  # itself and every attempt after it failed without a word, so the explanation
  # scrolled away and never came back.
  local bin; bin="$(stub_jq_without_b)"

  # NO PIPELINE. Piping each call into `sed` put it in a subshell, so the cache
  # set by the first call never reached the second and BOTH ran the uncached
  # path -- the case passed while the cached branch was never entered. Measured:
  # making the cached refusal silent reddened nothing. `{ …; } 2>file` keeps the
  # calls in one shell.
  run env REAL_PATH="$PATH" PATH="$bin:$PATH" bash -c '
    cd "$2"
    . "$1/drivers/storage/sqlite-sync.sh"
    { _sqlite_sync_require_jq_binary; } 2>err1
    { _sqlite_sync_require_jq_binary; } 2>err2
    echo "cached=$_AGMSG_JQ_BINARY_OK"
    echo "first: $(head -1 err1)"
    echo "second: $(head -1 err2)"
  ' _ "$SCRIPTS" "$BATS_TEST_TMPDIR"

  # BOTH, named separately: a control that only counted occurrences would pass
  # on two copies of the first one.
  # The cache really was consulted -- otherwise this proves nothing about the
  # cached branch.
  echo "$output" | grep -q 'cached=no'
  echo "$output" | grep -q 'first: agmsg: sending requires a jq whose -b'
  echo "$output" | grep -q 'second: agmsg: sending requires a jq whose -b'
}

@test "sync: concurrent probes in one process tree do not break each other (#829)" {
  # THE DEFECT AN EARLIER PUSHED HEAD CARRIED -- never landed, never released.
  # That head's probe wrote jq's output to
  # `${TMPDIR}/agmsg-jq-probe.$$`. Inside a subshell `$$` is the PARENT's pid, so
  # concurrent sealers in one process tree shared that path: one removed the file
  # while another was still reading it, the read failed, and a perfectly good jq
  # was refused. `concurrent age-v1 sealers publish one transaction winner`
  # turned red on it in CI.
  #
  # Same shape as the `$$` reasoning that was already wrong once in #804. The
  # probe carries no shared name now, and this holds it there.
  run bash -c '
    . "$1/drivers/storage/sqlite-sync.sh"
    rc=0
    for _ in 1 2 3 4 5 6 7 8; do
      ( _sqlite_sync_require_jq_binary ) || rc=1 &
    done
    wait
    exit "$rc"
  ' _ "$SCRIPTS"

  # Every one of them accepted the same real jq. A shared path shows up here as
  # an intermittent refusal, which is what it did on the runner.
  [ "$status" -eq 0 ]
  # And nothing was said, because nothing was wrong.
  [ -z "$output" ]
}

# A jq that adds CR to the values this driver READS back, and only to those.
#
# The stub above is scoped to `@tsv` because that is where #829's field report
# measured the CR -- on the send path. #968 is the other direction: `roster_seqs`
# arrives from the server and is read back through a plain `jq -r`, and the CR
# rides into `_sqlite_sync_sequence`, which refuses it as non-canonical.
#
# Scoped for the same reason the other one is, and the restriction is again the
# honest part: a stub that CR-terminated every line would also poison
# `min_available_seq`, `current_seq` and the member ids in this same function, so
# a failure could no longer be attributed to the read path under test. Filters
# naming `roster_seqs` are exactly the two calls that carry #968's value.
stub_jq_crlf_on_read() {
  local bin="$TEST_SKILL_DIR/jq-crlf-read"
  mkdir -p "$bin"
  cat > "$bin/jq" <<STUB
#!/usr/bin/env bash
real="$(command -v jq)"
for a in "\$@"; do
  case "\$a" in -b|-b*) exec "\$real" "\$@" ;; esac
done
roster=0
for a in "\$@"; do
  case "\$a" in *roster_seqs*) roster=1 ;; esac
done
if [ "\$roster" = 1 ]; then
  "\$real" "\$@" | sed 's/\$/\r/'
  exit "\${PIPESTATUS[0]}"
fi
exec "\$real" "\$@"
STUB
  chmod +x "$bin/jq"
  printf '%s' "$bin"
}

@test "sync: a CRLF jq does not put a trailing CR on a value read back (#968)" {
  # THE READ PATH, WHICH #829's FIX DID NOT COVER.
  #
  # #829 put `-b` on the three call sites that SEND. `roster_seqs` is read back
  # from the server through a call that had none, so the CR reached
  # `_sqlite_sync_sequence` and the driver refused its own server's answer. The
  # wrapper is what makes that unreachable: a read path cannot lose `-b` because
  # it never spells out `jq`.
  #
  # This case fails if it ever can again -- remove `-b` from `_sqlite_sync_jq`,
  # or reintroduce a bare `jq` on this path, and the CR comes back.
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store-read"
  export AGMSG_STORAGE_DRIVER=sqlite
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init demo >/dev/null

  local context
  context=$(jq -nc --arg member "018f3f7e-0000-7000-8000-000000000010" '
    {type:"sync_read_context",min_available_seq:"0",current_seq:"2",
     local_agents:["bob"],members:[{member_id:$member,name:"bob"}],
     roster_seqs:["1","2"]}')

  local bin; bin="$(stub_jq_crlf_on_read)"
  # RUN IN THIS SHELL, for the same reason the two cases above do: the driver's
  # functions are defined here by `agmsg_storage_load` and a `bash -c` child
  # would report "command not found" instead of exercising them.
  local saved_path="$PATH" status_seen=0
  PATH="$bin:$PATH"
  printf '%s\n' "$context" \
    | storage_sync_prepare_read_state demo \
        018f3f7e-0000-7000-8000-000000000000 \
        018f3f7e-0000-7000-8000-000000000001 1 >/dev/null 2>"$BATS_TEST_TMPDIR/read.err" \
    || status_seen=$?
  PATH="$saved_path"

  # ON THE VALUE, NOT MERELY ON THE EXIT CODE. A driver that refused this
  # context for some unrelated reason would also be non-zero, so the refusal
  # #968 names is what is asserted absent.
  refute grep -q "is not a canonical sequence (#968)" "$BATS_TEST_TMPDIR/read.err"
  refute grep -q "roster_seqs is not a list of at most 10000 canonical sequences (#968)" \
    "$BATS_TEST_TMPDIR/read.err"
  [ "$status_seen" -eq 0 ]
}

@test "sync: a missing node still answers 10, even when the jq also lacks -b (#829)" {
  # TWO REFUSALS, AND THE ORDER BETWEEN THEM IS A CONTRACT.
  #
  # `storage_sync_resync` answers 10 for "no node, no strict parser" and 13 for
  # everything else, and callers tell those apart. Resolving the jq capability at
  # function scope -- which every other entry in this driver now does, to stop
  # re-probing in each `$( )` subshell -- puts a second refusal in front of that
  # one. Placed first it outranks the 10: measured 13 where the caller expects
  # 10, with a node that is absent and a jq that happens to lack `-b`.
  #
  # So in this one function the gate sits after the node check. This case is what
  # holds it there; move it back above `command -v "$node_bin"` and this reddens.
  local bin; bin="$(stub_jq_without_b)"

  run env REAL_PATH="$PATH" PATH="$bin:$PATH" \
      AGMSG_SYNC_NODE_BIN=/nonexistent-node-binary bash -c '
    export SKILL_DIR="$2" AGMSG_STORAGE_PATH="$3" AGMSG_STORAGE_DRIVER=sqlite
    . "$1/lib/storage.sh"; agmsg_storage_load
    storage_init demo >/dev/null 2>&1
    printf "" | storage_sync_resync demo \
      018f3f7e-0000-7000-8000-000000000000 \
      018f3f7e-0000-7000-8000-000000000001 1
  ' _ "$SCRIPTS" "$TEST_SKILL_DIR" "$BATS_TEST_TMPDIR/store-resync"

  # ON THE NUMBER. A non-zero status is not the assertion -- 13 is also non-zero,
  # and 13 is exactly the regression this guards against.
  [ "$status" -eq 10 ]
}
