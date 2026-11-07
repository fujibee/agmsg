# Background processes a test starts, and their cleanup.
#
# The only processes a test ever signals are jobs of the test's own shell: they
# are recorded when they are started (track_bg), and a signal is sent only while
# the shell's job table still lists the pid as a RUNNING job. A pid that has been
# reaped, or that never was a job of this shell, is never signalled. Nothing is
# looked up by walking the process table, so no process is adopted by its pid.
# Whatever a job itself started (lock helpers) ends by itself: the update's lock
# coprocess when the update's pipe closes, the earlier-release lock helper within
# a second of its owner going away, and a held lock when its sleep ends.

TEST_BG=()

# Records a background job of this shell, right after it was started.
track_bg() {   # <pid of a job>
  TEST_BG+=("$1")
}

# 0 only if <pid> is a running job of this shell.
bg_is_running_job() {   # <pid>
  case " $(jobs -r -p | tr '\n' ' ') " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Holds BEGIN EXCLUSIVE on <db> for <seconds> in a background job of this shell.
hold_lock() {   # <db> <seconds>
  ( ( printf 'BEGIN EXCLUSIVE;\nSELECT 1;\n'; sleep "$2" ) | sqlite3 "$1" >/dev/null 2>&1 ) &
  HOLD_PID=$!
  track_bg "$HOLD_PID"
}

# Ends the tracked jobs: wait for them to finish by themselves, then TERM, then
# KILL, each step bounded and each signal only to a pid still listed as a running
# job. Returns 1 (and says so) if a job was still running at the end.
bg_reap_all() {
  local pid i left=0
  for pid in ${TEST_BG[@]+"${TEST_BG[@]}"}; do
    for ((i = 0; i < 50; i++)); do bg_is_running_job "$pid" || break; sleep 0.2; done
    if bg_is_running_job "$pid"; then
      kill "$pid" 2>/dev/null || true
      for ((i = 0; i < 15; i++)); do bg_is_running_job "$pid" || break; sleep 0.2; done
    fi
    if bg_is_running_job "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
      for ((i = 0; i < 10; i++)); do bg_is_running_job "$pid" || break; sleep 0.2; done
    fi
    if bg_is_running_job "$pid"; then
      # not waited for: a job that is still running would block the wait for good
      echo "teardown: background job $pid is still running" >&2
      left=1
    else
      wait "$pid" 2>/dev/null || true
    fi
  done
  return "$left"
}
