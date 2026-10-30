#!/bin/bash
# make_archive: pack the output folder next to itself as <out>.tgz. tar writes <out>.tgz.partial and the final
# name appears only by rename when tar succeeded, so the existence of <out>.tgz means a complete archive.
# A failed tar leaves no final name and adds a FAIL line to the summary (outside the archive, which is not made).
# Needs OUT and SUM; sourced by run-win.sh and selftest-sink.sh.
make_archive() {
  if ( cd "$(dirname "$OUT")" && tar czf "$OUT.tgz.partial" "$(basename "$OUT")" ) && mv "$OUT.tgz.partial" "$OUT.tgz"; then
    return 0
  fi
  echo "FAIL archive the output folder could not be packed; no $OUT.tgz was made (take the folder itself)" | tee -a "$SUM"
  return 1
}
