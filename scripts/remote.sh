#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   remote.sh connect --endpoint <url> [--e2ee] <team>
#   remote.sh pull --endpoint <url> [--team-id <uuid>] <team>
#   remote.sh unlock <team> --bundle <file> --confirm-digest <sha256>
#   remote.sh unlock <team> --snapshot <file> (--identity <file>|--identity-stdin)
#     [--confirm-digest <sha256>]
#   remote.sh unlock <team> --authenticated-bundle-stdin
#     Read the exact bundle bytes from stdin after the invoking program has
#     authenticated them end to end. remote.sh does not authenticate this input.
#     Use only with an authenticator that verifies integrity and binds the
#     expected team/context. This mode replaces, and must not be combined with,
#     --bundle or --confirm-digest.
#
#     This is not a bypass of the digest check: it switches the authentication
#     authority from a live human digest comparison to an upstream AEAD verifier.
#     remote.sh cannot prove that verifier ran, and does not pretend to — that
#     limit is the caller's contract, not a hidden assumption. Reserved for the
#     disaster-recovery route (see docs/remote-disaster-recovery.md); ordinary
#     onboarding and the courier `fetch` path use --bundle/--confirm-digest.
#   remote.sh status [<team>] [--json]
#   remote.sh sync start <team>
#   remote.sh disconnect <team>
#   remote.sh forget [--yes] <team>
#
# Team-scoped cloud/self-hosted sync connection. The OSS CLI never assumes or
# defaults to a server, so <endpoint> is always required. `connect` registers a
# local team directly; reaching the server is the permission. `pull` clones a
# remote team into an empty local team. An encrypted pull remains locked until
# `unlock` confirms the handed authority and starts the background sync engine.

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
# shellcheck source=lib/shquote.sh
source "$SCRIPT_DIR/lib/shquote.sh"
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

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }

_remote_team_config() { printf '%s' "$TEAMS_DIR/$1/config.json"; }
_remote_sync_config_file() {
  local encoded
  encoded="$(python3 -c \
    "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=\"-_.!~*'()\"))" \
    "$1")"
  printf '%s/remote-sync/%s.json' "$(agmsg_storage_dir)" "$encoded"
}

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

# An endpoint, safe to print. Keeps the scheme, host and port; DROPS everything
# else, and the list of what it drops is the point of this function:
#
#   path      — a hosted endpoint is `https://host/t/<token>`, and that token IS
#               the capability. Anyone who reads it off a terminal, a screen
#               share or a pasted log can connect as this team.
#   userinfo  — `scheme://user:pass@host` puts a credential before the host, so
#               a "host and port only" rule that forgets it prints the password.
#   query, fragment — no current endpoint carries either, and that is exactly
#               why they would be missed when one does.
#
# The caller keeps the team name in the message. That is what makes host-only
# enough to identify the destination: a team has one endpoint, so `team 'X' to
# host:port` names it exactly without naming the secret.
_remote_endpoint_display() {
  local url="$1" scheme rest
  case "$url" in
    *://*) scheme="${url%%://*}://"; rest="${url#*://}" ;;
    *) scheme=""; rest="$url" ;;
  esac
  # Cut the path/query/fragment FIRST. Doing userinfo first would let an `@`
  # inside a path decide where the host ends.
  rest="${rest%%/*}"; rest="${rest%%\?*}"; rest="${rest%%#*}"
  rest="${rest##*@}"
  printf '%s%s' "$scheme" "$rest"
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
    echo "'python3' is required for the remote control plane (connect/pull/status/disconnect/forget) and was not found on this device. Install it, then retry:"
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
  # Reaped on both normal paths below (waited on success, killed and waited on
  # failure), so this is short-lived by construction -- but the EXIT trap only
  # removes files, it does not kill the copier. A signal arriving before curl
  # opens the fifo therefore leaves it blocked on open() with no writer ever
  # coming, and an inherited fd 3 would then hold a bats test file open to the
  # timeout. Closing the fds costs nothing and removes that one path.
  python3 "$SCRIPT_DIR/internal/bounded-copy.py" 65536 < "$header_fifo" > "$header_file" 3>&- 4>&- &
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

# _remote_http_get_json <url> <team_id> <out_body_file> -> prints http_code
# The team-scoped read routes take their team from the Agmsg-Team-ID header.
# Nothing else is sent, because there is nothing else to send: this protocol
# carries no credential at all (see cmd_connect).
_remote_http_get_json() {
  local url="$1" team_id="$2" out_file="$3" cfg curl_output curl_status=0
  cfg="$(mktemp "${TMPDIR:-/tmp}/agmsg-curl-cfg.XXXXXX")"
  chmod 600 "$cfg"
  trap 'rm -f "$cfg"' EXIT INT TERM
  {
    printf 'url = "%s"\n' "$url"
    printf 'request = "GET"\n'
    printf 'header = "Agmsg-Protocol-Version: 1"\n'
    printf 'header = "Agmsg-Team-ID: %s"\n' "$team_id"
    printf 'connect-timeout = "10"\n'
    printf 'max-time = "15"\n'
    printf 'max-filesize = "2097152"\n'
  } > "$cfg"
  if curl_output=$(curl -sS -o "$out_file" -w '%{http_code}' -K "$cfg" 2>/dev/null); then
    :
  else
    curl_status=$?
  fi
  [ "$curl_status" -eq 0 ] || curl_output="000"
  rm -f "$cfg"
  trap - EXIT INT TERM
  printf '%s' "$curl_output"
}

# _remote_write_binding <cfg> <endpoint> <binding_cipher> <resp_file>
# Records the binding on the team config from a capability snapshot. No
# credential is stored: the snapshot holds nothing that cannot be fetched
# again, and the team_id is a value we minted ourselves.
#
# ONE writer for both the first connect and the adopt path below. Two copies of
# this object would drift, and the second copy is the one nobody re-reads.
_remote_write_binding() {
  local cfg="$1" endpoint="$2" binding_cipher="$3" resp_file="$4"
  local resp_escaped cfg_escaped connected_at updated \
    server_instance_id remote_team_id remote_team_name protocol_version
  resp_escaped="$(sed "s/'/''/g" "$resp_file")"
  {
    IFS= read -r server_instance_id
    IFS= read -r remote_team_id
    IFS= read -r remote_team_name
    IFS= read -r protocol_version
  } < <(agmsg_sqlite_mem \
      "SELECT json_extract('$resp_escaped', '\$.server_instance_id');
       SELECT json_extract('$resp_escaped', '\$.team_id');
       SELECT json_extract('$resp_escaped', '\$.team_name');
       SELECT json_extract('$resp_escaped', '\$.protocol_version');")
  connected_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  agmsg_lock_acquire "$(dirname "$cfg")" || return 1
  cfg_escaped="$(sed "s/'/''/g" "$cfg")"
  updated=$(agmsg_sqlite_mem \
    "SELECT json_set('$cfg_escaped', '\$.remote_binding', json_object(
       'endpoint', '$(_agmsg_sqlesc "$endpoint")',
       'server_instance_id', '$(_agmsg_sqlesc "$server_instance_id")',
       'remote_team_id', '$(_agmsg_sqlesc "$remote_team_id")',
       'remote_team_name', '$(_agmsg_sqlesc "$remote_team_name")',
       'protocol_version', $protocol_version,
       'cipher_profile', '$binding_cipher',
       'capabilities', json('$resp_escaped'),
       'connected_at', '$(_agmsg_sqlesc "$connected_at")',
       'disconnected_at', null,
       'binding_revision',
         coalesce(json_extract('$cfg_escaped', '\$.remote_binding.binding_revision'), 0) + 1
     ));")
  agmsg_write_atomic "$cfg" "$updated"
  agmsg_lock_release
}

# _remote_adopt_registration <team> <cfg> <endpoint> <team_id> <binding_cipher>
#
# Takes over a registration this server already holds for <team_id> and writes
# the binding for it, so connect continues from the step that still has work
# instead of stopping. Two callers, one situation: a retry that already holds a
# binding, and a first attempt whose POST committed but whose response never
# arrived. In both, the REMOTE side is complete — /v1/connect commits the team,
# its opening policy and the whole roster in one transaction — and only local,
# derived state is missing. There is nothing to roll back on either side.
#
# Deliberately absent, and not an oversight: a route that REMOVES a
# registration. This protocol carries no credential — reaching the server is
# the permission, and the trust boundary is the network it sits on. A delete
# route would let anyone who can reach the server destroy a team's registration
# with nothing but a team_id, which is strictly worse than the dead end it
# would be removing. The reason /v1/connect refuses to WRITE to a team that
# already exists is the same reason it must not offer to delete one.
#
# Returns 0 when the binding was written, 1 when the registration is not ours
# or the server could not be read.
# <expected_server_instance> is the server_instance_id the caller already has
# recorded, or empty when it has none. When given it must match EXACTLY: the
# endpoint is an address, not an identity, and the same address can come back
# as a different server. Without the comparison a rebuilt (or substituted)
# server holding a team with the same id, name and roster would have its own
# instance id written over ours, silently re-anchoring the binding. Empty is
# for the path that has nothing to compare -- a POST whose response was lost
# leaves no recorded id, and there the first fetch IS the anchor.
_remote_adopt_registration() {
  local team="$1" cfg="$2" endpoint="$3" team_id="$4" binding_cipher="$5" \
    expected_server_instance="${6:-}"
  local caps_file members_file http_code remote_team_name local_team_name \
    local_ids remote_ids cfg_escaped members_escaped \
    fetched_server_instance declared_cipher
  caps_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-caps.XXXXXX")"
  members_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-members.XXXXXX")"
  trap 'rm -f "$caps_file" "$members_file"' EXIT INT TERM

  http_code="$(_remote_http_get_json "$endpoint/v1/capabilities" "$team_id" "$caps_file")"
  if [ "$http_code" != "200" ]; then
    echo "agmsg: '$(_remote_endpoint_display "$endpoint")' holds a registration for team '$team' but its capabilities could not be read (HTTP $http_code); cannot confirm the registration is this team's." >&2
    rm -f "$caps_file" "$members_file"; trap - EXIT INT TERM
    return 1
  fi

  # Same server, not just the same address. Checked FIRST: if this is not the
  # server the binding was made against, nothing else it says about the team
  # means anything.
  fetched_server_instance="$(_remote_read_config_field "$caps_file" '$.server_instance_id')"
  if [ -n "$expected_server_instance" ] \
    && [ "$expected_server_instance" != "$fetched_server_instance" ]; then
    echo "agmsg: '$(_remote_endpoint_display "$endpoint")' is now server instance $fetched_server_instance, but team '$team' is bound to $expected_server_instance. Refusing to re-anchor the binding to a different server. If the server really was replaced, disconnect and connect again deliberately." >&2
    rm -f "$caps_file" "$members_file"; trap - EXIT INT TERM
    return 1
  fi

  # Confirm the registration is OURS before adopting it. team_id is minted
  # locally, so a server holding it is almost certainly holding our own earlier
  # attempt -- but "almost certainly" is not something to write a binding on.
  # The name is the cheap check; the roster is the one that means it, because
  # every member_id was minted on this machine too.
  remote_team_name="$(_remote_read_config_field "$caps_file" '$.team_name')"
  local_team_name="$(_remote_read_config_field "$cfg" '$.name')"
  if [ "$remote_team_name" != "$local_team_name" ]; then
    echo "agmsg: '$(_remote_endpoint_display "$endpoint")' already has team_id $team_id, but registered under the name '$remote_team_name' while this team is '$local_team_name'. Refusing to adopt a registration that is not this team's." >&2
    rm -f "$caps_file" "$members_file"; trap - EXIT INT TERM
    return 1
  fi

  http_code="$(_remote_http_get_json "$endpoint/v1/members" "$team_id" "$members_file")"
  if [ "$http_code" != "200" ]; then
    echo "agmsg: '$(_remote_endpoint_display "$endpoint")' holds a registration for team '$team' but its roster could not be read (HTTP $http_code); cannot confirm the registration is this team's." >&2
    rm -f "$caps_file" "$members_file"; trap - EXIT INT TERM
    return 1
  fi
  cfg_escaped="$(sed "s/'/''/g" "$cfg")"
  members_escaped="$(sed "s/'/''/g" "$members_file")"
  local_ids="$(agmsg_sqlite_mem \
    "SELECT coalesce(group_concat(mid, ','), '') FROM
       (SELECT json_extract(value, '\$.member_id') AS mid
          FROM json_each(json_extract('$cfg_escaped', '\$.agents')) ORDER BY mid);")"
  remote_ids="$(agmsg_sqlite_mem \
    "SELECT coalesce(group_concat(mid, ','), '') FROM
       (SELECT json_extract(value, '\$.member_id') AS mid
          FROM json_each(json_extract('$members_escaped', '\$.members')) ORDER BY mid);")"
  if [ "$local_ids" != "$remote_ids" ]; then
    echo "agmsg: '$(_remote_endpoint_display "$endpoint")' already has team_id $team_id, but its roster is not this team's. Refusing to adopt it. This is a real conflict, not a half-finished connect — resolve it before connecting this team here." >&2
    rm -f "$caps_file" "$members_file"; trap - EXIT INT TERM
    return 1
  fi

  # The cipher profile of an existing registration is the DECLARATION already
  # on the server, and this invocation's --e2ee (or its absence) does not get
  # to restate it. Writing the requested mode here would let a plain re-run of
  # `connect` record 'none' locally for a team registered as age-v1 -- a
  # downgrade written by a retry, in the direction that matters.
  #
  # `null` is a real answer, distinct from 'none': nobody has declared yet.
  # Only then does this machine's request stand.
  declared_cipher="$(_remote_read_config_field "$caps_file" '$.cipher_profile')"
  case "$declared_cipher" in
    ''|null) ;;
    "$binding_cipher") ;;
    *)
      # Name the change to make, not the profile: connect takes no profile
      # argument -- age-v1 is --e2ee and none is its absence -- so "re-run for
      # age-v1" would be an instruction with no command behind it.
      #
      # The endpoint is deliberately NOT reproduced here. It can carry a
      # capability, and this line exists to be read off a terminal and acted
      # on; printing a runnable command would mean printing the secret in it.
      # So the instruction names the flag and the team, and refers to the
      # endpoint the caller already has rather than echoing it back.
      #
      # The team IS spliced in, so it goes through agmsg_shq: a team name may
      # legally contain a single quote (lib/validate.sh rejects only empty /
      # . / .. / slashes / a leading dash / control characters), and a bare
      # '...' would close early and leave the rest as syntax for whatever
      # shell this gets pasted into.
      local recovery
      case "$declared_cipher" in
        age-v1) recovery="re-run the same connect for $(agmsg_shq "$team") with --e2ee added" ;;
        none)   recovery="re-run the same connect for $(agmsg_shq "$team") without --e2ee" ;;
        *)      recovery="" ;;
      esac
      if [ -n "$recovery" ]; then
        echo "agmsg: team '$team' is registered on $(_remote_endpoint_display "$endpoint") as '$declared_cipher', but this connect asked for '$binding_cipher'. Refusing to record a profile the registration does not have. To connect it the way it is registered, $recovery." >&2
      else
        echo "agmsg: team '$team' is registered on $(_remote_endpoint_display "$endpoint") as '$declared_cipher', which this version does not know how to connect as (it understands 'none' and 'age-v1'). Refusing to record a profile the registration does not have." >&2
      fi
      rm -f "$caps_file" "$members_file"; trap - EXIT INT TERM
      return 1
      ;;
  esac

  echo "Team '$team' is already registered on $(_remote_endpoint_display "$endpoint"); adopting that registration and continuing." >&2
  _remote_write_binding "$cfg" "$endpoint" "$binding_cipher" "$caps_file" || {
    rm -f "$caps_file" "$members_file"; trap - EXIT INT TERM
    return 1
  }
  rm -f "$caps_file" "$members_file"
  trap - EXIT INT TERM
  return 0
}

# _remote_local_disconnect <team> <cfg> [expected_binding_revision]
# Marks the binding disconnected. That is now the whole of it: there is no
# credential to delete and nothing to revoke, so this writes disconnected_at
# and bumps the revision, under the team lock.
#
# When <expected_binding_revision> is given, the comparison and the write happen
# under ONE lock acquisition, and the write only lands if the binding is still
# the generation the caller decided to disconnect. Without that, a concurrent
# reconnect between the caller's read and this lock would have its own, newer
# binding marked disconnected by a call that never touched it.
#
# The guard used to compare credential_id. That stopped meaning anything when
# connect stopped issuing credentials -- the expected value was always empty, so
# the comparison never ran -- while still reading like a live check.
# binding_revision is what every binding has and every write bumps.
#
# Returns 0 on success, 1 on lock failure, 2 if the revision no longer matches
# (the caller must treat that as "someone else changed this team's binding —
# abort, don't proceed").
_remote_local_disconnect() {
  local team="$1" cfg="$2" expected_binding_revision="${3:-}" \
    escaped updated disconnected_at current_binding_revision
  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 1
  if [ -n "$expected_binding_revision" ] && [ "$expected_binding_revision" != "null" ]; then
    current_binding_revision="$(_remote_read_config_field "$cfg" '$.remote_binding.binding_revision')"
    if [ "$current_binding_revision" != "$expected_binding_revision" ]; then
      agmsg_lock_release
      return 2
    fi
  fi
  disconnected_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  escaped=$(sed "s/'/''/g" "$cfg")
  # <escaped> is spliced as a genuine SQL string literal, NOT bound via
  # `.param set` (same tokenizer caveat as `_remote_read_config_field` above).
  updated=$(agmsg_sqlite_mem \
    "SELECT json_set('$escaped',
       '\$.remote_binding.disconnected_at', '$(_agmsg_sqlesc "$disconnected_at")',
       '\$.remote_binding.binding_revision',
         coalesce(json_extract('$escaped', '\$.remote_binding.binding_revision'), 0) + 1);")
  agmsg_write_atomic "$cfg" "$updated"
  agmsg_lock_release
}

# --- connect -------------------------------------------------------------















# Extract one field from a JSON document held in a variable. The file-based
# reader above cannot be used: this document is the engine's stdout, and
# writing it out just to read it back would put a team snapshot on disk for no
# reason.
_remote_json_field() {
  local doc="$1" path="$2" escaped
  escaped=$(printf '%s' "$doc" | sed "s/'/''/g")
  agmsg_sqlite_mem "SELECT COALESCE(json_extract('$escaped', '$path'), '');"
}

_remote_json_array_length() {
  local doc="$1" path="$2" escaped
  escaped=$(printf '%s' "$doc" | sed "s/'/''/g")
  agmsg_sqlite_mem "SELECT COALESCE(json_array_length(json_extract('$escaped', '$path')), 0);"
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
                         'drivers', json_object('partition', 'per-team'),
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

  local result pulled_id pulled_name imported pulled_sid pulled_protocol pulled_caps \
    pulled_age_v1 pulled_cipher binding_cipher
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
  pulled_age_v1="$(_remote_json_field "$result" '$.age_v1_envelopes')"
  [ "$pulled_id" = "$team_id" ] || {
    echo "agmsg: server answered with a different team id" >&2; exit 1; }
  case "$pulled_age_v1" in ''|*[!0-9]*)
    echo "agmsg: pull returned an invalid encrypted-envelope count" >&2; exit 1 ;; esac

  # The team's cipher is a DECLARED fact, taken from the server's snapshot —
  # not inferred from how many encrypted envelopes this pull happened to carry.
  # The old inference read a team with no messages yet as unencrypted, wrote
  # 'none' into the binding, and `unlock` then refused a team that was in fact
  # sealed. Counting arrivals answers "what has been sent", never "what this
  # team uses".
  #
  # An empty answer means no machine has declared it (a team connected before
  # the declaration was carried). That is recorded as unknown rather than
  # collapsed into 'none': the two are different facts, and only one of them is
  # safe to act on.
  pulled_cipher="$(_remote_json_field "$result" '$.capabilities.cipher_profile')"
  case "$pulled_cipher" in
    age-v1|none) binding_cipher="$pulled_cipher" ;;
    ''|null)     binding_cipher="unknown" ;;
    *) echo "agmsg: server declared an unsupported cipher profile" >&2; exit 1 ;;
  esac

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
       'cipher_profile', '$binding_cipher',
       'capabilities', json('$caps_escaped'),
       'connected_at', '$bind_at',
       'disconnected_at', null,
       'binding_revision',
         coalesce(json_extract('$escaped', '\$.remote_binding.binding_revision'), 0) + 1));")
  agmsg_write_atomic "$cfg" "$updated"
  agmsg_lock_release

  # "Machine two runs the same three in reverse: it registers, pulls the team
  # down, and continues" (docs/design/remote-sync.md). Continuing IS the engine:
  # without it a send on this machine reports success, stays local, and nothing
  # says this team has an upstream it never reached. Found by the first real
  # second machine, whose pulled team answered "connected" while running nothing.
  local cmd_name
  cmd_name="$(basename "$SKILL_DIR")"
  if [ "$pulled_age_v1" -gt 0 ]; then
    echo "Pulled '$pulled_name' into local team '$team' ($imported message(s))."
    echo "This team is encrypted; its sync engine is halted until the handed key material is imported and confirmed."
  else
    _remote_sync_engine_start "$team"
    echo "Pulled '$pulled_name' into local team '$team' ($imported message(s)). Sync engine running."
  fi
  if [ "$pulled_age_v1" -gt 0 ]; then
    # Print something that can be typed. `remote.sh` is not on PATH and never
    # has been: it lives in this install's scripts directory, whose name is
    # whatever the install was given -- which is why the sibling branch below
    # already goes through $cmd_name. The old line named a bare script the
    # shell cannot find, and named only --bundle, while --bundle without
    # --confirm-digest is refused a few lines into unlock. Both halves have to
    # be right, or this is a dead end with extra steps.
    echo "This team is local but locked. Unlock it with the secret handoff bundle you were given:"
    echo "  bash $(agmsg_shq "$SKILL_DIR/scripts/remote.sh") unlock $(agmsg_shq "$team") --bundle <file> --confirm-digest <sha256>"
  else
    echo "This team is now local and ready for normal use."
    echo "Open your agent and invoke its installed '$cmd_name' command, then join with a new agent name."
  fi
}

cmd_unlock() {
  local team="" identity_file="" identity_stdin=0 confirm_digest="" bundle="" \
    authenticated_stdin=0 snapshots=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --snapshot) snapshots+=("${2:?--snapshot requires a value}"); shift 2 ;;
      --snapshot=*) snapshots+=("${1#--snapshot=}"); shift ;;
      --bundle) bundle="${2:?--bundle requires a value}"; shift 2 ;;
      --bundle=*) bundle="${1#--bundle=}"; shift ;;
      --authenticated-bundle-stdin) authenticated_stdin=1; shift ;;
      --identity) identity_file="${2:?--identity requires a value}"; shift 2 ;;
      --identity=*) identity_file="${1#--identity=}"; shift ;;
      --identity-stdin) identity_stdin=1; shift ;;
      --confirm-digest) confirm_digest="${2:?--confirm-digest requires a value}"; shift 2 ;;
      --confirm-digest=*) confirm_digest="${1#--confirm-digest=}"; shift ;;
      --*) echo "agmsg: unknown unlock option: $1" >&2; exit 1 ;;
      *) [ -z "$team" ] || { echo "agmsg: unlock accepts one team" >&2; exit 1; }
         team="$1"; shift ;;
    esac
  done
  : "${team:?Usage: remote.sh unlock <team> (--bundle <file> --confirm-digest <sha256> | --authenticated-bundle-stdin | --snapshot <file> (--identity <file>|--identity-stdin)) }"
  agmsg_validate_team_name "$team" || exit 1
  if [ "$authenticated_stdin" -eq 1 ]; then
    # This mode REPLACES the digest gate rather than relaxing it, so it cannot
    # sit alongside another input mode: two authorities disagreeing about which
    # bytes were authenticated is worse than either alone. Fail closed.
    if [ -n "$bundle" ] || [ -n "$confirm_digest" ] || [ "${#snapshots[@]}" -gt 0 ] ||
        [ -n "$identity_file" ] || [ "$identity_stdin" -eq 1 ]; then
      echo "agmsg: --authenticated-bundle-stdin replaces --bundle/--confirm-digest and cannot be combined with them, --snapshot, or --identity" >&2
      exit 1
    fi
  elif [ -n "$bundle" ]; then
    if [ "${#snapshots[@]}" -gt 0 ] || [ -n "$identity_file" ] || [ "$identity_stdin" -eq 1 ]; then
      echo "agmsg: --bundle cannot be combined with --snapshot or --identity" >&2
      exit 1
    fi
    [ -n "$confirm_digest" ] || {
      echo "agmsg: --bundle requires --confirm-digest <sha256> verified over a separate live channel" >&2
      exit 1
    }
  else
    [ "${#snapshots[@]}" -gt 0 ] || { echo "agmsg: --snapshot or --bundle is required" >&2; exit 1; }
    if { [ -n "$identity_file" ] && [ "$identity_stdin" -eq 1 ]; } ||
        { [ -z "$identity_file" ] && [ "$identity_stdin" -eq 0 ]; }; then
      echo "agmsg: unlock requires exactly one of --identity <file> or --identity-stdin" >&2
      exit 1
    fi
  fi

  local cfg binding_cipher metadata digest epoch_revision key_id recipient
  cfg="$(_remote_team_config "$team")"
  [ -f "$cfg" ] || { echo "agmsg: team not found: $team" >&2; exit 1; }
  binding_cipher="$(_remote_read_config_field "$cfg" '$.remote_binding.cipher_profile')"
  # "Unknown" is a distinct answer from "not encrypted", and it has a distinct
  # remedy, so it gets its own message. Refusing with the plain-team wording
  # would send someone looking for a mistake they did not make: their team may
  # well be sealed — nobody has told this server which.
  if [ "$binding_cipher" = "unknown" ]; then
    cat >&2 <<EOF
agmsg: the encryption setting for '$team' is not known to the server, so this
machine cannot tell a sealed history from an empty one and will not guess.

The team was connected before that setting was carried. It is recorded the next
time the machine that already has '$team' sends to it — one ordinary message is
enough:

    send.sh $team <an-agent-there> <another-agent> "hello"

Then pull '$team' here again and run this unlock.
EOF
    exit 1
  fi
  [ "$binding_cipher" = "age-v1" ] || {
    echo "agmsg: team '$team' is not an encrypted pulled team awaiting unlock" >&2
    exit 1
  }
  local snapshot_args=() identity_args=() snapshot handoff_tmp="" handoff_metadata=""
  if [ "$authenticated_stdin" -eq 1 ]; then
    handoff_tmp="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-handoff.XXXXXX")"
    chmod 700 "$handoff_tmp"
    trap 'rm -r "${handoff_tmp:-}" 2>/dev/null || true' EXIT INT TERM HUP
    bundle="$handoff_tmp/authenticated.bundle"
    # Capture the caller's bytes ONCE, into a directory only this process can
    # reach. That is the whole reason this mode takes stdin and not a path: the
    # caller authenticated a specific sequence of bytes, and re-opening a path it
    # named would let anything with write access substitute different bytes
    # between that authentication and this import. A filename is not the bytes.
    # umask rather than a chmod afterwards: `cat >` creates the file with the
    # caller's umask, and a chmod on the next line leaves a window where the
    # secret is already on disk at whatever mode that was. Setting it in a
    # subshell around the redirection means the file is never briefly wider.
    ( umask 077; cat > "$bundle" )
    [ -s "$bundle" ] || {
      echo "agmsg: --authenticated-bundle-stdin received no bundle bytes on stdin" >&2
      exit 1
    }
  fi
  if [ -n "$bundle" ]; then
    if [ -z "$handoff_tmp" ]; then
      handoff_tmp="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-handoff.XXXXXX")"
      chmod 700 "$handoff_tmp"
      trap 'rm -r "${handoff_tmp:-}" 2>/dev/null || true' EXIT INT TERM HUP
    fi
    handoff_metadata="$(bash "$SCRIPT_DIR/remote-sync.sh" verify-age-handoff \
      --team "$team" --bundle "$bundle" --out-dir "$handoff_tmp")" || exit 1
    local snapshot_count identity_count index mapped_key mapped_path
    snapshot_count="$(_remote_json_array_length "$handoff_metadata" '$.snapshot_paths')"
    identity_count="$(_remote_json_array_length "$handoff_metadata" '$.identities')"
    index=0
    while [ "$index" -lt "$snapshot_count" ]; do
      snapshots+=("$(_remote_json_field "$handoff_metadata" "\$.snapshot_paths[$index]")")
      index=$((index + 1))
    done
    index=0
    while [ "$index" -lt "$identity_count" ]; do
      mapped_key="$(_remote_json_field "$handoff_metadata" "\$.identities[$index].key_id")"
      mapped_path="$(_remote_json_field "$handoff_metadata" "\$.identities[$index].path")"
      identity_args+=("$mapped_key=$mapped_path")
      index=$((index + 1))
    done
  fi
  for snapshot in "${snapshots[@]}"; do snapshot_args+=(--age-snapshot "$snapshot"); done
  metadata="$(bash "$SCRIPT_DIR/remote-sync.sh" verify-age-snapshot \
    --team "$team" "${snapshot_args[@]}")" || exit 1
  metadata="$(printf '%s\n' "$metadata" | grep '"age_snapshot_verified"' | tail -1)"
  [ -n "$metadata" ] || { echo "agmsg: snapshot verification produced no result" >&2; exit 1; }
  digest="$(_remote_json_field "$metadata" '$.snapshot_sha256')"
  epoch_revision="$(_remote_json_field "$metadata" '$.epoch_revision')"
  key_id="$(_remote_json_field "$metadata" '$.key_id')"
  recipient="$(_remote_json_field "$metadata" '$.recipient')"
  echo "Snapshot SHA-256: $digest"
  echo "Snapshot key_id: $key_id"

  if [ -n "$bundle" ]; then
    local bundle_digest
    bundle_digest="$(_remote_json_field "$handoff_metadata" '$.snapshot_sha256')"
    [ "$bundle_digest" = "$digest" ] || {
      echo "agmsg: handoff bundle verification disagrees with the snapshot chain" >&2
      exit 1
    }
  fi

  # The live-channel comparison is the ordinary authority over "are these the
  # bytes the other side sent". --authenticated-bundle-stdin substitutes a
  # different authority for it — an authenticator the invoking program already
  # verified over exactly these bytes — so the two are alternatives, never a
  # sequence where one can be skipped. Every other path still goes through the
  # gate unchanged.
  if [ "$authenticated_stdin" -ne 1 ]; then
    if [ -z "$confirm_digest" ]; then
      if [ "$identity_stdin" -eq 1 ] && { [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; }; then
        echo "agmsg: --identity-stdin without a terminal also requires --confirm-digest <sha256>" >&2
        exit 1
      fi
      _remote_prompt_read confirm_digest \
        "Type the snapshot SHA-256 you verified over a separate live channel: " || exit 1
    fi
    if [ "$confirm_digest" != "$digest" ]; then
      echo "agmsg: confirmed snapshot digest does not match; refusing to import trust or key material" >&2
      exit 1
    fi
  fi

  local identity_tmp="" derived_recipient identity_dest mapping mapping_key mapping_path
  if [ -n "$bundle" ]; then
    local configured_identity_args=()
    for mapping in "${identity_args[@]}"; do
      mapping_key="${mapping%%=*}"
      mapping_path="${mapping#*=}"
      grep '^AGE-SECRET-KEY-' "$mapping_path" |
        bash "$SCRIPT_DIR/key.sh" import "$team" --key-id "$mapping_key" \
          --identity-stdin || exit 1
      identity_dest="$CONNECTION_ROOT/run/remote-credentials/$team/keys/$mapping_key.key"
      configured_identity_args+=(--age-identity "$mapping_key=$identity_dest")
    done
  else
    identity_tmp="$(mktemp "${TMPDIR:-/tmp}/agmsg-unlock-identity.XXXXXX")"
    chmod 600 "$identity_tmp"
    trap 'rm -f "${identity_tmp:-}"; [ -z "${handoff_tmp:-}" ] || rm -r "$handoff_tmp" 2>/dev/null || true' EXIT INT TERM HUP
    if [ "$identity_stdin" -eq 1 ]; then
      cat > "$identity_tmp"
    else
      cat "$identity_file" > "$identity_tmp"
    fi
    derived_recipient="$(age-keygen -y "$identity_tmp" 2>/dev/null)" || {
      echo "agmsg: handed identity is not a valid age identity" >&2
      exit 1
    }
    if [ "$derived_recipient" != "$recipient" ]; then
      echo "agmsg: handed identity does not match the authority-confirmed snapshot" >&2
      exit 1
    fi
    grep '^AGE-SECRET-KEY-' "$identity_tmp" |
      bash "$SCRIPT_DIR/key.sh" import "$team" --key-id "$key_id" \
        --identity-stdin || exit 1
    identity_dest="$CONNECTION_ROOT/run/remote-credentials/$team/keys/$key_id.key"
    configured_identity_args=(--age-identity "$key_id=$identity_dest")
    rm -f "$identity_tmp"
    identity_tmp=""
  fi

  local endpoint remote_team_id configure_out reprocess_out reprocess_result imported blocking
  endpoint="$(_remote_read_config_field "$cfg" '$.remote_binding.endpoint')"
  remote_team_id="$(_remote_read_config_field "$cfg" '$.remote_binding.remote_team_id')"
  configure_out="$(bash "$SCRIPT_DIR/remote-sync.sh" configure \
    --team "$team" \
    --server "$endpoint" \
    --team-id "$remote_team_id" \
    --minimum-security e2ee-required \
    --cipher age-v1 \
    "${snapshot_args[@]}" \
    --age-checkpoint "$epoch_revision:$digest" \
    --age-confirmation operator-live \
    "${configured_identity_args[@]}")" || exit 1
  [ -n "$configure_out" ] && printf '%s\n' "$configure_out"
  reprocess_out="$(bash "$SCRIPT_DIR/remote-sync.sh" reprocess --team "$team")" || exit 1
  reprocess_result="$(printf '%s\n' "$reprocess_out" |
    grep '"event":"reprocess.complete"' | tail -1)"
  [ -n "$reprocess_result" ] || {
    echo "agmsg: reprocess produced no completion result" >&2
    exit 1
  }
  imported="$(_remote_json_field "$reprocess_result" '$.imported_count')"
  blocking="$(_remote_json_field "$reprocess_result" '$.blocking_remaining')"
  if [ "$blocking" != "0" ]; then
    echo "agmsg: encrypted envelopes remain blocked after reprocessing; no sync engine was started" >&2
    exit 1
  fi

  _remote_sync_engine_stop "$team" || {
    echo "agmsg: the previous sync engine did not stop; unlock cannot safely restart it" >&2
    exit 1
  }
  local engine_log="$CONNECTION_ROOT/run/remote-sync.$team.log" log_offset=1
  [ -f "$engine_log" ] &&
    log_offset=$(( $(wc -c < "$engine_log" | tr -d ' ') + 1 ))
  _remote_sync_engine_start "$team"
  local pid="${REMOTE_SYNC_ENGINE_PID:-}" ready=0 attempts=0
  while [ "$attempts" -lt 50 ]; do
    if [ -z "$pid" ] || ! _agmsg_pid_alive "$pid"; then
      break
    fi
    if tail -c "+$log_offset" "$engine_log" 2>/dev/null |
        grep -q '"event":"capabilities"'; then
      ready=1
      break
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  local pidfile="$(_remote_sync_engine_pidfile "$team")" recorded_pid=""
  [ -f "$pidfile" ] && recorded_pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ "$ready" -ne 1 ] || [ "$recorded_pid" != "$pid" ] ||
      ! _agmsg_pid_alive "$pid"; then
    _remote_sync_engine_stop "$team"
    echo "agmsg: encrypted sync was configured, but the sync engine did not become ready" >&2
    exit 1
  fi
  echo "Unlocked '$team': imported $imported envelope(s); engine running (pid $pid)."
  echo "This team is now local and ready for normal use."
  [ -z "$handoff_tmp" ] || rm -r "$handoff_tmp"
  trap - EXIT INT TERM HUP
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
  local team="$1" startup_nonce="${2:-}" pidfile logfile old_pid old_state
  pidfile="$(_remote_sync_engine_pidfile "$team")"
  logfile="$CONNECTION_ROOT/run/remote-sync.$team.log"
  mkdir -p "$CONNECTION_ROOT/run" 2>/dev/null || true
  # Stop only an engine whose argv proves that it owns this team. A stale
  # pidfile may point at a recycled, unrelated process and must never authorize
  # signalling that process.
  IFS=$'\t' read -r old_state old_pid < <(_remote_sync_engine_status "$team")
  if [ "$old_state" = "running" ]; then
    kill "$old_pid" 2>/dev/null || true
  fi
  # nohup so the engine outlives this connect; remote-sync.sh execs node, so $!
  # stays the engine's own pid and is exactly what _remote_sync_engine_stop signals.
  # fds 3 and 4 are closed explicitly: under bats, fd 3 is the TAP pipe, and a
  # daemon inheriting it keeps the whole test file open until the CI timeout —
  # the last-ok-then-orphan hang this repo has met before, this time spawned by
  # production code rather than a test.
  AGMSG_SYNC_START_NONCE="$startup_nonce" \
    nohup bash "$SCRIPT_DIR/remote-sync.sh" run --team "$team" >> "$logfile" 2>&1 3>&- 4>&- &
  REMOTE_SYNC_ENGINE_PID=$!
  echo "$REMOTE_SYNC_ENGINE_PID" > "$pidfile"
  disown 2>/dev/null || true
}

_remote_sync_engine_stop() {
  local team="$1" pidfile pid state
  pidfile="$(_remote_sync_engine_pidfile "$team")"
  [ -f "$pidfile" ] || return 0
  IFS=$'\t' read -r state pid < <(_remote_sync_engine_status "$team")
  if [ "$state" = "running" ]; then
    if ! _remote_sync_engine_reap_owned "$team" "$pid"; then
      echo "agmsg: sync engine pid $pid did not stop" >&2
      return 1
    fi
  fi
  rm -f "$pidfile"
}

# Print "<state>\t<pid>", where pid is empty when no valid pid is available.
# A live PID is not enough: PID reuse can make an unrelated process pass
# kill -0, so running requires the exact engine script/team suffix in argv.
_remote_sync_engine_status() {
  local team="$1" pidfile pid command expected
  pidfile="$(_remote_sync_engine_pidfile "$team")"
  if [ ! -f "$pidfile" ]; then
    printf 'stopped\t\n'
    return
  fi
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if ! [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]]; then
    printf 'stale\t\n'
    return
  fi
  if ! _agmsg_pid_alive "$pid"; then
    printf 'stale\t%s\n' "$pid"
    return
  fi
  command="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
  expected="$SCRIPT_DIR/internal/remote-sync.mjs run --team $team"
  case "$command" in
    *"$expected") printf 'running\t%s\n' "$pid" ;;
    *) printf 'stale\t%s\n' "$pid" ;;
  esac
}

_remote_sync_engine_reap_owned() {
  local team="$1" owned_pid="$2" state pid signal attempts
  for signal in TERM KILL; do
    IFS=$'\t' read -r state pid < <(_remote_sync_engine_status "$team")
    if ! _agmsg_pid_alive "$owned_pid"; then return 0; fi
    [ "$state" = "running" ] && [ "$pid" = "$owned_pid" ] || return 1
    kill "-$signal" "$owned_pid" 2>/dev/null || true
    attempts=0
    while [ "$attempts" -lt 100 ]; do
      _agmsg_pid_alive "$owned_pid" || return 0
      attempts=$((attempts + 1))
      sleep 0.01
    done
  done
  ! _agmsg_pid_alive "$owned_pid"
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

_remote_binding_allows_cipher() {
  local cfg="$1" cipher="$2" cfg_escaped
  cfg_escaped="$(sed "s/'/''/g" "$cfg")"
  [ "$(agmsg_sqlite_mem \
    "SELECT EXISTS(
       SELECT 1
         FROM json_each(json_extract('$cfg_escaped',
           '\$.remote_binding.capabilities.write_allowed_ciphers'))
        WHERE value = '$(_agmsg_sqlesc "$cipher")'
     );")" = "1" ]
}

_remote_configure_keyed_team() {
  local team="$1" cfg="$2" key_id endpoint remote_team_id \
    identity_file snapshot_file snapshot_sha
  key_id="$(_remote_read_config_field "$cfg" '$.remote_key.current.key_id')"
  if [ -z "$key_id" ] || [ "$key_id" = "null" ]; then
    return 0
  fi

  if ! _remote_binding_allows_cipher "$cfg" age-v1; then
    echo "agmsg: team '$team' has an encryption key, but this remote does not allow age-v1; refusing to fall back to plaintext." >&2
    return 1
  fi

  endpoint="$(_remote_read_config_field "$cfg" '$.remote_binding.endpoint')"
  remote_team_id="$(_remote_read_config_field "$cfg" '$.remote_binding.remote_team_id')"
  identity_file="$CONNECTION_ROOT/run/remote-credentials/$team/keys/$key_id.key"
  if [ ! -f "$identity_file" ]; then
    echo "agmsg: team '$team' has key_id=$key_id but its local identity file is missing; refusing to start plaintext sync." >&2
    return 1
  fi

  snapshot_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-age-snapshot.XXXXXX")"
  if ! bash "$SCRIPT_DIR/remote-sync.sh" export-age-snapshot \
      --team "$team" --out "$snapshot_file"; then
    rm -f "$snapshot_file"
    echo "agmsg: could not export the initial age-v1 snapshot for team '$team'; sync was not started." >&2
    return 1
  fi
  snapshot_sha="$(shasum -a 256 "$snapshot_file" | awk '{print $1}')"
  if ! bash "$SCRIPT_DIR/remote-sync.sh" configure \
      --team "$team" \
      --server "$endpoint" \
      --team-id "$remote_team_id" \
      --minimum-security e2ee-required \
      --cipher age-v1 \
      --age-snapshot "$snapshot_file" \
      --age-checkpoint "0:$snapshot_sha" \
      --age-confirmation operator-live \
      --age-identity "$key_id=$identity_file"; then
    rm -f "$snapshot_file"
    echo "agmsg: age-v1 setup failed for team '$team'; refusing to start plaintext sync." >&2
    return 1
  fi
  rm -f "$snapshot_file"
}

cmd_connect() {
  # Register a team you already own with a remote, then move it to its own
  # store and start syncing. No token, no credential: reaching the server is
  # the permission (docs/design/remote-sync.md). The team_id and every
  # member_id were minted locally at team creation; the server records what it
  # is sent and never originates a team.
  local endpoint="" team="" e2ee=0 positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --endpoint) endpoint="${2:?--endpoint requires a value}"; shift 2 ;;
      --endpoint=*) endpoint="${1#--endpoint=}"; shift ;;
      --e2ee) e2ee=1; shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  : "${endpoint:?Usage: remote.sh connect --endpoint <url> [--e2ee] <team>}"
  _remote_validate_endpoint "$endpoint" || exit 1
  endpoint="${endpoint%/}"
  team="${positional[0]:-}"
  [ -n "$team" ] || { echo "agmsg: connect requires a team: remote.sh connect --endpoint <url> [--e2ee] <team>" >&2; exit 1; }

  local cfg team_id team_name key_id binding_cipher
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
  key_id="$(_remote_read_config_field "$cfg" '$.remote_key.current.key_id')"
  if [ "$e2ee" -eq 1 ] && { [ -z "$key_id" ] || [ "$key_id" = "null" ]; }; then
    bash "$SCRIPT_DIR/key.sh" generate "$team" || exit 1
    key_id="$(_remote_read_config_field "$cfg" '$.remote_key.current.key_id')"
  elif [ "$e2ee" -eq 0 ] && [ -n "$key_id" ] && [ "$key_id" != "null" ]; then
    echo "Note: this team has a key, but plain sync was selected. The key will not be used; pass --e2ee to seal remote messages." >&2
  fi
  if [ "$e2ee" -eq 1 ]; then
    binding_cipher="age-v1"
  else
    binding_cipher="none"
  fi

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

  # `cipher_profile` is this machine's DECLARATION, decided above from --e2ee —
  # not a guess. Sending it is what lets a second machine be told what the team
  # uses instead of inferring it from how many encrypted messages happen to have
  # arrived, which reads an empty team as an unencrypted one.
  agmsg_sqlite_mem "SELECT json_object(
      'team_id', json_extract('$cfg_escaped', '\$.team_id'),
      'team_name', json_extract('$cfg_escaped', '\$.name'),
      'cipher_profile', '$binding_cipher',
      'members', coalesce(
        (SELECT json_group_array(json_object(
            'member_id', json_extract(value, '\$.member_id'),
            'name', key))
           FROM json_each(json_extract('$cfg_escaped', '\$.agents'))),
        json('[]'))
    );" > "$body_file"

  # A connect that already registered this team here must not register it
  # again. The steps AFTER registration -- key setup, the store move, the
  # engine -- are the ones that fail, and they are all local and all
  # re-derivable, so the way back in is to skip the one step that is already
  # done. Matching on endpoint AND remote_team_id, and requiring a recorded
  # server_instance_id: a binding pointing somewhere else is not this
  # connection's business, and one with no server_instance_id never completed a
  # registration to adopt. The recorded id is not just required to EXIST -- it
  # is handed to the adopt path, which refuses unless the server answering now
  # is the same one. Existence is a precondition; the identity check is there.
  #
  # A DISCONNECTED binding is not a live anchor. disconnect leaves the fields
  # in place and records disconnected_at, and that record is the operator
  # saying they no longer claim this anchor -- so connect must stop holding
  # them to it. Without this, the refusal below would tell them to disconnect
  # and connect again, and the retry would re-enter with the same stale
  # expected id and refuse identically, forever. A refusal has to leave a move
  # that actually works.
  local existing_endpoint existing_remote_team_id existing_server_instance \
    existing_disconnected_at
  existing_endpoint="$(_remote_read_config_field "$cfg" '$.remote_binding.endpoint')"
  existing_remote_team_id="$(_remote_read_config_field "$cfg" '$.remote_binding.remote_team_id')"
  existing_server_instance="$(_remote_read_config_field "$cfg" '$.remote_binding.server_instance_id')"
  existing_disconnected_at="$(_remote_read_config_field "$cfg" '$.remote_binding.disconnected_at')"
  if [ "$existing_endpoint" = "$endpoint" ] \
    && [ "$existing_remote_team_id" = "$team_id" ] \
    && [ -n "$existing_server_instance" ] && [ "$existing_server_instance" != "null" ] \
    && { [ -z "$existing_disconnected_at" ] || [ "$existing_disconnected_at" = "null" ]; }; then
    _remote_adopt_registration "$team" "$cfg" "$endpoint" "$team_id" \
      "$binding_cipher" "$existing_server_instance" || exit 1
  else
    echo "Connecting team '$team' to $(_remote_endpoint_display "$endpoint") ..." >&2
    http_code="$(_remote_http_post_json "$endpoint/v1/connect" "$body_file" "$resp_file" "$header_file")"
    if [ "$http_code" = "409" ]; then
      # The server holds this team_id and we hold no binding for it. That is
      # what a POST which committed but whose response never arrived leaves
      # behind -- the registration is complete, and the only thing missing is
      # our record of it. Rebuild that record instead of stopping: the
      # capability snapshot behind /v1/capabilities is the same object
      # /v1/connect returns on success. _remote_adopt_registration refuses if
      # the team there turns out not to be ours.
      _remote_adopt_registration "$team" "$cfg" "$endpoint" "$team_id" "$binding_cipher" || exit 1
    elif [ "$http_code" != "200" ]; then
      echo "agmsg: connect failed — $(_remote_endpoint_display "$endpoint")/v1/connect returned HTTP $http_code" >&2
      exit 1
    else
      _remote_write_binding "$cfg" "$endpoint" "$binding_cipher" "$resp_file" || exit 1
    fi
  fi

  # Read back what was recorded, rather than what any one path parsed. Both
  # ways in write the binding through _remote_write_binding, so the config is
  # the single place that knows the answer after either.
  local remote_team_name
  remote_team_name="$(_remote_read_config_field "$cfg" '$.remote_binding.remote_team_name')"

  if [ "$e2ee" -eq 0 ] && ! _remote_binding_allows_cipher "$cfg" none; then
    echo "agmsg: this remote does not allow $binding_cipher; no sync engine was started." >&2
    exit 1
  fi

  if [ "$e2ee" -eq 1 ]; then
    # The explicit switch, not key presence, selects E2EE. Configure before
    # migration or engine startup so a capability/trust failure cannot fall
    # back to plaintext.
    if ! _remote_configure_keyed_team "$team" "$cfg"; then
      echo "agmsg: the remote binding was recorded, but no sync engine was started." >&2
      exit 1
    fi
  fi

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

  local connection_security="plain"
  [ "$binding_cipher" = "age-v1" ] && connection_security="age-v1 encrypted"
  # `remote_team_name` is the team's name ON THE SERVER, read out of the connect
  # response above. That response carries no org — server_instance_id, team_id,
  # team_name, min_available_seq — so the word "org" named something the server
  # had never sent. While the two names match it reads as harmless repetition,
  # which is why it lasted: every test connected a team whose local and remote
  # names were the same string.
  #
  # So it is said only when it is news. Same name, nothing to add; different
  # name, the operator is told which one the server is using, under a label
  # that is true.
  local server_side=""
  if [ -n "$remote_team_name" ] && [ "$remote_team_name" != "$team" ]; then
    server_side=" (on the server: '$remote_team_name')"
  fi
  echo "Connected: team '$team'$server_side ($connection_security). Sync engine running."
  # Carrying the snapshot and key by hand is the plain install's answer to
  # getting a second machine in. A larger tool may have a ceremony for exactly
  # that, and this line would talk its operator out of it -- into doing by hand
  # the thing the ceremony exists to make unnecessary. So it is said only when
  # nobody else owns the next step.
  if [ "$e2ee" -eq 1 ] && agmsg_operator_guidance_is_ours; then
    echo "Export the public epoch snapshot with: key.sh show $team --snapshot --out <file>"
    echo "Transfer that snapshot and the key out of band; the other machine must import and live-confirm them before syncing."
  fi
}

# --- status --------------------------------------------------------------

_remote_status_one() {
  local team="$1" cfg connected_at disconnected_at write_allowed_ciphers key_id \
    binding_cipher engine_state engine_pid
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
  binding_cipher="$(_remote_read_config_field "$cfg" '$.remote_binding.cipher_profile')"

  IFS=$'\t' read -r engine_state engine_pid < <(_remote_sync_engine_status "$team")
  case "$engine_state" in
    running)
      echo "$team	connected (engine running, pid $engine_pid) since $connected_at" ;;
    stopped)
      echo "$team	connected (engine stopped — run: remote.sh sync start $team) since $connected_at" ;;
    stale)
      if [ -n "$engine_pid" ]; then
        echo "$team	connected (engine stale — pidfile $engine_pid points at a dead or foreign process) since $connected_at"
      else
        echo "$team	connected (engine stale — pidfile does not contain a valid process id) since $connected_at"
      fi
      ;;
  esac
  if [ "$binding_cipher" = "age-v1" ]; then
    if [ -n "$key_id" ] && [ "$key_id" != "null" ]; then
      echo "		encryption: age-v1, key present"
    else
      echo "		encryption: age-v1, local key missing"
    fi
  elif [ -n "$key_id" ] && [ "$key_id" != "null" ]; then
    echo "		encryption: none (local key is not used by this binding)"
  elif [[ "$write_allowed_ciphers" != *none* ]]; then
    echo "		encryption: required, no local key"
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
  local team="$1" cfg raw engine_state engine_pid
  cfg="$(_remote_team_config "$team")"
  [ -f "$cfg" ] || return 1

  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 1
  raw="$(cat "$cfg" 2>/dev/null)"
  agmsg_lock_release

  IFS=$'\t' read -r engine_state engine_pid < <(_remote_sync_engine_status "$team")
  printf '%s' "$raw" | python3 -c '
import json, sys
team, engine_state, engine_pid_text = sys.argv[1:4]
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
engine_pid = int(engine_pid_text) if engine_pid_text else None
if state == "disconnected":
    engine_state = "stopped"
    engine_pid = None
print(json.dumps({
    "local_team": team,
    "endpoint": binding.get("endpoint"),
    "server_instance_id": binding.get("server_instance_id"),
    "remote_team_id": binding.get("remote_team_id"),
    "credential_id": binding.get("credential_id"),
    "state": state,
    "engine_state": engine_state,
    "engine_pid": engine_pid,
}, sort_keys=True))
' "$team" "$engine_state" "$engine_pid"
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

# --- sync lifecycle --------------------------------------------------------

cmd_sync_start() {
  local team="${1:?Usage: remote.sh sync start <team>}" cfg connected_at disconnected_at \
    engine_state engine_pid started_pid ready_pid startup_nonce ready=0 i=0 \
    logfile log_offset=1
  [ $# -eq 1 ] || { echo "Usage: remote.sh sync start <team>" >&2; exit 1; }
  agmsg_validate_team_name "$team" || exit 1
  agmsg_lock_acquire "$TEAMS_DIR/$team" || exit 1
  cfg="$(_remote_team_config "$team")"
  connected_at="$(_remote_read_config_field "$cfg" '$.remote_binding.connected_at')"
  disconnected_at="$(_remote_read_config_field "$cfg" '$.remote_binding.disconnected_at')"
  if [ -z "$connected_at" ] || [ "$connected_at" = "null" ]; then
    echo "agmsg: team '$team' has no active remote binding; connect or pull it first" >&2
    agmsg_lock_release
    exit 1
  fi
  if [ -n "$disconnected_at" ] && [ "$disconnected_at" != "null" ]; then
    echo "agmsg: team '$team' is disconnected; connect or pull it before starting sync" >&2
    agmsg_lock_release
    exit 1
  fi

  IFS=$'\t' read -r engine_state engine_pid < <(_remote_sync_engine_status "$team")
  if [ "$engine_state" = "running" ]; then
    echo "Sync engine already running (pid $engine_pid)."
    agmsg_lock_release
    return
  fi

  logfile="$CONNECTION_ROOT/run/remote-sync.$team.log"
  [ -f "$logfile" ] && log_offset=$(( $(wc -c < "$logfile" | tr -d ' ') + 1 ))
  startup_nonce="$(compat_uuid7)"
  if ! _remote_sync_engine_start "$team" "$startup_nonce"; then
    agmsg_lock_release
    return 1
  fi
  started_pid="$(cat "$(_remote_sync_engine_pidfile "$team")")"
  while [ "$i" -lt 1600 ]; do
    IFS=$'\t' read -r engine_state ready_pid < <(_remote_sync_engine_status "$team")
    if [ "$engine_state" = "running" ] && [ "$ready_pid" = "$started_pid" ] &&
       tail -c "+$log_offset" "$logfile" 2>/dev/null |
         awk -v nonce="\"startup_nonce\":\"$startup_nonce\"" '
           index($0, "\"event\":\"capabilities\"") && index($0, nonce) { found = 1 }
           END { exit(found ? 0 : 1) }
         '; then
      ready=1
      break
    fi
    i=$((i + 1))
    sleep 0.01
  done
  if [ "$ready" -ne 1 ]; then
    if _remote_sync_engine_reap_owned "$team" "$started_pid"; then
      rm -f "$(_remote_sync_engine_pidfile "$team")"
    else
      echo "agmsg: failed engine ownership was preserved in its pidfile for diagnosis" >&2
    fi
    agmsg_lock_release
    echo "agmsg: sync engine for '$team' did not become ready" >&2
    return 1
  fi
  agmsg_lock_release
  echo "Sync engine started for '$team' (pid $started_pid)."
}

cmd_sync() {
  local action="${1:-}"
  case "$action" in
    start) shift; cmd_sync_start "$@" ;;
    *) echo "Usage: remote.sh sync start <team>" >&2; exit 1 ;;
  esac
}

# --- disconnect ------------------------------------------------------------

cmd_disconnect() {
  local team="${1:?Usage: remote.sh disconnect <team>}"
  agmsg_validate_team_name "$team" || exit 1
  local cfg
  cfg="$(_remote_team_config "$team")"
  # "Is it connected" and "which generation" have to come from ONE snapshot, and
  # the snapshot has to be the moment the decision is made. Read under the team
  # lock so a concurrent reconnect cannot land between the two fields, and read
  # both BEFORE stopping the engine: taking the generation afterwards would mean
  # a reconnect during the stop got its own, newer binding adopted as the thing
  # this call had decided to disconnect, and the check would then agree with
  # itself and disconnect the wrong one.
  #
  # binding_revision is the generation: every binding carries one and every write
  # bumps it. The guard used to compare credential_id, which stopped meaning
  # anything the moment connect stopped issuing credentials.
  # The stop is inside the same hold, and that is the point. connect writes its
  # binding under this lock and starts the engine after releasing it, so a
  # reconnect that landed between the snapshot and an unlocked stop would have
  # ITS engine killed by a disconnect that then refuses to write -- the config
  # protected by the check, the engine killed outside it. Holding through the
  # stop means the replacement cannot exist yet when the engine is stopped.
  local connected_at binding_revision
  agmsg_lock_acquire "$TEAMS_DIR/$team" || exit 1
  connected_at="$(_remote_read_config_field "$cfg" '$.remote_binding.connected_at')"
  binding_revision="$(_remote_read_config_field "$cfg" '$.remote_binding.binding_revision')"
  if [ -z "$connected_at" ] || [ "$connected_at" = "null" ]; then
    agmsg_lock_release
    echo "agmsg: team '$team' is not connected" >&2
    exit 1
  fi

  # Leaving the engine polling a team we are tearing the binding off of would
  # just error every cycle.
  _remote_sync_engine_stop "$team"
  agmsg_lock_release

  # `|| status=$?`, not a bare call followed by `$?`: under `set -e` a function
  # returning non-zero as a statement aborts the script before the next line
  # runs, so the branches below would never be reached and the caller would see
  # a bare exit 2 with nothing said. That was unreachable while the guard was
  # keyed on credential_id and always inert; making the guard work exposed it.
  local local_disconnect_status=0
  _remote_local_disconnect "$team" "$cfg" "$binding_revision" || local_disconnect_status=$?
  if [ "$local_disconnect_status" -eq 2 ]; then
    echo "agmsg: team '$team's binding changed to something else during disconnect — aborting rather than risk clobbering a concurrent connection. Retry if you still want to disconnect the CURRENT binding." >&2
    exit 1
  elif [ "$local_disconnect_status" -ne 0 ]; then
    exit 1
  fi

  echo "Disconnected '$team'. Local sync state cleared; sends/reads continue locally."
}

# --- forget ---------------------------------------------------------------

cmd_forget() {
  local team="" yes=0 positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [ "${#positional[@]}" -eq 1 ] || {
    echo "Usage: remote.sh forget [--yes] <team>" >&2
    exit 1
  }
  team="${positional[0]}"
  agmsg_validate_team_name "$team" || exit 1

  local team_dir cfg connected_at disconnected_at binding_before binding_current \
    binding_revision_before binding_revision_current escaped updated
  team_dir="$TEAMS_DIR/$team"
  cfg="$(_remote_team_config "$team")"
  [ -f "$cfg" ] || {
    echo "agmsg: team '$team' has no local remote binding to forget" >&2
    exit 1
  }
  agmsg_lock_acquire "$team_dir" || exit 1
  connected_at="$(_remote_read_config_field "$cfg" '$.remote_binding.connected_at')"
  disconnected_at="$(_remote_read_config_field "$cfg" '$.remote_binding.disconnected_at')"
  binding_revision_before="$(_remote_read_config_field "$cfg" '$.remote_binding.binding_revision')"
  if [ -z "$binding_revision_before" ] || [ "$binding_revision_before" = "null" ]; then
    escaped="$(sed "s/'/''/g" "$cfg")"
    updated="$(agmsg_sqlite_mem \
      "SELECT json_set('$escaped', '\$.remote_binding.binding_revision', 1);")"
    agmsg_write_atomic "$cfg" "$updated"
    binding_revision_before=1
  fi
  binding_before="$(_remote_read_config_field "$cfg" '$.remote_binding')"
  agmsg_lock_release
  if [ -z "$connected_at" ] || [ "$connected_at" = "null" ]; then
    echo "agmsg: team '$team' has never been connected" >&2
    exit 1
  fi
  if [ -z "$disconnected_at" ] || [ "$disconnected_at" = "null" ]; then
    echo "agmsg: team '$team' is still connected; run 'remote.sh disconnect $team' first" >&2
    exit 1
  fi

  # A successful remote connection owns this exact directory. Never resolve
  # through agmsg_db_path here: a malformed or interrupted partition selection
  # must not turn a team-scoped delete into deletion of the shared store.
  local store_dir store_path event_count=0 tables
  store_dir="$(agmsg_storage_dir)/teams/$team"
  store_path="$store_dir/messages.db"
  if [ -f "$store_path" ]; then
    tables="$(agmsg_sqlite "$store_path" \
      "SELECT name FROM sqlite_master WHERE type='table';")" || {
      echo "agmsg: cannot inspect team store '$store_path'; refusing to delete it" >&2
      exit 1
    }
    if printf '%s\n' "$tables" | grep -qx events; then
      event_count="$(agmsg_sqlite "$store_path" "SELECT COUNT(*) FROM events;")"
    fi
    if printf '%s\n' "$tables" | grep -qx messages; then
      event_count="$((event_count + $(agmsg_sqlite "$store_path" "SELECT COUNT(*) FROM messages;")))"
    fi
  fi

  echo "This will forget local team '$team' from this machine."
  echo "Store: $store_path"
  echo "Events: $event_count"
  echo "The server copy remains. Local roster, history, sync configuration, keys, and trust will be deleted."

  if [ "$yes" -ne 1 ]; then
    if [ ! -t 0 ]; then
      echo "agmsg: forget requires an interactive terminal or --yes" >&2
      exit 1
    fi
    local answer=""
    IFS= read -r -p "Type '$team' to confirm: " answer
    if [ "$answer" != "$team" ]; then
      echo "Forget cancelled."
      return
    fi
  fi

  # Revalidate under the registry lock after the operator has confirmed. A
  # reconnect racing the prompt must not have its new active binding deleted.
  agmsg_lock_acquire "$team_dir" || exit 1
  binding_current="$(_remote_read_config_field "$cfg" '$.remote_binding')"
  binding_revision_current="$(_remote_read_config_field "$cfg" '$.remote_binding.binding_revision')"
  if [ "$binding_revision_current" != "$binding_revision_before" ] ||
     [ "$binding_current" != "$binding_before" ]; then
    agmsg_lock_release
    echo "agmsg: team '$team' changed while forget was waiting; nothing was deleted" >&2
    exit 1
  fi
  disconnected_at="$(_remote_read_config_field "$cfg" '$.remote_binding.disconnected_at')"
  if [ -z "$disconnected_at" ] || [ "$disconnected_at" = "null" ]; then
    agmsg_lock_release
    echo "agmsg: team '$team' became connected while forget was waiting; nothing was deleted" >&2
    exit 1
  fi

  local sync_config trust_root trust_file server_instance_id remote_team_id \
    protocol_version retired_dir
  retired_dir="$TEAMS_DIR/.forget-$team.$$"
  [ ! -e "$retired_dir" ] || {
    agmsg_lock_release
    echo "agmsg: temporary forget path already exists; nothing was deleted" >&2
    exit 1
  }
  sync_config="$(_remote_sync_config_file "$team")"
  trust_root="${AGMSG_SYNC_TRUST_DIR:-$CONNECTION_ROOT/run/remote-trust}"
  server_instance_id="$(_remote_read_config_field "$cfg" '$.remote_binding.server_instance_id')"
  remote_team_id="$(_remote_read_config_field "$cfg" '$.remote_binding.remote_team_id')"
  protocol_version="$(_remote_read_config_field "$cfg" '$.remote_binding.protocol_version')"
  if ! [[ "$server_instance_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] ||
      ! [[ "$remote_team_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] ||
      [ "$protocol_version" != "1" ]; then
    agmsg_lock_release
    echo "agmsg: team '$team' has an invalid remote binding; refusing to derive deletion paths from it" >&2
    exit 1
  fi
  trust_file="$trust_root/age-v1-$server_instance_id-$remote_team_id-v$protocol_version.json"

  _remote_sync_engine_stop "$team"
  rm -f "$sync_config" \
    "$CONNECTION_ROOT/run/remote-sync.$team.log"
  local other_cfg trust_referenced=0
  for other_cfg in "$TEAMS_DIR"/*/config.json; do
    [ -f "$other_cfg" ] || continue
    [ "$other_cfg" = "$cfg" ] && continue
    if [ "$(_remote_read_config_field "$other_cfg" '$.remote_binding.server_instance_id')" = "$server_instance_id" ] &&
       [ "$(_remote_read_config_field "$other_cfg" '$.remote_binding.remote_team_id')" = "$remote_team_id" ] &&
       [ "$(_remote_read_config_field "$other_cfg" '$.remote_binding.protocol_version')" = "$protocol_version" ]; then
      trust_referenced=1
      break
    fi
  done
  [ "$trust_referenced" -eq 1 ] || rm -f "$trust_file"
  [ ! -d "$CRED_ROOT/$team" ] || rm -r "$CRED_ROOT/$team"
  [ ! -d "$store_dir" ] || rm -r "$store_dir"

  # Rename is the local commit point: after it, a fresh join may safely create
  # the same display name without racing deletion of the forgotten registry.
  mv "$team_dir" "$retired_dir"
  AGMSG_HELD_LOCKS=""
  trap - EXIT INT TERM
  rm -r "$retired_dir"

  echo "Forgot '$team' on this machine. The server copy was not changed."
}

case "${1:-}" in
  connect) shift; agmsg_require_python3 "remote connect" || exit 1; cmd_connect "$@" ;;
  pull) shift; agmsg_require_python3 "remote pull" || exit 1; cmd_pull "$@" ;;
  unlock) shift; agmsg_require_python3 "remote unlock" || exit 1; cmd_unlock "$@" ;;
  status) shift; agmsg_require_python3 "remote status" || exit 1; cmd_status "$@" ;;
  sync) shift; cmd_sync "$@" ;;
  disconnect) shift; agmsg_require_python3 "remote disconnect" || exit 1; cmd_disconnect "$@" ;;
  forget) shift; agmsg_require_python3 "remote forget" || exit 1; cmd_forget "$@" ;;
  doctor) shift; cmd_doctor "$@" ;;
  *)
    echo "Usage: remote.sh <connect|pull|unlock|status|sync|disconnect|forget|doctor> ..." >&2
    exit 1 ;;
esac
