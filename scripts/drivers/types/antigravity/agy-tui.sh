#!/usr/bin/env bash
set -euo pipefail

# agmsg Antigravity TUI launcher shim
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/../../../.." && pwd)"
PROJECT="${AGMSG_ANTIGRAVITY_PROJECT:-$(pwd)}"
TEAM="${AGMSG_ANTIGRAVITY_TEAM:-}"
ROLE="${AGMSG_ANTIGRAVITY_ROLE:-}"
AGY="${AGMSG_ANTIGRAVITY_BIN:-}"

usage() {
  printf '%s\n' 'Usage: agy-tui [status|stop|resume|reset-guard|ack|replay] [--project <path>] [--team <team>] [--name <role>] [--agy <path>] [monitor options...]'
}

ACTION=""
case "${1:-}" in
  status|stop|resume|reset-guard|ack|replay) ACTION="$1"; shift ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?--project requires a value}"; shift 2 ;;
    --team) TEAM="${2:?--team requires a value}"; shift 2 ;;
    --name) ROLE="${2:?--name requires a value}"; shift 2 ;;
    --agy) AGY="${2:?--agy requires a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ -z "$TEAM" ] && [ -z "$ROLE" ]; then
  identities="$("$SKILL_DIR/scripts/identities.sh" "$PROJECT" antigravity 2>/dev/null || true)"
  identity_count="$(printf '%s\n' "$identities" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$identity_count" -eq 1 ]; then
    IFS=$'\t' read -r TEAM ROLE <<< "$identities"
  elif [ "$identity_count" -gt 1 ]; then
    printf 'agy-tui: projectに複数のantigravity identityがあります。--teamと--nameを指定してください。\n' >&2
    printf '%s\n' "$identities" | sed 's/^/  /' >&2
    exit 1
  else
    printf 'agy-tui: projectにantigravity identityが一意に登録されていません。/agmsgでjoinするか--teamと--nameを指定してください。\n' >&2
    exit 1
  fi
fi

if [ -z "$TEAM" ] || [ -z "$ROLE" ]; then
  printf 'agy-tui: --teamと--nameは両方指定してください。\n' >&2
  exit 1
fi

if [ -z "$ACTION" ]; then
  if [ -z "$AGY" ]; then
    AGY="$(command -v agy || true)"
  fi
  if [ -z "$AGY" ] || [ ! -x "$AGY" ]; then
    printf 'agy-tui: agyがPATHにありません。agyを導入するか--agy <path>を指定してください。\n' >&2
    exit 1
  fi
elif [ -z "$AGY" ]; then
  AGY="agy"
fi

monitor_args=(
  --project "$PROJECT"
  --team "$TEAM"
  --name "$ROLE"
  --agy "$AGY" "$@"
)
if [ -n "$ACTION" ]; then
  exec bash "$HERE/antigravity-tui-monitor.sh" "$ACTION" "${monitor_args[@]}"
fi
exec bash "$HERE/antigravity-tui-monitor.sh" "${monitor_args[@]}"
