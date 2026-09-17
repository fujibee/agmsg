#!/usr/bin/env bats
# PATHS EMBEDDED IN A CURL CONFIG FILE ARE NOT TRANSLATED FOR YOU (#850).
#
# `_remote_http_post_json` hands curl its arguments in a `-K` config file so the
# request body -- which carries the token -- never appears in curl's argv. On
# Windows that has a consequence the POSIX side never sees: MSYS rewrites POSIX
# paths into Windows form for a native binary's ARGV, and does not touch the
# CONTENTS of a file that binary reads. So `data = "@/tmp/x"` reaches native
# curl as the literal string `/tmp/x`, which it cannot open. curl fails, and the
# caller reports HTTP 000 -- a network-shaped symptom for a path-shaped fault.
#
# THE SAME BYTES, TWO CONSUMERS. That is what makes this hard to test honestly:
# `/tmp/x` is openable by a POSIX curl and not by a native Windows one, so a
# path string is only right or wrong RELATIVE TO WHO READS IT. The stubs here
# are therefore capability-paired, and each test states which pairing it runs:
#
#   PATH        an allowlist sandbox -- cygpath is ABSENT because this file did
#               not link it, not because the host happens to lack one. Each arm
#               asserts the capability it relies on before relying on it.
#   curl        told which consumer it is playing. As `native-windows` it
#               refuses a POSIX path the way real curl.exe would; as `posix` it
#               refuses a Windows path. Neither accepts both.
#   cygpath     -m yields forward slashes, -w yields backslashes -- really both,
#               because telling them apart is the whole reason the fix names -m.
#
# An earlier version of this file got the second point wrong: its stub accepted
# any absolute POSIX path whatever the platform, so it could not have failed on
# the untranslated path that broke the user, and the file's own header claimed
# otherwise. Review caught it. What follows is written so that the claim and the
# stub say the same thing.

load test_helper

# Externals `remote.sh` needs to source, plus those `_remote_http_post_json`
# and the curl stub call. Derived by sourcing under an empty PATH and adding
# what it asked for, then reading the function for the rest: mktemp, mkfifo,
# chmod, python3 (the bounded-copy reader), rm, rmdir.
#
# An allowlist rather than a subtraction, matching `path_without_python3` in
# test_helper. A subtraction cannot express "cygpath is absent" on a machine
# where cygpath lives in the same directory as mktemp, which is every Git Bash.
SANDBOX_TOOLS=(bash dirname mktemp mkfifo chmod rm rmdir sed cp cat grep python3 uname)

setup() {
  setup_test_env

  CFG_CAPTURE="$BATS_TEST_TMPDIR/captured-config"
  export CFG_CAPTURE

  # The Windows drive prefix the fake cygpath maps onto. Any string works; what
  # matters is that the stubs agree, so the curl stub can undo it exactly the
  # way a native binary resolves a Windows path back to the same file.
  FAKE_ROOT="C:/msys64"
  export FAKE_ROOT

  STUB_SRC="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_SRC"

  cat > "$STUB_SRC/curl" <<'STUB'
#!/usr/bin/env bash
# Stands in for whichever curl the config is destined for. STUB_CURL_CONSUMER
# decides which one, and the two do NOT accept the same strings -- that
# asymmetry is the defect being tested, so a stub without it proves nothing.
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
cp "$cfg" "$CFG_CAPTURE"

# Resolve an embedded path to something this consumer can open, or fail.
#
#   native-windows  only a Windows path opens. A POSIX path is a literal
#                   filename with no such directory -- the reported bug.
#   posix           only a POSIX path opens. A Windows path is a filename
#                   containing a colon, which is not a path here.
resolve() {
  case "$STUB_CURL_CONSUMER:$1" in
    "native-windows:$FAKE_ROOT"/*) printf '%s' "/${1#"$FAKE_ROOT"/}" ;;
    native-windows:*) return 1 ;;
    posix:/*) printf '%s' "$1" ;;
    posix:*) return 1 ;;
    *) return 1 ;;
  esac
}

data_field="$(sed -n 's/^data = "@\(.*\)"$/\1/p' "$cfg")"
if [ -n "$data_field" ]; then
  if ! body="$(resolve "$data_field")" || [ ! -r "$body" ]; then
    echo "STUB_CURL($STUB_CURL_CONSUMER): cannot open data path: $data_field" >&2
    exit 26
  fi
fi

hdr_field="$(sed -n 's/^dump-header = "\(.*\)"$/\1/p' "$cfg")"
if [ -n "$hdr_field" ]; then
  if ! hdr="$(resolve "$hdr_field")"; then
    echo "STUB_CURL($STUB_CURL_CONSUMER): cannot open dump-header path: $hdr_field" >&2
    exit 23
  fi
  printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr" || {
    echo "STUB_CURL($STUB_CURL_CONSUMER): dump-header not writable: $hdr_field" >&2
    exit 23
  }
fi

[ -z "$out" ] || printf '{"ok":true}' > "$out"
printf '200'
STUB
  chmod +x "$STUB_SRC/curl"

  cat > "$STUB_SRC/cygpath" <<'STUB'
#!/usr/bin/env bash
set -u
mode="$1"; path="$2"
case "$mode" in
  -m) printf '%s%s' "$FAKE_ROOT" "$path" ;;
  -w) printf '%s%s' "${FAKE_ROOT//\//\\}" "${path//\//\\}" ;;
  *) echo "stub cygpath: unexpected mode $mode" >&2; exit 64 ;;
esac
STUB
  chmod +x "$STUB_SRC/cygpath"

  # A python3 that writes one line to stderr before becoming the real thing.
  # The copier is started with its stderr INHERITED, so that line arrives on the
  # helper's stderr -- which is what the redirect under test has to keep out of
  # bats's $output. Without something that actually writes there, adding or
  # removing the redirect changes nothing and the harness fix is unbound.
  REAL_PYTHON3="$(command -v python3)"; export REAL_PYTHON3
  NOISE="stderr-noise-from-the-copier"
  export NOISE
  cat > "$STUB_SRC/python3" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *bounded-copy.py*) printf '%s\n' "$NOISE" >&2 ;;
esac
exec "$REAL_PYTHON3" "$@"
STUB
  chmod +x "$STUB_SRC/python3"
}

teardown() { teardown_test_env; }

# A PATH holding the allowlist, the curl stub, and cygpath only when asked.
# Fails the test if the host is missing a tool: a silently short sandbox would
# make the helper fail for a reason that has nothing to do with the fix.
sandbox_path() {
  local want_cygpath="$1" dir tool src
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/sandbox.XXXXXX")"
  for tool in "${SANDBOX_TOOLS[@]}"; do
    src="$(command -v "$tool")" || { echo "host lacks $tool" >&2; return 1; }
    ln -s "$src" "$dir/$tool"
  done
  ln -s "$STUB_SRC/curl" "$dir/curl"
  ln -sf "$STUB_SRC/python3" "$dir/python3"
  [ "$want_cygpath" = "yes" ] && ln -s "$STUB_SRC/cygpath" "$dir/cygpath"
  printf '%s' "$dir"
}

# Runs the real helper under a sandbox PATH, and prints the http code. The
# consumer the curl stub plays is named by the caller, so a test cannot
# accidentally get a curl that accepts whatever the config happens to say.
# STDERR GOES TO A FILE, NOT INTO $output.
#
# bats merges the two streams, and this helper's stderr is not reliably empty.
# On a loaded macOS CI runner, bash reported
#
#   remote.sh: line NNN: .../agmsg-header-pipe.JVbrl7/header: Interrupted system call
#
# while opening the header fifo, and $output became that line followed by the
# http code. Every exact comparison against "200" or "000" then fails on a code
# that was in fact correct. Observed twice in one run, on a head that was green
# on the author's machine. That is the boundary of what was observed -- a
# loaded macOS CI runner produced it and no local run has. Load is the
# candidate, not something any control here varied.
#
# The http code is the only thing on stdout, so separating the streams is what
# makes an exact comparison mean what it says.
post_under() {
  local bin="$1" consumer="$2" body_file="$3" extra="${4:-}"
  ERR_FILE="$BATS_TEST_TMPDIR/helper-stderr"
  run env PATH="$bin" STUB_CURL_CONSUMER="$consumer" CFG_CAPTURE="$CFG_CAPTURE" \
    NOISE="$NOISE" REAL_PYTHON3="$REAL_PYTHON3" \
    FAKE_ROOT="$FAKE_ROOT" bash -c '
    set -uo pipefail
    . '"$SCRIPTS"'/remote.sh 2>/dev/null
    '"$extra"'
    _remote_http_post_json "https://example.invalid/v1/x" "'"$body_file"'" \
      "'"$BATS_TEST_TMPDIR"'/out-body" "'"$BATS_TEST_TMPDIR"'/out-header" 2>"'"$ERR_FILE"'"
  '
}

@test "the helper's stderr stays out of the code, and there IS stderr to keep out (#850)" {
  # THE CONTROL FOR THE REDIRECT ITSELF. Every other case here compares $output
  # against an exact code; that comparison only means something because stdout
  # and stderr are separated, and separation only means something when the
  # stream is non-empty. On a quiet run, adding or removing `2> "$ERR_FILE"`
  # changes nothing -- which is how the redirect went in unbound.
  #
  # The copier inherits the helper's stderr, so a python3 that writes one line
  # before exec'ing puts a real line there. What CI produced was bash reporting
  # an interrupted fifo open; this is a different writer to the same stream, and
  # it is deterministic.
  local bin; bin="$(sandbox_path no)"
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  post_under "$bin" posix "$body"
  [ "$status" -eq 0 ]

  # The code alone, and the noise really happened.
  [ "$output" = "200" ]
  grep -q -F -- "$NOISE" "$ERR_FILE"
}

@test "the sandbox decides whether cygpath exists — both directions (#850)" {
  # The control on the instrument. Every arm below rests on the capability
  # being what this file says it is, and on the host that is true by accident:
  # macOS has no cygpath at all. If the sandbox were not really removing it,
  # the negative arm would pass on any machine and fail on a Windows runner --
  # which is the one machine this fix is for.
  local without with
  without="$(sandbox_path no)"
  with="$(sandbox_path yes)"

  run env PATH="$without" bash -c 'command -v cygpath >/dev/null 2>&1 && echo PRESENT || echo ABSENT'
  [ "$output" = "ABSENT" ]

  run env PATH="$with" bash -c 'command -v cygpath >/dev/null 2>&1 && echo PRESENT || echo ABSENT'
  [ "$output" = "PRESENT" ]
}

@test "without cygpath the embedded paths are passed through byte for byte (#850)" {
  # macOS and Linux, and the assertion that says the fix costs them nothing:
  # the config must hold the exact strings the caller built.
  local bin; bin="$(sandbox_path no)"
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  post_under "$bin" posix "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  # The data path is one this test chose, so it can be compared exactly.
  grep -q -F -- "data = \"@$body\"" "$CFG_CAPTURE"

  # The header path is generated inside the helper, so what is asserted is its
  # shape: still POSIX, and untouched by any translation.
  hdr="$(sed -n 's/^dump-header = "\(.*\)"$/\1/p' "$CFG_CAPTURE")"
  [ -n "$hdr" ]
  case "$hdr" in /*) : ;; *) echo "not a POSIX path: $hdr"; return 1 ;; esac
  case "$hdr" in *"$FAKE_ROOT"*) echo "translated with no cygpath present: $hdr"; return 1 ;; esac
}

@test "with cygpath the DATA path is rendered in mixed Windows form (#850)" {
  # Two fields, two tests, because they are two effects of one line and can
  # regress apart. Asserting both in one test says "something is untranslated"
  # -- true of either, pointing at neither.
  local bin; bin="$(sandbox_path yes)"
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  post_under "$bin" native-windows "$body"
  [ "$status" -eq 0 ]

  # Deliberately NOT asserting the 200 here. The stub refuses to open either
  # field's path when it is untranslated, so a request fails whichever half is
  # wrong -- and asserting the outcome in both field tests made them both go
  # red for either mutation, which is the attribution this split exists to get.
  # The outcome has its own test below.
  grep -q -F -- "data = \"@$FAKE_ROOT$body\"" "$CFG_CAPTURE"
}

@test "with cygpath the DUMP-HEADER path is rendered in mixed Windows form (#850)" {
  # The half that is easy to leave behind: the body path is the one a reader
  # thinks of as "the file", and the header sink is generated inside the helper.
  # Translate one and not the other and curl opens the body, fails on the
  # header, and the caller reports 000 -- which reads as a header problem.
  local bin; bin="$(sandbox_path yes)"
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  post_under "$bin" native-windows "$body"
  [ "$status" -eq 0 ]

  # Config bytes only, for the reason given in the DATA case above.
  hdr="$(sed -n 's/^dump-header = "\(.*\)"$/\1/p' "$CFG_CAPTURE")"
  case "$hdr" in "$FAKE_ROOT"/*) : ;; *) echo "header path not translated: $hdr"; return 1 ;; esac
}

@test "with both fields rendered, the request actually completes (#850)" {
  # The outcome the two field tests deliberately leave alone. A native curl has
  # to be able to open BOTH paths for the call to return a code at all, so this
  # is the one assertion that fails for either field -- and that is its job:
  # whatever regresses, the user's request stops working.
  local bin; bin="$(sandbox_path yes)"
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  post_under "$bin" native-windows "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}

@test "the rendered paths carry forward slashes, never backslashes (#850)" {
  # `cygpath -w` also produces a valid Windows path, and it is the wrong one:
  # curl's config parser reads a backslash as an escape, so the path arrives
  # corrupted. Written against the config text rather than against the flag,
  # because what breaks a user is the bytes curl parses.
  local bin; bin="$(sandbox_path yes)"
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  post_under "$bin" native-windows "$body"
  [ "$status" -eq 0 ]

  refute grep -q '\\' "$CFG_CAPTURE"
}

@test "an untranslated POSIX path reaching native curl is the reported 000 (#850)" {
  # The defect itself, and the control on the stub. `_remote_curl_path` is
  # replaced AFTER sourcing, so the production helper is still the one under
  # test -- only its renderer is reduced to the passthrough it was before the
  # fix. The consumer is the native Windows one, which cannot open /tmp/...
  #
  # Without this case the assertions above could all be passing on a config no
  # curl would accept, which is exactly how the previous version of this file
  # was wrong.
  local bin; bin="$(sandbox_path yes)"
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  post_under "$bin" native-windows "$body" '_remote_curl_path() { printf "%s" "$1"; }'
  [ "$status" -eq 0 ]
  [ "$output" = "000" ]
}

@test "a Windows path reaching a POSIX curl is equally a 000 (#850)" {
  # The mirror, so "native-windows refuses POSIX paths" is not read as "this
  # stub refuses whatever the test needs it to". Each consumer refuses the
  # other's form, and the fix is what puts the right form in front of each.
  local bin; bin="$(sandbox_path no)"
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  post_under "$bin" posix "$body" '_remote_curl_path() { printf "%s%s" "$FAKE_ROOT" "$1"; }'
  [ "$status" -eq 0 ]
  # The status line, not the whole stream. This consumer takes the fifo branch,
  # and a curl that refuses the config never opens the header fifo -- so the
  # copier stays blocked in open() until the failure path kills it, and bash on
  # macOS reports that interrupted open on stderr (#869). The noise rides on a
  # request that was already failing; what this case is about is the code that
  # comes back, so assert a line that IS 000 rather than a stream equal to it.
  grep -qFx -- '000' <<<"$output"
}
