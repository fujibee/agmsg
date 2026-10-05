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

  # Only touch a pair THIS session actually, currently holds the actas lock
  # for -- never every pair registered for the project (#1577 review): two
  # seats sharing a project each have their OWN process and OWN socket, and
  # writing one's socket into the other's record would misdeliver agmsgd's
  # nudge to the wrong seat entirely. The lock, not the record's own (possibly
  # stale, see agmsg_role_session_set_messaging's session= handling) session=
  # field, is the live ownership fact -- the same primitive session-start.sh's
  # own narrowing block below already trusts for exactly this question.
  if ! command -v actas_lock_read >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${SKILL_DIR:-}/scripts/lib/actas-lock.sh"
  fi
  local bare_sid my_instance
  bare_sid="$(agmsg_instance_bare_sid "${SESSION_ID:-}" 2>/dev/null || true)"
  # The FULL composite "<sid>.<pid>" identifies THIS process uniquely; the
  # bare sid alone does not when another --resume/--continue of the same
  # underlying conversation is live under a different pid at the same time
  # (#1577 re-review: comparing bare sids let one such process's SessionStart
  # write its socket into the OTHER's already-claimed record -- same hazard
  # class as #1568). When the pid can't be resolved, agmsg_normalize_instance_id
  # degrades to the bare sid and warns on stderr; treat that exactly like any
  # other proof failure below -- never write on an unproven identity.
  my_instance="$(agmsg_normalize_instance_id "${SESSION_ID:-}" "${TYPE:-}" 2>/dev/null || true)"

  # Write, then read every OWNED pair back: this is the SAME check the daemon
  # itself applies (messaging_socket/claude_config_dir both present and
  # non-empty) before it will ever address this seat, so "the record actually
  # took" must be verified here too, not assumed from the write call
  # returning. No owned pair verified this way leaves this session exactly as
  # addressable-by-daemon as it already was -- never the one that silences
  # Monitor when in doubt (#1577 review).
  local any_pair_confirmed=0
  local pair_team pair_agent
  while IFS=$'\t' read -r pair_team pair_agent; do
    [ -n "$pair_team" ] || continue
    local lock_row lock_status lock_owner
    lock_row="$(actas_lock_read "$pair_team" "$pair_agent" 2>/dev/null)" || lock_row="unreadable	"
    lock_status="${lock_row%%$'\t'*}"
    [ "$lock_status" = ok ] || continue
    lock_owner="${lock_row#*$'\t'}"
    [ -n "$lock_owner" ] || continue
    # Exact match on the full composite id only -- a bare-sid match alone is
    # not proof of ownership (see above).
    agmsg_instance_is_composite "$my_instance" || continue
    [ "$lock_owner" = "$my_instance" ] || continue

    agmsg_role_session_set_messaging "$pair_team" "$pair_agent" "$socket" "$config_dir" "$bare_sid"
    local readback_socket readback_config_dir readback_session
    readback_socket="$(agmsg_role_session_get "$pair_team" "$pair_agent" messaging_socket 2>/dev/null || true)"
    readback_config_dir="$(agmsg_role_session_get "$pair_team" "$pair_agent" claude_config_dir 2>/dev/null || true)"
    readback_session="$(agmsg_role_session_uuid "$pair_team" "$pair_agent" 2>/dev/null || true)"
    if [ -n "$socket" ] && [ "$readback_socket" = "$socket" ] && \
       [ -n "$config_dir" ] && [ "$readback_config_dir" = "$config_dir" ] && \
       [ -n "$bare_sid" ] && [ "$readback_session" = "$bare_sid" ]; then
      any_pair_confirmed=1
    fi
  done <<< "${PAIRS:-}"

  # Windows has no native-channel implementation yet (named pipe + mandatory
  # auth line, separate work) -- never claim this session is daemon-reachable
  # there, no matter what the record says.
  if ! command -v _agmsg_detect_platform >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${SKILL_DIR:-}/scripts/lib/compat.sh"
  fi
  _agmsg_detect_platform

  # Only when agmsgd's own executor is actually ready, this is not Windows,
  # AND at least one owned pair's record round-tripped correctly (including
  # the session= field) do we skip the Monitor directive (mirrors codex's
  # plug: a Monitor-less delivery path must be verifiably live before this
  # session stops arming its own fallback). Any one of these missing leaves
  # Monitor delivery exactly as it is today -- when in doubt, arm Monitor
  # (#1577 review).
  if ! declare -F agmsg_daemon_read_state >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "${SKILL_DIR:-}/scripts/lib/daemon-state.sh"
  fi
  agmsg_daemon_read_state
  if [ "${AGMSGD_HEALTH:-}" = ready ] && [ "$_agmsg_platform" != msys ] && [ "$any_pair_confirmed" = 1 ]; then
    cat <<EOF
AGMSG delivery: agmsgd is running and will deliver to this session directly (native channel). No Monitor needed.
EOF
    exit 0
  fi
}
