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
#
# NOT memoised, though `compat_pid_gone` reaches it from a poll that can turn
# 1600 times. A cache here would be keyed on a pid, and a pid stops naming the
# same process the moment that process exits -- which is the reuse hazard the
# callers of this are built to survive. Paying a fork per turn on msys is the
# cost; it is the same failure path #779 is already open about.
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

# Is this process gone? Only when every probe available SAYS SO.
#
# THE TWO WRONG ANSWERS DO NOT COST THE SAME. A probe that wrongly says "alive"
# costs a signal aimed at a pid whose ownership the caller still has to prove. A
# probe that wrongly says "gone" leaves a live process nobody stops -- and that
# is #831 exactly: on Windows 11 three `sync start` attempts each read a running
# engine as dead, reported failure, and walked away, leaving three engines
# pulling.
#
# SO "COULD NOT ASK" IS NOT "GONE". Under Git Bash the Windows side is reached
# through a WINPID lookup and `tasklist`, and either can be missing, fail, or
# answer something this cannot parse. An earlier version of this function let all
# three fall through to "gone", which is the same collapse #652 was about --
# rebuilt here, in the function written to prevent it (raised in review on #840).
# Every one of them now answers "not gone", and the caller's cmdline check is
# what still keeps a dead pid from reading as a running engine.
#
# Under Git Bash the pid these shells minted is an MSYS pid, which `tasklist`
# does not report at all -- asking it about one is how #567 lost every codex
# bridge -- so the Windows side is asked about the WINPID.
#
# The WINPID may be passed in. A caller that resolved it while the process was
# provably its own must keep using THAT mapping: `ps` stops answering for a pid
# whose MSYS side has exited, and re-deriving it after a signal is how the
# lookup disappears exactly when it is needed (#840 review).
#
# `_agmsg_pid_alive_local` lives in instance-id.sh, which most callers of this
# file do not source. Its absence must not be answerable either: an undefined
# function exits 127, which is not 0, which fell straight through to "gone".
compat_pid_gone() {
  local pid="$1" winpid="${2:-}" listing=""
  if ! declare -f _agmsg_pid_alive_local >/dev/null 2>&1; then
    printf 'agmsg: compat_pid_gone needs lib/instance-id.sh sourced\n' >&2
    return 1
  fi
  _agmsg_pid_alive_local "$pid" && return 1
  _agmsg_detect_platform
  [ "$_agmsg_platform" = "msys" ] || return 0
  [ -n "$winpid" ] || winpid="$(_compat_get_winpid "$pid" 2>/dev/null || true)"
  # No mapping means the Windows side was never asked. Not an answer.
  case "$winpid" in ''|*[!0-9]*) return 1 ;; esac
  command -v tasklist >/dev/null 2>&1 || return 1
  listing="$(MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $winpid" 2>/dev/null)" || return 1
  case "$listing" in *"$winpid"*) return 1 ;; esac
  # tasklist ran, and did not list it. Both sides agree.
  return 0
}

# End a process tree this codebase started, on whatever the host calls it.
#
# `kill` alone is not enough under Git Bash. The sync engine is launched as
# `bash remote-sync.sh`, which runs `node`; the MSYS signal reaches the MSYS-side
# process and the native `node.exe` under it survives. Measured on Windows 11:
# `sync start` had already aimed a kill at each of three engines that were still
# running half an hour later (#831). Windows has no signal to deliver, so the
# tree is ended by pid instead -- `/T` for the children, and `/F` only on the
# second pass, after the polite attempt has been made and waited on.
#
# THE MAPPING IS RESOLVED BEFORE THE SIGNAL, and this ordering is the whole
# point. `ps -l -p <msys-pid>` is what turns a pid into a WINPID, and it stops
# answering once the MSYS side has exited -- so a `kill` sent first can take away
# the only means of naming the native process still running underneath. That is
# not a hypothetical: it is the reported symptom, "MSYS kill returns and node.exe
# is still there", reproduced by the order of two lines (#840 review). A caller
# that already resolved the WINPID while it could prove the process was its own
# passes it in, and the same mapping carries through the signal, the taskkill and
# the confirmation that it went.
#
# Neither half is allowed to fail this function -- a signal that could not be
# delivered is not distinguishable here from one delivered to a process that had
# already exited, and the caller decides by asking whether it is gone.
#
# WHAT THIS DOES NOT CHECK is whether the pid is the caller's to end. `/T` ends a
# whole tree, so on a recycled number that is somebody else's tree. Ownership is
# proven before this is called, by the cmdline and not by the number.
compat_signal_pid_tree() {
  local pid="$1" sig="$2" winpid="${3:-}"
  # ONE PLATFORM DECISION, AND IT HAPPENS HERE. Written as two -- a guard on the
  # lookup and a second guard before the taskkill -- either one alone could be
  # removed with nothing to show for it, so neither was actually held by a
  # control. Off msys there is no Windows name for this process, and saying that
  # once is what makes it testable.
  _agmsg_detect_platform
  if [ "$_agmsg_platform" = "msys" ]; then
    [ -n "$winpid" ] || winpid="$(_compat_get_winpid "$pid" 2>/dev/null || true)"
  else
    winpid=""
  fi
  kill "-$sig" "$pid" 2>/dev/null || true
  case "$winpid" in ''|*[!0-9]*) return 0 ;; esac
  case "$sig" in
    KILL) MSYS_NO_PATHCONV=1 taskkill /PID "$winpid" /T /F >/dev/null 2>&1 || true ;;
    *)    MSYS_NO_PATHCONV=1 taskkill /PID "$winpid" /T    >/dev/null 2>&1 || true ;;
  esac
  return 0
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
