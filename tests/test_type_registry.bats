#!/usr/bin/env bats

# Direct unit tests for the pluggable agent-type registry: discovery + the
# per-key manifest reader. The behavioral wiring (whoami detection, join
# whitelist, spawn dispatch, delivery routing) is covered by the existing
# whoami/join/spawn/delivery suites; these lock the registry primitives and the
# six built-in manifests themselves.
#
# setup_test_env copies scripts/ (with scripts/drivers/types/) into TEST_SKILL_DIR, so the lib
# resolves <skill-root>/scripts/drivers/types there. Each case sources the lib in a wiped env so
# host vars (this is a Claude Code session — CLAUDE_CODE_SESSION_ID is set) cannot
# leak into detection.

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# Write a node-launcher fixture type into TEST_SKILL_DIR/scripts/drivers/types so the suite
# exercises the spawn= (Node launcher) mechanism generically, with no dependency
# on any real external add-on:
#   - "nodetype": a node-launcher type whose manifest sets spawn= to a .mjs, with
#     a stub launcher file beside the manifest.
write_node_launcher_fixtures() {
  local nd="$TEST_SKILL_DIR/scripts/drivers/types/nodetype"
  mkdir -p "$nd"
  printf 'name=nodetype\ntemplate=cmd.nodetype.md\nspawn=nodetype-launcher.mjs\n' \
    > "$nd/type.conf"
  printf '// stub node launcher fixture\n' > "$nd/nodetype-launcher.mjs"
}

@test "type-registry: known_types lists the eleven built-ins" {
  run env -i PATH="$PATH" bash -c \
    "source '$SCRIPTS/lib/type-registry.sh'; agmsg_known_types | sort -u | paste -sd, -"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg-app,antigravity,claude-code,codex,copilot,cursor,gemini,grok-build,hermes,opencode,pi" ]
}

@test "type-registry: is_known_type accepts a built-in and rejects a bogus type" {
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_is_known_type opencode"
  [ "$status" -eq 0 ]
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_is_known_type bogus-type"
  [ "$status" -ne 0 ]
}

@test "type-registry: type_get reads keys and returns a default for a missing one" {
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get codex template"
  [ "$status" -eq 0 ]; [ "$output" = "template.md" ]
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get codex hooks_file"
  [ "$output" = ".codex/hooks.json" ]
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get codex cli"
  [ "$output" = "codex" ]
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get gemini missingkey FALLBACK"
  [ "$output" = "FALLBACK" ]
}

@test "type-registry: template_path resolves to the type dir's template.md" {
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_template_path codex"
  [ "$status" -eq 0 ]
  [ "${output##*/types/}" = "codex/template.md" ]
  [ -f "$output" ]
  # Unknown type → non-zero, no path.
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_template_path bogus-type"
  [ "$status" -ne 0 ]
}

@test "agent templates route remote-import intent before not_joined identity setup" {
  local template not_joined first_time guard
  for template in "$BATS_TEST_DIRNAME"/../scripts/drivers/types/*/template.md; do
    [ -f "$template" ] || continue
    grep -q '^## Identity$' "$template" || continue
    not_joined="$(grep -n '^\*\*C) Not in a team:\*\*$' "$template" | cut -d: -f1)"
    first_time="$(grep -n '^  > \*\*First-time setup required\.\*\*$' "$template" | cut -d: -f1)"
    guard="$(grep -n 'Before first-time setup, inspect the user'"'"'s request' "$template" | cut -d: -f1)"
    [ -n "$not_joined" ]
    [ "$not_joined" -lt "$guard" ]
    [ "$guard" -lt "$first_time" ]
    sed -n "${guard},$((first_time - 1))p" "$template" |
      grep -q 'do not call `join.sh`'
    sed -n "${guard},$((first_time - 1))p" "$template" |
      grep -q 'team-list.sh --json --scope all'
    sed -n "${guard},$((first_time - 1))p" "$template" |
      grep -q 'Go directly to `remote pull`'
  done

  not_joined="$(grep -n '^### Step 2a: If not in a team' "$BATS_TEST_DIRNAME/../SKILL.md" | cut -d: -f1)"
  first_time="$(grep -n '^Ask the user for a team name\.' "$BATS_TEST_DIRNAME/../SKILL.md" | cut -d: -f1)"
  guard="$(grep -n '^Before first-time setup, inspect the user'"'"'s request\.' "$BATS_TEST_DIRNAME/../SKILL.md" | cut -d: -f1)"
  [ -n "$not_joined" ]
  [ "$not_joined" -lt "$guard" ]
  [ "$guard" -lt "$first_time" ]
}

@test "agent templates all explain that readable local history is not evidence a team is unencrypted (#682)" {
  # scripts/drivers/types/*/template.md is ten independent copies with no
  # shared fragment (#676's exact shape) -- a loop with `[ -f ] || continue`
  # alone would silently pass if the glob matched fewer than ten files (a
  # renamed/missing template), so the count is asserted explicitly rather
  # than just "every file found had it."
  local template count=0
  for template in "$BATS_TEST_DIRNAME"/../scripts/drivers/types/*/template.md; do
    [ -f "$template" ] || continue
    count=$((count + 1))
    grep -q "Readable local history is therefore not evidence that a team is unencrypted" "$template" \
      || { echo "missing the e2ee-verification paragraph: $template" >&2; return 1; }
  done
  # agmsg-app has no template.md (spawnable=no -- it's the desktop app's own
  # identity, not a CLI type), so ten is the whole set, not a lower bound a
  # silently-skipped file could still satisfy.
  [ "$count" -eq 10 ]
}

@test "the e2ee-verification explanation also appears in both remote-setup docs (#682)" {
  grep -q "readable local message history is not evidence" "$BATS_TEST_DIRNAME/../docs/remote-setup.md"
  grep -q "ローカルのメッセージ履歴が読めることは" "$BATS_TEST_DIRNAME/../docs/remote-setup.ja.md"
}

@test "every agent-readable surface routes key rotate, and none of them calls it unavailable" {
  # The claim being guarded is not a wording preference: `key rotate` shipped
  # on 2026-07-22 and seven days later ten surfaces began telling every agent
  # it was "not available yet (they refuse unconditionally and change no
  # state)". An agent reads one of these at startup, so the lie was answered
  # to users far more often than any doc under docs/ is read.
  #
  # The negative half alone would pass on a file that says nothing at all, so
  # both halves are asserted, and the count is explicit for the same reason as
  # the #682 test above.
  # A template is an installer INPUT: install.sh renders it with
  # `sed s/__SKILL_NAME__/$CMD_NAME/g`, so a route written with a literal
  # `agmsg` sends an agent installed as `--cmd m` at somebody else's install
  # — and rotation changes key state, so that is not a cosmetic slip. The
  # path is therefore asserted per surface kind, not as one shared substring:
  # matching only `key.sh rotate <team>` is green for both spellings and
  # would have let this through.
  local surface count=0
  for surface in "$BATS_TEST_DIRNAME"/../scripts/drivers/types/*/template.md \
                 "$BATS_TEST_DIRNAME"/../SKILL.md; do
    [ -f "$surface" ] || continue
    count=$((count + 1))
    case "$surface" in
      */SKILL.md)
        # The top-level skill doc is a rendered artifact, not an input: it
        # carries no placeholder at all, so here the literal is correct.
        grep -Fq 'bash ~/.agents/skills/agmsg/scripts/key.sh rotate <team>' "$surface" \
          || { echo "SKILL.md does not route rotate through the literal install path: $surface" >&2; return 1; }
        ;;
      *)
        grep -Fq 'bash ~/.agents/skills/__SKILL_NAME__/scripts/key.sh rotate <team>' "$surface" \
          || { echo "template does not route rotate through __SKILL_NAME__: $surface" >&2; return 1; }
        ! grep -Fq '~/.agents/skills/agmsg/' "$surface" \
          || { echo "template hardcodes the default install name: $surface" >&2; return 1; }
        ;;
    esac
    grep -Fq 'Device pairing (`key request` / `key approve`) is not implemented' "$surface" \
      || { echo "does not state the pairing commands are absent: $surface" >&2; return 1; }
    ! grep -qiE 'rotat(e|ion)[^.]*not available' "$surface" \
      || { echo "still calls rotation unavailable: $surface" >&2; return 1; }
  done
  # ten templates (agmsg-app has none) plus SKILL.md.
  [ "$count" -eq 11 ]

  # Bind the claim to the code. If `rotate` ever stops being a subcommand the
  # surfaces above become wrong again, and this is the line that says so.
  grep -qE '^[[:space:]]*rotate\)' "$BATS_TEST_DIRNAME/../scripts/key.sh"
  grep -qE '^cmd_rotate\(\)' "$BATS_TEST_DIRNAME/../scripts/key.sh"

  # The same false sentence also stood in key.sh itself, where `generate`
  # refuses an existing key: it named rotation unavailable and sent the user
  # to `show`. Assert the working route is offered there too.
  grep -Fq 'To mint a replacement epoch instead:' "$BATS_TEST_DIRNAME/../scripts/key.sh"
}

@test "type-registry: spawnable set is exactly nine of the eleven built-ins (#277, #279)" {
  # hermes deliberately stays out (#279): no known CLI mode starts it
  # interactive with a seeded initial prompt. agmsg-app also stays out: it's
  # the desktop app itself (spawnable=no), not a spawnable agent type.
  run env -i PATH="$PATH" bash -c \
    "source '$SCRIPTS/lib/type-registry.sh'
     while IFS= read -r t; do
       [ -n \"\$t\" ] || continue
       [ \"\$(agmsg_type_get \"\$t\" spawnable)\" = yes ] && echo \"\$t\"
     done <<< \"\$(agmsg_known_types | sort -u)\" | paste -sd, -"
  [ "$status" -eq 0 ]
  [ "$output" = "antigravity,claude-code,codex,copilot,cursor,gemini,grok-build,opencode,pi" ]
}

@test "type-registry: detection manifests carry the expected env / proc keys" {
  g() { env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get $1 $2"; }
  [ "$(g claude-code detect)" = "CLAUDE_CODE_SESSION_ID" ]
  [ "$(g codex detect)" = "CODEX_SANDBOX CODEX_THREAD_ID" ]
  [ "$(g gemini detect)" = "GEMINI_CLI GEMINI_API_KEY" ]
  [ "$(g antigravity detect)" = "explicit" ]
  [ "$(g copilot detect)" = "explicit" ]
  [ "$(g opencode detect_proc)" = "opencode opencode-*" ]
  [ "$(g pi detect_proc)" = "pi pi-*" ]
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
  local dir="$TEST_SKILL_DIR/scripts/drivers/types/evil"
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
  local types='claude-code|codex|gemini|antigravity|copilot|opencode|hermes'
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
  refute grep -q "is not supported by spawn yet" <<<"$output"
  ! echo "$output" | grep -q "unknown agent type"
}

@test "spawn: the node-launcher path also splices spawn-options tokens (before --initial-input) (#273)" {
  write_node_launcher_fixtures
  local proj="$BATS_TEST_TMPDIR/nodeproj"
  mkdir -p "$proj"
  bash "$SCRIPTS/join.sh" nodeteam existing claude-code "$proj"

  local stub_bin="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_bin"
  local capture="$BATS_TEST_TMPDIR/launch-capture.txt"
  cat > "$stub_bin/record.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$capture"
EOF
  chmod +x "$stub_bin/record.sh"

  local opts="$BATS_TEST_TMPDIR/spawn_options.yaml"
  cat > "$opts" <<'YAML'
nodetype:
  --extra-flag: extra-value
YAML

  run env -u TMUX -u HERDR_ENV -u HERDR_PANE_ID AGMSG_TERMINAL="$stub_bin/record.sh {cmd}" \
    AGMSG_SPAWN_OPTIONS_FILE="$opts" \
    bash "$SCRIPTS/spawn.sh" nodetype nodeagent --project "$proj" --no-wait
  [ "$status" -eq 0 ]
  local boot; boot="$(cat "$capture")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"nodetype-launcher.mjs"* ]]
  [[ "$output" == *"--extra-flag"* ]]
  [[ "$output" == *"extra-value"* ]]
  # spawn-options tokens land before --initial-input, matching the direct-CLI
  # path's "before the actas prompt" placement.
  local before_flag after_flag before_input
  before_flag=$(grep -n -- "--extra-flag" "$boot" | head -1 | cut -d: -f1)
  before_input=$(grep -n -- "--initial-input" "$boot" | head -1 | cut -d: -f1)
  [ "$before_flag" -lt "$before_input" ]
}
