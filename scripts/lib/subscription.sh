#!/usr/bin/env bash
# Shared subscription helpers for live watchers and one-shot pending checks.
#
# Required caller-set variables:
#   SKILL_DIR  agmsg skill root

: "${SKILL_DIR:?subscription.sh requires SKILL_DIR}"

# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/resolve-project.sh"
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/role-session.sh"

agmsg_sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# Resolve the (team, agent) rows this process should receive for.
#
# Usage:
#   agmsg_subscription_pairs <project> <type> <owner_id> [active_name] [claim]
#
# `owner_id` is the current session/instance token used for actas ownership.
# When `active_name` is set, only that agent name is kept. When the final
# argument is `claim`, the helper attempts to claim each active pair for
# `owner_id`, matching watch.sh actas mode.
_agmsg_subscription_filter_locks() {
  local pairs="$1" owner_id="$2" active_name="${3:-}" claim_mode="${4:-}"
  local filtered skipped held state result
  [ -n "$pairs" ] || return 0

  filtered=""
  skipped=""
  held=""
  local team agent
  while IFS=$'\t' read -r team agent; do
    [ -z "$team" ] && continue
    state=$(actas_lock_state "$team" "$agent" "$owner_id")
    case "$state" in
      other:*)
        if [ -n "$active_name" ] && [ "$claim_mode" = "claim" ]; then
          held="${held:+$held }${team}/${agent}(${state#other:})"
        else
          skipped="${skipped:+$skipped }${team}/${agent}(${state#other:})"
        fi
        continue
        ;;
    esac

    if [ -n "$active_name" ] && [ "$claim_mode" = "claim" ]; then
      result=$(actas_lock_claim "$team" "$agent" "$owner_id" 2>/dev/null || true)
      case "$result" in
        held:*)
          held="${held:+$held }${team}/${agent}(${result#held:})"
          continue
          ;;
      esac
    fi

    filtered="${filtered:+$filtered$'\n'}${team}"$'\t'"${agent}"
  done <<< "$pairs"

  if [ -n "$skipped" ]; then
    echo "agmsg watch: skipping pairs held by other sessions: $skipped" >&2
  fi
  if [ -n "$held" ]; then
    echo "agmsg watch: cannot claim (held by other sessions): $held" >&2
    echo "agmsg watch: run \`/agmsg drop <name>\` in the owning session, then retry." >&2
    return 1
  fi

  printf '%s' "$filtered"
}

_agmsg_subscription_registered_pairs() {
  local project="$1" type="$2" active_name="${3:-}" pairs
  pairs="$("$SKILL_DIR/scripts/identities.sh" "$project" "$type")"
  if [ -n "$active_name" ]; then
    pairs=$(printf '%s\n' "$pairs" | awk -v n="$active_name" -F'\t' 'NF >= 2 && $2 == n')
  fi
  printf '%s' "$pairs"
}

# Narrow to a role-session record only when it identifies exactly one current
# registration for this project/type. Zero or multiple matches remain broad.
_agmsg_subscription_narrow_session() {
  local pairs="$1" project="$2" type="$3" session_token="$4"
  local bare_sid project_phys records matches="" team agent record_type record_project record_phys count
  [ -n "$session_token" ] || { printf '%s' "$pairs"; return 0; }
  bare_sid="$(agmsg_instance_bare_sid "$session_token")"
  project_phys="$(agmsg_canonical_path "$project" 2>/dev/null || printf '%s' "$project")"
  records="$(agmsg_role_session_pairs_by_sid "$bare_sid" 2>/dev/null || true)"
  while IFS=$'\t' read -r team agent record_type record_project; do
    [ -n "$team" ] && [ -n "$agent" ] || continue
    [ -z "$record_type" ] || [ "$record_type" = "$type" ] || continue
    if [ -n "$record_project" ]; then
      record_phys="$(agmsg_canonical_path "$record_project" 2>/dev/null || printf '%s' "$record_project")"
      [ "$record_phys" = "$project_phys" ] || continue
    fi
    printf '%s\n' "$pairs" | grep -Fxq "${team}"$'\t'"${agent}" || continue
    printf '%s\n' "$matches" | grep -Fxq "${team}"$'\t'"${agent}" && continue
    matches="${matches:+$matches$'\n'}${team}"$'\t'"${agent}"
  done <<< "$records"
  count=$(printf '%s\n' "$matches" | awk 'NF { n++ } END { print n+0 }')
  if [ "$count" -eq 1 ]; then
    printf '%s' "$matches"
  else
    printf '%s' "$pairs"
  fi
}

agmsg_subscription_pairs() {
  local project="$1" type="$2" owner_id="$3" active_name="${4:-}" claim_mode="${5:-}" pairs
  pairs="$(_agmsg_subscription_registered_pairs "$project" "$type" "$active_name")"
  _agmsg_subscription_filter_locks "$pairs" "$owner_id" "$active_name" "$claim_mode"
}

agmsg_session_subscription_pairs() {
  local project="$1" type="$2" owner_id="$3" session_token="${4:-}" active_name="${5:-}" claim_mode="${6:-}" pairs
  pairs="$(_agmsg_subscription_registered_pairs "$project" "$type" "$active_name")"
  pairs="$(_agmsg_subscription_narrow_session "$pairs" "$project" "$type" "$session_token")"
  _agmsg_subscription_filter_locks "$pairs" "$owner_id" "$active_name" "$claim_mode"
}

# Build a SQL predicate for a tab-separated pair list.
agmsg_subscription_where() {
  local pairs="$1"
  local where="" team agent t_esc a_esc pair
  while IFS=$'\t' read -r team agent; do
    [ -z "$team" ] && continue
    t_esc=$(agmsg_sql_escape "$team")
    a_esc=$(agmsg_sql_escape "$agent")
    pair="(team='$t_esc' AND to_agent='$a_esc')"
    where="${where:+$where OR }$pair"
  done <<< "$pairs"
  printf '%s' "$where"
}
