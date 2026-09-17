#!/usr/bin/env bats

# Under bats, fd 3 is the TAP pipe and fd 4 is used alongside it. A process that
# inherits either and outlives the command that started it holds the whole test
# file open, and the shard then runs to the CI job's timeout with every test
# already reported ok.
#
# Every background spawn under scripts/ closes both, on the line itself. There
# is no file-level exemption: codex-bridge-launcher.sh closes the fds once at
# the top with `exec` *and* on each of its spawns, so nothing depends on one,
# and an exemption keyed on "the file contains an exec somewhere" would accept
# that exec inside a function, inside a branch that never runs, or after the
# spawn it is supposed to cover. Requiring the guard on the line is redundant
# where a script-level exec exists, and redundancy is the cheaper mistake.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

_unguarded_spawns() {
  local root="${1:-$REPO_ROOT/scripts}" file line rest
  while IFS=: read -r file line rest; do
    [ -n "$file" ] || continue
    case "$rest" in
      *"3>&-"*)
        case "$rest" in *"4>&-"*) continue ;; esac
        printf '%s:%s: closes fd 3 but not fd 4 -- %s\n' "$file" "$line" "$rest"
        ;;
      *) printf '%s:%s: closes neither fd 3 nor fd 4 -- %s\n' "$file" "$line" "$rest" ;;
    esac
  done < <(grep -rnE '^[^#]*[^&|]&[[:space:]]*$' "$root" 2>/dev/null)
}

@test "every background spawn under scripts/ closes bats' fd 3 and fd 4" {
  local offenders
  offenders="$(_unguarded_spawns)"
  if [ -n "$offenders" ]; then
    printf 'background spawns missing the guard:\n%s\n' "$offenders" >&2
  fi
  [ -z "$offenders" ]
}

@test "the guard check sees the spawns it is meant to police" {
  # Without this, a pattern that quietly stopped matching would leave a test
  # passing because it found nothing -- the failure being guarded against is a
  # silent one, so the count is asserted rather than assumed.
  local total
  total="$(grep -rcE '^[^#]*[^&|]&[[:space:]]*$' "$REPO_ROOT/scripts" 2>/dev/null \
    | awk -F: '{s+=$2} END {print s+0}')"
  [ "$total" -ge 5 ]
}

@test "a spawn closing only fd 3 is reported" {
  # The half-guarded case an earlier revision of this file let through: it
  # asserted "fd 3 and fd 4" in its message while grepping for fd 3 alone.
  mkdir -p "$BATS_TEST_TMPDIR/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 300 3>&- &' \
    > "$BATS_TEST_TMPDIR/scripts/half-guarded.sh"
  run _unguarded_spawns "$BATS_TEST_TMPDIR/scripts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"closes fd 3 but not fd 4"* ]]
}

@test "an exec elsewhere in a file does not excuse an unguarded spawn" {
  # The loophole a file-level exemption would open, pinned as closed: the exec
  # here sits in a branch that never runs and after the spawn it would have
  # covered, which is exactly the shape a "does the file contain an exec?"
  # check cannot tell apart from a real one.
  mkdir -p "$BATS_TEST_TMPDIR/scripts"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'sleep 300 &' \
    'if false; then' \
    '  exec 3>&- 4>&-' \
    'fi' \
    > "$BATS_TEST_TMPDIR/scripts/decoy-exec.sh"
  run _unguarded_spawns "$BATS_TEST_TMPDIR/scripts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"closes neither fd 3 nor fd 4"* ]]
}
