#!/usr/bin/env bats
#
# .github/scripts/check-squash-subject.sh: the subject a squash merge will
# write must carry a type cliff.toml classifies, or git-cliff drops it from the
# release notes. Three things are pinned here, each with a control in the
# other direction:
#
#   - the RULE: which subjects pass, including the ones that already landed
#     wrong (they must be red -- a checker that accepts the very cases it was
#     written for has never fired);
#   - the SELECTION: a one-commit PR is judged by its commit's subject, a larger
#     PR by its title (measured on merged PRs, see the script header);
#   - the ZERO-TARGET answer: no subject, no commit count, an unreadable head,
#     or a cliff.toml the derivation cannot read must be exit 2, never 0.

setup() {
  load 'test_helper'
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECK="$REPO_ROOT/.github/scripts/check-squash-subject.sh"
  export AGMSG_CLIFF_CONFIG="$REPO_ROOT/cliff.toml"
}

# A one-line cliff.toml fixture with exactly the parsers given, so the
# derivation can be pointed at a file whose contents the test controls.
_cliff_fixture() {   # <parser message patterns...>
  local f="$BATS_TEST_TMPDIR/cliff.toml" p
  {
    echo '[git]'
    echo 'commit_parsers = ['
    for p in "$@"; do printf '  { message = "%s", group = "x" },\n' "$p"; done
    echo '  { message = ".*", skip = true },'
    echo ']'
  } > "$f"
  printf '%s' "$f"
}

# A throwaway repository with one commit whose subject is given; prints the sha.
_repo_with_commit() {   # <subject>
  local d="$BATS_TEST_TMPDIR/repo"
  git init -q "$d"
  git -C "$d" -c user.name=t -c user.email=t@x commit -q --allow-empty -m "$1"
  git -C "$d" rev-parse HEAD
}

# --- the rule ---------------------------------------------------------------------

@test "each subject that already landed prefix-less is red" {
  # The cases this exists for. Measured on integration/terminal-driver-v1 and
  # main (2026-09-07); `spawn:` has the shape of a type and is not one.
  local s
  while IFS= read -r s; do
    run bash "$CHECK" --subject "$s"
    [ "$status" -eq 1 ] || { echo "accepted: $s"; return 1; }
    grep -q 'dropped from the release notes' <<<"$output" || { echo "no reason for: $s"; return 1; }
  done <<'EOF'
Naming is an invariant every entry point re-asserts, and the roster can see it (#1044)
Remove internal handles from the published tree, and check for them by identifier context
spawn: launch codex through the bundled monitor shim, and refuse a bare fallback
Reduce repeated ciphertext literals in pull apply
EOF
}

@test "a subject with a type cliff.toml keeps is green, scope and bang included" {
  local s
  while IFS= read -r s; do
    run bash "$CHECK" --subject "$s"
    [ "$status" -eq 0 ] || { echo "rejected: $s -- $output"; return 1; }
  done <<'EOF'
feat(spawn): set the pane's agent key at spawn so codex seats are not left nameless
fix: refuse a non-string envelope.blob
perf(sync): check a pulled wire id without a process
release: 1.3.0
chore(ci): pin the runner image
feat!: drop the legacy index
EOF
}

@test "the shape is exact: unknown type, missing space, wrong case are red" {
  local s
  while IFS= read -r s; do
    run bash "$CHECK" --subject "$s"
    [ "$status" -eq 1 ] || { echo "accepted: $s"; return 1; }
  done <<'EOF'
feature-flag: gate the new path
feat:no space after the colon
Feat: capitalised type
feat (spawn): space before the scope
EOF
}

@test "the type set is derived from cliff.toml, not retyped: a new type is accepted without editing the script" {
  # Differential pair on the same subject; only the fixture differs.
  export AGMSG_CLIFF_CONFIG
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture '^feat' '^fix')"
  run bash "$CHECK" --subject 'wibble: a subject of a type nobody has yet'
  [ "$status" -eq 1 ]
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture '^feat' '^fix' '^(wibble|wobble)')"
  run bash "$CHECK" --subject 'wibble: a subject of a type nobody has yet'
  [ "$status" -eq 0 ]
}

@test "the derivation reads the real cliff.toml the same way an independent scrape does" {
  # Canary for the sed in the script: a second, cruder scrape of the same file
  # must agree, and both must find a type that lives only in an alternation
  # (`chore`) and one that is skipped rather than grouped (`release`).
  local expected got
  expected="$(grep -oE 'message *= *"\^[a-z(][a-z|)]*' "$REPO_ROOT/cliff.toml" \
    | sed -E 's/.*"\^//; s/[()]//g' | tr '|' '\n' | sort -u)"
  got="$(bash "$CHECK" --subject 'not: a real one' 2>&1 >/dev/null | grep -A1 'derived from cliff.toml' | tail -1 | tr ' ' '\n' | sed '/^$/d' | sort -u)"
  [ "$got" = "$expected" ]
  grep -qx chore <<<"$got"
  grep -qx release <<<"$got"
}

# --- the selection: which subject would land ------------------------------------

@test "a one-commit PR is judged by its commit subject, even when the PR title is fine" {
  # The asymmetric case that a title-only check gets wrong: #1043 landed
  # prefix-less under a fine-looking review, because the commit is what lands.
  local sha
  sha="$(_repo_with_commit 'Reduce repeated ciphertext literals in pull apply')"
  run bash "$CHECK" --title 'fix(sync): reduce repeated ciphertext literals' --commits 1 --head "$sha" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 1 ]
  grep -q "single commit's subject" <<<"$output"
  grep -q 'Reduce repeated ciphertext literals' <<<"$output"
}

@test "a one-commit PR with a good commit subject is green even when the title is bad" {
  local sha
  sha="$(_repo_with_commit 'fix(sync): reduce repeated ciphertext literals')"
  run bash "$CHECK" --title 'Reduce repeated ciphertext literals in pull apply' --commits 1 --head "$sha" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  grep -q "single commit's subject" <<<"$output"
}

@test "a multi-commit PR is judged by its title, and the commit subjects do not matter" {
  local sha
  sha="$(_repo_with_commit 'wip')"
  run bash "$CHECK" --title 'feat(spawn): set the agent key at spawn' --commits 2 --head "$sha" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  grep -q 'the PR title' <<<"$output"
  run bash "$CHECK" --title 'Set the agent key at spawn' --commits 2 --head "$sha" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 1 ]
  grep -q 'the PR title' <<<"$output"
}

@test "the verdict names what it checked, in both directions" {
  # A green that does not say which subject it read is indistinguishable from
  # a green that read nothing.
  run bash "$CHECK" --subject 'fix: something'
  [ "$status" -eq 0 ]
  grep -q 'checked the subject given on the command line' <<<"$output"
  run bash "$CHECK" --subject 'something'
  [ "$status" -eq 1 ]
  grep -q '^Checked: the subject given on the command line' <<<"$output"
}

# --- zero targets are not a pass --------------------------------------------------

@test "no subject at all is exit 2, not green" {
  run bash "$CHECK"
  [ "$status" -eq 2 ]
  grep -q 'nothing to check is not a pass' <<<"$output"
}

@test "a missing or non-numeric commit count is exit 2" {
  run bash "$CHECK" --title 'fix: fine' --head deadbeef
  [ "$status" -eq 2 ]
  run bash "$CHECK" --title 'fix: fine' --commits many --head deadbeef
  [ "$status" -eq 2 ]
  run bash "$CHECK" --title 'fix: fine' --commits 0 --head deadbeef
  [ "$status" -eq 2 ]
}

@test "a one-commit PR whose head cannot be read is exit 2, not judged by the title" {
  # The title is fine here on purpose: falling back to it would be a green
  # about a subject that was never read.
  run bash "$CHECK" --title 'fix: fine' --commits 1 --head 0000000000000000000000000000000000000000
  [ "$status" -eq 2 ]
  grep -q 'cannot read the subject' <<<"$output"
  run bash "$CHECK" --title 'fix: fine' --commits 1
  [ "$status" -eq 2 ]
}

@test "a multi-commit PR with no title is exit 2" {
  run bash "$CHECK" --commits 3 --head deadbeef
  [ "$status" -eq 2 ]
}

@test "a cliff.toml the derivation cannot read is exit 2 even for a good subject" {
  # Differential pair on one good subject: only the config differs. The first
  # has no parsers at all; the second has parsers but not the canaries.
  export AGMSG_CLIFF_CONFIG
  AGMSG_CLIFF_CONFIG="$BATS_TEST_TMPDIR/missing.toml"
  run bash "$CHECK" --subject 'feat: fine'
  [ "$status" -eq 2 ]
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture '^(chore|ci)')"
  run bash "$CHECK" --subject 'feat: fine'
  [ "$status" -eq 2 ]
  grep -q "do not include 'feat'" <<<"$output"
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture '^feat' '^fix')"
  run bash "$CHECK" --subject 'feat: fine'
  [ "$status" -eq 0 ]
}

@test "the workflow passes the three inputs the selection needs, and re-runs on a title edit" {
  # The script can only pick the landing subject if CI hands it the commit
  # count and the head; and a title fixed by editing is only re-checked if
  # `edited` is among the event types.
  local wf="$REPO_ROOT/.github/workflows/squash-subject.yml"
  grep -q 'check-squash-subject.sh' "$wf"
  grep -q 'github.event.pull_request.commits' "$wf"
  grep -q 'github.event.pull_request.head.sha' "$wf"
  grep -q 'github.event.pull_request.title' "$wf"
  grep -Eq 'types: \[.*edited.*\]' "$wf"
}
