#!/usr/bin/env bash
# input-box.sh — is a pane's input box currently empty?
#
# poke.sh types into a live pane and submits it. Before this existed, herdr's
# `agent prompt` (poke's own submission mechanism) had no way to know the
# caller was about to type over a person's own half-typed draft, and rearm.sh
# poking every seat at once did exactly that to a live pane once.
#
# Recognizing "empty" is a TYPE-specific question — each CLI's TUI draws its
# own prompt differently — so the recognition RULE lives as manifest data on
# that type (input_prompt_marker, input_prompt_boxed in type.conf), never as
# per-type code: manifests are read-only key=value data and are never sourced
# (the types-axis contract), so a type cannot ship its own check function.
# What lives here is the one shared INTERPRETATION of that data, common to
# every type that opts in by setting input_prompt_marker.
#
# Matching below is done with `case`/parameter-expansion, never `[[ x == y ]]`
# or `[[ x =~ y ]]`: both are widened by a caller's `shopt -s nocasematch`,
# which this file does not set and must not assume off (self-identity.sh's
# lesson). The literals matched here (❯, ›, ─) have no case, so the risk is
# theoretical for THIS data — but the file follows the house rule anyway
# rather than re-deciding it per character.

[ -n "${_AGMSG_INPUT_BOX_SH:-}" ] && return 0
_AGMSG_INPUT_BOX_SH=1

# 20 repeated box-drawing horizontal-line characters (U+2500). Measured live
# on a real Claude Code pane (2026-09-18): both the top rule (which also
# carries the pane's own label AFTER this many characters) and the bottom
# rule run 80+ long, so 20 never reaches into the label.
_AGMSG_INPUT_BOX_RULE20="────────────────────"

# agmsg_input_box_empty <marker> <boxed:yes|""> <screen_text>
# Returns 0 if <screen_text>, AT THE MOMENT IT WAS READ, showed the box this
# type's manifest describes as empty, 1 otherwise — INCLUDING when
# <screen_text> does not carry enough structure to decide. "Cannot tell"
# fails toward refusing to type, never toward typing; the caller (poke.sh)
# is the one place that turns a 1 here into a user-facing refusal.
#
# This narrows the window a poke can corrupt a draft; it does not close it.
# A person can start typing in the instant between this read and poke.sh's
# actual keystroke, and that keystroke can still land mixed with theirs —
# no mechanism here closes that gap (maintainer-accepted residual risk,
# #1321 review). Never describe this as "poke cannot type into a non-empty
# box" without that qualifier.
agmsg_input_box_empty() {
  local marker="$1" boxed="$2" screen="$3"
  [ -n "$marker" ] || return 1
  if [ "$boxed" = yes ]; then
    _agmsg_input_box_empty_boxed "$marker" "$screen"
  else
    _agmsg_input_box_empty_flat "$marker" "$screen"
  fi
}

# Boxed style (Claude Code): the input sits between the LAST two lines whose
# content starts with a run of 20+ "─" — the top rule also carries the
# pane's own label after its run, the bottom rule is unbroken. Empty means
# every line strictly between that pair is blank except the one starting
# with <marker>, and that one has nothing but whitespace after the marker.
_agmsg_input_box_empty_boxed() {
  local marker="$1" screen="$2" rule="$_AGMSG_INPUT_BOX_RULE20"
  local -a lines=()
  local line n=0
  while IFS= read -r line; do
    lines[n]="$line"
    n=$((n + 1))
  done <<<"$screen"

  local top=-1 bottom=-1 i=0
  while [ "$i" -lt "$n" ]; do
    case "${lines[$i]}" in
      "$rule"*) top="$bottom"; bottom="$i" ;;
    esac
    i=$((i + 1))
  done
  [ "$top" -ge 0 ] || return 1
  [ "$bottom" -gt "$top" ] || return 1

  local marker_seen=0 content rest
  i=$((top + 1))
  while [ "$i" -lt "$bottom" ]; do
    content="${lines[$i]}"
    case "$content" in
      "$marker"*)
        marker_seen=1
        rest="${content#"$marker"}"
        case "$rest" in ' '*) rest="${rest# }" ;; esac
        case "$rest" in *[![:space:]]*) return 1 ;; esac
        ;;
      *)
        case "$content" in *[![:space:]]*) return 1 ;; esac
        ;;
    esac
    i=$((i + 1))
  done
  [ "$marker_seen" -eq 1 ] || return 1
  return 0
}

# Flat style (Codex): no boxed delimiters. Two ways a naive "check only the
# last marker line" reading goes wrong (#1321 review): a multi-line
# draft whose FIRST line (the one carrying the marker) happens to be blank
# itself, with the actual typed text on a continuation line below it; and a
# stale marker left over higher up the screen while the live input box has
# scrolled out of view (or this is quoted/transcript text, not the prompt
# widget at all). Both must read as "not confirmed empty", never as empty.
_agmsg_input_box_empty_flat() {
  local marker="$1" screen="$2"
  local -a lines=()
  local line n=0
  while IFS= read -r line; do
    lines[n]="$line"
    n=$((n + 1))
  done <<<"$screen"
  [ "$n" -gt 0 ] || return 1

  local marker_idx=-1 i=0
  while [ "$i" -lt "$n" ]; do
    case "${lines[$i]}" in
      "$marker"*) marker_idx="$i" ;;
    esac
    i=$((i + 1))
  done
  [ "$marker_idx" -ge 0 ] || return 1

  # Must sit near the very bottom of the visible screen. NOT measured
  # against a real Codex pane (unlike Claude Code's boxed rule, captured
  # live) -- this constant is a deliberately conservative placeholder;
  # further from the bottom than this reads as "could not confirm", not
  # "confirmed empty".
  local near_bottom=6
  [ $((n - marker_idx)) -le "$near_bottom" ] || return 1

  # Everything strictly after the marker line must be blank -- a
  # continuation line with real text is exactly the multi-line-draft case
  # a check anchored only on the marker line's own tail would miss.
  i=$((marker_idx + 1))
  while [ "$i" -lt "$n" ]; do
    case "${lines[$i]}" in
      *[![:space:]]*) return 1 ;;
    esac
    i=$((i + 1))
  done

  local rest
  rest="${lines[$marker_idx]#"$marker"}"
  case "$rest" in ' '*) rest="${rest# }" ;; esac
  case "$rest" in *[![:space:]]*) return 1 ;; esac
  return 0
}
