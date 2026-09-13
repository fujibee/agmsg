#!/usr/bin/env bash
# self-proof.sh — is THIS seat's process structurally bound to THIS pane? (#1152)
#
# THE ONE PLACE THAT SAYS PROVED. A driver observes; this file classifies. Every
# other layer hands up facts and never a verdict, because a four-valued answer
# produced in two places is two answers: the same lock file was once called
# `free` by one producer and `unknown:owner_empty` by another, and nothing in the
# tree said which was right (#1071). So drivers here return a RECORD or a
# failure, and the words below exist in this file only.
#
# WHY A PROOF AND NOT A TYPE. The obvious shortcut is a list -- "claude-code runs
# in its pane, codex does not". It was measured false inside one team on one
# machine: of six seats, four had their recorded owner pid inside the claimed
# pane and two did not, and one of the two was claude-code (a background job,
# whose lineage is `claude bg-spare` -> `claude bg-pty-host` -> launchd and
# reaches no pane at all). A list would have called that seat safe and written
# into somebody else's pane. A proof stops on its own when it stops holding.
#
# THE FOUR STATES. stdout is always exactly one line, `state<TAB>payload`, and
# the exit status carries the same thing so a caller that reads only one of them
# cannot read a different answer than a caller that reads the other:
#
#   rc 0   proved<TAB><canonical-ref>   the pane's process is in the owner's
#                                       complete ancestry
#   rc 1   disproved<TAB><reason>       it is NOT, and the observation was whole
#   rc 2   undetermined<TAB><reason>    we could not tell
#   rc 3   unsupported<TAB><reason>     this configuration cannot answer at all
#
# There is deliberately no top-level `unreadable`: that word already means
# something in the pure classifier (self-identity.sh) and one word with two
# meanings passes a caller that handled only one of them. A failed read here is
# `undetermined:pane_process_unreadable`.
#
# ONLY `proved` MAY RAISE A PERMISSION. The reason word is part of the contract
# so it can drive diagnostics and retry policy, and for no other purpose: a
# caller that branches on a reason to decide whether to write has re-derived the
# verdict from a diagnostic. A test pins that.
#
# WHAT `disproved` CLAIMS, and what it costs to claim it. `disproved` says the
# absence was SEEN. That is only true when the ancestry walk finished on its own
# and the pane observation was whole -- a walk that stopped because a `ps` failed
# produces an empty intersection that is indistinguishable from a real one. Every
# incomplete walk is `undetermined`, never a negative. This is the axis the
# review flagged first and it is the one that would be silently wrong.

# THE CALLER'S SHELL IS NOT THIS FILE'S SHELL. Everything here is SOURCED, so
# `set -e`, `set -u`, `set -o pipefail`, `nocasematch` and `extglob` are the
# CALLER's settings and they are in force inside these functions. That has
# already produced two defects on this branch -- a `case` alphabet widened by
# `nocasematch`, and `x="$(cmd)"; rc=$?` killing the shell under `set -e` before
# the verdict could be printed -- and both passed a suite that ran with the
# defaults. The suite now reruns itself under each of those states; see
# tests/test_self_proof.bats. The rule here is: capture a status with
# `if x="$(cmd)"; then rc=0; else rc=$?; fi`, never with a bare assignment
# followed by `$?`.

[ -n "${_AGMSG_SELF_PROOF_SH:-}" ] && return 0
_AGMSG_SELF_PROOF_SH=1

# Walking someone's ancestry is unbounded work if the table lies to us.
_AGMSG_PROOF_ANCESTRY_MAX=256

# A canonical positive integer, decided without a shell pattern.
#
# `[0-9]` is a glob RANGE, and a range is widened by the locale on bash 3.2 (the
# macOS /bin/bash) exactly as `[a-z]` is -- measured in #1152. A pid is the input
# to a comparison that decides whether this seat may write into a pane, so it is
# checked with literal equality, through the one helper that already exists for
# that job.
_agmsg_proof_pid_ok() {   # <candidate>
  local v="${1-}"
  [ -n "$v" ] || return 1
  # No leading zero: `0123` and `123` are the same pid to `ps` and different
  # strings to the intersection test below, and two spellings of one pid is a
  # comparison that can miss.
  [ "${v#0}" = "$v" ] || return 1
  _agmsg_self_chars_in_set "$v" "0123456789" || return 1
  [ "$v" != "0" ] || return 1
  return 0
}

# The ancestry of <pid>, one per line, the pid itself first.
#
#   rc 0  complete -- the walk reached pid 1 on its own
#   rc 1  truncated -- a parent could not be read, or was not a pid
#   rc 2  a cycle
#   rc 3  the bound was reached
#
# A non-zero rc means the LIST IS NOT THE ANCESTRY. Callers must not treat it as
# a short one.
_agmsg_proof_ancestry() {   # <pid>
  local p="${1-}" seen="" n=0 pp
  _agmsg_proof_pid_ok "$p" || return 1
  while :; do
    printf '%s\n' "$p"
    seen="$seen $p"
    [ "$p" = 1 ] && return 0
    n=$((n + 1))
    [ "$n" -le "$_AGMSG_PROOF_ANCESTRY_MAX" ] || return 3
    # `ps` printing nothing is a FAILED READ, not "no parent": the pipeline
    # exits 0 either way (`tr` decides the status), so the value is validated
    # rather than the status believed.
    pp="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    _agmsg_proof_pid_ok "$pp" || return 1
    # Literal, and against whole fields: `seen` is a list of pids, so a glob
    # test would also be a locale/nocasematch question, and a substring test
    # would find 234 inside 1234. Unquoted on purpose -- these are digits.
    # shellcheck disable=SC2086
    if _agmsg_proof_pid_in "$pp" $seen; then return 2; fi
    p="$pp"
  done
}

# Is <needle> one of the whitespace-separated pids in <haystack>?
# Literal equality against whole fields -- a substring test would make 234 a hit
# inside 1234.
_agmsg_proof_pid_in() {   # <needle> <haystack...>
  local needle="${1-}" p
  shift || return 1
  for p in "$@"; do
    [ "$p" = "$needle" ] && return 0
  done
  return 1
}

# One driver observation, framed.
#
# The driver's record is `<canonical-id><TAB><pid>[<TAB><pid>…]` on exactly one
# line. Everything about it is checked HERE rather than trusted: a record with a
# missing field, a second line, a pid that is not a pid, or the SAME pid twice is
# an observation we do not understand, and answering from the part we do
# understand would be a count over an input nobody read.
#
# A DUPLICATE IS MALFORMED, not a set to be deduplicated. Two spellings of one
# process in a record that is supposed to enumerate them means the driver's
# enumeration is not what this file thinks it is, and quietly collapsing it would
# hide exactly that.
#
# Prints the framed record unchanged on rc 0. rc 1 means malformed.
_agmsg_proof_frame() {   # <record>
  local rec="${1-}" line id rest p q n=0 seen=""
  [ -n "$rec" ] || return 1
  # Exactly one line. `printf %s` adds none, so a second line can only be the
  # driver's.
  line="$(printf '%s' "$rec" | head -1)"
  [ "$line" = "$rec" ] || return 1
  id="${rec%%	*}"; rest="${rec#*	}"
  [ "$rest" != "$rec" ] || return 1
  [ -n "$id" ] || return 1
  # A control byte in the id would travel into a ref that later reaches a shell.
  # FRAMING ONLY: which ids are legal for a driver is that driver's question --
  # tmux socket refs carry ordinary spaces.
  case "$id" in *[[:cntrl:]]*) return 1 ;; esac
  # shellcheck disable=SC2086
  for p in $rest; do
    _agmsg_proof_pid_ok "$p" || return 1
    # shellcheck disable=SC2086
    for q in $seen; do [ "$q" = "$p" ] && return 1; done
    seen="$seen $p"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || return 1
  printf '%s\n' "$rec"
}

# Give every pid in a framed record its process IDENTITY, not just its number.
#
# A PID IS ONLY A NAME WHILE ITS PROCESS LIVES. Between the two observations this
# proof makes, a pane process can exit and its number be handed to something
# else; the record would read identically and the intersection would still be
# there, and the proof would join an old ancestry to a new process. So each pid
# is paired with its start time, and the pair is what gets compared.
#
# NO FALLBACK. A pid whose start cannot be read makes the WHOLE observation
# unusable (rc 1). An earlier revision degraded a missing token to `-` and then
# went on to answer proved or disproved: that is a verdict resting on the one
# fact we failed to obtain. Not knowing is `undetermined`, above.
#
# Prints `<canonical-id><TAB><pid>=<start>…`; rc 1 if any identity is missing.
_agmsg_proof_identify() {   # <framed-record>
  local rec="${1-}" id rest p start out
  id="${rec%%	*}"; rest="${rec#*	}"
  [ -n "$id" ] && [ "$rest" != "$rec" ] || return 1
  out="$id"
  # shellcheck disable=SC2086
  for p in $rest; do
    # Whitespace collapses to `_` so the tuple stays one word: the comparison
    # below splits on whitespace, and a start time is full of spaces.
    start="$(ps -o lstart= -p "$p" 2>/dev/null | tr -s '[:space:]' '_')"
    start="${start#_}"; start="${start%_}"
    [ -n "$start" ] || return 1
    case "$start" in *[[:cntrl:]]*) return 1 ;; esac
    out="$out	$p=$start"
  done
  printf '%s\n' "$out"
}

_agmsg_proof_say() {   # <state> <payload> <rc>
  printf '%s\t%s\n' "$1" "$2"
  return "$3"
}

# The proof.
#
#   agmsg_self_proof <team> <agent> <candidate>
#
# <team>/<agent> name the ROLE whose ownership record is the authority. They are
# not an authority about a process: the pid comes out of the recorded composite
# owner, never from the caller and never from `$$`. A caller that could hand in
# a pid could hand in one that happens to sit in the pane it wants.
#
# <candidate> is a SEARCH SCOPE, not an authority either. The ref that comes back
# with `proved` is the one the DRIVER observed for that candidate, revalidated
# here -- echoing the caller's string back would let a caller read its own input
# as a confirmation.
agmsg_self_proof() {   # <team> <agent> <candidate>
  local team="${1-}" agent="${2-}" cand="${3-}"
  local rd kind owner osid opid anc arc orc obs1 obs2 id1 id2 canon pids rest p
  local rd2 owner2 term ref

  # A driver that cannot observe a pane's processes is not a driver that failed:
  # it is a configuration in which this question has no answer. Kept apart from
  # `undetermined` so a caller can stop asking instead of retrying forever.
  declare -F terminal_pane_process_observe >/dev/null 2>&1 \
    || _agmsg_proof_say unsupported driver_no_process_binding 3 || return 3

  # A driver that can observe processes but declares no id grammar would make the
  # revalidation below a no-op: `_agmsg_terminal_id_ok` ACCEPTS ANYTHING for a
  # loaded driver that defines no `terminal_id_ok` (measured -- it is the
  # registry's documented policy, and it is the right default for the ops that
  # only pass an id along). Here the id becomes a ref this seat will act on, so
  # the absent grammar is a missing guard rather than a lenient one, and the
  # answer is that this configuration cannot support the question.
  declare -F terminal_id_ok >/dev/null 2>&1 \
    || _agmsg_proof_say unsupported driver_no_ref_grammar 3 || return 3

  [ -n "$team" ] && [ -n "$agent" ] \
    || _agmsg_proof_say undetermined role_not_named 2 || return 2
  [ -n "$cand" ] \
    || _agmsg_proof_say undetermined no_candidate 2 || return 2

  # --- the owner, and the root that comes out of it -------------------------
  rd="$(actas_lock_read "$team" "$agent")" \
    || _agmsg_proof_say undetermined owner_unreadable 2 || return 2
  kind="${rd%%	*}"; owner="${rd#*	}"
  [ "$kind" = ok ] || {
    # `absent` and `unreadable` are DIFFERENT things and neither is "no owner":
    # one says we looked, the other says we could not.
    if [ "$kind" = absent ]; then
      _agmsg_proof_say undetermined owner_absent 2; return 2
    fi
    _agmsg_proof_say undetermined owner_unreadable 2; return 2
  }
  [ -n "$owner" ] \
    || _agmsg_proof_say undetermined owner_empty 2 || return 2
  osid="${owner%.*}"; opid="${owner##*.}"
  [ "$osid" != "$owner" ] \
    || _agmsg_proof_say undetermined owner_not_composite 2 || return 2
  _agmsg_proof_pid_ok "$opid" \
    || _agmsg_proof_say undetermined owner_pid_invalid 2 || return 2

  # A RECORDED OWNER IS NOT A VERIFIED ONE. Parsing a pid out of the lock says
  # the file holds a number, not that the number is still this session. A pid is
  # reused; a lock outlives the process that wrote it. Without this, a stale
  # `<sid>.<pid>` whose number has been handed to some other process would be
  # walked as if it were the seat -- and if that process happens to sit in a
  # pane, the seat is `proved` into a pane it has never been in.
  #
  # `agmsg_instance_alive` is the three-valued verifier that already exists for
  # exactly this: it checks the pid AND the instance marker, so a reused pid
  # shows up as a marker mismatch rather than as a live process. Its three values
  # stay three here -- `dead` and `cannot tell` are different reasons, and
  # neither is a negative about the pane.
  if agmsg_instance_alive "$owner"; then arc=0; else arc=$?; fi
  # Alive is not identity. agmsg_instance_alive reads an ABSENT marker as alive,
  # and that is the conservative side for the LOCK it serves (nothing contradicts
  # a live pid, so do not reclaim). Here the same default is the dangerous side:
  # an absent marker means the number is alive but nothing says whose it is, and
  # a pid reused by a stranger would be walked as the owner and proved into the
  # stranger's pane (#1187, measured 2026-09-13). So this file asks for the marker
  # itself and does NOT share the lock's default -- keep them apart on purpose.
  if [ "$arc" -eq 0 ]; then
    local _mk; _mk="$(_agmsg_marker_read "${SKILL_DIR:?self-proof.sh requires SKILL_DIR}/run/cc-instance.$opid")"
    case "${_mk%%	*}" in
      ok) ;;
      absent) _agmsg_proof_say undetermined owner_marker_absent 2; return 2 ;;
      *)      _agmsg_proof_say undetermined owner_liveness_unknown 2; return 2 ;;
    esac
  fi
  case "$arc" in
    0) : ;;
    1) _agmsg_proof_say undetermined owner_not_alive 2; return 2 ;;
    *) _agmsg_proof_say undetermined owner_liveness_unknown 2; return 2 ;;
  esac

  # THIS invocation must be inside the owner it is speaking for. Without this the
  # proof is about a process that merely shares a role name -- measured: a seat's
  # tool invocations can run under a launchd-parented daemon while the recorded
  # owner sits in the pane, and the reverse. Either way the answer is about
  # whoever we rooted at, so the two have to be joined explicitly.
  # The binding is settled the moment the owner appears, so the walk's own rc is
  # read AFTER the membership test, not before it. Rooted the other way round, a
  # `ps` that failed somewhere ABOVE the owner -- a part of the tree this
  # question does not care about -- would report the seat as unbound. What is
  # above the owner is the owner walk's business, below.
  if anc="$(_agmsg_proof_ancestry "$$")"; then arc=0; else arc=$?; fi
  # shellcheck disable=SC2086
  if ! _agmsg_proof_pid_in "$opid" $anc; then
    # Not found. That only MEANS "not bound" if we saw the whole chain.
    [ "$arc" -eq 0 ] \
      && { _agmsg_proof_say undetermined invocation_not_bound_to_owner 2; return 2; }
    _agmsg_proof_say undetermined invocation_ancestry_truncated 2
    return 2
  fi

  # --- the pane, before -----------------------------------------------------
  # The driver's exit status separates two causes that both mean "no record",
  # and keeping them apart costs nothing: 13 is "that is not an id for me" (the
  # candidate never named a pane), anything else is "I could not reach it". Both
  # are `undetermined` -- the REASON never changes what a caller may do -- but a
  # caller reading the reason to decide whether to retry needs them apart.
  if obs1="$(terminal_pane_process_observe "$cand" 2>/dev/null)"; then orc=0; else orc=$?; fi
  [ "$orc" -eq 0 ] || {
    if [ "$orc" -eq 13 ]; then
      _agmsg_proof_say undetermined candidate_not_well_formed 2; return 2
    fi
    _agmsg_proof_say undetermined pane_process_unreadable 2; return 2
  }
  obs1="$(_agmsg_proof_frame "$obs1")" \
    || _agmsg_proof_say undetermined observation_malformed 2 || return 2
  id1="$(_agmsg_proof_identify "$obs1")" \
    || _agmsg_proof_say undetermined process_identity_unreadable 2 || return 2

  # --- the owner's ancestry -------------------------------------------------
  if anc="$(_agmsg_proof_ancestry "$opid")"; then arc=0; else arc=$?; fi
  case "$arc" in
    0) : ;;
    2) _agmsg_proof_say undetermined ancestry_cycle 2; return 2 ;;
    3) _agmsg_proof_say undetermined ancestry_limit 2; return 2 ;;
    *) _agmsg_proof_say undetermined ancestry_truncated 2; return 2 ;;
  esac

  # --- the pane, after ------------------------------------------------------
  # A pid is only a name for a process while that process lives, and the walk
  # above took time. If the pane's record changed underneath it, the comparison
  # would be across two generations and an empty intersection would mean nothing.
  obs2="$(terminal_pane_process_observe "$cand" 2>/dev/null)" \
    || _agmsg_proof_say undetermined pane_process_unreadable 2 || return 2
  obs2="$(_agmsg_proof_frame "$obs2")" \
    || _agmsg_proof_say undetermined observation_malformed 2 || return 2
  id2="$(_agmsg_proof_identify "$obs2")" \
    || _agmsg_proof_say undetermined process_identity_unreadable 2 || return 2
  # The TUPLES, not the pids: the record can be identical while the processes
  # behind it are not.
  [ "$id1" = "$id2" ] \
    || _agmsg_proof_say undetermined snapshot_changed 2 || return 2

  # --- the owner, again -----------------------------------------------------
  # The role can change hands while all of the above is happening, and a proof
  # about the previous holder is not a proof about this one.
  rd2="$(actas_lock_read "$team" "$agent")" \
    || _agmsg_proof_say undetermined owner_unreadable 2 || return 2
  owner2="${rd2#*	}"
  [ "$rd2" = "ok	$owner" ] || {
    _agmsg_proof_say undetermined owner_changed 2; return 2
  }

  canon="${obs1%%	*}"
  pids="${obs1#*	}"

  # The ref that leaves here is the DRIVER's own observation of the pane, run
  # through the same grammar every other ref in the tree goes through, and
  # qualified with the terminal so it cannot be read against the wrong server.
  # The caller's candidate is never echoed back: a caller reading its own input
  # as a confirmation is how a proof becomes a mirror.
  #
  # The terminal name comes from the REGISTRY's record of which driver it loaded,
  # not from an argument -- an argument could name a terminal whose grammar is
  # laxer than the one whose ops actually answered.
  term="${_AGMSG_TERMINAL_LOADED:-}"
  [ -n "$term" ] \
    || _agmsg_proof_say undetermined no_driver_loaded 2 || return 2
  _agmsg_terminal_id_ok "$term" "$canon" \
    || _agmsg_proof_say undetermined canonical_ref_invalid 2 || return 2
  ref="$(agmsg_terminal_ref "$term" "$canon")" \
    || _agmsg_proof_say undetermined canonical_ref_invalid 2 || return 2

  # shellcheck disable=SC2086
  for p in $pids; do
    # shellcheck disable=SC2086
    if _agmsg_proof_pid_in "$p" $anc; then
      _agmsg_proof_say proved "$ref" 0
      return 0
    fi
  done

  # Everything above established that the walk finished on its own and that both
  # observations agreed, so this empty intersection is a SEEN absence.
  _agmsg_proof_say disproved pane_process_not_ancestor 1
  return 1
}
