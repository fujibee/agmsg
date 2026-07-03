#!/usr/bin/env bats

# setup.sh is the bootstrapper both `npx agmsg` and the README's
# `curl .../main/setup.sh | bash` path run: it fetches the repo (git clone,
# with a curl+tar tarball fallback for machines with no git — see #172-adjacent
# git-less-install gap) into a temp dir and hands off to install.sh. These
# tests stub git/curl/tar so no real network call happens and the fetch
# outcome is deterministic; install.sh's own behavior is already covered by
# test_install.bats, so the fake install.sh here just records that it ran.

load test_helper

setup() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export FAKE_HOME="$(mktemp -d)"
  export STUB_BIN="$(mktemp -d)"

  # A fake install.sh that proves setup.sh handed off to *some* checkout
  # rather than asserting on install.sh's real behavior (covered elsewhere).
  read -r -d '' FAKE_INSTALL <<'EOF' || true
#!/usr/bin/env bash
echo "FAKE_INSTALL_RAN $*"
EOF
  export FAKE_INSTALL
}

teardown() {
  rm -rf "$FAKE_HOME" "$STUB_BIN"
}

stub_git_success() {
  cat > "$STUB_BIN/git" <<EOF
#!/usr/bin/env bash
dest="\${@: -1}"
mkdir -p "\$dest"
printf '%s\n' "\$FAKE_INSTALL" > "\$dest/install.sh"
chmod +x "\$dest/install.sh"
exit 0
EOF
  chmod +x "$STUB_BIN/git"
}

stub_git_fail() {
  cat > "$STUB_BIN/git" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN/git"
}

# Real git creates the clone destination dir before it can fail partway
# through (e.g. a bad ref after the initial mkdir). Reproduces that leftover.
stub_git_fail_partial_dest() {
  cat > "$STUB_BIN/git" <<'EOF'
#!/usr/bin/env bash
dest="${@: -1}"
mkdir -p "$dest"
touch "$dest/.git-partial-leftover"
exit 1
EOF
  chmod +x "$STUB_BIN/git"
}

stub_curl_marker() {
  # Records that it was invoked (used to prove it's skipped on the git-success path)
  cat > "$STUB_BIN/curl" <<EOF
#!/usr/bin/env bash
touch "$STUB_BIN/.curl-was-called"
exit 1
EOF
  chmod +x "$STUB_BIN/curl"
}

# Builds a real gzipped tarball fixture (top-level "agmsg-<ref>/install.sh")
# and stubs curl to just cat it to stdout instead of hitting the network.
stub_curl_tarball_success() {
  local ref="${1:-main}"
  local fixture_dir="$STUB_BIN/fixture"
  mkdir -p "$fixture_dir/agmsg-$ref"
  printf '%s\n' "$FAKE_INSTALL" > "$fixture_dir/agmsg-$ref/install.sh"
  chmod +x "$fixture_dir/agmsg-$ref/install.sh"
  tar -C "$fixture_dir" -czf "$STUB_BIN/fixture.tar.gz" "agmsg-$ref"

  cat > "$STUB_BIN/curl" <<EOF
#!/usr/bin/env bash
cat "$STUB_BIN/fixture.tar.gz"
EOF
  chmod +x "$STUB_BIN/curl"
}

stub_curl_tarball_malformed() {
  # A tarball with no top-level agmsg-* dir at all.
  local fixture_dir="$STUB_BIN/fixture"
  mkdir -p "$fixture_dir/not-agmsg"
  touch "$fixture_dir/not-agmsg/file"
  tar -C "$fixture_dir" -czf "$STUB_BIN/fixture.tar.gz" "not-agmsg"

  cat > "$STUB_BIN/curl" <<EOF
#!/usr/bin/env bash
cat "$STUB_BIN/fixture.tar.gz"
exit 0
EOF
  chmod +x "$STUB_BIN/curl"
}

stub_curl_fail() {
  cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
  chmod +x "$STUB_BIN/curl"
}

# install.sh that reports its own resolved directory then fails, so a test
# can find $TMP (its parent) and assert the EXIT trap cleaned it up.
stub_git_success_failing_install() {
  cat > "$STUB_BIN/git" <<'EOF'
#!/usr/bin/env bash
dest="${@: -1}"
mkdir -p "$dest"
cat > "$dest/install.sh" <<'INNER'
#!/usr/bin/env bash
echo "INSTALL_DIR=$(cd "$(dirname "$0")" && pwd)"
exit 3
INNER
chmod +x "$dest/install.sh"
exit 0
EOF
  chmod +x "$STUB_BIN/git"
}

@test "setup: uses git clone when git succeeds, never touches curl" {
  stub_git_success
  stub_curl_marker

  run env PATH="$STUB_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" \
    bash "$REPO_ROOT/setup.sh" --cmd agmsg-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAKE_INSTALL_RAN --cmd agmsg-test"* ]]
  [ ! -f "$STUB_BIN/.curl-was-called" ]
}

@test "setup: falls back to tarball download when git clone fails" {
  stub_git_fail
  stub_curl_tarball_success main

  run env PATH="$STUB_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" AGMSG_REF=main \
    bash "$REPO_ROOT/setup.sh" --cmd agmsg-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back to a tarball download"* ]]
  [[ "$output" == *"FAKE_INSTALL_RAN --cmd agmsg-test"* ]]
}

@test "setup: tarball fallback respects AGMSG_REF" {
  stub_git_fail
  stub_curl_tarball_success v1.1.3

  run env PATH="$STUB_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" AGMSG_REF=v1.1.3 \
    bash "$REPO_ROOT/setup.sh" --cmd agmsg-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAKE_INSTALL_RAN --cmd agmsg-test"* ]]
}

@test "setup: fails cleanly when git is unavailable and there is no curl/tar" {
  # A PATH with only the bare minimum (mktemp, rm) — no git, curl, or tar —
  # so the real system binaries can't leak in via a fallback PATH entry.
  local bare_bin="$(mktemp -d)"
  ln -s "$(command -v bash)" "$bare_bin/bash"
  ln -s "$(command -v mktemp)" "$bare_bin/mktemp"
  ln -s "$(command -v rm)" "$bare_bin/rm"

  run env -i PATH="$bare_bin" HOME="$FAKE_HOME" \
    bash "$REPO_ROOT/setup.sh" --cmd agmsg-test
  rm -rf "$bare_bin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"git unavailable, and no curl+tar to fall back to"* ]]
}

@test "setup: fails cleanly when the tarball download itself fails" {
  stub_git_fail
  stub_curl_fail

  run env PATH="$STUB_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" \
    bash "$REPO_ROOT/setup.sh" --cmd agmsg-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to download tarball"* ]]
}

@test "setup: fails cleanly when the tarball has no agmsg-* top-level dir" {
  stub_git_fail
  stub_curl_tarball_malformed

  run env PATH="$STUB_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" \
    bash "$REPO_ROOT/setup.sh" --cmd agmsg-test
  [ "$status" -ne 0 ]
  [[ "$output" == *"no agmsg-* directory was found"* ]]
}

@test "setup: tarball fallback works even if a failed git clone left a partial dest dir (#296 co1 finding)" {
  stub_git_fail_partial_dest
  stub_curl_tarball_success main

  run env PATH="$STUB_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" AGMSG_REF=main \
    bash "$REPO_ROOT/setup.sh" --cmd agmsg-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAKE_INSTALL_RAN --cmd agmsg-test"* ]]
}

@test "setup: tarball fallback resolves GitHub's dash-converted dir name for a slash-containing AGMSG_REF" {
  stub_git_fail
  # GitHub's archive endpoint converts slashes in the ref to dashes for the
  # top-level extracted directory name (e.g. feature/foo -> agmsg-feature-foo).
  stub_curl_tarball_success "feature-foo"

  run env PATH="$STUB_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" AGMSG_REF="feature/foo" \
    bash "$REPO_ROOT/setup.sh" --cmd agmsg-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAKE_INSTALL_RAN --cmd agmsg-test"* ]]
}

@test "setup: cleans up the temp dir (EXIT trap) even when install.sh fails" {
  stub_git_success_failing_install

  run env PATH="$STUB_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" \
    bash "$REPO_ROOT/setup.sh" --cmd agmsg-test
  [ "$status" -eq 3 ]
  local install_dir tmp_dir
  install_dir="$(echo "$output" | sed -n 's/^INSTALL_DIR=//p')"
  [ -n "$install_dir" ]
  tmp_dir="$(dirname "$install_dir")"
  [ ! -d "$tmp_dir" ]
}
