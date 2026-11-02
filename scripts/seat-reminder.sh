#!/usr/bin/env bash
# UserPromptSubmit hook for delivery modes `monitor` and `both`.
#
# Usage: seat-reminder.sh <type> <project_path>
#
# A resumed session that could not be matched to a seat on a project with
# several registered seats gets no inbox watcher (session-start.sh stands down so
# it cannot consume another seat's mail). This hook is what keeps that state from
# going unnoticed: while the session has no seat, it prints the "pick your seat"
# text on every prompt, so the seat is never silently deaf.
#
# session-start.sh leaves the text to print in run/seat-pending.<session_id>;
# actas-claim.sh and session-end.sh remove it. With no such file this exits at
# once. The whole script is bash builtins -- no sed, cat, or sqlite3 -- because
# it runs on every prompt of every session in the project.
#
# It never starts a watcher and never reads or marks any message.

_input=""
read -r -d '' _input || true
_re='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
if [[ $_input =~ $_re ]]; then
  _sid="${BASH_REMATCH[1]}"
  _sid="${_sid//[^A-Za-z0-9._-]/_}"
  _marker="${BASH_SOURCE[0]%/*}/../run/seat-pending.$_sid"
  if [ -n "$_sid" ] && [ -f "$_marker" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
      printf '%s\n' "$_line"
    done < "$_marker"
  fi
fi
exit 0
