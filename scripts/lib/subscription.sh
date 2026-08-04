#!/usr/bin/env bash
# Shared subscription helpers for live watchers and one-shot pending checks.
#
# Required caller-set variables:
#   SKILL_DIR  agmsg skill root

: "${SKILL_DIR:?subscription.sh requires SKILL_DIR}"

# compat_file_mtime, for the diagnostic below.
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/compat.sh"

agmsg_sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# Diagnose why (team, agent)'s lock reads as owned by `owner` and not by us —
# printed only when an exclusion empties the whole subscription (#605), never
# on every skip, so a normal multi-pair session with one busy pair stays
# quiet. Read-only: makes no decision, changes no behavior, mirrors the same
# branches agmsg_instance_alive (instance-id.sh) already took to reach its
# verdict, so a stale/misjudged lock can be told apart from a genuinely live
# one without reproducing the failure by hand.
_agmsg_subscription_skip_diag() {
  local team="$1" agent="$2" owner="$3"
  local lock_path mtime
  lock_path="$(actas_lock_path "$team" "$agent")"
  mtime="$(compat_file_mtime "$lock_path" 2>/dev/null || true)"
  [ -n "$mtime" ] || mtime="unknown"
  echo "agmsg watch:   lock file: $lock_path (mtime=$mtime)" >&2

  if agmsg_instance_is_composite "$owner"; then
    local pid cc_file cc_content cc_state
    pid="${owner##*.}"
    echo "agmsg watch:   owner token: composite (pid=$pid)" >&2
    if _agmsg_pid_alive "$pid" 2>/dev/null; then
      cc_file="$SKILL_DIR/run/cc-instance.$pid"
      if [ -f "$cc_file" ]; then
        cc_content="$(cat "$cc_file" 2>/dev/null || true)"
        if [ "$cc_content" = "$owner" ]; then
          cc_state="present, contents match — verdict: alive (confirmed)"
        else
          cc_state="present, contents differ ('$cc_content') — verdict: not alive"
        fi
      else
        cc_state="absent — verdict: alive (unconfirmed; no cc-instance record to cross-check the pid against)"
      fi
      echo "agmsg watch:   liveness: pid $pid answers alive; cc-instance.$pid $cc_state" >&2
    else
      echo "agmsg watch:   liveness: pid $pid does not answer alive — verdict: not alive (re-read a moment after the exclusion decision; a race with the original check is possible but narrow)" >&2
    fi
    return 0
  fi

  echo "agmsg watch:   owner token: bare (no pid embedded)" >&2
  local run="$SKILL_DIR/run" f p s matched=""
  if [ -d "$run" ]; then
    for f in "$run"/cc-instance.*; do
      [ -f "$f" ] || continue
      p=${f##*.}
      case "$p" in ''|*[!0-9]*) continue ;; esac
      _agmsg_pid_alive "$p" 2>/dev/null || continue
      s="$(cat "$f" 2>/dev/null || true)"
      if [ "$s" = "$owner" ] \
        || { agmsg_instance_is_composite "$s" && [ "${s%.*}" = "$owner" ]; }; then
        matched="$f"
        break
      fi
    done
  fi
  if [ -n "$matched" ]; then
    echo "agmsg watch:   liveness: matched $matched — verdict: alive" >&2
  else
    echo "agmsg watch:   liveness: no live cc-instance.* file matches — verdict: not alive (re-read a moment after the exclusion decision; a race with the original check is possible but narrow)" >&2
  fi
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
  local pairs filtered skipped skipped_pairs held state result

  pairs="$("$scripts_dir/identities.sh" "$project" "$type")"
  if [ -n "$active_name" ]; then
    pairs=$(printf '%s\n' "$pairs" | awk -v n="$active_name" -F'\t' 'NF >= 2 && $2 == n')
  fi

  [ -n "$pairs" ] || return 0

  filtered=""
  skipped=""
  skipped_pairs=""
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
          skipped_pairs="${skipped_pairs:+$skipped_pairs$'\n'}${team}"$'\t'"${agent}"$'\t'"${state#other:}"
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
    # Diagnostic detail only when the exclusion left nothing to subscribe to
    # (#605) -- a busy pair alongside others that still got through stays quiet.
    if [ -z "$filtered" ]; then
      local diag_team diag_agent diag_owner
      while IFS=$'\t' read -r diag_team diag_agent diag_owner; do
        [ -z "$diag_team" ] && continue
        _agmsg_subscription_skip_diag "$diag_team" "$diag_agent" "$diag_owner"
      done <<< "$skipped_pairs"
    fi
  fi
  if [ -n "$held" ]; then
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
