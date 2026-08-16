#!/usr/bin/env bash
# Close every inherited descriptor above stderr, before spawning something that
# outlives the shell that started it.
#
# WHY BY RANGE AND NOT BY NAME. A long-lived child keeps whatever it inherits
# for as long as it runs. Under bats that includes a descriptor internal to the
# harness, and the harness then waits for an EOF that cannot arrive: the shard
# runs to the CI job's cap with every test already reported ok. Observed twice
# on the same head, ~25 minutes each, with `Terminate orphan process: (node)`
# at cleanup.
#
# `exec 3>&- 4>&-` cannot reach it. The harness chooses the number — 13, 143 and
# 144 have all been seen — so the close has to enumerate what is actually open
# rather than name the two descriptors we expect.
#
# EACH CLOSE IS ITS OWN STATEMENT, deliberately. Collecting them into
# redirections on an `exec` reads better and is wrong: bash 3.2 — /bin/bash on
# macOS, and what runs this on the macOS runner — relocates descriptors into the
# range at and above 10 while it processes an exec's redirections, and the child
# inherits those relocated copies. Measured, same enumeration both times:
#
#   bash 5.3.15   child sees  0 1 2
#   bash 3.2.57   child sees  0 1 2 10 11      <- 143 came back as 11
#
# Closing 255 (where bash keeps the script it is reading) is safe: bash moves
# the script elsewhere when asked to close it, and a 291 KB script still ran to
# its last line under both 3.2.57 and 5.3.15. Do not "simplify" this onto an
# exec line.
#
# This lives in lib/ because more than one spawn path needs it, and the first
# time it was written it lived in only one of them — remote-sync.sh had the
# range close while codex-bridge-launcher.sh still closed 3 and 4 by name, so
# the bridge kept holding the harness pipe and hung the shard.
agmsg_close_inherited_fds() {
  local fd
  if [ -d /dev/fd ]; then
    for fd in /dev/fd/*; do
      fd="${fd##*/}"
      case "$fd" in '' | *[!0-9]*) continue ;; esac
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
