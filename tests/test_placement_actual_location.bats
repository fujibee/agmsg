#!/usr/bin/env bats
# Actual-location layer interface (#1144). NOT wired from
# placement-collisions.sh yet -- see that script's header and
# scripts/lib/placement-actual-location.sh. These tests feed the classifier a
# hand-built census blob shaped exactly like agmsg_terminal_enumerate's own
# TSV output; none of them call the real primitive or touch a terminal.

load test_helper

setup() {
  setup_test_env
  # shellcheck disable=SC1090
  . "$SCRIPTS/lib/placement-actual-location.sh"
}
teardown() { teardown_test_env; }

_census() { printf '%s\n' "$@"; }

@test "a locator the census actually observed is matched (#1144)" {
  census="$(_census $'herdr\tsockA\tw1:p9' $'tmux\tsockB\t%3')"
  run _agmsg_actual_location_classify "$census" herdr sockA w1:p9
  [ "$status" -eq 0 ]
  [ "$output" = matched ]
}

@test "an instance the census reached, with no matching pane, is stale_or_missing_target (#1144)" {
  # sockA WAS reached (it has an observed row for a different pane), and the
  # target pane just is not among them -- a positive absence.
  census="$(_census $'herdr\tsockA\tw1:p1')"
  run _agmsg_actual_location_classify "$census" herdr sockA w1:p9
  [ "$status" -eq 0 ]
  [ "$output" = stale_or_missing_target ]
}

@test "an instance never mentioned at all, with an empty census, is stale_or_missing_target (#1144)" {
  # An empty census for a kind that enumerated cleanly (no ?/!!/! rows at
  # all) means every instance of that kind was reached and found empty.
  census=""
  run _agmsg_actual_location_classify "$census" herdr sockA w1:p9
  [ "$status" -eq 0 ]
  [ "$output" = stale_or_missing_target ]
}

@test "an instance the census could not read is unknown, never stale (#1144)" {
  census="$(_census $'!\therdr\tsockA')"
  run _agmsg_actual_location_classify "$census" herdr sockA w1:p9
  [ "$status" -eq 0 ]
  [ "$output" = unknown ]
}

@test "a kind whose instance list could not be read is unknown (#1144)" {
  census="$(_census $'!!\therdr')"
  run _agmsg_actual_location_classify "$census" herdr sockA w1:p9
  [ "$status" -eq 0 ]
  [ "$output" = unknown ]
}

@test "a kind that cannot enumerate at all is unknown (#1144)" {
  census="$(_census $'?\tplain')"
  run _agmsg_actual_location_classify "$census" plain '-' anything
  [ "$status" -eq 0 ]
  [ "$output" = unknown ]
}

@test "an unreadable OTHER instance of the same kind does not poison this one (#1144)" {
  census="$(_census $'!\therdr\tsockZ' $'herdr\tsockA\tw1:p9')"
  run _agmsg_actual_location_classify "$census" herdr sockA w1:p9
  [ "$status" -eq 0 ]
  [ "$output" = matched ]
}
