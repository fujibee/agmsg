#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   remote.sh connect --endpoint <url> [<token>] [--token-stdin] [<team>] [--force]
#   remote.sh status [<team>]
#   remote.sh disconnect <team>
#   remote.sh doctor [<team>]
#
# Team-scoped cloud/self-hosted sync connection (ADR 0007). The OSS CLI never
# assumes or defaults to any particular server — <endpoint> is always
# required. Login/token acquisition is out of this repo's scope (ADR 0007
# §1a-§1c) — some provider tooling (or a self-hosted server's own admin
# command) obtains the token; this script only ever receives one.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"

TEAMS_DIR="$SCRIPT_DIR/../teams"
CRED_ROOT="$SKILL_DIR/run/remote-credentials"
PENDING_DIR="$SKILL_DIR/run/remote-connect-pending"

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }

_remote_team_config() { printf '%s' "$TEAMS_DIR/$1/config.json"; }
_remote_cred_file() { printf '%s' "$CRED_ROOT/$1.json"; }

_remote_read_config_field() {
  local cfg="$1" path="$2" escaped
  [ -f "$cfg" ] || { echo "null"; return; }
  escaped=$(sed "s/'/''/g" "$cfg")
  agmsg_sqlite_mem ".param set :json '$escaped'" "SELECT json_extract(:json, '$path');"
}

# Bootstrap a brand-new local team dir/config, mirroring join.sh's own
# initial-config shape exactly (no agents registered yet — connect only
# establishes the sync binding, not an agent identity in the team).
_remote_ensure_team() {
  local team="$1" cfg
  cfg="$(_remote_team_config "$team")"
  if [ ! -f "$cfg" ]; then
    mkdir -p "$TEAMS_DIR/$team"
    local initial
    initial=$(printf '{\n  "name": "%s",\n  "agents": {},\n  "created_at": "%s"\n}' \
      "$team" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    agmsg_write_atomic "$cfg" "$initial"
  fi
}

# Reject a non-HTTPS endpoint (token/credential would cross the wire in
# plaintext) except for loopback, which self-host/dev setups need without a
# cert (ADR 0007 review findings B6/R2). Delegates to a real URL parser —
# a shell glob/prefix check here was bypassable by
# http://127.0.0.1.evil.com, http://localhost.evil.com, and the userinfo
# trick http://localhost@evil.com, all of which matched a naive
# `http://127.0.0.1*`/`http://localhost*` case pattern while actually
# pointing at a different host.
_remote_validate_endpoint() {
  python3 "$SCRIPT_DIR/internal/validate-endpoint.py" "$1"
}

# --- doctor ------------------------------------------------------------

# Standalone, read-only, always-safe-to-run preflight (ADR 0007 §1): no
# token, no state change, safe whether or not the team is already connected.
# Currently just the age-binary-presence check (§8) — the natural home for
# any future preflight check added later.
cmd_doctor() {
  local team="${1:-}"
  echo "Checking prerequisites${team:+ for team '$team'}..."
  echo
  if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
    echo "  [x] age / age-keygen on PATH"
    echo
    echo "All checks passed."
  else
    echo "  [ ] age / age-keygen on PATH"
    echo
    echo "'age' is required for end-to-end encryption and was not found on this device. Install it, then retry:"
    echo "  macOS (Homebrew):      brew install age"
    echo "  Debian/Ubuntu:         sudo apt install age"
    echo "  Windows (winget):      winget install FiloSottile.age"
    echo "See https://github.com/FiloSottile/age for other install methods."
    echo
    echo "1 check failed."
    exit 1
  fi
}

# --- shared HTTP helpers (B1: never put secrets in curl's own argv/ps) ---

# _remote_http_post_json <url> <body_file> <out_body_file> -> prints http_code
# Posts <body_file> as the request body via a curl -K config file, so the
# body (which holds the token) never appears in curl's own argv/ps. The
# config file is 0600 and removed immediately after the call.
_remote_http_post_json() {
  local url="$1" body_file="$2" out_file="$3" cfg http_code
  cfg="$(mktemp "${TMPDIR:-/tmp}/agmsg-curl-cfg.XXXXXX")"
  chmod 600 "$cfg"
  trap 'rm -f "$cfg"' EXIT INT TERM
  {
    printf 'url = "%s"\n' "$url"
    printf 'request = "POST"\n'
    printf 'header = "Content-Type: application/json"\n'
    printf 'data = "@%s"\n' "$body_file"
  } > "$cfg"
  http_code=$(curl -sS -o "$out_file" -w '%{http_code}' -K "$cfg" 2>/dev/null) || http_code="000"
  rm -f "$cfg"
  trap - EXIT INT TERM
  printf '%s' "$http_code"
}

# _remote_http_post_bearer <url> <bearer_token> -> prints http_code
# Same argv-safety property for the Authorization header (revoke calls).
_remote_http_post_bearer() {
  local url="$1" token="$2" cfg http_code
  cfg="$(mktemp "${TMPDIR:-/tmp}/agmsg-curl-cfg.XXXXXX")"
  chmod 600 "$cfg"
  trap 'rm -f "$cfg"' EXIT INT TERM
  {
    printf 'url = "%s"\n' "$url"
    printf 'request = "POST"\n'
    printf 'header = "Authorization: Bearer %s"\n' "$token"
  } > "$cfg"
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' -K "$cfg" 2>/dev/null) || http_code="000"
  rm -f "$cfg"
  trap - EXIT INT TERM
  printf '%s' "$http_code"
}

# _remote_revoke <endpoint> <credential_id> <credential> -> 0 revoked, 1 not
# STRICTLY 200 only (E2 — reverted from an earlier "200 or 404 both
# count" version): a bare HTTP 404 status is not trustworthy proof the
# credential is actually gone. It's equally consistent with a wrong
# path/protocol-version mismatch, a proxy returning 404, or a server that
# doesn't implement this route at all — none of which mean the credential
# is inactive. Treating any of those as "revoked" would let the CLI
# report success while the credential stays fully active server-side,
# exactly the failure this check exists to prevent. Absent a pinned
# server contract for an authenticated "credential not found" response
# body distinct from a generic 404, the safe default is fail-closed on
# anything but 200 — a stuck retry (requiring a console-side revoke) is
# the correct failure mode here, not a false "confirmed revoked."
_remote_revoke() {
  local endpoint="$1" credential_id="$2" credential="$3" http_code
  http_code="$(_remote_http_post_bearer "$endpoint/v1/credentials/$credential_id/revoke" "$credential")"
  [ "$http_code" = "200" ]
}

# _remote_local_disconnect <team> <cfg> [expected_credential_id]
# The local-state half of disconnect (credential file removal + marking
# the binding disconnected) — factored out so the --force rebind path can
# apply it immediately after a successful revoke, before ever attempting
# the new exchange (D2): otherwise a crash between "old credential
# revoked" and "new connection fully committed" leaves local state
# claiming to still be connected to a credential that the server has
# already invalidated, with no way to tell from local state alone.
#
# When <expected_credential_id> is given, the credential_id check AND the
# cred-file removal AND the disconnected_at write all happen under ONE
# lock acquisition, and only if the binding's CURRENT credential_id still
# equals it (E1): the earlier version removed the cred file before ever
# taking the lock and unmarked "whatever binding is currently there"
# unconditionally, with no check that it was still the same one this
# caller revoked — a second concurrent operation's legitimately newer
# binding (for a different credential this call never touched or
# revoked) could get silently clobbered and its own credential file
# deleted, orphaning it exactly like the bug this was meant to fix.
# Returns 0 on success, 1 on lock failure, 2 if <expected_credential_id>
# no longer matches (caller must treat this as "someone else already
# changed this team's binding — abort, don't proceed").
_remote_local_disconnect() {
  local team="$1" cfg="$2" expected_credential_id="${3:-}" \
    cred_file escaped updated disconnected_at current_credential_id
  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 1
  if [ -n "$expected_credential_id" ]; then
    current_credential_id="$(_remote_read_config_field "$cfg" '$.remote_binding.credential_id')"
    if [ "$current_credential_id" != "$expected_credential_id" ]; then
      agmsg_lock_release
      return 2
    fi
  fi
  cred_file="$(_remote_cred_file "$team")"
  rm -f "$cred_file"
  disconnected_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  escaped=$(sed "s/'/''/g" "$cfg")
  updated=$(agmsg_sqlite_mem ".param set :json '$escaped'" \
    "SELECT json_set(:json, '\$.remote_binding.disconnected_at', '$(_agmsg_sqlesc "$disconnected_at")');")
  agmsg_write_atomic "$cfg" "$updated"
  agmsg_lock_release
}

# --- connect -------------------------------------------------------------

# A resumability key derived from (endpoint, token) — known BEFORE any
# network call, so it doesn't depend on the local team name, which may not
# be known until the exchange response comes back (B5: the earlier design
# keyed pending state by team name, which couldn't cover that case at all).
# The token itself is never written to disk or logged — only this
# irreversible digest of it, so the pending record can't be used to recover
# the token, and repeating the exact same (endpoint, token) pair after a
# crash resumes instead of re-consuming a token that may already be spent.
_remote_pending_key() {
  local endpoint="$1" token="$2"
  printf '%s\0%s' "$endpoint" "$token" | python3 -c "import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())"
}

_remote_pending_file() { printf '%s' "$PENDING_DIR/$1.json"; }

# _remote_write_pending <key> <resp_file> <endpoint>
# Durable, atomic (temp+rename), 0600 record of a successful exchange whose
# local commit has not (yet) fully completed — deliberately does NOT
# include the token. A crash between the exchange and _remote_commit
# finishing resumes from here on a retry with the same (endpoint, token),
# instead of needing (and orphaning a credential for) a fresh single-use
# token (B5).
#
# Takes the RAW response file and embeds its exact bytes VERBATIM as a
# JSON string value (never re-parsed/re-serialized as a nested object,
# and never the individually-extracted credential/credential_id/etc as
# their own values) — <resp_file> and <endpoint> are passed to python3 by
# PATH and as a non-secret string respectively, so the secret itself is
# read only via file I/O inside the python process and never appears as
# any process's own argv element (R1: an earlier version of this function
# passed the credential as a positional python3 argument, which any
# concurrent `ps` could read for as long as that process was alive).
# Storing the raw bytes verbatim rather than round-tripping through
# json.load()+json.dumps() also closes D4: a reparse/reserialize step
# would silently collapse duplicate keys with no trace, before resume
# ever gets a chance to run the duplicate-detecting strict validator
# against them.
_remote_write_pending() {
  local key="$1" resp_file="$2" endpoint="$3" pending_file tmp json
  mkdir -p "$PENDING_DIR"
  chmod 700 "$PENDING_DIR" 2>/dev/null || true
  pending_file="$(_remote_pending_file "$key")"
  json=$(python3 -c '
import json, sys
resp_path, endpoint = sys.argv[1], sys.argv[2]
with open(resp_path) as f:
    raw_response_text = f.read()
print(json.dumps({"endpoint": endpoint, "raw_response_text": raw_response_text}))
' "$resp_file" "$endpoint")
  tmp="$(mktemp "$PENDING_DIR/.pending-XXXXXX")"
  chmod 600 "$tmp"
  trap 'rm -f "$tmp"' EXIT INT TERM
  printf '%s\n' "$json" > "$tmp"
  sync 2>/dev/null || true
  mv "$tmp" "$pending_file"
  trap - EXIT INT TERM
}

# _remote_load_pending <pending_file> <out_resp_file> -> prints endpoint
# Extracts the embedded raw response bytes back out to its own file,
# byte-for-byte as originally received, so it can be re-run through the
# SAME strict parse-exchange-response.py validator (including its
# duplicate-key detection) a fresh exchange uses (R5/D4) — a pending file
# is not inherently more trustworthy than a live response and must not
# skip validation, and nothing about the original bytes may have been
# lost in between. <pending_file>'s path is passed by PATH, never its
# contents, as a python3 argument.
_remote_load_pending() {
  local pending_file="$1" out_resp_file="$2"
  python3 -c '
import json, sys
pending_path, out_path = sys.argv[1], sys.argv[2]
with open(pending_path) as f:
    pending = json.load(f)
with open(out_path, "w") as f:
    f.write(pending["raw_response_text"])
print(pending["endpoint"])
' "$pending_file" "$out_resp_file"
}

# _remote_commit <team> <cfg> <endpoint> <credential> <credential_id>
#   <server_instance_id> <remote_team_id> <remote_team_name> <protocol_version>
#   <capabilities_json>
# Assumes the caller ALREADY holds this team's config lock. Writes the 0600
# credential file and the (secret-free) binding record.
_remote_commit() {
  local team="$1" cfg="$2" endpoint="$3" credential="$4" credential_id="$5" \
    server_instance_id="$6" remote_team_id="$7" remote_team_name="$8" \
    protocol_version="$9" capabilities_json="${10}" \
    cred_file cred_json connected_at escaped updated

  mkdir -p "$CRED_ROOT"
  chmod 700 "$CRED_ROOT" 2>/dev/null || true
  cred_file="$(_remote_cred_file "$team")"
  # A real JSON serializer (python3 json.dumps), not hand-rolled sed
  # escaping (E3): sed only ever escaped backslash/quote, so a credential
  # containing any OTHER JSON control character (tab, CR, etc. — an
  # opaque bearer string is never validated against a fixed alphabet, per
  # this ADR's own "opaque to core" principle, so nothing rules these
  # out) would have produced invalid JSON — permanently unreadable on the
  # next load, discovered only when the credential was needed. The value
  # is piped in via stdin, never passed as a python3 argv element, so
  # this doesn't reopen R1's credential-in-argv leak.
  local credential_json_str credential_id_json_str
  credential_json_str="$(printf '%s' "$credential" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))')"
  credential_id_json_str="$(printf '%s' "$credential_id" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))')"
  cred_json="{\"credential\":${credential_json_str},\"credential_id\":${credential_id_json_str}}"
  # Atomic write (temp file in the same dir, 0600 before any content is
  # written, best-effort fsync, then rename) — never truncate the real
  # path in place (D3): a crash mid-write, or a re-commit racing another
  # reader, must not leave a half-written/corrupt credential file as the
  # only copy of the secret.
  local cred_tmp
  cred_tmp="$(mktemp "$CRED_ROOT/.cred-XXXXXX")"
  chmod 600 "$cred_tmp"
  # Cleanup trap (nonblocking follow-up noted after E1-E3): a kill signal
  # between mktemp and the rename below would otherwise leave a 0600-but-
  # never-renamed temp copy of the secret sitting in CRED_ROOT indefinitely.
  trap 'rm -f "$cred_tmp"' EXIT INT TERM
  printf '%s\n' "$cred_json" > "$cred_tmp"
  sync 2>/dev/null || true
  mv "$cred_tmp" "$cred_file"
  trap - EXIT INT TERM
  unset cred_json

  connected_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  escaped=$(sed "s/'/''/g" "$cfg")
  updated=$(agmsg_sqlite_mem ".param set :json '$escaped'" ".param set :caps '$(printf '%s' "$capabilities_json" | sed "s/'/''/g")'" \
    "SELECT json_set(:json, '\$.remote_binding', json_object(
       'endpoint', '$(_agmsg_sqlesc "$endpoint")',
       'credential_id', '$(_agmsg_sqlesc "$credential_id")',
       'server_instance_id', '$(_agmsg_sqlesc "$server_instance_id")',
       'remote_team_id', '$(_agmsg_sqlesc "$remote_team_id")',
       'remote_team_name', '$(_agmsg_sqlesc "$remote_team_name")',
       'protocol_version', $protocol_version,
       'capabilities', json(:caps),
       'connected_at', '$(_agmsg_sqlesc "$connected_at")',
       'disconnected_at', null
     ));")
  agmsg_write_atomic "$cfg" "$updated"
}

cmd_connect() {
  local endpoint="" token="" token_stdin=0 team="" force=0 positional=() \
    expected_old_credential_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --endpoint) endpoint="${2:?--endpoint requires a value}"; shift 2 ;;
      --endpoint=*) endpoint="${1#--endpoint=}"; shift ;;
      --token-stdin) token_stdin=1; shift ;;
      --force) force=1; shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  : "${endpoint:?Usage: remote.sh connect --endpoint <url> [<token>] [--token-stdin] [<team>] [--force]}"
  _remote_validate_endpoint "$endpoint" || exit 1
  # Canonicalize once (strip a trailing slash) so every use below — the
  # pending-key hash, the exchange/revoke URLs, and the stored binding —
  # agrees on the same endpoint string; a mismatch here would silently
  # break pending-record resumability (B5) for no user-visible reason.
  endpoint="${endpoint%/}"

  if [ "$token_stdin" -eq 1 ]; then
    if [ "${#positional[@]}" -gt 1 ]; then
      echo "agmsg: too many arguments with --token-stdin (expected only an optional <team>)" >&2
      exit 1
    fi
    # cat (not `read`) so a caller piping the token without a trailing
    # newline doesn't hit EOF-as-failure under `read -r` (which would abort
    # here silently under `set -e` before printing anything) — a real
    # concern since programmatic token handoff commonly omits the newline.
    token="$(cat)"
    team="${positional[0]:-}"
  else
    if [ "${#positional[@]}" -lt 1 ]; then
      echo "agmsg: missing token (positional argument, or use --token-stdin)" >&2
      exit 1
    fi
    token="${positional[0]}"
    team="${positional[1]:-}"
    echo "agmsg: passing the token as an argument may expose it via shell history or 'ps'; prefer --token-stdin" >&2
  fi
  [ -n "$token" ] || { echo "agmsg: empty token" >&2; exit 1; }

  # --force requires an explicit <team> (R4): the revoke-old-credential-
  # first step below only runs when <team> is known upfront. If <team>
  # were left to be discovered from the exchange response, that step
  # would be skipped entirely and --force could silently overwrite an
  # active binding without ever revoking its old credential.
  if [ "$force" -eq 1 ] && [ -z "$team" ]; then
    echo "agmsg: --force requires an explicit <team> — omitting it and letting the exchange response name the team would skip revoking any existing credential for that team first." >&2
    exit 1
  fi

  if [ -n "$team" ]; then
    agmsg_validate_team_name "$team" || exit 1
  fi

  # Resumability key, known before any network call regardless of whether
  # <team> was given (B5).
  local pending_key pending_file
  pending_key="$(_remote_pending_key "$endpoint" "$token")"
  pending_file="$(_remote_pending_file "$pending_key")"

  local credential credential_id server_instance_id remote_team_id remote_team_name \
    protocol_version capabilities_json write_allowed_ciphers current_seq

  if [ -f "$pending_file" ]; then
    echo "agmsg: resuming an exchange that already succeeded but wasn't fully committed locally (avoids consuming a fresh token)." >&2
    unset token

    # A pending file is not inherently more trustworthy than a fresh
    # response (R5) — extract its embedded raw response and run it
    # through the SAME strict validator a live exchange uses, rather than
    # reading fields ad hoc with no shape/type checks.
    local pending_resp_file pending_endpoint parsed_file
    pending_resp_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-pending-resp.XXXXXX")"
    chmod 600 "$pending_resp_file"
    pending_endpoint="$(_remote_load_pending "$pending_file" "$pending_resp_file")"
    if [ -z "$pending_endpoint" ] || [ "$pending_endpoint" != "$endpoint" ]; then
      rm -f "$pending_resp_file"
      echo "agmsg: pending record's endpoint does not match — refusing to resume." >&2
      exit 1
    fi
    parsed_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-connect-parsed.XXXXXX")"
    chmod 600 "$parsed_file"
    if ! python3 "$SCRIPT_DIR/internal/parse-exchange-response.py" < "$pending_resp_file" > "$parsed_file"; then
      rm -f "$pending_resp_file" "$parsed_file"
      echo "agmsg: pending record failed validation — refusing to resume." >&2
      exit 1
    fi
    rm -f "$pending_resp_file"
    {
      IFS= read -r credential
      IFS= read -r credential_id
      IFS= read -r server_instance_id
      IFS= read -r remote_team_id
      IFS= read -r remote_team_name
      IFS= read -r protocol_version
      IFS= read -r capabilities_json
      IFS= read -r write_allowed_ciphers
      IFS= read -r current_seq
    } < "$parsed_file"
    rm -f "$parsed_file"
  else
    # --force pre-check only applies when <team> is known upfront — when
    # omitted, whether "this team" is already connected can't be known
    # until the exchange response names it (checked again post-exchange
    # under the lock either way).
    if [ -n "$team" ]; then
      local existing_disconnected existing_connected_at existing_credential_id
      existing_disconnected="$(_remote_read_config_field "$(_remote_team_config "$team")" '$.remote_binding.disconnected_at')"
      existing_connected_at="$(_remote_read_config_field "$(_remote_team_config "$team")" '$.remote_binding.connected_at')"
      existing_credential_id="$(_remote_read_config_field "$(_remote_team_config "$team")" '$.remote_binding.credential_id')"
      if [ -n "$existing_connected_at" ] && [ "$existing_connected_at" != "null" ] \
        && { [ -z "$existing_disconnected" ] || [ "$existing_disconnected" = "null" ]; }; then
        if [ "$force" -ne 1 ]; then
          echo "agmsg: team '$team' is already connected (since $existing_connected_at) — run 'remote.sh disconnect $team' first, or pass --force to rebind." >&2
          exit 1
        fi
        # --force: revoke the OLD credential before ever asking for a new
        # one. If revoke can't be confirmed, abort rather than leaving the
        # old credential active-but-unreferenced (B5). This intentionally
        # does not yet build a durable orphan/revocation-pending queue for
        # the unreachable case; it fails closed and asks the operator to
        # retry or revoke from the console/admin side.
        local old_endpoint old_credential
        old_endpoint="$(_remote_read_config_field "$(_remote_team_config "$team")" '$.remote_binding.endpoint')"
        old_credential="$(python3 -c "import json,sys; print(json.load(open('$(_remote_cred_file "$team")')).get('credential',''))" 2>/dev/null || true)"
        if [ -z "$existing_credential_id" ] || [ "$existing_credential_id" = "null" ] \
          || [ -z "$old_endpoint" ] || [ "$old_endpoint" = "null" ] || [ -z "$old_credential" ] \
          || ! _remote_revoke "$old_endpoint" "$existing_credential_id" "$old_credential"; then
          echo "agmsg: --force rebind refused — could not confirm the existing credential ($existing_credential_id) was revoked. Revoke it from the console/admin side, or retry once the server is reachable, before rebinding." >&2
          exit 1
        fi
        unset old_credential
        # D2/E1: durably reflect the revoke locally right now, before the
        # new exchange even starts — otherwise a crash between here and
        # the new connection's commit leaves local state claiming to
        # still be connected to a credential the server has already
        # invalidated, with no local signal that anything is wrong. Pass
        # the credential_id we just confirmed revoked as the expected
        # value so this only touches the SAME binding — a concurrent
        # operation's already-newer binding for a different credential
        # must not be clobbered (E1: an earlier version had no such CAS
        # check here at all, and could disconnect/delete a legitimately
        # different concurrent connection's state).
        _remote_local_disconnect "$team" "$(_remote_team_config "$team")" "$existing_credential_id"
        local local_disconnect_status=$?
        if [ "$local_disconnect_status" -eq 2 ]; then
          echo "agmsg: team '$team's binding changed to something else during this operation — aborting rather than risk clobbering a concurrent connection." >&2
          exit 1
        elif [ "$local_disconnect_status" -ne 0 ]; then
          exit 1
        fi
        # D1: remember exactly which credential we confirmed revoked, so
        # the post-exchange CAS check (below) only proceeds if nothing
        # else has touched this team's binding since — --force authorizes
        # overriding *this specific* old credential, not "whatever is
        # there by the time the exchange finishes."
        expected_old_credential_id="$existing_credential_id"
      fi
    fi

    # The only network call that can fail before any local state changes.
    local body_file resp_file http_code token_json
    body_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-connect-body.XXXXXX")"
    chmod 600 "$body_file"
    resp_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-connect-resp.XXXXXX")"
    chmod 600 "$resp_file"
    trap 'rm -f "$body_file" "$resp_file"' EXIT INT TERM

    token_json="$(printf '%s' "$token" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)"
    unset token
    if [ -z "$token_json" ]; then
      echo "agmsg: internal error encoding token" >&2
      exit 1
    fi
    printf '{"token":%s}' "$token_json" > "$body_file"
    unset token_json

    http_code="$(_remote_http_post_json "$endpoint/v1/pairing/exchange" "$body_file" "$resp_file")"
    rm -f "$body_file"

    if [ "$http_code" != "200" ]; then
      echo "agmsg: connect failed — exchange endpoint returned HTTP $http_code" >&2
      rm -f "$resp_file"
      exit 1
    fi

    # Strict validation (B6) BEFORE any field is used — a malformed/
    # malicious response must not reach state mutation, and credential_id
    # in particular must be shape-checked before it's ever spliced into a
    # revoke URL. Parsed fields go to a FILE, not a command substitution —
    # bash's `$(...)` silently strips embedded NUL bytes from its captured
    # output, which would have destroyed NUL-delimited field boundaries
    # before `read` ever saw them (caught in testing). Newline-delimited
    # and file-based avoids that entirely.
    local parsed_file
    parsed_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-connect-parsed.XXXXXX")"
    chmod 600 "$parsed_file"
    if ! python3 "$SCRIPT_DIR/internal/parse-exchange-response.py" < "$resp_file" > "$parsed_file"; then
      rm -f "$resp_file" "$parsed_file"
      exit 1
    fi
    {
      IFS= read -r credential
      IFS= read -r credential_id
      IFS= read -r server_instance_id
      IFS= read -r remote_team_id
      IFS= read -r remote_team_name
      IFS= read -r protocol_version
      IFS= read -r capabilities_json
      IFS= read -r write_allowed_ciphers
      IFS= read -r current_seq
    } < "$parsed_file"
    rm -f "$parsed_file"

    # Durable pending record before the local commit (B5): if the process
    # dies between here and _remote_commit finishing, retrying with the
    # same (endpoint, token) resumes from this file instead of needing a
    # fresh token. Takes resp_file by PATH — the raw bytes (including the
    # secret) are read inside python3 via file I/O, never passed as any
    # process's own argv element (R1).
    _remote_write_pending "$pending_key" "$resp_file" "$endpoint"
    rm -f "$resp_file"
    trap - EXIT INT TERM
  fi

  [ -n "$team" ] || team="$remote_team_name"
  if [ -z "$team" ]; then
    echo "agmsg: could not determine a local team name (exchange response had no remote_team_name and none was given)" >&2
    exit 1
  fi
  agmsg_validate_team_name "$team" || exit 1
  _remote_ensure_team "$team"
  local cfg
  cfg="$(_remote_team_config "$team")"

  agmsg_lock_acquire "$TEAMS_DIR/$team" || exit 1
  # Re-check under the lock (CAS). Three cases are safe to commit into;
  # everything else fails closed, INCLUDING under --force (D1: force
  # authorizes overriding the *specific* old credential this operation
  # already confirmed revoked pre-exchange — it is not a blanket bypass
  # of this check, or a third party's differing credential could get
  # silently clobbered and permanently orphaned server-side):
  #   1. Not currently connected (fresh connect, or --force's pre-check
  #      already revoked-and-locally-disconnected the prior credential —
  #      D2 — so nothing conflicting remains to protect).
  #   2. Already connected, but to EXACTLY this same operation's own
  #      prior (partial) commit (credential_id/server_instance_id/
  #      remote_team_id all match) — the resume-after-commit-but-before-
  #      pending-cleanup crash case (R3). Re-commits (self-healing —
  #      D3 — rather than trusting the binding metadata alone and just
  #      deleting pending: if the credential FILE write never finished,
  #      re-running commit repairs it, since committing identical data
  #      twice is always safe).
  #   3. Already connected to a DIFFERENT credential, but --force is set
  #      AND that credential is exactly the one we revoked pre-exchange
  #      (nothing else touched this team's binding in between).
  local recheck_connected recheck_disconnected recheck_credential_id \
    recheck_server_instance_id recheck_remote_team_id
  recheck_connected="$(_remote_read_config_field "$cfg" '$.remote_binding.connected_at')"
  recheck_disconnected="$(_remote_read_config_field "$cfg" '$.remote_binding.disconnected_at')"
  recheck_credential_id="$(_remote_read_config_field "$cfg" '$.remote_binding.credential_id')"
  recheck_server_instance_id="$(_remote_read_config_field "$cfg" '$.remote_binding.server_instance_id')"
  recheck_remote_team_id="$(_remote_read_config_field "$cfg" '$.remote_binding.remote_team_id')"
  local already_connected=0
  if [ -n "$recheck_connected" ] && [ "$recheck_connected" != "null" ] \
    && { [ -z "$recheck_disconnected" ] || [ "$recheck_disconnected" = "null" ]; }; then
    already_connected=1
  fi

  local safe_to_commit=0
  if [ "$already_connected" -eq 0 ]; then
    safe_to_commit=1
  elif [ "$recheck_credential_id" = "$credential_id" ] \
    && [ "$recheck_server_instance_id" = "$server_instance_id" ] \
    && [ "$recheck_remote_team_id" = "$remote_team_id" ]; then
    safe_to_commit=1
  elif [ "$force" -eq 1 ] && [ -n "$expected_old_credential_id" ] \
    && [ "$recheck_credential_id" = "$expected_old_credential_id" ]; then
    safe_to_commit=1
  fi

  if [ "$safe_to_commit" -eq 1 ]; then
    _remote_commit "$team" "$cfg" "$endpoint" "$credential" "$credential_id" \
      "$server_instance_id" "$remote_team_id" "$remote_team_name" "$protocol_version" "$capabilities_json"
    rm -f "$pending_file"
    agmsg_lock_release
  else
    agmsg_lock_release
    echo "agmsg: team '$team' has a different, unexpected binding than expected — the credential just issued for it was NOT committed locally. Revoke it (credential_id=$credential_id) via the console/admin side if it should not remain active, then retry." >&2
    exit 1
  fi
  unset credential

  # E2EE insertion point (ADR 0007 §6/§8): only when the capability response
  # actually requires encryption and no local key exists yet for this team.
  local needs_encryption=0
  case ",$write_allowed_ciphers," in
    *,none,*) needs_encryption=0 ;;
    *) [ -n "$write_allowed_ciphers" ] && needs_encryption=1 ;;
  esac

  if [ "$needs_encryption" -eq 1 ]; then
    local existing_key
    existing_key="$(_remote_read_config_field "$cfg" '$.remote_key.current.key_id')"
    if [ -z "$existing_key" ] || [ "$existing_key" = "null" ]; then
      if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
        echo "'age' is required for this team's end-to-end encryption and was not found on this device. Install it, then re-run 'remote.sh connect ...':" >&2
        echo "  macOS (Homebrew):      brew install age" >&2
        echo "  Debian/Ubuntu:         sudo apt install age" >&2
        echo "  Windows (winget):      winget install FiloSottile.age" >&2
        echo "See https://github.com/FiloSottile/age for other install methods." >&2
        exit 1
      fi

      # STATUS: current_seq==0 only ever SUGGESTS the generate option — it
      # is never chosen as an automatic default. An adversarial review
      # found that local-only signals (message counts, and even an honest
      # server's current_seq==0) cannot prove "I am the first writer": two
      # devices can both see an empty/unseeded stream at once and both
      # auto-generate, producing two incompatible keys with no way to tell
      # which is authoritative (split-brain) — and a malicious/equivocating
      # server can trivially induce the same outcome on purpose. Until a
      # trusted, transactional first-writer claim exists, the only safe
      # defaults are import or abort; generate requires an explicit,
      # deliberate 'g' and is never selected on empty/EOF input.
      local seq_hint=""
      if [ "$current_seq" = "0" ]; then
        seq_hint=" (this team's stream looks empty — (g) may be safe, but only you can be sure no one else is the first writer)"
      fi

      echo "This team requires end-to-end encryption. No key found for this device.${seq_hint}"
      echo "  (g) Generate a new key — ONLY if you are certain you are the first person connecting this team"
      echo "  (i) Import a key you already have — do this if a teammate gave you one, or if unsure"
      echo "  (a) Abort — don't connect yet"
      local choice
      read -r -p "[i/g/a] (default: a): " choice || choice=""
      choice="${choice:-a}"

      case "$choice" in
        g)
          bash "$SCRIPT_DIR/key.sh" generate "$team" || exit 1
          ;;
        i)
          echo "On another machine that already has this team's key, run:"
          echo "  key.sh show $team --reveal-secret"
          echo "and paste its output below."
          local identity
          read -r -p "Paste identity: " identity || identity=""
          if [ -z "$identity" ]; then
            echo "agmsg: no identity provided — if the only device that ever held this team's key is gone entirely, there is nothing to import. The historical stream stays permanently unreadable under the lost key, and rotation to start a fresh epoch is not available in this release." >&2
            exit 1
          fi
          printf '%s' "$identity" | bash "$SCRIPT_DIR/key.sh" import "$team" --identity-stdin || exit 1
          unset identity
          ;;
        a|*)
          echo "Aborted. No driver switch performed; the binding record is present but the team is not fully connected until a key exists — see 'remote status $team'." >&2
          exit 1
          ;;
      esac
    fi
  fi

  echo "Connected: team '$team'${remote_team_name:+ (org '$remote_team_name')}."
}

# --- status --------------------------------------------------------------

_remote_status_one() {
  local team="$1" cfg connected_at disconnected_at write_allowed_ciphers key_id
  cfg="$(_remote_team_config "$team")"
  connected_at="$(_remote_read_config_field "$cfg" '$.remote_binding.connected_at')"
  disconnected_at="$(_remote_read_config_field "$cfg" '$.remote_binding.disconnected_at')"
  if [ -z "$connected_at" ] || [ "$connected_at" = "null" ]; then
    return 1
  fi
  if [ -n "$disconnected_at" ] && [ "$disconnected_at" != "null" ]; then
    echo "$team	disconnected (was connected until $disconnected_at)"
    return 0
  fi

  write_allowed_ciphers="$(_remote_read_config_field "$cfg" '$.remote_binding.capabilities.write_allowed_ciphers')"
  key_id="$(_remote_read_config_field "$cfg" '$.remote_key.current.key_id')"

  local needs_encryption=0
  case "$write_allowed_ciphers" in
    *none*) needs_encryption=0 ;;
    '['*']') [ "$write_allowed_ciphers" != "[]" ] && needs_encryption=1 ;;
  esac

  echo "$team	connected (since $connected_at)"
  if [ "$needs_encryption" -eq 1 ]; then
    if [ -z "$key_id" ] || [ "$key_id" = "null" ]; then
      echo "		encryption: required, no local key — run 'key.sh generate $team' or 'key.sh import $team'"
    else
      echo "		encryption: age-v1, key present"
    fi
  else
    echo "		encryption: none"
  fi
}

cmd_status() {
  local team="${1:-}"
  if [ -n "$team" ]; then
    agmsg_validate_team_name "$team" || exit 1
    _remote_status_one "$team" || { echo "agmsg: team '$team' has never been connected" >&2; exit 1; }
    return
  fi

  local any=0 t
  [ -d "$TEAMS_DIR" ] || { echo "No teams found."; return; }
  for t in "$TEAMS_DIR"/*/; do
    [ -d "$t" ] || continue
    t="$(basename "$t")"
    if _remote_status_one "$t"; then
      any=1
    fi
  done
  [ "$any" -eq 1 ] || echo "No teams are connected."
}

# --- disconnect ------------------------------------------------------------

cmd_disconnect() {
  local team="${1:?Usage: remote.sh disconnect <team>}"
  agmsg_validate_team_name "$team" || exit 1
  local cfg
  cfg="$(_remote_team_config "$team")"
  local connected_at
  connected_at="$(_remote_read_config_field "$cfg" '$.remote_binding.connected_at')"
  if [ -z "$connected_at" ] || [ "$connected_at" = "null" ]; then
    echo "agmsg: team '$team' is not connected" >&2
    exit 1
  fi

  local cred_file endpoint credential_id credential
  cred_file="$(_remote_cred_file "$team")"
  endpoint="$(_remote_read_config_field "$cfg" '$.remote_binding.endpoint')"
  credential_id="$(_remote_read_config_field "$cfg" '$.remote_binding.credential_id')"

  # Server-side revoke first, local cleanup always — local deletion alone
  # does not stop the credential from continuing to authenticate
  # server-side (ADR 0007 §4).
  local revoke_ok=0
  if [ -f "$cred_file" ] && [ -n "$endpoint" ] && [ "$endpoint" != "null" ] && [ -n "$credential_id" ] && [ "$credential_id" != "null" ]; then
    credential="$(python3 -c "import json,sys; print(json.load(open('$cred_file')).get('credential',''))" 2>/dev/null)"
    if [ -n "$credential" ] && _remote_revoke "$endpoint" "$credential_id" "$credential"; then
      revoke_ok=1
    fi
    unset credential
  fi

  # Pass the credential_id we just (attempted to) revoke as the expected
  # value (E1) — if the binding changed to something else in the window
  # since we read it above (a concurrent reconnect), disconnecting THAT
  # would silently tear down a connection this call never touched. Only
  # pass it when it's a real value — "null"/empty means this binding
  # never had one, so there's nothing meaningful to CAS against.
  local expected_credential_id_for_disconnect=""
  if [ -n "$credential_id" ] && [ "$credential_id" != "null" ]; then
    expected_credential_id_for_disconnect="$credential_id"
  fi
  _remote_local_disconnect "$team" "$cfg" "$expected_credential_id_for_disconnect"
  local local_disconnect_status=$?
  if [ "$local_disconnect_status" -eq 2 ]; then
    echo "agmsg: team '$team's binding changed to something else during disconnect — aborting rather than risk clobbering a concurrent connection. Retry if you still want to disconnect the CURRENT binding." >&2
    exit 1
  elif [ "$local_disconnect_status" -ne 0 ]; then
    exit 1
  fi

  if [ "$revoke_ok" -eq 1 ]; then
    echo "Revoking credential with server... ok."
  else
    echo "Revoking credential with server... failed."
    echo "Local state cleared, but the server could not be reached to revoke this credential — if this device may be compromised, revoke it from the console/admin side directly." >&2
  fi
  echo "Disconnected '$team'. Local sync state cleared; sends/reads continue locally."
}

case "${1:-}" in
  connect) shift; cmd_connect "$@" ;;
  status) shift; cmd_status "$@" ;;
  disconnect) shift; cmd_disconnect "$@" ;;
  doctor) shift; cmd_doctor "$@" ;;
  *)
    echo "Usage: remote.sh <connect|status|disconnect|doctor> ..." >&2
    exit 1 ;;
esac
