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

# Escape \ and " for embedding inside a curl -K config's double-quoted value
# (mirrors scripts/remote.sh's _remote_curl_quote, same reason: an unescaped
# " in a token or channel value this file does not control could close the
# quoted value early and let the rest of the line be read as a further
# config directive).
_slack_curl_quote() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# _slack_api_call <token> <GET|POST> <path> <out_body_file> [<json-body>]
#
# Never puts the token, or the request body, in this process's own argv --
# both go through a 0600 curl -K config file (the token as a header line,
# the body read from curl's OWN stdin via `data = "@-"`), so neither is
# visible to `ps` the way `-H "Authorization: Bearer $token"` or `--data
# "$json"` on the command line would be. The config file is removed no
# matter how this returns.
#
# On success (any completed HTTP exchange, including a Slack-reported error
# -- Slack answers those with plain 200) returns 0, writes the response body
# to <out_body_file>, and sets $_SLACK_HTTP_CODE.
#
# On a transport failure (DNS, TLS, connection refused, timeout) returns
# non-zero and sets $_SLACK_CURL_DIAG to ONE line with no embedded newline.
# curl's own -sS diagnostics describe the FAILURE (host, port, timeout) and
# never echo a header's VALUE, so this is safe to fold into handle's single
# failure line without re-deriving that guarantee per caller.
_slack_api_call() {
  local token="$1" method="$2" path="$3" out_file="$4" json="${5:-}" \
    work_dir cfg curl_err rc=0
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-slack-curl.XXXXXX")" || {
    _SLACK_CURL_DIAG="could not create a temp dir for the request"
    return 1
  }
  # Baked in with printf %q, not read from the variable, the same reason
  # remote.sh's HTTP helpers do this: a trap set inside a function cannot see
  # that function's own locals once its frame is gone, so an EXIT trap
  # referencing $work_dir directly would find it unset if this fires via
  # errexit unwinding out of this function.
  trap "rm -rf $(printf '%q' "$work_dir")" EXIT INT TERM
  cfg="$work_dir/config"
  curl_err="$work_dir/stderr"
  : > "$cfg"
  chmod 600 "$cfg"
  {
    printf 'url = "%s/%s"\n' "$(_slack_api_base)" "$path"
    printf 'header = "Authorization: Bearer %s"\n' "$(_slack_curl_quote "$token")"
    if [ "$method" = "POST" ]; then
      printf 'request = "POST"\n'
      printf 'header = "Content-Type: application/json; charset=utf-8"\n'
      printf 'data = "@-"\n'
    fi
    printf 'connect-timeout = "10"\n'
    printf 'max-time = "25"\n'
  } > "$cfg"
  _SLACK_HTTP_CODE="$(printf '%s' "$json" | curl -sS -o "$out_file" -w '%{http_code}' -K "$cfg" 2>"$curl_err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    _SLACK_CURL_DIAG="$(tr '\n' ' ' < "$curl_err" 2>/dev/null | cut -c1-200)"
    [ -n "$_SLACK_CURL_DIAG" ] || _SLACK_CURL_DIAG="curl exited $rc"
    rm -rf "$work_dir"
    trap - EXIT INT TERM
    return 1
  fi
  rm -rf "$work_dir"
  trap - EXIT INT TERM
  return 0
}
