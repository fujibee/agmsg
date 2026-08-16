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
# curl (used by remote.sh's own one-shot connect/pull requests) and Node
# (used here, and by everything this script execs into) trust a custom CA
# through two different, unrelated env vars. A user who points --endpoint at
# a server with a private/self-signed cert and sets only CURL_CA_BUNDLE gets
# a working `connect`, then a sync engine that fails every cycle forever
# with no indication why (#744). Node has no equivalent of CURL_CA_BUNDLE, so
# bridge it: if the caller already trusted curl with a CA bundle and never
# set Node's own variable, hand Node the same file. An explicit
# NODE_EXTRA_CA_CERTS is left untouched.
#
# This is per-invocation, not persisted with the team's remote binding: it
# only helps when CURL_CA_BUNDLE is set in the environment that runs THIS
# script, which includes `connect`'s own engine start but not a later
# `remote.sh sync start <team>` run from a shell that never re-exported it.
# Restarting the engine after a crash still needs CURL_CA_BUNDLE set again in
# that shell — nothing here writes the CA path anywhere durable.
if [ -z "${NODE_EXTRA_CA_CERTS+x}" ] && [ -n "${CURL_CA_BUNDLE:-}" ]; then
  export NODE_EXTRA_CA_CERTS="$CURL_CA_BUNDLE"
fi
# The engine outlives the command that starts it, so whatever it inherits it
# holds for as long as it runs — including a descriptor internal to bats,
# which then waits for an EOF that cannot arrive. Closing 3 and 4 by name
# cannot reach it, because the harness picks the number.
# The range close and the reasoning behind it now live in lib/close-fds.sh,
# because codex-bridge-launcher.sh needs exactly the same thing and had the
# insufficient by-name form until a macOS shard hung on it.
. "$SCRIPT_DIR/lib/close-fds.sh"
agmsg_close_inherited_fds

exec "$NODE_BIN" "$SCRIPT_DIR/internal/remote-sync.mjs" "$@"
