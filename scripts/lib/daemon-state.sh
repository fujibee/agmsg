#!/usr/bin/env bash
# Read-only daemon health, shared by ordinary operations, the shim and doctor.
# Resolve from this install, never from the message-storage override.
[ -n "${_AGMSG_DAEMON_STATE_SH:-}" ] && return 0
_AGMSG_DAEMON_STATE_SH=1
_AGMSG_DAEMON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/instance-id.sh"

agmsg_daemon_read_state() {
  AGMSGD_DESIRED=unknown; AGMSGD_HEALTH=unknown; AGMSGD_REASON="install record unavailable"
  local row state pid boot recorded_start current_boot process_start started_epoch
  [ -f "$_AGMSG_DAEMON_ROOT/run/install.db" ] || return 0
  # One sqlite invocation, read-only, bounded when another writer is busy.
  row="$(sqlite3 -readonly -cmd '.timeout 100' -separator $'\t' "$_AGMSG_DAEMON_ROOT/run/install.db" "
    SELECT COALESCE(i.desired,'unset'), o.state, COALESCE(o.executor_pid,0),
      COALESCE(o.executor_boot_id,'-'), COALESCE(o.executor_started_at,'-'),
      replace(replace(replace(COALESCE(
        (SELECT reason FROM daemon_start_attempts WHERE at > COALESCE(o.last_end_at,'') ORDER BY at DESC, rowid DESC LIMIT 1),
        o.last_end_reason, 'executor unavailable'),char(9),' '),char(10),' '),char(13),' ')
    FROM daemon_owner o CROSS JOIN daemon_intent i;
  " 2>/dev/null)" || return 0
  [ -n "$row" ] || return 0
  IFS=$'\t' read -r AGMSGD_DESIRED state pid boot recorded_start AGMSGD_REASON <<< "$row"
  AGMSGD_HEALTH=stopped
  [ "$state" = ready ] || { AGMSGD_REASON="$state: $AGMSGD_REASON"; return 0; }
  case "$pid" in ''|*[!0-9]*|0|1) return 0 ;; esac
  case "$(uname -s)" in
    Darwin)
      current_boot="$(sysctl -n kern.bootsessionuuid 2>/dev/null)" || current_boot=""
      process_start="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null)" || process_start=""
      started_epoch="$(LC_ALL=C date -j -f '%a %b %e %T %Y' "$process_start" +%s 2>/dev/null)" || started_epoch=""
      ;;
    Linux)
      current_boot="$(sed -n 's/^btime //p' /proc/stat 2>/dev/null)"
      local proc_stat ticks hz
      proc_stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || proc_stat=""
      ticks="$(printf '%s' "${proc_stat##*) }" | awk '{print $20}')"
      hz="$(getconf CLK_TCK 2>/dev/null)" || hz=""
      started_epoch=""
      case "$ticks:$hz:$current_boot" in *[!0-9:]*|:*|*::*|*:) ;; *)
        [ "$hz" -gt 0 ] && started_epoch=$((current_boot + ticks / hz)) ;;
      esac
      ;;
    MINGW*|MSYS*|CYGWIN*)
      # Git Bash has no boot id or process start time to read. Ask the daemon's
      # own judgement (the one `agmsg daemon status` gives) through the node it
      # runs on, instead of repeating that evidence in shell.
      local node_path verdict
      node_path="$(sqlite3 -readonly -cmd '.timeout 100' "$_AGMSG_DAEMON_ROOT/run/install.db" 'SELECT node_path FROM meta;' 2>/dev/null | tr -d '\r')" || node_path=""
      if [ -z "$node_path" ] || [ ! -x "$node_path" ] || [ ! -f "$_AGMSG_DAEMON_ROOT/scripts/daemon/liveness.mjs" ]; then
        AGMSGD_HEALTH=unchecked
        AGMSGD_REASON="the daemon's node cannot be run from here to check it"
        return 0
      fi
      verdict="$("$node_path" "$_AGMSG_DAEMON_ROOT/scripts/daemon/liveness.mjs" "$pid" "$boot" 2>/dev/null | tr -d '\r')" || verdict=""
      case "$verdict" in
        alive) AGMSGD_HEALTH=ready; AGMSGD_REASON="" ;;
        dead) AGMSGD_REASON="executor missing or boot/start evidence does not match ($AGMSGD_REASON)" ;;
        *) AGMSGD_HEALTH=unchecked; AGMSGD_REASON="the executor's liveness cannot be read from here" ;;
      esac
      return 0
      ;;
    *) AGMSGD_REASON="platform liveness check unavailable"; return 0 ;;
  esac
  # A macOS record written before the boot id became kern.bootsessionuuid
  # holds kern.boottime seconds, which the kernel shifts when the clock is
  # stepped. While its pid still exists it can be neither confirmed nor
  # refuted.
  if [ "$(uname -s)" = Darwin ] && [ -n "$current_boot" ] && [ "$current_boot" != "$boot" ]; then
    case "$boot" in ''|*[!0-9]*) ;; *)
      if _agmsg_pid_alive "$pid"; then
        AGMSGD_HEALTH=unverifiable
        return 0
      fi ;;
    esac
  fi
  # Evidence that could not be gathered is not evidence of a mismatch. A
  # sandboxed caller (an app that runs commands in its own sandbox) may be
  # denied the boot id, the process start time and even the liveness signal;
  # unless the pid is clearly gone, say the check is unavailable, not stopped.
  # A boot id that can be read and differs from the record is proof, whatever
  # else cannot be read: that executor is from another boot.
  if [ -n "$current_boot" ] && [ "$current_boot" != "$boot" ]; then
    AGMSGD_REASON="executor missing or boot/start evidence does not match ($AGMSGD_REASON)"
    return 0
  fi
  # Likewise a readable start time later than the owner's claim: a reused pid.
  local claim_epoch
  case "$recorded_start" in
    ????-??-??T??:??:??*)
      case "$(uname -s)" in
        Darwin) claim_epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "${recorded_start:0:19}" +%s 2>/dev/null)" || claim_epoch="" ;;
        Linux) claim_epoch="$(date -u -d "$recorded_start" +%s 2>/dev/null)" || claim_epoch="" ;;
      esac ;;
    *) claim_epoch="" ;;
  esac
  if [ -n "$started_epoch" ] && [ -n "$claim_epoch" ] && [ "$started_epoch" -gt "$claim_epoch" ]; then
    AGMSGD_REASON="executor start evidence does not match ($AGMSGD_REASON)"
    return 0
  fi
  if [ -z "$current_boot" ] || [ -z "$started_epoch" ]; then
    case "$(_agmsg_pid_signal_presence "$pid")" in
      gone) ;;
      *)
        AGMSGD_HEALTH=unchecked
        AGMSGD_REASON="the boot id or process start time cannot be read from here"
        return 0 ;;
    esac
  fi
  if [ -z "$current_boot" ] || [ "$current_boot" != "$boot" ] || [ -z "$started_epoch" ]; then
    AGMSGD_REASON="executor missing or boot/start evidence does not match ($AGMSGD_REASON)"
    return 0
  fi
  if [ -z "$claim_epoch" ] || [ "$started_epoch" -gt "$claim_epoch" ]; then
    AGMSGD_REASON="executor start evidence does not match ($AGMSGD_REASON)"
    return 0
  fi
  local process_state
  process_state="$(ps -p "$pid" -o stat= 2>/dev/null)" || process_state=""
  case "$process_state" in ''|*Z*|*T*) AGMSGD_REASON="executor exited or suspended ($AGMSGD_REASON)"; return 0 ;; esac
  AGMSGD_HEALTH=ready
  AGMSGD_REASON=""
}

# rc 0 when agmsgd last saw this seat's Claude Code hold its nudge, for the
# very socket given: a held nudge never reaches the model, so native delivery
# must not be claimed for that session. A different socket is a new session
# that has not been tried yet, so it is not held. Unreadable means not held.
agmsg_daemon_claude_seat_held() {   # <team> <agent> <socket>
  local t="${1//\'/\'\'}" a="${2//\'/\'\'}" sock="${3//\'/\'\'}" n
  [ -f "$_AGMSG_DAEMON_ROOT/run/install.db" ] || return 1
  n="$(sqlite3 -readonly -cmd '.timeout 100' "$_AGMSG_DAEMON_ROOT/run/install.db" "
    SELECT count(*) FROM beta_claude_seat WHERE seat = json_array('$t','$a')
      AND state = 'blocked' AND reason LIKE 'peer_held%' AND messaging_socket = '$sock';
  " 2>/dev/null | tr -d '\r')" || return 1
  [ "$n" = 1 ]
}

agmsg_daemon_recovery_text() {
  if [ "$AGMSGD_HEALTH" = unchecked ]; then
    printf 'agmsgd (Codex notices) could not be checked from this environment (%s). It may be running; nothing needs to be done unless notices stop arriving.\n' "$AGMSGD_REASON"
    return 0
  fi
  if [ "$AGMSGD_HEALTH" = unverifiable ]; then
    printf 'agmsgd (Codex notices) was recorded by an older version, so whether it is still running cannot be checked. Run agmsg daemon stop and then agmsg daemon start to update the record. Unread messages are preserved. If agmsg is not found, use "%s/scripts/agmsg" daemon stop.\n' "$_AGMSG_DAEMON_ROOT"
    return 0
  fi
  printf 'agmsgd (Codex notices) is stopped while enabled (reason: %s). Run agmsg daemon start (recommended), or agmsg daemon disable and restart your Codex sessions. Unread messages are preserved.' "$AGMSGD_REASON"
  case "$AGMSGD_REASON" in *Node*|*node*)
    printf ' Install Node >= 22.13.0 from https://nodejs.org/en/download, then run agmsg daemon enable.' ;;
  esac
  printf ' If agmsg is not found, use "%s/scripts/agmsg" daemon start (replace start with disable or enable as needed).\n' "$_AGMSG_DAEMON_ROOT"
}

agmsg_daemon_warn_if_stopped() {
  # Keep health state local without forking a shell that inherits caller FDs.
  local AGMSGD_DESIRED AGMSGD_HEALTH AGMSGD_REASON
  local now last=0 marker slot updating=0
  marker="$_AGMSG_DAEMON_ROOT/run/agmsgd-warning-at"
  # install --update is restarting the daemon right now (see
  # agmsg_install_restart_daemon): it is not stopped, so say nothing. The
  # marker is only believed for two minutes; after that, or once the update
  # removes it, a daemon that did not come back warns as usual.
  if [ -f "$_AGMSG_DAEMON_ROOT/run/agmsgd-updating" ]; then
    IFS= read -r updating < "$_AGMSG_DAEMON_ROOT/run/agmsgd-updating" || updating=0
    case "$updating" in ''|*[!0-9]*) updating=0 ;; esac
    now="$(date +%s)" || now=0
    # Only a readable clock and a timestamp not in the future count.
    if [ "$now" -gt 0 ] && [ "$updating" -gt 0 ] \
      && [ "$((now - updating))" -ge 0 ] && [ "$((now - updating))" -lt 120 ]; then
      return 0
    fi
  fi
  if [ "${1:-}" != always ]; then
    now="$(date +%s)" || return 0
    [ ! -f "$marker" ] || IFS= read -r last < "$marker" || last=0
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    # Already warned: skip SQLite and process liveness checks entirely.
    [ "$((now - last))" -ge 600 ] || return 0
  fi
  agmsg_daemon_read_state
  [ "$AGMSGD_DESIRED" = on ] && [ "$AGMSGD_HEALTH" != ready ] || return 0
  # Not being able to look is not a stop: say nothing on ordinary commands.
  [ "$AGMSGD_HEALTH" != unchecked ] || [ "${1:-}" = always ] || return 0
  if [ "${1:-}" = always ]; then
    agmsg_daemon_recovery_text >&2
    return 0
  fi
  # Atomic claim per time window; reread the rolling timestamp after claiming.
  # Concurrent claims across a boundary can still emit twice (beta limitation).
  # A killed claimant can suppress at most this window, never all future ones.
  slot="$_AGMSG_DAEMON_ROOT/run/agmsgd-warning-slot.$((now / 600))"
  mkdir "$slot" 2>/dev/null || return 0
  [ ! -f "$marker" ] || IFS= read -r last < "$marker" || last=0
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$((now - last))" -ge 600 ]; then
    printf '%s\n' "$now" > "$slot/at" || return 0
    mv "$slot/at" "$marker" || return 0
    agmsg_daemon_recovery_text >&2
  fi
  # The claimed window remains as an empty directory. Only past windows are
  # removed; none of them can grant a fresh claim in the current window.
  local old old_window
  for old in "$_AGMSG_DAEMON_ROOT/run/"agmsgd-warning-slot.*; do
    [ -d "$old" ] || continue
    old_window="${old##*.}"
    case "$old_window" in ''|*[!0-9]*) continue ;; esac
    [ "$old_window" -lt "$((now / 600))" ] && rmdir "$old" 2>/dev/null || true
  done
  return 0
}

# A project's explicit delivery choice, written only by `agmsg delivery <value>`
# as a line "<type><TAB><canonical project><TAB><value>" in run/delivery-choice.
# No line means nobody chose (an install updated from before, or a project that
# never saw the choice screen): agmsgd delivers as it always has. A value other
# than "agmsgd" (monitor, turn, both, off) is a decision not to use agmsgd for
# that project.
agmsg_delivery_choice_get() {   # <type> <project>
  local file="$_AGMSG_DAEMON_ROOT/run/delivery-choice" project="$2"
  [ -r "$file" ] && [ -n "$project" ] || return 0
  project="$(cd -- "$project" 2>/dev/null && pwd -P)" || project="$2"
  awk -F'\t' -v t="$1" -v p="$project" '$1 == t && $2 == p { c = $3 } END { if (c != "") print c }' "$file" 2>/dev/null
}

# Make this project read as agmsgd-off when it chose something other than agmsgd,
# so every caller that asks "does agmsgd deliver here" gets the project's answer.
# Call right after agmsg_daemon_read_state, in the same scope.
agmsg_daemon_apply_project_choice() {   # <type> <project>
  local choice
  choice="$(agmsg_delivery_choice_get "$1" "${2:-}")"
  case "$choice" in
    ''|agmsgd) return 0 ;;
  esac
  AGMSGD_DESIRED=off
  AGMSGD_HEALTH=stopped
  AGMSGD_REASON="this project chose $choice, not agmsgd"
}
