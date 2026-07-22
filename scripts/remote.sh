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
# cert (ADR 0007 review finding B6).
_remote_validate_endpoint() {
  local endpoint="$1"
  case "$endpoint" in
    https://*) return 0 ;;
    http://127.0.0.1*|http://localhost*|http://\[::1\]*) return 0 ;;
    http://*)
      echo "agmsg: --endpoint must be https:// (plaintext http:// would send the token/credential unencrypted) — loopback (127.0.0.1/localhost) is the only exception" >&2
      return 1 ;;
    *)
      echo "agmsg: --endpoint must start with https://" >&2
      return 1 ;;
  esac
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
  {
    printf 'url = "%s"\n' "$url"
    printf 'request = "POST"\n'
    printf 'header = "Content-Type: application/json"\n'
    printf 'data = "@%s"\n' "$body_file"
  } > "$cfg"
  http_code=$(curl -sS -o "$out_file" -w '%{http_code}' -K "$cfg" 2>/dev/null) || http_code="000"
  rm -f "$cfg"
  printf '%s' "$http_code"
}

# _remote_http_post_bearer <url> <bearer_token> -> prints http_code
# Same argv-safety property for the Authorization header (revoke calls).
_remote_http_post_bearer() {
  local url="$1" token="$2" cfg http_code
  cfg="$(mktemp "${TMPDIR:-/tmp}/agmsg-curl-cfg.XXXXXX")"
  chmod 600 "$cfg"
  {
    printf 'url = "%s"\n' "$url"
    printf 'request = "POST"\n'
    printf 'header = "Authorization: Bearer %s"\n' "$token"
  } > "$cfg"
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' -K "$cfg" 2>/dev/null) || http_code="000"
  rm -f "$cfg"
  printf '%s' "$http_code"
}

# _remote_revoke <endpoint> <credential_id> <credential> -> 0 revoked, 1 not
_remote_revoke() {
  local endpoint="$1" credential_id="$2" credential="$3" http_code
  http_code="$(_remote_http_post_bearer "$endpoint/v1/credentials/$credential_id/revoke" "$credential")"
  [ "$http_code" = "200" ]
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

# _remote_write_pending <key> <credential> <credential_id> <server_instance_id>
#   <remote_team_id> <remote_team_name> <protocol_version> <capabilities_json> <endpoint>
# Durable, atomic (temp+rename), 0600 record of a successful exchange whose
# local commit has not (yet) fully completed — deliberately does NOT
# include the token. A crash between the exchange and _remote_commit
# finishing resumes from here on a retry with the same (endpoint, token),
# instead of needing (and orphaning a credential for) a fresh single-use
# token (B5).
_remote_write_pending() {
  local key="$1" credential="$2" credential_id="$3" server_instance_id="$4" \
    remote_team_id="$5" remote_team_name="$6" protocol_version="$7" \
    capabilities_json="$8" endpoint="$9" pending_file tmp json
  mkdir -p "$PENDING_DIR"
  chmod 700 "$PENDING_DIR" 2>/dev/null || true
  pending_file="$(_remote_pending_file "$key")"
  json=$(python3 -c '
import json, sys
credential, credential_id, server_instance_id, remote_team_id, remote_team_name, protocol_version, capabilities_json, endpoint = sys.argv[1:9]
print(json.dumps({
    "credential": credential,
    "credential_id": credential_id,
    "server_instance_id": server_instance_id,
    "remote_team_id": remote_team_id,
    "remote_team_name": remote_team_name,
    "protocol_version": int(protocol_version),
    "capabilities": json.loads(capabilities_json),
    "endpoint": endpoint,
}))
' "$credential" "$credential_id" "$server_instance_id" "$remote_team_id" "$remote_team_name" "$protocol_version" "$capabilities_json" "$endpoint")
  tmp="$(mktemp "$PENDING_DIR/.pending-XXXXXX")"
  chmod 600 "$tmp"
  printf '%s\n' "$json" > "$tmp"
  sync 2>/dev/null || true
  mv "$tmp" "$pending_file"
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
  cred_json="$(printf '{"credential":"%s","credential_id":"%s"}' \
    "$(printf '%s' "$credential" | sed 's/"/\\"/g')" \
    "$(printf '%s' "$credential_id" | sed 's/"/\\"/g')")"
  ( umask 077; printf '%s\n' "$cred_json" > "$cred_file" )
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
  local endpoint="" token="" token_stdin=0 team="" force=0 positional=()
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
    credential="$(python3 -c "import json,sys; print(json.load(open('$pending_file')).get('credential',''))" 2>/dev/null)"
    credential_id="$(python3 -c "import json,sys; print(json.load(open('$pending_file')).get('credential_id',''))" 2>/dev/null)"
    server_instance_id="$(python3 -c "import json,sys; print(json.load(open('$pending_file')).get('server_instance_id',''))" 2>/dev/null)"
    remote_team_id="$(python3 -c "import json,sys; print(json.load(open('$pending_file')).get('remote_team_id',''))" 2>/dev/null)"
    remote_team_name="$(python3 -c "import json,sys; print(json.load(open('$pending_file')).get('remote_team_name',''))" 2>/dev/null)"
    protocol_version="$(python3 -c "import json,sys; print(json.load(open('$pending_file')).get('protocol_version',0))" 2>/dev/null)"
    capabilities_json="$(python3 -c "import json,sys; print(json.dumps(json.load(open('$pending_file')).get('capabilities',{})))" 2>/dev/null)"
    write_allowed_ciphers="$(python3 -c "import json,sys; print(','.join(json.load(open('$pending_file')).get('capabilities',{}).get('write_allowed_ciphers',[])))" 2>/dev/null)"
    current_seq="$(python3 -c "import json,sys; v=json.load(open('$pending_file')).get('capabilities',{}).get('current_seq'); print(v if v is not None else -1)" 2>/dev/null)"
    unset token
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
    rm -f "$resp_file"
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
    trap - EXIT INT TERM

    # Durable pending record before the local commit (B5): if the process
    # dies between here and _remote_commit finishing, retrying with the
    # same (endpoint, token) resumes from this file instead of needing a
    # fresh token.
    _remote_write_pending "$pending_key" "$credential" "$credential_id" "$server_instance_id" \
      "$remote_team_id" "$remote_team_name" "$protocol_version" "$capabilities_json" "$endpoint"
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
  # Re-check under the lock (CAS): if something else connected this team
  # in the window since our pre-flight check (or since the exchange, for
  # the omitted-team case where no pre-check was possible), fail closed
  # rather than mixing old/new bindings (B5) — the pending record survives
  # this abort so a deliberate retry can still resume it.
  local recheck_connected recheck_disconnected
  recheck_connected="$(_remote_read_config_field "$cfg" '$.remote_binding.connected_at')"
  recheck_disconnected="$(_remote_read_config_field "$cfg" '$.remote_binding.disconnected_at')"
  if [ -n "$recheck_connected" ] && [ "$recheck_connected" != "null" ] \
    && { [ -z "$recheck_disconnected" ] || [ "$recheck_disconnected" = "null" ]; } \
    && [ "$force" -ne 1 ]; then
    agmsg_lock_release
    echo "agmsg: team '$team' became connected by another process just now — the credential just issued for it was NOT committed locally. Revoke it (credential_id=$credential_id) via the console/admin side if it should not remain active, then retry." >&2
    exit 1
  fi
  _remote_commit "$team" "$cfg" "$endpoint" "$credential" "$credential_id" \
    "$server_instance_id" "$remote_team_id" "$remote_team_name" "$protocol_version" "$capabilities_json"
  rm -f "$pending_file"
  agmsg_lock_release
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

  rm -f "$cred_file"

  agmsg_lock_acquire "$TEAMS_DIR/$team" || exit 1
  local escaped updated disconnected_at
  disconnected_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  escaped=$(sed "s/'/''/g" "$cfg")
  updated=$(agmsg_sqlite_mem ".param set :json '$escaped'" \
    "SELECT json_set(:json, '\$.remote_binding.disconnected_at', '$(_agmsg_sqlesc "$disconnected_at")');")
  agmsg_write_atomic "$cfg" "$updated"
  agmsg_lock_release

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
