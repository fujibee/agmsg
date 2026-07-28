#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   remote.sh connect --endpoint <url> [<token>] [--token-stdin] [<team>] [--force]
#   remote.sh status [<team>] [--json]
#   remote.sh disconnect <team>
#   remote.sh doctor [<team>]
#   remote.sh pending list [--json]
#   remote.sh pending abort <pending_id>
#
# Team-scoped cloud/self-hosted sync connection. The OSS CLI never
# assumes or defaults to any particular server — <endpoint> is always
# required. Login/token acquisition is out of this repo's scope (remote-connect
# §1a-§1c) — some provider tooling (or a self-hosted server's own admin
# command) obtains the token; this script only ever receives one.
#
# `status --json` and `pending list/abort` (ADR 0007 addendum) are a
# strict, secret-free ABI a cloud/self-hosted driver polls/acts on for crash
# recovery: after a connect's exchange call, the driver may not know whether
# its child `connect` invocation actually committed locally before dying.
# `status --json` lets it correlate its own operation-status record against
# the local binding by credential_id/server_instance_id/remote_team_id;
# `pending list/abort` lets it enumerate and clean up an orphaned exchange
# that never reached a local commit at all (so it isn't stuck holding a
# server-issued credential neither side will ever use) — scoped to normal,
# non-quarantined pending records only (see the comment above
# `_remote_validate_pending_id`).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONNECTION_ROOT="${AGMSG_SYNC_CONNECTION_DIR:-$SKILL_DIR}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/require-python3.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/node.sh"

TEAMS_DIR="$CONNECTION_ROOT/teams"
CRED_ROOT="$CONNECTION_ROOT/run/remote-credentials"
PENDING_DIR="$CONNECTION_ROOT/run/remote-connect-pending"

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }

_remote_team_config() { printf '%s' "$TEAMS_DIR/$1/config.json"; }
_remote_cred_file() { printf '%s' "$CRED_ROOT/$1.json"; }

# <escaped> is spliced as a genuine SQL string literal below, NOT bound via
# `.param set`: the sqlite3 shell's dot-command tokenizer does not honour SQL
# '' escaping (unlike a real SQL statement's string literals), so
# `.param set :json '...'` silently mis-parses as soon as the config
# contains any single quote (#87 cluster; see resolve-project.sh's
# `resolve_team` for the same caveat, and PR #482 for the sibling-script fix
# this mirrors — e.g. a remote_team_name containing an apostrophe, which
# _remote_commit below stores as ordinary, unremarkable JSON text).
_remote_read_config_field() {
  local cfg="$1" path="$2" escaped
  [ -f "$cfg" ] || { echo "null"; return; }
  escaped=$(sed "s/'/''/g" "$cfg")
  agmsg_sqlite_mem "SELECT json_extract('$escaped', '$path');"
}

# Bootstrap a brand-new local team dir/config, mirroring join.sh's own
# initial-config shape exactly (no agents registered yet — connect only
# establishes the sync binding, not an agent identity in the team).
_remote_ensure_team() {
  local team="$1" cfg initial
  cfg="$(_remote_team_config "$team")"
  mkdir -p "$TEAMS_DIR/$team"
  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 1
  if [ ! -f "$cfg" ]; then
    initial=$(printf '{\n  "name": "%s",\n  "team_id": "%s",\n  "agents": {},\n  "created_at": "%s"\n}' \
      "$team" "$(compat_uuid7)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    agmsg_write_atomic "$cfg" "$initial"
  fi
  agmsg_lock_release
}

# Reject a non-HTTPS endpoint (token/credential would cross the wire in
# plaintext) except for loopback, which self-host/dev setups need without a
# cert (remote-connect review findings B6/R2). Delegates to a real URL parser —
# a shell glob/prefix check here was bypassable by
# http://127.0.0.1.evil.com, http://localhost.evil.com, and the userinfo
# trick http://localhost@evil.com, all of which matched a naive
# `http://127.0.0.1*`/`http://localhost*` case pattern while actually
# pointing at a different host.
_remote_validate_endpoint() {
  python3 "$SCRIPT_DIR/internal/validate-endpoint.py" "$1"
}

# Read an interactive value without coupling it to the token transport.
# `connect --token-stdin` intentionally consumes fd 0 through EOF before the
# E2EE bootstrap starts. In a real terminal the choice/identity must therefore
# come from the controlling TTY; otherwise the secure token path can only see
# EOF and silently takes the abort branch. Non-interactive callers retain the
# historical fd-0 fallback.
_remote_prompt_read() {
  local output_var="$1" prompt="$2" silent="${3:-0}" value="" \
    echo_newline=0 read_flags=(-r)
  [ "$silent" -eq 1 ] && read_flags+=(-s)
  if [ -r /dev/tty ] && [ -w /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
    echo_newline=1
    printf '%s' "$prompt" >/dev/tty
    IFS= read "${read_flags[@]}" value </dev/tty || {
      [ "$silent" -eq 1 ] && printf '\n' >/dev/tty
      printf -v "$output_var" '%s' ""
      return 1
    }
  else
    [ -t 0 ] && echo_newline=1
    IFS= read "${read_flags[@]}" -p "$prompt" value || {
      [ "$silent" -eq 1 ] && [ "$echo_newline" -eq 1 ] && printf '\n' >&2
      printf -v "$output_var" '%s' ""
      return 1
    }
  fi
  if [ "$silent" -eq 1 ] && [ "$echo_newline" -eq 1 ]; then
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
      printf '\n' >/dev/tty
    else
      printf '\n' >&2
    fi
  fi
  printf -v "$output_var" '%s' "$value"
}

# --- doctor ------------------------------------------------------------

# Standalone, read-only, always-safe-to-run preflight: no
# token, no state change, safe whether or not the team is already connected.
# Currently just the age-binary-presence check (§8) — the natural home for
# any future preflight check added later.
cmd_doctor() {
  local team="${1:-}"
  echo "Checking prerequisites${team:+ for team '$team'}..."
  echo
  local failed=0
  if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
    echo "  [x] age / age-keygen on PATH"
  else
    echo "  [ ] age / age-keygen on PATH"
    echo
    echo "'age' is required for end-to-end encryption and was not found on this device. Install it, then retry:"
    echo "  macOS (Homebrew):      brew install age"
    echo "  Debian/Ubuntu:         sudo apt install age"
    echo "  Windows (winget):      winget install FiloSottile.age"
    echo "See https://github.com/FiloSottile/age for other install methods."
    failed=1
  fi
  echo
  if agmsg_python3_usable; then
    echo "  [x] python3 on PATH"
  else
    echo "  [ ] python3 on PATH"
    echo
    echo "'python3' is required for the remote control plane (connect/status/disconnect/pending) and was not found on this device. Install it, then retry:"
    echo "  macOS (Homebrew):      brew install python3"
    echo "  macOS (Xcode tools):   xcode-select --install"
    echo "  Debian/Ubuntu:         sudo apt install python3"
    echo "  Windows (winget):      winget install Python.Python.3"
    failed=1
  fi
  echo
  if agmsg_node_usable; then
    echo "  [x] node on PATH"
  else
    echo "  [ ] node on PATH"
    echo
    echo "'node' is required for the remote sync data plane (remote-sync.sh) and was not found on this device. Install it, then retry:"
    echo "  macOS (Homebrew):      brew install node"
    echo "  Debian/Ubuntu:         sudo apt install nodejs"
    echo "  Windows (winget):      winget install OpenJS.NodeJS"
    echo "See https://nodejs.org for other install methods."
    failed=1
  fi
  echo
  if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
  else
    echo "Some checks failed. See above."
    exit 1
  fi
}

# --- shared HTTP helpers (B1: never put secrets in curl's own argv/ps) ---

# _remote_http_post_json <url> <body_file> <out_body_file> <out_header_file> -> prints http_code
# Posts <body_file> as the request body via a curl -K config file, so the
# body (which holds the token) never appears in curl's own argv/ps. The
# config file is 0600 and removed immediately after the call.
_remote_http_post_json() {
  local url="$1" body_file="$2" out_file="$3" header_file="$4" cfg http_code \
    fifo_dir header_fifo copier_pid curl_output curl_status=0
  cfg="$(mktemp "${TMPDIR:-/tmp}/agmsg-curl-cfg.XXXXXX")"
  fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-header-pipe.XXXXXX")"
  header_fifo="$fifo_dir/header"
  mkfifo "$header_fifo"
  chmod 600 "$cfg"
  trap 'rm -f "$cfg" "$header_fifo"; rmdir "$fifo_dir" 2>/dev/null || true' EXIT INT TERM
  python3 "$SCRIPT_DIR/internal/bounded-copy.py" 65536 < "$header_fifo" > "$header_file" &
  copier_pid=$!
  {
    printf 'url = "%s"\n' "$url"
    printf 'request = "POST"\n'
    printf 'header = "Content-Type: application/json"\n'
    printf 'header = "Agmsg-Protocol-Version: 1"\n'
    printf 'dump-header = "%s"\n' "$header_fifo"
    printf 'connect-timeout = "10"\n'
    printf 'max-time = "15"\n'
    printf 'max-filesize = "2097152"\n'
    printf 'data = "@%s"\n' "$body_file"
  } > "$cfg"
  if curl_output=$(curl -sS -o "$out_file" -w '%{http_code}' -K "$cfg" 2>/dev/null); then
    :
  else
    curl_status=$?
  fi
  if [ "$curl_status" -ne 0 ]; then
    kill "$copier_pid" 2>/dev/null || true
    wait "$copier_pid" 2>/dev/null || true
    http_code="000"
  elif wait "$copier_pid"; then
    http_code="$curl_output"
  else
    http_code="000"
  fi
  rm -f "$cfg" "$header_fifo"
  rmdir "$fifo_dir" 2>/dev/null || true
  trap - EXIT INT TERM
  printf '%s' "$http_code"
}

# _remote_http_post_bearer <url> <team_id> <bearer_token> <out_body_file> <out_header_file>
# -> prints http_code
# Same argv-safety property for the Authorization header (revoke calls).
_remote_http_post_bearer() {
  local url="$1" team_id="$2" token="$3" out_file="$4" header_file="$5" cfg http_code \
    fifo_dir header_fifo copier_pid curl_output curl_status=0
  cfg="$(mktemp "${TMPDIR:-/tmp}/agmsg-curl-cfg.XXXXXX")"
  fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-header-pipe.XXXXXX")"
  header_fifo="$fifo_dir/header"
  mkfifo "$header_fifo"
  chmod 600 "$cfg"
  trap 'rm -f "$cfg" "$header_fifo"; rmdir "$fifo_dir" 2>/dev/null || true' EXIT INT TERM
  python3 "$SCRIPT_DIR/internal/bounded-copy.py" 65536 < "$header_fifo" > "$header_file" &
  copier_pid=$!
  {
    printf 'url = "%s"\n' "$url"
    printf 'request = "POST"\n'
    printf 'header = "Authorization: Bearer %s"\n' "$token"
    printf 'header = "Agmsg-Protocol-Version: 1"\n'
    printf 'header = "Agmsg-Team-ID: %s"\n' "$team_id"
    printf 'dump-header = "%s"\n' "$header_fifo"
    printf 'connect-timeout = "10"\n'
    printf 'max-time = "15"\n'
    printf 'max-filesize = "65536"\n'
  } > "$cfg"
  if curl_output=$(curl -sS -o "$out_file" -w '%{http_code}' -K "$cfg" 2>/dev/null); then
    :
  else
    curl_status=$?
  fi
  if [ "$curl_status" -ne 0 ]; then
    kill "$copier_pid" 2>/dev/null || true
    wait "$copier_pid" 2>/dev/null || true
    http_code="000"
  elif wait "$copier_pid"; then
    http_code="$curl_output"
  else
    http_code="000"
  fi
  rm -f "$cfg" "$header_fifo"
  rmdir "$fifo_dir" 2>/dev/null || true
  trap - EXIT INT TERM
  printf '%s' "$http_code"
}

# _remote_revoke <endpoint> <server_instance_id> <team_id> <credential_id> <credential>
# -> 0 revoked and response-bound, 1 not
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
  (
    local endpoint="$1" server_instance_id="$2" team_id="$3" credential_id="$4" \
      credential="$5" http_code body_file header_file
    body_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-revoke-body.XXXXXX")"
    header_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-revoke-header.XXXXXX")"
    chmod 600 "$body_file" "$header_file"
    trap 'rm -f "$body_file" "$header_file"' EXIT INT TERM
    http_code="$(_remote_http_post_bearer \
      "$endpoint/v1/credentials/$credential_id/revoke" "$team_id" "$credential" \
      "$body_file" "$header_file")"
    [ "$http_code" = "200" ] || exit 1
    python3 "$SCRIPT_DIR/internal/validate-protocol-header.py" < "$header_file" || exit 1
    python3 "$SCRIPT_DIR/internal/parse-revoke-response.py" \
      "$server_instance_id" "$team_id" "$credential_id" < "$body_file" || exit 1
  )
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
  # <escaped> is spliced as a genuine SQL string literal, NOT bound via
  # `.param set` (same tokenizer caveat as `_remote_read_config_field` above).
  updated=$(agmsg_sqlite_mem \
    "SELECT json_set('$escaped', '\$.remote_binding.disconnected_at', '$(_agmsg_sqlesc "$disconnected_at")');")
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
print(json.dumps({"endpoint": endpoint, "protocol_header_verified": True,
                  "raw_response_text": raw_response_text}))
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
def strict_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate pending key")
        value[key] = item
    return value
with open(pending_path, "rb") as f:
    encoded = f.read(16 * 1024 * 1024 + 1)
if len(encoded) > 16 * 1024 * 1024:
    raise SystemExit(1)
pending = json.loads(encoded.decode("utf-8"), object_pairs_hook=strict_object)
if not isinstance(pending, dict) or not isinstance(pending.get("endpoint"), str) or \
        not 1 <= len(pending["endpoint"].encode("utf-8")) <= 2048 or \
        not isinstance(pending.get("raw_response_text"), str) or \
        len(pending["raw_response_text"].encode("utf-8")) > 2 * 1024 * 1024:
    raise SystemExit(1)
if set(pending) == {"endpoint", "raw_response_text"}:
    raise SystemExit(42)
if set(pending) != {"endpoint", "protocol_header_verified", "raw_response_text"} or \
        pending["protocol_header_verified"] is not True:
    raise SystemExit(1)
with open(out_path, "w") as f:
    f.write(pending["raw_response_text"])
print(pending["endpoint"])
' "$pending_file" "$out_resp_file"
}

# Preserve an exchange response that cannot be resumed automatically. It may
# be the only remaining recovery material for an already-issued credential;
# deleting it would orphan a still-active server credential. The path remains
# inside the private pending directory and is forced to 0600.
_remote_quarantine_pending() {
  local pending_file="$1" reason="$2" target
  target="${pending_file}.${reason}.$(date -u +%Y%m%dT%H%M%SZ).$$"
  mv "$pending_file" "$target" || return 1
  chmod 600 "$target"
  printf '%s' "$target"
}

# --- pending list/abort (ADR 0007 addendum) ---------------------------------
#
# A cloud/self-hosted driver enumerates and (if orphaned by a crashed child
# `connect` invocation) aborts pending exchange records independently of any
# team name it can yet supply — the exchange may have succeeded server-side
# with no local commit at all. pending_id (the sha256 hex digest already
# used as the pending record's filename, see `_remote_pending_key`) is the
# authoritative, opaque abort key: it is derived from (endpoint, token)
# BEFORE the exchange ever ran, so re-deriving the identical id requires the
# identical (endpoint, token) pair — i.e. the identical logical retry, not
# an unrelated operation coincidentally "reusing" an id. That content-derived
# uniqueness is why no separate generation counter is introduced here for
# ABA protection.
#
# Deliberately scoped to NORMAL (non-quarantined) `<id>.json` records only —
# `_remote_quarantine_pending` above renames a record that failed to load to
# `<id>.json.<reason>.<timestamp>.<pid>`, which this glob and
# `_remote_pending_file`'s exact-name lookup both naturally miss. That's
# intentional, not an oversight: a quarantined record is explicitly
# preserved for a human to work through the server admin credential
# list/revoke workflow (see `_remote_quarantine_pending`'s own comment), a
# fundamentally different remediation path than an automated pending
# list/abort — a driver should not be able to silently delete recovery
# material a human may still need to reconcile an already-issued credential.
_remote_validate_pending_id() {
  printf '%s' "$1" | grep -qE '^[0-9a-f]{64}$'
}

# _remote_pending_json_one <pending_file> — always prints exactly one JSONL
# object (never skips a record just because its content doesn't validate):
# pending_id comes from the filename; endpoint/credential_id/
# server_instance_id/remote_team_id come from `_remote_load_pending` +
# `parse-exchange-response.py --metadata-only` succeeding, and are null when
# either step fails (a genuinely malformed record, OR one whose 2-key legacy
# shape trips `_remote_load_pending`'s SystemExit(42) quarantine-candidate
# path — the endpoint it parsed in that case is intentionally not
# resurfaced here, since a record in that state is exactly the kind
# `cmd_connect`'s own resume path will quarantine on its next real attempt,
# not something this listing path re-implements recovery logic for).
# "valid" reports whether the embedded response passed full validation.
# `--metadata-only` (see parse-exchange-response.py) means the raw
# credential is never read into this function's process at all, let alone
# printed.
_remote_pending_json_one() {
  local pending_file="$1" pending_id endpoint="" valid="false" \
    credential_id="" server_instance_id="" remote_team_id="" \
    resp_file parsed_file
  pending_id="$(basename "$pending_file" .json)"

  resp_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-pending-list-resp.XXXXXX")"
  chmod 600 "$resp_file"
  if endpoint="$(_remote_load_pending "$pending_file" "$resp_file" 2>/dev/null)"; then
    parsed_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-pending-list-parsed.XXXXXX")"
    chmod 600 "$parsed_file"
    if python3 "$SCRIPT_DIR/internal/parse-exchange-response.py" --metadata-only < "$resp_file" > "$parsed_file" 2>/dev/null; then
      valid="true"
      {
        IFS= read -r credential_id
        IFS= read -r server_instance_id
        IFS= read -r remote_team_id
      } < "$parsed_file"
    fi
    rm -f "$parsed_file"
  else
    endpoint=""
  fi
  rm -f "$resp_file"

  python3 -c '
import json, sys
pending_id, endpoint, credential_id, server_instance_id, remote_team_id, valid = sys.argv[1:7]
def norm(v):
    return None if v == "" else v
print(json.dumps({
    "pending_id": pending_id,
    "endpoint": norm(endpoint),
    "server_instance_id": norm(server_instance_id),
    "remote_team_id": norm(remote_team_id),
    "credential_id": norm(credential_id),
    "valid": valid == "true",
}, sort_keys=True))
' "$pending_id" "$endpoint" "$credential_id" "$server_instance_id" "$remote_team_id" "$valid"
}

cmd_pending_list() {
  local json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      *) echo "agmsg: unknown argument to 'pending list': $1" >&2; exit 1 ;;
    esac
  done

  if [ ! -d "$PENDING_DIR" ]; then
    [ "$json" -eq 1 ] || echo "No pending connect records."
    return
  fi

  local any=0 f
  for f in "$PENDING_DIR"/*.json; do
    [ -f "$f" ] || continue
    any=1
    if [ "$json" -eq 1 ]; then
      _remote_pending_json_one "$f"
    else
      local pid ep
      pid="$(basename "$f" .json)"
      ep="$(_remote_load_pending "$f" /dev/null 2>/dev/null)" || ep="(unreadable or unverified record — see 'pending list --json')"
      echo "$pid	$ep"
    fi
  done
  if [ "$any" -eq 0 ] && [ "$json" -eq 0 ]; then
    echo "No pending connect records."
  fi
}

# Per-pending-id lock, shared by `cmd_connect`'s resume path and
# `cmd_pending_abort`: without a shared lock, `connect` could read+validate
# a pending record, `abort` could then delete that same record and report
# success, and `connect` would still go on to commit a real binding from its
# own already-in-hand copy — meaning "abort succeeded" and "an active
# binding now exists for that exact operation" could both become true.
# Locking (not just reading) the whole span from "does this pending record
# still exist" through to either a successful commit (which itself deletes
# the file) or giving up makes the two operations mutually exclusive.
# Per-id (not PENDING_DIR-wide) so unrelated connects/aborts for DIFFERENT
# pending records never serialize against each other.
#
# Backed by the owner_pid-tracked runtime lock (agmsg_runtime_lock_*,
# lib/storage.sh), not a plain `mkdir`-based one — a bare mkdir lock has no
# owner/liveness concept at all: if the process holding it died via
# SIGKILL/OOM/an OS crash (exactly the scenario this whole pending/abort
# feature exists to help recover from), the lock would never be cleaned up,
# permanently blocking both resume and abort of that exact record forever.
# This is the same primitive and staleness-reclaim pattern the codex
# dispatcher lock already uses (codex-bridge-launcher.sh's
# acquire_dispatcher_lock): a dead owner_pid (`kill -0` fails) is atomically
# replaced via compare-and-swap, so a crash simply leaves a reclaimable row
# rather than a stuck lock — no separate release-on-exit trap is needed for
# correctness, since a crash (or any exit that skips the explicit release
# below) just leaves this process's owner_pid dead for the NEXT acquire
# attempt to reclaim; the explicit release at the end of a normal run is
# purely a promptness optimization. Accepts the same bare-PID reuse risk
# window that primitive's existing caller already does — no separate
# nonce/start-time disambiguation, matching established precedent rather
# than inventing a stronger (and platform-fragile) scheme.
_remote_pending_runtime_resource() { printf 'remote-pending.%s' "$1"; }

_remote_pending_lock_acquire() {
  local pending_id="$1" resource owner attempt=0 max="${AGMSG_PENDING_LOCK_TRIES:-200}"
  resource="$(_remote_pending_runtime_resource "$pending_id")"
  while [ "$attempt" -lt "$max" ]; do
    owner="$(agmsg_runtime_lock_acquire "$resource" "$$" 2>/dev/null || true)"
    if [ "$owner" = "$$" ]; then
      return 0
    fi
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      attempt=$((attempt + 1))
      sleep 0.05
      continue
    fi
    # Dead (or missing) owner: reclaim only this EXACT stale generation via
    # compare-and-swap, so a peer that raced in a live owner between our
    # check above and now is never clobbered.
    owner="$(agmsg_runtime_lock_acquire "$resource" "$$" "${owner:-0}" 2>/dev/null || true)"
    if [ "$owner" = "$$" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.05
  done
  echo "agmsg: timed out acquiring pending lock for pending_id=$pending_id" >&2
  return 1
}

_remote_pending_lock_release() {
  agmsg_runtime_lock_release "$(_remote_pending_runtime_resource "$1")" "$$"
}

cmd_pending_abort() {
  local pending_id="${1:?Usage: remote.sh pending abort <pending_id>}"
  _remote_validate_pending_id "$pending_id" || {
    echo "agmsg: invalid pending_id (expected a 64-character lowercase hex sha256 digest)" >&2
    exit 1
  }
  local pending_file
  pending_file="$(_remote_pending_file "$pending_id")"

  _remote_pending_lock_acquire "$pending_id" || exit 1
  if [ ! -f "$pending_file" ]; then
    _remote_pending_lock_release "$pending_id"
    echo "agmsg: no pending connect record for pending_id=$pending_id (already aborted, already committed, quarantined, or never existed)" >&2
    exit 1
  fi
  rm -f "$pending_file"
  _remote_pending_lock_release "$pending_id"
  echo "Aborted pending connect record $pending_id."
}

cmd_pending() {
  local sub="${1:?Usage: remote.sh pending <list|abort> ...}"
  shift
  case "$sub" in
    list) cmd_pending_list "$@" ;;
    abort) cmd_pending_abort "$@" ;;
    *) echo "Usage: remote.sh pending <list|abort> ..." >&2; exit 1 ;;
  esac
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
  local caps_escaped
  caps_escaped=$(printf '%s' "$capabilities_json" | sed "s/'/''/g")
  # <escaped>/<caps_escaped> are spliced as genuine SQL string literals below,
  # NOT bound via `.param set` (same tokenizer caveat as
  # `_remote_read_config_field` above) — capabilities_json in particular
  # comes straight from the server's exchange response, so it is exactly
  # the kind of value that could legitimately contain a quote.
  updated=$(agmsg_sqlite_mem \
    "SELECT json_set('$escaped', '\$.remote_binding', json_object(
       'endpoint', '$(_agmsg_sqlesc "$endpoint")',
       'credential_id', '$(_agmsg_sqlesc "$credential_id")',
       'server_instance_id', '$(_agmsg_sqlesc "$server_instance_id")',
       'remote_team_id', '$(_agmsg_sqlesc "$remote_team_id")',
       'remote_team_name', '$(_agmsg_sqlesc "$remote_team_name")',
       'protocol_version', $protocol_version,
       'capabilities', json('$caps_escaped'),
       'connected_at', '$(_agmsg_sqlesc "$connected_at")',
       'disconnected_at', null
     ));")
  agmsg_write_atomic "$cfg" "$updated"
}

# Extract one field from a JSON document held in a variable. The file-based
# reader above cannot be used: this document is the engine's stdout, and
# writing it out just to read it back would put a team snapshot on disk for no
# reason.
_remote_json_field() {
  local doc="$1" path="$2" escaped
  escaped=$(printf '%s' "$doc" | sed "s/'/''/g")
  agmsg_sqlite_mem "SELECT COALESCE(json_extract('$escaped', '$path'), '');"
}

# Writes the local team for a pull. Unlike _remote_ensure_team this does NOT
# mint a team_id: the id came from the server and is recorded as it arrived.
# Minting here would give one team two identities, which is the whole reason
# ids exist.
#
# The roster is deliberately left empty. The server does not hold one -- team
# membership travels inside the envelope, so under e2ee it cannot -- and a
# roster taken from anywhere else at this moment would be a guess presented as
# fact. It is derived by replaying the team journal.
_remote_write_pulled_team() {
  local team="$1" team_id="$2" cfg initial
  cfg="$(_remote_team_config "$team")"
  mkdir -p "$TEAMS_DIR/$team"
  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 1
  initial=$(agmsg_sqlite_mem "
    SELECT json_object('name','$(_agmsg_sqlesc "$team")',
                       'team_id','$(_agmsg_sqlesc "$team_id")',
                       'agents', json_object(),
                       'created_at','$(date -u +%Y-%m-%dT%H:%M:%SZ)');")
  agmsg_write_atomic "$cfg" "$initial"
  agmsg_lock_release
}

# The other half of connect: this machine takes a team it does not have.
cmd_pull() {
  local endpoint="" team_id="" team="" positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --endpoint) endpoint="${2:?--endpoint requires a value}"; shift 2 ;;
      --endpoint=*) endpoint="${1#--endpoint=}"; shift ;;
      --team-id) team_id="${2:?--team-id requires a value}"; shift 2 ;;
      --team-id=*) team_id="${1#--team-id=}"; shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  : "${endpoint:?Usage: remote.sh pull --endpoint <url> --team-id <uuid> <team>}"
  : "${team_id:?Usage: remote.sh pull --endpoint <url> --team-id <uuid> <team>}"
  _remote_validate_endpoint "$endpoint" || exit 1
  endpoint="${endpoint%/}"
  team="${positional[0]:-}"
  [ -n "$team" ] || { echo "agmsg: pull requires a local team name" >&2; exit 1; }
  agmsg_validate_team_name "$team" || exit 1

  # Refused for the reason git refuses a non-fast-forward push: two teams that
  # each grew their own history do not become one by pointing at the same
  # remote. A second machine arrives empty and clones.
  local cfg existing
  cfg="$(_remote_team_config "$team")"
  if [ -f "$cfg" ]; then
    existing="$(agmsg_sqlite "$(agmsg_db_path "$team")" \
      "SELECT COUNT(*) FROM events WHERE type='message_sent';" 2>/dev/null | tr -d '\r')"
    case "$existing" in ''|*[!0-9]*) existing=0 ;; esac
    if [ "$existing" -gt 0 ]; then
      echo "agmsg: local team '$team' already has history; pull clones into an empty team" >&2
      exit 1
    fi
  fi

  local result pulled_id pulled_name imported
  result="$(AGMSG_SYNC_CONNECTION_DIR="$CONNECTION_ROOT" \
    "$SCRIPT_DIR/remote-sync.sh" pull-bootstrap \
      --team "$team" --team-id "$team_id" --endpoint "$endpoint")" || {
    echo "agmsg: pull failed" >&2; exit 1; }
  result="$(printf '%s\n' "$result" | grep '"pull_bootstrap_result"' | tail -1)"
  [ -n "$result" ] || { echo "agmsg: pull produced no result" >&2; exit 1; }

  pulled_id="$(_remote_json_field "$result" '$.team_id')"
  pulled_name="$(_remote_json_field "$result" '$.team_name')"
  imported="$(_remote_json_field "$result" '$.imported')"
  [ "$pulled_id" = "$team_id" ] || {
    echo "agmsg: server answered with a different team id" >&2; exit 1; }

  _remote_write_pulled_team "$team" "$pulled_id" || exit 1
  echo "Pulled '$pulled_name' into local team '$team' ($imported message(s))."
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

  # Claim this exact pending_id for the rest of this invocation (ADR 0007
  # addendum) — covers every exit path below (both the resume branch and
  # the fresh-exchange branch, through commit-or-fail) whether or not this
  # process explicitly releases it: the runtime lock is crash-safe by
  # design (see `_remote_pending_lock_acquire`'s comment), so a crash here
  # just leaves a reclaimable dead-owner row for the next attempt. Explicit
  # release is added at the normal exit points further down purely for
  # promptness. Serializes only against `pending abort <pending_key>` and
  # another `connect` for this exact (endpoint, token) — unrelated pending
  # records never contend for this lock.
  _remote_pending_lock_acquire "$pending_key" || exit 1

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
    local pending_load_status=0 quarantine_reason quarantine_path
    if pending_endpoint="$(_remote_load_pending "$pending_file" "$pending_resp_file")"; then
      :
    else
      pending_load_status=$?
      rm -f "$pending_resp_file"
      if [ "$pending_load_status" -eq 42 ]; then
        quarantine_reason="unverified"
        echo "agmsg: refusing to resume a legacy pending exchange without a verified protocol header." >&2
      else
        quarantine_reason="invalid"
        echo "agmsg: refusing to resume a malformed pending exchange record." >&2
      fi
      if quarantine_path="$(_remote_quarantine_pending "$pending_file" "$quarantine_reason")"; then
        echo "agmsg: preserved the 0600 recovery record at $quarantine_path. Do not share it; use the server admin credential list/revoke workflow before issuing a fresh pairing token." >&2
      else
        echo "agmsg: could not quarantine the recovery record; it remains at $pending_file. Do not delete or share it." >&2
      fi
      exit 1
    fi
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
        local old_endpoint old_server_instance_id old_remote_team_id old_credential
        old_endpoint="$(_remote_read_config_field "$(_remote_team_config "$team")" '$.remote_binding.endpoint')"
        old_server_instance_id="$(_remote_read_config_field "$(_remote_team_config "$team")" '$.remote_binding.server_instance_id')"
        old_remote_team_id="$(_remote_read_config_field "$(_remote_team_config "$team")" '$.remote_binding.remote_team_id')"
        old_credential="$(python3 -c "import json,sys; print(json.load(open('$(_remote_cred_file "$team")')).get('credential',''))" 2>/dev/null || true)"
        if [ -z "$existing_credential_id" ] || [ "$existing_credential_id" = "null" ] \
          || [ -z "$old_endpoint" ] || [ "$old_endpoint" = "null" ] || [ -z "$old_credential" ] \
          || [ -z "$old_server_instance_id" ] || [ "$old_server_instance_id" = "null" ] \
          || [ -z "$old_remote_team_id" ] || [ "$old_remote_team_id" = "null" ] \
          || ! _remote_revoke "$old_endpoint" "$old_server_instance_id" "$old_remote_team_id" \
            "$existing_credential_id" "$old_credential"; then
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
    local body_file resp_file header_file http_code token_json
    body_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-connect-body.XXXXXX")"
    chmod 600 "$body_file"
    resp_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-connect-resp.XXXXXX")"
    chmod 600 "$resp_file"
    header_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-connect-header.XXXXXX")"
    chmod 600 "$header_file"
    trap 'rm -f "$body_file" "$resp_file" "$header_file"' EXIT INT TERM

    token_json="$(printf '%s' "$token" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)"
    unset token
    if [ -z "$token_json" ]; then
      echo "agmsg: internal error encoding token" >&2
      exit 1
    fi
    printf '{"token":%s}' "$token_json" > "$body_file"
    unset token_json

    http_code="$(_remote_http_post_json "$endpoint/v1/pairing/exchange" \
      "$body_file" "$resp_file" "$header_file")"
    rm -f "$body_file"

    if [ "$http_code" != "200" ]; then
      echo "agmsg: connect failed — exchange endpoint returned HTTP $http_code" >&2
      rm -f "$resp_file"
      exit 1
    fi
    if ! python3 "$SCRIPT_DIR/internal/validate-protocol-header.py" < "$header_file"; then
      rm -f "$resp_file" "$header_file"
      exit 1
    fi
    rm -f "$header_file"

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
    # Done with this pending_id — release promptly (not required for
    # correctness: a crash here just leaves a reclaimable dead-owner row
    # for the next attempt, see _remote_pending_lock_acquire's comment).
    _remote_pending_lock_release "$pending_key"
  else
    agmsg_lock_release
    _remote_pending_lock_release "$pending_key"
    echo "agmsg: team '$team' has a different, unexpected binding than expected — the credential just issued for it was NOT committed locally. Revoke it (credential_id=$credential_id) via the console/admin side if it should not remain active, then retry." >&2
    exit 1
  fi
  unset credential

  # E2EE insertion point: only when the capability response
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
      # Wording condition from maintainer sign-off on this default-removal
      # (B3): a first-time user must be able to tell, at a glance, that
      # (g) is the one for them — not just be warned that (g) *might* be
      # risky. State the recommendation directly, then immediately follow
      # it with the honest caveat (empty history is a strong hint, not
      # proof) so the choice stays deliberate rather than becoming a new
      # rubber-stamped default.
      local seq_hint=""
      if [ "$current_seq" = "0" ]; then
        seq_hint=" This team has no message history yet — if you are the one setting it up for the first time, that's exactly when you choose (g). (Empty history is a strong hint, not proof: if you know someone else already has a key for this team, choose (i) instead.)"
      fi

      echo "This team requires end-to-end encryption. No key found for this device.${seq_hint}"
      echo "  (g) Generate a new key — ONLY if you are certain you are the first person connecting this team"
      echo "  (i) Import a key you already have — do this if a teammate gave you one, or if unsure"
      echo "  (a) Abort — don't connect yet"
      local choice
      _remote_prompt_read choice "[i/g/a] (default: a): " || choice=""
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
          _remote_prompt_read identity "Paste identity: " 1 || identity=""
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

# _remote_status_json_one <team> — prints one JSONL object for <team>'s
# binding, or returns 1 (no output) if the team has never been connected,
# matching _remote_status_one's own gate exactly (same "never connected"
# definition for both surfaces).
#
# Strict, machine-consumed ABI (ADR 0007 addendum): a cloud/self-hosted
# driver correlates this against its own operation-status record to decide
# whether a given connect attempt is the one that actually committed, or a
# stale retry against an already-superseded binding — so the field set and
# "null on unknown" contract are load-bearing, not just a debugging aid.
# credential_id/server_instance_id/remote_team_id are opaque ids, never the
# credential itself — this stays exactly as secret-free as the human-text
# status output above.
#
# Reads config.json exactly ONCE (co1 delta review, ported from
# feat/remote-connect-onboarding) — six independent
# `_remote_read_config_field` calls would each independently re-open the
# file from disk; a concurrent disconnect/reconnect/force-rebind's atomic
# rename could swap in a new version in between any two of those six reads,
# so the assembled object could mix fields from two different on-disk
# versions that never actually coexisted at any instant — a real defect for
# a strict ABI another process correlates fields against (unlike the
# human-text status path above, which is read for a person to glance at and
# where this same multi-read shape is only cosmetically stale, not a spec
# violation). Also acquired under the team's own write lock, so the single
# read can't land mid-write either. All fields are derived from that one
# in-memory snapshot by a single python parse — not hand-rolled string
# concatenation, since this is a strict schema a driver parses and a value
# containing a quote/backslash must not silently produce malformed JSON the
# way E3's hand-rolled credential escaping once did.
_remote_status_json_one() {
  local team="$1" cfg raw
  cfg="$(_remote_team_config "$team")"
  [ -f "$cfg" ] || return 1

  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 1
  raw="$(cat "$cfg" 2>/dev/null)"
  agmsg_lock_release

  printf '%s' "$raw" | python3 -c '
import json, sys
team = sys.argv[1]
try:
    cfg = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)
if not isinstance(cfg, dict):
    sys.exit(1)
binding = cfg.get("remote_binding")
if not isinstance(binding, dict) or not binding.get("connected_at"):
    sys.exit(1)
state = "disconnected" if binding.get("disconnected_at") else "active"
print(json.dumps({
    "local_team": team,
    "endpoint": binding.get("endpoint"),
    "server_instance_id": binding.get("server_instance_id"),
    "remote_team_id": binding.get("remote_team_id"),
    "credential_id": binding.get("credential_id"),
    "state": state,
}, sort_keys=True))
' "$team"
}

cmd_status() {
  local team="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      *) team="$1"; shift ;;
    esac
  done

  if [ -n "$team" ]; then
    agmsg_validate_team_name "$team" || exit 1
    if [ "$json" -eq 1 ]; then
      _remote_status_json_one "$team" || { echo "agmsg: team '$team' has never been connected" >&2; exit 1; }
    else
      _remote_status_one "$team" || { echo "agmsg: team '$team' has never been connected" >&2; exit 1; }
    fi
    return
  fi

  local any=0 t
  if [ ! -d "$TEAMS_DIR" ]; then
    [ "$json" -eq 1 ] || echo "No teams found."
    return
  fi
  for t in "$TEAMS_DIR"/*/; do
    [ -d "$t" ] || continue
    t="$(basename "$t")"
    if [ "$json" -eq 1 ]; then
      if _remote_status_json_one "$t"; then
        any=1
      fi
    else
      if _remote_status_one "$t"; then
        any=1
      fi
    fi
  done
  if [ "$any" -ne 1 ] && [ "$json" -ne 1 ]; then
    echo "No teams are connected."
  fi
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

  local cred_file endpoint server_instance_id remote_team_id credential_id credential
  cred_file="$(_remote_cred_file "$team")"
  endpoint="$(_remote_read_config_field "$cfg" '$.remote_binding.endpoint')"
  server_instance_id="$(_remote_read_config_field "$cfg" '$.remote_binding.server_instance_id')"
  remote_team_id="$(_remote_read_config_field "$cfg" '$.remote_binding.remote_team_id')"
  credential_id="$(_remote_read_config_field "$cfg" '$.remote_binding.credential_id')"

  # Server-side revoke first, local cleanup always — local deletion alone
  # does not stop the credential from continuing to authenticate
  # server-side (remote-connect lifecycle).
  local revoke_ok=0
  if [ -f "$cred_file" ] && [ -n "$endpoint" ] && [ "$endpoint" != "null" ] && [ -n "$credential_id" ] && [ "$credential_id" != "null" ]; then
    credential="$(python3 -c "import json,sys; print(json.load(open('$cred_file')).get('credential',''))" 2>/dev/null)"
    if [ -n "$credential" ] && [ -n "$server_instance_id" ] && [ "$server_instance_id" != "null" ] \
      && [ -n "$remote_team_id" ] && [ "$remote_team_id" != "null" ] \
      && _remote_revoke "$endpoint" "$server_instance_id" "$remote_team_id" \
        "$credential_id" "$credential"; then
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
  connect) shift; agmsg_require_python3 "remote connect" || exit 1; cmd_connect "$@" ;;
  pull) shift; agmsg_require_python3 "remote pull" || exit 1; cmd_pull "$@" ;;
  status) shift; agmsg_require_python3 "remote status" || exit 1; cmd_status "$@" ;;
  disconnect) shift; agmsg_require_python3 "remote disconnect" || exit 1; cmd_disconnect "$@" ;;
  doctor) shift; cmd_doctor "$@" ;;
  pending) shift; agmsg_require_python3 "remote pending" || exit 1; cmd_pending "$@" ;;
  *)
    echo "Usage: remote.sh <connect|status|disconnect|doctor|pending> ..." >&2
    exit 1 ;;
esac
