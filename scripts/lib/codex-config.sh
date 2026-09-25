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
