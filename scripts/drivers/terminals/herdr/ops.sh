#!/usr/bin/env bash
# herdr terminal driver — a pane inside a herdr session.
#
# Sourced by the terminals registry into the caller's context. terminal_* only,
# no set -e/-u.
#
# FACT BOUNDARY — what is measured vs still asserted (keep this honest):
#   MEASURED on the real machine (2026-08-29; and live on
#   a real workstation, herdr 0.8.0, 2026-09-02/03 — the resolver run against the real
#   `agent list`, with positive controls):
#     - `herdr agent list` is JSON; agent_session in the list is an OBJECT and the
#       session id is at .value (inherited HERDR_PANE_ID is NOT trusted).
#     - a session-less pane has the agent_session KEY ABSENT entirely; no live-list
#       entry carries a JSON-null agent_session. B recognizes it by STRUCTURE, not by
#       a value or a key-name set — both drift while the pane lives (agent_status
#       changes; name/display_agent come and go): the agent_session key is absent, the
#       pane_id is valid, the fixed identity anchor (agent/terminal_id/tab_id/
#       workspace_id, measured always-present, 0 variance over 11 panes, 2026-09-04)
#       is present, and NO field is object/array-valued (so a session moved to a renamed
#       OBJECT/ARRAY key cannot pass; a session FLATTENED to a scalar is an unidentifiable
#       residual — the cost of allowing unknown scalar extensions, named at the det CTE).
#       display_agent was a string in one 2026-09-04 agent list; a NAMED bare pane was not
#       observed by 2026-09-04 (its control is defensive).
#     - the pane-id grammar (w1:p4, w1:pB, w5:p3, w1:pC).
#     - `pane read --source <visible|recent|...>` (the --source values were measured live).
#     - the internal agent-name key is a collision-resistant SHA-256 derivation of
#       (team, agent) — see _herdr_internal_key for why concatenation/folding has a
#       structural collision.
#     - the existing spawn/despawn calls (pane split/run, tab create, pane close).
#   ASSERTED, NOT yet measured against a live call: `herdr agent prompt`'s argv for
#     poke and `herdr agent rename`'s argv for the internal name key (no agent-rename
#     call in main to measure against). These stay flagged inline and in the PR body;
#     the fixtures pin the control flow and the argv THIS driver emits, so a real-CLI
#     mismatch is a localized one-line fix.

# control op: herdr binary present?
terminal_check() {
  if command -v herdr >/dev/null 2>&1; then echo ok; return 0; fi
  printf 'AGMSG-DIRECTIVE: {"type":"install_deps","driver":"terminals/herdr","reason":"herdr not found"}\n'
  echo missing_deps
  return 10
}

terminal_describe() {
  printf 'name=herdr\n'
  printf 'backend=herdr pane\n'
  printf 'capabilities=spawn despawn peek poke where arrange name\n'
  printf 'syntax_help=herdr --help\n'
  printf 'skill_help=herdr --skill\n'
  printf 'intent.place_below=herdr pane move SOURCE --new-tab; herdr pane move SOURCE --tab CONTAINER --split down --target-pane TARGET\n'
  printf 'intent.place_right=herdr pane move SOURCE --new-tab; herdr pane move SOURCE --tab CONTAINER --split right --target-pane TARGET\n'
}

# Extract the pane id whose agent_session == <sid> from `herdr agent list` JSON.
# Uses sqlite3 JSON1 (the codebase's no-jq convention). ASSERTED field names
# (agent_session, pane_id) — verified by the live matrix. Prints the pane id, or
# nothing (empty) if no entry matches.
# Resolve <sid> to a pane via `agent list`, distinguishing THREE outcomes so the
# caller can give an honest reason (2026-08-31):
#   return 2         — could not ANSWER (herdr absent, or `agent list` errored/empty)
#   return 0, pane   — answered, this session's pane is <pane>
#   return 0, empty  — answered, but this session is not among the live agents
_herdr_pane_for_session() {
  local sid="$1" json rc=0
  # `|| rc=$?` (not `; rc=$?`): a bare command-substitution assignment fires the
  # caller's set -e the instant the command fails, so the next line never runs and
  # the "could not answer" case can't be classified. The conditional context
  # suppresses errexit and captures the status — same fix as agmsg_terminal_load.
  json="$(herdr agent list 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$json" ] || return 2
  local jesc valid vrc=0
  jesc="$(printf '%s' "$json" | sed "s/'/''/g")"
  # POSITIVE PROOF the list is something we could actually read: exit-0 bytes are
  # not proof of a live-agent set. Invalid JSON, a bad schema, or an unavailable
  # sqlite all mean "could not answer" (return 2), NOT "answered, no match".
  valid="$(sqlite3 :memory: "SELECT json_valid('$jesc')" 2>/dev/null)" || vrc=$?
  [ "$vrc" -eq 0 ] || return 2
  [ "$valid" = 1 ] || return 2
  local q pane sesc jtype jtrc alen det badhit out orc
  sesc="$(printf '%s' "$sid" | sed "s/'/''/g")"
  # The claim "not among" is a claim about the WHOLE set, so it is only honest when
  # every entry's membership is DECIDABLE. The trap (over several review rounds, then
  # the live measurement) is grabbing a proxy for "decidable":
  #   1 query succeeded  2 container is an array  3 an entry of the expected shape
  #   exists  4 >=1 well-formed  5 same predicate twice  6 the '|' delimiter is in
  #   the value  7 the pane-id "shape" is just a skeleton
  # and — measured on the real machine — a BARE PANE with no agent_session at all is
  # a NORMAL herdr member, not schema drift; treating it as "unreadable" made
  # `well == alen` never hold, so not-among was unreachable and every absent session
  # returned did-not-answer. The fix is to split "could not read this entry" from
  # "this entry legitimately has no session":
  #   DETERMINATE entry  — its membership is decidable: EITHER an agent_session OBJECT
  #                        whose .value is text (comparable to the target), OR a pane
  #                        POSITIVELY recognized as session-less by STRUCTURE (see the
  #                        det CTE): agent_session key absent, a valid pane_id, the fixed
  #                        identity anchor present, and NO field object/array-valued.
  #                        NOT by agent_status's value or the key-name set — both drift
  #                        while the pane lives, which is what made the value-pinned
  #                        version intermittently green (round-8 twice).
  #   indeterminate      — an agent_session PRESENT but malformed (scalar, or object
  #                        without a text .value), OR a key-absent entry that is NOT the
  #                        proven session-less structure (a session hidden under a renamed
  #                        key: future_session:{…}, future_sessions:[…], session_ids:[…]
  #                        — any object/array-valued field), a bare {}, or a shape lacking
  #                        the anchor: the target could be hiding there unread, so it must
  #                        NOT be silently ruled out.
  # One query over the array at $q (the authority once found) returns four
  # '|'-separated fields — alen, determinate count, "found-but-unusable-pane" count,
  # and the matched pane id. The matched pane is the ONLY free-text field and it is
  # constrained to the MEASURED herdr pane-id grammar, so it is [0-9A-Za-z:] only and
  # the '|'/one-line framing cannot mis-split (a pane with '|' or a newline is not a
  # usable id — the match is withheld and counted as found-but-unusable). Grammar
  # (from read-only measurement, herdr 0.8.0: w1:p4, w1:pB, w5:p3; fixtures also
  # wC:p4): w + >=1 alnum, exactly one ':', then p + >=1 alnum, alnum+':' only.
  #   GLOB 'w[0-9A-Za-z]*:p[0-9A-Za-z]*' : w<n>:p<x>, n/x non-empty (rejects w:p, w1:t1)
  #   NOT GLOB '*:*:*'                    : at most one ':' (rejects w1:x:p4)
  #   NOT GLOB '*[^0-9A-Za-z:]*'          : alnum + ':' only (rejects '|', newline;
  #                                         [^…] is GLOB's negated class, not [!…])
  # Candidate paths: $.result.agents is the measured location; others are defensive.
  for q in '$.result.agents' '$' '$.agents' '$.result'; do
    jtrc=0
    jtype="$(sqlite3 :memory: "SELECT json_type('$jesc', '$q')" 2>/dev/null)" || jtrc=$?
    [ "$jtrc" -eq 0 ] || return 2       # sqlite unavailable / JSON unparseable -> could not answer
    [ "$jtype" = array ] || continue    # no array at this path -> not this shape (a valid {} lands here)
    orc=0
    out="$(sqlite3 :memory: "
      WITH entries(value) AS (SELECT value FROM json_each('$jesc', '$q')),
           -- Tag every object entry ONCE (one predicate, no drift). The entries
           -- table is ALIASED (e) so the correlated json_each below binds e.value per
           -- row -- without the alias a bare json_each(value) does NOT correlate and
           -- returns the same answer for every row (measured).
           tagged(value, pane_ok, as_type, anchor_ok, struct_free) AS (
             -- pane_ok is normalized to a definite 0/1: a boolean expression
             -- would be NULL when pane_id is ABSENT, and then a target session with
             -- no pane_id lands in NEITHER hit (AND pane_ok -> NULL) nor badhit
             -- (AND NOT pane_ok -> NULL), so present-but-unaddressable would read as
             -- not-among. CASE WHEN … THEN 1 ELSE 0 END collapses the three-valued
             -- logic so hit draws from pane_ok=1 and badhit from pane_ok=0.
             SELECT e.value,
               CASE WHEN json_type(e.value,'\$.pane_id') = 'text'
                 AND json_extract(e.value,'\$.pane_id') GLOB 'w[0-9A-Za-z]*:p[0-9A-Za-z]*'
                 AND NOT (json_extract(e.value,'\$.pane_id') GLOB '*:*:*')
                 AND NOT (json_extract(e.value,'\$.pane_id') GLOB '*[^0-9A-Za-z:]*')
               THEN 1 ELSE 0 END,
               json_type(e.value,'\$.agent_session'),
               -- (c) the fixed bare-pane ANCHOR: the herdr-pane identity keys every
               --     agent-list entry carries (measured always-present, 0 variance over
               --     11 panes, live 2026-09-04). This is the POSITIVE proof the entry
               --     is a real herdr pane, so a minimal or unknown shape that merely has
               --     a pane_id-looking field is NOT taken for one.
               CASE WHEN json_type(e.value,'\$.agent') IS NOT NULL
                 AND json_type(e.value,'\$.terminal_id') IS NOT NULL
                 AND json_type(e.value,'\$.tab_id') IS NOT NULL
                 AND json_type(e.value,'\$.workspace_id') IS NOT NULL
               THEN 1 ELSE 0 END,
               -- (d‴) NO field is object- or array-valued -- every value is a scalar.
               CASE WHEN NOT EXISTS (
                 SELECT 1 FROM json_each(e.value) k WHERE k.type IN ('object','array'))
               THEN 1 ELSE 0 END
             FROM entries e WHERE json_type(e.value) = 'object'),
           -- DECIDABLE = positively one of the two KNOWN kinds. B (a session-less pane)
           -- is proven by STRUCTURE, never by a value or a key-NAME set -- both of those
           -- drift while the pane lives (agent_status changes state; name/display_agent
           -- appear and vanish when the agent is named or ends), so pinning to either
           -- makes the predicate intermittently green and reopens the round-8 regression.
           -- The four conditions (2026-09-04):
           --   (a) the agent_session KEY is ABSENT (as_type IS NULL);
           --   (b) a valid pane_id (grammar above);
           --   (c) the fixed identity anchor is present (anchor_ok);
           --   (d‴) no field is object- or array-valued (struct_free).
           -- SCOPE of (d‴), stated exactly: it catches a session moved to a
           -- renamed OBJECT or ARRAY key -- future_session:{…}, future_sessions:[…],
           -- session_ids:[…], inner shape irrelevant -- because the MEASURED agent_session
           -- is an object, so a structured value where none belongs fails struct_free and
           -- the target it hides is NOT reported not-among. It does NOT catch a session
           -- FLATTENED to a scalar (a future_session or session_id key whose VALUE is the
           -- bare target string, not an object/array): that passes struct_free and enters
           -- B. RESIDUAL, named not hidden: an unknown
           -- SCALAR field secretly carrying a session id is unidentifiable here -- the
           -- deliberate cost of ALLOWING unknown scalar extensions, which is required
           -- because name / display_agent are real scalar fields that come and go and a
           -- named bare pane must still reach not-among. If a scalar-flattened session is
           -- ever observed, add a condition then (same treatment as the hash-collision and
           -- the process-info residuals: written down, not hidden).
           -- A scalar extension (name, display_agent -- measured as a string once in the
           -- 2026-09-04 agent list) passes, so a NAMED bare pane still reaches not-among.
           -- NOTE: a named bare pane (name present, agent_session absent) was NOT
           -- observed as of 2026-09-04 (live measurement); its control is DEFENSIVE.
           det(value) AS (
             SELECT value FROM tagged
             WHERE ( as_type = 'object' AND json_type(value,'\$.agent_session.value') = 'text' )
                OR ( as_type IS NULL AND pane_ok = 1 AND anchor_ok = 1 AND struct_free = 1 )),
           -- the target, present as a session entry with a usable (grammar) pane:
           hit(pid) AS (
             SELECT json_extract(value,'\$.pane_id') FROM tagged
             WHERE as_type = 'object'
               AND json_extract(value,'\$.agent_session.value') = '$sesc'
               AND pane_ok = 1
             LIMIT 1),
           -- the target present as a session entry but with an UNUSABLE/absent pane id:
           badhit(x) AS (
             SELECT 1 FROM tagged
             WHERE as_type = 'object'
               AND json_extract(value,'\$.agent_session.value') = '$sesc'
               AND pane_ok = 0
             LIMIT 1)
      SELECT (SELECT count(*) FROM entries),
             (SELECT count(*) FROM det),
             (SELECT count(*) FROM badhit),
             (SELECT pid FROM hit)" 2>/dev/null)" || orc=$?
    [ "$orc" -eq 0 ] || return 2
    IFS='|' read -r alen det badhit pane <<< "$out"
    # Found, with a usable pane id (grammar-constrained -> framing-safe).
    if [ -n "$pane" ] && [ "$pane" != "null" ]; then printf '%s\n' "$pane"; return 0; fi
    # Target present but its pane id is unusable -> we cannot address it: could not answer.
    [ "${badhit:-0}" -gt 0 ] && return 2
    # No match. Not-among is honest only if EVERY entry was decidable — positively a
    # session entry (A) or a bare pane (B). Empty array: det==alen==0 -> not-among.
    [ "${det:-0}" -eq "${alen:-0}" ] && return 0   # answered, this session is not among the agents
    return 2   # some entry was neither A nor B (unknown/drift) -> the target may be unread
  done
  return 2   # no candidate array path (unknown schema) -> could not answer
}

# record op: we are under herdr iff HERDR_ENV=1 and herdr is on PATH. Resolve
# THIS session's pane from the session id via agent list (NOT inherited
# HERDR_PANE_ID). Non-zero if not under herdr or the pane cannot be resolved.
terminal_detect() {
  local sid="${1:-}"
  # PRESENCE (exit code) is HERDR_ENV=1 ALONE: whether herdr is on PATH is a
  # terminal_check question ("can I operate it"), NOT "which terminal am I in"
  # (2026-08-31). Conflating them would make a herdr session with no herdr
  # on PATH place/name as tmux or plain. SELF-ID (stdout) is the pane from agent
  # list, which may be EMPTY — the third value "could not resolve", NOT "not
  # herdr". The reason (no session id / list did not answer, incl. herdr absent /
  # answered but we are not in it) goes to stderr for resolve-for-name's error;
  # resolve-for-placement uses only the exit code and needs no id.
  [ "${HERDR_ENV:-}" = 1 ] || return 1
  if [ -z "$sid" ]; then
    echo "herdr: no session id to resolve this pane by" >&2
    return 0
  fi
  local pane hrc=0
  # `|| hrc=$?` (not `; hrc=$?`): a bare command-substitution assignment fires the
  # caller's set -e when the helper returns non-zero, so the classification below
  # never runs. The conditional context suppresses errexit and captures the code.
  pane="$(_herdr_pane_for_session "$sid")" || hrc=$?
  if [ "$hrc" -ne 0 ]; then
    echo "herdr: 'agent list' did not answer (herdr not on PATH or errored) — cannot resolve this pane" >&2
    return 0
  fi
  if [ -z "$pane" ]; then
    echo "herdr: session '$sid' is not among the live agents — cannot resolve this pane" >&2
    return 0
  fi
  printf '%s\n' "$pane"
  return 0
}

# Read the new pane id from a herdr JSON result at one of the known paths.
# The measured herdr pane-id grammar as ONE shell authority (the resolver and
# the spawn side must not implement the predicate twice and drift). w + >=1 alnum,
# exactly one ':', then p + >=1 alnum, alnum+':' only. A test cross-checks that this
# agrees with the resolver's SQL GLOB form on the boundary values. (bash negated
# class is [!…]; SQLite GLOB's is [^…] — same grammar, different dialect.)
_herdr_pane_id_ok() {
  # Delegate to the registry's single per-terminal id authority so the spawn-side
  # extraction, the resolver's cross-check, and agmsg_terminal_ref_terminal all use
  # ONE herdr pane grammar (do not implement the predicate twice). The herdr
  # driver is always loaded through the registry, so the helper is in scope; a bare
  # source without it falls back to the inline grammar rather than accepting anything.
  if declare -F _agmsg_terminal_id_ok >/dev/null 2>&1; then
    _agmsg_terminal_id_ok herdr "$1"; return $?
  fi
  case "$1" in
    w[0-9A-Za-z]*:p[0-9A-Za-z]*) : ;;
    *) return 1 ;;
  esac
  case "$1" in *:*:*) return 1 ;; esac
  case "$1" in *[!0-9A-Za-z:]*) return 1 ;; esac
  return 0
}

_herdr_new_pane_id() {
  local json="$1" q pane esc
  esc="$(printf '%s' "$json" | sed "s/'/''/g")"
  for q in '$.result.pane.pane_id' '$.result.root_pane.pane_id' '$.pane.pane_id' '$.root_pane.pane_id'; do
    # A usable pane id must match the pane-id grammar, not merely be non-empty text:
    # a numeric/null pane_id (malformed/partial response) OR a text one carrying a
    # newline / '|' / wrong shape must fail closed — otherwise the caller renames/runs
    # against a non-pane, and in the <terminal>:<id> record a newline breaks framing.
    pane="$(sqlite3 :memory: "SELECT json_extract('$esc', '$q')" 2>/dev/null)"
    _herdr_pane_id_ok "$pane" && { printf '%s\n' "$pane"; return 0; }
  done
  return 1
}

# requirement 1 (herdr pre-input readiness). Before typing the boot into the pane's
# shell, confirm the shell is AT ITS PROMPT — nothing else in the foreground — so a
# startup program (e.g. an oh-my-zsh update prompt) cannot eat the first keystroke.
# The signal is STRUCTURAL and environment-independent (2026-09-04): herdr's
# pane process-info reports shell_pid and foreground_process_group_id, and the shell is
# at its prompt IFF the foreground process group IS the shell itself. No prompt string
# is matched (zsh/bash/Windows alike) and no point-in-time value is baked in.
#
# Why not the obvious herdr calls (all MEASURED 2026-09-04, recorded so nobody re-hunts):
#   - herdr agent start takes only a --kind enum, NOT an arbitrary boot script, and our
#     spawn runs a boot script, so it cannot replace pane run.
#   - herdr agent wait waits for an AGENT state; a pane with no agent yet is not in
#     agent list (30 panes vs 11 agent-list entries), so it cannot see a bare shell.
#   - agent list has no shell-readiness field; process-info is the one that does.
#
# NECESSARY, NOT SUFFICIENT (kept honest): this proves "no OTHER command is
# running". It does NOT prove the keystroke survives — if the SHELL ITSELF is reading
# (an oh-my-zsh "[Y/n]" has no child process), process-info returns equal and this
# reports READY. That case was UNMEASURED as of 2026-09-04. So a first keystroke can
# still be lost; that residual is caught AFTER typing by the readiness handshake /
# launched-unconfirmed, never here. Do not read this gate as a guarantee.
#
# THREE outcomes, kept distinct (the positive-validation contract):
#   0 READY      — command ok, BOTH ids present and canonical positive integers, EQUAL.
#   1 NOT READY  — both ids validated the SAME way, and UNEQUAL (a foreground process).
#   2 UNKNOWN    — the command failed, a field is missing, or a value is not a canonical
#                  positive integer. "" == "" / null == null / same-malformed are NOT
#                  ready: equality is read ONLY after both values pass validation. A
#                  nonexistent pane and a malformed pane id return the SAME error, so
#                  they are not split — both are UNKNOWN.
_herdr_pane_input_ready() {
  local pane="$1" info rc=0 sp fg jesc
  info="$(herdr pane process-info --pane "$pane" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 2
  jesc="$(printf '%s' "$info" | sed "s/'/''/g")"
  # Require the JSON TYPE to be integer, in the SAME payload, BEFORE reading the value:
  # a JSON string "123" extracts as 123 and would pass a digit check, but a pid that
  # arrives as a string is not a validated pid. The CASE yields the value only when
  # json_type is 'integer', else empty -> the digit/positive guard below rejects it.
  sp="$(sqlite3 :memory: "SELECT CASE WHEN json_type('$jesc','\$.result.process_info.shell_pid')='integer' THEN json_extract('$jesc','\$.result.process_info.shell_pid') ELSE '' END" 2>/dev/null)" || return 2
  fg="$(sqlite3 :memory: "SELECT CASE WHEN json_type('$jesc','\$.result.process_info.foreground_process_group_id')='integer' THEN json_extract('$jesc','\$.result.process_info.foreground_process_group_id') ELSE '' END" 2>/dev/null)" || return 2
  # Canonical positive integer (^[1-9][0-9]*$): reject empty (non-integer type / null /
  # missing), a leading zero, and 0 or negatives. An unvalidated equality is no evidence.
  case "$sp" in ''|0*|*[!0-9]*) return 2 ;; esac
  case "$fg" in ''|0*|*[!0-9]*) return 2 ;; esac
  if [ "$sp" = "$fg" ]; then return 0; fi
  return 1
}

# record op: create a pane/window, launch boot, print the new bare pane id.
# Usage: terminal_spawn <name> <project> <target> <boot...>
# <target> fully specifies the placement (no ambient config): 'window', or
# 'pane-h' / 'pane-v' (herdr directions right / down). Mirrors spawn.sh's herdr
# placement (tab create / pane split, then rename + run).
terminal_spawn() {
  local name="$1" project="$2" target="$3"; shift 3
  local boot="$*" json pane dir
  # Validate target explicitly — a typo must fail, not silently pick a default.
  case "$target" in
    window|pane-h|pane-v) : ;;
    *) printf 'unsupported: unknown target: %s (window|pane-h|pane-v)\n' "$target" >&2; return 13 ;;
  esac
  if [ "$target" = window ]; then
    # A window needs a workspace. Absent one, FAIL explicitly rather than
    # silently splitting a pane the caller did not ask for.
    [ -n "${HERDR_WORKSPACE_ID:-}" ] || {
      printf 'unsupported: window target needs HERDR_WORKSPACE_ID\n' >&2; return 13; }
    json="$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --label "$name" --cwd "$project" 2>/dev/null)" || return 13
  else
    case "$target" in pane-h) dir=right ;; *) dir=down ;; esac
    json="$(herdr pane split "${HERDR_PANE_ID:-}" --direction "$dir" --no-focus --cwd "$project" 2>/dev/null)" || return 13
  fi
  pane="$(_herdr_new_pane_id "$json")" || return 13
  herdr pane rename "$pane" "$name" >/dev/null 2>&1 || true
  # requirement 1: wait (bounded) for the shell to reach its prompt, then act on the
  # THREE outcomes distinctly. Only NOT-READY(1) is retried — READY(0) and UNKNOWN(2)
  # are terminal. Every iteration uses the SAME classifier; UNKNOWN is never folded into
  # NOT READY. Exit codes carry the outcome to the caller: 0 typed+verified, 3 NOT typed
  # (pane never ready), 4 typed but pre-input state UNVERIFIED.
  #
  # The bound is FIXED, not an env surface: a knob read from the environment could arrive
  # empty / 0 / non-numeric and silently skip the observation (loop never runs -> UNKNOWN
  # -> boot), which is the very thing this gate exists to prevent. ~5s (50 * 0.1s)
  # covers a slow interactive-shell startup without a knob to misconfigure.
  # `ready_rc=0; classifier || ready_rc=$?`, NOT `classifier; ready_rc=$?`: the classifier
  # returns non-zero for NOT-READY(1)/UNKNOWN(2), and a bare command whose status is read
  # on the next line takes a `set -e` caller down BEFORE the branch classifies it.
  local ready_rc=2 tries=0
  while [ "$tries" -lt 50 ]; do
    ready_rc=0; _herdr_pane_input_ready "$pane" || ready_rc=$?
    [ "$ready_rc" = 1 ] || break
    sleep 0.1 2>/dev/null || true
    tries=$((tries + 1))
  done
  if [ "$ready_rc" = 1 ]; then
    # NOT READY after the bound: a foreground process is still running, so a typed boot
    # would be lost. Do NOT type; close the pane we created and fail with the reason.
    printf 'unsupported: pane %s never returned to its shell prompt (a foreground process is still running); the boot was NOT typed, to avoid a lost keystroke\n' "$pane" >&2
    herdr pane close "$pane" >/dev/null 2>&1 || true
    return 3
  fi
  herdr pane run "$pane" "$boot" >/dev/null 2>&1 || return 13
  printf '%s\n' "$pane"
  # UNKNOWN: the boot WAS typed, but the pre-input state could not be verified. Signal
  # that distinctly (4) so the caller can warn — a DIFFERENT reason from a missing
  # post-input handshake, and it must not silently read as a clean spawn.
  if [ "$ready_rc" = 2 ]; then return 4; fi
  return 0
}

# control op: close the herdr pane named by the bare id.
# Is the recorded pane still there? READ ONLY — `agent list` and nothing else.
#
# Same reason as the tmux driver's: `terminal_despawn` collapses "already closed"
# and "could not close" into 13, so it cannot tell a caller whether a graceful
# teardown worked.
#
#   present / 0    the id appears in the list
#   gone    / 0    the list answered, validly, and the id is not in it
#   unknown / 10   herdr could not be reached, or answered something unreadable
#
# `gone` is a claim about the WHOLE list, so it is only made after the list has
# been PROVEN readable — exit-0 bytes are not proof. Anything short of that is
# `unknown`, because the caller deletes the placement record on `gone` alone.
#
# The read-and-validate preamble is deliberately the same shape as
# `_herdr_pane_for_session` above and is NOT yet factored out of it: that
# function is under review for a release block. Two copies of a preamble is a
# thing to fix, not to leave unnamed — noted here so the next reader knows it is
# known rather than accidental.
terminal_pane_state() {
  local id="$1" json rc=0
  command -v herdr >/dev/null 2>&1 || { echo unknown; return 10; }
  json="$(herdr agent list 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || { echo unknown; return 10; }
  [ -n "$json" ] || { echo unknown; return 10; }

  local jesc valid vrc=0
  jesc="$(printf '%s' "$json" | sed "s/'/''/g")"
  valid="$(sqlite3 :memory: "SELECT json_valid('$jesc')" 2>/dev/null)" || vrc=$?
  [ "$vrc" -eq 0 ] || { echo unknown; return 10; }
  [ "$valid" = 1 ] || { echo unknown; return 10; }

  # `gone` is the ONLY answer that deletes a placement record, so it has to be
  # earned the same way `_herdr_pane_for_session` earns "not among": the claim is
  # about the WHOLE set, so it is honest only when EVERY entry's membership is
  # DECIDABLE. An array whose entries were never inspected proves nothing — a
  # target hiding in an entry this driver cannot read is exactly the case that
  # must not come back as `gone`.
  #
  # DECIDABLE here, for a pane_id question (narrower than the session question,
  # which also has to recognize a session-less pane by structure): the entry is an
  # object, carries a pane_id in the MEASURED grammar, and carries the fixed
  # identity anchor that positively marks it a real herdr pane. Both known kinds —
  # a session entry and a bare pane — satisfy this, because both carry a pane_id;
  # anything else (a non-object entry, a missing/ungrammatical pane_id, an
  # unanchored shape) is drift, and drift is `unknown`, never `gone`.
  #
  # `hit` is deliberately LOOSER than `det`: an exact pane_id match is evidence the
  # pane exists whatever else the entry looks like, and `present` keeps the record.
  # The asymmetry is the point — the cheap answer is permissive, the destructive
  # one is not.
  local iesc q jtype jtrc out orc alen det hit
  iesc="$(printf '%s' "$id" | sed "s/'/''/g")"
  for q in '$.result.agents' '$' '$.agents' '$.result'; do
    jtrc=0
    jtype="$(sqlite3 :memory: "SELECT json_type('$jesc', '$q')" 2>/dev/null)" || jtrc=$?
    [ "$jtrc" -eq 0 ] || { echo unknown; return 10; }
    [ "$jtype" = array ] || continue
    orc=0
    out="$(sqlite3 :memory: "
      WITH entries(value) AS (SELECT value FROM json_each('$jesc', '$q')),
           -- ALIASED (e) so the correlated json_each in the anchor test binds
           -- e.value per row; a bare json_each(value) does not correlate.
           tagged(pane_ok, anchor_ok, pid) AS (
             SELECT
               CASE WHEN json_type(e.value,'\$.pane_id') = 'text'
                 AND json_extract(e.value,'\$.pane_id') GLOB 'w[0-9A-Za-z]*:p[0-9A-Za-z]*'
                 AND NOT (json_extract(e.value,'\$.pane_id') GLOB '*:*:*')
                 AND NOT (json_extract(e.value,'\$.pane_id') GLOB '*[^0-9A-Za-z:]*')
               THEN 1 ELSE 0 END,
               CASE WHEN json_type(e.value,'\$.agent') IS NOT NULL
                 AND json_type(e.value,'\$.terminal_id') IS NOT NULL
                 AND json_type(e.value,'\$.tab_id') IS NOT NULL
                 AND json_type(e.value,'\$.workspace_id') IS NOT NULL
               THEN 1 ELSE 0 END,
               json_extract(e.value,'\$.pane_id')
             FROM entries e WHERE json_type(e.value) = 'object'),
           det(x) AS (SELECT 1 FROM tagged WHERE pane_ok = 1 AND anchor_ok = 1),
           hit(x) AS (SELECT 1 FROM tagged WHERE pid = '$iesc' LIMIT 1)
      SELECT (SELECT count(*) FROM entries),
             (SELECT count(*) FROM det),
             (SELECT count(*) FROM hit)" 2>/dev/null)" || orc=$?
    [ "$orc" -eq 0 ] || { echo unknown; return 10; }
    IFS='|' read -r alen det hit <<< "$out"
    if [ "${hit:-0}" -gt 0 ]; then echo present; return 0; fi
    # No match. Not-present is honest only if every entry was decidable.
    # Empty array: det == alen == 0 -> gone, which is correct (no panes at all).
    if [ "${det:-0}" -eq "${alen:-0}" ]; then echo gone; return 0; fi
    echo unknown
    return 10
  done
  # No array at any candidate path: the list was readable JSON but not a shape
  # this driver knows, which is "could not answer", not "not in it".
  echo unknown
  return 10
}

terminal_despawn() {
  local id="$1"
  herdr pane close "$id" >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
  return 0
}

# Ask herdr where a pane is. Existence is deliberately outside this op: a layout
# query that does not contain the pane is an unanswered location query, so it is
# unknown/10 rather than a claim that the pane is gone.
terminal_where() {
  local id="$1" json rc=0 esc container present
  command -v herdr >/dev/null 2>&1 || { echo unknown; return 10; }
  _herdr_pane_id_ok "$id" || { echo unsupported; return 13; }
  json="$(herdr pane layout --pane "$id" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$json" ] || { echo unknown; return 10; }
  esc="$(printf '%s' "$json" | sed "s/'/''/g")"
  present="$(sqlite3 :memory: "SELECT count(*) FROM json_each('$esc','\$.result.layout.panes') WHERE json_extract(value,'\$.pane_id') = '$(printf '%s' "$id" | sed "s/'/''/g")'" 2>/dev/null)" \
    || { echo unknown; return 10; }
  container="$(sqlite3 :memory: "SELECT json_extract('$esc','\$.result.layout.tab_id')" 2>/dev/null)" \
    || { echo unknown; return 10; }
  if [ "$present" != 1 ] || [ -z "$container" ]; then
    echo unknown
    echo "herdr: the layout answered but did not contain '$id'; pane existence must be checked separately" >&2
    return 10
  fi
  printf '%s\n' "$container"
  return 0
}

# Classify the requested terminal relationship from one pane-layout response.
# Output: unchanged, different, ambiguous_layout, or runtime_error.
_herdr_arrange_state() {
  local json="$1" source="$2" intent="$3" target="$4" esc sesc tesc dir result rc=0
  esc="$(printf '%s' "$json" | sed "s/'/''/g")"
  sesc="$(printf '%s' "$source" | sed "s/'/''/g")"
  tesc="$(printf '%s' "$target" | sed "s/'/''/g")"
  case "$intent" in place_below) dir=down ;; place_right) dir=right ;; *) echo unsupported; return 13 ;; esac
  # A candidate split must contain both panes, have the requested direction,
  # and agree with their rectangle order. Among those, the smallest area is the
  # LCA equivalent. Equal-area candidates really occur in degenerate layouts
  # (measured with a zero-height child); if more than one remains, fail closed.
  result="$(sqlite3 :memory: "
    WITH p AS (
      SELECT json_extract(value,'\$.pane_id') id,
             json_extract(value,'\$.rect.x') x, json_extract(value,'\$.rect.y') y,
             json_extract(value,'\$.rect.width') w, json_extract(value,'\$.rect.height') h
      FROM json_each('$esc','\$.result.layout.panes')
    ), src AS (SELECT * FROM p WHERE id='$sesc'), tgt AS (SELECT * FROM p WHERE id='$tesc'),
    candidates AS (
      SELECT json_extract(s.value,'\$.rect.width') * json_extract(s.value,'\$.rect.height') area
      FROM json_each('$esc','\$.result.layout.splits') s, src, tgt
      WHERE json_extract(s.value,'\$.direction')='$dir'
        AND src.x >= json_extract(s.value,'\$.rect.x')
        AND src.y >= json_extract(s.value,'\$.rect.y')
        AND src.x + src.w <= json_extract(s.value,'\$.rect.x') + json_extract(s.value,'\$.rect.width')
        AND src.y + src.h <= json_extract(s.value,'\$.rect.y') + json_extract(s.value,'\$.rect.height')
        AND tgt.x >= json_extract(s.value,'\$.rect.x')
        AND tgt.y >= json_extract(s.value,'\$.rect.y')
        AND tgt.x + tgt.w <= json_extract(s.value,'\$.rect.x') + json_extract(s.value,'\$.rect.width')
        AND tgt.y + tgt.h <= json_extract(s.value,'\$.rect.y') + json_extract(s.value,'\$.rect.height')
        AND (('$dir'='down' AND src.y = tgt.y + tgt.h AND src.x = tgt.x AND src.w = tgt.w)
          OR ('$dir'='right' AND src.x = tgt.x + tgt.w AND src.y = tgt.y AND src.h = tgt.h))
    ), m AS (SELECT min(area) area FROM candidates)
    SELECT CASE
      WHEN (SELECT count(*) FROM tgt) != 1 OR (SELECT count(*) FROM src) > 1 THEN 'unknown'
      WHEN (SELECT count(*) FROM src) = 0 THEN 'source_missing'
      WHEN (SELECT count(*) FROM candidates c,m WHERE c.area=m.area) > 1 THEN 'ambiguous_layout'
      WHEN (SELECT count(*) FROM candidates) > 0 THEN 'unchanged'
      ELSE 'different' END;" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$result" ] || { echo runtime_error; return 10; }
  printf '%s\n' "$result"
}

_herdr_move_changed() {
  local json="$1" esc
  esc="$(printf '%s' "$json" | sed "s/'/''/g")"
  [ "$(sqlite3 :memory: "SELECT json_extract('$esc','\$.result.move_result.changed')" 2>/dev/null)" = 1 ]
}

_herdr_move_created_tab() {
  local json="$1" esc
  esc="$(printf '%s' "$json" | sed "s/'/''/g")"
  sqlite3 :memory: "SELECT json_extract('$esc','\$.result.move_result.created_tab.tab_id')" 2>/dev/null
}

_herdr_layout_has_pane() {
  local json="$1" id="$2" esc iesc count
  esc="$(printf '%s' "$json" | sed "s/'/''/g")"
  iesc="$(printf '%s' "$id" | sed "s/'/''/g")"
  count="$(sqlite3 :memory: "SELECT count(*) FROM json_each('$esc','\$.result.layout.panes') WHERE json_extract(value,'\$.pane_id')='$iesc'" 2>/dev/null)" \
    || return 1
  [ "$count" = 1 ]
}

terminal_arrange() {
  local source="$1" intent="$2" target="$3" layout source_layout state rc=0 tab first second temporary_tab
  command -v herdr >/dev/null 2>&1 || { echo runtime_error; return 10; }
  _herdr_pane_id_ok "$source" && _herdr_pane_id_ok "$target" || { echo unsupported; return 13; }
  case "$intent" in place_below|place_right) : ;; *) echo unsupported; return 13 ;; esac
  layout="$(herdr pane layout --pane "$target" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$layout" ] || { echo runtime_error; return 10; }
  rc=0
  state="$(_herdr_arrange_state "$layout" "$source" "$intent" "$target")" || rc=$?
  case "$state" in
    unchanged) echo unchanged; return 0 ;;
    ambiguous_layout) echo ambiguous_layout; return 12 ;;
    different) : ;;
    source_missing)
      # `pane layout --pane TARGET` only describes TARGET's tab. A source in a
      # different tab is therefore absent from that response, but is still a
      # valid move candidate. Ask the source itself before treating absence as
      # "different"; an unanswered or malformed lookup remains unknown.
      rc=0
      source_layout="$(herdr pane layout --pane "$source" 2>/dev/null)" || rc=$?
      [ "$rc" -eq 0 ] && [ -n "$source_layout" ] && _herdr_layout_has_pane "$source_layout" "$source" \
        || { echo unknown; return 10; }
      ;;
    unknown) echo unknown; return 10 ;;
    *) echo runtime_error; [ "$rc" -ne 0 ] && return "$rc"; return 10 ;;
  esac
  tab="$(sqlite3 :memory: "SELECT json_extract('$(printf '%s' "$layout" | sed "s/'/''/g")','\$.result.layout.tab_id')" 2>/dev/null)" \
    || { echo runtime_error; return 10; }
  [ -n "$tab" ] || { echo runtime_error; return 10; }
  first="$(herdr pane move "$source" --new-tab --no-focus 2>/dev/null)" || { echo runtime_error; echo "herdr: failed before moving '$source' to a temporary tab" >&2; return 12; }
  _herdr_move_changed "$first" || { echo runtime_error; echo "herdr: the temporary-tab move for '$source' did not report changed=true" >&2; return 12; }
  temporary_tab="$(_herdr_move_created_tab "$first")" || temporary_tab=""
  [ -n "$temporary_tab" ] || temporary_tab='<new tab id unavailable>'
  case "$intent" in
    place_below) second="$(herdr pane move "$source" --tab "$tab" --split down --target-pane "$target" --no-focus 2>/dev/null)" ;;
    place_right) second="$(herdr pane move "$source" --tab "$tab" --split right --target-pane "$target" --no-focus 2>/dev/null)" ;;
  esac || {
    echo runtime_error
    echo "herdr: '$source' is left in temporary tab '$temporary_tab': placing it back in tab '$tab' relative to '$target' failed" >&2
    return 12
  }
  _herdr_move_changed "$second" || {
    echo runtime_error
    echo "herdr: '$source' may be left in temporary tab '$temporary_tab': the move back to tab '$tab' did not report changed=true" >&2
    return 12
  }
  echo moved
  return 0
}

# record op: print the visible pane buffer verbatim (NOT parsed — `agent read`/
# `pane read` output is raw terminal text). --lines N asks for more scrollback
# (herdr's --source recent) rather than an exact count. ASSERTED argv.
terminal_peek() {
  local id="$1"; shift
  local src=visible
  while [ $# -gt 0 ]; do
    case "$1" in
      --lines) src=recent; shift 2 ;;
      *) shift ;;
    esac
  done
  # peek is a READ op: only the pane CONTENT may reach stdout. herdr writes an error
  # JSON to STDOUT on failure (e.g. {"error":{"code":"pane_not_found",...}}), which the
  # caller would otherwise read as the pane's content — "read" and "could-not-read"
  # returning in the same shape (the third instance of one channel carrying two
  # meanings). ISOLATE it (capture; the error body goes to stderr, never stdout), and
  # SPLIT the single 13 so the caller can tell the three cases apart:
  #   plain has no peek path        -> 13 (unchanged; documented, and the templates say so)
  #   the terminal is unreachable   -> 10 (herdr not on PATH / cannot even be run)
  #   the pane is gone / unreadable -> 12 (herdr answered, but not with content)
  command -v herdr >/dev/null 2>&1 \
    || { echo "herdr: not on PATH — cannot reach the terminal to peek pane '$id'" >&2; return 10; }
  # READ contract: stdout must be the pane's visible text VERBATIM. A command
  # substitution strips EVERY trailing newline; a following printf '%s\n' then invents
  # exactly one back, so empty content becomes a lone newline and content ending in
  # 0 or 2+ newlines is silently rewritten. Capture to a temp file instead,
  # decide on rc, then cat the bytes unmodified. herdr writes its error JSON to
  # STDOUT on failure, so on the failure path that body is a diagnostic -> stderr,
  # never the caller's content.
  local tmp rc=0
  tmp="$(mktemp)" || { echo "herdr: could not allocate a temp file to peek pane '$id'" >&2; return 12; }
  herdr pane read "$id" --source "$src" >"$tmp" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -s "$tmp" ] && cat "$tmp" >&2   # the error body is a diagnostic, not content
    rm -f "$tmp"
    echo "herdr: could not read pane '$id' (it may no longer exist)" >&2
    return 12
  fi
  cat "$tmp"   # only the real pane content reaches stdout, byte-for-byte
  rm -f "$tmp"
  return 0
}

# Optional team.sh observation extension. Prints activity, visible pane label,
# terminal agent key, and CLI terminal title as four TAB-separated fields.
terminal_team_observe() {
  local id="$1" pane_json agents_json pesc aesc activity label key title
  command -v herdr >/dev/null 2>&1 || return 10
  _herdr_pane_id_ok "$id" || return 13
  pane_json="$(herdr pane get "$id" 2>/dev/null)" || return 10
  agents_json="$(herdr agent list 2>/dev/null)" || return 10
  pesc="$(printf '%s' "$pane_json" | sed "s/'/''/g")"
  aesc="$(printf '%s' "$agents_json" | sed "s/'/''/g")"
  activity="$(sqlite3 :memory: "SELECT COALESCE(json_extract('$pesc','\$.result.pane.agent_status'),'unknown:activity_missing')" 2>/dev/null)" || return 10
  label="$(sqlite3 :memory: "SELECT COALESCE(json_extract('$pesc','\$.result.pane.label'),'unknown:pane_label_missing')" 2>/dev/null)" || return 10
  title="$(sqlite3 :memory: "SELECT COALESCE(json_extract('$pesc','\$.result.pane.terminal_title'),'unknown:terminal_title_missing')" 2>/dev/null)" || return 10
  # Two different facts were collapsed into one value here, and the one this
  # exists to repair travelled the ambiguous half. The agent list was already
  # fetched successfully above (`|| return 10`), so reaching this point means the
  # list was READ — what remains undecided is only which case produced no name:
  #
  #   no entry for this pane_id   -> the pane could not be located in the list.
  #                                  Undecided: `unknown:` (team --fix skips it).
  #   entry present, no `.name`   -> the list answered ABOUT this pane and it
  #                                  carries no key. Decided: `absent:`, which
  #                                  reaches team --fix as a mismatch. This is
  #                                  the measured codex case.
  #
  # The nesting does the split: the inner COALESCE fires only when a row matched,
  # the outer one only when none did.
  key="$(sqlite3 :memory: "SELECT COALESCE((SELECT COALESCE(json_extract(value,'\$.name'),'absent:agent_key_unset') FROM json_each('$aesc','\$.result.agents') WHERE json_extract(value,'\$.pane_id')='$(printf '%s' "$id" | sed "s/'/''/g")' LIMIT 1),'unknown:pane_not_in_agent_list')" 2>/dev/null)" || return 10
  case "$activity$label$key$title" in *$'\t'*|*$'\n'*|*$'\r'*) return 10 ;; esac
  printf '%s\t%s\t%s\t%s\n' "$activity" "$label" "$key" "$title"
}

# Positive input-readiness proof for team --fix. A pane is writable only when
# Herdr itself recognizes an agent of the expected kind there and reports one of
# its measured interactive lifecycle states. A shell prompt (including an OMZ
# confirmation) is therefore not mistaken for an agent merely because it owns
# the foreground process group.
terminal_team_input_ready() {
  local id="$1" expected="$2" raw escaped kind status rc=0
  command -v herdr >/dev/null 2>&1 || { printf 'unknown:terminal_unreachable\n'; return 2; }
  _herdr_pane_id_ok "$id" || { printf 'unknown:invalid_pane_id\n'; return 2; }
  raw="$(herdr agent get "$id" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$raw" in
      *agent_not_found*) printf 'not_ready:agent_not_found\n'; return 1 ;;
      *) printf 'unknown:agent_query_failed\n'; return 2 ;;
    esac
  fi
  escaped="$(printf '%s' "$raw" | sed "s/'/''/g")"
  kind="$(sqlite3 :memory: "SELECT CASE WHEN json_type('$escaped','$.result.agent.agent')='text' THEN json_extract('$escaped','$.result.agent.agent') ELSE '' END" 2>/dev/null)" \
    || { printf 'unknown:agent_response_invalid\n'; return 2; }
  status="$(sqlite3 :memory: "SELECT CASE WHEN json_type('$escaped','$.result.agent.agent_status')='text' THEN json_extract('$escaped','$.result.agent.agent_status') ELSE '' END" 2>/dev/null)" \
    || { printf 'unknown:agent_response_invalid\n'; return 2; }
  [ -n "$kind" ] && [ -n "$status" ] \
    || { printf 'unknown:agent_response_incomplete\n'; return 2; }
  [ "$kind" = "$expected" ] \
    || { printf 'not_ready:agent_kind_mismatch\n'; return 1; }
  case "$status" in
    idle|done|working) printf 'ready\n'; return 0 ;;
    *) printf 'not_ready:agent_status_%s\n' "$status"; return 1 ;;
  esac
}

# control op: submit <text> to the agent in the pane. herdr's `agent prompt`
# submits on its own (no separate Enter, unlike tmux) — the #619 paste hazard is
# a tmux send-keys concern, not herdr's. ASSERTED argv (agent prompt <id> <text>).
terminal_poke() {
  local id="$1" text="$2"
  # Same exit taxonomy as peek: a terminal that is UNREACHABLE (herdr not on
  # PATH) is 10; a pane that cannot RECEIVE — gone, or with no live agent to accept the
  # prompt — is 12. 13 stays reserved for a driver with no poke path at all (plain's
  # permanent "no addressable pane"); a herdr pane whose agent has EXITED must not
  # borrow it. This is the peek/poke asymmetry made concrete: peek reads a pane and
  # succeeds even with no live agent, poke needs a running agent and so has a distinct
  # "no one to receive" failure that peek does not.
  command -v herdr >/dev/null 2>&1 \
    || { echo runtime_error; echo "herdr: not on PATH — cannot reach the terminal to poke pane '$id'" >&2; return 10; }
  herdr agent prompt "$id" "$text" >/dev/null 2>&1 \
    || { echo runtime_error; echo "herdr: could not deliver to pane '$id' — it may be gone, or have no live agent to receive (poke needs a running agent; peek does not)" >&2; return 12; }
  echo ok
  return 0
}

# Derive herdr's INTERNAL resolvable agent-name key from (team, agent): a
# COLLISION-RESISTANT 96-bit key (NOT injective — see below).
#
# The key must satisfy herdr's agent-name regex [a-z][a-z0-9_-]{0,31} AND, in
# practice, not collide between live members — a collision makes `herdr agent
# rename` clobber another member's addressing. FOLDING or CONCATENATING with any
# literal separator has a STRUCTURAL (deterministic, reachable) collision, because
# that separator can itself appear in a name (agmsg only forbids . / \ " [ ] control
# chars and a leading '-', so ':', '-' and '_' are all legal in team AND agent
# names):
#     ("a-b","c") and ("a","b-c")   both fold to  a-b-c
#     ("a:b","c") and ("a","b:c")   both join to  a:b:c   (the `<team>:<agent>` form too)
# We DERIVE instead: 'a' + the first 24 hex (96 bits) of SHA-256 of the pair. The
# pair is joined with a NEWLINE, a control char FORBIDDEN in both names
# (scripts/lib/validate.sh rejects [[:cntrl:]]), so the PREIMAGE encoding is
# unambiguous — this removes the structural '-'/':' ambiguity above. It is NOT
# mathematically injective: any hash of arbitrary-length input into 96 bits has
# collisions by pigeonhole. It is COLLISION-RESISTANT, which is what this needs:
# herdr requires a unique name only AMONG LIVE agents (scope Naming), a population
# of dozens in this store — 96 bits against dozens is far more than enough. A true
# no-collision guarantee would need a persistent map + collision detection (storage
# + migration), which is out of v1's scope. RECOVERY BOUNDARY on the vanishing
# chance of a collision: terminal_name's `herdr agent rename` fails, and that is
# non-fatal — the pane id in the placement record still resolves peek/poke.
#
# 'a' + 24 hex = 25 chars, leading letter, all within the regex. Uses the store's
# canonical agmsg_sha256 (lib/hash.sh); sourced context may not have it, so load it
# relative to this driver file. Prints the key, or non-zero if no SHA-256 tool.
_herdr_internal_key() {
  local team="$1" agent="$2" hex
  if ! command -v agmsg_sha256 >/dev/null 2>&1; then
    local _libd
    _libd="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" 2>/dev/null && pwd)" || return 1
    [ -n "$_libd" ] && [ -f "$_libd/hash.sh" ] && . "$_libd/hash.sh"
  fi
  command -v agmsg_sha256 >/dev/null 2>&1 || return 1
  hex="$(printf '%s\n%s' "$team" "$agent" | agmsg_sha256)" || return 1
  printf 'a%s\n' "${hex:0:24}"
}

# control op: name the pane (scope Naming). Two copies:
#   VISIBLE:    herdr pane rename <id> <team>:<agent>   (free text, ':' is fine)
#   RESOLVABLE: herdr agent rename <id> <key>           where <key> is the
#               collision-resistant SHA-256 derivation above — an INTERNAL key,
#               never shown; peek/poke go by the recorded pane id, so the user never
#               meets it. Idempotent. The visible rename is the required one; a
#               failed agent rename (a live-name collision, or no SHA-256 tool to
#               derive the key) is non-fatal — the pane id in the record still
#               resolves.
# <mode> is `key` or absent. Absent means both names; `key` means the resolvable
# one only, and the caller has already decided that (the registry reads the env
# var, so the policy lives in one place and this only carries it out).
#
# Which of the two is which matters: `pane rename` is the label a person reads,
# `agent rename` is the name herdr itself addresses the agent by, in its own
# namespace — NOT what this repo's `peek`/`poke` resolve through, which is the
# placement record's pane id. So under `key` that name is still established and
# only the decoration is skipped —
# and a key that cannot be set is an error there, because nothing else happened.
terminal_name() {
  local id="$1" team="$2" name="$3" mode="${4:-}" label key
  label="$team:$name"

  # THE KEY FIRST, and its failure is fatal.
  #
  # The reason is NOT that peek/poke resolve through the key — an earlier
  # revision of this comment said so and it is false in this tree: those commands
  # resolve through the placement record's pane id, and `_herdr_internal_key` is
  # read nowhere outside this driver. The key is the name herdr knows the agent
  # by, on its side.
  #
  # The reason that survives is the one below: the caller writes the placement
  # record only when this returns 0. Ordering the label first meant a failed
  # DECORATION returned 13 before the key was attempted and before the record was
  # written, so a member ended up with neither name and no record — the
  # requirement this driver serves broke through that door. tmux has always had
  # this order; herdr was the one driver that put the ornament in front.
  key="$(_herdr_internal_key "$team" "$name")" || { echo runtime_error; return 13; }
  herdr agent rename "$id" "$key" >/dev/null 2>&1 || { echo runtime_error; return 13; }

  # The label, and its failure is deliberately NOT fatal — the same shape tmux
  # has. Not merely for symmetry: the caller writes the placement record only
  # when this returns 0, and that record is the other half of addressing. A
  # non-zero here would therefore throw away the very thing the reordering above
  # exists to protect, for a decoration.
  if [ "$mode" != key ]; then
    herdr pane rename "$id" "$label" >/dev/null 2>&1 || true
  fi
  echo ok
  return 0
}
