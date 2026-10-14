#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/../../../.." && pwd)"
source "$SKILL_DIR/scripts/lib/storage.sh"
source "$SKILL_DIR/scripts/lib/actas-lock.sh"
source "$SKILL_DIR/scripts/lib/role-session.sh"
command="${1:?}"; project="${2:?}"; team="${3:?}"; role="${4:?}"; owner="${5:-}"
# Does this owner hold the role? 0 yes | 1 someone else's | 2 could not tell.
#
# `actas_lock_owner` is gone (#983). It answered the empty string, at status 0,
# for a missing lock, an unreadable one and an empty one alike, so
# `[ "$(actas_lock_owner …)" = "$owner" ]` could not tell "not yours" from "I
# could not look" -- it happened to refuse in both cases, which is the safe
# direction, but it then REPORTED the wrong one. The reader carries its own
# outcome now, so the two stay apart all the way to the message the operator
# reads.
_owner_check() {   # <team> <role> <owner>
  local _r; _r="$(actas_lock_read "$1" "$2")"
  [ "${_r%%$'\t'*}" = "ok" ] || return 2
  [ "${_r#*$'\t'}" = "$3" ] || return 1
  return 0
}

# A successful control operation is exactly three bytes: "ok" and LF. Read
# through a private file so command substitution cannot erase NUL or trailing
# newlines and turn an invalid response into apparent success.
_capture_control() {
  local _control_target="$1" _control_file _control_raw="" _control_ok=false
  shift
  _control_file="$(umask 077; mktemp)" || return 13
  if "$@" > "$_control_file"; then
    if IFS= read -r -d '' _control_raw < "$_control_file"; then
      : # A NUL delimiter is never valid, even after an otherwise valid reply.
    elif [ "$_control_raw" = $'ok\n' ]; then
      _control_ok=true
    fi
  fi
  rm -f -- "$_control_file" || return 13
  if [ "$_control_ok" != true ]; then
    echo 'agmsg: malformed protected control output' >&2
    return 13
  fi
  printf -v "$_control_target" '%s' ok
}

case "$command" in
 paths)
   printf '%s\n' "$(actas_lock_path "$team" "$role")"
   printf '%s/run/antigravity-bridge.%s.%s.%s.state.json\n' "$SKILL_DIR" "$(_actas_lock_encode "$project")" "$(_actas_lock_encode "$team")" "$(_actas_lock_encode "$role")"
   exit ;;
esac
bash "$SKILL_DIR/scripts/identities.sh" "$project" antigravity | awk -F '\t' -v t="$team" -v a="$role" '$1==t && $2==a { found=1 } END {exit !found}' || { echo 'unregistered role' >&2; exit 1; }
case "$command" in
 claim) actas_lock_claim "$team" "$role" "$owner"; exit ;;
 verify)
   if [ -n "${AGMSG_TEST_VERIFY_SIGNAL:-}" ]; then
     _n=0; [ -f "${AGMSG_TEST_VERIFY_SIGNAL}.count" ] && _n=$(cat "${AGMSG_TEST_VERIFY_SIGNAL}.count")
     _n=$((_n + 1)); printf '%s\n' "$_n" > "${AGMSG_TEST_VERIFY_SIGNAL}.count"
     if [ "$_n" -ge 3 ]; then kill -TERM $$; fi
   fi
   # The supervisor reads this as a boolean "is it still mine". Both "no" and
   # "cannot tell" must answer non-zero -- an unverifiable lock is not a held
   # one -- and errexit carries that status out, as the old form did.
   _owner_check "$team" "$role" "$owner"; exit ;;
 release) actas_lock_release "$team" "$role" "$owner"; exit ;;
 record) agmsg_role_session_record "$team" "$role" "${6:?}" "$project"; exit ;;
esac
# Both refuse, and they say different things: "someone else holds it" is a claim
# about the world, "I could not read the lock" is a claim about us, and the
# operator's next move differs. Reporting the second as the first is the same lie
# doctor used to tell with `lock=none`. (#983)
_own_rc=0; _owner_check "$team" "$role" "$owner" || _own_rc=$?
case "$_own_rc" in
  1) echo 'ownership mismatch' >&2; exit 1 ;;
  2) echo 'cannot read actas lock; ownership cannot be verified (will not proceed without verification)' >&2; exit 1 ;;
esac
agmsg_storage_load
source "$SKILL_DIR/scripts/lib/delivery-claims.sh"
source "$HERE/bridge-read-guard.sh"
case "$command" in
 admit|receive|renew|finish|relinquish|recover-batch)
   IFS= read -r _AGMSG_BRIDGE_ACK_CAP <&3
   exec 3<&-
   request="$(node "$HERE/bridge-read-guard.mjs" request "$team" "$role" "$owner")" || exit 13
   reservation="$(_agmsg_bridge_guard_reservation "$team" "$role")" || exit 13
   operation="$command"
   case "$command" in receive) operation=claim ;; finish) operation=ack ;; relinquish) operation=release ;; recover-batch) operation=recover ;; esac
   _agmsg_antigravity_authorize "$reservation" "$operation" "$request" || exit 13
   storage_driver="$(agmsg_storage_driver)" || exit 13
   if [ "$storage_driver" = sqlite ]; then _sqlite_bridge_ready "$team" || exit 13; fi
   if [ "$command" = admit ]; then
     capability_rc=0
     agmsg_delivery_claims_supported || capability_rc=$?
     case "$capability_rc" in
       0)
         [ "$storage_driver" = sqlite ] || { echo 'agmsg: protected claims require the SQLite driver' >&2; exit 13; }
         echo claims ;;
       1) echo legacy ;;
       *) exit 13 ;;
     esac
     exit
   fi
   agmsg_delivery_claims_supported || { echo 'agmsg: protected claims are unavailable' >&2; exit 13; }
   [ "$storage_driver" = sqlite ] || { echo 'agmsg: protected claims require the SQLite driver' >&2; exit 13; }
   fields="$(printf '%s' "$request" | node "$HERE/bridge-read-guard.mjs" fields)" || exit 13
   claim_owner=""; token=""; protection_id=""; ids=()
   while IFS='|' read -r key value; do
     _agmsg_delivery_decode_hex value "$value" || exit 13
     case "$key" in owner) claim_owner="$value" ;; token) token="$value" ;; protection_id) protection_id="$value" ;; id) ids+=("$value") ;; esac
   done <<< "$fields"
   case "$command" in
     receive) _agmsg_delivery_capture result _sqlite_bridge_claim_unread "$team" "$role" "$owner" 600 || exit 13 ;;
     renew) _capture_control result _sqlite_bridge_claim_change renew "$protection_id" "$team" "$role" "$claim_owner" "$token" 600 "${ids[@]}" || exit 13 ;;
     finish|relinquish) _capture_control result _sqlite_bridge_claim_change "$operation" "$protection_id" "$team" "$role" "$claim_owner" "$token" "${ids[@]}" || exit 13 ;;
     recover-batch)
       batch="$(node "$HERE/bridge-read-guard.mjs" saved-batch "$reservation")" || exit 13
       _agmsg_delivery_capture result _sqlite_bridge_claim_recover "$team" "$role" "$owner" 600 "$batch" || exit 13 ;;
   esac
   case "$command" in
     receive|recover-batch)
       printf '%s' "$result" | node "$HERE/bridge-read-guard.mjs" validate-output "$command" "$reservation" "$team" "$role" || exit 13 ;;
   esac
   _agmsg_antigravity_authorize "$reservation" "$operation" "$request" || exit 13
   case "$command" in
     receive|recover-batch) _agmsg_delivery_emit_records "$result" ;;
     *) [ -z "$result" ] || printf '%s\n' "$result" ;;
   esac
   exit ;;
esac
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
   ids=()
   while IFS= read -r id; do
     [ -n "$id" ] && ids+=("$id")
   done <<< "$id_lines"
   [ "${#ids[@]}" -gt 0 ]
   storage_mark_read_batch "$team" "$role" "${ids[@]}" ;;
 *) exit 2 ;;
esac
