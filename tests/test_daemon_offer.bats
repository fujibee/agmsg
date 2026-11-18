#!/usr/bin/env bats
# `agmsg daemon offer <type>`: the read-only answer the delivery choice screen
# uses to decide whether to offer agmsgd. Isolated scripts and data; no real
# service is touched and nothing is enabled.

setup() {
  export TEST_SKILL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/daemon-offer.XXXXXX")"
  TEST_SKILL_DIR="$(cd "$TEST_SKILL_DIR" && pwd -P)"
  cp -R "$BATS_TEST_DIRNAME/../scripts" "$TEST_SKILL_DIR/scripts"
  export SCRIPTS="$TEST_SKILL_DIR/scripts"
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/db" "$TEST_SKILL_DIR/bin"
  export AGMSG_CONFIG="$TEST_SKILL_DIR/config.json"
  export AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/db"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" < "$SCRIPTS/daemon/schema.sql"
}

_mark_daemon_ready() {
  local boot
  case "$(uname -s)" in
    Darwin) boot="$(sysctl -n kern.bootsessionuuid)" ;;
    Linux) boot="$(tr -d "[:space:]" < /proc/sys/kernel/random/boot_id 2>/dev/null || sed -n "s/^btime //p" /proc/stat)" ;;
    *) skip 'POSIX beta executor evidence' ;;
  esac
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE meta SET node_path='$(command -v node)'; UPDATE daemon_intent SET desired='on';
    UPDATE daemon_owner SET state='ready', executor_pid=$$, executor_boot_id='$boot', executor_started_at=strftime('%Y-%m-%dT%H:%M:%fZ','now');"
}

teardown() { rm -rf "$TEST_SKILL_DIR"; }

@test "offer: a fresh install can enable agmsgd" {
  run bash "$SCRIPTS/daemon.sh" offer claude-code
  [ "$status" -eq 0 ]
  [ "$output" = "agmsgd=available" ]
  run bash "$SCRIPTS/daemon.sh" offer codex
  [ "$output" = "agmsgd=available" ]
}

@test "offer: it only reads; the intent stays off" {
  bash "$SCRIPTS/daemon.sh" offer claude-code >/dev/null
  [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" 'SELECT desired FROM daemon_intent;')" != on ]
}

@test "offer: agmsgd that is on and running is reported as on, not offered again" {
  _mark_daemon_ready
  run bash "$SCRIPTS/daemon.sh" offer claude-code
  [ "$output" = "agmsgd=on" ]
}

@test "offer: turned on but nothing running is not reported as on (a failed start leaves exactly this)" {
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_intent SET desired='on';"
  run bash "$SCRIPTS/daemon.sh" offer claude-code
  [ "$status" -eq 0 ]
  [ "$output" != "agmsgd=on" ]
  [[ "$output" == "agmsgd=not-running reason="* ]]
}

@test "offer: a non-sqlite storage is unavailable, with the reason" {
  printf '{"storage":"jsonl"}\n' > "$AGMSG_CONFIG"
  run bash "$SCRIPTS/daemon.sh" offer claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == "agmsgd=unavailable reason="*sqlite* ]]
}

@test "offer: no usable Node is unavailable, with the reason" {
  printf '#!/bin/sh\nexit 1\n' > "$TEST_SKILL_DIR/bin/node"
  chmod +x "$TEST_SKILL_DIR/bin/node"
  run env PATH="$TEST_SKILL_DIR/bin:/usr/bin:/bin" bash "$SCRIPTS/daemon.sh" offer claude-code
  [[ "$output" == "agmsgd=unavailable reason="*Node* ]]
}

@test "offer: Linux without systemd user services is unavailable, with the reason" {
  printf '#!/bin/sh\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\necho Linux\n' > "$TEST_SKILL_DIR/bin/uname"
  printf '#!/bin/sh\nexit 1\n' > "$TEST_SKILL_DIR/bin/systemctl"
  chmod +x "$TEST_SKILL_DIR/bin/uname" "$TEST_SKILL_DIR/bin/systemctl"
  run env PATH="$TEST_SKILL_DIR/bin:$PATH" AGMSGD_SYSTEMCTL="$TEST_SKILL_DIR/bin/systemctl" bash "$SCRIPTS/daemon.sh" offer claude-code
  [[ "$output" == "agmsgd=unavailable reason="*systemd* ]]
}

@test "offer: a type agmsgd does not deliver to is not offered" {
  run bash "$SCRIPTS/daemon.sh" offer gemini
  [[ "$output" == "agmsgd=unavailable reason="* ]]
}

# review on #1979-followup: the above gate used to reject every type except
# claude-code/codex outright, even grok-build (which has its own native
# channel, grok-queue) and any type terminal-poke already delivers to
# (antigravity, via its own input_prompt_marker). Offer now mirrors the
# same two criteria terminal-poke-store.mjs/terminal-poke-types.mjs use to
# build their own roster.

@test "offer: grok-build is offered -- it has its own native channel (grok-queue)" {
  run bash "$SCRIPTS/daemon.sh" offer grok-build
  [ "$output" = "agmsgd=available" ]
}

@test "offer: a type with a verified input box (antigravity) is offered via terminal-poke" {
  run bash "$SCRIPTS/daemon.sh" offer antigravity
  [ "$output" = "agmsgd=available" ]
}

@test "offer: a type with no verified input box yet is not offered, and says so" {
  run bash "$SCRIPTS/daemon.sh" offer gemini
  [[ "$output" == "agmsgd=unavailable reason="*"no verified input box"* ]]
}

@test "offer: a type whose own type.conf turns poke delivery off is not offered, and says so" {
  mkdir -p "$SCRIPTS/drivers/types/fake-poke-off"
  cat > "$SCRIPTS/drivers/types/fake-poke-off/type.conf" <<'EOF'
name=fake-poke-off
input_prompt_marker=>
poke_delivery=no
EOF
  run bash "$SCRIPTS/daemon.sh" offer fake-poke-off
  [[ "$output" == "agmsgd=unavailable reason="*"turned off poke delivery"* ]]
}

@test "offer: no usable Node also disables a terminal-poke-eligible type's offer" {
  printf '#!/bin/sh\nexit 1\n' > "$TEST_SKILL_DIR/bin/node"
  chmod +x "$TEST_SKILL_DIR/bin/node"
  run env PATH="$TEST_SKILL_DIR/bin:/usr/bin:/bin" bash "$SCRIPTS/daemon.sh" offer antigravity
  [[ "$output" == "agmsgd=unavailable reason="*Node* ]]
}

# review on #1989, finding (1): a hand-built 'file://'+native-path URL
# breaks for any install path containing a URL-special character, and the
# import failure this caused was folded into the generic "agmsgd does not
# deliver to <type> sessions" -- a supported type's offer silently
# regressed to unavailable with a misleading reason.

@test "offer: a terminal-poke-eligible type is still offered when the install path needs URL-encoding" {
  local hashed_dir="$TEST_SKILL_DIR/has#hash dir"
  mkdir -p "$hashed_dir/run"
  cp -R "$SCRIPTS" "$hashed_dir/scripts"
  sqlite3 "$hashed_dir/run/install.db" < "$SCRIPTS/daemon/schema.sql"
  run env AGMSG_STORAGE_PATH="$AGMSG_STORAGE_PATH" bash "$hashed_dir/scripts/daemon.sh" offer antigravity
  [ "$output" = "agmsgd=available" ]
}

@test "offer: a broken terminal-poke-types.mjs reports its own import error, not the generic unsupported-type reason" {
  printf 'this is not valid javascript {{{\n' > "$SCRIPTS/daemon/channels/terminal-poke-types.mjs"
  run bash "$SCRIPTS/daemon.sh" offer antigravity
  [[ "$output" == "agmsgd=unavailable reason="* && "$output" != *"does not deliver to antigravity sessions"* ]]
}

# review on #1989, round 2: SCRIPT_DIR/SKILL_DIR under Git Bash are MSYS
# paths (/c/Users/...), which win32 Node's own pathToFileURL/readFileSync
# read as drive-relative rather than as the real path -- both the module
# path and installRoot need converting to a real Windows path before
# being handed to node, the same way the codex/Windows branch already
# does it (cygpath -w preferred; cd+pwd -W when cygpath is absent, not
# exercised here since bash's own pwd builtin cannot be stubbed via PATH).
@test "offer: on Windows (Git Bash), both the module path and installRoot are converted via cygpath -w before reaching node" {
  printf '#!/bin/sh\n[ "$1" = "-s" ] && { echo "MINGW64_NT-10.0"; exit 0; }\necho "MINGW64_NT-10.0"\n' > "$TEST_SKILL_DIR/bin/uname"
  printf '#!/bin/sh\n[ "$1" = "-w" ] && printf "WINCONV:%%s\\n" "$2"\n' > "$TEST_SKILL_DIR/bin/cygpath"
  chmod +x "$TEST_SKILL_DIR/bin/uname" "$TEST_SKILL_DIR/bin/cygpath"
  local real_node; real_node="$(command -v node)"
  cat > "$TEST_SKILL_DIR/bin/node" <<EOF_NODE_STUB
#!/bin/sh
if [ "\$1" = "--input-type=module" ]; then
  echo "\$@" > "$TEST_SKILL_DIR/node-argv-capture.txt"
fi
exec "$real_node" "\$@"
EOF_NODE_STUB
  chmod +x "$TEST_SKILL_DIR/bin/node"
  run env PATH="$TEST_SKILL_DIR/bin:$PATH" AGMSG_NODE="$TEST_SKILL_DIR/bin/node" bash "$SCRIPTS/daemon.sh" offer antigravity
  grep -q 'WINCONV:.*daemon/channels' "$TEST_SKILL_DIR/node-argv-capture.txt"
  [ "$(grep -o 'WINCONV:' "$TEST_SKILL_DIR/node-argv-capture.txt" | wc -l)" -eq 2 ]
}
