#!/usr/bin/env bash
# Resolve a Node binary to run codex-bridge.js.
#
# The bridge is a Node program, but a version-manager Node (nvm / fnm / volta) is
# only placed on PATH by an interactive shell's init. A bridge launched from a
# non-interactive context — e.g. a spawn boot script — therefore cannot find it
# via the `#!/usr/bin/env node` shebang, and Codex monitor silently never starts.
#
# Search order: an explicit override (AGMSG_NODE, then AGMSG_CODEX_NODE for
# back-compat) → active PATH (honours a loaded version manager) → common
# version-manager / system locations (newest nvm/fnm version first). Falls back to
# bare "node" so the behaviour is never worse than relying on PATH today (the
# caller still fails the same way, with the existing delivery.sh preflight
# warning). See #170.
agmsg_resolve_node() {
  # An explicit override is authoritative — return it verbatim, even if it does
  # not exist, so the caller's preflight surfaces a misconfigured value rather
  # than silently falling back. AGMSG_NODE is the canonical name; AGMSG_CODEX_NODE
  # is kept for back-compat with the delivery.sh preflight.
  if [ -n "${AGMSG_NODE:-}" ]; then
    printf '%s\n' "$AGMSG_NODE"
    return 0
  fi
  if [ -n "${AGMSG_CODEX_NODE:-}" ]; then
    printf '%s\n' "$AGMSG_CODEX_NODE"
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    command -v node
    return 0
  fi

  # Glob the version-manager dirs directly in the for-list (expands in both bash
  # and zsh, unlike an unquoted glob held in a variable). Keep the newest match
  # by version sort. Unmatched globs iterate once as the literal pattern, which
  # the -x test rejects.
  local n best=""
  for n in \
    "$HOME"/.nvm/versions/node/*/bin/node \
    "$HOME"/.fnm/node-versions/*/installation/bin/node \
    "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node; do
    [ -x "$n" ] || continue
    if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best" "$n" | sort -V | tail -1)" = "$n" ]; then
      best="$n"
    fi
  done
  if [ -n "$best" ]; then
    printf '%s\n' "$best"
    return 0
  fi

  for n in "$HOME/.volta/bin/node" /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    if [ -x "$n" ]; then
      printf '%s\n' "$n"
      return 0
    fi
  done

  printf '%s\n' "node"
  return 0
}
