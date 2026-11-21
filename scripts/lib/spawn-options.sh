#!/usr/bin/env bash
# spawn-options.sh — per-agent-type extra CLI args injected by spawn.sh.
#
# Reads a small YAML file mapping agent type -> a flat map of CLI flag ->
# value, using the same simple dialect db/config.yaml already uses (flat
# "section:" header + 2-space-indented "key: value", no nesting, no
# quoting — see config.sh's yaml_get). Turns one type's section into a list
# of ready-to-use shell tokens spawn.sh splices into its launch command.
#
# File resolution: $AGMSG_SPAWN_OPTIONS_FILE if set, else
# ~/.agmsg/config/spawn_options.yaml — agmsg's planned install-path-
# independent config home (#201), distinct from the current skill-dir-rooted
# db/config.yaml so it survives a custom --cmd install or multiple installs.
# A missing file, missing type section, or empty file all mean "no extra
# args" — this feature is fully opt-in and backward compatible.
#
# Value semantics (per key under a type's section):
#   <key>: <value>   -> two tokens: <key> <value>
#   <key>: true      -> one token:  <key>            (boolean flag on)
#   <key>: false     -> no tokens                     (explicitly suppressed)

# Guard against double-source.
[ -n "${_AGMSG_SPAWN_OPTIONS_SH:-}" ] && return 0
_AGMSG_SPAWN_OPTIONS_SH=1

agmsg_spawn_options_file() {
  printf '%s' "${AGMSG_SPAWN_OPTIONS_FILE:-$HOME/.agmsg/config/spawn_options.yaml}"
}

# Companion sample path beside the resolved spawn_options.yaml:
# dirname($AGMSG_SPAWN_OPTIONS_FILE)/spawn_options.yaml.sample when set,
# else ~/.agmsg/config/spawn_options.yaml.sample.
agmsg_spawn_options_sample_file() {
  local target dir
  target="$(agmsg_spawn_options_file)"
  dir="$(dirname "$target")"
  if [ "$dir" = "/" ]; then
    printf '/spawn_options.yaml.sample'
  else
    printf '%s/spawn_options.yaml.sample' "$dir"
  fi
}

# Place spawn_options.yaml.sample beside the resolved spawn_options.yaml path
# when absent. Never touches spawn_options.yaml itself and never overwrites an
# existing sample file. Best-effort: prints the created path on stdout only when
# newly written, and returns 0 even if the target directory is not writable.
agmsg_ensure_spawn_options_sample() {
  local src="$1" dest dir
  [ -f "$src" ] || return 0
  dest="$(agmsg_spawn_options_sample_file)"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    return 0
  fi
  dir="$(dirname "$dest")"
  mkdir -p "$dir" 2>/dev/null || return 0
  if ( set -C; tr -d '\r' < "$src" > "$dest" ) 2>/dev/null; then
    printf '%s\n' "$dest"
  fi
  return 0
}

# Emit one shell token per output line for <type>'s section. Each line is a
# complete argv token — the caller must read line-by-line (never word-split
# the output), so a value containing spaces stays a single token.
agmsg_spawn_options_tokens() {
  local type="$1" file
  file="$(agmsg_spawn_options_file)"
  [ -f "$file" ] || return 0

  awk -v section="$type" '
    /^[^ #]/ { in_section = ($0 ~ "^" section ":") }
    in_section && /^  [^ ]/ {
      line = $0
      sub(/^  /, "", line)
      idx = index(line, ":")
      if (idx == 0) next
      key = substr(line, 1, idx - 1)
      val = substr(line, idx + 1)
      sub(/[ \t]+#.*$/, "", val)
      sub(/^[ \t]+/, "", val)
      sub(/[ \t]+$/, "", val)
      if (val == "false") next
      print key
      if (val != "" && val != "true") print val
    }
  ' "$file"
}
