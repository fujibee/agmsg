#!/usr/bin/env bash
set -euo pipefail

# Manage how incoming messages reach this agent.
#
# Usage:
#   delivery.sh set <mode> <type> <project_path>
#   delivery.sh status [<type> <project_path>]
#   delivery.sh stop
#   delivery.sh restart [<project_path> <type>]
#
# `set`'s <project_path> must already exist as a directory (and be one this
# process can enter), must not be empty/whitespace-only, and must not carry a
# carriage return or newline byte anywhere in it -- it is never created
# implicitly, and a malformed value is rejected rather than silently cleaned
# up. Plain leading/trailing spaces or tabs are valid POSIX path characters
# and are accepted as-is. See agmsg_validate_project_path below (#493).
#
# Modes:
#   monitor  — SessionStart hook → Claude Code Monitor tool → watch.sh stream
#   turn     — Stop hook → check-inbox.sh between turns (legacy)
#   both     — monitor primary; turn as per-session safety net
#   off      — no automatic delivery
#
# settings.json injection is idempotent: each `set` call first strips any
# existing agmsg-owned SessionStart/Stop entries, then re-adds whichever
# the new mode requires. Re-running with the same mode is a no-op.
#
# For in-session activation, several actions print a final
# "AGMSG-DIRECTIVE:" line that a running Claude Code agent reads from the
# command output and acts on (invoke Monitor, TaskStop the watcher). This
# closes the gap where, without the directive, only the *next* session
# would pick up the mode change.

ACTION="${1:?Usage: delivery.sh set|status|restart ...}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_NAME="$(basename "$SKILL_DIR")"
RUN_DIR="$SKILL_DIR/run"
# instance-id derivation (#93) for the in-session monitor directive below.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/compat.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/instance-id.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/node.sh"
# hash.sh provides agmsg_sha1 — stop_codex_bridge derives the per-project
# app-server record paths (codex-app-server.<hash>.{pid,port,version}) from it.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/hash.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/type-registry.sh"
# storage.sh provides agmsg_sqlite_mem (CR-safe sqlite, #180); hooks-json.sh's
# primitives use it, so source storage first.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/storage.sh"
# JSON/SQLite hook-file primitives (sourced after SKILL_NAME is set above —
# strip/add reference it to detect agmsg-owned entries).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/hooks-json.sh"
# Shared "rule-file" delivery behavior (rulefile_apply), delegated to by the
# rule-file types' _delivery.sh plugs.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/delivery-rulefile.sh"

# Splices a value into a hook command string as its own shell argument. The
# implementation is shared with every other place that prints a runnable
# command; see lib/shquote.sh for why naive `'$var'` is not enough.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/shquote.sh"
_agmsg_shq() { agmsg_shq "$1"; }

# True (0) iff <cli>'s reported version is >= <min>, compared as MAJOR.MINOR.PATCH.
# FAIL-CLOSED: returns non-zero when the cli is not on PATH, `--version` fails, or
# neither the output nor <min> yields a dotted-numeric version — an unknown
# version must not pass, because the caller installs a hook only for a version
# confirmed to accept it (#1003). No env override: a version is READ from the CLI,
# never asserted; tests place a fake `codex` on PATH (both the pass and the fail
# cases), so no operator seam to claim an unmeasured capability is added.
_agmsg_cli_version_ge() {
  local cli="$1" min="$2" raw ver
  [ -n "$cli" ] && [ -n "$min" ] || return 1
  command -v "$cli" >/dev/null 2>&1 || return 1
  raw="$("$cli" --version 2>/dev/null || true)"
  ver="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+' | head -1)"
  [ -n "$ver" ] || return 1
  _agmsg_ver_ge "$ver" "$min"
}

# True (0) iff dotted-numeric $1 >= $2, compared component by component (a missing
# component reads as 0). Patch is significant: the floor is the exact measured
# version, so a same-minor build BELOW it (0.149.0 vs a 0.149.1 floor) is refused.
_agmsg_ver_ge() {
  local a="$1" b="$2" i av bv
  for i in 1 2 3; do
    av=$(printf '%s.0.0.0' "$a" | cut -d. -f"$i")
    bv=$(printf '%s.0.0.0' "$b" | cut -d. -f"$i")
    case "$av" in ''|*[!0-9]*) av=0 ;; esac
    case "$bv" in ''|*[!0-9]*) bv=0 ;; esac
    [ "$av" -gt "$bv" ] && return 0
    [ "$av" -lt "$bv" ] && return 1
  done
  return 0
}

# The per-project delivery hooks file is the type's manifest `hooks_file=`
# (project-relative), not a hardcoded per-type case. The hook FORMAT written into
# it is still type-specific (apply_settings_* below).
resolve_hooks_file() {
  local type="$1"
  local project="$2"
  local rel
  rel="$(agmsg_type_get "$type" hooks_file)"
  if [ -z "$rel" ]; then
    echo "Unknown agent type: $type" >&2
    return 1
  fi
  # hooks_file is project-relative; reject absolute paths or traversal so a
  # manifest can't redirect writes outside the project.
  case "$rel" in
    /*|*..*) echo "Invalid hooks_file for $type: $rel" >&2; return 1 ;;
  esac
  echo "$project/$rel"
}

# Default delivery behavior: JSON event-hooks (SessionStart / SessionEnd / Stop)
# written into the type's hooks_file. Used by claude-code and codex. Rule-file
# types override this by defining agmsg_delivery_apply in scripts/drivers/types/<name>/_delivery.sh.
agmsg_delivery_apply_default() {
  local type="$1"
  local project="$2"
  local mode="$3"

  local hooks_file
  hooks_file=$(resolve_hooks_file "$type" "$project")
  mkdir -p "$(dirname "$hooks_file")"

  # Whether hook entries also need a Windows-native "commandWindows" variant is
  # a per-type manifest fact (hook_windows_wrap=yes). Resolve it here — the layer
  # that knows agent types — and pass a plain flag down to add_event_entry_file,
  # which stays type-agnostic (see hooks-json.sh header).
  local ww
  ww=$(agmsg_type_get "$type" hook_windows_wrap 2>/dev/null || true)

  # Mid-turn delivery (#1003): a type whose manifest carries a posttooluse_output
  # datum also gets a PostToolUse hook running check-inbox between tool calls, not
  # only at Stop. The datum's PRESENCE opts the type in (kept type-agnostic here —
  # no `if type = codex`); its value is the wire shape check-inbox emits.
  #
  # But opt-in is not enough to INSTALL: the entry is meaningless to a CLI that
  # cannot execute PostToolUse, and — the concern that first motivated the gate —
  # an older parser that rejected it at startup/hooks-review would break turn
  # delivery before check-inbox runs. So a second datum, posttooluse_min_cli,
  # gates on the detected CLI version, FAIL-CLOSED: the entry is installed only
  # when the CLI is confirmed at or above it. Older, or a version we cannot read,
  # gets Stop only. (That older-parser concern was later measured — see the next
  # paragraph — so this stays as defense-in-depth, not the sole protection.)
  #
  # What this gate does and does NOT do (#1003 review): it narrows the POPULATION
  # of projects that get the entry WRITTEN to those where a supporting CLI was
  # seen at install time. It does NOT by itself govern how an OLDER CLI handles a
  # persisted entry later — hooks.json outlives this call, and a downgrade or a
  # different codex binary can read the same file without the gate running again.
  # That handling was measured separately: codex 0.116.0 (pre-PostToolUse) reads a
  # PostToolUse-carrying hooks.json and silently ignores the unknown key, no
  # startup/parse error, positive-control confirmed — the Hooks Review screen was
  # not directly reached (inferred harmless). So the gate is defense-in-depth on
  # top of that measurement, not the sole protection against an unknown.
  local pt_output pt_min pt_cli pt_install=0
  pt_output=$(agmsg_type_get "$type" posttooluse_output 2>/dev/null || true)
  if [ -n "$pt_output" ]; then
    pt_min=$(agmsg_type_get "$type" posttooluse_min_cli 2>/dev/null || true)
    pt_cli=$(agmsg_type_get "$type" cli 2>/dev/null || true)
    if [ -z "$pt_min" ]; then
      pt_install=1                              # opted in with no version floor
    elif _agmsg_cli_version_ge "$pt_cli" "$pt_min"; then
      pt_install=1                              # CLI confirmed new enough
    fi
  fi

  # Work on a temp copy so a partially-modified file never replaces the
  # original until the whole chain succeeds.
  local tmp_state
  tmp_state=$(mktemp "${TMPDIR:-/tmp}/agmsg-state.XXXXXX")
  if [ -f "$hooks_file" ]; then
    cp "$hooks_file" "$tmp_state"
  else
    printf '{}' > "$tmp_state"
  fi

  # 1) Strip any prior agmsg ownership from SessionStart, SessionEnd, Stop.
  strip_agmsg_event_file "$tmp_state" "SessionStart"
  strip_agmsg_event_file "$tmp_state" "SessionEnd"
  strip_agmsg_event_file "$tmp_state" "Stop"
  # Always strip PostToolUse too (#1003), so `off`/`monitor`/a mode change removes
  # the mid-turn entry alongside Stop. Unconditional: a type that never installed
  # one has nothing to remove.
  strip_agmsg_event_file "$tmp_state" "PostToolUse"

  # 2) Re-add what this mode wants.
  #
  # Each hook argument is wrapped with _agmsg_shq rather than a plain '...'
  # literal: $project (and, in principle, $type) is attacker-influenceable —
  # e.g. an extracted archive's directory name — and a bare `'$project'`
  # breaks out of its argument boundary as soon as the value itself contains
  # a single quote, letting the rest of the string run as shell syntax on the
  # next SessionStart/SessionEnd/Stop event. The JSON-string escaping
  # add_event_entry_file applies below only keeps the *JSON* well-formed; it
  # says nothing about the shell that later executes the "command" value.
  case "$mode" in
    monitor)
      local ss="$(_agmsg_shq "$SKILL_DIR/scripts/session-start.sh") $(_agmsg_shq "$type") $(_agmsg_shq "$project")"
      local se="$(_agmsg_shq "$SKILL_DIR/scripts/session-end.sh") $(_agmsg_shq "$type") $(_agmsg_shq "$project")"
      add_event_entry_file "$tmp_state" "SessionStart" "$ss" "$ww"
      add_event_entry_file "$tmp_state" "SessionEnd"   "$se" "$ww"
      ;;
    turn)
      local cmd="$(_agmsg_shq "$SKILL_DIR/scripts/check-inbox.sh") $(_agmsg_shq "$type") $(_agmsg_shq "$project")"
      add_event_entry_file "$tmp_state" "Stop" "$cmd" "$ww"
      # Same inbox check, fired after every tool call (#1003). The trailing event
      # arg tells check-inbox.sh which wire shape to emit; matcher is empty (all
      # tools) via add_event_entry_file. The 60s cooldown bounds the cost.
      if [ "$pt_install" = 1 ]; then
        add_event_entry_file "$tmp_state" "PostToolUse" "$cmd $(_agmsg_shq "PostToolUse")" "$ww"
      fi
      ;;
    both)
      local ss="$(_agmsg_shq "$SKILL_DIR/scripts/session-start.sh") $(_agmsg_shq "$type") $(_agmsg_shq "$project")"
      local se="$(_agmsg_shq "$SKILL_DIR/scripts/session-end.sh") $(_agmsg_shq "$type") $(_agmsg_shq "$project")"
      local st="$(_agmsg_shq "$SKILL_DIR/scripts/check-inbox.sh") $(_agmsg_shq "$type") $(_agmsg_shq "$project")"
      add_event_entry_file "$tmp_state" "SessionStart" "$ss" "$ww"
      add_event_entry_file "$tmp_state" "SessionEnd"   "$se" "$ww"
      add_event_entry_file "$tmp_state" "Stop"         "$st" "$ww"
      if [ "$pt_install" = 1 ]; then
        add_event_entry_file "$tmp_state" "PostToolUse" "$st $(_agmsg_shq "PostToolUse")" "$ww"
      fi
      ;;
    off)
      : # already stripped
      ;;
    *)
      rm -f "$tmp_state"
      echo "Unknown mode: $mode (use monitor|turn|both|off)" >&2
      return 1
      ;;
  esac

  # Say when mid-turn delivery was WANTED here but not installed, so a silent
  # absence is not mistaken for "it's on" (#1003; same "silent = can't tell
  # waiting from broken" hazard #1001 names). Only meaningful for turn/both, and
  # only when the type opted in (pt_output) but the version gate said no.
  if [ -n "$pt_output" ] && [ "$pt_install" != 1 ]; then
    case "$mode" in
      turn|both)
        echo "  ~ mid-turn delivery (PostToolUse) not installed: could not confirm the '$pt_cli' CLI is at or above ${pt_min:-?}. Stop-hook delivery is still active."
        ;;
    esac
  fi

  prune_empty_hooks_file "$tmp_state"

  mv "$tmp_state" "$hooks_file"
}

# Default delivery entry points (Template Method). A type's plug
# (scripts/drivers/types/<name>/_delivery.sh) may override any subset of these:
#   agmsg_delivery_apply      — write the hook file for a mode (default: JSON event-hooks)
#   agmsg_delivery_on_enable  — side effects when enabling monitor/both (default: none)
#   agmsg_delivery_on_disable — side effects when turning delivery off  (default: none)
#   agmsg_delivery_stop_directive — in-session watcher-stop directive (default: Claude TaskStop)
#   agmsg_delivery_runtime_status — runtime liveness summary (default: watch.sh pidfiles)
# A plug that wants the default apply can delegate to agmsg_delivery_apply_default.
agmsg_delivery_apply() { agmsg_delivery_apply_default "$@"; }
agmsg_delivery_on_enable() { :; }
# Default 'off' teardown: stop this (project, type)'s watch.sh watchers. A type
# with its own runtime (e.g. codex's bridge) overrides this. Args: <type>
# <project>. Passing the type scopes the kill so disabling one type's delivery
# never tears down another type's watcher in the same project.
agmsg_delivery_on_disable() { kill_all_watchers "$2" "$1" >/dev/null 2>&1 || true; }
# Default in-session stop directive: tell a running Claude Code session to find
# and TaskStop its watcher. Types whose runtime launches the watcher a different
# way (e.g. grok-build's `monitor` tool) override this with their own wording.
agmsg_delivery_stop_directive() { emit_stop_directive; }

# Default delivery status (json-hooks types: claude-code, codex). Derives the mode
# from the settings hooks file's agmsg-owned SessionStart/Stop entries, then prints
# the per-event entry detail. Rule-file types override agmsg_delivery_status.
agmsg_delivery_status_default() {
  local type="$1" project="$2"
  local hf
  hf=$(resolve_hooks_file "$type" "$project")
  local has_ss=0 has_st=0 hf_readable=0
  if [ -f "$hf" ]; then
    local sql_hf
    sql_hf=$(agmsg_sql_readfile_path "$hf")
    # Checked BEFORE trusting has_ss/has_st below: those two queries default
    # to 0 on ANY failure (`2>/dev/null || echo 0`), not only "genuinely zero
    # agmsg entries" -- malformed JSON, a readfile() that can't open the
    # file, or json_extract() choking on the shape all collapse to the same
    # 0 a real, deliberate off produces. Without this check a corrupt
    # settings file would report bare "mode: off", the same silent-deliberate
    # reading #687 is about, just from a different cause than a missing
    # file (review).
    local valid
    valid=$(agmsg_sqlite_mem "SELECT json_valid(readfile('$sql_hf'));" 2>/dev/null || echo "")
    if [ "$valid" = "1" ]; then
      hf_readable=1
      has_ss=$(agmsg_sqlite_mem "
        SELECT EXISTS(
          SELECT 1 FROM json_each(json_extract(readfile('$sql_hf'), '\$.hooks.SessionStart')) AS s,
            json_each(json_extract(s.value, '\$.hooks')) AS h
          WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
        );" 2>/dev/null || echo 0)
      has_st=$(agmsg_sqlite_mem "
        SELECT EXISTS(
          SELECT 1 FROM json_each(json_extract(readfile('$sql_hf'), '\$.hooks.Stop')) AS s,
            json_each(json_extract(s.value, '\$.hooks')) AS h
          WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
        );" 2>/dev/null || echo 0)
    fi
  fi
  # "off" never claims deliberateness (review, 3rd round): apply_default's
  # off path only strips agmsg's own hook entries -- it writes no marker
  # recording that `set off` ran. So a settings file with zero agmsg entries
  # is byte-for-byte identical whether someone ran `set off` or the project
  # simply never had agmsg configured. The CLI cannot tell those apart, so
  # the wording says only what it can observe: hooks are absent, not that
  # absence was chosen. Same reasoning is why `actas`/`drop` must not treat
  # this as safe-to-stay-silent either -- see template.md.
  local mode="off (no agmsg delivery hooks installed for this project)"
  if [ "$has_ss" = "1" ] && [ "$has_st" = "1" ]; then mode="both"
  elif [ "$has_ss" = "1" ]; then mode="monitor"
  elif [ "$has_st" = "1" ]; then mode="turn"
  elif [ ! -f "$hf" ] || [ "$hf_readable" != "1" ]; then
    # A settings file that does not exist and one that could not be read or
    # parsed as JSON both fall through to here with has_ss=has_st=0, but
    # neither means delivery.sh actually confirmed this project's state:
    # missing, most often because the caller passed the wrong path; or
    # unreadable/malformed, a corrupt or hand-edited settings file (#687
    # review round 1). These used to print the bare word "off" -- same as a
    # genuinely no-hooks-installed project -- so a reader (or `actas`,
    # whose own rule is "off means don't start delivery") could not tell
    # "I don't know" from "there's nothing to start". This is what deceived
    # a seat during #684 recovery: `mode: off` and `mode: monitor` were both
    # true, for the same project, because one reader's path resolved and the
    # other's did not. Distinguishing here, in the FIRST line rather than a
    # secondary one, is what #687 asks for -- a reader (or a caller only
    # capturing the first line) sees the difference without reading further.
    # No consumer matches "mode: off" exactly (re-checked for this string,
    # review round 3): the only exact-match consumers key on
    # "monitor"/"both"/"turn", so this string never being exactly "off" is
    # safe.
    if [ ! -f "$hf" ]; then
      if [ -n "$hf" ]; then
        mode="off (unrecognized: no settings file found at $hf -- this project may not be registered)"
      else
        mode="off (unrecognized: could not resolve a settings file for this project/type)"
      fi
    else
      mode="off (unrecognized: settings file at $hf could not be read as valid JSON)"
    fi
  fi
  echo "mode: $mode"

  if [ -f "$hf" ]; then
    local sql_hf count
    sql_hf=$(agmsg_sql_readfile_path "$hf")
    # readfile() rather than interpolating the file contents into argv —
    # for large settings (#95) the latter hits MAX_ARG_STRLEN on Linux.
    count=$(agmsg_sqlite_mem "SELECT json_array_length(json_extract(readfile('$sql_hf'), '\$.hooks.SessionStart'));" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    echo "settings hooks file: $hf"
    echo "  SessionStart entries: $count"
    count=$(agmsg_sqlite_mem "SELECT json_array_length(json_extract(readfile('$sql_hf'), '\$.hooks.SessionEnd'));" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    echo "  SessionEnd entries:   $count"
    count=$(agmsg_sqlite_mem "SELECT json_array_length(json_extract(readfile('$sql_hf'), '\$.hooks.Stop'));" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    echo "  Stop entries:         $count"
    # The mid-turn PostToolUse entry (#1003) sits next to Stop in turn/both for
    # types whose manifest opts in; show its count so an operator can see it.
    count=$(agmsg_sqlite_mem "SELECT json_array_length(json_extract(readfile('$sql_hf'), '\$.hooks.PostToolUse'));" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    echo "  PostToolUse entries:  $count"
  fi
}
agmsg_delivery_status() { agmsg_delivery_status_default "$@"; }

agmsg_delivery_runtime_status_default() {
  if [ -d "$RUN_DIR" ]; then
    local alive=0 dead=0
    for f in "$RUN_DIR"/watch.*.pid; do
      [ -f "$f" ] || continue
      local pid
      pid=$(cat "$f" 2>/dev/null || echo "")
      if [ -n "$pid" ] && _agmsg_pid_alive_local "$pid"; then
        alive=$((alive + 1))
      else
        dead=$((dead + 1))
      fi
    done
    echo "watch processes: $alive alive, $dead stale pidfiles"
  fi
}
agmsg_delivery_runtime_status() { agmsg_delivery_runtime_status_default "$@"; }

# Source the type's delivery plug (if present) so its overrides take effect.
# One type is handled per invocation, so the global overrides never go stale.
agmsg_delivery_load_plug() {
  local tdir
  tdir="$(agmsg_type_dir "$1" 2>/dev/null || true)"
  if [ -n "$tdir" ] && [ -f "$tdir/_delivery.sh" ]; then
    # shellcheck disable=SC1090
    . "$tdir/_delivery.sh"
  fi
}

apply_settings() {
  local type="$1" project="$2" mode="$3"
  agmsg_delivery_load_plug "$type"
  agmsg_delivery_apply "$type" "$project" "$mode"
}

CODEX_MONITOR_DOC_URL="https://github.com/fujibee/agmsg/blob/main/docs/codex-monitor-beta.md"

emit_monitor_directive() {
  local type="$1"
  local project="$2"
  local watch="$SKILL_DIR/scripts/watch.sh"

  # Claude Code exports CLAUDE_CODE_SESSION_ID for every subprocess of the
  # session. Bake it directly into the command so the agent never has to
  # invent a value — that lets SessionEnd find and clean the matching
  # pidfile reliably. Fall back to a generated id when the env var isn't
  # present (older CC, non-CC runtimes).
  local session_id="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -z "$session_id" ]; then
    session_id="agmsg-$(compat_uuidgen | tr 'A-Z' 'a-z')"
  fi

  # Key the watcher on the per-process instance id (#93) so parallel
  # --continue/--resume sessions sharing a session_id stay isolated. Baking the
  # composite into the directive matches SessionStart and makes the pidfile
  # liveness check below see the real watcher (idempotent in watch.sh).
  session_id="$(agmsg_normalize_instance_id "$session_id" "$type")"

  # Skip the directive when this CC session already has a live watcher —
  # invoking Monitor again would just spawn a duplicate and orphan the
  # previous watcher process.
  local pidfile="$RUN_DIR/watch.$session_id.pid"
  if [ -f "$pidfile" ]; then
    local existing
    existing=$(cat "$pidfile" 2>/dev/null || true)
    # _agmsg_pid_alive_local: EPERM-aware, so a sandbox-unsignalable watcher is
    # still alive, so we must not re-emit and spawn a duplicate.
    if [ -n "$existing" ] && _agmsg_pid_alive_local "$existing"; then
      cat <<EOF

A watch.sh is already streaming into this session (pid $existing). No
action needed — the existing watcher is the active one.
EOF
      return 0
    fi
  fi

  # Shell-quote each argv (printf %q) so a paste-and-run host shell keeps paths
  # with spaces or apostrophes intact; a plain '...' wrap breaks on /o'brien/...
  # (#188).
  local watch_command
  watch_command="$(printf '%q %q %q %q' "$watch" "$session_id" "$project" "$type")"
  cat <<EOF

AGMSG-DIRECTIVE: For this running session, invoke the Monitor tool now with:
  command: $watch_command
  description: agmsg inbox stream
  persistent: true

Pass the command above verbatim — the session_id is already filled in.
EOF
}

emit_stop_directive() {
  cat <<'EOF'

AGMSG-DIRECTIVE: If an agmsg watch Monitor task is running in this session,
find it with TaskList (description starts with "agmsg inbox stream") and
stop it with TaskStop. Existing watch.sh processes have already been killed
by this command.
EOF
}

# Stop the Codex monitor bridge(s) for a project and remove their run artifacts,
# then tear down the project's shared app-server record too (it is keyed per
# project, so `off` should not leave it running). Used by `set off codex` (and
# the manual counterpart to the not-yet-wired auto teardown, #149). The global
# shim is left alone (it is cross-project). Echoes how many bridges were killed.
stop_codex_bridge() {
  local project="$1"
  local pairs team name pidfile bpid killed=0
  pairs=$("$SCRIPT_DIR/identities.sh" "$project" codex 2>/dev/null || true)
  if [ -n "$pairs" ]; then
    while IFS=$'\t' read -r team name _rest; do
      [ -n "$team" ] && [ -n "$name" ] || continue
      pidfile="$RUN_DIR/codex-bridge.$team.$name.pid"
      [ -f "$pidfile" ] || continue
      bpid=$(cat "$pidfile" 2>/dev/null || true)
      if [ -n "$bpid" ] && _agmsg_pid_alive "$bpid"; then
        kill "$bpid" 2>/dev/null && killed=$((killed + 1))
      fi
      # .appserver records which app-server URL the bridge was bound to (the
      # launcher's stale-binding guard); drop it with the rest so it cannot
      # mislead a later launcher.
      rm -f "$pidfile" "${pidfile%.pid}.meta" "${pidfile%.pid}.log" "${pidfile%.pid}.appserver"
    done <<EOF
$pairs
EOF
  fi

  # Tear down the project's shared app-server too. It is keyed per project
  # (codex-app-server.<hash>.{pid,port,version}); turning delivery off means no
  # bridge needs it, and leaving it running keeps a stale port the next launch
  # would have to recreate anyway. Only kill the recorded pid when its cmdline
  # confirms it is our app-server (a recycled pid could be unrelated); drop the
  # record either way.
  local project_hash server_pidfile server_pid server_cmd
  project_hash="$(printf '%s' "$project" | agmsg_sha1 2>/dev/null || true)"
  if [ -n "$project_hash" ]; then
    server_pidfile="$RUN_DIR/codex-app-server.$project_hash.pid"
    if [ -f "$server_pidfile" ]; then
      server_pid="$(cat "$server_pidfile" 2>/dev/null || true)"
      if [ -n "$server_pid" ] && _agmsg_pid_alive_local "$server_pid"; then
        server_cmd="$(compat_get_cmdline "$server_pid" 2>/dev/null || true)"
        case "$server_cmd" in
          *codex*app-server*) kill "$server_pid" 2>/dev/null || true ;;
        esac
      fi
      rm -f "$RUN_DIR/codex-app-server.$project_hash.pid" \
            "$RUN_DIR/codex-app-server.$project_hash.port" \
            "$RUN_DIR/codex-app-server.$project_hash.version" \
            "$RUN_DIR/codex-app-server.$project_hash.log"
    fi
  fi

  echo "$killed"
}

# Reject a malformed project_path before any delivery-apply implementation
# gets to build a hooks/rule file path from it and `mkdir -p` the result
# (#493). Every implementation -- agmsg_delivery_apply_default,
# rulefile_apply, and the cursor/copilot/grok-build overrides -- shares this
# file's resolve_hooks_file(), and apply_settings (this function's sole
# caller) is the only place any of them get invoked from, so validating here
# once covers every agent type without touching each apply implementation.
#
# agmsg's primary callers are LLM agents composing this command from a
# SKILL.md, so a literal argument carrying a stray trailing newline (unlike a
# `$(pwd)`-style substitution, which already strips one) is a realistic input,
# not an exotic edge case -- that is exactly the #493 repro, where such a
# value got concatenated verbatim into a hooks_file path and mkdir -p'd into a
# bogus sibling directory nobody asked for.
#
# Policy: reject only the input shapes #493 is actually about, and otherwise
# use the caller's value literally. That is:
#   1. empty, or made up entirely of whitespace (spaces/tabs/CR/LF);
#   2. carrying a CR or LF byte anywhere -- leading, trailing, or embedded
#      (the #493 repro is exactly a trailing LF from adjacent-quote
#      concatenation; a leading or embedded one is just as likely to be the
#      product of a broken command composition, so all three are refused the
#      same way rather than treated as an intentional path byte);
#   3. not already an existing directory; or
#   4. an existing directory this process cannot actually enter.
# A plain leading/trailing space or tab is a valid POSIX path byte -- some
# directories are legitimately named that way -- so it is accepted and used
# as-is, not silently trimmed and not rejected. Rejecting only carries the
# same "loud error naming the exact value, not a silent guess" spirit for the
# shapes above: a caller that built a bad command should see why, not have it
# quietly "corrected" into something that happens to work this one time.
#
# The existence check + traversability probe below mirrors spawn.sh's
# existing --project handling: an unvalidated project_path must never cause a
# directory to be created implicitly.
#
# Echoes the caller's own path spelling back on success (validated, not
# rewritten); prints an error naming the offending value to stderr and returns
# non-zero on failure.
agmsg_validate_project_path() {
  local raw="$1" trimmed="$1"
  while :; do
    case "$trimmed" in
      " "*|$'\t'*|$'\r'*|$'\n'*) trimmed="${trimmed#?}" ;;
      *) break ;;
    esac
  done
  while :; do
    case "$trimmed" in
      *" "|*$'\t'|*$'\r'|*$'\n') trimmed="${trimmed%?}" ;;
      *) break ;;
    esac
  done

  # Emptiness is judged after trimming space/tab/CR/LF from both ends, so a
  # value that is only whitespace (of any of those four bytes) is caught here
  # regardless of which one(s) it's made of.
  if [ -z "$trimmed" ]; then
    echo "delivery.sh: project_path is empty or only whitespace: $(printf '%q' "$raw")" >&2
    return 1
  fi
  case "$raw" in
    *$'\n'*|*$'\r'*)
      # Judged against $raw (not $trimmed), so this catches a CR/LF anywhere
      # in the value -- leading, trailing, or hiding in the middle -- while
      # leaving plain leading/trailing spaces/tabs (already proven non-empty
      # above) untouched.
      echo "delivery.sh: project_path contains a carriage return or newline (leading, trailing, or embedded): $(printf '%q' "$raw")" >&2
      return 1
      ;;
  esac
  if [ ! -d "$raw" ]; then
    echo "delivery.sh: project path does not exist: $(printf '%q' "$raw")" >&2
    echo "  agmsg will not create a project directory implicitly -- pass an existing path (e.g. the output of \"\$(pwd)\")." >&2
    return 1
  fi
  # -d passes for a directory we cannot actually enter, and every apply
  # implementation goes on to write inside it, so prove traversability here
  # rather than failing later with a confusing mkdir error. `--` keeps a real
  # directory named like an option (`-P`, `-L`) from being parsed as one.
  #
  # The status is checked explicitly instead of being folded into a
  # `$(cd ... && pwd)` command substitution: printf returns 0 regardless, so
  # that shape lets a permission failure sail through as a successful
  # validation of an empty path -- a validator that fails open is worse than
  # no validator. CDPATH is cleared inside the subshell: with it set, a
  # RELATIVE project_path can `cd` into a same-named directory somewhere on
  # CDPATH instead of the one `-d` just checked -- an un-enterable local
  # directory would then validate against a different, enterable one.
  if ! ( CDPATH='' cd -- "$raw" ) >/dev/null 2>&1; then
    echo "delivery.sh: project path exists but cannot be entered: $(printf '%q' "$raw")" >&2
    return 1
  fi

  # Echo the caller's own spelling back. Canonicalizing here would be a second,
  # unrequested behavioral change: it rewrites relative paths to absolute and
  # collapses ./.., so anything downstream that compares or persists this value
  # would start seeing a different string than the caller passed. #493 is about
  # refusing malformed input, not about normalizing well-formed input.
  printf '%s' "$raw"
}

do_set() {
  local MODE="${1:?Usage: delivery.sh set <mode> <type> <project_path>}"
  local TYPE="${2:?Missing type}"
  local PROJECT="${3:?Missing project_path}"

  # Zeroth stage: the project path itself must be a real, unambiguous
  # directory before any type-specific logic (which mkdir -p's a path built
  # from it) runs. See agmsg_validate_project_path above (#493).
  PROJECT="$(agmsg_validate_project_path "$PROJECT")" || exit 1

  # Two-stage validation. First: is this even a real mode? The four mode names
  # are engine vocabulary (not type-specific), so a typo is caught here with a
  # generic message before any per-type logic.
  case "$MODE" in monitor|turn|both|off) ;; *)
    echo "Unknown mode: $MODE (use monitor|turn|both|off)" >&2; exit 1 ;;
  esac
  # Second: does THIS type accept the mode? A type declares the modes its CLI
  # accepts via the delivery_modes= manifest key (e.g. codex omits 'both' — the
  # the bridge has no both-mode; rule-file types like opencode omit
  # 'monitor'/'both'). Reject anything not listed, before any file is touched.
  # Types without the key fall back to the full set so an unconfigured manifest
  # still works.
  local SUPPORTED_MODES
  SUPPORTED_MODES=$(agmsg_type_get "$TYPE" delivery_modes 2>/dev/null || true)
  [ -z "$SUPPORTED_MODES" ] && SUPPORTED_MODES="monitor turn both off"
  case " $SUPPORTED_MODES " in
    *" $MODE "*) ;;
    *)
      echo "Error: '$MODE' mode is not supported for $TYPE (supported: $SUPPORTED_MODES)." >&2
      exit 1 ;;
  esac

  apply_settings "$TYPE" "$PROJECT" "$MODE"

  echo "Delivery mode set to '$MODE' for $PROJECT ($TYPE)"

  case "$MODE" in
    monitor|both)
      # Type-specific enable side effects (shim install, watcher directive, …)
      # live in the type's plug as agmsg_delivery_on_enable; default is none.
      agmsg_delivery_on_enable "$MODE" "$TYPE" "$PROJECT"
      ;;
    turn)
      echo "Future sessions: Stop hook will check inbox between turns."
      # Stop only THIS (project, type)'s watcher; other types in this project,
      # and other projects, keep theirs. (Before scoping, this killed every
      # watcher in the project — so any type's `set turn` tore down the
      # project's claude-code monitor, the only type that runs one.)
      kill_all_watchers "$PROJECT" "$TYPE" >/dev/null 2>&1 || true
      agmsg_delivery_stop_directive
      ;;
    off)
      echo "Future sessions: no automatic delivery."
      # Type-specific teardown via the plug (default: stop this project's
      # watchers; codex stops its bridge instead).
      agmsg_delivery_on_disable "$TYPE" "$PROJECT"
      # Only emit the in-session watcher-stop directive for types that actually
      # have an automatic delivery mode to stop. A manual-only type
      # (delivery_modes=off, e.g. hermes) has no Monitor/watcher, so the
      # directive would be noise — and a stray TaskStop could disturb an
      # unrelated agent's watcher. Data-driven, so no per-type branch here.
      case " $SUPPORTED_MODES " in
        *" monitor "*|*" turn "*|*" both "*) agmsg_delivery_stop_directive ;;
      esac
      ;;
  esac
}

do_status() {
  local TYPE="${1:-}"
  local PROJECT="${2:-}"

  # Mode is derived from the project's settings.local.json — there's no
  # global mode value. When called without <type> <project>, we can't infer
  # a project-scoped mode, so we just skip the mode line and report the
  # global watcher state below.
  # Mode + per-type status detail come from the type's delivery plug
  # (agmsg_delivery_status); default is JSON event-hooks, rule-file types override.
  if [ -n "$TYPE" ] && [ -n "$PROJECT" ]; then
    agmsg_delivery_load_plug "$TYPE"
    agmsg_delivery_status "$TYPE" "$PROJECT"
  fi

  agmsg_delivery_runtime_status "$TYPE" "$PROJECT"
}

kill_all_watchers() {
  # With no argument, kills every running watch.sh (used by stop). With a
  # <project> argument — and, when given, a <type> — kills only watchers whose
  # argv matches. watch.sh argv is "watch.sh <session_id> <project> <type>
  # [name]", so <project> <type> are adjacent space-delimited fields. Scoping to
  # (project, type) means switching one (project, type)'s delivery mode never
  # tears down another project's watcher OR another agent type's watcher in the
  # SAME project — which, because claude-code is the only type with a watcher,
  # is exactly the collateral kill that a non-claude `set turn` used to cause.
  local project="${1:-}" type="${2:-}"
  local killed=0
  # The argv substring to scope to: "<project> <type>" when a type is given
  # (exact adjacent fields), else just "<project>", else empty (match all).
  local needle=""
  if [ -n "$project" ]; then
    if [ -n "$type" ]; then needle=" $project $type "; else needle=" $project "; fi
  fi
  if [ -d "$RUN_DIR" ]; then
    for f in "$RUN_DIR"/watch.*.pid; do
      [ -f "$f" ] || continue
      local pid cmd
      pid=$(cat "$f" 2>/dev/null || echo "")
      if [ -n "$pid" ] && _agmsg_pid_alive_local "$pid"; then
        # Defensive: only kill if the pid's command line still looks like
        # our watch.sh. Defends against pid recycling — a stale pidfile
        # could point at an unrelated process that reused the pid.
        cmd=$(compat_get_cmdline "$pid" 2>/dev/null || true)
        if agmsg_cmdline_names_path "$cmd" "$SKILL_DIR/scripts/watch.sh"; then
          # When scoped, skip (and preserve the pidfile of) watchers that don't
          # match this (project, type) — i.e. other projects, and other types
          # in the same project.
          if [ -n "$needle" ]; then
            case " $cmd " in
              *"$needle"*) ;;
              *) continue ;;
            esac
          fi
          kill "$pid" 2>/dev/null && killed=$((killed + 1))
        fi   # otherwise it is not our watcher; leave it
      fi
      rm -f "$f"
    done
  fi
  echo "$killed"
}

do_stop() {
  local killed
  killed=$(kill_all_watchers)
  echo "Killed $killed watch process(es)."
  emit_stop_directive
}

do_restart() {
  local TYPE="${1:-}"
  local PROJECT="${2:-}"
  local killed
  # Restart only the targeted (project, type)'s watcher when args are given; a
  # bare `restart` (no args) still tears down every watcher. Same (project,
  # type) scoping as `set`, so restarting one type's delivery doesn't kill an
  # unrelated project's or type's watcher.
  killed=$(kill_all_watchers "$PROJECT" "$TYPE")
  echo "Killed $killed watch process(es)."
  if [ -n "$TYPE" ] && [ -n "$PROJECT" ]; then
    emit_stop_directive
    emit_monitor_directive "$TYPE" "$PROJECT"
  else
    emit_stop_directive
    cat <<'EOF'

To relaunch in this session, pass <type> <project_path> as arguments:
  delivery.sh restart claude-code /path/to/project
EOF
  fi
}

case "$ACTION" in
  set)     do_set "$@" ;;
  status)  do_status "$@" ;;
  stop)    do_stop "$@" ;;
  restart) do_restart "$@" ;;
  *)       echo "Unknown action: $ACTION (use set|status|stop|restart)" >&2; exit 1 ;;
esac
