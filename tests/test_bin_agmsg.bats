#!/usr/bin/env bats

BIN="$BATS_TEST_DIRNAME/../bin/agmsg.js"

@test "bin/agmsg.js: --help lists install and daemon and exits 0" {
  run node "$BIN" --help
  [ "$status" -eq 0 ]
  grep -Fq -- "agmsg install" <<<"$output"
  grep -Fq -- "agmsg daemon" <<<"$output"
}

@test "bin/agmsg.js: no arguments prints usage and exits 2 (it must not start an install)" {
  run node "$BIN"
  [ "$status" -eq 2 ]
  grep -Fq -- "Usage:" <<<"$output"
}

@test "bin/agmsg.js: the runtime is handed the arguments unchanged and its exit status comes back" {
  local rt="$BATS_TEST_TMPDIR/agmsg"
  cat > "$rt" <<'RT'
#!/usr/bin/env bash
printf 'argc=%s\n' "$#"
for a in "$@"; do printf '[%s]\n' "$a"; done
exit 7
RT
  run node -e 'require(process.argv[1]).runRuntime(process.argv[2], ["daemon", "two words", "日本語", "it'"'"'s"])' "$BIN" "$rt"
  [ "$status" -eq 7 ]
  grep -Fq -- "argc=4" <<<"$output"
  grep -Fq -- "[two words]" <<<"$output"
  grep -Fq -- "[日本語]" <<<"$output"
  grep -Fq -- "[it's]" <<<"$output"
}

# Which install the entry hands off to: the default one, or the one AGMSG_CMD
# names -- and a named install that is missing must never fall back.
@test "bin/agmsg.js: install resolution (default, AGMSG_CMD, no fallback, several candidates)" {
  local root="$BATS_TEST_TMPDIR/skills"
  mkdir -p "$root/other/scripts" "$root/third/scripts"
  touch "$root/other/scripts/agmsg" "$root/third/scripts/agmsg"

  # No default install, two others: list them, choose nothing.
  run node -e 'const r=require(process.argv[1]).resolveRuntime({}, process.argv[2]); console.log(JSON.stringify(r))' "$BIN" "$root"
  grep -Fq -- '"error":true' <<<"$output"
  grep -Fq -- "other" <<<"$output"
  grep -Fq -- "third" <<<"$output"

  # Named install: used.
  run node -e 'const r=require(process.argv[1]).resolveRuntime({AGMSG_CMD:"other"}, process.argv[2]); console.log(r.runtime)' "$BIN" "$root"
  [ "$output" = "$root/other/scripts/agmsg" ]

  # Named install that does not exist: an error, even though a default exists.
  mkdir -p "$root/agmsg/scripts"; touch "$root/agmsg/scripts/agmsg"
  run node -e 'const r=require(process.argv[1]).resolveRuntime({AGMSG_CMD:"missing"}, process.argv[2]); console.log(JSON.stringify(r))' "$BIN" "$root"
  grep -Fq -- '"error":true' <<<"$output"

  # Default install present and no AGMSG_CMD: the default.
  run node -e 'const r=require(process.argv[1]).resolveRuntime({}, process.argv[2]); console.log(r.runtime)' "$BIN" "$root"
  [ "$output" = "$root/agmsg/scripts/agmsg" ]

  # A name that is not a plain install name is refused.
  run node -e 'const r=require(process.argv[1]).resolveRuntime({AGMSG_CMD:"../x"}, process.argv[2]); console.log(JSON.stringify(r))' "$BIN" "$root"
  grep -Fq -- '"error":true' <<<"$output"
}
