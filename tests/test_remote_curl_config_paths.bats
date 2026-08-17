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
# WHAT THIS FILE DRIVES. The production `_remote_http_post_json`, sourced from
# `remote.sh`, with two stubs on PATH:
#
#   cygpath   present or absent, which is the capability the fix gates on
#   curl      captures the config it was given, and OPENS WHAT IT NAMES
#
# The second half of that stub is the point. A stub that only records the
# config would pass whatever the config said, including a path no curl could
# open -- which is the defect. This one resolves the path the way MSYS would,
# writes the headers, and FAILS if it cannot, so a wrong rendering shows up as
# the same 000 the user got rather than as a passing assertion about a string.

load test_helper

setup() {
  setup_test_env

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  CFG_CAPTURE="$BATS_TEST_TMPDIR/captured-config"
  export CFG_CAPTURE

  # The Windows drive prefix the fake cygpath maps onto. Any string works; what
  # matters is that the two stubs agree, so the curl stub can undo it exactly
  # the way a native binary on Windows resolves a real Windows path back to the
  # same file.
  FAKE_ROOT="C:/msys64"
  export FAKE_ROOT

  cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
# A stand-in for native curl on Windows: it reads the config, and it can only
# open paths that a native binary could open.
set -u
cfg=""
out=""
prev=""
for arg in "$@"; do
  case "$prev" in
    -K) cfg="$arg" ;;
    -o) out="$arg" ;;
  esac
  prev="$arg"
done
[ -n "$cfg" ] || { echo "STUB_CURL: no -K config" >&2; exit 2; }
cp "$cfg" "$CFG_CAPTURE"

# Undo the fake cygpath mapping, which is what the real MSYS/Windows pair does:
# a Windows path names the same file the POSIX path did. A path in neither form
# is one this stub cannot open -- and neither could curl.
resolve() {
  case "$1" in
    "$FAKE_ROOT"/*) printf '%s' "/${1#"$FAKE_ROOT"/}" ;;
    /*) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

# `data = "@<path>"` must name a readable file, or curl has nothing to post.
data_field="$(sed -n 's/^data = "@\(.*\)"$/\1/p' "$cfg")"
if [ -n "$data_field" ]; then
  if ! body="$(resolve "$data_field")" || [ ! -r "$body" ]; then
    echo "STUB_CURL: cannot open data path: $data_field" >&2
    exit 26
  fi
fi

# `dump-header = "<path>"` must be openable for writing. On the real thing this
# is the fifo the caller is already reading; failing to open it is exactly the
# fault this fix exists for.
hdr_field="$(sed -n 's/^dump-header = "\(.*\)"$/\1/p' "$cfg")"
if [ -n "$hdr_field" ]; then
  if ! hdr="$(resolve "$hdr_field")"; then
    echo "STUB_CURL: cannot open dump-header path: $hdr_field" >&2
    exit 23
  fi
  printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr" || {
    echo "STUB_CURL: dump-header not writable: $hdr_field" >&2
    exit 23
  }
fi

[ -z "$out" ] || printf '{"ok":true}' > "$out"
printf '200'
STUB
  chmod +x "$STUB_BIN/curl"

  cat > "$STUB_BIN/cygpath" <<'STUB'
#!/usr/bin/env bash
# Mixed (-m) gives forward slashes; Windows (-w) gives backslashes. The
# difference is the whole reason the fix names one of them, so the stub must
# actually produce both -- returning the same string for either would make the
# test unable to tell the two apart.
set -u
mode="$1"; path="$2"
case "$mode" in
  -m) printf '%s%s' "$FAKE_ROOT" "$path" ;;
  -w) printf '%s%s' "${FAKE_ROOT//\//\\}" "${path//\//\\}" ;;
  *) echo "stub cygpath: unexpected mode $mode" >&2; exit 64 ;;
esac
STUB
  chmod +x "$STUB_BIN/cygpath"
}

teardown() { teardown_test_env; }

# Runs the real helper with PATH arranged by the caller, and prints the http
# code it returned. `cygpath` is present only when asked for.
post_with() {
  local with_cygpath="$1" body_file="$2"
  local bin="$STUB_BIN"
  if [ "$with_cygpath" = "no" ]; then
    bin="$BATS_TEST_TMPDIR/bin-nocygpath"
    mkdir -p "$bin"
    ln -sf "$STUB_BIN/curl" "$bin/curl"
  fi
  run env PATH="$bin:$PATH" bash -c '
    set -uo pipefail
    . '"$SCRIPTS"'/remote.sh 2>/dev/null
    _remote_http_post_json "https://example.invalid/v1/x" "'"$body_file"'" \
      "'"$BATS_TEST_TMPDIR"'/out-body" "'"$BATS_TEST_TMPDIR"'/out-header"
  '
}

@test "without cygpath the embedded paths are passed through byte for byte (#850)" {
  # macOS and Linux have no cygpath, and this is the assertion that says the fix
  # costs them nothing: the config must hold the exact strings the caller built.
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  post_with no "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  # The data path is one the test chose, so it can be compared exactly.
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
  # -- which is true of either, and points at neither. Reverting the header
  # field alone must not be able to fail this one.
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  post_with yes "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  grep -q -F -- "data = \"@$FAKE_ROOT$body\"" "$CFG_CAPTURE"
}

@test "with cygpath the DUMP-HEADER path is rendered in mixed Windows form (#850)" {
  # The half that is easy to leave behind: the body path is the one a reader
  # thinks of as "the file", and the header sink is generated inside the helper.
  # Translate one and not the other and curl opens the body, fails on the
  # header, and the caller reports 000 -- which reads as a header problem.
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  post_with yes "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  hdr="$(sed -n 's/^dump-header = "\(.*\)"$/\1/p' "$CFG_CAPTURE")"
  case "$hdr" in "$FAKE_ROOT"/*) : ;; *) echo "header path not translated: $hdr"; return 1 ;; esac
}

@test "the rendered paths carry forward slashes, never backslashes (#850)" {
  # `cygpath -w` also produces a valid Windows path, and it is the wrong one:
  # curl's config parser reads a backslash as an escape, so the path arrives
  # corrupted. This is the assertion that separates -m from -w, and it is
  # written against the config text rather than against the flag, because what
  # breaks a user is the bytes curl parses.
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  post_with yes "$body"
  [ "$status" -eq 0 ]

  # No backslash anywhere in either embedded path.
  ! grep -q '\\' "$CFG_CAPTURE"
}

@test "a path curl cannot open surfaces as HTTP 000, the way the user saw it (#850)" {
  # The negative control for the stub itself. If the stub accepted any string as
  # a path, every assertion above would pass on a broken rendering -- so make
  # the rendering broken on purpose and confirm the stub notices.
  #
  # `_remote_curl_path` is replaced AFTER sourcing, so the production helper is
  # still the one under test; only its path renderer is made to produce
  # something no curl could open.
  body="$BATS_TEST_TMPDIR/body.json"
  printf '{"t":"secret"}' > "$body"

  run env PATH="$STUB_BIN:$PATH" bash -c '
    set -uo pipefail
    . '"$SCRIPTS"'/remote.sh 2>/dev/null
    _remote_curl_path() { printf "Z:\\\\nowhere\\\\%s" "$1"; }
    _remote_http_post_json "https://example.invalid/v1/x" "'"$body"'" \
      "'"$BATS_TEST_TMPDIR"'/out-body" "'"$BATS_TEST_TMPDIR"'/out-header"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "000" ]
}
