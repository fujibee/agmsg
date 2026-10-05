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
  # Record messaging_socket/claude_config_dir for every (team, agent) pair
  # this session embodies. Only an EXISTING role-session record is updated
  # (agmsg_role_session_set_messaging's own contract) -- a pair with no prior
  # actas-claim record gets nothing written, exactly like Codex's
  # role_session_missing seat.
  if ! declare -F agmsg_role_session_set_messaging >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$SKILL_DIR/scripts/lib/role-session.sh"
  fi

  # Same guard shape codex-record-session.sh applies to CODEX_HOME: anything
  # that is not an absolute path, or that carries a control character, is
  # never published as a delivery destination (a malformed value is worse
  # than none -- it would look addressable and silently never deliver).
  local socket=""
  case "${CLAUDE_CODE_MESSAGING_SOCKET:-}" in
    uds:/*) socket="${CLAUDE_CODE_MESSAGING_SOCKET#uds:}" ;;
    /*) socket="${CLAUDE_CODE_MESSAGING_SOCKET}" ;;
  esac
  case "$socket" in *[[:cntrl:]]*) socket="" ;; esac

  local config_dir="${CLAUDE_CONFIG_DIR:-${HOME:+$HOME/.claude}}"
  case "$config_dir" in
    *[[:cntrl:]]*) config_dir="" ;;
    /*) ;;
    *) config_dir="" ;;
  esac

  while IFS=$'\t' read -r pair_team pair_agent; do
    [ -n "$pair_team" ] || continue
    agmsg_role_session_set_messaging "$pair_team" "$pair_agent" "$socket" "$config_dir"
  done <<< "$PAIRS"

  # Only when agmsgd's own executor is actually ready do we skip the Monitor
  # directive (mirrors codex's plug: a Monitor-less delivery path must be
  # verifiably live before this session stops arming its own fallback). A
  # daemon that is merely installed but not running leaves Monitor delivery
  # exactly as it is today.
  if ! declare -F agmsg_daemon_read_state >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$SKILL_DIR/scripts/lib/daemon-state.sh"
  fi
  agmsg_daemon_read_state
  if [ "$AGMSGD_HEALTH" = ready ] && [ -n "$socket" ]; then
    cat <<EOF
AGMSG delivery: agmsgd is running and will deliver to this session directly (native channel). No Monitor needed.
EOF
    exit 0
  fi
}
