#!/usr/bin/env bash
#
# Fail when a script grows a `$?` read that errexit never lets it reach — or
# that it reaches only to find a 0 that means nothing.
#
# Measured, not assumed. Each row run as `bash -c 'set -e; <form>'` on both
# interpreters this project ships against:
#
#                                          bash 3.2.57      bash 5.3.15
#   x=$(false); rc=$?; echo $rc            shell dies       shell dies
#   local x=$(false); rc=$?; echo $rc      rc=0, survives   rc=0, survives
#   declare x=$(false); rc=$?              rc=0, survives   rc=0, survives
#   export x=$(false); rc=$?               rc=0, survives   rc=0, survives
#   x=$(false) || rc=$?                    rc=1             rc=1
#   if x=$(false); then :; fi              not fatal        not fatal
#   f() { . failing.sh; rc=$?; }           shell dies       rc=1, survives   <- differs
#   f() { . failing.sh || rc=$?; }         shell dies       rc=1, survives   <- differs
#
# Three ways to be wrong, one shape to look for — a status read that follows
# something errexit already decided:
#
#   [bare]    x=$(cmd)          the assignment's status IS the substitution's,
#             rc=$?             so a non-zero one kills the shell HERE. The
#                               next line is unreachable; the handler it feeds
#                               has never run.
#
#   [decl]    local x=$(cmd)    `local`/`declare`/`typeset`/`export`/`readonly`
#             rc=$?             is a builtin whose own status wins. The shell
#                               survives and `rc` is ALWAYS 0 — a handler that
#                               reads as present and can never fire. This is
#                               the quiet one; nothing crashes.
#
#   [source]  . file            On bash 3.2 a failing command at the top of a
#             rc=$?             sourced file fires the CALLER's errexit, and it
#                               does so EVEN with `|| rc=$?` on the source line
#                               (measured; the `||` does not save 3.2). macOS
#                               /bin/bash is 3.2, so this is a macOS-only death
#                               that passes every Linux run.
#
# The accepted fix for all three is the codebase's two-line lift — see
# `agmsg_terminal_load` in scripts/lib/terminal-registry.sh:
#
#     local rc=0 restore_e=0
#     case $- in *e*) restore_e=1 ;; esac
#     set +e
#     x=$(cmd)          # or `. file`
#     rc=$?
#     [ "$restore_e" = 1 ] && set -e
#
# so a statement sitting between `set +e` and `set -e` is NOT flagged: that is
# the fix, not the defect. `|| rc=$?` is not flagged either for [bare]/[decl]
# (measured correct on both shells) — but it does NOT clear [source].
#
# WHAT IS EXCLUDED, and why:
#   - anything between `set +e` and the next `set -e`: errexit is lifted, which
#     is the whole point of lifting it
#   - a statement carrying `||` or `&&`: explicit control (except [source])
#   - the condition of `if` / `while` / `until`: errexit does not apply there
#
# The baseline is a COUNT, not a file:line list, so moving code between files
# does not produce a spurious failure. It may only go down.
#
# WHY THIS CANNOT PASS BY FAILING TO LOOK: before it reports anything about the
# tree, it runs the same scanner over a fixture holding one known-bad instance
# of each kind and requires all three back. A regex that stops matching — a
# refactor, a quoting change, a wrong path — then exits 2 (could not answer)
# instead of 0 (nothing found). "Zero" is only ever printed by a scanner that
# has just proved it can find one.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASELINE_FILE="${AGMSG_ERREXIT_BASELINE:-$ROOT/.github/errexit-status-reads-baseline}"
SCAN_DIR="${1:-$ROOT/scripts}"

scan() {
  python3 - "$1" <<'PY'
import re, sys, pathlib

ASSIGN = re.compile(r'^(?P<decl>local|declare|typeset|export|readonly)?\s*'
                    r'(?P<name>[A-Za-z_][A-Za-z0-9_]*)=(?P<rhs>.*)$', re.S)
SOURCEC = re.compile(r'^(\.|source)\s+\S')
# A status READ is an assignment whose whole value is `$?` -- `rc=$?`,
# `local rc=$?`. A statement that merely CONTAINS `$?` is not one: the
# `|| vrc=$?` on a guarded assignment is that assignment's own handling,
# and reporting the line before it (herdr/ops.sh:60) was a false positive.
STATUS  = re.compile(r'^(local|declare|typeset|export|readonly)?\s*[A-Za-z_][A-Za-z0-9_]*=\$\?\s*$')
COND    = re.compile(r'^(if|while|until|elif)\b')
SETPLUS = re.compile(r'^set\s+\+[a-zA-Z]*e')
SETMINUS= re.compile(r'^set\s+-[a-zA-Z]*e')

def split_statements(text):
    """Walk the file once, tracking quote state and $( ) nesting ACROSS LINES.

    Splitting per line is what made this wrong: a SQL string that opens on one
    line and closes on another left every `;` between them looking like a
    statement separator, so

        x="$(sqlite3 :memory: "SELECT ... LIMIT 1;" 2>/dev/null)" || rc=$?

    was cut in half and its `|| rc=$?` guard was reported as an unguarded bare
    assignment. A checker that reports the correct form gets worked around, and
    a worked-around checker passes while guarding nothing.

    A command substitution opens a FRESH quoting context even when it appears
    inside double quotes -- `"$( ... "inner" ... )"` is one word to bash, and
    the inner quotes are the substitution's, not the outer string's. So the
    quote character is pushed on entering `$(` and restored on the matching
    `)`. Modelling that as a flat flag is what let the first fix swallow a real
    instance: the `"` right after `$(` read as CLOSING the outer string, and
    everything after it fell out of the statement."""
    out = []
    buf, start = '', None
    line = 1
    q = None            # active quote char in the CURRENT context
    stack = []          # saved quote chars, one per open $(
    i, n = 0, len(text)
    while i < n:
        c = text[i]

        if c == '\n':
            here = line
            line += 1
            if q is None and not stack:
                if buf.strip():
                    out.append((start or here, buf.strip()))
                buf, start = '', None
            else:
                buf += c
            i += 1
            continue

        # inside single quotes nothing is special but the closing quote
        if q == "'":
            buf += c
            if c == "'":
                q = None
            i += 1
            continue

        # command substitution opens a new quoting context, double quotes or not
        if text[i:i+2] == '$(':
            stack.append(q)
            q = None
            buf += '$('
            if start is None:
                start = line
            i += 2
            continue

        if c == ')' and stack and q is None:
            q = stack.pop()
            buf += c
            i += 1
            continue

        if q == '"':
            buf += c
            if c == '"' and text[i-1] != '\\':
                q = None
            i += 1
            continue

        # unquoted, at some $( depth or none
        if c in ('"', "'"):
            q = c
            buf += c
            if start is None:
                start = line
            i += 1
            continue

        if c == '#' and not buf.strip() and not stack:
            while i < n and text[i] != '\n':
                i += 1
            continue

        if c == ';' and not stack:
            if buf.strip():
                out.append((start or line, buf.strip()))
            buf, start = '', None
            i += 1
            continue

        buf += c
        if start is None and c.strip():
            start = line
        i += 1

    if buf.strip():
        out.append((start or line, buf.strip()))
    return out

rows = []
for f in sorted(pathlib.Path(sys.argv[1]).rglob('*.sh')):
    lifted = False
    prev = None
    for n, st in split_statements(f.read_text(errors='replace')):
        if SETPLUS.match(st):
            lifted = True; prev = (n, st); continue
        if SETMINUS.match(st):
            lifted = False; prev = (n, st); continue

        if prev and STATUS.match(st) and not lifted:
            pn, ps = prev
            if not COND.match(ps):
                m = ASSIGN.match(ps)
                guarded = re.search(r'\|\||&&', ps)
                kind = None
                if m and ('$(' in m.group('rhs') or '`' in m.group('rhs')):
                    if not guarded:
                        kind = 'decl' if m.group('decl') else 'bare'
                elif SOURCEC.match(ps):
                    kind = 'source'
                if kind:
                    flat = ' '.join(ps.split())
                    rows.append(f"{f}:{n}: [{kind}] {flat[:60]} -> {' '.join(st.split())[:40]}")
        prev = (n, st)

for r in rows:
    print(r)
PY
}

# ---- positive control: prove the scanner can still find each known-bad kind --
control_dir="$(mktemp -d)"
trap 'rm -rf "$control_dir"' EXIT
cat > "$control_dir/control.sh" <<'CTL'
#!/usr/bin/env bash
set -e
bare_case() {
  local out
  out="$(some_command)"
  rc=$?
  [ "$rc" -eq 0 ] || return 1
}
decl_case() {
  local out="$(some_command)"
  local rc=$?
  [ "$rc" -eq 0 ] || return 1
}
source_case() {
  . "$dir/ops.sh"
  rc=$?
  [ "$rc" -eq 0 ] || return 1
}
lifted_case() {          # the accepted fix — must NOT be reported
  set +e
  out="$(some_command)"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || return 1
}
guarded_case() {         # explicit control — must NOT be reported
  out="$(some_command)" || rc=$?
  [ "${rc:-0}" -eq 0 ] || return 1
}
sql_guarded_case() {     # the false positive that cost a workaround — must NOT
                         # be reported. The `;` sits inside a double-quoted SQL
                         # string that OPENS on one line and CLOSES on another.
  local out rc=0
  out="$(sqlite3 :memory: "
    SELECT json_extract(value,'$.pane_id')
    FROM json_each('$j')
    LIMIT 1;" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 2
}
sql_bare_case() {        # the same multi-line SQL shape, genuinely unguarded —
                         # MUST still be reported, or the splitter fix would have
                         # bought a false negative in place of a false positive.
  local out
  out="$(sqlite3 :memory: "
    SELECT 1;" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] || return 2
}
CTL
control="$(scan "$control_dir")"
# The multi-line SQL bare case must come back BY NAME, not merely by kind: the
# kinds are covered below, and what this proves is the other direction — that a
# quoted string spanning lines cannot swallow a real instance.
case "$control" in
  *sql_bare_case*|*"SELECT 1"*) ;;
  *)
    echo "check-errexit-status-reads: positive control did not report the multi-line" >&2
    echo "SQL bare case; the splitter can be made to hide a real one." >&2
    printf '%s\n' "$control" | sed 's/^/  /' >&2
    exit 2 ;;
esac
for kind in bare decl source; do
  case "$control" in
    *"[$kind]"*) ;;
    *)
      echo "check-errexit-status-reads: positive control did not report [$kind]." >&2
      echo "The scanner cannot find a form it is supposed to find, so a count of" >&2
      echo "zero from the tree would mean nothing. Fix the scanner, not the tree." >&2
      printf '%s\n' "$control" | sed 's/^/  /' >&2
      exit 2 ;;
  esac
done
# and the two correct forms must not be reported, or every fix would look like
# a defect and the baseline could never come down
for bad in lifted_case guarded_case sql_guarded_case; do
  case "$control" in
    *"$bad"*)
      echo "check-errexit-status-reads: positive control reported $bad, which is the" >&2
      echo "accepted form. The scanner would flag the fix; that is not usable." >&2
      exit 2 ;;
  esac
done

# ---- the tree ---------------------------------------------------------------
if [ ! -d "$SCAN_DIR" ] || [ -z "$(find "$SCAN_DIR" -name '*.sh' -print -quit)" ]; then
  echo "check-errexit-status-reads: no .sh files under $SCAN_DIR; this is not a clean tree." >&2
  exit 2
fi

listing="$(scan "$SCAN_DIR")"
if [ -z "$listing" ]; then
  found=0
else
  found="$(printf '%s\n' "$listing" | wc -l | tr -d '[:space:]')"
fi

baseline="$(tr -d '[:space:]' < "$BASELINE_FILE" 2>/dev/null || echo '')"
case "$baseline" in
  ''|*[!0-9]*)
    echo "check-errexit-status-reads: no readable baseline at $BASELINE_FILE" >&2
    exit 2 ;;
esac

if [ "$found" -gt "$baseline" ]; then
  echo "check-errexit-status-reads: $found status reads after an errexit decision, baseline is $baseline." >&2
  echo >&2
  printf '%s\n' "$listing" | sed 's/^/  /' >&2
  echo >&2
  echo "[bare]   the shell dies at the assignment; the \$? line never runs." >&2
  echo "[decl]   local/declare/export wins the status; \$? is ALWAYS 0." >&2
  echo "[source] bash 3.2 (macOS /bin/bash) dies here even with \`|| rc=\$?\`." >&2
  echo >&2
  echo "Lift errexit around it and restore it, as agmsg_terminal_load does:" >&2
  echo "  case \$- in *e*) restore_e=1 ;; esac; set +e; x=\$(cmd); rc=\$?; [ \"\$restore_e\" = 1 ] && set -e" >&2
  exit 1
fi

if [ "$found" -lt "$baseline" ]; then
  echo "check-errexit-status-reads: $found status reads after an errexit decision, below the baseline of $baseline."
  echo "Lower the baseline in $BASELINE_FILE to $found so it cannot drift back up."
  exit 1
fi

echo "check-errexit-status-reads: $found status reads after an errexit decision, at the baseline ($baseline)."
