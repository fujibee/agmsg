#!/usr/bin/env bats

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
}

@test "fast dispatch: non-Windows reports unavailable before side effects" {
  run env OS=Linux bash -c 'source "'$SCRIPTS'/lib/fast-dispatch.sh"; agmsg_fast_try team demo'
  [ "$status" -eq 78 ]
  [ -z "$output" ]
}

@test "fast dispatch: missing explicit Node override is loud" {
  run env OS=Windows_NT AGMSG_NODE=__agmsg_missing_node__ bash -c \
    'source "'$SCRIPTS'/lib/fast-dispatch.sh"; agmsg_fast_try team demo'
  [ "$status" -eq 127 ]
  [[ "$output" == *"configured Node executable is not runnable"* ]]
}

@test "fast dispatch: unsupported native capability returns 78 without fallback inside Node" {
  fake="$BATS_TEST_TMPDIR/node"
  printf '#!/usr/bin/env bash\nexit 78\n' > "$fake"
  chmod +x "$fake"
  run env OS=Windows_NT AGMSG_NODE="$fake" bash -c \
    'source "'$SCRIPTS'/lib/fast-dispatch.sh"; agmsg_fast_try team demo'
  [ "$status" -eq 78 ]
}
