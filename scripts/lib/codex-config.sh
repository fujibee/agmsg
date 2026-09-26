#!/usr/bin/env bash
# codex-config.sh — the set of Codex config.toml paths an agmsg install
# writes writable_roots entries to, kept in exactly one place so a writer
# (install.sh) and a cleaner (uninstall.sh) cannot silently disagree about
# which files exist. #1469 found exactly that: install.sh wrote to both
# $HOME/.codex/config.toml and $CODEX_HOME/config.toml when CODEX_HOME was
# set and different from the default, but uninstall.sh only ever cleaned the
# first -- so an uninstall on a machine with CODEX_HOME set (a Codex profile)
# left that second file's entries behind, unremoved and unreported.
#
# Codex resolves its own config against $CODEX_HOME (default ~/.codex), not
# always ~/.codex -- a machine running more than one Codex identity/account
# sets CODEX_HOME per profile. The Codex desktop app (codex-app) uses the
# plain ~/.codex default regardless of a shell's CODEX_HOME. So when
# CODEX_HOME differs from the default, BOTH surfaces need the same
# treatment; touching only one leaves the other silently stale, whichever
# direction (write or clean) that touch is.

# Prints one Codex config.toml path per line: always $HOME/.codex/config.toml,
# plus $CODEX_HOME/config.toml too when CODEX_HOME is set and resolves to a
# path different from the default.
agmsg_codex_config_paths() {
  local default_config="$HOME/.codex/config.toml"
  printf '%s\n' "$default_config"
  if [ -n "${CODEX_HOME:-}" ] && [ "$CODEX_HOME/config.toml" != "$default_config" ]; then
    printf '%s\n' "$CODEX_HOME/config.toml"
  fi
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
  local writable_paths=("$skill_dir/db" "$skill_dir/teams" "$skill_dir/run" "$skill_dir/ext-tools")
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
