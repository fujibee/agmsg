#!/usr/bin/env bats
# WHERE A REAL NAMED PIPE CANNOT EXIST, DO NOT BUILD ONE (#850).
#
# `_remote_http_post_json` streams curl's headers through a fifo so
# `bounded-copy.py` can enforce a size ceiling while the transfer is still
# running. That needs a real named pipe. On Windows/Git Bash there is none to
# have: MSYS emulates `mkfifo` with a `.lnk` file that only MSYS-aware programs
# understand, and curl there is a NATIVE binary. It cannot open what mkfifo
# made, so it fails and the caller reports the same `000` it reports for
# everything.
#
# The fix takes a different sink on that platform: dump straight to the
# caller's header file, no fifo and no copier. Two things then have to hold,
# and they are the two this file drives:
#
#   the fifo machinery is NOT built when the marker says it cannot work
#   the caller's header file SURVIVES -- on that path `header_fifo` IS
#     `header_file`, so the cleanup that removes the fifo would delete the
#     headers the function was asked to produce
#
# HOW THE ABSENCE OF A CALL IS OBSERVED. `mkfifo` and `python3` are replaced by
# recording wrappers that then exec the real thing, so a test can assert on
# what was invoked without changing what happens. An assertion that something
# did NOT run is only worth its opposite: every case here also names a case
# where the same wrapper DOES record, so "no line in the log" cannot pass
# because the log was never wired up.
#
# WHAT THIS FILE DOES NOT CLAIM. The sibling defect (#851, embedded config
# paths) is not on this branch, so paths stay POSIX here and the curl stub is a
# POSIX consumer. On a real Windows machine this fix alone is not enough --
# both are needed, and they compose only on the combined branch.
#
# Self-contained rather than sharing a harness with the #851 file: these are
# separate pull requests that must land in either order, and a helper moved
# into test_helper.bash by one of them is a conflict for the other.

load test_helper

# Externals `remote.sh` needs to source, plus those the helper and the stubs
# call. Allowlist rather than subtraction: on Git Bash `cygpath` sits in the
# same directory as `mktemp`, so nothing can be removed by dropping a path.
SANDBOX_TOOLS=(bash dirname mktemp mkfifo chmod rm rmdir sed cp cat grep python3 uname)

setup() {
  setup_test_env

  CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
  export CALL_LOG
  : > "$CALL_LOG"

  STUB_SRC="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_SRC"

  # curl: writes the headers where the config says, the way the real one does.
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
[ -n "$cfg" ] || { echo "STUB_CURL: no -K config" >&2; exit 2; }
hdr="$(sed -n 's/^dump-header = "\(.*\)"$/\1/p' "$cfg")"
if [ -n "$hdr" ]; then
  printf 'HTTP/1.1 200 OK\r\nX-Marker: from-curl\r\n\r\n' > "$hdr" || {
    echo "STUB_CURL: cannot write dump-header: $hdr" >&2; exit 23; }
fi
[ -z "$out" ] || printf '{"ok":true}' > "$out"
printf '200'
STUB
  chmod +x "$STUB_SRC/curl"

  # cygpath: only ever probed with `command -v` by the code under test, but it
  # has to be a working binary -- a marker that errors would be a different
  # experiment from a marker that exists.
  cat > "$STUB_SRC/cygpath" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${2-}"
STUB
  chmod +x "$STUB_SRC/cygpath"

  # Recording wrappers. They record and then do the real thing, so the run is
  # unchanged and only observability is added.
  cat > "$STUB_SRC/mkfifo" <<'STUB'
#!/usr/bin/env bash
printf 'mkfifo %s\n' "$*" >> "$CALL_LOG"
exec "$REAL_MKFIFO" "$@"
STUB
  chmod +x "$STUB_SRC/mkfifo"

  cat > "$STUB_SRC/python3" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *bounded-copy.py*) printf 'bounded-copy %s\n' "$*" >> "$CALL_LOG" ;;
  *) printf 'python3 %s\n' "$*" >> "$CALL_LOG" ;;
esac
exec "$REAL_PYTHON3" "$@"
STUB
  chmod +x "$STUB_SRC/python3"

  REAL_MKFIFO="$(command -v mkfifo)"; export REAL_MKFIFO
  REAL_PYTHON3="$(command -v python3)"; export REAL_PYTHON3
}

teardown() { teardown_test_env; }

# A PATH holding the allowlist plus the stubs, with cygpath present only when
# asked. Fails loudly if the host lacks a tool: a short sandbox would make the
# helper fail for reasons unrelated to the fix.
sandbox_path() {
  local want_cygpath="$1" dir tool src
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/sandbox.XXXXXX")"
  for tool in "${SANDBOX_TOOLS[@]}"; do
    src="$(command -v "$tool")" || { echo "host lacks $tool" >&2; return 1; }
    ln -s "$src" "$dir/$tool"
  done
  # The recording wrappers shadow the real tools of the same name.
  ln -sf "$STUB_SRC/mkfifo" "$dir/mkfifo"
  ln -sf "$STUB_SRC/python3" "$dir/python3"
  ln -s "$STUB_SRC/curl" "$dir/curl"
  [ "$want_cygpath" = "yes" ] && ln -s "$STUB_SRC/cygpath" "$dir/cygpath"
  printf '%s' "$dir"
}

post_under() {
  local bin="$1" body_file="$2" header_out="$3"
  run env PATH="$bin" CALL_LOG="$CALL_LOG" REAL_MKFIFO="$REAL_MKFIFO" \
    REAL_PYTHON3="$REAL_PYTHON3" bash -c '
    set -uo pipefail
    . '"$SCRIPTS"'/remote.sh 2>/dev/null
    _remote_http_post_json "https://example.invalid/v1/x" "'"$body_file"'" \
      "'"$BATS_TEST_TMPDIR"'/out-body" "'"$header_out"'"
  '
}

@test "the sandbox decides whether the marker exists — both directions (#850)" {
  # The control on the instrument, and on the recording wrappers. Everything
  # below reads a log, and a log that is never written looks exactly like a
  # call that never happened.
  local without with
  without="$(sandbox_path no)"
  with="$(sandbox_path yes)"

  run env PATH="$without" bash -c 'command -v cygpath >/dev/null 2>&1 && echo PRESENT || echo ABSENT'
  [ "$output" = "ABSENT" ]

  run env PATH="$with" bash -c 'command -v cygpath >/dev/null 2>&1 && echo PRESENT || echo ABSENT'
  [ "$output" = "PRESENT" ]

  # And the wrappers really do record, so an empty log later means something.
  run env PATH="$without" CALL_LOG="$CALL_LOG" REAL_MKFIFO="$REAL_MKFIFO" \
    bash -c 'mkfifo "$BATS_TEST_TMPDIR/control-fifo"'
  grep -q '^mkfifo ' "$CALL_LOG"
}

@test "with the marker present, no fifo is made (#850)" {
  # Two absences, two tests. They are separate pieces of machinery and can be
  # left behind separately -- keeping the fifo while dropping the copier gives
  # a pipe nobody drains, dropping the fifo while keeping the copier gives a
  # reader blocked on a file that never fills. One test asserting both says
  # "some of it is still there" and names neither.
  local bin; bin="$(sandbox_path yes)"
  body="$BATS_TEST_TMPDIR/body.json"; printf '{"t":"secret"}' > "$body"
  hdr="$BATS_TEST_TMPDIR/headers.txt"

  post_under "$bin" "$body" "$hdr"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  refute grep -q '^mkfifo ' "$CALL_LOG"
}

@test "with the marker present, no bounded copier is started (#850)" {
  local bin; bin="$(sandbox_path yes)"
  body="$BATS_TEST_TMPDIR/body.json"; printf '{"t":"secret"}' > "$body"
  hdr="$BATS_TEST_TMPDIR/headers.txt"

  post_under "$bin" "$body" "$hdr"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  refute grep -q '^bounded-copy ' "$CALL_LOG"
}

@test "with the marker present, the caller's header file survives the call (#850)" {
  # The trap this fix had to avoid: on that path `header_fifo` IS `header_file`,
  # so a cleanup that removes the fifo deletes the headers the caller asked for
  # — after a successful request, which makes it look like the server sent none.
  local bin; bin="$(sandbox_path yes)"
  body="$BATS_TEST_TMPDIR/body.json"; printf '{"t":"secret"}' > "$body"
  hdr="$BATS_TEST_TMPDIR/headers.txt"

  post_under "$bin" "$body" "$hdr"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  [ -f "$hdr" ]
  grep -q 'X-Marker: from-curl' "$hdr"
}

@test "without the marker, the fifo and the bounded copier are still used (#850)" {
  # The platforms that are supposed to be unchanged, asserted rather than
  # assumed. This is also the positive control for the two absences above.
  local bin; bin="$(sandbox_path no)"
  body="$BATS_TEST_TMPDIR/body.json"; printf '{"t":"secret"}' > "$body"
  hdr="$BATS_TEST_TMPDIR/headers.txt"

  post_under "$bin" "$body" "$hdr"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  grep -q '^mkfifo ' "$CALL_LOG"
  grep -q '^bounded-copy ' "$CALL_LOG"

  # And the headers still arrive, by the longer route.
  grep -q 'X-Marker: from-curl' "$hdr"
}

@test "without the marker, the fifo is cleaned up and the header file is not (#850)" {
  # Both halves of the cleanup on the POSIX path: the temporary pipe goes, the
  # caller's file stays. Reading the fifo path out of the call log is what makes
  # the first half checkable — it is a name the helper chose, not one we passed.
  local bin; bin="$(sandbox_path no)"
  body="$BATS_TEST_TMPDIR/body.json"; printf '{"t":"secret"}' > "$body"
  hdr="$BATS_TEST_TMPDIR/headers.txt"

  post_under "$bin" "$body" "$hdr"
  [ "$status" -eq 0 ]

  fifo="$(sed -n 's/^mkfifo //p' "$CALL_LOG" | head -1)"
  [ -n "$fifo" ]
  refute test -e "$fifo"
  [ -f "$hdr" ]
}
