#!/bin/bash
# Process handling for run-win.sh. Sourced (and by selftest-procs.sh with stubbed tasklist/taskkill).
# Rule: this run stops only the processes it launched itself, by process id, and only while the id still
# belongs to the image it launched. It never stops anything by image name.
#   TRACK   file listing "<windows pid> <image name>" for every process this run launched

winpid_of() { cat "/proc/$1/winpid" 2>/dev/null || echo "$1"; }   # Git Bash: the Windows id of an MSYS process

# image name of a Windows process id ("" when there is none)
image_of() { tasklist //FI "PID eq $1" //FO CSV //NH 2>/dev/null | head -1 | sed -n 's/^"\([^"]*\)".*/\1/p'; }

# another run's executables are present (checked before anything is launched or any trap is set)
other_run_present() { tasklist 2>/dev/null | grep -qi 'agmsg-app-win-measure'; }

# find_launched_pid <stub windows pid> <image>: the Windows id of the executable we started.
# In Git Bash, `env exe` leaves an MSYS stub whose id is NOT the executable's: the executable is its
# child. So look at the stub itself, then at the stub's children with that image name.
find_launched_pid() {
  local stub=$1 image=$2 i c
  for i in $(seq 1 20); do
    [ "$(image_of "$stub")" = "$image" ] && { echo "$stub"; return 0; }
    c=$(powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"ParentProcessId=$stub AND Name='$image'\" | Select-Object -First 1 -ExpandProperty ProcessId" 2>/dev/null | tr -d '\r' | head -1)
    [ -n "$c" ] && { echo "$c"; return 0; }
    sleep 0.5
  done
  return 1
}

# launch <logfile> <exe> [VAR=value ...]: start the executable in the background and record its Windows id.
# Returns 1 (and records the stub so the trap can stop its tree) when the real id cannot be found.
launch() {
  local log=$1 exe=$2; shift 2
  ( env "$@" "$exe" > "$log" 2>&1 < /dev/null & echo $! > "$TRACK.launching" )
  local stub image pid; stub=$(winpid_of "$(cat "$TRACK.launching")"); image=$(basename "$exe")
  if pid=$(find_launched_pid "$stub" "$image"); then
    echo "$pid $image" >> "$TRACK"
    return 0
  fi
  echo "launch: cannot find the Windows id of $image (stub $stub)" >&2
  local simg; simg=$(image_of "$stub"); [ -n "$simg" ] && echo "$stub $simg" >> "$TRACK"
  return 1
}

# stop everything recorded in TRACK (and nothing else), then forget it
stop_launched() {
  [ -f "$TRACK" ] || return 0
  local pid image left=0
  while read -r pid image; do
    [ -n "$pid" ] || continue
    if [ "$(image_of "$pid")" = "$image" ]; then
      taskkill //F //T //PID "$pid" > /dev/null 2>&1
    fi
  done < "$TRACK"
  sleep 2
  while read -r pid image; do
    [ -n "$pid" ] || continue
    if [ "$(image_of "$pid")" = "$image" ]; then echo "still running after taskkill: $pid $image" >&2; left=1; fi
  done < "$TRACK"
  [ "$left" = 0 ] && : > "$TRACK"
  return $left
}
