#!/usr/bin/env bats

@test "remote CI watches the data plane and its sync contracts" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"

  run grep -F 'scripts/internal/*' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'scripts/drivers/storage/*' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'scripts/lib/*' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'tests/*sync*.*' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'tests/test_remote*.bats' "$workflow"
  [ "$status" -eq 0 ]
}

@test "age-v1 CI exercises every age-gated test with pinned tools" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"

  run grep -F 'filippo.io/age/cmd/age-keygen@v1.3.1' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'echo "$(go env GOPATH)/bin" >> "$GITHUB_PATH"' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'command -v age >/dev/null' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'command -v age-keygen >/dev/null' "$workflow"
  [ "$status" -eq 0 ]

  # This used to pin a single filtered invocation, which pinned the hole in
  # place: 31 tests gate on age, the shards skip them for want of the binary,
  # and naming one file's worth here left 30 running nowhere -- five of them
  # red. What has to hold is that the set is DISCOVERED, so a new age-gated
  # file cannot land outside every job.
  run grep -F "grep -rl 'skip_if_no_age' tests/*.bats" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'bats --print-output-on-failure $files' "$workflow"
  [ "$status" -eq 0 ]
  # ...and that finding nothing is a failure rather than a quiet pass.
  run grep -F 'no age-gated test files found' "$workflow"
  [ "$status" -eq 0 ]
}

@test "CI: a docs-only skip and a passing suite are not the same green (#798)" {
  # The docs-only path reports the bats checks green without running the
  # suite, which is right for the required context and wrong for a reader:
  # #776's green was once put forward as evidence that the base was fine, and
  # that shard had run nothing. What this pins is that the run SAYS which green
  # it is, in three places, and that the required context is not renamed.
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"
  # 1. The shard job's name carries the marker, keyed on the docs_only output.
  #    Shard checks are not required contexts, so the name may vary.
  grep -Fq "name: bats (\${{ matrix.os }} \${{ matrix.shard }}/6)\${{ needs.changes.outputs.docs_only == 'true' && ' — docs-only, suite skipped' || '' }}" "$workflow"
  # 2. The aggregate -- the required context -- keeps its exact name, once,
  #    unconditionally.
  [ "$(grep -c '^    name: bats$' "$workflow")" -eq 1 ]
  # 3. Both greens are named on the aggregate's own output: the skip as an
  #    annotation and a summary heading, the full pass as a summary heading
  #    that carries the file count.
  grep -Fq '::notice title=bats::docs-only diff — the bats suite did not run on any shard' "$workflow"
  grep -Fq '"## bats: docs-only, suite skipped"' "$workflow"
  grep -Fq '"## bats: suite ran"' "$workflow"
  grep -Fq 'The shard partition covers $count test files' "$workflow"
  # 4. And on the shard itself, so the checks tab shows it per job.
  grep -Fq '::notice title=bats shard skipped::docs-only diff — this shard ran 0 test files' "$workflow"
  # 5. #1057 (measured): `gh run rerun --failed` only re-executes the shards
  #    that failed, so a shard from the ORIGINAL run had no fresh
  #    bats-manifest-* artifact in the rerun -- the aggregate's manifest
  #    download came up empty for it (`cat: manifests/bats-manifest-macos-
  #    latest-*/shard-files.txt: No such file`) and the required check went
  #    red even though every shard had actually passed. The aggregate no
  #    longer depends on any artifact a shard uploaded: it recomputes the
  #    same partition itself, via shard-tests.sh for every shard
  #    1..SHARD_TOTAL, which needs nothing from this run's own shards to
  #    have produced anything.
  if grep -Fq 'Download shard manifests' "$workflow"; then false; fi
  if grep -Fq 'name: bats-manifest-' "$workflow"; then false; fi
  grep -Fq 'for shard in $(seq 1 "$SHARD_TOTAL")' "$workflow"
  grep -Fq '.github/scripts/shard-tests.sh "$shard" "$SHARD_TOTAL"' "$workflow"
}

@test "CI: the #798 pins go red when the marker is taken back out (mutation control)" {
  # A pin that stays green when the thing it pins is removed is not a pin.
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml" mutant="$BATS_TEST_TMPDIR/tests.yml"
  sed "s/ && ' — docs-only, suite skipped' || ''//" "$workflow" > "$mutant"
  # The mutation took: the marker is gone from the copy.
  if grep -Fq "docs-only, suite skipped' || ''" "$mutant"; then false; fi
  # ...and the name pin no longer matches it.
  if grep -Fq "name: bats (\${{ matrix.os }} \${{ matrix.shard }}/6)\${{ needs.changes.outputs.docs_only == 'true' && ' — docs-only, suite skipped' || '' }}" "$mutant"; then false; fi
}

# The suite has to run on the shape that actually gets dogfooded. A PR is only
# ever tested as "this head against the base it was opened on", so when several
# PRs collect on one integration branch, the tip -- all of them together -- is a
# tree no PR run has seen. The push leg on `integration/**` is what covers it.
@test "tests run on integration branches, on both legs" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"

  # Two occurrences: one under push:, one under pull_request:. Asserting the
  # count (not merely "present somewhere") is what makes this fail if only one
  # leg is widened -- the failure mode that leaves the merged shape untested
  # while every summary view still reads green.
  run bash -c "grep -c \"branches: \[main, 'integration/\*\*'\]\" '$workflow'"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# #1304: main pushes used to be the one case exempt from cancellation (their
# own group was a unique run id, so nothing could ever supersede one), on the
# theory that a release reads a specific main-push run and losing it would
# leave that commit with no verdict. Checking the actual release path found
# nothing depends on that: a release always tags main's CURRENT tip right
# after merging, and neither release.yml nor cut-release.sh look up a
# tests.yml run at all (release.yml is self-contained and tag-triggered, a
# different event). Three main-push runs queuing back to back on
# 2026-09-22, two of them already superseded before their macOS jobs even
# started, is what made this worth fixing rather than leaving as-is. Pins
# that main now shares the SAME cancel-on-newer-push behavior every other
# push branch already had, with no special case left for it.
@test "main pushes are cancelled by a newer push, the same as any other push branch" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"

  run grep -F 'cancel-in-progress: true' "$workflow"
  [ "$status" -eq 0 ]

  # No more special-cased run-id grouping for main.
  run grep -F "github.ref == 'refs/heads/main' && github.run_id" "$workflow"
  [ "$status" -eq 1 ]

  # main and every other push branch (only integration/** in practice) share
  # the same by-ref group, so a later push supersedes an earlier one on both.
  run grep -F "format('push-{0}', github.ref)" "$workflow"
  [ "$status" -eq 0 ]
}

# #1304: a merged/closed PR used to keep its own in-flight run alive with
# nothing left to cancel it (only a further push to the same PR ever
# re-triggered the pr-<number> concurrency group). Pins both halves of the
# fix: the trigger fires on close, and the run it produces does no real work
# -- it exists only to land in the group and let cancel-in-progress cancel
# whatever was still running for this PR.
@test "a closed PR triggers a run that skips the suite instead of running it (#1304)" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"

  run grep -F 'types: [opened, synchronize, reopened, closed]' "$workflow"
  [ "$status" -eq 0 ]

  run grep -F 'if [ "$ACTION" = "closed" ]; then' "$workflow"
  [ "$status" -eq 0 ]
  run bash -c "grep -A25 'if \[ \"\$ACTION\" = \"closed\" \]; then' '$workflow' | grep -c 'GITHUB_OUTPUT'"
  [ "$status" -eq 0 ]
  [ "$output" -eq 5 ]

  # Every heavy job must skip at the JOB level on a closed event, not merely
  # skip its own steps -- a job-level `if:` that still evaluates true lets
  # the matrix expand and each leg claim a runner for a no-op checkout, which
  # defeats the point of freeing macOS slots on close (review finding). Pins
  # both that the guarded form is present the expected number of times AND
  # that the old, unguarded form is gone everywhere -- a partial fix (some
  # jobs updated, one missed) would otherwise still pass a "present somewhere"
  # check.
  run bash -c "grep -c 'if: \${{ !cancelled() && github.event.action != .closed. }}' '$workflow'"
  [ "$status" -eq 0 ]
  [ "$output" -eq 8 ]
  # grep -c exits 1 on a zero count, which is the expected/wanted outcome
  # here, so only $output (not $status) is asserted on this one.
  run bash -c "grep -c 'if: \${{ !cancelled() }}\$' '$workflow'"
  [ "$output" -eq 0 ]
}

# The push-only whole-tree reuse lookup from the `changes` job -- the real
# lines, cut out of the workflow -- run against a fake curl and git. Prints
# what it wrote to GITHUB_OUTPUT as reuse_run, and leaves the URL curl was
# asked for in $BATS_TEST_TMPDIR/reuse/curl-args.
_reuse_lookup() {   # <curl stdout> [curl exit status]
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"
  local dir="$BATS_TEST_TMPDIR/reuse" start run_line end
  mkdir -p "$dir/bin"
  start=$(grep -n '^      - id: reuse$' "$workflow" | cut -d: -f1)
  [ -n "$start" ]
  run_line=$(awk -v s="$start" 'NR > s && /^        run: \|$/ { print NR; exit }' "$workflow")
  end=$(grep -n 'echo "reuse_run=$run" >> "$GITHUB_OUTPUT"' "$workflow" | cut -d: -f1)
  [ -n "$run_line" ] && [ -n "$end" ] && [ "$end" -gt "$run_line" ]
  sed -n "$((run_line + 1)),${end}p" "$workflow" | sed 's/^          //' > "$dir/lookup.sh"
  printf '%s' "$1" > "$dir/curl-out"
  cat > "$dir/bin/curl" <<CURL
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$dir/curl-args"
cat "$dir/curl-out"
exit ${2:-0}
CURL
  cat > "$dir/bin/git" <<'GIT'
#!/usr/bin/env bash
[ "$1 $2" = "rev-parse HEAD^{tree}" ] && { echo 4b825dc642cb6eb9a060e54bf8d69288fbee4904; exit 0; }
exit 1
GIT
  chmod +x "$dir/bin/curl" "$dir/bin/git"
  : > "$dir/out"
  GITHUB_OUTPUT="$dir/out" GITHUB_API_URL=https://api.example GITHUB_REPOSITORY=owner/repo \
    GITHUB_REPOSITORY_ID=42 GH_TOKEN=token PATH="$dir/bin:$PATH" \
    bash "$dir/lookup.sh" > "$dir/log" 2>&1
  sed -n 's/^reuse_run=//p' "$dir/out"
}

@test "CI: a push reuses a tree only when this repository's own run passed it" {
  command -v jq >/dev/null || skip "jq not installed"
  local own='{"expired":false,"workflow_run":{"id":4242,"head_repository_id":42}}'
  local fork='{"expired":false,"workflow_run":{"id":777,"head_repository_id":7}}'
  local old='{"expired":true,"workflow_run":{"id":555,"head_repository_id":42}}'

  [ "$(_reuse_lookup "{\"artifacts\":[$own]}")" = "4242" ]
  # The lookup asked for exactly this tree's record.
  grep -Fq 'actions/artifacts?name=green-tree-4b825dc642cb6eb9a060e54bf8d69288fbee4904&per_page=20' "$BATS_TEST_TMPDIR/reuse/curl-args"
  # A fork's run cannot vouch for main, even listed first.
  [ "$(_reuse_lookup "{\"artifacts\":[$fork]}")" = "" ]
  # (assigned first: bash 3.2 brace-expands "[$fork,$own]" inside a nested
  # quoted substitution)
  local both="{\"artifacts\":[$fork,$own]}"
  [ "$(_reuse_lookup "$both")" = "4242" ]
  # An expired record, no record, a failed or malformed answer, or an id that
  # is not a number: run the suite.
  [ "$(_reuse_lookup "{\"artifacts\":[$old]}")" = "" ]
  [ "$(_reuse_lookup '{"total_count":0,"artifacts":[]}')" = "" ]
  [ "$(_reuse_lookup '{"artifacts":[]}' 22)" = "" ]
  [ "$(_reuse_lookup 'not json')" = "" ]
  [ "$(_reuse_lookup '{"artifacts":[{"expired":false,"workflow_run":{"id":"4242; touch x","head_repository_id":42}}]}')" = "" ]
  # It always writes the output, so the shards never read an unset value.
  grep -qx 'reuse_run=' "$BATS_TEST_TMPDIR/reuse/out"
}

@test "CI: only a pull_request run whose suite ran and passed records its tree, and a reused push says so" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"
  # The lookup is push-only; recording is pull_request-only and skipped for a
  # docs-only diff (nothing ran). The record sits in the aggregate job, after
  # the step that fails unless every shard passed.
  grep -Fq "      - id: reuse" "$workflow"
  [ "$(grep -A1 '^      - id: reuse$' "$workflow" | tail -1)" = "        if: github.event_name == 'push'" ]
  [ "$(grep -A2 '^      - name: Record this tree as passed$' "$workflow" | tail -1)" = "        if: github.event_name == 'pull_request' && needs.changes.outputs.docs_only != 'true'" ]
  grep -Fq 'name: green-tree-${{ steps.green.outputs.tree }}' "$workflow"
  # Every heavy shard step skips on a reused tree, the same set the docs-only
  # skip gates; nothing heavy is left gated on docs_only alone.
  [ "$(grep -c "needs.changes.outputs.docs_only != 'true' && needs.changes.outputs.reuse_run == ''" "$workflow")" -eq 10 ]
  # And the run says which green it is, on the shard and on the aggregate.
  grep -Fq "format(' — tree passed in run {0}, suite skipped', needs.changes.outputs.reuse_run)" "$workflow"
  grep -Fq '"## bats: tree already passed, suite skipped"' "$workflow"
  grep -Fq '::notice title=bats shard skipped::this tree passed every shard in run $REUSE_RUN' "$workflow"
}
