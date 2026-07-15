#!/usr/bin/env bash
# Shared filesystem primitives for the Codex monitor lease protocol.

[ -n "${_AGMSG_CODEX_LEASE_SH:-}" ] && return 0
_AGMSG_CODEX_LEASE_SH=1

: "${SKILL_DIR:?codex-lease.sh requires SKILL_DIR}"
RUN_DIR="${RUN_DIR:-$SKILL_DIR/run}"

# shellcheck source=compat.sh
. "$SKILL_DIR/scripts/lib/compat.sh"
# shellcheck source=hash.sh
. "$SKILL_DIR/scripts/lib/hash.sh"

CODEX_LEASE_FORMAT_VERSION=1

codex_lease_encode() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { for (n = 0; n < 256; n++) ord[sprintf("%c", n)] = n }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c ~ /[A-Za-z0-9._\-]/) printf "%s", c
        else printf "%%%02X", ord[c]
      }
    }
  '
}

codex_lease_generation() {
  local uuid
  uuid="$(compat_uuidgen | tr -cd 'A-Za-z0-9-')"
  printf '%s-%s\n' "$(date +%s)" "$uuid"
}

codex_tui_lease_path() {
  local team="$1" name="$2" thread="$3" generation="$4" thread_hash
  thread_hash="$(printf '%s' "$thread" | agmsg_sha1)"
  printf '%s/codex-tui-lease.%s.%s.%s.%s\n' "$RUN_DIR" \
    "$(codex_lease_encode "$team")" "$(codex_lease_encode "$name")" \
    "$thread_hash" "$(codex_lease_encode "$generation")"
}

codex_bridge_lease_path() {
  printf '%s/codex-bridge-lease.%s.%s\n' "$RUN_DIR" \
    "$(codex_lease_encode "$1")" "$(codex_lease_encode "$2")"
}

codex_monitor_request_path() { # project_hash tui_generation
  printf '%s/codex-bridge-request.%s.%s\n' "$RUN_DIR" "$1" "$(codex_lease_encode "$2")"
}

codex_monitor_state_path() { # project_hash tui_generation
  printf '%s/codex-monitor-state.%s.%s\n' "$RUN_DIR" "$1" "$(codex_lease_encode "$2")"
}

codex_monitor_state_write() { # path phase [detail]
  local path="$1" phase="$2" detail="${3:-}"
  {
    printf 'format_version=1\nphase=%s\n' "$phase"
    printf 'detail=%s\nupdated_at=%s\n' "$detail" "$(date +%s)"
  } | codex_lease_atomic_write "$path"
}

codex_tui_generation_fresh() { # team name generation [timeout]
  local team="$1" name="$2" generation="$3" timeout="${4:-${AGMSG_CODEX_LEASE_TIMEOUT:-15}}"
  local prefix file now updated age
  prefix="$RUN_DIR/codex-tui-lease.$(codex_lease_encode "$team").$(codex_lease_encode "$name")."
  now="$(date +%s)"
  for file in "$prefix"*; do
    [ -f "$file" ] || continue
    [ "$(codex_lease_field "$file" format_version 2>/dev/null || true)" = "$CODEX_LEASE_FORMAT_VERSION" ] || continue
    [ "$(codex_lease_field "$file" owner_kind 2>/dev/null || true)" = tui ] || continue
    [ "$(codex_lease_field "$file" generation 2>/dev/null || true)" = "$generation" ] || continue
    updated="$(codex_lease_field "$file" updated_at 2>/dev/null || true)"
    case "$updated" in ''|*[!0-9]*) continue ;; esac
    age=$((now - updated))
    [ "$age" -ge 0 ] && [ "$age" -le "$timeout" ] && return 0
  done
  return 1
}

codex_tui_lease_file_fresh() { # path [timeout]
  local file="$1" timeout="${2:-${AGMSG_CODEX_LEASE_TIMEOUT:-15}}" updated now age
  [ -f "$file" ] || return 1
  [ "$(codex_lease_field "$file" format_version 2>/dev/null || true)" = "$CODEX_LEASE_FORMAT_VERSION" ] || return 1
  [ "$(codex_lease_field "$file" owner_kind 2>/dev/null || true)" = tui ] || return 1
  updated="$(codex_lease_field "$file" updated_at 2>/dev/null || true)"
  case "$updated" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"; age=$((now - updated))
  [ "$age" -ge 0 ] && [ "$age" -le "$timeout" ]
}

codex_lease_atomic_write() { # <path>, content on stdin
  local path="$1" dir tmp
  dir="${path%/*}"; [ "$dir" != "$path" ] || dir=.
  [ -d "$dir" ] || mkdir -p "$dir"
  tmp="$(mktemp "$dir/.codex-lease.XXXXXX")" || return 1
  if ! cat >"$tmp"; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$path"
}

codex_write_tui_lease() { # team name thread generation project app_server owner_msys_pid
  local team="$1" name="$2" thread="$3" generation="$4" project="$5" app_server="$6" msys_pid="$7"
  local path winpid="" creation="" domain="msys"
  path="$(codex_tui_lease_path "$team" "$name" "$thread" "$generation")"
  if [ -f "$path" ]; then
    winpid="$(codex_lease_field "$path" owner_winpid 2>/dev/null || true)"
    creation="$(codex_lease_field "$path" owner_creation 2>/dev/null || true)"
  else
    winpid="$(compat_msys_pid_to_winpid "$msys_pid" 2>/dev/null || true)"
  fi
  if [ -n "$winpid" ]; then
    domain="both"
    [ -n "$creation" ] || creation="$(compat_native_creation_date "$winpid" 2>/dev/null || true)"
  fi
  if ! {
    printf 'format_version=%s\n' "$CODEX_LEASE_FORMAT_VERSION"
    printf 'owner_kind=tui\n'
    printf 'pid_domain=%s\n' "$domain"
    printf 'owner_msys_pid=%s\n' "$msys_pid"
    printf 'owner_winpid=%s\n' "$winpid"
    printf 'owner_creation=%s\n' "$creation"
    printf 'generation=%s\n' "$generation"
    printf 'project=%s\n' "$project"
    printf 'thread=%s\n' "$thread"
    printf 'app_server=%s\n' "$app_server"
    printf 'updated_at=%s\n' "$(date +%s)"
  } | codex_lease_atomic_write "$path"; then
    return 1
  fi
  printf '%s\n' "$path"
}

codex_lease_field() {
  local path="$1" key="$2"
  [ -f "$path" ] || return 1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$path" 2>/dev/null
}

codex_lease_compare_delete() { # path generation
  local path="$1" generation="$2" current
  [ -f "$path" ] || return 0
  current="$(codex_lease_field "$path" generation 2>/dev/null || true)"
  [ "$current" = "$generation" ] && rm -f "$path"
  return 0
}

codex_appserver_refs_dir() { printf '%s/codex-app-server.%s.refs\n' "$RUN_DIR" "$1"; }
codex_appserver_lock_dir() { printf '%s/codex-app-server.%s.lifecycle.lock\n' "$RUN_DIR" "$1"; }
codex_appserver_record_path() { printf '%s/codex-app-server.%s.record\n' "$RUN_DIR" "$1"; }
codex_appserver_marker_path() { printf '%s/codex-app-server.%s.spawning.%s\n' "$RUN_DIR" "$1" "$2"; }

codex_record_write_starting() { # hash generation version starter_msys_pid
  local hash="$1" generation="$2" version="$3" starter_pid="$4" path winpid=""
  path="$(codex_appserver_record_path "$hash")"
  winpid="$(compat_msys_pid_to_winpid "$starter_pid" 2>/dev/null || true)"
  {
    printf 'format_version=1\nstatus=starting\n'
    printf 'generation=%s\nversion=%s\n' "$generation" "$version"
    printf 'starter_pid_domain=msys\nstarter_msys_pid=%s\nstarter_winpid=%s\n' "$starter_pid" "$winpid"
    printf 'pid=\nport=\nupdated_at=%s\n' "$(date +%s)"
  } | codex_lease_atomic_write "$path"
}

codex_record_write_ready() { # hash generation version pid_domain pid port
  local hash="$1" generation="$2" version="$3" pid_domain="$4" pid="$5" port="$6"
  local path creation=""
  path="$(codex_appserver_record_path "$hash")"
  creation="$(codex_pid_creation_domain "$pid_domain" "$pid" 2>/dev/null || true)"
  {
    printf 'format_version=1\nstatus=ready\n'
    printf 'generation=%s\nversion=%s\n' "$generation" "$version"
    printf 'starter_pid_domain=\nstarter_msys_pid=\nstarter_winpid=\n'
    printf 'pid_domain=%s\npid=%s\npid_creation=%s\nport=%s\nupdated_at=%s\n' \
      "$pid_domain" "$pid" "$creation" "$port" "$(date +%s)"
  } | codex_lease_atomic_write "$path"
}

codex_marker_write() { # hash generation pid_domain pid log_path
  local hash="$1" generation="$2" pid_domain="$3" pid="$4" log_path="$5" path creation=""
  path="$(codex_appserver_marker_path "$hash" "$generation")"
  creation="$(codex_pid_creation_domain "$pid_domain" "$pid" 2>/dev/null || true)"
  {
    printf 'format_version=1\ngeneration=%s\n' "$generation"
    printf 'spawned_pid_domain=%s\nspawned_pid=%s\nspawned_creation=%s\n' "$pid_domain" "$pid" "$creation"
    printf 'log_path=%s\nupdated_at=%s\n' "$log_path" "$(date +%s)"
  } | codex_lease_atomic_write "$path"
}

codex_pid_alive_domain() {
  case "$1" in
    msys) compat_pid_alive_msys "$2" ;;
    native) compat_pid_alive_native "$2" ;;
    *) return 1 ;;
  esac
}

codex_pid_state_domain() {
  case "$1" in
    msys) if compat_pid_alive_msys "$2"; then echo alive; else echo dead; fi ;;
    native) compat_pid_state_native "$2" ;;
    *) echo unknown ;;
  esac
}

codex_pid_creation_domain() {
  local domain="$1" pid="$2" winpid
  case "$domain" in
    msys)
      winpid="$(compat_msys_pid_to_winpid "$pid" 2>/dev/null || true)"
      [ -n "$winpid" ] || return 1
      compat_native_creation_date "$winpid"
      ;;
    native) compat_native_creation_date "$pid" ;;
    *) return 1 ;;
  esac
}

codex_pid_cmdline_domain() {
  local domain="$1" pid="$2"
  case "$domain" in
    msys) compat_get_cmdline "$pid" ;;
    native)
      _agmsg_detect_platform
      if [ "$_agmsg_platform" = "msys" ]; then _compat_cim_cmdline "$pid"; else compat_get_cmdline "$pid"; fi
      ;;
    *) return 1 ;;
  esac
}

codex_pid_kill_domain() {
  local domain="$1" pid="$2"
  case "$domain" in
    msys) kill "$pid" 2>/dev/null ;;
    native)
      _agmsg_detect_platform
      if [ "$_agmsg_platform" = "msys" ]; then
        MSYS_NO_PATHCONV=1 taskkill.exe /PID "$pid" /T >/dev/null 2>&1
      else
        kill "$pid" 2>/dev/null
      fi
      ;;
    *) return 1 ;;
  esac
}

codex_appserver_ref_add() { # hash ref_name generation
  local dir path
  dir="$(codex_appserver_refs_dir "$1")"
  mkdir -p "$dir"
  path="$dir/$(codex_lease_encode "$2")"
  if ! printf 'generation=%s\nupdated_at=%s\n' "$3" "$(date +%s)" \
    | codex_lease_atomic_write "$path"; then
    return 1
  fi
  printf '%s\n' "$path"
}

# Reserve this ready app-server for a TUI before its first SessionStart supplies
# an exact thread id. Without this provisional ref, closing a newly opened TUI
# before its first turn leaves an unreferenced shared app-server behind; and a
# different TUI cannot safely decide whether it is the last user. The launcher
# replaces this ref atomically with its generation-specific TUI-lease ref.
codex_appserver_ref_add_provisional() { # hash ref_name server_generation tui_generation owner_msys_pid
  local hash="$1" ref_name="$2" generation="$3" tui_generation="$4" owner_msys="$5"
  local record current_generation status dir path owner_winpid
  codex_lifecycle_lock_acquire "$hash" || return 1
  record="$(codex_appserver_record_path "$hash")"
  status="$(codex_lease_field "$record" status 2>/dev/null || true)"
  current_generation="$(codex_lease_field "$record" generation 2>/dev/null || true)"
  if [ "$status" != ready ] || [ -z "$generation" ] || [ "$current_generation" != "$generation" ]; then
    codex_lifecycle_lock_release "$hash"
    return 1
  fi
  dir="$(codex_appserver_refs_dir "$hash")"; mkdir -p "$dir"
  path="$dir/$(codex_lease_encode "$ref_name")"
  owner_winpid="$(compat_msys_pid_to_winpid "$owner_msys" 2>/dev/null || true)"
  if ! {
    printf 'generation=%s\nref_kind=startup\nlease_generation=%s\n' "$generation" "$tui_generation"
    printf 'owner_msys_pid=%s\nowner_winpid=%s\nowner_creation=%s\n' \
      "$owner_msys" "$owner_winpid" ""
    printf 'updated_at=%s\n' "$(date +%s)"
  } | codex_lease_atomic_write "$path"; then
    codex_lifecycle_lock_release "$hash"
    return 1
  fi
  codex_lifecycle_lock_release "$hash"
  printf '%s\n' "$path"
}

codex_appserver_ref_replace() { # hash old_path ref_name generation
  local hash="$1" old_path="$2" ref_name="$3" generation="$4" dir path record current_generation status
  local lease_path tui_generation owner_msys owner_winpid owner_creation
  codex_lifecycle_lock_acquire "$hash" || return 1
  record="$(codex_appserver_record_path "$hash")"
  status="$(codex_lease_field "$record" status 2>/dev/null || true)"
  current_generation="$(codex_lease_field "$record" generation 2>/dev/null || true)"
  if [ "$status" != ready ] || [ -z "$current_generation" ] || [ "$current_generation" != "$generation" ]; then
    codex_lifecycle_lock_release "$hash"
    return 1
  fi
  dir="$(codex_appserver_refs_dir "$hash")"
  mkdir -p "$dir"
  path="$dir/$(codex_lease_encode "$ref_name")"
  lease_path="$RUN_DIR/$ref_name"
  tui_generation="$(codex_lease_field "$lease_path" generation 2>/dev/null || true)"
  owner_msys="$(codex_lease_field "$lease_path" owner_msys_pid 2>/dev/null || true)"
  owner_winpid="$(codex_lease_field "$lease_path" owner_winpid 2>/dev/null || true)"
  owner_creation="$(codex_lease_field "$lease_path" owner_creation 2>/dev/null || true)"
  if ! {
    printf 'generation=%s\nlease_name=%s\nlease_generation=%s\n' "$generation" "$ref_name" "$tui_generation"
    printf 'owner_msys_pid=%s\nowner_winpid=%s\nowner_creation=%s\n' "$owner_msys" "$owner_winpid" "$owner_creation"
    printf 'updated_at=%s\n' "$(date +%s)"
  } | codex_lease_atomic_write "$path"; then
    codex_lifecycle_lock_release "$hash"
    return 1
  fi
  if [ -n "$old_path" ] && [ "$old_path" != "$path" ]; then rm -f "$old_path"; fi
  codex_lifecycle_lock_release "$hash"
  printf '%s\n' "$path"
}

# Remove only refs whose new-format ownership proof says both the TUI lease and
# its owning process are gone. Old refs lack that proof and are retained
# fail-closed. This is startup hygiene; it never kills the app-server itself.
codex_appserver_ref_gc() { # hash
  local hash="$1" refs ref ref_kind lease_name lease_path owner_msys owner_winpid owner_creation current_creation native_state
  codex_lifecycle_lock_acquire "$hash" || return 1
  refs="$(codex_appserver_refs_dir "$hash")"
  if [ -d "$refs" ]; then
    for ref in "$refs"/*; do
      [ -f "$ref" ] || continue
      lease_name="$(codex_lease_field "$ref" lease_name 2>/dev/null || true)"
      ref_kind="$(codex_lease_field "$ref" ref_kind 2>/dev/null || true)"
      owner_msys="$(codex_lease_field "$ref" owner_msys_pid 2>/dev/null || true)"
      owner_winpid="$(codex_lease_field "$ref" owner_winpid 2>/dev/null || true)"
      owner_creation="$(codex_lease_field "$ref" owner_creation 2>/dev/null || true)"
      { [ -n "$owner_msys" ] || [ -n "$owner_winpid" ]; } || continue
      if [ "$ref_kind" = startup ]; then
        : # no TUI lease exists yet; process ownership below is authoritative
      else
        case "$lease_name" in codex-tui-lease.*) ;; *) continue ;; esac
        lease_path="$RUN_DIR/$lease_name"
        codex_tui_lease_file_fresh "$lease_path" && continue
      fi
      if [ -n "$owner_msys" ] && compat_pid_alive_msys "$owner_msys"; then continue; fi
      if [ -n "$owner_winpid" ]; then
        native_state="$(compat_pid_state_native "$owner_winpid")"
        [ "$native_state" = unknown ] && continue
        if [ "$native_state" = alive ]; then
          current_creation="$(compat_native_creation_date "$owner_winpid" 2>/dev/null || true)"
          # A live native PID with no comparable creation timestamp is unknown,
          # not dead. Retain the ref; only a proven mismatch means PID reuse.
          if [ -z "$owner_creation" ] || [ -z "$current_creation" ] \
            || [ "$current_creation" = "$owner_creation" ]; then
            continue
          fi
        fi
      fi
      rm -f "$ref"
    done
    rmdir "$refs" 2>/dev/null || true
  fi
  codex_lifecycle_lock_release "$hash"
}

codex_appserver_ref_remove_and_cleanup() { # hash ref_path expected_generation
  local hash="$1" ref_path="$2" expected_generation="$3" refs record generation pid domain cmd remove_record=1 pid_state
  codex_lifecycle_lock_acquire "$hash" || return 1
  rm -f "$ref_path"
  refs="$(codex_appserver_refs_dir "$hash")"
  if find "$refs" -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
    codex_lifecycle_lock_release "$hash"
    return 0
  fi
  record="$(codex_appserver_record_path "$hash")"
  generation="$(codex_lease_field "$record" generation 2>/dev/null || true)"
  if [ -n "$generation" ] && [ "$generation" = "$expected_generation" ]; then
    pid="$(codex_lease_field "$record" pid 2>/dev/null || true)"
    domain="$(codex_lease_field "$record" pid_domain 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      pid_state="$(codex_pid_state_domain "$domain" "$pid")"
      if [ "$pid_state" = unknown ]; then
        remove_record=0
      elif [ "$pid_state" = alive ]; then
        cmd="$(codex_pid_cmdline_domain "$domain" "$pid" 2>/dev/null || true)"
        case "$cmd" in
          *codex*app-server*) codex_pid_kill_domain "$domain" "$pid" || remove_record=0 ;;
          *) remove_record=0 ;;
        esac
      fi
    fi
    if [ "$remove_record" -eq 1 ]; then
      rm -f "$record" "$RUN_DIR/codex-app-server.$hash.pid" \
        "$RUN_DIR/codex-app-server.$hash.port" "$RUN_DIR/codex-app-server.$hash.version"
    fi
  fi
  rmdir "$refs" 2>/dev/null || true
  codex_lifecycle_lock_release "$hash"
}

codex_lifecycle_lock_acquire() {
  local project_hash="$1" lock attempts=0 owner mtime now
  lock="$(codex_appserver_lock_dir "$project_hash")"
  while ! mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt "${AGMSG_CODEX_LOCK_ATTEMPTS:-100}" ] || return 1
    owner="$(cat "$lock/owner" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! compat_pid_alive_msys "$owner"; then
      rm -f "$lock/owner" 2>/dev/null || true
      rmdir "$lock" 2>/dev/null || true
    elif [ -z "$owner" ]; then
      # Crash between mkdir and owner publication: reclaim only after a grace
      # period, never while another process may still be filling the directory.
      mtime="$(compat_file_mtime "$lock" 2>/dev/null || true)"
      now="$(date +%s)"
      case "$mtime" in ''|*[!0-9]*) ;; *)
        [ $((now - mtime)) -gt 10 ] && rmdir "$lock" 2>/dev/null || true
        ;;
      esac
    fi
    sleep 0.05
  done
  printf '%s\n' "$$" >"$lock/owner"
}

codex_lifecycle_lock_release() {
  local lock
  lock="$(codex_appserver_lock_dir "$1")"
  rm -f "$lock/owner" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
}
