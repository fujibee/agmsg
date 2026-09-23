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
  #
  # _AGMSG_DETECT_CLI_TYPE_DEFAULTED / _AGMSG_DETECT_CLI_TYPE_OUT: a side
  # channel (plain-statement call, never `x=$(...)` — same reason
  # `_slack_read_token`/`_AGMSG_AGENT_BINARIES_OUT` use one elsewhere: a
  # command substitution runs in a subshell, and a write there never reaches
  # the caller). This function's own RETURN VALUE and stdout stay exactly
  # what they always were -- always 0, always something on stdout -- because
  # every existing `$(...)`-based caller (whoami.sh, poke.sh,
  # windows/dispatch.sh) assigns that output directly under `set -e`, and a
  # failing command substitution in a bare assignment aborts the script
  # there, before the assignment completes (review round on #1402: an
  # earlier version of this change made the default branch return 1, on the
  # reasoning that no caller checked the status -- true, but irrelevant,
  # since `set -e` acts on the assignment itself, not on whether anything
  # later reads it). self-name.sh (#1391) is the one caller that needs to
  # tell "detected claude-code" apart from "gave up and said claude-code",
  # and reads this side channel instead.
  _AGMSG_DETECT_CLI_TYPE_DEFAULTED=0

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
        _AGMSG_DETECT_CLI_TYPE_OUT="$_t"
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
            $_pat) _AGMSG_DETECT_CLI_TYPE_OUT="$_t"; echo "$_t"; return 0 ;;
          esac
        done
      done < <(_agmsg_detect_order)
    fi

    # Move to parent process
    pid=$(compat_get_ppid "$pid" 2>/dev/null || true)
    depth=$((depth + 1))
  done

  # Weak environment evidence is a last resort. A shared SDK credential must
  # not hide a stronger process marker for another CLI.
  if [ -n "$_fallback_type" ]; then
    _AGMSG_DETECT_CLI_TYPE_OUT="$_fallback_type"
    echo "$_fallback_type"
    return 0
  fi

  # Default fallback. A LITERAL, and the one name here that no registry lookup
  # stands behind — which is why whoami.sh validates only a type the caller
  # asked for, and why nothing may treat this function's output as a member of
  # agmsg_known_types. _AGMSG_DETECT_CLI_TYPE_DEFAULTED=1 says this value is
  # not evidence of anything, for the one caller (self-name.sh) that reads it;
  # every other caller is unaffected, since this echoes and returns exactly
  # as it always did.
  _AGMSG_DETECT_CLI_TYPE_DEFAULTED=1
  _AGMSG_DETECT_CLI_TYPE_OUT="claude-code"
  echo "claude-code"
}
