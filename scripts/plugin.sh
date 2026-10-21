#!/usr/bin/env bash
set -euo pipefail

# agmsg plugin — manage trust for EXTERNAL drivers (axes: types, and later
# storage / delivery). External drivers are shell code that runs with your
# privileges, so the registry ignores them until you opt in here.
#
# Usage:
#   plugin.sh list                 # discovered drivers + trust state
#   plugin.sh trust <ref>          # opt into an external driver
#   plugin.sh untrust <ref>        # revoke
#   plugin.sh install <owner>/<repo>[@<ref>] [--yes] [--override]   (alias: add)
#   plugin.sh update  <owner>/<repo>[@<ref>] [--yes] [--override]
#   plugin.sh remove  <owner>/<repo>                                (alias: uninstall)
#
# install/update fetch a GitHub repository with git, show what it adds and which
# files can run, and only then install and trust it. Nothing is ever updated on
# its own: new code from a source runs only after `update` and a confirmation.
# Exit 3 means "needs confirmation": nothing was installed (no TTY and no --yes).
#
# <ref> is "<axis>/<name>" (e.g. types/codex) or a bare "<name>". A bare name
# matches across axes; if more than one axis has it, you must qualify it.

ACTION="${1:-list}"
shift || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/driver-registry.sh"

# ---------------------------------------------------------------------------
# Plugin sources (install / update / remove)
#
# A source is a GitHub repository checked out at ONE commit under
# <skill>/plugins/sources/github/<owner>/<repo>/<sha>/ and recorded in
# db/plugin-sources (TSV: source-id, spec, commit, abs-dir, installed-at). The
# registry reads that file, so each abs-dir is a search base. The directory name
# is the commit, so the path-pinned trust (db/trusted-plugins) also pins the
# commit: an update lands in a new directory that is not trusted until confirmed.
# ---------------------------------------------------------------------------

PLUGIN_ROOT="$(_agmsg_driver_root)"
PLUGIN_SOURCES_DIR="$PLUGIN_ROOT/plugins/sources"
PLUGIN_SOURCES_FILE="$PLUGIN_ROOT/db/plugin-sources"
PLUGIN_ACCEPTED_AXES="ext-tools terminals types"
PLUGIN_STAGE=""

_plugin_die() { echo "agmsg plugin: $*" >&2; exit 1; }

# Remove the staging directory this process made, and only that.
_plugin_stage_cleanup() {
  case "$PLUGIN_STAGE" in
    "$PLUGIN_SOURCES_DIR"/.staging/fetch.??*) rm -rf -- "$PLUGIN_STAGE" ;;
  esac
  PLUGIN_STAGE=""
}
trap _plugin_stage_cleanup EXIT

# owner / repo are path segments: no separators, no leading '.' or '-'.
_plugin_valid_segment() {
  case "$1" in ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

_plugin_valid_ref() {
  case "$1" in
    ''|-*|/*|*/|*//*|*..*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  return 0
}

_plugin_is_full_sha() {
  case "$1" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

# Parse "<owner>/<repo>[@<ref>]" into SPEC_OWNER / SPEC_REPO / SPEC_REF.
_plugin_parse_spec() {
  local spec="$1" base ref=""
  base="$spec"
  case "$spec" in
    *@*) base="${spec%%@*}"; ref="${spec#*@}"
         [ -n "$ref" ] || _plugin_die "empty ref in '$spec'" ;;
  esac
  case "$base" in
    */*/*|*/|/*|'') _plugin_die "expected <owner>/<repo>[@<ref>], got '$spec'" ;;
    */*) ;;
    *) _plugin_die "expected <owner>/<repo>[@<ref>], got '$spec'" ;;
  esac
  SPEC_OWNER="${base%%/*}"
  SPEC_REPO="${base#*/}"
  _plugin_valid_segment "$SPEC_OWNER" || _plugin_die "invalid owner '$SPEC_OWNER'"
  _plugin_valid_segment "$SPEC_REPO" || _plugin_die "invalid repository name '$SPEC_REPO'"
  if [ -n "$ref" ]; then
    _plugin_valid_ref "$ref" || _plugin_die "invalid ref '$ref'"
  fi
  SPEC_REF="$ref"
}

# git with the safety flags every call here needs. CRLF conversion off: a
# converted checkout puts \r in every shell script. No prompts, no hooks, no
# external-command transports.
_plugin_git() {
  GIT_TERMINAL_PROMPT=0 git \
    -c core.autocrlf=false -c core.eol=lf -c core.hooksPath=/dev/null \
    -c protocol.ext.allow=never "$@"
}

# Fetch <owner>/<repo> at <ref> into a fresh staging dir. Sets PLUGIN_STAGE
# (the staging dir), PLUGIN_SRC (the checkout inside it, .git removed) and
# PLUGIN_SHA (the exact commit).
_plugin_fetch() {
  local owner="$1" repo="$2" ref="$3" url
  command -v git >/dev/null 2>&1 || _plugin_die "git is required to install a plugin"
  url="${AGMSG_PLUGIN_GIT_BASE:-https://github.com}/$owner/$repo"
  mkdir -p "$PLUGIN_SOURCES_DIR/.staging"
  PLUGIN_STAGE="$(mktemp -d "$PLUGIN_SOURCES_DIR/.staging/fetch.XXXXXX")"
  PLUGIN_SRC="$PLUGIN_STAGE/src"
  if _plugin_is_full_sha "$ref"; then
    mkdir "$PLUGIN_SRC"
    _plugin_git -C "$PLUGIN_SRC" init -q || _plugin_die "git init failed"
    _plugin_git -C "$PLUGIN_SRC" remote add origin "$url"
    _plugin_git -C "$PLUGIN_SRC" fetch -q --depth 1 origin "$ref" \
      || _plugin_die "could not fetch commit $ref from $owner/$repo"
    _plugin_git -C "$PLUGIN_SRC" checkout -q FETCH_HEAD \
      || _plugin_die "could not check out $ref"
  elif [ -n "$ref" ]; then
    _plugin_git clone -q --depth 1 --branch "$ref" -- "$url" "$PLUGIN_SRC" \
      || _plugin_die "could not fetch $owner/$repo at '$ref'"
  else
    _plugin_git clone -q --depth 1 -- "$url" "$PLUGIN_SRC" \
      || _plugin_die "could not fetch $owner/$repo"
  fi
  PLUGIN_SHA="$(_plugin_git -C "$PLUGIN_SRC" rev-parse HEAD)"
  _plugin_is_full_sha "$PLUGIN_SHA" || _plugin_die "unexpected commit id '$PLUGIN_SHA'"
  if _plugin_is_full_sha "$ref" && [ "$PLUGIN_SHA" != "$ref" ]; then
    _plugin_die "fetched commit $PLUGIN_SHA does not match requested $ref"
  fi
  # The checkout is plain files from here on: no git metadata to run or read.
  rm -rf -- "$PLUGIN_SRC/.git"
}

# Read one key from agmsg-plugin.conf as data (never sourced).
_plugin_conf_get() {
  local file="$1" key="$2" line v
  line="$( { tr -d '\r' < "$file" | grep -E "^[[:space:]]*${key}[[:space:]]*=" || true; } | head -1)"
  v="${line#*=}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# Leading x.y.z of a version string ("v1.6.0-rc.6-12-gabc" -> 1.6.0).
_plugin_semver() {
  local v="${1#v}"
  if [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    printf '%s.%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

# 0 if $1 <= $2 (both x.y.z).
_plugin_semver_le() {
  local a b i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    [ "${a[$i]}" -lt "${b[$i]}" ] && return 0
    [ "${a[$i]}" -gt "${b[$i]}" ] && return 1
  done
  return 0
}

# Names of the drivers a checkout carries, one "<axis>/<name>" per line, from
# the accepted axes only.
_plugin_drivers_in() {
  local dir="$1" axis namedir
  for axis in $PLUGIN_ACCEPTED_AXES; do
    [ -d "$dir/$axis" ] || continue
    for namedir in "$dir/$axis"/*/; do
      [ -d "$namedir" ] || continue
      printf '%s/%s\n' "$axis" "$(basename "$namedir")"
    done
  done
}

# Validate a fetched checkout and describe it. On success sets:
#   PLUGIN_DRIVERS   newline list of <axis>/<name>
#   PLUGIN_IGNORED   space list of top-level directories that are not installed
#   PLUGIN_EXEC      newline list of files that can run (shebang or exec bit)
#   PLUGIN_CONF_NAME / PLUGIN_CONF_DESC
# Refuses (exit 1) on anything that could not load or is not allowed.
_plugin_inspect() {
  local dir="$1" conf="$1/agmsg-plugin.conf" top axis name d f
  [ -f "$conf" ] && [ ! -L "$conf" ] \
    || _plugin_die "this repository has no agmsg-plugin.conf at its top level, so it is not an agmsg plugin"
  PLUGIN_CONF_NAME="$(_plugin_conf_get "$conf" name)"
  PLUGIN_CONF_DESC="$(_plugin_conf_get "$conf" description)"
  local min_core core_raw core_v min_v
  min_core="$(_plugin_conf_get "$conf" min_core)"
  if [ -n "$min_core" ]; then
    min_v="$(_plugin_semver "$min_core")" || _plugin_die "agmsg-plugin.conf has an unreadable min_core '$min_core'"
    core_raw="$(cat "$PLUGIN_ROOT/VERSION" 2>/dev/null || true)"
    core_v="$(_plugin_semver "$core_raw")" \
      || _plugin_die "this plugin needs agmsg $min_core or newer, but this installation's version ('${core_raw:-unknown}') cannot be read, so that cannot be checked"
    _plugin_semver_le "$min_v" "$core_v" \
      || _plugin_die "this plugin needs agmsg $min_core or newer; this installation is $core_v. Update agmsg first."
  fi

  PLUGIN_DRIVERS=""
  PLUGIN_IGNORED=""
  for top in "$dir"/*/; do
    [ -d "$top" ] || continue
    axis="$(basename "$top")"
    case " $PLUGIN_ACCEPTED_AXES " in
      *" $axis "*)
        [ ! -L "${top%/}" ] || _plugin_die "$axis/ is a symlink; refusing"
        for d in "$top"*/; do
          [ -d "$d" ] || continue
          name="$(basename "$d")"
          [ ! -L "${d%/}" ] || _plugin_die "$axis/$name is a symlink; refusing"
          case "$name" in
            ''|*[!a-z0-9-]*) _plugin_die "$axis/$name: driver names may use only lowercase letters, digits and '-'" ;;
          esac
          case "$axis" in
            ext-tools) [ -f "$d/tool.conf" ] || _plugin_die "$axis/$name has no tool.conf, so it could not load" ;;
            types)     [ -f "$d/type.conf" ] || _plugin_die "$axis/$name has no type.conf, so it could not load" ;;
          esac
          PLUGIN_DRIVERS="${PLUGIN_DRIVERS:+$PLUGIN_DRIVERS
}$axis/$name"
        done
        ;;
      *) PLUGIN_IGNORED="${PLUGIN_IGNORED:+$PLUGIN_IGNORED }$axis/" ;;
    esac
  done
  [ -n "$PLUGIN_DRIVERS" ] || _plugin_die "this repository adds no driver (expected ext-tools/<name>, terminals/<name> or types/<name>)"

  PLUGIN_EXEC=""
  for axis in $PLUGIN_ACCEPTED_AXES; do
    [ -d "$dir/$axis" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -L "$f" ]; then
        _plugin_die "${f#"$dir"/} is a symlink; plugins may not contain symlinks"
      elif [ -x "$f" ] || [ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ]; then
        PLUGIN_EXEC="${PLUGIN_EXEC:+$PLUGIN_EXEC
}${f#"$dir"/}"
      fi
    done < <(find "$dir/$axis" \( -type f -o -type l \) 2>/dev/null | sort)
  done
}

# One record from db/plugin-sources: prints the TSV line for <source-id>.
_plugin_record() {
  [ -f "$PLUGIN_SOURCES_FILE" ] || return 1
  awk -F'\t' -v id="$1" '$1 == id { print; found = 1; exit } END { exit !found }' \
    "$PLUGIN_SOURCES_FILE"
}

_plugin_record_add() {  # id spec sha dir
  mkdir -p "$(dirname "$PLUGIN_SOURCES_FILE")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$PLUGIN_SOURCES_FILE"
}

# Replace <file> with <content> atomically (an empty result just empties it).
# Callers hold the plugin lock; the rename keeps unlocked readers (the registry
# reads these files on every lookup) from ever seeing a half-written file.
_plugin_write_filtered() {  # file content
  if [ -z "$2" ]; then
    : > "$1"
  else
    # shellcheck disable=SC1091
    declare -F agmsg_write_atomic >/dev/null 2>&1 || . "$SCRIPT_DIR/lib/registry-lock.sh"
    agmsg_write_atomic "$1" "$2"
  fi
}

_plugin_record_drop() {  # id
  [ -f "$PLUGIN_SOURCES_FILE" ] || return 0
  _plugin_write_filtered "$PLUGIN_SOURCES_FILE" \
    "$(awk -F'\t' -v id="$1" '$1 != id' "$PLUGIN_SOURCES_FILE")"
}

# Drop the trust line for exactly <axis>/<name> at <path>; other paths for the
# same name (there should be none) are left alone.
_plugin_untrust_path() {
  local axis="$1" name="$2" path="$3" tf
  tf="$(agmsg_driver_trustfile)" || return 0
  [ -f "$tf" ] || return 0
  _plugin_write_filtered "$tf" \
    "$( { grep -vxF "$(printf '%s/%s\t%s' "$axis" "$name" "$path")" "$tf" || true; } )"
}

# Delete one commit directory of a source, only if it is where we put it.
_plugin_rm_commit_dir() {  # owner repo path
  local base="$PLUGIN_SOURCES_DIR/github/$1/$2" path="$3"
  case "$path" in
    "$base"/*) ;;
    *) _plugin_die "refusing to delete '$path': not inside $base" ;;
  esac
  _plugin_is_full_sha "$(basename "$path")" \
    || _plugin_die "refusing to delete '$path': not a commit directory"
  rm -rf -- "$path"
}

# Clashes of the checkout in $1 (owned by source-id $2, "" if new) with built-in
# drivers and with other places a driver of that name already lives. Sets
# CLASH_BUILTIN (newline list) and CLASH_OTHER (newline list with the owner named).
_plugin_clashes() {
  local dir="$1" self="$2" drv axis name rec id od
  CLASH_BUILTIN=""
  CLASH_OTHER=""
  while IFS= read -r drv; do
    [ -n "$drv" ] || continue
    if [ -d "$PLUGIN_ROOT/scripts/drivers/$drv" ]; then
      CLASH_BUILTIN="${CLASH_BUILTIN:+$CLASH_BUILTIN
}$drv"
    fi
    if [ -d "$PLUGIN_ROOT/plugins/$drv" ]; then
      CLASH_OTHER="${CLASH_OTHER:+$CLASH_OTHER
}$drv (already in $PLUGIN_ROOT/plugins/, placed by hand)"
    fi
    if [ -f "$PLUGIN_SOURCES_FILE" ]; then
      while IFS=$'\t' read -r id _ _ od _; do
        [ -n "$id" ] && [ "$id" != "$self" ] || continue
        if [ -d "$od/$drv" ]; then
          CLASH_OTHER="${CLASH_OTHER:+$CLASH_OTHER
}$drv (already provided by $id)"
        fi
      done < "$PLUGIN_SOURCES_FILE"
    fi
  done <<EOF
$(_plugin_drivers_in "$dir")
EOF
}

_plugin_explain_override() {  # owner repo builtin-list action ref
  {
    echo "agmsg plugin: $1/$2 would replace built-in driver(s):"
    printf '%s\n' "$3" | sed 's/^/  - /'
    echo
    echo "What this means:"
    echo "  - Every team on this machine that uses that driver would run this plugin's"
    echo "    code instead of the one shipped with agmsg."
    echo "  - Whatever that driver owns (message delivery, spawning, session handling)"
    echo "    can break, and fixes in agmsg updates will not reach it while it is overridden."
    echo "  - To go back, run: agmsg plugin remove $1/$2   (the built-in is restored)."
    echo
    echo "Nothing was installed. If you want this on purpose, run:"
    echo "  agmsg plugin ${4:-install} $1/$2${5:+@$5} --override"
  } >&2
}

# Print what is about to be installed/trusted.
_plugin_report() {  # source-id sha
  echo "Plugin source: $1"
  echo "Commit:        $2"
  [ -z "$PLUGIN_CONF_NAME" ] || echo "Name:          $PLUGIN_CONF_NAME"
  [ -z "$PLUGIN_CONF_DESC" ] || echo "Description:   $PLUGIN_CONF_DESC"
  echo
  echo "Drivers it adds:"
  local drv mark
  while IFS= read -r drv; do
    [ -n "$drv" ] || continue
    mark=""
    case "
$CLASH_BUILTIN
" in *"
$drv
"*) mark="   <- REPLACES THE BUILT-IN" ;; esac
    echo "  $drv$mark"
  done <<EOF
$PLUGIN_DRIVERS
EOF
  echo
  echo "Files that can run with your privileges once trusted:"
  if [ -n "$PLUGIN_EXEC" ]; then
    printf '%s\n' "$PLUGIN_EXEC" | sed 's/^/  /'
  else
    echo "  (none found)"
  fi
  if [ -n "$PLUGIN_IGNORED" ]; then
    echo
    echo "Ignored (not installed; only agmsg-plugin.conf and the driver directories are kept): $PLUGIN_IGNORED"
  fi
  echo
  echo "NOTICE: installing a plugin is at your own risk. agmsg does not review or sign"
  echo "plugins; trusting one lets its code run as you."
}

# Ask, or refuse to guess. $1 = the exact command that proceeds on purpose.
_plugin_confirm() {
  local proceed="$1" ans
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  if [ -t 0 ] && [ -t 1 ]; then
    printf '\nInstall and trust this plugin? [y/N] '
    read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) return 0 ;; esac
    echo "Cancelled. Nothing was installed."
    exit 1
  fi
  {
    echo
    echo "Needs confirmation: nothing was installed. Review the above, then run:"
    echo "  $proceed"
  } >&2
  exit 3
}

_plugin_parse_flags() {  # sets ASSUME_YES OVERRIDE and PLUGIN_SPEC_ARG
  ASSUME_YES=0
  OVERRIDE=0
  PLUGIN_SPEC_ARG=""
  local a
  for a in "$@"; do
    case "$a" in
      --yes|-y) ASSUME_YES=1 ;;
      --override) OVERRIDE=1 ;;
      -*) _plugin_die "unknown option '$a'" ;;
      *) [ -z "$PLUGIN_SPEC_ARG" ] || _plugin_die "unexpected argument '$a'"
         PLUGIN_SPEC_ARG="$a" ;;
    esac
  done
}

_plugin_trust_all() {  # dir
  local drv
  while IFS= read -r drv; do
    [ -n "$drv" ] || continue
    agmsg_driver_trust "${drv%%/*}" "${drv#*/}" "$1/$drv"
  done <<EOF
$(_plugin_drivers_in "$1")
EOF
}

_plugin_untrust_all() {  # dir
  local drv
  while IFS= read -r drv; do
    [ -n "$drv" ] || continue
    _plugin_untrust_path "${drv%%/*}" "${drv#*/}" "$1/$drv"
  done <<EOF
$(_plugin_drivers_in "$1")
EOF
}

# db/plugin-sources and db/trusted-plugins are rewritten read-filter-mv, so two
# commands on different sources could lose each other's change. Every mutation
# runs under one lock (the registry's mkdir lock, keyed on db/); downloading,
# the report and the confirmation stay outside it, and each command re-checks
# what it relied on once it holds the lock.
_plugin_lock() {
  mkdir -p "$PLUGIN_ROOT/db"
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib/registry-lock.sh"
  agmsg_lock_acquire "$PLUGIN_ROOT/db" \
    || _plugin_die "could not lock the plugin records (another plugin command may be running)"
  # acquire installs its own EXIT trap; keep staging cleanup alongside it.
  trap '_plugin_stage_cleanup; agmsg_lock_release' EXIT
}

_plugin_unlock() {
  agmsg_lock_release
  trap _plugin_stage_cleanup EXIT
}

# Keep only agmsg-plugin.conf and the accepted driver directories of the staged
# tree, so what lands on disk is what the report said. Removes only direct
# children of the staging checkout this process made.
_plugin_prune_ignored() {  # dir
  local entry name
  case "$1" in "$PLUGIN_STAGE"/?*) ;; *) _plugin_die "refusing to prune outside the staging directory" ;; esac
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="$(basename "$entry")"
    [ "$name" != agmsg-plugin.conf ] || continue
    case " $PLUGIN_ACCEPTED_AXES " in *" $name "*) [ -d "$entry" ] && [ ! -L "$entry" ] && continue ;; esac
    if [ -d "$entry" ] && [ ! -L "$entry" ]; then rm -rf -- "$entry"; else rm -f -- "$entry"; fi
  done
}

# Refuse on a clash with another source / hand-placed driver, and on a new
# built-in replacement without --override. Run before the report and again under
# the lock. $4 = install|update, $5 = ref for the printed command, $6 = built-ins
# already accepted (update only).
_plugin_check_clashes() {  # id dir owner repo action ref accepted-dir
  local id="$1" dir="$2" owner="$3" repo="$4" action="$5" ref="$6" accepted="${7:-}" self="" drv new=""
  [ "$action" != update ] || self="$id"
  _plugin_clashes "$dir" "$self"
  if [ -n "$CLASH_OTHER" ]; then
    {
      echo "agmsg plugin: $id clashes with an existing driver of the same name:"
      printf '%s\n' "$CLASH_OTHER" | sed 's/^/  - /'
      echo "Nothing was changed. Remove the other one first if you want to switch."
    } >&2
    exit 1
  fi
  while IFS= read -r drv; do
    [ -n "$drv" ] || continue
    [ -n "$accepted" ] && [ -d "$accepted/$drv" ] && continue
    new="${new:+$new
}$drv"
  done <<EOF
$CLASH_BUILTIN
EOF
  if [ -n "$new" ] && [ "$OVERRIDE" -ne 1 ]; then
    _plugin_explain_override "$owner" "$repo" "$new" "$action" "$ref"
    exit 1
  fi
}

_plugin_cmd_install() {
  _plugin_parse_flags "$@"
  [ -n "$PLUGIN_SPEC_ARG" ] || _plugin_die "usage: plugin.sh install <owner>/<repo>[@<ref>] [--yes] [--override]"
  _plugin_parse_spec "$PLUGIN_SPEC_ARG"
  local owner="$SPEC_OWNER" repo="$SPEC_REPO" ref="$SPEC_REF" id rec
  id="github/$owner/$repo"
  if rec="$(_plugin_record "$id")"; then
    _plugin_die "$id is already installed (commit $(printf '%s' "$rec" | cut -f3)). Use 'plugin.sh update $owner/$repo', or 'plugin.sh remove $owner/$repo' first."
  fi
  _plugin_fetch "$owner" "$repo" "$ref"
  _plugin_inspect "$PLUGIN_SRC"
  _plugin_prune_ignored "$PLUGIN_SRC"
  _plugin_check_clashes "$id" "$PLUGIN_SRC" "$owner" "$repo" install "$ref"
  _plugin_report "$id" "$PLUGIN_SHA"
  _plugin_confirm "agmsg plugin install $owner/$repo@$PLUGIN_SHA --yes$([ "$OVERRIDE" -eq 1 ] && printf ' --override')"
  local final="$PLUGIN_SOURCES_DIR/github/$owner/$repo/$PLUGIN_SHA"
  _plugin_lock
  # Everything above ran without the lock; confirm it still holds.
  if rec="$(_plugin_record "$id")"; then
    _plugin_die "$id was installed by another command while this one waited (commit $(printf '%s' "$rec" | cut -f3))"
  fi
  _plugin_check_clashes "$id" "$PLUGIN_SRC" "$owner" "$repo" install "$ref"
  [ ! -e "$final" ] || _plugin_die "$final already exists; run 'plugin.sh remove $owner/$repo' and retry"
  mkdir -p "$(dirname "$final")"
  mv "$PLUGIN_SRC" "$final"
  _plugin_record_add "$id" "$owner/$repo${ref:+@$ref}" "$PLUGIN_SHA" "$final"
  _plugin_trust_all "$final"
  _plugin_unlock
  echo
  echo "Installed $id at $PLUGIN_SHA and trusted its drivers."
}

# Files that differ between two checkouts, as "A|M|D <path>".
_plugin_changes() {  # old new
  local f
  while IFS= read -r f; do
    if [ ! -e "$1/$f" ] && [ ! -L "$1/$f" ]; then echo "A $f"
    elif ! cmp -s "$1/$f" "$2/$f"; then echo "M $f"; fi
  done < <(cd "$2" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort)
  while IFS= read -r f; do
    if [ ! -e "$2/$f" ] && [ ! -L "$2/$f" ]; then echo "D $f"; fi
  done < <(cd "$1" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort)
}

_plugin_cmd_update() {
  _plugin_parse_flags "$@"
  [ -n "$PLUGIN_SPEC_ARG" ] || _plugin_die "usage: plugin.sh update <owner>/<repo>[@<ref>] [--yes] [--override]"
  _plugin_parse_spec "$PLUGIN_SPEC_ARG"
  local owner="$SPEC_OWNER" repo="$SPEC_REPO" ref="$SPEC_REF" id rec old_spec old_sha old_dir
  id="github/$owner/$repo"
  rec="$(_plugin_record "$id")" || _plugin_die "$id is not installed (use 'plugin.sh install $owner/$repo')"
  old_spec="$(printf '%s' "$rec" | cut -f2)"
  old_sha="$(printf '%s' "$rec" | cut -f3)"
  old_dir="$(printf '%s' "$rec" | cut -f4)"
  # No ref given: follow the one recorded at install time.
  if [ -z "$ref" ]; then
    case "$old_spec" in *@*) ref="${old_spec#*@}" ;; esac
  fi
  _plugin_fetch "$owner" "$repo" "$ref"
  if [ "$PLUGIN_SHA" = "$old_sha" ]; then
    echo "$id is already up to date (commit $old_sha)."
    return 0
  fi
  _plugin_inspect "$PLUGIN_SRC"
  _plugin_prune_ignored "$PLUGIN_SRC"
  # A built-in the old commit already replaced was accepted at install time;
  # only a NEW replacement needs --override.
  _plugin_check_clashes "$id" "$PLUGIN_SRC" "$owner" "$repo" update "$ref" "$old_dir"
  echo "Updating $id"
  echo "  from $old_sha"
  echo "    to $PLUGIN_SHA"
  echo
  echo "Changed files:"
  _plugin_changes "$old_dir" "$PLUGIN_SRC" | sed 's/^/  /'
  echo
  _plugin_report "$id" "$PLUGIN_SHA"
  _plugin_confirm "agmsg plugin update $owner/$repo@$PLUGIN_SHA --yes$([ "$OVERRIDE" -eq 1 ] && printf ' --override')"
  local final="$PLUGIN_SOURCES_DIR/github/$owner/$repo/$PLUGIN_SHA"
  _plugin_lock
  # Re-check under the lock: the source must still be at the commit we compared.
  rec="$(_plugin_record "$id")" || _plugin_die "$id was removed by another command while this one waited"
  [ "$(printf '%s' "$rec" | cut -f3)" = "$old_sha" ] \
    || _plugin_die "$id was changed by another command while this one waited; run the update again"
  _plugin_check_clashes "$id" "$PLUGIN_SRC" "$owner" "$repo" update "$ref" "$old_dir"
  [ ! -e "$final" ] || _plugin_die "$final already exists; run 'plugin.sh remove $owner/$repo' and retry"
  mkdir -p "$(dirname "$final")"
  mv "$PLUGIN_SRC" "$final"
  _plugin_untrust_all "$old_dir"
  _plugin_record_drop "$id"
  _plugin_record_add "$id" "$owner/$repo${ref:+@$ref}" "$PLUGIN_SHA" "$final"
  _plugin_trust_all "$final"
  _plugin_rm_commit_dir "$owner" "$repo" "$old_dir"
  _plugin_unlock
  echo
  echo "Updated $id to $PLUGIN_SHA; the previous commit was removed."
}

_plugin_cmd_remove() {
  _plugin_parse_flags "$@"
  [ -n "$PLUGIN_SPEC_ARG" ] || _plugin_die "usage: plugin.sh remove <owner>/<repo>"
  case "$PLUGIN_SPEC_ARG" in *@*) _plugin_die "remove takes <owner>/<repo> without a ref" ;; esac
  _plugin_parse_spec "$PLUGIN_SPEC_ARG"
  local owner="$SPEC_OWNER" repo="$SPEC_REPO" id rec dir drv back=""
  id="github/$owner/$repo"
  _plugin_lock
  rec="$(_plugin_record "$id")" || _plugin_die "$id is not installed"
  dir="$(printf '%s' "$rec" | cut -f4)"
  while IFS= read -r drv; do
    [ -n "$drv" ] || continue
    if [ -d "$PLUGIN_ROOT/scripts/drivers/$drv" ]; then
      back="${back:+$back, }$drv"
    fi
  done <<EOF
$(_plugin_drivers_in "$dir")
EOF
  _plugin_untrust_all "$dir"
  _plugin_record_drop "$id"
  rm -rf -- "$PLUGIN_SOURCES_DIR/github/$owner/$repo"
  rmdir "$PLUGIN_SOURCES_DIR/github/$owner" 2>/dev/null || true
  _plugin_unlock
  echo "Removed $id."
  if [ -n "$back" ]; then
    echo "The built-in driver(s) are back in use: $back"
  fi
}

# Source-id and short commit of the installed source that owns <dir>, or "-".
_plugin_source_of() {
  local dir="$1" id sha od
  if [ -f "$PLUGIN_SOURCES_FILE" ]; then
    while IFS=$'\t' read -r id _ sha od _; do
      [ -n "$od" ] || continue
      case "$dir" in "$od"/*) printf '%s\t%s' "$id" "$(printf '%.12s' "$sha")"; return 0 ;; esac
    done < "$PLUGIN_SOURCES_FILE"
  fi
  printf '%s\t%s' "-" "-"
}

# Emit "<kind>\t<axis>\t<name>\t<dir>" for every dir-based driver across all
# search bases (a driver is a directory <base>/<axis>/<name>/).
_plugin_enumerate() {
  local kind base axisdir axis namedir name
  while IFS=$'\t' read -r kind base; do
    [ -d "$base" ] || continue
    for axisdir in "$base"/*/; do
      [ -d "$axisdir" ] || continue
      axis="$(basename "$axisdir")"
      # plugins/sources/ holds installed plugin checkouts; each is its own base
      # (db/plugin-sources), not an axis.
      [ "$axis" != sources ] || continue
      for namedir in "$axisdir"*/; do
        [ -d "$namedir" ] || continue
        name="$(basename "$namedir")"
        printf '%s\t%s\t%s\t%s\n' "$kind" "$axis" "$name" "${namedir%/}"
      done
    done
  done <<EOF
$(agmsg_driver_bases)
EOF
}

# Resolve a user <ref> to a single EXTERNAL driver, echoed as "<axis>\t<name>\t<dir>".
# Bare names match across axes; ambiguity is an error that lists the candidates.
_plugin_resolve_external() {
  local ref="$1" want_axis="" want_name matches count
  case "$ref" in
    */*) want_axis="${ref%%/*}"; want_name="${ref#*/}" ;;
    *)   want_name="$ref" ;;
  esac
  matches="$(_plugin_enumerate | awk -F'\t' -v a="$want_axis" -v n="$want_name" \
    '$1=="external" && $3==n && (a=="" || $2==a) { print $2"\t"$3"\t"$4 }')"
  count="$(printf '%s' "$matches" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    echo "agmsg plugin: no external driver matches '$ref'" >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "agmsg plugin: '$ref' is ambiguous across axes:" >&2
    printf '%s\n' "$matches" | awk -F'\t' '{print "  "$1"/"$2}' >&2
    echo "       qualify it, e.g. agmsg plugin $ACTION $(printf '%s' "$matches" | head -1 | awk -F'\t' '{print $1"/"$2}')" >&2
    return 1
  fi
  printf '%s\n' "$matches"
}

case "$ACTION" in
  list)
    printf '%-26s %-11s %-28s %-13s %s\n' "AXIS/NAME" "STATE" "SOURCE" "COMMIT" "PATH"
    _plugin_enumerate | while IFS=$'\t' read -r kind axis name dir; do
      if [ "$kind" = builtin ]; then
        state="builtin"
      elif agmsg_driver_is_trusted "$axis" "$name" "$dir"; then
        state="trusted"
      else
        state="UNTRUSTED"
      fi
      IFS=$'\t' read -r src commit <<<"$(_plugin_source_of "$dir")"
      printf '%-26s %-11s %-28s %-13s %s\n' "$axis/$name" "$state" "$src" "$commit" "$dir"
    done
    ;;
  install|add) _plugin_cmd_install "$@" ;;
  update)      _plugin_cmd_update "$@" ;;
  remove|uninstall) _plugin_cmd_remove "$@" ;;
  trust)
    ref="${1:?Usage: plugin.sh trust <axis/name|name>}"
    res="$(_plugin_resolve_external "$ref")" || exit 1
    IFS=$'\t' read -r axis name dir <<<"$res"
    _plugin_lock
    agmsg_driver_trust "$axis" "$name" "$dir"
    _plugin_unlock
    echo "Trusted $axis/$name -> $dir"
    ;;
  untrust)
    ref="${1:?Usage: plugin.sh untrust <axis/name|name>}"
    case "$ref" in
      */*) axis="${ref%%/*}"; name="${ref#*/}" ;;
      *)   res="$(_plugin_resolve_external "$ref")" || exit 1
           IFS=$'\t' read -r axis name _ <<<"$res" ;;
    esac
    _plugin_lock
    agmsg_driver_untrust "$axis" "$name"
    _plugin_unlock
    echo "Untrusted $axis/$name"
    ;;
  *)
    echo "Usage: agmsg plugin list|trust <ref>|untrust <ref>|install <owner>/<repo>[@<ref>]|update <owner>/<repo>|remove <owner>/<repo>" >&2
    exit 1
    ;;
esac
