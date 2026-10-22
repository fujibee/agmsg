#!/usr/bin/env bash
# agmsgd's CLI ("agmsg daemon start|stop|status|enable|disable").
# Takes the subcommand as its first argument so the `agmsg` dispatcher
# wraps this file directly. User-facing instructions use `agmsg daemon ...`
# and give the installed dispatcher's absolute path when PATH is not set.
#
# No Node is required for `status` on the fast path: it reads
# install.db directly with sqlite3 first, and only shells out to Node
# (status.mjs) for the fuller decision text when Node is available and
# the record even suggests it's worth asking.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DB="$SKILL_DIR/run/install.db"
LOCK_DB="$SKILL_DIR/run/install-op.lock.db"
LAUNCHER="$SCRIPT_DIR/daemon/agmsgd-launch.sh"
# shellcheck source=lib/daemon-state.sh
source "$SCRIPT_DIR/lib/daemon-state.sh"
# shellcheck source=lib/storage.sh
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck source=lib/daemon-seats.sh
source "$SCRIPT_DIR/lib/daemon-seats.sh"
# shellcheck source=lib/install-db.sh
source "$SCRIPT_DIR/lib/install-db.sh"
# shellcheck source=lib/sqlpath.sh
source "$SCRIPT_DIR/lib/sqlpath.sh"
# shellcheck source=lib/hash.sh
source "$SCRIPT_DIR/lib/hash.sh"

_path_hint() {
  printf 'If agmsg is not found, use "%s/scripts/agmsg" daemon %s.\n' "$SKILL_DIR" "$1"
}

# Overridable so tests never register anything into the REAL resident
# manager (the real gui launchd domain, the real systemd --user, the real
# Task Scheduler) -- a test that killed a hung process outright, bypassing
# its own teardown, left exactly one real launchd unit behind on this
# machine. Tests point these at fake stand-ins; real registration is
# exercised only by hand and always torn down right after.
AGMSGD_LAUNCHCTL="${AGMSGD_LAUNCHCTL:-launchctl}"
AGMSGD_SYSTEMCTL="${AGMSGD_SYSTEMCTL:-systemctl}"
AGMSGD_SCHTASKS="${AGMSGD_SCHTASKS:-schtasks}"

_usage() {
  cat >&2 <<'EOF'
usage: agmsg daemon start|stop|status|enable|disable|offer <type>
status options: --json (machine-readable), --all (include older destinations)
EOF
}

_require_install_db() {
  if [ ! -f "$INSTALL_DB" ]; then
    echo "agmsg daemon: run/install.db does not exist -- run install.sh first" >&2
    exit 1
  fi
}

# An install.db made by an older install.sh lacks meta's node columns and the
# daemon tables; bring it up to schema.sql. Only the commands that change
# daemon state call this -- status stays a read.
_ensure_install_db_schema() {
  _require_install_db
  agmsg_install_db_apply_schema "$INSTALL_DB" "$SCRIPT_DIR/daemon/schema.sql" || {
    echo "agmsg daemon: could not bring run/install.db up to date" >&2
    exit 1
  }
}

# Runs $1 (one or more SQL statements against install.db's tables,
# unqualified names -- see below) inside the operation lock. Optional
# remaining arguments name one resident-manager action that must share the
# same lock (enable/register or disable/unregister).
#
# The EXCLUSIVE lock belongs to $LOCK_DB (an empty file, PR 2's own
# design -- the lock IS the file, nothing is ever written into it
# directly). $1's statements target install.db, so install.db is ATTACHed
# into the SAME connection/transaction that holds the lock: a bare
# `sqlite3 "$LOCK_DB" "...UPDATE daemon_intent..."` would run that UPDATE
# against $LOCK_DB itself, which has no such table at all -- caught
# exactly this way while testing (`no such table: daemon_intent` even
# though install.db plainly has the table). ATTACH keeps the lock where
# PR 2 says it lives while still writing to the file that actually holds
# the data, in one real cross-file transaction.
_install_generation() {
  local install_id manifest_path_sql manifest_id manifest_gen manifest_pair
  install_id="$(agmsg_sqlite "$INSTALL_DB" "SELECT install_id FROM meta;" 2>/dev/null)" || return 1
  manifest_path_sql="$(agmsg_sql_readfile_path "$SKILL_DIR/run/install-manifest.json")"
  # Captured on its own line, THEN split -- not `IFS='|' read ... < <(agmsg_sqlite ...)`
  # (review on #1668/#1631): a temporary assignment on a simple command's own
  # line is visible to every word expansion on that same line, including a
  # process substitution's subshell, so IFS='|' was still in effect inside
  # agmsg_sqlite() there. storage.sh's agmsg_sqlite() relies on the DEFAULT
  # IFS to word-split $_AGMSG_ESCAPE_FLAG ('-escape off') into two argv for
  # sqlite3; under IFS='|' that string stayed one argument, and `sqlite3
  # '-escape off' -cmd ...` failed outright on any sqlite3 build that
  # supports -escape (3.50+) -- enable never got past this read on such a
  # build, let alone to lock acquisition.
  manifest_pair="$(agmsg_sqlite :memory: "SELECT json_extract(CAST(readfile('$manifest_path_sql') AS TEXT), '\$.install_id') || '|' || json_extract(CAST(readfile('$manifest_path_sql') AS TEXT), '\$.gen');" 2>/dev/null)" || return 1
  IFS='|' read -r manifest_id manifest_gen <<<"$manifest_pair"
  [ -n "$install_id" ] && [ "$manifest_id" = "$install_id" ] && [ -n "$manifest_gen" ] || return 1
  printf '%s:%s' "$install_id" "$manifest_gen"
}

# Hold the SQLite installation lock across the database change and the
# resident-manager operation. The install generation is captured before
# acquisition and rechecked while the lock is held, so an upgrade between
# those points cannot register an obsolete launcher.
_with_op_lock() {
  # A lock helper that exits early must show up as "could not acquire", not as
  # this shell dying silently on a write to a closed pipe (exit 141).
  trap '' PIPE
  local rc=0
  _with_op_lock_run "$@" || rc=$?
  trap - PIPE
  return "$rc"
}

_with_op_lock_run() {
  local statements="$1" expected_generation current_generation ready applied lock_pid attach_path lock_dir
  local AGMSGD_LOCK_INSTALL_ID
  shift
  expected_generation="$(_install_generation)" || {
    echo "agmsg daemon: could not read this install's record (run/install-manifest.json does not match run/install.db, or one of them cannot be read). Repair it with: npx agmsg@next install --update (add --cmd <name> if this is a named install or several installs exist), then try again." >&2
    return 1
  }
  AGMSGD_LOCK_INSTALL_ID="${expected_generation%%:*}"
  lock_dir="$(mktemp -d "$SKILL_DIR/run/daemon-op-lock.XXXXXX")" || return 1
  if [ "$(_os)" = windows ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    # The native sqlite3 on Windows cannot be driven through an MSYS FIFO (it
    # never answers), so talk to it over a coprocess's anonymous pipes. eval
    # keeps the coproc syntax out of the parse for shells that lack it (bash
    # 3.2 has no coproc; Git Bash ships bash 5).
    eval 'coproc agmsgd_lock_sql { sqlite3 -batch "$LOCK_DB" 3>&- 4>&-; }'
    lock_pid="${agmsgd_lock_sql_PID:-}"
    if [ -z "$lock_pid" ] || [ -z "${agmsgd_lock_sql[0]:-}" ] || [ -z "${agmsgd_lock_sql[1]:-}" ]; then
      rmdir "$lock_dir" 2>/dev/null || true
      echo 'agmsg daemon: could not start sqlite3 to hold the install operation lock' >&2
      return 1
    fi
    exec 8>&"${agmsgd_lock_sql[1]:-}" 9<&"${agmsgd_lock_sql[0]:-}"
    eval "exec ${agmsgd_lock_sql[1]:-}>&- ${agmsgd_lock_sql[0]:-}<&-"
  else
    mkfifo "$lock_dir/in" "$lock_dir/out"
    sqlite3 -batch "$LOCK_DB" < "$lock_dir/in" > "$lock_dir/out" 3>&- 4>&- &
    lock_pid=$!
    exec 8> "$lock_dir/in"
    exec 9< "$lock_dir/out"
  fi
  attach_path="$(agmsg_sql_readfile_path "$INSTALL_DB")"
  printf '%s\n' '.bail on' "ATTACH DATABASE '$attach_path' AS installdb;" 'BEGIN EXCLUSIVE;' '.print LOCKED' >&8
  if ! IFS= read -r -t 10 ready <&9 || [ "${ready%$'\r'}" != "LOCKED" ]; then
    printf 'ROLLBACK;\n.quit\n' >&8 2>/dev/null || true
    exec 8>&-
    exec 9<&-
    wait "$lock_pid" 2>/dev/null || true
    rm -f "$lock_dir/in" "$lock_dir/out"
    rmdir "$lock_dir"
    echo "agmsg daemon: could not acquire the install operation lock" >&2
    return 1
  fi
  local generation_row generation_marker manifest_sql
  manifest_sql="$(agmsg_sql_readfile_path "$SKILL_DIR/run/install-manifest.json")"
  printf '%s\n' "SELECT CASE WHEN json_extract(CAST(readfile('$manifest_sql') AS TEXT), '\$.install_id') = (SELECT install_id FROM installdb.meta) THEN (SELECT install_id FROM installdb.meta) || ':' || json_extract(CAST(readfile('$manifest_sql') AS TEXT), '\$.gen') ELSE '' END;" '.print GENERATION_END' >&8
  IFS= read -r -t 10 generation_row <&9 || generation_row=""
  IFS= read -r -t 10 generation_marker <&9 || generation_marker=""
  current_generation="${generation_row%$'\r'}"
  if [ "${generation_marker%$'\r'}" != "GENERATION_END" ] || [ "$current_generation" != "$expected_generation" ]; then
    printf 'ROLLBACK;\n.quit\n' >&8
    exec 8>&-
    exec 9<&-
    wait "$lock_pid" 2>/dev/null || true
    rm -f "$lock_dir/in" "$lock_dir/out"
    rmdir "$lock_dir"
    echo "agmsg daemon: install generation changed while acquiring the operation lock; try again" >&2
    return 1
  fi
  if [ -n "$statements" ]; then
    # Upgrade rc.1 inside this connection's operation lock and transaction.
    local has_codex_path
    printf '%s\n' "SELECT count(*) FROM pragma_table_info('meta', 'installdb') WHERE name='codex_path';" >&8
    IFS= read -r -t 10 has_codex_path <&9 || has_codex_path=""
    has_codex_path="${has_codex_path%$'\r'}"
    if [ "$has_codex_path" = 0 ]; then
      printf '%s\n' 'ALTER TABLE installdb.meta ADD COLUMN codex_path TEXT;' >&8
    elif [ "$has_codex_path" != 1 ]; then
      printf 'ROLLBACK;\n.quit\n' >&8 2>/dev/null || true
      exec 8>&-
      exec 9<&-
      wait "$lock_pid" 2>/dev/null || true
      rm -f "$lock_dir/in" "$lock_dir/out"
      rmdir "$lock_dir"
      echo 'agmsg daemon: could not inspect the Codex executable column' >&2
      return 1
    fi
    printf '%s\n.print APPLIED\n' "$statements" >&8
    if ! IFS= read -r -t 10 applied <&9 || [ "${applied%$'\r'}" != "APPLIED" ]; then
      printf 'ROLLBACK;\n.quit\n' >&8 2>/dev/null || true
      exec 8>&-
      exec 9<&-
      wait "$lock_pid" 2>/dev/null || true
      rm -f "$lock_dir/in" "$lock_dir/out"
      rmdir "$lock_dir"
      echo "agmsg daemon: install database update failed" >&2
      return 1
    fi
  fi
  local action_status=0
  if [ "$#" -gt 0 ]; then
    "$@" || action_status=$?
  fi
  if [ "$action_status" -eq 0 ]; then
    printf 'COMMIT;\n' >&8
  else
    printf 'ROLLBACK;\n' >&8
  fi
  printf '.quit\n' >&8
  exec 8>&-
  exec 9<&-
  wait "$lock_pid" || action_status=1
  rm -f "$lock_dir/in" "$lock_dir/out"
  rmdir "$lock_dir"
  return "$action_status"
}

# A short, stable id for this install's resident-manager unit name,
# derived from the install anchor (realpath + install_id). Beta uses two
# of the three (root path, install_id); the record DB's own path is
# already implied by being run/install.db under this same root, so it is
# not a third independent input here.
_unit_id() {
  local install_id="${AGMSGD_LOCK_INSTALL_ID:-}"
  if [ -z "$install_id" ]; then
    install_id="$(agmsg_sqlite "$INSTALL_DB" "SELECT install_id FROM meta;" 2>/dev/null)"
  fi
  # shasum is absent from Git Bash; agmsg_sha256 falls back to sha256sum.
  printf '%s:%s' "$SKILL_DIR" "$install_id" | agmsg_sha256 | cut -c1-12
}

_os() {
  case "$(uname -s)" in
    Darwin) echo darwin ;;
    Linux) echo linux ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

# ---------------------------------------------------------------------------
# Resident registration. One function per OS; enable/
# disable call whichever applies. Only the darwin path has been run for
# real in this environment -- linux (systemd --user) and windows (Task
# Scheduler) use the same contract and are shellchecked, but need
# their own hands-on confirmation on those platforms, flagged in the PR
# rather than claimed here.
# ---------------------------------------------------------------------------

_launchd_label() { printf 'cc.agmsg.agmsgd.%s' "$(_unit_id)"; }
_launchd_plist_path() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(_launchd_label)"; }

_register_darwin() {
  local node_path="$1" label plist
  label="$(_launchd_label)"
  plist="$(_launchd_plist_path)"
  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$LAUNCHER</string>
  </array>
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardErrorPath</key><string>$SKILL_DIR/run/agmsgd.stderr.log</string>
</dict>
</plist>
EOF
  "$AGMSGD_LAUNCHCTL" bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || "$AGMSGD_LAUNCHCTL" load "$plist"
}

_unregister_darwin() {
  local label plist
  label="$(_launchd_label)"
  plist="$(_launchd_plist_path)"
  if [ -f "$plist" ]; then
    if ! "$AGMSGD_LAUNCHCTL" bootout "gui/$(id -u)/$label" 2>/dev/null && ! "$AGMSGD_LAUNCHCTL" unload "$plist" 2>/dev/null; then
      echo "agmsg daemon: could not unregister launchd service $label" >&2
      return 1
    fi
    rm -f "$plist"
  fi
}

# False on a machine with no systemd user manager (a container, WSL1, a
# minimal image): no systemctl at all, or one that cannot reach a user bus.
_systemd_user_usable() { "$AGMSGD_SYSTEMCTL" --user show-environment >/dev/null 2>&1; }

_systemd_unit_path() { printf '%s/.config/systemd/user/agmsgd-%s.service' "$HOME" "$(_unit_id)"; }

# NOT YET RUN ON LINUX in this environment -- configured with
# (Restart=on-failure, RestartSec=30s, StartLimitIntervalSec=600,
# StartLimitBurst=5) and shellchecked only.
_register_linux() {
  local unit_path unit_name
  unit_path="$(_systemd_unit_path)"
  unit_name="$(basename "$unit_path")"
  mkdir -p "$(dirname "$unit_path")"
  cat > "$unit_path" <<EOF
[Unit]
Description=agmsgd ($SKILL_DIR)
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
ExecStart=$LAUNCHER
Restart=on-failure
RestartSec=30s

[Install]
WantedBy=default.target
EOF
  "$AGMSGD_SYSTEMCTL" --user daemon-reload
  "$AGMSGD_SYSTEMCTL" --user enable "$unit_name"
}

_unregister_linux() {
  local unit_path unit_name
  unit_path="$(_systemd_unit_path)"
  unit_name="$(basename "$unit_path")"
  if [ -f "$unit_path" ]; then
    # With no systemd user manager there is nothing registered with it to
    # undo; drop the unit file so disable can still finish.
    if _systemd_user_usable; then
      if ! "$AGMSGD_SYSTEMCTL" --user disable --now "$unit_name"; then
        echo "agmsg daemon: could not disable systemd user service $unit_name" >&2
        return 1
      fi
      rm -f "$unit_path"
      "$AGMSGD_SYSTEMCTL" --user daemon-reload
    else
      rm -f "$unit_path"
    fi
  fi
}

_schtasks_name() { printf 'agmsgd-%s' "$(_unit_id)"; }

_service_registered() {
  case "$(_os)" in
    darwin) [ -f "$(_launchd_plist_path)" ] ;;
    linux) [ -f "$(_systemd_unit_path)" ] ;;
    windows) [ -f "$SKILL_DIR/run/$(_schtasks_name).xml" ] ;;
    *) return 1 ;;
  esac
}

_start_registered_service() {
  case "$(_os)" in
    darwin) "$AGMSGD_LAUNCHCTL" kickstart "gui/$(id -u)/$(_launchd_label)" ;;
    linux) "$AGMSGD_SYSTEMCTL" --user start "$(basename "$(_systemd_unit_path)")" ;;
    windows) _schtasks /Run /TN "$(_schtasks_name)" ;;
    *) echo "agmsg daemon start: unsupported resident manager" >&2; return 1 ;;
  esac
}

_start_unregistered_launcher() {
  local stderr_log="${AGMSGD_TEST_LAUNCH_STDERR_LOG:-/dev/null}"
  bash "$LAUNCHER" </dev/null >/dev/null 2>"$stderr_log" 3>&- 4>&- &
  disown 2>/dev/null || true
}

# NOT YET RUN ON WINDOWS in this environment -- written to the Windows
# Task Scheduler contract (LogonTrigger + RestartOnFailure via XML, since plain
# `/Create` flags do not set restart-on-failure) and shellchecked only.
# schtasks takes /Create-style switches; without this Git Bash rewrites a
# leading-slash argument into a path ("C:/Program Files/Git/Create").
_schtasks() {
  MSYS2_ARG_CONV_EXCL='*' "$AGMSGD_SCHTASKS" "$@"
}

# Paths go into the task XML as text; a "&" in a user name would otherwise
# make the task impossible to create.
_xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

_register_windows() {
  local node_path="$1" name xml
  name="$(_schtasks_name)"
  xml="$SKILL_DIR/run/${name}.xml"
  # A bare `bash.exe` in the task is resolved by CreateProcess, which looks in
  # System32 first and finds WSL's launcher there, not Git Bash. Name the Git
  # Bash that is running this script by its full path instead.
  local git_root git_bash native_bash native_launcher
  git_root="$(cygpath -m / 2>/dev/null || true)"
  git_root="${git_root%/}"
  git_bash="$git_root/bin/bash.exe"
  if [ -z "$git_root" ] || [ ! -f "$git_bash" ]; then
    echo "agmsg daemon: cannot find Git Bash's bin/bash.exe (looked for '$git_bash'); not registering the scheduled task" >&2
    return 1
  fi
  native_bash="$(cygpath -w "$git_bash" 2>/dev/null || printf '%s' "$git_bash")"
  native_launcher="$(cygpath -w "$LAUNCHER" 2>/dev/null || printf '%s' "$LAUNCHER")"
  native_bash="$(_xml_escape "$native_bash")"
  native_launcher="$(_xml_escape "$native_launcher")"
  local xml_utf8="$xml.utf8"
  cat > "$xml_utf8" <<EOF
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>
  </Triggers>
  <Actions>
    <Exec>
      <Command>$native_bash</Command>
      <Arguments>"$native_launcher"</Arguments>
    </Exec>
  </Actions>
  <Settings>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
</Task>
EOF
  { printf '\xff\xfe'; iconv -f UTF-8 -t UTF-16LE "$xml_utf8"; } > "$xml"
  rm -f "$xml_utf8"
  local native_xml
  native_xml="$(cygpath -w "$xml" 2>/dev/null || printf '%s' "$xml")"
  _schtasks /Create /TN "$name" /XML "$native_xml" /F
}

_unregister_windows() {
  local name xml
  name="$(_schtasks_name)"
  xml="$SKILL_DIR/run/$name.xml"
  if [ ! -f "$xml" ]; then
    return 0
  fi
  if ! _schtasks /Delete /TN "$name" /F; then
    echo "agmsg daemon: could not delete scheduled task $name" >&2
    return 1
  fi
  rm -f "$xml"
}

_register() {
  case "$(_os)" in
    darwin) _register_darwin "$1" ;;
    linux) _register_linux "$1" ;;
    windows) _register_windows "$1" ;;
    *) echo "agmsg daemon: unsupported OS for resident registration" >&2; return 1 ;;
  esac
}

_unregister() {
  case "$(_os)" in
    darwin) _unregister_darwin ;;
    linux) _unregister_linux ;;
    windows) _unregister_windows ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

# Confirms Node by actually running it, the same check
# agmsgd-launch.sh itself does -- enable/start both need this before
# recording node_path/node_version.
_resolve_node() {
  local candidate="${1:-node}" resolved
  resolved="$(command -v "$candidate" 2>/dev/null)" || return 1
  "$resolved" --disable-warning=ExperimentalWarning -e '
    const [maj, min] = process.versions.node.split(".").map(Number);
    if (maj < 22 || (maj === 22 && min < 13)) process.exit(1);
    require("node:sqlite");
  ' 2>/dev/null || return 1
  printf '%s' "$resolved"
}

_resolve_codex() {
  local candidate dir rest="${PATH:-}:" override="${AGMSG_REAL_CODEX:-}"
  while :; do
    if [ -n "$override" ]; then
      candidate="$override"
      override=""
    elif [ -n "$rest" ]; then
      dir="${rest%%:*}"
      rest="${rest#*:}"
      [ -n "$dir" ] || dir=.
      candidate="$dir/codex"
    else
      return 1
    fi
    case "$candidate" in *[[:cntrl:]]*) continue ;; esac
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    if head -c 4096 "$candidate" 2>/dev/null | grep -q 'Optional Codex entrypoint shim for agmsg monitor mode'; then
      continue
    fi
    dir="$(cd "$(dirname "$candidate")" && pwd -P)" || continue
    candidate="$dir/$(basename "$candidate")"
    if command -v cygpath >/dev/null 2>&1; then
      candidate="$(cygpath -m "$candidate")" || continue
    fi
    printf '%s\n' "$candidate"
    return 0
  done
}

_wait_for_ready() {
  local target_op_gen="$1" waited=0
  while [ "$waited" -lt 100 ]; do
    local state op_gen
    state="$(agmsg_sqlite "$INSTALL_DB" "SELECT state FROM daemon_owner;" 2>/dev/null || true)"
    op_gen="$(agmsg_sqlite "$INSTALL_DB" "SELECT op_gen FROM daemon_intent;" 2>/dev/null || true)"
    if [ "$state" = "ready" ] && [ "$op_gen" = "$target_op_gen" ]; then
      return 0
    fi
    waited=$((waited + 1))
    sleep 0.1
  done
  return 1
}

# `start --only-if-op-gen N` is what an update uses to bring a daemon back: it
# starts only if the intent is still the "on" at op_gen N the update saw, so a
# stop/disable/start made by a person in the meantime is never undone.
cmd_start() {
  local only_gen=""
  case "${1:-}" in
    --only-if-op-gen)
      only_gen="${2:-}"
      case "$only_gen" in ''|*[!0-9]*) _usage; return 2 ;; esac ;;
    '') ;;
    *) _usage; return 2 ;;
  esac
  _ensure_install_db_schema
  local state
  state="$(agmsg_sqlite "$INSTALL_DB" "SELECT state FROM daemon_owner;")"
  if [ "$state" = "ready" ] && node "$SCRIPT_DIR/daemon/status.mjs" "$SKILL_DIR" >/dev/null 2>&1; then
    echo "agmsg daemon start: already running"
    agmsg_daemon_seat_report start
    _path_hint status
    return 0
  fi

  # A install that was never enabled (enable refuses without a service
  # manager) has no Node recorded, and the launcher cannot start without
  # one. Find it here the way enable does, and stop before touching the
  # intent when there is none.
  local recorded_node found_node found_version record_node_sql=""
  recorded_node="$(agmsg_sqlite "$INSTALL_DB" "SELECT node_path FROM meta;" 2>/dev/null || true)"
  if [ -z "$recorded_node" ] || [ ! -x "$recorded_node" ]; then
    found_node="$(_resolve_node node)" || {
      echo "agmsg daemon start: no usable Node found (need >= 22.13.0 with node:sqlite), so agmsgd cannot start. Nothing was changed. Install Node from https://nodejs.org/en/download, then run agmsg daemon start." >&2
      _path_hint start >&2
      return 1
    }
    found_version="$("$found_node" -e 'console.log(process.versions.node)')"
    record_node_sql="UPDATE meta SET node_path = '$(printf '%s' "$found_node" | sed "s/'/''/g")', node_version = '$found_version';"
  fi

  # An install enabled by an earlier version (or updated before Codex was on
  # PATH) can hold an empty meta.codex_path, which blocks every Codex seat:
  # fill it from the current PATH, never overwriting a path already there.
  local codex_fill="" codex_path
  codex_path="$(_resolve_codex 2>/dev/null || true)"
  if [ -n "$codex_path" ]; then
    codex_fill="UPDATE meta SET codex_path = '$(printf '%s' "$codex_path" | sed "s/'/''/g")' WHERE COALESCE(codex_path, '') = '';"
  fi
  local new_op_gen
  local start_where=""
  [ -z "$only_gen" ] || start_where=" WHERE desired = 'on' AND op_gen = $only_gen"
  _with_op_lock "$record_node_sql $codex_fill UPDATE daemon_intent SET desired = 'on', op_gen = op_gen + 1, set_by = 'start', set_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')$start_where;"
  new_op_gen="$(agmsg_sqlite "$INSTALL_DB" "SELECT op_gen FROM daemon_intent;")"
  # The guarded UPDATE applied only if it left "on" at op_gen+1 written by start.
  if [ -n "$only_gen" ] && [ "$(agmsg_sqlite "$INSTALL_DB" "SELECT desired || '|' || op_gen || '|' || set_by FROM daemon_intent;")" != "on|$((only_gen + 1))|start" ]; then
    echo "agmsg daemon start: agmsgd was turned off or changed while waiting; left as it is now"
    return 0
  fi
  if _service_registered; then
    if ! _start_registered_service; then
      echo "agmsg daemon start: the registered service manager could not start agmsgd" >&2
      return 1
    fi
  else
    _start_unregistered_launcher
  fi
  if _wait_for_ready "$new_op_gen"; then
    echo "agmsg daemon start: running"
    agmsg_daemon_seat_report start
    _path_hint status
  else
    echo "agmsg daemon start: did not become ready in time -- check 'agmsg daemon status'" >&2
    if [ "$(_os)" = windows ] && _service_registered; then
      echo "agmsg daemon start: the scheduled task $(_schtasks_name) was created and started, but agmsgd never reported ready. Task Scheduler's own record of the run follows; 'agmsg daemon disable' removes the task." >&2
      _schtasks /Query /TN "$(_schtasks_name)" /V /FO LIST 2>&1 | grep -E 'Status|Last Run Time|Last Result|Task To Run' >&2 || true
    fi
    agmsg_daemon_warn_if_stopped always
    _path_hint status >&2
    return 1
  fi
}

# Best-effort courtesy nudge over the control socket -- NOT what confirms
# a stop; the caller's own polling of daemon_owner.state does that. A hard
# 5s ceiling: relying on the socket's own close/error events alone left
# this able to hang the whole command indefinitely if the daemon never
# answers (observed while testing: a daemon that had already started
# stepping aside for an unrelated reason at the same moment left this
# connection open with neither event firing).
_request_stop_over_socket() {
  local socket="$1"
  [ -n "$socket" ] || return 0
  node -e '
    const net = require("node:net");
    const s = net.createConnection(process.argv[1]);
    const done = () => { try { s.destroy(); } catch {} process.exit(0); };
    setTimeout(done, 5000);
    s.on("connect", () => {
      s.write(JSON.stringify({type:"hello",protocol:1,role:"control"}) + "\n");
      s.write(JSON.stringify({type:"stop"}) + "\n");
    });
    s.on("close", done);
    s.on("error", done);
  ' "$socket" 2>/dev/null || true
}

cmd_stop() {
  _ensure_install_db_schema
  # Stop takes no operation lock.
  local desired
  desired="$(agmsg_sqlite "$INSTALL_DB" "SELECT desired FROM daemon_intent;" 2>/dev/null || true)"
  if [ "$desired" != "on" ]; then
    echo "agmsg daemon stop: already stopped"
    return 0
  fi
  agmsg_sqlite "$INSTALL_DB" "UPDATE daemon_intent SET desired = 'off', op_gen = op_gen + 1, set_by = 'stop', set_at = strftime('%Y-%m-%dT%H:%M:%fZ','now');"
  local socket
  socket="$(agmsg_sqlite "$INSTALL_DB" "SELECT socket FROM daemon_owner WHERE state = 'ready';" 2>/dev/null || true)"
  _request_stop_over_socket "$socket"
  local waited=0
  while [ "$waited" -lt 100 ]; do
    local state
    state="$(agmsg_sqlite "$INSTALL_DB" "SELECT state FROM daemon_owner;" 2>/dev/null || true)"
    [ "$state" = "none" ] && { echo "agmsg daemon stop: stopped"; return 0; }
    waited=$((waited + 1))
    sleep 0.1
  done
  echo "agmsg daemon stop: requested, but it has not confirmed stopping yet -- check 'agmsg daemon status'" >&2
  return 1
}

cmd_status() {
  _require_install_db
  local json=false AGMSG_DAEMON_ALL=0 option
  for option in "$@"; do
    case "$option" in
      --json) json=true ;;
      --all) AGMSG_DAEMON_ALL=1 ;;
      *) _usage; return 2 ;;
    esac
  done
  local owner_tables
  # Only a database that answers and has no daemon_owner table is "not in use
  # yet"; a query that fails (corrupt, locked) falls through to the normal
  # read below and is reported as unknown.
  if owner_tables="$(agmsg_sqlite "$INSTALL_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='daemon_owner';" 2>/dev/null)" && [ "$owner_tables" = 0 ] && [ "$json" != true ]; then
    echo "agmsg daemon status: agmsgd is not in use yet (turn it on with 'agmsg daemon enable')"
    return 0
  fi
  local node_path
  node_path="$(_resolve_node node 2>/dev/null || true)"
  if [ -n "$node_path" ]; then
    local status_rc=0
    if [ "$json" = true ]; then
      "$node_path" --disable-warning=ExperimentalWarning "$SCRIPT_DIR/daemon/status.mjs" "$SKILL_DIR" --json || status_rc=$?
    else
      if [ "$AGMSG_DAEMON_ALL" = 1 ]; then
        "$node_path" --disable-warning=ExperimentalWarning "$SCRIPT_DIR/daemon/status.mjs" "$SKILL_DIR" --all || status_rc=$?
      else
        "$node_path" --disable-warning=ExperimentalWarning "$SCRIPT_DIR/daemon/status.mjs" "$SKILL_DIR" || status_rc=$?
      fi
      agmsg_daemon_seat_report status
    fi
    return "$status_rc"
  fi
  agmsg_daemon_read_state
  local health_rc=0
  if [ "${AGMSGD_DESIRED:-unknown}" = on ] && [ "${AGMSGD_HEALTH:-unknown}" != ready ]; then
    [ "$json" = true ] || agmsg_daemon_recovery_text
    health_rc=1
  elif [ "${AGMSGD_HEALTH:-unknown}" = unknown ]; then
    [ "$json" = true ] || echo 'agmsg daemon status: install record could not be read; health is unknown'
    health_rc=1
  fi
  if [ "$json" = true ]; then
    agmsg_sqlite "$INSTALL_DB" "SELECT json_object('state',state,'intent',(SELECT desired FROM daemon_intent),'health','${AGMSGD_HEALTH:-unknown}','detail','no usable Node') FROM daemon_owner;"
    return "$health_rc"
  fi
  # K14 fallback: no usable Node at all -- a minimal, honest read straight
  # from install.db rather than the fuller status.mjs decision text.
  local state desired
  state="$(agmsg_sqlite "$INSTALL_DB" "SELECT state FROM daemon_owner;" 2>/dev/null || echo "unknown")"
  desired="$(agmsg_sqlite "$INSTALL_DB" "SELECT desired FROM daemon_intent;" 2>/dev/null || echo "unknown")"
  echo "agmsg daemon status: state=$state intent=$desired (no usable Node -- a fuller check needs 'agmsg daemon enable')"
  agmsg_daemon_seat_report status
  _path_hint enable
  return "$health_rc"
}

cmd_enable() {
  _ensure_install_db_schema
  if [ "$(_os)" = linux ] && ! _systemd_user_usable; then
    echo "agmsg daemon enable: systemd user services are not available here (systemctl --user does not work), so agmsgd cannot be registered to start on its own. Nothing was changed. 'agmsg daemon start' runs it for this session only." >&2
    _path_hint start >&2
    return 1
  fi
  local node_path
  node_path="$(_resolve_node node)" || {
    echo "agmsg daemon enable: no usable Node found (need >= 22.13.0 with node:sqlite). Install one and try again." >&2
    echo 'Install Node from https://nodejs.org/en/download, then run agmsg daemon enable.' >&2
    _path_hint enable >&2
    return 1
  }
  local node_version
  node_version="$("$node_path" -e 'console.log(process.versions.node)')"
  local codex_path
  codex_path="$(_resolve_codex 2>/dev/null || true)"
  if [ -z "$codex_path" ]; then
    echo 'agmsg daemon enable: no usable Codex executable found; Codex seats stay blocked until enabled again with Codex available.' >&2
  fi
  _with_op_lock "
    UPDATE meta SET node_path = '$(printf '%s' "$node_path" | sed "s/'/''/g")', node_version = '$node_version', codex_path = '$(printf '%s' "$codex_path" | sed "s/'/''/g")';
    UPDATE daemon_intent SET desired = 'on';
  " _register "$node_path" || {
    if ! _with_op_lock "" _unregister; then
      echo "agmsg daemon enable: could not clean up the partially registered service" >&2
    fi
    return 1
  }
  cmd_start
}

# Reads daemon_owner.state, waiting up to ~10s for it to become "none".
_wait_owner_none() {
  local waited=0 state
  while [ "$waited" -lt 100 ]; do
    state="$(agmsg_sqlite "$INSTALL_DB" "SELECT state FROM daemon_owner;" 2>/dev/null || true)"
    [ "$state" = "none" ] && break
    waited=$((waited + 1))
    sleep 0.1
  done
  printf '%s' "$state"
}

# Runs on the connection _with_op_lock holds (fds 8/9): one value from install.db.
_lock_query() {
  local row marker
  printf '%s\n.print Q_END\n' "$1" >&8
  IFS= read -r -t 10 row <&9 || return 1
  IFS= read -r -t 10 marker <&9 || return 1
  [ "${marker%$'\r'}" = Q_END ] || return 1
  printf '%s' "${row%$'\r'}"
}

# Turns the intent off and records what it was and which op_gen this disable
# owns, so the later steps touch only their own change.
_disable_commit_intent() {
  DISABLE_PREV_INTENT="$(_lock_query "SELECT desired FROM installdb.daemon_intent;")" || return 1
  printf '%s\n' "UPDATE installdb.daemon_intent SET desired = 'off', op_gen = op_gen + 1, set_by = 'disable', set_at = strftime('%Y-%m-%dT%H:%M:%fZ','now');" >&8
  DISABLE_GEN="$(_lock_query "SELECT op_gen FROM installdb.daemon_intent;")" || return 1
}

# Unregisters only while the intent is still the one this disable wrote; a
# later enable/start owns the service now and is left alone.
_disable_unregister_if_current() {
  local now
  now="$(_lock_query "SELECT desired || '|' || op_gen FROM installdb.daemon_intent;")" || return 1
  if [ "$now" != "off|$DISABLE_GEN" ]; then
    DISABLE_SUPERSEDED=1
    return 0
  fi
  _unregister
}

# After a failed unregister: put the intent back as it was, but only if it is
# still the one this disable wrote.
_disable_restore_intent() {
  local now
  now="$(_lock_query "SELECT desired || '|' || op_gen FROM installdb.daemon_intent;")" || return 1
  [ "$now" = "off|$DISABLE_GEN" ] || return 0
  printf '%s\n' "UPDATE installdb.daemon_intent SET desired = '$DISABLE_PREV_INTENT', op_gen = op_gen + 1, set_by = 'disable', set_at = strftime('%Y-%m-%dT%H:%M:%fZ','now');" >&8
}

cmd_disable() {
  _ensure_install_db_schema
  # The daemon writes stopping -> none into install.db on its way out, so it
  # must stop while no operation holds that database: commit the intent and
  # release the lock first, let the daemon finish, and only then unregister
  # the service under the lock. Stopping the service from inside the lock
  # made the dying daemon fail with "database is locked" and left the record
  # at ready.
  local DISABLE_PREV_INTENT="" DISABLE_GEN="" DISABLE_SUPERSEDED=0
  _with_op_lock "" _disable_commit_intent || return 1
  local socket state
  socket="$(agmsg_sqlite "$INSTALL_DB" "SELECT socket FROM daemon_owner WHERE state = 'ready';" 2>/dev/null || true)"
  _request_stop_over_socket "$socket"
  state="$(_wait_owner_none)"
  if ! _with_op_lock "" _disable_unregister_if_current; then
    _with_op_lock "" _disable_restore_intent || true
    return 1
  fi
  if [ "$DISABLE_SUPERSEDED" = 1 ]; then
    echo "agmsg daemon disable: the service was changed by another command while disable was waiting; it was left as that command set it -- check 'agmsg daemon status'" >&2
    return 1
  fi
  if [ "$state" != "none" ]; then
    state="$(_wait_owner_none)"
  fi
  if [ "$state" != "none" ]; then
    # A record written by an older version cannot be checked against this
    # boot. Disable is the deliberate way out of it: the daemon was asked to
    # stop above, so drop the unverifiable record instead of leaving it to
    # block every later start.
    local AGMSGD_DESIRED AGMSGD_HEALTH AGMSGD_REASON seen_gen seen_pid seen_boot seen_triple
    # Captured first, split after (same reason as _install_generation above,
    # #1668 review): IFS='|' on this line would otherwise still be in effect
    # inside agmsg_sqlite()'s own process-substitution subshell and break its
    # `-escape off` argv splitting.
    seen_triple="$(agmsg_sqlite "$INSTALL_DB" "SELECT gen, COALESCE(executor_pid,0), COALESCE(executor_boot_id,'') FROM daemon_owner;" 2>/dev/null || true)"
    IFS='|' read -r seen_gen seen_pid seen_boot <<<"$seen_triple"
    agmsg_daemon_read_state
    # Only the exact record that was just judged unverifiable may be dropped:
    # a daemon started since then has a different gen, and is left alone.
    case "$seen_gen|$seen_pid|$seen_boot" in
      *[!0-9\|]*|''|'||'*) ;;
      *)
        if [ "${AGMSGD_HEALTH:-}" = unverifiable ]; then
          _with_op_lock "UPDATE daemon_owner SET state = 'none', socket = NULL, last_end_reason = 'record from an older version discarded by disable', last_end_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE gen = $seen_gen AND executor_pid = $seen_pid AND executor_boot_id = '$seen_boot' AND state = 'ready';"
          state="$(agmsg_sqlite "$INSTALL_DB" "SELECT state FROM daemon_owner;" 2>/dev/null || true)"
        fi ;;
    esac
  fi
  if [ "$state" != "none" ]; then
    echo "agmsg daemon disable: service was unregistered but agmsgd has not confirmed stopping -- check 'agmsg daemon status'" >&2
    return 1
  fi
  echo 'agmsg daemon disable: agmsgd turned off. Existing bridges continue to deliver notices; new Codex launches get a bridge.'
  echo 'Codex sessions without a bridge must be restarted. Until then they receive no new notices; unread messages are preserved. Restart with codex resume, then enter $agmsg actas <name> in that Codex session.'
  echo 'Notices already accepted by the Codex queue are not cancelled and may appear once more.'
  agmsg_daemon_seat_report disable
  _path_hint disable
}

# `agmsg daemon offer <type>` -- read-only. One line saying whether the delivery
# choice screen should offer agmsgd for this agent type:
#   agmsgd=on                       turned on and running; do not ask again
#   agmsgd=not-running reason=...   turned on, but not confirmed running
#   agmsgd=available                enable would go ahead
#   agmsgd=unavailable reason=...   enable would refuse (or does not apply)
# It changes nothing, and never enables anything.
cmd_offer() {
  local type="${1:-}" desired node_path found
  case "$type" in
    claude-code|codex) ;;
    *) echo "agmsgd=unavailable reason=agmsgd does not deliver to $type sessions"; return 0 ;;
  esac
  desired="$(sqlite3 -readonly -cmd '.timeout 100' "$INSTALL_DB" 'SELECT desired FROM daemon_intent;' 2>/dev/null | tr -d '\r' || true)"
  if [ "$desired" = on ]; then
    # Turned on is an intent, not proof that notices are being delivered:
    # a failed start or a stopped executor leaves it on with nothing running.
    local AGMSGD_DESIRED AGMSGD_HEALTH AGMSGD_REASON
    agmsg_daemon_read_state
    if [ "${AGMSGD_HEALTH:-}" = ready ]; then
      echo "agmsgd=on"
    else
      echo "agmsgd=not-running reason=${AGMSGD_REASON:-agmsgd is turned on but is not confirmed running}"
    fi
    return 0
  fi
  if [ "$(_os)" = linux ] && ! _systemd_user_usable; then
    echo "agmsgd=unavailable reason=systemd user services are not available here, so agmsgd cannot start on its own"
    return 0
  fi
  node_path="$(_resolve_node node)" || {
    echo "agmsgd=unavailable reason=agmsgd needs Node 22.13 or newer with node:sqlite, and none was found"
    return 0
  }
  if ! "$node_path" "$SCRIPT_DIR/daemon/channels/storage-gate.mjs" >/dev/null 2>&1; then
    echo "agmsgd=unavailable reason=agmsgd reads only the sqlite message storage, and this install uses another storage"
    return 0
  fi
  if [ "$type" = codex ] && [ "$(_os)" = windows ]; then
    found="$("$node_path" --input-type=module -e '
      const { checkWindowsCodexQueueGate } = await import(process.argv[1]);
      const gate = checkWindowsCodexQueueGate({ executable: "codex" });
      console.log(gate.state === "ok" ? "ok" : gate.reason);
    ' "file://$(cd "$SCRIPT_DIR/daemon/channels" && pwd -W 2>/dev/null || pwd)/windows-codex-queue.mjs" 2>/dev/null | tr -d '\r')" || found="windows_codex_version_unreadable"
    if [ "$found" != ok ]; then
      echo "agmsgd=unavailable reason=agmsgd needs Codex 0.157 or newer on Windows ($found)"
      return 0
    fi
  fi
  echo "agmsgd=available"
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  stop) cmd_stop ;;
  status) shift; cmd_status "$@" ;;
  enable) cmd_enable ;;
  disable) cmd_disable ;;
  offer) shift; cmd_offer "$@" ;;
  *) _usage; exit 2 ;;
esac
