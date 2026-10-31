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

# Same resolution and default-fallback behavior as agmsg_driver_for_team
# above (#1849), plus $_AGMSG_DRIVER_CONFIRMED: 1 when THIS call's own
# read of config.json and parse of its JSON definitively succeeded --
# whether that found a real configured value or confirmed the key is
# legitimately unset (a team with no `drivers.<axis>` key at all is
# correctly defaulting, not failing) -- 0 when it could not tell (the
# file could not be read, or its content could not be parsed as JSON).
#
# agmsg_driver_for_team's own ordinary contract has no way to tell these
# apart: it swallows every failure into the same <default> an ordinary,
# legitimate default produces, which is exactly right for its existing
# callers (never stop delivery over a config hiccup) but wrong for a
# caller deciding whether to CACHE the answer -- a cached fallback from a
# transient read/parse failure would keep returning that fallback long
# after the failure passed, since nothing about the file's own mtime/size
# changes when only the ability to read it does (confirmed directly: a
# chmod 000 file still `stat`s fine). This is a separate function, not a
# new argument/output mode on agmsg_driver_for_team itself, so every
# existing caller's behavior is completely unchanged.
# Sets $_AGMSG_DRIVER_RESOLVED_NAME and $_AGMSG_DRIVER_CONFIRMED in the
# CALLER's shell -- this must be invoked as a PLAIN STATEMENT, never via
# $(...): a command substitution runs the function body in a subshell,
# and a global written there is discarded the instant that subshell exits
# (the exact hazard _agmsg_driver_root's own cache, and watch.sh's
# "plain-statement warm" calls throughout this codebase, exist to avoid --
# caught here in review before it shipped: an earlier version of this
# function printed its result for a `name="$(...)"` caller to capture,
# which made $_AGMSG_DRIVER_CONFIRMED unreadable in the caller's own shell
# by construction, not merely by omission).
agmsg_driver_for_team_confirmed() {   # <axis> <team> <default>
  local axis="$1" team="$2" default="$3"
  _AGMSG_DRIVER_RESOLVED_NAME="$default"
  _AGMSG_DRIVER_CONFIRMED=0
  case "$axis" in *[!a-z-]*|'') return 0 ;; esac
  local root cfg rf out rc=0
  root="$(_agmsg_driver_root)" || return 0
  cfg="$root/teams/$team/config.json"
  [ -f "$cfg" ] || return 0
  rf="$(agmsg_sql_readfile_path "$cfg")"
  # One statement, two COLUMNS (joined by char(31), the unit separator --
  # already this codebase's own convention for an internal field
  # delimiter that cannot appear in a name, e.g. the roster journal's
  # own records) rather than a single magic-string result (review round
  # 5: a sentinel folded into the VALUE column collides with a config
  # that happens to be configured with that exact string -- found by the
  # same review as the bug below, same root cause: inventing a new
  # vocabulary instead of asking sqlite for the fact directly). The first
  # field is whether the read itself failed (readfile() -> NULL --
  # permissions, I/O); the second is the raw extracted value, exactly as
  # agmsg_driver_for_team's own query returns it -- including whatever
  # agmsg_driver_for_team's own COALESCE-to-empty-string already does for
  # a genuinely absent/null key, so the two functions read the identical
  # byte stream for "no explicit value" and the normalization below can
  # match agmsg_driver_for_team's own rule exactly instead of inventing a
  # second one. Malformed JSON makes json_extract itself raise an error --
  # sqlite3 exits non-zero with nothing useful on stdout, caught below by
  # the rc check rather than needing its own branch in the SQL. The CTE
  # reads the file ONCE or (review round 5, suggested, not required)
  # whatever the whole connection would otherwise do: a bare two-call
  # `readfile('$rf')` repeated in the same statement already isn't
  # guaranteed to be two separate filesystem reads in SQLite's own
  # execution model, but routing both references through one CTE removes
  # any doubt rather than relying on that.
  #
  # `|| rc=$?`, not a bare assignment: a caller running under `set -e`
  # (bats own test bodies do) would otherwise have THIS statement's own
  # failure abort the whole function the instant sqlite3 exits non-zero,
  # before the rc/output checks below ever run -- caught by this
  # function's own malformed-JSON regression test, which exercises
  # exactly that exit code.
  # sqlite3 >= 3.50 caret-escapes control bytes in its default text output
  # (the same #143 behavior storage.sh's own agmsg_sqlite already works
  # around), which would otherwise turn the char(31) separator above into
  # the two literal characters "^_" and break the field split below.
  # `agmsg_sqlite_warm`/`_agmsg_escape_flag` (storage.sh, already sourced
  # by the time this runs -- see this file's own callers) probe and
  # memoize whether `-escape off` is a real option on this build, the
  # same way every other direct sqlite3 call in this tree does.
  if declare -F agmsg_sqlite_warm >/dev/null 2>&1; then
    agmsg_sqlite_warm
  fi
  rc=0
  out="$(sqlite3 ${_AGMSG_ESCAPE_FLAG:-} :memory: \
    "WITH f AS (SELECT readfile('$rf') AS c)
     SELECT (CASE WHEN c IS NULL THEN '1' ELSE '0' END) || char(31) ||
            COALESCE(json_extract(c, '\$.drivers.$axis'), '')
       FROM f;" 2>/dev/null)" || rc=$?
  out="$(printf '%s' "$out" | tr -d '\r')"
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    return 0
  fi
  local readfail="${out%%$'\x1f'*}" raw="${out#*$'\x1f'}"
  [ "$readfail" = 1 ] && return 0
  _AGMSG_DRIVER_CONFIRMED=1
  # Identical normalization to agmsg_driver_for_team's own
  # `case "$name" in ''|null) ... esac` -- an empty extraction (the key is
  # absent, or JSON null) AND the literal string "null" (review round 5:
  # a config holding that string, which the old function has always
  # treated as "unset", must resolve the same way here, or a
  # previously-working config starts failing to find a driver file named
  # literally "null").
  case "$raw" in ''|null) ;; *) _AGMSG_DRIVER_RESOLVED_NAME="$raw" ;; esac
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
