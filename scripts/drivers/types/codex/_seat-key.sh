#!/usr/bin/env bash
# #1254: one Codex app-server per SEAT, never shared across seats. This file
# is the shared vocabulary every piece that touches a seat-keyed app-server
# record uses -- the key's grammar, the record's shape, and the two things
# ever done with a record: read it to find the seat's server, or stop it.
#
# Two separate identities, deliberately not one (design review):
#   - The SEAT KEY only has to be UNIQUE, so file names never collide. It is
#     "$$.<unix-time>.<RANDOM>", generated once by codex-monitor.sh before it
#     forks anything, and travels from there via AGMSG_CODEX_SEAT_KEY (set on
#     the app-server's own command and exported into the monitor's own shell,
#     so both the app-server's children and the exec'd TUI inherit it). It is
#     NEVER recomputed by a reader -- Windows cannot read a process's start
#     time via `ps`, so nothing here may depend on being able to.
#   - The record's pid/witness/cmdline triple is what STOPPING checks. A seat
#     key alone is not proof of identity; the record is.
#
# Every seat key this file's functions accept -- freshly generated or read
# back from AGMSG_CODEX_SEAT_KEY -- is validated against the same fixed,
# filename-safe grammar before it is ever used to build a path. A caller that
# skips the check could turn an inherited or corrupted env value into a path
# traversal or a collision with an unrelated file; refusing is the whole
# point of having a grammar at all.

# 0 if <key> is digits-and-dots only (no leading/trailing/doubled dot, no
# empty segment), a bounded length, and non-empty. This is the ENTIRE
# grammar: nothing else about a seat key is ever trusted before it is used
# to build a run/ path.
_agmsg_codex_seat_key_ok() {
  local key="$1"
  [ -n "$key" ] || return 1
  [ "${#key}" -le 128 ] || return 1
  case "$key" in
    *[!0-9.]*) return 1 ;;
    .*|*.|*..*) return 1 ;;
  esac
  return 0
}

# Generate a fresh seat key. Never reused, never recomputed from an inherited
# value -- a codex launched from inside another codex seat (a nested shell
# tool call, say) must get its own server, not silently attach to the
# ancestor's (design review). $RANDOM is 0-32767 and $$ is a plain pid, so the
# result is always digits-and-dots; date +%s is seconds, coarse enough that
# $$ plus $RANDOM still disambiguates same-second launches.
_agmsg_codex_seat_key_new() {
  printf '%s.%s.%s' "$$" "$(date +%s)" "$RANDOM"
}

# Absolute path to <seat key>'s record file, given <run_dir>. The record is
# the ONE file for pid+port+witness+project (design review point: written and
# read as a single atomic unit, never as separate files that could each be
# rewritten out of step with the others). The log stays a separate, plain,
# append-only file -- nothing ever needs it to agree with the record.
_agmsg_codex_seat_record_path() {   # <run_dir> <seat_key>
  printf '%s/codex-app-server.%s.record' "$1" "$2"
}
_agmsg_codex_seat_log_path() {   # <run_dir> <seat_key>
  printf '%s/codex-app-server.%s.log' "$1" "$2"
}

# Best-effort start witness for <pid>: "<src>\t<token>", or nothing (rc 1)
# when this platform cannot supply one. NEVER required for normal operation
# (a seat with no witness on record is simply never stopped automatically --
# left running, reported); only ever consulted before a kill.
#   Linux -> /proc/<pid>/stat field 22 (starttime, clock ticks): lossless.
#   Windows (MSYS/MINGW/CYGWIN) -> PowerShell (Get-Process -Id
#     <pid>).StartTime.Ticks -- taken INSTEAD of /proc, not merely before it:
#     MSYS exposes a working /proc, but keyed by the emulation layer's own pid
#     space, not the Windows pid a cmdline match is about.
#   else -> `ps -o lstart=`, second precision.
_agmsg_codex_is_windows() {
  case "${_AGMSG_CODEX_UNAME_S:=$(uname -s 2>/dev/null || echo unknown)}" in
    MINGW*|MSYS*|CYGWIN*|CLANGARM*) return 0 ;;
    *) return 1 ;;
  esac
}
_agmsg_codex_seat_witness() {   # <pid> -> "src<TAB>token" on stdout
  local pid="$1" s r tok bin
  local -a a
  if _agmsg_codex_is_windows; then
    for bin in powershell.exe pwsh; do
      tok="$("$bin" -NoProfile -NonInteractive -Command \
        "(Get-Process -Id $pid).StartTime.Ticks" 2>/dev/null | tr -d '\r' | head -n 1)"
      tok="${tok#"${tok%%[![:space:]]*}"}"
      tok="${tok%"${tok##*[![:space:]]}"}"
      case "$tok" in ''|*[!0-9]*) continue ;; esac
      printf 'pwsh\t%s' "$tok"
      return 0
    done
    return 1
  fi
  if [ -r "/proc/$pid/stat" ]; then
    s="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    r="${s##*)}"
    read -ra a <<< "$r"
    tok="${a[19]:-}"
    case "$tok" in ''|*[!0-9]*) return 1 ;; esac
    printf 'proc\t%s' "$tok"
    return 0
  fi
  tok="$(ps -o lstart= -p "$pid" 2>/dev/null)"
  tok="${tok#"${tok%%[![:space:]]*}"}"
  tok="${tok%"${tok##*[![:space:]]}"}"
  [ -n "$tok" ] || return 1
  printf 'ps\t%s' "$tok"
  return 0
}

# Write <path> atomically (temp file + rename) as one generation: a strict
# key=value record, one key per line, nothing else -- the same shape and the
# same "malformed fails closed" discipline codex-bridge-launcher.sh's lease
# reader already uses. `generation` is a fresh nonce independent of the seat
# key itself, so a later reader can tell "this exact write" apart from any
# other write that might ever land at this same path.
#
# witnesssrc/witness may both be empty (the platform could not supply one at
# write time); a reader must then never attempt to stop this seat's server --
# see _agmsg_codex_seat_record_stop below.
_agmsg_codex_seat_record_write() {   # <path> <project_hash> <pid> <port> <witnesssrc> <witness> <version>
  local path="$1" project_hash="$2" pid="$3" port="$4" wsrc="$5" witness="$6" version="$7"
  local generation tmp
  generation="$$.$(date +%s).$RANDOM.$RANDOM"
  tmp="$path.tmp.$$.$RANDOM"
  {
    printf 'v=1\n'
    printf 'generation=%s\n' "$generation"
    printf 'project=%s\n' "$project_hash"
    printf 'pid=%s\n' "$pid"
    printf 'port=%s\n' "$port"
    printf 'witnesssrc=%s\n' "$wsrc"
    printf 'witness=%s\n' "$witness"
    printf 'version=%s\n' "$version"
  } > "$tmp" || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  mv "$tmp" "$path"
}

# Parse <path> under an EXACT v=1 schema; fail closed on anything else --
# unknown/duplicate/missing/extra key, wrong line count. Sets
# SEAT_REC_{GENERATION,PROJECT,PID,PORT,WITNESSSRC,WITNESS,VERSION} only on a
# clean parse (return 0); an aborted parse leaves them empty and returns 1, so
# a caller that forgets to check the return value still gets empty fields
# rather than a previous record's leftovers.
_agmsg_codex_seat_record_read() {   # <path>
  local path="$1" line k v nlines=0
  local sv=0 sgen=0 sproj=0 spid=0 sport=0 swsrc=0 switness=0 sver=0
  SEAT_REC_GENERATION=""; SEAT_REC_PROJECT=""; SEAT_REC_PID=""; SEAT_REC_PORT=""
  SEAT_REC_WITNESSSRC=""; SEAT_REC_WITNESS=""; SEAT_REC_VERSION=""
  local lv=""
  [ -f "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    nlines=$((nlines + 1))
    case "$line" in *=*) ;; *) return 1 ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      v)          sv=$((sv + 1)); lv="$v" ;;
      generation) sgen=$((sgen + 1)); SEAT_REC_GENERATION="$v" ;;
      project)    sproj=$((sproj + 1)); SEAT_REC_PROJECT="$v" ;;
      pid)        spid=$((spid + 1)); SEAT_REC_PID="$v" ;;
      port)       sport=$((sport + 1)); SEAT_REC_PORT="$v" ;;
      witnesssrc) swsrc=$((swsrc + 1)); SEAT_REC_WITNESSSRC="$v" ;;
      witness)    switness=$((switness + 1)); SEAT_REC_WITNESS="$v" ;;
      version)    sver=$((sver + 1)); SEAT_REC_VERSION="$v" ;;
      *) return 1 ;;
    esac
  done < "$path"
  [ "$nlines" -eq 8 ] || return 1
  [ "$sv$sgen$sproj$spid$sport$swsrc$switness$sver" = "11111111" ] || return 1
  [ "$lv" = "1" ] || return 1
  case "$SEAT_REC_PID" in ''|*[!0-9]*) return 1 ;; esac
  case "$SEAT_REC_PORT" in ''|*[!0-9]*) return 1 ;; esac
  case "$SEAT_REC_WITNESSSRC" in ''|proc|ps|pwsh) ;; *) return 1 ;; esac
  # witness may legitimately be empty (paired with witnesssrc=); everything
  # else about the record's SHAPE has to be exact regardless.
  return 0
}

# Stop the app-server <seat_key>'s record (under <run_dir>) describes, IF AND
# ONLY IF every one of these holds, re-checked FRESH, immediately before the
# kill (design review point -- a generation re-check closes the gap between
# "we decided to stop this" and "we actually signaled a pid"):
#   - the record still parses cleanly, and its generation is UNCHANGED from
#     the first read (nobody rewrote this seat's record out from under us)
#   - witnesssrc/witness were recorded at all (a seat whose platform could
#     not supply one at write time is NEVER auto-stopped)
#   - the recorded pid is alive, its CURRENT witness still matches the
#     recorded one, and its cmdline still says codex app-server
# Any failure -- including simply being unable to read/confirm one of the
# above -- changes NOTHING and returns 1. Prints one line to stderr saying
# which check failed, for the caller to relay. On success, kills the pid,
# removes the record and its log, and returns 0.
# 0 only if <pid> is alive RIGHT NOW, its cmdline still says codex app-server,
# and its current start witness still matches <witnesssrc>/<witness> -- all
# read fresh on every call, never cached. Prints nothing; the caller (which
# knows the seat key and whether this is the first or the pre-kill check)
# reports.
_agmsg_codex_seat_pid_identity_ok() {   # <pid> <witnesssrc> <witness>
  local pid="$1" wsrc="$2" witness="$3"
  _agmsg_pid_alive_local "$pid" 2>/dev/null || return 1
  local cur_cmd
  cur_cmd="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
  case "$cur_cmd" in
    *codex*app-server*) ;;
    *) return 1 ;;
  esac
  local cur_witness
  cur_witness="$(_agmsg_codex_seat_witness "$pid" 2>/dev/null || true)"
  [ -n "$cur_witness" ] && [ "$cur_witness" = "$wsrc	$witness" ]
}

_agmsg_codex_seat_record_stop() {   # <run_dir> <seat_key>
  local run_dir="$1" seat_key="$2" path
  path="$(_agmsg_codex_seat_record_path "$run_dir" "$seat_key")"
  _agmsg_codex_seat_record_read "$path" || {
    echo "codex seat $seat_key: record missing or malformed -- leaving it, not stopping anything" >&2
    return 1
  }
  local first_gen="$SEAT_REC_GENERATION" pid="$SEAT_REC_PID"
  local wsrc="$SEAT_REC_WITNESSSRC" witness="$SEAT_REC_WITNESS"
  if [ -z "$wsrc" ] || [ -z "$witness" ]; then
    echo "codex seat $seat_key: no start witness was recorded for pid $pid -- leaving it, not stopping" >&2
    return 1
  fi
  if ! _agmsg_pid_alive_local "$pid" 2>/dev/null; then
    echo "codex seat $seat_key: recorded pid $pid is not alive -- nothing to stop, removing the record" >&2
    rm -f "$path" "$(_agmsg_codex_seat_log_path "$run_dir" "$seat_key")" 2>/dev/null || true
    return 1
  fi
  _agmsg_codex_seat_pid_identity_ok "$pid" "$wsrc" "$witness" || {
    echo "codex seat $seat_key: pid $pid no longer matches the recorded cmdline/start time -- leaving it, not stopping" >&2
    return 1
  }
  # Re-read right before signaling: the record must still describe the SAME
  # generation we validated above. If anything rewrote it in the meantime,
  # do nothing -- the new writer's own record is what governs now.
  _agmsg_codex_seat_record_read "$path" || {
    echo "codex seat $seat_key: record changed while stopping it -- leaving it alone" >&2
    return 1
  }
  if [ "$SEAT_REC_GENERATION" != "$first_gen" ] || [ "$SEAT_REC_PID" != "$pid" ]; then
    echo "codex seat $seat_key: record changed while stopping it -- leaving it alone" >&2
    return 1
  fi
  # Re-verify the PID's own identity one more time, immediately before the
  # kill: between the check above and here the process could have exited and
  # its pid been reused by an unrelated process -- the generation re-read
  # alone only proves the RECORD is unchanged, not that this pid is still
  # the process it named a moment ago.
  _agmsg_codex_seat_pid_identity_ok "$pid" "$wsrc" "$witness" || {
    echo "codex seat $seat_key: pid $pid no longer matches immediately before stopping it -- leaving it alone" >&2
    return 1
  }
  kill "$pid" 2>/dev/null || true
  rm -f "$path" "$(_agmsg_codex_seat_log_path "$run_dir" "$seat_key")" 2>/dev/null || true
  return 0
}
