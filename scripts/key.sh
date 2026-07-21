#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   key.sh generate [<team>]
#   key.sh show [<team>] [--reveal-secret]
#   key.sh import <team> <identity>
#   key.sh rotate [<team>]
#
# Team-scoped end-to-end encryption key management (age-v1 profile,
# docs/spec/age-v1-profile.md). Scope: single-writer-per-team onboarding and
# rotation only (ADR 0007 §8) — NOT the multi-writer cutover protocol
# (adding/removing a device from a team that already has other active
# writers needs its own quiesce/fence/commit design, not this script).

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

# Escape interpolated identifiers as SQL string literals (parity with
# rename.sh/send.sh): a value with a single quote would break the query.
_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }

_key_team_config() {
  printf '%s' "$TEAMS_DIR/$1/config.json"
}

_key_cred_dir() {
  printf '%s' "$CRED_ROOT/$1/keys"
}

# Refuse to proceed without a working age/age-keygen — this is the same
# preflight `remote.sh connect` runs before its own key-bootstrap prompt
# (ADR 0007 §8), duplicated here since key.sh can also be invoked directly
# (e.g. `key.sh import` ahead of ever running `connect`).
_key_require_age() {
  if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
    echo "agmsg: 'age' is required for end-to-end encryption and was not found on this device." >&2
    echo "Install it, then retry:" >&2
    echo "  macOS (Homebrew):      brew install age" >&2
    echo "  Debian/Ubuntu:         sudo apt install age" >&2
    echo "  Windows (winget):      winget install FiloSottile.age" >&2
    echo "See https://github.com/FiloSottile/age for other install methods." >&2
    return 1
  fi
}

# _key_read_config_field <config_json_path> <json_path> — "null" (string) if
# the file or the field doesn't exist, matching json_extract's own convention.
_key_read_config_field() {
  local cfg="$1" path="$2" escaped
  [ -f "$cfg" ] || { echo "null"; return; }
  escaped=$(sed "s/'/''/g" "$cfg")
  agmsg_sqlite_mem ".param set :json '$escaped'" "SELECT json_extract(:json, '$path');"
}

# Short, human-comparable digest of a recipient string (SSH-key-fingerprint
# style grouping) — for the H7 "fingerprint verification" step (ADR 0007 §8):
# two people compare this same short string over a separate channel.
_key_fingerprint() {
  printf '%s' "$1" | shasum -a 256 | cut -c1-16 | sed 's/\(....\)/\1-/g;s/-$//'
}

# A timestamp alone collides when generate/rotate run twice within the same
# second (age-keygen refuses to overwrite an existing identity file, which
# would otherwise fail *silently* under our error handling) — append a short
# random suffix so the key_id (and its identity filename) is always unique.
# Still matches the age-v1 profile's required key_id shape
# ([a-z0-9][a-z0-9._-]{0,63}).
_key_new_key_id() {
  printf 'epoch-%s-%04x' "$(date -u +%Y%m%d%H%M%S)" "$((RANDOM % 65536))"
}

_key_epoch_json() {
  # _key_epoch_json <key_id> <epoch_revision> <writer_generation> <recipient> <previous_snapshot_sha256|null> <created_at>
  local prev_sql="null"
  if [ "$5" != "null" ]; then
    prev_sql="'$(_agmsg_sqlesc "$5")'"
  fi
  printf "json_object('key_id', '%s', 'epoch_revision', %s, 'writer_generation', %s, 'recipient', '%s', 'previous_snapshot_sha256', %s, 'created_at', '%s')" \
    "$(_agmsg_sqlesc "$1")" "$2" "$3" "$(_agmsg_sqlesc "$4")" "$prev_sql" "$(_agmsg_sqlesc "$6")"
}

# _key_write_epoch <team> <config_json_path> <epoch_json_expr> [existing_epochs_array_or_empty]
# Writes remote_key.current = the new epoch and appends it to remote_key.epochs,
# under the per-team config lock.
_key_write_epoch() {
  local team="$1" cfg="$2" epoch_expr="$3" escaped updated
  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 1
  escaped=$(sed "s/'/''/g" "$cfg")
  updated=$(agmsg_sqlite_mem ".param set :json '$escaped'" \
    "SELECT json_set(:json,
       '\$.remote_key.current', $epoch_expr,
       '\$.remote_key.epochs',
         json_insert(
           CASE WHEN json_type(json_extract(:json, '\$.remote_key.epochs')) = 'array'
                THEN json_extract(:json, '\$.remote_key.epochs') ELSE json('[]') END,
           '\$[#]', $epoch_expr
         )
     );")
  agmsg_write_atomic "$cfg" "$updated"
  agmsg_lock_release
}

cmd_generate() {
  local team="${1:?Usage: key.sh generate [<team>]}"
  agmsg_validate_team_name "$team" || exit 1
  _key_require_age || exit 1

  local cfg
  cfg="$(_key_team_config "$team")"
  if [ ! -f "$cfg" ]; then
    echo "agmsg: team not found: $team" >&2
    exit 1
  fi

  local existing
  existing="$(_key_read_config_field "$cfg" '$.remote_key.current.key_id')"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    echo "agmsg: team '$team' already has a key (key_id=$existing) — use 'key.sh rotate $team' to start a new epoch, or 'key.sh show $team' to view the current one." >&2
    exit 1
  fi

  local cred_dir key_id created_at identity_file recipient
  cred_dir="$(_key_cred_dir "$team")"
  mkdir -p "$cred_dir"
  chmod 700 "$cred_dir" 2>/dev/null || true
  key_id="$(_key_new_key_id)"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  identity_file="$cred_dir/$key_id.key"

  local keygen_err
  keygen_err="$(mktemp "${TMPDIR:-/tmp}/agmsg-keygen-err.XXXXXX")"
  if ! age-keygen -o "$identity_file" 2>"$keygen_err"; then
    echo "agmsg: age-keygen failed: $(cat "$keygen_err" 2>/dev/null)" >&2
    rm -f "$keygen_err"
    exit 1
  fi
  rm -f "$keygen_err"
  chmod 600 "$identity_file"
  recipient="$(grep '^# public key:' "$identity_file" | sed 's/^# public key: //')"

  _key_write_epoch "$team" "$cfg" "$(_key_epoch_json "$key_id" 0 0 "$recipient" null "$created_at")" || exit 1

  echo "Generated a new key for team '$team'."
  echo "Recipient fingerprint: $(_key_fingerprint "$recipient")"
  echo
  echo "Back this up now. agmsg does not store a copy of this key anywhere —"
  echo "if this device is lost, every message encrypted under this key"
  echo "becomes permanently unreadable. There is no server-side recovery."
  echo "Run 'key.sh show $team --reveal-secret' to view and save it somewhere"
  echo "safe — a password manager entry, not a plaintext file. Do NOT copy"
  echo "it into a dotfiles repo, a git repo of any kind, or any other"
  echo "synced/backed-up-by-a-tool location you wouldn't also trust with a"
  echo "production credential. Removing a device later does not revoke its"
  echo "ability to read history encrypted before removal."
}

cmd_show() {
  local team="" reveal=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reveal-secret) reveal=1 ;;
      *) team="$1" ;;
    esac
    shift
  done
  : "${team:?Usage: key.sh show [<team>] [--reveal-secret]}"
  agmsg_validate_team_name "$team" || exit 1

  local cfg key_id recipient
  cfg="$(_key_team_config "$team")"
  key_id="$(_key_read_config_field "$cfg" '$.remote_key.current.key_id')"
  recipient="$(_key_read_config_field "$cfg" '$.remote_key.current.recipient')"
  if [ -z "$key_id" ] || [ "$key_id" = "null" ]; then
    echo "agmsg: team '$team' has no key yet — run 'key.sh generate $team' or 'key.sh import $team <identity>'." >&2
    exit 1
  fi

  if [ "$reveal" -eq 0 ]; then
    echo "Team: $team"
    echo "Recipient fingerprint: $(_key_fingerprint "$recipient")"
    echo "Public recipient: $recipient"
    return
  fi

  # Refused outright in agent mode — no TTY, no reveal, no override
  # (ADR 0007 secret-hygiene: this is the one place a raw secret can reach
  # stdout, so it must be harder to trigger than the rest of the CLI).
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "agmsg: --reveal-secret requires an interactive terminal and is refused in agent mode." >&2
    exit 1
  fi
  echo "This will print your private key material to the terminal."
  read -r -p "Type 'reveal' to confirm: " confirm
  if [ "$confirm" != "reveal" ]; then
    echo "Aborted." >&2
    exit 1
  fi
  local identity_file
  identity_file="$(_key_cred_dir "$team")/$key_id.key"
  if [ ! -f "$identity_file" ]; then
    echo "agmsg: local identity file missing for key_id=$key_id ($identity_file)" >&2
    exit 1
  fi
  grep '^AGE-SECRET-KEY-' "$identity_file"
}

cmd_import() {
  local team="${1:?Usage: key.sh import <team> <identity>}"
  local identity="${2:?Missing identity}"
  agmsg_validate_team_name "$team" || exit 1

  case "$identity" in
    AGE-SECRET-KEY-1*) : ;;
    *)
      echo "agmsg: not a well-formed age identity (expected AGE-SECRET-KEY-1...)" >&2
      exit 1 ;;
  esac

  local cfg
  cfg="$(_key_team_config "$team")"
  if [ ! -f "$cfg" ]; then
    echo "agmsg: team not found: $team" >&2
    exit 1
  fi

  _key_require_age || exit 1

  local recipient
  recipient="$(printf '%s\n' "$identity" | age-keygen -y 2>/dev/null)" || true
  if [ -z "$recipient" ]; then
    echo "agmsg: failed to derive a recipient from the given identity — not a valid age identity." >&2
    exit 1
  fi

  # Fail closed: if the team already has an authorized epoch, the imported
  # identity's recipient must match it — an identity that decrypts nothing
  # useful for this team is more confusing to discover later than to reject
  # up front (ADR 0007 §8).
  local cur_key_id cur_recipient
  cur_key_id="$(_key_read_config_field "$cfg" '$.remote_key.current.key_id')"
  cur_recipient="$(_key_read_config_field "$cfg" '$.remote_key.current.recipient')"
  if [ -n "$cur_key_id" ] && [ "$cur_key_id" != "null" ] && [ "$cur_recipient" != "$recipient" ]; then
    echo "agmsg: imported identity's recipient does not match team '$team's authorized key — refusing to import." >&2
    exit 1
  fi

  local cred_dir key_id created_at identity_file
  cred_dir="$(_key_cred_dir "$team")"
  mkdir -p "$cred_dir"
  chmod 700 "$cred_dir" 2>/dev/null || true

  if [ -z "$cur_key_id" ] || [ "$cur_key_id" = "null" ]; then
    # No epoch yet for this team: importing establishes the first one.
    key_id="epoch-$(date -u +%Y%m%d%H%M%S)"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    identity_file="$cred_dir/$key_id.key"
    printf '%s\n' "$identity" > "$identity_file"
    chmod 600 "$identity_file"
    _key_write_epoch "$team" "$cfg" "$(_key_epoch_json "$key_id" 0 0 "$recipient" null "$created_at")" || exit 1
  else
    # Matches the existing epoch (checked above): just store this device's
    # copy of the identity under the existing key_id. Does not create a new
    # epoch/snapshot — that only happens via generate (new team) or rotate.
    key_id="$cur_key_id"
    identity_file="$cred_dir/$key_id.key"
    printf '%s\n' "$identity" > "$identity_file"
    chmod 600 "$identity_file"
  fi

  echo "Imported key for team '$team'."
  echo "Recipient fingerprint: $(_key_fingerprint "$recipient")"
}

cmd_rotate() {
  local team="${1:?Usage: key.sh rotate [<team>]}"
  agmsg_validate_team_name "$team" || exit 1
  _key_require_age || exit 1

  local cfg
  cfg="$(_key_team_config "$team")"
  if [ ! -f "$cfg" ]; then
    echo "agmsg: team not found: $team" >&2
    exit 1
  fi

  local cur_key_id cur_epoch cur_writer_gen
  cur_key_id="$(_key_read_config_field "$cfg" '$.remote_key.current.key_id')"
  if [ -z "$cur_key_id" ] || [ "$cur_key_id" = "null" ]; then
    echo "agmsg: team '$team' has no existing key to rotate — run 'key.sh generate $team' first." >&2
    exit 1
  fi
  cur_epoch="$(_key_read_config_field "$cfg" '$.remote_key.current.epoch_revision')"
  cur_writer_gen="$(_key_read_config_field "$cfg" '$.remote_key.current.writer_generation')"

  local cred_dir new_key_id created_at identity_file new_epoch recipient
  cred_dir="$(_key_cred_dir "$team")"
  mkdir -p "$cred_dir"
  chmod 700 "$cred_dir" 2>/dev/null || true
  new_key_id="$(_key_new_key_id)"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  new_epoch=$((cur_epoch + 1))
  identity_file="$cred_dir/$new_key_id.key"

  local keygen_err
  keygen_err="$(mktemp "${TMPDIR:-/tmp}/agmsg-keygen-err.XXXXXX")"
  if ! age-keygen -o "$identity_file" 2>"$keygen_err"; then
    echo "agmsg: age-keygen failed: $(cat "$keygen_err" 2>/dev/null)" >&2
    rm -f "$keygen_err"
    exit 1
  fi
  rm -f "$keygen_err"
  chmod 600 "$identity_file"
  recipient="$(grep '^# public key:' "$identity_file" | sed 's/^# public key: //')"

  # Never re-encrypts existing envelopes (H1): only the config's "current"
  # epoch pointer moves. Every prior epoch stays in remote_key.epochs and its
  # identity file stays on disk — retaining old epochs is required to decrypt
  # history (single-writer rotation, no cutover barrier needed).
  _key_write_epoch "$team" "$cfg" "$(_key_epoch_json "$new_key_id" "$new_epoch" "$cur_writer_gen" "$recipient" null "$created_at")" || exit 1

  echo "Started a new epoch for team '$team' (epoch_revision $cur_epoch -> $new_epoch)."
  echo "Recipient fingerprint: $(_key_fingerprint "$recipient")"
  echo
  echo "This device's prior key is retained locally and still used to decrypt"
  echo "older history. Messages sent from now on use the new key. Sharing the"
  echo "new key with anyone else who needs to read new messages is a manual"
  echo "'key.sh show' hand-off, same as initial onboarding."
}

case "${1:-}" in
  generate) shift; cmd_generate "$@" ;;
  show) shift; cmd_show "$@" ;;
  import) shift; cmd_import "$@" ;;
  rotate) shift; cmd_rotate "$@" ;;
  *)
    echo "Usage: key.sh <generate|show|import|rotate> ..." >&2
    exit 1 ;;
esac
