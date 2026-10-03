#!/usr/bin/env bash
# actas-lock.sh — per-(team, agent) exclusivity locks.
#
# Background: agmsg supports a project being registered with multiple agent
# identities of the same type (claude-code/codex/...). Without ownership
# tracking, every concurrent CC session in that project would subscribe to
# every registered identity's messages — duplicate delivery, confused mark-
# read semantics, and the `actas` "exclusive role" model breaking down.
#
# This file implements a small filesystem-based ownership protocol:
#
#   Lock file: $SKILL_DIR/run/actas.<team>__<agent>.session
#   Content  : one line — the owner session_id.
#
# A session_id is alive iff some $SKILL_DIR/run/cc-instance.<pid> file
# currently contains it AND that PID is alive. The same primitive used by
# session-start.sh's orphan-watcher cleanup. Stale locks (owner is no
# longer alive) are reclaimable.
#
# Atomic claim is implemented via `ln` of a per-call tmp file. POSIX
# guarantees the link target either appears or doesn't, even under
# concurrent claim attempts.
#
# Required caller-set variable:
#   SKILL_DIR — agmsg skill root.

: "${SKILL_DIR:?actas-lock.sh requires SKILL_DIR}"

# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/name-encode.sh"

# Owner tokens are per-process instance ids (see instance-id.sh), not bare
# session_ids — this is what keeps parallel --continue/--resume sessions that
# share a session_id from each appearing to own the other's locks (#93). The
# liveness check (actas_lock_sid_alive) delegates to agmsg_instance_alive.
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/instance-id.sh"

_actas_lock_dir() { printf '%s/run' "$SKILL_DIR"; }

# --- #1023: run files are keyed by name, and two names can collide ------------
#
# `_actas_lock_encode` percent-encodes what a name is made of, but the `__`
# JOINING team and agent is not itself escaped -- so a team or agent name that
# legally CONTAINS `__` produces the same three paths for two different
# members: actas_lock_path("a__b","c") == actas_lock_path("a","b__c"). No
# separator fixes this on its own (`-` and `:` are equally legal in a name);
# the fix is to stop joining names at all where a stable id already exists.
#
# roster-journal.sh already maintains one: config.json's `team_id`, and a
# journal-derived `member_id` per (team, name). Both are UUIDs from a fixed
# alphabet, so `<team_id>__<member_id>` cannot suffer this collision -- no
# encoding scheme is needed for it.
#
# NOT EVERY TEAM HAS ONE. A team created before ids existed, that has never
# gone through `remote.sh`'s connect (which mints them), has no team_id --
# and, measured on this tree, a NEW member joining such a team today still
# gets no member_id either (join.sh's id-bearing branch never runs, because it
# is gated on the team already having one). There is deliberately no local
# minting path added here: for an id-less team, `_agmsg_id_key_for` returns
# nothing, and the three functions below fall back to the ORIGINAL
# name-encoded path, unconditionally -- the #1023 collision is not fixed for
# such a team, and that is a decided scope cut (#1023's follow-up), not a bug.
#
# FOR AN ID-BEARING TEAM, existing run files predate this change and are
# still name-keyed on disk. So the three path functions do not simply return
# the id-based path: each checks for a file already there under the id key,
# then a file under the legacy name key, and only when NEITHER exists does it
# hand back the id-based path -- which is where the NEXT write lands. A file
# already served under the old key keeps being served there until it is
# naturally replaced (a lock released and re-claimed, a placement rewritten);
# there is no bulk conversion and no caller anywhere needs to know which key
# it got. This is the same three-way "check, don't guess" shape the rest of
# this file already uses for the lock's own three-valued read.
# The `[ -f "$config" ]` and `[ -n "$team_id" ]` guards below are each
# measured REDUNDANT with the final `[ -n "$member_id" ]` one: removing config
# and team_id together still produces zero reds, because a missing config or
# empty team_id both lead to no roster journal existing, which
# agmsg_roster_name_owner already answers with an empty member_id -- caught by
# the one check that is load-bearing on its own (confirmed separately: removing
# only the member_id check reddens). Kept for clarity at each step rather than
# relying on a guard three calls away, same as #1152's measured-redundant
# empty-comm checks in agent-detect.sh.
# rc 0: printed the resolved key.
# rc 1: NO id for this team/agent -- decided (#1023's own scope cut for a
#       team with no team_id, or a member the roster never minted an id for).
#       Safe for a caller to fall back to the legacy name-keyed path.
# rc 2: UNDETERMINED -- could not even try to resolve one, so this says
#       NOTHING about whether an id exists. An unset SKILL_DIR is the only
#       cause today. This is NOT safe to treat as "no id": an id-keyed lock
#       could already exist on disk, and a caller that falls back anyway
#       would create a second lock at the legacy path for the same member --
#       exactly the double-lock _agmsg_id_or_legacy_path's own "MAIN defense"
#       exists to prevent, bypassed here instead of caught there (#1241
#       review). Every caller of this function must tell 1 and 2 apart.
_agmsg_id_key_for() {   # <team> <agent>
  local team="${1-}" agent="${2-}" team_dir config team_id member_id
  [ -n "$team" ] && [ -n "$agent" ] || return 1
  # Without this, the two `source` calls below run unguarded and errexit
  # takes down the whole caller (#1234-class hazard, measured on this file
  # after #1235 added it) -- rc 2, not 1: this says we could not tell, not
  # that there is no id.
  [ -n "${SKILL_DIR:-}" ] || return 2
  team_dir="$SKILL_DIR/teams/$team"
  config="$team_dir/config.json"
  [ -f "$config" ] || return 1
  if ! declare -F agmsg_sql_readfile_path >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$SKILL_DIR/scripts/lib/sqlpath.sh"
  fi
  team_id="$(sqlite3 :memory: \
    "SELECT COALESCE(json_extract(CAST(readfile('$(agmsg_sql_readfile_path "$config")') AS TEXT), '\$.team_id'),'');" \
    2>/dev/null | tr -d '\r')" || return 1
  [ -n "$team_id" ] || return 1
  if ! declare -F agmsg_roster_name_owner >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$SKILL_DIR/scripts/lib/roster-journal.sh"
  fi
  member_id="$(agmsg_roster_name_owner "$team_dir" "$agent" 2>/dev/null)" || return 1
  [ -n "$member_id" ] || return 1
  printf '%s__%s' "$team_id" "$member_id"
}

# The team half of the reverse of _agmsg_id_key_for: given a team_id, the
# team NAME (its directory's own basename) whose config.json currently
# carries it. A team dir is never itself named as its own team_id, so this
# is a scan, not a lookup -- there is no other index from id back to name.
# Prints nothing and returns 1 if no team dir carries this team_id, or if
# SKILL_DIR is unset.
_agmsg_team_name_for_id() {   # <team_id>
  local want="${1-}" d config tid
  [ -n "$want" ] || return 1
  [ -n "${SKILL_DIR:-}" ] || return 1
  [ -d "$SKILL_DIR/teams" ] || return 1
  if ! declare -F agmsg_sql_readfile_path >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$SKILL_DIR/scripts/lib/sqlpath.sh"
  fi
  for d in "$SKILL_DIR"/teams/*/; do
    [ -d "$d" ] || continue
    config="${d}config.json"
    [ -f "$config" ] || continue
    tid="$(sqlite3 :memory: \
      "SELECT COALESCE(json_extract(CAST(readfile('$(agmsg_sql_readfile_path "$config")') AS TEXT), '\$.team_id'),'');" \
      2>/dev/null | tr -d '\r')" || continue
    if [ -n "$tid" ] && [ "$tid" = "$want" ]; then
      d="${d%/}"
      printf '%s\n' "${d##*/}"
      return 0
    fi
  done
  return 1
}

# The reverse of _agmsg_id_key_for as a whole: given an id-keyed lock's
# <team_id>__<member_id> pair, the (team, agent) NAMES every other reader of
# a role actually keys by (#1457: self-fix.sh's own seat resolution treated
# this pair AS the names, which is where that defect lived). Prints
# "<team>\t<agent>" and returns 0 only when BOTH halves resolve; prints
# nothing and returns 1 otherwise -- a caller must refuse on that, not fall
# back to the raw ids, which is the exact failure this exists to close.
_agmsg_id_key_to_names() {   # <team_id> <member_id>
  local team_id="${1-}" member_id="${2-}" team agent
  [ -n "$team_id" ] && [ -n "$member_id" ] || return 1
  [ -n "${SKILL_DIR:-}" ] || return 1
  team="$(_agmsg_team_name_for_id "$team_id")" || return 1
  [ -n "$team" ] || return 1
  if ! declare -F agmsg_roster_owner_name >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "$SKILL_DIR/scripts/lib/roster-journal.sh"
  fi
  agent="$(agmsg_roster_owner_name "$SKILL_DIR/teams/$team" "$member_id" 2>/dev/null)" || return 1
  [ -n "$agent" ] || return 1
  printf '%s\t%s\n' "$team" "$agent"
}

# Which of <id-path> or <legacy-path> to actually use: the id-keyed one if a
# file already lives there, else the legacy one if a file already lives
# there, else the id-keyed one (nothing exists yet -- the next write starts
# the new form). Shared by all three functions below so "check, don't guess"
# is decided in one place. This is the MAIN defense against the double-lock
# the review below describes: while any file already lives at the legacy
# path, every one of the three functions keeps returning it -- an install
# switched onto this fix does not spontaneously create id-keyed files for
# pairs whose lock/ready/spawn record already exists at the old path.
#
# Review finding: a caller must never see BOTH files exist for the same
# member and get a resolution with no signal, and a resolution alone is not
# enough of a signal -- a warning-and-still-succeed form was tried and
# rejected on review: it still let a caller (claim, in particular) proceed as
# though it held sole ownership while an old-version reader could still honor
# the other file, and several callers of the three path functions discard
# stderr, so the warning was not even reliably seen. Refusing here instead
# does ripple the "always succeeds" contract of the three functions below to
# their callers (the trade explicitly accepted on review) -- but this state
# is reachable only by two writers racing across a version boundary onto a
# pair with no prior file at all (the MAIN defense above already means an
# UPGRADE alone, with an existing legacy file, never reaches here), so the
# callers reached are the ones a genuine double-claim must fail closed for.
_agmsg_id_or_legacy_path() {   # <id-path> <legacy-path>
  if [ -e "$1" ] && [ -e "$2" ]; then
    printf 'agmsg: ERROR: both an id-keyed lock (%s) and a legacy lock (%s) exist for the same member -- refusing to resolve a single path; remove the stale one\n' "$1" "$2" >&2
    return 1
  fi
  [ -e "$1" ] && { printf '%s\n' "$1"; return 0; }
  [ -e "$2" ] && { printf '%s\n' "$2"; return 0; }
  printf '%s\n' "$1"
}

# Bridge _agmsg_id_key_for's 3-way rc (0 resolved / 1 no id / 2 undetermined)
# into what a path function does next, in ONE place so the distinction is not
# re-decided three times. Prints the key and returns 0 when one resolved.
# Returns 1 with nothing printed when there is genuinely no id -- the caller
# must use <legacy> outright, its existing contract. Returns 2, with a
# reason on stderr, when resolution could not even be attempted -- the
# caller MUST NOT fall back (an id-keyed lock could already exist on disk;
# see the rc-2 note on _agmsg_id_key_for above) (#1241 review).
_agmsg_id_key_or_legacy() {   # <team> <agent>
  local key krc=0
  key="$(_agmsg_id_key_for "$1" "$2")" || krc=$?
  case "$krc" in
    0) printf '%s\n' "$key"; return 0 ;;
    1) return 1 ;;
    *) printf 'agmsg: ERROR: cannot tell whether %s/%s has an id-keyed lock (SKILL_DIR unresolved) -- refusing rather than risk missing one and creating a second lock at the legacy path\n' "$1" "$2" >&2
       return 2 ;;
  esac
}

# _agmsg_id_key_or_legacy's rc-2 refusal (above) is one level too deep to be
# the FIRST thing any of the three path functions below does: each builds
# <legacy> before calling it, and that build calls _actas_lock_dir, which
# reads SKILL_DIR bare. Under `set -u` -- every real entry point's shell --
# an unset SKILL_DIR aborts right there with "unbound variable", never
# reaching the rc-2 refusal at all (#1241 review, round 2: the first pass at
# this fix protected the resolver but not its own callers' earlier reads).
# This is the guard that actually runs first, called before any of the
# three touches SKILL_DIR in any way.
_agmsg_lock_paths_require_skill_dir() {   # <caller-name, for the message>
  [ -n "${SKILL_DIR:-}" ] && return 0
  printf 'agmsg: ERROR: %s: SKILL_DIR is not set -- refusing rather than guess a path\n' "$1" >&2
  return 1
}

# --- process-lifetime memoization of actas_lock_path's PRIMITIVES ------------
#
# team_id (config.json), member_id (the roster journal) and the two
# name-encodings are each a pure function of on-disk config that cannot
# change for the life of a long-running poller (watch.sh) without an
# external event this process has no way of observing anyway -- so
# recomputing them every poll cycle only forks sqlite3/tr/sed for the same
# answer every time. What CAN change on every call -- whether a lock file
# already exists under the id-keyed or legacy candidate path -- is NOT
# cached here: _actas_lock_path_cached still asks _agmsg_id_or_legacy_path
# fresh every time, exactly like actas_lock_path itself, so the #1023
# double-lock avoidance keeps seeing live filesystem state.
#
# Same shape as role-session.sh's _agmsg_role_session_path_into (#466):
# parallel arrays (bash 3.2 has no associative arrays), set in the CALLER's
# shell rather than via $(...) (a command-substitution write is lost with
# the subshell it runs in), capped growth.
_AGMSG_ALP_KEYS=()
_AGMSG_ALP_ENC_T=()
_AGMSG_ALP_ENC_A=()
_AGMSG_ALP_IDKEY=()
_AGMSG_ALP_IDKEY_RC=()
_AGMSG_ALP_MAX=64

# Sets _AGMSG_ALP_ENC_TEAM / _AGMSG_ALP_ENC_AGENT / _AGMSG_ALP_ID_KEY /
# _AGMSG_ALP_ID_KEY_RC in the CALLER's shell.
_actas_lock_primitives_into() {
  local team="$1" agent="$2" cachekey i n
  cachekey="${SKILL_DIR:-}"$'\x1f'"${team}"$'\x1f'"${agent}"
  n=${#_AGMSG_ALP_KEYS[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_AGMSG_ALP_KEYS[$i]}" = "$cachekey" ]; then
      _AGMSG_ALP_ENC_TEAM="${_AGMSG_ALP_ENC_T[$i]}"
      _AGMSG_ALP_ENC_AGENT="${_AGMSG_ALP_ENC_A[$i]}"
      _AGMSG_ALP_ID_KEY="${_AGMSG_ALP_IDKEY[$i]}"
      _AGMSG_ALP_ID_KEY_RC="${_AGMSG_ALP_IDKEY_RC[$i]}"
      return 0
    fi
  done
  _AGMSG_ALP_ENC_TEAM="$(_actas_lock_encode "$team")"
  _AGMSG_ALP_ENC_AGENT="$(_actas_lock_encode "$agent")"
  _AGMSG_ALP_ID_KEY_RC=0
  _AGMSG_ALP_ID_KEY="$(_agmsg_id_key_or_legacy "$team" "$agent")" || _AGMSG_ALP_ID_KEY_RC=$?
  # Cache a SUCCESSFUL resolution only (review, #1329 round 2). rc 1 ("no id")
  # and rc 2 ("could not even try") both cover a config.json or roster read
  # that did not go through -- which can be transient (the file mid-rewrite,
  # a momentary permission issue) as easily as a genuine decided absence, and
  # this function cannot tell the two apart. Caching either would make a
  # watcher that warmed at the wrong instant repeat the same failure for the
  # rest of its life even after the read would plainly succeed again; retrying
  # every call until one actually succeeds is what makes that self-correcting.
  if [ "$_AGMSG_ALP_ID_KEY_RC" -eq 0 ] && [ "$n" -lt "$_AGMSG_ALP_MAX" ]; then
    _AGMSG_ALP_KEYS[$n]="$cachekey"
    _AGMSG_ALP_ENC_T[$n]="$_AGMSG_ALP_ENC_TEAM"
    _AGMSG_ALP_ENC_A[$n]="$_AGMSG_ALP_ENC_AGENT"
    _AGMSG_ALP_IDKEY[$n]="$_AGMSG_ALP_ID_KEY"
    _AGMSG_ALP_IDKEY_RC[$n]="$_AGMSG_ALP_ID_KEY_RC"
  fi
  return 0
}

# Cached counterpart of actas_lock_path below: identical resolution rule,
# using the memoized primitives above in place of recomputing them on every
# call. Callers that need a fresh read on every call (most of the tree —
# spawn/despawn/actas-claim/etc., each a one-shot process where memoization
# buys nothing) keep using actas_lock_path unchanged; this is for a caller
# that resolves the SAME pairs over and over in one long-lived process.
actas_lock_path_cached() {
  local team="$1" agent="$2" legacy
  _agmsg_lock_paths_require_skill_dir actas_lock_path_cached || return 1
  _actas_lock_primitives_into "$team" "$agent"
  legacy="$(printf '%s/actas.%s__%s.session' "$(_actas_lock_dir)" "$_AGMSG_ALP_ENC_TEAM" "$_AGMSG_ALP_ENC_AGENT")"
  case "$_AGMSG_ALP_ID_KEY_RC" in
    0) _agmsg_id_or_legacy_path "$(printf '%s/actas.%s.session' "$(_actas_lock_dir)" "$_AGMSG_ALP_ID_KEY")" "$legacy" ;;
    1) printf '%s\n' "$legacy" ;;
    *) return 1 ;;
  esac
}

# Compute the lock file path for (team, agent). #1023: id-keyed when both ids
# resolve and a file already exists at either candidate path, or nothing does
# yet; the legacy name-keyed path otherwise -- see _agmsg_id_key_for above.
# Fails (empty stdout, rc 1) if BOTH candidates exist for the pair, or if id
# resolution itself was undetermined rather than genuinely absent -- see
# _agmsg_id_or_legacy_path and _agmsg_id_key_or_legacy. Every caller must
# check this.
actas_lock_path() {
  local team="$1" agent="$2"
  _agmsg_lock_paths_require_skill_dir actas_lock_path || return 1
  local t a legacy; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  legacy="$(printf '%s/actas.%s__%s.session' "$(_actas_lock_dir)" "$t" "$a")"
  local key krc=0
  key="$(_agmsg_id_key_or_legacy "$team" "$agent")" || krc=$?
  case "$krc" in
    0) _agmsg_id_or_legacy_path "$(printf '%s/actas.%s.session' "$(_actas_lock_dir)" "$key")" "$legacy" ;;
    1) printf '%s\n' "$legacy" ;;
    *) return 1 ;;
  esac
}

# Readiness sentinel path for (team, agent). watch.sh creates this when an
# exclusive (actas) watcher attaches and removes it on exit, so the file is
# present iff a live watcher is currently receiving for that role. `spawn`
# uses it to block until a freshly launched agent is actually listening,
# instead of racing the agent's first push. Same encoding as the lock path so
# both scripts agree without env plumbing. See #108.
agmsg_ready_path() {
  local team="$1" agent="$2"
  _agmsg_lock_paths_require_skill_dir agmsg_ready_path || return 1
  local t a legacy; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  legacy="$(printf '%s/ready.%s__%s' "$(_actas_lock_dir)" "$t" "$a")"
  local key krc=0
  key="$(_agmsg_id_key_or_legacy "$team" "$agent")" || krc=$?
  case "$krc" in
    0) _agmsg_id_or_legacy_path "$(printf '%s/ready.%s' "$(_actas_lock_dir)" "$key")" "$legacy" ;;
    1) printf '%s\n' "$legacy" ;;
    *) return 1 ;;
  esac
}

# Boot-process presence path for a spawned (team, agent). This records the
# launcher boot shell, not agent readiness or responsiveness. The boot shell
# owns the foreground CLI; if model-driven startup never reaches watcher
# registration, this still distinguishes a running CLI from no launch.
# Match ready/spawn path resolution, including ID-keyed paths and ambiguous
# legacy+ID state, so concurrent identities cannot silently split records.
agmsg_boot_pid_path() {
  local team="$1" agent="$2"
  _agmsg_lock_paths_require_skill_dir agmsg_boot_pid_path || return 1
  local t a legacy; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  legacy="$(printf '%s/boot-pid.%s__%s' "$(_actas_lock_dir)" "$t" "$a")"
  local key krc=0
  key="$(_agmsg_id_key_or_legacy "$team" "$agent")" || krc=$?
  case "$krc" in
    0) _agmsg_id_or_legacy_path "$(printf '%s/boot-pid.%s' "$(_actas_lock_dir)" "$key")" "$legacy" ;;
    1) printf '%s\n' "$legacy" ;;
    *) return 1 ;;
  esac
}

# Return 0 only while the recorded boot shell is the same process that wrote
# the sentinel. `kill -0` alone is insufficient: a dead shell's PID can be
# reused. `ps lstart` is the process-witness convention already used by the
# plain terminal driver on platforms without a finer native token.
agmsg_boot_pid_alive() {   # <team> <agent>
  local path pid start extra current
  path="$(agmsg_boot_pid_path "$1" "$2")" || return 1
  [ -r "$path" ] || return 1
  IFS=$'\t' read -r pid start extra < "$path" || return 1
  case "$pid" in ''|0*|*[!0-9]*) return 1 ;; esac
  [ -n "$start" ] && [ -z "$extra" ] || return 1
  current="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//' | tr ' ' '_')"
  [ -n "$current" ] && [ "$current" = "$start" ]
}

# Placement record path for a spawned (team, agent). `spawn` writes the
# member's tmux target id + project + type here at launch time so that
# `despawn --force` can tear the member down (kill its pane/window, drop its
# registration) even when the member's own watcher is dead and can't respond
# to a ctrl:despawn. Same encoding as the lock path. See #109.
agmsg_spawn_path() {
  local team="$1" agent="$2"
  _agmsg_lock_paths_require_skill_dir agmsg_spawn_path || return 1
  local t a legacy; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  legacy="$(printf '%s/spawn.%s__%s' "$(_actas_lock_dir)" "$t" "$a")"
  local key krc=0
  key="$(_agmsg_id_key_or_legacy "$team" "$agent")" || krc=$?
  case "$krc" in
    0) _agmsg_id_or_legacy_path "$(printf '%s/spawn.%s' "$(_actas_lock_dir)" "$key")" "$legacy" ;;
    1) printf '%s\n' "$legacy" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Reading a lock.
#
# There is exactly ONE reader, and it reports the read's own outcome alongside
# the owner. The function it replaces, `actas_lock_owner`, answered the empty
# string for three different worlds:
#
#     the lock file is not there            -> ""   rc 0
#     the lock file is there but unreadable -> ""   rc 0
#     the lock file is there and is empty   -> ""   rc 0
#
# and returned 0 for all three, so a caller could not separate them even by
# checking the status. Four producers then guessed, and each guessed the
# destructive way: "could not read" arrived as "nobody holds this", which became
# claim / rm / consume. Guarding at each call site is not the fix, because the
# next call site starts from the same empty string. The fold is removed HERE,
# and no owner-only form is left in the tree to fall back into.
# (#983, review ruling; the same shape as terminal_team_observe in #1066.)
#
# Prints "<read>\t<owner>":
#
#   ok\t<owner>    the file was read. <owner> is its first line, and an EMPTY
#                  owner here is a fact ABOUT THE FILE, not a failed read.
#   absent\t       there is no lock file, and the directory it would live in is
#                  searchable -- so "there is none" is something we established.
#   unreadable\t   the lock is there and could not be read, OR its directory
#                  cannot be searched, in which case absence is not knowable.
#                  `[ -e ]` is false for BOTH "no such file" and "cannot look
#                  inside the parent", so the directory is asked first (review).
_actas_lock_read_path() {   # <lock-path>
  local lock="$1" owner _dir
  if owner="$(head -1 "$lock" 2>/dev/null)"; then
    printf 'ok\t%s\n' "$owner"
    return 0
  fi
  _dir="${lock%/*}"
  if [ -e "$_dir" ] && { [ ! -r "$_dir" ] || [ ! -x "$_dir" ]; }; then
    printf 'unreadable\t\n'
    return 0
  fi
  if [ -e "$lock" ]; then
    printf 'unreadable\t\n'
    return 0
  fi
  # A missing lock DIRECTORY is `absent`, not `unreadable`: it is the ordinary
  # state of a fresh install. Collapsing it the other way is just as wrong and
  # far louder -- calling it unknown made spawn refuse to start anything (58
  # tests red in one run).
  printf 'absent\t\n'
}

# Same read, addressed by (team, agent) instead of by path. `ambiguous\t` when
# actas_lock_path itself could not resolve a single path (both an id-keyed and
# a legacy lock exist for this pair) -- a fourth read outcome, not folded into
# `unreadable` (a different fact: there IS a file and it could not be opened)
# or `absent` (there is no file at all) -- the vocabulary #983 exists to keep
# apart. _actas_lock_verdict maps it into the same unknown:* family every
# existing caller already refuses to proceed on.
actas_lock_read() {   # <team> <agent>
  local p
  p="$(actas_lock_path "$1" "$2")" || { printf 'ambiguous\t\n'; return 0; }
  _actas_lock_read_path "$p"
}

# Cached counterpart of actas_lock_read, via actas_lock_path_cached. See that
# function's comment for what is and is not memoized.
actas_lock_read_cached() {   # <team> <agent>
  local p
  p="$(actas_lock_path_cached "$1" "$2")" || { printf 'ambiguous\t\n'; return 0; }
  _actas_lock_read_path "$p"
}

# Return 0 if the given owner token is alive. The token is a per-process
# instance id (composite "<sid>.<pid>" or bare "<sid>" fallback); liveness is
# delegated to agmsg_instance_alive (composite -> kill -0 the embedded pid; bare
# -> live cc-instance.<pid> scan, with upgrade compat). Kept as a thin wrapper
# so existing callers (gc_stale, watch.sh subscription, session-start GC) need
# no change. Three-valued: 0 alive, 1 positively dead, 2 cannot tell.
actas_lock_sid_alive() {
  agmsg_instance_alive "$1"
}

# The verdict for one lock, shared by every producer.
#
# Review found the SAME empty lock answered `free` by actas_lock_observe and
# `unknown:owner_empty` by the claim path (now `_agmsg_lock_try_claim_at`).
# Both had been made three-valued -- separately -- so two producers disagreed
# about one file and nothing in the code said which was right. Review axis 5:
# it is not enough that a path returns unknown; every path must return the
# SAME unknown for the same state. So the
# decision lives in one function and the producers translate its answer into
# their own vocabulary instead of deciding again.
#
# Prints "<verdict>\t<owner>"; the owner is empty when there is none to report.
#
#   free                          no lock, or a lock whose owner is POSITIVELY dead
#   mine                          held by the calling session
#   other:<sid>                   held by a session POSITIVELY alive
#   unknown:lock_unreadable       the lock is there and could not be read
#   unknown:lock_ambiguous        both an id-keyed and a legacy lock exist for
#                                 this pair; actas_lock_path refused to pick
#                                 one (#1023 review)
#   unknown:owner_empty           the lock read fine and is empty. NOT free: the
#                                 file exists, and nothing in this tree ever
#                                 creates an empty one (claim writes the sid into
#                                 a tmp file BEFORE linking it into place, and
#                                 release unlinks), so an empty lock is a torn or
#                                 truncated write -- a reason to wait, not to take
#                                 the role. (#1071's trigger.)
#   unknown:liveness_undecidable  the owner is known, its liveness is not
_actas_lock_verdict() {   # <sid> <read> <owner>
  local sid="$1" rd="$2" owner="$3" arc=0
  case "$rd" in
    absent)     printf 'free\t\n';                    return 0 ;;
    unreadable) printf 'unknown:lock_unreadable\t\n'; return 0 ;;
    ambiguous)  printf 'unknown:lock_ambiguous\t\n';   return 0 ;;
  esac
  if [ -z "$owner" ]; then
    printf 'unknown:owner_empty\t\n'
    return 0
  fi
  if [ "$owner" = "$sid" ]; then
    printf 'mine\t%s\n' "$owner"
    return 0
  fi
  agmsg_instance_alive "$owner" || arc=$?
  case "$arc" in
    0) printf 'other:%s\t%s\n' "$owner" "$owner" ;;
    1) printf 'free\t%s\n' "$owner" ;;
    *) printf 'unknown:liveness_undecidable\t%s\n' "$owner" ;;
  esac
}

# The same claim, addressed by LOCK PATH and OWNER TOKEN instead of by role.
#
# The actas lock is not the only exclusion in this tree that must survive a
# claimant dying at any instruction: a seat's own single-flight (self-write-lock.sh)
# needs the identical write-then-readback-then-link publish, the identical
# three-valued verdict, and the identical positive-dead-only reclaim. Copying the
# body would make two producers of the same three values that drift apart one
# review at a time (the shape _actas_lock_verdict exists to prevent). So the body
# lives here, once, keyed on a path; the role-keyed functions above and below
# compute their path and call in. The owner token is whatever agmsg_instance_alive
# can judge: a session id, or a composite <sid>.<pid> instance token.
_agmsg_lock_try_claim_at() {   # <lock-path> <owner>
  local lock="$1" sid="$2"
  local dir tmp _r _v _w verdict existing
  dir="${lock%/*}"
  mkdir -p "$dir" 2>/dev/null || true

  tmp="$(mktemp "$dir/.actas-claim.XXXXXX" 2>/dev/null)" || return 1

  # The mirror of everything else in this change, and the worse half of it.
  # Everything above is about not treating "could not READ" as a fact. This is
  # not treating "could not WRITE" as one -- and a misread only misleads US,
  # while a lock we failed to write is published to every OTHER seat as a valid
  # one. A short write (a full filesystem under run/) leaves an empty or
  # truncated file, `ln` publishes it without complaint, and the claimant then
  # believes it holds a role that its peers read as unknown:owner_empty: held
  # here, unclaimable there. So the write is checked, and then what actually
  # landed is READ BACK before it is linked into place -- printf's status alone
  # does not prove the bytes are on disk. Failing here returns 1, which
  # actas_lock_claim already reports as unknown:claim_failed. (Review, axis 6.)
  if ! printf '%s\n' "$sid" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  _w="$(_actas_lock_read_path "$tmp")"
  if [ "${_w%%$'\t'*}" != "ok" ] || [ "${_w#*$'\t'}" != "$sid" ]; then
    rm -f "$tmp"
    return 1
  fi

  if ln "$tmp" "$lock" 2>/dev/null; then
    rm -f "$tmp"
    echo "ok"
    return 0
  fi
  rm -f "$tmp"

  _r="$(_actas_lock_read_path "$lock")"
  _v="$(_actas_lock_verdict "$sid" "${_r%%$'\t'*}" "${_r#*$'\t'}")"
  verdict="${_v%%$'\t'*}"
  existing="${_v#*$'\t'}"
  case "$verdict" in
    mine)      echo "ok" ;;
    other:*)   printf 'held:%s\n' "$existing" ;;
    unknown:*) printf '%s\n' "$verdict" ;;
    free)
      # `free` has two sources and they need different answers here. A dead
      # owner is a lock to reclaim. NO lock at all means it went away between
      # our failed `ln` and this read -- there is nothing to reclaim, and the
      # next attempt simply links into the gap. Calling that one "stale" sent
      # the caller into the reclaim mutex to delete a file that is not there.
      if [ -n "$existing" ]; then echo "stale"; else echo "vanished"; fi
      ;;
    *) echo "unknown:unclassified" ;;
  esac
  return 0
}

# Claim (team, agent) for session_id.
# Exit codes:
#   0  -- claimed (now ours, was already ours, or stale-replaced). Stdout: "ok".
#   1  -- not claimed. Stdout: "held:<other_sid>" or "unknown:<reason>".
#
# It ALWAYS prints a verdict, and that is load-bearing. Success used to print
# nothing -- and so did every failure this case did not name: mktemp failing, the
# lock directory not being creatable, three contended reclaim rounds. The three
# call sites branch on the OUTPUT, so all of those read as "not held: and not
# unknown:" = "we got it", and a pair nobody had claimed went into the subscribed
# set. A verdict on every path is what lets a caller require an explicit success
# instead of inferring one from silence. (#983, review)
actas_lock_claim() {
  local team="$1" agent="$2" sid="$3" p
  p="$(actas_lock_path "$team" "$agent")" || { echo "unknown:lock_ambiguous"; return 1; }
  agmsg_lock_claim_at "$p" "$sid"
}

# The claim loop by LOCK PATH and OWNER TOKEN (see _agmsg_lock_try_claim_at for
# why the body is shared). Same output contract and exit codes as actas_lock_claim.
agmsg_lock_claim_at() {   # <lock-path> <owner>
  local lock_path="$1" sid="$2"
  local attempts=0 result mutex mres _r _owner _alive_rc
  mutex="$(_agmsg_lock_mutex_path "$lock_path")"
  while [ "$attempts" -lt 3 ]; do
    if ! result="$(_agmsg_lock_try_claim_at "$lock_path" "$sid")"; then
      # mktemp failed, or the lock directory could not be made. Nothing was
      # claimed and nothing was learned about the holder.
      echo "unknown:claim_failed"
      return 1
    fi
    case "$result" in
      ok) echo "ok"; return 0 ;;
      vanished)
        attempts=$((attempts + 1))
        continue
        ;;
      stale)
        # Stale removal needs a re-check-under-mutex. A naked rm (or even an
        # atomic mv) reads-then-removes whatever sits at lock_path, with no
        # guard that the contents are still the stale value we decided on
        # earlier. So two concurrent callers can both see stale, A can
        # successfully install a live lock, and B's later rm/mv would delete
        # A's fresh lock -- the original blocker from #65 review finding 1,
        # and the same hazard the mv-only variant inherited.
        #
        # The mutex is a LOCK OF THE SAME KIND as the one it protects (an
        # owner-bearing file published by _agmsg_lock_try_claim_at), not a bare
        # `mkdir`. A directory has no owner: a reclaimer dying between mkdir and
        # rmdir left it behind with nothing to say whose it was, and with no
        # time-based reclaim every later claim spun three rounds into
        # unknown:reclaim_contended -- the protected lock was crash-safe and
        # the thing protecting it was not (review, 2026-09-11). With an owner
        # in the mutex, a reclaimer that died mid-reclaim is found the same way
        # a dead lock owner is: read, three-valued liveness, positive dead only.
        mres="$(_agmsg_lock_mutex_take "$mutex" "$sid")"
        case "$mres" in
          ok)
            # Reclaim DELETES, so it needs three facts, not one: the read
            # SUCCEEDED, an owner is actually there, and that owner is POSITIVELY
            # dead. "could not read it" and "could not tell" are neither. (#983)
            _r="$(_actas_lock_read_path "$lock_path")"
            if [ "${_r%%$'\t'*}" = "ok" ]; then
              _owner="${_r#*$'\t'}"
              if [ -n "$_owner" ]; then
                _alive_rc=0
                agmsg_instance_alive "$_owner" || _alive_rc=$?
                if [ "$_alive_rc" -eq 1 ]; then
                  rm -f "$lock_path"
                fi
              fi
            fi
            agmsg_lock_release_at "$mutex" "$sid"
            ;;
          held:*)
            # Another reclaimer is alive and mid-reclaim, or a dead one was
            # just cleared. Touch nothing; the next round sees the result.
            ;;
          unknown:*)
            # The mutex's own state could not be established (unreadable,
            # empty, liveness undecidable). Spinning would only repeat the
            # read; say so and stop, so the caller shows it.
            printf 'unknown:reclaim_mutex:%s\n' "${mres#unknown:}"
            return 1
            ;;
        esac
        attempts=$((attempts + 1))
        continue
        ;;
      held:*|unknown:*)
        printf '%s\n' "$result"
        return 1
        ;;
    esac
    # A value this function does not know. Refusing with a named verdict beats
    # falling through to a silent `return 1` that a caller reads as success.
    echo "unknown:claim_failed"
    return 1
  done
  # Three rounds of "stale, then someone else held the reclaim mutex". We never
  # got it and we never established a holder either.
  echo "unknown:reclaim_contended"
  return 1
}

# A narrow same-process handoff (#1468). codex's `/clear` mints a new thread
# id inside the SAME os process, so the current holder's embedded pid stays
# genuinely alive -- the ordinary reclaim path above (positively-dead only)
# correctly refuses to touch it, and that refusal must not be weakened. This
# is the one case that IS still safe to move a lock without the owner ever
# having died: a NEW owner token whose embedded pid -- derived the identical
# way every owner token is, via agmsg_instance_id's ancestor walk -- equals
# the CURRENT holder's embedded pid. Nothing else may pass this check: a
# different live pid holding the role legitimately keeps it, and an
# unreadable or empty lock is left for the normal claim path to name.
#
# Same vocabulary and exit codes as actas_lock_claim: "ok" (0, moved or
# already ours), "held:<owner>" / "unknown:<reason>" (1, untouched).
actas_lock_reclaim_same_process() {   # <team> <agent> <new-owner>
  local team="$1" agent="$2" new_owner="$3" lock_path new_pid
  lock_path="$(actas_lock_path "$team" "$agent")" || { echo "unknown:lock_ambiguous"; return 1; }
  new_pid="${new_owner##*.}"
  [ "$new_pid" != "$new_owner" ] || { echo "unknown:owner_not_composite"; return 1; }
  case "$new_pid" in ''|*[!0-9]*) echo "unknown:owner_pid_invalid"; return 1 ;; esac

  local mutex mres
  mutex="$(_agmsg_lock_mutex_path "$lock_path")"
  mres="$(_agmsg_lock_mutex_take "$mutex" "$new_owner")"
  case "$mres" in
    ok) ;;
    held:*)    printf 'unknown:reclaim_contended\n'; return 1 ;;
    unknown:*) printf 'unknown:reclaim_mutex:%s\n' "${mres#unknown:}"; return 1 ;;
    *)         printf 'unknown:reclaim_mutex_unclassified\n'; return 1 ;;
  esac

  # REPLACES, so it needs the same three facts the ordinary stale-reclaim
  # above requires before it deletes -- the read SUCCEEDED, an owner is
  # actually there, and this time the positive fact is "same pid, positively
  # alive" rather than "positively dead". Anything short of that
  # (unreadable, empty, a different pid, dead, or undecidable) leaves the
  # lock exactly as found.
  #
  # NEVER delete-then-claim (#1470 review, the #1445/#994 race again in a
  # new spot): a plain claim elsewhere takes no mutex at all, so a lock path
  # left empty even briefly -- released here, filled by an ordinary `ln`
  # later -- is a window an unrelated claimant can win, and this reclaim
  # would then either silently lose its own race or, worse, report success
  # about a lock it no longer owns. So the move is ONE filesystem op:
  # write the new owner to a fresh name beside the lock, verify the write
  # landed, and `mv` it directly over the existing (still-occupied) path --
  # same directory, so the rename is atomic and there is no instant where
  # the path reads as absent.
  local result="unknown:not_same_process" rc=1
  local rd owner_now old_pid alive_rc
  rd="$(_actas_lock_read_path "$lock_path")"
  if [ "${rd%%$'\t'*}" = "ok" ] && [ -n "${rd#*$'\t'}" ]; then
    owner_now="${rd#*$'\t'}"
    old_pid="${owner_now##*.}"
    alive_rc=0
    agmsg_instance_alive "$owner_now" || alive_rc=$?
    if [ "$old_pid" = "$new_pid" ] && [ "$alive_rc" -eq 0 ]; then
      local dir tmp w
      dir="${lock_path%/*}"
      if tmp="$(mktemp "$dir/.actas-reclaim.XXXXXX" 2>/dev/null)"; then
        if printf '%s\n' "$new_owner" > "$tmp" 2>/dev/null; then
          w="$(_actas_lock_read_path "$tmp")"
          if [ "${w%%$'\t'*}" = "ok" ] && [ "${w#*$'\t'}" = "$new_owner" ]; then
            if mv "$tmp" "$lock_path" 2>/dev/null; then
              result="ok"; rc=0
            else
              result="unknown:reclaim_rename_failed"
            fi
          else
            result="unknown:reclaim_write_unverified"
          fi
        else
          result="unknown:reclaim_write_failed"
        fi
        rm -f "$tmp" 2>/dev/null
      else
        result="unknown:reclaim_write_failed"
      fi
    fi
  fi
  agmsg_lock_release_at "$mutex" "$new_owner"

  if [ "$rc" -eq 0 ]; then
    echo "ok"
    return 0
  fi
  if [ "$result" != "unknown:not_same_process" ]; then
    printf '%s\n' "$result"
    return 1
  fi
  # Not our case to touch at all (a different pid, or nothing readable to
  # compare against) -- the lock is untouched, so the ordinary claim path
  # decides and reports from its own fresh read.
  agmsg_lock_claim_at "$lock_path" "$new_owner"
}

# Where the reclaim mutex for a lock lives: beside it, one file.
_agmsg_lock_mutex_path() {   # <lock-path>
  printf '%s.reclaim' "$1"
}

# Take the reclaim mutex for <owner>. Prints exactly one of:
#   ok                    held by us now; caller must agmsg_lock_release_at it
#   held:<reason>         not ours this round (a live reclaimer, a vanished or
#                         just-cleared mutex); caller loops, touching nothing
#   unknown:<reason>      the mutex's state could not be established
# The exit status is 0 on EVERY verdict: the line decides. A step here that
# printed its verdict and also returned 1 killed a `set -e` caller of the claim
# loop inside `mres=$(...)`, before any verdict reached stdout -- silence in the
# shape of a refusal (measured 2026-09-11: child rc 1, empty stdout).
#
# A dead reclaimer's mutex is cleared here, and that clearing is the one place
# a lock of this kind is removed without holding a mutex over IT. Regress has to
# stop somewhere; it stops with an atomic rename to a name only this claimant
# uses. `mv` of the mutex to `<mutex>.dead.<us>` succeeds for exactly one
# caller (the second finds no source), and the winner then owns the moved file
# exclusively: it is SETTLED there (_agmsg_lock_tomb_settle) -- deleted only if
# its owner is still positively dead, linked back otherwise. A caller dying
# between the rename and the settle leaves `<mutex>.dead.<us>` behind, and that
# is why every take starts by settling whatever tombstones exist: a tombstone is
# a mutex in transit, not garbage, and a claim that ignored it would link into
# the gap it left.
_agmsg_lock_mutex_take() {   # <mutex-path> <owner>
  local mutex="$1" sid="$2" r tomb s t
  # Tombstones first. Any of them is a displaced mutex whose fate was not yet
  # decided; deciding it is the same routine as below. One that cannot be
  # settled stops this claim with a named unknown instead of a gap.
  for t in "$mutex".dead.*; do
    [ -e "$t" ] || continue
    s="$(_agmsg_lock_tomb_settle "$t" "$mutex")"
    case "$s" in
      settled:*) ;;
      *) printf 'unknown:tombstone_%s\n' "${s#unsettled:}"; return 0 ;;
    esac
  done
  r="$(_agmsg_lock_try_claim_at "$mutex" "$sid")" || { echo "unknown:mutex_claim_failed"; return 0; }
  case "$r" in
    ok)        echo ok; return 0 ;;
    held:*)    printf '%s\n' "$r"; return 0 ;;
    vanished)  echo "held:vanished"; return 0 ;;
    unknown:*) printf '%s\n' "$r"; return 0 ;;
    stale) ;;
    *)         echo "unknown:mutex_unclassified"; return 0 ;;
  esac
  tomb="${mutex}.dead.$(_actas_lock_encode "$sid")"
  if mv "$mutex" "$tomb" 2>/dev/null; then
    s="$(_agmsg_lock_tomb_settle "$tomb" "$mutex")"
    case "$s" in
      settled:*) ;;
      *) printf 'unknown:tombstone_%s\n' "${s#unsettled:}"; return 0 ;;
    esac
  fi
  echo "held:reclaiming"
  return 0
}

# Decide the fate of one tombstone (a mutex displaced by rename). Prints:
#   settled:removed    its owner is positively dead -> it is gone
#   settled:restored   linked back to <mutex-path>  -> the mutex is as it was
#   settled:superseded a fresh mutex already sits at <mutex-path>, read and
#                      confirmed there -> the tombstone is dropped
#   unsettled:<why>    it is KEPT, and the caller must not treat the mutex slot
#                      as free: restore_failed (ln failed and the destination is
#                      absent -- ENOSPC, EIO, a permission), destination_unreadable
#                      (something is there and cannot be read)
# Exit status 0 on every verdict, for the same reason as _agmsg_lock_mutex_take.
#
# The restore is `ln`, never `mv`: a mutex somebody published into the gap must
# not be overwritten. And a failed `ln` is NOT read as "somebody did": that
# folds the benign failure (destination exists) with the destructive ones
# (nothing there, and the link could not be made), and the delete that followed
# removed the only inode of a mutex just judged undeletable. The destination is
# re-read instead, and only a mutex actually READ there licenses dropping the
# tombstone. (Review, 2026-09-11 -- the third "two failure kinds folded into
# one" of the day.)
_agmsg_lock_tomb_settle() {   # <tombstone-path> <mutex-path>
  local tomb="$1" mutex="$2" _r _owner _alive_rc _d
  _r="$(_actas_lock_read_path "$tomb")"
  _owner="${_r#*$'\t'}"
  _alive_rc=2
  if [ "${_r%%$'\t'*}" = "ok" ] && [ -n "$_owner" ]; then
    _alive_rc=0
    agmsg_instance_alive "$_owner" || _alive_rc=$?
  fi
  if [ "$_alive_rc" -eq 1 ]; then
    rm -f "$tomb"
    echo "settled:removed"
    return 0
  fi
  if ln "$tomb" "$mutex" 2>/dev/null; then
    rm -f "$tomb"
    echo "settled:restored"
    return 0
  fi
  _d="$(_actas_lock_read_path "$mutex")"
  case "${_d%%$'\t'*}" in
    ok)         rm -f "$tomb"; echo "settled:superseded"; return 0 ;;
    unreadable) echo "unsettled:destination_unreadable"; return 0 ;;
    *)          echo "unsettled:restore_failed"; return 0 ;;
  esac
}

# Release a lock if we own it. Idempotent. If actas_lock_path cannot resolve a
# single path (both an id-keyed and a legacy lock exist), this deletes
# NEITHER -- it already does not know which file the caller means, and
# releasing based on a guess is exactly the kind of silent resolution #1023
# review rejected. actas_lock_path's own stderr already named the ambiguity.
actas_lock_release() {
  local team="$1" agent="$2" sid="$3" p
  p="$(actas_lock_path "$team" "$agent")" || return 1
  agmsg_lock_release_at "$p" "$sid"
}

# Release by LOCK PATH and OWNER TOKEN. Only an exact owner match deletes; a lock
# that is unreadable, empty, or someone else's is left exactly as found.
agmsg_lock_release_at() {   # <lock-path> <owner>
  local lock="$1" sid="$2"
  local _r
  # This DELETES, so it needs a read that worked AND an owner that is positively
  # us. `[ -f ] || return 0` followed by comparing a possibly-empty owner landed
  # on the same behaviour by accident (an unreadable lock compares unequal to any
  # sid); saying it outright is what keeps the next edit from breaking it.
  _r="$(_actas_lock_read_path "$lock")"
  if [ "${_r%%$'\t'*}" = "ok" ] && [ "${_r#*$'\t'}" = "$sid" ]; then
    rm -f "$lock"
  fi
  return 0
}

# Release every lock currently owned by the given session_id. Used by
# session-end.sh when a CC session exits.
actas_lock_release_all() {
  local sid="$1"
  local dir; dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || return 0
  local f _r
  for f in "$dir"/actas.*.session; do
    [ -f "$f" ] || continue
    # This was the last `head -1 ... || true` in the file. It could only ever
    # have released a lock this session did not own -- an unreadable lock
    # compares unequal to any sid -- but it left the fold in the tree for the
    # next reader to copy, and reading it properly costs nothing. (#983)
    _r="$(_actas_lock_read_path "$f")"
    if [ "${_r%%$'\t'*}" = "ok" ] && [ "${_r#*$'\t'}" = "$sid" ]; then
      rm -f "$f"
    fi
  done
  return 0
}

# Garbage-collect locks whose owner session_id is no longer alive.
# Returns the number of locks reclaimed on stdout (for observability).
actas_lock_gc_stale() {
  local dir; dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || { echo 0; return 0; }
  local f owner count=0 _r _alive_rc
  for f in "$dir"/actas.*.session; do
    [ -f "$f" ] || continue
    # `|| true` discarded the read's status, so an unreadable lock became an
    # empty owner, which read as "nobody owns it", which read as garbage -- and
    # this is a SWEEP, so one transient read problem did not lose a role, it lost
    # every role in the directory. Delete only what is positively abandoned: the
    # read worked, an owner is there, and its session is positively dead. (#983)
    #
    # Measured, so the next reader is not misled about which line is holding
    # this up: the two guards below OVERLAP. An unreadable read yields an empty
    # owner, so deleting the status check alone changes nothing and the mutation
    # produces no reds. It stays because "the read worked" is the fact this
    # decision rests on, and inferring it from "the owner came back non-empty"
    # is the coupling that made an unreadable lock look abandoned in the first
    # place. The empty-owner line is the one a test can redden today.
    _r="$(_actas_lock_read_path "$f")"
    [ "${_r%%$'\t'*}" = "ok" ] || continue
    owner="${_r#*$'\t'}"
    [ -n "$owner" ] || continue
    _alive_rc=0
    actas_lock_sid_alive "$owner" || _alive_rc=$?
    if [ "$_alive_rc" -eq 1 ]; then
      rm -f "$f"
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Classify a (team, agent) pair relative to the calling session.
# Prints "<state>\t<owner>"; the owner is empty when there is none to report.
# The states are _actas_lock_verdict's, documented there -- this function is the
# read plus that verdict, and nothing else, so that `observe` and `try_claim`
# cannot drift apart again (they did: review axis 5).
#
# Returning the owner alongside the state matters as much as the values: callers
# that need a baseline to compare against later were reading the state and then
# reading the owner in a SECOND call, and a claim landing between the two
# produced a stale state paired with a fresh owner. One read, both facts, no
# window. (#983, found in review.)
actas_lock_observe() {
  local _r
  _r="$(actas_lock_read "$1" "$2")"
  _actas_lock_verdict "$3" "${_r%%$'\t'*}" "${_r#*$'\t'}"
}

# Cached counterpart of actas_lock_observe, via actas_lock_read_cached. Same
# verdict rule, same owner read every call — only the path resolution behind
# it is memoized. See actas_lock_path_cached's comment for scope.
actas_lock_observe_cached() {
  local _r
  _r="$(actas_lock_read_cached "$1" "$2")"
  _actas_lock_verdict "$3" "${_r%%$'\t'*}" "${_r#*$'\t'}"
}

# Classify a (team, agent) pair relative to the calling session. Thin wrapper over
# actas_lock_observe so there is exactly one place that reads and one set of rules;
# callers needing the owner as well should use actas_lock_observe and split, rather
# than calling both (that pairing is what created the window described above).
actas_lock_state() {
  local _out
  _out="$(actas_lock_observe "$1" "$2" "$3")" || return 1
  # A REAL tab, not the two characters `\t`: `${var%%\t*}` strips nothing, and
  # `actas_lock_state` then returned "free<TAB>" to every caller that compares it
  # to `free`. Measured the moment it was written, which is the only reason it is
  # not in the diff.
  printf '%s\n' "${_out%%$'\t'*}"
}
