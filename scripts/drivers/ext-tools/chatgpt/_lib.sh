#!/usr/bin/env bash
# Shared helpers for the ChatGPT (Orca built-in browser) ext-tool.
# Sourced, not executed; no shebang exec bit.
#
# Everything here talks to the tab through `orca` CLI only -- never through
# AppleScript, accessibility APIs, or synthetic keystrokes. Injection uses
# the proven path (eval + execCommand('insertText') + send-button click):
# orca fill/type/focus do not reach ChatGPT's ProseMirror composer.

# Read a single key from a member config file (key=value, never sourced --
# same discipline as every other driver). Empty when file or key absent.
_cg_conf_get() {   # <config_path> <key>
  local config_path="$1" key="$2" line
  [ -f "$config_path" ] || return 0
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$config_path" 2>/dev/null | head -1)" || true
  printf '%s' "${line#*=}"
}

# _cg_orca <args...> — run `orca <args> --json`, print .result on success.
# Non-zero with one stderr line on CLI-level failure.
_cg_orca() {
  local out rc=0
  out="$(orca "$@" --json 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] || [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" != "true" ]; then
    if [ -n "${LOG_FILE:-}" ]; then
      printf '%s ORCA-FAIL rc=%s cmd=%s out=%s\n' "$(date -u +%FT%TZ)" "$rc" "$1" \
        "$(printf '%s' "$out" | tr '\n' ' ' | head -c 300)" >> "$LOG_FILE" 2>/dev/null || true
    fi
    return 1
  fi
  printf '%s' "$out" | jq -c '.result // {}'
  return 0
}

# _cg_eval <page> <js-expression> — evaluate JS in the tab (expressions that
# return a Promise are awaited by the CLI). Prints the expression's own
# return value (the drivers always return a JSON string).
_cg_eval() {
  local page="$1" expr="$2" out
  if ! out="$(_cg_orca eval --page "$page" --expression "$expr")"; then
    return 1
  fi
  printf '%s' "$out" | jq -r '.result // empty'
  return 0
}

# _cg_find_page <worktree> <url_regex> [page_pin] — echo a browserPageId for
# a live tab matching url_regex inside the worktree's browser. A configured
# page pin is tried first and still wins only while the tab exists and its
# URL still matches; otherwise falls back to a fresh regex scan so a
# recreated tab keeps working.
_cg_find_page() {
  local worktree="$1" url_regex="$2" pin="${3:-}" tabs
  tabs="$(_cg_orca tab list --worktree "path:$worktree")" || return 1
  if [ -n "$pin" ]; then
    local purl
    purl="$(printf '%s' "$tabs" | jq -r --arg p "$pin" \
      '.tabs[]? | select(.browserPageId==$p) | .url' 2>/dev/null | head -1)"
    if [ -n "$purl" ] && printf '%s' "$purl" | grep -qE "$url_regex"; then
      printf '%s' "$pin"
      return 0
    fi
  fi
  printf '%s' "$tabs" | jq -r --arg re "$url_regex" \
    '[.tabs[]? | select(.url | test($re))][0].browserPageId // empty' 2>/dev/null
}

# _cg_classify <page> — one eval, one JSON object back:
#   {composer, generating, retry, errorText, url}
# Then mapped to a health word by the caller:
#   generating -> GENERATING, retry -> ERROR_RETRYABLE, composer ->
#   HEALTHY_IDLE, !composer && errorText -> ERROR_PAGE, else UNKNOWN.
# retry is matched on <button> elements only (aria-label or textContent) --
# matching conversation text produced false "retry"/"stop" hits in the
# watchdog implementation this is derived from.
_cg_classify() {
  _cg_eval "$1" '(()=>{
    const q=s=>document.querySelector(s);
    const vis=b=>b&&b.offsetParent!==null;
    const btns=[...document.querySelectorAll("button")];
    const name=b=>((b.getAttribute("aria-label")||"")+" "+(b.dataset.testid||"")+" "+(b.textContent||""));
    const stop=btns.find(b=>vis(b)&&/stop|停止/i.test(b.getAttribute("aria-label")||b.dataset.testid||""));
    const retry=btns.find(b=>vis(b)&&/retry|try again|再試行/i.test(name(b)));
    const errTxt=/something went wrong|network error|エラーが発生/i.test((document.body&&document.body.innerText)||"");
    const composer=q("#prompt-textarea");
    return JSON.stringify({composer:!!composer,composerEmpty:!composer||((composer.innerText||"").trim()===""),generating:!!stop,retry:!!retry,errorText:errTxt,url:location.href});
  })()'
}

_cg_health() {   # <classify-json> -> HEALTHY_IDLE|GENERATING|ERROR_RETRYABLE|ERROR_PAGE|UNKNOWN
  local c="${1:-}"
  [ -n "$c" ] || c='{}'
  if [ "$(printf '%s' "$c" | jq -r '.generating')" = "true" ]; then echo GENERATING; return; fi
  if [ "$(printf '%s' "$c" | jq -r '.retry')" = "true" ]; then echo ERROR_RETRYABLE; return; fi
  if [ "$(printf '%s' "$c" | jq -r '.composer')" = "true" ]; then echo HEALTHY_IDLE; return; fi
  if [ "$(printf '%s' "$c" | jq -r '.errorText')" = "true" ]; then echo ERROR_PAGE; return; fi
  echo UNKNOWN
}

# _cg_inject <page> <text> — focus composer, insertText, then click send.
# Deliberately NOT one async eval: a Promise-returning expression that waits
# inside the page can be garbage-collected by the browser before it settles
# (orca reports "Promise was collected"), observed when inject ran under the
# dispatcher. All evals here are synchronous; the send-button wait is a bash
# loop of cheap evals instead of an in-page await.
_cg_inject() {
  local page="$1" text="$2" text_js res t0
  text_js="$(printf '%s' "$text" | jq -Rs .)"
  res="$(_cg_eval "$page" '(()=>{
    const el=document.querySelector("#prompt-textarea");
    if(!el) return JSON.stringify({ok:false,err:"no-composer"});
    if((el.innerText||"").trim()) return JSON.stringify({ok:false,err:"composer-busy"});
    el.focus();
    document.execCommand("insertText",false,'"$text_js"');
    return JSON.stringify({ok:true});
  })()')" || return 1
  [ "$(printf '%s' "$res" | jq -r '.ok // false' 2>/dev/null)" = "true" ] || {
    printf '%s' "$res"; return 0; }

  # Send button enables once the editor registers the inserted text.
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt 10 ]; do
    res="$(_cg_eval "$page" '(()=>{
      const b=[...document.querySelectorAll("button")].find(x=>x.offsetParent!==null&&!x.disabled&&/send|送信/i.test((x.getAttribute("aria-label")||"")+" "+(x.dataset.testid||"")));
      return JSON.stringify({ready:!!b});
    })()' 2>/dev/null || true)"
    [ "$(printf '%s' "$res" | jq -r '.ready // false' 2>/dev/null)" = "true" ] && break
    sleep 0.5
  done
  [ "$(printf '%s' "$res" | jq -r '.ready // false' 2>/dev/null)" = "true" ] || {
    printf '%s' '{"ok":false,"err":"send-button-disabled"}'; return 0; }

  _cg_eval "$page" '(()=>{
    const b=[...document.querySelectorAll("button")].find(x=>x.offsetParent!==null&&!x.disabled&&/send|送信/i.test((x.getAttribute("aria-label")||"")+" "+(x.dataset.testid||"")));
    if(!b) return JSON.stringify({ok:false,err:"send-button-gone"});
    b.click(); return JSON.stringify({ok:true});
  })()'
}

# _cg_send_confirmed <page> <mid> — "confirmed" = a real user message node
# in the transcript carries our mid marker. Composer echo alone does NOT
# count (optimistic render can roll back).
_cg_send_confirmed() {
  local page="$1" mid="$2" mid_js
  mid_js="$(printf '%s' "$mid" | jq -Rs .)"
  _cg_eval "$page" '(()=>{
    const msgs=[...document.querySelectorAll("[data-message-author-role=\"user\"]")];
    return JSON.stringify({confirmed:msgs.some(m=>(m.innerText||"").includes('"$mid_js"'))});
  })()' | jq -r '.confirmed // false' 2>/dev/null
}

# _cg_reply_state <page> <mid> — JSON: {found, reply, generating}
# reply = innerText of the FIRST assistant message AFTER the user message
# carrying mid (not "the last assistant message" -- a human typing in the
# same conversation must not leak another exchange into this reply).
_cg_reply_state() {
  local page="$1" mid="$2" mid_js
  mid_js="$(printf '%s' "$mid" | jq -Rs .)"
  _cg_eval "$page" '(()=>{
    const all=[...document.querySelectorAll("[data-message-author-role]")];
    const midIdx=all.findIndex(m=>m.dataset.messageAuthorRole==="user"&&(m.innerText||"").includes('"$mid_js"'));
    let reply="";
    if(midIdx>=0){
      for(let i=midIdx+1;i<all.length;i++){
        if(all[i].dataset.messageAuthorRole==="assistant"){reply=all[i].innerText||"";break}
      }
    }
    const stop=[...document.querySelectorAll("button")].find(b=>b.offsetParent!==null&&/stop|停止/i.test((b.getAttribute("aria-label")||"")+" "+(b.dataset.testid||"")));
    return JSON.stringify({found:midIdx>=0&&reply.length>0,reply,generating:!!stop});
  })()'
}

_cg_reload() { _cg_orca reload --page "$1" >/dev/null; }

_cg_click_retry() {   # <page> — click a visible retry-ish button via eval
  _cg_eval "$1" '(()=>{
    const b=[...document.querySelectorAll("button")].find(x=>x.offsetParent!==null&&/retry|try again|再試行/i.test((x.getAttribute("aria-label")||"")+" "+x.textContent));
    if(!b) return JSON.stringify({ok:false});
    b.click(); return JSON.stringify({ok:true});
  })()' >/dev/null
}

# _cg_judge <config_dir> <judge_member> <question_body_json> — ask a jev
# member of the SAME team for one arbitration. Directly invokes that
# driver's handle (these are internal mechanics, not team traffic; routing
# them through send.sh would spam team history and race the inbox cursor).
# Prints jev's one-line reply on stdout; non-zero when unavailable.
_cg_judge() {
  local dir="$1" member="$2" body="$3" jconf jhandle
  jconf="$dir/$member.conf"
  jhandle="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../jev/handle"
  [ -f "$jconf" ] && [ -f "$jhandle" ] || return 2
  jq -cn --arg cfg "$jconf" --arg body "$body" \
    '{team:"",from:"chatgpt",to:"jev",body:$body,config_path:$cfg}' |
    bash "$jhandle" 2>/dev/null
}

# _cg_watch_ensure <member.conf> — the transcript watcher is a plain
# process, not an agent, so nothing supervises it. Instead every delivery
# re-ensures it: if the singleton lock's owner pid is dead, spawn it. A
# reply that completed while the watcher was down is recovered by the
# watcher's baseline logic on restart.
_cg_watch_ensure() {
  local conf="$1" lock="$1.watchrun.lock.d" opid
  opid="$(awk '{print $1}' "$lock/owner" 2>/dev/null || true)"
  [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null && return 0
  rm -rf "$lock" 2>/dev/null
  # Detach hard: ext-tool-dispatch runs handle under `set -m` and kills the
  # whole process group (kill -- -PGID) on exit/timeout, so a plain `&`
  # child dies with us. setsid() gives the watcher its own session -- macOS
  # has no setsid binary, but /usr/bin/perl is always there.
  perl -MPOSIX -e 'fork() and exit 0; setsid(); exec @ARGV' \
    bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/watch-transcript.sh" "$conf" \
    >/dev/null 2>&1 </dev/null
  return 0
}

# Locking: mkdir is atomic on every filesystem we run on (no flock on
# macOS). Owner stamp lets a crashed holder's lock be reclaimed after
# stale_after seconds.
_cg_lock_acquire() {   # <lock_dir> <stale_after_s> <budget_s>
  local lock="$1" stale="$2" budget="$3" t0 now
  t0=$(date +%s)
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s %s\n' "$$" "$(date +%s)" > "$lock/owner" 2>/dev/null || true
      return 0
    fi
    now=$(date +%s)
    if [ -d "$lock" ]; then
      local ts
      ts="$(awk '{print $2}' "$lock/owner" 2>/dev/null || echo 0)"
      if [ "$((now - ${ts:-0}))" -gt "$stale" ]; then
        rm -rf "$lock" 2>/dev/null || true
        continue
      fi
    fi
    [ "$((now - t0))" -ge "$budget" ] && return 1
    sleep 1
  done
}
_cg_lock_release() { rm -rf "$1" 2>/dev/null || true; }
