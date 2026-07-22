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
# establishes the sync binding, not a agent identity in the team).
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

# --- connect -------------------------------------------------------------

_remote_write_binding() {
  # _remote_write_binding <team> <cfg> <endpoint> <credential_id> <server_instance_id>
  #   <remote_team_id> <remote_team_name> <protocol_version> <capabilities_json>
  local team="$1" cfg="$2" endpoint="$3" credential_id="$4" server_instance_id="$5" \
    remote_team_id="$6" remote_team_name="$7" protocol_version="$8" capabilities_json="$9" \
    connected_at escaped updated
  connected_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 1
  escaped=$(sed "s/'/''/g" "$cfg")
  updated=$(agmsg_sqlite_mem ".param set :json '$escaped'" ".param set :caps '$(printf '%s' "$capabilities_json" | sed "s/'/''/g")'" \
    "SELECT json_set(:json, '\$.remote_binding', json_object(
       'endpoint', '$(_agmsg_sqlesc "$endpoint")',
       'credential_id', '$(_agmsg_sqlesc "$credential_id")',
       'server_instance_id', '$(_agmsg_sqlesc "$server_instance_id")',
       'remote_team_id', '$(_agmsg_sqlesc "$remote_team_id")',
       'remote_team_name', '$(_agmsg_sqlesc "$remote_team_name")',
       'protocol_version', '$(_agmsg_sqlesc "$protocol_version")',
       'capabilities', json(:caps),
       'connected_at', '$(_agmsg_sqlesc "$connected_at")',
       'disconnected_at', null
     ));")
  agmsg_write_atomic "$cfg" "$updated"
  agmsg_lock_release
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
    local existing_disconnected
    existing_disconnected="$(_remote_read_config_field "$(_remote_team_config "$team")" '$.remote_binding.disconnected_at')"
    local existing_connected_at
    existing_connected_at="$(_remote_read_config_field "$(_remote_team_config "$team")" '$.remote_binding.connected_at')"
    if [ -n "$existing_connected_at" ] && [ "$existing_connected_at" != "null" ] \
      && { [ -z "$existing_disconnected" ] || [ "$existing_disconnected" = "null" ]; } \
      && [ "$force" -ne 1 ]; then
      echo "agmsg: team '$team' is already connected (since $existing_connected_at) — run 'remote.sh disconnect $team' first, or pass --force to rebind." >&2
      exit 1
    fi
  fi

  # The only network call that can fail before any local state changes.
  local resp_body http_code tmp_body token_escaped
  tmp_body="$(mktemp "${TMPDIR:-/tmp}/agmsg-connect-resp.XXXXXX")"
  token_escaped="$(printf '%s' "$token" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)"
  unset token
  if [ -z "$token_escaped" ]; then
    rm -f "$tmp_body"
    echo "agmsg: internal error encoding token" >&2
    exit 1
  fi
  http_code=$(curl -sS -o "$tmp_body" -w '%{http_code}' \
    -X POST "${endpoint%/}/v1/pairing/exchange" \
    -H 'Content-Type: application/json' \
    -d "{\"token\":$token_escaped}" \
    2>/dev/null) || http_code="000"
  unset token_escaped

  if [ "$http_code" != "200" ]; then
    echo "agmsg: connect failed — exchange endpoint returned HTTP $http_code" >&2
    rm -f "$tmp_body"
    exit 1
  fi

  resp_body="$(cat "$tmp_body")"
  rm -f "$tmp_body"

  local credential credential_id server_instance_id remote_team_id remote_team_name protocol_version capabilities_json write_allowed_ciphers
  credential="$(printf '%s' "$resp_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('credential',''))" 2>/dev/null)"
  credential_id="$(printf '%s' "$resp_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('credential_id',''))" 2>/dev/null)"
  server_instance_id="$(printf '%s' "$resp_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('server_instance_id',''))" 2>/dev/null)"
  remote_team_id="$(printf '%s' "$resp_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('remote_team_id',''))" 2>/dev/null)"
  remote_team_name="$(printf '%s' "$resp_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('remote_team_name',''))" 2>/dev/null)"
  protocol_version="$(printf '%s' "$resp_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('protocol_version',''))" 2>/dev/null)"
  capabilities_json="$(printf '%s' "$resp_body" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('capabilities',{})))" 2>/dev/null)"
  write_allowed_ciphers="$(printf '%s' "$resp_body" | python3 -c "import json,sys; print(','.join(json.load(sys.stdin).get('capabilities',{}).get('write_allowed_ciphers',[])))" 2>/dev/null)"
  unset resp_body

  if [ -z "$credential" ] || [ -z "$credential_id" ]; then
    echo "agmsg: connect failed — exchange response missing credential/credential_id" >&2
    exit 1
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

  # The secret never touches config.json or any other read/diffed/logged
  # file — a dedicated, 0600, engine-side credential file (ADR 0007 §3.4).
  mkdir -p "$CRED_ROOT"
  chmod 700 "$CRED_ROOT" 2>/dev/null || true
  local cred_file cred_json
  cred_file="$(_remote_cred_file "$team")"
  cred_json="$(printf '{"credential":"%s","credential_id":"%s"}' \
    "$(printf '%s' "$credential" | sed 's/"/\\"/g')" \
    "$(printf '%s' "$credential_id" | sed 's/"/\\"/g')")"
  unset credential
  ( umask 077; printf '%s\n' "$cred_json" > "$cred_file" )
  unset cred_json

  _remote_write_binding "$team" "$cfg" "$endpoint" "$credential_id" "$server_instance_id" \
    "$remote_team_id" "$remote_team_name" "$protocol_version" "$capabilities_json" || exit 1

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

      local db msg_count default_choice
      db="$(agmsg_db_path)"
      msg_count=0
      if [ -f "$db" ]; then
        msg_count="$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM messages WHERE team='$(_agmsg_sqlesc "$team")';" 2>/dev/null || echo 0)"
      fi
      if [ "$msg_count" -eq 0 ] 2>/dev/null; then
        default_choice="g"
      else
        default_choice="i"
      fi

      echo "This team requires end-to-end encryption. No key found for this device."
      echo "  (g) Generate a new key — do this if you are the first person connecting this team"
      echo "  (i) Import a key you already have — do this if a teammate gave you one, or if this team already has message history"
      echo "  (a) Abort — don't connect yet"
      local choice
      read -r -p "[g/i/a] (default: $default_choice): " choice || choice=""
      choice="${choice:-$default_choice}"

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
            echo "agmsg: no identity provided — if the only device that ever held this team's key is gone entirely, there is nothing to import. The historical stream stays permanently unreadable under the lost key. The only forward path is 'key.sh rotate $team' to start a fresh epoch for messages sent from now on." >&2
            exit 1
          fi
          bash "$SCRIPT_DIR/key.sh" import "$team" "$identity" || exit 1
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
      echo "		encryption: required, no local key — run 'key.sh generate $team' or 'key.sh import $team <identity>'"
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
    if [ -n "$credential" ]; then
      local http_code
      http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
        -X POST "${endpoint%/}/v1/credentials/$credential_id/revoke" \
        -H "Authorization: Bearer $credential" \
        2>/dev/null) || http_code="000"
      unset credential
      [ "$http_code" = "200" ] && revoke_ok=1
    fi
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
