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
  if ! declare -F agmsg_role_session_set_messaging >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${SKILL_DIR:-}/scripts/lib/role-session.sh"
  fi

  # Same guard shape codex-record-session.sh applies to CODEX_HOME: anything
  # that is not an absolute path, or that carries a control character, is
  # never published as a delivery destination (a malformed value is worse
  # than none -- it would look addressable and silently never deliver).
  local raw_socket="${CLAUDE_CODE_MESSAGING_SOCKET:-}" socket=""
  case "$raw_socket" in
    uds:/*) socket="${raw_socket#uds:}" ;;
    /*) socket="$raw_socket" ;;
  esac
  case "$socket" in *[[:cntrl:]]*) socket="" ;; esac

  local config_dir="${CLAUDE_CONFIG_DIR:-${HOME:+$HOME/.claude}}"
  case "$config_dir" in
    *[[:cntrl:]]*) config_dir="" ;;
    /*) ;;
    *) config_dir="" ;;
  esac

  # Check every OTHER precondition FIRST, before ever touching a lock
  # (#1577 re-review): a session that cannot possibly use the native path
  # (daemon not ready, Windows, no usable socket) must claim NOTHING. The
  # earlier version claimed first and checked these after, so a session with
  # agmsgd disabled or no socket could still silently seize an actas lock it
  # was never going to use -- only Monitor's own watch.sh was ever supposed
  # to touch that lock in that case.
  if [ -z "$socket" ]; then return 0; fi
  if ! command -v _agmsg_detect_platform >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${SKILL_DIR:-}/scripts/lib/compat.sh"
  fi
  _agmsg_detect_platform
  [ "$_agmsg_platform" != msys ] || return 0
  if ! declare -F agmsg_daemon_read_state >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${SKILL_DIR:-}/scripts/lib/daemon-state.sh"
  fi
  agmsg_daemon_read_state
  [ "${AGMSGD_HEALTH:-}" = ready ] || return 0

  # Claim ONLY the single role this session is actually resuming as -- never
  # loop over every pair whose record happens to share this bare sid
  # (#1577 re-review: the same conversation can carry session=<bare sid>
  # into MORE THAN ONE role's record over its life, e.g. actas alice then
  # later actas bob; a resumed session must take back only whichever one
  # role it is now, not seize every stale name it ever wore). Delegates to
  # agmsg_role_session_match_unique -- the SAME ambiguity rule session-
  # start.sh's own narrowing uses elsewhere in this file: a second
  # qualifying record makes the whole lookup refuse rather than guess.
  if ! command -v agmsg_role_session_match_unique >/dev/null 2>&1 \
     || ! command -v actas_lock_claim >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${SKILL_DIR:-}/scripts/lib/actas-lock.sh"
  fi
  local bare_sid my_instance project_phys match pair_team pair_agent
  bare_sid="$(agmsg_instance_bare_sid "${SESSION_ID:-}" 2>/dev/null || true)"
  my_instance="$(agmsg_normalize_instance_id "${SESSION_ID:-}" "${TYPE:-}" 2>/dev/null || true)"
  [ -n "$bare_sid" ] || return 0
  agmsg_instance_is_composite "$my_instance" 2>/dev/null || return 0
  project_phys="$(agmsg_canonical_path "${PROJECT:-}" 2>/dev/null || printf '%s' "${PROJECT:-}")"
  match="$(agmsg_role_session_match_unique "${TYPE:-}" "$project_phys" "$bare_sid" 2>/dev/null)" || return 0
  pair_team="${match%%$'\t'*}"
  pair_agent="${match#*$'\t'}"
  [ -n "$pair_team" ] && [ -n "$pair_agent" ] || return 0

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
  claim_result="$(actas_lock_claim "$pair_team" "$pair_agent" "$my_instance" 2>/dev/null)" || claim_result="unknown:claim_failed"
  [ "$claim_result" = ok ] || return 0

  # Write, then read back: this is the SAME check the daemon itself applies
  # (messaging_socket/claude_config_dir both present and non-empty) before
  # it will ever address this seat, so "the record actually took" must be
  # verified here too, not assumed from the write call returning.
  agmsg_role_session_set_messaging "$pair_team" "$pair_agent" "$socket" "$config_dir" "$bare_sid"
  local readback_socket readback_config_dir readback_session
  readback_socket="$(agmsg_role_session_get "$pair_team" "$pair_agent" messaging_socket 2>/dev/null || true)"
  readback_config_dir="$(agmsg_role_session_get "$pair_team" "$pair_agent" claude_config_dir 2>/dev/null || true)"
  readback_session="$(agmsg_role_session_uuid "$pair_team" "$pair_agent" 2>/dev/null || true)"
  if [ "$readback_socket" = "$socket" ] && [ -n "$config_dir" ] && \
     [ "$readback_config_dir" = "$config_dir" ] && [ "$readback_session" = "$bare_sid" ]; then
    cat <<EOF
AGMSG delivery: agmsgd is running and will deliver to this session directly (native channel). No Monitor needed.
EOF
    exit 0
  fi
}
