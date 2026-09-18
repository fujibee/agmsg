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

# Flat style (Codex): no boxed delimiters, so a bare "last line starting
# with the marker" reading cannot tell a live input box from a stale "›"
# left over on screen with the real box scrolled out of view (or quoted
# transcript text) -- a proximity guess ("near the bottom") does not prove
# that either, and was rejected on review (#1321) for exactly that reason:
# a blank stale marker with blank lines after it, and no live box at all,
# passed it.
#
# What actually distinguishes the live widget, measured read-only on 5
# real, currently-running Codex panes on this machine (2026-09-18), every
# one of them: the marker line is followed by exactly one blank
# line, then a status footer line containing "·" (U+00B7, the field
# separator in "<model> <effort> · <cwd> · <task>") -- e.g.
#   › Ask Codex to do anything
#
#     gpt-5.6-sol low · ~/projects/esota/agmsg-dev · task
# That triplet is required; without it, refuse -- a "›" with no such
# witness right below it is not confirmed to be the live box at all, no
# matter how close to the bottom it sits. The measured placeholder Codex
# shows when nothing has been typed is the literal text "Ask Codex to do
# anything" (not a blank tail) -- empty means the marker line's own tail is
# either that placeholder or genuinely blank; anything else, including a
# continuation line's worth of real text one row below (which the blank-
# line requirement above already catches), is a draft.
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

  local footer_idx=$((marker_idx + 2))
  [ "$footer_idx" -lt "$n" ] || return 1
  case "${lines[$((marker_idx + 1))]}" in *[![:space:]]*) return 1 ;; esac
  case "${lines[$footer_idx]}" in *·*) ;; *) return 1 ;; esac

  local rest
  rest="${lines[$marker_idx]#"$marker"}"
  case "$rest" in ' '*) rest="${rest# }" ;; esac
  case "$rest" in
    '') ;;
    'Ask Codex to do anything') ;;
    *) return 1 ;;
  esac
  return 0
}
