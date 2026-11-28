#!/usr/bin/env bash
# Environment markers: which hosted environments this machine looks like.
# The list is the data file drivers/env-markers.conf (one source); this lib only
# evaluates it. It spawns nothing: every check is a shell builtin.

# The directory of this file, by parameter expansion alone: sourced on every
# remote.sh call, so it must not spawn. (remote.sh is run by path, so the path
# is absolute or resolvable from the cwd.)
_agmsg_env_markers_src="${BASH_SOURCE[0]:-$0}"
case "$_agmsg_env_markers_src" in */*) _AGMSG_ENV_MARKERS_LIB_DIR="${_agmsg_env_markers_src%/*}" ;; *) _AGMSG_ENV_MARKERS_LIB_DIR=. ;; esac
unset _agmsg_env_markers_src

# agmsg_env_markers -> prints the ids of the markers that match, one per line,
# in file order, each at most once. Prints nothing when none match or the file
# is absent. Never prints a path or a value.
agmsg_env_markers() {
  local conf="$_AGMSG_ENV_MARKERS_LIB_DIR/../drivers/env-markers.conf" \
    id check arg extra seen=" "
  [ -r "$conf" ] || return 0
  while IFS=' ' read -r id check arg extra || [ -n "$id" ]; do
    case "$id" in ''|'#'*) continue ;; esac
    [ -z "$extra" ] || continue
    case "$id" in [a-z]*) ;; *) continue ;; esac
    case "$id" in *[!a-z0-9-]*) continue ;; esac
    [ "${#id}" -le 32 ] || continue
    case "$seen" in *" $id "*) continue ;; esac
    case "$check" in
      dir) case "$arg" in /*) [ -d "$arg" ] || continue ;; *) continue ;; esac ;;
      *) continue ;;
    esac
    seen="$seen$id "
    printf '%s\n' "$id"
  done < "$conf"
}
