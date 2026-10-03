#!/usr/bin/env bash
# Compatibility consumers of delivery-claims-v1. Claims are bounded to 1000
# rows per team/invocation; remaining backlog stays unread for the next poll.
# Bodies and opaque IDs travel through stdin/hex, never external argv or
# whitespace-separated ID lists. Callers own stdout and the handoff boundary.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/delivery-claims.sh"

agmsg_reader_init() {
  local rc=0
  AGMSG_READER_CLAIMS=0
  agmsg_delivery_claims_supported || rc=$?
  case "$rc" in
    0) AGMSG_READER_CLAIMS=1 ;;
    1)
      if [ "${_AGMSG_READER_WARNED:-0}" != 1 ]; then
        printf 'agmsg: storage driver has no delivery-claims-v1; using legacy delivery without reservation guarantees.\n' >&2
        _AGMSG_READER_WARNED=1
      fi
      ;;
    *) return 13 ;;
  esac
  AGMSG_READER_OWNER="shell:$$:${1:-reader}"
}

# An existing durable bridge reservation is ordinary contention. All other
# resolution errors, including a publication racing the facade's postcheck,
# remain errors. A reservation check never authorizes an ACK.
agmsg_reader_claim() {
  local rc=0
  agmsg_bridge_reservation_status "$1" "$2" && return 0
  rc=$?
  if [ "$rc" -ne 1 ]; then
    printf 'agmsg: read reservation state could not be validated; delivery was not attempted.\n' >&2
    return 13
  fi
  agmsg_delivery_claim_unread "$1" "$2" "$AGMSG_READER_OWNER" 60 "${3:-1000}"
}

# Private watch-group framing. SQL has already validated the records; keep the
# large formatted payload out of hex and decode only the small identity set.
# Nothing is exposed to a caller until the entire private capture is valid.
_agmsg_reader_watch_frame() {
  local file="$1" kind count token extra ih previous id marker payload header total_bytes clean_bytes
  local metadata="" seen='' index=0 row_id row_from row_body row_at row_team row_to row_token
  local ids=() hex_ids=() nul_pair='^(..)*00'
  # Line reads and command substitution can hide NUL. Verify the complete
  # private capture first, without a slow byte-at-a-time Bash read. Deleting
  # only NUL must leave the byte count unchanged; no filtered bytes are used.
  total_bytes="$(LC_ALL=C wc -c < "$file")" || return 13
  clean_bytes="$(set -o pipefail; LC_ALL=C tr -d '\000' < "$file" | LC_ALL=C wc -c)" || return 13
  total_bytes="${total_bytes//[[:space:]]/}"
  clean_bytes="${clean_bytes//[[:space:]]/}"
  case "$total_bytes" in ''|*[!0-9]*) return 13 ;; esac
  case "$clean_bytes" in ''|*[!0-9]*) return 13 ;; esac
  [ "$total_bytes" = "$clean_bytes" ] || return 13
  {
    IFS= read -r header || return 13
    IFS='|' read -r kind count token extra <<< "$header" || return 13
    [ "$header" = "$kind|$count|$token" ] || return 13
    case "$kind" in text|rows) ;; *) return 13 ;; esac
    case "$count" in ''|*[!0-9]*) return 13 ;; esac
    [ "${#count}" -le 2 ] && [ "$count" -ge 1 ] && [ "$count" -le 32 ] || return 13
    [ -z "$extra" ] && [ "${#token}" -eq 64 ] || return 13
    case "$token" in *[!0-9a-f]*) return 13 ;; esac
    while [ "$index" -lt "$count" ]; do
      IFS= read -r ih || return 13
      case "$ih" in ''|*[!0-9A-F]*) return 13 ;; esac
      [ $(( ${#ih} % 2 )) -eq 0 ] || return 13
      [[ ! "$ih" =~ $nul_pair ]] || return 13
      case "$seen" in *"|$ih|"*) return 13 ;; esac
      seen+="|$ih|"
      _agmsg_delivery_decode_hex id "$ih" || return 13
      ids+=("$id"); hex_ids+=("$ih")
      metadata+="$ih"$'\n'
      index=$((index + 1))
    done
    IFS= read -r marker || return 13
    [ "$marker" = AGMSG_READER_PAYLOAD ] || return 13
    # A final non-newline sentinel preserves every payload LF during command
    # substitution. Read the original validated bytes, and propagate failures.
    payload="$(cat || exit 13; printf '.')" || return 13
    case "$payload" in *.) payload="${payload%.}" ;; *) return 13 ;; esac
  } < "$file"
  case "$payload" in *$'\nAGMSG_READER_END\n') ;; *) return 13 ;; esac
  payload="${payload%$'AGMSG_READER_END\n'}"
  [ -n "$payload" ] || return 13
  case "$payload" in *$'\n') ;; *) return 13 ;; esac
  if [ "$kind" = text ]; then
    # Eligible header fields and normalized bodies contain no physical LF.
    # Thus every SQL result row is exactly one output line, even for big bodies.
    local lines
    lines="$(set -o pipefail; printf '%s' "$payload" | LC_ALL=C awk 'END { print NR }')" || return 13
    [ "$lines" = "$count" ] || return 13
  else
    index=0
    while IFS='|' read -r row_id row_from row_body row_at row_team row_to row_token; do
      [ "$index" -lt "$count" ] || return 13
      [ "$row_id" = "${hex_ids[$index]}" ] || return 13
      for ih in "$row_from" "$row_body" "$row_at" "$row_team" "$row_to" "$row_token"; do
        case "$ih" in *[!0-9A-F]*) return 13 ;; esac
        [ $(( ${#ih} % 2 )) -eq 0 ] || return 13
        [[ ! "$ih" =~ $nul_pair ]] || return 13
      done
      _agmsg_delivery_decode_hex previous "$row_token" || return 13
      [ "$previous" = "$token" ] || return 13
      index=$((index + 1))
    done <<< "${payload%$'\n'}"
    [ "$index" -eq "$count" ] || return 13
  fi
  AGMSG_READER_IDS=("${ids[@]}")
  AGMSG_READER_TOKEN="$token"
  AGMSG_READER_METADATA="$token"$'\n'"$metadata"
  AGMSG_READER_GROUP_KIND="$kind"
  if [ "$kind" = text ]; then
    AGMSG_READER_TEXT="$payload"
  else
    AGMSG_READER_ROWS="${payload%$'\n'}"
  fi
}

# Decode an entire validated result before preparing output. Internal columns
# are hex, including the ID; a newline/tab/pipe in an ID cannot split a record.
agmsg_reader_parse() {
  local jsonl="$1" style="${2:-inbox}" claimed="${3:-1}"
  local expected_team="${4:?missing expected team}" expected_agent="${5:?missing expected agent}"
  local document quote="'" rows ih fh bh th teamh toh tokenh
  local id from body ts team to token body_sql watch_file="" parse_rc=0
  AGMSG_READER_IDS=()
  AGMSG_READER_TOKEN=""
  AGMSG_READER_TEXT=""
  AGMSG_READER_ROWS=""
  AGMSG_READER_METADATA=""
  AGMSG_READER_GROUP_KIND=""
  [ -n "$jsonl" ] || return 0
  document="[$(printf '%s\n' "$jsonl" | paste -sd, -)]" || return 13
  # Only decoded NUL can be hidden by SQLite JSON1. Most records contain no
  # candidate escape, so avoid copying a large document just to prove absence.
  case "$document" in
    *'\u0000'*)
      local no_escaped_backslashes="${document//\\\\/}"
      case "$no_escaped_backslashes" in *'\u0000'*) return 13 ;; esac
      ;;
  esac
  body_sql="replace(replace(json_extract(value,'\$.body'),char(10),'\n'),char(9),'\t')"
  case "$style" in watch|watch-group) body_sql="replace($body_sql,char(13),'')" ;; esac
  if [ "$style" = watch-group ]; then
    watch_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/agmsg-watch-prepared.XXXXXX")" || return 13
  fi
  rows="$(
    set -o pipefail
    {
      printf '%s\n' 'CREATE TABLE input(document TEXT CHECK(json_valid(document)));'
      printf "INSERT INTO input VALUES('"
      # Escape through stdin: whole-document Bash substitution scales poorly
      # for large groups. Byte-wise quoting preserves UTF-8 verbatim. Keep the
      # inner pipeline failure explicit so the closing printf cannot hide it.
      printf '%s' "$document" | LC_ALL=C sed "s/'/''/g" || exit 13
      printf "');\n"
      printf '%s\n' "CREATE TABLE valid(ok INTEGER CHECK(ok=1));
        INSERT INTO valid SELECT CASE WHEN NOT EXISTS(
          SELECT 1 FROM input,json_each(document)
          WHERE json_type(value)!='object'
            OR json_type(value,'\$.id') NOT IN ('text','integer')
            OR COALESCE(CAST(json_extract(value,'\$.id') AS TEXT),'')=''
            OR COALESCE(json_type(value,'\$.from'),'')!='text'
            OR COALESCE(json_type(value,'\$.body'),'')!='text'
            OR COALESCE(json_type(value,'\$.at'),'')!='text'
            OR COALESCE(json_type(value,'\$.team'),'')!='text'
            OR COALESCE(json_type(value,'\$.to'),'')!='text'
            OR json_extract(value,'\$.team')!='${expected_team//$quote/$quote$quote}'
            OR json_extract(value,'\$.to')!='${expected_agent//$quote/$quote$quote}'
            OR ($claimed=1 AND (
              COALESCE(json_type(value,'\$.claim_token'),'')!='text'
              OR length(json_extract(value,'\$.claim_token'))!=64
              OR json_extract(value,'\$.claim_token') GLOB '*[^0-9a-f]*'))
        ) AND (SELECT COUNT(*) FROM input,json_each(document))=
          (SELECT COUNT(DISTINCT CAST(json_extract(value,'\$.id') AS TEXT)) FROM input,json_each(document))
          AND ($claimed=0 OR (SELECT COUNT(DISTINCT json_extract(value,'\$.claim_token'))
             FROM input,json_each(document))=1)
        THEN 1 ELSE 0 END;"
      if [ "$style" = watch-group ]; then
        printf '%s\n' "CREATE TEMP TABLE prepared AS SELECT
          CAST(key AS INTEGER) AS ord,CAST(json_extract(value,'\$.id') AS TEXT) AS id,
          json_extract(value,'\$.from') AS sender,$body_sql AS body,
          json_extract(value,'\$.at') AS at,json_extract(value,'\$.team') AS team,
          json_extract(value,'\$.to') AS recipient,json_extract(value,'\$.claim_token') AS token
          FROM input,json_each(document);
          CREATE TEMP TABLE mode AS SELECT CASE WHEN EXISTS(SELECT 1 FROM prepared
            WHERE body='ctrl:despawn'
              OR instr(at,char(10)) OR instr(at,char(13))
              OR instr(sender,char(10)) OR instr(sender,char(13))
              OR instr(team,char(10)) OR instr(team,char(13))
              OR instr(recipient,char(10)) OR instr(recipient,char(13)))
            THEN 'rows' ELSE 'text' END AS kind;
          SELECT kind||'|'||(SELECT COUNT(*) FROM prepared)||'|'||
            (SELECT token FROM prepared ORDER BY ord LIMIT 1) FROM mode;
          SELECT hex(id) FROM prepared ORDER BY ord;
          SELECT 'AGMSG_READER_PAYLOAD';
          SELECT at||' | '||team||' | '||sender||' → '||recipient||' | '||body
            FROM prepared WHERE (SELECT kind FROM mode)='text' ORDER BY ord;
          SELECT hex(id)||'|'||hex(sender)||'|'||hex(body)||'|'||hex(at)||'|'||
            hex(team)||'|'||hex(recipient)||'|'||hex(token)
            FROM prepared WHERE (SELECT kind FROM mode)='rows' ORDER BY ord;
          SELECT 'AGMSG_READER_END';"
      else
        printf '%s\n' "SELECT hex(CAST(json_extract(value,'\$.id') AS TEXT))||'|'||
          hex(json_extract(value,'\$.from'))||'|'||hex($body_sql)||'|'||
          hex(json_extract(value,'\$.at'))||'|'||
          hex(COALESCE(json_extract(value,'\$.team'),''))||'|'||
          hex(COALESCE(json_extract(value,'\$.to'),''))||'|'||
          hex(COALESCE(json_extract(value,'\$.claim_token'),''))
        FROM input,json_each(document);"
      fi
    } | {
      if [ -n "$watch_file" ]; then
        agmsg_sqlite -bail -batch ':memory:' > "$watch_file"
      else
        agmsg_sqlite -bail -batch ':memory:'
      fi
    }
  )" || parse_rc=13
  if [ -n "$watch_file" ]; then
    if [ "$parse_rc" -eq 0 ]; then
      _agmsg_reader_watch_frame "$watch_file" || parse_rc=13
    fi
    rm -f "$watch_file" || parse_rc=13
    return "$parse_rc"
  fi
  [ "$parse_rc" -eq 0 ] || return 13
  while IFS='|' read -r ih fh bh th teamh toh tokenh; do
    [ -n "$ih" ] || continue
    _agmsg_delivery_decode_hex id "$ih" || return 13
    _agmsg_delivery_decode_hex from "$fh" || return 13
    _agmsg_delivery_decode_hex body "$bh" || return 13
    _agmsg_delivery_decode_hex ts "$th" || return 13
    _agmsg_delivery_decode_hex team "$teamh" || return 13
    _agmsg_delivery_decode_hex to "$toh" || return 13
    _agmsg_delivery_decode_hex token "$tokenh" || return 13
    AGMSG_READER_IDS+=("$id")
    AGMSG_READER_TOKEN="$token"
    AGMSG_READER_METADATA+="$ih"$'\n'
    if [ "$style" = watch ]; then
      AGMSG_READER_TEXT+="$ts | $team | $from → $to | $body"$'\n'
    else
      AGMSG_READER_TEXT+="  [$ts] $from: $body"$'\n'
    fi
  done <<< "$rows"
  AGMSG_READER_METADATA="$AGMSG_READER_TOKEN"$'\n'"$AGMSG_READER_METADATA"
  AGMSG_READER_ROWS="$rows"
}

# Metadata is re-read from the original JSONL, keeping exact opaque IDs in a
# Bash array. On malformed driver output there may be an undisclosed claim;
# leave it to expire rather than guessing a fence or a partial set.
agmsg_reader_control() {
  local operation="$1" team="$2" agent="$3" jsonl="$4"
  agmsg_reader_parse "$jsonl" inbox 1 "$team" "$agent" || return 13
  [ "${#AGMSG_READER_IDS[@]}" -gt 0 ] || return 0
  agmsg_reader_control_metadata "$operation" "$team" "$agent" "$AGMSG_READER_METADATA"
}

# Prepared metadata is a validated token followed by one hex ID per line.
# Reuse it for renew/ACK: formatting a large body again would spend the lease
# on work unrelated to handoff and can starve a bounded 1000-row batch.
agmsg_reader_control_metadata() {
  local operation="$1" team="$2" agent="$3" metadata="$4"
  local token="${metadata%%$'\n'*}" ids_hex="${metadata#*$'\n'}" id_hex id
  local ids=()
  [ "${#token}" -eq 64 ] || return 13
  case "$token" in *[!0-9a-f]*) return 13 ;; esac
  while IFS= read -r id_hex; do
    [ -n "$id_hex" ] || continue
    _agmsg_delivery_decode_hex id "$id_hex" || return 13
    [ -n "$id" ] || return 13
    ids+=("$id")
  done <<< "$ids_hex"
  [ "${#ids[@]}" -gt 0 ] || return 13
  if [ "$operation" = renew ]; then
    agmsg_delivery_claim_renew "$team" "$agent" "$AGMSG_READER_OWNER" \
      "$token" 60 "${ids[@]}" >/dev/null
  else
    "agmsg_delivery_claim_$operation" "$team" "$agent" "$AGMSG_READER_OWNER" \
      "$token" "${ids[@]}" >/dev/null
  fi
}

agmsg_reader_release_metadata() {
  agmsg_reader_control_metadata release "$@" ||
    printf 'agmsg: could not release an unattempted delivery; its reservation will expire.\n' >&2
}

agmsg_reader_release() {
  agmsg_reader_control release "$@" ||
    printf 'agmsg: could not release an unattempted delivery; its reservation will expire.\n' >&2
}

# JSON quoting through stdin also escapes CR and all C0 bytes. No jq/runtime
# dependency and no shell substitution can reinterpret message text.
agmsg_reader_json_quote() {
  local quote="'"
  {
    printf "SELECT json_quote('"
    printf '%s' "${1//$quote/$quote$quote}"
    printf "');\n"
  } | agmsg_sqlite -bail -batch ':memory:'
}

agmsg_reader_barrier() {
  agmsg_reader_wait_barrier "${AGMSG_TEST_MARK_BARRIER:-}"
}

agmsg_reader_wait_barrier() {
  local barrier="$1"
  [ -n "$barrier" ] || return 0
  : > "$barrier.reached"
  local waited=0
  while [ ! -e "$barrier.release" ]; do
    sleep 0.05
    waited=$((waited + 1))
    [ "$waited" -lt 1200 ] || return 13
  done
}

# Capture classification and raw owner together, as watch does. Comparing only
# the derived "free" state can hide an ownership change between observations.
agmsg_reader_role_observe() {
  local observation
  observation="$(actas_lock_observe_cached "$1" "$2" "$3")" || return 13
  AGMSG_READER_ROLE_STATE="${observation%%$'\t'*}"
  AGMSG_READER_ROLE_OWNER="${observation#*$'\t'}"
  case "$AGMSG_READER_ROLE_STATE" in other:*|unknown:*) return 1 ;; esac
  case "$AGMSG_READER_ROLE_STATE" in free|mine) return 0 ;; esac
  return 13
}

agmsg_reader_role_matches() {
  local record current
  record="$(actas_lock_read_cached "$1" "$2")" || return 13
  case "$record" in
    ok$'\t'*) current="${record#*$'\t'}" ;;
    absent) current="" ;;
    absent$'\t'*) current="" ;;
    *) return 13 ;;
  esac
  [ "$current" = "$3" ]
}
