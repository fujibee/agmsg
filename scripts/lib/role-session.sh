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
_agmsg_role_session_path() {
  local team="$1" agent="$2" t a
  t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/role-session.%s__%s' "$(_actas_lock_dir)" "$t" "$a"
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
  path="$(_agmsg_role_session_path "$team" "$agent")" || return 0
  dir="$(_actas_lock_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
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
  path="$(_agmsg_role_session_path "$team" "$agent")" || return 0
  _agmsg_role_session_field "$path" "$key"
}

# Read a single field from a record file. Empty if file/field absent.
_agmsg_role_session_field() {
  local path="$1" key="$2"
  [ -f "$path" ] || return 0
  # First match only; value is everything after the first '='.
  sed -n "s/^${key}=//p" "$path" 2>/dev/null | head -1
}

# Read back the recorded bare session id for (team, agent). Empty if no record.
# This is the primary getter used by the boot wrapper (PR-C).
agmsg_role_session_uuid() {
  local team="$1" agent="$2" path
  path="$(_agmsg_role_session_path "$team" "$agent")" || return 0
  _agmsg_role_session_field "$path" session
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
