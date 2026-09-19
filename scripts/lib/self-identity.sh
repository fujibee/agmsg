#!/usr/bin/env bash
# self-identity.sh — the PURE half of a seat deriving its own pane (#1152).
#
# "Pure" is the whole point of this file. It holds the mark, the line grammar and
# the classifier, and it holds NOTHING that reaches a terminal: no pane
# candidate, no emit, no pane read, no writer a caller could hand a raw pane to.
# Those parts' shape still depends on a measurement that has not come back (can a
# codex seat read panes at all?) and on who owns the projection writes, and a
# pure function that quietly did them would be that half wearing a different
# name. A test pins their absence by name.
#
# WHAT THE MARK IS FOR. A seat whose commands run outside its pane cannot learn
# which pane is its own from the environment: the environment answers about the
# PROCESS, and for a seat under a shared app-server the process is not where the
# seat lives (measured, #1112: three seats resolving one pane while sitting in
# three). What does distinguish them is where the seat's own output renders.
#
# THE MARK IS A ONE-SHOT FRESHNESS CHALLENGE. It is NOT a secret, and nothing
# here may rest on it being one: a mark is rendered on a screen and may be
# scrolled, copied, logged or quoted, and that is normal. What makes a hit
# evidence is that this mark was minted for this one attempt and did not exist
# anywhere before it -- so a row carrying it is a row written after the challenge
# began. That is why the observation needs a BASELINE taken before the emit
# (someone else's business, not this file's) and why a mark is never reused: a
# second use cannot be told apart from the leftovers of the first.
#
# WHAT THIS DOES NOT RULE OUT, said plainly: if the mark is copied into a pane
# that is not the seat's while the attempt is open, the classifier will see it
# there and cannot tell the copy from the original. `ambiguous` catches the case
# where both panes carry it; a copy into a pane where the seat's own output never
# landed is a false positive this design does not close. The freshness window and
# the uniqueness requirement narrow it; they do not remove it.

[ -n "${_AGMSG_SELF_IDENTITY_SH:-}" ] && return 0
_AGMSG_SELF_IDENTITY_SH=1

# The agreed shape: 17 characters, `agp-` plus 13 base32 characters.
_AGMSG_SELF_MARK_PREFIX="agp-"
_AGMSG_SELF_MARK_DIGEST_CHARS=13
_AGMSG_SELF_MARK_LEN=17

# THE ALPHABETS, as literal strings. Membership is tested character by character
# with `test =`, never with a glob -- see _agmsg_self_chars_in_set for why.
_AGMSG_SELF_MARK_ALPHABET="abcdefghijklmnopqrstuvwxyz234567"
_AGMSG_SELF_HEX_ALPHABET="0123456789abcdef"

# Is every character of <string> in <alphabet>? An empty string is not.
#
# NO GLOB, AND NOT ONLY BECAUSE OF THE LOCALE. Two separate shell settings widen
# a pattern past what this file means by its alphabet, and both were measured on
# this machine:
#
#                        bash 3.2            bash 5
#   case [a-z]           widened by LOCALE   not widened      (collation order)
#   case [abc...]        widened by NOCASE   widened by NOCASE
#   [[ x == y ]]         widened by NOCASE   widened by NOCASE
#   [ x = y ]            not widened         not widened
#   ${s#pat} ${s%pat}    not widened         not widened
#
# The first row is why the range became an explicit set. The second row is why
# the set is gone too: `shopt -s nocasematch` is the CALLER's setting, this file
# is SOURCED into the caller's shell, and under it `case A in [abc...])` matches
# on BOTH interpreters -- so the grammar would accept upper case in any caller
# that happens to have the option on, and the locale test would go red for a
# reason that has nothing to do with the locale (found in review).
#
# `test =` is literal string equality under both settings on both interpreters,
# so the check is built out of that alone. Note also what this function does NOT
# do: it sets no shell option and restores none. Never touching one is the only
# version of "leaves the caller's options as it found them" that cannot be got
# wrong -- and on bash 3.2, saving and restoring an option around a function is
# its own question.
_agmsg_self_chars_in_set() {   # <string> <alphabet>
  local s="${1-}" set="${2-}" n m i j c found
  n=${#s}; m=${#set}
  [ "$n" -gt 0 ] && [ "$m" -gt 0 ] || return 1
  i=0
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    found=""
    j=0
    while [ "$j" -lt "$m" ]; do
      if [ "$c" = "${set:$j:1}" ]; then found=1; break; fi
      j=$((j + 1))
    done
    [ -n "$found" ] || return 1
    i=$((i + 1))
  done
  return 0
}

# Is this exactly a mark? The grammar is checked everywhere a mark crosses a
# boundary, because a function that accepts "any non-empty string" accepts a
# newline, a row of spaces, or somebody else's token, and then every later
# comparison is against something that was never a mark.
_agmsg_self_mark_ok() {   # <candidate>
  local s="${1-}" rest
  [ "${#s}" -eq "$_AGMSG_SELF_MARK_LEN" ] || return 1
  # Prefix removal, not a pattern test: parameter expansion is the one construct
  # in the table above that neither setting widens.
  rest="${s#"$_AGMSG_SELF_MARK_PREFIX"}"
  [ "$rest" != "$s" ] || return 1
  [ "${#rest}" -eq "$_AGMSG_SELF_MARK_DIGEST_CHARS" ] || return 1
  _agmsg_self_chars_in_set "$rest" "$_AGMSG_SELF_MARK_ALPHABET"
}

# A fresh mark, or nothing.
#
# ENTROPY IS CHECKED, NOT HOPED FOR. An earlier revision built the mark from a
# group pipeline whose `/dev/urandom` half could fail or read short without
# anybody noticing -- the pid and the clock would carry on alone, and a hash does
# not add entropy to what it is given. So the random bytes are read on their own,
# and their length is verified before anything else happens. The pid and the time
# are still mixed in, but they are DOMAIN SEPARATION (two seats drawing at the
# same instant do not collide), not a second source of entropy.
#
# Unavailable, short, or unreadable entropy is a refusal. A mark with less than
# the intended entropy is worse than no mark: it still looks like one.
agmsg_self_mark() {
  local bytes hex rest
  command -v agmsg_sha256 >/dev/null 2>&1 || return 1
  # The encoder needs awk. If it is not there this REFUSES -- it does not fall
  # back. A mark produced by a degraded encoder is still shaped like a mark.
  command -v awk >/dev/null 2>&1 || return 1
  # Exactly 32 bytes, as hex. `od` is used rather than `xxd` because the minimal
  # PATH the entry points must work under carries `od` and not `xxd`.
  bytes="$(head -c 32 /dev/urandom 2>/dev/null | od -An -v -tx1 2>/dev/null | tr -d ' \n')" || return 1
  # 32 bytes is 64 hex characters. A short read, a missing /dev/urandom, or an
  # `od` that printed nothing all land here.
  [ "${#bytes}" -eq 64 ] || return 1
  _agmsg_self_chars_in_set "$bytes" "$_AGMSG_SELF_HEX_ALPHABET" || return 1
  hex="$(printf '%s\n%s\n%s' "$bytes" "$$" "$(date -u +%s 2>/dev/null)" | agmsg_sha256)" || return 1
  # Exactly 64 lower-case hex characters. `>= 32` with no alphabet check was not
  # a check: the base32 encoder SKIPS characters that are not hex nibbles, so a
  # truncated or non-hex digest would have produced a short-but-plausible mark
  # instead of a refusal (found in review).
  [ "${#hex}" -eq 64 ] || return 1
  _agmsg_self_chars_in_set "$hex" "$_AGMSG_SELF_HEX_ALPHABET" || return 1
  rest="$(printf '%s' "$hex" | _agmsg_self_base32)"
  rest="${rest:0:$_AGMSG_SELF_MARK_DIGEST_CHARS}"
  [ "${#rest}" -eq "$_AGMSG_SELF_MARK_DIGEST_CHARS" ] || return 1
  local mark="$_AGMSG_SELF_MARK_PREFIX$rest"
  _agmsg_self_mark_ok "$mark" || return 1
  printf '%s\n' "$mark"
}

# base32 (RFC 4648 alphabet, lower case, no padding) of the hex string on stdin.
#
# DEPENDENCIES, and what happens when one is missing.
#
# This file uses `awk`, `head`, `od`, `tr` and `date`, plus `agmsg_sha256` and
# `/dev/urandom`. `head`, `od`, `tr` and `date` are on the minimal list in
# registry-lock.sh; `awk` is NOT, and neither is `base32` -- which is why the
# encoding is written out here rather than shelled out, and why the pair key is
# an awk array rather than a bash one (bash 3.2, the macOS /bin/bash, has no
# associative arrays).
#
# That leaves a real question -- may a caller bound by the minimal PATH call in
# here? -- and this file does not get to answer it. What it does instead is make
# the absence LOUD: without `awk`, `agmsg_self_mark` refuses and
# `agmsg_self_classify` says `unreadable`. Neither degrades into a weaker mark or
# a count taken without looking. A test pins both, and a test derives the whole
# dependency set from the code so the list above cannot drift away from it.
_agmsg_self_base32() {
  LC_ALL=C awk '
    BEGIN { a = "abcdefghijklmnopqrstuvwxyz234567" }
    {
      n = length($0); bits = ""; out = ""
      for (i = 1; i <= n; i++) {
        c = tolower(substr($0, i, 1))
        v = index("0123456789abcdef", c) - 1
        if (v < 0) continue
        for (b = 8; b >= 1; b /= 2) { bits = bits ((int(v / b) % 2) ? "1" : "0") }
      }
      for (i = 1; i + 4 <= length(bits); i += 5) {
        v = 0
        for (j = 0; j < 5; j++) { v = v * 2 + substr(bits, i + j, 1) }
        out = out substr(a, v + 1, 1)
      }
      print out
    }'
}

# The line a seat emits, and the only line the classifier accepts. One line,
# nothing before or after it on that row.
agmsg_self_mark_line() {   # <mark>
  _agmsg_self_mark_ok "${1-}" || return 1
  printf '%s\n' "$1"
}

# Does this row, as read back from a pane, carry exactly this mark?
#
# Only a trailing CR is normalised away -- terminals differ on line endings and
# nothing else about the row may be adjusted. Trimming spaces, or matching a
# substring, would accept a row that merely CONTAINS the mark, which is exactly
# what quoting it produces.
_agmsg_self_line_is_mark() {   # <line> <mark>
  local line="${1-}" mark="${2-}"
  _agmsg_self_mark_ok "$mark" || return 1
  line="${line%$'\r'}"
  [ "$line" = "$mark" ]
}

# The classifier. PURE, and deliberately not a chooser.
#
# It takes an observation that SOMEONE ELSE made, in a file, and says which of
# four things that observation is. It does not acquire a candidate, does not read
# a pane, and does not select a location.
#
# Input file, one record per line:
#
#   <terminal>\t<pane>\t<line>     a line that was read from that pane
#   !\t<terminal>\t<pane>          that pane could NOT be read
#
# Output:
#
#   rc 0   unique\t<terminal>\t<pane>   exactly one pane carried the mark, and
#                                       every pane in the observation was read
#   rc 1   not_observed                 no pane carried it
#   rc 1   ambiguous                    more than one pane carried it
#   rc 1   unreadable                   a pane could not be read, OR the
#                                       observation itself could not be trusted
#
# The `unique` row carries the pane as a WITNESS -- what the observation showed
# -- not as a decision. Whoever asked is the one entitled to act on it.
#
# UNREADABLE BEATS A HIT, deliberately. One hit plus one pane nobody could open
# is not "exactly one": it is "one that we saw", and the mark could be in the
# pane that would not open. Uniqueness is a claim about ALL panes, so a gap in
# the observation is a gap in the claim.
#
# A MALFORMED ROW IS ALSO A GAP. A row with the wrong number of fields, an
# unrecognised record kind, or a terminal/pane that is not a plausible id, means
# the observation is not the thing this function knows how to read. Skipping such
# rows and answering from the rest would report a count over an input we did not
# understand -- so the whole observation is `unreadable`.
agmsg_self_classify() {   # <mark> <observation-file>
  local mark="${1-}" obs="${2-}" out
  _agmsg_self_mark_ok "$mark" || { printf 'unreadable\n'; return 1; }
  # A file that cannot be read is not an empty observation.
  [ -n "$obs" ] && [ -r "$obs" ] || { printf 'unreadable\n'; return 1; }
  # The pass needs awk (bash 3.2 on macOS has no associative arrays, which is
  # what the pair key needs). Without it the answer is `unreadable`: a missing
  # tool is a gap in the observation, and the one thing it must never become is
  # a count.
  command -v awk >/dev/null 2>&1 || { printf 'unreadable\n'; return 1; }
  # awk does the whole pass: the pair key lives in an associative array, so a
  # pane id carrying `*`, `?`, `[`, `;` or `:` cannot collide with another pair
  # the way a string-concatenation key in shell could (found in review).
  out="$(LC_ALL=C awk -v mark="$mark" '
    # `exit` runs END, so a verdict printed here would be printed again there.
    # The flag is the verdict; END is the only place that prints.
    function bad() { malformed = 1; exit }
    # FRAMING ONLY. Whether an id is a valid id for its driver is the driver s
    # question -- tmux socket paths carry ordinary spaces (a home directory with
    # a space in it is normal) and the tmux driver deliberately allows them,
    # rejecting only control bytes. A charset here would be this file quietly
    # narrowing somebody else s grammar, and the panes it rejected would look
    # like a malformed observation rather than a pane it refused to consider.
    function field_ok(v) { return (v != "" && v !~ /[\001-\037\177]/) }
    BEGIN { FS = "\t"; unreadable = 0; malformed = 0; n = 0 }
    {
      if ($0 == "") next
      if ($1 == "!") {
        if (NF != 3) bad()
        if (!field_ok($2) || !field_ok($3)) bad()
        unreadable = 1
        next
      }
      if (NF < 3) bad()
      term = $1; pane = $2
      if (!field_ok(term) || !field_ok(pane)) bad()
      # The text is everything after the second tab, so a rendered row that
      # itself contains tabs is compared whole rather than truncated.
      text = $3
      for (i = 4; i <= NF; i++) text = text "\t" $i
      sub(/\r$/, "", text)
      if (text != mark) next
      key = term SUBSEP pane
      if (!(key in seen)) { seen[key] = 1; n++; first_t = (n == 1 ? term : first_t); first_p = (n == 1 ? pane : first_p) }
    }
    END {
      if (malformed)  { print "unreadable"; exit 0 }
      if (unreadable) { print "unreadable"; exit 0 }
      if (n == 0) { print "not_observed"; exit 0 }
      if (n > 1)  { print "ambiguous";    exit 0 }
      printf "unique\t%s\t%s\n", first_t, first_p
    }' "$obs")" || { printf 'unreadable\n'; return 1; }
  printf '%s\n' "$out"
  # Literal, for the reason the alphabet check is literal: `case` is widened by
  # nocasematch, and the verdict word is a fixed string.
  [ "${out:0:7}" = "unique"$'\t' ] || return 1
  return 0
}
