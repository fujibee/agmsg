#!/usr/bin/env bash
# Driver registry — axis-generic discovery + trust policy.
#
# agmsg's pluggable units are "drivers" grouped by axis (ADR 0001 / docs/spec/
# driver-interface.md). The agent-type registry (type-registry.sh) is the first
# consumer (axis = "types"); storage and delivery axes reuse the same machinery.
#
# This lib knows NOTHING about a given axis's internal layout (types use a
# directory with type.conf; another axis may differ). It only provides:
#   - the ordered search BASES   (in-tree built-ins, then external plugin dirs)
#   - the TRUST policy           (which external drivers the user opted into)
# Each axis facade enumerates `<base>/<axis>/...` itself and gates externals with
# agmsg_driver_is_trusted.
#
# Search bases, in priority order (later overrides earlier among ELIGIBLE ones):
#   1. <root>/scripts/drivers          in-tree built-ins — always trusted
#   2. <root>/plugins                  default external plugin dir (install_dir/plugins)
#   3. each abs-dir in <root>/db/plugin-sources   installed plugin sources
#   4. each dir in $AGMSG_PLUGIN_DIRS   ':'-separated extra external dirs
#
# SECURITY: external drivers are shell code that runs with the user's privileges.
# They are NEVER loaded unless explicitly opted into (`agmsg plugin trust`), so an
# unexpected drop-in cannot execute. An untrusted external driver that is present
# is ignored (a built-in of the same name still resolves); callers may warn.
#
# Safe under `set -u`: every env read is guarded.

# Resolve THIS lib's dir at source time (robust to later subshell/relative cwd).
_AGMSG_DRIVER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

if ! declare -F agmsg_sql_readfile_path >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$_AGMSG_DRIVER_LIB_DIR/sqlpath.sh"
fi
if ! declare -F agmsg_plugin_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$_AGMSG_DRIVER_LIB_DIR/plugin-cmd.sh"
fi

# <skill-root> = up two from scripts/lib/. Memoized for the life of the
# process (#1849): this path cannot change for as long as this process
# runs (it is this install's own on-disk location), so a long-lived caller
# -- watch.sh's poll loop, calling this several times per cycle through
# agmsg_driver_for_team/agmsg_ext_tool_dir -- pays the `cd`+`pwd` fork
# exactly once instead of every single call. A one-shot script still pays
# it once, same as before; this only removes REPEAT payments within one
# process.
_AGMSG_DRIVER_ROOT_CACHE=""
_agmsg_driver_root() {
  if [ -n "$_AGMSG_DRIVER_ROOT_CACHE" ]; then
    printf '%s\n' "$_AGMSG_DRIVER_ROOT_CACHE"
    return 0
  fi
  _AGMSG_DRIVER_ROOT_CACHE="$(cd "$_AGMSG_DRIVER_LIB_DIR/../.." 2>/dev/null && pwd)" || return 1
  [ -n "$_AGMSG_DRIVER_ROOT_CACHE" ] || return 1
  printf '%s\n' "$_AGMSG_DRIVER_ROOT_CACHE"
}

# Echo the search bases as "<kind>\t<dir>" lines, in priority order. <kind> is
# "builtin" (in-tree, always trusted) or "external" (requires opt-in).
agmsg_driver_bases() {
  local root
  root="$(_agmsg_driver_root)" || return 0
  [ -n "$root" ] || return 0
  printf 'builtin\t%s\n' "$root/scripts/drivers"
  printf 'external\t%s\n' "$root/plugins"
  # db/plugin-sources: one installed source per line, TSV
  # "<source-id> <spec> <commit-or-digest> <abs-dir> <installed-at>". Only the
  # abs-dir matters here. A plain file read: no git, no subprocess.
  local _ps="$root/db/plugin-sources" _id _spec _rev _dir _rest
  if [ -f "$_ps" ]; then
    while IFS=$'\t' read -r _id _spec _rev _dir _rest || [ -n "$_id" ]; do
      _dir="${_dir%$'\r'}"
      case "$_id" in ''|'#'*) continue ;; esac
      [ -n "$_dir" ] && printf 'external\t%s\n' "$_dir"
    done < "$_ps"
  fi
  # AGMSG_PLUGIN_DIRS: ':'-separated extra external bases (override last).
  local IFS=: d
  for d in ${AGMSG_PLUGIN_DIRS:-}; do
    [ -n "$d" ] && printf 'external\t%s\n' "$d"
  done
}

# Path to the opt-in allowlist. One trusted driver per line: "<axis>/<name>\t<abs-path>".
# Lives under db/ (preserved across --update installs, like config.yaml). A plain
# TSV — not config.yaml — because driver identities contain '/' which the YAML
# key parser does not handle, and append/grep/remove are trivial here.
agmsg_driver_trustfile() {
  local root
  root="$(_agmsg_driver_root)" || return 1
  printf '%s\n' "$root/db/trusted-plugins"
}

# 0 if the external driver <axis>/<name> at <path> was opted into (exact path
# match — a trusted name pointing elsewhere is NOT honored, so swapping the dir
# under a trusted name does not silently activate new code).
agmsg_driver_is_trusted() {
  local axis="$1" name="$2" path="$3" tf
  tf="$(agmsg_driver_trustfile)" || return 1
  [ -f "$tf" ] || return 1
  grep -qxF "$(printf '%s/%s\t%s' "$axis" "$name" "$path")" "$tf"
}

# Record an opt-in for <axis>/<name> at <path>. Idempotent.
agmsg_driver_trust() {
  local axis="$1" name="$2" path="$3" tf line
  tf="$(agmsg_driver_trustfile)" || return 1
  mkdir -p "$(dirname "$tf")"
  line="$(printf '%s/%s\t%s' "$axis" "$name" "$path")"
  [ -f "$tf" ] && grep -qxF "$line" "$tf" && return 0
  printf '%s\n' "$line" >> "$tf"
}

# Remove every opt-in for <axis>/<name> (any path).
agmsg_driver_untrust() {
  local axis="$1" name="$2" tf tmp
  tf="$(agmsg_driver_trustfile)" || return 1
  [ -f "$tf" ] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/agmsg-trust.XXXXXX")"
  grep -vE "^$(printf '%s/%s' "$axis" "$name" | sed 's/[][\.*^$/]/\\&/g')	" "$tf" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$tf"
}

# Which driver a TEAM uses on <axis>, falling back to <default>.
#
# Teams choose independently: one team can sit on a per-team store while its
# neighbour is still in the shared one. That is the point — the shared partition is
# what every external reader of the database depends on, so a team only leaves
# it when something (today: connecting to a remote) actually requires it.
#
# Axis-generic on purpose. The storage axis (sqlite / jsonl) is install-wide
# today and is expected to become per-team later; when it does it reads this
# same field rather than growing a second mechanism beside it.
#
# The choice lives in the team's own config.json, which is already the local
# record of a team. A team that has never left the default records nothing,
# which is why <default> is a required argument rather than a constant here.
agmsg_driver_for_team() {
  local axis="$1" team="$2" default="$3"
  # The axis is interpolated into a JSON path, so it is checked rather than
  # trusted even though every caller passes a literal.
  case "$axis" in *[!a-z-]*|'') printf '%s\n' "$default"; return 0 ;; esac
  local root cfg name
  root="$(_agmsg_driver_root)" || { printf '%s\n' "$default"; return 0; }
  cfg="$root/teams/$team/config.json"
  [ -f "$cfg" ] || { printf '%s\n' "$default"; return 0; }
  # readfile() rather than a shell read: a config may contain any UTF-8, and
  # this mirrors how the rest of the tree reads these files.
  name="$(sqlite3 :memory: \
    "SELECT COALESCE(json_extract(readfile('$(agmsg_sql_readfile_path "$cfg")'), '\$.drivers.$axis'), '')" \
    2>/dev/null | tr -d '\r')"
  case "$name" in ''|null) printf '%s\n' "$default" ;; *) printf '%s\n' "$name" ;; esac
}

# ext-tools go through the same bases as every other axis: a built-in tool is
# always eligible, an external one only once trusted. The tool name becomes a
# path segment, so it is checked here too (letters, digits, '-', '_').
_agmsg_ext_tool_name_ok() {
  case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  return 0
}

# Echo the tool's driver directory (the last eligible base that has a tool.conf
# for it); non-zero if there is none. An untrusted external copy is ignored with
# a warning on stderr (once per copy per process).
agmsg_ext_tool_dir() {
  local tool="$1" kind base dir found=""
  _agmsg_ext_tool_name_ok "$tool" || return 1
  while IFS=$'\t' read -r kind base; do
    dir="$base/ext-tools/$tool"
    [ -f "$dir/tool.conf" ] || continue
    if [ "$kind" != builtin ] && ! agmsg_driver_is_trusted ext-tools "$tool" "$dir"; then
      case " ${_AGMSG_EXT_TOOL_WARNED:-} " in *" $tool@$dir "*) ;; *)
        _AGMSG_EXT_TOOL_WARNED="${_AGMSG_EXT_TOOL_WARNED:-} $tool@$dir"
        printf "agmsg: external plugin 'ext-tools/%s' found at %s but not trusted (ignored).\n       Opt in if you put it there intentionally: %s plugin trust ext-tools/%s\n" \
          "$tool" "$dir" "$(agmsg_plugin_cmd "$(_agmsg_driver_root)")" "$tool" >&2 ;;
      esac
      continue
    fi
    found="$dir"
  done <<EOF
$(agmsg_driver_bases)
EOF
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# Names of every usable ext-tool, ", "-joined and sorted ("none" if empty).
agmsg_ext_tool_available() {
  local kind base dir name names=""
  while IFS=$'\t' read -r kind base; do
    for dir in "$base"/ext-tools/*/; do
      [ -f "${dir}tool.conf" ] || continue
      name="$(basename "$dir")"
      _agmsg_ext_tool_name_ok "$name" || continue
      [ "$kind" = builtin ] || agmsg_driver_is_trusted ext-tools "$name" "${dir%/}" || continue
      names="$names$name"$'\n'
    done
  done <<EOF
$(agmsg_driver_bases)
EOF
  [ -n "$names" ] || { printf 'none'; return 0; }
  printf '%s' "$names" | sort -u | paste -sd, - | sed 's/,/, /g'
}
