#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/../../../.." && pwd)"
source "$SKILL_DIR/scripts/lib/storage.sh"
source "$SKILL_DIR/scripts/lib/actas-lock.sh"
source "$SKILL_DIR/scripts/lib/role-session.sh"
command="${1:?}"; project="${2:?}"; team="${3:?}"; role="${4:?}"; owner="${5:-}"
case "$command" in
 paths)
   printf '%s\n' "$(actas_lock_path "$team" "$role")"
   printf '%s/run/antigravity-bridge.%s.%s.%s.state.json\n' "$SKILL_DIR" "$(_actas_lock_encode "$project")" "$(_actas_lock_encode "$team")" "$(_actas_lock_encode "$role")"
   exit ;;
esac
bash "$SKILL_DIR/scripts/identities.sh" "$project" antigravity | awk -F '\t' -v t="$team" -v a="$role" '$1==t && $2==a { found=1 } END {exit !found}' || { echo '未登録role' >&2; exit 1; }
case "$command" in
 claim) actas_lock_claim "$team" "$role" "$owner"; exit ;;
 verify)
   if [ -n "${AGMSG_TEST_VERIFY_SIGNAL:-}" ]; then
     _n=0; [ -f "${AGMSG_TEST_VERIFY_SIGNAL}.count" ] && _n=$(cat "${AGMSG_TEST_VERIFY_SIGNAL}.count")
     _n=$((_n + 1)); printf '%s\n' "$_n" > "${AGMSG_TEST_VERIFY_SIGNAL}.count"
     if [ "$_n" -ge 3 ]; then kill -TERM $$; fi
   fi
   [ "$(actas_lock_owner "$team" "$role")" = "$owner" ]; exit ;;
 release) actas_lock_release "$team" "$role" "$owner"; exit ;;
 record) agmsg_role_session_record "$team" "$role" "${6:?}" "$project"; exit ;;
esac
[ "$(actas_lock_owner "$team" "$role")" = "$owner" ] || { echo '所有権不一致' >&2; exit 1; }
agmsg_storage_load
case "$command" in
 peek)
   if [ -n "${AGMSG_TEST_PEEK_BARRIER:-}" ]; then
     : > "$AGMSG_TEST_PEEK_BARRIER.reached"
     while [ ! -e "$AGMSG_TEST_PEEK_BARRIER.release" ]; do sleep 0.02; done
   fi
   if [ -n "${AGMSG_TEST_PEEK_FAILURE:-}" ]; then
     : > "$AGMSG_TEST_PEEK_FAILURE.reached"
     exit 42
   fi
   if [ -n "${AGMSG_TEST_PEEK_SIGNAL:-}" ]; then
     : > "$AGMSG_TEST_PEEK_SIGNAL.reached"
     kill -TERM $$
   fi
   storage_list_unread "$team" "$role" --limit 20 ;;
 ack)
   IFS= read -r _AGMSG_BRIDGE_ACK_CAP <&3
   exec 3<&-
   id_lines=$(node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const a=JSON.parse(s);if(!Array.isArray(a)||!a.length||a.some(x=>typeof x!=="string"||!x||/[\r\n]/.test(x)))process.exit(2);console.log(a.join("\n"))})')
   mapfile -t ids <<< "$id_lines"
   [ "${#ids[@]}" -gt 0 ]
   storage_mark_read_batch "$team" "$role" "${ids[@]}" ;;
 *) exit 2 ;;
esac
