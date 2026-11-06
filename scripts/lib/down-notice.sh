#!/usr/bin/env bash
# down-notice.sh — a durable "this component is down or degraded" record.
#
# A resident part of agmsg (the sync engine, the watcher, a bridge) that stops
# and cannot bring itself back must not do so silently. It writes one small file
# under <install>/run/down/, through this helper, and the places a person already
# looks show it: the component's own `status`, `doctor`, and once at the start of
# a session. The record carries the state, the reason and the command that
# recovers it. It is not a message to members and not an OS notification.
#
#   down_notice_set <component> <down|degraded> <reason> <recovery command>
#   down_notice_clear <component>
#   down_notice_list    "<component>\t<state>\t<since>\t<reason>\t<recovery>" per record
#   down_notice_key <prefix> <value>   a valid component key built from free text,
#                                      ending in a hash of the raw text
#   down_notice_print [prefix]  the records (of one family) as text; nothing when none
#   down_notice_print_once  the same, once per record per session start
#
# <component> matches ^[a-z0-9][a-z0-9._-]{0,99}$; anything else is refused
# (return 2) and nothing is written. Callers scope their key (`sync.<team>`) so
# one healthy caller never clears another's record. Every other outcome returns
# 0 (set: done and verified, clear: gone), 1 (an I/O failure, one line on stderr),
# 2 (invalid input). A caller never lets a failed notice fail its own path.
#
# Process launches (programs started; the `$( )` substitutions around builtins are
# shell forks that start no program):
#   source          none; one shell fork to find the install root
#   set             `date` + `mv`, and `mkdir` the first time
#   clear           `rm`
#   list / print    none (records are read with `$(<file)`)
#   print_once      none
#   key             none (the hash is shell arithmetic)
# No locking: one writer per key by construction.
#
# The record is JSON, written without any escaping logic: `"` and `\` in free
# text become `'` and `/`, and every control character (newline, tab, ESC, ...)
# becomes a space, so every field is a plain string that is valid JSON and is read
# back with parameter expansion.

[ -n "${_AGMSG_DOWN_NOTICE_SH:-}" ] && return 0
_AGMSG_DOWN_NOTICE_SH=1

# The install this file ships in, not the caller's cwd or an ambient SKILL_DIR:
# tests get their sandbox copy for free. A caller can set AGMSG_DOWN_NOTICE_ROOT
# for its own calls (see _down_notice_dir).
_AGMSG_DOWN_NOTICE_ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." 2>/dev/null && pwd)"

_down_notice_dir() {
  # AGMSG_DOWN_NOTICE_ROOT is for a caller that keeps its state elsewhere and says
  # so itself (remote.sh passes its connection root for the sync engine). No
  # ambient variable redirects the records of every component.
  local root="${AGMSG_DOWN_NOTICE_ROOT:-$_AGMSG_DOWN_NOTICE_ROOT}"
  [ -n "$root" ] || return 1
  printf '%s/run/down\n' "$root"
}

_down_notice_key_ok() {
  # Ranges follow the collation order outside the C locale (on macOS a-z can match
  # an uppercase letter), so the check pins it.
  local LC_ALL=C
  case "$1" in
    '') return 1 ;;
    [!a-z0-9]*) return 1 ;;
    *[!a-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 100 ]
}

# The replacements go through variables: on bash 3.2 a quoted or backslashed
# literal on the replacement side keeps its backslash, which turned a recovery
# command's quoted path into a different path.
_down_notice_clean() {   # free text -> one line of printable text, no quote, no backslash
  # shellcheck disable=SC1003  # a lone backslash is the point
  local LC_ALL=C v="${1-}" dq='"' sq="'" bs='\' sl='/' sp=' '
  v="${v//$dq/$sq}"
  v="${v//"$bs"/$sl}"
  v="${v//[[:cntrl:]]/$sp}"
  printf '%s' "$v"
}

# <json text> <field> -> the field's string value
_down_notice_field() {
  local rest="${1#*\""$2"\":\"}"
  [ "$rest" != "$1" ] || return 1
  printf '%s' "${rest%%\"*}"
}

# A key from free text: folded to lowercase with unusable characters as `-`, then
# an 8-hex hash of the RAW text, so two different texts never share a key just
# because they fold alike ('My Team' and 'my-team'). The hash is FNV-1a over the
# bytes, in shell arithmetic and builtins only: no process is started.
down_notice_key() {   # <prefix> <free text> -> prefix.slug-<8 hex>
  local LC_ALL=C v="${2-}" slug="" i ch n h=2166136261 hex
  for ((i = 0; i < ${#v}; i++)); do
    ch="${v:i:1}"
    printf -v n '%d' "'$ch"
    # bash 3.2 reads a byte above 0x7f as a negative number, bash 5 as 128..255.
    n=$(( n & 255 ))
    h=$(( ((h ^ n) * 16777619) & 4294967295 ))
  done
  printf -v hex '%08x' "$h"
  v="${v//A/a}"; v="${v//B/b}"; v="${v//C/c}"; v="${v//D/d}"; v="${v//E/e}"; v="${v//F/f}"
  v="${v//G/g}"; v="${v//H/h}"; v="${v//I/i}"; v="${v//J/j}"; v="${v//K/k}"; v="${v//L/l}"
  v="${v//M/m}"; v="${v//N/n}"; v="${v//O/o}"; v="${v//P/p}"; v="${v//Q/q}"; v="${v//R/r}"
  v="${v//S/s}"; v="${v//T/t}"; v="${v//U/u}"; v="${v//V/v}"; v="${v//W/w}"; v="${v//X/x}"
  v="${v//Y/y}"; v="${v//Z/z}"
  for ((i = 0; i < ${#v}; i++)); do
    ch="${v:i:1}"
    case "$ch" in [a-z0-9._-]) slug="$slug$ch" ;; *) slug="$slug-" ;; esac
  done
  # prefix + "." + slug + "-" + 8 hex must fit the 100-character limit.
  local room=$(( 100 - ${#1} - 10 ))
  [ "$room" -gt 0 ] || room=0
  slug="${slug:0:room}"
  printf '%s.%s-%s\n' "$1" "$slug" "$hex"
}

# 0 = done and verified (the record exists with the new content), 1 = an I/O
# failure (one line on stderr), 2 = an invalid key or state (nothing written).
# A caller never lets this fail its own path (`down_notice_set ... || :`); it
# looks at the status only to decide whether to try again later, and a caller that
# remembers "already written" remembers it only on 0.
down_notice_set() {   # <component> <down|degraded> <reason> <recovery>
  local key="${1-}" state="${2-}" dir f tmp since="" old="" now line
  _down_notice_key_ok "$key" || return 2
  case "$state" in down|degraded) ;; *) return 2 ;; esac
  dir="$(_down_notice_dir)" || { echo "agmsg: could not record that $key is $state (no install root)" >&2; return 1; }
  if [ ! -d "$dir" ] && ! mkdir -p "$dir" 2>/dev/null; then
    echo "agmsg: could not record that $key is $state (cannot create $dir)" >&2
    return 1
  fi
  f="$dir/$key.json"
  tmp="$dir/.$key.json.$$"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -f "$f" ]; then
    old="$(<"$f")" 2>/dev/null || old=""
    # "since" is when it first went into THIS state; a change of state restarts it.
    if [ "$(_down_notice_field "$old" state)" = "$state" ]; then since="$(_down_notice_field "$old" since)"; fi
  fi
  [ -n "$since" ] || since="$now"
  line="$(printf '{"component":"%s","state":"%s","reason":"%s","recovery":"%s","since":"%s","updated":"%s"}' \
    "$key" "$state" "$(_down_notice_clean "${3-}")" "$(_down_notice_clean "${4-}")" "$since" "$now")"
  # 2>/dev/null FIRST: redirections are processed left to right, and the shell's
  # own "Permission denied" for the failed open of $tmp would otherwise print
  # before the redirection that hides it, giving two lines for one failure.
  if ! printf '%s\n' "$line" 2>/dev/null >"$tmp"; then
    rm -f "$tmp" 2>/dev/null
    echo "agmsg: could not record that $key is $state (cannot write in $dir)" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$f" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    echo "agmsg: could not record that $key is $state" >&2
    return 1
  fi
  # Verified, not assumed: the record is there with the content just written.
  if [ ! -f "$f" ] || [ "$(<"$f")" != "$line" ] 2>/dev/null; then
    echo "agmsg: could not record that $key is $state (the record did not read back)" >&2
    return 1
  fi
  return 0
}

# 0 = the record is gone (or never existed), 1 = it could not be removed or
# its absence could not be established, 2 = an invalid key.
down_notice_clear() {   # <component>
  local dir
  _down_notice_key_ok "${1-}" || return 2
  dir="$(_down_notice_dir)" || { echo "agmsg: could not clear the record for $1 (no install root)" >&2; return 1; }
  rm -f "$dir/$1.json.shown" 2>/dev/null
  # The result of the removal itself decides, not a look at the path afterwards:
  # under an unsearchable directory the removal fails AND the path cannot be seen,
  # and "I cannot see it" is not "it is gone". `rm -f` returns 0 for a record that
  # was never there and for one it removed, and non-zero for one it could not.
  if ! rm -f "$dir/$1.json" 2>/dev/null; then
    echo "agmsg: could not clear the record for $1 (cannot remove $dir/$1.json)" >&2
    return 1
  fi
  return 0
}

_down_notice_row() {   # <json> -> one list line
  printf '%s\t%s\t%s\t%s\t%s\n' "$(_down_notice_field "$1" component)" "$(_down_notice_field "$1" state)" \
    "$(_down_notice_field "$1" since)" "$(_down_notice_field "$1" reason)" "$(_down_notice_field "$1" recovery)"
}

down_notice_list() {
  local dir f json
  dir="$(_down_notice_dir)" || return 0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    json="$(<"$f")" 2>/dev/null || continue
    _down_notice_row "$json"
  done
  return 0
}

_down_notice_text() {   # records on stdin
  local component state since reason recovery
  while IFS=$'\t' read -r component state since reason recovery; do
    [ -n "$component" ] || continue
    printf 'AGMSG: %s is %s since %s: %s\n' "$component" "$state" "$since" "$reason"
    [ -z "$recovery" ] || printf '  recover with: %s\n' "$recovery"
  done
}

# An optional prefix limits it to one component family (`sync.`). Builtins only:
# it must work on a PATH with no awk, and with no record it returns at once.
down_notice_print() {
  local prefix="${1-}" component state since reason recovery
  while IFS=$'\t' read -r component state since reason recovery; do
    [ -n "$component" ] || continue
    case "$component" in "$prefix"*) ;; *) continue ;; esac
    printf 'AGMSG: %s is %s since %s: %s\n' "$component" "$state" "$since" "$reason"
    [ -z "$recovery" ] || printf '  recover with: %s\n' "$recovery"
  done < <(down_notice_list)
  return 0
}

# Shown once per record: the marker holds the record it was shown for (state,
# since, reason, recovery -- not `updated`, which changes every time the same
# record is set again), so a record that changed is shown again and one that did
# not is not.
down_notice_print_once() {
  local dir f json row
  dir="$(_down_notice_dir)" || return 0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    json="$(<"$f")" 2>/dev/null || continue
    [ -n "$json" ] || continue
    row="$(_down_notice_row "$json")"
    if [ -f "$f.shown" ] && [ "$(<"$f.shown")" = "$row" ] 2>/dev/null; then continue; fi
    printf '%s\n' "$row" | _down_notice_text
    printf '%s\n' "$row" >"$f.shown" 2>/dev/null || true
  done
  return 0
}
