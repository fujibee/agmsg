#!/usr/bin/env bash
# The command a person types to reach THIS installation's `plugin` verb, for
# the hints the plugin code prints (#1779). The shared `agmsg` launcher and the
# npm `agmsg` command belong to the install named agmsg only; an install made
# with `install.sh --cmd <other>` gets no `agmsg` command, so a hint saying
# `agmsg plugin ...` there would reach a different installation, or none.

# agmsg_plugin_cmd <skill-dir>: prints "agmsg", or "bash <skill-dir>/scripts/agmsg"
# (shell-quoted) for an install with another name.
agmsg_plugin_cmd() {
  local skill="${1%/}"
  if [ "${skill##*/}" = agmsg ]; then
    printf 'agmsg'
  else
    printf 'bash %q' "$skill/scripts/agmsg"
  fi
}
