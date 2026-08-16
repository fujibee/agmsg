// Internal team names must not appear in what we publish. This repository IS
// the published artifact — its files are read on GitHub and rendered onto every
// user's disk at install — so the scope is "everything tracked", not a list of
// directories or extensions. A list would be short by one the next time someone
// adds a file type.
//
// Two detectors, because the two kinds of name need different treatment:
//
//   SHAPE      seat names follow <base>-cc<n> / <base>-co<n>. A pattern catches
//              the whole class, including seats that do not exist yet, and puts
//              no name into this file. Always runs.
//
//   INJECTED   names with no shape — a person's handle, a project nickname —
//              cannot be patterned. They are supplied from outside the repo,
//              because writing them here would publish exactly what the rule
//              exists to keep unpublished. A checker that leaks its own subject
//              is not a checker.
//
// Absent injection is a FAILURE, never a pass. A check that quietly does
// nothing is worse than no check: its green is read as "clean".

/**
 * Word boundaries by explicit character class, never `\b`. Two measured
 * reasons, one of them load-bearing today:
 *
 * 1. `-` must NOT be a boundary here. These two are the SHAPE's boundaries, and
 *    a shape is built out of hyphens: with `\b`, `<a>-<b>-cc1` could match from
 *    the middle and report `<b>-cc1`, naming a seat that does not exist while
 *    the real one goes unreported. Excluding `-` forces the match to start at
 *    the beginning of the name. (The bare-name boundaries are separate, and
 *    deliberately looser — see below.)
 *
 * 2. It says what it means. `\b` is defined against `\w`, so reading a pattern
 *    requires knowing which characters that covers in this engine — and the
 *    answer differs between engines on the same text. Python's `re` treats `の`
 *    as a word character, so a handle written straight against a particle in
 *    the Japanese docs matches nothing; JavaScript's `\w` is ASCII and finds
 *    it. Both were measured. The class below cannot drift that way, and those
 *    docs are real input here.
 */
const BEFORE = "(?<![A-Za-z0-9_-])";
const AFTER = "(?![A-Za-z0-9_-])";

/**
 * Bare names get plain boundaries on both sides, and DO overlap the shape.
 *
 * Two earlier versions tried to keep a seat name from being reported twice --
 * once by the shape, once as the bare name inside it -- and each attempt left a
 * hole where neither detector fired:
 *
 *   refusing `-` on the LEFT   missed `<team>-<name>`, 17 real occurrences
 *   refusing `-` on the RIGHT  missed `<name>-approved`, found in review
 *   suppressing when a role follows missed `<hyphenated-base>-cc1` entirely,
 *     because the shape does not match it either
 *
 * Every hole came from the same wish. A duplicate report costs a reader one
 * confused moment; a hole costs a published name. So the suppression is gone:
 * a seat name built on a listed base is reported by both detectors, and the
 * summary counts lines as well as findings so "two findings" reads as the one
 * edit it is.
 */
const NAME_BEFORE = "(?<![A-Za-z0-9])";
const NAME_AFTER = "(?![A-Za-z0-9])";

/**
 * A seat name: a base, then a role, then an optional index. The base may
 * itself contain hyphens -- `<a>-<b>-cc1` is a seat, and a base of
 * `[a-z][a-z0-9]*` alone matched neither from `<a>` (where `-<b>` is not a
 * role) nor from `<b>` (where the preceding hyphen is refused).
 *
 * Only `cc` and `co` are roles here, and that is measured rather than assumed:
 * adding `x` or `it` to the alternation matches `linux-x64`, `win32-x64`,
 * `darwin-x64` and friends — over three hundred false hits across the tree,
 * which is how a check gets switched off.
 *
 * Case-SENSITIVE, also measured. Seat names are lowercase by construction, and
 * matching case-insensitively adds exactly one hit on the current tree:
 * `non-CC` in "older CC, non-CC runtimes", where CC is Claude Code. 60 real
 * hits either way, one false positive with the flag on.
 */
export const SEAT_SHAPE = new RegExp(
  `${BEFORE}[a-z][a-z0-9]*(?:-[a-z0-9]+)*-(?:cc|co)[0-9]*${AFTER}`,
  "g",
);

/** Escape a supplied name so a stray `.` or `+` cannot widen the match. */
const quote = (name) => name.replace(/[.*+?^${}()|[\]\\-]/gu, "\\$&");

/**
 * Build the matcher for injected names. Returns null when none were supplied —
 * the caller decides what to do about that, and the only correct answer is to
 * fail.
 */
export function injectedPattern(names) {
  const cleaned = names.map((name) => name.trim()).filter(Boolean);
  if (cleaned.length === 0) return null;
  // Longest first so a name that contains another is reported as itself.
  const alternation = [...cleaned]
    .sort((a, b) => b.length - a.length)
    .map(quote)
    .join("|");
  // Case-INSENSITIVE here, unlike the shape. A handle is a word in prose and
  // gets capitalised at the start of a sentence, and that is the same
  // attribution as the lowercase form. No capitalised variant exists on the
  // current tree, so this costs nothing today; it is for the one that will be
  // written, which a fixed sample cannot rule out.
  return new RegExp(`${NAME_BEFORE}(?:${alternation})${NAME_AFTER}`, "gi");
}

/** Read injected names from the environment: a literal list, or a file of them. */
const stripComments = (lines) =>
  // A list a person maintains needs somewhere to say why a name is on it.
  // Without this, `# a person's handle` becomes a "name" and the checker starts
  // matching the prose of its own configuration.
  lines.map((line) => line.replace(/(^|\s)#.*$/u, "$1"));

export function readInjectedNames(environment, readFile) {
  const literal = environment.AGMSG_PRIVATE_NAMES;
  const file = environment.AGMSG_PRIVATE_NAMES_FILE;
  if (literal && file) {
    throw new Error(
      "AGMSG_PRIVATE_NAMES and AGMSG_PRIVATE_NAMES_FILE are both set; " +
      "supply the list one way so there is one thing to audit",
    );
  }
  // An explicit, spelled-out opt-out. Not the same as "unset": the caller has
  // said so, and the runner prints that it happened. Unset stays a failure.
  if (literal === "none") return { names: [], declaredNone: true };
  if (literal) return { names: literal.split(/[\n,]/u), declaredNone: false };
  if (file) {
    const names = stripComments(readFile(file).split(/\n/u));
    // A file that is all comments supplied no names. Say absent, so the caller
    // fails rather than running a vacuous check that reports clean.
    return { names: names.some((name) => name.trim()) ? names : null, declaredNone: false };
  }
  return { names: null, declaredNone: false };
}

/**
 * Findings in one file's text. `line` is 1-indexed; `text` is the whole line, so
 * the report can be read without opening the file.
 */
export function scan(text, source, patterns) {
  const found = [];
  text.split("\n").forEach((line, index) => {
    for (const [kind, pattern] of patterns) {
      if (!pattern) continue;
      pattern.lastIndex = 0;
      for (const match of line.matchAll(pattern)) {
        found.push({ source, line: index + 1, kind, name: match[0], text: line.trim() });
      }
    }
  });
  return found;
}

/**
 * One line per finding, in the form an editor can jump to.
 *
 * The name is NOT printed by default, and neither is the line it sits on. This
 * check runs in CI, CI logs are readable by anyone who can read the repository,
 * and a report saying `found "<handle>"` publishes the handle at the exact
 * moment it is being flagged for not being published. A file and a line number
 * are enough to find it; the author has the file open.
 *
 * `reveal` is for running it by hand, where the output goes to your terminal.
 */
export function format(findings, { reveal = false } = {}) {
  return findings.map((f) => (reveal
    ? `${f.source}:${f.line}: [${f.kind}] "${f.name}" in: ${f.text}`
    : `${f.source}:${f.line}: [${f.kind}] internal name, ${f.name.length} chars`));
}
