#!/usr/bin/env bats
#
# A pull request runs the macOS legs of the suite only when its diff can behave
# differently there (.github/scripts/mac-needed.mjs, rows in mac-patterns.tsv).
# These pin each pattern, the path rules, and the direction every doubt leans:
# toward running macOS.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MAC="$REPO_ROOT/.github/scripts/mac-needed.mjs"
  PATS="$REPO_ROOT/.github/scripts/mac-patterns.tsv"
}

# decide <changed-path> <added-line> : prints the answer; file name decides which
# added lines are looked at.
decide() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/changed.txt"
  printf '+++ b/%s\n@@ -0,0 +1 @@\n+%s\n' "$1" "$2" > "$BATS_TEST_TMPDIR/diff.txt"
  node "$MAC" --changed "$BATS_TEST_TMPDIR/changed.txt" --diff "$BATS_TEST_TMPDIR/diff.txt" | cut -d' ' -f1
}

# One line that must match and one that must not, per pattern row.
fixture() {
  case "$1" in
    sed-in-place) POS='sed -i "s/a/b/" f';                NEG='sed -n "1p" f' ;;
    sed-gnu-extension) POS='sed -r "s/(a)/\1/" f';       NEG='sed "s/a/b/" f' ;;
    date-gnu-bsd) POS='date -d "1 day ago" +%s';          NEG='date +%s' ;;
    stat-format) POS='stat -c %s file';                   NEG='stat file' ;;
    readlink-f) POS='readlink -f "$p"';                   NEG='readlink "$p"' ;;
    grep-perl) POS='grep -P "\d+" f';                     NEG='grep -E "[0-9]+" f' ;;
    xargs-r) POS='ls | xargs -r rm';                      NEG='ls | xargs rm' ;;
    find-printf) POS='find . -printf "%p\n"';             NEG='find . -name x' ;;
    mktemp-gnu) POS='mktemp --suffix=.x';                 NEG='mktemp -d' ;;
    base64-decode) POS='echo x | base64 -d';              NEG='echo x | base64' ;;
    sort-version) POS='sort -V list';                     NEG='sort -u list' ;;
    timeout-cmd) POS='timeout 5 cmd';                     NEG='echo timeouts are fine' ;;
    awk-gnu) POS='awk "{print strftime()}"';              NEG='awk "{print \$1}"' ;;
    tac) POS='cat f | tac';                               NEG='echo tactics' ;;
    checksum-tools) POS='sha256sum f';                    NEG='echo hash' ;;
    ps-format) POS='ps -o pid= -p 1';                     NEG='echo ps' ;;
    lsof) POS='lsof -p 1';                                NEG='echo flsofx' ;;
    platform-word) POS='[ "$(uname)" = Darwin ]';         NEG='echo hello' ;;
    *) return 1 ;;
  esac
}

@test "every pattern row has a fixture, matches its positive line and not its negative one" {
  local name n=0
  while IFS=$'\t' read -r name _; do
    case "$name" in ''|'#'*) continue ;; esac
    fixture "$name" || { echo "no fixture for pattern: $name"; return 1; }
    [ "$(decide scripts/x.sh "$POS")" = true ] || { echo "no match for $name: $POS"; return 1; }
    [ "$(decide scripts/x.sh "$NEG")" = false ] || { echo "false match for $name: $NEG"; return 1; }
    n=$((n + 1))
  done < "$PATS"
  [ "$n" -ge 15 ]
}

@test "an added line in a file that is not shell or JavaScript is not looked at" {
  [ "$(decide docs/notes.md 'sed -i is mentioned here')" = false ]
  [ "$(decide app/src/App.tsx 'const x = "Darwin"')" = false ]
}

@test "a diff with nothing macOS-sensitive in it does not need macOS" {
  [ "$(decide scripts/send.sh 'echo "$msg" >> "$log"')" = false ]
  [ "$(decide tests/test_send.bats '  [ "$status" -eq 0 ]')" = false ]
}

@test "the CI definition, compat.sh, an installer, the daemon and macOS-named files always need macOS" {
  local p
  for p in .github/workflows/tests.yml scripts/lib/compat.sh install.sh uninstall.sh setup.sh scripts/daemon.sh scripts/daemon/main.mjs \
           scripts/lib/launchd-unit.sh tests/test_macos_paths.bats scripts/darwin-helper.sh; do
    [ "$(decide "$p" 'echo plain')" = true ] || { echo "not needed for $p"; return 1; }
  done
}

@test "a removed line alone is not a reason" {
  printf 'scripts/x.sh\n' > "$BATS_TEST_TMPDIR/changed.txt"
  printf '+++ b/scripts/x.sh\n@@ -1 +0,0 @@\n-sed -i s/a/b/ f\n' > "$BATS_TEST_TMPDIR/diff.txt"
  run node "$MAC" --changed "$BATS_TEST_TMPDIR/changed.txt" --diff "$BATS_TEST_TMPDIR/diff.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == false* ]]
}

@test "any failure to decide answers with an error and no verdict, which the workflow reads as needed" {
  : > "$BATS_TEST_TMPDIR/empty"
  printf 'scripts/x.sh\n' > "$BATS_TEST_TMPDIR/changed.txt"
  printf '+++ b/scripts/x.sh\n+echo\n' > "$BATS_TEST_TMPDIR/diff.txt"
  # empty changed list
  run bash -c 'node "$1" --changed "$2" --diff "$3" 2>/dev/null' _ "$MAC" "$BATS_TEST_TMPDIR/empty" "$BATS_TEST_TMPDIR/diff.txt"
  [ "$status" -ne 0 ]; [ -z "$output" ]
  # empty diff
  run bash -c 'node "$1" --changed "$2" --diff "$3" 2>/dev/null' _ "$MAC" "$BATS_TEST_TMPDIR/changed.txt" "$BATS_TEST_TMPDIR/empty"
  [ "$status" -ne 0 ]; [ -z "$output" ]
  # missing pattern table
  run bash -c 'node "$1" --changed "$2" --diff "$3" --patterns /no/such 2>/dev/null' _ "$MAC" "$BATS_TEST_TMPDIR/changed.txt" "$BATS_TEST_TMPDIR/diff.txt"
  [ "$status" -ne 0 ]; [ -z "$output" ]
  # a malformed pattern row
  printf 'oops-no-tab\n' > "$BATS_TEST_TMPDIR/bad.tsv"
  run bash -c 'node "$1" --changed "$2" --diff "$3" --patterns "$4" 2>/dev/null' _ "$MAC" "$BATS_TEST_TMPDIR/changed.txt" "$BATS_TEST_TMPDIR/diff.txt" "$BATS_TEST_TMPDIR/bad.tsv"
  [ "$status" -ne 0 ]; [ -z "$output" ]
}
