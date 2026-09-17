#!/usr/bin/env bats
# WHEN THE ONLY THING A CALLER SEES IS "000", THROWING AWAY curl's STDERR IS
# THROWING AWAY THE DIAGNOSIS (#850).
#
# `_remote_http_post_json` reports `000` for every kind of failure alike: a
# refused connection, a timeout, a path curl could not open. The reason existed
# each time -- curl wrote it to stderr -- and `2>/dev/null` discarded it. A
# Windows run spent an afternoon on a bare `000` whose cause was in that stream.
#
# WHAT HAS TO HOLD, and each is its own case here:
#
#   on failure   the diagnosis reaches the caller's stderr
#   on success   nothing does, even if curl wrote something -- the show is
#                gated on curl having FAILED, not on the stream being empty
#   either way   the http code is exactly what it was before
#   either way   no scratch file is left behind
#
# The stderr of the helper is captured to a FILE rather than read from bats's
# `$output`, which merges the two streams: a test that cannot tell stdout from
# stderr cannot check that a message went to the right one, and "the message
# appears somewhere" is what this fix is not about.

load test_helper

SANDBOX_TOOLS=(bash dirname mktemp mkfifo chmod rm rmdir sed cp cat grep python3 uname)

setup() {
  setup_test_env

  STUB_SRC="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_SRC"

  # A curl whose behaviour the test dictates: STUB_CURL_MODE says whether it
  # succeeds, and STUB_CURL_STDERR is written to stderr either way. Writing on
  # the success path too is the point of one of the cases below -- it is how
  # "shown only when curl failed" is told apart from "the stream was empty".
  cat > "$STUB_SRC/curl" <<'STUB'
#!/usr/bin/env bash
set -u
cfg=""; out=""; prev=""
for arg in "$@"; do
  case "$prev" in
    -K) cfg="$arg" ;;
    -o) out="$arg" ;;
  esac
  prev="$arg"
done
[ -z "${STUB_CURL_STDERR:-}" ] || printf '%s\n' "$STUB_CURL_STDERR" >&2
hdr="$(sed -n 's/^dump-header = "\(.*\)"$/\1/p' "$cfg")"
if [ "${STUB_CURL_MODE:-ok}" = "fail" ]; then
  # A failure AFTER the headers were written -- curl exceeding max-filesize on
  # the body, say. The headers matter here: leaving the fifo without a writer
  # strands the bounded copier on open(), and everything downstream of that
  # waits on a process that will never finish. That is a real property of the
  # failure path, and driving it is a different experiment from this one.
  [ -z "$hdr" ] || printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
  exit 63
fi
[ -z "$hdr" ] || printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
[ -z "$out" ] || printf '{"ok":true}' > "$out"
printf '200'
STUB
  chmod +x "$STUB_SRC/curl"
}

sandbox_path() {
  local dir tool src
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/sandbox.XXXXXX")"
  for tool in "${SANDBOX_TOOLS[@]}"; do
    src="$(command -v "$tool")" || { echo "host lacks $tool" >&2; return 1; }
    ln -s "$src" "$dir/$tool"
  done
  ln -s "$STUB_SRC/curl" "$dir/curl"
  printf '%s' "$dir"
}

# Runs the helper with its own TMPDIR, so "what scratch files remain" is a
# question about this call and not about everything else on the machine.
# stdout (the http code) lands in $output; stderr lands in $ERR_FILE.
post_with_curl() {
  local mode="$1" stderr_text="$2"
  RUN_TMPDIR="$(mktemp -d "$BATS_TEST_TMPDIR/run.XXXXXX")"
  ERR_FILE="$BATS_TEST_TMPDIR/helper-stderr"
  local bin; bin="$(sandbox_path)"
  local body="$RUN_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  run env PATH="$bin" TMPDIR="$RUN_TMPDIR" STUB_CURL_MODE="$mode" \
    STUB_CURL_STDERR="$stderr_text" bash -c '
    set -uo pipefail
    . '"$SCRIPTS"'/remote.sh 2>/dev/null
    _remote_http_post_json "https://example.invalid/v1/x" "'"$body"'" \
      "'"$RUN_TMPDIR"'/out-body" "'"$RUN_TMPDIR"'/out-header" 2>"'"$ERR_FILE"'"
  '
}

@test "a failing curl's diagnosis reaches the caller's stderr (#850)" {
  # The whole point. Without this the operator has "000" and nothing else, and
  # the reason they need is written down and then deleted.
  post_with_curl fail "curl: (26) Failed to open/read local data from file"
  [ "$status" -eq 0 ]
  [ "$output" = "000" ]

  grep -q 'Failed to open/read local data' "$ERR_FILE"
}

@test "a successful curl's stderr is NOT shown, even when it wrote something (#850)" {
  # Distinguishes "shown only when curl failed" from "the stream happened to be
  # empty". curl -sS is quiet on success, so a test that let it stay quiet here
  # would pass against a version that dumped stderr unconditionally -- and that
  # version would drop noise into the middle of a caller's output.
  post_with_curl ok "a progress line nobody asked for"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  [ ! -s "$ERR_FILE" ]
}

@test "the http code is unchanged on both paths (#850)" {
  # The contract this must not have altered while adding the diagnosis.
  post_with_curl ok ""
  [ "$output" = "200" ]

  post_with_curl fail "curl: (7) Failed to connect"
  [ "$output" = "000" ]
}

@test "no scratch file is left behind, on either path (#850)" {
  # The config, the error file and the fifo now live in one directory the helper
  # mints, so this is one glob rather than three.
  #
  # THE NAME MATTERS AND ALMOST GOT THIS WRONG. An earlier version of this test
  # globbed agmsg-curl-cfg.* and agmsg-curl-err.*, which the new layout never
  # creates -- the check would have passed on any behaviour whatsoever, and gone
  # on passing if the directory leaked. An absence assertion aimed at a name
  # nothing uses is indistinguishable from a clean run.
  post_with_curl ok ""
  [ "$output" = "200" ]
  refute ls -d "$RUN_TMPDIR"/agmsg-curl.* 2>/dev/null

  post_with_curl fail "curl: (7) Failed to connect"
  [ "$output" = "000" ]
  refute ls -d "$RUN_TMPDIR"/agmsg-curl.* 2>/dev/null
}

@test "a diagnosis that cannot be written does not change the outcome (#850)" {
  # THIS CASE ASSERTED THE OPPOSITE UNTIL REVIEW TURNED IT AROUND.
  #
  # The diagnosis used to be `[ ... ] && [ ... ] && cat "$curl_err" >&2` sitting
  # before the failure arm. Under `set -e` a failing `cat` -- closed stderr, a
  # reader that went away, a full disk -- ended the function there: no reap, no
  # cleanup, and no http code at all where the contract promises "000".
  #
  # I wrote a test that drove exactly that and asserted it: nonzero status,
  # empty stdout, and a comment noting the copier was left orphaned. It was
  # measuring the defect and calling it the property. Being unable to EXPLAIN a
  # failure must not turn it into a DIFFERENT failure, so all three of these are
  # now the other way round.
  RUN_TMPDIR="$(mktemp -d "$BATS_TEST_TMPDIR/run.XXXXXX")"
  local bin; bin="$(sandbox_path)"
  local body="$RUN_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  # A `cat` that always fails, shadowing the real one for this run only. The
  # symlink is REMOVED first: `>` through a symlink writes to its target, which
  # here is the system's own /bin/cat. An earlier version did exactly that and
  # was refused by the OS -- on a machine where it was not refused, this test
  # would have replaced a system binary.
  rm -f "$bin/cat"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/cat"
  chmod +x "$bin/cat"

  run env PATH="$bin" TMPDIR="$RUN_TMPDIR" STUB_CURL_MODE=fail \
    STUB_CURL_STDERR="curl: (26) Failed to open/read local data" bash -c '
    set -euo pipefail
    . '"$SCRIPTS"'/remote.sh 2>/dev/null
    REAP_LOG="'"$RUN_TMPDIR"'/reap.log"
    kill() { printf "kill %s\n" "$*" >> "$REAP_LOG"; builtin kill "$@"; }
    wait() {
      printf "wait %s\n" "$*" >> "$REAP_LOG"
      builtin wait "$@"
      local rc=$?
      printf "wait-rc %s %s\n" "$*" "$rc" >> "$REAP_LOG"
      return $rc
    }
    _remote_http_post_json "https://example.invalid/v1/x" "'"$body"'" \
      "'"$RUN_TMPDIR"'/out-body" "'"$RUN_TMPDIR"'/out-header"
  '

  # 1. The request still reports what it always reported.
  [ "$status" -eq 0 ]
  [ "$output" = "000" ]

  # 2. THE COPIER WAS REAPED, and the identity is the shell's own child table
  #    rather than anything found in the process table afterwards.
  #
  #    Four post-hoc instruments failed their positive controls before this one
  #    (a pid the copier writes about itself, two pgrep forms, lsof on the work
  #    dir), all for the same reason: a copier waiting on the fifo is still a
  #    forked BASH wearing its parent's command line -- `comm` reads `bash` --
  #    because python3 is not exec'd until curl opens the pipe. Nothing outside
  #    can name it. But the shell that forked it can: `wait` is a builtin over
  #    that shell's OWN waitable children, so a successful wait IS the
  #    observation, and it needs no identity of its own.
  #
  #    `kill` and `wait` are shadowed in the driven shell and delegate to the
  #    builtins, so production runs unchanged and only the seam is recorded.
  reap="$RUN_TMPDIR/reap.log"
  [ -s "$reap" ]
  killed="$(sed -n 's/^kill //p' "$reap" | head -1)"
  waited="$(sed -n 's/^wait //p' "$reap" | head -1)"
  [ -n "$killed" ]
  [ "$killed" = "$waited" ]

  #    And the wait really collected that child: 127 is bash's "not a child of
  #    this shell", which is what a stale or foreign pid returns.
  rc="$(sed -n "s/^wait-rc $waited //p" "$reap" | head -1)"
  [ -n "$rc" ]
  [ "$rc" != "127" ]

  # 3. Nothing is left on disk.
  refute ls -d "$RUN_TMPDIR"/agmsg-curl.* 2>/dev/null
}

@test "a failure while setting up leaves nothing behind either (#850)" {
  # The window the previous shape could not close: anything created BEFORE the
  # trap is armed is unprotected, and there is always a first allocation. The
  # answer is that there is now only ONE allocation before the trap, and
  # everything else is made inside it.
  #
  # Driven by making `mkfifo` fail, which happens after the directory exists and
  # after the config has been written into it. Under `set -e` that leaves the
  # function immediately -- before curl, before any cleanup the tail would do.
  RUN_TMPDIR="$(mktemp -d "$BATS_TEST_TMPDIR/run.XXXXXX")"
  local bin; bin="$(sandbox_path)"
  local body="$RUN_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  rm -f "$bin/mkfifo"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/mkfifo"
  chmod +x "$bin/mkfifo"

  run env PATH="$bin" TMPDIR="$RUN_TMPDIR" bash -c '
    set -euo pipefail
    . '"$SCRIPTS"'/remote.sh 2>/dev/null
    _remote_http_post_json "https://example.invalid/v1/x" "'"$body"'" \
      "'"$RUN_TMPDIR"'/out-body" "'"$RUN_TMPDIR"'/out-header"
  '
  [ "$status" -ne 0 ]

  # Nothing survives: not the directory, and so not the config inside it. The
  # config is the file that matters -- it is what this helper exists to keep
  # out of curl's argv, and a stranded copy names the request body.
  refute ls -d "$RUN_TMPDIR"/agmsg-curl.* 2>/dev/null
}

@test "an EXIT trap cannot read the locals of the function that set it (#850)" {
  # The premise the trap's shape rests on, measured here rather than asserted
  # in a comment. If a future bash made locals visible to an EXIT trap, the
  # `printf %q` baking would look like pointless ceremony and someone would
  # simplify it back into a single-quoted body -- reopening the leak. This test
  # is what tells them the ceremony is load-bearing.
  run bash -c '
    f() { local v="hello"; trap '"'"'printf "TRAP_SEES=[%s]\n" "${v:-EMPTY}"'"'"' EXIT; false; }
    set -e
    f
  '
  [ "$output" = "TRAP_SEES=[EMPTY]" ]
}

@test "the leftover check can see a leftover when there is one (#850)" {
  # Control on the assertion above, which is an absence: a glob that matches
  # nothing looks exactly like a glob pointed at the wrong directory. Plant one
  # and confirm the same check fires.
  # Planted under the name the helper really uses, so this controls the glob
  # that the absence assertions actually run.
  post_with_curl ok ""
  mkdir -p "$RUN_TMPDIR/agmsg-curl.planted"
  run ls -d "$RUN_TMPDIR"/agmsg-curl.*
  [ "$status" -eq 0 ]
}
