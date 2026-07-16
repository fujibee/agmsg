#!/usr/bin/env bash
# resolve-project.sh — resolve an agent SESSION's real project root from a
# possibly-misleading invocation pwd. See #92.
#
# Background: agmsg slash commands pass "$(pwd)" as the project key. When the
# user cd's into a subdirectory (or a git worktree) of the project the agent
# session actually lives in, that pwd no longer matches the registered project,
# so lookups silently miss and phantom registrations get created under a fresh
# alias tied to the subdir.
#
# Two complementary signals recover the real root, NEITHER needing a stable
# session_id (Codex slash commands don't expose one — docs/actas.md):
#
#   1. A per-process marker written at SessionStart, keyed by the enclosing
#      agent process PID:  run/proj.<agent_pid>.project = <real root>
#      Works for claude-code and codex alike — both have a process we can walk
#      to via the ppid chain, and a slash command runs as a child of it.
#   2. Ancestor walk: the nearest ancestor of pwd that is a registered project
#      for this type. Git-independent (handles worktrees, non-git trees), and
#      covers Codex / non-hook invocations where no marker was written.
#
# Resolution order: marker -> ancestor -> pwd. The pwd fallback is unchanged
# behavior, so direct shell invocations and genuinely-unrelated directories
# keep working as before. Set AGMSG_RESOLVE_PROJECT=0 to force the raw pwd:
# used by spawn.sh, which passes an explicit, not-yet-registered --project that
# must never be rewritten to the spawning session's own project.
#
# Required caller-set variable: SKILL_DIR — agmsg skill root.

: "${SKILL_DIR:?resolve-project.sh requires SKILL_DIR}"

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"

# agmsg_registered_projects() below reads team configs via readfile() and needs
# agmsg_sql_readfile_path(). Not every caller that sources resolve-project.sh
# also sources storage.sh (e.g. actas-claim.sh), so pull it in here. Re-sourcing
# where the caller already has it just redefines the helpers — harmless.
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/storage.sh"

_agmsg_run_dir() { printf '%s/run' "$SKILL_DIR"; }

# Canonicalize a directory path by resolving symlinks to its physical location.
# Portable on purpose: `cd && pwd -P` works on macOS bash 3.2 (no GNU realpath)
# and Linux alike. Falls back to the input unchanged when the path doesn't
# exist or isn't a directory, so non-existent inputs still compare as their
# literal value. The `cd` runs in a command-substitution subshell, so the
# caller's working directory is never affected. See #160.
agmsg_canonical_path() {
  local p="$1" phys
  [ -n "$p" ] || { printf '%s' "$p"; return 0; }
  if phys=$(cd -- "$p" 2>/dev/null && pwd -P); then
    printf '%s' "$phys"
  else
    printf '%s' "$p"
  fi
}

# Normalize only path spelling, not filesystem identity. Windows paths use the
# mixed form used by Git for Windows (`C:/path`); POSIX paths keep their form
# except for redundant trailing slashes.
#
# Trade-off: the reinterpretation is form-based, not platform-gated, so a POSIX
# path whose first component is a single letter (`/c/foo`) is treated as an
# MSYS drive form. Lookups stay correct either way — the variant set generated
# below always includes the original spelling — but such paths are rare enough
# on POSIX hosts that we prefer the simpler, platform-independent rule.
agmsg_normalize_project_path() {
  local p="$1" drive rest squeezed
  [ -n "$p" ] || { printf '%s' "$p"; return 0; }
  p="${p//\\//}"

  # Collapse repeated slashes (C://x, /c//x) while preserving a UNC-style
  # leading double slash.
  squeezed=$(printf '%s' "$p" | tr -s '/')
  case "$p" in
    //*) p="/$squeezed" ;;
    *)   p="$squeezed" ;;
  esac

  case "$p" in
    /[A-Za-z])
      drive=$(printf '%s' "${p#/}" | tr '[:lower:]' '[:upper:]')
      printf '%s:/' "$drive"
      return 0
      ;;
    /[A-Za-z]/*)
      drive=$(printf '%s' "${p:1:1}" | tr '[:lower:]' '[:upper:]')
      rest="${p:2}"
      p="$drive:$rest"
      ;;
    [A-Za-z]:)
      drive=$(printf '%s' "${p:0:1}" | tr '[:lower:]' '[:upper:]')
      printf '%s:/' "$drive"
      return 0
      ;;
    [A-Za-z]:/*)
      drive=$(printf '%s' "${p:0:1}" | tr '[:lower:]' '[:upper:]')
      p="$drive:${p:2}"
      ;;
  esac

  case "$p" in
    [A-Za-z]:/)
      printf '%s' "$p"
      return 0
      ;;
    */)
      while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do
        p="${p%/}"
      done
      case "$p" in [A-Za-z]:) p="$p/" ;; esac
      ;;
  esac
  printf '%s' "$p"
}

# Print equivalent project path spellings for lookup compatibility with legacy
# registrations. The first line is the canonical comparison form.
agmsg_project_path_variants() {
  local raw="$1"
  local norm="$1" drive lower rest mixed_lower msys_lower msys_upper native_upper native_lower
  local variants=() existing
  norm="$(agmsg_normalize_project_path "$norm")"

  _agmsg_add_project_variant() {
    local candidate="$1" seen
    [ -n "$candidate" ] || return 0
    # ${arr[@]+...} guards the empty-array expansion: under `set -u` bash 3.2
    # (macOS default) treats "${variants[@]}" on an empty array as unbound.
    for seen in ${variants[@]+"${variants[@]}"}; do
      [ "$seen" = "$candidate" ] && return 0
    done
    variants[${#variants[@]}]="$candidate"
  }

  _agmsg_add_project_variant "$norm"
  # The caller's exact spelling always participates — covers exotic forms the
  # normalizer does not model (e.g. native UNC \\server\share).
  _agmsg_add_project_variant "$raw"
  case "$norm" in
    [A-Z]:/*)
      drive="${norm:0:1}"
      lower="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
      rest="${norm:2}"
      mixed_lower="$lower:$rest"
      msys_lower="/$lower$rest"
      msys_upper="/$drive$rest"
      native_upper="$drive:${rest//\//\\}"
      native_lower="$lower:${rest//\//\\}"

      _agmsg_add_project_variant "$mixed_lower"
      _agmsg_add_project_variant "$msys_lower"
      _agmsg_add_project_variant "$msys_upper"
      _agmsg_add_project_variant "$native_upper"
      _agmsg_add_project_variant "$native_lower"
      if [ "$norm" != "$drive:/" ]; then
        _agmsg_add_project_variant "$norm/"
        _agmsg_add_project_variant "$mixed_lower/"
        _agmsg_add_project_variant "$msys_lower/"
        _agmsg_add_project_variant "$msys_upper/"
        _agmsg_add_project_variant "$native_upper\\"
        _agmsg_add_project_variant "$native_lower\\"
      fi
      ;;
    //*)
      # UNC: registrations may be stored with backslashes and/or a trailing
      # separator.
      _agmsg_add_project_variant "${norm//\//\\}"
      _agmsg_add_project_variant "$norm/"
      _agmsg_add_project_variant "${norm//\//\\}\\"
      ;;
    /|[A-Z]:/) : ;;
    /*)
      # Legacy POSIX registrations may carry a trailing slash.
      _agmsg_add_project_variant "$norm/"
      ;;
  esac

  for existing in ${variants[@]+"${variants[@]}"}; do
    printf '%s\n' "$existing"
  done
  unset -f _agmsg_add_project_variant
}

agmsg_project_sql_in_list() {
  local path="$1" candidate escaped out=""
  while IFS= read -r candidate; do
    escaped=$(printf '%s' "$candidate" | sed "s/'/''/g")
    out="${out:+$out,}'$escaped'"
  done < <(agmsg_project_path_variants "$path")
  printf '%s' "$out"
}

agmsg_find_registered_project_variant() {
  local projects="$1" path="$2" candidate match match_norm home_norm
  # #357: never resolve to `/` or $HOME. They are ancestors of nearly every
  # directory, so one stray registration there (even in another team, or a
  # leftover) would capture unrelated sessions -- the ancestor walk climbs
  # through them and would otherwise MATCH them, silently rewriting a project to
  # $HOME. The walk may still ASCEND through these dirs; it just must not land on
  # one. (marker resolution, step 1, is unaffected.)
  #
  # The exclusion compares NORMALIZED paths, so a registration stored with a
  # trailing/duplicate slash ("$HOME/", "//") -- which raw string compare would
  # miss -- is still excluded (agmsg_normalize_project_path collapses/strips
  # those). Normalization is logical, not symlink-resolving; see the PR notes.
  home_norm="$(agmsg_normalize_project_path "${HOME:-}" 2>/dev/null || true)"
  while IFS= read -r candidate; do
    match=$(printf '%s\n' "$projects" | grep -Fx -- "$candidate" | head -n 1 || true)
    if [ -n "$match" ]; then
      match_norm="$(agmsg_normalize_project_path "$match" 2>/dev/null || printf '%s' "$match")"
      case "$match_norm" in "/"|""|[A-Za-z]:|[A-Za-z]:/) continue ;; esac
      { [ -n "$home_norm" ] && [ "$match_norm" = "$home_norm" ]; } && continue
      printf '%s' "$match"
      return 0
    fi
  done < <(agmsg_project_path_variants "$path")
  return 1
}

# Map an agent type to the binary basename(s) its process may carry.
_agmsg_agent_binaries() {
  case "$1" in
    claude-code) echo "claude" ;;
    codex)       echo "codex" ;;
    gemini)      echo "gemini" ;;
    antigravity) echo "antigravity" ;;
    copilot)     echo "copilot" ;;
    opencode)    echo "opencode" ;;
    *)           echo "claude codex gemini" ;;
  esac
}

# Does <pid> currently look like an agent process of <type>? Checks both the
# `comm` name and argv[0] basename. Guards marker trust against PID recycling —
# a recycled pid pointing at an unrelated process must not hijack resolution.
agmsg_pid_is_agent() {
  local pid="$1" type="$2"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  local binaries comm first base bin
  binaries=$(_agmsg_agent_binaries "$type")
  comm=$(compat_get_comm "$pid" 2>/dev/null || true)
  first=$(compat_get_cmdline "$pid" 2>/dev/null | awk '{print $1}' || true)
  base=$(basename -- "${first:-}" 2>/dev/null || true)
  for bin in $binaries; do
    case "$comm" in "$bin"|"$bin"-*) return 0 ;; esac
    [ "$base" = "$bin" ] && return 0
  done
  return 1
}

# Walk the process tree from $$ upward, echoing the PID of the nearest ancestor
# that looks like an agent process of <type>. Empty (return 1) when none is
# found — e.g. a detached watcher or a plain human shell.
#
# Override hook: when AGMSG_AGENT_PID is set, it pins the resolved pid instead
# of walking the tree — a non-empty value is echoed as-is, an empty value forces
# the "no agent ancestor" path (so instance-id derivation falls back to the bare
# session_id). This makes instance-id keying (#93) deterministic for the test
# suite regardless of the ambient process tree, and is a usable escape hatch
# when the ps-walk heuristic misfires for an unusual launch topology.
agmsg_agent_pid() {
  local type="$1"
  if [ -n "${AGMSG_AGENT_PID+set}" ]; then
    case "$AGMSG_AGENT_PID" in
      '')       return 1 ;;  # explicit empty → force the bare-sid fallback
      *[!0-9]*)              # non-numeric → ignore, warn, fall back to bare
        printf 'agmsg: ignoring non-numeric AGMSG_AGENT_PID=%s; using bare session_id\n' "$AGMSG_AGENT_PID" >&2
        return 1 ;;
      *) printf '%s' "$AGMSG_AGENT_PID"; return 0 ;;
    esac
  fi
  local pid="$$" hops=0
  while [ "${pid:-0}" -gt 1 ] && [ "$hops" -lt 20 ]; do
    pid=$(compat_get_ppid "$pid" 2>/dev/null || true)
    [ -z "$pid" ] && return 1
    [ "$pid" = "0" ] && return 1
    if agmsg_pid_is_agent "$pid" "$type"; then
      printf '%s' "$pid"
      return 0
    fi
    hops=$((hops + 1))
  done
  return 1
}

agmsg_project_marker_path() { printf '%s/proj.%s.project' "$(_agmsg_run_dir)" "$1"; }

# Persist <project> as the real root for agent <pid>. Best-effort.
agmsg_write_project_marker() {
  local pid="$1" project="$2" dir
  [ -n "$pid" ] && [ -n "$project" ] || return 1
  dir="$(_agmsg_run_dir)"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s\n' "$project" > "$(agmsg_project_marker_path "$pid")" 2>/dev/null || return 1
}

# Read the marker for <pid>, but only trust it when <pid> is still a live agent
# process of <type>. Empty (return 1) otherwise.
agmsg_read_project_marker() {
  local pid="$1" type="$2" f
  f="$(agmsg_project_marker_path "$pid")"
  [ -f "$f" ] || return 1
  agmsg_pid_is_agent "$pid" "$type" || return 1
  head -1 "$f" 2>/dev/null
}

# Remove markers whose pid is no longer alive. Liveness-only (not argv) so a
# transient ps hiccup can't delete a live agent's marker; a recycled-but-live
# pid is handled by the read-side argv check instead.
agmsg_marker_gc_stale() {
  local dir; dir="$(_agmsg_run_dir)"
  [ -d "$dir" ] || return 0
  local f pid
  for f in "$dir"/proj.*.project; do
    [ -f "$f" ] || continue
    pid=${f##*/proj.}; pid=${pid%.project}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || rm -f "$f"
  done
}

# List distinct registered project paths for <type>, one per line. An optional
# <team> scopes the scan to that team's config only (#357): a poison registration
# in an unrelated team must not leak into this team's resolution. Omitting <team>
# keeps the legacy all-teams scan for callers that don't know the target team
# (whoami/actas/watch) — a deliberate phased migration.
agmsg_registered_projects() {
  local type="$1" team="${2:-}" teams_dir="$SKILL_DIR/teams" config_file cfg_sql type_sql
  [ -d "$teams_dir" ] || return 0
  # Read config.json inside SQL via readfile() rather than binding it through a
  # `.param set` dot-command — the sqlite3 shell tokenizer doesn't honour SQL ''
  # escaping, so a config value with a single quote breaks the bind (#112). The
  # path and type are interpolated as SQL string literals with '' doubling.
  type_sql=$(printf '%s' "$type" | sed "s/'/''/g")
  local -a configs
  if [ -n "$team" ]; then
    configs=("$teams_dir/$team/config.json")
  else
    configs=("$teams_dir"/*/config.json)
  fi
  for config_file in ${configs[@]+"${configs[@]}"}; do
    [ -f "$config_file" ] || continue
    cfg_sql=$(agmsg_sql_readfile_path "$config_file")
    sqlite3 :memory: "
      WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
      cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw),
      agents AS (
        SELECT CASE
          WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
          ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
        END AS registrations
        FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
      )
      SELECT DISTINCT json_extract(r.value, '\$.project')
      FROM agents, json_each(agents.registrations) AS r
      WHERE json_extract(r.value, '\$.type') = '$type_sql';
    " | tr -d '\r'
  done
}

# Echo the main-checkout root of <start>'s git repo, but only when it is a
# registered project for <type>. This recovers a SIBLING git worktree back to
# the registered main checkout — a case the ancestor walk cannot reach because
# the worktree is not nested under the registered path. Validation against the
# registry keeps it from misfiring when registration sits on an umbrella parent
# dir (the git checkout itself is then unregistered, so we decline and let the
# ancestor walk handle it). return 1 when git is absent or nothing matches.
agmsg_gitcommon_project() {
  local start="$1" type="$2" team="${3:-}" common main projects match
  command -v git >/dev/null 2>&1 || return 1
  [ -d "$start" ] || return 1
  common=$(cd "$start" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  # --git-common-dir may be relative to <start>; make it absolute.
  case "$common" in /*) ;; *) common="$start/$common" ;; esac
  main=$(cd "$(dirname "$common")" 2>/dev/null && pwd) || return 1
  projects="$(agmsg_registered_projects "$type" "$team")"
  [ -n "$projects" ] || return 1
  match="$(agmsg_find_registered_project_variant "$projects" "$main")" || return 1
  printf '%s' "$match"
}

# Echo the nearest ancestor of <start> (inclusive) that is a registered project
# for <type>. return 1 when none matches.
agmsg_ancestor_project() {
  local start="$1" type="$2" team="${3:-}" projects d next match
  projects="$(agmsg_registered_projects "$type" "$team")"
  [ -n "$projects" ] || return 1
  d="$(agmsg_normalize_project_path "$start")"
  while [ -n "$d" ] && [ "$d" != "." ]; do
    if match="$(agmsg_find_registered_project_variant "$projects" "$d")"; then
      printf '%s' "$match"
      return 0
    fi
    case "$d" in "/"|[A-Za-z]:|[A-Za-z]:/) break ;; esac
    next=$(dirname "$d")
    [ -z "$next" ] && break
    [ "$next" = "$d" ] && break
    d="$next"
  done
  return 1
}

# Resolve the real project root for a slash-command invocation.
# Usage: agmsg_resolve_project <pwd_path> <type> [team]
# An optional <team> scopes the registry-based fallbacks (ancestor / git-common)
# to that team, so a poison registration in another team can't capture this
# resolution (#357). join.sh passes it (the join target team is known);
# team-agnostic callers (whoami/actas/watch/reset) omit it and keep the legacy
# all-teams behavior.
agmsg_resolve_project() {
  local pwd_path="$1" type="$2" team="${3:-}" pid marker anc gitc
  # Explicit opt-out: caller passed a deliberate, possibly-unregistered path.
  if [ "${AGMSG_RESOLVE_PROJECT:-1}" = "0" ]; then
    printf '%s' "$pwd_path"; return 0
  fi
  # 1) Per-process SessionStart marker (precise). Written only by session-start
  #    (cc monitor/both); codex never installs it, so codex relies on 2)/3).
  if pid="$(agmsg_agent_pid "$type")" && [ -n "$pid" ]; then
    if marker="$(agmsg_read_project_marker "$pid" "$type")" && [ -n "$marker" ]; then
      printf '%s' "$marker"; return 0
    fi
  fi
  # 2) Nearest registered ancestor of pwd (git-independent; covers nested
  #    subdirs and worktrees that live under the registered project).
  if anc="$(agmsg_ancestor_project "$pwd_path" "$type" "$team")" && [ -n "$anc" ]; then
    printf '%s' "$anc"; return 0
  fi
  # 3) Registered main checkout of pwd's git repo (recovers a SIBLING worktree
  #    the ancestor walk cannot reach). Validated against the registry.
  if gitc="$(agmsg_gitcommon_project "$pwd_path" "$type" "$team")" && [ -n "$gitc" ]; then
    printf '%s' "$gitc"; return 0
  fi
  # 4) Unchanged fallback.
  printf '%s' "$pwd_path"
}
