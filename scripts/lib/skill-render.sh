#!/usr/bin/env bash

# Compose the shared SKILL.md body with an agent-type fragment. The root file
# owns the command ordering and common safety guidance; type templates contain
# only the sections whose behavior is specific to that CLI.

agmsg_render_skill() {
  local agent_type="${1:?agent type required}"
  local skill_name="${2:?skill name required}"
  local output="${3:?output path required}"
  local root="${SCRIPT_DIR:-}/SKILL.md"
  local fragment
  local cmd_prefix
  local temp
  local root_marker='<!-- agmsg:render-root -->'
  local overlay_marker='<!-- agmsg:render-overlay'
  local rendered_overlay_marker="<!-- agmsg:render-overlay ${agent_type} -->"

  fragment="$(agmsg_type_template_path "$agent_type")" || return 1
  if [ ! -f "$root" ] || [ ! -r "$root" ] || [ ! -s "$root" ]; then
    echo "agmsg: shared SKILL.md is missing, unreadable, or empty: $root" >&2
    return 1
  fi
  if [ ! -f "$fragment" ] || [ ! -r "$fragment" ] || [ ! -s "$fragment" ]; then
    echo "agmsg: agent-type overlay is missing, unreadable, or empty: $fragment" >&2
    return 1
  fi
  if ! grep -Fq "$root_marker" "$root"; then
    echo "agmsg: shared SKILL.md render marker is missing: $root" >&2
    return 1
  fi
  if ! grep -Fq "$overlay_marker" "$fragment"; then
    echo "agmsg: agent-type overlay render marker is missing: $fragment" >&2
    return 1
  fi
  cmd_prefix="$(agmsg_type_get "$agent_type" cmd_prefix 2>/dev/null || true)"
  cmd_prefix="${cmd_prefix:-/}"

  if ! temp="$(mktemp "${output}.tmp.XXXXXX" 2>/dev/null)"; then
    echo "agmsg: cannot create temporary rendered skill: $output" >&2
    return 1
  fi

  if ! awk -v fragment="$fragment" \
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
  ' "$fragment" "$root" > "$temp"; then
    rm -f "$temp"
    echo "agmsg: skill rendering failed for $agent_type" >&2
    return 1
  fi

  if [ ! -s "$temp" ] || ! grep -Fq "$root_marker" "$temp" || \
     ! grep -Fq "$rendered_overlay_marker" "$temp"; then
    rm -f "$temp"
    echo "agmsg: rendered skill failed composition validation for $agent_type" >&2
    return 1
  fi
  chmod 644 "$temp" || { rm -f "$temp"; return 1; }
  if ! mv -f "$temp" "$output"; then
    rm -f "$temp"
    echo "agmsg: cannot install rendered skill: $output" >&2
    return 1
  fi
}
