#!/usr/bin/env bats

BIN="$BATS_TEST_DIRNAME/../bin/agmsg.js"

@test "bin/agmsg.js: --version exits successfully" {
  run node "$BIN" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agmsg bootstrapper" ]]
}

@test "bin/agmsg.js: --help exits successfully" {
  run node "$BIN" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "npm bootstrapper for cross-agent messaging" ]]
}

# `agmsg <verb>` is the wrong guess the docs taught — a sweep of docs/design
# and docs/spec found 34 backticked commands assuming a CLI that does not
# exist. Fixing the documents does not help the person who types from memory,
# so the refusal has to name the real form.
#
# Asserted on the PATH being present, not on the wording: the value of this
# message is that it tells you what to type instead, and a test that only
# checked for "not a command" would pass on the old text.
@test "bin/agmsg.js: an unknown verb names the script to run instead" {
  run node "$BIN" send hello
  [ "$status" -eq 2 ]
  [[ "$output" =~ "is not a command" ]]
  [[ "$output" =~ "scripts/send.sh" ]]
}

# A verb with no mapping still has to answer "then what do I type", because
# the mapping is a hint that is allowed to be incomplete. `storage` is one the
# docs use and no script implements.
@test "bin/agmsg.js: an unmapped verb still points at the install" {
  run node "$BIN" storage list
  [ "$status" -eq 2 ]
  [[ "$output" =~ "is not a command" ]]
  [[ "$output" =~ "scripts/" ]]
}

# EVERY entry in the map, not the one verb a hand-written test happened to
# pick (review P1). The map is allowed to be incomplete — a new verb
# missing from it costs nothing — but an entry that is PRESENT and stale makes
# the message name a path that does not exist, which is worse than the general
# advice it replaced. Completeness is not pinned; correctness of what is
# listed is.
@test "bin/agmsg.js: every mapped verb names a script that exists" {
  run node -e '
    const { SCRIPT_FOR_VERB } = require(process.argv[1]);
    const fs = require("fs"), path = require("path");
    const dir = path.join(path.dirname(process.argv[1]), "..", "scripts");
    const missing = Object.entries(SCRIPT_FOR_VERB)
      .filter(([, s]) => !fs.existsSync(path.join(dir, s)))
      .map(([v, s]) => v + " -> " + s);
    if (missing.length) { console.error(missing.join("\n")); process.exit(1); }
    console.log("checked " + Object.keys(SCRIPT_FOR_VERB).length);
  ' "$BIN"
  [ "$status" -eq 0 ]
  # Non-empty, not an exact count (review): pinning the number would mean adding
  # a legitimate verb to the map fails this test, which makes the map harder
  # to extend for no safety gained. What must not pass is a map emptied to {}
  # reporting "nothing missing".
  [[ "$output" =~ checked\ [1-9] ]]
}

# The person this package exists for has NOT installed yet, and they reach
# this same branch (review P1). Telling them to `bash <install path>` is
# telling them to run a command that fails. HOME is redirected to an empty
# directory; nothing here touches the network.
@test "bin/agmsg.js: with nothing installed, it says to install first" {
  local fresh="$BATS_TEST_TMPDIR/fresh-home"
  mkdir -p "$fresh"
  run env HOME="$fresh" node "$BIN" send hello
  [ "$status" -eq 2 ]
  [[ "$output" =~ "does not look installed" ]]
  [[ "$output" =~ "npx agmsg install" ]]
  # Still names the eventual command, so the person knows where they are going.
  [[ "$output" =~ "scripts/send.sh" ]]
}

@test "bin/agmsg.js: with the script present, it names it and says nothing about installing" {
  local home="$BATS_TEST_TMPDIR/has-install"
  mkdir -p "$home/.agents/skills/agmsg/scripts"
  # The FILE, not just the directory. An earlier version of this test created
  # an empty scripts/ and accepted advice pointing at a send.sh that was not
  # there — the same defect as the map pin, one layer out (review P1).
  touch "$home/.agents/skills/agmsg/scripts/send.sh"
  run env HOME="$home" node "$BIN" send hello
  [ "$status" -eq 2 ]
  [[ ! "$output" =~ "does not look installed" ]]
  [[ ! "$output" =~ "does not contain that command" ]]
  [[ "$output" =~ "scripts/send.sh" ]]
}

# An install that exists but lacks the command — an old version, or a partial
# update. The repo-side pin cannot see this: it proves the map matches THIS
# repo, not the tree on someone's disk. Distinct from "never installed"
# because the recovery is update, not install.
@test "bin/agmsg.js: an install without that script says update, not install" {
  local home="$BATS_TEST_TMPDIR/stale-install"
  mkdir -p "$home/.agents/skills/agmsg/scripts"
  touch "$home/.agents/skills/agmsg/scripts/history.sh"   # some other command
  run env HOME="$home" node "$BIN" send hello
  [ "$status" -eq 2 ]
  [[ "$output" =~ "does not contain that command" ]]
  [[ ! "$output" =~ "does not look installed" ]]
  [[ "$output" =~ "npx agmsg install" ]]
}

# An unmapped verb names the DIRECTORY, so the directory is all that is
# checked — the contract matches what is printed.
@test "bin/agmsg.js: an unmapped verb is satisfied by the directory alone" {
  local home="$BATS_TEST_TMPDIR/dir-only"
  mkdir -p "$home/.agents/skills/agmsg/scripts"
  run env HOME="$home" node "$BIN" storage list
  [ "$status" -eq 2 ]
  [[ ! "$output" =~ "does not look installed" ]]
  [[ "$output" =~ "ls " ]]
}

@test "bin/agmsg.js: toBashPath converts backslashes to forward slashes (#262)" {
  run node -e 'const { toBashPath } = require(process.argv[1]); const input = String.raw`C:\Users\me\AppData\Local\Temp\agmsg-bootstrap-abc123\setup.sh`; const expected = "C:/Users/me/AppData/Local/Temp/agmsg-bootstrap-abc123/setup.sh"; if (toBashPath(input) !== expected) process.exit(1);' "$BIN"
  [ "$status" -eq 0 ]
}

@test "bin/agmsg.js: toBashPath is a no-op on POSIX paths" {
  run node -e 'const { toBashPath } = require(process.argv[1]); const p = "/tmp/agmsg-bootstrap-abc123/setup.sh"; if (toBashPath(p) !== p) process.exit(1);' "$BIN"
  [ "$status" -eq 0 ]
}
