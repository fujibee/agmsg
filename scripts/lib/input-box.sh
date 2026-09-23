#!/usr/bin/env bash
# input-box.sh — locate a pane's input box and tell a real, stalled draft
# apart from decorative or placeholder text, for poke.sh's "is it safe to
# type here" check.
#
# poke.sh types into a live pane and submits it. Before any of this existed,
# herdr's `agent prompt` (poke's own submission mechanism) had no way to know
# the caller was about to type over a person's own half-typed draft, and
# rearm.sh poking every seat at once did exactly that to a live pane once.
#
# This has gone through two designs already (#1321, #1322) and this is the
# third:
#   1. (#1321) Judge by CONTENT: a marker line with anything after it is a
#      draft, refuse. Broke on Claude Code's own candidate/suggestion text
#      and Codex's "Ask Codex to do anything" placeholder — both non-blank,
#      so content alone can't tell them from a real draft — and poke refused
#      almost every idle seat once 1.4.0 shipped.
#   2. (#1322 round 1) Judge by CHANGE: take two snapshots ~1s apart, refuse
#      only if they differ. Content-blind, so it correctly let candidate
#      text and placeholders through — but a REAL, stalled draft (someone
#      typed something and paused) is JUST AS STATIONARY as those, so this
#      let poke type over a real draft too, concatenated with no separator
#      (measured live, 2026-09-22: a maintainer's stalled draft and a poke's
#      own body landed as one submitted message).
#   3. (#1322 round 2, this file) Judge by STYLE, on top of change-detection:
#      Claude Code's candidate text and Codex's placeholder are both drawn
#      DIM (SGR faint, code 2); a person's own typed characters are not
#      (measured live on all three, 2026-09-21/22). herdr's `pane read
#      --format ansi` exposes this; the plain `--format text` read #1322
#      round 1 used discards it entirely. So: read styled, strip Codex's own
#      decorative Braille-block animation FIRST (it is drawn in a plain
#      foreground color, not dim -- left unstripped it reads as "real,
#      non-dim" content and defeats this check exactly the way it defeated
#      round 1's plain-text comparison), then check whether anything VISIBLE
#      remains outside a dim span. Anything does -> a real draft, refuse
#      outright. Nothing does -> round 1's two-snapshot change check decides
#      (kept, unmodified in spirit: it is what catches someone starting to
#      type in the window between reads).
#
# Recognizing WHERE the box is remains a TYPE-specific question — each CLI's
# TUI draws its own prompt differently — so that recognition RULE lives as
# manifest data on that type (input_prompt_marker, input_prompt_boxed in
# type.conf), never as per-type code: manifests are read-only key=value data
# and are never sourced (the types-axis contract), so a type cannot ship its
# own check function. What lives here is the one shared INTERPRETATION of
# that data. Everything past locating the box (dim-or-not, braille-or-not) is
# ONE rule applied to every runtime unconditionally, never a per-type branch.
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

_AGMSG_ESC="$(printf '\033')"
# Sentinels for _agmsg_input_box_is_real_draft's dim-tracking below. Bytes
# 0x01/0x02 (never valid mid-character UTF-8, never printable) so they can
# never collide with real pane content.
_AGMSG_DIM_START="$(printf '\001')"
_AGMSG_DIM_END="$(printf '\002')"
# U+00A0 NO-BREAK SPACE as raw UTF-8 bytes. Claude Code puts one between its
# marker and the box text. Whether `[[:space:]]` matches it depends on the
# caller's locale (measured on CI: under the C/POSIX locale it does not, so a
# box holding only dim candidate text read as a real draft), so the dim walk
# below turns it into an ASCII space first.
_AGMSG_NBSP="$(printf '\302\240')"

# Strip every `ESC[...m` (SGR) sequence from <text> outright (unlike the
# Braille stripper below, which replaces — this one is used only to derive a
# STYLE-BLIND view for locating structural landmarks and for the final
# plain-text comparison key, where exact column alignment no longer matters
# once styling is gone entirely).
_agmsg_strip_ansi_sgr() {
  LC_ALL=C sed -E "s/${_AGMSG_ESC}\[[0-9;]*m//g" <<<"$1"
}

# Strip Braille Patterns (U+2800–U+28FF) from <text>, each replaced with a
# single space (never deleted outright — deleting would shift everything
# after it, so two reads that differ only in WHERE a decoration glyph
# happened to land would then also differ in ordinary text position, and
# still compare unequal). Trailing whitespace is trimmed afterward; interior
# and leading spacing is left alone, since that IS meaningful content for a
# real draft.
#
# WHY THIS EXISTS: measured live (2026-09-21) on a real Codex pane
# stuck refusing poke — its input box was genuinely empty (Codex's own "Ask
# Codex to do anything" placeholder), but Codex draws a decorative animation
# of Braille dots moving across that placeholder, AND across the row a
# structural check needs blank to confirm the live widget (see
# _agmsg_input_box_raw_flat below), on every redraw. Left unstripped, two
# reads of the SAME untouched box never agreed, and (round 2) the dots read
# as real, non-dim content since Codex draws them in a plain foreground
# color, not dim — either way, poke stayed permanently refused. Claude
# Code's boxed input has no such decoration; stripping this block is a no-op
# there (measured: no Braille codepoints appear in a Claude Code read at
# all).
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
# spaces, and it would misread as safe to type over. Judged not to happen in
# practice — no observed workflow types Braille directly into an agmsg
# member's input box — and accepted rather than narrowing the strip further
# (which would risk missing some other decoration Codex or a future CLI
# draws the same way).
_agmsg_strip_decorative_braille() {
  local text="$1" stripped
  stripped="$(LC_ALL=C sed -E \
    "s/$(printf '\xe2')[$(printf '\xa0')-$(printf '\xa3')][$(printf '\x80')-$(printf '\xbf')]/ /g" \
    <<<"$text")"
  printf '%s' "${stripped%"${stripped##*[![:space:]]}"}"
}

# agmsg_input_box_locate <marker> <boxed:yes|""> <ansi_screen>
# Echoes the input box's region, STYLING PRESERVED (raw ANSI escapes intact
# — never for display to a human or a log), on success (rc 0). Returns 1,
# echoing nothing meaningful, when <ansi_screen> does not carry enough
# structure to confirm where the box even is — treated by every caller
# exactly like "this is a real draft" (fail toward refusing, never toward
# typing — unchanged bias from #1321/#1322 round 1).
#
# Locates on a STYLE-STRIPPED derived copy (rule/marker lines can carry
# leading color codes — measured live on Codex — so a literal-prefix match
# against the raw styled line would miss them), then echoes the ORIGINAL,
# styled line(s) at the same positions: stripping never changes line count
# or order (no SGR sequence contains a newline), so the two stay aligned.
agmsg_input_box_locate() {
  local marker="$1" boxed="$2" screen="$3"
  [ -n "$marker" ] || return 1
  if [ "$boxed" = yes ]; then
    _agmsg_input_box_raw_boxed "$marker" "$screen"
  else
    _agmsg_input_box_raw_flat "$marker" "$screen"
  fi
}

# Boxed style (Claude Code): the input sits between the LAST two lines whose
# STYLE-STRIPPED content starts with a run of 20+ "─" — the top rule also
# carries the pane's own label after its run, the bottom rule is unbroken.
# Echoes every line strictly between that pair, styling intact (the box's
# full content, marker line included, multi-line drafts and all).
_agmsg_input_box_raw_boxed() {
  local marker="$1" screen="$2" rule="$_AGMSG_INPUT_BOX_RULE20"
  local -a lines=() plain=()
  local line n=0
  while IFS= read -r line; do
    lines[n]="$line"
    plain[n]="$(_agmsg_strip_ansi_sgr "$line")"
    n=$((n + 1))
  done <<<"$screen"

  local top=-1 bottom=-1 i=0
  while [ "$i" -lt "$n" ]; do
    case "${plain[$i]}" in
      "$rule"*) top="$bottom"; bottom="$i" ;;
    esac
    i=$((i + 1))
  done
  [ "$top" -ge 0 ] || return 1
  [ "$bottom" -gt "$top" ] || return 1

  local marker_seen=0
  i=$((top + 1))
  while [ "$i" -lt "$bottom" ]; do
    case "${plain[$i]}" in "$marker"*) marker_seen=1 ;; esac
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
# That triplet is required to confirm this is the LIVE box at all (located
# on the STYLE-STRIPPED derived copy, same reason as the boxed check above);
# without it, refuse. Echoes the marker line's own raw content (single
# line), styling intact.
_agmsg_input_box_raw_flat() {
  local marker="$1" screen="$2"
  local -a lines=() plain=()
  local line n=0
  while IFS= read -r line; do
    lines[n]="$line"
    plain[n]="$(_agmsg_strip_ansi_sgr "$line")"
    n=$((n + 1))
  done <<<"$screen"
  [ "$n" -gt 0 ] || return 1

  local marker_idx=-1 i=0
  while [ "$i" -lt "$n" ]; do
    case "${plain[$i]}" in
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
  case "$(_agmsg_strip_decorative_braille "${plain[$((marker_idx + 1))]}")" in
    *[![:space:]]*) return 1 ;;
  esac
  case "${plain[$footer_idx]}" in *·*) ;; *) return 1 ;; esac

  printf '%s\n' "${lines[$marker_idx]}"
  return 0
}

# agmsg_input_box_is_real_draft <marker> <ansi_region>
# 0 (true) if <ansi_region> — as returned by agmsg_input_box_locate, styling
# intact — carries any VISIBLE character outside a dim (SGR faint, code 2)
# span once <marker> and Codex's own decorative Braille animation are both
# removed first. 1 (false) otherwise: blank, or everything visible is dim
# (Claude Code's candidate text, Codex's own placeholder — both measured
# dim, live, 2026-09-21/22).
#
# <marker> is removed by SUBSTRING match, not prefix: measured live on
# Codex, the marker glyph itself can sit after leading style codes (bold +
# background), so it is not always the first thing in the line.
#
# Dim tracking: SGR code 2 (exact `ESC[2m`) starts a dim span; `ESC[0m`
# (reset) or `ESC[22m` (explicitly un-bold/un-dim) ends one — matched by
# EXACT bracket content, not "does the params list contain token 2/0/22
# anywhere": a compound sequence like `ESC[48;2;65;65;65m` (24-bit
# background color) also contains a bare "2" token as part of an unrelated
# color spec, and a substring/token search would misread it as dim.
# Measured (2026-09-21/22, live, both Claude Code and Codex): every dim
# start/end observed is its OWN separate escape with nothing else in it, so
# an exact match on the whole bracket is correct for real data, not just
# simpler.
#
# Implemented via three `sed` passes reducing the ANSI text to two 1-byte
# sentinels (dim-start/dim-end, chosen from the 0x01/0x02 range — never
# valid mid-character UTF-8, never printable, so they cannot collide with
# real content) plus literal text, then a single bash pass over that walks
# sentinel-delimited chunks via prefix removal — no `${s:i:1}` character
# slicing, so this is immune to the same ambient-locale multibyte trap
# _agmsg_strip_decorative_braille's own comment documents.
agmsg_input_box_is_real_draft() {
  local marker="$1" region="$2" tail nobraille sentinel
  tail="${region/"$marker"/}"
  nobraille="$(_agmsg_strip_decorative_braille "$tail")"
  sentinel="$(LC_ALL=C sed -E \
    -e "s/${_AGMSG_ESC}\[2m/${_AGMSG_DIM_START}/g" \
    -e "s/${_AGMSG_ESC}\[(0|22)?m/${_AGMSG_DIM_END}/g" \
    -e "s/${_AGMSG_ESC}\[[0-9;]*m//g" \
    -e "s/${_AGMSG_NBSP}/ /g" \
    <<<"$nobraille")"

  local s="$sentinel" dim=0 saw_nondim=0 chunk seg_to_start seg_to_end
  while [ -n "$s" ]; do
    case "$s" in
      "$_AGMSG_DIM_START"*) dim=1; s="${s#"$_AGMSG_DIM_START"}" ;;
      "$_AGMSG_DIM_END"*) dim=0; s="${s#"$_AGMSG_DIM_END"}" ;;
      *)
        seg_to_start="${s%%"$_AGMSG_DIM_START"*}"
        seg_to_end="${s%%"$_AGMSG_DIM_END"*}"
        if [ "${#seg_to_start}" -le "${#seg_to_end}" ]; then
          chunk="$seg_to_start"
        else
          chunk="$seg_to_end"
        fi
        s="${s#"$chunk"}"
        if [ "$dim" -eq 0 ]; then
          case "$chunk" in *[![:space:]]*) saw_nondim=1 ;; esac
        fi
        ;;
    esac
  done
  [ "$saw_nondim" -eq 1 ]
}

# agmsg_input_box_normalize <ansi_region>
# Echoes <ansi_region> reduced to a plain-text comparison key: Braille
# stripped, then every SGR escape stripped outright (unlike
# _agmsg_input_box_is_real_draft, exact column alignment no longer matters
# once nothing is being classified by style — only compared for equality
# against a second read), then trailing whitespace trimmed. Used by poke.sh
# for the ~1s two-snapshot "did anything change" check (#1322 round 1),
# which this file keeps: it is what catches someone starting to type in the
# window between reads, which a single style classification cannot.
agmsg_input_box_normalize() {
  local stripped
  stripped="$(_agmsg_strip_ansi_sgr "$(_agmsg_strip_decorative_braille "$1")")"
  printf '%s' "${stripped%"${stripped##*[![:space:]]}"}"
}

# agmsg_input_box_draft_text <marker> <boxed:yes|""> <ansi_region>
# Echoes the PLAIN semantic text of a real draft located by
# agmsg_input_box_locate — ANSI/braille stripped, and the type's own prompt
# decoration removed — so the result is what a caller would need to TYPE
# BACK (via a driver's literal-text send, e.g. herdr's terminal_input_type,
# #1384) to reproduce the draft, not what the screen shows. Never used to
# CLASSIFY a box (agmsg_input_box_is_real_draft, above, does that) — only to
# preserve one that classification already confirmed is real.
#
# Decoration removed, both measured live (2026-09-22, real Claude Code and
# Codex panes, `herdr pane send-text` then `--format text` read back):
#   - the marker itself, plus the ONE separator character each type draws
#     between it and the first line of text — Claude Code's is U+00A0
#     NO-BREAK SPACE (_AGMSG_NBSP above; folded to an ASCII space first, same
#     reason that fold already exists in this file), Codex's is a plain
#     ASCII space. Stripped from the FIRST line only, by prefix.
#   - boxed style only (Claude Code's multi-line drafts): every line AFTER
#     the first carries a fixed 2-space continuation indent, matching the
#     marker's own on-screen width. Stripped by prefix, capped at 2, so a
#     line whose real content happens to start with its own leading spaces
#     keeps whatever is left over 2. Flat style (Codex) never reaches this:
#     agmsg_input_box_locate's flat reader (above) only ever returns the one
#     marker line.
#
# ACCEPTED RESIDUAL RISK: a single logical line long enough to SOFT-wrap
# across more than one screen row (no explicit newline, just terminal
# width) reads back here as several separate lines — nothing in the
# rendered screen distinguishes a wrapped continuation from a newline the
# person actually pressed. Retyping the result would then not reproduce the
# original byte-for-byte. This is why the restore step that uses this
# (#1384) compares before/after and reports the saved file on a mismatch
# instead of trusting the retype — a wrong reconstruction here degrades to
# "here is your draft, please restore it by hand," never to silent loss.
agmsg_input_box_draft_text() {
  local marker="$1" boxed="$2" region="$3"
  local plain
  plain="$(_agmsg_strip_ansi_sgr "$(_agmsg_strip_decorative_braille "$region")")"
  plain="${plain//"$_AGMSG_NBSP"/ }"

  local -a lines=()
  local line n=0
  while IFS= read -r line; do
    lines[n]="$line"
    n=$((n + 1))
  done <<<"$plain"
  [ "$n" -gt 0 ] || return 0

  local first="${lines[0]#"$marker"}"
  first="${first# }"
  printf '%s' "$first"

  local i=1 cont
  while [ "$i" -lt "$n" ]; do
    cont="${lines[$i]}"
    if [ "$boxed" = yes ]; then
      case "$cont" in '  '*) cont="${cont#  }" ;; esac
    fi
    printf '\n%s' "$cont"
    i=$((i + 1))
  done
}
