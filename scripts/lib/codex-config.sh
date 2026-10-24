#!/usr/bin/env bash
# Codex config selection is shared by installation, cleanup, and notices.
# An explicit CODEX_HOME isolates the profile: never also edit the default
# profile, including when testing a separate install (#1718).

# Prints the active profile config, falling back to Codex's default.
agmsg_codex_config_paths() {
  printf '%s/config.toml\n' "${CODEX_HOME:-$HOME/.codex}"
}

# Use the same native Windows path spelling for insertion and removal.
agmsg_codex_native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1" 2>/dev/null || printf '%s\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

# Prints one writable_roots path per line for <skill_dir>: db/, teams/, run/,
# ext-tools/ under it, in the SAME form install.sh's configure_codex_sandbox
# writes into Codex's config.toml. On Windows (MSYS2/Git Bash), $skill_dir is
# in MSYS form (/c/Users/...); Codex is a native Windows binary whose Rust
# path resolution cannot parse that (it resolves to a phantom C:\c\Users\...),
# so when cygpath is on PATH each path is converted to the mixed C:/Users/...
# form both the shell and Codex accept, before anything writes or greps for
# it. Kept in one place, alongside agmsg_codex_config_paths, so the writer
# (install.sh) and the reader (agmsg_codex_writable_roots_notice below) can
# never disagree about which form a path is in -- disagreeing here is exactly
# what made the notice fire "missing" forever on Windows even right after a
# correct `install --update` (#1483 review).
agmsg_codex_writable_paths() {
  local skill_dir="$1"
  local paths=("$skill_dir/db" "$skill_dir/teams" "$skill_dir/run" "$skill_dir/ext-tools")
  local i
  for i in "${!paths[@]}"; do
    paths[$i]="$(agmsg_codex_native_path "${paths[$i]}")"
  done
  printf '%s\n' "${paths[@]}"
}

# agmsg_codex_writable_roots_notice <skill_dir>
#
# Prints ONE line to stdout when a Codex config this install would write to
# (agmsg_codex_config_paths) exists but is missing any of this install's
# writable_roots entries (db/, teams/, run/, ext-tools/ under <skill_dir>) --
# the state left behind when Codex is installed AFTER agmsg (#1477):
# install.sh's own configure_codex_sandbox only ever writes these entries
# into a Codex config that already exists at install time, and nothing later
# adds them or says anything is missing. A sandboxed Codex session then has
# its writes under <skill_dir> silently refused.
#
# Read-only, on purpose: never edits the Codex config from here. That write
# may itself be refused from inside the same sandboxed session whose
# missing roots this is reporting, and rewriting a user's config out from
# under them without being asked is a separate, larger step than naming the
# fix. `install.sh --update` (or `npx agmsg install --update`) is the actual
# fix; this only says so, once, when it is true.
#
# Checked the SAME way configure_codex_sandbox itself decides "missing" --
# a literal `grep -q` for each path against the config file's raw text --
# so this can never disagree with what the installer would consider already
# done.
#
# A config file that does not exist at all is not reported: that is Codex
# not being installed (yet) on this profile, not this install's own gap
# (matches configure_codex_sandbox's own `[ -f "$code_config" ] || return 0`).
agmsg_codex_writable_roots_notice() {
  local skill_dir="$1"
  local writable_paths=()
  local _wp
  while IFS= read -r _wp; do
    writable_paths+=("$_wp")
  done < <(agmsg_codex_writable_paths "$skill_dir")
  unset _wp
  local cfg p incomplete
  while IFS= read -r cfg; do
    [ -f "$cfg" ] || continue
    incomplete=0
    for p in "${writable_paths[@]}"; do
      if ! grep -q "$p" "$cfg" 2>/dev/null; then
        incomplete=1
        break
      fi
    done
    if [ "$incomplete" -eq 1 ]; then
      printf "agmsg: Codex cannot write agmsg's data yet -- run 'npx agmsg install --update' once\n"
      return 0
    fi
  done < <(agmsg_codex_config_paths)
}
