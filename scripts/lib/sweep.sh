#!/usr/bin/env bash
# sweep.sh -- explicit leader-side fan-out for a team's self-repair (#1152).

[ -n "${_AGMSG_SWEEP_SH:-}" ] && return 0
_AGMSG_SWEEP_SH=1

# This is the only seam between the command and #1155's read-only census. The
# census is shared infrastructure, not a sweep-owned scan: diagnostics and this
# command consume the same observation independently and never consume one
# another's output. Once #1155 lands, the body is exactly the production
# primitive. Keeping the call here also lets the orchestrator tests replace the
# observation without an environment-based target injection path in the shipped
# command.
_agmsg_sweep_agent_rows() {
  declare -F agmsg_terminal_agents >/dev/null 2>&1 || return 127
  agmsg_terminal_agents
}

# These two adapters are intentionally fail-closed until the instance-aware
# label reader and compare-and-poke ABI land. Neither may be emulated by loading
# a driver against the leader's environment: two terminal instances routinely
# contain the same bare pane id.
_agmsg_sweep_label_at() { return 127; }       # <kind> <instance> <pane>
_agmsg_sweep_poke_fenced() { return 127; }    # <kind> <instance> <pane> <owner> <text>
_agmsg_sweep_instance_allowed() { return 127; } # <team> <kind> <instance>
_agmsg_sweep_locator() {                      # <kind> <instance> <pane>
  declare -F agmsg_locator_compose >/dev/null 2>&1 || return 127
  agmsg_locator_compose "$1" "$2" "$3"
}

# Is <label> exactly one local registration in <team> whose type agrees with
# the process observation? Prints the agent name on success. A label is only a
# target-selection fact; it is never used as the terminal address.
_agmsg_sweep_roster_match() {   # <team> <label> <type>
  local team="$1" label="$2" type="$3" cfg esc out
  cfg="$SKILL_DIR/teams/$team/config.json"
  [ -r "$cfg" ] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 2
  esc="$(sed "s/'/''/g" "$cfg")" || return 2
  out="$(sqlite3 -noheader :memory: "
    WITH cfg(j) AS (SELECT json('$esc')),
    matches(agent) AS (
      SELECT a.key
      FROM cfg, json_each(json_extract(cfg.j, '\$.agents')) AS a
      WHERE '$team:' || a.key = '$(printf '%s' "$label" | sed "s/'/''/g")'
        AND EXISTS (
          SELECT 1
          FROM json_each(json_extract(a.value, '\$.registrations')) AS r
          WHERE json_extract(r.value, '\$.type') = '$(printf '%s' "$type" | sed "s/'/''/g")'
        )
    )
    SELECT CASE WHEN count(*) = 1 THEN min(agent) ELSE '' END FROM matches;
  " 2>/dev/null)" || return 2
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

_agmsg_sweep_report_skip() {   # <kind> <instance> <pane> <reason>
  printf 'skipped kind=%s instance=%s pane=%s reason=%s\n' "$1" "$2" "$3" "$4" >&2
}

# Serialize one argument for the command line typed into an agent. Instance
# paths may contain spaces and quotes; raw interpolation would let one ref turn
# into several arguments before `fix` sees it. POSIX single-quote form is
# understood by every shell-backed command parser used by the agent skills.
_agmsg_sweep_quote_arg() {   # <value>
  local value="${1-}" escaped
  escaped="$(printf '%s' "$value" | sed "s/'/'\\\\''/g")" || return 1
  printf "'%s'" "$escaped"
}

# Consume #1155 rows:
#   kind<TAB>instance<TAB>pane<TAB>state<TAB>payload
# plus its ! / !! / ? hole rows. Every row that is not a complete, corroborated
# agent candidate is loud and makes the command non-zero.
agmsg_sweep_run() {   # <team>
  local team="${1-}" rows rows_rc=0 rc=0 tab line
  local kind instance pane state payload extra label label_rc agent owner ref locator_rc text poke_rc
  [ -n "$team" ] || { echo 'sweep: team is required' >&2; return 2; }
  tab="$(printf '\t')"

  if rows="$(_agmsg_sweep_agent_rows)"; then rows_rc=0; else rows_rc=$?; fi
  if [ "$rows_rc" -ne 0 ]; then
    echo "sweep: pane/agent enumeration failed (rc=$rows_rc); nothing was written" >&2
    return 1
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS="$tab" read -r kind instance pane state payload extra <<EOF
$line
EOF
    if [ -n "${extra:-}" ]; then
      _agmsg_sweep_report_skip "${kind:-?}" "${instance:-?}" "${pane:-?}" malformed_row
      rc=1
      continue
    fi
    case "$kind" in
      '!'|'!!'|'?')
        _agmsg_sweep_report_skip "$kind" "${instance:-?}" "${pane:-?}" enumeration_hole
        rc=1
        continue
        ;;
    esac
    if [ -z "${kind:-}" ] || [ -z "${instance:-}" ] || [ -z "${pane:-}" ] \
       || [ -z "${state:-}" ]; then
      _agmsg_sweep_report_skip "${kind:-?}" "${instance:-?}" "${pane:-?}" malformed_row
      rc=1
      continue
    fi
    case "$state" in
      agent) [ -n "${payload:-}" ] || {
          _agmsg_sweep_report_skip "$kind" "$instance" "$pane" malformed_agent_row
          rc=1
          continue
        } ;;
      none|unknown)
        _agmsg_sweep_report_skip "$kind" "$instance" "$pane" "$state${payload:+:$payload}"
        rc=1
        continue
        ;;
      *)
        _agmsg_sweep_report_skip "$kind" "$instance" "$pane" malformed_state
        rc=1
        continue
        ;;
    esac

    # A team-scoped sweep may not wander into every local terminal instance.
    # The instance must occur in that team's own recorded placements. Unknown
    # is a refusal, not permission: another team's instance may reuse every bare
    # pane id in this row.
    if ! _agmsg_sweep_instance_allowed "$team" "$kind" "$instance"; then
      _agmsg_sweep_report_skip "$kind" "$instance" "$pane" instance_not_allowed
      rc=1
      continue
    fi

    label=""; label_rc=0
    label="$(_agmsg_sweep_label_at "$kind" "$instance" "$pane" 2>/dev/null)" || label_rc=$?
    if [ "$label_rc" -ne 0 ] || [ -z "$label" ]; then
      _agmsg_sweep_report_skip "$kind" "$instance" "$pane" "label_unavailable:rc_$label_rc"
      rc=1
      continue
    fi
    agent=""
    agent="$(_agmsg_sweep_roster_match "$team" "$label" "$payload" 2>/dev/null)" || agent=""
    if [ -z "$agent" ]; then
      _agmsg_sweep_report_skip "$kind" "$instance" "$pane" roster_label_process_mismatch
      rc=1
      continue
    fi

    # The address and the instruction are made once, from this row's variables,
    # through the shared terminal-registry grammar. This command neither parses
    # nor hand-serializes a locator: four readers doing that would become four
    # subtly different grammars. Do not parse the result back into a bare pane
    # for the write; that would create a second address derivation that could
    # cross instances.
    ref=""; locator_rc=0
    # Composer stderr carries its named refusal (instance_malformed,
    # pane_malformed, unknown_kind). Preserve it: a generic rc without the
    # grammar reason would make malformed input indistinguishable from an
    # unavailable implementation.
    ref="$(_agmsg_sweep_locator "$kind" "$instance" "$pane")" || locator_rc=$?
    if [ "$locator_rc" -ne 0 ] || [ -z "$ref" ]; then
      _agmsg_sweep_report_skip "$kind" "$instance" "$pane" "locator_unavailable:rc_$locator_rc"
      rc=1
      continue
    fi
    text="\$agmsg fix --pane $(_agmsg_sweep_quote_arg "$ref")"
    owner="$team/$agent"
    poke_rc=0
    _agmsg_sweep_poke_fenced "$kind" "$instance" "$pane" "$owner" "$text" >/dev/null || poke_rc=$?
    if [ "$poke_rc" -ne 0 ]; then
      _agmsg_sweep_report_skip "$kind" "$instance" "$pane" "write_fence_or_poke_failed:rc_$poke_rc"
      rc=1
      continue
    fi
    printf 'sent team=%s agent=%s type=%s pane=%s\n' "$team" "$agent" "$payload" "$ref"
  done <<EOF
$rows
EOF
  return "$rc"
}

# LIMIT: the command can target only locations the census can observe. A seat
# whose real location is absent from that snapshot cannot be swept, and a
# detector using the same census cannot diagnose that seat's lone bad claim by
# comparing it with a location the census never saw. Never fill that hole from
# a placement record: the record is the projection being repaired.
