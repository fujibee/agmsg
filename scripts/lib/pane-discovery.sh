#!/usr/bin/env bash
# Finding the pane a hand-started agent is in, for a seat that has no placement
# record (or whose recorded pane is gone). A seat opened by hand -- no spawn, no
# actas -- is recorded only after the agent itself runs an agmsg script once, and
# a type with no SessionStart hook (antigravity's agy) may never do so before the
# first message arrives. The terminal driver can still say which pane holds that
# agent: this asks each driver that can (terminal_enumerate_agent_panes) and
# accepts a pane only when it is unambiguous.
#
#   agmsg_discover_agent_pane <type> <project> <own-record-path>
# prints one line:
#   found<TAB><ref>                       exactly one pane runs the type's CLI in the project
#   none                                  no such pane
#   ambiguous<TAB><ref> <ref> ...         more than one; nothing is chosen
#   unknown<TAB><reason>                  could not tell (a terminal or instance could not be read)
#
# A pane already recorded for another seat is not a candidate. The listing is
# asked for once per census window (AGMSG_PANE_CENSUS_TTL seconds, default 15),
# in a cache file under run/, so several seats checked in one poll share one
# listing; a listing with a hole is never cached.

_agmsg_pane_census() {   # -> rows "<terminal>\t<id>\t<default>\t<agent>\t<cwd>\t<fcwd>" and "!!\t<terminal>" / "!\t<terminal>\t<instance>"
  local cache="${SKILL_DIR:?}/run/pane-census.tsv" ttl="${AGMSG_PANE_CENSUS_TTL:-15}" now mt name out orc rows="" holes=0 was line
  declare -F compat_file_mtime >/dev/null 2>&1 || . "${SCRIPT_DIR:?SCRIPT_DIR is not set}/lib/compat.sh"
  if [ -f "$cache" ]; then
    now="$(date +%s)"; mt="$(compat_file_mtime "$cache" 2>/dev/null || true)"
    case "$mt" in ''|*[!0-9]*) ;; *)
      if [ $((now - mt)) -ge 0 ] && [ $((now - mt)) -lt "$ttl" ]; then cat "$cache"; return 0; fi ;;
    esac
  fi
  was="${_AGMSG_TERMINAL_LOADED:-}"
  for name in $(agmsg_terminal_candidates); do
    agmsg_terminal_load "$name" >/dev/null 2>&1 || continue
    declare -F terminal_enumerate_agent_panes >/dev/null 2>&1 || continue
    if out="$(terminal_enumerate_agent_panes 2>/dev/null)"; then orc=0; else orc=$?; fi
    if [ "$orc" -ne 0 ]; then rows="${rows}"$'!!\t'"$name"$'\n'; holes=1; continue; fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        '!'*) rows="${rows}"$'!\t'"$name"$'\t'"${line#*	}"$'\n'; holes=1 ;;
        *) rows="${rows}${name}"$'\t'"${line}"$'\n' ;;
      esac
    done <<CENSUS_END
$out
CENSUS_END
  done
  if [ -n "$was" ]; then agmsg_terminal_load "$was" >/dev/null 2>&1 || true; fi
  [ "$holes" -eq 0 ] && { mkdir -p "$SKILL_DIR/run" 2>/dev/null; agmsg_write_atomic "$cache" "${rows%$'\n'}" 2>/dev/null || true; }
  printf '%s' "$rows"
}

agmsg_discover_agent_pane() {   # <type> <project> <own-record-path>
  local type="$1" project="$2" own="$3" cli phys census taken="" f ref _p _t
  local term id isdef agent cwd fcwd cref bare matches="" n=0 holes=0 tab
  tab=$'\t'
  [ -n "$type" ] && [ -n "$project" ] || { printf 'none\n'; return 0; }
  cli="$(agmsg_type_get "$type" cli 2>/dev/null)"
  [ -n "$cli" ] || { printf 'unknown\tno_cli_for_type\n'; return 0; }
  phys="$(cd "$project" 2>/dev/null && pwd -P)" || phys=""
  for f in "$SKILL_DIR"/run/spawn.*; do
    [ -f "$f" ] && [ "$f" != "$own" ] || continue
    IFS="$tab" read -r ref _p _t < "$f" || true
    [ -n "$ref" ] && taken="${taken}"$'\n'"${ref}"
  done
  taken="${taken}"$'\n'
  census="$(_agmsg_pane_census)" || census=""
  while IFS="$tab" read -r term id isdef agent cwd fcwd; do
    [ -n "$term" ] || continue
    case "$term" in '!'*) holes=1; continue ;; esac
    [ "$agent" = "$cli" ] || continue
    case "$cwd" in "$project"|"${phys:-/nonexistent-}") ;; *)
      case "$fcwd" in "$project"|"${phys:-/nonexistent-}") ;; *) continue ;; esac ;;
    esac
    cref="$(agmsg_terminal_ref "$term" "$id")"
    case "$taken" in *$'\n'"$cref"$'\n'*) continue ;; esac
    if [ "$isdef" = 1 ]; then
      bare="${term}:${id#"${id%:*:*}":}"
      case "$taken" in *$'\n'"$bare"$'\n'*) continue ;; esac
    fi
    matches="${matches:+$matches }$cref"
    n=$((n + 1))
  done <<CENSUS_END
$census
CENSUS_END
  if [ "$n" -gt 1 ]; then printf 'ambiguous\t%s\n' "$matches"; return 0; fi
  if [ "$holes" -eq 1 ]; then printf 'unknown\tpane_listing_incomplete\n'; return 0; fi
  if [ "$n" -eq 1 ]; then printf 'found\t%s\n' "$matches"; return 0; fi
  printf 'none\n'
}
