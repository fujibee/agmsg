#!/usr/bin/env bash
# Shared helpers for handle and setup. Sourced, not executed; no shebang exec bit.
#
# Nothing here prints or logs the OpenRouter key. _jev_read_key is the only
# function that ever holds one in a variable ($_JEV_KEY); every caller passes
# it straight to _jev_api_call's Authorization header -- never to echo, never
# to a file this library writes.

# handle's promise: a successful reply is EXACTLY one line, and whatever
# the sender wrote in the message body cannot break that -- a question's
# `choice` name (never validated, by design: see handle's own shape check)
# is echoed straight back by the endpoint and lands directly in that line.
# This is the ONE place that promise is kept: EVERY line handle sends
# anywhere -- the success reply on stdout, and the one-line failure reason
# on stderr that agmsg wraps into the sender's own reply -- is built into a
# variable and passed through here as the literal last step before it is
# ever printed, so nothing reaches either stream without going through it
# (review finding, #1364, rounds 2-3: fixing one control character at the
# CHOICE-EXTRACTION site just meant the next one reappeared at the same
# place -- the property to hold is about every line handle ever emits, not
# about guessing every input byte a caller-controlled string could carry).
_jev_one_line() {   # <text>
  local text="$1"
  text="${text//$'\r'/\\r}"
  text="${text//$'\n'/\\n}"
  # CR/LF are turned into the two-character \r/\n above rather than dropped,
  # so the message this used to be about (a newline turning one line into
  # several) stays visible in the escaped text rather than silently gone.
  # Every OTHER C0 control character (TAB, ESC, BS, ...) and DEL is not
  # informative the same way and is just noise in a line meant to be read or
  # matched by a downstream reader -- and review round 2 on the batch reply
  # found one wasn't handled at all: with several answers now sharing one
  # printed line each, a raw control byte in a caller-controlled `choice` or
  # question name could still corrupt what a reader sees, even though it can
  # no longer add a fake extra line the way a raw newline could. \r and \n
  # are already gone from $text by this point (turned into the two ordinary
  # characters \ and r/n above), so this range does not need to exclude them.
  text="$(printf '%s' "$text" | tr '\000-\037\177' ' ')"
  printf '%s' "$text"
}

# The same promise, assigned to a variable instead of printed: _jev_one_line
# above, called as `x="$(_jev_one_line ...)"`, costs a subshell and a `tr` per
# line, and on native Windows each process is the expensive part of a handle
# call (#1584). This takes the text unchanged when it holds no control
# character at all (every real reply line), which is exactly what _jev_one_line
# would return for it, and defers to _jev_one_line for anything else. [[:cntrl:]]
# includes at least every byte _jev_one_line rewrites, in any locale, so a line
# it would change is never taken as clean.
_jev_one_line_var() {   # <var> <text>
  case "$2" in
    *[[:cntrl:]]*) printf -v "$1" '%s' "$(_jev_one_line "$2")" ;;
    *) printf -v "$1" '%s' "$2" ;;
  esac
}

# Read a single key from a member config file, or from a tool.conf-shaped
# manifest (same key=value shape, read the same way: never sourced, so a
# config file cannot run arbitrary shell just by being loaded). Returns empty
# if the file or key is absent -- callers decide whether that is fatal.
#
# Read with builtins only: this runs several times per handle call, and the
# grep, head and command substitution it used to cost are each a process on
# native Windows (#1584). _jev_conf_read is the form that assigns to a variable
# (no subshell); _jev_conf_get prints, for callers that capture it.
_jev_conf_read() {   # <var> <config_path> <key>
  local _jc_line="" _jc_re="^[[:space:]]*${3}[[:space:]]*="
  printf -v "$1" '%s' ""
  [ -f "$2" ] || return 0
  while IFS= read -r _jc_line || [ -n "$_jc_line" ]; do
    if [[ $_jc_line =~ $_jc_re ]]; then
      printf -v "$1" '%s' "${_jc_line#*=}"
      return 0
    fi
  done < "$2"
  return 0
}

_jev_conf_get() {   # <config_path> <key>
  local _jg_val=""
  _jev_conf_read _jg_val "$1" "$2"
  printf '%s' "$_jg_val"
}

# The three things that vary by provider (maintainer decision, 2026-09-21):
# the base URL, the decision-endpoint path, and the default model name.
# Auth (Authorization: Bearer <key>) and the request/response shape are the
# same for both. An unrecognized provider falls back to openrouter's
# values here -- callers are expected to have already validated the
# provider string and failed on anything else; these are just table
# lookups, not where that validation happens.
_jev_provider_default_base() {   # <provider>
  case "$1" in
    typesafe) printf '%s' "https://api.typesafe.ai" ;;
    *) printf '%s' "https://openrouter.ai" ;;
  esac
}

_jev_provider_path() {   # <provider>
  case "$1" in
    typesafe) printf '%s' "/v1/systemone" ;;
    *) printf '%s' "/api/alpha/decisions" ;;
  esac
}

_jev_provider_default_model() {   # <provider>
  case "$1" in
    typesafe) printf '%s' "jev-latest" ;;
    *) printf '%s' "typesafe/jev-1.13" ;;
  esac
}

# The provider's base URL. Overridable so tests point this at a loopback
# fixture instead of the real API (design note §5b: real API never called in
# CI); production leaves it unset and gets the provider's real one. The SAME
# override variable covers both providers -- a test picks which provider's
# defaults it's overriding by which provider it passes to handle/setup, not
# by a separate env var per provider.
_jev_api_base() {   # <provider>
  printf '%s' "${AGMSG_JEV_API_BASE:-$(_jev_provider_default_base "$1")}"
}

# Splitting what handle's two jq calls print. Fields end with U+001F and
# records with U+001E (see handle), so an empty field is kept and a value can
# hold anything else. Pure parameter expansion: no read, no subshell.
#
# Both always terminate: a piece with no separator left is taken whole and ends
# the loop, so a stray fragment can never leave the remainder unconsumed.
_jev_fields() {   # <text>  ->  array $_JEV_F
  local rest="$1" f us=$'\037'
  _JEV_F=()
  while [ -n "$rest" ]; do
    case "$rest" in
      *"$us"*) f=${rest%%"$us"*}; rest=${rest#*"$us"} ;;
      *) f=$rest; rest="" ;;
    esac
    _JEV_F+=("$f")
  done
}

_jev_records() {   # <text>  ->  array $_JEV_R
  local rest="$1" f rs=$'\036'
  _JEV_R=()
  while [ -n "$rest" ]; do
    case "$rest" in
      *"$rs"*) f=${rest%%"$rs"*}; rest=${rest#*"$rs"} ;;
      *) f=$rest; rest="" ;;
    esac
    _JEV_R+=("$f")
  done
}

# Sets $_JEV_URL (the full request URL) and $_JEV_MODEL for <provider>, the
# same values the three lookups above and _jev_api_base give, without the four
# command substitutions handle would otherwise pay for them.
_jev_endpoint() {   # <provider>
  local base
  case "$1" in
    typesafe) base="https://api.typesafe.ai"; _JEV_URL_PATH="/v1/systemone"; _JEV_MODEL="jev-latest" ;;
    *) base="https://openrouter.ai"; _JEV_URL_PATH="/api/alpha/decisions"; _JEV_MODEL="typesafe/jev-1.13" ;;
  esac
  _JEV_URL="${AGMSG_JEV_API_BASE:-$base}$_JEV_URL_PATH"
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
  if [ -d "$key_file" ]; then
    _JEV_KEY_ERROR="key file not readable: $key_file"
    return 1
  fi
  # Builtin read, not cat in a command substitution (a process each on native
  # Windows, #1584). `read -d ''` stops at a NUL, so the file is read in
  # NUL-separated pieces until the end and the pieces are joined -- the NULs
  # drop out exactly as they did from "$(cat ...)", and what follows one is
  # still checked, not ignored. Trailing newlines are then dropped the same way.
  key=""
  {
    local piece="" more=0
    while :; do
      piece=""
      IFS= read -r -d '' piece && more=1 || more=0
      key+="$piece"
      [ "$more" -eq 1 ] || break
    done
  } 2>/dev/null < "$key_file" || true
  while [ "${key%$'\n'}" != "$key" ]; do key="${key%$'\n'}"; done
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

# The same escaping, assigned to a variable with parameter expansion: no sed,
# no subshell. The backslash and the quote are held in variables so the
# replacement text means the same thing in every bash this runs under.
_jev_curl_quote_into() {   # <var> <value>
  local _jq_bs='\' _jq_q='"' _jq_v="$2"
  _jq_v=${_jq_v//"$_jq_bs"/"$_jq_bs$_jq_bs"}
  _jq_v=${_jq_v//"$_jq_q"/"$_jq_bs$_jq_q"}
  printf -v "$1" '%s' "$_jq_v"
}

# _jev_api_call <key> <json-body> <out_body_file> <url>
#
# <url> is the FULL request URL, already assembled by the caller from
# _jev_api_base/_jev_provider_path for whichever provider it's calling --
# this function itself no longer decides which provider's endpoint to hit,
# only how to call one safely.
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
  local key="$1" json="$2" out_file="$3" url="$4" \
    cfg curl_err rc=0 qurl qkey diag

  # <url> is production-reachable code even though only tests actually
  # override the base it's built from (review finding, #1339): a curl -K
  # config file is LINE-based, so an embedded newline in this value could
  # inject a further directive (e.g. a second `header = "Authorization:
  # ..."` line aimed at a different host) regardless of quoting -- the same
  # class of risk _jev_key_looks_valid guards for the key itself. Reject it
  # here, covering BOTH providers' URLs the same way, rather than trust the
  # source.
  case "$url" in
    *$'\n'*)
      _JEV_CURL_DIAG="invalid API base (embedded newline)"
      return 1
      ;;
  esac

  # One private file, not a directory plus chmod: mktemp creates it 0600
  # already, so the chmod (a process, and over a second on native Windows,
  # #1584) added nothing. curl's stderr goes to a sibling name created here
  # with noclobber, so a name someone planted first is refused rather than
  # followed.
  cfg="$(mktemp "${TMPDIR:-/tmp}/agmsg-jev-curl.XXXXXX")" || {
    _JEV_CURL_DIAG="could not create a temp file for the request"
    return 1
  }
  curl_err="$cfg.err"
  # Baked in with printf %q, not read from the variables, the same reason
  # remote.sh's HTTP helpers do this: a trap set inside a function cannot see
  # that function's own locals once its frame is gone, so an EXIT trap
  # referencing $cfg directly would find it unset if this fires via
  # errexit unwinding out of this function.
  trap "rm -f $(printf '%q' "$cfg") $(printf '%q' "$curl_err")" EXIT INT TERM
  local made=0
  set -C
  if { : > "$curl_err"; } 2>/dev/null; then made=1; fi
  set +C
  if [ "$made" -ne 1 ]; then
    _JEV_CURL_DIAG="could not create a temp file for the request"
    rm -f "$cfg" "$curl_err"
    trap - EXIT INT TERM
    return 1
  fi

  _jev_curl_quote_into qurl "$url"
  _jev_curl_quote_into qkey "$key"
  {
    printf 'url = "%s"\n' "$qurl"
    printf 'request = "POST"\n'
    printf 'header = "Authorization: Bearer %s"\n' "$qkey"
    printf 'header = "Content-Type: application/json; charset=utf-8"\n'
    printf 'data = "@-"\n'
    printf 'connect-timeout = "10"\n'
    printf 'max-time = "25"\n'
  } > "$cfg"
  # -q (--disable) MUST be curl's first argument: it stops curl from reading
  # ~/.curlrc / the global curlrc at all (review finding, #1339). Without it, a
  # curlrc enabling verbose/trace output can print the Authorization header
  # to curl's own stderr, which line 2 below folds into $_JEV_CURL_DIAG --
  # and that diagnostic becomes part of handle's one-line reply on a
  # transport failure, leaking the key into agmsg message history.
  #
  # The body reaches curl's stdin through a here-string rather than a pipe from
  # printf (a subshell). curl strips newlines from `data = "@-"`, which is all
  # the here-string's trailing one is.
  _JEV_HTTP_CODE="$(curl -q -sS -o "$out_file" -w '%{http_code}' -K "$cfg" 2>"$curl_err" <<<"$json")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    diag=""
    IFS= read -r -d '' diag < "$curl_err" 2>/dev/null || true
    diag="${diag//$'\n'/ }"
    _JEV_CURL_DIAG="${diag:0:200}"
    [ -n "$_JEV_CURL_DIAG" ] || _JEV_CURL_DIAG="curl exited $rc"
    rm -f "$cfg" "$curl_err"
    trap - EXIT INT TERM
    return 1
  fi
  rm -f "$cfg" "$curl_err"
  trap - EXIT INT TERM
  return 0
}
