#!/usr/bin/env bats

# Direct unit tests for the pluggable agent-type registry: discovery + the
# per-key manifest reader. The behavioral wiring (whoami detection, join
# whitelist, spawn dispatch, delivery routing) is covered by the existing
# whoami/join/spawn/delivery suites; these lock the registry primitives and the
# six built-in manifests themselves.
#
# setup_test_env copies both scripts/ and types/ into TEST_SKILL_DIR, so the lib
# resolves <skill-root>/types there. Each case sources the lib in a wiped env so
# host vars (this is a Claude Code session — CLAUDE_CODE_SESSION_ID is set) cannot
# leak into detection.

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# Write a node-launcher fixture type into TEST_SKILL_DIR/types so the suite
# exercises the spawn= (Node launcher) mechanism generically, with no dependency
# on any real external add-on:
#   - "nodetype": a node-launcher type whose manifest sets spawn= to a .mjs, with
#     a stub launcher file beside the manifest.
write_node_launcher_fixtures() {
  local nd="$TEST_SKILL_DIR/types/nodetype"
  mkdir -p "$nd"
  printf 'name=nodetype\ntemplate=cmd.nodetype.md\nspawn=nodetype-launcher.mjs\n' \
    > "$nd/type.conf"
  printf '// stub node launcher fixture\n' > "$nd/nodetype-launcher.mjs"
}

@test "type-registry: known_types lists the six built-ins" {
  run env -i PATH="$PATH" bash -c \
    "source '$SCRIPTS/lib/type-registry.sh'; agmsg_known_types | sort -u | paste -sd, -"
  [ "$status" -eq 0 ]
  [ "$output" = "antigravity,claude-code,codex,copilot,gemini,opencode" ]
}

@test "type-registry: is_known_type accepts a built-in and rejects a bogus type" {
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_is_known_type opencode"
  [ "$status" -eq 0 ]
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_is_known_type bogus-type"
  [ "$status" -ne 0 ]
}

@test "type-registry: type_get reads keys and returns a default for a missing one" {
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get codex template"
  [ "$status" -eq 0 ]; [ "$output" = "cmd.codex.md" ]
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get codex hooks_file"
  [ "$output" = ".codex/hooks.json" ]
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get codex cli"
  [ "$output" = "codex" ]
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get gemini missingkey FALLBACK"
  [ "$output" = "FALLBACK" ]
}

@test "type-registry: spawnable set is exactly claude-code and codex" {
  run env -i PATH="$PATH" bash -c \
    "source '$SCRIPTS/lib/type-registry.sh'
     while IFS= read -r t; do
       [ -n \"\$t\" ] || continue
       [ \"\$(agmsg_type_get \"\$t\" spawnable)\" = yes ] && echo \"\$t\"
     done <<< \"\$(agmsg_known_types | sort -u)\" | paste -sd, -"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-code,codex" ]
}

@test "type-registry: detection manifests carry the expected env / proc keys" {
  g() { env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get $1 $2"; }
  [ "$(g claude-code detect)" = "CLAUDE_CODE_SESSION_ID" ]
  [ "$(g codex detect)" = "CODEX_SANDBOX CODEX_THREAD_ID" ]
  [ "$(g gemini detect)" = "GEMINI_API_KEY GOOGLE_GEMINI_CLI" ]
  [ "$(g antigravity detect)" = "explicit" ]
  [ "$(g copilot detect)" = "explicit" ]
  [ "$(g opencode detect_proc)" = "opencode opencode-*" ]
}

@test "type-registry: whoami detects codex end-to-end from CODEX_THREAD_ID" {
  # Join a codex agent so whoami has a registration to report, then call it with
  # no explicit type: detection must pick codex from the manifest's detect= key.
  bash "$SCRIPTS/join.sh" myteam bob codex "$BATS_TEST_TMPDIR" >/dev/null
  run env -i PATH="$PATH" CODEX_THREAD_ID=x bash "$SCRIPTS/whoami.sh" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "type=codex"
}

@test "type-registry: env-detection precedence is claude-code < codex < gemini" {
  # Reproduce whoami's manifest-driven env sweep (sorted order) and assert the
  # historical precedence: a runtime's own session var beats the GEMINI_* family,
  # and detect=explicit types never win.
  sweep() {
    env -i PATH="$PATH" "$@" bash -c "
      source '$SCRIPTS/lib/type-registry.sh'
      while IFS= read -r t; do
        [ -n \"\$t\" ] || continue
        d=\$(agmsg_type_get \"\$t\" detect)
        if [ -z \"\$d\" ] || [ \"\$d\" = explicit ]; then continue; fi
        for v in \$d; do [ -n \"\${!v:-}\" ] && { echo \"\$t\"; exit 0; }; done
      done <<< \"\$(agmsg_known_types | sort -u)\"
      echo claude-code"
  }
  [ "$(sweep CODEX_THREAD_ID=x)" = codex ]
  [ "$(sweep GEMINI_API_KEY=x)" = gemini ]
  [ "$(sweep CLAUDE_CODE_SESSION_ID=x CODEX_THREAD_ID=y)" = claude-code ]
  [ "$(sweep CODEX_SANDBOX=x GEMINI_API_KEY=y)" = codex ]
  [ "$(sweep)" = claude-code ]
}

@test "type-registry: manifests are DATA — never executed" {
  # An adversarial value must be read as a literal string, not run.
  local dir="$TEST_SKILL_DIR/types/evil"
  mkdir -p "$dir"
  printf 'name=evil\ncli=$(touch %s/PWNED)\n' "$BATS_TEST_TMPDIR" > "$dir/type.conf"
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get evil cli"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/PWNED" ]
}

@test "type-registry: type_get returns its default under set -e + pipefail" {
  # A missing key must reach the default branch even when grep exits 1 under
  # pipefail (regression: the assignment used to abort silently).
  run bash -c "set -euo pipefail; source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get gemini missingkey DEF; echo REACHED"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "DEF"
  echo "$output" | grep -qx "REACHED"
}

@test "type-registry: detect_proc matching is independent of the caller's cwd" {
  # Regression: `for p in \$pats` glob-expanded the patterns against cwd, so a
  # project file like codex-helper made codex-* stop matching real codex procs.
  # detect_cli_type runs the split under `set -f`; prove that makes it cwd-proof.
  local proj="$BATS_TEST_TMPDIR/proj"; mkdir -p "$proj"; touch "$proj/codex-helper" "$proj/claude-x"
  run env -i PATH="$PATH" bash -c "cd '$proj'
    source '$SCRIPTS/lib/type-registry.sh'; set -f
    pats=\$(agmsg_type_get codex detect_proc); m=no
    for p in \$pats; do case codex-nightly in \$p) m=yes ;; esac; done
    echo \$m"
  [ "$output" = "yes" ]
}

@test "type-registry: whoami precedence — claude-code beats codex end-to-end" {
  bash "$SCRIPTS/join.sh" t alice claude-code "$BATS_TEST_TMPDIR" >/dev/null
  run env -i PATH="$PATH" CLAUDE_CODE_SESSION_ID=x CODEX_THREAD_ID=y bash "$SCRIPTS/whoami.sh" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "type=claude-code"
}

@test "type-registry: refactored scripts hardcode no per-type branch" {
  # join.sh and spawn.sh must be fully data-driven; whoami.sh is allowed only its
  # default fallback (echo "claude-code"). Any other type literal on a non-comment
  # line is a re-introduced per-type branch.
  local types='claude-code|codex|gemini|antigravity|copilot|opencode'
  for f in join.sh spawn.sh; do
    run bash -c "sed 's/#.*//' '$SCRIPTS/$f' | grep -nE '$types' || true"
    [ -z "$output" ] || { echo "hardcoded type literal in $f:"; echo "$output"; false; }
  done
  run bash -c "sed 's/#.*//' '$SCRIPTS/whoami.sh' | grep -nE '$types' | grep -vE 'echo \"claude-code\"' || true"
  [ -z "$output" ] || { echo "unexpected type literal in whoami.sh:"; echo "$output"; false; }
}

@test "type-registry: node-launcher type resolves its spawn launcher file" {
  write_node_launcher_fixtures
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get nodetype spawn"
  [ "$status" -eq 0 ]
  [ "$output" = "nodetype-launcher.mjs" ]
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_dir nodetype"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -f "$output/nodetype-launcher.mjs" ]
}

@test "type-registry: spawnable set (spawnable=yes OR non-empty spawn=) includes nodetype" {
  write_node_launcher_fixtures
  run env -i PATH="$PATH" bash -c \
    "source '$SCRIPTS/lib/type-registry.sh'
     while IFS= read -r t; do
       [ -n \"\$t\" ] || continue
       if [ \"\$(agmsg_type_get \"\$t\" spawnable)\" = yes ] || [ -n \"\$(agmsg_type_get \"\$t\" spawn)\" ]; then
         echo \"\$t\"
       fi
     done <<< \"\$(agmsg_known_types | sort -u)\" | paste -sd, -"
  [ "$status" -eq 0 ]
  echo "$output" | tr ',' '\n' | grep -qx nodetype
  echo "$output" | tr ',' '\n' | grep -qx claude-code
  echo "$output" | tr ',' '\n' | grep -qx codex
}

@test "spawn: a spawn= node-launcher type clears the spawnable gate" {
  # Regression: the gate honoured only spawnable=yes while spawnable_types() also
  # counts spawn=, so a node-launcher type (nodetype: spawn=, no spawnable=yes)
  # was rejected as 'not supported' yet listed as supported. It must clear the
  # gate (it then fails later for lack of a team/terminal — that's expected).
  write_node_launcher_fixtures
  run "$SCRIPTS/spawn.sh" nodetype someagent --project "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  ! echo "$output" | grep -q "is not supported by spawn yet"
  ! echo "$output" | grep -q "unknown agent type"
}
