#!/usr/bin/env bash
# antigravity driver — rule-file class. Shares .agent/rules/agmsg.md with gemini
# (path owned by resolve_hooks_file). Thin: behavior lives in _rulefile.sh.

agmsg_driver_apply() { rulefile_apply "$@"; }
agmsg_driver_status() { rulefile_status "$@"; }
