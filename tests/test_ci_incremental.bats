#!/usr/bin/env bats

# Where CI runs what: a push runs only the fast checks, the release pull
# request runs everything, and a new push to an ordinary pull request runs
# only what changed since its last all-green head. These run the workflow's
# real detect step, lifted out of tests.yml, in a throwaway repository, with
# the GitHub API answered by a stand-in for curl.

load test_helper

ROOT="$BATS_TEST_DIRNAME/.."
WORKFLOW="$ROOT/.github/workflows/tests.yml"

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  cp -R "$ROOT/tests" "$ROOT/.github" "$REPO/"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@example.invalid
  git -C "$REPO" config user.name t
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm base
  A="$(git -C "$REPO" rev-parse HEAD)"
  _commit docs/a2.md; A2="$(git -C "$REPO" rev-parse HEAD)"
  _commit docs/b.md;  B="$(git -C "$REPO" rev-parse HEAD)"
  _commit docs/c.md;  C="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q --orphan other
  _commit docs/other.md; OTHER="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q "$C"

  FAKE="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKE"
  cat > "$FAKE/curl" <<'EOF2'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */actions/workflows/tests.yml/runs*) [ -n "${FAKE_RUNS:-}" ] && cat "$FAKE_RUNS" || exit 22 ;;
  */artifacts\?name=pr-base) [ -n "${FAKE_ART:-}" ] && cat "$FAKE_ART" || exit 22 ;;
  */zip) [ -n "${FAKE_ZIP:-}" ] && cp "$FAKE_ZIP" "$out" || exit 22 ;;
  *) exit 22 ;;
esac
EOF2
  chmod +x "$FAKE/curl"
}

_commit() {
  mkdir -p "$REPO/$(dirname "$1")"
  echo "$1" > "$REPO/$1"
  git -C "$REPO" add "$1"
  git -C "$REPO" commit -qm "$1"
}

# The whole detect step's run block.
_detect_script() {
  local script="$BATS_TEST_TMPDIR/detect.sh" start end
  start=$(grep -n '^      - id: detect$' "$WORKFLOW" | head -1 | cut -d: -f1)
  [ -n "$start" ]
  start=$(awk -v s="$start" 'NR > s && /^        run: \|$/ { print NR; exit }' "$WORKFLOW")
  end=$(grep -n "^      # This run's base, for the next push" "$WORKFLOW" | head -1 | cut -d: -f1)
  [ -n "$start" ] && [ -n "$end" ] && [ "$end" -gt "$start" ]
  sed -n "$((start + 1)),$((end - 1))p" "$WORKFLOW" | sed 's/^          //' > "$script"
  printf '%s' "$script"
}

# _detect <event> <action> [VAR=value ...]: runs detect in the throwaway repo.
_detect() {
  local event="$1" action="$2" script
  shift 2
  script="$(_detect_script)"
  OUT="$BATS_TEST_TMPDIR/out"
  LOG="$BATS_TEST_TMPDIR/log"
  : > "$OUT"
  (cd "$REPO" && env PATH="$FAKE:$PATH" EVENT="$event" ACTION="$action" BASE_SHA="$A2" HEAD_SHA="$C" \
    PR_HEAD_REF=fix/x PR_HEAD_REPO_ID=1 GITHUB_REPOSITORY_ID=1 PR_TITLE="Fix x" GH_TOKEN=t \
    GITHUB_API_URL=https://api.invalid GITHUB_REPOSITORY=o/r GITHUB_OUTPUT="$OUT" RUNNER_TEMP="$BATS_TEST_TMPDIR" \
    "$@" bash "$script") > "$LOG" 2>&1
}

_out() { sed -n "s/^$1=//p" "$OUT"; }

# The changed-file list detect printed.
_changed() { sed -n '/^Changed files:$/,/^Result: /p' "$LOG" | sed '1d;$d' | grep -v '^$' || true; }

_runs() {
  FAKE_RUNS="$BATS_TEST_TMPDIR/runs.json"
  printf '{"workflow_runs":[{"head_sha":"%s","id":11,"conclusion":"success","created_at":"2026-01-01T00:00:00Z","head_repository":{"id":1}}]}' "$1" > "$FAKE_RUNS"
}

_base_record() {
  command -v zip >/dev/null || skip "zip not available"
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/base.txt"
  FAKE_ZIP="$BATS_TEST_TMPDIR/fixture-base.zip"
  rm -f "$FAKE_ZIP"
  (cd "$BATS_TEST_TMPDIR" && zip -qj fixture-base.zip base.txt)
  FAKE_ART="$BATS_TEST_TMPDIR/art.json"
  echo '{"artifacts":[{"id":22,"expired":false}]}' > "$FAKE_ART"
}

@test "ci-incremental: a push runs only the fast checks" {
  _detect push ""
  [ "$(_out docs_only)" = true ]
  [ "$(_out contracts_needed)" = false ]
  [ "$(_out app_changed)" = false ]
}

@test "ci-incremental: the release pull request runs everything" {
  _detect pull_request synchronize PR_HEAD_REF=release/v1.9.0
  [ "$(_out docs_only)" = false ]
  [ "$(_out contracts_needed)" = true ]
  [ -z "$(_out bats_skip)" ]
  _detect pull_request opened PR_HEAD_REF=integration/1.9.0 PR_TITLE="release: 1.9.0"
  [ "$(_out docs_only)" = false ]
  [ "$(_out app_changed)" = true ]
}

@test "ci-incremental: a new push runs only what changed since the last all-green head" {
  _runs "$B"; _base_record "$A2"
  _detect pull_request synchronize FAKE_RUNS="$FAKE_RUNS" FAKE_ART="$FAKE_ART" FAKE_ZIP="$FAKE_ZIP"
  grep -qF "Incremental run: changes since head $B" "$LOG"
  [ "$(_changed)" = "docs/c.md" ]
}

@test "ci-incremental: when main moved, the base's changes join the list" {
  _runs "$B"; _base_record "$A"
  _detect pull_request synchronize FAKE_RUNS="$FAKE_RUNS" FAKE_ART="$FAKE_ART" FAKE_ZIP="$FAKE_ZIP"
  grep -qF "base $A -> $A2" "$LOG"
  [ "$(_changed)" = "$(printf 'docs/a2.md\ndocs/c.md')" ]
}

@test "ci-incremental: anything it cannot establish uses the whole pull request diff, and says so" {
  local full
  full="$(printf 'docs/b.md\ndocs/c.md')"
  # The run list cannot be fetched.
  _detect pull_request synchronize
  grep -qF "Incremental run not possible (could not list earlier runs)" "$LOG"
  [ "$(_changed)" = "$full" ]
  # The only green head is not in this history.
  _runs "$OTHER"; _base_record "$A2"
  _detect pull_request synchronize FAKE_RUNS="$FAKE_RUNS" FAKE_ART="$FAKE_ART" FAKE_ZIP="$FAKE_ZIP"
  grep -qF "no earlier all-green head" "$LOG"
  [ "$(_changed)" = "$full" ]
  # The green run left no base record.
  _runs "$B"
  _detect pull_request synchronize FAKE_RUNS="$FAKE_RUNS"
  grep -qF "has no readable pr-base record" "$LOG"
  [ "$(_changed)" = "$full" ]
  # A malformed record.
  _base_record "not-a-sha"
  _detect pull_request synchronize FAKE_RUNS="$FAKE_RUNS" FAKE_ART="$FAKE_ART" FAKE_ZIP="$FAKE_ZIP"
  grep -qF "Incremental run not possible" "$LOG"
  [ "$(_changed)" = "$full" ]
  # A pull request from another repository.
  _base_record "$A2"
  _detect pull_request synchronize PR_HEAD_REPO_ID=2 FAKE_RUNS="$FAKE_RUNS" FAKE_ART="$FAKE_ART" FAKE_ZIP="$FAKE_ZIP"
  grep -qF "pull request from another repository" "$LOG"
  [ "$(_changed)" = "$full" ]
}

@test "ci-incremental: the first push of a pull request uses its whole diff" {
  _runs "$B"; _base_record "$A2"
  _detect pull_request opened FAKE_RUNS="$FAKE_RUNS" FAKE_ART="$FAKE_ART" FAKE_ZIP="$FAKE_ZIP"
  refute grep -qF "Incremental run" "$LOG"
  [ "$(_changed)" = "$(printf 'docs/b.md\ndocs/c.md')" ]
}


@test "ci-incremental: the daily run is full, and only full runs mark macOS to run" {
  _detect schedule ""
  [ "$(_out full)" = true ]
  [ "$(_out docs_only)" = false ]
  [ "$(_out contracts_needed)" = true ]
  _detect pull_request opened PR_HEAD_REF=release/v1.9.0
  [ "$(_out full)" = true ]
  _detect pull_request opened
  [ "$(_out full)" = false ]
  _detect push ""
  [ "$(_out full)" != true ]
}

# The shard gate step, run with the inputs each case names.
_gate() {
  local script="$BATS_TEST_TMPDIR/gate.sh" start end
  start=$(grep -n 'name: Decide whether this shard runs' "$WORKFLOW" | head -1 | cut -d: -f1)
  [ -n "$start" ]
  start=$(awk -v s="$start" 'NR > s && /^        run: \|/ { print NR; exit }' "$WORKFLOW")
  end=$(awk -v s="$start" 'NR > s && !/^          / && !/^$/ { print NR; exit }' "$WORKFLOW")
  sed -n "$((start + 1)),$((end - 1))p" "$WORKFLOW" | sed 's/^          //' > "$script"
  OUT="$BATS_TEST_TMPDIR/gate-out"
  : > "$OUT"
  DOCS_ONLY="$1" FULL="$2" MATRIX_OS="$3" GITHUB_OUTPUT="$OUT" bash "$script" >/dev/null
  _out run
}

@test "ci-incremental: macOS shards run only on a full run; ubuntu shards on any non-docs diff" {
  [ "$(_gate false false ubuntu-latest)" = true ]
  [ "$(_gate false false macos-latest)" = false ]
  [ "$(_gate false true macos-latest)" = true ]
  [ "$(_gate true true ubuntu-latest)" = false ]
}
