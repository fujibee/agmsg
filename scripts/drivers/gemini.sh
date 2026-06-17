#!/usr/bin/env bash
# gemini driver — rule-file class. Rule file: <project>/.agent/rules/agmsg.md
# (path owned by resolve_hooks_file). Thin: the behavior lives in _rulefile.sh.

agmsg_driver_apply() { rulefile_apply "$@"; }
agmsg_driver_status() { rulefile_status "$@"; }
