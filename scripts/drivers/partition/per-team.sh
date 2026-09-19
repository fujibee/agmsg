#!/usr/bin/env bash
# partition/per-team — the team owns its own store at teams/<team>/messages.db.
#
# A team moves here when connecting to a remote, and not before. The reason is
# not tidiness: a connected team's rows carry ids where a local team's carry
# names, and one column cannot hold both. Separating the file is what keeps that
# schema change inside the team that asked for it.
#
# The cost is that external readers of the shared store stop seeing this team.
# That is the trade connecting makes, and it is why the move is per team rather
# than per install.
#
# Contract (axis = partition): echo the store path RELATIVE to the storage dir.
# The facade joins it and handles the Windows path form.

partition_store_relpath() {
  # The caller validates the team as a path segment before reaching here; this
  # driver would otherwise be the place a '..' escapes the storage tree.
  printf 'teams/%s/messages.db\n' "$1"
}
