# agmsg_require_python3 <feature description> -- preflight check before any
# python3 invocation on the "remote" dependency tier (remote.sh, team-list.sh,
# and their scripts/internal/*.py helpers). Mirrors key.sh's
# _key_require_age: the caller MUST call this before the first python3
# invocation on a given code path, not merely check python3's own exit
# status after the fact.
#
# This matters beyond a clean error message: on macOS, invoking a bare
# `python3` when Xcode Command Line Tools are not installed does not fail
# fast with "command not found" -- it triggers the OS's own "install
# command line developer tools?" GUI dialog (the /usr/bin/python3 shim is a
# CLT installer trampoline, not a real interpreter, until CLT is present).
#
# `command -v python3` alone is NOT sufficient to detect this (review,
# P1): the trampoline file genuinely exists at /usr/bin/python3, so
# `command -v` reports success even when CLT is not installed -- the
# dialog only fires once something actually EXECUTES it. So on Darwin,
# when python3's CANONICAL (symlink-resolved) target is exactly
# /usr/bin/python3, an additional check is required: `xcode-select -p`
# reports whether CLT (or a full Xcode) is actually installed. It is safe
# to call -- unlike python3 itself, it is a real, always-present binary
# that only inspects installed-tool state and never pops a GUI dialog; it
# just exits non-zero with no CLT installed.
#
# Comparing `command -v`'s raw output as a literal string is NOT enough
# either (delta review, P1): PATH may resolve python3 through a
# symlink -- e.g. ~/bin/python3 -> /usr/bin/python3 -- in which case
# `command -v` reports `~/bin/python3`, a string comparison against
# `/usr/bin/python3` misses it, and the trampoline still fires once that
# symlink is executed. The resolved path is therefore followed through
# every symlink hop (relative or absolute) to its physical target before
# comparing, without ever executing python3 itself, using a portable
# manual loop -- BSD/macOS `readlink` has no `-f`/canonicalize flag, so
# `realpath`/`readlink -f` cannot be relied on to exist.
#
# On any canonical target other than /usr/bin/python3 (Homebrew, pyenv,
# apt, etc.), or on a non-Darwin platform, there is no trampoline to
# worry about and `command -v` alone is authoritative.
#
# python3 itself is NEVER executed by this check, on any platform.
#
# core (local-only) and E2EE (age) tiers never source this file and never
# need python3; only remote-tier code should call it.

# Indirection points so tests can substitute fakes without touching real
# filesystem paths or fighting `command -v`'s exact-string PATH lookup --
# bash resolves a called function by name from the function table before
# ever consulting PATH, so a test that re-defines these after sourcing
# this file transparently overrides them for agmsg_python3_usable.
_agmsg_python3_resolved_path() { command -v python3 2>/dev/null; }
_agmsg_platform() { uname -s 2>/dev/null; }
# The known CLT trampoline location, as its own indirection point so a
# test can point this at a disposable fixture path instead of the real
# /usr/bin/python3 (which tests must never create, delete, or depend on
# the real state of).
_agmsg_python3_trampoline_path() { printf '/usr/bin/python3'; }

# _agmsg_canonical_path <path> -- resolve every symlink hop (relative or
# absolute) to <path>'s physical target, WITHOUT executing it. Portable
# to BSD/macOS `readlink` (no -f flag available there). Loop-bounded
# against a symlink cycle. If <path> (or any hop) doesn't exist, returns
# the furthest point reached rather than failing, so a caller comparing
# against a known canonical string simply gets a non-match.
_agmsg_canonical_path() {
  local path="$1" dir target hops=0
  while [ -L "$path" ] && [ "$hops" -lt 40 ]; do
    target="$(readlink "$path")"
    case "$target" in
      /*) path="$target" ;;
      *)
        dir="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)"
        path="${dir:+$dir/}$target"
        ;;
    esac
    hops=$((hops + 1))
  done
  dir="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)"
  if [ -n "$dir" ]; then
    printf '%s/%s\n' "$dir" "$(basename "$path")"
  else
    printf '%s\n' "$path"
  fi
}

# agmsg_python3_usable -- 0 if python3 is present AND safe to invoke
# without risking the macOS CLT dialog, 1 otherwise. Never executes
# python3.
agmsg_python3_usable() {
  local resolved canonical trampoline
  resolved="$(_agmsg_python3_resolved_path)"
  [ -n "$resolved" ] || return 1
  if [ "$(_agmsg_platform)" = "Darwin" ]; then
    canonical="$(_agmsg_canonical_path "$resolved")"
    trampoline="$(_agmsg_canonical_path "$(_agmsg_python3_trampoline_path)")"
    if [ "$canonical" = "$trampoline" ]; then
      xcode-select -p >/dev/null 2>&1 || return 1
    fi
  fi
  return 0
}

agmsg_require_python3() {
  local feature="${1:-this feature}"
  if ! agmsg_python3_usable; then
    echo "agmsg: $feature requires python3, which was not found (or not yet usable) on this device." >&2
    echo "Install it, then retry:" >&2
    echo "  macOS (Homebrew):      brew install python3" >&2
    echo "  macOS (Xcode tools):   xcode-select --install" >&2
    echo "  Debian/Ubuntu:         sudo apt install python3" >&2
    echo "  Windows (winget):      winget install Python.Python.3" >&2
    return 1
  fi
}
