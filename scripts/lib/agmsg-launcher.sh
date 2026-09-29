#!/usr/bin/env bash
# Places (and later removes) the thin `agmsg` launcher that lets a person type
# `agmsg daemon ...` from a terminal. It never edits a shell rc file, never
# follows a symlink, and never overwrites a file it does not own.
#
# The launcher is a marked regular file, not a symlink: a symlink cannot carry
# an ownership marker, and `dirname $0` inside the runtime would then resolve
# to the bin directory instead of the install.

# Marker prefix. The full marker line is "<prefix> <absolute skill dir>".
AGMSG_LAUNCHER_MARKER='# agmsg-launcher-owner:'

# Sets AGMSG_LAUNCHER_DIR to the directory a launcher goes in. An explicit
# AGMSG_BIN_DIR is used as given (it must be absolute); otherwise the one
# default candidate for this platform. Never searches PATH.
agmsg_launcher_pick_dir() {
  AGMSG_LAUNCHER_DIR=""
  if [ -n "${AGMSG_BIN_DIR:-}" ]; then
    case "$AGMSG_BIN_DIR" in
      /*) AGMSG_LAUNCHER_DIR="$AGMSG_BIN_DIR"; return 0 ;;
      *)  AGMSG_LAUNCHER_REASON="AGMSG_BIN_DIR is not an absolute path"; return 1 ;;
    esac
  fi
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) AGMSG_LAUNCHER_DIR="$HOME/bin" ;;
    *)                    AGMSG_LAUNCHER_DIR="$HOME/.local/bin" ;;
  esac
}

# Prints the launcher file content for the install at $1.
agmsg_launcher_render() {
  local skill_dir="$1"
  printf '#!/usr/bin/env bash\n'
  printf '# agmsg launcher -- placed by the agmsg installer; remove it with the uninstaller.\n'
  printf '%s %s\n' "$AGMSG_LAUNCHER_MARKER" "$skill_dir"
  printf 'exec bash %q "$@"\n' "$skill_dir/scripts/agmsg"
}

# Sets AGMSG_LAUNCHER_KIND for the target path $1 and install $2 to one of:
#   absent | own-same | own-modified | other-install | symlink | directory |
#   not-regular | foreign
# The target is judged without following links.
agmsg_launcher_classify() {
  local target="$1" skill_dir="$2" marker_line owner
  AGMSG_LAUNCHER_KIND=""
  AGMSG_LAUNCHER_OWNER=""
  if [ -L "$target" ]; then AGMSG_LAUNCHER_KIND=symlink; return 0; fi
  if [ ! -e "$target" ]; then AGMSG_LAUNCHER_KIND=absent; return 0; fi
  if [ -d "$target" ]; then AGMSG_LAUNCHER_KIND=directory; return 0; fi
  if [ ! -f "$target" ]; then AGMSG_LAUNCHER_KIND=not-regular; return 0; fi
  marker_line="$(grep -m1 "^$AGMSG_LAUNCHER_MARKER " "$target" 2>/dev/null || true)"
  if [ -z "$marker_line" ]; then AGMSG_LAUNCHER_KIND=foreign; return 0; fi
  owner="${marker_line#"$AGMSG_LAUNCHER_MARKER "}"
  AGMSG_LAUNCHER_OWNER="$owner"
  if [ "$owner" != "$skill_dir" ]; then AGMSG_LAUNCHER_KIND=other-install; return 0; fi
  if [ "$(agmsg_launcher_render "$skill_dir")" = "$(cat "$target")" ]; then
    AGMSG_LAUNCHER_KIND=own-same
  else
    AGMSG_LAUNCHER_KIND=own-modified
  fi
}

# Places the launcher for the install at $1 and prints a three-part report:
# what was placed, whether this process can see it, and what to check on a
# real terminal. Always returns 0: not placing a launcher is never an install
# failure.
agmsg_launcher_install() {
  local skill_dir="$1" target tmp resolved old
  AGMSG_LAUNCHER_REASON=""
  if ! agmsg_launcher_pick_dir; then
    echo "  ~ agmsg command: not placed ($AGMSG_LAUNCHER_REASON)"
    return 0
  fi
  target="$AGMSG_LAUNCHER_DIR/agmsg"
  agmsg_launcher_classify "$target" "$skill_dir"
  case "$AGMSG_LAUNCHER_KIND" in
    own-same) echo "  ~ agmsg command: already in place at $target" ;;
    absent)
      if ! mkdir -p "$AGMSG_LAUNCHER_DIR" 2>/dev/null \
         || ! tmp="$(mktemp "$AGMSG_LAUNCHER_DIR/.agmsg-launcher.XXXXXX" 2>/dev/null)"; then
        echo "  ~ agmsg command: not placed ($AGMSG_LAUNCHER_DIR is not writable)"
        return 0
      fi
      if agmsg_launcher_render "$skill_dir" > "$tmp" && chmod +x "$tmp" && mv -n "$tmp" "$target" 2>/dev/null && [ ! -e "$tmp" ]; then
        agmsg_launcher_record "$skill_dir" "$target"
        echo "  + agmsg command: placed $target"
      else
        rm -f "$tmp"
        echo "  ~ agmsg command: not placed (could not write $target)"
        return 0
      fi
      ;;
    other-install)
      echo "  ~ agmsg command: not placed ($target already belongs to the install at $AGMSG_LAUNCHER_OWNER)"
      return 0 ;;
    own-modified)
      echo "  ~ agmsg command: not placed ($target was edited; leaving it as it is)"
      return 0 ;;
    symlink)
      echo "  ~ agmsg command: not placed ($target is a symlink; agmsg never replaces one)"
      return 0 ;;
    directory|not-regular|foreign)
      echo "  ~ agmsg command: not placed ($target already exists and is not an agmsg launcher)"
      return 0 ;;
  esac
  case ":$PATH:" in
    *":$AGMSG_LAUNCHER_DIR:"*) echo "    visible in this environment: yes ($AGMSG_LAUNCHER_DIR is on PATH)" ;;
    *) echo "    visible in this environment: no ($AGMSG_LAUNCHER_DIR is not on PATH)" ;;
  esac
  resolved="$(command -v agmsg 2>/dev/null || true)"
  if [ -n "$resolved" ] && [ "$resolved" != "$target" ]; then
    echo "    note: 'agmsg' currently resolves to $resolved, which comes first on PATH"
  fi
  # Every PATH entry ahead of the launcher's directory is checked, not just the
  # first hit: during `npx agmsg install` a temporary entry sits first and an
  # older global one can sit behind it.
  if old="$(agmsg_launcher_find_old_npm_entry "$AGMSG_LAUNCHER_DIR")"; then
    echo "    $old is an older npm agmsg (1.5.1 or earlier) that comes before the launcher on PATH;"
    echo "    it does not know 'agmsg daemon'. Update it with: npm i -g agmsg@latest"
    echo "    (or put $AGMSG_LAUNCHER_DIR before it on PATH)"
    return 0
  fi
  echo "    on your own terminal: not checked here; open a new terminal and run: command -v agmsg"
  echo "    if that prints nothing, add this line to your shell startup file yourself:"
  echo "      export PATH=\"$AGMSG_LAUNCHER_DIR:\$PATH\""
}

# True when the file at $1 is the npm entry from before the single-command
# release (its header names it a bootstrapper). Reads files only. On Unix npm
# links the entry, so reading the path follows to the JS. On Windows npm writes
# a small shell wrapper next to the entry; that wrapper names
# node_modules/agmsg/bin/agmsg.js relative to its own directory, and that file
# is what is read.
agmsg_launcher_is_old_npm_entry() {
  local file="$1" js
  [ -f "$file" ] || return 1
  head -c 4096 "$file" 2>/dev/null | grep -q 'agmsg npm bootstrapper' && return 0
  if head -c 4096 "$file" 2>/dev/null | grep -q 'node_modules/agmsg/bin/agmsg.js'; then
    js="$(dirname "$file")/node_modules/agmsg/bin/agmsg.js"
    [ -f "$js" ] && head -c 4096 "$js" 2>/dev/null | grep -q 'agmsg npm bootstrapper' && return 0
  fi
  return 1
}

# Prints the first older npm agmsg found on PATH ahead of directory $1 (or
# anywhere on PATH when $1 is not on it) and returns 0; returns 1 when none.
agmsg_launcher_find_old_npm_entry() {
  local stop="$1" dir rest="$PATH:"
  while [ -n "$rest" ]; do
    dir="${rest%%:*}"
    rest="${rest#*:}"
    [ -n "$dir" ] || continue
    [ "$dir" = "$stop" ] && return 1
    if agmsg_launcher_is_old_npm_entry "$dir/agmsg"; then
      printf '%s\n' "$dir/agmsg"
      return 0
    fi
  done
  return 1
}

# Remembers where the launcher went so uninstall can find it under a custom
# AGMSG_BIN_DIR. The record is never trusted alone; uninstall re-checks the file.
agmsg_launcher_record() {
  mkdir -p "$1/run" 2>/dev/null || return 0
  printf '%s\n' "$2" > "$1/run/agmsg-launcher.path" 2>/dev/null || true
}

# Removes the launcher for the install at $1 only if the file carries our
# marker, names this install, and still has exactly the content we wrote.
# Prints one line saying what happened. Returns non-zero only when a launcher
# that is ours could not be removed; the record is then kept. The remove
# command defaults to rm; the uninstaller passes its lock-checked remover in
# AGMSG_LAUNCHER_RM so a removal can never run after the lock was lost.
agmsg_launcher_uninstall() {
  local skill_dir="$1" record="" candidate seen=""
  local remover="${AGMSG_LAUNCHER_RM:-rm}"
  [ -f "$skill_dir/run/agmsg-launcher.path" ] && record="$(head -n1 "$skill_dir/run/agmsg-launcher.path" 2>/dev/null || true)"
  agmsg_launcher_pick_dir >/dev/null 2>&1 || true
  for candidate in "$record" "${AGMSG_LAUNCHER_DIR:+$AGMSG_LAUNCHER_DIR/agmsg}"; do
    [ -n "$candidate" ] || continue
    case "$seen" in *"|$candidate|"*) continue ;; esac
    seen="$seen|$candidate|"
    agmsg_launcher_classify "$candidate" "$skill_dir"
    case "$AGMSG_LAUNCHER_KIND" in
      own-same)
        if ! "$remover" -f "$candidate"; then
          echo "  ! could not remove agmsg command $candidate" >&2
          return 1
        fi
        echo "  - removed agmsg command $candidate"
        "$remover" -f "$skill_dir/run/agmsg-launcher.path" || return 1
        return 0 ;;
      own-modified)
        echo "  ~ left $candidate in place (it was edited)" ;;
      other-install)
        echo "  ~ left $candidate in place (it belongs to the install at $AGMSG_LAUNCHER_OWNER)" ;;
      symlink|directory|not-regular|foreign)
        [ "$candidate" = "$record" ] && echo "  ~ left $candidate in place (it is not an agmsg launcher)" ;;
    esac
  done
  return 0
}
