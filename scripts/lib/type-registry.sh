#!/usr/bin/env bash
# Agent-type registry.
#
# Agent types are discovered from `types/<name>/type.conf` manifests instead of
# hardcoded whitelists, so a type (and its template / delivery / session-start /
# spawn behavior) can be added by dropping a directory — including by an external
# add-on outside the agmsg tree.
#
# IMPORTANT — manifests are read-only `key=value` DATA and are NEVER `source`d.
# A small per-key reader is used, so a third-party add-on's manifest cannot
# execute code. Multi-value keys are space-separated.
#
# Search order:
#   1. in-tree built-ins:  <skill-root>/types
#   2. external add-ons:   ${AGMSG_HOME:-$HOME/.config/agmsg}/types
# Built-in names are reserved; if the same name appears in both, the in-tree one
# wins (listed first).
#
# Safe under `set -u`: every env read is guarded.

# Resolve THIS lib's directory at SOURCE time. BASH_SOURCE inside a later
# function call — especially within a command-substitution subshell, or when the
# lib was sourced via a relative path from a different cwd — can resolve against
# the wrong directory; capturing it once here is robust however the registry is
# queried later.
_AGMSG_REGISTRY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# Echo the type search directories, one per line (in-tree first).
_agmsg_type_search_dirs() {
  local root="${AGMSG_TYPES_ROOT:-}"
  if [ -z "$root" ]; then
    # this lib lives at <root>/scripts/lib/type-registry.sh -> up two = <root>
    root="$(cd "$_AGMSG_REGISTRY_LIB_DIR/../.." 2>/dev/null && pwd)"
  fi
  [ -n "$root" ] && printf '%s\n' "$root/types"
  # ${HOME:-} keeps this safe under `set -u` with an empty environment.
  local ext="${AGMSG_HOME:-${HOME:-}/.config/agmsg}/types"
  [ -n "$root" ] && [ "$ext" = "$root/types" ] || printf '%s\n' "$ext"
}

# Echo the directory holding <name>/type.conf, or return 1.
agmsg_type_dir() {
  local want="$1" d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -f "$d/$want/type.conf" ] && { printf '%s\n' "$d/$want"; return 0; }
  done <<EOF
$(_agmsg_type_search_dirs)
EOF
  return 1
}

# List all known type names (deduped, sorted).
agmsg_known_types() {
  local d sub name
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    for sub in "$d"/*/; do
      [ -f "${sub}type.conf" ] || continue
      name="$(basename "$sub")"
      printf '%s\n' "$name"
    done
  done <<EOF
$(_agmsg_type_search_dirs)
EOF
}

# 0 if <name> is a known type.
agmsg_is_known_type() {
  local want="$1" t
  while IFS= read -r t; do
    [ "$t" = "$want" ] && return 0
  done <<EOF
$(agmsg_known_types | sort -u)
EOF
  return 1
}

# Read a single key from <name>/type.conf. Usage:
#   agmsg_type_get <name> <key> [default]
# Reads (never sources) the manifest; strips surrounding quotes/space.
agmsg_type_get() {
  local name="$1" key="$2" def="${3:-}" dir line val
  dir="$(agmsg_type_dir "$name")" || { printf '%s\n' "$def"; return 0; }
  # `|| true` so a no-match grep (exit 1) does not, under set -e + pipefail,
  # abort the assignment before the default-return branch below is reached.
  line="$( { grep -E "^[[:space:]]*${key}[[:space:]]*=" "$dir/type.conf" 2>/dev/null || true; } | head -1)"
  if [ -z "$line" ]; then
    printf '%s\n' "$def"
    return 0
  fi
  val="${line#*=}"
  # trim leading/trailing whitespace
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  # strip one pair of surrounding double quotes if present
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
  esac
  printf '%s\n' "$val"
}

# Comma-or-space list helper: 0 if <value> is in the space-separated <name>'s <key>.
agmsg_type_has() {
  local name="$1" key="$2" want="$3" tok
  for tok in $(agmsg_type_get "$name" "$key"); do
    [ "$tok" = "$want" ] && return 0
  done
  return 1
}
