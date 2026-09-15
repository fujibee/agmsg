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
# the per-type manifests' `detect=` (env-var names), `detect_fallback=` (weak
# env-var names), and `detect_proc=` (process name globs) keys — no hardcoded
# type list lives here.

# Print known types in detection priority order. Lower numeric priority wins;
# missing or malformed values use the neutral default. The type name breaks
# ties so existing deterministic ordering remains intact for equal priorities.
_agmsg_detect_order() {
  local _t _priority
  while IFS= read -r _t; do
    [ -n "$_t" ] || continue
    _priority="$(agmsg_type_get "$_t" priority 50)"
    case "$_priority" in
      ''|*[!0-9]*) _priority=50 ;;
    esac
    printf '%s\t%s\n' "$_priority" "$_t"
  done < <(agmsg_known_types | sort -u) |
    LC_ALL=C sort -n -k1,1 -k2,2 | cut -f2-
}

agmsg_detect_cli_type() {
  # `detect=` / `detect_proc=` tokens are split with `read -ra` (IFS word-split,
  # NO pathname expansion) rather than an unquoted `for x in $list` — a file in
  # the caller's cwd matching a pattern like `claude-*` must not glob-eat the
  # pattern. (Plain `set -f` can't be used here: agmsg_known_types discovers types
  # via a `*/` glob that must keep working.)

  # 1. Strong environment variables. Runtime session markers are checked by
  # manifest priority. `detect=explicit` (and types with no detect=) are never
  # auto-detected. Weak credentials such as GEMINI_API_KEY are deferred until
  # process evidence has had a chance to identify the actual CLI.
  local _t _v _detect _fallback _toks _fallback_toks
  local _fallback_type=""
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
    _fallback="$(agmsg_type_get "$_t" detect_fallback)"
    if [ -n "$_fallback" ] && [ "$_fallback" != explicit ]; then
      read -ra _fallback_toks <<<"$_fallback"
      for _v in "${_fallback_toks[@]}"; do
        if [ -n "${!_v:-}" ] && [ -z "$_fallback_type" ]; then
          _fallback_type="$_t"
          break
        fi
      done
    fi
  done < <(_agmsg_detect_order)

  # 2. Process-tree detection via each type's `detect_proc=` name globs. Walk up
  # from this process; at each ancestor the first type whose glob matches wins
  # (the globs are disjoint, so order within a level is irrelevant).
  #
  # The (type, detect_proc) pairs are STATIC for this call -- they do not
  # depend on which ancestor is being examined -- so they are read ONCE here,
  # not once per ancestor. #1254 made this function's caller
  # (agmsg_terminal_env_untrusted) run on every self-naming action, including
  # from a shell with none of the strong detect= env vars set (a CI runner
  # carries no CLAUDE_CODE_SESSION_ID/CODEX_THREAD_ID/...), which always falls
  # through to this process-tree walk: re-reading every type's manifest via a
  # fresh _agmsg_detect_order() at each of up to 10 ancestor levels turned one
  # detection into ~10x its own already-nontrivial manifest I/O, slow enough
  # to blow CI's 30-minute job cap on the first test that exercised it
  # (test_self_name.bats, macOS runner, #1261 CI report).
  # A newline+tab-delimited STRING, not a bash array: an array left with zero
  # elements (no type declares detect_proc=) throws "unbound variable" under
  # `set -u` on bash 3.2 (macOS's /bin/bash) the moment it is expanded with
  # `${arr[@]}` -- fixed in bash 4.4, not available here. Matches this file's
  # own _agmsg_detect_order and agmsg_terminal_candidates's `names` variable,
  # which use the same string-accumulation shape for the same reason.
  local _order_t _pats _proc_list=""
  while IFS= read -r _order_t; do
    [ -n "$_order_t" ] || continue
    _pats="$(agmsg_type_get "$_order_t" detect_proc)"
    [ -n "$_pats" ] || continue
    _proc_list="${_proc_list}${_order_t}$(printf '\t')${_pats}
"
  done < <(_agmsg_detect_order)

  local pid=$$ max_depth=10 depth=0 proc_name _pt _pp _pat
  while [ $depth -lt $max_depth ] && [ "$pid" != "1" ] && [ -n "$pid" ]; do
    proc_name=$(compat_get_comm "$pid" 2>/dev/null || true)
    if [ -n "$proc_name" ] && [ -n "$_proc_list" ]; then
      while IFS=$'\t' read -r _pt _pp; do
        [ -n "$_pt" ] || continue
        read -ra _toks <<<"$_pp"
        for _pat in "${_toks[@]}"; do
          # $_pat is intentionally an UNQUOTED glob pattern matched against the
          # process name; read -ra already kept it out of pathname expansion.
          # shellcheck disable=SC2254
          case "$proc_name" in
            $_pat) echo "$_pt"; return 0 ;;
          esac
        done
      done <<<"$_proc_list"
    fi

    # Move to parent process
    pid=$(compat_get_ppid "$pid" 2>/dev/null || true)
    depth=$((depth + 1))
  done

  # Weak environment evidence is a last resort. A shared SDK credential must
  # not hide a stronger process marker for another CLI.
  [ -n "$_fallback_type" ] && { echo "$_fallback_type"; return 0; }

  # Default fallback. A LITERAL, and the one name here that no registry lookup
  # stands behind — which is why whoami.sh validates only a type the caller
  # asked for, and why nothing may treat this function's output as a member of
  # agmsg_known_types.
  echo "claude-code"
}
