#!/usr/bin/env bats
# The seat-local single-flight lock (scripts/lib/self-write-lock.sh).
#
# Every test names the failure it exists to catch; each is meant to go red on
# exactly one mutation of the code (listed at the bottom of the file).

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/self-write-lock.sh"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
}

teardown() { teardown_test_env; }

# A composite owner token whose pid is this test process: alive for the whole
# test, and its marker names the token, so agmsg_instance_alive answers 0.
me_token() { printf 'sid-me.%s' "$$"; }
mark_alive() { printf '%s\n' "$1" > "$RUN_DIR/cc-instance.${1##*.}"; }

# A composite token whose pid is positively dead: a child that has already
# been reaped. Its marker names the token, so only the pid decides.
dead_token() {
  local pid
  ( : ) & pid=$!
  wait "$pid" 2>/dev/null || true
  printf 'sid-gone.%s' "$pid"
}

# --- path: its own name and place ------------------------------------------

@test "path: lives under run/ as self-write.<team>__<agent>.lock, encoded" {
  local p; p="$(agmsg_self_write_lock_path "te am" "al/ice")"
  [ "$p" = "$RUN_DIR/self-write.te%20am__al%2Fice.lock" ]
}

@test "path: never the actas lock and never the leader lock for the same seat" {
  local p a; p="$(agmsg_self_write_lock_path T alice)"; a="$(actas_lock_path T alice)"
  [ "$p" != "$a" ]
  case "$p" in *self-fix.*) false ;; esac
  case "$p" in *self-write.T__alice.lock) : ;; *) false ;; esac
}

# --- acquire: the plain cases ------------------------------------------------

@test "acquire: a free lock is taken and records the owner" {
  local tok; tok="$(me_token)"; mark_alive "$tok"
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$tok" ]
}

@test "acquire: the holder re-acquiring its own lock is ok, not busy" {
  local tok; tok="$(me_token)"; mark_alive "$tok"
  agmsg_self_write_lock_acquire T alice "$tok" >/dev/null
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "acquire: an empty owner is refused as unknown, and nothing is written" {
  run agmsg_self_write_lock_acquire T alice ""
  [ "$status" -eq 2 ]
  [ "$output" = unknown:owner_empty ]
  [ ! -e "$(agmsg_self_write_lock_path T alice)" ]
}

# --- control 1: another live process holds it -> busy, visible ----------------

@test "control other-process: a live holder makes the second claimant busy, naming the holder" {
  local tok; tok="$(me_token)"; mark_alive "$tok"
  agmsg_self_write_lock_acquire T alice "$tok" >/dev/null
  run agmsg_self_write_lock_acquire T alice "sid-other.$$"
  [ "$status" -eq 1 ]
  [ "$output" = "busy:$tok" ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$tok" ]
}

@test "control other-process: busy clears once the holder releases (sequential race)" {
  # Two claimants need two live pids: one marker per pid is the whole point of
  # the composite token (a second token on the same pid IS a pid reuse).
  local a b bpid
  a="$(me_token)"; mark_alive "$a"
  sleep 30 & bpid=$!
  b="sid-b.$bpid"; mark_alive "$b"
  agmsg_self_write_lock_acquire T alice "$a" >/dev/null
  run agmsg_self_write_lock_acquire T alice "$b"
  [ "$status" -eq 1 ]
  [ "$output" = "busy:$a" ]
  agmsg_self_write_lock_release T alice "$a"
  run agmsg_self_write_lock_acquire T alice "$b"
  kill "$bpid" 2>/dev/null; wait "$bpid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$b" ]
}

# --- control 2: PID reuse -> the marker disagrees -> dead -> reclaimed ---------

@test "control pid-reuse: a live pid whose marker names another instance is dead, and the lock is reclaimed" {
  local stale="sid-old.$$"
  # The pid is alive (it is us) but the marker says this pid is now someone else.
  printf 'sid-new.%s\n' "$$" > "$RUN_DIR/cc-instance.$$"
  printf '%s\n' "$stale" > "$(agmsg_self_write_lock_path T alice)"
  run agmsg_self_write_lock_acquire T alice "sid-new.$$"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "sid-new.$$" ]
}

# --- control 3: a crash BEFORE publish leaves an orphan temp, not a lock -------

@test "control orphan-temp: a claimant that died before linking leaves no lock; the next claim succeeds without reclaim and the orphan is left alone" {
  local tok orphan; tok="$(me_token)"; mark_alive "$tok"
  orphan="$RUN_DIR/.actas-claim.orphan"
  printf 'sid-crashed.%s\n' 999999 > "$orphan"
  [ ! -e "$(agmsg_self_write_lock_path T alice)" ]
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ -e "$orphan" ]                                   # temp GC is a separate fact
  [ "$(cat "$orphan")" = "sid-crashed.999999" ]
}

# --- control 4: an EMPTY lock on disk is a torn write, never free --------------

@test "control write-empty: an empty lock file is unknown, is not taken, and is not deleted" {
  local tok; tok="$(me_token)"; mark_alive "$tok"
  : > "$(agmsg_self_write_lock_path T alice)"
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 2 ]
  [ "$output" = unknown:owner_empty ]
  [ -e "$(agmsg_self_write_lock_path T alice)" ]
  [ ! -s "$(agmsg_self_write_lock_path T alice)" ]
}

# --- control 5: a crash MID-WRITE leaves a lock whose owner is dead ------------

@test "control crash-mid-cell: a lock held by a positively dead owner is reclaimed by the next claimant" {
  local gone tok; gone="$(dead_token)"; mark_alive "$gone"
  tok="$(me_token)"; mark_alive "$tok"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$tok" ]
}

@test "control crash-mid-cell: an owner whose liveness cannot be decided is NOT reclaimed" {
  local tok; tok="$(me_token)"; mark_alive "$tok"
  printf 'sid-x.%s\n' 424242 > "$(agmsg_self_write_lock_path T alice)"
  agmsg_instance_alive() { return 2; }     # cannot tell
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 2 ]
  [ "$output" = unknown:liveness_undecidable ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "sid-x.424242" ]
}

@test "control crash-mid-cell: a dead verdict that turns undecidable under the reclaim mutex does NOT delete the lock" {
  # The reclaim re-checks the owner INSIDE the mutex, and that re-check is only
  # reached after the first read already said dead. A test in which liveness is
  # undecidable from the start never arrives there (the claim refuses one step
  # earlier), so the re-check's own guard can only be seen shut by a liveness
  # that FLIPS: dead on the first read, undecidable on the second. Mutating the
  # re-check to reclaim on anything-but-alive reddens exactly this test.
  local tok; tok="$(me_token)"; mark_alive "$tok"
  printf 'sid-x.%s\n' 424242 > "$(agmsg_self_write_lock_path T alice)"
  : > "$RUN_DIR/alive-calls"
  agmsg_instance_alive() {
    printf 'x' >> "$RUN_DIR/alive-calls"
    [ "$(wc -c < "$RUN_DIR/alive-calls")" -le 1 ] && return 1   # first read: dead
    return 2                                                       # re-check: cannot tell
  }
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 2 ]
  [ "$output" = unknown:liveness_undecidable ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "sid-x.424242" ]
  [ "$(wc -c < "$RUN_DIR/alive-calls")" -ge 2 ]                  # the re-check RAN
}

# --- control 7: the reclaim MUTEX is as crash-safe as the lock it protects ------
#
# Every case below starts from a main lock whose owner is positively dead (so the
# claim enters the reclaim path) and varies only the state of the mutex file
# beside it. Before this, the mutex was a bare directory: a reclaimer dying
# between mkdir and rmdir left it forever and every later claim spun into
# unknown:reclaim_contended -- with no time-based reclaim, a permanent stop.

mutex_of() { printf '%s.reclaim' "$(agmsg_self_write_lock_path "$1" "$2")"; }

@test "mutex crash-live: a reclaimer that is alive keeps its mutex; the claimant is contended, and the dead main lock is untouched" {
  local gone tok bpid other
  gone="$(dead_token)"; mark_alive "$gone"; tok="$(me_token)"; mark_alive "$tok"
  sleep 30 & bpid=$!
  other="sid-reclaimer.$bpid"; mark_alive "$other"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  printf '%s\n' "$other" > "$(mutex_of T alice)"
  run agmsg_self_write_lock_acquire T alice "$tok"
  kill "$bpid" 2>/dev/null; wait "$bpid" 2>/dev/null || true
  [ "$status" -eq 2 ]
  [ "$output" = unknown:reclaim_contended ]
  [ "$(cat "$(mutex_of T alice)")" = "$other" ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$gone" ]
}

@test "mutex crash-dead: a reclaimer that died mid-reclaim leaves a mutex that is cleared, and the claim then succeeds" {
  local gone deadmx tok
  gone="$(dead_token)"; mark_alive "$gone"
  deadmx="$(dead_token)"; mark_alive "$deadmx"
  tok="$(me_token)"; mark_alive "$tok"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  printf '%s\n' "$deadmx" > "$(mutex_of T alice)"
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ ! -e "$(mutex_of T alice)" ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$tok" ]
  # nothing else was left beside the lock (no tombstone survives a completed clear)
  [ -z "$(ls "$RUN_DIR" | grep -F "$(basename "$(mutex_of T alice)").dead." || true)" ]
}

@test "mutex crash-between-take-and-release: a reclaimer killed while HOLDING the mutex (published by the real path) does not stop later claims" {
  # The path tl named: die after taking the mutex and before releasing it. The
  # mutex here is produced by the code under test, not written by hand: a child
  # process takes it through _agmsg_lock_mutex_take, reports, and is then
  # killed mid-hold. Its token dies with it, so the next claimant must find a
  # dead-owned mutex, clear it, reclaim the dead main lock, and succeed.
  local gone tok mx child ctok
  gone="$(dead_token)"; mark_alive "$gone"; tok="$(me_token)"; mark_alive "$tok"
  mx="$(mutex_of T alice)"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  ( ctok="sid-child.$BASHPID"; printf '%s\n' "$ctok" > "$RUN_DIR/cc-instance.$BASHPID"
    _agmsg_lock_mutex_take "$mx" "$ctok" > "$RUN_DIR/child-take"
    sleep 30 ) &
  child=$!
  local i=0; while [ ! -s "$RUN_DIR/child-take" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
  [ "$(cat "$RUN_DIR/child-take")" = ok ]
  kill -9 "$child" 2>/dev/null; wait "$child" 2>/dev/null || true
  pkill -P "$child" 2>/dev/null || true
  [ -e "$mx" ]                                       # died holding it
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ ! -e "$mx" ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$tok" ]
}

@test "mutex empty: an empty mutex file is a torn write -> unknown, kept, main lock kept" {
  local gone tok; gone="$(dead_token)"; mark_alive "$gone"; tok="$(me_token)"; mark_alive "$tok"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  : > "$(mutex_of T alice)"
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 2 ]
  [ "$output" = unknown:reclaim_mutex:owner_empty ]
  [ -e "$(mutex_of T alice)" ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$gone" ]
}

@test "mutex unreadable: an unreadable mutex is unknown, kept, and the main lock is kept" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  local gone tok mx; gone="$(dead_token)"; mark_alive "$gone"; tok="$(me_token)"; mark_alive "$tok"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  mx="$(mutex_of T alice)"; printf 'sid-someone.%s\n' 424242 > "$mx"; chmod 000 "$mx"
  run agmsg_self_write_lock_acquire T alice "$tok"
  local kept=0; [ -e "$mx" ] && kept=1
  chmod 644 "$mx" 2>/dev/null || true
  [ "$status" -eq 2 ]
  [ "$output" = unknown:reclaim_mutex:lock_unreadable ]
  [ "$kept" -eq 1 ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$gone" ]
}

@test "mutex undecidable: a mutex whose owner's liveness cannot be judged is unknown and kept" {
  local gone tok; gone="$(dead_token)"; mark_alive "$gone"; tok="$(me_token)"; mark_alive "$tok"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  printf 'sid-mx.%s\n' 424242 > "$(mutex_of T alice)"
  _real_alive="$(declare -f agmsg_instance_alive)"
  agmsg_instance_alive() { case "$1" in sid-mx.*) return 2 ;; esac; eval "${_real_alive/agmsg_instance_alive/_orig_alive}"; _orig_alive "$1"; }
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 2 ]
  [ "$output" = unknown:reclaim_mutex:liveness_undecidable ]
  [ "$(cat "$(mutex_of T alice)")" = "sid-mx.424242" ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$gone" ]
}

@test "mutex pid-reuse: a mutex whose owner pid is alive but whose marker names another instance is dead -> cleared" {
  local gone tok; gone="$(dead_token)"; mark_alive "$gone"
  tok="sid-new.$$"; printf '%s\n' "$tok" > "$RUN_DIR/cc-instance.$$"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  printf 'sid-old.%s\n' "$$" > "$(mutex_of T alice)"      # same pid, different instance
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ ! -e "$(mutex_of T alice)" ]
}

@test "mutex flip: a mutex owner judged dead on the first read but undecidable on the tombstone re-read is restored, not deleted" {
  # The one deletion that holds no mutex over itself is the clearing of a dead
  # reclaimer's mutex. Its guard is the re-read of the exclusively renamed file:
  # if the owner is no longer POSITIVELY dead there, the file goes back by ln.
  # The flip lands on "cannot tell", the answer a guard written as "anything but
  # alive" would wrongly treat as dead (the same mutation as control 5's).
  local gone tok; gone="$(dead_token)"; mark_alive "$gone"; tok="$(me_token)"; mark_alive "$tok"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  printf 'sid-mx.%s\n' 424242 > "$(mutex_of T alice)"
  : > "$RUN_DIR/mx-calls"
  _real_alive="$(declare -f agmsg_instance_alive)"
  eval "${_real_alive/agmsg_instance_alive/_orig_alive}"
  agmsg_instance_alive() {
    case "$1" in
      sid-mx.*) printf 'x' >> "$RUN_DIR/mx-calls"
                [ "$(wc -c < "$RUN_DIR/mx-calls")" -le 1 ] && return 1   # first: dead
                return 2 ;;                                               # re-read: cannot tell
    esac
    _orig_alive "$1"
  }
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$(cat "$(mutex_of T alice)")" = "sid-mx.424242" ]                 # restored
  [ "$(wc -c < "$RUN_DIR/mx-calls")" -ge 2 ]                           # the re-read RAN
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$gone" ]       # main lock untouched
  [ "$status" -ne 0 ]
}

# --- control 8: a tombstone (a mutex in transit) is never lost --------------------
#
# The restore of a displaced mutex is `ln tomb mutex`. Its failure has two kinds
# that must not be folded: benign (a fresh mutex already sits there) and
# destructive (nothing is there and the link could not be made). Each case below
# injects one failure into `ln` and asserts which files survive. The starting
# state is always: dead main lock, and a mutex whose owner reads dead on the
# first check and NOT positively dead on the tombstone re-read, so the code
# reaches the restore.

tomb_of() { printf '%s.dead.%s' "$(mutex_of "$1" "$2")" "$(_actas_lock_encode "$3")"; }

_arm_flip() {   # first liveness read of sid-mx.* = dead, later ones = cannot tell
  : > "$RUN_DIR/mx-calls"
  _real_alive="$(declare -f agmsg_instance_alive)"
  eval "${_real_alive/agmsg_instance_alive/_orig_alive}"
  agmsg_instance_alive() {
    case "$1" in
      sid-mx.*) printf 'x' >> "$RUN_DIR/mx-calls"
                [ "$(wc -c < "$RUN_DIR/mx-calls")" -le 1 ] && return 1
                return 2 ;;
    esac
    _orig_alive "$1"
  }
}

@test "tombstone (a) restore ln fails with the destination ABSENT: the tombstone is kept, the claim is unknown, and later claims stay unknown (no gap)" {
  local gone tok mx; gone="$(dead_token)"; mark_alive "$gone"; tok="$(me_token)"; mark_alive "$tok"
  mx="$(mutex_of T alice)"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  printf 'sid-mx.%s\n' 424242 > "$mx"
  _arm_flip
  # The fault is injected on the RESTORE link only (source = a tombstone); the
  # mutex's own publish link must keep working or the injection tests the
  # wrong ln (it did, first time round).
  ln() { case "$1" in *.dead.*) return 1 ;; esac; command ln "$@"; }     # ENOSPC/EIO stand-in
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 2 ]
  [ "$output" = unknown:reclaim_mutex:tombstone_restore_failed ]
  [ -e "$(tomb_of T alice "$tok")" ]
  [ "$(cat "$(tomb_of T alice "$tok")")" = "sid-mx.424242" ]
  [ ! -e "$mx" ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$gone" ]     # main lock untouched
  # a later claimant, ln still broken, must not read the empty mutex slot as free
  run agmsg_self_write_lock_acquire T alice "sid-later.$$"
  [ "$status" -eq 2 ]
  [ "$output" = unknown:reclaim_mutex:tombstone_restore_failed ]
  [ -e "$(tomb_of T alice "$tok")" ]
}

@test "tombstone (a2) once ln works again, the kept tombstone is restored by the next claim and the mutex is back as it was" {
  local gone tok mx; gone="$(dead_token)"; mark_alive "$gone"; tok="$(me_token)"; mark_alive "$tok"
  mx="$(mutex_of T alice)"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  printf 'sid-mx.%s\n' 424242 > "$mx"
  _arm_flip
  ln() { case "$1" in *.dead.*) return 1 ;; esac; command ln "$@"; }
  agmsg_self_write_lock_acquire T alice "$tok" >/dev/null || true
  [ -e "$(tomb_of T alice "$tok")" ]
  unset -f ln
  run agmsg_self_write_lock_acquire T alice "sid-later.$$"
  [ ! -e "$(tomb_of T alice "$tok")" ]
  [ "$(cat "$mx")" = "sid-mx.424242" ]                                # restored, not deleted
  [ "$status" -ne 0 ]                                                  # its owner is still undecidable
}

@test "tombstone (b) restore ln fails because a FRESH mutex already sits there: the fresh one is kept and the tombstone dropped" {
  local gone tok mx bpid fresh; gone="$(dead_token)"; mark_alive "$gone"; tok="$(me_token)"; mark_alive "$tok"
  mx="$(mutex_of T alice)"
  sleep 30 & bpid=$!
  fresh="sid-fresh.$bpid"; mark_alive "$fresh"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  printf 'sid-mx.%s\n' 424242 > "$mx"
  _arm_flip
  # the gap is filled by a peer between our rename and our ln: model it inside ln
  ln() { case "$1" in *.dead.*) printf '%s\n' "$fresh" > "$mx"; return 1 ;; esac; command ln "$@"; }
  run agmsg_self_write_lock_acquire T alice "$tok"
  kill "$bpid" 2>/dev/null; wait "$bpid" 2>/dev/null || true
  [ ! -e "$(tomb_of T alice "$tok")" ]
  [ "$(cat "$mx")" = "$fresh" ]
  [ "$status" -eq 2 ]
  [ "$output" = unknown:reclaim_contended ]                            # the fresh holder is live
}

@test "tombstone (c) restore ln fails and the destination is UNREADABLE: neither file is deleted, the claim is unknown" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  local gone tok mx; gone="$(dead_token)"; mark_alive "$gone"; tok="$(me_token)"; mark_alive "$tok"
  mx="$(mutex_of T alice)"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  printf 'sid-mx.%s\n' 424242 > "$mx"
  _arm_flip
  ln() { case "$1" in *.dead.*) printf 'x\n' > "$mx"; chmod 000 "$mx"; return 1 ;; esac; command ln "$@"; }
  run agmsg_self_write_lock_acquire T alice "$tok"
  local tomb_kept=0 mx_kept=0
  [ -e "$(tomb_of T alice "$tok")" ] && tomb_kept=1
  [ -e "$mx" ] && mx_kept=1
  chmod 644 "$mx" 2>/dev/null || true
  [ "$status" -eq 2 ]
  [ "$output" = unknown:reclaim_mutex:tombstone_destination_unreadable ]
  [ "$tomb_kept" -eq 1 ]
  [ "$mx_kept" -eq 1 ]
}

@test "tombstone (d) a claimant that died between the rename and the settle leaves a tombstone; if its owner is dead it is removed by the next claim, which then succeeds" {
  local gone deadmx tok; gone="$(dead_token)"; mark_alive "$gone"
  deadmx="$(dead_token)"; mark_alive "$deadmx"; tok="$(me_token)"; mark_alive "$tok"
  printf '%s\n' "$gone" > "$(agmsg_self_write_lock_path T alice)"
  printf '%s\n' "$deadmx" > "$(tomb_of T alice "sid-crashed.999999")"   # left by a dead displacer
  run agmsg_self_write_lock_acquire T alice "$tok"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ ! -e "$(tomb_of T alice "sid-crashed.999999")" ]
  [ ! -e "$(mutex_of T alice)" ]
}

# --- control 6: release only on an EXACT owner match --------------------------

@test "control release-exact: releasing with another owner token leaves the lock as found" {
  local tok; tok="$(me_token)"; mark_alive "$tok"
  agmsg_self_write_lock_acquire T alice "$tok" >/dev/null
  agmsg_self_write_lock_release T alice "sid-other.$$"
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$tok" ]
  agmsg_self_write_lock_release T alice "$tok"
  [ ! -e "$(agmsg_self_write_lock_path T alice)" ]
}

@test "control release-exact: an unreadable lock is not deleted by release" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  local tok lock; tok="$(me_token)"; mark_alive "$tok"
  lock="$(agmsg_self_write_lock_path T alice)"
  printf '%s\n' "$tok" > "$lock"
  chmod 000 "$lock"
  agmsg_self_write_lock_release T alice "$tok"
  local kept=0; [ -e "$lock" ] && kept=1
  chmod 644 "$lock" 2>/dev/null || true
  [ "$kept" -eq 1 ]
}

@test "control release-exact: release of an empty lock leaves it (a torn write is not ours to erase)" {
  local tok; tok="$(me_token)"
  : > "$(agmsg_self_write_lock_path T alice)"
  agmsg_self_write_lock_release T alice "$tok"
  [ -e "$(agmsg_self_write_lock_path T alice)" ]
}

# --- held_by: the three answers -----------------------------------------------

@test "held_by: mine / free / other / unreadable are four distinct, named answers" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  local tok lock; tok="$(me_token)"; mark_alive "$tok"
  lock="$(agmsg_self_write_lock_path T alice)"
  run agmsg_self_write_lock_held_by T alice "$tok"
  [ "$status" -eq 1 ]; [ "$output" = free ]
  agmsg_self_write_lock_acquire T alice "$tok" >/dev/null
  run agmsg_self_write_lock_held_by T alice "$tok"
  [ "$status" -eq 0 ]; [ "$output" = mine ]
  run agmsg_self_write_lock_held_by T alice "sid-other.$$"
  [ "$status" -eq 1 ]; [ "$output" = "other:$tok" ]
  chmod 000 "$lock"
  run agmsg_self_write_lock_held_by T alice "$tok"
  chmod 644 "$lock" 2>/dev/null || true
  [ "$status" -eq 2 ]; [ "$output" = unknown:lock_unreadable ]
}

# --- the shared core: the actas lock still lands in its own file --------------

@test "sharing: the actas lock and the self-write lock for one seat are two files, each with its own owner" {
  local tok; tok="$(me_token)"; mark_alive "$tok"
  printf 'sid-me\n' > "$RUN_DIR/cc-instance.$$"    # bare sid for the actas side
  actas_lock_claim T alice sid-me >/dev/null
  mark_alive "$tok"
  agmsg_self_write_lock_acquire T alice "$tok" >/dev/null
  [ "$(cat "$(actas_lock_path T alice)")" = sid-me ]
  [ "$(cat "$(agmsg_self_write_lock_path T alice)")" = "$tok" ]
}

# Mutations, one test each (run by hand, never committed):
#   M1 in agmsg_self_write_lock_acquire map held:* to ok      -> control other-process red
#   M2 in agmsg_lock_claim_at reclaim on _alive_rc != 0        -> liveness-undecided red
#   M3 in agmsg_lock_release_at drop the owner comparison      -> release-exact (other owner) red
#   M4 in _actas_lock_verdict answer free for an empty owner   -> control write-empty red
#   M5 in agmsg_self_write_lock_path drop the "self-write." prefix -> path tests red
#   M6 in _agmsg_lock_try_claim_at skip the temp readback      -> actas axis-6 test red (shared core)

# --- errexit: the verdict LINE must reach stdout under a set -e caller ------------
#
# The shared loop's internal steps print a verdict and used to also return 1
# (held / unknown). A `set -e` caller doing `v=$(agmsg_lock_claim_at ...)` as a
# bare statement then died INSIDE the loop, before any verdict was printed --
# stdout empty, exit 1: silence wearing the shape of a refusal (control measured
# 2026-09-11: child_rc=1, stdout=[]). `run` suspends errexit, so this cannot be
# seen through `run`: the call is made as a bare statement in a real `bash -e`
# child, and the signal is whether the verdict reached stdout.
@test "errexit: a bare set -e call of the shared claim loop with a live-held mutex still prints its verdict" {
  local gone tok bpid other lockp
  gone="$(dead_token)"; mark_alive "$gone"; tok="$(me_token)"; mark_alive "$tok"
  sleep 30 & bpid=$!
  other="sid-reclaimer.$bpid"; mark_alive "$other"
  lockp="$(agmsg_self_write_lock_path T alice)"
  printf '%s\n' "$gone" > "$lockp"
  printf '%s\n' "$other" > "$(mutex_of T alice)"
  # A BARE statement, not `v=$(...)`: the loop's own exit status is 1 for
  # "not claimed" by contract, so a set -e child dies right after it either
  # way. What distinguishes the two worlds is whether the verdict line was
  # printed BEFORE that death -- so the loop's stdout is the child's stdout.
  bash -e -c '. "$1/scripts/lib/actas-lock.sh"; agmsg_lock_claim_at "$2" "$3"; echo unreachable' \
    _ "$SKILL_DIR" "$lockp" "$tok" > "$RUN_DIR/errexit-out" 2>/dev/null || true
  kill "$bpid" 2>/dev/null; wait "$bpid" 2>/dev/null || true
  [ "$(cat "$RUN_DIR/errexit-out")" = "unknown:reclaim_contended" ]
}
