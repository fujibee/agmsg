#!/usr/bin/env bash
# Shared helpers for handle and setup. Sourced, not executed; no shebang exec bit.
#
# Nothing here prints or logs a token. _slack_read_token is the only function
# that ever holds one in a variable, and its one caller passes it straight to
# curl's Authorization header -- never to echo, never to a file this library
# writes.

# Read a single key from a member config file (the same key=value shape as
# type.conf, read the same way: never sourced, so a config file cannot run
# arbitrary shell just by being loaded). Returns empty if the file or key is
# absent -- callers decide whether that is fatal.
_slack_conf_get() {   # <config_path> <key>
  local config_path="$1" key="$2" line
  [ -f "$config_path" ] || return 0
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$config_path" 2>/dev/null | head -1)" || true
  printf '%s' "${line#*=}"
}

# The Slack Web API base URL. Overridable so tests point this at a loopback
# fixture instead of the real workspace (design note §5b: "本物の Slack を
# 使わない"); production leaves it unset and gets the real one.
_slack_api_base() {
  printf '%s' "${AGMSG_SLACK_API_BASE:-https://slack.com/api}"
}

# Read the bot token from <key_file>. Never echoed by any caller; a missing or
# unreadable file, or one that is empty after trimming, is reported by NAME
# ("key file ... not readable") rather than by printing what was in it.
_slack_read_token() {   # <key_file>
  local key_file="$1" token
  [ -n "$key_file" ] || return 1
  [ -r "$key_file" ] || return 1
  token="$(cat "$key_file" 2>/dev/null)" || return 1
  token="${token%$'\n'}"
  [ -n "$token" ] || return 1
  printf '%s' "$token"
}

# POST <path> with a bearer token and a JSON body (already built by the
# caller via jq -cn, so this never string-interpolates untrusted content into
# JSON itself). Prints the raw response body; the caller reads .ok/.error.
_slack_api_post() {   # <token> <path> <json-body>
  local token="$1" path="$2" json="$3"
  curl -sS --max-time 25 -X POST "$(_slack_api_base)/$path" \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data "$json"
}

_slack_api_get() {   # <token> <path-with-query>
  local token="$1" path="$2"
  curl -sS --max-time 25 -X GET "$(_slack_api_base)/$path" \
    -H "Authorization: Bearer $token"
}
