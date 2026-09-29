#!/usr/bin/env bash
# agmsgd's launcher (T3 "入口の組み立て"). What the resident manager
# (launchd / systemd --user / Task Scheduler) actually starts.
#
# FIXED BOOTSTRAP, on purpose: this file's own bytes are checked against
# the completion record the same way scripts/daemon/agmsgd's are (T3's
# "入口の一貫性"), so it must never drift version to version except by an
# explicit bootstrap-version bump recorded there. It therefore does NOT
# source scripts/lib/*.sh (those can and do change release to release) --
# only external tools (sqlite3) and bash builtins.
#
# install.sh extracts this exact line (`^BOOTSTRAP_VERSION=`, PR 2,
# 2026-09-29) and cross-checks it against scripts/daemon/agmsgd's
# own `const BOOTSTRAP_VERSION = ` line before writing either into the
# completion record's bootstrap_version field. The line's shape must not
# change without install.sh's own extraction changing with it.
set -euo pipefail

BOOTSTRAP_VERSION=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_DB="$SKILL_DIR/run/install.db"
MANIFEST="$SKILL_DIR/run/install-manifest.json"
LOCK_DB="$SKILL_DIR/run/install-op.lock.db"

# Records a start attempt (T3: "起動役は持ち主にならない。書くのは
# daemon_start_attemptsだけ"). Best-effort: if install.db cannot be
# written either, the reason still reaches stderr.
_agmsgd_launch_record_attempt() {
  local reason="$1"
  if [ -f "$INSTALL_DB" ]; then
    sqlite3 "$INSTALL_DB" \
      "INSERT INTO daemon_start_attempts (at, reason, executor_pid) VALUES (strftime('%Y-%m-%dT%H:%M:%fZ','now'), '$(printf '%s' "$reason" | sed "s/'/''/g")', $$);" \
      2>/dev/null || true
  fi
  echo "agmsgd-launch: $reason" >&2
}

# Non-blocking probe of run/install-op.lock.db's BEGIN EXCLUSIVE (PR 2) --
# an empty file this process never writes to, only locks against, exactly
# like lifecycle.mjs's own Node-side probe (kept in sync with it
# deliberately: same busy_timeout=0-then-BEGIN-EXCLUSIVE idiom, so bash and
# Node can never disagree about whether the lock is held).
_agmsgd_launch_lock_held() {
  [ -f "$LOCK_DB" ] || return 1
  ! sqlite3 -cmd "PRAGMA busy_timeout=0;" "$LOCK_DB" "BEGIN EXCLUSIVE; ROLLBACK;" >/dev/null 2>&1
}

# Reads the completion record's bootstrap_version and compares it against
# this file's own $BOOTSTRAP_VERSION (T3 "入口の一貫性": both the launcher
# and the Node entrypoint check their own compiled-in constant against the
# SAME recorded value under the operation lock). Uses json_extract over
# readfile() -- the same idiom scripts/identities.sh already uses for team
# config.json -- rather than jq, which is not on this launcher's
# guaranteed PATH. Caller passes the already-confirmed-to-exist manifest
# path; this does not decide completeness, only the version match.
_agmsgd_launch_check_bootstrap_version() {
  local manifest_path="$1" recorded
  recorded="$(sqlite3 :memory: "
    WITH raw(json) AS (SELECT CAST(readfile('$(printf '%s' "$manifest_path" | sed "s/'/''/g")') AS TEXT))
    SELECT json_extract(json, '\$.bootstrap_version') FROM raw;
  " 2>/dev/null)"
  [ "$recorded" = "$BOOTSTRAP_VERSION" ]
}

# 1. install.db must be readable, or we must not assume `on` (T3 step 1).
if [ ! -f "$INSTALL_DB" ]; then
  echo "agmsgd-launch: run/install.db does not exist -- nothing to start" >&2
  exit 0
fi
DESIRED="$(sqlite3 "$INSTALL_DB" "SELECT desired FROM daemon_intent;" 2>/dev/null)" || {
  _agmsgd_launch_record_attempt "install.db could not be read"
  exit 0
}

# 2. Not `on` -> nothing to do, silently (T3 step 2).
if [ "$DESIRED" != "on" ]; then
  exit 0
fi
OP_GEN="$(sqlite3 "$INSTALL_DB" "SELECT op_gen FROM daemon_intent;" 2>/dev/null)"

# 3. Completion record state (T3 step 3 / "更新").
if [ -f "$MANIFEST" ]; then
  : # complete -- proceed
elif [ -f "$MANIFEST.prev" ]; then
  if _agmsgd_launch_lock_held; then
    echo "agmsgd-launch: an install/uninstall is in progress" >&2
    exit 75
  fi
  _agmsgd_launch_record_attempt "a previous update never completed -- run install.sh again"
  exit 0
else
  _agmsgd_launch_record_attempt "no completion record -- install.sh needs to run again"
  exit 0
fi

_agmsgd_launch_check_bootstrap_version "$MANIFEST" || {
  _agmsgd_launch_record_attempt "bootstrap version mismatch"
  exit 75
}

# 4. Node: resolve, then ACTUALLY RUN it -- T2 #3: found is confirmed by
# execution (version + node:sqlite loads), not by trusting the recorded
# path/version strings.
NODE_PATH="$(sqlite3 "$INSTALL_DB" "SELECT node_path FROM meta;" 2>/dev/null)"
if [ -z "$NODE_PATH" ] || [ ! -x "$NODE_PATH" ]; then
  _agmsgd_launch_record_attempt "no usable Node recorded (run 'agmsg daemon enable' again)"
  exit 0
fi
NODE_CHECK_OUTPUT="$("$NODE_PATH" -e '
  const [maj, min] = process.versions.node.split(".").map(Number);
  if (maj < 22 || (maj === 22 && min < 13)) { console.error("too old: " + process.versions.node); process.exit(1); }
  require("node:sqlite");
  console.log(process.versions.node);
' 2>&1)" || {
  _agmsgd_launch_record_attempt "recorded Node failed the version/node:sqlite check: $NODE_CHECK_OUTPUT"
  exit 0
}

# 5. Hand off. `exec -a agmsgd` reads the entrypoint file exactly once,
# here (T3: "execの時点で入口のファイルを1回だけ読む").
exec -a agmsgd "$NODE_PATH" "$SCRIPT_DIR/agmsgd" "$SKILL_DIR" "$DESIRED" "$OP_GEN"
