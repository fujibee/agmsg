#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   remote.sh connect --endpoint <url> <team>
#   remote.sh pull --endpoint <url> [--team-id <uuid>] <team>
#   remote.sh status [<team>] [--json]
#   remote.sh disconnect <team>
#
# Team-scoped cloud/self-hosted sync connection. The OSS CLI never assumes or
# defaults to a server, so <endpoint> is always required. `connect` registers a
# local team directly; reaching the server is the permission. `pull` clones a
# remote team into an empty local team. Both start the background sync engine.

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
# For _agmsg_pid_alive — the one piece of watch.sh's daemon plumbing that is
# already a shared, reusable helper. The rest of the sync engine's lifecycle
# (below) is written here rather than shared, because watch.sh's is inline and
# keyed on watcher-only concepts (session/actas) this engine does not have.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/instance-id.sh"

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
  # age is optional, and the wording has to say so. Remote sync defaults to
  # cipher "none"; end-to-end encryption is a capability, not a prerequisite.
  # Reporting its absence as a failure told every new user they were unfit for
  # a feature they had not asked for -- and, because it set failed=1, doctor
  # exited non-zero on a machine where everything actually required was present.
  #
  # python3 and node below stay required: without them the remote control plane
  # and data plane do not run at all. The three are not interchangeable and are
  # deliberately not reported the same way.
  if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
    echo "  [x] age / age-keygen on PATH  (optional)"
  else
    echo "  [ ] age / age-keygen on PATH  (optional)"
    echo
    echo "'age' enables end-to-end encryption. Remote sync works without it: teams"
    echo "default to cipher \"none\", where the server stores blobs it does not read"
    echo "but which are not encrypted end to end. Install it only if you want E2EE:"
    echo "  macOS (Homebrew):      brew install age"
    echo "  Debian/Ubuntu:         sudo apt install age"
    echo "  Windows (winget):      winget install FiloSottile.age"
    echo "See https://github.com/FiloSottile/age for other install methods."
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
  local team="$1" team_id="$2" cfg initial existing_id
  cfg="$(_remote_team_config "$team")"
  mkdir -p "$TEAMS_DIR/$team"
  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 1
  if [ -f "$cfg" ]; then
    existing_id="$(_remote_read_config_field "$cfg" '$.team_id')"
    if [ "$existing_id" != "$team_id" ]; then
      echo "agmsg: local team '$team' has a different team id" >&2
      agmsg_lock_release
      return 1
    fi
  else
    initial=$(agmsg_sqlite_mem "
      SELECT json_object('name','$(_agmsg_sqlesc "$team")',
                         'team_id','$(_agmsg_sqlesc "$team_id")',
                         'agents', json_object(),
                         'created_at','$(date -u +%Y-%m-%dT%H:%M:%SZ)');")
    agmsg_write_atomic "$cfg" "$initial"
  fi
  agmsg_lock_release
}

# Resolve a team name to one team_id, or explain why it cannot be resolved.
#
# A name is not unique on the server -- only team_id is -- so the answer is a
# list. One entry settles it. Several is not bad data: it is a question only the
# operator can answer, so the candidates are printed with what tells them apart
# and --team-id is offered.
_remote_resolve_team_id() {
  local endpoint="$1" name="$2" out status result count doc
  # The engine's exit status is read on its own rather than through a pipeline,
  # so a server that is unreachable and a server whose answer failed validation
  # stay distinguishable from a name that simply matched nothing. Collapsing
  # those into one message is how a rejected answer would get read as "no such
  # team" -- the wrong conclusion to hand an operator about their own team.
  out="$("$SCRIPT_DIR/remote-sync.sh" resolve-team \
    --endpoint "$endpoint" --name "$name" 2>/dev/null)"
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "agmsg: could not look up '$name': the server was unreachable, or its answer was rejected" >&2
    return 1
  fi
  result="$(printf '%s\n' "$out" | grep '"team_lookup_result"' | tail -1)" || true
  [ -n "$result" ] || { echo "agmsg: the server did not answer the lookup for '$name'" >&2; return 1; }

  doc="$(printf '%s' "$result" | sed "s/'/''/g")"
  count="$(agmsg_sqlite_mem "SELECT json_array_length(json_extract('$doc', '\$.teams'));")"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac

  if [ "$count" -eq 0 ]; then
    echo "agmsg: no team named '$name' on this server" >&2
    return 1
  fi
  if [ "$count" -eq 1 ]; then
    agmsg_sqlite_mem "SELECT json_extract('$doc', '\$.teams[0].team_id');"
    return 0
  fi

  {
    echo "agmsg: $count teams are named '$name' on this server:"
    agmsg_sqlite_mem "
      SELECT '  ' || json_extract(value, '\$.team_id') ||
             '   registered ' || substr(json_extract(value, '\$.registered_at'), 1, 10) ||
             '   ' || json_extract(value, '\$.current_seq') || ' messages'
        FROM json_each('$doc', '\$.teams');"
    echo "re-run with --team-id <one of the above>"
  } >&2
  return 1
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
  : "${endpoint:?Usage: remote.sh pull --endpoint <url> [--team-id <uuid>] <team>}"
  _remote_validate_endpoint "$endpoint" || exit 1
  endpoint="${endpoint%/}"
  team="${positional[0]:-}"
  [ -n "$team" ] || { echo "agmsg: pull requires a local team name" >&2; exit 1; }
  agmsg_validate_team_name "$team" || exit 1

  # The name is normally enough. A team_id had to be carried between machines by
  # hand only because it stood in for authentication, and this server has none
  # to stand in for. --team-id remains for the case a name cannot settle -- two
  # teams sharing it -- and for anyone who scripted the old form.
  if [ -z "$team_id" ]; then
    team_id="$(_remote_resolve_team_id "$endpoint" "$team")" || exit 1
  fi

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

  # The roster driver projects imported identity events into this config while
  # the bootstrap is running. Publish the empty identity-bearing shell first;
  # retries reuse it, and the successful projection is never overwritten.
  _remote_write_pulled_team "$team" "$team_id" || exit 1

  local result pulled_id pulled_name imported pulled_sid pulled_protocol pulled_caps
  result="$(AGMSG_SYNC_CONNECTION_DIR="$CONNECTION_ROOT" \
    AGMSG_SYNC_LOCAL_ROSTER_FILE="$cfg" \
    "$SCRIPT_DIR/remote-sync.sh" pull-bootstrap \
      --team "$team" --team-id "$team_id" --endpoint "$endpoint")" || {
    echo "agmsg: pull failed" >&2; exit 1; }
  result="$(printf '%s\n' "$result" | grep '"pull_bootstrap_result"' | tail -1)"
  [ -n "$result" ] || { echo "agmsg: pull produced no result" >&2; exit 1; }

  pulled_id="$(_remote_json_field "$result" '$.team_id')"
  pulled_name="$(_remote_json_field "$result" '$.team_name')"
  imported="$(_remote_json_field "$result" '$.imported')"
  pulled_sid="$(_remote_json_field "$result" '$.server_instance_id')"
  pulled_protocol="$(_remote_json_field "$result" '$.protocol_version')"
  pulled_caps="$(_remote_json_field "$result" '$.capabilities')"
  [ "$pulled_id" = "$team_id" ] || {
    echo "agmsg: server answered with a different team id" >&2; exit 1; }

  # Bind AFTER the bootstrap, and by updating the config in place: the roster
  # driver has been projecting identity events into this file while the
  # bootstrap ran, so rewriting it wholesale would discard the roster it just
  # built. The binding is what lets the sync engine keep this team in sync
  # afterwards ("Machine two ... and continues", docs/design/remote-sync.md).
  case "$pulled_protocol" in ''|*[!0-9]*)
    echo "agmsg: server answered with an invalid protocol version" >&2; exit 1 ;; esac
  agmsg_lock_acquire "$TEAMS_DIR/$team" || exit 1
  local bind_at escaped caps_escaped updated
  bind_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  escaped=$(sed "s/'/''/g" "$cfg")
  caps_escaped=$(printf '%s' "$pulled_caps" | sed "s/'/''/g")
  updated=$(agmsg_sqlite_mem \
    "SELECT json_set('$escaped', '\$.remote_binding', json_object(
       'endpoint', '$(_agmsg_sqlesc "$endpoint")',
       'server_instance_id', '$(_agmsg_sqlesc "$pulled_sid")',
       'remote_team_id', '$(_agmsg_sqlesc "$pulled_id")',
       'remote_team_name', '$(_agmsg_sqlesc "$pulled_name")',
       'protocol_version', $pulled_protocol,
       'capabilities', json('$caps_escaped'),
       'connected_at', '$bind_at',
       'disconnected_at', null));")
  agmsg_write_atomic "$cfg" "$updated"
  agmsg_lock_release

  # "Machine two runs the same three in reverse: it registers, pulls the team
  # down, and continues" (docs/design/remote-sync.md). Continuing IS the engine:
  # without it a send on this machine reports success, stays local, and nothing
  # says this team has an upstream it never reached. Found by the first real
  # second machine, whose pulled team answered "connected" while running nothing.
  _remote_sync_engine_start "$team"

  local cmd_name
  cmd_name="$(basename "$SKILL_DIR")"
  echo "Pulled '$pulled_name' into local team '$team' ($imported message(s)). Sync engine running."
  echo "This team is now local and ready for normal use."
  echo "Open your agent and invoke its installed '$cmd_name' command, then join with a new agent name."
}

# The remote-sync engine runs as a background daemon: one per connected team,
# polling to push new local messages and pull remote ones. Its lifecycle mirrors
# watch.sh's FORM without sharing its code (see the instance-id.sh source note):
# one pidfile per unit under the connection's run dir, SIGTERM to stop, and
# _agmsg_pid_alive to tell a live engine from a stale pidfile. This leaves the
# pidfile lifecycle in two places (here and watch.sh); factoring it into a shared
# lib is intentionally deferred, not overlooked.
_remote_sync_engine_pidfile() { printf '%s' "$CONNECTION_ROOT/run/remote-sync.$1.pid"; }

_remote_sync_engine_start() {
  local team="$1" pidfile logfile old_pid
  pidfile="$(_remote_sync_engine_pidfile "$team")"
  logfile="$CONNECTION_ROOT/run/remote-sync.$team.log"
  mkdir -p "$CONNECTION_ROOT/run" 2>/dev/null || true
  # Stop a previous engine for this team before claiming the slot; a stale
  # pidfile (its process already gone) is simply overwritten. _agmsg_pid_alive
  # guards against a recycled pid pointing at an unrelated process.
  if [ -f "$pidfile" ]; then
    old_pid="$(cat "$pidfile" 2>/dev/null || true)"
    [ -n "$old_pid" ] && _agmsg_pid_alive "$old_pid" && kill "$old_pid" 2>/dev/null || true
  fi
  # nohup so the engine outlives this connect; remote-sync.sh execs node, so $!
  # stays the engine's own pid and is exactly what _remote_sync_engine_stop signals.
  # fds 3 and 4 are closed explicitly: under bats, fd 3 is the TAP pipe, and a
  # daemon inheriting it keeps the whole test file open until the CI timeout —
  # the last-ok-then-orphan hang this repo has met before, this time spawned by
  # production code rather than a test.
  nohup bash "$SCRIPT_DIR/remote-sync.sh" run --team "$team" >> "$logfile" 2>&1 3>&- 4>&- &
  echo $! > "$pidfile"
  disown 2>/dev/null || true
}

_remote_sync_engine_stop() {
  local team="$1" pidfile pid
  pidfile="$(_remote_sync_engine_pidfile "$team")"
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  [ -n "$pid" ] && _agmsg_pid_alive "$pid" && kill "$pid" 2>/dev/null || true
  rm -f "$pidfile"
}

# Upgrade a team that predates local ids: mint a team_id AND a member_id for
# every current member, in one shot, then persist. connect is the point an old
# team first needs ids, and the invariant is all-or-none — a team carries ids
# for every member or for none — so this never leaves a half-id-holding roster.
_remote_mint_team_ids() {
  local team="$1" cfg="$2" cfg_json escaped names name mid
  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 1
  cfg_json="$(cat "$cfg")"
  escaped="$(printf '%s' "$cfg_json" | sed "s/'/''/g")"
  names="$(agmsg_sqlite_mem "SELECT key FROM json_each(json_extract('$escaped', '\$.agents'));")"
  cfg_json="$(agmsg_sqlite_mem "SELECT json_set('$escaped', '\$.team_id', '$(compat_uuid7)');")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    mid="$(compat_uuid7)"
    escaped="$(printf '%s' "$cfg_json" | sed "s/'/''/g")"
    # A quoted path key ("name") lets a member name carry characters a bare
    # path token could not; the whole statement is a single-quoted SQL literal.
    cfg_json="$(agmsg_sqlite_mem "SELECT json_set('$escaped', '\$.agents.\"$(printf '%s' "$name" | sed "s/'/''/g")\".member_id', '$mid');")"
  done <<EOF_MINT_NAMES
$names
EOF_MINT_NAMES
  agmsg_write_atomic "$cfg" "$cfg_json"
  agmsg_lock_release
}

cmd_connect() {
  # Register a team you already own with a remote, then move it to its own
  # store and start syncing. No token, no credential: reaching the server is
  # the permission (docs/design/remote-sync.md). The team_id and every
  # member_id were minted locally at team creation; the server records what it
  # is sent and never originates a team.
  local endpoint="" team="" positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --endpoint) endpoint="${2:?--endpoint requires a value}"; shift 2 ;;
      --endpoint=*) endpoint="${1#--endpoint=}"; shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  : "${endpoint:?Usage: remote.sh connect --endpoint <url> <team>}"
  _remote_validate_endpoint "$endpoint" || exit 1
  endpoint="${endpoint%/}"
  team="${positional[0]:-}"
  [ -n "$team" ] || { echo "agmsg: connect requires a team: remote.sh connect --endpoint <url> <team>" >&2; exit 1; }

  local cfg team_id team_name
  cfg="$(_remote_team_config "$team")"
  [ -f "$cfg" ] || { echo "agmsg: team '$team' is not a local team" >&2; exit 1; }
  team_id="$(_remote_read_config_field "$cfg" '$.team_id')"
  team_name="$(_remote_read_config_field "$cfg" '$.name')"
  case "$team_id" in
    ''|null)
      # A team that predates local ids: mint them now (connect is the point it
      # first needs them), for the whole roster at once, then re-read.
      _remote_mint_team_ids "$team" "$cfg" || {
        echo "agmsg: could not mint local ids for team '$team'" >&2; exit 1; }
      team_id="$(_remote_read_config_field "$cfg" '$.team_id')"
      ;;
  esac

  # The body: the team's id and name, plus the roster from .agents — each
  # agent's key is its name and its minted member_id comes with it.
  local cfg_escaped body_file resp_file header_file http_code
  cfg_escaped="$(sed "s/'/''/g" "$cfg")"
  body_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-connect-body.XXXXXX")"
  resp_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-connect-resp.XXXXXX")"
  header_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-connect-hdr.XXXXXX")"
  # Guard each name with ${var:-}: this trap also fires on the script's own EXIT,
  # by which point these function-locals are out of scope and a bare reference
  # would abort under `set -u`.
  trap 'rm -f "${body_file:-}" "${resp_file:-}" "${header_file:-}"' EXIT INT TERM

  agmsg_sqlite_mem "SELECT json_object(
      'team_id', json_extract('$cfg_escaped', '\$.team_id'),
      'team_name', json_extract('$cfg_escaped', '\$.name'),
      'members', coalesce(
        (SELECT json_group_array(json_object(
            'member_id', json_extract(value, '\$.member_id'),
            'name', key))
           FROM json_each(json_extract('$cfg_escaped', '\$.agents'))),
        json('[]'))
    );" > "$body_file"

  echo "Connecting team '$team' to $endpoint ..." >&2
  http_code="$(_remote_http_post_json "$endpoint/v1/connect" "$body_file" "$resp_file" "$header_file")"
  if [ "$http_code" = "409" ]; then
    echo "agmsg: team '$team' (team_id $team_id) is already registered on this remote. A team_id registers once — this is a uniqueness conflict (like a non-fast-forward push), not a transient error to retry." >&2
    exit 1
  fi
  if [ "$http_code" != "200" ]; then
    echo "agmsg: connect failed — $endpoint/v1/connect returned HTTP $http_code" >&2
    exit 1
  fi

  # The response is the server's capability snapshot: server_instance_id,
  # protocol_version, the team ids it now holds, min_available_seq, and the
  # write policy. The whole object is the binding's capabilities record.
  local resp_escaped server_instance_id remote_team_id remote_team_name \
    protocol_version min_available_seq
  resp_escaped="$(sed "s/'/''/g" "$resp_file")"
  {
    IFS= read -r server_instance_id
    IFS= read -r remote_team_id
    IFS= read -r remote_team_name
    IFS= read -r protocol_version
    IFS= read -r min_available_seq
  } < <(agmsg_sqlite_mem \
      "SELECT json_extract('$resp_escaped', '\$.server_instance_id');
       SELECT json_extract('$resp_escaped', '\$.team_id');
       SELECT json_extract('$resp_escaped', '\$.team_name');
       SELECT json_extract('$resp_escaped', '\$.protocol_version');
       SELECT json_extract('$resp_escaped', '\$.min_available_seq');")

  # Record the binding on the team config. No credential is stored: the
  # response holds nothing that cannot be re-fetched by connecting again, and
  # the team_id is a value we minted ourselves.
  local connected_at updated
  connected_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  updated=$(agmsg_sqlite_mem \
    "SELECT json_set('$cfg_escaped', '\$.remote_binding', json_object(
       'endpoint', '$(_agmsg_sqlesc "$endpoint")',
       'server_instance_id', '$(_agmsg_sqlesc "$server_instance_id")',
       'remote_team_id', '$(_agmsg_sqlesc "$remote_team_id")',
       'remote_team_name', '$(_agmsg_sqlesc "$remote_team_name")',
       'protocol_version', $protocol_version,
       'capabilities', json('$resp_escaped'),
       'connected_at', '$(_agmsg_sqlesc "$connected_at")',
       'disconnected_at', null
     ));")
  agmsg_write_atomic "$cfg" "$updated"

  # Move the team out of the shared store into its own before the engine runs:
  # a connected team's rows carry ids, and one column cannot hold both those and
  # a local team's names. The copy is verified and the shared rows are dropped
  # only after — see migrate-team-store.sh. Teams that never connect are left in
  # the shared store untouched.
  bash "$SCRIPT_DIR/internal/migrate-team-store.sh" "$team" || {
    echo "agmsg: connect recorded the binding but the per-team store migration failed — see 'remote status $team'." >&2
    exit 1
  }

  # Start the polling engine in the background: it pushes what we have, pulls
  # anything already there, and keeps running so new messages flow both ways as
  # they are written. Stop it with 'remote.sh disconnect <team>'.
  _remote_sync_engine_start "$team"

  echo "Connected: team '$team'${remote_team_name:+ (org '$remote_team_name')}. Sync engine running."
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

  # Stop the background sync engine first: leaving it polling a team we are
  # tearing the binding off of would just error every cycle.
  _remote_sync_engine_stop "$team"

  local cred_file endpoint server_instance_id remote_team_id credential_id credential
  cred_file="$(_remote_cred_file "$team")"
  endpoint="$(_remote_read_config_field "$cfg" '$.remote_binding.endpoint')"
  server_instance_id="$(_remote_read_config_field "$cfg" '$.remote_binding.server_instance_id')"
  remote_team_id="$(_remote_read_config_field "$cfg" '$.remote_binding.remote_team_id')"
  credential_id="$(_remote_read_config_field "$cfg" '$.remote_binding.credential_id')"

  # Server-side revoke first, local cleanup always — local deletion alone
  # does not stop the credential from continuing to authenticate
  # server-side (remote-connect lifecycle).
  local revoke_required=0 revoke_ok=0
  if [ -f "$cred_file" ] ||
      { [ -n "$credential_id" ] && [ "$credential_id" != "null" ]; }; then
    revoke_required=1
  fi
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

  if [ "$revoke_required" -eq 1 ]; then
    if [ "$revoke_ok" -eq 1 ]; then
      echo "Revoking credential with server... ok."
    else
      echo "Revoking credential with server... failed."
      echo "Local state cleared, but the server could not be reached to revoke this credential — if this device may be compromised, revoke it from the console/admin side directly." >&2
    fi
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
    echo "Usage: remote.sh <connect|pull|status|disconnect|doctor|pending> ..." >&2
    exit 1 ;;
esac
