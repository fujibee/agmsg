#!/usr/bin/env bats

# Install smoke tests. These run the real install.sh against a throwaway HOME so
# the packaged artifact (not a hand-built tree like test_helper builds) is what
# gets validated. Catches packaging drift — e.g. a new scripts/lib/ helper that
# the installer forgets to copy, which would make every command die at `source`.

load test_helper  # for setup_live_owner

setup() {
  export FAKE_HOME="$(mktemp -d)"
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SK="$FAKE_HOME/.agents/skills/agmsg"
}

teardown() {
  rm -rf "$FAKE_HOME"
}

@test "install: fresh install ships scripts/lib and the commands actually run" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  [ -f "$SK/scripts/lib/storage.sh" ]

  # End-to-end through the installed scripts — a missing sourced helper would
  # surface here, not just as a stat on a file.
  bash "$SK/scripts/join.sh" demo alice claude-code /tmp/install-projA
  bash "$SK/scripts/join.sh" demo bob   claude-code /tmp/install-projB
  run bash "$SK/scripts/send.sh" demo alice bob "hello from install"
  [ "$status" -eq 0 ]
  run bash "$SK/scripts/inbox.sh" demo bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hello from install" ]]
}

@test "install: --update restores scripts/lib even if it went missing" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  rm -rf "$SK/scripts/lib"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  [ -f "$SK/scripts/lib/storage.sh" ]
  run bash "$SK/scripts/send.sh" demo alice bob "after update"
  [ "$status" -eq 0 ]
}

@test "install: AGMSG_STORAGE_PATH override works against the installed skill" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local store="$FAKE_HOME/override-store"
  AGMSG_STORAGE_PATH="$store" bash "$SK/scripts/send.sh" demo alice bob "via override"
  [ -f "$store/messages.db" ]
  run bash -c "AGMSG_STORAGE_PATH='$store' bash '$SK/scripts/inbox.sh' demo bob"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "via override" ]]
}

# Regression: actas-claim.sh used to source lib/actas-lock.sh without first
# setting SKILL_DIR, which made `: "${SKILL_DIR:?...}"` fire and the script
# die in any fresh-shell invocation. bats tests passed because test_helper
# pre-exports SKILL_DIR. This guards against that whole class of bug for
# any directly-invoked script — invoke via `env -i` so nothing from the
# bats environment leaks into the child shell.
@test "install: actas-claim runs in a fresh shell with no inherited env" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  bash "$SK/scripts/join.sh" demo alice claude-code /tmp/install-projA

  run env -i PATH=/usr/bin:/bin:/usr/local/bin HOME="$FAKE_HOME" \
    bash "$SK/scripts/actas-claim.sh" /tmp/install-projA claude-code alice fresh-sid-1
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=ok" ]]
  [[ "$output" =~ "team=demo" ]]
}

# Regression: re-invoking Monitor for the same session_id used to leave the
# previous watch.sh running but invisible to every cleanup pathway (pidfile
# got overwritten). watch.sh now self-cleans the previous holder of its
# pidfile at startup. See #66.
@test "install: drops a Copilot SKILL.md when ~/.copilot exists" {
  mkdir -p "$FAKE_HOME/.copilot"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local copilot_skill="$FAKE_HOME/.copilot/skills/agmsg/SKILL.md"
  [ -f "$copilot_skill" ]
  # The Copilot SKILL.md must drive whoami with type=copilot, not codex,
  # otherwise Copilot sessions get mis-identified.
  grep -q "whoami.sh \"\$(pwd)\" copilot" "$copilot_skill"
  ! grep -q "whoami.sh \"\$(pwd)\" codex" "$copilot_skill"
  # Frontmatter has the substituted skill name.
  grep -q "^name: agmsg" "$copilot_skill"
}

@test "install: skips Copilot skill when ~/.copilot is absent" {
  # Make sure ~/.copilot isn't there
  rm -rf "$FAKE_HOME/.copilot"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  [ ! -d "$FAKE_HOME/.copilot" ]
}

@test "install --update: refreshes the Copilot skill if it was previously installed" {
  mkdir -p "$FAKE_HOME/.copilot"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local copilot_skill="$FAKE_HOME/.copilot/skills/agmsg/SKILL.md"
  [ -f "$copilot_skill" ]
  # Mutate the file so we can verify --update overwrites.
  echo "tampered" > "$copilot_skill"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  ! grep -q "^tampered$" "$copilot_skill"
  grep -q "whoami.sh \"\$(pwd)\" copilot" "$copilot_skill"
}

# Regression for a Copilot review finding: --update used to gate the Copilot
# skill refresh on the SKILL.md already existing, which meant users who had
# installed agmsg before the Copilot integration landed could never gain the
# skill via the documented upgrade path. --update must install it for them.
@test "install --update: installs Copilot skill for upgraders without prior skill" {
  # First install without ~/.copilot, simulating a Copilot-less environment
  # at the time the user originally installed agmsg.
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  [ ! -d "$FAKE_HOME/.copilot/skills/agmsg" ]
  # User then installs Copilot CLI and runs --update.
  mkdir -p "$FAKE_HOME/.copilot"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  [ -f "$FAKE_HOME/.copilot/skills/agmsg/SKILL.md" ]
  grep -q "whoami.sh \"\$(pwd)\" copilot" "$FAKE_HOME/.copilot/skills/agmsg/SKILL.md"
}

@test "install: Windows helpers are generated with the selected command name" {
  AGMSG_FORCE_WINDOWS=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd msg

  [ -f "$FAKE_HOME/.agents/msg.ps1" ]
  [ -f "$FAKE_HOME/.agents/msg-run.sh" ]
  [ -f "$FAKE_HOME/.agents/bin/sqlite3" ]
  [ -x "$FAKE_HOME/.agents/msg-run.sh" ]
  [ -x "$FAKE_HOME/.agents/bin/sqlite3" ]

  grep -q "function msg" "$FAKE_HOME/.agents/msg.ps1"
  grep -q '\$HOME/.agents/msg-run.sh' "$FAKE_HOME/.agents/msg.ps1"
  grep -q 'SKILL_NAME="${AGMSG_SKILL_NAME:-msg}"' "$FAKE_HOME/.agents/msg-run.sh"
  ! grep -q "__SKILL_NAME__" "$FAKE_HOME/.agents/msg.ps1"
  ! grep -q "__SKILL_NAME__" "$FAKE_HOME/.agents/msg-run.sh"
}

@test "install --update: restores Windows helpers" {
  AGMSG_FORCE_WINDOWS=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  echo "tampered" > "$FAKE_HOME/.agents/agmsg-run.sh"

  AGMSG_FORCE_WINDOWS=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update

  ! grep -q "^tampered$" "$FAKE_HOME/.agents/agmsg-run.sh"
  grep -q 'SKILL_NAME="${AGMSG_SKILL_NAME:-agmsg}"' "$FAKE_HOME/.agents/agmsg-run.sh"
}

@test "windows runner: sends and receives messages through AGMSG environment values" {
  AGMSG_FORCE_WINDOWS=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  bash "$SK/scripts/join.sh" demo alice codex /tmp/agmsg-win-a
  bash "$SK/scripts/join.sh" demo bob codex /tmp/agmsg-win-b

  local msg="hello with spaces and 'quotes'"
  HOME="$FAKE_HOME" AGMSG_TEAM=demo AGMSG_AGENT=alice AGMSG_SUB=send AGMSG_TO=bob AGMSG_MSG="$msg" \
    bash "$FAKE_HOME/.agents/agmsg-run.sh"

  run env HOME="$FAKE_HOME" AGMSG_TEAM=demo AGMSG_AGENT=bob AGMSG_SUB=inbox \
    bash "$FAKE_HOME/.agents/agmsg-run.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "$msg" ]]
  [[ "$output" != *"^_"* ]]
  [ -f "$FAKE_HOME/.agents/run/sqlite3-shim.cache" ]
}

@test "plugin SKILL.md bootstrap: a fresh plugin install path can bootstrap ~/.agents/skills/agmsg" {
  # Simulate the post-plugin-install state: no ~/.agents/skills/agmsg yet, but
  # the plugin marketplace flow has populated the cache dir with a copy of the
  # repo. Then run the Step 0 bootstrap snippet from SKILL.md and assert the
  # canonical install location exists.
  local plugin_dir="$FAKE_HOME/.claude/plugins/cache/fujibee-agmsg/agmsg/1.0.0"
  mkdir -p "$plugin_dir"
  cp -R "$REPO_ROOT/." "$plugin_dir/"
  [ ! -d "$SK" ]  # canonical agmsg location absent

  # Run the same shell snippet our SKILL.md prescribes as Step 0.
  HOME="$FAKE_HOME" bash -c '
    if [ ! -d ~/.agents/skills/agmsg ]; then
      installer=$(ls ~/.claude/plugins/cache/fujibee-agmsg/agmsg/*/install.sh 2>/dev/null | head -1)
      [ -n "$installer" ] && bash "$installer" --cmd agmsg
    fi
  '

  [ -d "$SK" ]
  [ -f "$SK/db/messages.db" ]
  [ -f "$SK/scripts/whoami.sh" ]
  # The substituted SKILL.md the installer drops should not still carry the
  # __SKILL_NAME__ placeholder (Codex / Gemini / Antigravity all read it).
  ! grep -q "__SKILL_NAME__" "$SK/SKILL.md"
}

# Regression guard for #83: the plugin's SKILL.md is consumed verbatim by the
# Claude Code plugin install path, so it must not carry the install-time
# __SKILL_NAME__ placeholder (which install.sh substitutes for the
# generated-per-agent-type SKILL.md, but the plugin install does not).
@test "plugin SKILL.md: repo SKILL.md has no unsubstituted __SKILL_NAME__ placeholder" {
  ! grep -q "__SKILL_NAME__" "$REPO_ROOT/SKILL.md"
}

@test "install: watch.sh self-cleans a prior watcher on re-invocation for the same sid" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  bash "$SK/scripts/join.sh" demo alice claude-code /tmp/install-projA
  local sid="resue-sid-$$"

  bash "$SK/scripts/watch.sh" "$sid" /tmp/install-projA claude-code &
  local first=$!
  # Give the first watcher long enough to write the pidfile and enter its
  # poll loop. The sleep is short — if it's flaky, raise to 0.5s.
  sleep 0.3
  [ -f "$SK/run/watch.$sid.pid" ]
  [ "$(cat "$SK/run/watch.$sid.pid")" -eq "$first" ]

  bash "$SK/scripts/watch.sh" "$sid" /tmp/install-projA claude-code &
  local second=$!
  sleep 0.3
  # New pid wrote the pidfile.
  [ "$(cat "$SK/run/watch.$sid.pid")" -eq "$second" ]
  # And the previous one was actually killed.
  run kill -0 "$first"
  [ "$status" -ne 0 ]

  kill "$second" 2>/dev/null || true
  wait 2>/dev/null || true
}

# --- Pipe-stdin guard: simulate a curl|bash entry path (#98) ---
#
# The npm bootstrapper executes the wrapper as `curl ... | bash`, so install.sh
# runs with its stdin wired to the wrapper script stream rather than a tty.
# Before #98 this caused the interactive command-name prompt to consume the
# next line of the wrapper as CMD_NAME — installing the skill under e.g.
# "rm -rf $TMP/" instead of "agmsg". The guard added in install.sh forces
# INTERACTIVE=false whenever stdin is not a tty. These tests pipe a payload
# that would have been swallowed by `read -r` pre-fix, then verify the
# install landed under the default name and the payload bytes were left
# untouched on stdin.

@test "install: non-tty stdin falls back to the 'agmsg' default (#98)" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" </dev/null

  [ -d "$FAKE_HOME/.agents/skills/agmsg" ]
  [ -f "$SK/.agmsg" ]
  [ -f "$SK/scripts/whoami.sh" ]

  # No bogus skill directories created from a leaked stdin line.
  local bogus
  bogus=$(find "$FAKE_HOME/.agents/skills" -maxdepth 1 -mindepth 1 -type d ! -name agmsg | wc -l | tr -d ' ')
  [ "$bogus" = "0" ]
}

@test "install: payload on non-tty stdin is NOT consumed by the prompt (#98)" {
  # The real failure mode: install.sh's `read -r` would pull the next
  # line off stdin. Build a stdin that has a sentinel line after what
  # the install would have prompted for, then assert the sentinel
  # survived on stdin after install.sh returned.
  local stdin_capture stdout_capture
  stdin_capture=$(mktemp)
  stdout_capture=$(mktemp)
  {
    printf 'rm -rf "$TMP"\n'
    printf 'SENTINEL_SURVIVED\n'
  } | {
    HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" > "$stdout_capture" 2>&1
    cat > "$stdin_capture"
  }

  [ -d "$FAKE_HOME/.agents/skills/agmsg" ]
  grep -q '^rm -rf "\$TMP"$' "$stdin_capture"
  grep -q '^SENTINEL_SURVIVED$' "$stdin_capture"
  ! grep -q 'rm -rf' "$stdout_capture"
  rm -f "$stdin_capture" "$stdout_capture"
}

@test "install: records a git-describe provenance VERSION and /version prints it" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  # install.sh runs from a git checkout here, so the recorded version is a
  # `git describe` string: a tag (v1.2.3-N-gSHA) when tags are present, or — in
  # a tag-less checkout like CI's shallow clone — the bare abbreviated commit
  # from `--always` (any hex, e.g. a828563). Accept both; just not "unknown".
  [ -f "$SK/VERSION" ]
  run cat "$SK/VERSION"
  [ -n "$output" ]
  [[ "$output" =~ ^(v[0-9]|[0-9]+\.[0-9]+|[0-9a-f]{7}) ]]
  [[ "$output" != unknown* ]]
  # /version (version.sh) prints the same recorded value.
  run bash "$SK/scripts/version.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$SK/VERSION")" ]
}

@test "install: --update refreshes the recorded VERSION" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  echo "stale-marker" > "$SK/VERSION"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  run cat "$SK/VERSION"
  [ "$output" != "stale-marker" ]
}

@test "version.sh falls back gracefully when no VERSION was recorded" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  rm -f "$SK/VERSION"
  run bash "$SK/scripts/version.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "unknown" ]]
}

@test "install: a non-git copy nested in a foreign git repo records canonical VERSION, not the parent's describe" {
  # `git describe` searches ancestors for a .git. A non-git agmsg copy unpacked
  # under some OTHER git repo must still record agmsg's canonical VERSION, not
  # the parent repo's describe. See #117 review.
  local parent="$BATS_TEST_TMPDIR/foreign"
  mkdir -p "$parent"
  git -C "$parent" init -q
  git -C "$parent" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
  git -C "$parent" tag v9.9.9
  mkdir -p "$parent/agmsg-src"
  cp -R "$REPO_ROOT/." "$parent/agmsg-src/"
  rm -rf "$parent/agmsg-src/.git"   # non-git copy, nested under the foreign repo
  local canonical; canonical="$(tr -d '[:space:]' < "$parent/agmsg-src/VERSION")"

  HOME="$FAKE_HOME" bash "$parent/agmsg-src/install.sh" --cmd agmsg
  run cat "$SK/VERSION"
  [ "$output" = "$canonical" ]
  [[ "$output" != v9.9.9* ]]
}
