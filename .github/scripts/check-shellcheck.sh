#!/usr/bin/env bash
#
# Fail when shellcheck finds more in the tracked .sh files than the baseline.
#
# No linter ran over the shell scripts in CI (#1068), so every "shellcheck
# clean" ever claimed was made on an unknown local setup -- and once, on a
# machine with no shellcheck at all, where "no output" read as "no findings".
# This runs it in one known place, and the claim it makes is attributable:
# the shellcheck version that ran is printed first, and the baseline is only
# valid for the version it was measured with.
#
# Same shape as check-enforced-assertions: the baseline is a COUNT recorded in
# the repository, it may only go down, and lowering it is the burn-down. All
# severities count. Gating at `error` would hide every warning and note for
# good, and that is where the real bash bugs in this tree live (unquoted
# expansions, `$?` after a pipeline, `read` without `-r`). A rule broken on
# purpose gets an inline `# shellcheck disable=SCxxxx` with a reason, not a
# global exclusion.
#
# What it refuses to be green about (exit 2, never 0):
#   - shellcheck is not there, or fails for a reason other than findings
#   - the shellcheck that ran is not the version the baseline was measured
#     with -- counts from different versions are not comparable
#   - no tracked .sh files were found: scanning nothing is not a pass
#   - the baseline file cannot be read
#
# Usage:
#   check-shellcheck.sh                     check the tree this script lives in
#   check-shellcheck.sh --positive-control  prove the checker fires: build a
#                                           throwaway repository with one
#                                           broken script and a zero baseline,
#                                           and require exit 1 from itself
#
# Environment:
#   SHELLCHECK                  the binary to run (default: `shellcheck` on PATH)
#   AGMSG_SHELLCHECK_ROOT       the git tree to scan (default: this checkout)
#   AGMSG_SHELLCHECK_BASELINE   the baseline file (default: <root>/.github/shellcheck-baseline)
#
# Baseline file: two lines --
#   <shellcheck version the count was measured with>
#   <finding count>

set -u

ME=check-shellcheck
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${AGMSG_SHELLCHECK_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
BASELINE_FILE="${AGMSG_SHELLCHECK_BASELINE:-$ROOT/.github/shellcheck-baseline}"
SHELLCHECK="${SHELLCHECK:-shellcheck}"

# --- the tool must demonstrably run -----------------------------------------------
if ! version="$("$SHELLCHECK" --version 2>/dev/null | sed -n 's/^version: *//p')" || [ -z "$version" ]; then
  echo "$ME: cannot run '$SHELLCHECK --version'; no shellcheck, no claim." >&2
  exit 2
fi
echo "$ME: shellcheck $version ($SHELLCHECK)"

# --- positive control ---------------------------------------------------------------
if [ "${1-}" = "--positive-control" ]; then
  tmp="$(mktemp -d)"
  git init -q "$tmp"
  # The `$` must reach the fixture literally: it is the unquoted expansion the
  # control expects shellcheck to flag (SC2086 at broken.sh:3:6).
  # shellcheck disable=SC2016
  printf '#!/bin/bash\nfoo=$1\necho $foo\n' > "$tmp/broken.sh"
  git -C "$tmp" add broken.sh
  printf '%s\n0\n' "$version" > "$tmp/baseline"
  out="$(AGMSG_SHELLCHECK_ROOT="$tmp" AGMSG_SHELLCHECK_BASELINE="$tmp/baseline" SHELLCHECK="$SHELLCHECK" "$SELF" 2>&1)"
  rc=$?
  rm -f "$tmp/broken.sh" "$tmp/baseline"
  rm -rf "$tmp/.git"
  rmdir "$tmp" 2>/dev/null || true
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'broken.sh:3:6: '; then
    echo "$ME: positive control fired -- a broken script against a zero baseline is exit 1, naming the finding."
    exit 0
  fi
  echo "$ME: positive control did NOT fire (exit $rc); the checker cannot be trusted to go red." >&2
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  exit 2
fi

# --- the baseline -------------------------------------------------------------------
if [ ! -r "$BASELINE_FILE" ]; then
  echo "$ME: no readable baseline at $BASELINE_FILE" >&2
  exit 2
fi
baseline_version="$(sed -n '1p' "$BASELINE_FILE" | tr -d '[:space:]')"
baseline="$(sed -n '2p' "$BASELINE_FILE" | tr -d '[:space:]')"
case "$baseline" in
  ''|*[!0-9]*)
    echo "$ME: $BASELINE_FILE line 2 must be the finding count (got '$baseline')" >&2
    exit 2 ;;
esac
if [ "$baseline_version" != "$version" ]; then
  echo "$ME: the baseline ($baseline findings) was measured with shellcheck $baseline_version, but $version ran." >&2
  echo "Counts from different versions are not comparable. Re-measure with $version and record both lines," >&2
  echo "or run the version the baseline names." >&2
  exit 2
fi

# --- the files ----------------------------------------------------------------------
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(git -C "$ROOT" ls-files -z -- '*.sh' 2>/dev/null)
if [ "${#files[@]}" -eq 0 ]; then
  echo "$ME: no tracked .sh files under $ROOT; this is not a clean tree, it is an empty scan." >&2
  exit 2
fi

# --- the count ----------------------------------------------------------------------
listing="$(cd "$ROOT" && "$SHELLCHECK" -f gcc "${files[@]}" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
  echo "$ME: shellcheck exited $rc, which is a tool failure, not a verdict:" >&2
  printf '%s\n' "$listing" | head -20 | sed 's/^/  /' >&2
  exit 2
fi
findings="$(printf '%s\n' "$listing" | grep -cE '^[^:]+:[0-9]+:[0-9]+: (error|warning|note|style): ')"

echo "$ME: ${#files[@]} tracked .sh files, $findings findings, baseline $baseline (shellcheck $version)."

if [ "$findings" -gt "$baseline" ]; then
  echo "$ME: $findings findings, above the baseline of $baseline." >&2
  echo >&2
  printf '%s\n' "$listing" | grep -E '^[^:]+:[0-9]+:[0-9]+: (error|warning|note|style): ' | sed 's/^/  /' >&2
  echo >&2
  echo "Fix the new findings, or disable the rule inline with a reason (# shellcheck disable=SCxxxx)." >&2
  echo "The baseline in $BASELINE_FILE only goes down." >&2
  exit 1
fi

if [ "$findings" -lt "$baseline" ]; then
  echo "$ME: $findings findings, below the baseline of $baseline."
  echo "Lower line 2 of $BASELINE_FILE to $findings so it cannot drift back up."
  exit 1
fi

echo "$ME: at the baseline."
