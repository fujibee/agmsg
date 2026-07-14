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

codex_lease_atomic_write() { # <path>, content on stdin
  local path="$1" tmp
  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp "$(dirname "$path")/.codex-lease.XXXXXX")" || return 1
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
  {
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
  } | codex_lease_atomic_write "$path"
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
  printf 'generation=%s\nupdated_at=%s\n' "$3" "$(date +%s)" | codex_lease_atomic_write "$path"
  printf '%s\n' "$path"
}

codex_appserver_ref_replace() { # hash old_path ref_name generation
  local hash="$1" old_path="$2" ref_name="$3" generation="$4" dir path
  codex_lifecycle_lock_acquire "$hash" || return 1
  dir="$(codex_appserver_refs_dir "$hash")"
  mkdir -p "$dir"
  path="$dir/$(codex_lease_encode "$ref_name")"
  printf 'generation=%s\nupdated_at=%s\n' "$generation" "$(date +%s)" | codex_lease_atomic_write "$path"
  if [ -n "$old_path" ] && [ "$old_path" != "$path" ]; then rm -f "$old_path"; fi
  codex_lifecycle_lock_release "$hash"
  printf '%s\n' "$path"
}

codex_appserver_ref_remove_and_cleanup() { # hash ref_path expected_generation
  local hash="$1" ref_path="$2" expected_generation="$3" refs record generation pid domain cmd
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
    if [ -n "$pid" ] && codex_pid_alive_domain "$domain" "$pid"; then
      cmd="$(codex_pid_cmdline_domain "$domain" "$pid" 2>/dev/null || true)"
      case "$cmd" in *codex*app-server*) codex_pid_kill_domain "$domain" "$pid" || true ;; esac
    fi
    rm -f "$record" "$RUN_DIR/codex-app-server.$hash.pid" \
      "$RUN_DIR/codex-app-server.$hash.port" "$RUN_DIR/codex-app-server.$hash.version"
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
