#!/usr/bin/env bash
# shellcheck disable=SC1091

# Renders where.sh's machine-readable key=value line into a single
# human-readable sentence, for injection into an agent's own session context.
#
# Kept as a separate rendering layer rather than a where.sh flag: where.sh's
# key=value contract is already tested (test_where.bats) and consumed
# programmatically elsewhere; a human-facing wording change here must never
# have to touch that contract or its tests.
#
# The failure mode this exists to avoid is silence: an agent that cannot learn
# its own terminal driver falls back to guessing from env vars and grep (the
# #1171-class incident this line is meant to prevent), and a where.sh call
# whose failure produces no output at session start is indistinguishable from
# a where.sh call that was never made. So a where.sh failure renders as a
# visible failure sentence, never as an empty line or no line at all.
#
# Usage: agmsg_terminal_context_line <session_id_or_empty> <skill_dir>
# Always prints exactly one line to stdout and returns 0 — a where.sh failure
# is content, not a call failure, so a caller can always fold this straight
# into its own output without an extra branch.
agmsg_terminal_context_line() {
  local sid="$1" skill_dir="$2" out rc=0

  out="$("$skill_dir/scripts/where.sh" "$sid" 2>/dev/null)" || rc=$?

  # Plain shell parameter expansion throughout, deliberately — not sed/grep
  # regex. `\b` word-boundary matching is a GNU extension; BSD sed (macOS's
  # `/bin/sed`, the same tool this project already routes around elsewhere on
  # this platform) silently treats it as a literal `b` and matches nothing, so
  # a `\bterminal=` pattern extracted an empty string on macOS in testing
  # while working on Linux CI — the exact "found it on one platform, shipped
  # broken on the other" shape this project's own sed patterns avoid
  # elsewhere. `${var#*key=}` / `${var%% *}` are POSIX shell, need no regex
  # engine, and cannot have this split.
  case "$out" in
    resolved=false*)
      local reason="${out#*reason=}"
      printf 'AGMSG terminal: could not be determined (%s)\n' "${reason:-where.sh failed with no reason}"
      return 0
      ;;
  esac

  # `terminal=` and `capabilities=` are present on every resolved=true line
  # (both branches of where.sh); capabilities is always the LAST field, so
  # stripping everything up to its own key takes the rest of the line rather
  # than stopping at the first space — multi-word capability lists (e.g.
  # "spawn despawn peek poke") are the norm, not the exception.
  local terminal capabilities pane_desc notes rest
  rest="${out#*terminal=}"; terminal="${rest%% *}"
  capabilities="${out#*capabilities=}"

  case "$out" in
    *' placement=none '*)
      pane_desc="no addressable pane"
      ;;
    *)
      local placement id
      rest="${out#*placement=}"; placement="${rest%% *}"
      id="${placement#*:}"
      pane_desc="pane $id"
      ;;
  esac

  notes="$skill_dir/scripts/drivers/terminals/$terminal/SKILL.md"
  if [ -n "$terminal" ] && [ -f "$notes" ]; then
    printf 'AGMSG terminal: %s (%s) capabilities=%s; notes: %s\n' \
      "$terminal" "$pane_desc" "${capabilities:-none}" "$notes"
  else
    printf 'AGMSG terminal: %s (%s) capabilities=%s\n' \
      "${terminal:-unknown}" "$pane_desc" "${capabilities:-none}"
  fi
}
