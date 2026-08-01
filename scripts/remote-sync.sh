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
# The closes are attached to the exec rather than performed before it. One of the
# descriptors above stderr belongs to the shell itself -- bash keeps the script it
# is reading open, at 255 -- and closing it from a statement would leave the shell
# to carry on reading a script through a descriptor it no longer holds. Bash does
# defend against that (observed: it moves the script to another number), but as a
# redirection on the exec the question does not arise: nothing of this script runs
# between the close and the execve.
_fd_closes=""
if [ -d /dev/fd ]; then
  for _fd in /dev/fd/*; do
    _fd="${_fd##*/}"
    case "$_fd" in ''|*[!0-9]*) continue ;; esac
    [ "$_fd" -gt 2 ] || continue
    _fd_closes="$_fd_closes ${_fd}>&-"
  done
else
  # Nothing to enumerate, so name a range instead. Closing a descriptor that was
  # never open is not an error, which is what makes the blind form safe.
  for _fd in $(seq 3 255); do
    _fd_closes="$_fd_closes ${_fd}>&-"
  done
fi

eval "exec$_fd_closes \"\$NODE_BIN\" \"\$SCRIPT_DIR/internal/remote-sync.mjs\" \"\$@\""
