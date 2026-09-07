#!/usr/bin/env bash
#
# Fail when the subject a squash merge WILL write matches no cliff.toml rule.
#
# This checker rejects a subject that matches none of cliff.toml's commit
# parsers. Whether the matching rule keeps or skips is not the question:
# a skip rule is a deliberate exclusion (`chore:`, `ci:`, `release:` do not
# belong in the notes, and cliff.toml says so), so it passes. What fails is
# the subject nobody decided about -- it falls to the trailing catch-all and
# is dropped without anyone having chosen that. Three answers, then:
#
#   matches a keep rule        -> exit 0, it will be in the notes
#   matches a skip rule        -> exit 0, it is left out on purpose
#   matches only the catch-all -> exit 1, it is lost by accident
#
# The checker does not bind new subjects to the Conventional shape either:
# a Conventional subject can be excluded (`chore:`) and a non-Conventional
# one kept (the legacy rules in cliff.toml), so a check on the shape answers
# a different question.
#
# The repository squashes every PR (allow_merge_commit=false,
# allow_rebase_merge=false) with squash_merge_commit_title=COMMIT_OR_PR_TITLE.
# Measured on the 30 most recent PRs merged into main (2026-09-07): a PR with
# ONE commit lands under that commit's subject (3 of 3 cases where the two
# differed), a PR with two or more lands under the PR title (5 of 5). So the
# thing to check is not "the PR title" but "whichever of the two will become
# the subject", and this script asks for both inputs so it can pick.
#
# Why the subject matters: a subject git-cliff drops is silently absent from
# the release notes -- 1.1.7 lost a headline feature that way, and on the 1.3.0
# integration branch four more landed that way (#1047, #1062, #1064 and, on
# main, #1043).
#
# What git-cliff does, MEASURED with git-cliff 2.10.1 against this cliff.toml
# on a fixture repository (2026-09-07):
#   - commit_parsers are tried in file order and the FIRST match decides:
#     `chore: native windows bits` is dropped by the `^(chore|...)` skip rule
#     even though `(?i)native windows` would keep it;
#   - a rule with `group` keeps the commit, a rule with `skip = true` drops it,
#     and the trailing `.*` skip rule drops everything unmatched;
#   - matching is a regex SEARCH over the message, so `^feat` also keeps
#     `feature-flag: ...`, and `Feat:` (capitalised) is dropped;
#   - unanchored patterns see the commit BODY too: a subject with no match
#     whose body says "native windows" is kept. This script judges the SUBJECT
#     LINE only, because that line is what the notes show and what a reviewer
#     reads; the divergence is confined to cliff.toml's unanchored legacy
#     rules, and it errs towards red;
#   - three [git] keys change the answer, and each is read from cliff.toml
#     with git-cliff's own default (measured) used only when the key is
#     absent -- and the output says which were defaulted:
#       conventional_commits     (default true)  breaking marks are only parsed
#                                                on Conventional subjects
#       filter_unconventional    (default true)  drops every non-Conventional
#                                                commit before the rules run;
#                                                this cliff.toml sets it false,
#                                                which is what lets its legacy
#                                                non-Conventional keep rules
#                                                be reached at all
#       protect_breaking_commits (default false) a breaking commit is kept
#                                                even when a skip rule -- or
#                                                the catch-all -- matches it
#                                                first: `chore!:`, `release!:`
#                                                and `wip!:` are all kept when
#                                                it is true, dropped when false
#
# This checker reads the subject line only. The body's `BREAKING CHANGE:`
# footer is not visible to it, so a subject that hits a skip rule (or only
# the catch-all) and is breaking only in its body comes back red -- git-cliff
# keeps it, but that cannot be detected here. The blind spot is deliberately
# on the red side, so that it never produces a false green: a false red is
# seen by a person, who fixes one line or waives it; a false green is seen
# by nobody until the notes are missing an entry. The body is not taken as
# input because at PR time the squash body is not yet fixed, and judging
# something that can still change is how a "passed, then dropped" happens.
# If such a subject must pass, put the `!` in the subject, or a person decides.
#
# The rules are DERIVED from cliff.toml at run time, never retyped here; a
# rule added there is honoured by the next run.
#
# What this checks, in order:
#   1. cliff.toml can be read and has parsers of the shape this reads (at
#      least one `group` rule and at least one `skip` rule). If not, exit 2 --
#      a checker that cannot derive its rule has nothing to be green about.
#   2. There is a subject to check. No subject, no commit count, an unreadable
#      head: exit 2, not 0. Scanning nothing is not a pass.
#   3. The first cliff.toml rule matching the subject is a keep rule or a
#      skip rule written for it: exit 0, naming the rule. Only the catch-all
#      (a skip rule that matches everything, `.*`), or nothing: exit 1.
#
# Usage (CI passes the first form; the second is for a pre-PR check by hand):
#   check-squash-subject.sh --title "<PR title>" --commits <N> --head <sha> [--repo <dir>]
#   check-squash-subject.sh --subject "<the subject as it would land>"
#   check-squash-subject.sh --parsers        # print the rules as derived, in order
#
# --repo is where <sha> is read from (default: this checkout), so the
# selection can be exercised against a fixture repository.
#
# Environment:
#   AGMSG_CLIFF_CONFIG   path to cliff.toml (default: <repo>/cliff.toml), so the
#                        derivation can be exercised against a fixture.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLIFF="${AGMSG_CLIFF_CONFIG:-$ROOT/cliff.toml}"
ME=check-squash-subject

title=""; commits=""; head=""; subject=""; subject_source=""; repo="$ROOT"; mode=judge
while [ $# -gt 0 ]; do
  case "$1" in
    --title|--commits|--head|--repo|--subject)
      # An option without its value must end here, not loop: `shift 2` with
      # one argument left fails without shifting, and this loop has no errexit.
      if [ $# -lt 2 ]; then
        echo "$ME: $1 needs a value." >&2
        exit 2
      fi ;;
  esac
  case "$1" in
    --title)   title="$2";   shift 2 ;;
    --commits) commits="$2"; shift 2 ;;
    --head)    head="$2";    shift 2 ;;
    --repo)    repo="$2";    shift 2 ;;
    --subject) subject="$2"; subject_source="the subject given on the command line"; shift 2 ;;
    --parsers) mode=parsers; shift ;;
    -h|--help) sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "$ME: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- 1. derive the rules from cliff.toml -----------------------------------------
#
# Reads the `commit_parsers = [ ... ]` array of the [git] table line by line:
# one `{ message = "<regex>", group = "..." }` or `{ ..., skip = true }` per
# line, as the file is written. No TOML library, so it runs on any python3.
# Also reads the three flags above, each with its measured git-cliff default
# and a note of whether the file or the default supplied it.
#
# Prints, first, one header line
#   config: conventional_commits=<bool>(file|default) filter_unconventional=... protect_breaking_commits=...
# then one rule per line:  <index>\t<keep|skip>\t<pattern>.  Exits 2 when the
# file has no usable rules.
derive_rules() {
  python3 - "$1" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
try:
    text = p.read_text()
except OSError as e:
    print(f"cannot read {p}: {e}", file=sys.stderr); sys.exit(2)
# Only the [git] table matters; stop at the next table header.
m = re.search(r'^\[git\]\s*$(.*?)(?=^\[|\Z)', text, re.S | re.M)
git = m.group(1) if m else ''
def flag(name, default):
    mm = re.search(r'^\s*' + name + r'\s*=\s*(true|false)\b', git, re.M)
    if mm:
        return (mm.group(1) == 'true'), 'file'
    return default, 'default'
# git-cliff's defaults, measured 2.10.1: conventional_commits true,
# filter_unconventional true, protect_breaking_commits false.
flags = [(n, *flag(n, d)) for n, d in (('conventional_commits', True),
                                       ('filter_unconventional', True),
                                       ('protect_breaking_commits', False))]
# The parsers array: everything between `commit_parsers = [` and the closing `]`
# that starts a line.
a = re.search(r'^\s*commit_parsers\s*=\s*\[(.*?)^\s*\]', git, re.S | re.M)
rules = []
if a:
    for line in a.group(1).splitlines():
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        mm = re.search(r'message\s*=\s*"((?:[^"\\]|\\.)*)"', s)
        if not mm:
            continue
        pattern = bytes(mm.group(1), 'utf-8').decode('unicode_escape')
        if re.search(r'\bskip\s*=\s*true\b', s):
            kind = 'skip'
        elif re.search(r'\bgroup\s*=', s):
            kind = 'keep'
        else:
            continue
        rules.append((kind, pattern))
keeps = sum(1 for k, _ in rules if k == 'keep')
skips = sum(1 for k, _ in rules if k == 'skip')
if not rules or keeps == 0 or skips == 0:
    print(f"{p} has no usable commit_parsers (keep rules: {keeps}, skip rules: {skips}); "
          f"the file no longer has the shape this reads.", file=sys.stderr)
    sys.exit(2)
for k, pat in rules:
    try:
        re.compile(pat)
    except re.error as e:
        print(f"{p}: cannot compile parser pattern {pat!r}: {e}", file=sys.stderr); sys.exit(2)
print("config: " + " ".join(f"{n}={'true' if v else 'false'}({src})" for n, v, src in flags))
for i, (k, pat) in enumerate(rules, 1):
    print(f"{i}\t{k}\t{pat}")
PY
}

if ! rules="$(derive_rules "$CLIFF")"; then
  echo "$ME: cannot derive the rules from $CLIFF; nothing can be checked." >&2
  exit 2
fi
if [ "$mode" = parsers ]; then
  printf '%s\n' "$rules"
  exit 0
fi

# --- 2. pick the subject a squash merge would write ---------------------------
if [ -z "$subject" ]; then
  if [ -z "$title" ] && [ -z "$commits" ] && [ -z "$head" ]; then
    echo "$ME: no --subject and no --title/--commits/--head; nothing to check is not a pass." >&2
    exit 2
  fi
  case "$commits" in
    ''|*[!0-9]*|0)
      echo "$ME: --commits must be the PR's commit count (got '${commits}'); without it the landing subject cannot be chosen." >&2
      exit 2 ;;
  esac
  if [ "$commits" -eq 1 ]; then
    if [ -z "$head" ]; then
      echo "$ME: a one-commit PR lands under its commit's subject, and no --head was given to read it from." >&2
      exit 2
    fi
    if ! subject="$(git -C "$repo" log -1 --format=%s "$head" 2>/dev/null)" || [ -z "$subject" ]; then
      echo "$ME: cannot read the subject of $head in $repo (not fetched?); a one-commit PR lands under that subject." >&2
      exit 2
    fi
    subject_source="the single commit's subject ($head), which COMMIT_OR_PR_TITLE uses for a one-commit PR"
  else
    if [ -z "$title" ]; then
      echo "$ME: a $commits-commit PR lands under the PR title, and no --title was given." >&2
      exit 2
    fi
    subject="$title"
    subject_source="the PR title, which COMMIT_OR_PR_TITLE uses for a $commits-commit PR"
  fi
fi

# --- 3. what git-cliff would do with it ------------------------------------------
#
# Prints one line:  keep|skip|lost <TAB> <reason>   -- the first matching rule
# in file order decides, as measured. A skip rule that matches EVERYTHING (the
# trailing `.*`, recognised as any pattern that matches the empty string) is
# the catch-all, not a decision about this subject: landing there is `lost`.
# The rules travel in the environment: the python program itself is what
# `python3 -` reads from stdin. (A function, not an inline `$( ... <<'PY' )`:
# bash 3.2 mis-parses a heredoc with an unbalanced parenthesis inside command
# substitution.)
judge_subject() {   # $1 = subject; RULES in the environment
  python3 - "$1" <<'PY'
import os, re, sys
subject = sys.argv[1]
lines = os.environ['RULES'].splitlines()
cfg = dict(re.findall(r'(\w+)=(true|false)\(', lines[0]))
conventional = cfg['conventional_commits'] == 'true'
filter_unconventional = cfg['filter_unconventional'] == 'true'
protect_breaking = cfg['protect_breaking_commits'] == 'true'
rules = [l.split('\t', 2) for l in lines[1:]]
# The Conventional shape git-cliff parses:  <type>(<scope>)?!?: <description>.
# Both flags below only mean anything for a Conventional subject (measured:
# with conventional_commits=false a `chore!:` is not protected).
conv = re.match(r'^[A-Za-z][A-Za-z0-9_-]*(\([^()]*\))?(!)?: \S', subject) if conventional else None
# git-cliff's `filter_unconventional` drops a non-Conventional commit before
# any parser runs. No rule was written for the subject: a loss, not an exclusion.
if filter_unconventional and not conv:
    print("lost\tfilter_unconventional is true, and this subject is not of the form "
          "<type>(<scope>)?!?: <description>, so it is dropped before any parser runs")
    sys.exit(0)
# A breaking commit is kept regardless of which rule matches -- skip rules and
# the catch-all included (measured: `chore!:`, `release!:`, `wip!:` all kept).
# Only the subject's `!` is visible here; a footer-only BREAKING CHANGE is the
# documented blind spot and falls through to the rules, i.e. towards red.
if protect_breaking and conv and conv.group(2):
    print("keep\ta breaking change (`!` in the subject), which protect_breaking_commits keeps whatever rule matches")
    sys.exit(0)
for i, kind, pat in rules:
    if re.search(pat, subject):
        if kind == 'keep':
            print(f"keep\tkept by parser {i} `{pat}`")
        elif re.search(pat, ''):
            print(f"lost\tmatches no rule but the catch-all (parser {i} `{pat}`), so it is dropped without anyone having decided that")
        else:
            print(f"skip\tleft out of the notes on purpose by parser {i} `{pat}` (skip = true)")
        sys.exit(0)
print("lost\tmatches none of cliff.toml's parsers, so it is dropped without anyone having decided that")
PY
}
verdict="$(RULES="$rules" judge_subject "$subject")"
decision="${verdict%%	*}"
reason="${verdict#*	}"

config="$(printf '%s\n' "$rules" | head -1)"

case "$decision" in
  keep)
    echo "$ME: ok -- git-cliff keeps it ($reason). Checked $subject_source:"
    echo "  $subject"
    echo "  $config"
    exit 0 ;;
  skip)
    echo "$ME: ok -- git-cliff excludes it deliberately ($reason). Checked $subject_source:"
    echo "  $subject"
    echo "  $config"
    exit 0 ;;
  lost)
    echo "$ME: this subject would be lost from the release notes: $reason." >&2
    echo >&2
    echo "  $subject" >&2
    echo "  $config" >&2
    echo >&2
    echo "Checked: $subject_source." >&2
    echo "The rules are cliff.toml's commit_parsers, first match wins; \`$0 --parsers\`" >&2
    echo "prints them as derived. A subject a keep rule matches goes into the notes; one" >&2
    echo "a skip rule matches is left out on purpose and passes too. Retitle the PR, or" >&2
    echo "for a one-commit PR reword that commit (or add a second commit so the PR title" >&2
    echo "is what lands)." >&2
    exit 1 ;;
  *)
    echo "$ME: internal error: no verdict for the subject." >&2
    exit 2 ;;
esac
