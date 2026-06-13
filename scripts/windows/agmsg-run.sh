#!/usr/bin/env bash
set -euo pipefail

# Runner used by the native Windows PowerShell shortcut.
#
# PowerShell passes subcommand data through AGMSG_* environment variables so
# message bodies do not need to survive another layer of shell quoting.

export PATH="$HOME/.agents/bin:$HOME/bin:$PATH"

SKILL_NAME="${AGMSG_SKILL_NAME:-__SKILL_NAME__}"
SD="$HOME/.agents/skills/$SKILL_NAME/scripts"
TYPE="${AGMSG_AGENT_TYPE:-codex}"
PROJECT="${AGMSG_PROJECT:-$(pwd)}"
SUB="${AGMSG_SUB:-inbox}"
AGENT="${AGMSG_AGENT:-}"
TEAMS="${AGMSG_TEAM:-}"

field_value() {
  local line="$1" key="$2"
  printf '%s\n' "$line" | sed -n "s/.*$key=\([^[:space:]]*\).*/\1/p"
}

resolve_identity() {
  if [[ -n "$AGENT" && -n "$TEAMS" ]]; then
    return 0
  fi

  local who
  if ! who="$("$SD/whoami.sh" "$PROJECT" "$TYPE")"; then
    printf '%s\n' "$who" >&2
    return 1
  fi

  case "$who" in
    agent=*)
      AGENT="${AGENT:-$(field_value "$who" agent)}"
      TEAMS="${TEAMS:-$(field_value "$who" teams)}"
      ;;
    multiple=true*)
      printf '%s\n' "$who" >&2
      echo "agmsg: multiple identities found; set AGMSG_AGENT and AGMSG_TEAM, or use the agent skill command." >&2
      return 2
      ;;
    not_joined=true*|suggest=true*)
      printf '%s\n' "$who" >&2
      echo "agmsg: this project is not joined yet. Run the agmsg skill once in your agent, then retry." >&2
      return 2
      ;;
    *)
      printf '%s\n' "$who" >&2
      echo "agmsg: could not resolve project identity." >&2
      return 2
      ;;
  esac

  if [[ -z "$AGENT" || -z "$TEAMS" ]]; then
    echo "agmsg: missing AGMSG_AGENT or AGMSG_TEAM after identity lookup." >&2
    return 2
  fi
}

first_team() {
  printf '%s' "${TEAMS%%,*}"
}

for_each_team() {
  local script="$1"
  resolve_identity
  local team
  IFS=',' read -ra team_list <<< "$TEAMS"
  for team in "${team_list[@]}"; do
    "$script" "$team" "$AGENT"
  done
}

case "$SUB" in
  inbox)
    for_each_team "$SD/inbox.sh"
    ;;
  history)
    for_each_team "$SD/history.sh"
    ;;
  team)
    resolve_identity
    IFS=',' read -ra team_list <<< "$TEAMS"
    for team in "${team_list[@]}"; do
      "$SD/team.sh" "$team"
    done
    ;;
  send)
    resolve_identity
    exec "$SD/send.sh" "$(first_team)" "$AGENT" "${AGMSG_TO:?missing recipient}" "${AGMSG_MSG:?missing message}"
    ;;
  mode)
    MODE="${AGMSG_MODE:-}"
    if [[ -z "$MODE" ]]; then
      exec "$SD/delivery.sh" status "$TYPE" "$PROJECT"
    fi
    case "$MODE" in
      turn|off) exec "$SD/delivery.sh" set "$MODE" "$TYPE" "$PROJECT" ;;
      monitor|both)
        echo "Codex has no Monitor tool; only 'turn' or 'off' modes are supported." >&2
        exit 2
        ;;
      *)
        echo "usage: $SKILL_NAME mode [turn|off]" >&2
        exit 2
        ;;
    esac
    ;;
  reset)
    if [[ -n "$AGENT" ]]; then
      exec "$SD/reset.sh" "$PROJECT" "$TYPE" "$AGENT"
    fi
    exec "$SD/reset.sh" "$PROJECT" "$TYPE"
    ;;
  *)
    echo "usage: $SKILL_NAME [inbox|history|team|mode [turn|off]|send <to> <message>|reset]" >&2
    exit 2
    ;;
esac
