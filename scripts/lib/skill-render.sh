#!/usr/bin/env bash

# Compose the shared SKILL.md body with an agent-type fragment. The root file
# owns the command ordering and common safety guidance; type templates contain
# only the sections whose behavior is specific to that CLI.

agmsg_render_skill() {
  local agent_type="${1:?agent type required}"
  local skill_name="${2:?skill name required}"
  local output="${3:?output path required}"
  local fragment
  local cmd_prefix

  fragment="$(agmsg_type_template_path "$agent_type")" || return 1
  cmd_prefix="$(agmsg_type_get "$agent_type" cmd_prefix 2>/dev/null || true)"
  cmd_prefix="${cmd_prefix:-/}"

  awk -v fragment="$fragment" \
      -v skill_name="$skill_name" \
      -v agent_type="$agent_type" \
      -v cmd_prefix="$cmd_prefix" '
    function expand(line,    p) {
      while ((p = index(line, "__SKILL_NAME__")) > 0)
        line = substr(line, 1, p - 1) skill_name substr(line, p + 14)
      while ((p = index(line, "__AGENT_TYPE__")) > 0)
        line = substr(line, 1, p - 1) agent_type substr(line, p + 14)
      while ((p = index(line, "__CMD_PREFIX__")) > 0)
        line = substr(line, 1, p - 1) cmd_prefix substr(line, p + 14)
      return line
    }
    FILENAME == fragment {
      if ($0 ~ /^<!-- agmsg:slot [^ ]+ -->$/) {
        name = $0
        sub(/^<!-- agmsg:slot /, "", name)
        sub(/ -->$/, "", name)
        active = name
        slot_count[name] = 0
        next
      }
      if ($0 ~ /^<!-- \/agmsg:slot [^ ]+ -->$/) {
        active = ""
        next
      }
      if (active != "") {
        slot_count[active]++
        slot_line[active, slot_count[active]] = $0
      }
      next
    }
    {
      if ($0 ~ /^<!-- agmsg:slot [^ ]+ -->$/) {
        name = $0
        sub(/^<!-- agmsg:slot /, "", name)
        sub(/ -->$/, "", name)
        active = name
        next
      }
      if ($0 ~ /^<!-- \/agmsg:slot [^ ]+ -->$/) {
        name = active
        if (slot_count[name] > 0) {
          for (i = 1; i <= slot_count[name]; i++)
            print expand(slot_line[name, i])
        } else {
          for (i = 1; i <= default_count[name]; i++)
            print expand(default_line[name, i])
        }
        active = ""
        next
      }
      if (active != "") {
        default_count[active]++
        default_line[active, default_count[active]] = $0
        next
      }
      if (active == "")
        print expand($0)
    }
  ' "$fragment" "$SCRIPT_DIR/SKILL.md" > "$output"
}
