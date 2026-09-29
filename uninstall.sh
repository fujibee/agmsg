#!/usr/bin/env bash
set -euo pipefail

# agmsg — Agent Messaging uninstaller
# With no options, removes ONE install's own messaging skill, commands, and
# hooks (#1400: this used to remove every agmsg install found on the
# machine, unconditionally). --all restores that "remove everything" shape,
# but only when explicitly asked for.
#
# Usage:
#   ./uninstall.sh                    # This install only (confirms each step)
#   ./uninstall.sh --yes              # This install only, no confirmation
#   ./uninstall.sh --keep-data        # Remove skill but keep DB and teams
#   ./uninstall.sh --all              # Every agmsg install on the machine
#                                     # (one combined confirmation, unless --yes)

AGENTS_DIR="$HOME/.agents"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGMSG_INSTALL_OP_RECOVERY_SOURCE=""
if [ -e "$SCRIPT_DIR/run/install-op-incomplete.json" ] || [ -L "$SCRIPT_DIR/run/install-op-incomplete.json" ]; then
  if [ -r "$SCRIPT_DIR/run/install-op-recovery.sh" ]; then
    AGMSG_INSTALL_OP_RECOVERY_SOURCE="$SCRIPT_DIR/run/install-op-recovery.sh"
  else
    for _agmsg_recovery_candidate in "$SCRIPT_DIR"/run/.install-op-recovery-retired.*; do
      [ -r "$_agmsg_recovery_candidate" ] || continue
      AGMSG_INSTALL_OP_RECOVERY_SOURCE="$_agmsg_recovery_candidate"
      break
    done
    unset _agmsg_recovery_candidate
  fi
fi
if [ -n "$AGMSG_INSTALL_OP_RECOVERY_SOURCE" ]; then
  # Prefer the atomically-published recovery code while an operation record
  # exists; scripts/ may be incomplete after an interrupted update.
  # shellcheck disable=SC1090
  . "$AGMSG_INSTALL_OP_RECOVERY_SOURCE"
elif [ -r "$SCRIPT_DIR/scripts/lib/codex-config.sh" ] && [ -r "$SCRIPT_DIR/scripts/lib/install-op-lock.sh" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/scripts/lib/codex-config.sh"
  # The same operation lock install.sh takes (agmsgd beta).
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/scripts/lib/install-op-lock.sh"
else
  AGMSG_INSTALL_OP_RECOVERY_SOURCE="$SCRIPT_DIR/run/install-op-recovery.sh"
  if [ ! -r "$AGMSG_INSTALL_OP_RECOVERY_SOURCE" ]; then
    for _agmsg_recovery_candidate in "$SCRIPT_DIR"/run/.install-op-recovery-retired.*; do
      [ -r "$_agmsg_recovery_candidate" ] || continue
      AGMSG_INSTALL_OP_RECOVERY_SOURCE="$_agmsg_recovery_candidate"
      break
    done
    unset _agmsg_recovery_candidate
  fi
  if [ ! -r "$AGMSG_INSTALL_OP_RECOVERY_SOURCE" ]; then
    echo "  ! uninstall support files are missing; restore the install before continuing" >&2
    exit 1
  fi
  # This fallback remains under run/ while an uninstall is incomplete, so an
  # installed copy can recover after --keep-data removed scripts/.
  # shellcheck disable=SC1090
  . "$AGMSG_INSTALL_OP_RECOVERY_SOURCE"
fi

AUTO_YES=false
KEEP_DATA=false
REMOVE_ALL=false
CMD_NAME=""
RECOVER_ID=""
AGMSG_INSTALL_OP_ACTIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)       AUTO_YES=true;  shift ;;
    --keep-data)    KEEP_DATA=true; shift ;;
    --all)          REMOVE_ALL=true; shift ;;
    --cmd)          CMD_NAME="$2"; shift 2 ;;
    --recover)      RECOVER_ID="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: ./uninstall.sh [options]"
      echo ""
      echo "Options:"
      echo "  --yes, -y       Remove without confirmation"
      echo "  --keep-data     Remove skill but keep DB and team configs"
      echo "  --all           Remove every agmsg install on the machine"
      echo "  --cmd <name>    Select one installation under ~/.agents/skills"
      echo "  --recover <id>  Clear a verified incomplete operation, then continue uninstall"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$RECOVER_ID" ] && { [ -z "$CMD_NAME" ] || [ "$REMOVE_ALL" = true ]; }; then
  echo "  ! --recover requires --cmd <name> and cannot be combined with --all" >&2
  exit 1
fi

echo ""
echo "  agmsg — Uninstall"
echo "  ──────────────────"
echo ""

confirm() {
  if [ "$AUTO_YES" = true ]; then return 0; fi
  printf "  %s (y/n) [n]: " "$1"
  read -r input
  [ "${input:-n}" = "y" ] || [ "${input:-n}" = "Y" ]
}

REMOVED=false

_uninstall_operation_exit() {
  if [ "${AGMSG_INSTALL_OP_ACTIVE:-false}" = true ]; then
    agmsg_install_op_unlock
    AGMSG_INSTALL_OP_ACTIVE=false
  fi
}
trap '_uninstall_operation_exit' EXIT
trap 'agmsg_install_op_handle_signal INT' INT
trap 'agmsg_install_op_handle_signal TERM' TERM

_uninstall_operation_require() {
  if agmsg_install_op_require; then
    return 0
  fi
  agmsg_install_op_unlock
  return 1
}

_uninstall_checked_rm() {
  _uninstall_operation_require || return 1
  if ! agmsg_install_op_run_writer rm "$@"; then
    agmsg_install_op_unlock
    return 1
  fi
  _uninstall_operation_require
}

# Removes this install's own writable_roots entries (SKILL_DIR's db/,
# teams/, run/, ext-tools/) from ONE Codex config.toml, if it exists and
# actually mentions them. Split out of _uninstall_one so it can be applied
# to every path agmsg_codex_config_paths names (#1469), not just the plain
# ~/.codex/config.toml default -- the logic itself is unchanged from before
# that split.
#
# review: the old entry-match pattern ("$SKILL_DIR followed by any
# characters up to the closing quote") had no boundary at all, so it also
# matched a sibling install whose own path this one's is a literal prefix of
# (e.g. SKILL_DIR "agmsg" matching a "agmsg-second" entry too). An entry is
# removed only when it IS exactly SKILL_DIR, or starts with SKILL_DIR
# followed by "/" -- and SKILL_DIR is regex-escaped first (it can contain
# ".", which is otherwise "any character" in the pattern awk builds).
#
# review, round 2: a loose pre-check here (even a boundary-correct one) is
# still a claim about what the file contains, and "do we write, back up,
# and report changed" deserves better than trusting that claim. Transform
# into a candidate file first and compare it against the original; back up
# and replace only when they actually differ. A config that only mentions a
# SIBLING install's own root now never gets touched, backed up, or reported
# "cleaned" at all -- not because the entry check happened to be narrow
# enough, but because nothing about it would actually change.
_uninstall_clean_codex_config() {
  local CODEX_CONFIG="$1" SKILL_DIR="$2"
  [ -f "$CODEX_CONFIG" ] || return 0
  # Remove matching entries from writable_roots (handles multiline arrays)
  awk -v pattern="$SKILL_DIR" '
    function ere_escape(s,    i, c, out, special) {
      special = "\\.[]()*+?{}|^$"
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (index(special, c) > 0) out = out "\\" c
        else out = out c
      }
      return out
    }
    BEGIN { esc = ere_escape(pattern) }
    /writable_roots/ { in_roots=1; buf="" }
    in_roots { buf = buf $0 "\n" }
    in_roots && /\]/ {
      gsub("\"" esc "(/[^\"]*)?\"[, ]*", "", buf)
      # Clean up trailing/leading commas
      gsub(/,[ \t]*\]/, "]", buf)
      gsub(/\[[ \t]*,/, "[", buf)
      gsub(/,[ \t]*,/, ",", buf)
      # Check if empty
      if (buf ~ /writable_roots[^[]*\[\s*\]/) {
        in_roots=0; next
      }
      printf "%s", buf
      in_roots=0; next
    }
    !in_roots { print }
  ' "$CODEX_CONFIG" > "$CODEX_CONFIG.tmp"
  # Remove empty [sandbox_workspace_write] section
  awk '
    /^\[sandbox_workspace_write\]/ {
      header=$0
      if (getline nextline <= 0) next
      if (nextline ~ /^\[/ || nextline == "") { print nextline; next }
      print header
      print nextline
      next
    }
    { print }
  ' "$CODEX_CONFIG.tmp" > "$CODEX_CONFIG.tmp2" && mv "$CODEX_CONFIG.tmp2" "$CODEX_CONFIG.tmp"
  if cmp -s "$CODEX_CONFIG" "$CODEX_CONFIG.tmp"; then
    rm -f "$CODEX_CONFIG.tmp"
  else
    _uninstall_operation_require || return 1
    cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak"
    _uninstall_operation_require || return 1
    mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"
    _uninstall_operation_require || return 1
    echo "  - cleaned Codex writable_roots in $CODEX_CONFIG (backup: $(basename "$CODEX_CONFIG").bak)"
    REMOVED=true
  fi
}

# Removes ONE install's own commands, hooks, skill files, and Codex
# writable_roots entries -- everything except the machine-wide shared
# pieces, which the caller handles once, separately (_uninstall_shared_pieces
# below). Sets the global REMOVED=true on any change.
_uninstall_one() {
  local SKILL_DIR="$1"
  local SKILL_NAME; SKILL_NAME="$(basename "$SKILL_DIR")"

  # Operation lock (agmsgd beta): held for the whole of this function,
  # the same lock install.sh takes for the same
  # SKILL_DIR. A failure here means another install/uninstall/enable/
  # disable is already in progress against this exact install -- refuse
  # rather than race it. No trap releases this on an unexpected abort: the
  # OS drops the file lock the moment this process dies; there is no
  # stale-lock recovery step, so an uninstall
  # that crashes mid-way is the same "held until the holder dies" state a
  # crashed install.sh already leaves.
  if ! agmsg_install_op_lock "$SKILL_DIR/run/install-op.lock.db"; then
    echo "  ! could not take the install operation lock for $SKILL_DIR: ${AGMSG_INSTALL_OP_LOCK_FAILURE_REASON:-unknown lock handshake failure}" >&2
    return 1
  fi
  AGMSG_INSTALL_OP_ACTIVE=true
  _uninstall_operation_require || return 1

  local pending="$SKILL_DIR/run/install-op-incomplete.json"
  local recovery_prefix recovery_entrypoint="$SKILL_DIR/uninstall.sh" running_entrypoint="" operation_mode=remove-data recovery_helper="$SKILL_DIR/run/install-op-recovery.sh" recovery_retired="" uninstaller_retired=""
  if [ "$SCRIPT_DIR" = "$SKILL_DIR" ]; then
    case "$(basename "$0")" in
    .install-op-uninstaller-retired.*) running_entrypoint="$SKILL_DIR/$(basename "$0")" ;;
    esac
  fi
  if [ ! -f "$recovery_entrypoint" ]; then
    if [ -f "$pending" ] && agmsg_install_op_pending_validate "$pending"; then
      local _recovery_entrypoint_candidate="$SKILL_DIR/.install-op-uninstaller-retired.$AGMSG_INSTALL_OP_PENDING_ID"
      [ -f "$_recovery_entrypoint_candidate" ] && recovery_entrypoint="$_recovery_entrypoint_candidate"
      unset _recovery_entrypoint_candidate
    fi
  fi
  [ "$KEEP_DATA" = true ] && operation_mode=keep-data
  recovery_prefix="bash $(printf '%q' "$recovery_entrypoint") --cmd $(printf '%q' "$(basename "$SKILL_DIR")")"
  [ "$KEEP_DATA" = true ] && recovery_prefix="$recovery_prefix --keep-data"
  [ "$AUTO_YES" = true ] && recovery_prefix="$recovery_prefix --yes"
  recovery_prefix="$recovery_prefix --recover"
  if [ -n "$RECOVER_ID" ]; then
    agmsg_install_op_pending_recover "$pending" "$RECOVER_ID" uninstall "$operation_mode" || return 1
    RECOVER_ID=""
  elif [ -e "$pending" ] || [ -L "$pending" ]; then
    agmsg_install_op_pending_refuse "$pending" "$recovery_prefix" uninstall "$operation_mode"
    return 1
  fi
  AGMSG_INSTALL_OP_MARKER="$pending"
  agmsg_install_op_pending_begin "$pending" uninstall "$SKILL_DIR" "" "$operation_mode" || return 1
  uninstaller_retired="$SKILL_DIR/.install-op-uninstaller-retired.$AGMSG_INSTALL_OP_ID"
  if [ -n "$running_entrypoint" ] && [ ! -f "$SKILL_DIR/uninstall.sh" ]; then
    uninstaller_retired="$running_entrypoint"
  fi
  # This install's own path with its trailing slash (review): matching on
  # SKILL_NAME or a bare SKILL_DIR prefix is not a boundary -- "agmsg" is a
  # literal substring of "agmsg-second", and "$SKILL_DIR" (no trailing
  # slash) is a literal PREFIX of "$SKILL_DIR-second", so either one also
  # matches a sibling install's own path/hooks/commands. The trailing "/"
  # is what "agmsg-second"/"$SKILL_DIR-second" can never contain right after
  # this install's own name/path. Rendered content embeds the real absolute
  # path (e.g. hook commands, scripts/delivery.sh), never a "~"-shortened
  # one, so matching the expanded SKILL_DIR is correct here.
  local SKILL_DIR_SLASH="$SKILL_DIR/"

  # --- Remove slash commands and hooks from joined projects ---
  local TEAMS_DIR="$SKILL_DIR/teams"
  if [ -d "$TEAMS_DIR" ]; then
    echo "  Scanning joined projects for commands and hooks..."
    local config
    for config in "$TEAMS_DIR"/*/config.json; do
      [ -f "$config" ] || continue

      # A member's registrations moved into a '$.registrations' array (to
      # support more than one project per agent) some time after this query
      # was written; it kept reading '$.type'/'$.project' straight off the
      # agent, which that array shape never has -- so it matched nothing,
      # ever, against a config.json in the current shape, and this whole
      # project-cleanup pass was silently a no-op. Falls back to reading
      # them straight off the agent for a not-yet-migrated record, the same
      # two-shape handling agmsg_registered_type (resolve-project.sh) uses.
      local projects
      projects=$(sqlite3 -separator '	' :memory: \
        ".param set :json '$(sed "s/'/''/g" "$config")'" \
        "WITH agent AS (
           SELECT CASE
             WHEN json_type(json_extract(value, '$.registrations')) = 'array' THEN json_extract(value, '$.registrations')
             ELSE json_array(json_object('type', json_extract(value, '$.type'), 'project', json_extract(value, '$.project')))
           END AS registrations
           FROM json_each(json_extract(:json, '$.agents'))
         )
         SELECT json_extract(value, '$.project') FROM agent, json_each(agent.registrations)
         WHERE json_extract(value, '$.type') = 'claude-code'
           AND json_extract(value, '$.project') IS NOT NULL;" 2>/dev/null || true)

      local project
      while IFS= read -r project; do
        [ -n "$project" ] || continue

        # Remove command files that reference THIS install's own scripts
        # (review: a bare "mentions any agmsg script name" match, with no
        # install identity in it at all, removed every install's command
        # file from a project more than one had joined -- not just a
        # same-prefix collision).
        if [ -d "$project/.claude/commands" ]; then
          local cmd_file
          for cmd_file in "$project/.claude/commands"/*.md; do
            [ -f "$cmd_file" ] || continue
            if grep -qF "$SKILL_DIR_SLASH" "$cmd_file" 2>/dev/null; then
              local cmd_name; cmd_name=$(basename "$cmd_file" .md)
              _uninstall_checked_rm "$cmd_file" || return 1
              echo "  - removed /$cmd_name command from $project"
              REMOVED=true
            fi
          done
        fi

        # Remove only THIS install's own hook entries from settings files
        # (preserve other hooks, and another install's own -- review).
        local settings_file
        for settings_file in "$project/.claude/settings.json" "$project/.claude/settings.local.json"; do
          if [ -f "$settings_file" ] && grep -qF "$SKILL_DIR_SLASH" "$settings_file" 2>/dev/null; then
            local SETTINGS_ESC UPDATED
            SETTINGS_ESC=$(sed "s/'/''/g" "$settings_file")
            UPDATED=$(sqlite3 :memory: "
              WITH hook_types(ht) AS (VALUES ('Stop'), ('PostToolUse'))
              SELECT COALESCE(
                (SELECT result FROM (
                  SELECT '$SETTINGS_ESC' AS result
                ) WHERE NOT EXISTS (
                  SELECT 1 FROM hook_types, json_each(json_extract('$SETTINGS_ESC', '\$.hooks.' || ht)) AS e,
                    json_each(json_extract(e.value, '\$.hooks')) AS h
                  WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_DIR_SLASH') > 0
                )),
                (SELECT CASE
                  WHEN (SELECT count(*) FROM json_each(json_extract(filtered, '\$.hooks'))
                        WHERE json_array_length(value) > 0 OR json_type(value) != 'array') = 0
                  THEN json_remove(filtered, '\$.hooks')
                  ELSE filtered
                END
                FROM (
                  SELECT json_set(json_set('$SETTINGS_ESC',
                    '\$.hooks.Stop',
                    COALESCE((SELECT json_group_array(json(e.value))
                      FROM json_each(json_extract('$SETTINGS_ESC', '\$.hooks.Stop')) AS e
                      WHERE NOT EXISTS (
                        SELECT 1 FROM json_each(json_extract(e.value, '\$.hooks')) AS h
                        WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_DIR_SLASH') > 0
                      )), json('[]'))),
                    '\$.hooks.PostToolUse',
                    COALESCE((SELECT json_group_array(json(e.value))
                      FROM json_each(json_extract('$SETTINGS_ESC', '\$.hooks.PostToolUse')) AS e
                      WHERE NOT EXISTS (
                        SELECT 1 FROM json_each(json_extract(e.value, '\$.hooks')) AS h
                        WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_DIR_SLASH') > 0
                      )), json('[]'))) AS filtered
                ))
              );
            " 2>/dev/null) || true
            if [ -n "$UPDATED" ] && [ "$UPDATED" != "$SETTINGS_ESC" ]; then
              _uninstall_operation_require || return 1
              echo "$UPDATED" > "$settings_file"
              _uninstall_operation_require || return 1
              echo "  - removed agmsg hook from $settings_file"
              REMOVED=true
            fi
          fi
        done
      done <<< "$projects"

      # --- Copilot CLI project-scoped hook file cleanup ---
      # Same two-shape registrations handling as the claude-code query above.
      local copilot_projects
      copilot_projects=$(sqlite3 -separator '	' :memory: \
        ".param set :json '$(sed "s/'/''/g" "$config")'" \
        "WITH agent AS (
           SELECT CASE
             WHEN json_type(json_extract(value, '$.registrations')) = 'array' THEN json_extract(value, '$.registrations')
             ELSE json_array(json_object('type', json_extract(value, '$.type'), 'project', json_extract(value, '$.project')))
           END AS registrations
           FROM json_each(json_extract(:json, '$.agents'))
         )
         SELECT json_extract(value, '$.project') FROM agent, json_each(agent.registrations)
         WHERE json_extract(value, '$.type') = 'copilot'
           AND json_extract(value, '$.project') IS NOT NULL;" 2>/dev/null || true)

      while IFS= read -r project; do
        [ -n "$project" ] || continue
        local copilot_hook="$project/.github/hooks/agmsg.json"
        if [ -f "$copilot_hook" ] && grep -qF "$SKILL_DIR_SLASH" "$copilot_hook" 2>/dev/null; then
          _uninstall_checked_rm "$copilot_hook" || return 1
          echo "  - removed agmsg Copilot hook from $project"
          REMOVED=true
        fi
      done <<< "$copilot_projects"

      # --- Grok Build CLI project-scoped rule file cleanup ---
      # Same two-shape registrations handling as the claude-code query above.
      # #1469: install.sh's own comment describes this as a hook under
      # ~/.grok/hooks/, but that path is written nowhere in this codebase --
      # scripts/drivers/types/grok-build/type.conf's actual hooks_file is
      # .grok/rules/agmsg.md, project-relative, written by
      # grok-build/_delivery.sh's own agmsg_delivery_apply (turn/monitor
      # mode). That install.sh comment is stale; this cleans the file that
      # is actually written, the same way the Copilot hook above is cleaned.
      local grok_projects
      grok_projects=$(sqlite3 -separator '	' :memory: \
        ".param set :json '$(sed "s/'/''/g" "$config")'" \
        "WITH agent AS (
           SELECT CASE
             WHEN json_type(json_extract(value, '$.registrations')) = 'array' THEN json_extract(value, '$.registrations')
             ELSE json_array(json_object('type', json_extract(value, '$.type'), 'project', json_extract(value, '$.project')))
           END AS registrations
           FROM json_each(json_extract(:json, '$.agents'))
         )
         SELECT json_extract(value, '$.project') FROM agent, json_each(agent.registrations)
         WHERE json_extract(value, '$.type') = 'grok-build'
           AND json_extract(value, '$.project') IS NOT NULL;" 2>/dev/null || true)

      while IFS= read -r project; do
        [ -n "$project" ] || continue
        local grok_rule="$project/.grok/rules/agmsg.md"
        if [ -f "$grok_rule" ] && grep -qF "$SKILL_DIR_SLASH" "$grok_rule" 2>/dev/null; then
          _uninstall_checked_rm "$grok_rule" || return 1
          echo "  - removed agmsg Grok Build rule from $project"
          REMOVED=true
        fi
      done <<< "$grok_projects"
    done
  fi

  # --- Remove Claude Code global command ---
  local CC_CMD="$HOME/.claude/commands/$SKILL_NAME.md"
  if [ -f "$CC_CMD" ]; then
    _uninstall_checked_rm "$CC_CMD" || return 1
    echo "  - removed /$SKILL_NAME from ~/.claude/commands/"
    REMOVED=true
  fi

  # --- Remove Copilot CLI skill ---
  local COPILOT_SKILL="$HOME/.copilot/skills/$SKILL_NAME"
  if [ -d "$COPILOT_SKILL" ]; then
    _uninstall_checked_rm -rf "$COPILOT_SKILL" || return 1
    echo "  - removed /$SKILL_NAME skill from ~/.copilot/skills/"
    REMOVED=true
  fi

  # --- Remove Antigravity skill ---
  local ANTIGRAVITY_SKILL="$HOME/.gemini/config/skills/$SKILL_NAME"
  if [ -d "$ANTIGRAVITY_SKILL" ]; then
    _uninstall_checked_rm -rf "$ANTIGRAVITY_SKILL" || return 1
    echo "  - removed /$SKILL_NAME skill from ~/.gemini/config/skills/"
    REMOVED=true
  fi

  # --- Remove native Windows helpers ---
  local helper
  for helper in "$AGENTS_DIR/$SKILL_NAME.ps1" "$AGENTS_DIR/$SKILL_NAME-run.sh"; do
    if [ -f "$helper" ]; then
      _uninstall_checked_rm "$helper" || return 1
      echo "  - removed $helper"
      REMOVED=true
    fi
  done

  # --- Remove the skill directory ---
  if [ "$KEEP_DATA" = true ]; then
    echo ""
    echo "  Removing $SKILL_NAME skill (keeping DB and teams)..."
    _uninstall_checked_rm -rf "$SKILL_DIR/scripts" "$SKILL_DIR/templates" "$SKILL_DIR/agents" "$SKILL_DIR/.trash" || return 1
    _uninstall_checked_rm -f "$SKILL_DIR/SKILL.md" || return 1
    echo "  - removed scripts, templates, SKILL.md"
    echo "  ~ preserved $SKILL_DIR/db/ and $SKILL_DIR/teams/"
    REMOVED=true
  else
    echo ""
    if confirm "Remove $SKILL_NAME (including DB and teams)?"; then
      # run/install-op.lock.db is NEVER deleted, even here (agmsgd beta):
      # removing a DB a waiter still has open makes a
      # freshly recreated file of the same name a DIFFERENT lock than the
      # one the waiter holds a reference to -- see install-op-lock.sh's own
      # header). Remove every top-level entry EXCEPT run/ by name, then
      # inside run/ remove everything except install-op.lock.db by name --
      # never a single recursive rm -rf "$SKILL_DIR" that cannot make this
      # one exception. rmdir (not rm -rf) on SKILL_DIR itself: it correctly
      # fails and is left in place, since run/install-op.lock.db means it
      # is never truly empty after this.
      local _entry _run_entry
      for _entry in "$SKILL_DIR"/* "$SKILL_DIR"/.[!.]*; do
        [ -e "$_entry" ] || continue
        # Keep the installed recovery entrypoint available until the
        # incomplete-operation record is cleared below.
        case "$(basename "$_entry")" in
        uninstall.sh|.install-op-uninstaller-retired.*) continue ;;
        esac
        if [ "$(basename "$_entry")" = "run" ]; then
          for _run_entry in "$_entry"/*; do
            [ -e "$_run_entry" ] || continue
            case "$(basename "$_run_entry")" in
            install-op.lock.db|install-op-incomplete.json|install-op-recovery.sh|.install-op-recovery-retired.*) continue ;;
            esac
            _uninstall_checked_rm -rf "$_run_entry" || return 1
          done
        else
          _uninstall_checked_rm -rf "$_entry" || return 1
        fi
      done
      unset _entry _run_entry
      _uninstall_operation_require || return 1
      rmdir "$SKILL_DIR" 2>/dev/null || true
      echo "  - removed $SKILL_DIR (kept run/install-op.lock.db and the active operation record)"
      REMOVED=true
    fi
  fi

  # --- Clean up Codex writable_roots (this install's own path only) ---
  # Every config install.sh could have written to (#1469: install.sh writes
  # to both the plain ~/.codex/config.toml default and $CODEX_HOME's own
  # config.toml when CODEX_HOME is set and different -- this used to clean
  # only the first, one canonical list shared with install.sh via
  # agmsg_codex_config_paths, scripts/lib/codex-config.sh).
  local _codex_cfg
  while IFS= read -r _codex_cfg; do
    _uninstall_clean_codex_config "$_codex_cfg" "$SKILL_DIR" || return 1
  done < <(agmsg_codex_config_paths)

  # --- Remove OpenCode, Hermes, and Grok Build skill files ---
  # Each mirrors install.sh's own SKILL_DIR construction and gating
  # (scripts/drivers/types/{opencode,hermes,grok-build}, install.sh) --
  # these three were the ones #1469 found install.sh writes but uninstall.sh
  # never removed. Deletes the exact file this install wrote, by name, then
  # rmdir (never rm -rf): rmdir only succeeds on an EMPTY directory, so
  # anything unexpected sharing that directory is left alone and reported,
  # rather than pulled in by a recursive delete that cannot tell the
  # difference (review).
  local _dedicated_dir_label _dedicated_dir _dedicated_label
  for _dedicated_dir_label in \
    "$HOME/.config/opencode/skills/$SKILL_NAME|OpenCode" \
    "$HOME/.hermes/skills/$SKILL_NAME|Hermes" \
    "$HOME/.grok/skills/$SKILL_NAME|Grok Build"
  do
    _dedicated_dir="${_dedicated_dir_label%%|*}"
    _dedicated_label="${_dedicated_dir_label#*|}"
    if [ -f "$_dedicated_dir/SKILL.md" ]; then
      _uninstall_checked_rm -f "$_dedicated_dir/SKILL.md" || return 1
      if rmdir "$_dedicated_dir" 2>/dev/null; then
        echo "  - removed /$SKILL_NAME $_dedicated_label skill"
      else
        echo "  - removed /$SKILL_NAME $_dedicated_label skill (SKILL.md only; $_dedicated_dir left in place, not empty)"
      fi
      REMOVED=true
    fi
  done
  unset _dedicated_dir_label _dedicated_dir _dedicated_label

  if [ -f "$recovery_helper" ]; then
    recovery_retired="$SKILL_DIR/run/.install-op-recovery-retired.$AGMSG_INSTALL_OP_ID"
    _uninstall_operation_require || return 1
    mv "$recovery_helper" "$recovery_retired" || return 1
    _uninstall_operation_require || return 1
  elif [ -n "$AGMSG_INSTALL_OP_RECOVERY_SOURCE" ] && [ -f "$AGMSG_INSTALL_OP_RECOVERY_SOURCE" ]; then
    recovery_retired="$SKILL_DIR/run/.install-op-recovery-retired.$AGMSG_INSTALL_OP_ID"
    _uninstall_operation_require || return 1
    mv "$AGMSG_INSTALL_OP_RECOVERY_SOURCE" "$recovery_retired" || return 1
    _uninstall_operation_require || return 1
  fi
  if [ "$KEEP_DATA" = false ] && [ -f "$SKILL_DIR/uninstall.sh" ]; then
    _uninstall_operation_require || return 1
    if ! agmsg_install_op_run_writer mv "$SKILL_DIR/uninstall.sh" "$uninstaller_retired"; then
      echo "  ! could not preserve the installed recovery entrypoint: $SKILL_DIR/uninstall.sh" >&2
      return 1
    fi
    _uninstall_operation_require || return 1
  fi
  agmsg_install_op_pending_complete "$AGMSG_INSTALL_OP_MARKER" "$AGMSG_INSTALL_OP_ID" || {
    echo "  ! could not clear the completed-operation record; later changes are blocked pending recovery" >&2
    return 1
  }
  if [ -n "$uninstaller_retired" ] && [ -e "$uninstaller_retired" ]; then
    # Remove only this generation's retired path after the record is cleared;
    # a later install writes uninstall.sh and cannot be removed by this cleanup.
    rm -f "$uninstaller_retired" || {
      echo "  ! uninstall completed but could not remove its retired entrypoint: $uninstaller_retired" >&2
      return 1
    }
  fi
  if [ -n "$recovery_retired" ]; then
    rm -f "$recovery_retired" || {
      echo "  ! uninstall completed but could not remove its temporary recovery helper: $recovery_retired" >&2
      return 1
    }
  fi
  agmsg_install_op_unlock
  AGMSG_INSTALL_OP_ACTIVE=false
  unset AGMSG_INSTALL_OP_ID AGMSG_INSTALL_OP_MARKER
}

# Machine-wide pieces, shared by every install: only safe to remove once NO
# agmsg install remains on the machine to still need them. Sets the global
# REMOVED=true on any change.
_uninstall_shared_pieces() {
  local SQLITE_SHIM="$AGENTS_DIR/bin/sqlite3"
  local REMOVED_SQLITE_SHIM=false
  if [ -f "$SQLITE_SHIM" ] && grep -q "sqlite3 compatibility shim for agmsg" "$SQLITE_SHIM" 2>/dev/null; then
    rm "$SQLITE_SHIM"
    echo "  - removed $SQLITE_SHIM"
    REMOVED=true
    REMOVED_SQLITE_SHIM=true
  fi

  local SQLITE_SHIM_CACHE="$AGENTS_DIR/run/sqlite3-shim.cache"
  if [ "$REMOVED_SQLITE_SHIM" = true ] && [ -f "$SQLITE_SHIM_CACHE" ]; then
    rm "$SQLITE_SHIM_CACHE"
    echo "  - removed $SQLITE_SHIM_CACHE"
    REMOVED=true
  fi

  # A same-named non-agmsg file is left alone -- the owner-comment signature
  # is what confirms this is genuinely an agmsg-written shim, not who wrote
  # it: with no install left, whichever one wrote it no longer matters.
  local ANTIGRAVITY_TUI_SHIM="$AGENTS_DIR/bin/agy-tui"
  if [ -f "$ANTIGRAVITY_TUI_SHIM" ] && grep -q "^# agmsg-shim-owner: " "$ANTIGRAVITY_TUI_SHIM" 2>/dev/null; then
    rm "$ANTIGRAVITY_TUI_SHIM"
    echo "  - removed $ANTIGRAVITY_TUI_SHIM"
    REMOVED=true
  fi
}

# True (0) iff no ~/.agents/skills/*/ carries the .agmsg marker any more.
# Scanned FRESH, after the removal(s) above ran -- never decided from a
# count taken before them (review): a KEEP_DATA run (--keep-data, or "n" to
# the interactive "remove DB and teams too?") never deletes the marker
# file, on purpose, so that install still counts as present, and the
# machine-wide shared pieces below must stay in that case even though this
# run's own OTHER_SKILL_DIRS/ALL_SKILL_DIRS count (taken before removal)
# said otherwise.
_uninstall_none_remain() {
  local d
  for d in "$AGENTS_DIR"/skills/*/; do
    [ -f "${d}.agmsg" ] && return 1
  done
  return 0
}

if [ "$REMOVE_ALL" = true ]; then
  # --- --all: every agmsg install on the machine (#1400 follow-up) ---
  # The pre-fix behavior, restored, but only when explicitly asked for --
  # works the same no matter which install's uninstall.sh (or a repo
  # checkout's ./uninstall.sh) this is run from, since it enumerates every
  # marker unconditionally rather than resolving one.
  ALL_SKILL_DIRS=()
  for d in "$AGENTS_DIR"/skills/*/; do
    d="${d%/}"
    [ -f "$d/.agmsg" ] && ALL_SKILL_DIRS+=("$d")
  done

  if [ ${#ALL_SKILL_DIRS[@]} -eq 0 ]; then
    echo "  Nothing to remove (not installed?)"
    echo ""
    exit 0
  fi

  echo "  Removing ALL installations:"
  for d in "${ALL_SKILL_DIRS[@]}"; do
    echo "    $(basename "$d") → $d"
  done
  echo ""

  if [ "$AUTO_YES" != true ]; then
    if ! confirm "Remove ALL ${#ALL_SKILL_DIRS[@]} installation(s) listed above?"; then
      echo "  Aborted."
      echo ""
      exit 0
    fi
    # A SEPARATE question (review): saying yes to removing every INSTALL is
    # not the same claim as saying yes to erasing every install's DB
    # (message history) and teams too -- the first question never says
    # that, and answering it must not be read as having answered this one.
    # Answered once here, applied to every install below via KEEP_DATA, not
    # re-asked per install. Skipped when --keep-data already said no.
    if [ "$KEEP_DATA" != true ] && ! confirm "Also remove each install's DB (message history) and teams?"; then
      KEEP_DATA=true
    fi
    # Both questions above stand in for the per-install "keep DB and teams?"
    # prompt inside _uninstall_one, which must not ask again, once per
    # install, for what this run already answered.
    AUTO_YES=true
  fi

  for d in "${ALL_SKILL_DIRS[@]}"; do
    echo ""
    echo "  --- $(basename "$d") ---"
    _uninstall_one "$d"
  done

  echo ""
  if _uninstall_none_remain; then
    _uninstall_shared_pieces
  fi

else
  # --- This install only (#1400) ---
  #
  # Earlier this iterated every ~/.agents/skills/*/ carrying an `.agmsg`
  # marker -- every OTHER install on the machine, not just this one -- and
  # removed all of their commands, skills, hooks and writable_roots entries:
  # uninstalling one throwaway install wiped every install on the machine.
  # Deciding which ONE install this run is about, in order:
  #   1. uninstall.sh ships INSIDE each install (copied there by install.sh)
  #      and is normally run from there, so when $0's own directory carries
  #      the marker, that unambiguously IS this run's install.
  #   2. $0 does not identify one (e.g. run from a kept git checkout, the way
  #      this project's own tests do): a single install on the machine is
  #      still unambiguous. More than one refuses rather than guess --
  #      pointing at each one's own uninstall.sh, or --all to remove every
  #      install on the machine at once.
  SELF_SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [ -n "$CMD_NAME" ]; then
    SELF_SKILL_DIR="$AGENTS_DIR/skills/$CMD_NAME"
    if [ ! -d "$SELF_SKILL_DIR" ]; then
      echo "  ! selected installation does not exist: $SELF_SKILL_DIR" >&2
      exit 1
    fi
  elif [ ! -f "$SELF_SKILL_DIR/.agmsg" ]; then
    candidates=()
    for d in "$AGENTS_DIR"/skills/*/; do
      d="${d%/}"
      [ -f "$d/.agmsg" ] && candidates+=("$d")
    done
    case "${#candidates[@]}" in
      0)
        echo "  Nothing to remove (not installed?)"
        echo ""
        exit 0
        ;;
      1) SELF_SKILL_DIR="${candidates[0]}" ;;
      *)
        echo "  ! Several agmsg installs found:" >&2
        for d in "${candidates[@]}"; do
          echo "      $d/uninstall.sh" >&2
        done
        echo "  ! Cannot tell which one to uninstall. Run the uninstall.sh inside the one you want to remove, or pass --all to remove them all." >&2
        exit 1
        ;;
    esac
  fi

  # Other installs, purely to decide whether the machine-wide shared pieces
  # are still needed below -- never touched otherwise. Two installs can
  # legitimately coexist (different --cmd names to install.sh), and one
  # going away must not disturb the others.
  OTHER_SKILL_DIRS=()
  for d in "$AGENTS_DIR"/skills/*/; do
    [ -f "${d}.agmsg" ] || continue
    [ "${d%/}" = "$SELF_SKILL_DIR" ] && continue
    OTHER_SKILL_DIRS+=("${d%/}")
  done

  echo "  Removing installation:"
  echo "    $(basename "$SELF_SKILL_DIR") → $SELF_SKILL_DIR"
  if [ ${#OTHER_SKILL_DIRS[@]} -gt 0 ]; then
    echo "  Other installation(s) found, left untouched:"
    for sd in "${OTHER_SKILL_DIRS[@]}"; do
      echo "    $(basename "$sd") → $sd"
    done
  fi
  echo ""

  _uninstall_one "$SELF_SKILL_DIR"

  if _uninstall_none_remain; then
    _uninstall_shared_pieces
  fi
fi

# --- Clean up empty ~/.agents/ ---
if [ -d "$AGENTS_DIR" ]; then
  rmdir "$AGENTS_DIR/bin" 2>/dev/null || true
  rmdir "$AGENTS_DIR/skills" 2>/dev/null || true
  rmdir "$AGENTS_DIR" 2>/dev/null || true
fi

# --- Done ---
echo ""
if [ "$REMOVED" = true ]; then
  echo "  ✓ Uninstall complete"
else
  echo "  Nothing removed."
fi
echo ""
