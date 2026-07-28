#!/usr/bin/env bash
# Shared subscription helpers for live watchers and one-shot pending checks.
#
# Required caller-set variables:
#   SKILL_DIR  agmsg skill root

: "${SKILL_DIR:?subscription.sh requires SKILL_DIR}"

agmsg_sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

_agmsg_subscription_rollback_or_report() {
  local pairs="$1" owner_id="$2" retained
  if retained="$(actas_lock_rollback_pairs "$pairs" "$owner_id")"; then
    return 0
  fi
  echo "agmsg watch: rollback=incomplete locked=$retained" >&2
  return 1
}

# Resolve the (team, agent) rows this process should receive for.
#
# Usage:
#   agmsg_subscription_pairs <project> <type> <owner_id> [active_name] [claim]
#
# `owner_id` is the current session/instance token used for actas ownership.
# When `active_name` is set, only that agent name is kept. When the final
# argument is `claim`, the helper attempts to claim each active pair for
# `owner_id`, matching watch.sh actas mode.
agmsg_subscription_pairs() {
  local project="$1" type="$2" owner_id="$3" active_name="${4:-}" claim_mode="${5:-}"
  local scripts_dir="$SKILL_DIR/scripts"
  local pairs filtered skipped held state result claim_status claimed rollback reason

  pairs="$("$scripts_dir/identities.sh" "$project" "$type")"
  if [ -n "$active_name" ]; then
    pairs=$(printf '%s\n' "$pairs" | awk -v n="$active_name" -F'\t' 'NF >= 2 && $2 == n')
  fi

  [ -n "$pairs" ] || return 0

  filtered=""
  skipped=""
  held=""
  claimed=""
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
      claim_status=0
      if result=$(actas_lock_claim "$team" "$agent" "$owner_id" 2>/dev/null); then
        claim_status=0
      else
        claim_status=$?
      fi
      if [ "$claim_status" -eq 0 ] && [ -z "$result" ]; then
        if [ "$state" = "free" ]; then
          claimed="${claimed:+$claimed$'\n'}${team}"$'\t'"${agent}"
        fi
      elif [ "$claim_status" -eq 1 ]; then
        case "$result" in
          held:*)
            held="${held:+$held }${team}/${agent}(${result#held:})"
            continue
            ;;
          *) ;;
        esac
        rollback="$claimed"
        [ "$state" = "free" ] \
          && rollback="${rollback:+$rollback$'\n'}${team}"$'\t'"${agent}"
        _agmsg_subscription_rollback_or_report "$rollback" "$owner_id" || true
        echo "agmsg watch: actas claim failed for ${team}/${agent}: claim-protocol" >&2
        return 2
      else
        rollback="$claimed"
        [ "$state" = "free" ] \
          && rollback="${rollback:+$rollback$'\n'}${team}"$'\t'"${agent}"
        _agmsg_subscription_rollback_or_report "$rollback" "$owner_id" || true
        case "$result" in
          error:*) reason="${result#error:}" ;;
          *) reason="claim-protocol" ;;
        esac
        echo "agmsg watch: actas claim failed for ${team}/${agent}: $reason" >&2
        return 2
      fi
    fi

    filtered="${filtered:+$filtered$'\n'}${team}"$'\t'"${agent}"
  done <<< "$pairs"

  if [ -n "$skipped" ]; then
    echo "agmsg watch: skipping pairs held by other sessions: $skipped" >&2
  fi
  if [ -n "$held" ]; then
    _agmsg_subscription_rollback_or_report "$claimed" "$owner_id" || true
    echo "agmsg watch: cannot claim (held by other sessions): $held" >&2
    echo "agmsg watch: run \`/agmsg drop <name>\` in the owning session, then retry." >&2
    return 1
  fi

  printf '%s' "$filtered"
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
