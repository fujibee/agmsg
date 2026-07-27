#!/usr/bin/env bash
# Measure the per-iteration cost of the codex-bridge-launcher poll loops by
# replaying the exact call sequence each loop body performs, against the real
# libraries and the real installed skill dir. Read-only: nothing is written to
# the message store, no bridge is launched.
set -uo pipefail

SKILL_DIR="${SKILL_DIR:-$HOME/.agents/skills/agmsg}"
export SKILL_DIR
SCRIPT_DIR="$SKILL_DIR/scripts/drivers/types/codex"
PROJECT="${1:-$HOME/projects/esota/ag-dev-agent}"
TYPE="${2:-claude-code}"
ITERS="${3:-10}"

TAB="$(printf '\t')"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/hash.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/storage.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/role-session.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/resolve-project.sh"

ROLE_PAIR=""
resolve_identity() {
  "$SKILL_DIR/scripts/identities.sh" "$PROJECT" "$TYPE" 2>/dev/null \
    | awk -v t="$TAB" 'NF >= 2 { print $1 t $2 }' \
    | { if [ -n "$ROLE_PAIR" ]; then grep -Fx "$ROLE_PAIR" || true; else cat; fi; } \
    | sort -u
}

REQUEST_FILE="/nonexistent-request-file"
safety_fingerprint() {
  local request="" team name rec rec_project
  [ -f "$REQUEST_FILE" ] && request="$(cat "$REQUEST_FILE" 2>/dev/null || true)"
  printf 'request=%s\n' "$request"
  resolve_identity | while IFS="$TAB" read -r team name; do
    rec="$(agmsg_role_session_uuid "$team" "$name" 2>/dev/null || true)"
    rec_project="$(agmsg_role_session_get "$team" "$name" project 2>/dev/null || true)"
    printf '%s\t%s\t%s\t%s\n' "$team" "$name" "$rec" "$rec_project"
  done
}

now_ms() { printf '%s' "$(($(date +%s%N 2>/dev/null || printf 0)/1000000))"; }
if [ "$(now_ms)" = "0" ]; then
  now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
fi

roles="$(resolve_identity)"
role_count="$(printf '%s\n' "$roles" | grep -c . || true)"
teams="$(ls -d "$SKILL_DIR"/teams/*/ 2>/dev/null | wc -l | tr -d ' ')"
echo "project=$PROJECT type=$TYPE teams_on_disk=$teams roles_for_project=$role_count iters=$ITERS"

bench() { # name, then the body as remaining args
  local name="$1"; shift
  local t0 t1 i
  t0="$(now_ms)"
  for ((i = 0; i < ITERS; i++)); do "$@" >/dev/null 2>&1; done
  t1="$(now_ms)"
  printf '%-34s %8.1f ms/iter\n' "$name" "$(echo "scale=3; ($t1 - $t0) / $ITERS" | bc)"
}

dispatcher_tick() {
  agmsg_runtime_lock_verify "codex-dispatcher:measure" "$$" || true
  local current_pairs child_team child_name
  current_pairs="$(resolve_identity || true)"
  while IFS="$TAB" read -r child_team child_name; do
    [ -n "$child_team" ] || continue
    printf '%s\n' "$current_pairs" | grep -Fxq "$child_team$TAB$child_name" && continue
  done <<< "$current_pairs"
}

role_child_tick() {
  local latest team name rec_thread rec_project rec_project_phys
  latest="$(safety_fingerprint)"
  [ -f "$REQUEST_FILE" ] && cat "$REQUEST_FILE" >/dev/null 2>&1
  IFS="$TAB" read -r team name <<< "$roles"
  rec_thread="$(agmsg_role_session_uuid "$team" "$name" 2>/dev/null || true)"
  rec_project="$(agmsg_role_session_get "$team" "$name" project 2>/dev/null || true)"
  rec_project_phys="$(agmsg_canonical_path "$rec_project" 2>/dev/null || printf '%s' "$rec_project")"
  cat /nonexistent-pidfile 2>/dev/null || true
  cat /nonexistent-appserver 2>/dev/null || true
  cat /nonexistent-thread 2>/dev/null || true
}

bench "identities.sh (bare)" "$SKILL_DIR/scripts/identities.sh" "$PROJECT" "$TYPE"
bench "resolve_identity" resolve_identity
bench "safety_fingerprint" safety_fingerprint
bench "dispatcher loop body" dispatcher_tick
bench "role-child loop body" role_child_tick
