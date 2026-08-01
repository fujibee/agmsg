#!/usr/bin/env bash
# Stage-1 polling synchronization client (dogfood; docs/spec/ref/stage-1-remote-sync.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export SKILL_DIR
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/node.sh"
export AGMSG_SYNC_STORAGE_DIR="$(agmsg_storage_dir)"
export AGMSG_SYNC_TRUST_DIR="${AGMSG_SYNC_TRUST_DIR:-${AGMSG_SYNC_CONNECTION_DIR:-$SKILL_DIR}/run/remote-trust}"
export AGMSG_SYNC_DRIVER="$SCRIPT_DIR/internal/storage-sync-driver.sh"
NODE_BIN="$(agmsg_resolve_node)"
export AGMSG_SYNC_NODE_BIN="$NODE_BIN"
export AGMSG_SYNC_CIPHER_HELPER="$SCRIPT_DIR/internal/sync-cipher.mjs"
# The engine outlives the command that starts it, so whatever it inherits it
# holds for as long as it runs. Under bats that included fd 144 -- a descriptor
# internal to the harness -- and the shard then ran to the CI job's cap with
# every test already reported ok, because bats was waiting for an EOF the engine
# was keeping from arriving. Captured directly: the engine and three bats
# processes all held the same pipe, 0xc9aea28a590ca110, at fd 144.
#
# Closing 3 and 4 by name at the spawn sites, which is what this repo did until
# now, cannot reach a descriptor whose number the harness chooses. So the close
# is by range, not by name, and it lives here -- the one place every engine
# invocation passes through -- rather than at each caller.
#
# The engine speaks only over stdin, stdout and stderr; the spawn sites already
# point those at a log. Nothing above stderr is anything it should keep.
#
# Each close is its own statement. Collecting them into redirections on the exec
# reads better and is wrong: bash 3.2 -- which is /bin/bash on macOS, and what
# runs this on the macOS runner -- relocates descriptors into the range at and
# above 10 while it processes an exec's redirections, and the child then inherits
# those relocated copies. Measured, same script, same enumeration
# (`10>&- 143>&- 255>&- 3>&-`) both times:
#
#   bash 5.3.15   engine sees  0 1 2
#   bash 3.2.57   engine sees  0 1 2 10 11      <- 143 came back as 11
#
# A CI shard hung on exactly that: the engine held bats's pipe at fd 13 while
# bats held it at 143, and bats sat waiting for an EOF that could not arrive.
#
# The hazard that argued for the exec form does not bite. One descriptor above
# stderr belongs to the shell -- bash keeps the script it is reading open, at 255
# -- and closing it from a statement might have left the shell reading through a
# descriptor it had given up. Bash defends itself: given `exec 255>&-` it moves
# the script to another number (observed as 11), and a script padded to 291 KB,
# far past any read buffer, still ran to its last line under both 3.2.57 and
# 5.3.15. Do not "simplify" this back onto the exec line.
_close_inherited_fds() {
  local fd
  if [ -d /dev/fd ]; then
    for fd in /dev/fd/*; do
      fd="${fd##*/}"
      case "$fd" in ''|*[!0-9]*) continue ;; esac
      [ "$fd" -gt 2 ] || continue
      eval "exec ${fd}>&-" 2>/dev/null || true
    done
  else
    # Nothing to enumerate, so sweep a range instead. Closing a descriptor that
    # was never open is not an error, which is what makes the blind form safe.
    for fd in $(seq 3 255); do
      eval "exec ${fd}>&-" 2>/dev/null || true
    done
  fi
}
_close_inherited_fds

exec "$NODE_BIN" "$SCRIPT_DIR/internal/remote-sync.mjs" "$@"
