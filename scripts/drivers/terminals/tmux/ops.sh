#!/usr/bin/env bash
# tmux terminal driver — a pane/window inside a tmux server.
#
# Sourced by the terminals registry into the caller's context. terminal_* only,
# no set -e/-u. Faithful to the pre-axis inline calls in spawn.sh / despawn.sh /
# watch.sh so the migration is a drop-in.

# control op: tmux binary present?
terminal_check() {
  if command -v tmux >/dev/null 2>&1; then echo ok; return 0; fi
  printf 'AGMSG-DIRECTIVE: {"type":"install_deps","driver":"terminals/tmux","reason":"tmux not found"}\n'
  echo missing_deps
  return 10
}

terminal_describe() {
  printf 'name=tmux\n'
  printf 'backend=tmux pane/window\n'
  printf 'capabilities=spawn despawn peek poke where arrange name\n'
  printf 'syntax_help=tmux list-commands\n'
  printf 'intent.place_below=tmux move-pane -s SOURCE -t TARGET -v\n'
  printf 'intent.place_right=tmux move-pane -s SOURCE -t TARGET -h\n'
}

# READ op: print the window containing <id>. This answers WHERE only and never
# treats an unresolved location as proof that the pane is gone.
terminal_where() {
  local id="$1" out container sock bare
  command -v tmux >/dev/null 2>&1 || { echo unknown; return 10; }
  # Split the server off first: a ref now carries the socket that owns the pane,
  # and both the kind test below and the listing have to see the bare id or a
  # socket-qualified ref is read as an unknown kind (unsupported/13) while the
  # listing goes to whichever server happens to be ambient.
  sock="$(_tmux_sock_of "$id")"; bare="$(_tmux_bare_of "$id")"
  # A window placement (@N) is its own container.
  case "$bare" in @*) printf '%s\n' "$id"; return 0 ;; %*) : ;; *) echo unsupported; return 13 ;; esac
  out="$(_tmux_do "$id" list-panes -a -F '#{pane_id}|#{window_id}' 2>/dev/null)" \
    || { echo unknown; return 10; }
  container="$(printf '%s\n' "$out" | awk -F '|' -v id="$bare" '$1 == id { print $2; exit }')"
  if [ -z "$container" ]; then
    echo unknown
    echo "tmux: the pane listing answered but did not contain '$id'; pane existence must be checked separately" >&2
    return 10
  fi
  # The answer is exactly as server-qualified as the question: a window id is no
  # more unique across servers than a pane id, so a container derived from a
  # socket-qualified ref keeps the socket, and one derived from a legacy bare id
  # stays bare rather than gaining a precision it does not have.
  if [ -n "$sock" ]; then printf '%s:%s\n' "$sock" "$container"; else printf '%s\n' "$container"; fi
  return 0
}

# True iff source already occupies the exact split that the native move would
# create. tmux exposes geometry, not a split tree, so this is intentionally a
# visible-rectangle predicate. The +1 is tmux's separator cell.
_tmux_arranged() {
  local intent="$1" st="$2" sl="$3" sw="$4" sh="$5" tt="$6" tl="$7" tw="$8" th="$9"
  case "$intent" in
    place_below) [ "$sl" -eq "$tl" ] && [ "$sw" -eq "$tw" ] && [ "$st" -eq $((tt + th + 1)) ] ;;
    place_right) [ "$st" -eq "$tt" ] && [ "$sh" -eq "$th" ] && [ "$sl" -eq $((tl + tw + 1)) ] ;;
    *) return 2 ;;
  esac
}

_tmux_layout_numbers_ok() {
  local value
  for value in "$@"; do case "$value" in ''|*[!0-9]*) return 1 ;; esac; done
  return 0
}

terminal_arrange() {
  local source="$1" intent="$2" target="$3" out srow trow
  local ssock sbare tsock tbare
  local sid swin st sl sw sh tid twin tt tl tw th
  command -v tmux >/dev/null 2>&1 || { echo runtime_error; return 10; }
  ssock="$(_tmux_sock_of "$source")"; sbare="$(_tmux_bare_of "$source")"
  tsock="$(_tmux_sock_of "$target")"; tbare="$(_tmux_bare_of "$target")"
  case "$sbare:$tbare" in %*:%*) : ;; *) echo unsupported; return 13 ;; esac
  # Both panes must live on the SAME server, and it must be established rather
  # than assumed. A pane cannot be moved between servers, and one server's
  # listing cannot decide another's layout. Mixed precision is refused for the
  # same reason: a bare id names no server, so "same server" is not a fact — and
  # unlike a read, this op MUTATES, so the unestablished case must not proceed.
  [ "$ssock" = "$tsock" ] || { echo unsupported; return 13 ;}
  case "$intent" in place_below|place_right) : ;; *) echo unsupported; return 13 ;; esac
  out="$(_tmux_do "$source" list-panes -a -F '#{pane_id}|#{window_id}|#{pane_top}|#{pane_left}|#{pane_width}|#{pane_height}' 2>/dev/null)" \
    || { echo runtime_error; return 10; }
  srow="$(printf '%s\n' "$out" | awk -F '|' -v id="$sbare" '$1 == id { print; exit }')"
  trow="$(printf '%s\n' "$out" | awk -F '|' -v id="$tbare" '$1 == id { print; exit }')"
  [ -n "$srow" ] && [ -n "$trow" ] || { echo unknown; return 10; }
  IFS='|' read -r sid swin st sl sw sh <<< "$srow"
  IFS='|' read -r tid twin tt tl tw th <<< "$trow"
  _tmux_layout_numbers_ok "$st" "$sl" "$sw" "$sh" "$tt" "$tl" "$tw" "$th" \
    || { echo runtime_error; return 10; }
  [ "$swin" = "$twin" ] && _tmux_arranged "$intent" "$st" "$sl" "$sw" "$sh" "$tt" "$tl" "$tw" "$th" \
    && { echo unchanged; return 0; }
  case "$intent" in
    place_below) _tmux_do "$source" move-pane -s "$sbare" -t "$tbare" -v >/dev/null 2>&1 ;;
    place_right) _tmux_do "$source" move-pane -s "$sbare" -t "$tbare" -h >/dev/null 2>&1 ;;
  esac || { echo runtime_error; return 12; }
  echo moved
  return 0
}

# record op: report TWO facts and decide nothing (2026-08-31). PRESENCE — are
# we under tmux — is the exit code: 0 iff $TMUX is set (we ARE in tmux, whether or
# not we can name our own pane). SELF-ID is stdout: $TMUX_PANE, which may be EMPTY
# — that is the third value "could not resolve", NOT "not tmux"; the reason goes
# to stderr so a caller that needs the id (resolve-for-name) can report WHY. A
# caller that only needs the terminal (resolve-for-placement) uses the exit code
# and ignores the id. A missing tmux BINARY is a terminal_check concern (we are
# still under tmux). The session id arg is unused — tmux reports via the env.
terminal_detect() {
  [ -n "${TMUX:-}" ] || return 1
  if [ -n "${TMUX_PANE:-}" ]; then
    # `<socket>:<pane>`, so whatever records this can later ask the RIGHT server.
    # $TMUX is "<socket-path>,<pid>,<session>"; the first field is the socket.
    printf '%s:%s\n' "${TMUX%%,*}" "$TMUX_PANE"
  else
    echo "tmux: \$TMUX_PANE is unset — cannot identify this pane" >&2
  fi
  return 0
}

# A tmux id may carry the SERVER it belongs to: `<socket-path>:%1`, or a bare
# `%1` for a record written before this existed.
#
# It has to, because a pane id is not unique across servers — measured: two
# throwaway servers both had `%0`, and each answered "yes, I know %0" about the
# other's pane. Without the socket, "is this pane still there?" cannot be asked
# of the right authority, and a wrong answer deletes the placement record (#1051).
#
# The socket must be SPLIT OFF before the id reaches `-t`, never passed through:
# measured, `tmux kill-pane -t '<socket>:%0'` is read as session:window, prints
# "can't find window: %0" and closes NOTHING. Silent no-op, not a wrong kill —
# but a teardown that did nothing while looking like it ran is exactly this
# issue's shape.
#
# Split on the LAST colon: a socket path may contain one.
_tmux_sock_of() { case "$1" in *:*) printf '%s' "${1%:*}" ;; *) printf '' ;; esac; }
_tmux_bare_of() { printf '%s' "${1##*:}"; }

# Run tmux against the server that owns <id>. With no socket in the id this is
# plain `tmux`, which is what a legacy record gets and what the ambient
# environment decides — the honest behaviour for a ref that does not say.
_tmux_do() {   # <id> <tmux args...>
  local id="$1"; shift
  local sock; sock="$(_tmux_sock_of "$id")"
  if [ -n "$sock" ]; then tmux -S "$sock" "$@"; else tmux "$@"; fi
}

# Positive proof that a captured id is a tmux id of the expected KIND: a pane is
# %<n>, a window is @<n>, n a non-negative integer (tmux docs). Without this the
# driver would accept whatever tmux printed — exit-0 garbage, a wrong-kind id, or a
# value with a newline — and the caller would record `tmux:<raw>`, breaking the
# <terminal>:<id> record framing (newline) or leaving despawn unable to act
# (wrong-kind/garbage). $1 = id, $2 = expected sigil ('%' or '@').
_tmux_id_ok() {
  local id="$1" sigil="$2" rest="${1#"$2"}"
  [ "$rest" != "$id" ] || return 1               # id actually started with the sigil
  case "$rest" in ''|*[!0-9]*) return 1 ;; esac   # >=1 char after it, all decimal
  return 0
}

# record op: create a pane/window, launch the boot command, print the new bare
# id (%N for a pane, @N for a window). Usage:
#   terminal_spawn <name> <project> <target> <boot...>
# <target> fully specifies the placement (no ambient config): 'window', or
# 'pane-h' / 'pane-v' for a horizontal / vertical split. Mirrors spawn.sh's tmux
# placement faithfully. The captured id is validated against its expected kind
# BEFORE it is named or returned, so a garbage/wrong-kind/newline id fails closed.
terminal_spawn() {
  local name="$1" project="$2" target="$3"; shift 3
  local id dir
  case "$target" in
    window)
      id="$(tmux new-window -P -F '#{window_id}' -n "$name" -c "$project" "$@")" || return 13
      _tmux_id_ok "$id" '@' || return 13
      tmux set-window-option -t "$id" automatic-rename off >/dev/null 2>&1 || true
      ;;
    pane-h|pane-v)
      case "$target" in pane-h) dir=-h ;; *) dir=-v ;; esac
      # #990: split the CALLER's pane, not the attached client's active window. With
      # no -t, tmux resolves the target from the ATTACHED client, so a spawn from one
      # agent's pane can land in ANOTHER agent's window when several share the server.
      # $TMUX_PANE is the caller's pane (tmux sets it in every pane; the tmux
      # equivalent of herdr's $HERDR_PANE_ID). Require it and target it EXPLICITLY —
      # not observing the caller's pane is NOT evidence the ambient target is the
      # caller, so fail closed rather than guess (positive-proof). A window
      # target does not need it and is handled above.
      [ -n "${TMUX_PANE:-}" ] \
        || { printf 'unsupported: a tmux split needs $TMUX_PANE to target the caller pane (#990)\n' >&2; return 13; }
      id="$(tmux split-window "$dir" -t "$TMUX_PANE" -P -F '#{pane_id}' -c "$project" "$@")" || return 13
      _tmux_id_ok "$id" '%' || return 13
      tmux select-pane -t "$id" -T "$name" >/dev/null 2>&1 || true
      ;;
    *) printf 'unsupported: unknown target: %s (window|pane-h|pane-v)\n' "$target" >&2; return 13 ;;
  esac
  # Socket-qualified, the same shape terminal_detect emits: whoever records this
  # id must be able to ask the server that owns it, not whichever one they can
  # reach. A spawn always happens from inside a tmux server, so $TMUX is set.
  if [ -n "${TMUX:-}" ]; then
    printf '%s:%s\n' "${TMUX%%,*}" "$id"
  else
    printf '%s\n' "$id"
  fi
  return 0
}

# control op: kill the pane (%N) or window (@N) named by the bare id.
# Is the recorded pane still there? READ ONLY — this never closes anything.
#
# It exists because `terminal_despawn` cannot answer the question. Measured on a
# throwaway server: `kill-pane` returns 0 for a live pane and non-zero for one
# that is already gone, and the driver maps both non-zeros to 13 — so "already
# closed" and "could not close" arrive as the same value, and a graceful teardown
# that succeeded would have to report needs-force.
#
# Prints a token and returns a code, like the other ops:
#   present / 0    the id is in the terminal's own list
#   gone    / 0    the list answered and the id is not in it
#   unknown / 10   the terminal could not be reached to ask
#   unknown / 13   the id is not one this terminal can be asked about
#
# "Could not ask" must never come back as 0: the caller deletes the placement
# record — the only thing `--force` can work from — on `gone` alone.
terminal_pane_state() {
  local id="$1" out
  command -v tmux >/dev/null 2>&1 \
    || { echo unknown; return 10; }
  # No socket in the id: a record written before refs carried one. The pane id
  # alone cannot name an authority — two servers can both hold `%0` — so this
  # cannot be answered, and saying `gone` here is what deletes a live member's
  # record. An honest `unknown` sends the caller to --force instead (#1051).
  local sock bare
  sock="$(_tmux_sock_of "$id")"
  bare="$(_tmux_bare_of "$id")"
  [ -n "$sock" ] || { echo unknown; return 10; }

  # The server that owned this pane is gone, so the pane is too — a pane does not
  # outlive its server. This matters because it is the ORDINARY case: measured,
  # killing a server's last pane ends the server, which is what folding a member
  # that had its own window does, and without this the answer was `unknown`
  # exactly when the teardown had worked.
  #
  # The discriminator is tmux SAYING SO, not the socket file: measured, the socket
  # survives the server's exit, so its presence proves nothing. `no server running
  # on <path>` is tmux telling us the server is not there, and only that sentence
  # is taken as proof — every other failure stays `unknown`, because `gone` is
  # what deletes the placement record and it must be earned.
  local err="" out="" _rc=0
  case "$bare" in
    %*) out="$(_tmux_do "$id" list-panes  -a -F '#{pane_id}'   2>/tmp/.agmsg-tmux-err.$$)" || _rc=$? ;;
    @*) out="$(_tmux_do "$id" list-windows -a -F '#{window_id}' 2>/tmp/.agmsg-tmux-err.$$)" || _rc=$? ;;
    *)  rm -f "/tmp/.agmsg-tmux-err.$$" 2>/dev/null; echo unknown; return 13 ;;
  esac
  err="$(cat "/tmp/.agmsg-tmux-err.$$" 2>/dev/null)"
  rm -f "/tmp/.agmsg-tmux-err.$$" 2>/dev/null
  if [ "$_rc" -ne 0 ]; then
    case "$err" in
      *"no server running"*) echo gone; return 0 ;;
      *)                     echo unknown; return 10 ;;
    esac
  fi
  if printf '%s\n' "$out" | grep -qx -- "$bare"; then echo present; return 0; fi
  echo gone
  return 0
}

terminal_despawn() {
  local id="$1"
  # The KIND is in the bare id; a socket-qualified id starts with the socket path.
  case "$(_tmux_bare_of "$id")" in
    %*) _tmux_do "$id" kill-pane   -t "$(_tmux_bare_of "$id")" >/dev/null 2>&1 || { echo runtime_error; return 13; } ;;
    @*) _tmux_do "$id" kill-window -t "$(_tmux_bare_of "$id")" >/dev/null 2>&1 || { echo runtime_error; return 13; } ;;
    *)  printf 'unsupported: not a tmux pane/window id: %s\n' "$id" >&2; return 13 ;;
  esac
  echo ok
  return 0
}

# record op: print the visible pane buffer verbatim (NOT parsed). --lines N
# starts N lines back into the scrollback (default: just the visible screen).
terminal_peek() {
  local id="$1"; shift
  local lines=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --lines) lines="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$lines" in ''|*[!0-9]*) lines="" ;; esac
  # peek exit taxonomy, SHARED with herdr so the template reads one meaning across
  # every peek-capable driver: the terminal being UNREACHABLE (tmux not on
  # PATH — no server to talk to) is 10; an answered-but-no-content failure (the pane
  # is gone / capture failed) is 12. 13 is reserved for a driver with no peek path at
  # all (plain's permanent "no addressable pane") — a different message to the user,
  # so a tmux pane's transient loss must NOT borrow it. Errors go to stderr; peek's
  # stdout stays content-only (capture-pane streams straight through, no rewrapping).
  command -v tmux >/dev/null 2>&1 \
    || { echo "tmux: not on PATH — cannot reach the terminal to peek pane '$id'" >&2; return 10; }
  if [ -n "$lines" ]; then
    _tmux_do "$id" capture-pane -p -t "$(_tmux_bare_of "$id")" -S "-$lines" \
      || { echo "tmux: could not capture pane '$id' (it may no longer exist)" >&2; return 12; }
  else
    _tmux_do "$id" capture-pane -p -t "$(_tmux_bare_of "$id")" \
      || { echo "tmux: could not capture pane '$id' (it may no longer exist)" >&2; return 12; }
  fi
  return 0
}

# tmux has no pane-label field independent of the CLI-owned terminal title.
# The resolvable key is the pane-local @agmsg_agent user option.
terminal_team_observe() {
  local id="$1" key title bare
  command -v tmux >/dev/null 2>&1 || return 10
  # Two separate things, and doing only one of them is worse than doing neither:
  # STRIP the socket so the kind test and `-t` see a bare id, and USE that socket
  # so the query goes to the server that owns the pane. A ref stripped but not
  # routed lands on whatever server is ambient, where the same pane id is a
  # DIFFERENT pane — which is where #1051 started.
  bare="$(_tmux_bare_of "$id")"
  case "$bare" in @*|%*) : ;; *) return 13 ;; esac
  key="$(_tmux_do "$id" show-options -p -v -t "$bare" @agmsg_agent 2>/dev/null)" || key=""
  title="$(_tmux_do "$id" display-message -p -t "$bare" '#{pane_title}' 2>/dev/null)" || return 10
  [ -n "$key" ] || key=unknown:agent_key_missing
  [ -n "$title" ] || title=unknown:terminal_title_missing
  case "$key$title" in *$'\t'*|*$'\n'*|*$'\r'*) return 10 ;; esac
  printf 'n/a:unsupported\tn/a:no_independent_field\t%s\t%s\n' "$key" "$title"
}

# Positive input-readiness proof for team --fix. pane_current_command is only a
# display hint (Claude may publish a version there), so identify the foreground
# process-group leader from the pane tty and compare its argv with the expected
# CLI executable.
terminal_team_input_ready() {
  local id="$1" expected="$2" facts in_mode pane_pid pane_tty tpgid command first bare
  command -v tmux >/dev/null 2>&1 || { printf 'unknown:terminal_unreachable\n'; return 2; }
  # Strip the socket for the kind test and `-t`, and route the query to the
  # server the ref names — see terminal_team_observe. Here the stakes are the
  # pane's pid and tty: reading them off another server's same-numbered pane
  # would produce a confident readiness answer about the wrong process.
  bare="$(_tmux_bare_of "$id")"
  case "$bare" in @*|%*) : ;; *) printf 'unknown:invalid_pane_id\n'; return 2 ;; esac
  facts="$(_tmux_do "$id" display-message -p -t "$bare" '#{pane_in_mode}|#{pane_pid}|#{pane_tty}' 2>/dev/null)" \
    || { printf 'unknown:pane_query_failed\n'; return 2; }
  IFS='|' read -r in_mode pane_pid pane_tty <<EOF
$facts
EOF
  [ "$in_mode" = 0 ] || { printf 'not_ready:copy_mode\n'; return 1; }
  case "$pane_pid" in ''|0*|*[!0-9]*) printf 'unknown:pane_pid_invalid\n'; return 2 ;; esac
  case "$pane_tty" in /dev/*) : ;; *) printf 'unknown:pane_tty_invalid\n'; return 2 ;; esac
  tpgid="$(ps -o tpgid= -p "$pane_pid" 2>/dev/null | tr -d '[:space:]')" \
    || { printf 'unknown:foreground_pgid_unavailable\n'; return 2; }
  case "$tpgid" in ''|0*|*[!0-9]*) printf 'unknown:foreground_pgid_invalid\n'; return 2 ;; esac
  command="$(ps -o command= -p "$tpgid" 2>/dev/null)" \
    || { printf 'unknown:foreground_argv_unavailable\n'; return 2; }
  first="${command%% *}"
  case "$first" in
    "$expected"|*/"$expected") printf 'ready\n'; return 0 ;;
    *) printf 'not_ready:foreground_cli_mismatch\n'; return 1 ;;
  esac
}

# control op: type <text> into the pane and submit it — in TWO bursts.
# #619: text and Enter in the SAME send-keys burst are read as a paste by Codex,
# and the Enter becomes a literal newline instead of submitting. A Right arrow in
# a SEPARATE burst decisively ends paste detection (a no-op for the cursor at
# end-of-line), so the following Enter submits. The brief gap lets the terminal
# finish the text burst before the arrow; it is part of the behavior, not a tunable
# — no env seam.
terminal_poke() {
  local id="$1" text="$2"
  # Same exit taxonomy as peek: tmux not on PATH (unreachable) is 10; a
  # send-keys failure (the pane is gone) is 12. 13 stays reserved for a driver with no
  # poke path at all (plain) — a tmux pane's transient loss must not borrow it.
  command -v tmux >/dev/null 2>&1 \
    || { echo runtime_error; echo "tmux: not on PATH — cannot reach the terminal to poke pane '$id'" >&2; return 10; }
  _tmux_do "$id" send-keys -l -t "$(_tmux_bare_of "$id")" -- "$text" \
    || { echo runtime_error; echo "tmux: could not send to pane '$id' (it may no longer exist)" >&2; return 12; }
  sleep 0.3 2>/dev/null || true
  _tmux_do "$id" send-keys -t "$(_tmux_bare_of "$id")" Right Enter \
    || { echo runtime_error; echo "tmux: could not send Enter to pane '$id' (it may no longer exist)" >&2; return 12; }
  echo ok
  return 0
}

# control op: name the pane. The RESOLVABLE key is a pane user option
# @agmsg_agent = <team>:<agent> (scope Naming: tmux is never targeted by name —
# '-t a:b' is session:window to tmux — so peek/poke scan @agmsg_agent instead).
# select-pane -T sets the human-visible title as a copy. Canonical separator is
# ':' (both team and agent commonly contain '-'). Idempotent (safe to re-apply on
# SessionStart).
# <mode> is `key` or absent — see the herdr driver for the split. Here the
# `@agmsg_agent` pane option is the resolvable one and the window name / pane
# title is the decoration, so `key` sets the option and stops.
terminal_name() {
  local id="$1" team="$2" name="$3" mode="${4:-}" label
  label="$team:$name"
  _tmux_do "$id" set-option -p -t "$(_tmux_bare_of "$id")" @agmsg_agent "$label" >/dev/null 2>&1 || { echo runtime_error; return 13; }
  if [ "$mode" = key ]; then echo ok; return 0; fi
  case "$(_tmux_bare_of "$id")" in
    @*) _tmux_do "$id" rename-window -t "$(_tmux_bare_of "$id")" "$label" >/dev/null 2>&1 || true ;;
    *)  _tmux_do "$id" select-pane  -t "$(_tmux_bare_of "$id")" -T "$label" >/dev/null 2>&1 || true ;;
  esac
  echo ok
  return 0
}
