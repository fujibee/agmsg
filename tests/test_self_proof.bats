#!/usr/bin/env bats

# Is this seat's process structurally bound to this pane? (#1152)
#
# READ THIS BEFORE TRUSTING THE POSITIVE CASE. Every `proved` in this file is
# built on a SYNTHETIC process tree. That is deliberate and it is also a
# limitation: as of writing, the seat running these tests cannot produce a live
# `proved` -- its own lineage is `claude bg-spare` -> `claude bg-pty-host` ->
# launchd and reaches no pane. A synthetic positive proves the CONTRACT (that the
# classifier says `proved` when the intersection is there); it is NOT evidence
# that any particular seat can obtain one. Those are different claims and this
# file only makes the first.

setup() {
  load 'test_helper'
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"

  PS_TREE="$BATS_TEST_TMPDIR/tree"; : > "$PS_TREE"; export PS_TREE
  PS_FAIL_FOR=""; export PS_FAIL_FOR
  PS_FAIL_PPID_FOR=""; export PS_FAIL_PPID_FOR
  PS_START="$BATS_TEST_TMPDIR/start"; : > "$PS_START"; export PS_START
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/ps" <<'PSEOF'
#!/usr/bin/env bash
# A process table that the test writes. Only the two forms this code uses.
field=""; pid=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field="$2"; shift 2 ;;
    -p) pid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
for bad in $PS_FAIL_FOR; do [ "$bad" = "$pid" ] && exit 1; done
case "$field" in
  ppid=)
    for bad in ${PS_FAIL_PPID_FOR:-}; do [ "$bad" = "$pid" ] && exit 1; done
    awk -F'\t' -v p="$pid" '$1 == p { print " " $2; found=1 } END { exit !found }' "$PS_TREE" ;;
  lstart=) awk -F'\t' -v p="$pid" '$1 == p { print $2; found=1 } END { exit !found }' "$PS_START" ;;
  *) exit 1 ;;
esac
PSEOF
  chmod +x "$BATS_TEST_TMPDIR/bin/ps"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/instance-id.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/self-identity.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/self-proof.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
  # Load the driver for real: its `terminal_id_ok` is what revalidates the ref,
  # and setting _AGMSG_TERMINAL_LOADED by hand without it made the revalidation
  # accept anything (the registry accepts every id for a loaded driver that
  # declares no grammar). A fixture that skips the load tests a laxer system
  # than the one that ships.
  agmsg_terminal_load herdr

  # The owner pid must be a REAL live process: the proof verifies the recorded
  # owner with agmsg_instance_alive, which asks the kernel and not the fake `ps`.
  # A synthetic owner would make every test answer `owner_not_alive` -- the right
  # answer to the wrong question.
  sleep 600 &
  OWNER_PID=$!
  PANE_PID=800
  _edge "$$" "$OWNER_PID"
  _edge "$OWNER_PID" "$PANE_PID"
  _edge "$PANE_PID" 1
  for _p in "$PANE_PID" 777 654 80 800; do _start "$_p" "Mon Jan  1 00:00:00 2020"; done
  _own "agmsg" "seat" "sid-1.$OWNER_PID"
  # A live session has its instance marker; the proof requires it (#1187).
  mkdir -p "$SKILL_DIR/run"
  printf 'sid-1.%s\n' "$OWNER_PID" > "$SKILL_DIR/run/cc-instance.$OWNER_PID"
  _driver_returns "w1:p9	$PANE_PID"

  # THE CALLER'S SHELL STATE, applied last so it is in force for the test body.
  # Two defects on this branch came from a caller's option -- `nocasematch`
  # widening a `case`, and `set -e` killing the shell at a status capture before
  # the verdict was printed -- and BOTH passed a suite that ran with the
  # defaults. The suite reruns itself under each state; see the last test.
  local tok
  for tok in ${AGMSG_CALLER_SHELL_STATE:-}; do
    case "$tok" in
      errexit|nounset|pipefail) set -o "$tok" ;;
      nocasematch|extglob)      shopt -s "$tok" ;;
      *) echo "unknown caller shell state: $tok"; return 1 ;;
    esac
  done
}
teardown() {
  [ -z "${OWNER_PID:-}" ] || kill "$OWNER_PID" 2>/dev/null || true
  teardown_test_env
}
_start() { printf '%s\t%s\n' "$1" "$2" >> "$PS_START"; }

_edge() { printf '%s\t%s\n' "$1" "$2" >> "$PS_TREE"; }
_own() {   # <team> <agent> <owner-token>
  local f; f="$(actas_lock_path "$1" "$2")"
  mkdir -p "${f%/*}"
  printf '%s\n' "$3" > "$f"
}
# Replace the driver op with one that hands back a fixed record.
_driver_returns() {
  FAKE_DRIVER_SRC='terminal_pane_process_observe() { printf "%s\n" '"$(printf '%q' "$1")"'; }'
  eval "$FAKE_DRIVER_SRC"
}
_driver_fails() {   # <rc>
  FAKE_DRIVER_SRC="terminal_pane_process_observe() { return $1; }"
  eval "$FAKE_DRIVER_SRC"
}

# --- the four states -----------------------------------------------------------

@test "proved: the pane's process is in the owner's ancestry (SYNTHETIC tree) (#1152)" {
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 0 ]
  [ "$output" = "proved"$'\t'"herdr:w1:p9" ]
}

@test "disproved: it is not, and the observation was whole (#1152)" {
  _driver_returns "w1:p9	777"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 1 ]
  [ "$output" = "disproved"$'\t'"pane_process_not_ancestor" ]
}

@test "a second pane, in the same run, is disproved while the first is proved (#1152)" {
  # The negative control has to come out of the SAME observation as the positive:
  # a proof machine that answered `proved` for everything would pass a suite that
  # only ever showed it the right pane.
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 0 ]
  _driver_returns "w1:pX	654"
  run agmsg_self_proof agmsg seat w1:pX
  [ "$status" -eq 1 ]
  [ "$output" = "disproved"$'\t'"pane_process_not_ancestor" ]
}

@test "unsupported: a driver with no process op is not a driver that failed (#1152)" {
  unset -f terminal_pane_process_observe
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 3 ]
  [ "$output" = "unsupported"$'\t'"driver_no_process_binding" ]
}

# --- an incomplete walk is never a negative ------------------------------------

@test "a walk that could not finish is undetermined, NOT disproved (#1152)" {
  # The axis that would be silently wrong. A `ps` that fails part way up produces
  # an empty intersection that looks exactly like a real absence.
  PS_FAIL_PPID_FOR="$PANE_PID"; export PS_FAIL_PPID_FOR
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"ancestry_truncated" ]
  [ "$output" != "disproved"$'\t'"pane_process_not_ancestor" ]
}

@test "a parent that is not a pid truncates rather than terminating the walk (#1152)" {
  : > "$PS_TREE"
  _edge "$$" "$OWNER_PID"
  _edge "$OWNER_PID" "not-a-pid"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"ancestry_truncated" ]
}

@test "a cycle is undetermined, and is not read as reaching the top (#1152)" {
  : > "$PS_TREE"
  _edge "$$" "$OWNER_PID"
  _edge "$OWNER_PID" 901
  _edge 901 "$OWNER_PID"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"ancestry_cycle" ]
}

@test "a chain past the bound is undetermined, not a short ancestry (#1152)" {
  : > "$PS_TREE"
  _edge "$$" "$OWNER_PID"
  local p="$OWNER_PID" i=0
  while [ "$i" -lt 12 ]; do _edge "$p" "$((1000 + i))"; p="$((1000 + i))"; i=$((i + 1)); done
  _AGMSG_PROOF_ANCESTRY_MAX=5
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"ancestry_limit" ]
}

@test "pid 1 ends the walk on its own, without reading its parent (#1152)" {
  # `ps` is made to FAIL for pid 1: a walk that asked would truncate here, and
  # every proof on this machine would become undetermined.
  PS_FAIL_FOR="1"; export PS_FAIL_FOR
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 0 ]
  [ "$output" = "proved"$'\t'"herdr:w1:p9" ]
}

# --- the root is the recorded owner, not the caller and not $$ -----------------

@test "an invocation outside the recorded owner cannot prove anything (#1152)" {
  # Measured live: a seat's tool invocations can run under a launchd-parented
  # daemon while the recorded owner sits elsewhere. Rooting at the owner without
  # joining the two would answer about a process that only shares a role name.
  : > "$PS_TREE"
  _edge "$$" 700
  _edge 700 1
  _edge "$OWNER_PID" "$PANE_PID"
  _edge "$PANE_PID" 1
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"invocation_not_bound_to_owner" ]
}

@test "owner states are kept apart: absent, unreadable, empty, bare, bad pid (#1152)" {
  local f; f="$(actas_lock_path agmsg seat)"

  rm -f "$f"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]; [ "$output" = "undetermined"$'\t'"owner_absent" ]

  printf '\n' > "$f"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]; [ "$output" = "undetermined"$'\t'"owner_empty" ]

  printf 'sid-only\n' > "$f"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]; [ "$output" = "undetermined"$'\t'"owner_not_composite" ]

  printf 'sid-1.0900\n' > "$f"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]; [ "$output" = "undetermined"$'\t'"owner_pid_invalid" ]

  printf 'sid-1.nope\n' > "$f"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]; [ "$output" = "undetermined"$'\t'"owner_pid_invalid" ]
}

@test "the role changing hands mid-proof is undetermined, not a proof of the old one (#1152)" {
  local f; f="$(actas_lock_path agmsg seat)"
  # The second observation is where the lock is swapped, so the swap lands
  # between the two reads the proof makes.
  eval 'terminal_pane_process_observe() {
          printf "%s\n" "w1:p9	'"$PANE_PID"'"
          printf "%s\n" "sid-2.'"$OWNER_PID"'" > "'"$f"'"
        }'
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"owner_changed" ]
}

# --- the observation is framed, not trusted ------------------------------------

@test "the driver's failure is undetermined, and 13 is told from the rest (#1152)" {
  _driver_fails 10
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]; [ "$output" = "undetermined"$'\t'"pane_process_unreadable" ]
  _driver_fails 13
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]; [ "$output" = "undetermined"$'\t'"candidate_not_well_formed" ]
}

@test "a record this file does not understand is malformed, never a count (#1152)" {
  local bad
  for bad in \
    "w1:p9" \
    "	$PANE_PID" \
    "w1:p9	not-a-pid" \
    "w1:p9	0$PANE_PID" \
    "w1:p9	0" \
    "w1:p9	" \
    "w1:p9	$PANE_PID	$PANE_PID" \
  ; do
    _driver_returns "$bad"
    run agmsg_self_proof agmsg seat w1:p9
    [ "$status" -eq 2 ] || { echo "accepted a malformed record: [$bad] -> $output"; return 1; }
    [ "$output" = "undetermined"$'\t'"observation_malformed" ] \
      || { echo "wrong reason for [$bad]: $output"; return 1; }
  done
  # Not vacuous: the well-formed record still passes.
  _driver_returns "w1:p9	$PANE_PID"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 0 ]
}

@test "a second line in the record is malformed, not a first line with extra (#1152)" {
  _driver_returns "w1:p9	$PANE_PID
w1:pX	$PANE_PID"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"observation_malformed" ]
}

@test "a control byte in the record is malformed (#1152)" {
  _driver_returns "w1:$(printf '\001')p9	$PANE_PID"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"observation_malformed" ]
}

@test "the pane changing between the two looks is undetermined (#1152)" {
  local c="$BATS_TEST_TMPDIR/calls"; : > "$c"
  eval 'terminal_pane_process_observe() {
          printf "x\n" >> "'"$c"'"
          if [ "$(wc -l < "'"$c"'" | tr -d " ")" = 1 ]; then
            printf "%s\n" "w1:p9	'"$PANE_PID"'"
          else
            printf "%s\n" "w1:p9	777"
          fi
        }'
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"snapshot_changed" ]
}

@test "a reused pid is a DIFFERENT process, though the record is identical (#1152)" {
  # This is the case a record of bare pids cannot see: the pane process exits
  # between the two looks and its number is handed to something else. Both
  # records read `w1:p9<TAB>800`. Only the process start time says they are not
  # the same process -- which is why the comparison is over (pid, start) pairs
  # and not over the record.
  local c="$BATS_TEST_TMPDIR/calls2"; : > "$c"
  eval 'terminal_pane_process_observe() {
          printf "x\n" >> "'"$c"'"
          if [ "$(wc -l < "'"$c"'" | tr -d " ")" != 1 ]; then
            printf "%s\t%s\n" "'"$PANE_PID"'" "Tue Feb  2 00:00:00 2021" > "'"$PS_START"'"
          fi
          printf "%s\n" "w1:p9	'"$PANE_PID"'"
        }'
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"snapshot_changed" ]
}

# --- the candidate is a scope, not an authority --------------------------------

@test "the ref that comes back is the DRIVER's observation, not the caller's input (#1152)" {
  # A caller that got its own string back would read its own input as a
  # confirmation. The driver here answers about a different pane than the one
  # asked for, and the proof reports the driver's.
  _driver_returns "w1:pREAL	$PANE_PID"
  run agmsg_self_proof agmsg seat w1:pASKED
  [ "$status" -eq 0 ]
  [ "$output" = "proved"$'\t'"herdr:w1:pREAL" ]
  case "$output" in *pASKED*) echo "the caller's candidate came back"; return 1 ;; esac
}

@test "a canonical ref that fails the shared grammar is undetermined, not proved (#1152)" {
  _driver_returns "not a pane id	$PANE_PID"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"canonical_ref_invalid" ]
}

@test "with no driver loaded there is no terminal to qualify the ref with (#1152)" {
  _AGMSG_TERMINAL_LOADED=""
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"no_driver_loaded" ]
}

@test "a missing role name is undetermined, never a proof about some other role (#1152)" {
  run agmsg_self_proof "" seat w1:p9
  [ "$status" -eq 2 ]; [ "$output" = "undetermined"$'\t'"role_not_named" ]
  run agmsg_self_proof agmsg "" w1:p9
  [ "$status" -eq 2 ]; [ "$output" = "undetermined"$'\t'"role_not_named" ]
  run agmsg_self_proof agmsg seat ""
  [ "$status" -eq 2 ]; [ "$output" = "undetermined"$'\t'"no_candidate" ]
}

# --- the contract itself -------------------------------------------------------

@test "every answer is one line of state<TAB>payload, and the rc agrees with it (#1152)" {
  # DERIVED: the outcomes are produced by exercising the paths, and the shape is
  # checked on whatever comes out -- not against a list of states written here.
  local f; f="$(actas_lock_path agmsg seat)"
  local outs=0
  _check() {
    local out="$1" st="$2" state
    [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" -eq 0 ] || { echo "more than one line: [$out]"; return 1; }
    state="${out%%$'\t'*}"
    [ "$state" != "$out" ] || { echo "no payload: [$out]"; return 1; }
    case "$state" in
      proved)       [ "$st" -eq 0 ] || { echo "proved with rc $st"; return 1; } ;;
      disproved)    [ "$st" -eq 1 ] || { echo "disproved with rc $st"; return 1; } ;;
      undetermined) [ "$st" -eq 2 ] || { echo "undetermined with rc $st"; return 1; } ;;
      unsupported)  [ "$st" -eq 3 ] || { echo "unsupported with rc $st"; return 1; } ;;
      *) echo "not one of the four states: [$state]"; return 1 ;;
    esac
    outs=$((outs + 1))
  }
  run agmsg_self_proof agmsg seat w1:p9;          _check "$output" "$status"
  _driver_returns "w1:p9	777"
  run agmsg_self_proof agmsg seat w1:p9;          _check "$output" "$status"
  _driver_fails 10
  run agmsg_self_proof agmsg seat w1:p9;          _check "$output" "$status"
  rm -f "$f"
  run agmsg_self_proof agmsg seat w1:p9;          _check "$output" "$status"
  unset -f terminal_pane_process_observe
  run agmsg_self_proof agmsg seat w1:p9;          _check "$output" "$status"
  # All four states really were produced, so the loop above was not four passes
  # through one branch.
  [ "$outs" -eq 5 ]
}

@test "NOTHING but proved exits 0 -- checked over every reason in the file (#1152)" {
  # The permission rule: a caller decides on `proved` and on nothing else. A
  # reason word exists for diagnostics, and a reason that could carry rc 0 would
  # be a second way to earn a write.
  local src="$SKILL_DIR/scripts/lib/self-proof.sh" reasons n=0 r
  reasons="$(grep -v '^[[:space:]]*#' "$src" \
             | grep -oE '_agmsg_proof_say (disproved|undetermined|unsupported) [a-z_]+ [0-9]' \
             | awk '{print $3"\t"$4}' | sort -u)"
  [ -n "$reasons" ] || { echo "derived no reasons -- the scan is broken"; return 1; }
  while IFS=$'\t' read -r r rc; do
    [ -n "$r" ] || continue
    [ "$rc" -ne 0 ] || { echo "reason $r would exit 0"; return 1; }
    n=$((n + 1))
  done <<< "$reasons"
  [ "$n" -ge 10 ] || { echo "only $n reasons found; the scan is probably not reading the code"; return 1; }
}

@test "no driver produces a state word -- the classifier lives in one file (#1152)" {
  # DERIVED over every driver in the tree, not a list of the three that exist
  # today. A driver that answered `proved` would be a second classifier, and two
  # classifiers for one question is how the same lock came to be `free` in one
  # place and `unknown` in another (#1071).
  #
  # SCOPED TO THE OP, not to the whole file: `unsupported` is an older word in
  # these drivers with an unrelated meaning (arrange and spawn print it for a
  # target they do not handle). Scanning the file flagged eight of those and said
  # nothing about the op -- a check whose population is wider than its claim.
  local d found=0 body hits
  for d in "$SKILL_DIR"/scripts/drivers/terminals/*/ops.sh; do
    [ -f "$d" ] || continue
    found=$((found + 1))
    body="$(awk '/^terminal_pane_process_observe\(\)/,/^}/' "$d" | grep -v '^[[:space:]]*#' || true)"
    [ -n "$body" ] || continue      # a driver without the op says nothing at all
    hits="$(printf '%s\n' "$body" | grep -nE '(proved|disproved|undetermined|unsupported)' || true)"
    [ -z "$hits" ] || { echo "$d states a verdict inside the op:"; printf '%s\n' "$hits"; return 1; }
  done
  [ "$found" -ge 3 ] || { echo "scanned only $found drivers"; return 1; }
}

@test "a driver that can observe but declares no id grammar is unsupported (#1152)" {
  # The revalidation is only as strong as the loaded driver's grammar, and the
  # registry accepts EVERY id for a driver that declares none. Without this the
  # canonical ref would be checked by a validator that cannot say no.
  unset -f terminal_id_ok
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 3 ]
  [ "$output" = "unsupported"$'\t'"driver_no_ref_grammar" ]
}

@test "a ps failure ABOVE the owner does not unbind the invocation (#1152)" {
  # The binding is settled once the owner appears in the chain. Reading the
  # walk's status BEFORE the membership test made a failure in a part of the
  # tree this question does not care about report the seat as unbound -- and
  # `not bound` and `could not tell` are different answers.
  : > "$PS_TREE"
  _edge "$$" "$OWNER_PID"
  _edge "$OWNER_PID" "$PANE_PID"
  _edge "$PANE_PID" 1
  # The owner walk still needs the chain; only the INVOCATION walk is made to
  # fail past the owner, by starting it at a pid whose parent chain is broken
  # only above OWNER_PID.
  _edge 1 2                    # a parent for pid 1 that ps will refuse
  PS_FAIL_FOR=""; export PS_FAIL_FOR
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 0 ]
  [ "$output" = "proved"$'\t'"herdr:w1:p9" ]
}

@test "an owner missing from a chain we could not finish is undetermined, not unbound (#1152)" {
  : > "$PS_TREE"
  _edge "$$" 700       # 700's parent is unreadable, and the owner is not below
  _edge "$OWNER_PID" "$PANE_PID"
  _edge "$PANE_PID" 1
  PS_FAIL_FOR="700"; export PS_FAIL_FOR
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"invocation_ancestry_truncated" ]
}

@test "a pid is matched whole: 80 is not a hit inside 800 (#1152)" {
  # The intersection is between two lists of pids. A substring test -- the
  # obvious `case " $list " in *"$p"*)` -- would find 80 inside 800 and hand out
  # a proof for a pane whose process this seat has never been near.
  _driver_returns "w1:p9	80"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 1 ]
  [ "$output" = "disproved"$'\t'"pane_process_not_ancestor" ]
  # Not vacuous: 800 IS in the ancestry, so the list really does contain the
  # string this test is checking is not matched loosely.
  _driver_returns "w1:p9	800"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 0 ]
}

@test "the FIRST observation is framed on its own terms, not by the comparison (#1152)" {
  # Measured: deleting the framing of the first record reddened NOTHING -- the
  # second record is framed too, and a malformed first one then failed the
  # before/after comparison instead. Same permission, different reason, and a
  # reason that names the wrong thing is what a caller reads when it asks why.
  # So the first record is rejected for BEING malformed, in a run where the
  # second one is fine.
  local c="$BATS_TEST_TMPDIR/calls3"; : > "$c"
  eval 'terminal_pane_process_observe() {
          printf "x\n" >> "'"$c"'"
          if [ "$(wc -l < "'"$c"'" | tr -d " ")" = 1 ]; then
            printf "%s\n" "w1:p9	not-a-pid"
          else
            printf "%s\n" "w1:p9	'"$PANE_PID"'"
          fi
        }'
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"observation_malformed" ]
  [ "$output" != "undetermined"$'\t'"snapshot_changed" ]
}

# --- the recorded owner is verified, not just parsed ---------------------------

@test "an owner whose process is gone is undetermined, not a proof about it (#1152)" {
  # A lock outlives the process that wrote it. Parsing a pid out of the file says
  # the file holds a number, not that the number is still this session.
  sleep 60 & local dead=$!
  kill "$dead" 2>/dev/null; wait "$dead" 2>/dev/null || true
  # The precondition is that the pid is GONE. On a loaded runner the number can
  # be handed to a new process between the wait and the read below (#1187,
  # seen twice on macOS); then this test is not measuring what it says, and a
  # red here would be about the fixture, not the classifier. Say so and skip.
  if kill -0 "$dead" 2>/dev/null; then skip "pid $dead was reused by another process before the read (#1187)"; fi
  _own agmsg seat "sid-1.$dead"
  _edge "$$" "$dead"; _edge "$dead" "$PANE_PID"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"owner_not_alive" ]
}

@test "an owner pid that is alive but has NO instance marker is undetermined, never a proof (#1187)" {
  # The dangerous shape behind #1187: a pid that is alive because it was REUSED,
  # with the session's marker gone (cleaned at its end, or never written). The
  # lock reclaim reads an absent marker as alive-by-default, which is the
  # conservative side THERE; here the same default would take a stranger's
  # process for the owner and, with a complete ancestry, prove it into whatever
  # pane the stranger sits in. Measured 2026-09-13: before the fix this fixture
  # returned proved. The proof therefore requires positive identity: no marker,
  # no proof.
  sleep 60 & local stranger=$!
  _own agmsg seat "sid-1.$stranger"
  rm -f "$SKILL_DIR/run/cc-instance.$stranger"
  : > "$PS_TREE"
  _edge "$$" "$stranger"; _edge "$stranger" "$PANE_PID"; _edge "$PANE_PID" 1
  _driver_returns "w1:p9	$PANE_PID"
  run agmsg_self_proof agmsg seat w1:p9
  kill "$stranger" 2>/dev/null; wait "$stranger" 2>/dev/null || true
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"owner_marker_absent" ]
}

@test "a REUSED owner pid is caught by the instance marker, not by liveness (#1152)" {
  # The dangerous shape: the pid is alive, because it now belongs to something
  # else. `kill -0` says yes. Only the instance marker says the process behind
  # the number is not the session the lock names -- and without this the seat
  # would be walked from a stranger's process, and proved into whatever pane that
  # stranger happens to sit in.
  mkdir -p "$SKILL_DIR/run"
  printf 'a-completely-different-session.%s\n' "$OWNER_PID" > "$SKILL_DIR/run/cc-instance.$OWNER_PID"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"owner_not_alive" ]
  # Not vacuous: with the marker naming this owner, the same call proves.
  printf 'sid-1.%s\n' "$OWNER_PID" > "$SKILL_DIR/run/cc-instance.$OWNER_PID"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 0 ]
}

@test "a half-written instance marker is 'cannot tell', not dead and not alive (#1152)" {
  mkdir -p "$SKILL_DIR/run"
  : > "$SKILL_DIR/run/cc-instance.$OWNER_PID"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"owner_liveness_unknown" ]
  [ "$output" != "undetermined"$'\t'"owner_not_alive" ]
}

# --- a pid is only a name while its process lives ------------------------------

@test "a pid whose process start cannot be read makes the observation unusable (#1152)" {
  # NO FALLBACK. An earlier revision degraded a missing start token to `-` and
  # went on to answer proved or disproved -- a verdict resting on the one fact it
  # had failed to obtain.
  : > "$PS_START"          # no start times for anybody
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"process_identity_unreadable" ]
  [ "$output" != "proved"$'\t'"herdr:w1:p9" ]
  [ "$output" != "disproved"$'\t'"pane_process_not_ancestor" ]
}

@test "one unreadable start among several fails the whole observation (#1152)" {
  # Not "the ones we could read": a partial set wearing the shape of a complete
  # one is the failure this file refuses everywhere else. 999 is in the record
  # and has no start time to be had.
  _driver_returns "w1:p9	$PANE_PID	999"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"process_identity_unreadable" ]
  # Not vacuous: with 999's start readable, the same record proves.
  _start 999 "Mon Jan  1 00:00:00 2020"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 0 ]
}

# --- the caller's shell state ---------------------------------------------------

# Run the proof in a REAL shell that has the given `set`/`shopt` state, as a bare
# statement -- not through bats' `run`, and not on the left of `&&`/`||`.
#
# MEASURED, and it is the whole reason this helper exists: with `set -e` applied
# in `setup()` and the call made through `run`, reverting an errexit-safe capture
# to the defective `x="$(cmd)"; rc=$?` produced ZERO reds. bats' `run` turns
# errexit off for the command it invokes, and so does putting the call on the
# left of `&&` or `||`. Both of the obvious ways to write this test are therefore
# blind to the defect the test is FOR. A caller that simply calls the function
# is not, so that is what this runs.
#
# WHAT THE DIFFERENCE ACTUALLY LOOKS LIKE. Under a caller's errexit, a function
# that returns non-zero as a bare statement kills that caller -- correct code and
# defective code alike. So the child dying is NOT the signal. The signal is
# whether the verdict reached stdout first:
#
#   correct    the verdict line is printed, then the caller dies on the status
#   defective  the shell dies inside the capture, and there is NO verdict line
#
# So the probe reads stdout and the exit status, and never requires the child to
# have survived a non-zero verdict.
_proof_in_a_real_shell() {   # <shell-state> <team> <agent> <candidate>
  local state="$1" team="$2" agent="$3" cand="$4"
  local script="$BATS_TEST_TMPDIR/real.sh"
  cat > "$script" <<'RSEOF'
for tok in $AGMSG_STATE; do
  case "$tok" in
    errexit|nounset|pipefail) set -o "$tok" ;;
    nocasematch|extglob)      shopt -s "$tok" ;;
  esac
done
# This shell has its own pid, so give the fake process table an edge from it to
# the owner -- otherwise the invocation is unbound and every answer is the same.
printf '%s\t%s\n' "$$" "$AGMSG_OWNER_PID" >> "$PS_TREE"
. "$SKILL_DIR/scripts/lib/instance-id.sh"
. "$SKILL_DIR/scripts/lib/actas-lock.sh"
. "$SKILL_DIR/scripts/lib/self-identity.sh"
. "$SKILL_DIR/scripts/lib/self-proof.sh"
. "$SKILL_DIR/scripts/lib/terminal-registry.sh"
agmsg_terminal_load herdr
eval "$AGMSG_FAKE_DRIVER"
agmsg_self_proof "$1" "$2" "$3"
printf '__rc=%s\n' "$?"
RSEOF
  AGMSG_STATE="$state" AGMSG_OWNER_PID="$OWNER_PID" \
  AGMSG_FAKE_DRIVER="${FAKE_DRIVER_SRC:-}" \
    bash "$script" "$team" "$agent" "$cand" 2>/dev/null
}

@test "set -e in the CALLER still gets exactly one verdict, from every producer (#1152)" {
  # The defect this exists for: `x="$(cmd)"; rc=$?` exits the shell under a
  # caller's errexit BEFORE the verdict line is printed, so the contract ("always
  # exactly one line") breaks silently for truncated / cycle / limit / driver
  # failure. Each non-zero producer is driven here in a shell that really has it.
  local out st
  _expect() {   # <output> <verdict> <rc>
    local o="$1" want="$2" want_rc="$3" got_st="$4" v
    v="$(printf '%s\n' "$o" | grep -v '^__rc=')"
    [ "$v" = "$want" ] || { echo "verdict was [$v], wanted [$want]"; return 1; }
    [ "$got_st" = "$want_rc" ] || { echo "exit was [$got_st], wanted [$want_rc]"; return 1; }
    # A zero verdict means the caller survives, so the trailing line must be
    # there too -- proof that the function RETURNED rather than the shell dying
    # on something after the verdict.
    if [ "$want_rc" = 0 ]; then
      [ "$(printf '%s\n' "$o" | grep -c '^__rc=0')" = 1 ] \
        || { echo "proved but the caller did not survive"; return 1; }
    fi
  }

  PS_FAIL_PPID_FOR="$PANE_PID"; export PS_FAIL_PPID_FOR
  out="$(_proof_in_a_real_shell errexit agmsg seat w1:p9)" && st=0 || st=$?
  _expect "$out" "undetermined"$'\t'"ancestry_truncated" 2 "$st"
  PS_FAIL_PPID_FOR=""; export PS_FAIL_PPID_FOR

  _driver_fails 10
  out="$(_proof_in_a_real_shell errexit agmsg seat w1:p9)" && st=0 || st=$?
  _expect "$out" "undetermined"$'\t'"pane_process_unreadable" 2 "$st"

  _driver_fails 13
  out="$(_proof_in_a_real_shell errexit agmsg seat w1:p9)" && st=0 || st=$?
  _expect "$out" "undetermined"$'\t'"candidate_not_well_formed" 2 "$st"

  : > "$PS_TREE"
  _edge "$OWNER_PID" 901; _edge 901 "$OWNER_PID"
  _driver_returns "w1:p9	$PANE_PID"
  out="$(_proof_in_a_real_shell errexit agmsg seat w1:p9)" && st=0 || st=$?
  _expect "$out" "undetermined"$'\t'"ancestry_cycle" 2 "$st"

  # Not vacuous: the ordinary path is still a proof in the same real shell.
  : > "$PS_TREE"
  _edge "$OWNER_PID" "$PANE_PID"; _edge "$PANE_PID" 1
  out="$(_proof_in_a_real_shell errexit agmsg seat w1:p9)" && st=0 || st=$?
  _expect "$out" "proved"$'\t'"herdr:w1:p9" 0 "$st"
}

@test "every caller shell state, together, still gets exactly one verdict (#1152)" {
  local out
  local all="errexit nounset pipefail nocasematch extglob" st
  out="$(_proof_in_a_real_shell "$all" agmsg seat w1:p9)" && st=0 || st=$?
  [ "$(printf '%s\n' "$out" | grep -v '^__rc=')" = "proved"$'\t'"herdr:w1:p9" ]
  [ "$st" -eq 0 ]
  [ "$(printf '%s\n' "$out" | grep '^__rc=')" = "__rc=0" ]
  _driver_returns "w1:p9	777"
  out="$(_proof_in_a_real_shell "$all" agmsg seat w1:p9)" && st=0 || st=$?
  [ "$(printf '%s\n' "$out" | grep -v '^__rc=')" = "disproved"$'\t'"pane_process_not_ancestor" ]
  [ "$st" -eq 1 ]
}

@test "the whole suite passes under each caller shell state (#1152)" {
  # THE CLASS, not the two instances. Both defects review found on this branch
  # were the caller's shell state leaking into a sourced file -- `nocasematch`
  # widening a `case`, then `set -e` killing a status capture before the verdict
  # could be printed -- and both passed a suite that ran with the defaults.
  # Rather than wait for a third, the suite reruns ITSELF with those states set.
  #
  # WHAT THIS CANNOT SEE, stated so nobody reads it as covering errexit: bats'
  # `run` turns errexit OFF for the command it invokes, so every test in this
  # file that goes through `run` is blind to an errexit defect no matter what
  # this harness sets. Measured -- reverting a capture to the defective form
  # reddened NOTHING here. The errexit axis is covered by the two tests above,
  # which call the proof in a real shell instead. This harness is for the
  # options `run` does NOT suppress: nocasematch, extglob, nounset, pipefail.
  #
  # ALL OF THEM AT ONCE in the green case, which costs one extra run of this
  # file; only when that goes red does it rerun each state alone, to say WHICH.
  [ -z "${AGMSG_CALLER_SHELL_NEST:-}" ] || skip "inner run"
  local all="errexit nounset pipefail nocasematch extglob"
  local out="$BATS_TEST_TMPDIR/state.all.out"
  if AGMSG_CALLER_SHELL_NEST=1 AGMSG_CALLER_SHELL_STATE="$all" \
     bats "$BATS_TEST_FILENAME" > "$out" 2>&1; then
    return 0
  fi
  echo "the suite is not green with [$all]; narrowing:"
  local st one
  for st in $all; do
    one="$BATS_TEST_TMPDIR/state.$st.out"
    if AGMSG_CALLER_SHELL_NEST=1 AGMSG_CALLER_SHELL_STATE="$st" \
       bats "$BATS_TEST_FILENAME" > "$one" 2>&1; then
      echo "  [$st] green"
    else
      echo "  [$st] RED:"
      grep -A3 '^not ok' "$one" | head -12 | sed 's/^/      /'
    fi
  done
  return 1
}

# --- the herdr observation, at the driver ---------------------------------------
#
# These drive the REAL op with a fake `herdr` binary, because the rule under test
# lives in the op and not in the coordinator: an entry the op cannot read must
# fail the WHOLE observation. A coordinator-level fake would never see it.

_fake_herdr() {   # <json>
  cat > "$BATS_TEST_TMPDIR/bin/herdr" <<HEOF
#!/usr/bin/env bash
cat <<'JSONEOF'
$1
JSONEOF
HEOF
  chmod +x "$BATS_TEST_TMPDIR/bin/herdr"
}

_load_real_herdr_op() {
  unset -f terminal_pane_process_observe
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/drivers/terminals/herdr/ops.sh"
}

@test "herdr: a complete payload is one record, each process once (#1152)" {
  _load_real_herdr_op
  _fake_herdr '{"result":{"process_info":{"pane_id":"w1:p9","shell_pid":11,"foreground_process_group_id":22,"foreground_processes":[{"pid":22},{"pid":33}]}}}'
  run terminal_pane_process_observe w1:p9
  [ "$status" -eq 0 ]
  # 22 is both the group id and one of the processes; the record carries it once.
  [ "$output" = "w1:p9"$'\t'"11"$'\t'"22"$'\t'"33" ]
}

@test "herdr: an entry with no readable pid fails the WHOLE observation (#1152)" {
  # The defect this replaces: the op skipped what it could not read and returned
  # the rest -- a partial set wearing the shape of a complete one. If the skipped
  # entry were the owner's process, the coordinator would answer `disproved`
  # about a pane the seat is actually in.
  _load_real_herdr_op
  _fake_herdr '{"result":{"process_info":{"pane_id":"w1:p9","shell_pid":11,"foreground_process_group_id":22,"foreground_processes":[{"pid":22},{"pid":"not-an-int"},{"pid":33}]}}}'
  run terminal_pane_process_observe w1:p9
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "herdr: a missing or mistyped schema field is no answer, not an empty pane (#1152)" {
  _load_real_herdr_op
  local bad
  for bad in \
    '{"result":{"process_info":{"pane_id":"w1:p9","foreground_process_group_id":22,"foreground_processes":[{"pid":22}]}}}' \
    '{"result":{"process_info":{"pane_id":"w1:p9","shell_pid":"11","foreground_process_group_id":22,"foreground_processes":[{"pid":22}]}}}' \
    '{"result":{"process_info":{"pane_id":"w1:p9","shell_pid":11,"foreground_processes":[{"pid":22}]}}}' \
    '{"result":{"process_info":{"pane_id":"w1:p9","shell_pid":11,"foreground_process_group_id":22,"foreground_processes":"nope"}}}' \
    '{"result":{"process_info":{"pane_id":"w1:p9","shell_pid":0,"foreground_process_group_id":22,"foreground_processes":[{"pid":22}]}}}' \
  ; do
    _fake_herdr "$bad"
    run terminal_pane_process_observe w1:p9
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
  done
}

@test "herdr: an answer about a DIFFERENT pane is no answer (#1152)" {
  # The same rule the tmux op's identity canary enforces. Without it the op would
  # report another pane's processes under the id that was asked for.
  _load_real_herdr_op
  _fake_herdr '{"result":{"process_info":{"pane_id":"w1:pOTHER","shell_pid":11,"foreground_process_group_id":22,"foreground_processes":[{"pid":22}]}}}'
  run terminal_pane_process_observe w1:p9
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # Not vacuous: the same payload naming the pane we asked for is accepted.
  _fake_herdr '{"result":{"process_info":{"pane_id":"w1:p9","shell_pid":11,"foreground_process_group_id":22,"foreground_processes":[{"pid":22}]}}}'
  run terminal_pane_process_observe w1:p9
  [ "$status" -eq 0 ]
}

@test "herdr: a candidate that is not a pane id is told from a pane we cannot reach (#1152)" {
  _load_real_herdr_op
  _fake_herdr '{"result":{"process_info":{"pane_id":"w1:p9","shell_pid":11,"foreground_process_group_id":22,"foreground_processes":[{"pid":22}]}}}'
  run terminal_pane_process_observe 'w1:p9;kill'
  [ "$status" -eq 13 ]
  cat > "$BATS_TEST_TMPDIR/bin/herdr" <<'HEOF'
#!/usr/bin/env bash
exit 1
HEOF
  chmod +x "$BATS_TEST_TMPDIR/bin/herdr"
  run terminal_pane_process_observe w1:p9
  [ "$status" -eq 10 ]
}

@test "the state harness really applies the state it claims to (#1152)" {
  # A control that has never gone red is indistinguishable from one that never
  # ran, and the rerun harness above currently has NO defect in this file it can
  # detect: the errexit axis is invisible to it (bats' `run` suppresses errexit)
  # and nothing here has a case-foldable alphabet. So rather than let it read as
  # a control it is not, this asserts the MECHANISM -- that an inner run really
  # does have the options set. It is a guard against the next defect of that
  # class, not evidence about this one.
  if [ -n "${AGMSG_CALLER_SHELL_NEST:-}" ]; then
    local tok
    for tok in ${AGMSG_CALLER_SHELL_STATE:-}; do
      case "$tok" in
        errexit|nounset|pipefail)
          [ -o "$tok" ] || { echo "inner run does not have $tok set"; return 1; } ;;
        nocasematch|extglob)
          shopt -q "$tok" || { echo "inner run does not have $tok set"; return 1; } ;;
      esac
    done
    # And the outer run must NOT have them, or the inner run proves nothing.
    return 0
  fi
  [ ! -o errexit ] || { echo "the outer run already has errexit; the inner run would prove nothing"; return 1; }
  shopt -q nocasematch && { echo "the outer run already has nocasematch"; return 1; }
  return 0
}
