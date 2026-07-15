#!/usr/bin/env bash
# compat.sh — Platform compatibility shim for agmsg on MSYS2/Windows.
#
# MSYS2's ps does not support POSIX -o flags (ppid=, args=, comm=), uuidgen
# may be absent, and stat flags differ across platforms. This shim provides
# portable wrappers so the rest of the scripts need not branch per-platform.
#
# Usage: source this file early; call _agmsg_detect_platform (or let the
#        wrappers lazy-init it), then use compat_* functions.

_agmsg_platform=""

_agmsg_detect_platform() {
  [ -n "$_agmsg_platform" ] && return
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) _agmsg_platform="msys"  ;;
    Darwin*)               _agmsg_platform="macos" ;;
    *)                     _agmsg_platform="linux" ;;
  esac
}

# Get parent PID of a process.  Replaces: ps -o ppid= -p <pid>
compat_get_ppid() {
  local pid="$1"
  [ -z "$pid" ] && return 1
  _agmsg_detect_platform
  case "$_agmsg_platform" in
    msys)
      ps -l -p "$pid" 2>/dev/null | awk '
        NR==1 { for (i = 1; i <= NF; i++) if ($i == "PPID") col = i; next }
        NR==2 && col { print $col }
      '
      ;;
    *)
      ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' '
      ;;
  esac
}

# Get Windows PID (WINPID) for an MSYS2 process.  Internal helper.
_compat_get_winpid() {
  local pid="$1"
  ps -l -p "$pid" 2>/dev/null | awk '
    NR==1 { for (i = 1; i <= NF; i++) if ($i == "WINPID") col = i; next }
    NR==2 && col { print $col }
  '
}

# Public PID-domain helpers.  MSYS PIDs and native Windows PIDs are different
# namespaces; callers must choose explicitly instead of feeding an unknown PID
# to a best-effort generic probe.
compat_msys_pid_to_winpid() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  case "$pid" in *[!0-9]*) return 1 ;; esac
  _agmsg_detect_platform
  if [ "$_agmsg_platform" = "msys" ]; then
    _compat_get_winpid "$pid"
  else
    printf '%s\n' "$pid"
  fi
}

compat_pid_alive_msys() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  case "$pid" in *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

compat_pid_state_native() {
  local pid="$1"
  [ -n "$pid" ] || { echo unknown; return 0; }
  case "$pid" in *[!0-9]*) echo unknown; return 0 ;; esac
  _agmsg_detect_platform
  if [ "$_agmsg_platform" = "msys" ]; then
    local output status
    if output="$(MSYS_NO_PATHCONV=1 tasklist.exe /FI "PID eq $pid" /FO CSV /NH 2>&1)"; then
      status=0
    else
      status=$?
    fi
    if [ "$status" -ne 0 ]; then
      # tasklist can be disabled by policy while CIM remains available. Query a
      # fixed, validated property as the secondary signal; failure of both is
      # unknown and must never authorize cleanup or duplicate startup.
      local cim_pid
      if cim_pid="$(_compat_cim_property "$pid" ProcessId 2>/dev/null)"; then
        cim_pid="$(printf '%s' "$cim_pid" | tr -d '[:space:]')"
        if [ "$cim_pid" = "$pid" ]; then echo alive; else echo dead; fi
      else
        echo unknown
      fi
      return 0
    fi
    if printf '%s\n' "$output" | tr -d '\r' \
      | awk -F',' -v wanted="$pid" '{ gsub(/^"|"$/, "", $2); if ($2 == wanted) found=1 } END { exit !found }'; then
      echo alive
    else
      echo dead
    fi
  else
    if kill -0 "$pid" 2>/dev/null; then
      echo alive
    elif ps -p "$pid" >/dev/null 2>&1; then
      echo alive
    else
      echo dead
    fi
  fi
}

compat_pid_alive_native() {
  [ "$(compat_pid_state_native "$1")" = alive ]
}

# Query a single Win32_Process property.  Property names are fixed by callers;
# reject anything else so this helper can never become a PowerShell injection
# surface.
_compat_cim_property() {
  local winpid="$1" property="$2" output status
  [ -n "$winpid" ] || return 1
  case "$winpid" in *[!0-9]*) return 1 ;; esac
  case "$property" in CommandLine|CreationDate|ParentProcessId|ProcessId) ;; *) return 1 ;; esac
  [ -z "${_AGMSG_COMPAT_NO_CIM:-}" ] || return 1
  _agmsg_detect_platform
  [ "$_agmsg_platform" = "msys" ] || return 1
  if output="$(powershell.exe -NoProfile -Command \
    "\$ErrorActionPreference='Stop'; (Get-CimInstance Win32_Process -Filter \"ProcessId=$winpid\" -ErrorAction Stop).$property" \
    2>/dev/null)"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] || return "$status"
  printf '%s\n' "$output" | tr -d '\r'
}

# Query Windows CIM for the full command line of a process by WINPID.
_compat_cim_cmdline() {
  local winpid="$1"
  [ -n "$winpid" ] || return 1
  case "$winpid" in *[!0-9]*) return 1 ;; esac
  [ -z "${_AGMSG_COMPAT_NO_CIM:-}" ] || return 1
  _compat_cim_property "$winpid" CommandLine | tr '\\' '/'
}

compat_native_creation_date() {
  _compat_cim_property "$1" CreationDate
}

compat_native_parent_pid() {
  _compat_cim_property "$1" ParentProcessId
}

# Get full command line of a process.  Replaces: ps -o args= -p <pid>
compat_get_cmdline() {
  local pid="$1"
  [ -z "$pid" ] && return 1
  _agmsg_detect_platform
  case "$_agmsg_platform" in
    msys)
      if [ -z "${_AGMSG_COMPAT_NO_PROC:-}" ] && [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null
      else
        local winpid cim_result
        winpid=$(_compat_get_winpid "$pid")
        if [ -n "$winpid" ]; then
          cim_result=$(_compat_cim_cmdline "$winpid" || true)
          if [ -n "$cim_result" ]; then
            printf '%s' "$cim_result"
            return
          fi
        fi
        ps -l -p "$pid" 2>/dev/null | awk 'NR==2{print $NF}'
      fi
      ;;
    *)
      ps -o args= -p "$pid" 2>/dev/null
      ;;
  esac
}

# Get the bare command name of a process.  Replaces: ps -o comm= -p <pid>
compat_get_comm() {
  local pid="$1"
  [ -z "$pid" ] && return 1
  _agmsg_detect_platform
  case "$_agmsg_platform" in
    msys)
      if [ -z "${_AGMSG_COMPAT_NO_PROC:-}" ] && [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -1 | xargs basename 2>/dev/null
      else
        local winpid cim_result
        winpid=$(_compat_get_winpid "$pid")
        if [ -n "$winpid" ]; then
          cim_result=$(_compat_cim_cmdline "$winpid" || true)
          if [ -n "$cim_result" ]; then
            local _exe
            _exe=$(printf '%s\n' "$cim_result" | head -1 | sed 's/^"\([^"]*\)".*/\1/; t; s/ .*//')
            basename "$_exe" 2>/dev/null | sed 's/\.exe$//'
            return
          fi
        fi
        ps -l -p "$pid" 2>/dev/null | awk 'NR==2{print $NF}' | xargs basename 2>/dev/null
      fi
      ;;
    *)
      ps -o comm= -p "$pid" 2>/dev/null | xargs basename 2>/dev/null
      ;;
  esac
}

# Generate a UUID.  Replaces: uuidgen
compat_uuidgen() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    sqlite3 :memory: "SELECT lower(
      hex(randomblob(4)) || '-' ||
      hex(randomblob(2)) || '-4' ||
      substr(hex(randomblob(2)),2) || '-' ||
      substr('89ab', abs(random()) % 4 + 1, 1) ||
      substr(hex(randomblob(2)),2) || '-' ||
      hex(randomblob(6)));"
  fi | tr -d '\r'
}

# Get file modification time as epoch seconds.
# Replaces: stat -f %m (macOS) / stat -c %Y (Linux/MSYS2)
compat_file_mtime() {
  local file="$1"
  [ -z "$file" ] && return 1
  _agmsg_detect_platform
  case "$_agmsg_platform" in
    macos)  stat -f %m "$file" 2>/dev/null ;;
    *)      stat -c %Y "$file" 2>/dev/null ;;
  esac
}
