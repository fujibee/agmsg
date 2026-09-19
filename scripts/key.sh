#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   key.sh generate [<team>]
#   key.sh show [<team>] [--key-id <key-id>] [--reveal-secret]
#   key.sh show [<team>] --snapshot [--out <file>]
#   key.sh handoff <team> [--out <file>]
#   key.sh import <team> [<identity>] [--identity-stdin]
#   key.sh rotate [<team>]
#
# Team-scoped end-to-end encryption key management (age-v1 profile,
# docs/spec/ref/age-v1-profile.md). Scope: initial single-writer onboarding
# (generate the very first key, import one obtained out-of-band, or announce a
# replacement through the team journal).
# Authority-confirmed epoch snapshots are imported separately through
# remote-sync configure. Rotation protects messages written after the
# acknowledged boundary; anyone who retained an old key can still read the
# history encrypted with it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONNECTION_ROOT="${AGMSG_SYNC_CONNECTION_DIR:-$SKILL_DIR}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
# shellcheck source=lib/operator-guidance.sh
source "$SCRIPT_DIR/lib/operator-guidance.sh"
# A printed command is one someone pastes, so the team name in it has to
# survive a shell. See lib/shquote.sh for why naive `'$var'` is not enough.
# shellcheck source=lib/shquote.sh
source "$SCRIPT_DIR/lib/shquote.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/roster-journal.sh"
# agmsg_sha256 -- `shasum` is absent in Git for Windows' Git Bash, and every
# digest below is either a fingerprint a human compares or an E2EE checkpoint.
# shellcheck source=lib/hash.sh
source "$SCRIPT_DIR/lib/hash.sh"

TEAMS_DIR="$CONNECTION_ROOT/teams"
CRED_ROOT="$CONNECTION_ROOT/run/remote-credentials"

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
# (see docs/design/remote-sync.md), duplicated here since key.sh can also be invoked directly
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
# <escaped> is spliced as a genuine SQL string literal below, NOT bound via
# `.param set`: the sqlite3 shell's dot-command tokenizer does not honour SQL
# '' escaping (unlike a real SQL statement's string literals), so
# `.param set :json '...'` silently mis-parses as soon as the config
# contains any single quote (#87 cluster; see resolve-project.sh's
# `resolve_team` for the same caveat, and PR #482 for the sibling-script
# fix this mirrors).
_key_read_config_field() {
  local cfg="$1" path="$2" escaped
  [ -f "$cfg" ] || { echo "null"; return; }
  escaped=$(sed "s/'/''/g" "$cfg")
  agmsg_sqlite_mem "SELECT json_extract('$escaped', '$path');"
}

# Short, human-comparable digest of a recipient string (SSH-key-fingerprint
# style grouping) — for the H7 fingerprint-verification step:
# two people compare this same short string over a separate channel.
#
# Fails rather than returning a short string it could not compute: see the
# callers, which now take the value into a variable of its own before printing
# it. An empty fingerprint is the worst possible output here -- both people see
# the same blank and agree.
#
# THAT REFUSAL RIDES ON `set -o pipefail`, LINE 2. `agmsg_sha256` is in the
# middle of this pipeline, and `cut` and `sed` are perfectly happy with the
# empty input a failed digest leaves them: without pipefail the pipeline exits 0
# with an empty string, the caller's assignment succeeds, and the label prints
# with nothing after it. Dropping `pipefail` reddens both "no blank
# fingerprint" cases in tests/test_key.bats, which is the control for this
# paragraph -- if you are here because you want to simplify line 2, run them.
_key_fingerprint() {
  printf '%s' "$1" | agmsg_sha256 | cut -c1-16 | sed 's/\(....\)/\1-/g;s/-$//'
}

_key_fingerprint_sha256() {
  printf '%s' "$1" | agmsg_sha256
}

# A timestamp alone collides when two epochs are minted within the same
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

# _key_write_epoch_locked <config_json_path> <epoch_json_expr>
# Assumes the caller ALREADY holds this team's config lock (agmsg_lock_acquire)
# — does not acquire/release it itself. Writes remote_key.current = the new
# epoch and appends it to remote_key.epochs.
_key_write_epoch_locked() {
  local cfg="$1" epoch_expr="$2" escaped updated
  escaped=$(sed "s/'/''/g" "$cfg")
  # <escaped> is spliced as a genuine SQL string literal, NOT bound via
  # `.param set` (same tokenizer caveat as `_key_read_config_field` above).
  updated=$(agmsg_sqlite_mem \
    "SELECT json_set('$escaped',
       '\$.remote_key.current', $epoch_expr,
       '\$.remote_key.epochs',
         json_insert(
           CASE WHEN json_type(json_extract('$escaped', '\$.remote_key.epochs')) = 'array'
                THEN json_extract('$escaped', '\$.remote_key.epochs') ELSE json('[]') END,
           '\$[#]', $epoch_expr
         )
     );")
  agmsg_write_atomic "$cfg" "$updated"
}

# _key_stage_epoch_locked <config_json_path> <epoch_json_expr>
# Appends the epoch to remote_key.epochs and leaves remote_key.current alone.
# Same locking contract as _key_write_epoch_locked.
#
# A rotation is announced locally but is not effective until the authority
# sequences its journal record. remote_key.current means "the latest CONFIRMED
# epoch" -- every reader of it is entitled to that -- so a rotation stages into
# epochs and waits. Staging into current instead made key.sh import read the
# announced replacement as the current key and take the idempotent re-import
# path, so the announced-replacement install became unreachable on the machine
# that rotated -- caught by tests/test_key.bats "key import: installs an
# out-of-band replacement only after its fingerprint is announced".
_key_stage_epoch_locked() {
  local cfg="$1" epoch_expr="$2" escaped updated
  escaped=$(sed "s/'/''/g" "$cfg")
  updated=$(agmsg_sqlite_mem \
    "SELECT json_set('$escaped',
       '\$.remote_key.epochs',
         json_insert(
           CASE WHEN json_type(json_extract('$escaped', '\$.remote_key.epochs')) = 'array'
                THEN json_extract('$escaped', '\$.remote_key.epochs') ELSE json('[]') END,
           '\$[#]', $epoch_expr
         )
     );")
  agmsg_write_atomic "$cfg" "$updated"
}

# _key_confirmed_epoch <team>
# The epoch the authority actually sequenced, as revision<TAB>key_id<TAB>recipient,
# read from the tail of the exported snapshot chain -- the one place that knows.
# Non-zero (and silent) when there is no chain to read, which is the caller's cue
# to leave current where it is rather than guess.
#
# The revision alone does not identify it. Two machines can announce a rotation
# at the same revision; the authority sequences one of them and the chain's tail
# names THAT one, key and recipient included. Promoting on the revision would let
# a machine whose local ledger holds the loser install the loser as effective --
# the exact thing this file is here to prevent, in the case where it matters most.
_key_confirmed_epoch() {
  local team="$1" snapshot row
  snapshot="$(mktemp "${TMPDIR:-/tmp}/agmsg-confirmed-epoch.XXXXXX")" || return 1
  if ! bash "$SCRIPT_DIR/remote-sync.sh" export-age-snapshot \
      --team "$team" --out "$snapshot" >/dev/null 2>&1; then
    rm -f "$snapshot"
    return 1
  fi
  row="$(agmsg_sqlite_mem "
    WITH doc(j) AS (SELECT readfile('$(agmsg_sql_readfile_path "$snapshot")')),
         tail(e) AS (
           SELECT value FROM doc, json_each(json_extract(doc.j, '\$.history'))
            ORDER BY CAST(key AS INTEGER) DESC LIMIT 1)
    SELECT json_extract(e, '\$.epoch_revision') || char(9) ||
           json_extract(e, '\$.key_id')         || char(9) ||
           json_extract(e, '\$.recipients[0]')
      FROM tail;")"
  rm -f "$snapshot"
  case "$row" in ''|*'|'*) return 1 ;; esac
  # A tail missing any of the three is not something to promote against.
  case "$row" in *$'\t'*$'\t'*) ;; *) return 1 ;; esac
  printf '%s' "$row"
}

# _key_promote_confirmed_locked <team> <config_json_path>
# Move remote_key.current forward to the epoch the chain has confirmed, and only
# when the local ledger holds that exact epoch -- revision, key_id and recipient
# all matching. A machine that staged a competing rotation has no entry to
# promote and keeps the epoch it has, which is the correct answer: it needs the
# winner's identity imported before anything of its own becomes effective.
#
# Lazy on purpose: the chain is the single source of truth, so nothing writes
# back into this ledger at confirmation time -- readers find current already
# correct on the next key.sh run. Same locking contract as above.
_key_promote_confirmed_locked() {
  local team="$1" cfg="$2" row confirmed_rev confirmed_key confirmed_rcpt \
    cur_revision escaped updated
  row="$(_key_confirmed_epoch "$team")" || return 0
  confirmed_rev="${row%%	*}"
  confirmed_key="${row#*	}"; confirmed_key="${confirmed_key%%	*}"
  confirmed_rcpt="${row##*	}"
  case "$confirmed_rev" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$confirmed_key" ] && [ -n "$confirmed_rcpt" ] || return 0
  cur_revision="$(_key_read_config_field "$cfg" '$.remote_key.current.epoch_revision')"
  case "$cur_revision" in ''|null|*[!0-9]*) return 0 ;; esac
  [ "$confirmed_rev" -gt "$cur_revision" ] 2>/dev/null || return 0
  escaped=$(sed "s/'/''/g" "$cfg")
  updated=$(agmsg_sqlite_mem \
    "SELECT json_set('$escaped', '\$.remote_key.current',
       (SELECT value FROM json_each(json_extract('$escaped', '\$.remote_key.epochs'))
         WHERE json_extract(value, '\$.epoch_revision') = $confirmed_rev
           AND json_extract(value, '\$.key_id')        = '$(_agmsg_sqlesc "$confirmed_key")'
           AND json_extract(value, '\$.recipient')     = '$(_agmsg_sqlesc "$confirmed_rcpt")'
         LIMIT 1));")
  # No local entry for the confirmed winner: leave the ledger alone rather than
  # write a null over a live current.
  case "$updated" in ''|*'"current":null'*) return 0 ;; esac
  agmsg_write_atomic "$cfg" "$updated"
}

# _key_write_identity_atomic <dest_path> <content>
# Writes <content> to <dest_path> without ever truncating an existing file
# in place: create a same-directory temp file with mktemp (which itself
# opens O_EXCL, so it can never collide with or follow an existing path —
# in particular never follows a symlink at <dest_path>), 0600 it before any
# content touches disk, write, best-effort fsync, then atomically rename
# over the destination. A crash or full disk during the write leaves the
# temp file incomplete and the real <dest_path> (if any) untouched (B4).
_key_write_identity_atomic() {
  local dest="$1" content="$2" dir tmp
  dir="$(dirname "$dest")"
  tmp="$(mktemp "$dir/.identity-XXXXXX")"
  chmod 600 "$tmp"
  # Cleanup trap: a kill signal between mktemp and the rename below would
  # otherwise leave a 0600-but-never-renamed temp copy of the key sitting
  # in the credential store indefinitely (same nonblocking finding raised
  # against remote.sh's analogous credential-file write).
  trap 'rm -f "$tmp"' EXIT INT TERM
  printf '%s\n' "$content" > "$tmp"
  sync 2>/dev/null || true
  mv "$tmp" "$dest"
  trap - EXIT INT TERM
}

cmd_generate() {
  local team="${1:?Usage: key.sh generate [<team>]}"
  agmsg_validate_team_name "$team" || exit 1

  local cfg
  cfg="$(_key_team_config "$team")"
  if [ ! -f "$cfg" ]; then
    echo "agmsg: team not found: $team" >&2
    exit 1
  fi
  local connected_at disconnected_at binding_cipher
  connected_at="$(_key_read_config_field "$cfg" '$.remote_binding.connected_at')"
  disconnected_at="$(_key_read_config_field "$cfg" '$.remote_binding.disconnected_at')"
  binding_cipher="$(_key_read_config_field "$cfg" '$.remote_binding.cipher_profile')"
  if [ -n "$connected_at" ] && [ "$connected_at" != "null" ] &&
      [ "$binding_cipher" != "age-v1" ] &&
      { [ -z "$disconnected_at" ] || [ "$disconnected_at" = "null" ]; }; then
    echo "agmsg: team '$team' already has a plaintext remote binding; its encryption choice cannot be changed later." >&2
    echo "Create a new team, generate its key, then connect that new team with --e2ee." >&2
    exit 1
  fi
  _key_require_age || exit 1

  local cred_dir
  cred_dir="$(_key_cred_dir "$team")"
  mkdir -p "$cred_dir"
  chmod 700 "$cred_dir" 2>/dev/null || true

  # The existence check and the write happen inside the SAME team-config
  # lock (B4) — otherwise two concurrent `generate` (or `generate` racing
  # `import`) calls can both pass the check before either writes, minting
  # two unrelated epoch-0 keys for the same team.
  agmsg_lock_acquire "$TEAMS_DIR/$team" || exit 1
  local existing
  existing="$(_key_read_config_field "$cfg" '$.remote_key.current.key_id')"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    agmsg_lock_release
    echo "agmsg: team '$team' already has a key (key_id=$existing). To view it:" >&2
    echo "  bash $(agmsg_shq "$SKILL_DIR/scripts/key.sh") show $(agmsg_shq "$team")" >&2
    echo "To mint a replacement epoch instead:" >&2
    echo "  bash $(agmsg_shq "$SKILL_DIR/scripts/key.sh") rotate $(agmsg_shq "$team")" >&2
    exit 1
  fi

  local key_id created_at identity_file recipient keygen_err
  key_id="$(_key_new_key_id)"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  identity_file="$cred_dir/$key_id.key"

  keygen_err="$(mktemp "${TMPDIR:-/tmp}/agmsg-keygen-err.XXXXXX")"
  if ! age-keygen -o "$identity_file" 2>"$keygen_err"; then
    agmsg_lock_release
    echo "agmsg: age-keygen failed: $(cat "$keygen_err" 2>/dev/null)" >&2
    rm -f "$keygen_err"
    exit 1
  fi
  rm -f "$keygen_err"
  chmod 600 "$identity_file"
  recipient="$(grep '^# public key:' "$identity_file" | sed 's/^# public key: //')"

  _key_write_epoch_locked "$cfg" "$(_key_epoch_json "$key_id" 0 0 "$recipient" null "$created_at")"
  agmsg_lock_release

  # Computed into a variable of its own, NOT inline in the echo. A command
  # substitution that fails inside a simple command's arguments leaves that
  # command's own status untouched, so `echo` succeeded and printed the label
  # with nothing after it. A bare assignment's status IS the substitution's, so
  # `set -e` stops here instead. (Same reasoning as remote.sh's `existing=` note;
  # `local fp_short="$(...)"` would put the status back on the declaration and
  # undo it.)
  local fp_short
  fp_short="$(_key_fingerprint "$recipient")"
  echo "Generated a new key for team '$team'."
  echo "Recipient fingerprint: $fp_short"
  echo
  # What the key IS, always: true whoever ran this, so it is never held back.
  #
  # Stated as KEY loss, not DEVICE loss. Those are the same event only where
  # nothing keeps a copy, which is this install's situation and not everyone's
  # -- a caller may hold a sealed copy of this same key and be able to recover
  # it after the device is gone. "Lose the device and it is unreadable" would
  # be the very premise this change exists to stop asserting on their behalf.
  # The condition below holds either way, because a surviving copy is exactly
  # what makes it not hold.
  echo "If this key is lost and no copy of it survives anywhere, every"
  echo "message encrypted under it becomes permanently unreadable. Removing"
  echo "a device later does not revoke its ability to read history encrypted"
  echo "before removal."

  # What to DO about it: only ours to say when nobody else owns that job.
  # Both claims below are specific to a plain install -- a larger tool may
  # keep a sealed copy on a server and have its own way to set that up, and
  # its operator has never heard of key.sh. Saying this there is not merely
  # noise; it is false, and it points away from the route they have.
  if agmsg_operator_guidance_is_ours; then
    echo
    echo "Back this up now. agmsg does not store a copy of this key anywhere,"
    echo "and there is no server-side recovery — so losing this device loses"
    echo "the key, and with it the history. Run"
    echo "  bash $(agmsg_shq "$SKILL_DIR/scripts/key.sh") show $(agmsg_shq "$team") --reveal-secret"
    echo "and save what it prints somewhere safe — a password manager entry,"
    echo "not a plaintext file. Do NOT copy it into a dotfiles repo, a git repo"
    echo "of any kind, or any other synced/backed-up-by-a-tool location you"
    echo "wouldn't also trust with a production credential."
  fi
}

cmd_show() {
  local team="" requested_key_id="" reveal=0 snapshot=0 out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reveal-secret) reveal=1 ;;
      --snapshot) snapshot=1 ;;
      --out)
        shift
        out="${1:?Missing value for --out}"
        ;;
      --key-id)
        shift
        requested_key_id="${1:?Missing value for --key-id}"
        ;;
      *) team="$1" ;;
    esac
    shift
  done
  : "${team:?Usage: key.sh show [<team>] [--reveal-secret] | key.sh show [<team>] --snapshot [--out <file>]}"
  agmsg_validate_team_name "$team" || exit 1

  local cfg key_id recipient identity_file
  cfg="$(_key_team_config "$team")"
  key_id="${requested_key_id:-$(_key_read_config_field "$cfg" '$.remote_key.current.key_id')}"
  if [ -z "$key_id" ] || [ "$key_id" = "null" ]; then
    echo "agmsg: team '$team' has no key yet — run one of:" >&2
    echo "  bash $(agmsg_shq "$SKILL_DIR/scripts/key.sh") generate $(agmsg_shq "$team")" >&2
    echo "  bash $(agmsg_shq "$SKILL_DIR/scripts/key.sh") import $(agmsg_shq "$team")" >&2
    exit 1
  fi

  if [ "$snapshot" -eq 1 ]; then
    if [ "$reveal" -eq 1 ] || [ -n "$requested_key_id" ]; then
      echo "agmsg: --snapshot cannot be combined with --reveal-secret or --key-id." >&2
      exit 1
    fi
    if [ -n "$out" ]; then
      exec bash "$SCRIPT_DIR/remote-sync.sh" export-age-snapshot \
        --team "$team" --out "$out"
    fi
    exec bash "$SCRIPT_DIR/remote-sync.sh" export-age-snapshot --team "$team"
  elif [ -n "$out" ]; then
    echo "agmsg: --out requires --snapshot." >&2
    exit 1
  fi

  identity_file="$(_key_cred_dir "$team")/$key_id.key"
  if [ -n "$requested_key_id" ]; then
    _key_require_age || exit 1
    [ -f "$identity_file" ] || {
      echo "agmsg: local identity file missing for key_id=$key_id ($identity_file)" >&2
      exit 1
    }
    recipient="$(age-keygen -y "$identity_file" 2>/dev/null)"
  else
    recipient="$(_key_read_config_field "$cfg" '$.remote_key.current.recipient')"
  fi

  if [ "$reveal" -eq 0 ]; then
    local fp_short
    fp_short="$(_key_fingerprint "$recipient")"
    echo "Team: $team"
    echo "Recipient fingerprint: $fp_short"
    echo "Public recipient: $recipient"
    return
  fi

  # Refused outright in agent mode — no TTY, no reveal, no override
  # (remote-connect secret hygiene: this is the one place a raw secret can reach
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
  if [ ! -f "$identity_file" ]; then
    echo "agmsg: local identity file missing for key_id=$key_id ($identity_file)" >&2
    exit 1
  fi
  grep '^AGE-SECRET-KEY-' "$identity_file"
}

cmd_handoff() {
  local team="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:?--out requires a value}"; shift 2 ;;
      --out=*) out="${1#--out=}"; shift ;;
      --*) echo "agmsg: unknown handoff option: $1" >&2; exit 1 ;;
      *) [ -z "$team" ] || { echo "agmsg: handoff accepts one team" >&2; exit 1; }
         team="$1"; shift ;;
    esac
  done
  : "${team:?Usage: key.sh handoff <team> [--out <file>]}"
  agmsg_validate_team_name "$team" || exit 1
  if [ -z "$out" ]; then
    local handoff_dir="$CRED_ROOT/$team/handoff"
    mkdir -p "$handoff_dir"
    chmod 700 "$handoff_dir" 2>/dev/null || true
    out="$handoff_dir/$team-age-handoff.json"
  fi
  _key_require_age || exit 1
  bash "$SCRIPT_DIR/remote-sync.sh" export-age-handoff --team "$team" --out "$out"
  echo "Handoff bundle written to: $out"
  echo "KEEP SECRET — this file IS the key. Transfer it only through a trusted channel."
}

cmd_import() {
  local identity_stdin=0 requested_key_id="" positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --identity-stdin) identity_stdin=1; shift ;;
      --key-id) requested_key_id="${2:?--key-id requires a value}"; shift 2 ;;
      --key-id=*) requested_key_id="${1#--key-id=}"; shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  local team="${positional[0]:?Usage: key.sh import <team> [<identity>] [--identity-stdin]}"
  agmsg_validate_team_name "$team" || exit 1
  if [ -n "$requested_key_id" ]; then
    printf '%s\n' "$requested_key_id" |
      grep -Eq '^[a-z0-9][a-z0-9._-]{0,63}$' || {
      echo "agmsg: --key-id is not a valid age key id." >&2
      exit 1
    }
  fi

  local identity
  if [ "$identity_stdin" -eq 1 ]; then
    if [ "${#positional[@]}" -gt 1 ]; then
      echo "agmsg: too many arguments with --identity-stdin (expected only <team>)" >&2
      exit 1
    fi
    identity="$(cat)"
  else
    identity="${positional[1]:?Missing identity (positional argument, or use --identity-stdin)}"
    echo "agmsg: passing the identity as an argument may expose it via shell history, 'ps', or a caller's own argv/transcript; prefer --identity-stdin" >&2
  fi

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

  local cred_dir
  cred_dir="$(_key_cred_dir "$team")"
  mkdir -p "$cred_dir"
  chmod 700 "$cred_dir" 2>/dev/null || true

  # Fail closed, and check-then-act atomically under the team lock (B4):
  # if the team already has an authorized epoch, the imported identity's
  # recipient must match it. Checking outside the lock would let a
  # concurrent generate/import race land a different key in between.
  agmsg_lock_acquire "$TEAMS_DIR/$team" || exit 1
  # Catch up with the chain first: the branch below turns on what current is,
  # and a rotation confirmed since the last key.sh run has not been copied here
  # yet. Cheap and idempotent when nothing has moved.
  _key_promote_confirmed_locked "$team" "$cfg"
  local cur_key_id cur_recipient
  cur_key_id="$(_key_read_config_field "$cfg" '$.remote_key.current.key_id')"
  cur_recipient="$(_key_read_config_field "$cfg" '$.remote_key.current.recipient')"

  if [ -n "$cur_key_id" ] && [ "$cur_key_id" != "null" ]; then
    if { [ -n "$requested_key_id" ] && [ "$requested_key_id" != "$cur_key_id" ]; } ||
       [ "$cur_recipient" != "$recipient" ]; then
      local journal journal_sql fingerprint staged_key_id
      journal="$(agmsg_roster_journal_path "$TEAMS_DIR/$team")"
      fingerprint="$(_key_fingerprint_sha256 "$recipient")"
      staged_key_id=""
      if [ -f "$journal" ]; then
        journal_sql="$(agmsg_sql_readfile_path "$journal")"
        staged_key_id="$(agmsg_sqlite_mem "
          WITH source(doc) AS (
            SELECT '[' || replace(
              rtrim(CAST(readfile('$journal_sql') AS TEXT), char(10)),
              char(10), ',') || ']'
          )
          SELECT json_extract(value, '\$.key_id')
            FROM source, json_each(source.doc)
           WHERE json_extract(value, '\$.type')='key_rotated'
             AND json_extract(value, '\$.fingerprint')='$(_agmsg_sqlesc "$fingerprint")'
           ORDER BY CAST(key AS INTEGER) DESC LIMIT 1;")"
      fi
      if [ -z "$staged_key_id" ]; then
        agmsg_lock_release
        echo "agmsg: imported identity does not match the current key or an announced rotation — refusing to import." >&2
        exit 1
      fi
      if [ -n "$requested_key_id" ] && [ "$requested_key_id" != "$staged_key_id" ]; then
        agmsg_lock_release
        echo "agmsg: imported authority key id does not match the announced rotation." >&2
        exit 1
      fi
      printf '%s\n' "$staged_key_id" | grep -Eq '^[a-z0-9][a-z0-9._-]{0,63}$' || {
        agmsg_lock_release
        echo "agmsg: announced replacement key id is invalid — refusing to import." >&2
        exit 1
      }
      _key_write_identity_atomic "$cred_dir/$staged_key_id.key" "$identity"
      agmsg_lock_release
      unset identity
      local fp_short
      fp_short="$(_key_fingerprint "$recipient")"
      echo "Imported replacement key for team '$team' (key_id=$staged_key_id)."
      echo "Recipient fingerprint: $fp_short"
      return
    fi
    # Matches the existing epoch: just store this device's copy of the
    # identity under the existing key_id (idempotent re-import). Does not
    # create a new epoch/snapshot — that only happens via generate.
    _key_write_identity_atomic "$cred_dir/$cur_key_id.key" "$identity"
    agmsg_lock_release
  else
    # No epoch yet for this team: importing establishes the first one.
    local key_id created_at
    key_id="${requested_key_id:-$(_key_new_key_id)}"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _key_write_identity_atomic "$cred_dir/$key_id.key" "$identity"
    _key_write_epoch_locked "$cfg" "$(_key_epoch_json "$key_id" 0 0 "$recipient" null "$created_at")"
    agmsg_lock_release
  fi
  unset identity

  local fp_short
  fp_short="$(_key_fingerprint "$recipient")"
  echo "Imported key for team '$team'."
  echo "Recipient fingerprint: $fp_short"
}

cmd_rotate() {
  local team="${1:?Usage: key.sh rotate [<team>]}"
  agmsg_validate_team_name "$team" || exit 1
  local cfg team_dir cred_dir current_key journal journal_sql pending
  cfg="$(_key_team_config "$team")"
  team_dir="$TEAMS_DIR/$team"
  [ -f "$cfg" ] || { echo "agmsg: team not found: $team" >&2; exit 1; }
  cred_dir="$(_key_cred_dir "$team")"
  mkdir -p "$cred_dir"
  chmod 700 "$cred_dir" 2>/dev/null || true

  agmsg_lock_acquire "$team_dir" || exit 1
  # The replacement is minted relative to current, so current has to be the
  # confirmed epoch before anything is computed from it.
  _key_promote_confirmed_locked "$team" "$cfg"
  current_key="$(_key_read_config_field "$cfg" '$.remote_key.current.key_id')"
  if [ -z "$current_key" ] || [ "$current_key" = "null" ]; then
    agmsg_lock_release
    echo "agmsg: team '$team' has no current key — generate or import the first key before rotating." >&2
    exit 1
  fi
  if ! _key_require_age; then
    agmsg_lock_release
    exit 1
  fi
  agmsg_roster_ensure "$team_dir" "$cfg"
  journal="$(agmsg_roster_journal_path "$team_dir")"
  if [ ! -f "$journal" ]; then
    agmsg_lock_release
    echo "agmsg: team '$team' has no identity journal; connect or migrate it before rotating." >&2
    exit 1
  fi
  journal_sql="$(agmsg_sql_readfile_path "$journal")"
  pending="$(agmsg_sqlite_mem "
    WITH source(doc) AS (
      SELECT '[' || replace(
        rtrim(CAST(readfile('$journal_sql') AS TEXT), char(10)),
        char(10), ',') || ']'
    ),
    rows AS (SELECT value FROM source,json_each(source.doc)),
    rotations AS (
      SELECT json_extract(value,'\$.id') AS id FROM rows
       WHERE json_extract(value,'\$.type')='key_rotated'
    ),
    synced AS (
      SELECT json_extract(value,'\$.mutation_id') AS id FROM rows
       WHERE json_extract(value,'\$.type')='roster_synced'
    )
    SELECT count(*) FROM rotations r LEFT JOIN synced s USING(id)
     WHERE s.id IS NULL;")"
  if [ "$pending" -ne 0 ]; then
    agmsg_lock_release
    echo "agmsg: team '$team' already has an unacknowledged key rotation." >&2
    exit 1
  fi

  # A rotation number identifies the transition, while key_id identifies the
  # locally generated key material. Concurrent machines announce the same
  # next number; server sequence then selects the first announcement.
  local base_revision latest accepted_epoch accepted_key_id accepted_fingerprint next_epoch
  base_revision="$(_key_read_config_field "$cfg" '$.remote_key.current.epoch_revision')"
  [ -n "$base_revision" ] && [ "$base_revision" != "null" ] || base_revision=0
  printf '%s\n' "$base_revision" | grep -Eq '^(0|[1-9][0-9]*)$' || {
    agmsg_lock_release
    echo "agmsg: current key epoch revision is invalid." >&2
    exit 1
  }
  latest="$(agmsg_sqlite_mem "
    WITH source(doc) AS (
      SELECT '[' || replace(
        rtrim(CAST(readfile('$journal_sql') AS TEXT), char(10)),
        char(10), ',') || ']'
    ),
    rows AS (SELECT value FROM source,json_each(source.doc)),
    rotations AS (
      SELECT json_extract(value,'\$.id') AS id,
             json_extract(value,'\$.epoch') AS epoch,
             json_extract(value,'\$.key_id') AS key_id,
             json_extract(value,'\$.fingerprint') AS fingerprint
        FROM rows WHERE json_extract(value,'\$.type')='key_rotated'
    ),
    synced AS (
      SELECT json_extract(value,'\$.mutation_id') AS id,
             CAST(json_extract(value,'\$.server_seq') AS INTEGER) AS server_seq
        FROM rows WHERE json_extract(value,'\$.type')='roster_synced'
          AND json_extract(value,'\$.server_instance_id')='$(_agmsg_sqlesc "$(_key_read_config_field "$cfg" '$.remote_binding.server_instance_id')")'
          AND json_extract(value,'\$.remote_team_id')='$(_agmsg_sqlesc "$(_key_read_config_field "$cfg" '$.remote_binding.remote_team_id')")'
    ),
    ordered AS (
      SELECT r.*, s.server_seq,
             row_number() OVER (
               PARTITION BY r.epoch ORDER BY s.server_seq, r.id
             ) AS choice
        FROM rotations r JOIN synced s USING(id)
    )
    SELECT epoch || '|' || key_id || '|' || fingerprint
      FROM ordered WHERE choice=1
     ORDER BY CAST(epoch AS INTEGER) DESC LIMIT 1;")"
  accepted_epoch="$base_revision"
  accepted_key_id="$current_key"
  accepted_fingerprint=""
  if [ -n "$latest" ]; then
    IFS='|' read -r accepted_epoch accepted_key_id accepted_fingerprint <<EOF
$latest
EOF
    printf '%s\n' "$accepted_epoch" | grep -Eq '^(0|[1-9][0-9]*)$' || {
      agmsg_lock_release
      echo "agmsg: accepted key rotation epoch is invalid." >&2
      exit 1
    }
    printf '%s\n' "$accepted_key_id" | grep -Eq '^[a-z0-9][a-z0-9._-]{0,63}$' || {
      agmsg_lock_release
      echo "agmsg: accepted replacement key id is invalid." >&2
      exit 1
    }
    if [ ! -f "$cred_dir/$accepted_key_id.key" ]; then
      agmsg_lock_release
      echo "agmsg: accepted epoch $accepted_epoch requires replacement key_id=$accepted_key_id; import that key out of band before rotating again." >&2
      exit 1
    fi
    local accepted_recipient
    accepted_recipient="$(age-keygen -y "$cred_dir/$accepted_key_id.key" 2>/dev/null)" || true
    if [ -z "$accepted_recipient" ] ||
       [ "$(_key_fingerprint_sha256 "$accepted_recipient")" != "$accepted_fingerprint" ]; then
      agmsg_lock_release
      echo "agmsg: local identity for accepted epoch $accepted_epoch does not match its announced fingerprint." >&2
      exit 1
    fi
  fi
  next_epoch="$(agmsg_sqlite_mem "SELECT CAST('$(_agmsg_sqlesc "$accepted_epoch")' AS INTEGER) + 1;")"
  printf '%s\n' "$next_epoch" | grep -Eq '^[1-9][0-9]*$' || {
    agmsg_lock_release
    echo "agmsg: next key rotation epoch is outside the supported range." >&2
    exit 1
  }

  local key_id created_at identity_file recipient fingerprint keygen_err previous_snapshot \
    previous_snapshot_sha writer_generation original_cfg
  key_id="$(_key_new_key_id)"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  identity_file="$cred_dir/$key_id.key"
  keygen_err="$(mktemp "${TMPDIR:-/tmp}/agmsg-keygen-err.XXXXXX")"
  if ! age-keygen -o "$identity_file" 2>"$keygen_err"; then
    agmsg_lock_release
    echo "agmsg: age-keygen failed: $(cat "$keygen_err" 2>/dev/null)" >&2
    rm -f "$keygen_err"
    exit 1
  fi
  rm -f "$keygen_err"
  chmod 600 "$identity_file"
  recipient="$(grep '^# public key:' "$identity_file" | sed 's/^# public key: //')"
  fingerprint="$(_key_fingerprint_sha256 "$recipient")"
  previous_snapshot="$(mktemp "${TMPDIR:-/tmp}/agmsg-age-snapshot.XXXXXX")"
  if ! bash "$SCRIPT_DIR/remote-sync.sh" export-age-snapshot \
      --team "$team" --out "$previous_snapshot" >/dev/null; then
    rm -f "$previous_snapshot" "$identity_file"
    agmsg_lock_release
    echo "agmsg: could not read the current authority-confirmed epoch snapshot." >&2
    exit 1
  fi
  previous_snapshot_sha="$(agmsg_sha256 < "$previous_snapshot")"
  rm -f "$previous_snapshot"
  writer_generation="$(agmsg_sqlite_mem \
    "SELECT CAST('$(_agmsg_sqlesc "$(_key_read_config_field "$cfg" '$.remote_key.current.writer_generation')")' AS INTEGER) + 1;")"
  original_cfg="$(cat "$cfg")"
  if ! _key_stage_epoch_locked "$cfg" \
      "$(_key_epoch_json "$key_id" "$next_epoch" "$writer_generation" "$recipient" "$previous_snapshot_sha" "$created_at")"; then
    rm -f "$identity_file"
    agmsg_lock_release
    echo "agmsg: failed to stage the replacement epoch." >&2
    exit 1
  fi
  if ! agmsg_roster_append_key_rotated "$team_dir" "$next_epoch" "$key_id" "$fingerprint" "$created_at"; then
    agmsg_write_atomic "$cfg" "$original_cfg"
    rm -f "$identity_file"
    agmsg_lock_release
    echo "agmsg: failed to publish the key rotation; no replacement was announced." >&2
    exit 1
  fi
  agmsg_lock_release

  local fp_short
  fp_short="$(_key_fingerprint "$recipient")"
  echo "Generated replacement key for team '$team' (epoch=$next_epoch, key_id=$key_id)."
  echo "Recipient fingerprint: $fp_short"
  echo "The private key was not written to the journal; distribute it out of band."
  echo "On an interactive terminal, run:"
  echo "  bash $(agmsg_shq "$SKILL_DIR/scripts/key.sh") show $(agmsg_shq "$team") --key-id $(agmsg_shq "$key_id") --reveal-secret"
  echo "Messages before the acknowledged rotation boundary remain readable with the old key."
}

case "${1:-}" in
  generate) shift; cmd_generate "$@" ;;
  show) shift; cmd_show "$@" ;;
  handoff) shift; cmd_handoff "$@" ;;
  import) shift; cmd_import "$@" ;;
  rotate) shift; cmd_rotate "$@" ;;
  *)
    echo "Usage: key.sh <generate|show|handoff|import|rotate> ..." >&2
    exit 1 ;;
esac
