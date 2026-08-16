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
  # Pin bare instance-id keying (#93) so the watcher self-clean smoke test keys
  # its pidfile on the raw session_id it passes — deterministic in CI and when
  # the suite runs under an agent process.
  export AGMSG_AGENT_PID=""
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

@test "install: Codex skill documents safe Git Bash quoting for Windows PowerShell" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg --agent-type codex

  grep -Fq "& 'C:\\Program Files\\Git\\bin\\bash.exe' -lc '~/.agents/skills/agmsg/scripts/whoami.sh \"\$(pwd)\" codex'" "$SK/SKILL.md"
  grep -Fq "Do not use POSIX \`'\"'\"'\` quote splicing in PowerShell" "$SK/SKILL.md"
}

@test "install: --update restores scripts/lib even if it went missing" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  bash "$SK/scripts/join.sh" demo alice claude-code /tmp/install-update-projA
  bash "$SK/scripts/join.sh" demo bob   claude-code /tmp/install-update-projB
  rm -rf "$SK/scripts/lib"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  [ -f "$SK/scripts/lib/storage.sh" ]
  run bash "$SK/scripts/send.sh" demo alice bob "after update"
  [ "$status" -eq 0 ]
}

@test "install: ships an executable uninstall.sh so npx/curl installs have one to run later" {
  # setup.sh's temp checkout is deleted right after install, so a copy inside
  # the skill dir is the only uninstaller npx/curl-installed users ever have.
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  [ -x "$SK/uninstall.sh" ]
  diff "$REPO_ROOT/uninstall.sh" "$SK/uninstall.sh"
}

@test "install: --update refreshes uninstall.sh even if it went missing" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  rm -f "$SK/uninstall.sh"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  [ -x "$SK/uninstall.sh" ]
}

@test "install: --update --cmd updates the named skill even when a backup skill exists" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local backup="$FAKE_HOME/.agents/skills/agmsg.backup-keep"
  mkdir -p "$backup/scripts" "$backup/templates" "$backup/db" "$backup/agents"
  touch "$backup/.agmsg"
  echo "backup sentinel" > "$backup/SKILL.md"

  run env HOME="$FAKE_HOME" AGMSG_FORCE_WINDOWS=1 bash "$REPO_ROOT/install.sh" --cmd agmsg --update
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Updating agmsg..." ]]
  [[ ! "$output" =~ "Updating agmsg.backup-keep" ]]
  [ ! -f "$FAKE_HOME/.agents/agmsg.ps1" ]
  [ ! -f "$FAKE_HOME/.agents/agmsg.backup-keep.ps1" ]
  grep -q "backup sentinel" "$backup/SKILL.md"
}

@test "install: Claude Code command file gates actas/drop's fresh Monitor on delivery mode (#280)" {
  # actas/drop used to invoke a fresh Monitor unconditionally, ignoring
  # mode=off/turn (#280) — this is prompt-instruction text, not executable
  # code, so a content assertion is the regression coverage available: both
  # sections must carry the same delivery-mode gate the normal entry flow
  # already has (line ~90 in the template). The Claude Code command file is
  # only installed when ~/.claude exists (install.sh), separate from the
  # shared codex-typed $SK/SKILL.md.
  #
  # The substring shape checked here changed under #687 (review round 3):
  # the old prose "Only if the project's delivery mode is monitor or both"
  # became a per-mode bullet list (mode: monitor/both starts Monitor; every
  # other mode -- turn, off (no hooks), off (unrecognized) -- leaves it
  # stopped, some of them now with a required user-facing message). The
  # #280 regression this guards -- Monitor invoked unconditionally -- is
  # still what's being checked; only the literal wording moved.
  mkdir -p "$FAKE_HOME/.claude"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local cmd_file="$FAKE_HOME/.claude/commands/agmsg.md"
  [ -f "$cmd_file" ]
  local actas_block drop_block
  actas_block="$(sed -n '/If argument starts with "actas"/,/If argument starts with "drop"/p' "$cmd_file")"
  drop_block="$(sed -n '/If argument starts with "drop"/,/If argument starts with "spawn"/p' "$cmd_file")"
  [[ "$actas_block" == *"mode: monitor"*"mode: both"* ]]
  [[ "$actas_block" == *"delivery.sh status"* ]]
  [[ "$drop_block" == *"mode: monitor"*"mode: both"* ]]
  [[ "$drop_block" == *"delivery.sh status"* ]]
}

@test "install: --update warns to re-register delivery hooks (#133)" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  run env HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg --update
  [ "$status" -eq 0 ]
  # Surface the silent-delivery-loss footgun: an upgrade can drop a project's
  # SessionStart/Stop hook, so the user is told to re-run delivery.sh set.
  [[ "$output" =~ "delivery.sh set" ]]
  [[ "$output" =~ "#133" ]]
}

@test "install: AGMSG_STORAGE_PATH override works against the installed skill" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  bash "$SK/scripts/join.sh" demo alice claude-code /tmp/install-override-projA
  bash "$SK/scripts/join.sh" demo bob   claude-code /tmp/install-override-projB
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
wait_for_pidfile_pid() {
  local file="$1" expected="$2"
  local i actual
  for i in $(seq 1 30); do
    if [ -f "$file" ]; then
      actual="$(cat "$file")"
      [ "$actual" = "$expected" ] && return 0
    fi
    sleep 0.1
  done
  return 1
}

@test "install: drops a Copilot SKILL.md when ~/.copilot exists" {
  mkdir -p "$FAKE_HOME/.copilot"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local copilot_skill="$FAKE_HOME/.copilot/skills/agmsg/SKILL.md"
  [ -f "$copilot_skill" ]
  # The Copilot SKILL.md must drive whoami with type=copilot, not codex,
  # otherwise Copilot sessions get mis-identified.
  grep -q "whoami.sh \"\$(pwd)\" copilot" "$copilot_skill"
  refute grep -q "whoami.sh \"\$(pwd)\" codex" "$copilot_skill"
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
  refute grep -q "^tampered$" "$copilot_skill"
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

@test "install: drops an OpenCode SKILL.md when ~/.config/opencode exists" {
  mkdir -p "$FAKE_HOME/.config/opencode"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local opencode_skill="$FAKE_HOME/.config/opencode/skills/agmsg/SKILL.md"
  [ -f "$opencode_skill" ]
  # The OpenCode SKILL.md must drive whoami with type=opencode, not codex,
  # otherwise OpenCode sessions get mis-identified.
  grep -q "whoami.sh \"\$(pwd)\" opencode" "$opencode_skill"
  refute grep -q "whoami.sh \"\$(pwd)\" codex" "$opencode_skill"
  grep -q "^name: agmsg" "$opencode_skill"
}

@test "install: skips OpenCode skill when ~/.config/opencode is absent" {
  rm -rf "$FAKE_HOME/.config/opencode"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  [ ! -d "$FAKE_HOME/.config/opencode/skills/agmsg" ]
}

@test "install --update: refreshes the OpenCode skill if it was previously installed" {
  mkdir -p "$FAKE_HOME/.config/opencode"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local opencode_skill="$FAKE_HOME/.config/opencode/skills/agmsg/SKILL.md"
  [ -f "$opencode_skill" ]
  echo "tampered" > "$opencode_skill"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  refute grep -q "^tampered$" "$opencode_skill"
  grep -q "whoami.sh \"\$(pwd)\" opencode" "$opencode_skill"
}

@test "install --update: installs OpenCode skill for upgraders without prior skill" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  [ ! -d "$FAKE_HOME/.config/opencode/skills/agmsg" ]
  mkdir -p "$FAKE_HOME/.config/opencode"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  [ -f "$FAKE_HOME/.config/opencode/skills/agmsg/SKILL.md" ]
  grep -q "whoami.sh \"\$(pwd)\" opencode" "$FAKE_HOME/.config/opencode/skills/agmsg/SKILL.md"
}

@test "install: no PowerShell launcher is shipped (dispatcher only)" {
  AGMSG_FORCE_WINDOWS=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd msg

  [ ! -f "$FAKE_HOME/.agents/msg.ps1" ]
  [ ! -f "$FAKE_HOME/.agents/msg-run.sh" ]
  [ ! -f "$FAKE_HOME/.agents/bin/sqlite3" ]
  # The PowerShell port was removed; only the Bash dispatcher ships.
  [ ! -f "$FAKE_HOME/.agents/skills/msg/scripts/windows/agmsg.ps1" ]
  [ ! -f "$FAKE_HOME/.agents/skills/msg/scripts/windows/install-agmsg.ps1" ]
  [ -f "$FAKE_HOME/.agents/skills/msg/scripts/windows/dispatch.sh" ]
}

@test "install --update: removes legacy Windows runner and sqlite shim" {
  AGMSG_FORCE_WINDOWS=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  echo "legacy runner" > "$FAKE_HOME/.agents/agmsg-run.sh"
  mkdir -p "$FAKE_HOME/.agents/bin"
  mkdir -p "$FAKE_HOME/.agents/run"
  cat > "$FAKE_HOME/.agents/bin/sqlite3" <<'SHIM'
#!/usr/bin/env bash
# sqlite3 compatibility shim for agmsg on native Windows / Git Bash.
exit 1
SHIM
  chmod +x "$FAKE_HOME/.agents/bin/sqlite3"
  echo "/usr/bin/sqlite3" > "$FAKE_HOME/.agents/run/sqlite3-shim.cache"
  cat > "$FAKE_HOME/.agents/agmsg.ps1" <<'PS1'
# PowerShell shortcut for agmsg on native Windows.
function agmsg {
    & 'C:\Users\example\.agents\skills\agmsg\scripts\windows\agmsg.ps1' @args
}
PS1

  AGMSG_FORCE_WINDOWS=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update

  [ ! -f "$FAKE_HOME/.agents/agmsg.ps1" ]
  [ ! -f "$FAKE_HOME/.agents/agmsg-run.sh" ]
  [ ! -f "$FAKE_HOME/.agents/bin/sqlite3" ]
  [ ! -f "$FAKE_HOME/.agents/run/sqlite3-shim.cache" ]
}

@test "install: Windows dispatcher is shipped with the skill scripts" {
  AGMSG_FORCE_WINDOWS=1 HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg

  [ ! -f "$SK/scripts/windows/agmsg.ps1" ]
  [ ! -f "$SK/scripts/windows/install-agmsg.ps1" ]
  [ -f "$SK/scripts/windows/dispatch.sh" ]
  [ ! -f "$SK/scripts/windows/agmsg-run.sh" ]
  [ ! -f "$SK/scripts/windows/sqlite3-shim.sh" ]
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

  bash "$SK/scripts/watch.sh" "$sid" /tmp/install-projA claude-code 3>&- &
  local first=$!
  wait_for_pidfile_pid "$SK/run/watch.$sid.pid" "$first"

  bash "$SK/scripts/watch.sh" "$sid" /tmp/install-projA claude-code 3>&- &
  local second=$!
  wait_for_pidfile_pid "$SK/run/watch.$sid.pid" "$second"
  # The pidfile can flip to $second a beat before $first's TERM trap has
  # actually run — poll for its exit rather than checking the instant the
  # pidfile changes (a single check raced this and flaked, see #124; same
  # fix already applied to the equivalent check in test_watch.bats).
  local i
  for i in $(seq 1 30); do kill -0 "$first" 2>/dev/null || break; sleep 0.1; done
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
  refute grep -q 'rm -rf' "$stdout_capture"
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

@test "install: recorded VERSION uses the core tag lineage, not a co-located app-v* tag" {
  # agmsg-core and the desktop app share one repo/tag namespace (v1.2.3 core
  # releases alongside app-v0.2.0 app releases). Unrestricted `git describe
  # --tags` matches whichever lineage is closer in history -- when an app-v*
  # tag landed after the last core v* tag, installs recorded provenance like
  # "app-v0.2.0-26-gHASH" instead of "v1.1.8-27-gHASH", which the desktop
  # app's own version comparison can't parse as semver and treats as
  # unconditionally outdated. Observed on a real install, not hypothetical.
  # Resolve to the PHYSICAL path: on macOS $BATS_TEST_TMPDIR lands under
  # /var/folders/... which is itself a symlink to /private/var/folders/....
  # install.sh's SCRIPT_DIR uses plain `pwd` (logical, follows the symlink
  # form actually cd'd into), while `git rev-parse --show-toplevel` always
  # returns the physical path -- agmsg_source_version()'s toplevel-equality
  # check would then never match on a logical-path synth dir, skipping
  # `git describe` entirely regardless of tags. Unrelated pre-existing
  # quirk, not something this fix touches -- work around it in the fixture.
  local synth
  mkdir -p "$BATS_TEST_TMPDIR/synth-agmsg"
  synth="$(cd "$BATS_TEST_TMPDIR/synth-agmsg" && pwd -P)"
  cp -R "$REPO_ROOT/." "$synth/"
  rm -rf "$synth/.git"
  git -C "$synth" init -q
  git -C "$synth" -c user.email=t@e -c user.name=t add -A
  git -C "$synth" -c user.email=t@e -c user.name=t commit -q -m "core release"
  git -C "$synth" tag v1.0.0
  git -C "$synth" -c user.email=t@e -c user.name=t commit -q --allow-empty -m "app release"
  git -C "$synth" tag app-v9.9.9
  git -C "$synth" -c user.email=t@e -c user.name=t commit -q --allow-empty -m "one more commit"

  HOME="$FAKE_HOME" bash "$synth/install.sh" --cmd agmsg
  run cat "$SK/VERSION"
  [[ "$output" =~ ^v1\.0\.0- ]]
  [[ "$output" != app-v9.9.9* ]]
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

# --- Codex sandbox writable_roots (#41) ---
@test "install: configures Codex writable_roots for db teams and run" {
  mkdir -p "$FAKE_HOME/.codex"
  cat > "$FAKE_HOME/.codex/config.toml" <<'EOF'
model = "gpt-test"
EOF

  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg

  grep -q "$SK/db" "$FAKE_HOME/.codex/config.toml"
  grep -q "$SK/teams" "$FAKE_HOME/.codex/config.toml"
  grep -q "$SK/run" "$FAKE_HOME/.codex/config.toml"
}

@test "install --update: adds missing Codex run writable_root for existing installs" {
  mkdir -p "$FAKE_HOME/.codex"
  cat > "$FAKE_HOME/.codex/config.toml" <<'EOF'
[sandbox_workspace_write]
writable_roots = []
EOF

  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  # Simulate an older install that had db/ and teams/ but not run/.
  cat > "$FAKE_HOME/.codex/config.toml" <<EOF
[sandbox_workspace_write]
writable_roots = ["$SK/db", "$SK/teams"]
EOF

  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update

  grep -q "$SK/run" "$FAKE_HOME/.codex/config.toml"
}

@test "install: fills an existing EMPTY Codex writable_roots without corrupting TOML" {
  mkdir -p "$FAKE_HOME/.codex"
  cat > "$FAKE_HOME/.codex/config.toml" <<'EOF'
[sandbox_workspace_write]
writable_roots = []
EOF

  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg

  # The empty-array path used to emit `[, "..."]` — a leading comma, which is
  # invalid TOML and broke the user's Codex config.
  refute grep -Eq '\[[[:space:]]*,' "$FAKE_HOME/.codex/config.toml"
  grep -q "$SK/db" "$FAKE_HOME/.codex/config.toml"
  grep -q "$SK/teams" "$FAKE_HOME/.codex/config.toml"
  grep -q "$SK/run" "$FAKE_HOME/.codex/config.toml"

  # Parse end-to-end when a TOML reader is available, to prove validity.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$FAKE_HOME/.codex/config.toml" <<'PY'
import sys
try:
    import tomllib
except ImportError:
    sys.exit(0)
with open(sys.argv[1], "rb") as f:
    tomllib.load(f)
PY
  fi
}


# --- hermes Agent skill (~/.hermes/skills/<name>/SKILL.md) ---

@test "install: drops a Hermes skill when ~/.hermes exists" {
  mkdir -p "$FAKE_HOME/.hermes"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local hermes_skill="$FAKE_HOME/.hermes/skills/agmsg/SKILL.md"
  [ -f "$hermes_skill" ]
  grep -q "whoami.sh \"\$(pwd)\" hermes" "$hermes_skill"
  grep -q "^name: agmsg" "$hermes_skill"
  grep -q "~/.agents/skills/agmsg/scripts" "$hermes_skill"
}

@test "install: Hermes skill no longer advertises 'spawn hermes' as a valid example (#279)" {
  mkdir -p "$FAKE_HOME/.hermes"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local hermes_skill="$FAKE_HOME/.hermes/skills/agmsg/SKILL.md"
  [ -f "$hermes_skill" ]
  refute grep -q "spawn hermes reviewer" "$hermes_skill"
  refute grep -q 'must be `claude-code`, `codex`, or `hermes`' "$hermes_skill"
  grep -q "hermes.*is not spawnable\|hermes.*not spawnable" "$hermes_skill"
}

@test "install: custom command name is substituted in Hermes skill" {
  mkdir -p "$FAKE_HOME/.hermes"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd msg
  local hermes_skill="$FAKE_HOME/.hermes/skills/msg/SKILL.md"
  [ -f "$hermes_skill" ]
  grep -q "^name: msg" "$hermes_skill"
  grep -q "~/.agents/skills/msg/scripts" "$hermes_skill"
  grep -q "You can now use \`/msg\`" "$hermes_skill"
  ! grep -q "__SKILL_NAME__" "$hermes_skill"
}

@test "install: --agent-type hermes makes shared SKILL.md Hermes-typed" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg --agent-type hermes
  grep -q "whoami.sh \"\$(pwd)\" hermes" "$SK/SKILL.md"
  refute grep -q "whoami.sh \"\$(pwd)\" codex" "$SK/SKILL.md"
  refute grep -q "whoami.sh \"\$(pwd)\" gemini" "$SK/SKILL.md"
  ! grep -q "whoami.sh \"\$(pwd)\" antigravity" "$SK/SKILL.md"
}

@test "install: --agent-type cursor makes shared SKILL.md Cursor-typed (#131)" {
  # Regression guard: the TPL_TYPE case must list cursor, or --agent-type cursor
  # silently falls through to the codex template and the install ships a
  # codex-typed SKILL.md (delivery/join then run as codex, not cursor).
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg --agent-type cursor
  grep -q "whoami.sh \"\$(pwd)\" cursor" "$SK/SKILL.md"
  ! grep -q "whoami.sh \"\$(pwd)\" codex" "$SK/SKILL.md"
}

@test "install --update: refreshes the Hermes skill if it was previously installed" {
  mkdir -p "$FAKE_HOME/.hermes"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local hermes_skill="$FAKE_HOME/.hermes/skills/agmsg/SKILL.md"
  [ -f "$hermes_skill" ]
  echo "tampered" > "$hermes_skill"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  refute grep -q "^tampered$" "$hermes_skill"
  grep -q "whoami.sh \"\$(pwd)\" hermes" "$hermes_skill"
}

@test "install --update: installs Hermes skill for upgraders without prior skill" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  [ ! -d "$FAKE_HOME/.hermes/skills/agmsg" ]
  mkdir -p "$FAKE_HOME/.hermes"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  [ -f "$FAKE_HOME/.hermes/skills/agmsg/SKILL.md" ]
  grep -q "whoami.sh \"\$(pwd)\" hermes" "$FAKE_HOME/.hermes/skills/agmsg/SKILL.md"
}

@test "install: --update re-points an existing Codex monitor shim to the new path" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  # Install the shim the way enabling Codex monitor mode would.
  HOME="$FAKE_HOME" bash "$SK/scripts/drivers/types/codex/codex-shim-install.sh" install >/dev/null
  local shim="$FAKE_HOME/.agents/bin/codex"
  [ -f "$shim" ]
  grep -q '/scripts/drivers/types/codex/codex-shim.sh' "$shim"

  # Simulate a shim baked by a pre-1.1.0 layout (stale exec path), keeping the
  # agmsg marker so it is still recognized as ours.
  local tmp; tmp="$(mktemp)"
  sed 's#/scripts/drivers/types/codex/#/scripts/codex/#g' "$shim" > "$tmp"
  mv "$tmp" "$shim"
  grep -q '/scripts/codex/codex-shim.sh' "$shim"
  refute grep -q '/scripts/drivers/types/codex/codex-shim.sh' "$shim"

  # --update must regenerate it back to the post-move path.
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  grep -q '/scripts/drivers/types/codex/codex-shim.sh' "$shim"
  ! grep -q '/scripts/codex/codex-shim.sh' "$shim"
}

@test "install: --update does NOT create a Codex shim when none was installed" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  [ ! -e "$FAKE_HOME/.agents/bin/codex" ]
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  # The refresh is gated on an existing agmsg shim — it must not opt the user in.
  [ ! -e "$FAKE_HOME/.agents/bin/codex" ]
}

# #553: a second install under a different --cmd name used to silently
# rewrite ~/.agents/bin/codex to point at itself, so every Codex launch on the
# machine (through the shim) started dispatching into the second install's
# drivers/storage instead of the production one -- with no warning, printed
# as if it were a routine "refreshed" no-op.

@test "install: a second, differently-named install does NOT clobber the first's Codex shim (#553)" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg --agent-type codex
  HOME="$FAKE_HOME" bash "$SK/scripts/drivers/types/codex/codex-shim-install.sh" install >/dev/null
  local shim="$FAKE_HOME/.agents/bin/codex"
  [ -f "$shim" ]
  # Positive control: pin exactly which install owns it before touching
  # anything else, byte for byte -- if this does not already say "agmsg",
  # the rest of the test proves nothing.
  local before; before="$(grep AGMSG_CODEX_SHIM_SCRIPT_DIR "$shim")"
  printf '%s' "$before" | grep -qF "/skills/agmsg/"

  local sk2="$FAKE_HOME/.agents/skills/agmsg-dfr"
  run env HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg-dfr --agent-type codex
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "owned by a different install"

  # The shim's bytes must be completely unchanged, not just "still valid" --
  # comparing the whole recorded line rather than only the owning dir catches
  # a partial/malformed rewrite too.
  local after; after="$(grep AGMSG_CODEX_SHIM_SCRIPT_DIR "$shim")"
  [ "$before" = "$after" ]
  [ -d "$sk2" ]  # the second install itself still succeeded
}

@test "install: --update --cmd can reclaim a Codex shim owned by a different install (#553)" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg --agent-type codex
  HOME="$FAKE_HOME" bash "$SK/scripts/drivers/types/codex/codex-shim-install.sh" install >/dev/null
  local shim="$FAKE_HOME/.agents/bin/codex"

  local sk2="$FAKE_HOME/.agents/skills/agmsg-dfr"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg-dfr --agent-type codex >/dev/null
  grep -q "/skills/agmsg/" "$shim"  # still the first install's, per the test above

  # --update --cmd names a specific, already-registered install explicitly --
  # that explicit targeting is the documented recovery path, so it is allowed
  # to reclaim the shim rather than being blocked like the fresh install above.
  run env HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg-dfr --update
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "refreshed Codex monitor shim"
  grep -q "/skills/agmsg-dfr/" "$shim"
}

@test "install: bare --update (no --cmd) does NOT force-steal a Codex shim owned by a different install (#553)" {
  # Unlike --update --cmd <name>, a bare --update resolves its target by
  # scanning for an existing install rather than the caller naming one --- and
  # on this base (#599's fail-closed fix, PR #659, is not yet merged here),
  # that resolution does not even fail closed when more than one install is
  # present. Forcing the shim reclaim unconditionally for bare --update would
  # let whichever install a glob happens to land on steal the shim from
  # another one the caller never named at all (review finding). This pins
  # that a shim already owned by a DIFFERENT install survives a bare --update
  # of the install that does NOT own it.
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg --agent-type codex
  HOME="$FAKE_HOME" bash "$SK/scripts/drivers/types/codex/codex-shim-install.sh" install >/dev/null
  local shim="$FAKE_HOME/.agents/bin/codex"
  local before; before="$(grep AGMSG_CODEX_SHIM_SCRIPT_DIR "$shim")"
  printf '%s' "$before" | grep -qF "/skills/agmsg/"

  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg-dfr --agent-type codex >/dev/null
  grep -q "/skills/agmsg/" "$shim"  # still the first install's, per the earlier tests

  # Bare --update, no --cmd: this base's ambiguous-candidate handling means
  # which of the two real installs it lands on isn't the point of this test
  # (that's #599 / #659's concern) -- what matters here is that whichever one
  # it is, it must not walk away with a shim it was never explicitly told to
  # claim.
  run env HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  [ "$status" -eq 0 ]
  local after; after="$(grep AGMSG_CODEX_SHIM_SCRIPT_DIR "$shim")"
  [ "$before" = "$after" ]
}

@test "install: bare --update migrates this machine's own pre-#553 (owner-unknown) Codex shim (#553)" {
  # The two fixes above -- fail closed on an owner-unknown shim, and bare
  # --update no longer forcing -- are each correct alone but combined to
  # block the single-install upgrade they were never meant to touch: nearly
  # every real machine's shim predates ownership tracking, has no owner
  # comment, and a routine `install.sh --update` with no --cmd (the normal
  # way a single-install user upgrades) must still be able to refresh it
  # (review finding). Provably only one agmsg install existing at all is what
  # makes that safe without needing --cmd or --force: there is no other
  # install the shim could actually belong to.
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg --agent-type codex
  local shim="$FAKE_HOME/.agents/bin/codex"
  mkdir -p "$FAKE_HOME/.agents/bin"
  # A legacy shim: real marker, but written before this PR added the owner
  # comment -- exactly what every pre-existing production shim looks like.
  cat > "$shim" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Optional Codex entrypoint shim for agmsg monitor mode.
# Generated by agmsg. Dispatches to the installed skill script.
export AGMSG_CODEX_SHIM_WRAPPER=1
export AGMSG_CODEX_SHIM_SCRIPT_DIR=/some/stale/pre-move/path
exec /some/stale/pre-move/path/codex-shim.sh "$@"
EOF
  chmod +x "$shim"
  refute grep -q "agmsg-shim-owner" "$shim"

  run env HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "refreshed Codex monitor shim"
  grep -q "agmsg-shim-owner" "$shim"
  grep -q "/skills/agmsg/scripts/drivers/types/codex" "$shim"
  refute grep -q "/some/stale/pre-move/path" "$shim"
}

@test "install: a second, differently-named FRESH install does NOT silently claim a pre-existing legacy shim (#553 review)" {
  # Review finding: install.sh checks/refreshes the Codex shim (~line 436)
  # BEFORE it touches this install's own .agmsg marker (~line 452). So when a
  # second, differently-named install's fresh `install.sh --cmd` run reaches
  # the shim step, agmsg_only_one_install sees only the FIRST install's
  # marker on disk -- its own marker does not exist yet -- and (wrongly)
  # concludes only one install exists anywhere, which is exactly the
  # condition meant to let ONLY a genuinely sole install claim an
  # owner-unknown legacy shim without --force. This pins that a second,
  # differently-named install must not benefit from that allowance just
  # because its own marker hasn't been written yet.
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg --agent-type codex
  local shim="$FAKE_HOME/.agents/bin/codex"
  mkdir -p "$FAKE_HOME/.agents/bin"
  # A legacy shim: real marker, but no owner comment -- same shape as any
  # shim written before this PR, and the same fixture the bare-`--update`
  # migration test above uses.
  cat > "$shim" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Optional Codex entrypoint shim for agmsg monitor mode.
# Generated by agmsg. Dispatches to the installed skill script.
export AGMSG_CODEX_SHIM_WRAPPER=1
export AGMSG_CODEX_SHIM_SCRIPT_DIR=/some/stale/pre-move/path
exec /some/stale/pre-move/path/codex-shim.sh "$@"
EOF
  chmod +x "$shim"
  local before; before="$(cat "$shim")"

  # A second, DIFFERENT, freshly-created install -- not --update, so this
  # install's own .agmsg marker genuinely does not exist until after the
  # shim step runs.
  run env HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg-dfr --agent-type codex
  [ "$status" -eq 0 ]

  [ "$(cat "$shim")" = "$before" ]  # byte-for-byte unchanged, not silently claimed
}

# --- grok-build skill (~/.grok/skills/<name>/SKILL.md) ---

@test "install: drops a Grok Build SKILL.md when ~/.grok exists" {
  mkdir -p "$FAKE_HOME/.grok"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local grok_skill="$FAKE_HOME/.grok/skills/agmsg/SKILL.md"
  [ -f "$grok_skill" ]
  grep -q "whoami.sh \"\$(pwd)\" grok-build" "$grok_skill"
  refute grep -q "whoami.sh \"\$(pwd)\" codex" "$grok_skill"
  grep -q "^name: agmsg" "$grok_skill"
}

@test "install: skips Grok Build skill when ~/.grok is absent" {
  rm -rf "$FAKE_HOME/.grok"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  [ ! -d "$FAKE_HOME/.grok" ]
}

@test "install --update: installs Grok Build skill for upgraders without prior skill" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  [ ! -d "$FAKE_HOME/.grok/skills/agmsg" ]
  mkdir -p "$FAKE_HOME/.grok"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  [ -f "$FAKE_HOME/.grok/skills/agmsg/SKILL.md" ]
  grep -q "whoami.sh \"\$(pwd)\" grok-build" "$FAKE_HOME/.grok/skills/agmsg/SKILL.md"
}

@test "install: --agent-type grok-build makes shared SKILL.md Grok-typed" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg --agent-type grok-build
  grep -q "whoami.sh \"\$(pwd)\" grok-build" "$SK/SKILL.md"
  ! grep -q "whoami.sh \"\$(pwd)\" codex" "$SK/SKILL.md"
}

# The Windows leg of the bats matrix selects by test NAME (filter "[Ww]indows"),
# and until this test existed it ran only the two install-helper checks above --
# so join.sh, which is the first thing any Windows user runs, executed in no
# Windows job at all. #669 is exactly what that hole let through: on Git Bash
# join.sh printed "Created team: <team>" and then exited 1 in silence, because
# the roster journal handed sqlite an MSYS path readfile() could not open.
#
# Asserting the exit status alone would not have caught the earlier shape of
# this bug, where the team directory appears and the membership does not. So
# this asserts the membership is actually there afterwards.
@test "install: on Windows too, join.sh writes the membership it just announced" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg

  run bash "$SK/scripts/join.sh" wteam alice claude-code /tmp/install-wteam
  [ "$status" -eq 0 ]

  run bash "$SK/scripts/team.sh" wteam
  [ "$status" -eq 0 ]
  [[ "$output" == *alice* ]]
}
