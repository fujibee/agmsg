#!/usr/bin/env bash
set -euo pipefail

TEAM="${1:?team required}"
AGENT="${2:?agent required}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/actas-lock.sh"
ready="$(SKILL_DIR="$SKILL_DIR" agmsg_ready_path "$TEAM" "$AGENT")"
[[ -f "$ready" ]] || exit 1
pid="$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' "$ready")"
[[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] && kill -0 "$pid" 2>/dev/null
