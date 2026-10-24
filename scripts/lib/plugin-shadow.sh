#!/usr/bin/env bash
# An update that adds a built-in driver can land under a name a trusted plugin
# already uses (#1594). The registry lets a trusted plugin replace a built-in of
# the same name, and `agmsg plugin install` asks for --override before it allows
# that -- but a built-in that did not exist at install time was never part of
# that question. install.sh lists the built-ins before it copies the new ones,
# then calls agmsg_plugin_shadow_warn with that list, so the person hears that
# the plugin, not the new built-in, is what runs.
#
# Which driver runs is the installed registry's answer, not a reading of
# db/trusted-plugins here: the registry also checks the search bases, the exact
# trust row and the manifest, and a second reading of those would drift.
#
# Warn only: nothing is untrusted or removed here, and nothing here may fail the
# install. Sourced by install.sh only.

# Print "<axis>/<name>" for each built-in driver directory under
# <skill-dir>/scripts/drivers, sorted. Prints nothing for a first install.
agmsg_builtin_driver_names() {  # skill-dir
  local root="$1/scripts/drivers" axis d
  for axis in types terminals ext-tools; do
    for d in "$root/$axis"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      printf '%s/%s\n' "$axis" "${d##*/}"
    done
  done | LC_ALL=C sort
}

# Print the directory the installed registry resolves <axis>/<name> to, or
# nothing. A separate bash, so the registry libs never enter install.sh's shell.
_agmsg_plugin_shadow_winner() {  # skill-dir axis name
  local fn
  case "$2" in
    types) fn=agmsg_type_dir ;;
    terminals) fn=agmsg_terminal_dir ;;
    ext-tools) fn=agmsg_ext_tool_dir ;;
    *) return 0 ;;
  esac
  bash -c '. "$1/scripts/lib/driver-registry.sh" || exit 0
    case "$2" in
      agmsg_type_dir) . "$1/scripts/lib/type-registry.sh" || exit 0 ;;
      agmsg_terminal_dir) . "$1/scripts/lib/terminal-registry.sh" || exit 0 ;;
    esac
    "$2" "$3"' _ "$1" "$fn" "$3" 2>/dev/null | head -n 1 || true
}

# Warn about each built-in that is new since <before> (the output of
# agmsg_builtin_driver_names taken before the copy) but that the registry does
# not pick, because a trusted plugin of the same name wins.
agmsg_plugin_shadow_warn() {  # skill-dir before
  local skill before="$2" ref winner src
  # The registry names its root with `cd && pwd`; compare in the same spelling.
  skill="$(cd "$1" 2>/dev/null && pwd)" || return 0
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    printf '%s\n' "$before" | grep -qxF -- "$ref" && continue
    winner="$(_agmsg_plugin_shadow_winner "$skill" "${ref%%/*}" "${ref#*/}")"
    [ -n "$winner" ] || continue
    [ "$winner" != "$skill/scripts/drivers/$ref" ] || continue
    echo "  ! this update adds a built-in $ref, but your trusted plugin replaces it:"
    echo "      $winner"
    echo "    The plugin keeps running in its place. To use the built-in instead, run"
    echo "      agmsg plugin untrust $ref"
    src=""
    case "$winner" in
      "$skill"/plugins/sources/github/*/*/*)
        src="${winner#"$skill"/plugins/sources/github/}"
        src="${src%%/*}/$(printf '%s' "${src#*/}" | cut -d/ -f1)"
        ;;
    esac
    if [ -n "$src" ]; then
      echo "    or remove the whole plugin source (every driver it provides):"
      echo "      agmsg plugin remove $src"
    fi
  done <<EOF
$(agmsg_builtin_driver_names "$skill")
EOF
  return 0
}
