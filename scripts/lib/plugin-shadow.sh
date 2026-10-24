#!/usr/bin/env bash
# An update that adds a built-in driver can land under a name a trusted plugin
# already uses (#1594). The registry lets a trusted plugin replace a built-in of
# the same name, and `agmsg plugin install` asks for --override before it allows
# that -- but a built-in that did not exist at install time was never part of
# that question. install.sh lists the built-ins before it copies the new ones,
# then calls agmsg_plugin_shadow_warn with that list, so the person hears that
# the plugin, not the new built-in, is what runs.
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

# Warn about each trusted plugin driver whose name is a built-in now but was not
# in <before> (the output of agmsg_builtin_driver_names taken before the copy).
agmsg_plugin_shadow_warn() {  # skill-dir before
  local skill="$1" before="$2" trust="$1/db/trusted-plugins" ref path src
  [ -f "$trust" ] || return 0
  while IFS=$'\t' read -r ref path || [ -n "$ref" ]; do
    path="${path%$'\r'}"
    case "$ref" in types/?*|terminals/?*|ext-tools/?*) ;; *) continue ;; esac
    [ -d "$skill/scripts/drivers/$ref" ] || continue
    printf '%s\n' "$before" | grep -qxF -- "$ref" && continue
    [ -d "$path" ] || continue
    echo "  ! this update adds a built-in $ref, but your trusted plugin replaces it:"
    echo "      $path"
    echo "    The plugin keeps running in its place. To use the built-in instead, run"
    src=""
    case "$path" in
      "$skill"/plugins/sources/github/*/*/*)
        src="${path#"$skill"/plugins/sources/github/}"
        src="${src%%/*}/$(printf '%s' "${src#*/}" | cut -d/ -f1)"
        ;;
    esac
    if [ -n "$src" ]; then
      echo "      agmsg plugin remove $src     (or: agmsg plugin untrust $ref)"
    else
      echo "      agmsg plugin untrust $ref"
    fi
  done < "$trust"
  return 0
}
