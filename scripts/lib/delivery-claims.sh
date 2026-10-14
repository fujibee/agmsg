#!/usr/bin/env bash
# Machine delivery helpers, sourced after lib/storage.sh. Loading this file
# opens no store. Private function presence is not a public capability.

_agmsg_delivery_has_capability() {
  local wanted="$1" description line capabilities=""
  description="$(storage_describe)" || return 13
  while IFS= read -r line; do
    case "$line" in capabilities=*) capabilities="${line#capabilities=}" ;; esac
  done <<< "$description"
  case ",$capabilities," in *",$wanted,"*) return 0 ;; esac
  return 1
}

agmsg_delivery_claims_supported() { _agmsg_delivery_has_capability delivery-claims-v1; }
agmsg_delivery_claims_bytes_supported() { _agmsg_delivery_has_capability delivery-claims-bytes-v1; }

# Hex protects delimiters/newlines during shell parsing. printf is a builtin;
# decoded data never becomes external argv. The JSON reader rejects NUL.
_agmsg_delivery_decode_hex() {
  local _delivery_hex="$2" _delivery_escape=""
  case "$_delivery_hex" in *[!0-9a-fA-F]*) return 13 ;; esac
  [ $(( ${#_delivery_hex} % 2 )) -eq 0 ] || return 13
  if [ "${#_delivery_hex}" -gt 512 ]; then
    # Avoid repeatedly copying a large opaque ID. Data still travels on stdin,
    # and printf below remains a builtin (no per-argument size ceiling).
    _delivery_escape="$(printf '%s' "$_delivery_hex" | sed 's/../\\x&/g')" || return 13
  else
    while [ -n "$_delivery_hex" ]; do
      _delivery_escape="$_delivery_escape\\x${_delivery_hex:0:2}"
      _delivery_hex="${_delivery_hex:2}"
    done
  fi
  printf -v "$1" '%b' "$_delivery_escape"
}

# Validate bytes, including decoded JSON strings: SQLite JSON1 accepts some
# invalid UTF-8 and lone surrogate escapes that Node would replace or interpret
# differently. RFC 3629 section 4 bounds every continuation byte. od/awk are
# already used by the core; no new Node/Python dependency for shell readers.
_agmsg_delivery_validate_utf8() (
  set -o pipefail
  LC_ALL=C od -An -v -t u1 | LC_ALL=C awk '
    {
      for (i=1; i<=NF; i++) {
        b=$i+0
        if (remaining) {
          if (b<lower || b>upper) exit 1
          remaining--; lower=128; upper=191
        } else if (b==0) { exit 1 }
        else if (b<=127) { continue }
        else if (b>=194 && b<=223) { remaining=1; lower=128; upper=191 }
        else if (b>=224 && b<=239) {
          remaining=2; lower=(b==224 ? 160 : 128); upper=(b==237 ? 159 : 191)
        } else if (b>=240 && b<=244) {
          remaining=3; lower=(b==240 ? 144 : 128); upper=(b==244 ? 143 : 191)
        } else { exit 1 }
      }
    }
    END { if (remaining) exit 1 }
  '
)

# Call after populating records(document). Check object keys at every depth,
# then emit decoded strings only to the UTF-8 validator, never to the caller.
_agmsg_delivery_json_strings_sql() {
  printf '%s\n' "CREATE TEMP TABLE scalar_nodes AS
    SELECT r.rowid AS record_id,j.id AS node_id,j.parent AS parent_id,
           j.type AS node_type,j.key AS node_key,j.atom AS node_atom
      FROM records r,json_tree(r.document) j;
    CREATE TEMP TABLE object_keys(record_id,parent_id,node_key,
      UNIQUE(record_id,parent_id,node_key));
    INSERT INTO object_keys
      SELECT c.record_id,c.parent_id,c.node_key FROM scalar_nodes c
      JOIN scalar_nodes p ON p.record_id=c.record_id AND p.node_id=c.parent_id
      WHERE p.node_type='object';
    SELECT node_atom FROM scalar_nodes WHERE node_type='text';
    SELECT node_key FROM scalar_nodes WHERE typeof(node_key)='text';"
}

_agmsg_delivery_validate_request_text() (
  local document="$1" quote="'"
  set -o pipefail
  agmsg_sqlite_warm || exit 13
  printf '%s' "$document" | _agmsg_delivery_validate_utf8 || exit 13
  {
    printf '%s\n' "CREATE TEMP TABLE records(document TEXT NOT NULL
      CHECK(json_valid(document) AND json_type(document)='object'));"
    printf "INSERT INTO records VALUES('%s');\n" "${document//$quote/$quote$quote}"
    _agmsg_delivery_json_strings_sql
  } | { agmsg_sqlite_warm || exit 13; agmsg_sqlite -bail -batch ':memory:' 2>/dev/null; } | _agmsg_delivery_validate_utf8
)

# Populate AGMSG_CLAIM_* in this shell. A misspelled fence/TTL is an error,
# never a default with different semantics. Accept exactly one JSON object.
agmsg_delivery_parse_request() {
  local operation="$1" document="$2" allowed required required_count ids_required=0
  # JSON1 on supported SQLite versions truncates a decoded U+0000 before
  # instr() can inspect it. Strip escaped backslash pairs first so a literal
  # "\\u0000" stays valid, then reject actual NUL escapes in values AND keys.
  local unescaped_backslashes="${document//\\\\/}"
  case "$unescaped_backslashes" in
    *'\u0000'*) printf 'agmsg delivery: invalid_request\n' >&2; return 13 ;;
  esac
  case "$operation" in
    claim)
      allowed="'team','agent','owner','ttl','limit','ids','max_bytes'"
      required="'team','agent','owner'"; required_count=3 ;;
    renew)
      allowed="'team','agent','owner','token','ttl','ids'"
      required="'team','agent','owner','token'"; required_count=4; ids_required=1 ;;
    ack|release)
      allowed="'team','agent','owner','token','ids'"
      required="'team','agent','owner','token'"; required_count=4; ids_required=1 ;;
    peek)
      allowed="'team','agent','limit','max_bytes'"
      required="'team','agent'"; required_count=2 ;;
    *) printf 'agmsg delivery: invalid_operation\n' >&2; return 13 ;;
  esac
  local quote="'" escaped rows key value
  escaped="${document//$quote/$quote$quote}"
  agmsg_sqlite_warm || return 13
  _agmsg_delivery_validate_request_text "$document" || {
    printf 'agmsg delivery: invalid_request\n' >&2; return 13;
  }
  rows="$(
    set -o pipefail
    {
      printf "CREATE TEMP TABLE request(document TEXT NOT NULL CHECK(json_valid(document)));\n"
      printf "INSERT INTO request VALUES('%s');\n" "$escaped"
      printf '%s\n' "CREATE TEMP TABLE valid_request(ok INTEGER CHECK(ok=1));
        INSERT INTO valid_request SELECT CASE WHEN
          json_type(document)='object'
          AND NOT EXISTS(SELECT 1 FROM json_each(document) WHERE key NOT IN ($allowed))
          AND (SELECT COUNT(*) FROM json_each(document) WHERE key IN ($required))=$required_count
          AND NOT EXISTS(SELECT 1 FROM json_each(document)
            WHERE key IN ($required) AND (type!='text' OR value='' OR instr(value,char(0))>0))
          AND NOT EXISTS(SELECT 1 FROM json_each(document) WHERE key='ttl'
            AND (type!='integer' OR value<1 OR value>3600))
          AND NOT EXISTS(SELECT 1 FROM json_each(document) WHERE key='limit'
            AND (type!='integer' OR value<1 OR value>1000))
          AND NOT EXISTS(SELECT 1 FROM json_each(document) WHERE key='max_bytes'
            AND (type!='integer' OR value<4096 OR value>1048576))
          AND (json_type(document,'$.max_bytes') IS NULL OR
            (json_type(document,'$.ids') IS NULL AND COALESCE(json_extract(document,'$.limit'),32)<=32))
          AND NOT EXISTS(SELECT 1 FROM json_each(document) WHERE key='token'
            AND (length(value)!=64 OR value GLOB '*[^0-9a-f]*'))
          AND NOT EXISTS(SELECT 1 FROM json_each(document) WHERE key='ids' AND type!='array')
          AND NOT EXISTS(SELECT 1 FROM json_each(document,'$.ids')
            WHERE type!='text' OR value='' OR instr(value,char(0))>0)
          AND ($ids_required=0 OR COALESCE(json_array_length(document,'$.ids'),0)>0)
          AND (SELECT COUNT(*) FROM json_each(document))=
              (SELECT COUNT(DISTINCT key) FROM json_each(document))
          AND (SELECT COUNT(*) FROM json_each(document,'$.ids'))=
              (SELECT COUNT(DISTINCT value) FROM json_each(document,'$.ids'))
          THEN 1 ELSE 0 END FROM request;
        SELECT key||'|'||hex(CAST(value AS TEXT))
          FROM request,json_each(document) WHERE key!='ids';
        SELECT 'id|'||hex(value) FROM request,json_each(document,'$.ids');"
    } | { agmsg_sqlite_warm || exit 13; agmsg_sqlite -bail -batch ':memory:'; }
  )" || { printf 'agmsg delivery: invalid_request\n' >&2; return 13; }
  AGMSG_CLAIM_TEAM=""; AGMSG_CLAIM_AGENT=""; AGMSG_CLAIM_OWNER=""
  AGMSG_CLAIM_TOKEN=""; AGMSG_CLAIM_TTL=60; AGMSG_CLAIM_LIMIT=100
  AGMSG_CLAIM_MAX_BYTES=""; local limit_present=false
  AGMSG_CLAIM_IDS=()
  while IFS='|' read -r key value; do
    [ -n "$key" ] || continue
    _agmsg_delivery_decode_hex value "$value" || return 13
    case "$key" in
      team) AGMSG_CLAIM_TEAM="$value" ;;
      agent) AGMSG_CLAIM_AGENT="$value" ;;
      owner) AGMSG_CLAIM_OWNER="$value" ;;
      token) AGMSG_CLAIM_TOKEN="$value" ;;
      ttl) AGMSG_CLAIM_TTL="$value" ;;
      limit) AGMSG_CLAIM_LIMIT="$value"; limit_present=true ;;
      max_bytes) AGMSG_CLAIM_MAX_BYTES="$value" ;;
      id) AGMSG_CLAIM_IDS+=("$value") ;;
    esac
  done <<< "$rows"
  if [ -n "$AGMSG_CLAIM_MAX_BYTES" ] && [ "$limit_present" = false ]; then AGMSG_CLAIM_LIMIT=32; fi
}

_agmsg_delivery_require_capability() {
  local rc=0
  agmsg_delivery_claims_supported || rc=$?
  [ "$rc" -ne 0 ] || return 0
  if [ "$rc" -eq 1 ]; then
    printf 'agmsg delivery: delivery_claims_unavailable\n' >&2
  else
    printf 'agmsg delivery: capability_check_failed\n' >&2
  fi
  return 13
}

# Keep the entire committed result private until both admission checks pass.
# A reservation published during the storage call wins: its undisclosed lease
# expires without revealing a body or token to this caller.
_agmsg_delivery_capture() {
  local _capture_var="$1" _capture_file _capture_rc=0
  shift
  printf -v "$_capture_var" '%s' ''
  _capture_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/agmsg-delivery-records.XXXXXX")" || return 13
  # Command substitution strips raw NUL before validation. Keep the bytes in
  # a private file, check producer success, then detect NUL with Bash read.
  # No library EXIT trap: callers own their cleanup. SIGKILL may leave this
  # owner-only temporary file, as with the existing SQL-input temp files.
  if "$@" >"$_capture_file"; then
    if IFS= read -r -d '' "$_capture_var" <"$_capture_file"; then
      printf 'agmsg delivery: invalid_record_nul\n' >&2
      _capture_rc=13
    elif ! _agmsg_delivery_validate_records "$_capture_file"; then
      printf 'agmsg delivery: invalid_record_framing\n' >&2
      _capture_rc=13
    fi
  else
    _capture_rc=13
  fi
  rm -f "$_capture_file" || _capture_rc=13
  if [ "$_capture_rc" -ne 0 ]; then
    printf -v "$_capture_var" '%s' ''
    return 13
  fi
}

_agmsg_delivery_validate_records() (
  [ -s "$1" ] || exit 0
  set -o pipefail
  agmsg_sqlite_warm || exit 13
  _agmsg_delivery_validate_utf8 <"$1" || exit 13
  {
    printf '%s\n' "CREATE TEMP TABLE records(document TEXT NOT NULL
      CHECK(json_valid(document) AND json_type(document)='object'));"
    # Bash 3.2 pattern substitution repeatedly scans long matching records.
    # Keep this pass byte-oriented and linear instead: raw UTF-8/NUL was
    # checked above, and SQLite/decoded UTF-8 still validate the result below.
    LC_ALL=C awk -v quote="'" '
      {
        # JSON1 can truncate decoded NUL. Only an odd run of backslashes
        # before u0000 decodes to NUL; paired backslashes stay literal.
        if (index($0, "\\u0000")) {
          escaped=0; size=length($0)
          for (i=1; i<=size; i++) {
            character=substr($0,i,1)
            if (escaped) {
              if (character=="u" && substr($0,i+1,4)=="0000") exit 13
              escaped=0
            } else if (character=="\\") escaped=1
          }
        }
        gsub(quote,quote quote)
        printf "INSERT INTO records VALUES(%s%s%s);\n",quote,$0,quote
      }
    ' <"$1" || exit 13
    _agmsg_delivery_json_strings_sql
  } | { agmsg_sqlite_warm || exit 13; agmsg_sqlite -bail -batch ':memory:' 2>/dev/null; } | _agmsg_delivery_validate_utf8
)

_agmsg_delivery_emit_records() {
  [ -n "$1" ] || return 0
  printf '%s' "$1" || return $?
  case "$1" in *$'\n') ;; *) printf '\n' ;; esac
}

agmsg_delivery_claim_unread() {
  [ $# -ge 5 ] || { printf 'agmsg delivery: invalid_arguments\n' >&2; return 13; }
  _agmsg_delivery_require_capability || return 13
  declare -F agmsg_bridge_claim_guard_check >/dev/null 2>&1 || return 13
  agmsg_bridge_claim_guard_check claim "$1" "$2" "$3" "" "${@:6}" || return 13
  local result
  _agmsg_delivery_capture result storage_claim_unread "$@" || return 13
  agmsg_bridge_claim_guard_check claim "$1" "$2" "$3" "" "${@:6}" || return 13
  _agmsg_delivery_emit_records "$result"
}

_agmsg_delivery_control() {
  local operation="$1"; shift
  if ! _agmsg_delivery_require_capability; then printf 'runtime_error\n'; return 13; fi
  if ! declare -F agmsg_bridge_claim_guard_check >/dev/null 2>&1; then
    printf 'runtime_error\n'; return 13
  fi
  [ $# -ge 5 ] || { printf 'agmsg delivery: invalid_arguments\n' >&2; printf 'runtime_error\n'; return 13; }
  local ids_offset=5
  [ "$operation" != renew ] || ids_offset=6
  if ! agmsg_bridge_claim_guard_check "$operation" "$1" "$2" "$3" "$4" "${@:ids_offset}"; then
    printf 'runtime_error\n'; return 13
  fi
  "storage_claim_$operation" "$@"
}
agmsg_delivery_claim_renew() { _agmsg_delivery_control renew "$@"; }
agmsg_delivery_claim_ack() { _agmsg_delivery_control ack "$@"; }
agmsg_delivery_claim_release() { _agmsg_delivery_control release "$@"; }

# Readiness stays non-consuming and suppresses protected roles even when their
# durable batch has outlived a message lease. Ambiguous/corrupt reservation
# resolution is an error, never evidence that this role is available.
agmsg_delivery_list_deliverable() {
  _agmsg_delivery_require_capability || return 13
  local rc result
  agmsg_bridge_reservation_status "$1" "$2" && return 0
  rc=$?
  [ "$rc" -eq 1 ] || return 13
  _agmsg_delivery_capture result storage_list_deliverable "$@" || return 13
  agmsg_bridge_reservation_status "$1" "$2" && return 0
  rc=$?
  [ "$rc" -eq 1 ] || return 13
  _agmsg_delivery_emit_records "$result"
}

_agmsg_delivery_require_bytes_capability() {
  _agmsg_delivery_require_capability || return 13
  agmsg_delivery_claims_bytes_supported || {
    printf 'agmsg delivery: delivery_claims_bytes_unavailable\n' >&2; return 13;
  }
}

agmsg_delivery_claim_unread_bounded() {
  [ "$#" -eq 6 ] || return 13
  _agmsg_delivery_require_bytes_capability || return 13
  agmsg_bridge_claim_guard_check claim "$1" "$2" "$3" "" || return 13
  local result
  _agmsg_delivery_capture result storage_claim_unread_bounded "$@" || return 13
  agmsg_bridge_claim_guard_check claim "$1" "$2" "$3" "" || return 13
  _agmsg_delivery_emit_records "$result"
}

agmsg_delivery_list_deliverable_bounded() {
  [ "$#" -eq 4 ] || return 13
  _agmsg_delivery_require_bytes_capability || return 13
  local rc result
  agmsg_bridge_reservation_status "$1" "$2" && return 0
  rc=$?
  [ "$rc" -eq 1 ] || return 13
  _agmsg_delivery_capture result storage_list_deliverable_bounded "$@" || return 13
  agmsg_bridge_reservation_status "$1" "$2" && return 0
  rc=$?
  [ "$rc" -eq 1 ] || return 13
  _agmsg_delivery_emit_records "$result"
}
