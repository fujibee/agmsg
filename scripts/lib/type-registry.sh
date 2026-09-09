#!/usr/bin/env bash
# Agent-type registry.
#
# Agent types are discovered from `scripts/drivers/types/<name>/type.conf` manifests instead of
# hardcoded whitelists, so a type (and its template / delivery / session-start /
# spawn behavior) can be added by dropping a directory — including by an external
# add-on outside the agmsg tree.
#
# IMPORTANT — manifests are read-only `key=value` DATA and are NEVER `source`d.
# A small per-key reader is used, so a third-party add-on's manifest cannot
# execute code. Multi-value keys are space-separated.
#
# Discovery + trust are delegated to driver-registry.sh (this is the "types"
# axis). Search bases are <root>/scripts/drivers (built-in), <root>/plugins, and
# $AGMSG_PLUGIN_DIRS. External drivers must be opted into (`agmsg plugin trust`);
# untrusted drop-ins are ignored. Later bases override earlier ones among
# eligible candidates, so an opted-in plugin can shadow a built-in.
#
# Safe under `set -u`: every env read is guarded.

# Resolve THIS lib's directory at SOURCE time. BASH_SOURCE inside a later
# function call — especially within a command-substitution subshell, or when the
# lib was sourced via a relative path from a different cwd — can resolve against
# the wrong directory; capturing it once here is robust however the registry is
# queried later.
_AGMSG_REGISTRY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# Axis-generic bases + trust policy.
# shellcheck disable=SC1091
. "$_AGMSG_REGISTRY_LIB_DIR/driver-registry.sh"

# Warn (once per process, on stderr) about any untrusted external 'types' driver
# that is present. An unexpected drop-in is a potential attack, so it is ignored
# until opted into; this tells the user it exists and how to trust it.
_agmsg_type_warn_untrusted() {
  [ -n "${_AGMSG_TYPE_WARNED:-}" ] && return 0
  _AGMSG_TYPE_WARNED=1
  local kind base dir name
  while IFS=$'\t' read -r kind base; do
    [ "$kind" = external ] && [ -d "$base/types" ] || continue
    for dir in "$base"/types/*/; do
      [ -f "${dir}type.conf" ] || continue
      name="$(basename "$dir")"
      agmsg_driver_is_trusted types "$name" "${dir%/}" && continue
      printf "agmsg: external plugin 'types/%s' found at %s but not trusted (ignored).\n       Opt in if you put it there intentionally: agmsg plugin trust types/%s\n" \
        "$name" "${dir%/}" "$name" >&2
    done
  done <<EOF
$(agmsg_driver_bases)
EOF
}

# Echo the directory holding <name>/type.conf, or return 1. Later bases override
# earlier ones among ELIGIBLE candidates: built-ins are always eligible; external
# drivers only once opted into. Untrusted external candidates are skipped.
agmsg_type_dir() {
  local want="$1" kind base dir chosen=""
  while IFS=$'\t' read -r kind base; do
    dir="$base/types/$want"
    [ -f "$dir/type.conf" ] || continue
    if [ "$kind" = builtin ] || agmsg_driver_is_trusted types "$want" "$dir"; then
      chosen="$dir"
    fi
  done <<EOF
$(agmsg_driver_bases)
EOF
  [ -n "$chosen" ] && { printf '%s\n' "$chosen"; return 0; }
  return 1
}

# List all known (eligible) type names, with duplicates the caller dedups via
# `sort -u`. Surfaces untrusted-external warnings as a side effect (once/process).
agmsg_known_types() {
  _agmsg_type_warn_untrusted
  local kind base dir name
  while IFS=$'\t' read -r kind base; do
    [ -d "$base/types" ] || continue
    for dir in "$base"/types/*/; do
      [ -f "${dir}type.conf" ] || continue
      name="$(basename "$dir")"
      [ "$kind" = builtin ] || agmsg_driver_is_trusted types "$name" "${dir%/}" || continue
      printf '%s\n' "$name"
    done
  done <<EOF
$(agmsg_driver_bases)
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

# Echo the absolute path to <name>'s SKILL command template, resolved from the
# manifest `template=` key relative to the type's own directory
# (scripts/drivers/types/<name>/template.md). Returns 1 if the type or its template= key is
# unknown. template= is a type-dir-relative filename; reject absolute paths or
# traversal so a third-party manifest can't redirect reads outside its type dir
# (mirrors resolve_hooks_file's guard in delivery.sh).
agmsg_type_template_path() {
  local name="$1" dir rel
  dir="$(agmsg_type_dir "$name")" || return 1
  rel="$(agmsg_type_get "$name" template)"
  [ -n "$rel" ] || return 1
  case "$rel" in
    /*|*..*) echo "Invalid template for $name: $rel" >&2; return 1 ;;
  esac
  printf '%s\n' "$dir/$rel"
}

# Comma-or-space list helper: 0 if <value> is in the space-separated <name>'s <key>.
agmsg_type_has() {
  local name="$1" key="$2" want="$3" tok
  for tok in $(agmsg_type_get "$name" "$key"); do
    [ "$tok" = "$want" ] && return 0
  done
  return 1
}

# Space-separated names of eligible agent types that have a skill template.
# Types such as agmsg-app remain in the registry but are not renderable because
# they deliberately have no template= manifest key. Keep this derived from the
# registry so adding a templated type cannot leave install/test composition
# loops silently stale.
_agmsg_renderable_types() {
  local type
  while IFS= read -r type; do
    [ -n "$type" ] || continue
    if [ -n "$(agmsg_type_get "$type" template)" ]; then
      printf '%s\n' "$type"
    fi
  done < <(agmsg_known_types | sort -u)
}

AGMSG_RENDERABLE_SKILL_TYPES="$(_agmsg_renderable_types | paste -sd' ' -)"
