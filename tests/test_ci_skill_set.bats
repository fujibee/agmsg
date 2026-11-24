#!/usr/bin/env bats

# The skill test set: a pull request whose diff is only prose plus files bats
# reads by name (SKILL.md, the per-type templates, the READMEs) runs only the
# bats files that name them. These run the workflow's real detect script and
# the Windows legs' real decision step, lifted out of tests.yml, rather than a
# restatement of them.

load test_helper

ROOT="$BATS_TEST_DIRNAME/.."
WORKFLOW="$ROOT/.github/workflows/tests.yml"

# The detect step from its file-list read to the end of its run block, with the
# read replaced by a list this test supplies. Anchors are asserted, so a moved
# anchor fails here instead of testing an empty script.
_detect_script() {
  local script="$BATS_TEST_TMPDIR/detect.sh" start end
  start=$(grep -n 'changed=\$(git diff --name-only' "$WORKFLOW" | head -1 | cut -d: -f1)
  end=$(grep -n '^      # Whole-tree reuse, push only' "$WORKFLOW" | head -1 | cut -d: -f1)
  [ -n "$start" ] && [ -n "$end" ] && [ "$end" -gt "$start" ]
  { echo 'set -euo pipefail'
    sed -n "${start},$((end - 1))p" "$WORKFLOW" \
      | sed 's/^          //' \
      | sed 's|changed=\$(git diff --name-only "\$BASE_SHA\.\.\.\$HEAD_SHA")|changed="$CHANGED"|'
  } > "$script"
  printf '%s' "$script"
}

# Runs detect for the given changed files; leaves its outputs in $OUT.
_detect() {
  local script
  script="$(_detect_script)"
  OUT="$BATS_TEST_TMPDIR/out"
  : > "$OUT"
  (cd "$ROOT" && CHANGED="$(printf '%s\n' "$@")" GITHUB_OUTPUT="$OUT" RUNNER_TEMP="$BATS_TEST_TMPDIR" bash "$script") > "$BATS_TEST_TMPDIR/log" 2>&1
}

_out() { sed -n "s/^$1=//p" "$OUT"; }

# The set the workflow should derive, computed here the same way.
_expected_set() {
  (cd "$ROOT" && grep -lE 'SKILL\.md|template\.md|skill-render|render-plugin-skill|README(\.ja)?\.md' tests/*.bats | LC_ALL=C sort)
}

# A grep that answers the skill-set query with a chosen result and passes
# every other call to the real grep.
_fake_grep() {
  local real dir="$BATS_TEST_TMPDIR/fakebin"
  real="$(command -v grep)"
  mkdir -p "$dir"
  cat > "$dir/grep" <<EOF2
#!/usr/bin/env bash
case "\$*" in
  *skill-render*)
    case "\$FAKE_SKILL_GREP" in
      empty) exit 1 ;;
      partial) echo tests/test_install.bats; exit 2 ;;
    esac ;;
esac
exec "$real" "\$@"
EOF2
  chmod +x "$dir/grep"
  PATH="$dir:$PATH"
}

@test "ci-skill-set: prose plus skill files run only the derived skill test set" {
  _detect SKILL.md README.md README.ja.md docs/x.md scripts/drivers/types/codex/template.md scripts/drivers/terminals/codex-app/README.md
  [ "$(_out skill_only)" = true ]
  [ "$(_out docs_only)" = false ]
  [ "$(_out contracts_needed)" = false ]
  local skip expected all
  skip="$(_out bats_skip | tr ',' '\n' | LC_ALL=C sort)"
  expected="$(_expected_set)"
  all="$(cd "$ROOT" && find tests -maxdepth 1 -name '*.bats' | LC_ALL=C sort)"
  [ -n "$expected" ]
  # Every file runs or is skipped, never both, and what runs is the set.
  [ "$(printf '%s\n%s\n' "$skip" "$expected" | LC_ALL=C sort)" = "$all" ]
  grep -qx 'tests/test_install.bats' <<<"$expected"
  refute grep -qx 'tests/test_install.bats' <<<"$skip"
}

@test "ci-skill-set: a skill file together with code takes the normal path" {
  _detect SKILL.md scripts/daemon.sh
  [ "$(_out skill_only)" = false ]
  [ "$(_out docs_only)" = false ]
  [ "$(_out contracts_needed)" = true ]
}

@test "ci-skill-set: prose alone is still docs-only" {
  _detect ARCHITECTURE.ja.md CONTRIBUTING.ja.md SECURITY.md docs/x.md
  [ "$(_out docs_only)" = true ]
  [ "$(_out skill_only)" = false ]
}

@test "ci-skill-set: an empty skill set runs the whole suite, with no per-file selection" {
  _fake_grep
  FAKE_SKILL_GREP=empty _detect SKILL.md
  [ "$(_out skill_only)" = false ]
  [ "$(_out docs_only)" = false ]
  [ "$(_out contracts_needed)" = true ]
  [ -z "$(_out bats_skip)" ]
}

@test "ci-skill-set: a grep that fails part way is not trusted, even with partial output" {
  _fake_grep
  FAKE_SKILL_GREP=partial _detect SKILL.md
  [ "$(_out skill_only)" = false ]
  [ "$(_out contracts_needed)" = true ]
  [ -z "$(_out bats_skip)" ]
}

# The Windows legs' decision step, run with the inputs each case names.
_leg() {
  local script="$BATS_TEST_TMPDIR/leg.sh" start end
  start=$(grep -n 'name: Decide whether this leg runs' "$WORKFLOW" | head -1 | cut -d: -f1)
  [ -n "$start" ]
  start=$(awk -v s="$start" 'NR > s && /^        run: \|/ { print NR; exit }' "$WORKFLOW")
  end=$(awk -v s="$start" 'NR > s && !/^          / && !/^$/ { print NR; exit }' "$WORKFLOW")
  [ -n "$start" ] && [ -n "$end" ]
  sed -n "$((start + 1)),$((end - 1))p" "$WORKFLOW" | sed 's/^          //' > "$script"
  OUT="$BATS_TEST_TMPDIR/leg-out"
  : > "$OUT"
  DOCS_ONLY="$1" SKILL_ONLY="$2" BATS_SKIP="$3" TARGET="$4" GITHUB_OUTPUT="$OUT" bash "$script" >/dev/null
  _out run
}

@test "ci-skill-set: a Windows leg runs on a skill-only diff only when a target is in the set" {
  [ "$(_leg false true 'tests/test_a.bats,tests/test_b.bats' 'tests/test_install.bats')" = true ]
  [ "$(_leg false true 'tests/test_install.bats,tests/test_b.bats' 'tests/test_install.bats')" = false ]
  [ "$(_leg false true 'tests/test_codex_monitor.bats' 'tests/test_codex_monitor.bats tests/test_codex_bridge_launcher.bats')" = true ]
  [ "$(_leg false true 'tests/test_codex_monitor.bats,tests/test_codex_bridge_launcher.bats' 'tests/test_codex_monitor.bats tests/test_codex_bridge_launcher.bats')" = false ]
  [ "$(_leg true false '' 'tests/test_install.bats')" = false ]
  [ "$(_leg false false 'tests/test_install.bats' 'tests/test_install.bats')" = true ]
}

