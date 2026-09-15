#!/usr/bin/env bash
#
# Fail when the bats suite grows an assertion that cannot fail.
#
# Measured, not assumed (#670). A false assertion in a NON-LAST position of a
# `@test` body, one construct per row, with the interpreter printed from inside
# the body:
#
#                        bash 3.2.57   bash 5.3.15
#   [ 1 -eq 2 ]          not ok        not ok
#   test 1 -eq 2         not ok        not ok
#   false                not ok        not ok
#   echo a | grep -q b   not ok        not ok
#   [[ a == b ]]         OK            not ok      <- macOS only
#   (( 1 == 2 ))         OK            not ok      <- macOS only
#   ! true               OK            OK          <- everywhere
#
# In the LAST position everything is enforced on both: that is the body's own
# exit status, not errexit. So what this looks for is a construct that does not
# trip errexit, sitting anywhere but last.
#
# CI runs bats on macOS, whose `/bin/bash` is 3.2. An assertion in that state
# reports `ok` with a false claim inside it, which is indistinguishable from a
# check that was never written.
#
# WHAT IS EXCLUDED, and why:
#   - anything inside `if` / `while` / `until` / `for` / `case`: a failure
#     there is a condition being evaluated, not an unhandled error
#   - anything chained with `||` or `&&`: explicit control, enforced on both
#   - the body's last statement: it IS the result
#
# The baseline is a COUNT, not a file:line list, so moving a test between files
# does not produce a spurious failure. It may only go down. Lowering it is the
# burn-down; raising it is the thing this exists to stop.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Overridable so the checker can be exercised against a fixture tree. A guard
# that can only be run against the real, already-clean tree has never been
# shown to fire.
BASELINE_FILE="${AGMSG_ASSERTION_BASELINE:-$ROOT/.github/enforced-assertions-baseline}"
TESTS_DIR="${1:-$ROOT/tests}"

count_and_list() {
  python3 - "$1" <<'PY'
import re, sys, pathlib
OPENERS = re.compile(r'^(if|while|until|for|case)\b')
def kind(s):
    if s.startswith('[['): return '[[ ]]'
    if s.startswith('(('): return '(( ))'
    if s.startswith('! '): return '! negated'
    return None
rows = []
for f in sorted(pathlib.Path(sys.argv[1]).glob('*.bats')):
    lines = f.read_text().splitlines()
    i = 0
    while i < len(lines):
        if not re.match(r'\s*@test\s', lines[i]):
            i += 1; continue
        j = i + 1; body = []
        while j < len(lines) and lines[j].rstrip() != '}':
            body.append((j + 1, lines[j])); j += 1
        depth = 0; stmts = []
        for n, l in body:
            s = l.strip()
            if not s or s.startswith('#'): continue
            if depth == 0: stmts.append((n, s))
            depth += len(re.findall(r'\b(if|while|until|for|case)\b', s)) if OPENERS.match(s) else 0
            depth -= len(re.findall(r'\b(fi|done|esac)\b', s))
            if depth < 0: depth = 0
        if stmts:
            last = stmts[-1][0]
            for n, s in stmts:
                if re.search(r'\|\||&&', s): continue
                k = kind(s)
                if k and n != last:
                    rows.append(f"{f.name}:{n}: [{k}] {s[:70]}")
        i = j + 1
for r in rows: print(r)
PY
}

listing="$(count_and_list "$TESTS_DIR")"
if [ -z "$listing" ]; then
  found=0
else
  found="$(printf '%s\n' "$listing" | wc -l | tr -d '[:space:]')"
fi

# Scanning nothing is not a pass. A tests dir that stopped matching -- a move,
# a rename, a wrong argument -- must say so rather than report a clean tree it
# never opened.
if [ ! -d "$TESTS_DIR" ] || [ -z "$(find "$TESTS_DIR" -maxdepth 1 -name '*.bats' -print -quit)" ]; then
  echo "check-enforced-assertions: no .bats files under $TESTS_DIR; this is not a clean tree." >&2
  exit 2
fi

baseline="$(tr -d '[:space:]' < "$BASELINE_FILE" 2>/dev/null || echo '')"
case "$baseline" in
  ''|*[!0-9]*)
    echo "check-enforced-assertions: no readable baseline at $BASELINE_FILE" >&2
    exit 2 ;;
esac

if [ "$found" -gt "$baseline" ]; then
  over=$((found - baseline))
  echo "check-enforced-assertions: $found unenforceable assertions, baseline is $baseline (+$over)." >&2
  echo >&2
  # Say what the list is before printing it. It is every offender in the tree,
  # and on a typical red that is hundreds of lines around a `+1`. Four people
  # read this output on one red and each drew a different wrong conclusion --
  # the first file in the list taken as the cause, a hundred-line diff between
  # two heads read as a hundred new offenders (line numbers shift below any
  # insertion), and from that a guess that the listing must be truncated. It is
  # not truncated; it is complete, unordered by novelty, and unlabelled.
  #
  # No state is added here on purpose. Storing the previous offender set beside
  # the count would let this name the new entries directly, but it introduces a
  # second thing to keep in sync with the first, and a listing that disagrees
  # with the count is the same confusion wearing different clothes. The count
  # stays the only authority; what changes is that the output stops implying
  # otherwise. See #892.
  if [ "$over" -eq 1 ]; then
    echo "One assertion pushed this over. The list below is EVERY unenforceable" >&2
  else
    echo "$over assertions pushed this over. The list below is EVERY unenforceable" >&2
  fi
  echo "assertion in the tree, not the new one(s) -- nothing here marks which." >&2
  echo "To find them: run this checker at the previous commit and compare the" >&2
  echo "counts, bisecting until the count changes. Comparing the listings does" >&2
  echo "not work; a line added anywhere shifts every line number below it." >&2
  echo >&2
  printf '%s\n' "$listing" | sed 's/^/  /' >&2
  echo >&2
  echo "A non-last \`[[ ]]\`, \`(( ))\` or \`! cmd\` cannot fail the test on macOS" >&2
  echo "(bash 3.2), and \`! cmd\` cannot fail it anywhere. Use \`[ ]\`, a plain" >&2
  echo "command, or the \`refute\` helper; see #670." >&2
  exit 1
fi

if [ "$found" -lt "$baseline" ]; then
  echo "check-enforced-assertions: $found unenforceable assertions, below the baseline of $baseline."
  echo "Lower the baseline in $BASELINE_FILE to $found so it cannot drift back up."
  exit 1
fi

echo "check-enforced-assertions: $found unenforceable assertions, at the baseline ($baseline)."
