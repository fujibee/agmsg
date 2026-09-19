#!/usr/bin/env bash
# Pre-#1248 agmsg (1.3.0 and earlier) generated its antigravity rule file
# with this exact per-driver notes path; #1249 renamed the real file to
# README.md and this line went with it. Kept here, on its own, so
# _delivery.sh's rule-file migration check can still recognize a rule file
# an old client wrote and migrate it instead of refusing it as foreign.
#
# This is the ONLY place in the tracked tree allowed to hold the old path
# literally -- tests/test_capability_docs.bats's #1249 check excludes this
# one file by name for exactly that reason. It is never emitted by any
# current code path; do not copy this string anywhere else.
#
# Read via `source` by callers outside this file, so shellcheck cannot see
# the use when checking this file alone.
# shellcheck disable=SC2034
LEGACY_PRE1248_NOTES_PATH='drivers/terminals/<terminal>/SKILL.md'
