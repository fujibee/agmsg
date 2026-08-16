#!/usr/bin/env bash
# Which CLI is this? Detection lives here, not in whoami.sh, because whoami.sh
# is not the only caller that needs the answer (#783/#801): windows/dispatch.sh
# hands the type to join.sh, reset.sh, delivery.sh and identities.sh, and a
# default guessed there registers a real agent under a type nobody chose.
#
# Sourcing this requires lib/type-registry.sh and lib/compat.sh to be sourced
# first; it reads agmsg_known_types / agmsg_type_get / compat_get_comm /
# compat_get_ppid and deliberately does not source them itself, so a caller
# cannot end up with two copies of the registry's state.

# Auto-detect CLI type from environment variables and the process tree, driven by
# the per-type manifests' `detect=` (env-var names) and `detect_proc=` (process
# name globs) keys — no hardcoded type list lives here.
agmsg_detect_cli_type() {
  # `detect=` / `detect_proc=` tokens are split with `read -ra` (IFS word-split,
  # NO pathname expansion) rather than an unquoted `for x in $list` — a file in
  # the caller's cwd matching a pattern like `claude-*` must not glob-eat the
  # pattern. (Plain `set -f` can't be used here: agmsg_known_types discovers types
  # via a `*/` glob that must keep working.)

  # 1. Environment variables. Sorted registry order preserves the historical
  # precedence: a runtime's own session vars (CLAUDE_CODE_SESSION_ID, CODEX_*) are
  # checked before the GEMINI_* family, which users also set for the SDK without
  # the CLI. `detect=explicit` (and types with no detect=) are never auto-detected.
  local _t _v _detect _toks
  while IFS= read -r _t; do
    [ -n "$_t" ] || continue
    _detect="$(agmsg_type_get "$_t" detect)"
    if [ -z "$_detect" ] || [ "$_detect" = "explicit" ]; then
      continue
    fi
    read -ra _toks <<<"$_detect"
    for _v in "${_toks[@]}"; do
      if [ -n "${!_v:-}" ]; then
        echo "$_t"
        return 0
      fi
    done
  done <<EOF
$(agmsg_known_types | sort -u)
EOF

  # 2. Process-tree detection via each type's `detect_proc=` name globs. Walk up
  # from this process; at each ancestor the first type whose glob matches wins
  # (the globs are disjoint, so order within a level is irrelevant).
  local pid=$$ max_depth=10 depth=0 proc_name _pats _pat
  while [ $depth -lt $max_depth ] && [ "$pid" != "1" ] && [ -n "$pid" ]; do
    proc_name=$(compat_get_comm "$pid" 2>/dev/null || true)
    if [ -n "$proc_name" ]; then
      while IFS= read -r _t; do
        [ -n "$_t" ] || continue
        _pats="$(agmsg_type_get "$_t" detect_proc)"
        [ -n "$_pats" ] || continue
        read -ra _toks <<<"$_pats"
        for _pat in "${_toks[@]}"; do
          # $_pat is intentionally an UNQUOTED glob pattern matched against the
          # process name; read -ra already kept it out of pathname expansion.
          # shellcheck disable=SC2254
          case "$proc_name" in
            $_pat) echo "$_t"; return 0 ;;
          esac
        done
      done <<EOF
$(agmsg_known_types | sort -u)
EOF
    fi

    # Move to parent process
    pid=$(compat_get_ppid "$pid" 2>/dev/null || true)
    depth=$((depth + 1))
  done

  # Default fallback. A LITERAL, and the one name here that no registry lookup
  # stands behind — which is why whoami.sh validates only a type the caller
  # asked for, and why nothing may treat this function's output as a member of
  # agmsg_known_types.
  echo "claude-code"
}
