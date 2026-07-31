#!/usr/bin/env bash
# partition/shared — one store holds every team. The default, and the partition the
# database has always had.
#
# This is the partition that external programs read. Several open the store
# directly rather than going through agmsg, and they find their messages by
# filtering on the `team` column of one file. Moving a team out of here breaks
# every one of them for that team, silently, because the old path still resolves
# to a real database. That is why nothing leaves this partition by default.
#
# Contract (axis = partition): echo the store path RELATIVE to the storage dir.
# The facade joins it and handles the Windows path form.

partition_store_relpath() {
  # Takes the team for signature parity with per-team; deliberately ignores it.
  printf 'messages.db\n'
}
