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
