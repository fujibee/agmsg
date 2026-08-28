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

# `${BASH_SOURCE[0]}` rather than `$0`, so this resolves the same whether the
# file is executed or sourced. Sourcing is what lets a test call the internal
# functions directly; with `$0` it resolved to the sourcing shell and every
# `source "$SCRIPT_DIR/lib/..."` below failed (#762).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONNECTION_ROOT="${AGMSG_SYNC_CONNECTION_DIR:-$SKILL_DIR}"

# Whether the caller of _remote_sync_engine_start already holds this team's lock.
#
# Assigned unconditionally, NOT `${VAR:-0}`: the point of the flag is that it
# cannot be supplied from outside. An exported variable of this name from a
# parent process would otherwise make the engine start skip its own locking and
# run the check-then-act unserialised -- the failure this flag exists to prevent,
# handed to anything upstream that sets a name (#762).
_REMOTE_ENGINE_CALLER_HOLDS_LOCK=0
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
# For _agmsg_pid_alive_local — the one piece of watch.sh's daemon plumbing that
# is already a shared, reusable helper. The LOCAL probe, because every pid this
# file checks is one it minted itself (#652); see the lifecycle note below. The rest of the sync engine's lifecycle
# (below) is written here rather than shared, because watch.sh's is inline and
# keyed on watcher-only concepts (session/actas) this engine does not have.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/instance-id.sh"
# agmsg_sha256 -- the age-v1 checkpoint below is a SHA-256 of the snapshot, and
# `shasum` is absent in Git for Windows' Git Bash.
# shellcheck source=lib/hash.sh
source "$SCRIPT_DIR/lib/hash.sh"

TEAMS_DIR="$CONNECTION_ROOT/teams"
CRED_ROOT="$CONNECTION_ROOT/run/remote-credentials"

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }

# How many members this machine can actually name.
#
# The same `$.agents` map `team.sh` prints from, counted rather than listed. A
# roster materialises from `member_joined` events in the message stream, so on a
# machine that pulled before any connected engine pushed them this is 0 while
# the server's membership is not (#743).
_remote_local_roster_count() {
  local cfg="$1" escaped
  [ -f "$cfg" ] || { echo 0; return; }
  escaped=$(sed "s/'/''/g" "$cfg")
  agmsg_sqlite_mem "SELECT COALESCE((SELECT count(*) FROM
    json_each(json_extract('$escaped', '\$.agents'))), 0);"
}

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

# Decide whether an endpoint may be spoken to over plaintext http. Delegates to
# a real URL parser — a shell glob/prefix check here was bypassable by
# http://127.0.0.1.evil.com, http://localhost.evil.com, and the userinfo trick
# http://localhost@evil.com, all of which matched a naive
# `http://127.0.0.1*`/`http://localhost*` case pattern while actually pointing
# at a different host (remote-connect review findings B6/R2).
#
# The rule is "IP literal in a private range", not "loopback" (#717). The
# bypasses above are all NAMES that read like a safe host; a literal is the
# address itself, so a LAN address over http is allowed and does not need a
# tunnel to a loopback port. This adapter calls the same implementation that
# continued sync uses; keeping a second parser here caused the two paths to
# disagree on five URL forms (#722).
#
# What plaintext costs, stated where it is decided: the client sends no
# credential (there is no Authorization header), so what crosses in the clear
# is the message bodies of a team synced with cipher `none`. Under --e2ee the
# contents are sealed before they leave the machine.
_remote_validate_endpoint() {
  local node
  node="$(agmsg_resolve_node)"
  "$node" "$SCRIPT_DIR/internal/validate-endpoint.mjs" "$1"
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
# WHICH DIRECTORY TO REMOVE — the thing that was missing (#865).
#
# A registry lock left behind by a killed process is never broken by anything:
# nothing expires, nothing sweeps, and acquire waits out its budget and fails
# with `timed out acquiring registry lock`, which describes contention. The
# operator's next move is to look for the process holding it; there is no
# process, and no message anywhere names the directory to remove. A machine in
# that state cannot get itself out.
#
# This REPORTS and removes nothing. The report alone ends "cannot recover":
# it says which team, what the lock records, whether that process is running,
# and prints the removal as a line to paste. Sweeping automatically is a
# separate decision with a worse failure mode — a wrong verdict takes a lock
# away from a process that is using it — and it is not made here.
#
# Not a check, so no `[x]`/`[ ]` and no effect on the exit code: a lock that
# exists is not a failed prerequisite, and a doctor that exits non-zero because
# a team is busy would be wrong every time somebody is joining.
# One lock, reported. Split out so the two ways of finding them — a named team,
# or a sweep — share this body and neither has to feed a loop from a string.
# Joining the paths into one variable and reading it back would mean either an
# unquoted heredoc, which runs command substitution on a team name, or unquoted
# word splitting, which globs one.
_remote_doctor_one_lock() {
  local lock="$1" team holder pid state q
  [ -d "$lock" ] || return 0
  team="${lock%/.config.lock}"
  team="${team##*/}"
  if [ "$shown" -eq 0 ]; then
    echo "Registry locks:"
    shown=1
  fi
  holder="$lock.holder"
  pid=""
  [ -f "$holder" ] && pid="$(sed -n 's/^pid //p' "$holder" 2>/dev/null | head -1)"
  # THREE ANSWERS, NOT TWO. "held" and "the holder is gone" are what the
  # operator acts on; "cannot tell" is neither — a lock this could not ask
  # about, and saying it is gone would be a guess. The guess that costs is the
  # one that calls a live lock dead and then prints the command to remove it.
  #
  # WHICH IS WHY THE NUMBER IS VALIDATED BEFORE IT IS ASKED ABOUT.
  # `_agmsg_pid_alive_local` returns false for a value it never put to the
  # process table at all — non-numeric, leading zero, past the POSIX ceiling —
  # and folding that into "not running" turned `pid not-a-pid` into a stale
  # verdict with a removal beside it (raised in review). The same ceiling the
  # helper uses, for the same reason it uses it.
  if [ -z "$pid" ]; then
    state="cannot tell — no holder recorded"
  elif ! _agmsg_pid_valid "$pid" 2147483647; then
    state="cannot tell — the holder record's pid is not a usable number"
  elif _agmsg_pid_alive_local "$pid"; then
    state="held — pid $pid is running"
  else
    state="stale — pid $pid is not running"
  fi
  echo "  $team: $state"
  if [ -f "$holder" ]; then
    echo "    records: $(tr '\n' ' ' < "$holder" 2>/dev/null)"
  fi
  echo "    created: $(ls -ld "$lock" 2>/dev/null || printf '%s (cannot stat)' "$lock")"
  # QUOTED, because this is meant to be pasted. The store root and the team
  # name can both contain a space, and an unquoted path becomes several
  # arguments to `rm -r`. Same scheme as lib/shquote.sh.
  q="$(printf "'%s'" "$(printf '%s' "$lock" | sed "s/'/'\\\\''/g")")"
  if [ "$state" = "held — pid $pid is running" ]; then
    echo "    a command is using this team. Nothing to do."
  else
    echo "    if no agmsg command is running for this team, remove it:"
    echo "      rm -r $q"
    [ -f "$holder" ] && echo "      rm -f $q.holder"
    echo "    nothing but the lock lives in there — it holds no team data."
  fi
}

_remote_doctor_locks() {
  local only_team="${1:-}" lock shown=0
  # A NAMED TEAM IS LOOKED AT DIRECTLY, and the sweep does not stop at `*`.
  #
  # Team names may begin with a dot — the validator rejects empty, `.`, `..`, a
  # leading `-`, `/`, `\` and control characters, and nothing else — and `*`
  # does not match a leading dot, so `.foo` was invisible to the sweep (raised
  # in review). The two extra patterns cover `.foo` and `..foo`; `.` and `..`
  # themselves cannot be team names.
  #
  # Globs rather than `find`, which is not on every PATH this tree is required
  # to run under. Quoted, so a team name containing a space stays one path.
  if [ -n "$only_team" ]; then
    # VALIDATED BEFORE IT BECOMES A PATH. `cmd_doctor` takes its argument and,
    # until this line, only ever put it in a header sentence — so nothing had
    # ever checked it. Building `$TEAMS_DIR/$only_team/.config.lock` from it
    # turned `doctor ../outside` into a read of a directory outside the store,
    # reported with its records and a `rm -r` to paste (raised in review). The
    # sweep it replaced never reached one only because no team was named that.
    #
    # The same validator every other team-taking path uses: it rejects empty,
    # `.`, `..`, `/`, `\`, a leading `-` and control characters, and allows a
    # leading dot and a space, which this reports on and must keep.
    agmsg_validate_team_name "$only_team" || return 1
    _remote_doctor_one_lock "$TEAMS_DIR/$only_team/.config.lock"
  else
    for lock in "$TEAMS_DIR"/*/.config.lock "$TEAMS_DIR"/.[!.]*/.config.lock "$TEAMS_DIR"/..?*/.config.lock; do
      _remote_doctor_one_lock "$lock"
    done
  fi
  [ "$shown" -eq 0 ] || echo
}

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
  # Reported with age, and optional for the same reason: only end-to-end
  # encryption needs it. Not failed=1 -- a machine syncing with cipher "none"
  # is fully functional without it. Listed at all because when it IS missing
  # the symptom lands after the team is registered, which reads like a server
  # problem rather than a missing tool.
  # "usable", not "on PATH": presence and usability are different questions and
  # this line answers the second one -- a tool that is installed and fails, or
  # that returns the wrong digest for a known input, reports unusable here.
  if agmsg_sha256_usable; then
    echo "  [x] usable SHA-256 tool  (optional)"
  else
    echo "  [ ] usable SHA-256 tool  (optional)"
    echo
    echo "End-to-end encryption needs one of 'shasum', 'sha256sum' or 'openssl' for key"
    echo "fingerprints and the age-v1 checkpoint. Remote sync without --e2ee does not use it:"
    echo "  macOS (Homebrew):      brew install openssl"
    echo "  Debian/Ubuntu:         sudo apt install coreutils"
    echo "  Windows (Git Bash):    ships with Git for Windows; reinstall it if 'sha256sum' is missing"
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
  # A REJECTED TEAM NAME ENDS THE COMMAND. The validator prints why; carrying on
  # to "All prerequisite checks passed." after refusing to look at what was
  # asked about would report success for a question nobody answered.
  _remote_doctor_locks "$team" || exit 1
  if [ "$failed" -eq 0 ]; then
    # NARROWED, because a lock report can sit above this line. "All checks
    # passed." after "stale — pid 4711 is not running" and a `rm -r` reads as
    # cancelling it, and the exit code deliberately does not move: a locked team
    # is not a failed prerequisite (raised in review).
    echo "All prerequisite checks passed."
  else
    echo "Some checks failed. See above."
    exit 1
  fi
}

# --- shared HTTP helpers (B1: never put secrets in curl's own argv/ps) ---

# _remote_curl_path <path> — render <path> for embedding INSIDE a curl -K config
# file. On Windows/Git Bash, MSYS translates POSIX paths to Windows form only for
# a native binary's argv, NOT for paths read from a config file's contents, so an
# embedded /tmp or /c/.. path is unopenable by native curl (→ curl fails → the
# caller's HTTP 000). cygpath -m yields a Windows drive path with FORWARD slashes;
# -w is wrong here because curl's config parser treats backslashes as escapes.
# Capability-gated on cygpath so macOS/Linux (no cygpath) are unchanged.
_remote_curl_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# _remote_http_post_json <url> <body_file> <out_body_file> <out_header_file> -> prints http_code
# Posts <body_file> as the request body via a curl -K config file, so the
# body (which holds the token) never appears in curl's own argv/ps. The
# config file is 0600 and removed immediately after the call.
_remote_http_post_json() {
  local url="$1" body_file="$2" out_file="$3" header_file="$4" cfg http_code \
    work_dir header_fifo copier_pid curl_output curl_status=0 curl_err
  # ONE ALLOCATION BEFORE THE TRAP, AND EVERYTHING ELSE INSIDE IT.
  #
  # Two things go wrong with the ordering this replaces, and this shape is the
  # smallest one that closes both.
  #
  # A trap cannot expand what it cannot see. An EXIT trap set inside a function
  # runs after that function's frame is gone, so a single-quoted body expands
  # `$cfg` in the CALLER's scope, where no local of that name exists. It removes
  # "" and returns 0, so the cleanup reads as working. Measured on bash 3.2.57
  # and 5.3.15: a local is EMPTY inside an EXIT trap fired by errexit from
  # within the function. `printf %q` fixes the value at set time and survives a
  # TMPDIR containing spaces.
  #
  # And anything created BEFORE the trap is armed is unprotected. Making the
  # config, then a directory, then arming the trap leaves a window where the
  # second allocation fails and the first is stranded -- including a 0600 config
  # naming the request body. Reordering cannot close it, because there is always
  # a first allocation. So there is exactly one, and everything else is made
  # inside a directory that is already condemned.
  #
  # It also removes a hazard rather than guarding it: the caller's header file
  # lives OUTSIDE this directory, so `rm -rf` cannot reach it even on the marker
  # path below, where `header_fifo` IS `header_file`.
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-curl.XXXXXX")"
  trap "rm -rf $(printf '%q' "$work_dir")" EXIT INT TERM
  cfg="$work_dir/config"
  curl_err="$work_dir/stderr"
  : > "$cfg"
  chmod 600 "$cfg"
  # The headers go through a fifo so a hostile or broken server cannot make us
  # buffer an unbounded response — bounded-copy.py enforces the ceiling while
  # the transfer is still running. That mechanism needs a real named pipe.
  #
  # On Windows/Git Bash there is no real named pipe to have: MSYS emulates
  # mkfifo with a .lnk file that only MSYS-aware programs understand, and curl
  # there is a NATIVE binary. It cannot open what mkfifo made, so it fails and
  # the caller sees the "000" it reports for every failure alike.
  #
  # Where cygpath exists, dump straight to the destination file and skip both
  # the fifo and the copier. That gives up streaming enforcement of the size
  # ceiling on that platform — curl's own `max-filesize` still applies to the
  # BODY, and the header dump is what becomes unbounded. Stated rather than
  # hidden, because it is a real difference between the platforms and not a
  # detail of how the file is named.
  #
  # Gated on `command -v cygpath`, not on an OS name. Say what that probe
  # actually asks, because it is narrower than the thing we care about: it is a
  # CAPABILITY MARKER for an environment where MSYS fifos and a native curl
  # coexist -- it does not test whether a real fifo can be made, and nothing
  # here does. An earlier version of this comment claimed it did, which would
  # have told the next reader that a machine passing the probe had been checked
  # for the property that matters.
  if command -v cygpath >/dev/null 2>&1; then
    header_fifo="$header_file"
    : > "$header_fifo"
    copier_pid=""
  else
    header_fifo="$work_dir/header"
    mkfifo "$header_fifo"
    # Reaped on both normal paths below (waited on success, killed and waited on
    # failure), so this is short-lived by construction -- but the EXIT trap only
    # removes files, it does not kill the copier. A signal arriving before curl
    # opens the fifo therefore leaves it blocked on open() with no writer ever
    # coming, and an inherited fd 3 would then hold a bats test file open to the
    # timeout. Closing the fds costs nothing and removes that one path.
    python3 "$SCRIPT_DIR/internal/bounded-copy.py" 65536 < "$header_fifo" > "$header_file" 3>&- 4>&- &
    copier_pid=$!
  fi
  {
    printf 'url = "%s"\n' "$url"
    printf 'request = "POST"\n'
    printf 'header = "Content-Type: application/json"\n'
    printf 'header = "Agmsg-Protocol-Version: 1"\n'
    printf 'dump-header = "%s"\n' "$(_remote_curl_path "$header_fifo")"
    printf 'connect-timeout = "10"\n'
    printf 'max-time = "15"\n'
    printf 'max-filesize = "2097152"\n'
    printf 'data = "@%s"\n' "$(_remote_curl_path "$body_file")"
  } > "$cfg"
  # Do not discard curl's stderr. On failure it is the only record of WHY, and
  # the caller only ever sees the HTTP code -- which this function reports as
  # "000" for every kind of failure alike. A Windows run spent a long time on a
  # bare 000 whose cause (curl could not open a path embedded in the config)
  # was sitting in the stderr this line was throwing away.
  #
  # Captured rather than passed through, and shown only when curl actually
  # failed: on the success path curl -sS is already silent, and a stray write
  # to stderr here would land in the middle of a caller's output.
  if curl_output=$(curl -sS -o "$out_file" -w '%{http_code}' -K "$cfg" 2>"$curl_err"); then
    :
  else
    curl_status=$?
  fi
  # THE DIAGNOSIS COMES AFTER THE OUTCOME IS SETTLED, AND CANNOT CHANGE IT.
  #
  # This used to be one `&& && cat` line placed before the branch below. Under
  # `set -e` a failing `cat` -- a closed stderr, a reader that went away, a full
  # disk -- ends the function on the spot: the copier is never reaped, the
  # work_dir is never removed, and the caller gets no code at all instead of the
  # "000" this helper promises for every failure. Being unable to explain a
  # failure must not turn it into a different failure.
  #
  # So: reap and decide first, then write the diagnosis best-effort.
  if [ "$curl_status" -ne 0 ]; then
    [ -n "$copier_pid" ] && { kill "$copier_pid" 2>/dev/null || true; wait "$copier_pid" 2>/dev/null || true; }
    http_code="000"
  elif [ -z "$copier_pid" ] || wait "$copier_pid"; then
    http_code="$curl_output"
  else
    http_code="000"
  fi
  if [ "$curl_status" -ne 0 ] && [ -s "$curl_err" ]; then
    cat "$curl_err" >&2 || true
  fi
  # One directory holds the config, the error file and the fifo, so the normal
  # path removes exactly what the trap would have. The caller's header file is
  # not in it and was never at risk from this line -- which is the point of the
  # layout rather than a condition to remember.
  rm -rf "$work_dir"
  trap - EXIT INT TERM
  printf '%s' "$http_code"
}

# _remote_http_get_json <url> <team_id> <out_body_file> -> prints http_code
# The team-scoped read routes take their team from the Agmsg-Team-ID header.
# Nothing else is sent, because there is nothing else to send: this protocol
# carries no credential at all (see cmd_connect).
_remote_http_get_json() {
  local url="$1" team_id="$2" out_file="$3" cfg curl_output curl_status=0 \
    curl_err work_dir
  # One allocation, then the trap, then everything else inside it -- the same
  # shape as the POST helper and for the same two reasons. A trap set inside a
  # function cannot expand that function's locals when it fires, so the path is
  # baked in with printf %q; and anything created before the trap is armed is
  # unprotected, so only one thing is.
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-curl.XXXXXX")"
  trap "rm -rf $(printf '%q' "$work_dir")" EXIT INT TERM
  cfg="$work_dir/config"
  curl_err="$work_dir/stderr"
  : > "$cfg"
  chmod 600 "$cfg"
  {
    printf 'url = "%s"\n' "$url"
    printf 'request = "GET"\n'
    printf 'header = "Agmsg-Protocol-Version: 1"\n'
    printf 'header = "Agmsg-Team-ID: %s"\n' "$team_id"
    printf 'connect-timeout = "10"\n'
    printf 'max-time = "15"\n'
    printf 'max-filesize = "2097152"\n'
  } > "$cfg"
  # Same reason as the POST helper: discarding stderr leaves "000" as the only
  # thing anyone sees, and "000" is what this reports for every failure alike.
  # `pull` goes through here, so a failure on this path was as undiagnosable as
  # the connect one that cost a Windows run its afternoon.
  if curl_output=$(curl -sS -o "$out_file" -w '%{http_code}' -K "$cfg" 2>"$curl_err"); then
    :
  else
    curl_status=$?
  fi
  # The outcome is settled BEFORE the diagnosis is written, and the write is
  # best-effort. As one fatal `&&` chain this line ended the function whenever
  # `cat` failed -- a closed stderr, a reader that went away -- so being unable
  # to explain a failure returned no code at all instead of the "000" this
  # helper promises. Reviewed and reversed on the POST side; the same shape
  # would have been wrong here.
  [ "$curl_status" -eq 0 ] || curl_output="000"
  if [ "$curl_status" -ne 0 ] && [ -s "$curl_err" ]; then
    cat "$curl_err" >&2 || true
  fi
  rm -rf "$work_dir"
  trap - EXIT INT TERM
  printf '%s' "$curl_output"
}

# _remote_archive_replaced_binding <cfg_escaped> <new_server_instance_id> \
#   <new_remote_team_id> <new_protocol_version> <stamp>
#
# Echoes the config document with the current $.remote_binding moved into
# $.previous_bindings, when — and only when — the binding being written names
# a DIFFERENT identity (#849). The caller passes the SQL-escaped document and
# re-escapes what comes back before splicing it into its own write.
#
# EVERY site that replaces $.remote_binding wholesale must run its document
# through this first. There are two such writers — _remote_write_binding
# below, and cmd_pull's bind-after-bootstrap write — and the non-destruction
# invariant of #849 holds at the writer boundary only if both archive. (The
# binding_revision-only touch-ups elsewhere replace nothing and are not
# writers in this sense.)
#
# One entry per (server_instance_id, remote_team_id, protocol_version): an
# entry for the identity being archived is replaced by the newer copy, and an
# entry matching the identity being written becomes the live binding again
# and leaves the archive. The array is therefore bounded by the number of
# distinct such identity tuples this team has ever been bound to -- one per
# server in the common case, more if the same server re-registers the team
# or the protocol version moves -- never by how often the team moved
# between them.
#
# `capabilities` is dropped from the archived copy: it is refetched on every
# connect, and an archived copy would be the one stale snapshot nobody
# re-reads. Restoring a previous binding is a reconnect to its endpoint --
# which refetches -- never a copy of the archived object back into
# $.remote_binding.
#
# A current binding with no server_instance_id never completed a
# registration; there is no partition behind it to point back to, so it is
# replaced without being archived, same as before.
_remote_archive_replaced_binding() {
  local cfg_escaped="$1" new_instance_sql new_team_sql pv="$4" stamp="$5"
  new_instance_sql="$(_agmsg_sqlesc "$2")"
  new_team_sql="$(_agmsg_sqlesc "$3")"
  agmsg_sqlite_mem \
    "WITH cfg(doc) AS (SELECT '$cfg_escaped'),
     cur(b) AS (SELECT json_extract(doc, '\$.remote_binding') FROM cfg),
     kept(arr) AS (SELECT coalesce((
       SELECT json_group_array(json(value))
         FROM cfg, json_each(coalesce(json_extract(cfg.doc, '\$.previous_bindings'), '[]'))
        WHERE NOT (json_extract(value, '\$.server_instance_id') IS json_extract((SELECT b FROM cur), '\$.server_instance_id')
               AND json_extract(value, '\$.remote_team_id')     IS json_extract((SELECT b FROM cur), '\$.remote_team_id')
               AND json_extract(value, '\$.protocol_version')   IS json_extract((SELECT b FROM cur), '\$.protocol_version'))
          AND NOT (json_extract(value, '\$.server_instance_id') IS '$new_instance_sql'
               AND json_extract(value, '\$.remote_team_id')     IS '$new_team_sql'
               AND json_extract(value, '\$.protocol_version')   IS $pv)), '[]'))
     SELECT CASE
       WHEN (SELECT b FROM cur) IS NOT NULL
        AND json_extract((SELECT b FROM cur), '\$.server_instance_id') IS NOT NULL
        AND NOT (json_extract((SELECT b FROM cur), '\$.server_instance_id') IS '$new_instance_sql'
             AND json_extract((SELECT b FROM cur), '\$.remote_team_id')     IS '$new_team_sql'
             AND json_extract((SELECT b FROM cur), '\$.protocol_version')   IS $pv)
       THEN json_set(doc, '\$.previous_bindings',
              json_insert((SELECT arr FROM kept), '\$[#]',
                json(json_set(json_remove((SELECT b FROM cur), '\$.capabilities'),
                              '\$.replaced_at', '$(_agmsg_sqlesc "$stamp")'))))
       ELSE doc
     END FROM cfg;"
}

# _remote_write_binding <cfg> <endpoint> <binding_cipher> <resp_file>
# Records the binding on the team config from a capability snapshot. No
# credential is stored: the snapshot holds nothing that cannot be fetched
# again, and the team_id is a value we minted ourselves.
#
# ONE writer for both the first connect and the adopt path below — but NOT
# for every path: cmd_pull binds after its bootstrap with a write of its own,
# which is why the archive step above is a shared primitive rather than a
# private step of this function.
_remote_write_binding() {
  local cfg="$1" endpoint="$2" binding_cipher="$3" resp_file="$4" \
    expected_binding_revision="${5:-}"
  local resp_escaped cfg_escaped connected_at updated \
    server_instance_id remote_team_id remote_team_name protocol_version \
    current_binding_revision
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
  # Optional compare-and-swap, same contract as _remote_local_disconnect: the
  # caller snapshotted the binding at revision N, verified against that
  # snapshot, and must not have its write land on a binding someone else moved
  # in between -- a concurrent disconnect would otherwise be silently undone
  # by this write's disconnected_at:null. Checked INSIDE the lock, against the
  # file as it is now, not as it was read.
  if [ -n "$expected_binding_revision" ] && [ "$expected_binding_revision" != "null" ]; then
    current_binding_revision="$(_remote_read_config_field "$cfg" '$.remote_binding.binding_revision')"
    if [ "$current_binding_revision" != "$expected_binding_revision" ]; then
      agmsg_lock_release
      echo "agmsg: the team's binding changed while this command was running (revision is now $current_binding_revision, this command verified revision $expected_binding_revision); nothing was written. Check 'remote status' and re-run." >&2
      return 2
    fi
  fi
  cfg_escaped="$(sed "s/'/''/g" "$cfg")"
  # A write that points the team at a DIFFERENT server must not orphan the
  # binding it replaces (#849). The local sync rows and keys for the old server
  # survive this write untouched -- they are keyed on (server_instance_id,
  # remote_team_id, protocol_version) -- but the endpoint string in the binding
  # is the only pointer back to them, so overwriting it strands data that is
  # still on disk. The shared archive primitive above moves the current
  # binding into $.previous_bindings, a sibling key the wholesale json_set on
  # $.remote_binding never touches.
  local archived_doc
  archived_doc="$(_remote_archive_replaced_binding "$cfg_escaped" \
    "$server_instance_id" "$remote_team_id" "$protocol_version" "$connected_at")"
  cfg_escaped="$(printf '%s' "$archived_doc" | sed "s/'/''/g")"
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
    expected_server_instance="${6:-}" expected_binding_revision="${7:-}"
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
  _remote_write_binding "$cfg" "$endpoint" "$binding_cipher" "$caps_file" \
    "$expected_binding_revision" || {
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
  local team="$1" team_id="$2" endpoint="${3:-<url>}" cfg initial existing_id local_connected local_disconnected
  cfg="$(_remote_team_config "$team")"
  mkdir -p "$TEAMS_DIR/$team"
  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 1
  if [ -f "$cfg" ]; then
    existing_id="$(_remote_read_config_field "$cfg" '$.team_id')"
    if [ "$existing_id" != "$team_id" ]; then
      # The refusal is right and stays. What was missing is what to do next
      # (#680): the operator learned that two things disagreed and nothing
      # else -- not which ids, not that their own team was untouched, not that
      # there are two ways out and which is safe when.
      #
      # `_remote_resolve_team_id` a few lines down already answers the same
      # class of question this way -- print what tells the candidates apart,
      # then name the flag that settles it -- so this is that treatment, not a
      # new convention.
      {
        echo "agmsg: local team '$team' is a different team from the one on the server."
        echo "  local id:  $existing_id"
        echo "  server id: $team_id"
        # A fact, so it is said either way: the worst reading of a bare refusal
        # is that something was half-done.
        echo "Nothing local was changed."
        # The routes are the plain install's, so they are held back when a
        # caller owns the next step -- same split as everywhere else here.
        if agmsg_operator_guidance_is_ours; then
          # The first route must land somewhere the collision is not.
          # Re-running with --team-id and the SAME local name reproduces the
          # command that just failed: that flag picks between same-named teams
          # on the SERVER, and the local name is still taken either way. With a
          # free local name it is a route that completes -- and it is the one
          # that works even when the local team is connected and must not move.
          echo "Two ways forward:"
          echo "  keep your local '$team' and take the server's team under a free name:"
          echo "    bash $(agmsg_shq "$SKILL_DIR/scripts/remote.sh") pull --endpoint $(agmsg_shq "$endpoint") --team-id $(agmsg_shq "$team_id") <a-free-local-name>"
          # The second route frees THIS name, and only one of the two states can
          # take it. rename-team.sh is local only: it never reads or writes
          # `remote_binding` and never tells the server, so renaming a team that
          # is already connected leaves the binding naming the team the server
          # still knows by the old name. Which state the operator is in is
          # knowable here, so it is decided here rather than handed over as a
          # caveat to apply themselves.
          # STILL connected, which is not the same as "has ever connected".
          # A disconnected team keeps its `connected_at` and gains a
          # `disconnected_at`, so reading the first alone calls it connected
          # and withholds a route it is entitled to. This is the same predicate
          # `_remote_status_one` and `connect`'s re-adoption use: a binding is
          # live when it has a connected_at and no disconnected_at.
          local_connected="$(_remote_read_config_field "$cfg" '$.remote_binding.connected_at')"
          local_disconnected="$(_remote_read_config_field "$cfg" '$.remote_binding.disconnected_at')"
          if [ -n "$local_connected" ] && [ "$local_connected" != null ] \
            && { [ -z "$local_disconnected" ] || [ "$local_disconnected" = null ]; }; then
            echo "  renaming your local '$team' is NOT a way out: it is connected, and a"
            echo "  rename is local only — it does not tell the server, so the binding"
            echo "  would keep naming the team the server still knows by the old name."
          else
            echo "  or free this name first — your local '$team' is not connected, so:"
            echo "    bash $(agmsg_shq "$SKILL_DIR/scripts/rename-team.sh") $(agmsg_shq "$team") <a-new-name-for-it>"
            echo "  then pull again. Rename before connecting, never after: a rename is"
            echo "  local only and does not tell the server."
          fi
        fi
      } >&2
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
  #
  # stderr is NOT redirected here, on purpose (same as pull-bootstrap below):
  # the engine's own top-level handler already writes a specific message for
  # whatever actually went wrong -- a fetch failure, a protocol mismatch, a
  # malformed candidate -- and it needs to reach the operator, not get
  # replaced by a single line that names two different causes at once and
  # lets the reader guess which one happened.
  out="$("$SCRIPT_DIR/remote-sync.sh" resolve-team \
    --endpoint "$endpoint" --name "$name")"
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "agmsg: could not look up '$name'" >&2
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
  local cfg
  cfg="$(_remote_team_config "$team")"
  if [ -f "$cfg" ]; then
    # Asked through the storage driver, never in SQL from here.
    #
    # The old guard counted `FROM events WHERE type='message_sent'` itself.
    # Two things were wrong with that. The SQLite driver keeps history in TWO
    # shapes -- the event log and the legacy `messages` table, which api.sh
    # unions -- so on a legacy store the query failed on a missing table every
    # time; and `existing="$(...)"` is an assignment, not a `local`
    # declaration, so its status is the substitution's and `set -e` ended pull
    # right there. With `2>/dev/null` swallowing the reason the operator got
    # exit 1 and a blank screen, and the guard never once ran -- including for
    # the team it exists to refuse.
    #
    # Copying api.sh's union here would fix today's store and break again on
    # the next driver; JSONL and partition drivers are in the same contract.
    # So the question goes to whoever owns the answer:
    #
    #   no store        history zero, continue. That is a local shell with
    #                   nothing in it -- exactly what a caller leaves behind
    #                   when it creates the team and installs a key before
    #                   pulling. Asking must not CREATE one either: a read
    #                   that materialises an empty database is how "does it
    #                   exist" stops being answerable.
    #   store, empty    continue.
    #   store, any row  refuse, as before.
    #   cannot read     refuse, and say so. An unknown history rounded down to
    #                   empty is how a non-fast-forward guard stops guarding.
    local backend history_status=0 first_row
    backend="$(agmsg_storage_driver 2>/dev/null || printf 'unknown')"
    if ! agmsg_storage_load; then
      echo "agmsg: cannot load the '$backend' storage driver to check team '$team' for history" >&2
      echo "agmsg: refusing to pull rather than treat an unknown history as an empty one." >&2
      exit 1
    fi
    if storage_store_exists "$team" 2>/dev/null; then
      # --limit 1: whether there is any history, not how much. Nothing here
      # needs a count, and asking for one makes a large team pay for a yes/no.
      first_row="$(storage_history "$team" --limit 1 2>/dev/null)" || history_status=$?
      if [ "$history_status" -ne 0 ]; then
        echo "agmsg: cannot read the local history of team '$team' from the '$backend' store" >&2
        echo "agmsg: refusing to pull rather than treat an unreadable history as an empty one." >&2
        exit 1
      fi
      if [ -n "$first_row" ]; then
        echo "agmsg: local team '$team' already has history; pull clones into an empty team" >&2
        exit 1
      fi
    fi
  fi

  # The roster driver projects imported identity events into this config while
  # the bootstrap is running. Publish the empty identity-bearing shell first;
  # retries reuse it, and the successful projection is never overwritten.
  # The endpoint travels so the refusal above can print a `pull --team-id` line
  # that runs, rather than one with a placeholder the operator has to fill in
  # from memory.
  _remote_write_pulled_team "$team" "$team_id" "$endpoint" || exit 1

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
  local bind_at escaped caps_escaped updated archived_doc
  bind_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  escaped=$(sed "s/'/''/g" "$cfg")
  # This is the second wholesale writer of $.remote_binding (#849): a pull
  # into a team that already holds a binding to a DIFFERENT server would
  # otherwise replace it with no way back. Same archive primitive as
  # _remote_write_binding, so the non-destruction invariant holds at the
  # writer boundary, not just on the connect path.
  archived_doc="$(_remote_archive_replaced_binding "$escaped" \
    "$pulled_sid" "$pulled_id" "$pulled_protocol" "$bind_at")"
  escaped="$(printf '%s' "$archived_doc" | sed "s/'/''/g")"
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
  # Whether the engine runs is a question about THIS MACHINE, not about the
  # team. The old test was `age-v1 envelopes arrived` -- which says the team is
  # sealed, and nothing at all about whether the key to open it is here. Those
  # came apart the moment a caller could deliver the key before the pull: the
  # key was installed, the engine was halted anyway because ciphertext had
  # arrived, and the operator was told to go import key material they already
  # had. Nothing decrypted, because the thing that decrypts was the thing that
  # had been stopped.
  #
  # Whether a key is NEEDED comes from the server's declaration, not from how
  # many sealed envelopes happened to arrive. A team declared age-v1 with an
  # empty history needs the key for everything it is about to receive; gating
  # on the count skipped the check entirely for that team and started the
  # engine on a machine that cannot read a word of what comes next -- the same
  # "connected, reading nothing" this is meant to end, reached from the other
  # side.
  #
  # Anything that is not a clear `none` is treated as needing the key:
  #   age-v1                 declared sealed
  #   unknown / legacy       nobody has said; assuming plaintext is the
  #                          optimistic guess, and the optimistic guess is
  #                          what produces a silently unreadable team
  #   none + age envelopes   the declaration and the traffic disagree, and a
  #                          disagreement is not permission to proceed
  #
  # Asked once, here, and every line below is a description of this answer.
  local needs_key=0
  case "$binding_cipher" in
    none) [ "$pulled_age_v1" -gt 0 ] && needs_key=1 ;;
    *)    needs_key=1 ;;
  esac

  # Named for what it HOLDS. It is set when the key is missing, so the name
  # has to say "cannot": a reader who trusts a `can_read` that means the
  # opposite writes `[ "$can_read" -eq 1 ] && start_engine` and reopens the
  # hole this decision closed. The value was always right; the label was the
  # dangerous part.
  local cannot_read=0
  if [ "$needs_key" -eq 1 ] && ! _remote_holds_current_key "$team" "$cfg"; then
    cannot_read=1
  fi

  if [ "$cannot_read" -ne 0 ]; then
    echo "Pulled '$pulled_name' into local team '$team' ($imported message(s))."
    echo "This team is encrypted and this machine does not hold the key for its current epoch, so its sync engine is halted."
  else
    # Whether a start failure should end the command depends on what the command
    # was for: if the engine IS the purpose, not having one means the purpose was
    # not served and the command fails; if it is a side effect, the command
    # reports and returns. Pull's purpose is to bring the team here, and it has.
    # So this reports. (cmd_unlock exits 1 on the same failure for the opposite
    # reason -- its purpose is to make the team readable AND start syncing it.
    # The three are deliberately not uniform; making them uniform would be the
    # error.)
    local engine_started=1
    _remote_sync_engine_start "$team" || engine_started=0
    local engine_note=" Sync engine start requested (remote.sh status $team confirms)."
    [ "$engine_started" -eq 1 ] || engine_note=" The sync engine did not start; the reason is on stderr."
    if [ "$needs_key" -eq 1 ]; then
      # Says what was checked, and stops there. The identity for the current
      # epoch is here; messages sealed to an earlier key are a different
      # question and this did not ask it.
      echo "Pulled '$pulled_name' into local team '$team' ($imported message(s)).$engine_note"
      echo "This team is encrypted; this machine holds the key for its current epoch."
    else
      echo "Pulled '$pulled_name' into local team '$team' ($imported message(s)).$engine_note"
    fi
  fi
  if [ "$cannot_read" -ne 0 ]; then
    # The state, always. Dropping this would let a finished pull read as a
    # usable team, which is the worse failure of the two: the messages are
    # here and none of them can be read yet.
    echo "This team is local but locked."

    # The route, only when nobody else owns it. Both halves of this are the
    # plain install's: `remote.sh` is not on PATH -- it lives in this
    # install's scripts directory, whose name is whatever the install was
    # given -- and "the secret handoff bundle you were given" describes
    # material a caller's operator was never handed. Theirs arrives through a
    # different ceremony entirely, and telling them to go find a bundle sends
    # them looking for something that does not exist.
    #
    # --confirm-digest is named alongside --bundle because unlock refuses the
    # one without the other a few lines in. A route worth printing is one that
    # runs.
    if agmsg_operator_guidance_is_ours; then
      echo "Unlock it with the secret handoff bundle you were given:"
      echo "  bash $(agmsg_shq "$SKILL_DIR/scripts/remote.sh") unlock $(agmsg_shq "$team") --bundle <file> --confirm-digest <sha256>"
    fi
  else
    # The next instruction is "join with a new agent name", and the way an agent
    # picks a free one is by reading the roster. When the roster is empty that
    # instruction is worse than useless: every name looks available, including
    # the ones already answering on the other machine -- the exact collision
    # step 4 of docs/remote-setup.md exists to prevent (#743).
    #
    # Emptiness here is not a fault to be fixed by waiting longer in this
    # command. The roster arrives as messages, so it cannot exist until a
    # connected machine's engine has pushed them, and that machine may not be
    # running one yet. What this can do is stop implying otherwise.
    #
    # "ready for normal use" is withheld in that case rather than printed and
    # then qualified. It was the sentence the report quoted: a pull that says
    # ready, followed by a roster that says nobody, reads as a working team.
    if [ "$(_remote_local_roster_count "$(_remote_team_config "$team")")" -eq 0 ]; then
      echo "This team is local, but not yet usable for joining."
      echo "No members are known here yet. The roster travels as messages, so it"
      echo "appears once a connected machine's sync engine has pushed it -- not at"
      echo "the moment of this pull, and not from this machine's own effort."
      echo "Until then '$cmd_name' cannot tell you which names are taken, and a name"
      echo "you pick may already answer on the other machine. Re-run:"
      echo "  bash $(agmsg_shq "$SKILL_DIR/scripts/team.sh") $(agmsg_shq "$team")"
      echo "and join once it lists the members you expect."
    else
      echo "This team is now local and ready for normal use."
      echo "Open your agent and invoke its installed '$cmd_name' command, then join with a new agent name."
    fi
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
  # A refusal leaves REMOTE_SYNC_ENGINE_PID empty, which the readiness check
  # below already treats as "did not become ready" and reports with unlock's own
  # message. Tolerated here only because that handler exists.
  #
  # Detection is the handler's; the EXPLANATION is the refusal's, and it is
  # already on stderr by the time this runs -- `|| true` discards the status,
  # not the output, so the operator sees both the cause and the outcome. That
  # only holds while the refusal is printed BEFORE the return: move it after and
  # the two causes collapse into one message, which is the failure this whole
  # change is about.
  _remote_sync_engine_start "$team" || true
  local pid="${REMOTE_SYNC_ENGINE_PID:-}" ready=0 attempts=0
  while [ "$attempts" -lt 50 ]; do
    if [ -z "$pid" ] || ! _agmsg_pid_alive_local "$pid"; then
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
      ! _agmsg_pid_alive_local "$pid"; then
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
# _agmsg_pid_alive_local to tell a live engine from a stale pidfile.
#
# LOCAL, and that is not a detail. Every pid checked in this file came from `$!`
# in this shell, or was read back from the pidfile this shell wrote it to — and
# a pidfile does not move a number into another pid space. Under Git Bash those
# are MSYS pids, which `tasklist` has no record of, so the non-local probe
# answers "dead" for an engine that is running: the field report in #652, where
# `ps -W` found the process, the pidfile held the same number, and status still
# said stale. The rule is in instance-id.sh and it is about WHERE THE PID WAS
# MINTED, not about whether it arrived through a file. This leaves the
# pidfile lifecycle in two places (here and watch.sh); factoring it into a shared
# lib is intentionally deferred, not overlooked.
_remote_sync_engine_pidfile() { printf '%s' "$CONNECTION_ROOT/run/remote-sync.$1.pid"; }
# Written by the engine after a cycle completes (#756). Derived here the same way
# the pidfile is, because it has the same lifetime and the same owner.
_remote_sync_engine_cycle_stamp() { printf '%s' "$CONNECTION_ROOT/run/remote-sync.$1.cycles.json"; }
# Written by the engine when the server REFUSED, and removed by the engine on
# the next successful cycle (#773). Same directory, same derivation, same
# lifetime as the two above.
#
# The reason for its existence is that the reason was already on disk and
# unread: `event()` writes a `fatal` line into the run log with a timestamp,
# and nothing `status` opens has ever mentioned it. This is a place to read
# from, not a new place to write.
_remote_sync_engine_refusal() { printf '%s' "$CONNECTION_ROOT/run/remote-sync.$1.refusal.json"; }

# The refusal record, or nothing when a cycle has SINCE succeeded.
#
# THE READER DOES NOT TRUST THE DELETE. The engine removes this file after a
# successful cycle, and that removal is best-effort — an unwritable run
# directory, a permission change, a crash between the two writes. If the
# removal is the only thing standing between a reversed decision and the
# operator, then a failed removal reports a refusal that is no longer true,
# for ever, on every `status` (raised in review).
#
# So the file is not the answer; the file COMPARED TO THE LAST SUCCESSFUL
# CYCLE is. Deleting can fail. Comparing cannot. That makes this the stronger
# of the two guarantees — "it does not lie even when the delete failed" rather
# than "the delete is made certain" — and it is why the clear stays
# best-effort in the engine rather than growing a retry.
#
# The comparison is lexicographic on the two timestamps, which is exact
# because BOTH are written by the same engine in the same format (an ISO-8601
# UTC instant). It is not a general date comparison and must not be reused as
# one.
#
# With no cycle stamp there is nothing to compare against, and the refusal is
# reported: an engine that has refused and never succeeded is exactly the case
# the record exists for.
_remote_sync_engine_refusal_current() {
  local team="$1" file stamp last_cycle refused_at
  file="$(_remote_sync_engine_refusal "$team")"
  [ -f "$file" ] || return 0
  # Quiet on purpose: an unreadable record is ABSENT, and saying so on stderr
  # would put a parse error into the same stream a caller reads the JSON from
  # (measured — it turned the "unreadable reads as absent" case red).
  refused_at="$(_remote_read_config_field "$file" '$.at' 2>/dev/null)"
  [ -n "$refused_at" ] && [ "$refused_at" != "null" ] || return 0
  stamp="$(_remote_sync_engine_cycle_stamp "$team")"
  if [ -f "$stamp" ]; then
    last_cycle="$(_remote_read_config_field "$stamp" '$.last_success_at' 2>/dev/null)"
    if [ -n "$last_cycle" ] && [ "$last_cycle" != "null" ] && [[ "$last_cycle" > "$refused_at" ]]; then
      return 0
    fi
  fi
  cat "$file" 2>/dev/null || true
}

# _remote_holds_current_key <team> -> 0 when this machine holds the identity
# for the team's CURRENT epoch, 1 otherwise.
#
# What this measures, exactly, because the difference matters to what gets
# printed: the identity file for the epoch named in the config is present, and
# the recipient derived from it equals the recipient the config records for
# that epoch. That is "the key this team's current messages are sealed to is
# here and is the right one".
#
# It is NOT "every pulled message opens". A team that has rotated has older
# envelopes sealed to earlier keys, and this says nothing about those. The
# wording at the call site is held to that same line -- a check that proves
# one thing must not be reported as the other.
#
# No age binary, or a file that does not yield a recipient, answers 1: a
# machine that cannot derive the key cannot read with it either, and guessing
# in the optimistic direction is how "connected" came to mean "running
# nothing".
_remote_holds_current_key() {
  local team="$1" cfg="$2" key_id recipient identity derived
  key_id="$(_remote_read_config_field "$cfg" '$.remote_key.current.key_id')"
  recipient="$(_remote_read_config_field "$cfg" '$.remote_key.current.recipient')"
  case "$key_id" in ''|null) return 1 ;; esac
  case "$recipient" in ''|null) return 1 ;; esac
  identity="$CONNECTION_ROOT/run/remote-credentials/$team/keys/$key_id.key"
  [ -r "$identity" ] || return 1
  command -v age-keygen >/dev/null 2>&1 || return 1
  derived="$(age-keygen -y "$identity" 2>/dev/null)" || return 1
  [ -n "$derived" ] && [ "$derived" = "$recipient" ]
}

# Why a start failure has to be spoken here rather than left to the caller.
#
# This function used to end in `disown … || true`, so it always returned 0, and
# every caller was written around that. `cmd_sync_start` called it as
# `if ! _remote_sync_engine_start …`, where `set -e` is suspended — so a failed
# `echo > "$pidfile"` two lines from the end was stepped over, the function
# reported success, and the command died further down at `cat "$pidfile"` having
# printed nothing of its own. The others did not look at the return value at
# all. Measured with the run dir made unwritable: the caller saw success, then
# exit 1, silent.
#
# Five callers now, and they are deliberately not uniform — the rule is whether
# the engine is what the command was FOR:
#
#   cmd_sync_start    `if ! …`     the engine is the purpose; the command fails
#   cmd_unlock        `|| true`    same, but its own readiness handler converts
#                                  the empty pid into unlock's failure, and the
#                                  refusal is already on stderr by then
#   cmd_pull          capture      purpose already served; reports
#   cmd_connect       capture      purpose already served; reports
#   cmd_set_endpoint  capture      purpose already served; reports
#
# Derive the set before trusting it: `grep -n '_remote_sync_engine_start "'`.
# set-endpoint arrived while this change was in review, as a bare call, and the
# rebase that brought it did not conflict.
#
# The tolerant `mkdir … || true` was half of it. Tolerating the directory and
# then writing into it unguarded moves the failure to a line that cannot
# explain itself. Both halves are checked below, and the writability of the
# pidfile is proven BEFORE the engine is spawned — a spawn whose pidfile cannot
# be written produces an engine no `status` can see and no `stop` can reach.
_remote_sync_engine_start_refused() {
  local team="$1" path="$2" why="$3"
  {
    echo "agmsg: could not start the sync engine for '$team': $why"
    echo "  $path"
    echo "  Nothing is syncing for this team: messages written here will not"
    echo "  reach the server, and new ones will not arrive, until an engine runs."
    echo "  If this machine sandboxes the agent (Codex does), that directory has"
    echo "  to be writable by it. Then run:"
    echo "    remote.sh sync start $(agmsg_shq "$team")"
  } >&2
}

_remote_sync_engine_start() {
  local team="$1"
  # Skipped only when THIS PROCESS took the lock on the way in, proved by a flag
  # a caller sets after its own successful acquire -- not by `AGMSG_HELD_LOCKS`.
  # That variable is seeded from the environment (registry-lock.sh:27), so
  # anything upstream can export it and be believed, and a substring test over it
  # would additionally let one team's lock path vouch for another's when one name
  # is a prefix of the other. Ownership has to be something this process did, not
  # something it was told.
  # `agmsg_lock_acquire` installs its own EXIT/INT/TERM traps, and its comment
  # says so: "no current registry writer sets its own trap; a future caller that
  # does must chain these in." Acquiring here made that false. `cmd_unlock` sets
  # an EXIT trap to remove the handoff temp directory, and this acquire replaced
  # it -- the directory survived every unlock that reached an engine start, which
  # is how the suite caught it: an unrelated test asserts no such directory is
  # left anywhere in $TMPDIR.
  #
  # So the caller's trap is saved before the acquire and restored after the
  # release, and the window between them is exactly the critical section the
  # library's own traps are there to protect.
  local lock_taken=0 saved_traps=""
  if [ "${_REMOTE_ENGINE_CALLER_HOLDS_LOCK:-0}" != "1" ] && [ -d "$TEAMS_DIR/$team" ]; then
    # All THREE that the acquire overwrites, not just EXIT. `cmd_unlock` sets
    # its cleanup on EXIT INT TERM HUP; restoring EXIT alone leaves the
    # library's `agmsg_lock_release; exit 130` on INT and its TERM twin in
    # place, so a Ctrl-C during an unlock would exit without removing the
    # handoff directory -- the same leak this chaining was added to stop, on the
    # paths nobody presses on a good day. (HUP is not touched by the acquire, so
    # the caller's HUP handler survives on its own.)
    saved_traps="$(trap -p EXIT INT TERM)"
    if agmsg_lock_acquire "$TEAMS_DIR/$team"; then
      lock_taken=1
    else
      # The acquire has already said why on stderr. A start that cannot
      # serialise itself is refused rather than run unserialised: the failure
      # this covers is two live engines, and "probably alone" is not a property
      # anything downstream can check.
      _remote_sync_engine_start_refused "$team" "$TEAMS_DIR/$team" \
        "its team lock could not be acquired, so a second engine could start alongside this one"
      return 1
    fi
  fi

  # The lock is released on EVERY exit, so the work is a separate function and
  # this one is the only place that unlocks. Written inline it would need the
  # release repeated at six returns and the success path; one of those is how
  # a lock gets held for the life of a shell.
  local rc=0
  _remote_sync_engine_start_locked "$@" || rc=$?
  # `if`, not `[ ] && release`: under `set -e` an AND-OR list whose first half
  # is false makes the list false, and the list is a command like any other.
  # Releases the ONE lock this function took. `agmsg_lock_release` drops every
  # lock the process holds, and the library's contract is that a caller may hold
  # several: releasing all of them here would take locks away from an operation
  # that is still using them.
  if [ "$lock_taken" -eq 1 ]; then
    agmsg_lock_release_one "$TEAMS_DIR/$team"
    # Put back whatever the caller had, including "nothing": leaving the
    # library's `agmsg_lock_release` on EXIT would also make a later exit drop
    # locks this function never took.
    # Clear all three first, then replay whatever the caller had. `trap -p`
    # prints nothing for a signal with no handler, so replaying alone would
    # leave the library's handler on any signal the caller had not set.
    trap - EXIT INT TERM
    if [ -n "$saved_traps" ]; then eval "$saved_traps"; fi
  fi
  return "$rc"
}

_remote_sync_engine_start_locked() {
  local team="$1" startup_nonce="${2:-}" pidfile logfile old_pid old_state rundir
  pidfile="$(_remote_sync_engine_pidfile "$team")"
  logfile="$CONNECTION_ROOT/run/remote-sync.$team.log"
  rundir="$CONNECTION_ROOT/run"

  # One engine per team, enforced where the invariant lives rather than at each
  # caller. Everything from here to the pidfile write is check-then-act -- read
  # the old pid, decide it is ours, kill it, truncate, spawn, record -- and two
  # callers inside that window both spawn. The pidfile then names the second,
  # and the FIRST is invisible to `status` and unreachable by `stop`: the orphan
  # state this file guards against elsewhere, produced by the guard's own gap.
  #
  # Of the five callers, only `sync start` held the lock across its spawn.
  # `pull`, `connect`, `unlock` and `set-endpoint` did not -- pull releases at
  # line 934 and spawns at 998, and the other three never take it at all (#762).
  #
  # Taken here, so a caller cannot forget, and skipped when this process already
  # holds it: the lock is a mkdir and is NOT reentrant, so acquiring it under
  # `sync start` would spin until its own timeout and then refuse to start an
  # engine because of a lock it is holding itself.
  # Cleared first: this is a global, and the early returns below happen before
  # any spawn. Left alone, a caller that reads it after a refusal would get the
  # pid of whatever this function started the previous time it was called.
  REMOTE_SYNC_ENGINE_PID=""
  if ! mkdir -p "$rundir" 2>/dev/null; then
    _remote_sync_engine_start_refused "$team" "$rundir" \
      "its run directory could not be created"
    return 1
  fi
  # The cycle record has to be clearable before anything is signalled.
  #
  # A start that will refuse must refuse while it is still free: past this point
  # the previous engine is killed, and a refusal after that has taken down a
  # working engine for a bookkeeping reason. So the pathological shapes are
  # rejected here, where the cost of being wrong is a message.
  #
  # "Clearable" means absent or a plain file. Anything else is refused rather
  # than removed: a directory cannot be removed by `rm -f` at all, and a symlink
  # is worse than unremovable -- the engine writes THROUGH it, so a link left in
  # place turns this record into a write to wherever it points. `-L` is tested
  # before `-e` because `-e` follows the link and calls a dangling one absent,
  # which would let exactly that case past (#756).
  local cycle_stamp
  cycle_stamp="$(_remote_sync_engine_cycle_stamp "$team")"
  if [ -L "$cycle_stamp" ] || { [ -e "$cycle_stamp" ] && [ ! -f "$cycle_stamp" ]; }; then
    _remote_sync_engine_start_refused "$team" "$cycle_stamp" \
      "the previous engine's cycle record is not a plain file, so it cannot be cleared and its successes would be read as this engine's"
    return 1
  fi
  # Stop only an engine whose argv proves that it owns this team. A stale
  # pidfile may point at a recycled, unrelated process and must never authorize
  # signalling that process.
  IFS=$'\t' read -r old_state old_pid < <(AGMSG_SKIP_SYSTEMD_PROBE=1 _remote_sync_engine_status "$team")
  if [ "$old_state" = "running" ]; then
    kill "$old_pid" 2>/dev/null || true
  fi
  # The cycle record belongs to the engine that made it, and this is where a new
  # one begins. Clearing it on STOP is not enough: an engine that crashes, is
  # killed, or leaves a stale pidfile never runs that path, so its record would
  # still be on disk when the replacement starts -- and `status` would attribute
  # a predecessor's success to an engine that has not completed a cycle yet.
  #
  # The shape was accepted before anything was signalled; the removal happens
  # HERE, after the old engine is dead, because an engine that is still alive can
  # write the record again between the clear and its own exit.
  #
  # Still checked, and the check is absence rather than rm's exit code: `rm -f`
  # reports success for a file that was not there (which is fine) and failure for
  # one it cannot remove -- e.g. under a parent that turned unwritable since the
  # precondition. Absence is tested lexically, `! -e` AND `! -L`, because `-e`
  # follows a symlink and calls a dangling one absent.
  #
  # It runs before the pidfile is truncated, so a refusal leaves no ownership
  # claim behind: an engine that will not start must not look like one that owns
  # this team (#756).
  rm -f "$cycle_stamp" 2>/dev/null || true
  if [ -e "$cycle_stamp" ] || [ -L "$cycle_stamp" ]; then
    _remote_sync_engine_start_refused "$team" "$cycle_stamp" \
      "the previous engine's cycle record could not be removed, and starting now would report its successes as this engine's"
    return 1
  fi
  # Writability proven before the spawn -- but AFTER the block above, not before
  # it. Truncating the pidfile first destroys the pid that _remote_sync_engine_status
  # reads to decide whether an old engine owns this team, so the old one is never
  # signalled and survives the restart: the orphan this guard exists to prevent,
  # manufactured by the guard. Caught by test_remote.bats "remote unlock … resumes
  # age-v1 sync"; by this point the previous engine has already been identified
  # and killed, so the truncation costs nothing.
  if ! : > "$pidfile" 2>/dev/null; then
    _remote_sync_engine_start_refused "$team" "$pidfile" \
      "its pidfile could not be written"
    return 1
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
  if ! echo "$REMOTE_SYNC_ENGINE_PID" > "$pidfile" 2>/dev/null; then
    # The engine is already running at this point. Leaving it without a pidfile
    # is the orphan state: invisible to status, and _remote_sync_engine_stop
    # returns 0 without looking for it. Take it back down rather than create one.
    kill "$REMOTE_SYNC_ENGINE_PID" 2>/dev/null || true
    REMOTE_SYNC_ENGINE_PID=""
    _remote_sync_engine_start_refused "$team" "$pidfile" \
      "its pidfile could not be written, so the engine was stopped again"
    return 1
  fi
  disown 2>/dev/null || true
}

_remote_sync_engine_stop() {
  local team="$1" pidfile pid state
  pidfile="$(_remote_sync_engine_pidfile "$team")"
  [ -f "$pidfile" ] || return 0
  IFS=$'\t' read -r state pid < <(AGMSG_SKIP_SYSTEMD_PROBE=1 _remote_sync_engine_status "$team")
  if [ "$state" = "running" ]; then
    if ! _remote_sync_engine_reap_owned "$team" "$pid"; then
      echo "agmsg: sync engine pid $pid did not stop" >&2
      return 1
    fi
  fi
  rm -f "$pidfile"
  # The cycle record goes with the engine that made it. Left behind, the NEXT
  # engine's first `status` would report a predecessor's success as its own --
  # which is the exact claim this record was added to stop anyone making (#756).
  #
  # Quiet, and NOT this function's exit status. Written as a bare `rm -f` it was
  # both: an unclearable record made a successful stop report failure, and
  # set-endpoint then refused to move an endpoint over a piece of bookkeeping,
  # after the engine it was protecting had already been stopped. This function
  # promises one thing -- the engine is not running -- and that promise was kept
  # in every case where this line spoke. The start path is where an unclearable
  # record has to block, because that is where a stale one could be misread.
  rm -f "$(_remote_sync_engine_cycle_stamp "$team")" 2>/dev/null || true
}

# Return the systemd user-unit state as "state<TAB>pid".
#
# A unit that is not installed is not a systemd-managed team here, so callers
# retain the pidfile behavior. An existing unit is different: an active unit
# whose MainPID cannot be authenticated is UNKNOWN and must not be shadowed by
# a new unmanaged engine. The command can be replaced in tests; no host
# systemd query is needed there.
_remote_systemd_engine_status() {
  local team="$1" unit show load active sub pid command systemctl_bin
  unit="agmsg-remote-sync-$team.service"
  systemctl_bin="${AGMSG_SYSTEMCTL:-systemctl}"
  command -v "$systemctl_bin" >/dev/null 2>&1 || { printf 'unavailable\t\n'; return; }
  show="$($systemctl_bin --user show "$unit" -p LoadState -p ActiveState -p SubState -p MainPID 2>/dev/null)" || {
    printf 'absent\t\n'
    return
  }
  load="$(printf '%s\n' "$show" | sed -n 's/^LoadState=//p')"
  active="$(printf '%s\n' "$show" | sed -n 's/^ActiveState=//p')"
  sub="$(printf '%s\n' "$show" | sed -n 's/^SubState=//p')"
  pid="$(printf '%s\n' "$show" | sed -n 's/^MainPID=//p')"
  [ "$load" = "not-found" ] && { printf 'absent\t\n'; return; }
  case "$active:$sub" in
    active:running)
      if _agmsg_pid_valid "$pid" && _agmsg_pid_alive_local "$pid"; then
        command="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
        if agmsg_cmdline_names_path "$command" "$SCRIPT_DIR/internal/remote-sync.mjs" &&
           case "$command" in *" run --team $team") true ;; *) false ;; esac; then
          printf 'running\t%s\n' "$pid"
        else
          printf 'unknown\t%s\n' "$pid"
        fi
      else
        printf 'unknown\t%s\n' "$pid"
      fi
      ;;
    active:starting|active:reloading|active:auto-restart|activating:*|deactivating:*)
      printf 'starting\t%s\n' "$pid"
      ;;
    inactive:*|failed:*)
      printf 'inactive\t%s\n' "$pid"
      ;;
    *)
      printf 'unknown\t%s\n' "$pid"
      ;;
  esac
}

# Print "<state>\t<pid>", where pid is empty when no valid pid is available.
# A live PID is not enough: PID reuse can make an unrelated process pass
# kill -0, so running requires the exact engine script/team suffix in argv.
_remote_sync_engine_status() {
  local team="$1" pidfile pid command expected systemd_state systemd_pid
  REMOTE_SYNC_ENGINE_SUPERVISOR=""
  REMOTE_SYNC_ENGINE_SUPERVISOR_PID=""
  if [ "${AGMSG_SKIP_SYSTEMD_PROBE:-0}" != 1 ]; then
    IFS=$'\t' read -r systemd_state systemd_pid < <(_remote_systemd_engine_status "$team")
  else
    systemd_state=absent
  fi
  case "$systemd_state" in
    running|starting|inactive|unknown)
      REMOTE_SYNC_ENGINE_SUPERVISOR="systemd"
      REMOTE_SYNC_ENGINE_SUPERVISOR_PID="$systemd_pid"
      printf '%s\t%s\n' "$systemd_state" "$systemd_pid"
      return
      ;;
  esac
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
  if ! _agmsg_pid_alive_local "$pid"; then
    printf 'stale\t%s\n' "$pid"
    return
  fi
  command="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
  # Two conditions where there was one suffix match, and neither one is written
  # in a path alphabet: the cmdline has to NAME the engine script -- asked
  # through the comparator, which knows the OS may spell that path its own way
  # (#652) -- and it has to END with this team's arguments, which is what kept
  # another team's engine from answering for this one.
  if agmsg_cmdline_names_path "$command" "$SCRIPT_DIR/internal/remote-sync.mjs" &&
     case "$command" in *" run --team $team") true ;; *) false ;; esac; then
    printf 'running\t%s\n' "$pid"
  else
    printf 'stale\t%s\n' "$pid"
  fi
}

_remote_sync_engine_reap_owned() {
  local team="$1" owned_pid="$2" state pid signal attempts
  for signal in TERM KILL; do
    IFS=$'\t' read -r state pid < <(AGMSG_SKIP_SYSTEMD_PROBE=1 _remote_sync_engine_status "$team")
    if ! _agmsg_pid_alive_local "$owned_pid"; then return 0; fi
    [ "$state" = "running" ] && [ "$pid" = "$owned_pid" ] || return 1
    kill "-$signal" "$owned_pid" 2>/dev/null || true
    attempts=0
    while [ "$attempts" -lt 100 ]; do
      _agmsg_pid_alive_local "$owned_pid" || return 0
      attempts=$((attempts + 1))
      sleep 0.01
    done
  done
  ! _agmsg_pid_alive_local "$owned_pid"
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
  snapshot_sha="$(agmsg_sha256 < "$snapshot_file")"
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
  # Asked HERE: before the key is minted and before the registration POST.
  # Every SHA-256 in the e2ee path -- the fingerprint printed by `key.sh
  # generate`, and the age-v1 checkpoint that starts the sync engine -- happens
  # at or after those, so a device without one used to register the team and
  # only then fail, reporting "binding recorded, sync engine not started" for
  # what is a missing command-line tool. Same category as the `age` preflight:
  # a prerequisite of end-to-end encryption, so it is only asked under --e2ee.
  if [ "$e2ee" -eq 1 ]; then
    agmsg_require_sha256 || exit 1
  fi
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
  #
  # Connect's purpose is the binding, and the binding is written by this point,
  # so a start failure reports rather than fails the command -- same rule as
  # cmd_pull, opposite of cmd_unlock, and the note there explains why the three
  # differ. What it must not do is end by saying the engine runs: the line below
  # made that claim unconditionally, from a function that could not fail.
  local engine_started=1
  _remote_sync_engine_start "$team" || engine_started=0

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
  # "start requested", not "running": all this path knows is that the engine was
  # spawned and its pid recorded. The child can still die on its own -- a log
  # redirection it cannot make, a Node that will not start -- and nothing here
  # waits to find out. Confirming would mean a readiness wait of up to 16s in a
  # command whose purpose is the binding, not the engine; the sentence is
  # narrowed instead, and points at the command that does check. Saying
  # "running" from a check that only proves "spawned" is the defect this change
  # exists to remove, one step smaller. Found in review.
  #
  # Names the stream, not a position. The refusal goes to stderr and this line
  # to stdout, so "above" is only true on a terminal that interleaves them --
  # `remote.sh connect … | tee log` puts them in different places, and a note
  # that points at nothing is the kind of sentence this change exists to remove.
  local engine_note=" Sync engine start requested (remote.sh status $team confirms)."
  [ "$engine_started" -eq 1 ] || engine_note=" The sync engine did not start; the reason is on stderr."
  echo "Connected: team '$team'$server_side ($connection_security).$engine_note"
  # Carrying the snapshot and key by hand is the plain install's answer to
  # getting a second machine in. A larger tool may have a ceremony for exactly
  # that, and this line would talk its operator out of it -- into doing by hand
  # the thing the ceremony exists to make unnecessary. So it is said only when
  # nobody else owns the next step.
  if [ "$e2ee" -eq 1 ] && agmsg_operator_guidance_is_ours; then
    # The bundle, not the snapshot pair (#668). Both are accepted by `unlock`
    # and that has not changed; what changed is which one this screen names.
    #
    # It named the snapshot, and `pull` on the other machine asks for "the
    # secret handoff bundle you were given" -- so each side named the other's
    # route and an operator following the screens produced the wrong artifact.
    #
    # The bundle wins on a measurement rather than a preference: the snapshot
    # route needs the private key too, and the only command that hands it over
    # is `key.sh show --reveal-secret`, which refuses without a TTY. The
    # walkthrough that leads here tells the reader to drive this with an agent,
    # so that route stops at its second step for the reader it is written for.
    # `key.sh handoff` needs no terminal, is one artifact instead of two, and
    # is the one `unlock` gates behind a confirmed digest.
    echo "Export one secret handoff bundle for the other machine:"
    echo "  bash $(agmsg_shq "$SKILL_DIR/scripts/key.sh") handoff $(agmsg_shq "$team") --out <file>"
    echo "That file IS the key: transfer it only through a channel you trust, and never"
    echo "into agent chat. Compare the snapshot digest it prints over a separate live"
    echo "channel — the other machine's unlock refuses the bundle without it."
  fi
}

# --- status --------------------------------------------------------------

# _remote_config_shape_ok <content> -> true (0) if <content> parses as a
# JSON OBJECT; false (1) for invalid JSON, or valid JSON that isn't an
# object (`[]`, `null`, `42`, `"text"`). The ONE predicate both status
# forms call for this question (review): a first version of this fix put
# an equivalent check only on the human-text path (as bash+sqlite), while
# _remote_status_json_one kept its own separate python
# `isinstance(cfg, dict)` check. Two implementations of one question drift
# -- exactly what happened here: tightening the --json side's check left
# the human side still falling through to json_extract-returns-null,
# rc=1 "never connected", for the same file the --json side correctly
# called unreadable. Same structural mistake as #722 (two independent
# implementations of one endpoint-validity question), fixed the same way:
# collapse to one function, both callers use its answer.
#
# Takes CONTENT, not a path, on purpose: _remote_status_json_one already
# does one locked read of the file for its own strict-ABI reasons (see its
# header comment) and must not read it a second time here, unlocked --
# that would reopen exactly the TOCTOU race that single read exists to
# close. Callers that only have a path (the human-text side) read the
# file themselves and pass the content in.
#
# `json_type` only runs inside the CASE branch taken when json_valid is
# true (SQLite's CASE WHEN is lazy per-branch), specifically so it is
# never asked to type a string that failed to parse at all -- evaluating
# it unconditionally would risk erroring on the same invalid input this
# function exists to classify, rather than answering false.
_remote_config_shape_ok() {
  local content="$1" escaped top_type
  escaped=$(printf '%s' "$content" | sed "s/'/''/g")
  top_type=$(agmsg_sqlite_mem "SELECT CASE WHEN json_valid('$escaped') THEN json_type('$escaped') ELSE 'invalid' END;" 2>/dev/null || echo "")
  [ "$top_type" = "object" ]
}

# _remote_config_malformed <cfg> -> true (0) when the file EXISTS but its
# content does not satisfy _remote_config_shape_ok; false (1) when it's
# missing (the ordinary "never connected" case _remote_read_config_field
# already answers with "null") or genuinely a valid object. #650: a config
# that exists but cannot be read is a FAILURE, not the same answer as
# "there is nothing to read" -- callers below must check this before
# treating field-read results as meaningful, or a parse failure quietly
# reads as "no binding" (and, via _remote_read_config_field, leaks a raw
# sqlite error line onto stdout/stderr first).
_remote_config_malformed() {
  local cfg="$1"
  [ -f "$cfg" ] || return 1
  _remote_config_shape_ok "$(cat "$cfg" 2>/dev/null)" && return 1
  return 0
}

_remote_status_one() {
  local team="$1" cfg connected_at disconnected_at write_allowed_ciphers key_id \
    binding_cipher engine_state engine_pid
  cfg="$(_remote_team_config "$team")"
  if _remote_config_malformed "$cfg"; then
    return 2
  fi
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
    starting)
      echo "$team	connected (engine starting under systemd, pid $engine_pid; do not run sync start) since $connected_at" ;;
    inactive)
      echo "$team	connected (engine inactive under systemd; run: systemctl --user restart agmsg-remote-sync-$team.service) since $connected_at" ;;
    unknown)
      echo "$team	connected (engine state unknown under systemd; do not run sync start; inspect systemctl --user status agmsg-remote-sync-$team.service) since $connected_at" ;;
    stopped)
      echo "$team	connected (engine stopped — run: bash $(agmsg_shq "$SKILL_DIR/scripts/remote.sh") sync start $(agmsg_shq "$team")) since $connected_at" ;;
    stale)
      # Names the command, exactly as `stopped` does. The asymmetry mattered:
      # `stopped` is what an operator reaches by stopping the engine themselves,
      # and `stale` is what a REBOOT leaves — so the branch with no remedy was
      # the one reached by someone who did nothing and has the least idea what
      # to type (#761).
      if [ -n "$engine_pid" ]; then
        echo "$team	connected (engine stale — pidfile $engine_pid points at a dead or foreign process; run: bash $(agmsg_shq "$SKILL_DIR/scripts/remote.sh") sync start $(agmsg_shq "$team")) since $connected_at"
      else
        echo "$team	connected (engine stale — pidfile does not contain a valid process id; run: bash $(agmsg_shq "$SKILL_DIR/scripts/remote.sh") sync start $(agmsg_shq "$team")) since $connected_at"
      fi
      ;;
  esac
  # Connected, and unable to name anybody.
  #
  # `status` could say "engine running" indefinitely while `team.sh` said
  # `0 member(s)`, and neither line was wrong -- the process was alive and the
  # roster was empty. What was missing was anything connecting the two, so the
  # state read as a working team with no members rather than as a wait (#743).
  #
  # Only the empty case is reported, because it is the only one this can
  # establish without asking the server: a partial roster is indistinguishable
  # from a complete small one from here. The engine, which holds both numbers,
  # logs `roster.incomplete` with the missing names.
  if [ "$(_remote_local_roster_count "$cfg")" -eq 0 ]; then
    echo "		roster: no members known here yet — it arrives from a connected machine's engine"
  fi
  # Whether anything has actually synced, as opposed to whether a process is up.
  #
  # `engine running` says the process is alive, which is true and is not the
  # question. An engine that has never completed a cycle and one that completed a
  # cycle four seconds ago were indistinguishable here, and in #744's report the
  # first case ran for an entire session while this line said `running` (#756).
  #
  # Only for a running engine: for a stopped one the line above already says the
  # useful thing, and "no cycles" beside "engine stopped" reads as a second fault
  # rather than the same one.
  if [ "$engine_state" = "running" ]; then
    local stamp last_cycle
    stamp="$(_remote_sync_engine_cycle_stamp "$team")"
    last_cycle="$(_remote_read_config_field "$stamp" '$.last_success_at')"
    if [ -z "$last_cycle" ] || [ "$last_cycle" = "null" ]; then
      # Says what is absent, not what did not happen. The record is written
      # best-effort, so its absence covers three states this cannot tell apart:
      # no cycle has completed, one completed seconds ago and the write has not
      # landed, or the run directory is unwritable and cycles are succeeding
      # unrecorded. "nothing has synced yet" picks one of the three and asserts
      # it -- a claim wider than the check, which is the defect this whole line
      # exists to remove from `status` rather than to reintroduce.
      echo "		cycles: no successful cycle recorded since this engine started"
    else
      echo "		cycles: last successful sync $last_cycle"
    fi
  fi
  # WHY IT IS NOT SYNCING, when the server has said so (#773).
  #
  # Printed for a running engine AND a stopped one: a refusal recorded by an
  # engine that has since been stopped is still the last thing the server said,
  # and the operator asking "why" is owed it either way.
  #
  # REPEATED, NOT INTERPRETED. The status and the code are the server's words.
  # This client talks to *a* remote — self-hosted, someone else's, or a service
  # — and cannot know what a particular one means by a particular code. A
  # sentence invented here is wrong for some server. What it may add is where
  # the operator of that server would be reached, which is the host the
  # binding already names.
  local refusal_raw refusal_status refusal_code refusal_at refusal_host
  # Through the currency check, not straight off the file — see the helper.
  refusal_raw="$(_remote_sync_engine_refusal_current "$team")"
  if [ -n "$refusal_raw" ]; then
    local refusal_file="$(_remote_sync_engine_refusal "$team")"
    refusal_status="$(_remote_read_config_field "$refusal_file" '$.status')"
    refusal_code="$(_remote_read_config_field "$refusal_file" '$.code')"
    refusal_at="$(_remote_read_config_field "$refusal_file" '$.at')"
    refusal_host="$(_remote_read_config_field "$refusal_file" '$.endpoint_host')"
    if [ -n "$refusal_status" ] && [ "$refusal_status" != "null" ]; then
      echo "		refused: the server answered $refusal_status${refusal_code:+ $refusal_code} at $refusal_at"
      if [ -n "$refusal_host" ] && [ "$refusal_host" != "null" ]; then
        echo "		         that server is $refusal_host — what the answer means is theirs to say"
      fi
    fi
  fi
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
  # What this team was bound to before, and when it was replaced (#849). The
  # archived binding is the only pointer back to that server's local sync rows
  # and keys, so a repair must not depend on the operator remembering the URL.
  #
  # Displayed through _remote_endpoint_display, which keeps scheme/host/port
  # and DROPS the path -- for a hosted endpoint the path IS the capability.
  # That means the printed form is NOT the value to reconnect with; the exact
  # endpoint stays in the team's config, and the trailing line says so instead
  # of pretending the display is it.
  #
  # One JSON object per row, NOT tab-separated fields: validateEndpoint now
  # refuses raw control bytes, but a binding written by an OLDER version can
  # hold an endpoint carrying them, and the archive keeps whatever the binding
  # held. JSON escapes every byte below 0x20, so a row is one line whatever
  # the endpoint contains; the per-field extraction below re-reads each row as
  # JSON, and the printed values are additionally stripped of control bytes so
  # nothing steers the terminal.
  local prev_row prev_endpoint prev_replaced prev_any=0
  while IFS= read -r prev_row; do
    [ -n "$prev_row" ] || continue
    prev_endpoint="$(agmsg_sqlite_mem \
      "SELECT json_extract('$(printf '%s' "$prev_row" | sed "s/'/''/g")', '\$.e');")"
    prev_replaced="$(agmsg_sqlite_mem \
      "SELECT json_extract('$(printf '%s' "$prev_row" | sed "s/'/''/g")', '\$.a');")"
    prev_endpoint="$(_remote_endpoint_display "$prev_endpoint")"
    prev_endpoint="${prev_endpoint//[[:cntrl:]]/}"
    prev_replaced="${prev_replaced//[[:cntrl:]]/}"
    prev_any=1
    echo "		previous: was bound to $prev_endpoint until $prev_replaced"
  done < <(agmsg_sqlite_mem \
    "SELECT json_object('e', json_extract(value, '\$.endpoint'),
                        'a', coalesce(json_extract(value, '\$.replaced_at'), 'an unrecorded time'))
       FROM json_each(coalesce(json_extract('$(sed "s/'/''/g" "$cfg")', '\$.previous_bindings'), '[]'));")
  if [ "$prev_any" -eq 1 ]; then
    echo "		          to restore one, reconnect to its full endpoint — it is kept under previous_bindings in this team's config.json, and is not printed here because it can embed the access token"
  fi
}

# _remote_status_json_one <team> — prints one JSONL object for <team>'s
# binding. Return code carries which of two different answers a caller got
# (#650): 1 means the team has never been connected (no config, or a valid
# config with no remote_binding) -- ordinary, matches _remote_status_one's
# own gate. 2 means the team's config could not actually be read (its lock
# could not be acquired, or its file exists but is not parseable JSON) --
# a FAILURE distinct from "never connected", because a caller enumerating
# every locally-known team (e.g. deciding what to back up) must not treat a
# team it failed to read as identical to one that was genuinely never bound.
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
# Reads config.json exactly ONCE (delta review, ported from
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

  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 2
  raw="$(cat "$cfg" 2>/dev/null)"
  agmsg_lock_release

  # Authoritative shape gate (review, #650): the same _remote_config_shape_ok
  # the human-text path uses, called here against the already-locked-read
  # $raw rather than re-reading the file. Python's own json.loads/isinstance
  # below stays as defensive-only belt-and-suspenders after this -- it should
  # never actually trigger once this has passed, but a shell string escape
  # and a SQLite JSON parser are not literally the same implementation as
  # Python's, so it stays rather than assuming they can never disagree.
  _remote_config_shape_ok "$raw" || return 2

  IFS=$'\t' read -r engine_state engine_pid < <(_remote_sync_engine_status "$team")
  # THE SURFACE AN AGENT READS (#773).
  #
  # Someone asks their agent "why isn't this syncing?" and the agent has to be
  # able to answer. `/agmsg remote status` runs this with `--json`, and it is
  # the only thing an agent consults about the engine — so the refusal has to
  # be here, not only in a line a human reads.
  #
  # Passed as a whole file rather than as parsed fields: whatever the engine
  # recorded is what the reader gets, and adding a field there does not need a
  # change here.
  # Same currency check as the human line, from the same helper: the two must
  # not be able to disagree about whether a refusal still stands.
  local refusal_raw
  refusal_raw="$(_remote_sync_engine_refusal_current "$team")"
  printf '%s' "$raw" | REFUSAL_JSON="$refusal_raw" python3 -c '
import json, os, sys
team, engine_state, engine_pid_text = sys.argv[1:4]
try:
    cfg = json.loads(sys.stdin.read())
except Exception:
    sys.exit(2)
if not isinstance(cfg, dict):
    sys.exit(2)
binding = cfg.get("remote_binding")
if not isinstance(binding, dict) or not binding.get("connected_at"):
    sys.exit(1)
state = "disconnected" if binding.get("disconnected_at") else "active"
engine_pid = int(engine_pid_text) if engine_pid_text else None
if state == "disconnected":
    engine_state = "stopped"
    engine_pid = None
try:
    refusal = json.loads(os.environ.get("REFUSAL_JSON") or "null")
except Exception:
    refusal = None
if not isinstance(refusal, dict):
    refusal = None
print(json.dumps({
    "local_team": team,
    "endpoint": binding.get("endpoint"),
    "server_instance_id": binding.get("server_instance_id"),
    "remote_team_id": binding.get("remote_team_id"),
    "credential_id": binding.get("credential_id"),
    "state": state,
    "engine_state": engine_state,
    "engine_pid": engine_pid,
    # null when the server has refused nothing, or when what was recorded
    # cannot be read. An unreadable record is reported as absent rather than
    # guessed at; the human line above is derived from the same file.
    "refusal": refusal,
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
    local rc=0
    if [ "$json" -eq 1 ]; then
      _remote_status_json_one "$team" || rc=$?
    else
      _remote_status_one "$team" || rc=$?
    fi
    case "$rc" in
      0) : ;;
      2) echo "agmsg: team '$team' could not be read -- its config exists but could not be parsed (or its lock could not be acquired); connection state is unknown, not confirmed unconnected (#650)" >&2; exit 2 ;;
      *) echo "agmsg: team '$team' has never been connected" >&2; exit 1 ;;
    esac
    return
  fi

  local any=0 t
  if [ ! -d "$TEAMS_DIR" ]; then
    [ "$json" -eq 1 ] || echo "No teams found."
    return
  fi
  local rc
  for t in "$TEAMS_DIR"/*/; do
    [ -d "$t" ] || continue
    t="$(basename "$t")"
    if [ "$json" -eq 1 ]; then
      rc=0; _remote_status_json_one "$t" || rc=$?
      case "$rc" in
        0) any=1 ;;
        # #650: absence of a line must mean "never connected", nothing else --
        # a team whose config could not be read gets an explicit line instead
        # of silently vanishing from what a caller treats as the full set.
        2) python3 -c 'import json, sys; print(json.dumps({"local_team": sys.argv[1], "state": "unreadable"}))' "$t"
           any=1 ;;
      esac
    else
      rc=0; _remote_status_one "$t" || rc=$?
      case "$rc" in
        0) any=1 ;;
        2) echo "$t	could not be read (config exists but could not be parsed) (#650)"
           any=1 ;;
      esac
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
  # Set only after the acquire returned success, and only in the process that
  # made the call: this is what _remote_sync_engine_start trusts instead of the
  # inheritable AGMSG_HELD_LOCKS, so it must never be set optimistically (#762).
  _REMOTE_ENGINE_CALLER_HOLDS_LOCK=1
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
  case "$engine_state" in
    running)
      echo "Sync engine already running (pid $engine_pid)."
      agmsg_lock_release
      return
      ;;
    starting|inactive|unknown)
      echo "agmsg: systemd owns team '$team' in state '$engine_state'; inspect or restart the user unit instead of sync start" >&2
      agmsg_lock_release
      return 1
      ;;
  esac

  logfile="$CONNECTION_ROOT/run/remote-sync.$team.log"
  [ -f "$logfile" ] && log_offset=$(( $(wc -c < "$logfile" | tr -d ' ') + 1 ))
  startup_nonce="$(compat_uuid7)"
  if ! _remote_sync_engine_start "$team" "$startup_nonce"; then
    _REMOTE_ENGINE_CALLER_HOLDS_LOCK=0
    agmsg_lock_release
    return 1
  fi
  # Cleared as soon as the start is over. The flag says "the caller holds the
  # lock RIGHT NOW"; left standing past the release below, a second engine start
  # in the same process would read a stale yes and skip its own locking.
  _REMOTE_ENGINE_CALLER_HOLDS_LOCK=0
  started_pid="$(cat "$(_remote_sync_engine_pidfile "$team")")"

  # RELEASED HERE, BEFORE THE WAIT, AND THAT IS THE WHOLE FIX (#817).
  #
  # The lock exists to serialise "is one running, and if not, start one". Both
  # halves are over by this line: the pidfile names a live engine, so a second
  # `sync start` that takes this lock now reads `running` from
  # `_remote_sync_engine_status` -- which asks the pidfile, the pid's liveness
  # and its cmdline, and never asks about readiness -- and returns
  # "already running" without starting anything. Nothing below needs exclusion:
  # the loop only reads status and tails a log.
  #
  # WHAT THE FIELD REPORT ACTUALLY WAS, in the order it happened.
  #
  # The engine emits the capabilities marker BEFORE it asks for this lock, so the
  # ordinary sequence is: marker, this loop sees it, release, then `roster
  # prepare` takes the lock. That order was never the problem, and an earlier
  # version of this comment said it was.
  #
  # On the reporting machine the loop never reached the marker check at all.
  # `_remote_sync_engine_status` answered `stale` for a pid this shell had just
  # started -- the non-local probe cannot see it on Windows (#652) -- so
  # `engine_state = running` was false and the condition short-circuited before
  # the marker was ever read. The loop then ran to its ceiling, which is counted
  # in ITERATIONS and not in time (#779), and on that host 1600 turns of four
  # spawned processes each is not sixteen seconds. The lock was held for all of
  # it, and every other operation for that team waited on a directory that was
  # not going to be removed.
  #
  # #812 removed the direct cause: the status probe is local now. This release is
  # not a second fix for that. It is a separate contract -- the lock covers
  # deciding whether to start and starting, and nothing after -- so that a marker
  # that is late or missing for ANY reason costs this caller its own wait and
  # not the rest of the machine.
  agmsg_lock_release
  while [ "$i" -lt 1600 ]; do
    IFS=$'\t' read -r engine_state ready_pid < <(AGMSG_SKIP_SYSTEMD_PROBE=1 _remote_sync_engine_status "$team")
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
    # TAKEN BACK FOR THE CLEANUP, because the cleanup WRITES SHARED STATE.
    #
    # The pidfile and the cycle stamp are per team, not per caller. Releasing
    # before the wait -- which is the point of this change -- means another
    # `sync start` may have taken the lock, decided this engine was gone and
    # started its own by the time we get here. Removing those two files without
    # the lock would then delete the state of an engine this call never
    # started, and the pidfile is the only thing that names it (raised in
    # review). Reaping is guarded by `_remote_sync_engine_reap_owned`, which
    # refuses a pid it cannot prove is ours; the file removal had no such guard.
    #
    # A lock that cannot be retaken must not swallow the diagnostic below, so
    # the failure is reported and the files are left rather than removed blind:
    # a stale pidfile is what `status` already knows how to describe.
    local relocked=1
    agmsg_lock_acquire "$TEAMS_DIR/$team" || relocked=0
    if _remote_sync_engine_reap_owned "$team" "$started_pid"; then
      if [ "$relocked" -eq 1 ]; then
        # AND ONLY IF IT IS STILL OURS. Retaking the lock stops the file from
        # changing under the removal; it does not make the file this call's to
        # remove. Between the release and here another `sync start` may have
        # completed and written its own pid, and that pidfile is the only thing
        # naming its engine -- removing it would leave a live engine nothing
        # points at, which is the shape `set-endpoint` already warns about.
        local recorded
        recorded="$(cat "$(_remote_sync_engine_pidfile "$team")" 2>/dev/null || true)"
        if [ "$recorded" = "$started_pid" ]; then
          rm -f "$(_remote_sync_engine_pidfile "$team")"
          rm -f "$(_remote_sync_engine_cycle_stamp "$team")"   # same reason as in _remote_sync_engine_stop
        fi
        agmsg_lock_release
      else
        echo "agmsg: could not retake the registry lock to clear the engine's records for '$team'" >&2
        echo "  the engine is stopped; its pidfile is left, and 'remote.sh status' reads it as stale." >&2
      fi
      echo "agmsg: sync engine for '$team' did not become ready" >&2
      return 1
    fi
    [ "$relocked" -eq 1 ] && agmsg_lock_release
    # The reap did not stop it, and the engine is still running.
    #
    # _remote_sync_engine_reap_owned returns non-zero for two different
    # reasons, and this branch cannot tell them apart:
    #
    #   ownership unproven   it returns BEFORE any kill -- deliberately, since
    #                        it must never signal a pid it cannot prove is ours
    #   signalling failed    TERM then KILL were sent and it survived
    #
    # So the text below says what is known -- it is running, and this command
    # did not stop it -- and offers the sandbox as the likely reason rather
    # than the established one. An earlier version asserted "this shell was not
    # allowed to signal it" unconditionally, which is false on the first path,
    # and the test here drives exactly that path. Naming a cause the check did
    # not establish sends the next reader somewhere the evidence does not.
    #
    # The Codex observation is still worth carrying, because it produces BOTH:
    # measured there, `kill -0` and `kill -TERM` on the engine this shell just
    # started return "Operation not permitted" while the same signal from
    # outside is allowed -- so ownership cannot be confirmed from in there
    # either.
    #
    # Saying only "the pidfile was preserved" read as a file kept for
    # diagnosis. It is a live process that cannot reach the server and retries
    # on a backoff forever -- and since the pidfile only ever names the most
    # recent one, a second attempt leaves the first with nothing pointing at
    # it. Measured: one after the first failed attempt, two after the second.
        {
      echo "agmsg: sync engine for '$team' did not become ready, and this command did not stop it."
      echo "  pid $started_pid is still running. It cannot reach the server -- that is why"
      echo "  it never became ready -- and it will keep retrying on a backoff."
      echo "  This shell either could not confirm the process was ours or could not signal it."
      echo "  A sandboxed agent (Codex is one) produces both: signals to other processes are"
      echo "  blocked inside it, and ownership cannot be confirmed from in there either."
      echo "  Nothing is syncing for this team meanwhile."
      echo "  Running sync start again leaves another one behind, and only the newest"
      echo "  is recorded in $(_remote_sync_engine_pidfile "$team")."
      echo "  Stop it from a shell that can signal it:"
      echo "    kill $started_pid"
      echo "  or give up the binding entirely:"
      echo "    remote.sh disconnect $(agmsg_shq "$team")"
    } >&2
    return 1
  fi
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
    echo "agmsg: team '$team' is still connected; run this first:" >&2
    echo "  bash $(agmsg_shq "$SKILL_DIR/scripts/remote.sh") disconnect $(agmsg_shq "$team")" >&2
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
      # Only legacy rows the event log does not already carry: every message is
      # written to both tables (#689), so counting both in full reports twice
      # the number of messages about to be deleted.
      #
      # The column is asked about rather than assumed. This inspects a store
      # file directly and deliberately never initializes it, so a store written
      # before that column existed is a state this path must survive -- and it
      # has no mirrored rows anyway, which makes the plain count the right
      # answer there. Naming a column that is not there fails the whole query,
      # and an empty result then breaks the arithmetic below rather than the
      # SQL, which is a long way from the cause.
      legacy_dedupe=""
      if [ "$(agmsg_sqlite "$store_path" \
            "SELECT COUNT(*) FROM pragma_table_info('events') WHERE name='legacy_id';" \
            2>/dev/null | tr -d '\r')" = "1" ]; then
        legacy_dedupe=" WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.legacy_id = m.id)"
      fi
      legacy_count="$(agmsg_sqlite "$store_path" \
        "SELECT COUNT(*) FROM messages m$legacy_dedupe;" | tr -d '\r')" || {
        echo "agmsg: cannot count messages in team store '$store_path'; refusing to delete it" >&2
        exit 1
      }
      # A count that cannot be proved is not zero. The inspection above already
      # refuses when it cannot read the table list, and this is the same kind of
      # claim: normalising a failed query to 0 would tell the operator there is
      # less to lose than there is, immediately before deleting it. A missing
      # column is a different thing and is handled by the probe above -- that is
      # a store shape we support, not a failure.
      case "$legacy_count" in
        ''|*[!0-9]*)
          echo "agmsg: message count in team store '$store_path' was not a number; refusing to delete it" >&2
          exit 1
          ;;
      esac
      event_count="$((event_count + legacy_count))"
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

# _remote_snapshot_binding_for_update <team> <cfg>
# Prints one tab-separated line:
#   endpoint  server_instance_id  remote_team_id  cipher_profile
#   connected_at  disconnected_at  binding_revision
#
# ONE lock acquisition covers both the legacy-revision initialization and the
# reads, so every field describes the same generation of the binding and the
# revision printed is the revision that generation really has. Read outside a
# single lock, the pieces can straddle a concurrent write: the caller judges
# "connected" from one generation and then snapshots the NEXT generation's
# revision -- at which point its CAS validates a write against a state it
# never examined, and a disconnect landing in the gap is silently undone
# (#739 review, round 5).
#
# The revision initialization is cmd_forget's compat move, hoisted: a binding
# written before revisions existed has none, and both CAS functions skip their
# comparison entirely for an empty expected value -- which would disable the
# lifecycle guard for exactly those legacy teams.
_remote_snapshot_binding_for_update() {
  local team="$1" cfg="$2" escaped updated revision endpoint server_instance \
    remote_team_id cipher connected_at disconnected_at
  agmsg_lock_acquire "$TEAMS_DIR/$team" || return 1
  endpoint="$(_remote_read_config_field "$cfg" '$.remote_binding.endpoint')"
  if [ -n "$endpoint" ] && [ "$endpoint" != "null" ]; then
    revision="$(_remote_read_config_field "$cfg" '$.remote_binding.binding_revision')"
    if [ -z "$revision" ] || [ "$revision" = "null" ]; then
      escaped="$(sed "s/'/''/g" "$cfg")"
      updated="$(agmsg_sqlite_mem \
        "SELECT json_set('$escaped', '\$.remote_binding.binding_revision', 1);")"
      agmsg_write_atomic "$cfg" "$updated"
      revision=1
    fi
  else
    revision=""
  fi
  server_instance="$(_remote_read_config_field "$cfg" '$.remote_binding.server_instance_id')"
  remote_team_id="$(_remote_read_config_field "$cfg" '$.remote_binding.remote_team_id')"
  cipher="$(_remote_read_config_field "$cfg" '$.remote_binding.cipher_profile')"
  connected_at="$(_remote_read_config_field "$cfg" '$.remote_binding.connected_at')"
  disconnected_at="$(_remote_read_config_field "$cfg" '$.remote_binding.disconnected_at')"
  agmsg_lock_release
  # Unit separator, NOT tab: several of these fields are legitimately empty
  # (a JSON null reads back as ""), and tab is IFS whitespace -- `read`
  # collapses consecutive whitespace delimiters, shifting every later field
  # left. A non-whitespace separator keeps empty fields empty.
  printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$endpoint" "$server_instance" \
    "$remote_team_id" "$cipher" "$connected_at" "$disconnected_at" "$revision"
}

# --- set-endpoint ----------------------------------------------------------
#
# Move a connected team's binding to a new address. Only the ADDRESS moves:
# what the team is bound TO is the identity triple (server_instance_id,
# remote_team_id, protocol_version), and the server answering at the new
# address must prove it is that same identity before anything is written.
# _remote_adopt_registration is both the proof and the only writer: it fetches
# the new address's capabilities, refuses unless the server instance matches
# the recorded one (naming both ids when it does not), re-checks that the
# registration is this team's (name and roster), and only then rewrites the
# binding -- endpoint included, binding_revision advanced. There is
# deliberately no unverified path to the write.
#
# A disconnected team is refused: disconnect is the operator renouncing the
# anchor, and `connect --endpoint <new>` is the deliberate re-anchoring move
# for that state. set-endpoint exists for the live team whose address was
# never meant to be permanent -- a port-forward, a tunnel, a machine that
# later got a stable name (#718).
cmd_set_endpoint() {
  local endpoint="" team="" positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --endpoint) endpoint="${2:?--endpoint requires a value}"; shift 2 ;;
      --endpoint=*) endpoint="${1#--endpoint=}"; shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  : "${endpoint:?Usage: remote.sh set-endpoint --endpoint <url> <team>}"
  _remote_validate_endpoint "$endpoint" || exit 1
  endpoint="${endpoint%/}"
  team="${positional[0]:-}"
  [ -n "$team" ] || { echo "agmsg: set-endpoint requires a team: remote.sh set-endpoint --endpoint <url> <team>" >&2; exit 1; }
  agmsg_validate_team_name "$team" || exit 1

  local cfg old_endpoint server_instance remote_team_id binding_cipher \
    connected_at disconnected_at binding_revision align_out \
    engine_state engine_pid end_state end_pid was_running=0
  cfg="$(_remote_team_config "$team")"
  [ -f "$cfg" ] || { echo "agmsg: team '$team' is not a local team" >&2; exit 1; }
  # One atomic snapshot: the fields this command JUDGES from (connected,
  # disconnected, identity) and the revision its CAS will later verify all
  # come from the same generation of the binding, read under one lock hold.
  # Any change after this point -- a disconnect included -- advances the
  # revision past this snapshot and the write refuses.
  IFS=$'\037' read -r old_endpoint server_instance remote_team_id binding_cipher \
    connected_at disconnected_at binding_revision \
    < <(_remote_snapshot_binding_for_update "$team" "$cfg") || {
    echo "agmsg: could not snapshot team '$team' state for the update" >&2
    exit 1
  }
  if [ -z "$connected_at" ] || [ "$connected_at" = "null" ] \
    || [ -z "$server_instance" ] || [ "$server_instance" = "null" ]; then
    echo "agmsg: team '$team' has no remote binding; there is no endpoint to move. Connect or pull it first." >&2
    exit 1
  fi
  if [ -n "$disconnected_at" ] && [ "$disconnected_at" != "null" ]; then
    echo "agmsg: team '$team' is disconnected; set-endpoint moves a live binding only. To re-anchor it deliberately, run connect with the new endpoint." >&2
    exit 1
  fi
  if [ "$old_endpoint" = "$endpoint" ]; then
    # The binding already names this address -- but the binding is only ONE of
    # the two places that pin it. A failure between the binding write below
    # and the stored-config alignment leaves binding=new / stored config=old,
    # and the remedy this command prints for that state is to re-run itself.
    # So this path must REPAIR, not return on the binding comparison alone
    # (#739 review): the alignment runs, fixing a mismatched stored config and
    # recording a no-op when the two already agree. An engine cannot be
    # running against a mismatched stored config (loadConfig refuses the
    # pair), so there is nothing to stop here.
    align_out="$(bash "$SCRIPT_DIR/remote-sync.sh" set-endpoint --team "$team")" || {
      echo "agmsg: the stored sync configuration could not be aligned with the binding; the sync engine stays stopped until it is. Fix what the message above names, then re-run set-endpoint." >&2
      exit 1
    }
    if printf '%s' "$align_out" | grep -Fq '"changed":true'; then
      echo "Team '$team' already had its binding on $(_remote_endpoint_display "$endpoint"); the stored sync configuration has now been aligned to it. Restart sync with: remote.sh sync start $(agmsg_shq "$team")"
    else
      echo "Team '$team' already uses $(_remote_endpoint_display "$endpoint"); nothing to change."
    fi
    exit 0
  fi

  # Test seam: a two-file barrier that lets the lifecycle-race regressions
  # land a concurrent disconnect / sync start deterministically between this
  # command's state snapshot and its write. No-op unless set.
  if [ -n "${AGMSG_TEST_SET_ENDPOINT_BARRIER:-}" ]; then
    : > "$AGMSG_TEST_SET_ENDPOINT_BARRIER.reached"
    _agmsg_barrier_waited=0
    while [ ! -e "$AGMSG_TEST_SET_ENDPOINT_BARRIER.release" ]; do
      sleep 0.05
      _agmsg_barrier_waited=$((_agmsg_barrier_waited + 1))
      [ "$_agmsg_barrier_waited" -ge 1200 ] && break # 60s safety cap
    done
  fi

  IFS=$'\t' read -r engine_state engine_pid < <(AGMSG_SKIP_SYSTEMD_PROBE=1 _remote_sync_engine_status "$team")
  [ "$engine_state" = "running" ] && was_running=1
  _remote_sync_engine_stop "$team" || {
    echo "agmsg: the sync engine did not stop; refusing to move the endpoint under it" >&2
    exit 1
  }

  # The write is compare-and-swap on the snapshotted binding_revision: a
  # concurrent disconnect (or any other binding writer) advances the revision,
  # and this write must refuse rather than overwrite that newer state -- the
  # adopt path rewrites the whole binding, disconnected_at:null included.
  _remote_adopt_registration "$team" "$cfg" "$endpoint" "$remote_team_id" \
    "$binding_cipher" "$server_instance" "$binding_revision" || exit 1

  # Two places pin the address: the binding (moved above) and the stored sync
  # config, whose server_url loadConfig requires to match the binding. The
  # engine-side subcommand aligns the latter after re-verifying the identity
  # end to end; a plain team with no stored config is a recorded no-op. On
  # failure the engine stays stopped and the next start says exactly which
  # two things disagree -- and re-running set-endpoint reaches the repair
  # path above, which retries this alignment.
  bash "$SCRIPT_DIR/remote-sync.sh" set-endpoint --team "$team" >/dev/null || {
    echo "agmsg: the binding now names $(_remote_endpoint_display "$endpoint") but the stored sync configuration still names the old address; re-run set-endpoint (the sync engine stays stopped until both agree)" >&2
    exit 1
  }

  # Decide from BOTH the snapshot and the present: an engine that was running
  # at the snapshot is restarted, and an engine somebody started while this
  # command ran is restarted too (never silently left stopped, and a restart
  # is what hands it the moved address -- a running engine keeps its old
  # config in memory). _remote_sync_engine_start kills a live engine first.
  IFS=$'\t' read -r end_state end_pid < <(AGMSG_SKIP_SYSTEMD_PROBE=1 _remote_sync_engine_status "$team")
  if [ "$was_running" -eq 1 ] || [ "$end_state" = "running" ]; then
    # Same rule as cmd_pull and cmd_connect: the move is this command's purpose
    # and it is done by here, so a start failure reports rather than fails --
    # and, unlike before, does not end the line by claiming a restart that did
    # not happen. This call site arrived while #730 was in review; without the
    # capture the bare call would abort here under `set -e`, because the helper
    # can now return non-zero.
    local engine_restarted=1
    _remote_sync_engine_start "$team" || engine_restarted=0
    local engine_note=" Sync engine restarted."
    [ "$engine_restarted" -eq 1 ] || engine_note=" The sync engine did not restart; the reason is on stderr."
    echo "Endpoint for '$team' moved: $(_remote_endpoint_display "$old_endpoint") -> $(_remote_endpoint_display "$endpoint") (same server instance).$engine_note"
  else
    echo "Endpoint for '$team' moved: $(_remote_endpoint_display "$old_endpoint") -> $(_remote_endpoint_display "$endpoint") (same server instance)."
  fi
}

# The dispatcher runs only when this file is EXECUTED. Sourcing it defines the
# functions and stops there, which is what makes the internal lock/trap wiring
# testable at all: driven through the CLI, a wrapper's trap bookkeeping leaves
# no trace an outside process can read, and a test that re-implements it is
# testing its own copy (#762).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
case "${1:-}" in
  connect) shift; agmsg_require_python3 "remote connect" || exit 1; cmd_connect "$@" ;;
  pull) shift; agmsg_require_python3 "remote pull" || exit 1; cmd_pull "$@" ;;
  unlock) shift; agmsg_require_python3 "remote unlock" || exit 1; cmd_unlock "$@" ;;
  status) shift; agmsg_require_python3 "remote status" || exit 1; cmd_status "$@" ;;
  sync) shift; cmd_sync "$@" ;;
  disconnect) shift; agmsg_require_python3 "remote disconnect" || exit 1; cmd_disconnect "$@" ;;
  set-endpoint) shift; agmsg_require_python3 "remote set-endpoint" || exit 1; cmd_set_endpoint "$@" ;;
  forget) shift; agmsg_require_python3 "remote forget" || exit 1; cmd_forget "$@" ;;
  doctor) shift; cmd_doctor "$@" ;;
  *)
    echo "Usage: remote.sh <connect|pull|unlock|status|sync|set-endpoint|disconnect|forget|doctor> ..." >&2
    exit 1 ;;
esac
fi
