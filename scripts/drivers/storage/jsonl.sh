#!/usr/bin/env bash
# jsonl storage driver (opt-in).
#
# Implements the storage contract (docs/spec/driver-interface.md §2, ADR 0003)
# over an append-only JSONL event log — the same canonical model as the sqlite
# driver (message_sent / message_read), but the file IS the store. Sourced by the
# storage facade (lib/storage.sh), so agmsg_db_path is in scope; the log lives at
# <db-dir>/events.jsonl.
#
# Engine: jq is the zero-extra-dep default (declared by storage_check). duckdb is
# an OPT-IN accelerator for the one hot anti-join (list_unread) on large logs —
# the PoC crossover is ~10-20k events (#207 / FINDINGS.md); below it jq's lack of
# startup cost wins, so the driver picks jq unless the log is big AND duckdb is on
# PATH. No daemon: duckdb runs file-direct, one process per query.
#
# Framing (§1.4): record-returning ops write JSONL to stdout and fail non-zero;
# control ops (check/init/mark_read_batch/compact) print a §1.4 status name.
#
# Delivery cursor (§2.2): a LOGICAL position — the ordinal count of message_sent
# events, NOT a byte offset. Compaction only coalesces message_read (never removes
# or reorders message_sent), so an ordinal stays valid across a log rewrite; a
# byte offset would not. The cursor is an opaque decimal string to core.

# --- helpers ---------------------------------------------------------------

# Where this driver (and its companion duckdb .sql) lives — captured at source
# time so the optional duckdb path can read the query from a data file rather than
# carry apostrophe-laden SQL inline (which the macOS bash 3.2 parser mis-handles).
_JSONL_DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
_JSONL_SYNC_HELPER_DEFAULT="$_JSONL_DRIVER_DIR/../../internal/jsonl-sync.mjs"

_jsonl_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# The storage selector for the call in progress. Every contract entry point below
# sets it before touching the log; _jsonl_log is the only reader.
#
# A variable rather than a parameter on ~20 internal helpers, and safe for one
# specific reason: it is only ever read DOWNWARD. Helpers run in this shell, and
# a `$( )` inside them inherits it. Nothing writes it back up — that direction
# does not survive a subshell, and relying on it is how caches and counters get
# silently thrown away.
#
# Unset is a loud failure, not a silent wrong store: agmsg_db_path rejects an
# empty selector.
_JSONL_TEAM=""
_jsonl_log() { printf '%s\n' "$(dirname "$(agmsg_db_path "$_JSONL_TEAM")")/events.jsonl"; }
_jsonl_read_cursors() {
  local log; log="$(_jsonl_log)"
  printf '%s\n' "$(dirname "$log")/read-cursors.tsv"
}
_jsonl_read_cursor_marker() {
  local log; log="$(_jsonl_log)"
  printf '%s\n' "$(dirname "$log")/.read-cursor-v1"
}

_jsonl_init_file() {
  local log; log="$(_jsonl_log)"
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  [ -f "$log" ] || : > "$log" 2>/dev/null || true
  _jsonl_read_cursor_migrate || return 1
}

# One-time Phase-3 adoption. Existing message history is treated as consumed so
# upgrading a monitor-heavy installation cannot replay its entire log. An empty
# fresh log writes an empty cursor file and starts naturally at zero.
_jsonl_read_cursor_migrate() {
  local marker lock i=0 log cursors tmp tip
  marker="$(_jsonl_read_cursor_marker)"; [ -f "$marker" ] && return 0
  lock="$marker.lock"
  until mkdir "$lock" 2>/dev/null; do
    [ -f "$marker" ] && return 0
    i=$((i + 1)); [ "$i" -ge 1000 ] && return 1
    sleep 0.01
  done
  if [ -f "$marker" ]; then rmdir "$lock" 2>/dev/null || true; return 0; fi
  log="$(_jsonl_log)"; cursors="$(_jsonl_read_cursors)"
  tmp=$(mktemp "${cursors}.tmp.XXXXXX") || { rmdir "$lock" 2>/dev/null || true; return 1; }
  tip=$(jq -s 'def logical_events: .[] | if .type=="sync_pull_commit" then
    .messages[]? | select(.status=="imported") | .local_event // empty else . end;
    [logical_events | select(.type=="message_sent")] | length' "$log") || {
    rm -f "$tmp"; rmdir "$lock" 2>/dev/null || true; return 1;
  }
  jq -r --argjson tip "$tip" -s 'def logical_events: .[] |
    if .type=="sync_pull_commit" then .messages[]? | select(.status=="imported") |
      .local_event // empty else . end;
    [logical_events | select(.type=="message_sent") | [.team,.to]] | unique[] |
    @tsv + "\t" + ($tip|tostring)' "$log" > "$tmp" || { rm -f "$tmp"; rmdir "$lock" 2>/dev/null || true; return 1; }
  mv "$tmp" "$cursors" || { rm -f "$tmp"; rmdir "$lock" 2>/dev/null || true; return 1; }
  : > "$marker.tmp.$$" || { rmdir "$lock" 2>/dev/null || true; return 1; }
  mv "$marker.tmp.$$" "$marker" || { rm -f "$marker.tmp.$$"; rmdir "$lock" 2>/dev/null || true; return 1; }
  rmdir "$lock" 2>/dev/null || true
}

# Serialize all log mutations (append / mark / compact / import) behind a portable
# mkdir lock; record-returning reads hold the same lock through their snapshot EOF.
_jsonl_with_lock() {
  local lock i=0 rc=0 max="${AGMSG_JSONL_LOCK_TRIES:-1000}"
  lock="$(_jsonl_log).lock"
  until mkdir "$lock" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -ge "$max" ] && return 1
    sleep 0.01
  done
  "$@" || rc=$?
  rmdir "$lock" 2>/dev/null || true
  return $rc
}

# duckdb is used only when present AND the log is past the jq crossover. The check
# is byte-size based (file-direct I/O is size-bound, FINDINGS.md): ~5 MB ≈ tens of
# thousands of events. AGMSG_JSONL_ENGINE=jq|duckdb forces a choice (tests/bench).
_jsonl_use_duckdb() {
  local log sz; log="$(_jsonl_log)"
  # Imported messages live inside one atomic sync_pull_commit journal record.
  # The jq projection understands that nested record; the optional flat DuckDB
  # query does not. This correctness guard also overrides a forced engine.
  grep -q '"type":"sync_pull_commit"' "$log" 2>/dev/null && return 1
  case "${AGMSG_JSONL_ENGINE:-}" in
    jq) return 1 ;;
    duckdb) command -v duckdb >/dev/null 2>&1 && return 0 || return 1 ;;
  esac
  command -v duckdb >/dev/null 2>&1 || return 1
  sz=$(wc -c < "$log" 2>/dev/null | tr -d ' ') || return 1
  [ "${sz:-0}" -ge "${AGMSG_JSONL_DUCKDB_BYTES:-5242880}" ]
}

# --- contract: lifecycle ----------------------------------------------------

storage_check() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'AGMSG-DIRECTIVE: {"type":"install_deps","driver":"jsonl","commands":["brew install jq"],"reason":"jq not found on PATH"}\n'
    echo missing_deps
    return 10
  fi
  echo ok
}

storage_describe() {
  # Defaulted, not required: this is the one contract call with an optional
  # selector (see below), and callers that omit it run under `set -u`.
  _JSONL_TEAM="${1-}"
  # The selector is optional HERE and only here: describe reports driver
  # metadata, and the capabilities caller has no team to name. The path line
  # is the only team-dependent part, so it is reported only when a specific
  # store was asked about. This is not a second way to reach the store.
  printf 'name=jsonl\n'
  printf 'backend=append-only JSONL event log (jq; duckdb opt-in accelerator)\n'
  [ -z "${1-}" ] || printf 'log=%s\n' "$(_jsonl_log)"
  if _jsonl_sync_available; then printf 'capabilities=stage1-sync\n'; fi
}

storage_init() {
  _JSONL_TEAM="$1"
  _jsonl_init_file
  echo ok
}

# Does a store already exist? (does NOT create one.) The log is the store, so a
# read call-site can answer "no messages yet" without lazily creating events.jsonl.
storage_store_exists() { _JSONL_TEAM="$1"; [ -f "$(_jsonl_log)" ]; }

# --- optional Stage-1 remote synchronization -------------------------------

_jsonl_sync_node() {
  printf '%s\n' "${AGMSG_SYNC_NODE_BIN:-${AGMSG_NODE:-node}}"
}

_jsonl_sync_helper() {
  printf '%s\n' "$_JSONL_SYNC_HELPER_DEFAULT"
}

_jsonl_sync_available() {
  local node helper; node="$(_jsonl_sync_node)"; helper="$(_jsonl_sync_helper)"
  [ -f "$helper" ] || return 1
  if [ "${node#*/}" != "$node" ]; then [ -x "$node" ]; else command -v "$node" >/dev/null 2>&1; fi
}

_jsonl_sync_exec_locked() {
  local operation="$1"; shift
  local node helper; node="$(_jsonl_sync_node)"; helper="$(_jsonl_sync_helper)"
  _jsonl_sync_available || return 10
  "$node" "$helper" "$operation" "$(_jsonl_log)" "$@"
}

storage_sync_prepare_push() {
  _JSONL_TEAM="$1"
  _jsonl_init_file || return 13
  _jsonl_with_lock _jsonl_sync_exec_locked prepare "$@"
}

storage_sync_reconcile_push() {
  _JSONL_TEAM="$1"
  _jsonl_init_file || return 13
  _jsonl_with_lock _jsonl_sync_exec_locked reconcile "$@"
}

storage_sync_apply_pull() {
  _JSONL_TEAM="$1"
  _jsonl_init_file || return 13
  _jsonl_with_lock _jsonl_sync_exec_locked apply "$@"
}

storage_sync_reprocess() {
  _JSONL_TEAM="$1"
  _jsonl_init_file || return 13
  _jsonl_with_lock _jsonl_sync_exec_locked reprocess "$@"
}

# --- contract: messages -----------------------------------------------------

storage_send() {
  _JSONL_TEAM="$1"
  local team="$1" from="$2" to="$3" body="$4"
  local id at line; id="$(compat_uuid7)"; at="$(_jsonl_now)"
  _jsonl_init_file
  line="$(jq -nc --arg id "$id" --arg team "$team" --arg from "$from" \
    --arg to "$to" --arg body "$body" --arg at "$at" \
    '{type:"message_sent",id:$id,team:$team,from:$from,to:$to,body:$body,at:$at}')" \
    || return 1
  _jsonl_with_lock _jsonl_append "$line" || return 1
  printf '%s\n' "$id"
}
_jsonl_append() { printf '%s\n' "$1" >> "$(_jsonl_log)"; }

_jsonl_prepare_rotated_generation_locked() {
  local target="$1" log; log="$(_jsonl_log)"
  grep -Eq '"type":"sync_generation"|"driver_generation":' "$log" 2>/dev/null || return 0
  local node helper; node="$(_jsonl_sync_node)"; helper="$(_jsonl_sync_helper)"
  _jsonl_sync_available || return 10
  "$node" "$helper" rotate-generation "$target" >/dev/null
}

storage_list_unread() {
  _JSONL_TEAM="$1"
  _jsonl_init_file || return 1
  _jsonl_with_lock _jsonl_list_unread_locked "$@"
}

_jsonl_list_unread_locked() {
  local team="$1" agent="$2" limit=""
  shift 2
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  local log out cursor; log="$(_jsonl_log)"
  cursor=$(storage_read_cursor_get "$team" "$agent") || return 1
  if _jsonl_use_duckdb; then
    out="$(_jsonl_unread_duckdb "$team" "$agent" "$log" "$cursor")" || return 1
  else
    out="$(jq -c --arg team "$team" --arg agent "$agent" --argjson cursor "$cursor" -s '
      def logical_events: .[] | if .type=="sync_pull_commit" then
    .messages[]? | select(.status=="imported") | .local_event // empty else . end;
      [logical_events] as $events |
      (reduce $events[] as $e ({}; if $e.type=="message_read" and
        $e.team==$team and $e.agent==$agent then .[$e.msg_id]=true else . end)) as $read |
      [$events[] | select(.type=="message_sent")] | to_entries[] |
      select((.key + 1) > $cursor and .value.team==$team and .value.to==$agent and
        ($read[.value.id] | not)) | .value |
      {type:"message_sent",id:.id,team:.team,from:.from,to:.to,body:.body,at:.at}' "$log")" || return 1
  fi
  [ -n "$out" ] || return 0
  if [ -n "$limit" ]; then printf '%s\n' "$out" | head -n "$limit"; else printf '%s\n' "$out"; fi
}

# duckdb file-direct anti-join (opt-in, large logs). Same unread set AND identical
# record shape as the jq path. Fields are read as explicit VARCHAR columns — never
# read_json_auto, whose type inference would parse `at` as a TIMESTAMP and re-emit
# it as "Y-M-D H:M:S", losing the canonical ISO-8601 "...T...Z" the jq path keeps.
_jsonl_unread_duckdb() {
  local team="$1" agent="$2" log="$3" cursor="$4" tl al lg sql tpl
  # SQL-escape every value spliced into the query (team/agent are not apostrophe-
  # free per validate.sh, and the path may contain one) so a legal team/agent that
  # the jq path handles can't break — or silently misbehave on — the duckdb path.
  tl="$(printf '%s' "$team"  | sed "s/'/''/g")"
  al="$(printf '%s' "$agent" | sed "s/'/''/g")"
  lg="$(printf '%s' "$log"   | sed "s/'/''/g")"
  # Read the query from the companion .sql DATA file and fill placeholders with
  # plain bash substitution (literal, so a value with sed-special / regex chars is
  # safe). Keeping the SQL out of this shell file is what makes the driver parse
  # under macOS bash 3.2 (an inline apostrophe-laden SQL string desyncs its parser).
  tpl="$_JSONL_DRIVER_DIR/jsonl-unread.duckdb.sql"
  [ -f "$tpl" ] || return 1
  sql="$(cat "$tpl")"
  sql="${sql//__LG__/$lg}"
  sql="${sql//__TL__/$tl}"
  sql="${sql//__AL__/$al}"
  sql="${sql//__CUR__/$cursor}"
  printf '%s\n' "$sql" | duckdb -noheader -list 2>/dev/null
}

storage_read_cursor_get() {
  _JSONL_TEAM="$1"
  local team="$1" agent="$2" f
  _jsonl_init_file || return 1
  f="$(_jsonl_read_cursors)"
  [ -f "$f" ] || { printf '0\n'; return 0; }
  awk -F'\t' -v t="$team" -v a="$agent" '$1==t && $2==a {p=$3}
    END { print (p=="" ? 0 : p) }' "$f"
}

_jsonl_read_cursor_write_locked() {
  local team="$1" agent="$2" pos="$3" f tmp
  f="$(_jsonl_read_cursors)"; tmp=$(mktemp "${f}.tmp.XXXXXX") || return 1
  { [ -f "$f" ] && awk -F'\t' -v t="$team" -v a="$agent" '!($1==t && $2==a)' "$f"
    printf '%s\t%s\t%s\n' "$team" "$agent" "$pos"; } > "$tmp" || {
      rm -f "$tmp"; return 1;
    }
  mv "$tmp" "$f"
}

_jsonl_read_cursor_consume_locked() {
  local team="$1" agent="$2" target="$3"; shift 3
  local current safe log tip normalized
  current=$(storage_read_cursor_get "$team" "$agent") || return 1
  _jsonl_mark "$team" "$agent" "$@" || return 1
  log="$(_jsonl_log)"
  tip=$(jq -s 'def logical_events: .[] | if .type=="sync_pull_commit" then
    .messages[]? | select(.status=="imported") | .local_event // empty else . end;
    [logical_events | select(.type=="message_sent")] | length' "$log") || return 1
  # Cap against the same locked log snapshot. Compare canonical decimal strings
  # instead of shell integers so a maliciously huge target cannot overflow the
  # host shell before it is reduced to the real tip.
  normalized=$(printf '%s' "$target" | sed 's/^0*//'); [ -n "$normalized" ] || normalized=0
  target="$normalized"
  if [ "${#target}" -gt "${#tip}" ] || {
    [ "${#target}" -eq "${#tip}" ] && [[ "$target" > "$tip" ]];
  }; then
    target="$tip"
  fi
  safe=$(jq -r --arg team "$team" --arg agent "$agent" --argjson current "$current" \
    --argjson target "$target" -s -f "$_JSONL_DRIVER_DIR/jsonl-read-cursor.jq" "$log") || return 1
  [ "$safe" -ge "$current" ] || safe="$current"
  _jsonl_read_cursor_write_locked "$team" "$agent" "$safe"
}

storage_read_cursor_consume() {
  _JSONL_TEAM="$1"
  local team="$1" agent="$2" target="$3"; shift 3
  case "$target" in ''|*[!0-9]*) echo runtime_error; return 13 ;; esac
  _jsonl_init_file || { echo runtime_error; return 13; }
  _jsonl_with_lock _jsonl_read_cursor_consume_locked "$team" "$agent" "$target" "$@" \
    || { echo runtime_error; return 13; }
  echo ok
}

storage_mark_read_batch() {
  _JSONL_TEAM="$1"
  local team="$1" agent="$2"; shift 2
  [ $# -gt 0 ] || { echo ok; return 0; }
  local tip; tip=$(storage_watch_tip "$team:$agent") || { echo runtime_error; return 13; }
  storage_read_cursor_consume "$team" "$agent" "$tip" "$@"
}
_jsonl_mark() {
  local team="$1" agent="$2"; shift 2
  local log id at line existing; log="$(_jsonl_log)"
  # A failed scan of existing reads (e.g. a corrupt log) must abort the mark, not
  # silently treat every id as new and append — that would be the same swallowed
  # failure. The caller turns this non-zero into runtime_error.
  existing="$(jq -r --arg team "$team" --arg agent "$agent" \
    'select(.type=="message_read" and .team==$team and .agent==$agent) | .msg_id' \
    "$log")" || return 1
  for id in "$@"; do
    printf '%s\n' "$existing" | grep -Fxq "$id" && continue
    at="$(_jsonl_now)"
    line="$(jq -nc --arg id "$(compat_uuid7)" --arg msg_id "$id" --arg team "$team" \
      --arg agent "$agent" --arg at "$at" \
      '{type:"message_read",id:$id,msg_id:$msg_id,team:$team,agent:$agent,at:$at}')"
    printf '%s\n' "$line" >> "$log"
    existing="$existing"$'\n'"$id"
  done
}

# --- contract: watch (delivery cursor §2.2) ---------------------------------

storage_watch_tip() {
  _JSONL_TEAM="$(agmsg_pair_team "$@")" || return 13
  _jsonl_init_file || return 1
  _jsonl_with_lock _jsonl_watch_tip_locked
}

_jsonl_watch_tip_locked() {
  # An empty log makes jq return 0 with exit 0; a CORRUPT log makes jq fail, and
  # that must surface as a non-zero exit (data-op framing §2.1) — no `|| echo 0`
  # fallback that would mask a broken store as a fresh tip of 0.
  jq -s 'def logical_events: .[] | if .type=="sync_pull_commit" then
    .messages[]? | select(.status=="imported") | .local_event // empty else . end;
    [logical_events | select(.type=="message_sent")] | length' "$(_jsonl_log)"
}

storage_watch_after() {
  _JSONL_TEAM="$(agmsg_pair_team "${@:2}")" || return 13
  _jsonl_init_file || return 1
  _jsonl_with_lock _jsonl_watch_after_locked "$@"
}

_jsonl_watch_after_locked() {
  local cursor="$1"; shift
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  local pairs_json; pairs_json="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length>0))')"
  # One file read = one snapshot: the trailing cursor (total message_sent count)
  # is computed from the same scan, so it never runs ahead of the rows returned.
  jq -c --argjson cursor "$cursor" --argjson pairs "$pairs_json" -s '
    def logical_events: .[] | if .type=="sync_pull_commit" then
    .messages[]? | select(.status=="imported") | .local_event // empty else . end;
    [logical_events] as $events
    | (reduce $events[] as $event ({};
        if $event.type=="message_read" then
          .[([$event.team,$event.agent,$event.msg_id] | tojson)] = true
        else . end)) as $read
    | [$events[] | select(.type=="message_sent")] as $sent
    | ($sent
        | to_entries
        | map(select((.key >= $cursor)
              and ((.value.team + ":" + .value.to) as $p | ($pairs | index($p)) != null)
              and (($read[[.value.team,.value.to,.value.id] | tojson] // false) | not)))
        | .[].value
        | {type:"message_sent",id:.id,team:.team,from:.from,to:.to,body:.body,at:.at}),
      {type:"cursor",cursor:(($sent | length) | tostring)}
  ' "$(_jsonl_log)" 2>/dev/null
}

# --- contract: history ------------------------------------------------------

storage_history() {
  _JSONL_TEAM="$1"
  _jsonl_init_file || return 1
  _jsonl_with_lock _jsonl_history_locked "$@"
}

_jsonl_history_locked() {
  local team="$1"; shift
  local agent="" limit=""
  if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then agent="$1"; shift; fi
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="-1" ;; esac
  jq -c --arg team "$team" --arg agent "$agent" --argjson limit "$limit" -s '
    def logical_events: .[] | if .type=="sync_pull_commit" then
    .messages[]? | select(.status=="imported") | .local_event // empty else . end;
    [logical_events | select(.type=="message_sent" and .team==$team
            and ($agent=="" or .to==$agent or .from==$agent))
     | {type:"message_sent",id:.id,team:.team,from:.from,to:.to,body:.body,at:.at}]
    | (if $limit >= 0 and (length > $limit) then .[length-$limit:] else . end)
    | .[]
  ' "$(_jsonl_log)" 2>/dev/null
}

# --- contract: export / import / compact ------------------------------------

storage_export() {
  _JSONL_TEAM="$1"; shift
  _jsonl_init_file || return 1
  _jsonl_with_lock _jsonl_export_locked "$@"
}

_jsonl_export_locked() {
  # Forward-compat (§2.3): only the v1 event types are projected; unknown types
  # are dropped rather than leaked.
  jq -c -s 'def logical_events: .[] | if .type=="sync_pull_commit" then
    .messages[]? | select(.status=="imported") | .local_event // empty else . end;
    logical_events | select(.type=="message_sent" or .type=="message_read")' \
    "$(_jsonl_log)" > "$1"
}

storage_import() {
  _JSONL_TEAM="$1"; shift
  local file="$1"; [ -f "$file" ] || return 1
  _jsonl_init_file
  _jsonl_with_lock _jsonl_import_do "$file"
}
_jsonl_import_do() {
  jq -c 'select(.type=="message_sent" or .type=="message_read")' "$1" >> "$(_jsonl_log)"
}

storage_compact() {
  _JSONL_TEAM="$1"
  _jsonl_init_file
  _jsonl_with_lock _jsonl_compact_do || { echo runtime_error; return 13; }
  echo ok
}

# Internal rename hooks keep the store-owned cursor beside its rewritten event
# identity. The cursor file briefly contains both keys before the log flips, so
# a crash can only leave a redundant cursor key, never a message with no usable
# read frontier.
_jsonl_rename_agent_locked() {
  local team="$1" old="$2" new="$3" log cursors log_tmp dual_tmp clean_tmp
  log="$(_jsonl_log)"; cursors="$(_jsonl_read_cursors)"
  log_tmp=$(mktemp "${log}.rename.XXXXXX") || return 1
  dual_tmp=$(mktemp "${cursors}.rename-dual.XXXXXX") || { rm -f "$log_tmp"; return 1; }
  clean_tmp=$(mktemp "${cursors}.rename-clean.XXXXXX") || {
    rm -f "$log_tmp" "$dual_tmp"; return 1;
  }
  jq -c --arg team "$team" --arg old "$old" --arg new "$new" '
    if .type == "sync_pull_commit" then
      .messages |= map(if .local_event != null and .local_event.team == $team then
        .local_event |= ((if .from == $old then .from = $new else . end) |
          (if .to == $old then .to = $new else . end)) else . end)
    elif .team != $team then .
    elif .type == "message_sent" then
      (if .from == $old then .from = $new else . end) |
      (if .to == $old then .to = $new else . end)
    elif .type == "message_read" and .agent == $old then .agent = $new
    else . end' "$log" > "$log_tmp" || {
      rm -f "$log_tmp" "$dual_tmp" "$clean_tmp"; return 1;
    }
  _jsonl_prepare_rotated_generation_locked "$log_tmp" || {
    rm -f "$log_tmp" "$dual_tmp" "$clean_tmp"; return 1;
  }
  awk -F '\t' -v OFS='\t' -v team="$team" -v old="$old" -v new="$new" '
    $1==team && $2==old { print; $2=new; print; next } { print }' "$cursors" > "$dual_tmp" || {
      rm -f "$log_tmp" "$dual_tmp" "$clean_tmp"; return 1;
    }
  awk -F '\t' -v OFS='\t' -v team="$team" -v old="$old" '
    !($1==team && $2==old) { print }' "$dual_tmp" > "$clean_tmp" || {
      rm -f "$log_tmp" "$dual_tmp" "$clean_tmp"; return 1;
    }
  mv "$dual_tmp" "$cursors" && mv "$log_tmp" "$log" && mv "$clean_tmp" "$cursors" || {
    rm -f "$log_tmp" "$dual_tmp" "$clean_tmp"; return 1;
  }
}

storage_rename_agent() {
  _JSONL_TEAM="$1"
  _jsonl_init_file || { echo runtime_error; return 13; }
  _jsonl_with_lock _jsonl_rename_agent_locked "$1" "$2" "$3" || {
    echo runtime_error; return 13;
  }
  echo ok
}

_jsonl_rename_team_locked() {
  local old="$1" new="$2" log cursors log_tmp dual_tmp clean_tmp
  log="$(_jsonl_log)"; cursors="$(_jsonl_read_cursors)"
  log_tmp=$(mktemp "${log}.rename.XXXXXX") || return 1
  dual_tmp=$(mktemp "${cursors}.rename-dual.XXXXXX") || { rm -f "$log_tmp"; return 1; }
  clean_tmp=$(mktemp "${cursors}.rename-clean.XXXXXX") || {
    rm -f "$log_tmp" "$dual_tmp"; return 1;
  }
  jq -c --arg old "$old" --arg new "$new" '
    if .binding.local_team == $old then .binding.local_team = $new else . end |
    if .type == "sync_pull_commit" then
      .messages |= map(if .local_event != null and .local_event.team == $old then
        .local_event.team = $new else . end)
    elif .team == $old then .team = $new else . end' \
    "$log" > "$log_tmp" || { rm -f "$log_tmp" "$dual_tmp" "$clean_tmp"; return 1; }
  _jsonl_prepare_rotated_generation_locked "$log_tmp" || {
    rm -f "$log_tmp" "$dual_tmp" "$clean_tmp"; return 1;
  }
  awk -F '\t' -v OFS='\t' -v old="$old" -v new="$new" '
    $1==old { print; $1=new; print; next } { print }' "$cursors" > "$dual_tmp" || {
      rm -f "$log_tmp" "$dual_tmp" "$clean_tmp"; return 1;
    }
  awk -F '\t' -v OFS='\t' -v old="$old" '$1!=old { print }' \
    "$dual_tmp" > "$clean_tmp" || { rm -f "$log_tmp" "$dual_tmp" "$clean_tmp"; return 1; }
  mv "$dual_tmp" "$cursors" && mv "$log_tmp" "$log" && mv "$clean_tmp" "$cursors" || {
    rm -f "$log_tmp" "$dual_tmp" "$clean_tmp"; return 1;
  }
}

storage_rename_team() {
  # The team's files live under its own name, so a rename has to move them
  # before it can rewrite them. rename-team.sh normally has already done so for
  # every driver at once; this move is the case where the driver is called on
  # its own, and it is guarded so the two never fight.
  #
  # Resolving on the old name after the move would find nothing, and
  # _jsonl_init_file would helpfully recreate it — an empty log beside the real
  # one, cursor lost. So paths resolve through the NEW name either way; the
  # old/new arguments below drive the CONTENT rewrite, not the location.
  local old_dir new_dir
  old_dir="$(dirname "$(agmsg_db_path "$1")")"
  new_dir="$(dirname "$(agmsg_db_path "$2")")"
  if [ -d "$old_dir" ] && [ ! -e "$new_dir" ]; then
    mkdir -p "$(dirname "$new_dir")"
    mv "$old_dir" "$new_dir" || { echo runtime_error; return 13; }
  fi
  _JSONL_TEAM="$2"
  _jsonl_init_file || { echo runtime_error; return 13; }
  _jsonl_with_lock _jsonl_rename_team_locked "$1" "$2" || {
    echo runtime_error; return 13;
  }
  echo ok
}
_jsonl_compact_do() {
  local log tmp; log="$(_jsonl_log)"; tmp="$log.compact.$$"
  # Keep every message_sent in order; collapse duplicate message_read for the same
  # (team, agent, msg_id) to the first seen. message_sent order is preserved, so
  # the ordinal delivery cursor stays valid (compaction cursor-safety, spec 2.7).
  # NOTE: this jq program is deliberately a SINGLE line — a multi-line
  # single-quoted jq string in this position desyncs the macOS system bash 3.2
  # parser and breaks the rest of the file (a no-error `bash -n`, but a real
  # source failure). Keep new jq one-liners here.
  jq -c -s 'reduce .[] as $e ({out:[], seen:{}}; if $e.type=="message_read" then ([$e.team,$e.agent,$e.msg_id]|tojson) as $k | if .seen[$k] then . else .seen[$k]=true | .out += [$e] end else .out += [$e] end) | .out[]' "$log" > "$tmp" || { rm -f "$tmp"; return 1; }
  _jsonl_prepare_rotated_generation_locked "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$log" || { rm -f "$tmp"; return 1; }
}
