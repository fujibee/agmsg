#!/usr/bin/env python3
"""static_deps.py -- static "which repo files can this bats file read" analysis
for fujibee/agmsg.

usage: python3 -I static_deps.py <repo-root> <out-dir>

For every tests/*.bats it computes the tracked repo files the test file can read:
  * the test file itself, the helpers it `load`s, and only the test_helper.bash
    functions it actually calls (setup_test_env -> scripts/internal/init-db.sh);
  * every path expression in the file that resolves to a tracked file:
    $SCRIPTS/..., $TEST_SKILL_DIR/scripts/..., $TYPES/..., "$BATS_TEST_DIRNAME/../...",
    "$SK/scripts/..." of an install sandbox (".../skills/<name>/..." suffix),
    plain 'scripts/x.sh' / 'tests/fixtures/x' literals, ./install.sh, ...;
  * transitively, the same inside every script reached: source/., exec, bash/node/
    python3 X, "$SCRIPT_DIR/x.sh", "$(dirname "$0")/x.sh", "${BASH_SOURCE%/*}/x.sh",
    "$SKILL_DIR/scripts/x.sh", lib dirs, drivers/types/<name>/..., JS
    import/require/new URL(..., import.meta.url)/path.join(__dirname, ...),
    python HERE/'x' and 'scripts/...' string literals.
Rules:
  * variables are resolved from every assignment / for-list / ${X:-default} in the
    same file (flow-insensitive union) plus a few environment defaults
    (SCRIPTS, TYPES, TEST_SKILL_DIR, SKILL_DIR, BATS_TEST_DIRNAME, SCRIPT_DIR);
  * TEST_SKILL_DIR / SKILL_DIR inside tests only map the scripts/ subtree (that is
    all setup_test_env copies); anything else under it is a sandbox file;
  * an unknown base falls back to suffix matching (".../skills/<x>/" or the
    longest path suffix that names a tracked file);
  * a loop over a glob counts as all matches; a path part that comes from an
    unresolved variable becomes a wildcard ("dyn") and is kept while it matches
    at most DYN_CAP files;
  * in a scanning command (grep -r, git grep, find, rglob, git ls-files) a path
    that resolves to a repo directory expands to every file under it.

Outputs (in <out-dir>):
  static_closure.tsv          test_file, dep_file, via  (loose: recurse through every edge)
  static_closure_strict.tsv   same; recursion only through source/exec/import edges
                              (a script that is only grepped/copied/cat'ed is a leaf)
  edges.tsv                   src_file, dep_file, kind, qual, line
  unresolved.tsv              pattern, file, line, detail
  summary.json                counts used by README.md
"""
import collections
import json
import os
import posixpath
import re
import subprocess
import sys

DYN_CAP = 25          # max files a variable-derived wildcard may expand to
SUFFIX1_CAP = 15      # max files a one-component suffix match may expand to


# ---------------------------------------------------------------- repo model
def git_files(root):
    out = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True,
                         text=True, check=True).stdout
    return sorted(set(out.split("\n")) - {""})


def glob_to_re(pat):
    i, n, out = 0, len(pat), []
    while i < n:
        c = pat[i]
        if c == "*":
            if pat[i:i + 2] == "**":
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            j = pat.find("]", i + 1)
            if j == -1:
                out.append(re.escape(c))
            else:
                body = pat[i + 1:j]
                if body.startswith("!"):
                    body = "^" + body[1:]
                out.append("[" + body.replace("\\", "\\\\") + "]")
                i = j
        else:
            out.append(re.escape(c))
        i += 1
    return "".join(out)


def has_glob(p):
    return any(ch in p for ch in "*?[")


class Repo:
    def __init__(self, root):
        self.root = root.rstrip("/")
        self.files = git_files(self.root)
        self.fileset = set(self.files)
        self.dirs = {""}
        for f in self.files:
            p = f
            while "/" in p:
                p = p.rsplit("/", 1)[0]
                self.dirs.add(p)
        self.tops = sorted({f.split("/", 1)[0] for f in self.files})
        self.top_dirs = sorted({f.split("/", 1)[0] for f in self.files if "/" in f})
        self.top_files = sorted({f for f in self.files if "/" not in f})
        self._m, self._s, self._t, self._k = {}, {}, {}, {}

    def text(self, rel):
        t = self._t.get(rel)
        if t is None:
            try:
                with open(os.path.join(self.root, rel), encoding="utf-8", errors="replace") as fh:
                    t = fh.read()
            except OSError:
                t = ""
            self._t[rel] = t
        return t

    def kind(self, rel):
        k = self._k.get(rel)
        if k is None:
            ext = posixpath.splitext(rel)[1]
            if ext in (".sh", ".bash", ".bats"):
                k = "sh"
            elif ext in (".mjs", ".js", ".cjs"):
                k = "js"
            elif ext == ".py":
                k = "py"
            else:
                k = "data"
                if ext == "":
                    first = self.text(rel).split("\n", 1)[0]
                    if first.startswith("#!"):
                        if "node" in first:
                            k = "js"
                        elif "python" in first:
                            k = "py"
                        elif re.search(r"\b(bash|sh|zsh|dash|bats)\b", first):
                            k = "sh"
            self._k[rel] = k
        return k

    def match(self, pat):
        pat = pat.strip("/")
        hit = self._m.get(pat)
        if hit is None:
            if not has_glob(pat):
                hit = ({pat} if pat in self.fileset else set(),
                       {pat} if pat in self.dirs else set())
            else:
                rx = re.compile(glob_to_re(pat) + r"\Z")
                hit = ({f for f in self.files if rx.match(f)},
                       {d for d in self.dirs if d and rx.match(d)})
            self._m[pat] = hit
        return hit

    def ends_with(self, pat):
        hit = self._s.get(pat)
        if hit is None:
            rx = re.compile(r"(?:.*/)?" + glob_to_re(pat) + r"\Z")
            hit = ({f for f in self.files if rx.match(f)},
                   {d for d in self.dirs if d and rx.match(d)})
            self._s[pat] = hit
        return hit

    def under(self, d, name_glob=None):
        pre = d + "/" if d else ""
        out = {f for f in self.files if f.startswith(pre)}
        if name_glob:
            rx = re.compile(glob_to_re(name_glob) + r"\Z")
            out = {f for f in out if rx.match(posixpath.basename(f))}
        return out


# ---------------------------------------------------------------- shell text
BS = r'(?:\$\{BASH_SOURCE(?:\[0\])?(?::-\$0)?\}|\$BASH_SOURCE|\$\{0\}|\$0)'
DEVNULL = r'(?:[0-9&]?>\s*/dev/null\s*)*'
R_CD_DIRNAME = re.compile(r'\$\(\s*cd\s+(?:-P\s+)?(?:--\s+)?"?\$\(\s*dirname\s+(?:--\s+)?"?' + BS +
                          r'"?\s*\)((?:/[^"\s)]*)?)"?\s*' + DEVNULL + r'(?:&&|;)\s*pwd(?:\s+-P)?\s*\)')
R_DIRNAME = re.compile(r'\$\(\s*dirname\s+(?:--\s+)?"?' + BS + r'"?\s*\)')
R_PCT = re.compile(r'\$\{(?:BASH_SOURCE(?:\[0\])?|0)%/\*\}')
R_BATS_DIR = re.compile(r'\$\(\s*dirname\s+"?\$\{?BATS_TEST_FILENAME\}?"?\s*\)')
R_CD_PWD = re.compile(r'\$\(\s*cd\s+(?:-P\s+)?(?:--\s+)?"?([^"()\s;&|]+)"?\s*' + DEVNULL +
                      r'(?:&&|;)\s*pwd(?:\s+-P)?\s*\)')
R_REALPATH = re.compile(r'\$\(\s*(?:realpath|readlink\s+-f|cygpath\s+-\w)\s+"?([^"()\s;&|]+)"?\s*\)')
R_GITTOP = re.compile(r'\$\(\s*git\s+(?:-C\s+\S+\s+)?rev-parse\s+--show-toplevel\s*\)')
R_ADJ = re.compile(r'(\$\{[A-Za-z_]\w*\})(?=[A-Za-z_][\w.-]*\.(?:conf|sh|md|json|mjs|js|py)\b)')

VARX = r'\$\{[^}]*\}|\$[A-Za-z_][A-Za-z_0-9]*|\$[0-9]'
SEGC = r'[A-Za-z0-9_.*?+@%,=~\[\]-]'
R_PATHEXPR = re.compile(r'(?P<base>@SELF@|@ROOT@|' + VARX + r')(?P<tail>(?:/(?:' + SEGC + r'|' + VARX + r')*)+)')
R_VAR_IN_TAIL = re.compile(VARX)
R_BAREVAR = re.compile(r'(?<![\w$])(' + VARX + r')(?![\w/])')
R_ASSIGN = re.compile(r'''(?:^|[\s;&|({])(?:(?:export|local|readonly|typeset)\s+(?:-[a-zA-Z]+\s+)*|declare\s+(?:-[a-zA-Z]+\s+)*)?([A-Za-z_][A-Za-z_0-9]*)=((?:"(?:[^"\\]|\\.)*"|'[^']*'|[^\s;&|()'"]+)+)''')
R_DEFASSIGN = re.compile(r'\$\{([A-Za-z_]\w*):?=([^}]*)\}')
R_FOR = re.compile(r'\bfor\s+([A-Za-z_]\w*)\s+in\s+(.+?)\s*(?:;\s*do\b.*)?$')
R_SCAN = re.compile(r'\bgrep\b[^|;&]*?\s-[a-zA-Z]*[rR][a-zA-Z]*\b|\bgrep\b[^|;&]*--include|\bgit\s+grep\b|'
                    r'\bfind\b|\.rglob\(|\bos\.walk\(|\bgit\s+ls-files\b')
R_SCAN_NAME = re.compile(r'(?:-name\s+|--include=|rglob\(\s*)(\S+?)\)?(?:\s|$)')
R_GITGREP = re.compile(r'\bgit\s+grep\b|\bgit\s+ls-files\b')
R_EVAL = re.compile(r'(?:^|[\s;&|({!`])eval\s')
R_LOAD = re.compile(r'^\s*load\s+["\']?([\w./-]+)["\']?')
R_CMD_POS = re.compile(r'(?:^|[;&|({!`]|\$\(|\bthen|\bdo|\belse|\bif|\bwhile|\buntil|&&|\|\|)\s*$')
INTERP = {"bash", "sh", "zsh", "dash", "node", "python3", "python", "perl", "osascript",
          "exec", "run", "nohup", "timeout", "env", "xargs", "command", "time", "setsid",
          "caffeinate", "nice", "bats", "sudo", "if", "while", "until", "!", "then", "do", "else"}
NONREAD_CMDS = {"chmod", "mkdir", "touch", "rm", "rmdir", "chown"}
GENERIC_NAMES = {"README.md", "package.json", "package-lock.json", "config.json", "index.js",
                 "index.mjs", "LICENSE", "VERSION", "SKILL.md", "Cargo.toml", "main.rs", "lib.rs"}
SCRIPT_EXT = re.compile(r'\.(?:sh|bash|mjs|js|cjs|py)$')


def normalize(line):
    prev, s = None, line
    while s != prev:
        prev = s
        s = R_CD_DIRNAME.sub(lambda m: "@SELF@" + (m.group(1) or ""), s)
        s = R_DIRNAME.sub("@SELF@", s)
        s = R_PCT.sub("@SELF@", s)
        s = R_BATS_DIR.sub("$BATS_TEST_DIRNAME", s)
        s = R_CD_PWD.sub(lambda m: m.group(1), s)
        s = R_REALPATH.sub(lambda m: m.group(1), s)
        s = R_GITTOP.sub("@ROOT@", s)
    return s


def strip_quotes(s):
    return s.replace('"', "").replace("'", "")


def strip_quotes_grouped(s):
    """strip_quotes(), but whitespace inside a quoted string becomes \x01, so a quoted word stays
    one token; positions match strip_quotes(s) exactly."""
    out, dq, sq = [], False, False
    for c in s:
        if c == '"' and not sq:
            dq = not dq
            continue
        if c == "'" and not dq:
            sq = not sq
            continue
        if c in ('"', "'"):
            continue
        out.append("\x01" if (dq or sq) and c in " \t" else c)
    return "".join(out)


SEG_SPLIT = re.compile(r';|&&|\|\||\||\$\(|`|(?<![$\w])\(|\{|\bthen\b|\bdo\b|\belse\b|\bif\b|\bwhile\b|\buntil\b|(?:^|\s)!(?=\s)')
WRAPPERS = {"run", "command", "exec", "time", "nohup", "env", "sudo", "setsid", "nice", "caffeinate", "builtin"}
INTERPS = {"bash", "sh", "zsh", "dash", "node", "python3", "python", "perl", "osascript", "bats", "xargs",
           "timeout", "gtimeout"}
READ_CMDS = {"grep", "egrep", "fgrep", "rg", "cat", "sed", "awk", "gawk", "head", "tail", "wc", "diff", "cmp", "cp",
             "ln", "mv", "test", "[", "[[", "printf", "echo", "shasum", "sha256sum", "sha1sum", "md5", "md5sum",
             "cksum", "readlink", "basename", "dirname", "stat", "ls", "file", "sort", "uniq", "cut", "tr", "jq",
             "git", "sqlite3", "tee", "rm", "chmod", "touch", "mkdir", "du", "find", "xxd", "od", "strings",
             "iconv", "install", "realpath", "cygpath", "tar", "zip", "unzip", "base64", "openssl", "hexdump",
             "local", "export", "declare", "readonly", "return", "exit", "case", "unset", "wait", "kill", "sleep",
             "cd", "pushd", "shellcheck", "comm", "paste", "nl", "fold", "rev", "column", "split", "truncate",
             "mapfile", "readarray", "read", "trap", "printf_", "dd", "cmp", "ditto", "rsync", "chown", "for",
             "select", "refute", "assert", "assert_output", "wait_for_file", "wait_for_missing",
             "wait_for_file_contains", "wait_for_file_is", "file_mode", "rf"}


def classify(prefix):
    """edge kind of a path that follows <prefix> on its line:
    source | exec | call (argument of a function/unknown command) | assign | data."""
    p = prefix
    if re.search(r'(?:^|[\s;&|({])(?:BASH_ENV|ENV)=$', p):
        return "source"
    if re.search(r'(?:^|[\s;&|({])[A-Za-z_]\w*(?:\[[^\]]*\])?\+?=$', p):
        return "assign"
    if re.search(r'(?:[<>]|<<<)\s*$', p):
        return "data"
    ps = p.rstrip()
    seg = SEG_SPLIT.split(p)[-1]
    toks = seg.split()
    # `source X` anywhere (also inside a `bash -c 'source X'` string); `. X` only where `.`
    # is the command word (so `grep . X` stays a read)
    if toks and (toks[-1] == "source" or (toks[-1] == "." and (len(toks) == 1 or toks[-2] in ("-c", "then", "do", "else")))):
        return "source"
    if re.search(r'(?:^|[;&|({!`])\s*\.$', ps):
        return "source"
    if toks and toks[0] == "for":
        return "assign"
    k = 0
    while k < len(toks):
        t = toks[k]
        if re.fullmatch(r'[A-Za-z_]\w*=\S*', t):
            k += 1
            continue
        if t in WRAPPERS:
            k += 1
            while k < len(toks) and toks[k].startswith("-"):
                k += 2 if toks[k] == "-a" else 1
            continue
        break
    if k >= len(toks):
        return "exec"
    cmd = toks[k]
    if cmd in INTERPS:
        return "exec"
    if cmd.startswith("$"):
        name = cmd.strip("${}")
        if re.search(r'(?i)node|python|bash|interp|runtime|_bin$|^sh$|^BIN$', name):
            return "exec"
        return "call"
    if cmd in READ_CMDS or not re.match(r'[A-Za-z_]', cmd):
        return "data"
    return "call"


def is_grep_pattern(prefix):
    """True when the text that follows <prefix> is grep's PATTERN operand (a search string that
    merely looks like a path, e.g. `grep -F 'scripts/internal/*' "$workflow"`), not a file operand."""
    seg = SEG_SPLIT.split(prefix)[-1]
    toks = seg.split()
    k = 0
    while k < len(toks) and (toks[k] in WRAPPERS or re.fullmatch(r'[A-Za-z_]\w*=\S*', toks[k])):
        k += 1
    if k >= len(toks) or toks[k] not in ("grep", "egrep", "fgrep", "rg"):
        return False
    rest = toks[k + 1:]
    if rest and not prefix[-1:].isspace():
        rest = rest[:-1]          # the operand being matched started before the path (quoted word)
    if any(t in ("-e", "-f", "--regexp", "--file") or t.startswith(("--regexp=", "--file=")) for t in rest):
        return False
    return all(t.startswith("-") for t in rest)


def first_cmd(code):
    toks = [t for t in re.split(r'\s+|[;&|(`]', code.strip()) if t]
    for t in toks:
        if re.fullmatch(r'[A-Za-z_]\w*=\S*', t) or t in ("then", "do", "else", "if", "!", "{", "run"):
            continue
        return t
    return ""


class Ref:
    __slots__ = ("dep", "kind", "qual", "line")

    def __init__(self, dep, kind, qual, line):
        self.dep, self.kind, self.qual, self.line = dep, kind, qual, line


class FileCtx:
    """per-file resolution context for shell-ish files."""

    def __init__(self, an, rel, in_tests):
        self.an, self.repo, self.rel, self.in_tests = an, an.repo, rel, in_tests
        self.selfdir = posixpath.dirname(rel)
        self.assign = collections.defaultdict(list)    # var -> [(value, line)]
        self.assign_lines = collections.defaultdict(set)
        self.func_ranges = []                          # (start, end, name)
        self.callargs = {}                             # function -> [set(arg1), set(arg2), set(arg3)]
        self.cur_line = 0

    def func_at(self, line):
        best = None
        for a, b, n in self.func_ranges:
            if a <= line <= b and (best is None or a >= best[0]):
                best = (a, b, n)
        return best[2] if best else None

    def positional_words(self, idx, line):
        fn = self.func_at(line or self.cur_line)
        if not fn or fn not in self.callargs or idx < 1 or idx > 3:
            return []
        return sorted(self.callargs[fn][idx - 1])

    # -- variable model -------------------------------------------------------
    def defaults(self, name):
        if name == "SCRIPTS":
            return [("R", "scripts", name, False)]
        if name == "TYPES":
            return [("R", "scripts/drivers/types", name, False)]
        if name == "TEST_SKILL_DIR":
            return [("R", "", name, True)]
        if name in ("SKILL_DIR", "AGMSG_SKILL_DIR", "skill_dir", "_skill_dir", "SKILL_ROOT"):
            return [("R", "", name, self.in_tests)]
        if name == "BATS_TEST_DIRNAME":
            return [("R", "tests", name, False)]
        if name == "BATS_TEST_FILENAME":
            return [("R", self.rel, name, False)]
        if name == "SCRIPT_DIR":
            return [("R", self.selfdir, name, False), ("R", "scripts", name, False)]
        return None

    def var_templates(self, name, depth):
        memo = self.__dict__.setdefault("_vt_memo", {})
        busy = self.__dict__.setdefault("_vt_busy", set())
        if name in memo:
            return memo[name]
        if depth > 8 or name in busy:
            return [("U", "", name, False)]
        busy.add(name)
        out = []
        for v, ln in self.assign.get(name, ()):
            out.extend(self.value_templates(v, depth + 1, name, ln))
        busy.discard(name)
        d = self.defaults(name)
        if d and (not out or name in ("SCRIPTS", "TYPES", "TEST_SKILL_DIR", "BATS_TEST_DIRNAME")):
            out.extend(d)
        if not out:
            out = [("U", "", name, False)]
        # de-dup, cap
        seen, res = set(), []
        for t in out:
            if t not in seen:
                seen.add(t)
                res.append(t)
        res = res[:48]
        if not busy:
            memo[name] = res
        return res

    def base_templates(self, base, depth=0, line=None):
        if base == "@SELF@":
            return [("R", self.selfdir, "SELF", False)]
        if base == "@ROOT@":
            return [("R", "", "ROOT", False)]
        m = re.fullmatch(r'\$\{([A-Za-z_][A-Za-z_0-9]*|[0-9@*#?])(\[[^\]]*\])?(.*)\}', base, re.S)
        if m:
            name, op = m.group(1), m.group(3)
        else:
            name, op = base[1:], ""
        if name.isdigit():
            words = self.positional_words(int(name), line)
            out = [("W", w, name, False) for w in words] or [("U", "", name, False)]
        else:
            out = list(self.var_templates(name, depth))
        default = None
        if op.startswith((":-", ":=")):
            default = op[2:]
        elif op[:1] in ("-", "="):
            default = op[1:]
        elif op.startswith("%/"):
            out = [(a, posixpath.dirname(r), h, s) for (a, r, h, s) in out]
        if default:
            out.extend(self.value_templates(strip_quotes(default), depth + 1, name, line))
        return out

    def value_templates(self, v, depth, name, line=None):
        v = strip_quotes(normalize(v)).strip()
        if not v:
            return []
        m = R_PATHEXPR.match(v)
        if m and m.end() == len(v):
            res = []
            for (a, r, h, s) in self.base_templates(m.group("base"), depth, line):
                for t, _dyn in self.expand_tail(m.group("tail"), depth, line):
                    res.append((a, posixpath.join(r, t.lstrip("/")) if r or a != "R" else t.lstrip("/"), h, s))
            return res
        mb = re.fullmatch(r'(@SELF@|@ROOT@|' + VARX + r')', v)
        if mb:
            return self.base_templates(mb.group(1), depth, line)
        if "$" in v or "`" in v or v.startswith(("-", "/")):
            return [("U", "", name, False)]
        if "/" in v:
            first = v.split("/", 1)[0]
            if first in self.repo.tops:
                return [("R", v, name, False)]
            return [("W", v, name, False)]
        return [("W", v, name, False)]

    def var_words(self, name, depth):
        words = []
        for (a, r, h, s) in self.var_templates(name, depth + 1):
            if a == "W":
                words.append(r)
            elif a == "R" and r and not self.in_tests:
                words.append(None)
            else:
                words.append(None)
        return words

    def expand_tail(self, tail, depth=0, line=None):
        parts = R_VAR_IN_TAIL.split(tail)
        vars_ = R_VAR_IN_TAIL.findall(tail)
        if not vars_:
            return [(tail, False)]
        combos = [("", False)]
        for i, lit in enumerate(parts):
            combos = [(c + lit, d) for (c, d) in combos]
            if i < len(vars_):
                v = vars_[i]
                m = re.fullmatch(r'\$\{?([A-Za-z_][A-Za-z_0-9]*|[0-9])', v.split("[")[0].split(":")[0].split("%")[0].split("#")[0].rstrip("}"))
                name = m.group(1) if m else ""
                if name.isdigit():
                    words = self.positional_words(int(name), line)
                else:
                    words = [w for w in self.var_words(name, depth) if w] if name else []
                if words and len(words) <= 24:
                    combos = [(c + w, d) for (c, d) in combos for w in words]
                else:
                    combos = [(c + "*", True) for (c, d) in combos]
                combos = combos[:64]
        # collapse '**' produced by adjacent wildcards
        return [(re.sub(r'\*+', '*', c), d) for (c, d) in combos]

    # -- resolution -----------------------------------------------------------
    def suffix_resolve(self, path, hint):
        comps = [c for c in path.split("/") if c not in ("", ".")]
        while comps and comps[0] == "..":
            comps.pop(0)
        if not comps:
            return set(), set()
        repo = self.repo
        h = (hint or "").lower()
        tries = []
        if "script" in h:
            tries.append("scripts/" + "/".join(comps))
        if h.endswith("types"):
            tries.append("scripts/drivers/types/" + "/".join(comps))
        if "skill" in h or h in ("sk", "skd", "root", "repo", "repo_root", "sk_second"):
            tries.append("/".join(comps))
        for i in range(len(comps) - 1):
            if comps[i] == "skills":
                tries.append("/".join(comps[i + 2:]))
        for t in tries:
            if not t:
                continue
            f, d = repo.match(t)
            if f or d:
                return f, d
        for i in range(len(comps)):
            sub = comps[i:]
            pat = "/".join(sub)
            # a suffix must keep at least one literal component, or "*/*" matches the repo
            if not any(not has_glob(c) and c not in ("..",) for c in sub):
                break
            if has_glob(pat):
                f, d = repo.ends_with(pat)
                if len(f) > DYN_CAP:
                    break
            if len(sub) == 1:
                name = sub[0]
                if (not re.search(r'[._-]', name) or name in GENERIC_NAMES or name.startswith("*")):
                    break
                f, d = repo.ends_with(pat)
                if f and len(f) <= SUFFIX1_CAP:
                    return f, set()
                break
            f, d = repo.ends_with(pat)
            if f or d:
                return f, d
        return set(), set()

    def resolve(self, base, tail):
        """-> (files, dirs, quals:set)"""
        files, dirs, quals = set(), set(), set()
        templates = self.base_templates(base) if base else [("R", "", "", False)]
        tails = self.expand_tail(tail)
        for (a, r, h, sandbox) in templates:
            for t, dyn in tails:
                q = "dyn" if dyn else ("glob" if has_glob(t) else "")
                rel_t = t.lstrip("/")
                f, d = set(), set()
                if a == "R":
                    pat = posixpath.normpath(posixpath.join(r, rel_t)) if (r or rel_t) else ""
                    if pat == ".":
                        pat = ""
                    if pat.startswith(".."):
                        continue
                    if sandbox and not (pat == "scripts" or pat.startswith("scripts/")):
                        continue
                    f, d = self.repo.match(pat)
                    if not f and not d and rel_t:
                        f, d = self.suffix_resolve(rel_t, h)
                        if f or d:
                            q = (q + "+suffix").strip("+")
                elif a == "U":
                    f, d = self.suffix_resolve(posixpath.join(r, rel_t), h)
                    q = (q + "+suffix").strip("+")
                else:  # W: a literal word used as a base
                    f, d = self.repo.match(posixpath.normpath(posixpath.join(r, rel_t)))
                    if not f and not d:
                        f, d = self.suffix_resolve(posixpath.join(r, rel_t), h)
                    q = (q + "+word").strip("+")
                # "dir/" names directories only; so does a suffix match whose last component is
                # a bare variable ("$base/types/$want" is a type dir, not types/x.d.ts)
                if t.endswith("/") or ("suffix" in q and rel_t.rstrip("/").split("/")[-1] == "*"):
                    f = set()
                if dyn and len(f) > DYN_CAP:
                    self.an.unres("dyn-too-broad", self.rel, self.cur_line,
                                  "%s%s -> %d files" % (base, tail, len(f)))
                    continue
                if f or d:
                    files |= f
                    dirs |= d
                    if q:
                        quals.add(q)
        return files, dirs, quals


# ---------------------------------------------------------------- analyzer
class Analyzer:
    def __init__(self, root):
        self.repo = Repo(root)
        self.unresolved = []
        self._edges = {}
        top_dirs = [t for t in self.repo.top_dirs]
        self.R_RELPATH = re.compile(r'(?<![\w$/.@}\-])((?:\.\.?/)*(?:%s)/(?:%s|/)*)' %
                                    ("|".join(map(re.escape, top_dirs)), SEGC))
        self.R_BARETOP = re.compile(r'(?<![\w$/.@}\-])(?:\./)?(%s)(?![\w.-])' %
                                    "|".join(map(re.escape, [f for f in self.repo.top_files if "." in f])))
        self.R_BAREDIR = re.compile(r'(?<![\w$/.@}\-:])(%s)/?(?![\w.*?/\[-])' % "|".join(map(re.escape, top_dirs)))
        self.R_STRLIT = re.compile(r'''(['"`])((?:\.\.?/)*(?:%s)/[^'"`\s$]*)\1''' % "|".join(map(re.escape, top_dirs)))
        self.cur = None
        # registry manifests (key=value under scripts/drivers/**) whose value names a file
        self.manifest_keys = collections.defaultdict(set)
        for f in self.repo.files:
            if f.startswith("scripts/drivers/") and f.endswith(".conf"):
                d = posixpath.dirname(f)
                for ln in self.repo.text(f).split("\n"):
                    m = re.match(r'\s*([A-Za-z_]\w*)\s*=\s*(.*?)\s*$', ln)
                    if not m:
                        continue
                    for v in m.group(2).strip("\"'").split():
                        cand = posixpath.normpath(posixpath.join(d, v))
                        if cand in self.repo.fileset:
                            self.manifest_keys[m.group(1)].add(cand)
        # functions whose body reads such a key (`agmsg_*get* <name> <key>`) -> files it can name
        self.deref_funcs = collections.defaultdict(set)
        self.deref_top = collections.defaultdict(set)
        for f in self.repo.files:
            if self.repo.kind(f) != "sh":
                continue
            text = self.repo.text(f)
            for key, files in self.manifest_keys.items():
                for m in re.finditer(r'\bagmsg_\w*get\w*\s+\S+\s+' + re.escape(key) + r'\b', text):
                    head = text[:m.start()]
                    defs = list(re.finditer(r'(?m)^\s*([A-Za-z_][\w:-]*)\s*\(\)\s*\{', head))
                    if defs:
                        self.deref_funcs[defs[-1].group(1)] |= files
                    else:
                        self.deref_top[f] |= files

    def unres(self, pattern, f, line, detail):
        self.unresolved.append((pattern, f, line, detail.strip()[:200]))

    # -- shell ------------------------------------------------------------------
    def shell_refs(self, rel, text=None, line_filter=None, in_tests=None):
        """Return [Ref] for a shell-ish file (optionally only lines in line_filter)."""
        repo = self.repo
        if text is None:
            text = repo.text(rel)
        if in_tests is None:
            in_tests = rel.startswith("tests/")
        ctx = FileCtx(self, rel, in_tests)
        ctx.cur_line = 0
        raw = text.split("\n")
        lines = [(i, "", "") for i in range(1, len(raw) + 1)]
        grouped = {}
        cont, cont_at = "", 0   # backslash-continued command: analysed as one line, at its first line
        for i, ln in enumerate(raw, 1):
            s = ln.strip()
            if not cont and (s.startswith("#") or s.startswith("@test ")):
                continue
            if ln.endswith("\\") and not ln.endswith("\\\\"):
                if not cont:
                    cont_at = i
                cont += ln[:-1] + " "
                continue
            at = i
            if cont:
                ln, at, cont = cont + ln, cont_at, ""
            norm = normalize(ln)
            lines[at - 1] = (at, norm, R_ADJ.sub(r'\1/', strip_quotes(norm)))
            grouped[at] = R_ADJ.sub(r'\1/', strip_quotes_grouped(norm))
        # pass 1: variable model (whole file, flow-insensitive)
        for i, norm, nq in lines:
            if not norm:
                continue
            for m in R_ASSIGN.finditer(norm):
                ctx.assign[m.group(1)].append((m.group(2), i))
                ctx.assign_lines[m.group(1)].add(i)
            for m in R_DEFASSIGN.finditer(norm):
                ctx.assign[m.group(1)].append((m.group(2), i))
                ctx.assign_lines[m.group(1)].add(i)
            mf = R_FOR.search(nq)
            if mf:
                for w in mf.group(2).split():
                    if w in ("do", ";"):
                        break
                    ctx.assign[mf.group(1)].append((w.rstrip(";"), i))
                ctx.assign_lines[mf.group(1)].add(i)
        open_fns = []
        for i, ln in enumerate(raw, 1):
            mh = re.match(r'^(\s*)(?:function\s+)?([A-Za-z_][\w:.-]*)\s*\(\)\s*(\{.*)?$', ln)
            if mh:
                body = (mh.group(3) or "").rstrip()
                if body.endswith("}") and body.count("{") <= body.count("}"):
                    ctx.func_ranges.append((i, i, mh.group(2)))
                else:
                    open_fns.append((mh.group(1), i, mh.group(2)))
                continue
            if open_fns and ln.rstrip() == open_fns[-1][0] + "}":
                ind, a, n = open_fns.pop()
                ctx.func_ranges.append((a, i, n))
        for ind, a, n in open_fns:
            ctx.func_ranges.append((a, len(raw), n))
        fnames = {n for _a, _b, n in ctx.func_ranges}
        if fnames:
            rx = re.compile(r'(?<![\w$./-])(%s)((?:[ \t]+[^\s;|&)<>]+){1,3})' % "|".join(sorted(map(re.escape, fnames), key=len, reverse=True)))
            headers = {a for a, _b, _n in ctx.func_ranges}
            for i, norm, nq in lines:
                if not nq or i in headers:
                    continue
                for m in rx.finditer(nq):
                    args = m.group(2).split()
                    slot = ctx.callargs.setdefault(m.group(1), [set(), set(), set()])
                    for k, a in enumerate(args[:3]):
                        if a and not re.search(r'[$`*]', a) and not a.startswith("-") and len(a) < 120:
                            slot[k].add(a)
        refs = []
        var_refs = collections.defaultdict(list)    # var -> [Ref] captured on its assignment lines
        for i, norm, nq in lines:
            if not nq or (line_filter is not None and i not in line_filter):
                continue
            ctx.cur_line = i
            cmd = first_cmd(nq)
            if cmd in NONREAD_CMDS:
                continue
            scan = bool(R_SCAN.search(nq))
            name_glob = None
            if scan:
                mn = R_SCAN_NAME.search(nq)
                if mn:
                    name_glob = mn.group(1).strip("'\"")
            line_refs = []
            spans = []

            def emit(files, dirs, quals, kind, start, detail):
                got = False
                for f in sorted(files):
                    r = Ref(f, kind, "+".join(sorted(quals)), i)
                    line_refs.append((r, start))
                    got = True
                # a `cd DIR` / `git -C DIR` / `pushd DIR` target is a working dir, not a scan root
                if re.search(r'(?:\bcd|\bpushd|\s-C)\s+$', nq[:start]):
                    return got or bool(dirs)
                if scan and dirs:
                    for d in sorted(dirs):
                        for f in sorted(repo.under(d, name_glob)):
                            line_refs.append((Ref(f, "data", "scan", i), start))
                            got = True
                    self.unres("repo-wide-scan", rel, i, "%s -> %s%s" % (
                        detail, ",".join(sorted(d or "<root>" for d in dirs)),
                        (" (-name %s)" % name_glob) if name_glob else ""))
                return got

            for m in R_PATHEXPR.finditer(nq):
                spans.append((m.start(), m.end()))
                if is_grep_pattern(grouped.get(i, nq)[:m.start()]):
                    continue
                kind = classify(nq[:m.start()])
                files, dirs, quals = ctx.resolve(m.group("base"), m.group("tail"))
                got = emit(files, dirs, quals, kind, m.start(), m.group(0))
                tail = m.group("tail")
                looks_repo = bool(SCRIPT_EXT.search(tail.split("/")[-1]))
                if not got and (kind == "source" or (kind == "exec" and looks_repo)):
                    self.unres("dynamic-" + kind, rel, i, nq.strip())
                elif got and "dyn" in quals and kind in ("source", "exec"):
                    self.unres("data-driven-" + kind, rel, i, "%s -> %d files" % (nq.strip(), len(files)))
                elif got and "dyn" in quals and SCRIPT_EXT.search(tail) is None:
                    self.unres("data-driven-read", rel, i, "%s -> %d files" % (nq.strip(), len(files)))
            for m in self.R_RELPATH.finditer(nq):
                if any(a <= m.start() < b for a, b in spans):
                    continue
                if is_grep_pattern(grouped.get(i, nq)[:m.start()]):
                    continue
                kind = classify(nq[:m.start()])
                files, dirs, quals = ctx.resolve("", "/" + re.sub(r'^(?:\.\.?/)+', "", m.group(1)))
                emit(files, dirs, quals | {"literal"}, kind, m.start(), m.group(1))
            for m in self.R_BARETOP.finditer(nq):
                if any(a <= m.start() < b for a, b in spans):
                    continue
                kind = classify(nq[:m.start()])
                if kind in ("exec", "source") or m.group(0).startswith("./"):
                    emit({m.group(1)}, set(), {"literal"}, kind, m.start(), m.group(0))
            if scan:
                if R_GITGREP.search(nq) and in_tests:
                    # pathspecs after `--`; exclusions (:!x, :^x, :(exclude)x) do not narrow the scan
                    after = nq.split(" -- ", 1)[1].split() if " -- " in nq else []
                    pathspec = [t for t in after if not t.startswith((":!", ":^", ":(exclude)")) and t != "."]
                    if not pathspec:
                        for f in repo.files:
                            line_refs.append((Ref(f, "data", "scan", i), 0))
                        self.unres("repo-wide-scan", rel, i, "git grep/ls-files over the whole tree: " + nq.strip())
                for m in R_BAREVAR.finditer(nq):
                    if any(a <= m.start() < b for a, b in spans):
                        continue
                    files, dirs, quals = ctx.resolve(m.group(1), "")
                    if dirs:
                        emit(set(), dirs, quals, "data", m.start(), m.group(1))
                for m in self.R_BAREDIR.finditer(nq):
                    if any(a <= m.start() < b for a, b in spans) or is_grep_pattern(grouped.get(i, nq)[:m.start()]):
                        continue
                    if re.search(r'\bcd\b', nq[:m.start()]) or in_tests:
                        emit(set(), {m.group(1)}, set(), "data", m.start(), m.group(1))
            if R_EVAL.search(nq):
                self.unres("eval", rel, i, nq.strip())
            # assignment capture: refs on `VAR=...` / `for VAR in ...` lines
            assigned = [v for v, ls in ctx.assign_lines.items() if i in ls]
            for r, _start in line_refs:
                refs.append(r)
                for v in assigned:
                    var_refs[v].append(r)
        # pass 3: upgrade refs whose variable is later sourced / executed
        for i, norm, nq in lines:
            if not nq or (line_filter is not None and i not in line_filter):
                continue
            for m in R_BAREVAR.finditer(nq):
                tok = m.group(1)
                name = re.sub(r'^\$\{?([A-Za-z_]\w*).*$', r'\1', tok)
                if name not in var_refs:
                    if name and classify(nq[:m.start()]) == "source" and not name.isdigit():
                        if not ctx.var_templates(name, 0) or all(t[0] == "U" for t in ctx.var_templates(name, 0)):
                            self.unres("dynamic-source", rel, i, nq.strip())
                    continue
                k = classify(nq[:m.start()])
                if k in ("source", "exec", "call"):
                    for r in var_refs[name]:
                        if r.kind in ("data", "assign") and "scan" not in r.qual:
                            r.kind = k if k != "call" or r.kind == "assign" else r.kind
        return refs

    # -- js / python --------------------------------------------------------------
    R_JS_SPEC = re.compile(r"""(?:\bfrom\s*|\bimport\s*\(\s*|\bimport\s+|\brequire\s*\(\s*|\bnew\s+URL\s*\(\s*)(['"`])([^'"`\n]+)\1""")
    R_JS_DYN = re.compile(r"""\b(?:import|require)\s*\(\s*(?!['"`])([^)\n]{1,80})""")
    R_JS_JOINSTART = re.compile(r"""(?<![\w$.])(?:path\.)?(?:join|resolve)\(""")
    R_JS_SELFEXPR = re.compile(r"""^(?:__dirname|import\.meta\.dirname|(?:path\.)?dirname\(\s*(?:url\.)?fileURLToPath\(\s*import\.meta\.url\s*\)\s*\)|(?:url\.)?fileURLToPath\(\s*new\s+URL\(\s*['"]\.\/?['"]\s*,\s*import\.meta\.url\s*\)\s*\))$""")
    R_JS_CONST = re.compile(r"""\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(.+?);?\s*$""")
    R_PY_HERE = re.compile(r"""\b(HERE|ROOT|BASE|DIR|SCRIPT_DIR)\s*/\s*(['"])([^'"]+)\2""")
    R_BARE_SCRIPT = re.compile(r"""(['"`])([\w.-]+\.(?:sh|mjs|js|cjs|py))\1""")
    R_READS_TEXT = re.compile(r"""\b(?:readFile|readFileSync|existsSync|statSync|accessSync|createReadStream|lstatSync|read_text|open)\s*\(""")

    @staticmethod
    def _split_args(text, i):
        """text[i] is just after '(' -> (list of top-level arg strings, index after ')') or (None, i)."""
        depth, cur, args, q = 0, [], [], None
        j = i
        while j < len(text):
            c = text[j]
            if q:
                cur.append(c)
                if c == "\\":
                    if j + 1 < len(text):
                        cur.append(text[j + 1])
                    j += 2
                    continue
                if c == q:
                    q = None
            elif c in "'\"`":
                q = c
                cur.append(c)
            elif c in "([{":
                depth += 1
                cur.append(c)
            elif c in ")]}":
                if depth == 0:
                    args.append("".join(cur).strip())
                    return args, j + 1
                depth -= 1
                cur.append(c)
            elif c == "," and depth == 0:
                args.append("".join(cur).strip())
                cur = []
            else:
                cur.append(c)
            j += 1
        return None, i

    def _js_dir(self, expr, env, selfdir, depth=0):
        """Evaluate a JS path expression to a repo-relative path, or None."""
        expr = expr.strip()
        if depth > 5:
            return None
        if self.R_JS_SELFEXPR.match(expr):
            return selfdir
        m = re.fullmatch(r"""(['"])([^'"]*)\1""", expr)
        if m:
            return ("LIT", m.group(2))
        if re.fullmatch(r"[A-Za-z_$][\w$]*", expr):
            return env.get(expr)
        m = self.R_JS_JOINSTART.match(expr)
        if m:
            args, end = self._split_args(expr, m.end())
            if args and end == len(expr):
                return self._js_join(args, env, selfdir, depth + 1)
        m = re.fullmatch(r"(?:path\.)?dirname\((.*)\)", expr)
        if m:
            d = self._js_dir(m.group(1), env, selfdir, depth + 1)
            if isinstance(d, str):
                return posixpath.dirname(d)
        return None

    def _js_join(self, args, env, selfdir, depth=0):
        base = self._js_dir(args[0], env, selfdir, depth)
        parts = []
        for a in args[1:]:
            v = self._js_dir(a, env, selfdir, depth)
            if isinstance(v, tuple):
                parts.append(v[1])
            else:
                parts.append("*")
        tail = "/".join(parts)
        if isinstance(base, str):
            p = posixpath.normpath(posixpath.join(base, tail)) if tail else base
            return p if not p.startswith("..") else None
        if isinstance(base, tuple):
            return ("LIT", posixpath.join(base[1], tail))
        return ("UNK:" + args[0][:40], tail)

    def js_py_refs(self, rel, lang):
        repo = self.repo
        text = repo.text(rel)
        ctx = FileCtx(self, rel, rel.startswith("tests/"))
        ctx.cur_line = 0
        selfdir = posixpath.dirname(rel)
        refs = []
        env = {}
        lines = text.split("\n")
        if lang == "js":
            for ln in lines:
                m = self.R_JS_CONST.search(ln)
                if m:
                    v = self._js_dir(m.group(2).rstrip(";").strip(), env, selfdir)
                    if isinstance(v, str):
                        env[m.group(1)] = v
        for i, ln in enumerate(lines, 1):
            s = ln.strip()
            if s.startswith(("//", "#", "*", "/*")):
                continue
            ctx.cur_line = i
            window = " ".join(lines[max(0, i - 3):i + 1])
            reads_text = bool(self.R_READS_TEXT.search(ln))

            def kind_for(dep):
                if reads_text or repo.kind(dep) == "data":
                    return "data"
                return "exec"

            got_spans = []
            if lang == "js":
                for m in self.R_JS_SPEC.finditer(ln):
                    spec = m.group(2)
                    if not spec.startswith("."):
                        continue
                    got_spans.append((m.start(), m.end()))
                    base = posixpath.normpath(posixpath.join(selfdir, spec))
                    hit = None
                    for cand in (base, base + ".mjs", base + ".js", base + ".cjs", base + "/index.mjs", base + "/index.js"):
                        if cand in repo.fileset:
                            hit = cand
                            break
                    if hit:
                        k = "source" if "URL" not in m.group(0) else kind_for(hit)
                        refs.append(Ref(hit, k, "import", i))
                    else:
                        self.unres("js-unresolved-import", rel, i, s)
                for m in self.R_JS_DYN.finditer(ln):
                    self.unres("js-dynamic-import", rel, i, s)
                for m in self.R_JS_JOINSTART.finditer(ln):
                    args, end = self._split_args(ln, m.end())
                    if not args or len(args) < 2:
                        continue
                    got_spans.append((m.start(), end))
                    v = self._js_join(args, env, selfdir)
                    files = set()
                    if isinstance(v, str):
                        files, _d = repo.match(v)
                        q = "join"
                    elif isinstance(v, tuple) and v[0] == "LIT":
                        files, _d = repo.match(posixpath.normpath(v[1])) if not v[1].startswith("..") else (set(), set())
                        q = "join"
                    elif isinstance(v, tuple):
                        tail = v[1]
                        if tail and any(not has_glob(c) for c in tail.split("/")):
                            files, _d = ctx.suffix_resolve(tail, v[0][4:])
                        q = "join+suffix"
                        if not files and SCRIPT_EXT.search(tail):
                            self.unres("js-computed-path", rel, i, s)
                    if len(files) > DYN_CAP:
                        files = set()
                    for x in sorted(files):
                        refs.append(Ref(x, kind_for(x), q, i))
            else:
                for m in self.R_PY_HERE.finditer(ln):
                    if m.group(1) == "HERE":
                        f, d = repo.match(posixpath.normpath(posixpath.join(selfdir, m.group(3))))
                    else:
                        f, d = ctx.suffix_resolve(m.group(3), m.group(1))
                    for x in sorted(f):
                        refs.append(Ref(x, kind_for(x), "here", i))
            for m in self.R_STRLIT.finditer(ln):
                if any(a <= m.start() < b for a, b in got_spans):
                    continue
                lit = re.sub(r'^(?:\.\.?/)+', "", m.group(2))
                f, d = repo.match(lit)
                if not f:
                    f, d = ctx.suffix_resolve(lit, "")
                for x in sorted(f):
                    refs.append(Ref(x, kind_for(x), "literal", i))
            for m in self.R_BARE_SCRIPT.finditer(ln):
                if any(a <= m.start() < b for a, b in got_spans):
                    continue
                name = m.group(2)
                f, d = repo.match(posixpath.join(selfdir, name))
                if not f:
                    f, d = repo.match("scripts/" + name)
                if not f:
                    f, d = repo.ends_with(name)
                    if len(f) > 3:
                        f = set()
                for x in sorted(f):
                    refs.append(Ref(x, kind_for(x), "name", i))
        return refs

    # -- per-file edges (memoized) ---------------------------------------------------
    def edges(self, rel):
        e = self._edges.get(rel)
        if e is None:
            k = self.repo.kind(rel)
            if k == "sh":
                e = self.shell_refs(rel)
                text = self.repo.text(rel)
                for fn, files in self.deref_funcs.items():
                    for m in re.finditer(r'(?<![\w-])' + re.escape(fn) + r'(?![\w-])(?!\s*\(\))', text):
                        ln = text.count("\n", 0, m.start()) + 1
                        line_txt = text.split("\n")[ln - 1].strip()
                        if line_txt.startswith("#"):
                            continue
                        for x in sorted(files):
                            e.append(Ref(x, "exec" if self.repo.kind(x) != "data" else "data", "manifest:" + fn, ln))
                        self.unres("registry-data", rel, ln, "%s() dereferences a manifest key -> %d files" % (fn, len(files)))
                        break
                for x in sorted(self.deref_top.get(rel, ())):
                    e.append(Ref(x, "exec" if self.repo.kind(x) != "data" else "data", "manifest", 0))
            elif k in ("js", "py"):
                e = self.js_py_refs(rel, k)
            else:
                e = []
            e = [r for r in e if r.dep != rel]
            self._edges[rel] = e
        return e

    # -- test_helper function model -------------------------------------------------
    def helper_model(self, rel="tests/test_helper.bash"):
        text = self.repo.text(rel)
        funcs, cur, start = {}, None, 0
        toplevel = set()
        for i, ln in enumerate(text.split("\n"), 1):
            m = re.match(r'^([A-Za-z_][\w:-]*)\s*\(\)\s*\{', ln)
            if cur is None and m:
                cur, start = m.group(1), i
                continue
            if cur is not None:
                if ln.startswith("}"):
                    funcs[cur] = set(range(start, i + 1))
                    cur = None
                continue
            toplevel.add(i)
        refs_all = self.shell_refs(rel, in_tests=True)
        by_line = collections.defaultdict(list)
        for r in refs_all:
            by_line[r.line].append(r)
        fn_refs = {f: [r for ln in sorted(lines) for r in by_line.get(ln, [])] for f, lines in funcs.items()}
        top_refs = [r for ln in sorted(toplevel) for r in by_line.get(ln, [])]
        calls = {}
        for f, lines in funcs.items():
            body = "\n".join(text.split("\n")[min(lines) - 1:max(lines)])
            calls[f] = {g for g in funcs if g != f and re.search(r'(?<![\w-])' + re.escape(g) + r'(?![\w-])', body)}
        return funcs, fn_refs, top_refs, calls

    # -- closure ------------------------------------------------------------------
    EXPAND = {"strict": {"source", "exec", "self"}, "call": {"source", "exec", "call", "self"}, "loose": None}

    def closure(self, test_rel, mode, helper):
        funcs, fn_refs, top_refs, calls = helper
        repo = self.repo
        best = {}
        expanded = set()
        queue = collections.deque()

        def add(dep, kind, via, expand=True):
            if dep not in best:
                best[dep] = via
            if not expand or dep in expanded or repo.kind(dep) == "data":
                return
            # another test file is only ever read (listed, grepped), never run from here
            if dep != test_rel and dep.startswith("tests/") and dep.endswith(".bats"):
                return
            allowed = self.EXPAND[mode]
            if allowed is not None and kind not in allowed:
                return
            expanded.add(dep)
            queue.append(dep)

        add(test_rel, "self", "self")
        text = repo.text(test_rel)
        code = "\n".join(l for l in text.split("\n") if not l.strip().startswith("#"))
        loads = []
        for ln in text.split("\n"):
            m = R_LOAD.match(ln)
            if m:
                name = m.group(1)
                for cand in ("tests/%s.bash" % name, "tests/%s" % name):
                    if cand in repo.fileset:
                        loads.append(cand)
                        break
        used = set()
        if "tests/test_helper.bash" in loads:
            add("tests/test_helper.bash", "load", "load", expand=False)
            todo = [f for f in funcs if re.search(r'(?<![\w-])' + re.escape(f) + r'(?![\w-])', code)]
            while todo:
                f = todo.pop()
                if f in used:
                    continue
                used.add(f)
                todo.extend(calls.get(f, ()))
            for r in top_refs:
                add(r.dep, r.kind, "helper-top>%s%s:tests/test_helper.bash:%d" % (r.kind, "+" + r.qual if r.qual else "", r.line))
            for f in sorted(used):
                for r in fn_refs.get(f, ()):
                    add(r.dep, r.kind, "helper(%s)>%s%s:tests/test_helper.bash:%d" % (f, r.kind, "+" + r.qual if r.qual else "", r.line))
        for l in loads:
            if l != "tests/test_helper.bash":
                add(l, "source", "load")
        # A setup_test_env sandbox holds only scripts/ (+ db/, teams/): a script's reference to
        # <skill-root>/VERSION, SKILL.md, ... names a sandbox path, not a repo file -- unless the
        # test installs a real tree (install.sh / setup.sh / uninstall.sh / bin/agmsg.js).
        install_ctx = any(r.dep in ("install.sh", "setup.sh", "uninstall.sh", "bin/agmsg.js")
                          for r in self.edges(test_rel))
        while queue:
            f = queue.popleft()
            for r in self.edges(f):
                if not install_ctx and f.startswith("scripts/") and not r.dep.startswith("scripts/"):
                    continue
                add(r.dep, r.kind, "%s%s:%s:%d" % (r.kind, "+" + r.qual if r.qual else "", f, r.line))
        return best, used


def main():
    root, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    an = Analyzer(root)
    repo = an.repo
    tests = [f for f in repo.files if f.startswith("tests/") and f.endswith(".bats") and "/" not in f[len("tests/"):]]
    helper = an.helper_model()
    closures = {"strict": {}, "call": {}, "loose": {}}
    helpers_used = {}
    for t in tests:
        for mode in closures:
            closures[mode][t], used = an.closure(t, mode, helper)
        helpers_used[t] = used
    loose, strict = closures["loose"], closures["strict"]
    # every code file reached gets its edges computed; dump them
    with open(os.path.join(out, "edges.tsv"), "w") as fh:
        fh.write("src_file\tdep_file\tkind\tqual\tline\n")
        for src in sorted(an._edges):
            seen = set()
            for r in an._edges[src]:
                key = (r.dep, r.kind, r.qual)
                if key in seen:
                    continue
                seen.add(key)
                fh.write("%s\t%s\t%s\t%s\t%d\n" % (src, r.dep, r.kind, r.qual, r.line))
    RECOMMENDED = "call"
    for name, cl in (("static_closure.tsv", closures[RECOMMENDED]), ("static_closure_strict.tsv", strict),
                     ("static_closure_call.tsv", closures["call"]), ("static_closure_loose.tsv", loose)):
        with open(os.path.join(out, name), "w") as fh:
            fh.write("test_file\tdep_file\tvia\n")
            for t in tests:
                for dep in sorted(cl[t]):
                    fh.write("%s\t%s\t%s\n" % (t, dep, cl[t][dep]))
    seen = set()
    with open(os.path.join(out, "unresolved.tsv"), "w") as fh:
        fh.write("pattern\tfile\tline\tdetail\n")
        for row in an.unresolved:
            key = row[:3]
            if key in seen:
                continue
            seen.add(key)
            fh.write("%s\t%s\t%d\t%s\n" % (row[0], row[1], row[2], row[3].replace("\t", " ")))
    summary = {
        "tests": len(tests),
        "repo_files": len(repo.files),
        "loose_avg": sum(len(v) for v in loose.values()) / len(tests),
        "strict_avg": sum(len(v) for v in strict.values()) / len(tests),
        "call_avg": sum(len(v) for v in closures["call"].values()) / len(tests),
        "helpers_used": {t: sorted(v) for t, v in helpers_used.items()},
    }
    with open(os.path.join(out, "summary.json"), "w") as fh:
        json.dump(summary, fh, indent=1, sort_keys=True)
    print("tests=%d strict_avg=%.1f call_avg=%.1f loose_avg=%.1f unresolved_rows=%d" % (
        len(tests), summary["strict_avg"], summary["call_avg"], summary["loose_avg"], len(seen)))


if __name__ == "__main__":
    main()
