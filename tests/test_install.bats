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
