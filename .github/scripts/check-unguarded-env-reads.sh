#!/usr/bin/env bash
#
# Fail when `scripts/**/*.sh` grows a read of an ENVIRONMENT variable with no
# default, under shell options that make such a read fatal.
#
# WHY THIS IS STATIC, and not a test (#1129). Every entry point that reaches
# these files runs `set -euo pipefail` -- join.sh, actas-claim.sh, watch.sh,
# session-start.sh, inbox.sh and the rest. The bats suite does not: measured,
# `tests/test_helper.bash` sets no shell options at all, so a read that is only
# fatal under `-u` cannot fire inside a test.
#
# That was measured, not assumed. Forcing `set -u` into the shared test helper
# and running all 102 suites produced 8 reds, and NONE of them was a defect in
# `scripts/`: five were tests reading their own undefined variables, one was an
# artefact of where the option was placed, and two did not reproduce in
# isolation. Then the method was CALIBRATED against the one confirmed defect of
# this class -- #1126, `sock="${TMUX%%,*}"` with no default, which killed the
# tmux label search in a subshell whose caller discarded stderr. With `set -u`
# forced, `test_terminal_registry` on the tree that still contained it was
# 129/129 GREEN. The suite cannot see this class, so the guard has to be static.
#
# WHAT COUNTS AS A FINDING
#   a read of an ALL-CAPS name that
#     - is never assigned anywhere in the same file (so it comes from the
#       environment or from a caller's export), and
#     - is read without a default: `$NAME`, `${NAME}`, `${NAME%%,*}`, and
#     - is not already guarded, in the same function, by an earlier
#       `[ -n "${NAME:-}" ]` / `[ -z "${NAME:-}" ]`.
#
# The guard clause is what lets this go DOWN as well as up, and it was the
# difference between a calibrated check and a decorative one. Measured on three
# trees:
#
#   040a4c7  before #1112 introduced the defect      89
#   07d76ef  with the defect present                 90   <- the new row is the defect
#   b3fe77d  after #1126 guarded it                  89
#
# Without the guard clause the count was 147 / 147 / 147: it would not have
# moved when the defect landed OR when it was fixed.
#
# TWO WAYS TO BURN ONE DOWN, and they are not equal. Giving the read a default
# (`${NAME:-}`) is the one that also makes the code correct wherever it runs.
# Adding a `[ -n "${NAME:-}" ]` guard in the same function is accepted here
# because it is what the tmux driver's own `terminal_detect` does and it makes
# an honest refusal -- but it only protects the reads BELOW it in that function.
#
# WHAT THIS DOES NOT SEE, said plainly so nobody reads a pass as a promise:
#   - a variable assigned somewhere in the file and read before that line
#   - a guard in a CALLER rather than in the same function
#   - `${NAME:-}` used where a missing value is not actually acceptable
# The baseline is a COUNT, so it certifies nothing about the rows already in it.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Overridable so the checker can be exercised against a fixture tree. A guard
# that can only be run against the real, already-clean tree has never been shown
# to fire.
BASELINE_FILE="${AGMSG_ENV_READS_BASELINE:-$ROOT/.github/unguarded-env-reads-baseline}"
SCAN_DIR="${1:-$ROOT/scripts}"

count_and_list() {
  python3 - "$1" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
READ  = re.compile(r'\$\{([A-Z][A-Z0-9_]*)(:[-+?]|[-+?])?[^}]*\}|\$([A-Z][A-Z0-9_]*)\b')
GUARD = re.compile(r'\[\s+-[nz]\s+"\$\{([A-Z][A-Z0-9_]*):-[^}]*\}"')
FUNC  = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{')
# Shell-provided or set-by-the-OS-everywhere: reading these unguarded is not the
# hazard this looks for.
SPECIAL = {'BASH_SOURCE','FUNCNAME','BASH_REMATCH','PIPESTATUS','OPTARG','OPTIND',
           'RANDOM','LINENO','SECONDS','BASHPID','BASH_VERSINFO','EUID','UID','PPID',
           'HOSTNAME','OSTYPE','MACHTYPE','SHLVL','REPLY','IFS','PATH','HOME','PWD',
           'TMPDIR','USER','SHELL','LANG','LC_ALL','TERM','COLUMNS','LINES','EDITOR'}
rows = []
for f in sorted(root.rglob('*.sh')):
    txt = f.read_text(errors='replace')
    guarded = set()
    for i, line in enumerate(txt.splitlines(), 1):
        if FUNC.match(line):
            guarded = set()
        elif line == '}':
            guarded = set()
        s = line.strip()
        if s.startswith('#'):
            continue
        for g in GUARD.finditer(line):
            guarded.add(g.group(1))
        for m in READ.finditer(line):
            name = m.group(1) or m.group(3)
            op   = m.group(2)
            if not name or name in SPECIAL or op or name in guarded:
                continue
            if re.search(r'(?<![A-Za-z0-9_])' + name + r'=(?!=)', txt):
                continue
            if re.search(r'\b(?:for|read)\b[^\n]*\b' + name + r'\b', txt):
                continue
            rows.append("%s:%d: $%s   %s" % (f.relative_to(root), i, name, s[:72]))
for r in rows:
    print(r)
PY
}

# Scanning nothing is not a pass. A directory that stopped matching -- a move, a
# rename, a wrong argument -- must say so rather than report a clean tree it
# never opened.
if [ ! -d "$SCAN_DIR" ] || [ -z "$(find "$SCAN_DIR" -name '*.sh' -print -quit)" ]; then
  echo "check-unguarded-env-reads: no .sh files under $SCAN_DIR; this is not a clean tree." >&2
  exit 2
fi

listing="$(count_and_list "$SCAN_DIR")"
if [ -z "$listing" ]; then
  found=0
else
  found="$(printf '%s\n' "$listing" | wc -l | tr -d '[:space:]')"
fi

baseline="$(tr -d '[:space:]' < "$BASELINE_FILE" 2>/dev/null || echo '')"
case "$baseline" in
  ''|*[!0-9]*)
    echo "check-unguarded-env-reads: no readable baseline at $BASELINE_FILE" >&2
    exit 2 ;;
esac

if [ "$found" -gt "$baseline" ]; then
  echo "check-unguarded-env-reads: $found unguarded environment reads, baseline is $baseline." >&2
  echo >&2
  printf '%s\n' "$listing" | sed 's/^/  /' >&2
  echo >&2
  echo "Every entry point that reaches these files runs 'set -euo pipefail', so a" >&2
  echo "read with no default kills the shell -- and inside a command substitution" >&2
  echo "whose caller discards stderr, it does so silently. Give the read a default" >&2
  echo "(\${NAME:-}), or guard the function with [ -n \"\${NAME:-}\" ] and refuse." >&2
  echo "The test suite cannot catch this: it runs with no shell options (#1129)." >&2
  exit 1
fi

echo "check-unguarded-env-reads: $found unguarded environment reads, at the baseline ($baseline)."
