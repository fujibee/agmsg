#!/usr/bin/env bats
#
# The antigravity driver's fail-closed reads: the transport's ownership gate,
# and the supervisor's start token.
#
# inbox-transport.sh's ownership gate. It sits in front of `peek` (reads the
# inbox) and `ack` (marks read, which does not come back), and it is the only
# thing between the bridge and another session's messages.
#
# The gate has three answers and the existing suite reached exactly ONE of them.
# `antigravity_bridge.test.mjs` always runs with the lock the bridge itself just
# claimed, so every path through it is "the owner matches" -- the refusals were
# never executed, in either flavour, by anything. That is the same shape this
# driver's review has now hit three times: a check that exists, and a test set
# in which nothing can reach it. Each case below is reached on purpose, and the
# match case is kept alongside so "refuse everything" cannot pass. (#1090)

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export TRANSPORT="$SCRIPTS/drivers/types/antigravity/inbox-transport.sh"
  export PROJ="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJ" "$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/join.sh" fixture worker antigravity "$PROJ" >/dev/null
  LOCK="$( ( export SKILL_DIR="$TEST_SKILL_DIR"
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/actas-lock.sh"; actas_lock_path fixture worker ) )"
  export LOCK
}

teardown() {
  chmod 644 "$LOCK" 2>/dev/null || true
  teardown_test_env
}

@test "transport verify: the owner it names is the owner in the lock -> 0" {
  # The partner the two refusals need. Without it, a gate that refused
  # everything would pass them both and the bridge would never read its inbox.
  printf 'sid-me\n' > "$LOCK"
  run bash "$TRANSPORT" verify "$PROJ" fixture worker sid-me
  [ "$status" -eq 0 ]
}

@test "transport verify: a lock held by someone else -> non-zero" {
  printf 'sid-other\n' > "$LOCK"
  run bash "$TRANSPORT" verify "$PROJ" fixture worker sid-me
  [ "$status" -ne 0 ]
}

@test "transport verify: a lock that cannot be READ -> non-zero, not 'still mine'" {
  # The supervisor reads this exit status as the boolean "do I still hold the
  # role". "I could not find out" must answer the same as "no" here: an
  # unverifiable lock is not a held one.
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  printf 'sid-me\n' > "$LOCK"
  chmod 000 "$LOCK"
  run bash "$TRANSPORT" verify "$PROJ" fixture worker sid-me
  chmod 644 "$LOCK"
  [ "$status" -ne 0 ]
}

@test "transport peek: someone else's lock is refused as a mismatch" {
  printf 'sid-other\n' > "$LOCK"
  run bash "$TRANSPORT" peek "$PROJ" fixture worker sid-me
  [ "$status" -ne 0 ]
  grep -q '所有権不一致' <<<"$output"
}

@test "transport peek: an unreadable lock is refused, and NOT as a mismatch" {
  # Both refuse; what this pins is that they refuse with DIFFERENT words.
  # "someone else holds it" is a claim about the world and sends the operator to
  # the other session; "I could not read the lock" is a claim about us and sends
  # them to the file. Reporting the second as the first is the lie `doctor` used
  # to tell with lock=none.
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  printf 'sid-me\n' > "$LOCK"
  chmod 000 "$LOCK"
  run bash "$TRANSPORT" peek "$PROJ" fixture worker sid-me
  chmod 644 "$LOCK"
  [ "$status" -ne 0 ]
  grep -q '所有権を確認できません' <<<"$output"
  refute grep -q '所有権不一致' <<<"$output"
}

@test "supervisor proc_start: a failed /proc read raises, it never falls back to ps" {
  # Structural, and deliberately so. The defect this pins is a LIVE process whose
  # /proc read fails once: the fallback returns a `ps` token, the stored token
  # came from /proc, the comparison correctly refuses to match, and a running
  # supervisor is reported as a different process. Constructing that state needs
  # a pid that is alive and whose /proc entry is unreadable, which is not
  # something a test can arrange on either platform here -- a pid with no /proc
  # entry makes BOTH the fixed and the broken version raise, so it separates
  # nothing. Same situation, and the same answer, as the one-read rule in
  # test_watch.bats: when the window is not addressable from a test, pin the
  # shape. (#1090 review)
  # The CODE only: the docstring above it explains what was removed and why, so
  # extracting the whole function would find `lstart` in the very sentence that
  # says there is no lstart any more. (Measured -- the first version of this test
  # failed on its own explanation.)
  local body
  body="$(awk '/^def proc_start\(pid\):/{f=1} f&&/^    try:/{c=1} c{print} c&&/^    return /{exit}' \
    "$SCRIPTS/drivers/types/antigravity/antigravity-tui-supervisor.py")"
  # Canary: the extraction found the function's body, so an absence below is real.
  grep -q "/proc/{pid}/stat" <<<"$body"
  # No second source, and no tag for one: both existed only to support the
  # fallback, and both are gone with it.
  refute grep -q "lstart" <<<"$body"
  refute grep -q "'ps:" <<<"$body"
  refute grep -q "subprocess" <<<"$body"
  # And the failure says what could not be read, rather than exiting quietly.
  grep -q "起動時刻を判定できません" <<<"$body"
}

@test "supervisor: 'could not read' is a DIFFERENT exception from 'the pid is gone'" {
  # The three call sites that displace a reservation (acquire, reset_guard,
  # recover) catch FileNotFoundError to mean "that pid is gone" and then unlink,
  # reclaim or recover. Mapping every OSError to FileNotFoundError fed
  # "could not read /proc" straight into that -- a live supervisor with an
  # unreadable /proc would have had its reservation taken. This pins the split
  # at the type level, which is where the three handlers read it.
  run python3 - "$SCRIPTS/drivers/types/antigravity/antigravity-tui-supervisor.py" <<'PY'
import importlib.util, sys, os
spec=importlib.util.spec_from_file_location('sup', sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# The property the three handlers depend on: an unreadable read must not land in
# their `except FileNotFoundError`.
assert not issubclass(m.StartTimeUnreadable, FileNotFoundError), 'StartTimeUnreadable would be caught as "gone"'
assert issubclass(m.StartTimeUnreadable, OSError), 'should still be an OSError'
# Reached for real on a host with no /proc at all: every pid "looks" absent
# there, and that is a fact about the system, not about the process.
if not os.path.isdir('/proc'):
    try:
        m.proc_start(os.getpid()); raise SystemExit('proc_start returned on a host with no /proc')
    except m.StartTimeUnreadable:
        pass
    except FileNotFoundError:
        raise SystemExit('no /proc was reported as "the pid is gone"')
# And the one place the live question is answered turns only the gone case into
# False; an unreadable read propagates. Checked on process_still's OWN body:
# `except FileNotFoundError` also appears inside proc_start, so asking the whole
# file matched there and the mutation that widened THIS clause to `except OSError`
# produced no red. (Measured -- the first version of this line did exactly that.)
src=open(sys.argv[1]).read()
body=src.split('def process_still(pid, start):',1)[1].split('\ndef ',1)[0]
assert 'except FileNotFoundError:' in body, 'process_still must catch the gone case'
assert 'except OSError' not in body, 'process_still must NOT swallow an unreadable read'
print('ok')
PY
  [ "$status" -eq 0 ]
  grep -q '^ok$' <<<"$output"
}

@test "supervisor: the live check lives in ONE place, and the displacing callers use it" {
  # Three separate `except` clauses is how the fourth one comes out facing the
  # other way -- the same reason inbox-transport.sh has a single _owner_check.
  local src="$SCRIPTS/drivers/types/antigravity/antigravity-tui-supervisor.py"
  # Canary: the helper is there, so the counts below mean something.
  grep -q '^def process_still(pid, start):' "$src"
  # Every site that decides whether to displace a reservation goes through it.
  [ "$(grep -c 'process_still(int(' "$src")" -eq 4 ]
  # And none of them still asks proc_start directly and reads the exception.
  refute grep -q "proc_start(int(" "$src"
}

@test "the mjs read-guard: turning delivery OFF still works on a non-Linux host" {
  # This is the regression the first version of the guard caused, so it is pinned
  # first. `delivery.sh set off antigravity` runs antigravity-mode.mjs stop, and
  # turning delivery OFF has to work on every host -- it is the escape hatch. A
  # refusal at module load broke it. With no reservation present, proc() is never
  # reached, and nothing is being claimed about any process.
  [ "$(uname -s)" = Linux ] && skip "this asserts the behaviour on a host that is NOT Linux"
  run node "$SCRIPTS/drivers/types/antigravity/antigravity-mode.mjs" stop "$PROJ"
  [ "$status" -eq 0 ]
}

@test "the mjs read-guard: a reservation it cannot judge refuses out loud, at the entries the launchers do not cover" {
  # The launchers gate the two documented ways in. These are the others:
  # _delivery.sh runs antigravity-mode.mjs directly for runtime status, and
  # bridge-read-guard.sh runs the guard module directly. Gating only the
  # launchers leaves both walking into a /proc read.
  #
  # The refusal lives in the OPERATION inside the module that owns the
  # dependency -- not at import (that broke `set off`, above) and not in the two
  # callers (three call sites is how the fourth faces the other way). And
  # mode.mjs used to wrap proc() in `try{...}catch{}`, folding any failure into
  # live=false: status said 停止/要確認 and stop left the reservation behind,
  # neither saying why. An unsupported platform is not a dead process.
  [ "$(uname -s)" = Linux ] && skip "this asserts the refusal on a host that is NOT Linux"
  local run_dir="$TEST_SKILL_DIR/run"
  local state="$run_dir/antigravity-bridge.state.json"
  # $PROJ as-is, NOT `pwd -P`: mode.mjs compares against path.resolve(project),
  # which normalises but does not follow symlinks. On macOS the temp dir is
  # /var -> /private/var, so the resolved spelling silently failed to match and
  # the loop skipped the reservation entirely -- the test passed through without
  # ever reaching the code it names. (Measured.)
  printf '{"project":"%s","team":"fixture","role":"worker"}\n' "$PROJ" > "$state"
  printf '{"pid":1,"start":"x","state":"%s","kind":"tui-pty"}\n' "$state" \
    > "$run_dir/antigravity-reservation.fixture__worker.json"

  run node "$SCRIPTS/drivers/types/antigravity/antigravity-mode.mjs" status "$PROJ"
  [ "$status" -ne 0 ]
  grep -q 'Linux 専用' <<<"$output"

  # The guard's own entry. It was ALREADY fail-closed here -- its blanket catch
  # exits 13 either way -- so what changed is only what it says: "検査に失敗しました"
  # read the same whether the check failed or could never run on this host, and
  # the operator's next move differs. Exit 13 is left alone; callers branch on it.
  run node "$SCRIPTS/lib/bridge-read-guard.mjs" check "$run_dir/antigravity-reservation.fixture__worker.json" 1 fixture worker
  [ "$status" -eq 13 ]
  grep -q 'Linux 専用' <<<"$output"
}
