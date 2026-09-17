#!/usr/bin/env bats

# Does a command line name a path we hold? (#652)
#
# The two sides are written in different alphabets and only one of them is ours.
# `compat_get_cmdline` returns what the OS says; the path it is compared against
# came out of this shell. Under Git Bash the same file is `/c/Users/...` on our
# side and `C:/Users/...` on the OS's, so a plain match never fires -- silently,
# because "no match" is the ordinary answer for someone else's process.
#
# These run EVERYWHERE, not only on MSYS. That is deliberate and it is why the
# comparator was written to route the conversion through `cygpath`: a stub on
# PATH reproduces the Windows spelling on any host, so the branch that only
# Windows takes is still exercised by every run of this suite. The alternative
# -- gating on `uname` like tests/test_compat.bats does -- would mean this fix
# is verified on the one platform nobody develops on.

load test_helper

setup() {
  setup_test_env
  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  # Mimics `cygpath -m`: the mixed form, forward slashes, which is what MSYS
  # hands a native binary and therefore what that process reports.
  cat > "$STUB_DIR/cygpath" <<'STUB'
#!/bin/sh
case "$2" in
  /c/*) printf %s "C:${2#/c}" ;;
  *) printf %s "$2" ;;
esac
STUB
  chmod +x "$STUB_DIR/cygpath"

  ENGINE_PATH="/c/Users/u/.agents/skills/agmsg/scripts/internal/remote-sync.mjs"
  WINDOWS_CMDLINE="\"C:\\Program Files\\nodejs\\node.exe\" C:/Users/u/.agents/skills/agmsg/scripts/internal/remote-sync.mjs run --team ossb"
  POSIX_CMDLINE="/usr/bin/node $ENGINE_PATH run --team ossb"
}

teardown() { teardown_test_env; }

@test "cmdline-path: a Windows-spelled command line names a path we hold in POSIX form (#652)" {
  PATH="$STUB_DIR:$PATH"
  . "$SCRIPTS/lib/compat.sh"
  # The whole defect in one line: this is the comparison that answered "not
  # ours" about a live engine on the reporting machine.
  run agmsg_cmdline_names_path "$WINDOWS_CMDLINE" "$ENGINE_PATH"
  [ "$status" -eq 0 ]
}

@test "cmdline-path: a POSIX-spelled command line still matches, with or without cygpath (#652)" {
  # The control, and the regression guard. If the fix only worked through the
  # conversion, every non-Windows host would stop recognising its own
  # processes -- which is a worse failure than the one being fixed, and it
  # would not show up on a Windows-gated test.
  . "$SCRIPTS/lib/compat.sh"
  run agmsg_cmdline_names_path "$POSIX_CMDLINE" "$ENGINE_PATH"
  [ "$status" -eq 0 ]

  PATH="$STUB_DIR:$PATH"
  run agmsg_cmdline_names_path "$POSIX_CMDLINE" "$ENGINE_PATH"
  [ "$status" -eq 0 ]
}

@test "cmdline-path: a different path is not matched, in either spelling (#652)" {
  # What the comparison is FOR. The pid came out of our own pidfile, so this
  # only has to catch a pid that has been reused by something else -- and a
  # conversion that made everything match would remove that check entirely
  # while looking like a fix.
  PATH="$STUB_DIR:$PATH"
  . "$SCRIPTS/lib/compat.sh"

  run agmsg_cmdline_names_path "$WINDOWS_CMDLINE" "/c/Users/u/.agents/skills/agmsg/scripts/internal/other.mjs"
  [ "$status" -ne 0 ]

  run agmsg_cmdline_names_path "$POSIX_CMDLINE" "/c/Users/u/.agents/skills/agmsg/scripts/internal/other.mjs"
  [ "$status" -ne 0 ]
}

@test "cmdline-path: an empty command line is not a match (#652)" {
  # `compat_get_cmdline` returns empty when it cannot read the process at all
  # -- a sandbox, or a pid that is gone. Callers treat empty as "cannot tell",
  # and a comparator that answered "yes" to it would turn every unreadable
  # process into one of ours.
  PATH="$STUB_DIR:$PATH"
  . "$SCRIPTS/lib/compat.sh"
  run agmsg_cmdline_names_path "" "$ENGINE_PATH"
  [ "$status" -ne 0 ]
}

@test "cmdline-path: no caller compares a shell path against a command line directly (#652)" {
  # The structural control, and the reason it is structural: the four watcher
  # sites decide whether to KILL something, and a per-site regression test would
  # have to stand up a fake watcher four times to say what one grep says once.
  #
  # This is the criterion the sweep used, not a list of the five files found by
  # it -- a sixth site added tomorrow fails this without anyone editing it.
  #
  # The shape being banned: a `case`/`[[` arm whose pattern interpolates a
  # shell-derived path and whose subject came from `compat_get_cmdline`.
  local offenders
  offenders="$(grep -rnE '\*"\$(SKILL_DIR|SCRIPT_DIR)[^"]*"\*?\)' "$SCRIPTS"/*.sh "$SCRIPTS"/drivers/types/codex/*.sh 2>/dev/null || true)"
  [ -z "$offenders" ] || {
    printf 'a path is being matched against a command line directly:\n%s\n' "$offenders" >&3
    false
  }
}

@test "cmdline-path: every file that reads a command line for a path uses the comparator (#652)" {
  # The other half. The ban above is satisfied by deleting a check entirely;
  # this says the five that need the comparison still make it.
  local f
  for f in remote.sh watch.sh session-end.sh session-start.sh delivery.sh; do
    grep -q 'agmsg_cmdline_names_path' "$SCRIPTS/$f" || {
      printf '%s no longer asks the comparator\n' "$f" >&3
      false
      return
    }
  done
}
