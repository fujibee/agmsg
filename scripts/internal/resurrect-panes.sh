#!/usr/bin/env bash
# resurrect-panes.sh — tmux-resurrect post-restore seat assignment (#339).
#
# Wire it up in tmux.conf as the restore-time hook (NOT @resurrect-processes):
#   set -g @resurrect-hook-post-restore-all '<skill>/scripts/internal/resurrect-panes.sh'
#
# Why a hook and not @resurrect-processes: a verbatim argv re-run is wrong BOTH
# ways. A pane saved with the fresh-boot argv (`claude -n <name> "/agmsg actas
# <name>"`) would re-run as ANOTHER brand-new session; a pane saved with a
# name-based resume argv (`claude --resume <name>`) stalls on the interactive
# picker. So we let resurrect restore panes as plain shells, then this hook
# resolves each role's CURRENT session at restore time and relaunches it via the
# same resume-or-fresh command spawn builds (shared lib/boot-command.sh).
#
# For each restored pane whose saved title or argv carries a role's <team>-<agent>
# name, it looks up the role-session record (type/team/agent/uuid), builds the
# boot command, and send-keys it into that exact pane -- but only if the pane
# came back as a plain shell (never clobber a pane already running a program).
#
# Fail-open throughout: no save file, no records, tmux absent, an unparseable
# line, or a pane running something -> silent skip. Safe to run repeatedly.
#
# The parse + command-construction core is agmsg_resurrect_plan (pure: reads the
# save file + records, emits "<target>\t<command>" lines, touches no tmux), so it
# is unit-testable against a fixture. The live send-keys wrapper runs only when
# this file is executed directly.

set -uo pipefail

_RP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_DIR="${SKILL_DIR:-$(cd "$_RP_SCRIPT_DIR/../.." && pwd)}"
export SKILL_DIR
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/type-registry.sh"
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/role-session.sh"
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/boot-command.sh"

# Locate the newest resurrect save file: the `last` symlink under the XDG path,
# then the legacy ~/.tmux path. AGMSG_RESURRECT_SAVE overrides (used by tests).
agmsg_resurrect_save_file() {
  local f
  for f in "${AGMSG_RESURRECT_SAVE:-}" \
           "${HOME:-}/.local/share/tmux/resurrect/last" \
           "${HOME:-}/.tmux/resurrect/last"; do
    [ -n "$f" ] && [ -e "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# Trim a saved pane_title to its role-name candidate: drop an optional leading
# ':' (some resurrect versions prefix preservable fields) and a leading activity
# glyph + space (tmux may render e.g. "* name"). Returns the trailing token.
_agmsg_rp_title_candidate() {
  local t="${1#:}"
  printf '%s' "${t##* }"
}

# Emit "<tmux-target>\t<boot-command>" for every save-file pane that is a role's
# seat. Pure: no tmux calls, no live-pane check -- the caller decides whether to
# actually seat each target. Reads role-session records from $SKILL_DIR/run.
agmsg_resurrect_plan() {
  local save="$1"
  [ -n "$save" ] && [ -f "$save" ] || return 0

  # Load every role-session record once into parallel arrays. Small N (one per
  # role ever actas'd on this host).
  local run_dir="$SKILL_DIR/run" rec n ty tm ag
  local -a names=() types=() teams=() agents=()
  if [ -d "$run_dir" ]; then
    for rec in "$run_dir"/role-session.*; do
      [ -f "$rec" ] || continue
      n="$(sed -n 's/^name=//p' "$rec" 2>/dev/null | head -1)"
      [ -n "$n" ] || continue
      ty="$(sed -n 's/^type=//p'  "$rec" 2>/dev/null | head -1)"
      tm="$(sed -n 's/^team=//p'  "$rec" 2>/dev/null | head -1)"
      ag="$(sed -n 's/^agent=//p' "$rec" 2>/dev/null | head -1)"
      names+=("$n"); types+=("$ty"); teams+=("$tm"); agents+=("$ag")
    done
  fi
  [ "${#names[@]}" -gt 0 ] || return 0

  # tmux-resurrect pane line (tab-separated), observed layout:
  #   1 marker(pane) 2 session 3 window_index 4 window_active 5 window_flags
  #   6 pane_index 7 pane_title 8 :current_path 9 pane_active
  #   10 pane_current_command 11 :pane_full_command
  local marker session windex wactive wflags pindex ptitle cpath pactive ccmd fullcmd
  local title_cand i rn rty narg idx target proj uuid prompt cli line
  while IFS=$'\t' read -r marker session windex wactive wflags pindex ptitle cpath pactive ccmd fullcmd; do
    [ "$marker" = "pane" ] || continue
    [ -n "$session" ] && [ -n "$windex" ] && [ -n "$pindex" ] || continue
    fullcmd="${fullcmd#:}"
    title_cand="$(_agmsg_rp_title_candidate "$ptitle")"

    # Match this pane to a role by name -- via the saved title, or the `-n <name>`
    # role marker in the saved argv (name_arg from the role's type). Match on the
    # whole name (never split <team>-<agent> on '-').
    idx=-1; i=0
    while [ "$i" -lt "${#names[@]}" ]; do
      rn="${names[$i]}"; rty="${types[$i]}"
      narg="$(agmsg_type_get "$rty" name_arg 2>/dev/null || true)"
      if [ -n "$rn" ] && [ "$title_cand" = "$rn" ]; then
        idx="$i"; break
      fi
      if [ -n "$narg" ] && [ -n "$rn" ]; then
        case " $fullcmd " in
          *" $narg $rn "*) idx="$i"; break ;;
        esac
      fi
      i=$((i + 1))
    done
    [ "$idx" -ge 0 ] || continue

    # Skip a role whose actas lock is held by a LIVE session (mirrors spawn's
    # pre-flight). The role is already seated elsewhere -- its record may have
    # been sown from a still-running session in another process, and resuming its
    # uuid here would double-launch, which the CLI rejects, killing the pane back
    # to a bare shell. "the pane restored as a shell" alone can't catch this; the
    # lock is the source of truth for "is this role's owner alive right now". A
    # dead owner leaves a stale lock -> actas_lock_state reports free -> we reseat.
    lockstate="$(actas_lock_state "${teams[$idx]}" "${agents[$idx]}" '' 2>/dev/null || echo free)"
    case "$lockstate" in other:*) continue ;; esac

    rty="${types[$idx]}"
    cli="$(agmsg_type_get "$rty" cli 2>/dev/null || true)"
    [ -n "$cli" ] || continue
    proj="${cpath#:}"
    uuid="$(agmsg_role_resume_uuid "$rty" "${teams[$idx]}" "${agents[$idx]}" "$proj" 2>/dev/null || true)"
    prompt="$(agmsg_actas_prompt "$rty" "${agents[$idx]}")"
    # Resume head right after the cli (cli-immediately-after convention), then
    # the name/prompt tail -- same order spawn emits.
    line="$cli$(agmsg_role_resume_head "$rty" "$uuid")$(agmsg_role_cli_args "$rty" "${names[$idx]}" "$prompt")"
    target="${session}:${windex}.${pindex}"
    printf '%s\t%s\n' "$target" "$line"
  done < "$save"
  return 0
}

# Is the live pane <target> sitting at a plain shell (safe to seat)?
_agmsg_rp_pane_is_shell() {
  local target="$1" cmd
  cmd="$(tmux display -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)"
  case "${cmd##*/}" in
    ''|bash|zsh|sh|fish|dash|ksh|tcsh|csh|-bash|-zsh|-sh) return 0 ;;
    *) return 1 ;;
  esac
}

# Live entry point: build the plan, then seat each target that restored as a
# plain shell. Fail-open: no tmux -> nothing to do.
agmsg_resurrect_run() {
  command -v tmux >/dev/null 2>&1 || return 0
  local save target cmd
  save="$(agmsg_resurrect_save_file)" || return 0
  while IFS=$'\t' read -r target cmd; do
    [ -n "$target" ] && [ -n "$cmd" ] || continue
    _agmsg_rp_pane_is_shell "$target" || continue
    tmux send-keys -t "$target" "$cmd" Enter 2>/dev/null || true
  done < <(agmsg_resurrect_plan "$save")
  return 0
}

# Run only when executed directly (so tests can source for agmsg_resurrect_plan).
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  agmsg_resurrect_run
fi
