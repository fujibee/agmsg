#!/usr/bin/env bats
# cut-release.sh releases from the branch you are on, not from `main` (#679).
#
# These run against a throwaway repository with a local bare remote, and with
# `gh` and `git-cliff` replaced by recorders. Nothing here reaches the network
# and nothing here opens a real PR: what is measured is the argv the script
# would have handed to `gh`, which is where the defect lived -- `--base main`,
# unconditionally, on a release cut from `integration/remote`.

load test_helper

setup() {
  CUT="$BATS_TEST_DIRNAME/../scripts/release/cut-release.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  BIN="$BATS_TEST_TMPDIR/bin"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  CLIFF_LOG="$BATS_TEST_TMPDIR/cliff.log"
  mkdir -p "$BIN"

  # `gh` answers the identity check and records everything else. `git-cliff`
  # only records: whether it ran at all is one of the things under test.
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$GH_LOG"' \
    'case "$*" in *"api user"*) echo fujibee ;; esac' > "$BIN/gh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$CLIFF_LOG"' > "$BIN/git-cliff"
  chmod +x "$BIN/gh" "$BIN/git-cliff"

  git init -q --bare "$REMOTE"
  mkdir -p "$REPO/scripts/release" "$REPO/.claude-plugin"
  cp "$CUT" "$REPO/scripts/release/cut-release.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$REPO/scripts/release/sync-version.sh"
  chmod +x "$REPO/scripts/release/"*.sh
  printf '1.2.0-rc.3\n' > "$REPO/VERSION"
  printf '{"version":"1.2.0-rc.3"}\n' > "$REPO/package.json"
  printf '{"version":"1.2.0-rc.3"}\n' > "$REPO/.claude-plugin/plugin.json"
  printf '# Changelog\n' > "$REPO/CHANGELOG.md"

  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm init
  git -C "$REPO" remote add origin "$REMOTE"
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" switch -qc integration/remote
  git -C "$REPO" push -q -u origin integration/remote
}

run_cut() {
  cd "$REPO" || return 1
  run env PATH="$BIN:$PATH" GH_LOG="$GH_LOG" CLIFF_LOG="$CLIFF_LOG" \
    bash scripts/release/cut-release.sh "$@"
}

@test "cut-release: a prerelease from a side branch opens its PR against THAT branch (#679)" {
  run_cut 1.2.0-rc.4
  [ "$status" -eq 0 ]
  # The defect, stated as an assertion: the base must be the branch released
  # from. Before #679 this was the literal string `main` on every cut.
  grep -q -F -- "pr create --base integration/remote --head release/v1.2.0-rc.4" "$GH_LOG"
  refute grep -qF -- "--base main" <<<"$(cat "$GH_LOG")"
  # And the branch it actually pushed carries the bump.
  [ "$(git -C "$REPO" show "release/v1.2.0-rc.4:VERSION")" = "1.2.0-rc.4" ]
}

@test "cut-release: a prerelease leaves CHANGELOG.md alone, and says so" {
  run_cut 1.2.0-rc.4
  [ "$status" -eq 0 ]
  # rc.1, rc.2 and rc.3 were all cut without a CHANGELOG section, and the file
  # carries no `rc.` heading for any of them. This is that rule, enforced.
  [ ! -s "$CLIFF_LOG" ]
  printf '%s\n' "$output" | grep -q -F -- "CHANGELOG.md is left alone"
  # The commit must not carry it either -- a `git add` of an untouched file is
  # harmless, but it would mean the decision lived only in the message.
  run git -C "$REPO" show --stat --name-only "release/v1.2.0-rc.4"
  refute grep -qF -- "CHANGELOG.md" <<<"$output"
}

@test "cut-release: a stable version still regenerates the changelog" {
  # The negative control for the test above. Without it, a script that skipped
  # git-cliff unconditionally would pass just as well.
  run_cut 1.3.0
  [ "$status" -eq 0 ]
  [ -s "$CLIFF_LOG" ]
  grep -q -F -- "--tag v1.3.0" "$CLIFF_LOG"
}

@test "cut-release: a detached HEAD is refused by name, not treated as a branch" {
  git -C "$REPO" checkout -q --detach
  run_cut 1.2.0-rc.4
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q -F -- "HEAD is detached"
}

@test "cut-release: a branch with no counterpart on origin is refused, naming it" {
  git -C "$REPO" switch -qc local-only
  run_cut 1.2.0-rc.4
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q -F -- "origin/local-only does not exist"
}

@test "cut-release: cutting from an existing release branch is refused" {
  git -C "$REPO" switch -qc release/v9.9.9
  git -C "$REPO" push -q -u origin release/v9.9.9
  run_cut 1.2.0-rc.4
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q -F -- "already on a release branch"
}

@test "cut-release: a branch out of sync with its own origin is refused" {
  # Was "local main is not in sync with origin/main". The check is the same one;
  # what changed is which branch it is about. An unpushed commit is enough --
  # the assertion is equality with origin, in either direction.
  git -C "$REPO" commit -q --allow-empty -m "not pushed"
  run_cut 1.2.0-rc.4
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q -F -- "not in sync with origin/integration/remote"
}
