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
  ppid=)   awk -F'\t' -v p="$pid" '$1 == p { print " " $2; found=1 } END { exit !found }' "$PS_TREE" ;;
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

  OWNER_PID=900
  PANE_PID=800
  _edge "$$" "$OWNER_PID"
  _edge "$OWNER_PID" "$PANE_PID"
  _edge "$PANE_PID" 1
  _own "agmsg" "seat" "sid-1.$OWNER_PID"
  _driver_returns "w1:p9	gen-1	$PANE_PID"
}
teardown() { teardown_test_env; }

_edge() { printf '%s\t%s\n' "$1" "$2" >> "$PS_TREE"; }
_own() {   # <team> <agent> <owner-token>
  local f; f="$(actas_lock_path "$1" "$2")"
  mkdir -p "${f%/*}"
  printf '%s\n' "$3" > "$f"
}
# Replace the driver op with one that hands back a fixed record.
_driver_returns() {
  eval 'terminal_pane_process_observe() { printf "%s\n" '"$(printf '%q' "$1")"'; }'
}
_driver_fails() {   # <rc>
  eval "terminal_pane_process_observe() { return $1; }"
}

# --- the four states -----------------------------------------------------------

@test "proved: the pane's process is in the owner's ancestry (SYNTHETIC tree) (#1152)" {
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 0 ]
  [ "$output" = "proved"$'\t'"herdr:w1:p9" ]
}

@test "disproved: it is not, and the observation was whole (#1152)" {
  _driver_returns "w1:p9	gen-1	777"
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
  _driver_returns "w1:pX	gen-1	654"
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
  PS_FAIL_FOR="$PANE_PID"; export PS_FAIL_FOR
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
          printf "%s\n" "w1:p9	gen-1	'"$PANE_PID"'"
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
    "w1:p9	gen-1" \
    "	gen-1	$PANE_PID" \
    "w1:p9		$PANE_PID" \
    "w1:p9	gen-1	not-a-pid" \
    "w1:p9	gen-1	0$PANE_PID" \
    "w1:p9	gen-1	0" \
    "w1:p9	gen-1	" \
  ; do
    _driver_returns "$bad"
    run agmsg_self_proof agmsg seat w1:p9
    [ "$status" -eq 2 ] || { echo "accepted a malformed record: [$bad] -> $output"; return 1; }
    [ "$output" = "undetermined"$'\t'"observation_malformed" ] \
      || { echo "wrong reason for [$bad]: $output"; return 1; }
  done
  # Not vacuous: the well-formed record still passes.
  _driver_returns "w1:p9	gen-1	$PANE_PID"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 0 ]
}

@test "a second line in the record is malformed, not a first line with extra (#1152)" {
  _driver_returns "w1:p9	gen-1	$PANE_PID
w1:pX	gen-1	$PANE_PID"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"observation_malformed" ]
}

@test "a control byte in the record is malformed (#1152)" {
  _driver_returns "w1:$(printf '\001')p9	gen-1	$PANE_PID"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"observation_malformed" ]
}

@test "the pane changing between the two looks is undetermined (#1152)" {
  local c="$BATS_TEST_TMPDIR/calls"; : > "$c"
  eval 'terminal_pane_process_observe() {
          printf "x\n" >> "'"$c"'"
          if [ "$(wc -l < "'"$c"'" | tr -d " ")" = 1 ]; then
            printf "%s\n" "w1:p9	gen-1	'"$PANE_PID"'"
          else
            printf "%s\n" "w1:p9	gen-2	'"$PANE_PID"'"
          fi
        }'
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 2 ]
  [ "$output" = "undetermined"$'\t'"snapshot_changed" ]
}

@test "a reused pid with a new generation is a DIFFERENT process (#1152)" {
  # The intersection would still be there -- the pid did not change. Only the
  # generation token says the process behind it did.
  local c="$BATS_TEST_TMPDIR/calls2"; : > "$c"
  eval 'terminal_pane_process_observe() {
          printf "x\n" >> "'"$c"'"
          if [ "$(wc -l < "'"$c"'" | tr -d " ")" = 1 ]; then
            printf "%s\n" "w1:p9	Mon Jan  1 00:00:00 2020	'"$PANE_PID"'"
          else
            printf "%s\n" "w1:p9	Tue Feb  2 00:00:00 2021	'"$PANE_PID"'"
          fi
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
  _driver_returns "w1:pREAL	gen-1	$PANE_PID"
  run agmsg_self_proof agmsg seat w1:pASKED
  [ "$status" -eq 0 ]
  [ "$output" = "proved"$'\t'"herdr:w1:pREAL" ]
  case "$output" in *pASKED*) echo "the caller's candidate came back"; return 1 ;; esac
}

@test "a canonical ref that fails the shared grammar is undetermined, not proved (#1152)" {
  _driver_returns "not a pane id	gen-1	$PANE_PID"
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
  _driver_returns "w1:p9	gen-1	777"
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
  _driver_returns "w1:p9	gen-1	80"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 1 ]
  [ "$output" = "disproved"$'\t'"pane_process_not_ancestor" ]
  # Not vacuous: 800 IS in the ancestry, so the list really does contain the
  # string this test is checking is not matched loosely.
  _driver_returns "w1:p9	gen-1	800"
  run agmsg_self_proof agmsg seat w1:p9
  [ "$status" -eq 0 ]
}
