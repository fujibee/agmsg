#!/usr/bin/env bash
#
# Fail when the subject a squash merge WILL write is one git-cliff would drop.
#
# The repository squashes every PR (allow_merge_commit=false,
# allow_rebase_merge=false) with squash_merge_commit_title=COMMIT_OR_PR_TITLE.
# Measured on the 30 most recent PRs merged into main (2026-09-07): a PR with
# ONE commit lands under that commit's subject (3 of 3 cases where the two
# differed), a PR with two or more lands under the PR title (5 of 5). So the
# thing to check is not "the PR title" but "whichever of the two will become
# the subject", and this script asks for both inputs so it can pick.
#
# Why the subject matters: cliff.toml's commit_parsers classify a subject by an
# anchored prefix (`^feat`, `^fix`, ...) and its last rule skips everything
# else. A subject without one of those prefixes is silently absent from the
# release notes -- 1.1.7 lost a headline feature that way, and on the 1.3.0
# integration branch four more landed prefix-less:
#
#   Naming is an invariant every entry point re-asserts ...        (#1047)
#   Remove internal handles from the published tree ...            (#1062)
#   spawn: launch codex through the bundled monitor shim ...       (#1064)
#   Reduce repeated ciphertext literals in pull apply              (#1043, main)
#
# `spawn:` is the instructive one: it has the SHAPE of a type but is not one
# cliff.toml classifies, so shape alone is not the test. The accepted types
# are therefore DERIVED from cliff.toml at run time, never retyped here; a
# type added to cliff.toml is accepted by the next run of this script.
#
# What this checks, in order:
#   1. cliff.toml still has parsers of the shape this reads (canary: the derived
#      set must name feat and fix). If not, exit 2 -- a checker that cannot
#      derive its rule has nothing to be green about.
#   2. There is a subject to check. No subject, no commit count, an unreadable
#      head: exit 2, not 0. Scanning nothing is not a pass.
#   3. The subject matches  <type>(<scope>)?!?: <text>  with <type> in the
#      derived set. Otherwise exit 1, saying which subject was checked, why
#      that one, and what cliff would do with it.
#
# Usage (CI passes the first form; the second is for a pre-PR check by hand):
#   check-squash-subject.sh --title "<PR title>" --commits <N> --head <sha> [--repo <dir>]
#   check-squash-subject.sh --subject "<the subject as it would land>"
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

title=""; commits=""; head=""; subject=""; subject_source=""; repo="$ROOT"
while [ $# -gt 0 ]; do
  case "$1" in
    --title)   title="${2-}";   shift 2 ;;
    --commits) commits="${2-}"; shift 2 ;;
    --head)    head="${2-}";    shift 2 ;;
    --repo)    repo="${2-}";    shift 2 ;;
    --subject) subject="${2-}"; subject_source="the subject given on the command line"; shift 2 ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "$ME: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- 1. derive the accepted types from cliff.toml ----------------------------
#
# A parser line looks like  { message = "^feat", group = "..." }  or
# { message = "^(chore|ci|build|test|style)", skip = true }. Take every
# anchored pattern, keep the lowercase words at its start (a bare word or an
# alternation), and that is the set. Anything else in the file -- exact legacy
# titles, `^Merge`, the `.*` catch-all -- is not a type and is not collected.
if [ ! -r "$CLIFF" ]; then
  echo "$ME: cannot read $CLIFF; the accepted types are derived from it, so nothing can be checked." >&2
  exit 2
fi
types="$(
  grep -oE 'message *= *"\^(\([a-z|]+\)|[a-z]+)"' "$CLIFF" \
    | sed -E 's/.*"\^//; s/[()"]//g' | tr '|' '\n' | sed '/^$/d' | sort -u
)"
for canary in feat fix; do
  if ! printf '%s\n' "$types" | grep -qx "$canary"; then
    echo "$ME: the types derived from $CLIFF do not include '$canary' -- the file no longer has the shape this reads. Derived: $(printf '%s' "$types" | tr '\n' ' ')" >&2
    exit 2
  fi
done
alternation="$(printf '%s\n' "$types" | paste -sd '|' -)"

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

# --- 3. the rule ----------------------------------------------------------------
if printf '%s\n' "$subject" | grep -Eq "^($alternation)(\([^)]+\))?!?: [^ ]"; then
  echo "$ME: ok -- checked $subject_source:"
  echo "  $subject"
  exit 0
fi

echo "$ME: this subject would be dropped from the release notes." >&2
echo >&2
echo "  $subject" >&2
echo >&2
echo "Checked: $subject_source." >&2
echo "cliff.toml classifies a subject by its prefix and skips everything else, so" >&2
echo "the landed subject must look like  <type>(<scope>)?!?: <text>  with <type>" >&2
echo "one of (derived from cliff.toml):" >&2
echo "  $(printf '%s' "$types" | tr '\n' ' ')" >&2
echo "Retitle the PR, or for a one-commit PR reword that commit (or add a second" >&2
echo "commit so the PR title is what lands)." >&2
exit 1
