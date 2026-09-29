#!/usr/bin/env bash
# install-manifest.sh — the install completion record (agmsgd beta).
#
# run/install-manifest.json names one completed install: which generation it
# is (install_id, gen), what version it shipped, and the path+sha256 digest
# of every file under scripts/ at the moment it was written. Its presence,
# absence, and .prev sibling are how a stale generation and a crashed
# mid-update are told apart -- see agmsg_install_manifest_next_gen.
#
# install_id itself is NOT this file's concern -- see install-db.sh.
#
# Required caller-set variable: none. Sources scripts/lib/sqlpath.sh (for
# agmsg_sql_readfile_path), scripts/lib/sqlite-output.sh (for normalized
# sqlite3 output), and scripts/lib/hash.sh (for agmsg_sha256) if not already
# loaded; all are small, dependency-light files, not the whole of storage.sh.

[ -n "${_AGMSG_INSTALL_MANIFEST_SH:-}" ] && return 0
_AGMSG_INSTALL_MANIFEST_SH=1

_agmsg_install_manifest_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if ! declare -F agmsg_sql_readfile_path >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$_agmsg_install_manifest_dir/sqlpath.sh"
fi
if ! declare -F agmsg_sqlite_capture >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$_agmsg_install_manifest_dir/sqlite-output.sh"
fi
if ! declare -F agmsg_sha256 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$_agmsg_install_manifest_dir/hash.sh"
fi
unset _agmsg_install_manifest_dir

# Same '' -> '' doubling every other SQL-string-literal caller in this
# codebase uses (leave.sh's own _agmsg_sqlesc, storage.sh's agmsg_sqlesc).
# Defined locally rather than pulling in storage.sh, which this file has no
# other reason to depend on.
_agmsg_install_manifest_sqlesc() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Prints the NEXT gen for the completion record install.sh is about to
# write: the current manifest's gen + 1, or a valid .prev's if the current
# manifest is absent or unreadable, or 1 only when neither file exists.
#
# install_id is not this function's concern: install.db's meta row is the
# source of truth, and the manifest only carries a copy of it.
#
# install.sh reads the current generation after acquiring the operation
# lock, then writes the next generation; it has no earlier observation that
# could have become stale while waiting for the lock.
_agmsg_install_manifest_read_gen() {   # <manifest_path>
  local path="${1:-}" sqlpath gen
  [ -f "$path" ] || return 1
  sqlpath="$(agmsg_sql_readfile_path "$path")" || return 1
  gen="$(agmsg_sqlite_capture :memory: "SELECT json_extract(CAST(readfile('$sqlpath') AS TEXT), '\$.gen');")" || return 1
  case "$gen" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # Keep the value inside Bash's portable signed arithmetic range.
  [ "${#gen}" -le 18 ] || return 1
  [ "$gen" -gt 0 ] || return 1
  printf '%s\n' "$gen"
}

agmsg_install_manifest_next_gen() {   # <manifest_path>
  local manifest_path="${1:-}" prior_gen="" current_present=false prev_present=false
  [ -n "$manifest_path" ] || return 1
  { [ -e "$manifest_path" ] || [ -L "$manifest_path" ]; } && current_present=true
  { [ -e "$manifest_path.prev" ] || [ -L "$manifest_path.prev" ]; } && prev_present=true

  if [ "$current_present" = true ] && prior_gen="$(_agmsg_install_manifest_read_gen "$manifest_path")"; then
    :
  elif [ "$prev_present" = true ] && prior_gen="$(_agmsg_install_manifest_read_gen "$manifest_path.prev")"; then
    :
  elif [ "$current_present" = false ] && [ "$prev_present" = false ]; then
    printf '1\n'
    return 0
  else
    echo "agmsg: install manifest and its previous copy are unreadable; refusing to reuse a generation" >&2
    return 1
  fi

  printf '%s\n' "$((prior_gen + 1))"
}

# Renames the current manifest to its own .prev, so a half-done copy is
# never photographed as "complete" -- must run BEFORE the copy step, every
# time. A missing manifest (first install) is not an error: there is
# nothing to rotate. Overwrites any existing .prev -- an install that
# crashed twice in a row without ever completing in between only ever needs
# the most recent attempt's generation, which agmsg_install_manifest_next_gen
# already read before this runs.
agmsg_install_manifest_rotate_prev() {   # <manifest_path>
  local manifest_path="${1:-}"
  [ -n "$manifest_path" ] || return 1
  if [ -f "$manifest_path" ]; then
    if _agmsg_install_manifest_read_gen "$manifest_path" >/dev/null; then
      mv -f "$manifest_path" "$manifest_path.prev"
      return $?
    fi
  elif [ ! -e "$manifest_path" ] && [ ! -L "$manifest_path" ]; then
    [ -e "$manifest_path.prev" ] || [ -L "$manifest_path.prev" ] || return 0
  fi

  if _agmsg_install_manifest_read_gen "$manifest_path.prev" >/dev/null; then
    # Preserve the last readable completion record instead of replacing it
    # with an unreadable current file.
    rm -f "$manifest_path"
    return $?
  fi
  echo "agmsg: cannot rotate an unreadable install manifest without a readable previous copy" >&2
  return 1
}

# Writes the completion record for a just-finished copy: every file under
# <scripts_dir>, its path (relative to <scripts_dir>'s own parent, i.e.
# "scripts/...") and sha256 digest, plus <version>, <install_id>, <gen>,
# <bootstrap_version> (the fixed shape agmsgd and
# agmsgd-launch.sh both carry, a SEPARATE version number from <version>/
# <gen> that only bumps when that fixed contract itself changes; the real
# entrypoint, a later PR, checks this against its own embedded constant
# under the operation lock and exits 75 on a mismatch), and the write's own
# timestamp. Atomic (tmpfile + rename): a reader never sees a partially-
# written manifest. Symlinks are never listed (`find -type f` only) --
# deliberately: the startup-side reader treats ANY symlink under scripts/ as
# a match failure on its own, so a writer that skipped listing one is
# consistent with that, not a gap in it.
agmsg_install_manifest_write() {   # <scripts_dir> <manifest_path> <version> <install_id> <gen> <bootstrap_version>
  # ${N:-}, not bare $N: this function's own caller has been seen, under
  # heavy load on this shared machine, to somehow reach this call with fewer
  # than 6 positional arguments -- root cause not yet pinned down (not
  # reproducible in isolation). A bare $6 there turns that into an unbound-
  # variable crash under set -u; reading it as "" instead lets the
  # gen/bootstrap_version validation below report it as an ordinary, clearly
  # worded refusal -- no manifest written, .prev left in place -- same as
  # any other input this function already rejects.
  local scripts_dir="${1:-}" manifest_path="${2:-}" version="${3:-}" install_id="${4:-}" gen="${5:-}" bootstrap_version="${6:-}"
  local entry rel digest created_at db tmp json

  if [ -z "$scripts_dir" ] || [ -z "$manifest_path" ] || [ -z "$install_id" ]; then
    echo "agmsg: install manifest write called with a missing argument (scripts_dir/manifest_path/install_id); refusing" >&2
    return 1
  fi

  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  agmsg_sha256_usable || {
    echo "agmsg: no usable sha256 tool found; refusing to write the install manifest" >&2
    return 1
  }
  case "$gen" in
    ''|*[!0-9]*)
      echo "agmsg: install manifest gen must be a positive integer, got: $gen" >&2
      return 1
      ;;
  esac
  case "$bootstrap_version" in
    ''|*[!0-9]*)
      echo "agmsg: install manifest bootstrap_version must be a positive integer, got: $bootstrap_version" >&2
      return 1
      ;;
  esac

  db="$(mktemp)" || return 1
  if ! sqlite3 "$db" "CREATE TABLE files (path TEXT PRIMARY KEY, digest TEXT NOT NULL);" 2>/dev/null; then
    rm -f "$db"
    return 1
  fi

  while IFS= read -r -d '' entry; do
    rel="${entry#./}"
    digest="$(agmsg_sha256 < "$scripts_dir/$rel")" || { rm -f "$db"; return 1; }
    if ! sqlite3 "$db" \
      "INSERT INTO files (path, digest) VALUES ('scripts/$(_agmsg_install_manifest_sqlesc "$rel")', '$digest');" \
      2>/dev/null; then
      rm -f "$db"
      return 1
    fi
  done < <(cd "$scripts_dir" && find . -type f -print0)

  json="$(agmsg_sqlite_capture "$db" "
    SELECT json_object(
      'install_id', '$(_agmsg_install_manifest_sqlesc "$install_id")',
      'gen', $gen,
      'version', '$(_agmsg_install_manifest_sqlesc "$version")',
      'bootstrap_version', $bootstrap_version,
      'created_at', '$(_agmsg_install_manifest_sqlesc "$created_at")',
      'digest_algo', 'sha256',
      'files', (SELECT json_group_array(json_object('path', path, 'digest', digest))
                  FROM (SELECT path, digest FROM files ORDER BY path))
    );")"
  rm -f "$db"
  [ -n "$json" ] || return 1

  if [ "${AGMSG_INSTALL_OP_ACTIVE:-false}" = true ] && ! agmsg_install_op_require; then
    return 1
  fi
  tmp="$(mktemp "$(dirname "$manifest_path")/.$(basename "$manifest_path").XXXXXX")" || return 1
  if ! printf '%s\n' "$json" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if [ "${AGMSG_INSTALL_OP_ACTIVE:-false}" = true ] && ! agmsg_install_op_require; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$manifest_path"
}
