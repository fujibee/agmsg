#!/usr/bin/env bats

# #804. `pull` wrote the team binding at whatever the caller's umask produced,
# and the `unlock` after it refused that file: every reader of a binding rejects
# `mode & 0o022`, and `umask 002` -- ordinary on a group-shared machine --
# produces 0664. The product refused its own output, on the happy path, every
# time, for anyone with that umask.
#
# The mode is asserted rather than the message, because the message is downstream
# of it: fix the mode and no reader has anything to refuse.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
}
teardown() { teardown_test_env; }

# `stat` is one of the flags this suite exists to keep honest across userlands.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

@test "a binding written under umask 002 is not group-writable (#804)" {
  ( umask 002; bash "$SCRIPTS/join.sh" umaskteam alice claude-code /tmp/p-804 >/dev/null )
  local cfg mode
  cfg="$TEST_SKILL_DIR/teams/umaskteam/config.json"
  [ -f "$cfg" ]
  mode="$(file_mode "$cfg")"
  # The property the readers enforce, stated the way they state it.
  [ "$(( 8#$mode & 8#0022 ))" -eq 0 ]
  # And the mode this product gives its own authority files.
  [ "$mode" = "600" ]
}

@test "the same holds under umask 000, where nothing is masked (#804)" {
  # 002 is the reported case; 000 is the one that proves the write sets the mode
  # rather than merely surviving a friendly umask.
  ( umask 000; bash "$SCRIPTS/join.sh" openteam alice claude-code /tmp/p-804b >/dev/null )
  local mode
  mode="$(file_mode "$TEST_SKILL_DIR/teams/openteam/config.json")"
  [ "$(( 8#$mode & 8#0022 ))" -eq 0 ]
  [ "$mode" = "600" ]
}

@test "a leftover permissive temp is never opened, so no content passes through it (#804)" {
  # THE STALE-TEMP CASE, and it has to be driven through the helper directly.
  #
  # An earlier version of this test spawned `join.sh` and planted a decoy named
  # `<dest>.tmp.$$` — but `$$` there was the TEST's pid, and the script writing
  # the file has its own. The decoy never had the name the old implementation
  # would have opened, so the control passed against both implementations. It
  # proved nothing, which is the same defect it exists to catch.
  #
  # Calling the helper in this shell makes `$$` the one it would use.
  #
  # AND `$$` ALONE WAS NOT ENOUGH, WHICH THIS TEST USED TO GET WRONG. TWICE.
  #
  # The candidate name has changed twice under this case, and both times the
  # decoy was left on the OLD one, so the helper walked past it and every
  # assertion below passed for the wrong reason:
  #
  #   decoy at `<dest>.tmp.$$`          candidate was `<dest>.tmp.$$.$RANDOM`
  #   decoy at `<dest>.tmp.$$.$RANDOM`  candidate is  `<dest>.tmp.$$.$RANDOM.d`
  #
  # Measured, not supposed: at the first of those, removing `set -C` from the
  # creation altogether left all five cases in this file green.
  #
  # The decoy is now a DIRECTORY on the seeded first candidate, holding a file
  # at the name the helper writes into. That is the stronger statement: it fails
  # if the helper adopts a directory it did not create, not merely if it
  # truncates a file.
  #
  # `RANDOM` is seeded so the first candidate is known here. The call is direct
  # rather than under `run`, because bash reseeds the generator in a subshell.
  local probe decoy
  probe="$TEST_SKILL_DIR/stale.json"

  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/registry-lock.sh"

  RANDOM=20804
  decoy="$probe.tmp.$$.$RANDOM.d"
  mkdir "$decoy"
  printf 'SENTINEL-NOT-TOUCHED\n' > "$decoy/new"
  chmod 777 "$decoy"
  chmod 666 "$decoy/new"

  RANDOM=20804
  agmsg_write_atomic "$probe" '{"endpoint":"https://host/t/THE-SECRET/"}'

  # 1. the leftover is still THERE. This is the assertion that discriminates:
  # the old implementation opened this exact path and then `mv`'d it into place,
  # so under that code the decoy does not survive at all -- it becomes the
  # destination. Its disappearance is the observable, and it has to be asserted
  # before its contents, because `cat` on a missing file is a different failure
  # with a different message.
  [ -d "$decoy" ]
  [ -f "$decoy/new" ]
  # 2. and it still holds its own bytes
  [ "$(cat "$decoy/new")" = "SENTINEL-NOT-TOUCHED" ]
  # 3. and the secret is not in it, at any mode. This one cannot be the reason
  # the test reddens -- adoption removes the file rather than leaving it with
  # the secret inside -- so it is a guard against a future implementation that
  # writes through the leftover WITHOUT consuming it, not the discriminator.
  #
  # `refute`, not `! grep`: a command under `!` is exempt from errexit, so the
  # negated form returns non-zero and the test carries on regardless -- it could
  # not fail. The repository has a checker for exactly this, and it was right to
  # stop this file. #715 is the same mechanism, found the same way.
  refute grep -q 'THE-SECRET' "$decoy/new"
  # 4. the real write happened, privately
  grep -q 'THE-SECRET' "$probe"
  [ "$(file_mode "$probe")" = "600" ]
  rm -rf "$decoy"
}

@test "the temp the helper creates is private before any content is written (#804)" {
  # Asserted on the primitive rather than on a race: `umask 077` applies at
  # CREATION -- to the directory the call makes and to the file it opens inside
  # it -- so there is no moment at which either exists more permissively. If the
  # helper is changed to create-then-narrow, this stops holding.
  #
  # It used to say `mktemp` creates at 0600. `mktemp` was removed from this
  # helper long before this line was, and a comment naming a primitive the code
  # does not use is read as enforcement by whoever arrives next.
  local probe
  probe="$TEST_SKILL_DIR/probe.json"
  ( umask 002
    source "$SCRIPTS/lib/registry-lock.sh"
    # A content large enough that the write is not one atomic-looking blip.
    agmsg_write_atomic "$probe" "$(head -c 200000 /dev/zero | tr '\0' 'x')" )
  [ "$(file_mode "$probe")" = "600" ]
  # No temp survives beside it.
  [ -z "$(find "$TEST_SKILL_DIR" -maxdepth 1 -name 'probe.json.tmp.*' -print -quit)" ]
}

@test "a write that fails part-way leaves the old file exactly as it was (#804)" {
  # `mv` makes a reader see the whole new file or the whole old one. It does not
  # make the CONTENT whole: a printf that writes half the payload and then fails
  # would be published, indivisibly, as a truncated destination (review).
  #
  # The failure is forced with `ulimit -f`, and SIGXFSZ is ignored so the write
  # RETURNS the error instead of killing the shell -- which is what makes the
  # helper's own handling observable rather than the kernel's.
  local dest original
  dest="$TEST_SKILL_DIR/partial.json"
  original='{"keep":"this exact byte string"}'
  printf '%s\n' "$original" > "$dest"
  chmod 600 "$dest"
  local before
  before="$(cat "$dest")"

  local status=0
  (
    trap '' XFSZ
    ulimit -f 1          # 512-byte blocks: a 200 KB payload cannot land
    # shellcheck disable=SC1091
    source "$SCRIPTS/lib/registry-lock.sh"
    agmsg_write_atomic "$dest" "$(head -c 200000 /dev/zero | tr '\0' 'x')"
  ) 2>/dev/null || status=$?

  # 1. it did not claim success
  [ "$status" -ne 0 ]
  # 2. the old destination is byte-for-byte what it was
  [ "$(cat "$dest")" = "$before" ]
  # 3. and nothing private was left lying beside it
  [ -z "$(find "$TEST_SKILL_DIR" -maxdepth 1 -name 'partial.json.tmp.*' -print -quit)" ]
}

@test "when every candidate name is taken the write gives up and says so (#804)" {
  # THE GIVE-UP PATH, driven deterministically rather than by luck.
  #
  # The loop draws `<dest>.tmp.$$.$RANDOM` and stops after 32 candidates. Seeding
  # `RANDOM` makes that sequence reproducible, so this plants exactly the 32
  # names the helper is about to draw and nothing else. No permissions are
  # changed and no filesystem is filled, which is what makes it run the same way
  # on every platform in the matrix.
  #
  # The alternative was an unwritable directory. That drives the same branch
  # through a different cause and answers differently where chmod is advisory,
  # so it would have been a control on the runner rather than on this loop.
  local probe taken i
  probe="$TEST_SKILL_DIR/exhaust.json"
  printf 'ORIGINAL\n' > "$probe"

  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/registry-lock.sh"

  RANDOM=7104
  taken=()
  for ((i = 0; i < 32; i++)); do
    taken+=("$probe.tmp.$$.$RANDOM.d")
  done
  for name in "${taken[@]}"; do
    mkdir "$name"
    printf 'SOMEONE-ELSES\n' > "$name/new"
  done

  # Direct, not under `run`: bash reseeds the generator in a subshell, so a
  # forked call would draw a different sequence and collide with none of these.
  # STDERR GOES TO A FILE, not through `$( )`. A command substitution forks, and
  # a forked bash reseeds `RANDOM` -- the helper would then draw 32 names none of
  # which are planted here, allocate on the first try and return 0. That is
  # exactly what it did on the first run of this test: the assertion below caught
  # it, and the cause was the capture, not the loop.
  RANDOM=7104
  local rc=0 errfile="$TEST_SKILL_DIR/exhaust.err"
  agmsg_write_atomic "$probe" '{"endpoint":"https://host/t/THE-SECRET/"}' 2>"$errfile" || rc=$?

  # 1. it FAILED, rather than returning 0 with nothing written
  [ "$rc" -ne 0 ]
  # 2. and said which of the two failures this was
  grep -q 'could not create a private temporary directory' "$errfile"
  # 3. the destination is untouched — the caller's old file is still the file
  [ "$(cat "$probe")" = "ORIGINAL" ]
  # 4. and not one of the 32 was opened, emptied or carried off
  for name in "${taken[@]}"; do
    [ -d "$name" ]
    [ "$(cat "$name/new")" = "SOMEONE-ELSES" ]
  done
  refute grep -rq 'THE-SECRET' "$TEST_SKILL_DIR"

  rm -rf "${taken[@]}"
}

@test "a cleanup that fails after the write landed does not report a failure (#804)" {
  # THE WRITE IS COMMITTED AT THE `mv`. Everything after it is tidying, and this
  # function used to end on a bare `rmdir` -- so the tidy-up's status became the
  # function's, and a caller was told a committed write had failed. No `set -e`
  # is needed for that; the last command's status is the function's.
  #
  # `rmdir` is shadowed by one that always fails, which is the same failure a
  # non-empty or vanished directory would produce, without needing to arrange
  # either.
  local dest bindir errfile rc=0
  dest="$TEST_SKILL_DIR/committed.json"
  bindir="$TEST_SKILL_DIR/failing-rmdir"
  errfile="$TEST_SKILL_DIR/committed.err"
  mkdir -p "$bindir"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$bindir/rmdir"
  chmod +x "$bindir/rmdir"

  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/registry-lock.sh"
  PATH="$bindir:$PATH" agmsg_write_atomic "$dest" '{"endpoint":"https://host/t/KEPT/"}' 2>"$errfile" || rc=$?

  # 1. the write is reported as what it is: done
  [ "$rc" -eq 0 ]
  # 2. and it really is done, at the right mode
  grep -q 'KEPT' "$dest"
  [ "$(file_mode "$dest")" = "600" ]
  # 3. the leak is SAID rather than swallowed, and says which directory
  grep -q 'could not remove the temporary directory' "$errfile"
  # 4. and it is not dressed up as a failure of the write
  refute grep -q 'could not write the new contents' "$errfile"
}

@test "a failed write with no rm says so, and says what it left (#804)" {
  # THE MINIMAL PATH IS THE POINT. `join` must work on a PATH without `rm`, so
  # a write that fails there cannot remove its own attempt, and the directory
  # holding it cannot be removed either. Two things must survive that: the
  # caller's diagnostic and its non-zero return, neither of which may be
  # replaced by the cleanup's own failure under `set -e`.
  local dest bindir errfile before rc=0
  dest="$TEST_SKILL_DIR/norm.json"
  bindir="$TEST_SKILL_DIR/no-rm-bin"
  errfile="$TEST_SKILL_DIR/norm.err"
  printf '%s\n' '{"keep":"this exact byte string"}' > "$dest"
  chmod 600 "$dest"
  before="$(cat "$dest")"

  mkdir -p "$bindir"
  # Everything the helper needs, and deliberately NOT `rm`.
  for tool in mkdir rmdir mv; do
    ln -sf "$(command -v "$tool")" "$bindir/$tool"
  done

  # THE PAYLOAD IS BUILT INSIDE THE SCRIPT, BY A BUILTIN, AND NOT PASSED IN.
  #
  # Two ways of getting it in have already failed here, and both are recorded
  # because each looked correct:
  #
  #   composed inside the narrowed PATH -> `head` and `tr` are not in that bin
  #     dir, so it wrote an EMPTY string, the write succeeded, and the case
  #     passed with rc=0.
  #   passed as `run bash "$script" "$payload"` -> a 200 KB argv entry is over
  #     ARG_MAX on Linux. It ran on the machine that wrote it and died on CI
  #     with `/usr/bin/bash: Argument list too long` -- the same shape as #820,
  #     which I had filed against `history.sh` an hour earlier.
  #
  # Doubling a string is a builtin loop: no argv, no external command, and it
  # works after PATH has been narrowed to the bin dir below.
  #
  # RUN IN A CHILD SHELL, and that is not a style choice. The first version
  # wrapped the scenario in `( set -e; ... ) || rc=$?`. A compound command on the
  # left of `||` has errexit DISABLED inside it, so the `set -e` never applied
  # and the mutation that removes the `|| :` from the cleanup changed nothing.
  # A separate process carries its own errexit, which no condition in this test
  # can suppress.
  local script="$TEST_SKILL_DIR/no-rm-write.sh"
  cat > "$script" <<SCRIPT
set -e
trap '' XFSZ
ulimit -f 1
PATH="$bindir"
. "$SCRIPTS/lib/registry-lock.sh"
payload=x
while [ \${#payload} -lt 200000 ]; do payload="\$payload\$payload"; done
agmsg_write_atomic "$dest" "\$payload"
SCRIPT

  run bash "$script"
  rc="$status"
  printf '%s' "$output" > "$errfile"

  # 1. it failed, and said so as a WRITE failure
  [ "$rc" -ne 0 ]
  grep -q 'could not write the new contents' "$errfile"
  # 2. the residue is named rather than left to be discovered
  grep -q 'a private copy of the failed attempt is left in' "$errfile"
  # 3. the destination is byte-for-byte what it was
  [ "$(cat "$dest")" = "$before" ]
}
