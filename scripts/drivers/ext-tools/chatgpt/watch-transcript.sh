#!/usr/bin/env bash
set -uo pipefail

# watch-transcript.sh <member.conf> — standing companion process for a
# chatgpt ext-tool member (the inject-only mode is where it earns its keep,
# but it works alongside sync-wait too).
#
# What it does, once per tick:
#   1. resolves the member's tab (worktree + url_regex, same as handle)
#   2. reads the transcript tail via one eval
#   3. a user message carrying "[agm <this-member>:<from>:<mid>]" marks the
#      following assistant reply as routed back to <from>
#   4. a user message with NO marker is a human typing straight into the
#      tab -> relayed into agmsg as `boss` -> <human_relay_to> (only when
#      that key is configured), and its reply goes to <human_relay_to> too
#   5. an assistant message counts as complete when generation stopped and
#      its text is unchanged across two ticks
#
# It is a process, not an agent: replies are posted through send.sh under
# the member's own name (send.sh does not authenticate sender names), so
# unlike the fleet watchdog this needs no secretary session consuming an
# inbox. First successful tick is a baseline -- nothing already in the
# transcript is replayed.
#
# One process per member config. Stop with SIGTERM.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_lib.sh"
SEND="$(cd "$SCRIPT_DIR/../../.." && pwd)/send.sh"

CONF="${1:?Usage: watch-transcript.sh <member.conf>}"
[ -f "$CONF" ] || { echo "config not found: $CONF" >&2; exit 1; }

worktree="$(_cg_conf_get "$CONF" worktree)"
url_regex="$(_cg_conf_get "$CONF" url_regex)"; [ -n "$url_regex" ] || url_regex='chatgpt\.com'
human_relay_to="$(_cg_conf_get "$CONF" human_relay_to)"
judge_member="$(_cg_conf_get "$CONF" judge_member)"
mode="$(_cg_conf_get "$CONF" mode)"; [ -n "$mode" ] || mode="sync-wait"
member="$(basename "$CONF" .conf)"
team="$(basename "$(dirname "$CONF")")"
INTERVAL="${AGMSG_CG_WATCH_INTERVAL:-4}"

[ -n "$worktree" ] || { echo "config is missing worktree: $CONF" >&2; exit 1; }

LOG_FILE="$CONF.watch.log"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

# Singleton: one watcher per member config. The lock doubles as a pidfile
# (_cg_watch_ensure reads owner to decide whether to respawn). A crashed
# watcher's stale lock is reclaimed via its dead owner pid.
WATCH_LOCK="$CONF.watchrun.lock.d"
if ! mkdir "$WATCH_LOCK" 2>/dev/null; then
  opid="$(awk '{print $1}' "$WATCH_LOCK/owner" 2>/dev/null || echo 0)"
  if kill -0 "${opid:-0}" 2>/dev/null; then
    exit 0   # already running
  fi
  rm -rf "$WATCH_LOCK"
  mkdir "$WATCH_LOCK" 2>/dev/null || exit 0
fi
printf '%s %s\n' "$$" "$(date +%s)" > "$WATCH_LOCK/owner"
trap 'rm -rf "$WATCH_LOCK"' EXIT

log "watcher start member=$member team=$team mode=$mode url_regex=$url_regex human_relay_to=${human_relay_to:-none}"

send_msg() {  # <from> <to> <body> -- never let a send hiccup kill the loop
  bash "$SEND" "$team" "$1" "$2" "$3" >/dev/null 2>&1 || true
  log "relayed from=$1 to=$2 len=${#3}"
}

sig() { printf '%s' "$1" | shasum | cut -c1-16; }

# One jev call per relayed reply (only when judge_member is configured and
# the reply is long enough for truncation to be meaningful -- jev
# over-flags terse replies). A stopped/failed generation leaves a stable
# partial text that is final: there is nothing to wait for, so the reply
# ships with a note instead of being dropped.
annotate() {
  local text="$1" tail_txt verdict
  [ -n "$judge_member" ] || { printf '%s' "$text"; return; }
  [ "${#text}" -ge 400 ] || { printf '%s' "$text"; return; }
  tail_txt="$(printf '%s' "$text" | tail -c 1500)"
  verdict="$(_cg_judge "$(dirname "$CONF")" "$judge_member" \
    "$(jq -cn --arg t "$tail_txt" \
      '{state:("This ChatGPT reply was captured from the page after generation stopped. Tail: "+$t),"questions":{shape:{type:"choice",instructions:"Is the reply complete or truncated?",criteria:{complete:"ends at a natural stopping point",truncated:"cut off mid-sentence, mid-list, or ends with an obvious error stub"}}}}')" 2>/dev/null || true)"
  log "judge verdict=${verdict:-none}"
  case "$verdict" in
    *"truncated"*"confidence=0."[7-9]*|*"truncated"*"confidence=1"*)
      printf '%s\n\n[agmsg note: this reply appears truncated mid-generation -- possibly stopped or errored]' "$text" ;;
    *) printf '%s' "$text" ;;
  esac
}

# Parse "[agm <member>:<from>:<mid>]" out of a user message's text.
# Echoes "<member> <from>" or nothing.
parse_marker() {
  printf '%s' "$1" | grep -oE '\[agm [^: ]+:[^: ]+:[^] ]+\]' | tail -1 |
    sed -E 's/^\[agm ([^: ]+):([^: ]+):([^] ]+)\]$/\1 \2/'
}

# macOS ships bash 3.2 (no assoc arrays) -- sigs are fixed 17-char tokens,
# so a colon-delimited string works fine for membership checks. Both sets
# are persisted to a state file so a restart does not double-relay, and a
# marked reply that completed while we were down still gets delivered.
STATE="$CONF.watch.state"
seen_users=":"    # sigs already relayed or deliberately skipped
announced=":"     # assistant sigs already posted
pending_mid="" pending_from="" pending_since=0 pending_reloaded=0
[ -f "$STATE" ] && . "$STATE"
has() { case ":$2" in *":$1:"*) return 0;; esac; return 1; }
save_state() {
  printf "seen_users='%s'\nannounced='%s'\npending_mid='%s'\npending_from='%s'\npending_since=%s\npending_reloaded=%s\n" \
    "$seen_users" "$announced" "$pending_mid" "$pending_from" "${pending_since:-0}" "${pending_reloaded:-0}" > "$STATE"
}
baseline_done=0
cand_sig="" cand_text="" cand_to="" cand_stable=0

# Recovery + outbound-queue state. Same lock key handle uses, so a watcher
# inject can never interleave with a sync member's delivery on the tab.
QDIR="$CONF.queue.d"
tab_key="$(printf '%s|%s' "$worktree" "$url_regex" | shasum | cut -c1-16)"
TAB_LOCK="$(dirname "$CONF")/.tablock-$tab_key.d"
reloads=0 last_reload=0 unknown_streak=0 retry_clicks=0
gen_sig="" gen_frozen=0
last_qf="" qf_fails=0
REPLY_TIMEOUT=120     # injected but unanswered this long -> reload once
RELOAD_COOLDOWN=60
MAX_RELOADS=3         # consecutive; HEALTHY_IDLE resets the counter

while :; do
  page="$(_cg_find_page "$worktree" "$url_regex" 2>/dev/null || true)"
  if [ -z "$page" ]; then
    log "no tab matching '$url_regex' in $worktree"
    sleep "$INTERVAL"; continue
  fi

  # One eval per tick: last 12 transcript nodes (role + full text) and
  # whether a generation is in flight.
  st="$(_cg_eval "$page" '(()=>{
    const all=[...document.querySelectorAll("[data-message-author-role]")];
    const msgs=all.slice(-12).map(m=>({r:m.dataset.messageAuthorRole,t:m.innerText||""}));
    const stop=[...document.querySelectorAll("button")].find(b=>b.offsetParent!==null&&/stop|停止/i.test((b.getAttribute("aria-label")||"")+" "+(b.dataset.testid||"")));
    return JSON.stringify({msgs,generating:!!stop});
  })()' 2>/dev/null || true)"
  [ -n "$st" ] || { sleep "$INTERVAL"; continue; }

  generating="$(printf '%s' "$st" | jq -r '.generating // false' 2>/dev/null)"
  count="$(printf '%s' "$st" | jq -r '.msgs | length' 2>/dev/null || echo 0)"

  now=$(date +%s)

  # --- health & recovery ---------------------------------------------------
  # handle owns recovery for its own sync deliveries; for the async member
  # the watcher is the only process watching the tab, so it recovers too.
  cls="$(_cg_classify "$page" 2>/dev/null || true)"
  health="$(_cg_health "$cls")"
  case "$health" in
    HEALTHY_IDLE)
      reloads=0; unknown_streak=0; retry_clicks=0; gen_frozen=0 ;;
    GENERATING)
      msgsig="$(printf '%s' "$st" | jq -c '.msgs' | shasum | cut -c1-16)"
      if [ "$msgsig" = "$gen_sig" ]; then
        gen_frozen=$((gen_frozen + INTERVAL))
      else
        gen_sig="$msgsig"; gen_frozen=0
      fi
      # A real long answer is just waited out ("ただ待つ"); only a frozen
      # stream earns a reload.
      if [ "$gen_frozen" -ge 90 ] && [ "$reloads" -lt "$MAX_RELOADS" ]; then
        log "GENERATING frozen ${gen_frozen}s -> reload"
        _cg_reload "$page"; reloads=$((reloads + 1)); last_reload=$now; gen_frozen=0
      fi ;;
    ERROR_RETRYABLE)
      if [ "$retry_clicks" -lt 3 ]; then
        log "ERROR_RETRYABLE -> click retry ($((retry_clicks + 1)))"
        _cg_click_retry "$page"; retry_clicks=$((retry_clicks + 1))
      elif [ $((now - last_reload)) -gt "$RELOAD_COOLDOWN" ] && [ "$reloads" -lt "$MAX_RELOADS" ]; then
        log "ERROR_RETRYABLE persists -> reload"
        _cg_reload "$page"; reloads=$((reloads + 1)); last_reload=$now; retry_clicks=0
      fi ;;
    ERROR_PAGE)
      if [ $((now - last_reload)) -gt "$RELOAD_COOLDOWN" ] && [ "$reloads" -lt "$MAX_RELOADS" ]; then
        log "ERROR_PAGE -> reload"
        _cg_reload "$page"; reloads=$((reloads + 1)); last_reload=$now
      fi ;;
    UNKNOWN)
      unknown_streak=$((unknown_streak + 1))
      if [ "$unknown_streak" -ge 8 ] && [ $((now - last_reload)) -gt "$RELOAD_COOLDOWN" ] && [ "$reloads" -lt "$MAX_RELOADS" ]; then
        log "UNKNOWN x$unknown_streak -> reload"
        _cg_reload "$page"; reloads=$((reloads + 1)); last_reload=$now; unknown_streak=0
      fi ;;
  esac

  # --- pending outbound: injected, confirmed, but no reply appeared --------
  if [ -n "$pending_mid" ] && [ "$generating" != "true" ] && [ $((now - pending_since)) -gt "$REPLY_TIMEOUT" ]; then
    if [ "$pending_reloaded" = "0" ] && [ "$reloads" -lt "$MAX_RELOADS" ]; then
      log "no reply to mid=$pending_mid for ${REPLY_TIMEOUT}s -> reload"
      _cg_reload "$page"; reloads=$((reloads + 1)); last_reload=$now
      pending_reloaded=1; pending_since=$now; dirty=1
    else
      log "mid=$pending_mid still unanswered after reload -> fail notice"
      send_msg "$member" "$pending_from" "chatgpt: processing failed (no reply appeared after reload)"
      pending_mid=""; dirty=1
    fi
  fi

  # --- queue drain ---------------------------------------------------------
  # inject-only deliveries land in $QDIR via handle; serial: one in flight.
  if [ "$health" = "HEALTHY_IDLE" ] && [ -z "$pending_mid" ] && [ "$baseline_done" = "1" ]; then
    qf="$(find "$QDIR" -name '*.json' 2>/dev/null | sort | head -1)"
    if [ -n "$qf" ]; then
      qbody="$(jq -r '.body // empty' "$qf" 2>/dev/null)"
      qfrom="$(jq -r '.from // "unknown"' "$qf" 2>/dev/null)"
      qmid="$(jq -r '.mid // empty' "$qf" 2>/dev/null)"
      if [ -z "$qbody" ] || [ -z "$qmid" ]; then
        log "queue: bad entry $qf -- dropping"; rm -f "$qf"
      elif _cg_lock_acquire "$TAB_LOCK" 300 60; then
        res="$(_cg_inject "$page" "$qbody

[agm $member:$qfrom:$qmid]" 2>/dev/null || true)"
        if [ "$(printf '%s' "$res" | jq -r '.ok // false' 2>/dev/null)" = "true" ] \
           && _cg_send_confirmed "$page" "$qmid" 30; then
          rm -f "$qf"
          pending_mid="$qmid"; pending_from="$qfrom"; pending_since=$now; pending_reloaded=0; dirty=1
          log "queue delivered mid=$qmid to=$qfrom"
        else
          if [ "$qf" = "$last_qf" ]; then qf_fails=$((qf_fails + 1)); else last_qf="$qf"; qf_fails=1; fi
          log "queue inject/confirm failed mid=$qmid tries=$qf_fails res=${res:-EMPTY}"
          if [ "$qf_fails" -ge 2 ]; then
            rm -f "$qf"
            send_msg "$member" "$qfrom" "chatgpt: processing failed (inject failed after retries)"
          fi
        fi
        _cg_lock_release "$TAB_LOCK"
      fi
    fi
  fi

  attr=""            # routing for the assistant that follows a user msg
  last_idx=$((count - 1))
  i=0
  while [ "$i" -lt "$count" ]; do
    role="$(printf '%s' "$st" | jq -r ".msgs[$i].r" 2>/dev/null)"
    text="$(printf '%s' "$st" | jq -r ".msgs[$i].t" 2>/dev/null)"
    if [ "$role" = "user" ]; then
      usig="u:$(sig "$text")"
      mark="$(parse_marker "$text")"
      # Routing for the assistant that follows THIS user msg (reset per msg):
      # marked for us -> original sender, but ONLY in inject-only mode (in
      # sync-wait the handle itself returns the reply; relaying here would
      # double-post). Marked for another member -> that member owns it.
      # Unmarked -> human input.
      if [ -n "$mark" ]; then
        if [ "${mark%% *}" = "$member" ] && [ "$mode" = "inject-only" ]; then
          attr="${mark##* }"
        else
          attr=""
        fi
      elif [ -n "$human_relay_to" ]; then
        attr="HUMAN"
      else
        attr=""
      fi
      if ! has "$usig" "$seen_users"; then
        seen_users="$seen_users$usig:"; dirty=1
        # Relay human input into agmsg (never after baseline, never marked
        # messages -- those are our own deliveries).
        if [ "$baseline_done" = "1" ] && [ -z "$mark" ] && [ -n "$human_relay_to" ]; then
          send_msg boss "$human_relay_to" "$text"
        fi
      fi
    elif [ "$role" = "assistant" ]; then
      asig="a:$(sig "$text")"
      if ! has "$asig" "$announced"; then
        if [ "$baseline_done" = "0" ]; then
          # Baseline: replay nothing old -- except a trailing reply to a
          # marked delivery, which survives a watcher restart (its question
          # IS on record in agmsg). Human exchanges at baseline are not
          # resumed: the question was never recorded.
          if [ "$i" -lt "$last_idx" ] || [ -z "$attr" ] || [ "$attr" = "HUMAN" ]; then
            announced="$announced$asig:"; dirty=1
          fi
        elif [ "$i" -lt "$last_idx" ]; then
          # A later message exists -> this reply is finalized; no stability
          # wait needed. (Bug fixed: checking only the LAST assistant lost
          # any reply pushed up the transcript by a concurrent send.)
          announced="$announced$asig:"; dirty=1
          if [ "$attr" = "HUMAN" ]; then
            [ -n "$human_relay_to" ] && send_msg "$member" "$human_relay_to" "$(annotate "$text")"
          elif [ -n "$attr" ]; then
            send_msg "$member" "$attr" "$(annotate "$text")"
          fi
          # a reply landed for the in-flight queue entry -> next may go
          if [ -n "$pending_mid" ] && [ "$attr" = "$pending_from" ]; then
            pending_mid=""; dirty=1
          fi
        elif [ "$generating" = "true" ]; then
          cand_sig=""; cand_stable=0    # still streaming; don't lock a sig
        else
          if [ "$asig" = "$cand_sig" ]; then
            cand_stable=$((cand_stable + 1))
          else
            cand_sig="$asig"; cand_text="$text"; cand_to="$attr"; cand_stable=1
          fi
          if [ "$cand_stable" -ge 2 ]; then
            announced="$announced$asig:"; dirty=1
            if [ "$cand_to" = "HUMAN" ]; then
              [ -n "$human_relay_to" ] && send_msg "$member" "$human_relay_to" "$(annotate "$cand_text")"
            elif [ -n "$cand_to" ]; then
              send_msg "$member" "$cand_to" "$(annotate "$cand_text")"
            fi
            # a reply landed for the in-flight queue entry -> next may go
            if [ -n "$pending_mid" ] && [ "$cand_to" = "$pending_from" ]; then
              pending_mid=""; dirty=1
            fi
          fi
        fi
      fi
    fi
    i=$((i + 1))
  done
  baseline_done=1
  [ "${dirty:-0}" = "1" ] && save_state
  dirty=0
  sleep "$INTERVAL"
done
