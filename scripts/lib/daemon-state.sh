#!/usr/bin/env bash
# Read-only daemon health, shared by ordinary operations, the shim and doctor.
# Resolve from this install, never from the message-storage override.
[ -n "${_AGMSG_DAEMON_STATE_SH:-}" ] && return 0
_AGMSG_DAEMON_STATE_SH=1
_AGMSG_DAEMON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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
      current_boot="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\),.*/\1/p')"
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
    *) AGMSGD_REASON="platform liveness check unavailable"; return 0 ;;
  esac
  if [ -z "$current_boot" ] || [ "$current_boot" != "$boot" ] || [ -z "$started_epoch" ]; then
    AGMSGD_REASON="executor missing or boot/start evidence does not match ($AGMSGD_REASON)"
    return 0
  fi
  # The owner records its claim time. A process born after that claim is a
  # reused PID, never evidence that the recorded executor is still running.
  local claim_epoch
  case "$recorded_start" in
    ????-??-??T??:??:??*)
      case "$(uname -s)" in
        Darwin) claim_epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "${recorded_start:0:19}" +%s 2>/dev/null)" || claim_epoch="" ;;
        Linux) claim_epoch="$(date -u -d "$recorded_start" +%s 2>/dev/null)" || claim_epoch="" ;;
      esac ;;
    *) claim_epoch="" ;;
  esac
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

agmsg_daemon_recovery_text() {
  printf 'agmsgd (Codex notices) is stopped while enabled (reason: %s). Run agmsg daemon start (recommended), or agmsg daemon disable and restart your Codex sessions. Unread messages are preserved.' "$AGMSGD_REASON"
  case "$AGMSGD_REASON" in *Node*|*node*)
    printf ' Install Node >= 22.13.0 from https://nodejs.org/en/download, then run agmsg daemon enable.' ;;
  esac
  printf ' If agmsg is not found, use "%s/scripts/agmsg" daemon start (replace start with disable or enable as needed).\n' "$_AGMSG_DAEMON_ROOT"
}

agmsg_daemon_warn_if_stopped() (
  # Subshell keeps any cleanup trap and shell state out of the caller.
  agmsg_daemon_read_state
  [ "$AGMSGD_DESIRED" = on ] && [ "$AGMSGD_HEALTH" != ready ] || return 0
  if [ "${1:-}" = always ]; then
    agmsg_daemon_recovery_text >&2
    return 0
  fi
  local now last=0 marker slot
  now="$(date +%s)" || return 0
  marker="$_AGMSG_DAEMON_ROOT/run/agmsgd-warning-at"
  [ ! -f "$marker" ] || IFS= read -r last < "$marker" || last=0
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$((now - last))" -ge 600 ] || return 0
  # Atomic claim per time window; reread the rolling timestamp after claiming
  # so a boundary does not produce two warnings less than ten minutes apart.
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
)
