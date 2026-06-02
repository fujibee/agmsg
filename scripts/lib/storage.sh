#!/usr/bin/env bash
# storage.sh — resolve the path to the sqlite message store (messages.db).
#
# Scope: the storage axis only — where messages are persisted. This is NOT a
# storage-driver interface; it just centralizes the path resolution that was
# previously duplicated across the script set.
#
# Resolution order:
#   1. AGMSG_STORAGE_PATH — directory that holds messages.db (env override)
#   2. built-in default   — <skill>/db
#
# [seam] A config-file layer is expected to slot in between the env override
# and the built-in default once the storage-driver work lands; the intended
# full order is env > config > default. Keep that logic here so call sites
# stay unchanged.

# Echo the directory that holds (or will hold) the message store.
agmsg_storage_dir() {
  if [ -n "${AGMSG_STORAGE_PATH:-}" ]; then
    # Strip a single trailing slash for a stable join with the filename.
    printf '%s\n' "${AGMSG_STORAGE_PATH%/}"
    return
  fi
  local lib_dir skill_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  skill_dir="$(cd "$lib_dir/../.." && pwd)"
  printf '%s\n' "$skill_dir/db"
}

# Echo the full path to messages.db.
agmsg_db_path() {
  printf '%s/messages.db\n' "$(agmsg_storage_dir)"
}
