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

# Query Windows CIM for the full command line of a process by WINPID.
_compat_cim_cmdline() {
  local winpid="$1"
  [ -n "$winpid" ] || return 1
  case "$winpid" in *[!0-9]*) return 1 ;; esac
  [ -z "${_AGMSG_COMPAT_NO_CIM:-}" ] || return 1
  powershell.exe -NoProfile -Command \
    "(Get-CimInstance Win32_Process -Filter \"ProcessId=$winpid\").CommandLine" 2>/dev/null \
    | tr -d '\r' | tr '\\' '/'
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
      # `ps -o comm=` prints the executable path on macOS. Piping it through
      # `xargs basename` splits that path on whitespace (and eats quotes), so a
      # binary under e.g. "~/Library/Application Support/..." resolves to
      # "Application". Take the basename of the whole string instead.
      local _comm
      _comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
      [ -n "$_comm" ] || return 1
      basename -- "$_comm" 2>/dev/null
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
