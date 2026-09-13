#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" alpha alice claude-code /tmp/a >/dev/null
  bash "$SCRIPTS/join.sh" alpha bob codex /tmp/b >/dev/null
}

@test "census seam delegates to the shared terminal enumeration primitive" {
  run bash -c '
    unset _AGMSG_SWEEP_SH
    source "$1/lib/sweep.sh"
    agmsg_terminal_enumerate() {
      printf "herdr\t/run/jugemu.sock\tw1:p7\n"
    }
    _agmsg_sweep_agent_rows
  ' _ "$SCRIPTS"

  [ "$status" -eq 0 ] || return 1
  [ "$output" = $'herdr\t/run/jugemu.sock\tw1:p7' ]
}

@test "missing SKILL_DIR is a named refusal and writes nothing" {
  run bash -c '
    unset _AGMSG_SWEEP_SH SKILL_DIR
    source "$1/lib/sweep.sh"
    _agmsg_sweep_agent_rows() { printf "herdr\t/run/jugemu.sock\tw1:p7\n"; }
    _agmsg_sweep_process_at() { printf "agent\tclaude-code\n"; }
    _agmsg_sweep_instance_allowed() { return 0; }
    _agmsg_sweep_label_at() { printf "alpha:alice\n"; }
    _agmsg_sweep_poke_fenced() { printf written >> "$2"; }
    agmsg_sweep_run alpha
  ' _ "$SCRIPTS" "$BATS_TEST_TMPDIR/pokes"

  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *'sweep: skill_dir_unavailable; nothing was written'* ]] || return 1
  [ ! -e "$BATS_TEST_TMPDIR/pokes" ]
}

teardown() { teardown_test_env; }

_run_sweep_fixture() {   # <rows>
  local rows="$1"
  run bash -c '
    set -u
    SCRIPTS=$1; SKILL_DIR=$2; ROWS=$3; LOG=$4
    . "$SCRIPTS/lib/sweep.sh"
    _agmsg_sweep_agent_rows() {
      printf "%s\n" "$ROWS" | awk -F "\t" '\''
        $1 == "!" || $1 == "!!" || $1 == "?" { print; next }
        { print $1 "\t" $2 "\t" $3 }
      '\''
    }
    _agmsg_sweep_process_at() {
      printf "%s\n" "$ROWS" | awk -F "\t" -v kind="$1" -v instance="$2" -v pane="$3" '\''
        $1 == kind && $2 == instance && $3 == pane {
          out = $4
          for (i = 5; i <= NF; i++) out = out "\t" $i
          print out
          exit
        }
      '\''
    }
    _agmsg_sweep_instance_allowed() {
      [ "$2:$3" != "herdr:/run/oma.sock" ]
    }
    _agmsg_sweep_locator() {
      case "$2" in *:*) echo instance_malformed >&2; return 2 ;; esac
      printf "%s:%s:%s\n" "$1" "$2" "$3"
    }
    _agmsg_sweep_label_at() {
      case "$1:$2:$3" in
        herdr:/run/jugemu.sock:w1:p7) printf "alpha:alice\n" ;;
        tmux:/tmp/tmux-a:%4) printf "alpha:bob\n" ;;
        "tmux:/tmp/server with space:%4") printf "alpha:bob\n" ;;
        tmux:/tmp/server:alternate:%4) printf "alpha:bob\n" ;;
        plain:iterm:/dev/ttys040) printf "alpha:alice\n" ;;
        *) return 1 ;;
      esac
    }
    _agmsg_sweep_poke_fenced() {
      printf "%s\t%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$4" "$5" >> "$LOG"
    }
    agmsg_sweep_run alpha
  ' _ "$SCRIPTS" "$TEST_SKILL_DIR" "$rows" "$BATS_TEST_TMPDIR/pokes"
}

@test "sweep makes the poke target and fix ref from the same complete row (#1152)" {
  _run_sweep_fixture $'herdr\t/run/jugemu.sock\tw1:p7\tagent\tclaude-code\ntmux\t/tmp/tmux-a\t%4\tagent\tcodex'
  [ "$status" -eq 0 ] || return 1
  grep -Fqx $'herdr\t/run/jugemu.sock\tw1:p7\talpha/alice\t$agmsg fix --pane '\''herdr:/run/jugemu.sock:w1:p7'\''' "$BATS_TEST_TMPDIR/pokes" || return 1
  grep -Fqx $'tmux\t/tmp/tmux-a\t%4\talpha/bob\t$agmsg fix --pane '\''tmux:/tmp/tmux-a:%4'\''' "$BATS_TEST_TMPDIR/pokes"
}

@test "same bare pane in two instances cannot cross target and body (#1152)" {
  _run_sweep_fixture $'herdr\t/run/jugemu.sock\tw1:p7\tagent\tclaude-code\nherdr\t/run/oma.sock\tw1:p7\tagent\tclaude-code'
  [ "$status" -eq 1 ] || return 1
  [ "$(wc -l < "$BATS_TEST_TMPDIR/pokes" | tr -d ' ')" -eq 1 ] || return 1
  grep -Fqx $'herdr\t/run/jugemu.sock\tw1:p7\talpha/alice\t$agmsg fix --pane '\''herdr:/run/jugemu.sock:w1:p7'\''' "$BATS_TEST_TMPDIR/pokes" || return 1
  refute grep -Fq '/run/oma.sock' "$BATS_TEST_TMPDIR/pokes"
}

@test "none unknown holes malformed rows and label mismatch are loud and never poked (#1152)" {
  _run_sweep_fixture $'herdr\t/run/jugemu.sock\tw1:p1\tnone\t\nherdr\t/run/jugemu.sock\tw1:p2\tunknown\twalk_incomplete\n!\therdr\t/run/bad.sock\n!!\ttmux\n?\tplain\nbroken\trow\nherdr\t/run/jugemu.sock\tw1:p3\tagent\tcodex\textra\nherdr\t/run/jugemu.sock\tw1:p7\tagent\tcodex'
  [ "$status" -eq 1 ] || return 1
  [ ! -e "$BATS_TEST_TMPDIR/pokes" ] || return 1
  grep -Fq 'reason=none' <<< "$output" || return 1
  grep -Fq 'reason=unknown:walk_incomplete' <<< "$output" || return 1
  grep -Fq 'reason=enumeration_hole' <<< "$output" || return 1
  grep -Fq 'reason=malformed_row' <<< "$output" || return 1
  grep -Fq 'reason=malformed_process_observation' <<< "$output" || return 1
  grep -Fq 'reason=roster_label_process_mismatch' <<< "$output"
}

@test "plain emulator target uses the same fenced path as pane terminals (#1152)" {
  _run_sweep_fixture $'plain\titerm\t/dev/ttys040\tagent\tclaude-code'
  [ "$status" -eq 0 ] || return 1
  grep -Fqx $'plain\titerm\t/dev/ttys040\talpha/alice\t$agmsg fix --pane '\''plain:iterm:/dev/ttys040'\''' "$BATS_TEST_TMPDIR/pokes"
}

@test "instance paths with spaces stay one quoted fix argument (#1152)" {
  _run_sweep_fixture $'tmux\t/tmp/server with space\t%4\tagent\tcodex'
  [ "$status" -eq 0 ] || return 1
  grep -Fqx $'tmux\t/tmp/server with space\t%4\talpha/bob\t$agmsg fix --pane '\''tmux:/tmp/server with space:%4'\''' "$BATS_TEST_TMPDIR/pokes"
}

@test "an unrepresentable colon in an instance is loud and writes nothing (#1152)" {
  _run_sweep_fixture $'tmux\t/tmp/server:alternate\t%4\tagent\tcodex'
  [ "$status" -eq 1 ] || return 1
  [ ! -e "$BATS_TEST_TMPDIR/pokes" ] || return 1
  grep -Fq 'instance_malformed' <<< "$output" || return 1
  grep -Fq 'reason=locator_unavailable:rc_2' <<< "$output"
}

@test "fence refusal is loud and does not report a send (#1152)" {
  run bash -c '
    set -u
    SCRIPTS=$1; SKILL_DIR=$2
    . "$SCRIPTS/lib/sweep.sh"
    _agmsg_sweep_agent_rows() { printf "herdr\t/run/jugemu.sock\tw1:p7\n"; }
    _agmsg_sweep_process_at() { printf "agent\tclaude-code\n"; }
    _agmsg_sweep_instance_allowed() { return 0; }
    _agmsg_sweep_locator() { printf "%s:%s:%s\n" "$1" "$2" "$3"; }
    _agmsg_sweep_label_at() { printf "alpha:alice\n"; }
    _agmsg_sweep_poke_fenced() { return 12; }
    agmsg_sweep_run alpha
  ' _ "$SCRIPTS" "$TEST_SKILL_DIR"
  [ "$status" -eq 1 ] || return 1
  grep -Fq 'reason=write_fence_or_poke_failed:rc_12' <<< "$output" || return 1
  refute grep -Fq 'sent team=' <<< "$output"
}

@test "entry point requires an explicit team and never sweeps from another command (#1152)" {
  run bash "$SCRIPTS/sweep.sh"
  [ "$status" -eq 2 ] || return 1
  [ "$output" = 'Usage: sweep.sh <team>' ] || return 1
  refute rg -n 'sweep\.sh|agmsg_sweep_run' "$SCRIPTS"/join.sh "$SCRIPTS"/team.sh "$SCRIPTS"/watch.sh "$SCRIPTS"/session-start.sh
}

@test "skill exposes sweep only as an explicit team-scoped action (#1152)" {
  grep -Fq 'If argument starts with "sweep" followed by a team name:' "$BATS_TEST_DIRNAME/../SKILL.md" || return 1
  grep -Fq 'scripts/sweep.sh <team>' "$BATS_TEST_DIRNAME/../SKILL.md" || return 1
  grep -Fq 'Never run it from inbox delivery' "$BATS_TEST_DIRNAME/../SKILL.md"
}

@test "locator adapter uses the shared registry composer (#1152, #1168)" {
  run bash -c '
    unset _AGMSG_TERMINAL_REGISTRY_SH _AGMSG_SWEEP_SH
    SKILL_DIR=$1
    source "$1/scripts/lib/terminal-registry.sh"
    source "$1/scripts/lib/sweep.sh"
    _agmsg_sweep_locator herdr "/run/path with space/herdr.sock" w1:p7
  ' _ "$TEST_SKILL_DIR"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "herdr:/run/path with space/herdr.sock:w1:p7" ] || return 1

  run bash -c '
    unset _AGMSG_TERMINAL_REGISTRY_SH _AGMSG_SWEEP_SH
    SKILL_DIR=$1
    source "$1/scripts/lib/terminal-registry.sh"
    source "$1/scripts/lib/sweep.sh"
    _agmsg_sweep_locator herdr "/run/path:alternate/herdr.sock" w1:p7
  ' _ "$TEST_SKILL_DIR"
  [ "$status" -eq 2 ] || return 1
  [ "$output" = "agmsg: locator: instance_malformed" ]
}
