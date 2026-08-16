#!/usr/bin/env bash
# role-session.sh — advisory (team, agent) -> session record.
#
# A role (team, agent) has no durable link to the CLI session that embodies it:
# spawn always boots fresh, and a resumed session can only be found by guessing
# in the picker. This file records the LATEST session id that held each role, so
# a boot wrapper (#339 PR-C) can resume a role back into its prior conversational
# context, and the tmux-resurrect hook (PR-D) / role-aware SessionStart (PR-E)
# can reverse-map a pane / session id back to its role.
#
# Design notes:
#   - The record stores the BARE session id (agmsg_instance_bare_sid), which is
#     stable across resume generations — NOT the composite instance id (#93) the
#     actas lock keys on. The lock answers "who owns this role right now"; this
#     record answers "what session last embodied it" (resumable identity).
#   - It is ADVISORY runtime state, not config: written/read only by this lib and
#     its consumers, safe to delete at any time. Every write is best-effort — a
#     failed record write must NEVER fail the caller (the claim). Every read is
#     fail-open — a missing/unreadable record yields empty (→ fresh boot).
#   - Filenames follow the actas-lock convention exactly: run/role-session.<t>__<a>
#     with the SAME percent-encoding sanitizer, so these files sit next to the
#     actas.<t>__<a>.session locks and encode names identically (unicode-safe).
#
# Required caller-set variable:
#   SKILL_DIR — agmsg skill root.

# Guard against double-source (actas-claim.sh sources both this and actas-lock.sh).
[ -n "${_AGMSG_ROLE_SESSION_SH:-}" ] && return 0
_AGMSG_ROLE_SESSION_SH=1

: "${SKILL_DIR:?role-session.sh requires SKILL_DIR}"

# Reuse the actas-lock filename sanitizer (_actas_lock_encode) and run/ dir
# (_actas_lock_dir) rather than reimplementing them — the two families of state
# files must agree on encoding. Source it only if not already present so callers
# that already sourced actas-lock.sh (e.g. actas-claim.sh) don't re-run it.
if ! command -v _actas_lock_encode >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/instance-id.sh"
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/actas-lock.sh"
fi

# Compute the record file path for (team, agent). Same encoding + dir as the
# actas lock, distinct prefix (role-session. vs actas.), no .session suffix.
#
# Memoized per shell. The result is a pure function of (SKILL_DIR, team, agent),
# but computing it costs three command substitutions and two awk processes, and
# the codex bridge launcher re-derives it for the same handful of pairs on every
# poll iteration for the lifetime of an app-server. SKILL_DIR is part of the key
# so a caller that relocates the skill root mid-process (tests do) simply misses
# the cache rather than reading a stale path.
#
# IMPORTANT: a cache entry is only kept when the helper runs in the caller's own
# shell. `path="$(_agmsg_role_session_path ...)"` computes the entry inside a
# command substitution and throws it away with the subshell, so a caller that
# only ever invokes it that way pays full price every time. Use the _into form
# below from a long-lived shell; subshells forked afterwards inherit the warm
# cache and read from it.
#
# Parallel arrays, not an associative array: macOS ships bash 3.2, which has
# none. The pair count is a handful, so the linear scan is cheaper than the
# awk processes it replaces. Encoding itself is deliberately NOT reimplemented
# here -- _actas_lock_encode is shared with the actas lock filenames, and any
# divergence would orphan live state files.
_AGMSG_RS_PATH_KEYS=()
_AGMSG_RS_PATH_VALS=()
_AGMSG_RS_PATH_MAX=64

# Sets _AGMSG_ROLE_SESSION_PATH in the CALLER's shell, so the memo survives.
_agmsg_role_session_path_into() {
  local team="$1" agent="$2" t a key i n
  key="${SKILL_DIR}"$'\x1f'"${team}"$'\x1f'"${agent}"
  n=${#_AGMSG_RS_PATH_KEYS[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_AGMSG_RS_PATH_KEYS[$i]}" = "$key" ]; then
      _AGMSG_ROLE_SESSION_PATH="${_AGMSG_RS_PATH_VALS[$i]}"
      return 0
    fi
  done
  t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  _AGMSG_ROLE_SESSION_PATH="$(_actas_lock_dir)/role-session.${t}__${a}"
  if [ "$n" -lt "$_AGMSG_RS_PATH_MAX" ]; then
    _AGMSG_RS_PATH_KEYS[$n]="$key"
    _AGMSG_RS_PATH_VALS[$n]="$_AGMSG_ROLE_SESSION_PATH"
  fi
  return 0
}

# stdout form, for callers that are not in a hot loop.
_agmsg_role_session_path() {
  _agmsg_role_session_path_into "$1" "$2"
  printf '%s' "$_AGMSG_ROLE_SESSION_PATH"
}

# Read the two fields the codex bridge launcher needs in ONE pass, into the
# caller's shell: AGMSG_ROLE_SESSION_UUID and AGMSG_ROLE_SESSION_PROJECT. Both
# are empty when the record or the field is absent. This exists so the poll path
# can resolve a role without a single command substitution -- the getters below
# are fine one-shot, but each one costs a subshell and its own read of the same
# file, and the launcher wants both fields for the same pair several times a
# second. First match wins per field, matching the getters exactly.
agmsg_role_session_load() {
  local team="$1" agent="$2" line path have_uuid=0 have_project=0
  AGMSG_ROLE_SESSION_UUID=""
  AGMSG_ROLE_SESSION_PROJECT=""
  _agmsg_role_session_path_into "$team" "$agent"
  path="$_AGMSG_ROLE_SESSION_PATH"
  [ -f "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      session=*)
        [ "$have_uuid" = "1" ] || { AGMSG_ROLE_SESSION_UUID="${line#session=}"; have_uuid=1; }
        ;;
      project=*)
        [ "$have_project" = "1" ] || { AGMSG_ROLE_SESSION_PROJECT="${line#project=}"; have_project=1; }
        ;;
    esac
  done < "$path" 2>/dev/null
  return 0
}

# Record (team, agent) -> <bare_sid> for <project>. Latest session wins
# (overwrites any prior record). Best-effort: returns 0 on every path, including
# every failure, so a caller can `agmsg_role_session_record ... || true` purely
# for readability — a failed write never propagates. Written atomically via a
# tmp file + rename so a concurrent reader never sees a half-written record.
#
# Fields (key=value, one per line):
#   session=<bare_sid>     resumable session identity (stable across resume)
#   name=<team>-<agent>    the -n display name; whole, so reverse lookup never
#                          has to split <team>-<agent> apart (either half may
#                          itself contain '-')
#   team=<team>            stored explicitly so by-sid consumers (PR-E) recover
#   agent=<agent>          the role without re-parsing the joined name
#   type=<type>            the agent type (claude-code/...); the resurrect hook
#                          (PR-D) needs it to rebuild the role's boot command
#                          from the type manifest. Empty when unknown.
#   project=<project>      the resolved project root
#   updated_at=<iso8601>   best-effort timestamp (empty if date(1) unavailable)
agmsg_role_session_record() {
  local team="$1" agent="$2" bare_sid="$3" project="${4:-}" type="${5:-}"
  [ -n "$team" ] && [ -n "$agent" ] && [ -n "$bare_sid" ] || return 0
  local path dir tmp ts
  _agmsg_role_session_path_into "$team" "$agent"
  path="$_AGMSG_ROLE_SESSION_PATH"
  dir="$(_actas_lock_dir)"
  mkdir -p "$dir" 2>/dev/null || true
  tmp="$(mktemp "$dir/.role-session.XXXXXX" 2>/dev/null)" || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  {
    printf 'session=%s\n' "$bare_sid"
    printf 'name=%s-%s\n' "$team" "$agent"
    printf 'team=%s\n' "$team"
    printf 'agent=%s\n' "$agent"
    printf 'type=%s\n' "$type"
    printf 'project=%s\n' "$project"
    printf 'updated_at=%s\n' "$ts"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# Read a single field from a role's record by (team, agent). Empty if absent.
# Convenience getter used by consumers that need one field (e.g. the resurrect
# hook reading `type`); mirrors agmsg_role_session_uuid's read of `session`.
agmsg_role_session_get() {
  local team="$1" agent="$2" key="$3" path
  _agmsg_role_session_path_into "$team" "$agent"
  _agmsg_role_session_field "$_AGMSG_ROLE_SESSION_PATH" "$key"
}

# Read a single field from a record file. Empty if file/field absent.
#
# Builtins only. This was `sed -n | head -1`, i.e. two processes per field, and
# the codex bridge launcher reads two fields per role on every poll iteration.
# The record is a handful of short key=value lines, so reading it in the shell
# is both cheaper and exactly equivalent: first match wins, and the value is
# everything after the first '='.
_agmsg_role_session_field() {
  local path="$1" key="$2" line
  [ -f "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key"=*) printf '%s\n' "${line#"$key"=}"; return 0 ;;
    esac
  done < "$path" 2>/dev/null
  return 0
}

# Read back the recorded bare session id for (team, agent). Empty if no record.
# This is the primary getter used by the boot wrapper (PR-C).
agmsg_role_session_uuid() {
  local team="$1" agent="$2" path
  _agmsg_role_session_path_into "$team" "$agent"
  _agmsg_role_session_field "$_AGMSG_ROLE_SESSION_PATH" session
}

# Scan run/role-session.* for the record whose name= field equals <name> and
# print its full body (all key=value lines). Empty if none. Matches on the whole
# name= field (never by splitting on '-'), per the record's raison d'etre.
# Used by the resurrect hook (PR-D) to map a pane's `-n <name>` back to a uuid.
agmsg_role_session_lookup_by_name() {
  local name="$1" dir f v
  [ -n "$name" ] || return 0
  dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || return 0
  for f in "$dir"/role-session.*; do
    [ -f "$f" ] || continue
    v="$(_agmsg_role_session_field "$f" name)"
    if [ "$v" = "$name" ]; then
      cat "$f" 2>/dev/null || true
      return 0
    fi
  done
  return 0
}

# Print the session id of every record of <type>, one per line (unordered, may
# repeat across teams). Empty if none. Used by codex seat resolution (#579) to
# subtract already-claimed threads from the app-server's loaded set: what is left
# is the session that has not been seated yet.
agmsg_role_session_recorded_uuids() {
  local type="$1" dir f t v
  [ -n "$type" ] || return 0
  dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || return 0
  for f in "$dir"/role-session.*; do
    [ -f "$f" ] || continue
    t="$(_agmsg_role_session_field "$f" type)"
    [ "$t" = "$type" ] || continue
    v="$(_agmsg_role_session_field "$f" session)"
    [ -n "$v" ] && printf '%s\n' "$v"
  done
  return 0
}

# Scan run/role-session.* for the record whose session= field equals <sid> and
# print its full body (all key=value lines). Empty if none. Used by role-aware
# SessionStart (PR-E) to map a resumed session id back to its (team, agent).
agmsg_role_session_lookup_by_sid() {
  local sid="$1" dir f v
  [ -n "$sid" ] || return 0
  dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || return 0
  for f in "$dir"/role-session.*; do
    [ -f "$f" ] || continue
    v="$(_agmsg_role_session_field "$f" session)"
    if [ "$v" = "$sid" ]; then
      cat "$f" 2>/dev/null || true
      return 0
    fi
  done
  return 0
}
