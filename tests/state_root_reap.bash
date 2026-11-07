# Ending the background processes a test started, without ever signalling a
# process that is not the one it started. Every process is a record
# "pid|start time", and EVERY signal is preceded by a fresh check that the pid
# still has that start time, so a pid that was reaped and reused is skipped
# (and so is anything found below a reused pid). The commands used (ps, pgrep,
# kill, sleep) are looked up at call time so a test can stub them.

TEST_BG=()

# Records a process the test just started.
track_bg() {   # <pid>
  TEST_BG+=("$1|$(LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null)")
}

# 0 only if <pid> is alive now and has exactly the recorded start time.
bg_same() {   # <pid> <start time>
  local now
  [ -n "$2" ] || return 1
  now="$(LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null)"
  [ "$now" = "$2" ]
}

# Sends <signal> to <pid> only if it is still the recorded process.
bg_signal() {   # <signal> <pid> <start time>
  bg_same "$2" "$3" || return 1
  kill "-$1" "$2" 2>/dev/null || true
}

# Waits up to <tenths of a second> for the recorded process to be gone; 0 if it is.
bg_wait_gone() {   # <pid> <start time> <ticks>
  local i
  for ((i = 0; i < $3; i++)); do
    bg_same "$1" "$2" || return 0
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.2
  done
  bg_same "$1" "$2" || return 0
  return 1
}

# Ends the recorded process: a polite wait, TERM, a wait, KILL. Each signal is
# preceded by the identity check; none is sent to anything else.
bg_reap() {   # <pid|start time>
  local pid="${1%%|*}" started="${1#*|}"
  [ -n "$started" ] || return 0
  bg_wait_gone "$pid" "$started" 10 && return 0
  bg_signal TERM "$pid" "$started" || return 0
  bg_wait_gone "$pid" "$started" 15 && return 0
  bg_signal KILL "$pid" "$started" || true
  return 0
}

# Prints the records of the children below a process, recursively, but only
# while that process is still the recorded one: nothing is collected below a pid
# that has been reused.
bg_children() {   # <pid> <start time>
  local c cs
  bg_same "$1" "$2" || return 0
  for c in $(pgrep -P "$1" 2>/dev/null); do
    cs="$(LC_ALL=C ps -p "$c" -o lstart= 2>/dev/null)"
    [ -n "$cs" ] || continue
    printf '%s|%s\n' "$c" "$cs"
    bg_children "$c" "$cs"
  done
}

# Ends a recorded process and what it started. The owner's identity is verified
# BEFORE its children are looked for; if it does not match, nothing is done.
bg_reap_family() {   # <pid|start time>
  local pid="${1%%|*}" started="${1#*|}" fam sub
  bg_same "$pid" "$started" || return 0
  fam="$(bg_children "$pid" "$started")"
  bg_reap "$1"
  while IFS= read -r sub; do
    [ -n "$sub" ] && bg_reap "$sub"
  done <<< "$fam"
  return 0
}

bg_reap_all() {
  local rec
  for rec in ${TEST_BG[@]+"${TEST_BG[@]}"}; do
    bg_reap_family "$rec"
    wait "${rec%%|*}" 2>/dev/null || true
  done
}
