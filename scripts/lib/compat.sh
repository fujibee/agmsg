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
# Does <cmdline> name <path>?
#
# It has to be asked as a function because the two sides are written in
# different alphabets and only one of them is ours. `compat_get_cmdline` returns
# what the OS says a process was started with; the path we compare it against
# came out of this shell. Under Git Bash those disagree for the same file:
# `$SKILL_DIR` is `/c/Users/...`, and a native binary launched from it reports
# `C:/Users/...`. A `case` on one against the other never fires -- so every
# check built that way answers "not ours" about a process that IS ours, and
# does it silently, because a non-match is the ordinary answer.
#
# Measured on the reporting machine (#652): the sync engine was alive, its
# `/proc/<pid>/cmdline` read
#   "C:\Program Files\nodejs\node.exe" C:/Users/.../internal/remote-sync.mjs run --team ossb
# while the comparison held /c/Users/.../internal/remote-sync.mjs. Forcing the
# CIM source instead of /proc returned the same `C:/` form, so this is not about
# where the cmdline is read from -- both sources speak Windows.
#
# Five call sites compared a shell path against an OS cmdline this way. Four of
# them decide whether to kill a stale watcher, so on Windows they answered "not
# ours" and left it running.
#
# `cygpath -m` is the mixed form -- `C:/Users/...`, forward slashes -- which is
# what MSYS hands a native binary, and therefore what the process reports.
# Off Windows there is no cygpath and this is the plain match and nothing else,
# the same escape `agmsg_sql_readfile_path` takes.
agmsg_cmdline_names_path() {
  local cmdline="$1" path="$2" native
  [ -n "$cmdline" ] && [ -n "$path" ] || return 1
  case "$cmdline" in *"$path"*) return 0 ;; esac
  command -v cygpath >/dev/null 2>&1 || return 1
  native="$(cygpath -m "$path" 2>/dev/null || true)"
  [ -n "$native" ] || return 1
  # Identical forms would make this second look a copy of the first, not a
  # second chance at it.
  [ "$native" != "$path" ] || return 1
  case "$cmdline" in *"$native"*) return 0 ;; esac
  return 1
}

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

# Generate a UUIDv7: 48-bit millisecond timestamp, version 7, RFC 4122
# variant, and random tail bytes. Keep this in the core dependency tier:
# /dev/urandom supplies the random bytes without invoking Python or another
# optional runtime. No counter or other persistent state.
compat_uuid7() {
  local ms hex rnd
  ms=$(( $(date -u +%s) * 1000 ))
  hex=$(printf '%012x' "$ms")
  rnd=$(head -c 10 /dev/urandom | od -An -tx1 | tr -d ' \n')
  printf '%s-%s-7%s-8%s-%s\n' \
    "${hex:0:8}" "${hex:8:4}" "${rnd:0:3}" "${rnd:3:3}" "${rnd:6:12}"
}

# Get file size in bytes.
# Replaces: stat -f %z (macOS) / stat -c %s (Linux/MSYS2)
#
# Same split as compat_file_mtime below, and added for the same kind of caller:
# a bounded log has to know when to rotate, and `wc -c` on a file being
# appended to is a second read of the whole thing.
compat_file_size() {
  local file="$1"
  [ -z "$file" ] && return 1
  _agmsg_detect_platform
  case "$_agmsg_platform" in
    macos)  stat -f %z "$file" 2>/dev/null ;;
    *)      stat -c %s "$file" 2>/dev/null ;;
  esac
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
