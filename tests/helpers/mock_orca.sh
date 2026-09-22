#!/usr/bin/env bash
# mock_orca.sh — a fake `orca` CLI for the chatgpt ext-tool's bats tests.
# Symlink/copy it onto PATH as `orca` and point FAKE_ORCA_DIR at a scenario
# directory:
#
#   $FAKE_ORCA_DIR/tabs.json            result object for `orca tab list`
#                                       ({"tabs":[{browserPageId,url,...}]});
#                                       absent -> {"tabs":[]}
#   $FAKE_ORCA_DIR/eval.<kind>          inner JSON the page eval returns, served
#                                       on every call of that kind
#   $FAKE_ORCA_DIR/eval.<kind>.seq/<n>  staged variant: file <n> is served on the
#                                       nth call of that kind; once the sequence
#                                       is exhausted the last file repeats
#   $FAKE_ORCA_DIR/argv.log             every invocation's argv, appended
#
# <kind> is detected by a marker substring in the --expression payload:
#   composerEmpty -> classify   insertText -> inject       ready:!!b -> ready
#   send-button-gone -> click   msgs.some -> confirmed     midIdx -> reply
#   slice( -> transcript
#
# Emits the real CLI's envelope: {ok:true,result:<object>} for tab list, and
# {ok:true,result:{result:"<inner json string>"}} for eval -- the drivers'
# expressions all return a JSON *string*, which lands at .result.result.
set -u

dir="${FAKE_ORCA_DIR:?mock_orca: FAKE_ORCA_DIR is not set}"
mkdir -p "$dir/state"
printf '%s\n' "$*" >> "$dir/argv.log" 2>/dev/null || true

args=("$@")
last=$((${#args[@]} - 1))
[ "${args[$last]:-}" = "--json" ] && unset "args[$last]"

fail() { jq -cn --arg e "$1" '{ok:false,error:$e}'; exit 1; }

# serve <kind> — print the eval envelope for the current staged response.
serve() {
  local kind="$1" f n
  if [ -d "$dir/eval.$kind.seq" ]; then
    n=$(( $(cat "$dir/state/$kind" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$n" > "$dir/state/$kind"
    f="$dir/eval.$kind.seq/$n"
    [ -f "$f" ] || f="$dir/eval.$kind.seq/$(ls "$dir/eval.$kind.seq" | sort -n | tail -1)"
  else
    f="$dir/eval.$kind"
  fi
  [ -f "$f" ] || fail "mock_orca: no scenario for eval kind=$kind"
  jq -cn --rawfile v "$f" '{ok:true,result:{result:$v}}'
}

case "${args[0]:-} ${args[1]:-}" in
  "tab list")
    if [ -f "$dir/tabs.json" ]; then
      jq -cn --slurpfile r "$dir/tabs.json" '{ok:true,result:$r[0]}'
    else
      printf '%s\n' '{"ok":true,"result":{"tabs":[]}}'
    fi ;;
  "eval --page")
    expr=""
    for i in "${!args[@]}"; do
      [ "${args[$i]}" = "--expression" ] && expr="${args[$((i + 1))]:-}"
    done
    [ -n "$expr" ] || fail "mock_orca: eval without --expression"
    case "$expr" in
      *composerEmpty*)      serve classify ;;
      *insertText*)         serve inject ;;
      *'ready:!!b'*)        serve ready ;;
      *send-button-gone*)   serve click ;;
      *msgs.some*)          serve confirmed ;;
      *midIdx*)             serve reply ;;
      *'slice('*)           serve transcript ;;
      *) fail "mock_orca: unrecognised eval expression" ;;
    esac ;;
  "reload --page")
    printf '%s\n' '{"ok":true,"result":{}}' ;;
  *) fail "mock_orca: unhandled command: ${args[*]:-}" ;;
esac
