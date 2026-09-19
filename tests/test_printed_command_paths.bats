#!/usr/bin/env bats

# A printed command is one someone pastes (#667).
#
# `key.sh` and `remote.sh` are not on PATH — they live inside the install
# directory, whose name is chosen at install time — so a printed `key.sh show
# ...` cannot be run as printed, and on a machine with more than one install
# the reader cannot guess which one printed it.
#
# The heaviest instance was the key-backup notice: it sits directly under
# "losing this key makes every message permanently unreadable" as the only
# offered way to prevent that, and it produced `command not found`.
#
# These assert the printed line names a path that EXISTS, not that it contains
# some spelling. A line naming the wrong directory would satisfy a substring
# check and still not run.
#
# Every load-bearing assertion here is `… || return 1`, and never a bare
# `[[ ]]`. Bats reports a failure through an ERR trap, and on bash 3.2 — which
# is what the macOS shards run — `[[ ]]` and `(( ))` do not fire that trap, so
# a bare one mid-body is enforced on ubuntu only (#670). `[ ]` and ordinary
# commands do fire it there, measured, but an explicit `return 1` does not
# depend on knowing which constructs the trap covers.

load test_helper

# Legal, and nothing like the fixtures elsewhere: validate.sh rejects empty,
# `.`, `..`, `/`, `\`, a leading `-` and control characters — a space and a
# single quote are allowed. A printed command has to survive both.
QTEAM="it's a team"

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
}

teardown() {
  teardown_test_env
}

skip_if_no_age() {
  command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 || skip "age/age-keygen not installed"
}

# The first path inside a printed `bash '<path>' ...` line naming <script>.
printed_path() {
  printf '%s\n' "$output" | sed -n "s/.*bash '\([^']*$1\)'.*/\1/p" | head -1
}

# A connected binding, so the commands that only appear for one can be reached
# without standing up a server. Parameterised by team, because the point of the
# tests below is a team name the rest of the suite does not use.
bind_team() {
  python3 - "$SCRIPTS/../teams/$1/config.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['remote_binding'] = {
    'endpoint': 'https://sync.example.test',
    'server_instance_id': '018f3f7e-0000-7000-8000-000000000000',
    'remote_team_id': d['team_id'],
    'remote_team_name': d['name'],
    'protocol_version': 1,
    'capabilities': {'write_allowed_ciphers': ['none', 'age-v1']},
    'connected_at': '2026-07-30T00:00:00Z',
    'disconnected_at': None,
}
open(p, 'w').write(json.dumps(d) + '\n')
PY
}

@test "printed commands: the key-backup notice names a key.sh that exists" {
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$output" | grep -q 'Back this up now' || return 1
  path="$(printed_path 'key\.sh')"
  # Non-empty first: an empty path would make every check below vacuous, and
  # "no printed command at all" is the state this issue was about.
  [ -n "$path" ] || return 1
  [ -f "$path" ] || return 1
}

@test "printed commands: that notice is still the --reveal-secret route" {
  # Paired with the test above. A path pointing at a real file proves nothing
  # if the subcommand stopped being the one that shows the secret.
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$output" | grep -q -- "--reveal-secret" || return 1
}

@test "printed commands: 'no key yet' names both routes with a path" {
  run bash "$SCRIPTS/key.sh" show testteam
  [ "$status" -ne 0 ] || return 1
  printf '%s\n' "$output" | grep -q 'has no key yet' || return 1
  # Both offered commands, each with a path that exists. Counted rather than
  # matched once: the message offers generate AND import, and a fix that
  # repaired only the first would pass a single check.
  n="$(printf '%s\n' "$output" | grep -c "bash '$SCRIPTS/key.sh' ")"
  [ "$n" -eq 2 ] || return 1
}

@test "printed commands: 'already has a key' names a key.sh that exists" {
  skip_if_no_age
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ] || return 1
  run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -ne 0 ] || return 1
  path="$(printed_path 'key\.sh')"
  [ -n "$path" ] || return 1
  [ -f "$path" ] || return 1
}

@test "printed commands: the guidance gate still withholds the backup route" {
  # The path work must not have turned a withheld route into a printed one.
  # A caller that owns the next step gets the FACT and not the command.
  skip_if_no_age
  AGMSG_OPERATOR_GUIDANCE=caller run bash "$SCRIPTS/key.sh" generate testteam
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$output" | grep -q 'permanently unreadable' || return 1
  run_output_has_backup=0
  printf '%s\n' "$output" | grep -q 'Back this up now' && run_output_has_backup=1
  [ "$run_output_has_backup" -eq 0 ] || return 1
}

@test "printed commands: the key route survives a team with a space and a quote" {
  # A substring check cannot tell correct quoting from a line that merely
  # contains the right words. This parses the printed command with a shell and
  # compares argv byte for byte, which is the only thing that proves it.
  skip_if_no_age
  bash "$SCRIPTS/join.sh" "$QTEAM" alice claude-code /tmp/project-q
  run bash "$SCRIPTS/key.sh" generate "$QTEAM"
  [ "$status" -eq 0 ] || return 1
  line="$(printf '%s\n' "$output" | grep -F -- "key.sh' show " | head -1)"
  [ -n "$line" ] || return 1
  eval "set -- $line"
  [ "$1" = bash ] || return 1
  [ -f "$2" ] || return 1
  [ "$3" = show ] || return 1
  [ "$4" = "$QTEAM" ] || return 1
  [ "$5" = --reveal-secret ] || return 1
}

@test "printed commands: the remote route survives a team with a space and a quote" {
  bash "$SCRIPTS/join.sh" "$QTEAM" alice claude-code /tmp/project-q
  bind_team "$QTEAM"
  run bash "$SCRIPTS/remote.sh" forget --yes "$QTEAM"
  [ "$status" -ne 0 ] || return 1
  line="$(printf '%s\n' "$output" | grep -F -- "remote.sh' disconnect " | head -1)"
  [ -n "$line" ] || return 1
  eval "set -- $line"
  [ "$1" = bash ] || return 1
  [ -f "$2" ] || return 1
  [ "$3" = disconnect ] || return 1
  [ "$4" = "$QTEAM" ] || return 1
}
