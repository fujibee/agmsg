#!/usr/bin/env bash
# herdr terminal driver — a pane inside a herdr session.
#
# Sourced by the terminals registry into the caller's context. terminal_* only,
# no set -e/-u.
#
# MEASURED (seat 0, 2026-08-29) vs ASSERTED-pending-live-matrix:
#   measured: `herdr agent list` is JSON; the pane is resolved from it by the
#     session id (inherited HERDR_PANE_ID is NOT trusted; agent_session in the list
#     is an OBJECT and the id is at .value); the internal agent-name key is a
#     collision-resistant SHA-256 derivation of (team, agent) — see
#     _herdr_internal_key for why concatenation/folding has a structural collision;
#     the existing spawn/despawn calls (pane split/rename/run, tab create, pane close);
#     and `pane read --source <visible|recent|...>` (seat 0 measured the --source values).
#   asserted (exact argv/JSON fields verified only by the live matrix on koit's
#     machine, NOT measured here): the `agent list` JSON field names used to
#     extract the pane (agent_session / pane_id), `herdr agent prompt`'s argv for
#     poke, and `herdr agent rename`'s argv for the internal name key (no existing
#     agent-rename call in main to measure against). These are flagged inline and
#     in the PR body; the fixtures pin the control flow and the argv THIS driver
#     emits, so a real-CLI mismatch is a localized one-line fix the matrix catches.

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
  printf 'capabilities=spawn despawn peek poke name\n'
}

# Extract the pane id whose agent_session == <sid> from `herdr agent list` JSON.
# Uses sqlite3 JSON1 (the codebase's no-jq convention). ASSERTED field names
# (agent_session, pane_id) — verified by the live matrix. Prints the pane id, or
# nothing (empty) if no entry matches.
# Resolve <sid> to a pane via `agent list`, distinguishing THREE outcomes so the
# caller can give an honest reason (co1/tl 2026-08-31):
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
  local q pane qrc sesc queried=0 jtype jtrc alen arc well wrc
  sesc="$(printf '%s' "$sid" | sed "s/'/''/g")"
  # POSITIVE PROOF, one layer down (co1/tl 2026-09-01, 3rd instance of the same
  # shape — do not grab the proxy before the state it stands for). The answer here
  # depends on "the session id was COMPARED against a real agent entry". So the
  # positive proof is "at least one entry of the EXPECTED SHAPE existed", NOT "the
  # container was an array" (json_type=array only closes {} / unknown wrapper). A
  # non-empty array of the wrong entry shape — [1], [{}], or the old scalar
  # agent_session — json_eaches to 0 matching rows and would be MISREAD as
  # "answered, session not present". Three outcomes per candidate array path:
  #   empty array (len 0)            -> answered, no agents (queried, not-among)
  #   non-empty, 0 expected entries  -> could NOT answer (schema drift, return 2)
  #   non-empty, >=1 expected entry  -> queried; search the session among them
  # EXPECTED SHAPE (measured, herdr 0.8.0 read-only): entry is an object, pane_id is
  # text, agent_session is an object whose .value is text (the session id is in
  # .value, NOT the object itself). Candidate paths: $.result.agents is the measured
  # location; the others are version-defensive.
  for q in '$.result.agents' '$' '$.agents' '$.result'; do
    jtrc=0
    jtype="$(sqlite3 :memory: "SELECT json_type('$jesc', '$q')" 2>/dev/null)" || jtrc=$?
    [ "$jtrc" -eq 0 ] || return 2       # sqlite unavailable / JSON unparseable -> could not answer
    [ "$jtype" = array ] || continue    # no array at this path -> not this shape (a valid {} lands here)
    arc=0
    alen="$(sqlite3 :memory: "SELECT json_array_length('$jesc', '$q')" 2>/dev/null)" || arc=$?
    [ "$arc" -eq 0 ] || return 2
    if [ "${alen:-0}" -eq 0 ]; then queried=1; continue; fi   # empty list -> answered, no agents
    # Count entries that satisfy the measured entry shape.
    wrc=0
    well="$(sqlite3 :memory: "
      SELECT count(*) FROM json_each('$jesc', '$q')
      WHERE json_type(value) = 'object'
        AND json_type(value,'\$.pane_id') = 'text'
        AND json_type(value,'\$.agent_session') = 'object'
        AND json_type(value,'\$.agent_session.value') = 'text'" 2>/dev/null)" || wrc=$?
    [ "$wrc" -eq 0 ] || return 2
    # Search the session among the well-formed entries. A positive find is decisive
    # regardless of any malformed siblings — we located the pane.
    qrc=0
    pane="$(sqlite3 :memory: "
      SELECT json_extract(value,'\$.pane_id')
      FROM json_each('$jesc', '$q')
      WHERE json_type(value,'\$.agent_session') = 'object'
        AND json_extract(value,'\$.agent_session.value') = '$sesc'
      LIMIT 1" 2>/dev/null)" || qrc=$?
    [ "$qrc" -eq 0 ] || return 2
    [ -n "$pane" ] && [ "$pane" != "null" ] && { printf '%s\n' "$pane"; return 0; }
    # No match. ABSENCE is only provable if the WHOLE set was comparable — every
    # entry well-formed (co1, one layer further: >=1 well-formed proves some entries
    # are readable, not that the target is not hiding in a malformed one). A single
    # malformed sibling means the session could be there unread: could not answer.
    [ "${well:-0}" -eq "${alen:-0}" ] || return 2
    queried=1   # every entry was comparable and none matched -> answered, not among
  done
  # No candidate path held a recognizable agent list (all unknown/ill-formed) =>
  # could not answer. Only a real array (empty, or well-formed with no match)
  # reaches here with queried=1 => answered, not among.
  [ "$queried" = 1 ] || return 2
  return 0
}

# record op: we are under herdr iff HERDR_ENV=1 and herdr is on PATH. Resolve
# THIS session's pane from the session id via agent list (NOT inherited
# HERDR_PANE_ID). Non-zero if not under herdr or the pane cannot be resolved.
terminal_detect() {
  local sid="${1:-}"
  # PRESENCE (exit code) is HERDR_ENV=1 ALONE: whether herdr is on PATH is a
  # terminal_check question ("can I operate it"), NOT "which terminal am I in"
  # (co1/tl 2026-08-31). Conflating them would make a herdr session with no herdr
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
_herdr_new_pane_id() {
  local json="$1" q pane
  for q in '$.result.pane.pane_id' '$.result.root_pane.pane_id' '$.pane.pane_id' '$.root_pane.pane_id'; do
    pane="$(sqlite3 :memory: "SELECT json_extract('$(printf '%s' "$json" | sed "s/'/''/g")', '$q')" 2>/dev/null)"
    [ -n "$pane" ] && [ "$pane" != "null" ] && { printf '%s\n' "$pane"; return 0; }
  done
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
  herdr pane run "$pane" "$boot" >/dev/null 2>&1 || return 13
  printf '%s\n' "$pane"
  return 0
}

# control op: close the herdr pane named by the bare id.
terminal_despawn() {
  local id="$1"
  herdr pane close "$id" >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
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
  herdr pane read "$id" --source "$src" || return 13
  return 0
}

# control op: submit <text> to the agent in the pane. herdr's `agent prompt`
# submits on its own (no separate Enter, unlike tmux) — the #619 paste hazard is
# a tmux send-keys concern, not herdr's. ASSERTED argv (agent prompt <id> <text>).
terminal_poke() {
  local id="$1" text="$2"
  herdr agent prompt "$id" "$text" >/dev/null 2>&1 || { echo runtime_error; return 13; }
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
#     ("a:b","c") and ("a","b:c")   both join to  a:b:c   (tl's `<team>:<agent>` too)
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
terminal_name() {
  local id="$1" team="$2" name="$3" label key
  label="$team:$name"
  herdr pane rename "$id" "$label" >/dev/null 2>&1 || { echo runtime_error; return 13; }
  if key="$(_herdr_internal_key "$team" "$name")"; then
    herdr agent rename "$id" "$key" >/dev/null 2>&1 || true
  fi
  echo ok
  return 0
}
