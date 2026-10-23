#!/usr/bin/env bash
# claude-code SessionStart plug — record this session's own cross-session-
# messaging destination, and (when agmsgd's native channel is up) skip the
# generic Monitor directive the same way codex's own plug skips it.
#
# Sourced by session-start.sh in its global context (so it sees TYPE, PROJECT,
# RUN_DIR, SKILL_DIR, PAIRS and SESSION_ID). Defines agmsg_session_start,
# overriding session-start.sh's default no-op.
#
# Measured 2026-10-05 (memory/design/2026-10-05-cross-session-messaging-socket-
# measurement.md and its addendum) and ruled on the same day
# (memory/design/2026-09-22-agmsgd-arch-8-delivery-driver.md §12/§12.1):
#   - CLAUDE_CODE_MESSAGING_SOCKET changes on every `--resume` (new process,
#     new pid-named socket) but not on /clear or /compact, so this must run
#     and overwrite on every SessionStart, never cache or trust a stale value.
#   - CLAUDE_CONFIG_DIR (falling back to ~/.claude) is the base agmsgd needs
#     to find this session's own transcript later; it must NEVER be hardcoded
#     to ~/.claude, since this machine's own accounts live elsewhere.

agmsg_session_start() {
  if ! declare -F agmsg_claude_code_native_target >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${SKILL_DIR:-}/scripts/lib/role-session.sh"
  fi

  # A malformed or missing destination is never published (see
  # agmsg_claude_code_native_target).
  local target socket config_dir
  target="$(agmsg_claude_code_native_target)" || return 0
  socket="${target%%$'\t'*}"
  config_dir="${target#*$'\t'}"

  # Check every OTHER precondition FIRST, before ever touching a lock
  # (#1577 re-review): a session that cannot possibly use the native path
  # (daemon not ready, Windows, no usable socket) must claim NOTHING. The
  # earlier version claimed first and checked these after, so a session with
  # agmsgd disabled or no socket could still silently seize an actas lock it
  # was never going to use -- only Monitor's own watch.sh was ever supposed
  # to touch that lock in that case.
  if ! command -v _agmsg_detect_platform >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${SKILL_DIR:-}/scripts/lib/compat.sh"
  fi
  _agmsg_detect_platform
  if ! declare -F agmsg_daemon_read_state >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${SKILL_DIR:-}/scripts/lib/daemon-state.sh"
  fi
  agmsg_daemon_read_state
  # A project that chose something other than agmsgd keeps the Monitor path.
  agmsg_daemon_apply_project_choice claude-code "${PROJECT:-}"
  [ "${AGMSGD_HEALTH:-}" = ready ] || return 0
  if ! agmsg_claude_code_native_storage_ready; then
    echo "AGMSG delivery: agmsgd is running, but its Claude channel only reads the sqlite storage and this install's storage config is not usable for it, so the native channel is not used. Next: arm the Monitor below."
    return 0
  fi

  # Claim ONLY the single role this session is actually resuming as -- never
  # loop over every pair whose record happens to share this bare sid
  # (#1577 re-review: the same conversation can carry session=<bare sid>
  # into MORE THAN ONE role's record over its life, e.g. actas alice then
  # later actas bob; a resumed session must take back only whichever one
  # role it is now, not seize every stale name it ever wore).
  #
  # The seat is chosen the way session-start.sh's own resume does: only the
  # (team, agent) pairs registered for THIS project count, so a record left
  # by a team that is no longer registered cannot make the answer ambiguous.
  # A pair is a candidate when its role-session record carries this bare sid,
  # or when this sid owns its actas lock (a record with no session row is
  # still this session's seat). Still exactly one or none: a second
  # candidate refuses rather than guesses -- but says so.
  if ! command -v actas_lock_claim >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${SKILL_DIR:-}/scripts/lib/actas-lock.sh"
  fi
  local bare_sid my_instance pair_team="" pair_agent=""
  bare_sid="$(agmsg_instance_bare_sid "${SESSION_ID:-}" 2>/dev/null || true)"
  my_instance="$(agmsg_normalize_instance_id "${SESSION_ID:-}" "${TYPE:-}" 2>/dev/null || true)"
  [ -n "$bare_sid" ] || return 0
  # An instance id without a process id cannot claim the seat's lock; that is
  # reported below, once the seat is known, rather than skipped silently.
  local pid_unresolved=0
  agmsg_instance_is_composite "$my_instance" 2>/dev/null || pid_unresolved=1
  local _tab _p_team _p_agent _rs _own _owner _n=0
  _tab="$(printf '\t')"
  while IFS="$_tab" read -r _p_team _p_agent; do
    [ -n "$_p_team" ] && [ -n "$_p_agent" ] || continue
    _rs="$(agmsg_role_session_uuid "$_p_team" "$_p_agent" 2>/dev/null || true)"
    _owner=""
    _own="$(actas_lock_read "$_p_team" "$_p_agent" 2>/dev/null)" || _own=""
    if [ "${_own%%"$_tab"*}" = ok ]; then
      _owner="$(agmsg_instance_bare_sid "${_own#*"$_tab"}" 2>/dev/null || true)"
    fi
    if [ "$_rs" = "$bare_sid" ] || [ "$_owner" = "$bare_sid" ]; then
      _n=$((_n + 1)); pair_team="$_p_team"; pair_agent="$_p_agent"
    fi
  done <<EOF
${PAIRS:-}
EOF
  if [ "$_n" -eq 0 ]; then
    # Nothing recorded for this session. The seat is still decided when this
    # project has exactly one registered pair of this type: that is the seat
    # session-start.sh's own Monitor directive would watch (it only falls
    # back to the generic watcher for a single pair), so take it.
    if [ "$(printf '%s\n' "${PAIRS:-}" | grep -c '.' || true)" -eq 1 ]; then
      IFS="$_tab" read -r pair_team pair_agent <<EOF
${PAIRS:-}
EOF
    else
      echo "AGMSG delivery: agmsgd is running, but this project has several registered seats and none is recorded for this session, so the native channel is not used. Next: run /agmsg actas <name> (it switches to direct delivery), or arm the Monitor below."
      return 0
    fi
  elif [ "$_n" -gt 1 ]; then
    echo "AGMSG delivery: agmsgd is running, but this session is recorded under $_n registered seats, so the native channel is not used. Next: arm the Monitor below; the extra records stay until they are cleaned up."
    return 0
  fi

  if [ "$pid_unresolved" = 1 ]; then
    # The record still holds the destination of the process this session
    # replaced, so say the seat cannot be reached rather than leave it looking
    # addressable. Only a record that names this session is cleared (checked
    # under the write lock): a seat held by another live session keeps its own
    # destination.
    if agmsg_role_session_mark_messaging_blocked "$pair_team" "$pair_agent" seat_pid_unresolved "$bare_sid"; then
      echo "AGMSG delivery: agmsgd is running, but this session's own process could not be identified, so the native channel is not used and the old delivery record for $pair_agent@$pair_team was cleared (agmsg daemon status shows seat_pid_unresolved). Next: arm the Monitor below."
    else
      echo "AGMSG delivery: agmsgd is running, but this session's own process could not be identified, so the native channel is not used. Next: arm the Monitor below."
    fi
    return 0
  fi

  # actas_lock_claim is the write gate -- the SAME primitive watch.sh uses to
  # reclaim a role's lock across --resume (session-start.sh's own 4th-arg
  # "Role-aware resume" relies on exactly this, via watch.sh, when Monitor
  # fires; this plug needs its own call since it may skip Monitor entirely).
  # Its "mine" verdict requires an EXACT token match; a mismatched owner
  # that is still genuinely alive fails the claim outright, and only a
  # mismatched DEAD owner reclaims -- so two live processes that happen to
  # share a bare sid (same hazard class as #1568) can never both end up
  # "owning" the same pair, while a real --resume (new pid, old pid now
  # dead) correctly reclaims.
  local claim_result
  claim_result="$(actas_lock_claim "$pair_team" "$pair_agent" "$my_instance" 2>/dev/null || true)"
  [ -n "$claim_result" ] || claim_result="unknown:claim_failed"
  if [ "$claim_result" != ok ]; then
    echo "AGMSG delivery: agmsgd is running, but seat $pair_agent@$pair_team could not be claimed ($claim_result), so the native channel is not used. Next: arm the Monitor below."
    return 0
  fi

  # Write, then read back: this is the SAME check the daemon itself applies
  # (messaging_socket/claude_config_dir both present and non-empty) before
  # it will ever address this seat, so "the record actually took" must be
  # verified here too, not assumed from the write call returning.
  # Only now, holding the lock, may a missing record be created: an existing
  # record belongs to whoever it names, and the claim above is what shows the
  # seat is ours.
  if [ -z "$(agmsg_role_session_get "$pair_team" "$pair_agent" type 2>/dev/null || true)" ]; then
    agmsg_role_session_record "$pair_team" "$pair_agent" "$bare_sid" \
      "$(agmsg_canonical_path "${PROJECT:-}" 2>/dev/null || printf '%s' "${PROJECT:-}")" "${TYPE:-}" "$my_instance"
  fi
  if agmsg_role_session_publish_messaging "$pair_team" "$pair_agent" "$socket" "$config_dir" "$bare_sid" "${CLAUDE_CODE_MESSAGING_TOKEN:-}"; then
    if agmsg_daemon_claude_seat_held "$pair_team" "$pair_agent" "$socket"; then
      echo "AGMSG delivery: agmsgd's notices are being held by this Claude Code (its crossSessionInbound setting or permission mode), so the native channel is not used. Next: arm the Monitor below."
      return 0
    fi
    cat <<EOF
AGMSG delivery: agmsgd is running and will deliver to this session directly (native channel). No Monitor needed.
EOF
    exit 0
  fi
  echo "AGMSG delivery: agmsgd is running, but the delivery record for $pair_agent@$pair_team did not take, so the native channel is not used. Next: arm the Monitor below, then run agmsg doctor."
}
