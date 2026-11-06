#!/usr/bin/env bash
# state-root.sh — keep an install's runtime state outside its skills directory.
#
# Codex watches every skill root (~/.agents/skills) and tells each connected
# session to re-read all skills whenever anything under it changes. agmsg writes
# run/, db/, teams/ and locks constantly, so a watched skills directory made
# every Codex app-server rescan about every 10 seconds. The state therefore lives
# in <state base>/<install name>/ and the skills directory holds a symlink for
# each part, so every script, hook and the app keeps using the old paths. Writes
# through a symlinked directory are not reported to the watcher.
#
#   agmsg_state_base                     <state base>: $AGMSG_HOME or ~/.agmsg
#   agmsg_state_key <skill dir> <agents dir>    the install's name under the base
#   agmsg_state_root <skill dir> <agents dir>   <state base>/<key>
#   agmsg_state_preflight <skill dir> <state root>   0 = can move; else one line on stderr
#   agmsg_state_link <skill dir> <state root>        move + link (see below); 0 = done
#
# Parts moved: run db teams ext-tools .trash. A part that is already a link to its
# place is left alone; a link to somewhere else is the owner's own arrangement and
# is left alone too (and reported). Nothing is removed that was not first moved.

[ -n "${_AGMSG_HOME_SH:-}" ] && return 0
_AGMSG_HOME_SH=1

AGMSG_STATE_PARTS="run db teams ext-tools .trash"

# Names that cannot be an install: they are shared directories under the base.
AGMSG_STATE_RESERVED="config"
agmsg_state_name_reserved() {   # <install name> -> 0 when it may not be used
  local r
  for r in $AGMSG_STATE_RESERVED; do [ "$1" != "$r" ] || return 0; done
  return 1
}

agmsg_state_base() {
  printf '%s\n' "${AGMSG_HOME:-$HOME/.agmsg}"
}

# One install -> one name. An install under <agents dir>/skills is named by its
# directory (that is the --cmd name); one anywhere else (a copy, a kit's own
# base) gets its directory name plus an 8-hex FNV-1a hash of its absolute path,
# so two different bases never share a name. Shell arithmetic only.
agmsg_state_key() {   # <skill dir> <agents dir>
  local skill="${1%/}" agents="${2%/}" name v i ch n h=2166136261 hex
  name="${skill##*/}"
  if [ "${skill%/*}" = "$agents/skills" ]; then
    printf '%s\n' "$name"
    return 0
  fi
  local LC_ALL=C
  v="$skill"
  for ((i = 0; i < ${#v}; i++)); do
    ch="${v:i:1}"
    printf -v n '%d' "'$ch"
    n=$(( n & 255 ))
    h=$(( ((h ^ n) * 16777619) & 4294967295 ))
  done
  printf -v hex '%08x' "$h"
  printf '%s-%s\n' "$name" "$hex"
}

agmsg_state_root() {   # <skill dir> <agents dir>
  printf '%s/%s\n' "$(agmsg_state_base)" "$(agmsg_state_key "$1" "$2")"
}

# The device a path (or its nearest existing parent) is on.
_agmsg_state_dev() {
  local p="$1"
  while [ ! -e "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do p="${p%/*}"; [ -n "$p" ] || p=/; done
  stat -c %d "$p" 2>/dev/null || stat -f %d "$p" 2>/dev/null
}

# Says why the state cannot be moved, naming the install; changes nothing that
# outlives the call.
AGMSG_STATE_REASON=""
_agmsg_state_refuse() {   # <name> <skill dir> <reason>
  AGMSG_STATE_REASON="$3"
  echo "agmsg: state of '$1' stays in $2: $3" >&2
  return 1
}

agmsg_state_preflight() {   # <skill dir> <state root>
  local skill="${1%/}" root="${2%/}" name part probe owner
  name="${skill##*/}"
  AGMSG_STATE_REASON=""
  if [ ! -d "$skill" ]; then
    _agmsg_state_refuse "$name" "$skill" "the install directory does not exist"; return 1
  fi
  # Windows without symlink rights (Git Bash then copies instead of linking) is
  # caught by the real link test below, not by guessing from the OS name.
  if ! mkdir -p "$root" 2>/dev/null || [ ! -w "$root" ]; then
    _agmsg_state_refuse "$name" "$skill" "cannot create or write $root"; return 1
  fi
  # A directory made here by mktemp, holding one file and a link to it: nothing
  # that already exists is touched, and only what this call made is removed (a
  # Windows ln that copies leaves a plain file in place of the link, so no
  # recursive removal is needed).
  probe="$(mktemp -d "$root/.link-probe.XXXXXX" 2>/dev/null)" || {
    _agmsg_state_refuse "$name" "$skill" "cannot create or write $root"; return 1
  }
  : > "$probe/target"
  if ! ln -s target "$probe/link" 2>/dev/null || [ ! -L "$probe/link" ]; then
    command rm -f "$probe/target" "$probe/link"
    rmdir "$probe" 2>/dev/null
    _agmsg_state_refuse "$name" "$skill" "symbolic links cannot be created in $root"; return 1
  fi
  command rm -f "$probe/target" "$probe/link"
  rmdir "$probe" 2>/dev/null
  if [ "$(_agmsg_state_dev "$skill")" != "$(_agmsg_state_dev "$root")" ]; then
    _agmsg_state_refuse "$name" "$skill" "$root is on another filesystem, so the move would not be a rename"; return 1
  fi
  # A root made for another install is never shared: a copy of an install (cp -R
  # keeps the links) or two bases that fold to the same name end up here.
  if [ -f "$root/.owner" ]; then
    owner="$(<"$root/.owner")"
    if [ -n "$owner" ] && [ "$owner" != "$skill" ] && [ -d "$owner" ]; then
      _agmsg_state_refuse "$name" "$skill" "$root belongs to $owner"
      return 1
    fi
  fi
  for part in $AGMSG_STATE_PARTS; do
    # A part that is a real directory here AND already has content there would be
    # merged blindly; the owner decides which copy is the live one.
    if [ -d "$skill/$part" ] && [ ! -L "$skill/$part" ] && [ -n "$(ls -A "$root/$part" 2>/dev/null)" ]; then
      echo "agmsg: state of '$name' stays in $skill: both $skill/$part and $root/$part hold data" >&2
      return 1
    fi
  done
  return 0
}

# Makes <src> a link to <dest> (already moved there). A running script may make
# <src> again between the move and the link (mkdir -p run); ln -s would then put
# the link INSIDE that directory. So: whatever is in a recreated <src> is folded
# into <dest> first (names that already exist there are not overwritten), a link
# that landed inside is taken out again, and the result is checked to be the link.
_agmsg_state_fold() {   # <src> <dest>
  local f
  ( shopt -s dotglob nullglob; for f in "$1"/*; do mv -n "$f" "$2/" 2>/dev/null; done )
  rmdir "$1" 2>/dev/null
}
_agmsg_state_publish() {   # <src> <dest>
  local src="$1" dest="$2" inner
  if [ -d "$src" ] && [ ! -L "$src" ]; then _agmsg_state_fold "$src" "$dest"; fi
  if [ ! -e "$src" ] && [ ! -L "$src" ]; then ln -s "$dest" "$src" 2>/dev/null; fi
  if [ -d "$src" ] && [ ! -L "$src" ]; then
    inner="$src/${src##*/}"
    if [ -L "$inner" ] && [ "$(readlink "$inner")" = "$dest" ]; then command rm -f "$inner"; fi
    _agmsg_state_fold "$src" "$dest"
    if [ ! -e "$src" ] && [ ! -L "$src" ]; then ln -s "$dest" "$src" 2>/dev/null; fi
  fi
  [ "$(readlink "$src" 2>/dev/null)" = "$dest" ]
}

# Moves each part to the state root and links it back. Safe to re-run at any
# point of an earlier, interrupted run: every step looks at what is there now.
agmsg_state_link() {   # <skill dir> <state root>
  local skill="${1%/}" root="${2%/}" part dest src failed=0 target
  mkdir -p "$root" || return 1
  for part in $AGMSG_STATE_PARTS; do
    src="$skill/$part"; dest="$root/$part"
    if [ -L "$src" ]; then
      target="$(readlink "$src")"
      if [ "$target" != "$dest" ]; then
        echo "agmsg: $src is a link to $target; left as it is" >&2
      fi
      mkdir -p "$dest" 2>/dev/null || true
      continue
    fi
    if [ -e "$src" ] && [ ! -d "$src" ]; then
      echo "agmsg: $src is not a directory; left as it is" >&2
      failed=1
      continue
    fi
    if [ -d "$src" ]; then
      if [ -d "$dest" ] && [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then rmdir "$dest" 2>/dev/null || true; fi
      if ! mv "$src" "$dest" 2>/dev/null; then
        echo "agmsg: could not move $src to $dest" >&2
        failed=1
        continue
      fi
    else
      mkdir -p "$dest" 2>/dev/null || { echo "agmsg: could not create $dest" >&2; failed=1; continue; }
    fi
    if ! _agmsg_state_publish "$src" "$dest"; then
      echo "agmsg: moved $src to $dest but could not link it back (something else made $src and its entries cannot all be moved); fix that, then run: ln -s $dest $src" >&2
      failed=1
    fi
  done
  if [ "$failed" = 0 ]; then
    printf '%s\n' "$skill" > "$root/.owner" 2>/dev/null || failed=1
  fi
  [ "$failed" = 0 ]
}

# The install's marker (.agmsg) says where its state is, so the shim, update,
# uninstall, the app and doctor read it instead of guessing. Scanners that only
# test that the file exists are unaffected.
#   skill=<this install dir>   state=<root | in-place>   reason=<why in place>
agmsg_state_marker_write() {   # <skill dir>
  local skill="${1%/}" state="in-place" t
  if [ -L "$skill/run" ]; then
    t="$(readlink "$skill/run")"
    state="${t%/run}"
  fi
  { printf 'skill=%s\nstate=%s\n' "$skill" "$state"
    [ "$state" != "in-place" ] || printf 'reason=%s\n' "${AGMSG_STATE_REASON:-not moved}"
  } > "$skill/.agmsg"
}

# <skill dir> <key> -> that line's value from the marker (empty if none)
agmsg_state_marker_get() {
  local line
  [ -f "${1%/}/.agmsg" ] || return 0
  while IFS= read -r line; do
    case "$line" in "$2="*) printf '%s\n' "${line#*=}"; return 0 ;; esac
  done < "${1%/}/.agmsg"
}

# An install whose parts already link to its state root (made by hand, or by an
# earlier run of the move) but carries no .owner: record it, move nothing, stop
# nothing. A root that names another existing install is refused, never shared.
agmsg_state_adopt() {   # <skill dir> <state root>
  local skill="${1%/}" root="${2%/}" owner
  if [ -f "$root/.owner" ]; then
    owner="$(<"$root/.owner")"
    if [ -n "$owner" ] && [ "$owner" != "$skill" ] && [ -d "$owner" ]; then
      _agmsg_state_refuse "${skill##*/}" "$skill" "$root belongs to $owner"
      return 1
    fi
  fi
  printf '%s\n' "$skill" > "$root/.owner"
}

# A copy made with cp -R keeps the links, so they name the ORIGINAL's state. Each
# part linked into a root that belongs to another existing install becomes an
# empty real directory in this one; the other install's state is not read,
# written or removed. 0 = nothing wrong or done; 1 = could not detach.
agmsg_state_detach_foreign() {   # <skill dir>
  local skill="${1%/}" part target parent owner
  for part in $AGMSG_STATE_PARTS; do
    [ -L "$skill/$part" ] || continue
    target="$(readlink "$skill/$part")"
    case "$target" in /*/"$part") parent="${target%/*}" ;; *) continue ;; esac
    if [ -f "$parent/.owner" ]; then
      owner="$(<"$parent/.owner")"
    else
      owner="$(agmsg_state_marker_get "$skill" skill)"
    fi
    if [ -n "$owner" ] && [ "${owner%/}" != "$skill" ] && [ -d "$owner" ] \
       && [ "$(cd -P "$owner" 2>/dev/null && pwd -P)" != "$(cd -P "$skill" 2>/dev/null && pwd -P)" ]; then
      command rm -f "$skill/$part" && mkdir -p "$skill/$part" || return 1
      echo "  ~ $skill/$part was linked into the state of $owner; this install now has its own (that state is left as it is)"
    fi
  done
  return 0
}
