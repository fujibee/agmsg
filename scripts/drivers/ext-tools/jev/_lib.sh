#!/usr/bin/env bash
# Shared helpers for handle and setup. Sourced, not executed; no shebang exec bit.
#
# Nothing here prints or logs the OpenRouter key. _jev_read_key is the only
# function that ever holds one in a variable ($_JEV_KEY); every caller passes
# it straight to _jev_api_call's Authorization header -- never to echo, never
# to a file this library writes.

# Read a single key from a member config file, or from a tool.conf-shaped
# manifest (same key=value shape, read the same way: never sourced, so a
# config file cannot run arbitrary shell just by being loaded). Returns empty
# if the file or key is absent -- callers decide whether that is fatal.
_jev_conf_get() {   # <config_path> <key>
  local config_path="$1" key="$2" line
  [ -f "$config_path" ] || return 0
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$config_path" 2>/dev/null | head -1)" || true
  printf '%s' "${line#*=}"
}

# OpenRouter's own base URL. Overridable so tests point this at a loopback
# fixture instead of the real API (design note §5b: real API never called in
# CI); production leaves it unset and gets the real one.
_jev_api_base() {
  printf '%s' "${AGMSG_JEV_API_BASE:-https://openrouter.ai}"
}

# A usable key is one line (no embedded newline) with no whitespace anywhere.
# Checked before the key is ever embedded in a curl -K config line, because a
# config file is LINE-based: an embedded newline ends a `header = "..."` line
# right there regardless of quoting, and everything after it is read as a
# FURTHER config directive -- a corrupt or multi-line key_file could
# otherwise make this process's own curl call do something other than what
# this file wrote. _jev_curl_quote (below) closes the quoting half of that (a
# literal " or \); this closes the half quoting cannot touch.
_jev_key_looks_valid() {   # <key>
  [ -n "$1" ] || return 1
  case "$1" in
    *[$' \t\n\r']*) return 1 ;;
  esac
  return 0
}

# Read the API key from <key_file> into $_JEV_KEY -- NOT printed to stdout,
# on purpose: a caller that captured it via `x="$(_jev_read_key ...)"` would
# run this in a command-substitution SUBSHELL, where an error side-channel
# like $_JEV_KEY_ERROR set inside it never reaches the caller's own shell.
# Call this as a plain statement and read $_JEV_KEY/$_JEV_KEY_ERROR after,
# the same shape _jev_api_call's $_JEV_HTTP_CODE/$_JEV_CURL_DIAG use.
#
# On any failure -- missing/unreadable file, empty content, or a value that
# does not pass _jev_key_looks_valid -- sets $_JEV_KEY_ERROR to one line
# naming WHY (never the key itself) and returns non-zero.
_jev_read_key() {   # <key_file>
  local key_file="$1" key
  _JEV_KEY=""
  _JEV_KEY_ERROR=""
  if [ -z "$key_file" ] || [ ! -r "$key_file" ]; then
    _JEV_KEY_ERROR="key file not found or not readable: $key_file"
    return 1
  fi
  # Read the WHOLE file, not just its first line: a value that spans more
  # than one line must be REJECTED by _jev_key_looks_valid below, not
  # silently truncated to its first line -- truncating would hide a
  # corrupt/injected key_file instead of refusing it.
  key="$(cat "$key_file" 2>/dev/null)" || {
    _JEV_KEY_ERROR="key file not readable: $key_file"
    return 1
  }
  if [ -z "$key" ]; then
    _JEV_KEY_ERROR="key file is empty: $key_file"
    return 1
  fi
  if ! _jev_key_looks_valid "$key"; then
    _JEV_KEY_ERROR="key file does not hold a single-line key: $key_file"
    return 1
  fi
  _JEV_KEY="$key"
}

# Escape \ and " for embedding inside a curl -K config's double-quoted value.
# Handles the QUOTING half of keeping a value from escaping its config line;
# a literal newline is the other half, and that is _jev_key_looks_valid's job
# (above) -- this function alone does not make an arbitrary value safe to
# embed.
_jev_curl_quote() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# _jev_api_call <key> <json-body> <out_body_file>
#
# Never puts the key, or the request body, in this process's own argv --
# both go through a 0600 curl -K config file (the key as a header line, the
# body read from curl's OWN stdin via `data = "@-"`), so neither is visible
# to `ps` the way `-H "Authorization: Bearer $key"` or `--data "$json"` on
# the command line would be. The config file is removed no matter how this
# returns.
#
# On success (any completed HTTP exchange, including an error status)
# returns 0, writes the response body to <out_body_file>, and sets
# $_JEV_HTTP_CODE.
#
# On a transport failure (DNS, TLS, connection refused, timeout) returns
# non-zero and sets $_JEV_CURL_DIAG to ONE line with no embedded newline.
# curl's own -sS diagnostics describe the FAILURE (host, port, timeout) and
# never echo a header's VALUE, so this is safe to fold into handle's single
# failure line without re-deriving that guarantee per caller.
_jev_api_call() {
  local key="$1" json="$2" out_file="$3" \
    work_dir cfg curl_err rc=0
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-jev-curl.XXXXXX")" || {
    _JEV_CURL_DIAG="could not create a temp dir for the request"
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

  # AGMSG_JEV_API_BASE is production-reachable code even though only tests
  # set it (review finding, #1339): a curl -K config file is LINE-based, so an
  # embedded newline in this value could inject a further directive (e.g. a
  # second `header = "Authorization: ..."` line aimed at a different host)
  # regardless of quoting -- the same class of risk _jev_key_looks_valid
  # guards for the key itself. Reject it here rather than trust the source.
  local api_base
  api_base="$(_jev_api_base)"
  case "$api_base" in
    *$'\n'*)
      _JEV_CURL_DIAG="invalid API base (embedded newline)"
      rm -rf "$work_dir"
      trap - EXIT INT TERM
      return 1
      ;;
  esac

  {
    printf 'url = "%s/api/alpha/decisions"\n' "$(_jev_curl_quote "$api_base")"
    printf 'request = "POST"\n'
    printf 'header = "Authorization: Bearer %s"\n' "$(_jev_curl_quote "$key")"
    printf 'header = "Content-Type: application/json; charset=utf-8"\n'
    printf 'data = "@-"\n'
    printf 'connect-timeout = "10"\n'
    printf 'max-time = "25"\n'
  } > "$cfg"
  chmod 600 "$cfg"
  # -q (--disable) MUST be curl's first argument: it stops curl from reading
  # ~/.curlrc / the global curlrc at all (review finding, #1339). Without it, a
  # curlrc enabling verbose/trace output can print the Authorization header
  # to curl's own stderr, which line 2 below folds into $_JEV_CURL_DIAG --
  # and that diagnostic becomes part of handle's one-line reply on a
  # transport failure, leaking the key into agmsg message history.
  _JEV_HTTP_CODE="$(printf '%s' "$json" | curl -q -sS -o "$out_file" -w '%{http_code}' -K "$cfg" 2>"$curl_err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    _JEV_CURL_DIAG="$(tr '\n' ' ' < "$curl_err" 2>/dev/null | cut -c1-200)"
    [ -n "$_JEV_CURL_DIAG" ] || _JEV_CURL_DIAG="curl exited $rc"
    rm -rf "$work_dir"
    trap - EXIT INT TERM
    return 1
  fi
  rm -rf "$work_dir"
  trap - EXIT INT TERM
  return 0
}
