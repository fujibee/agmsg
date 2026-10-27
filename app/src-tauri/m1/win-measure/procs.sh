#!/bin/bash
# Process handling for run-win.sh. Sourced (and by selftest-procs.sh with stubbed tasklist/taskkill).
# Rule: this run stops only the processes it launched itself, by process id, and only while the id still
# belongs to the image it launched. It never stops anything by image name.
#   TRACK   file listing "<windows pid> <image name>" for every process this run launched

winpid_of() { cat "/proc/$1/winpid" 2>/dev/null || echo "$1"; }   # Git Bash: the Windows id of an MSYS child

# another run's executables are present (checked before anything is launched or any trap is set)
other_run_present() { tasklist 2>/dev/null | grep -qi 'agmsg-app-win-measure'; }

# launch <logfile> <exe> [VAR=value ...]: start the executable in the background and record its id
launch() {
  local log=$1 exe=$2; shift 2
  ( env "$@" "$exe" > "$log" 2>&1 < /dev/null & echo $! > "$TRACK.launching" )
  local pid; pid=$(winpid_of "$(cat "$TRACK.launching")")
  echo "$pid $(basename "$exe")" >> "$TRACK"
}

# stop everything recorded in TRACK (and nothing else), then forget it
stop_launched() {
  [ -f "$TRACK" ] || return 0
  local pid image
  while read -r pid image; do
    [ -n "$pid" ] || continue
    if tasklist //FI "PID eq $pid" //FO CSV //NH 2>/dev/null | grep -qiF "\"$image\""; then
      taskkill //F //T //PID "$pid" > /dev/null 2>&1
    fi
  done < "$TRACK"
  : > "$TRACK"
  sleep 2
}
