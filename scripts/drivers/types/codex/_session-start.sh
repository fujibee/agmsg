#!/usr/bin/env bash

# Codex SessionStart plug. Rebind only when the current process exports an exact
# thread id. Rollout scanning, command-line socket discovery, launcher request
# files, and thread/start fallback can attach a different task and are forbidden.

agmsg_session_start() {
  if [ "${AGMSG_CODEX_BACKGROUND_RESUME:-}" = "1" ]; then
    exit 0
  fi

  local thread_id team="" name="" seat log match_count=0
  thread_id="${AGMSG_CODEX_ACTAS_THREAD:-${CODEX_THREAD_ID:-}}"
  case "$thread_id" in ""|loaded|current|unresolved) thread_id="" ;; esac

  [ -n "$thread_id" ] || exit 0
  for seat in "$RUN_DIR"/codex-seat.*.tsv; do
    [ -f "$seat" ] || continue
    IFS=$'\t' read -r saved_project saved_type saved_team saved_name saved_thread _saved_at < "$seat" || true
    if [ "$saved_project" = "$PROJECT" ] && [ "$saved_type" = "$TYPE" ] \
        && [ "$saved_thread" = "$thread_id" ] \
        && printf '%s\n' "$PAIRS" | grep -Fxq "$(printf '%s\t%s' "$saved_team" "$saved_name")"; then
      team="$saved_team"
      name="$saved_name"
      match_count=$((match_count + 1))
    fi
  done
  [ "$match_count" = "1" ] || exit 0
  [ -n "$team" ] && [ -n "$name" ] || exit 0

  mkdir -p "$RUN_DIR" 2>/dev/null || true
  log="$RUN_DIR/codex-actas-restore.log"
  AGMSG_CODEX_ACTAS_THREAD="$thread_id" \
    "$SKILL_DIR/scripts/drivers/types/codex/actas-monitor.sh" \
      "$PROJECT" "$TYPE" "$name" "$thread_id" >> "$log" 2>&1 || true
  exit 0
}
