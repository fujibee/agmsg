#!/usr/bin/env bash
# input-box.sh — read a pane's input box content, for comparing it against
# itself a moment later (poke.sh's "is someone typing right now" check).
#
# poke.sh types into a live pane and submits it. Before this existed, herdr's
# `agent prompt` (poke's own submission mechanism) had no way to know the
# caller was about to type over a person's own half-typed draft, and rearm.sh
# poking every seat at once did exactly that to a live pane once.
#
# This used to try to recognize "empty" by CONTENT (a marker line with
# nothing after it). That broke on two shapes that are not a person's draft
# at all, but were read as one: Claude Code's own candidate/suggestion text
# left sitting in the box, and Codex's "Ask Codex to do anything" placeholder
# — both real, non-blank characters in the box that a content-pattern check
# has no way to tell apart from someone's actual half-typed message (#1322).
# Blocking on EITHER of those, not just a real draft, made poke refuse
# almost every idle seat once 1.4.0 shipped.
#
# The maintainer's call: what this guard must protect against is someone
# ACTIVELY TYPING, not stale or system-drawn text sitting in the box. That is
# a question about CHANGE OVER TIME, not content — so this file's job
# shrank to "hand back a comparable snapshot of the box", and poke.sh takes
# two of them, ~1s apart (see poke.sh's own comment for why ~1s), and only
# refuses when they differ. Content-blind on purpose: a snapshot function
# never has to know what "empty" looks like for a given CLI, only where its
# input box IS -- the recognizing-the-box part (marker, boxed structure) is
# unavoidably type-specific and stays below; JUDGING what's in it no longer
# is.
#
# Recognizing WHERE the box is remains a TYPE-specific question — each CLI's
# TUI draws its own prompt differently — so that recognition RULE lives as
# manifest data on that type (input_prompt_marker, input_prompt_boxed in
# type.conf), never as per-type code: manifests are read-only key=value data
# and are never sourced (the types-axis contract), so a type cannot ship its
# own check function. What lives here is the one shared INTERPRETATION of
# that data, common to every type that opts in by setting
# input_prompt_marker.
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

# Strip Braille Patterns (U+2800–U+28FF) from <text>, each replaced with a
# single space (never deleted outright — deleting would shift everything
# after it, so two reads that differ only in WHERE a decoration glyph
# happened to land would then also differ in ordinary text position, and
# still compare unequal). Trailing whitespace is trimmed afterward; interior
# and leading spacing is left alone, since that IS meaningful content for a
# real draft.
#
# WHY THIS EXISTS: measured live (2026-09-21) on a Codex pane (`advisor`)
# stuck refusing poke — its input box was genuinely empty (Codex's own "Ask
# Codex to do anything" placeholder), but Codex draws a decorative animation
# of Braille dots moving across that placeholder on every redraw. Two reads
# of the SAME, untouched, empty box a second apart came back byte-different
# every time because of it — exactly the failure this guard exists to avoid
# ("changed" forever, poke permanently refused, worse than 1.3.1 which typed
# blind). Claude Code's boxed input has no such decoration; stripping this
# block is a no-op there (measured: no Braille codepoints appear in a
# Claude Code read at all).
#
# ONE rule, applied to every type unconditionally — not a per-type branch.
# A branch here would need a maintained table of which type needs which
# treatment, and a new terminal or CLI runtime added later would silently
# fall outside it. Braille removal costs nothing for a type that never
# produces any (the loop just never matches).
#
# Implemented via `LC_ALL=C sed` matching the exact UTF-8 byte pattern for
# this block (0xE2 0xA0-0xA3 0x80-0xBF), not bash's `${s:i:1}`/Unicode glob
# ranges: those depend on the CALLER's locale being a UTF-8 one to slice
# multibyte characters correctly (measured: under `LC_ALL=C`, the ambient
# locale poke.sh cannot control, `${#s}`/`${s:i:1}` count and slice BYTES,
# silently corrupting every multibyte character in the line, not just the
# Braille ones). Forcing `LC_ALL=C` on the `sed` invocation itself sidesteps
# the ambient locale entirely — this compares raw bytes, so it behaves the
# same regardless of what locale poke.sh happens to run under.
#
# ACCEPTED RESIDUAL RISK: if a person's real, in-progress draft consisted
# ENTIRELY of Braille Patterns characters, this strips it down to blank
# spaces, and two reads of a genuinely-changing Braille-only draft could
# still compare equal. Judged not to happen in practice — no observed
# workflow types Braille directly into an agmsg member's input box — and
# accepted rather than narrowing the strip further (which would risk missing
# some other decoration Codex or a future CLI draws the same way).
_agmsg_strip_decorative_braille() {
  local text="$1" stripped
  stripped="$(LC_ALL=C sed -E \
    "s/$(printf '\xe2')[$(printf '\xa0')-$(printf '\xa3')][$(printf '\x80')-$(printf '\xbf')]/ /g" \
    <<<"$text")"
  printf '%s' "${stripped%"${stripped##*[![:space:]]}"}"
}

# agmsg_input_box_snapshot <marker> <boxed:yes|""> <screen_text>
# Echoes a normalized snapshot of <screen_text>'s input box on success (rc
# 0). Returns 1, echoing nothing meaningful, when <screen_text> does not
# carry enough structure to confirm where the box even is — the caller
# (poke.sh) treats that exactly like "changed" (refuse), the same
# fail-toward-refusing bias the old content check used for "cannot tell".
#
# Deliberately says nothing about whether the box is empty, a draft, a
# suggestion, or a placeholder — poke.sh calls this twice, ~1s apart, and
# refuses only if the two snapshots differ. See poke.sh's own comment for
# why that replaced a content judgment (#1322).
agmsg_input_box_snapshot() {
  local marker="$1" boxed="$2" screen="$3" raw
  [ -n "$marker" ] || return 1
  if [ "$boxed" = yes ]; then
    raw="$(_agmsg_input_box_raw_boxed "$marker" "$screen")" || return 1
  else
    raw="$(_agmsg_input_box_raw_flat "$marker" "$screen")" || return 1
  fi
  _agmsg_strip_decorative_braille "$raw"
}

# Boxed style (Claude Code): the input sits between the LAST two lines whose
# content starts with a run of 20+ "─" — the top rule also carries the
# pane's own label after its run, the bottom rule is unbroken. Echoes every
# line strictly between that pair (the box's full content, marker line
# included, multi-line drafts and all) verbatim, one per output line.
_agmsg_input_box_raw_boxed() {
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

  local marker_seen=0
  i=$((top + 1))
  while [ "$i" -lt "$bottom" ]; do
    case "${lines[$i]}" in "$marker"*) marker_seen=1 ;; esac
    printf '%s\n' "${lines[$i]}"
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
# That triplet is required to confirm this is the LIVE box at all; without
# it, refuse. Echoes the marker line's own raw content (single line) once
# confirmed — including Codex's own decorative Braille animation over it,
# which the caller strips (see _agmsg_strip_decorative_braille above).
_agmsg_input_box_raw_flat() {
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
  # Braille-stripped before the blank check: Codex's own decorative
  # animation (see _agmsg_strip_decorative_braille above) was measured
  # (2026-09-21, live) drawing across this line too, not just the marker
  # line -- an un-stripped check here would fail to confirm the live widget
  # at all on a genuinely-idle Codex pane, refusing every poke to it exactly
  # like the bug this file exists to fix.
  case "$(_agmsg_strip_decorative_braille "${lines[$((marker_idx + 1))]}")" in
    *[![:space:]]*) return 1 ;;
  esac
  case "${lines[$footer_idx]}" in *·*) ;; *) return 1 ;; esac

  printf '%s\n' "${lines[$marker_idx]}"
  return 0
}
