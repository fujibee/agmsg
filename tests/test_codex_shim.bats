#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
  export CALL_LOG="$TEST_PROJECT/calls.log"

  export FAKE_CODEX="$TEST_PROJECT/real-codex"
  cat > "$FAKE_CODEX" <<'EOF'
#!/usr/bin/env bash
printf 'real-codex' >> "$CALL_LOG"
for arg in "$@"; do
  printf ' <%s>' "$arg" >> "$CALL_LOG"
done
printf '\n' >> "$CALL_LOG"
EOF
  chmod +x "$FAKE_CODEX"

  export FAKE_MONITOR="$TEST_PROJECT/monitor"
  cat > "$FAKE_MONITOR" <<'EOF'
#!/usr/bin/env bash
printf 'monitor real=%s' "${AGMSG_REAL_CODEX:-}" >> "$CALL_LOG"
for arg in "$@"; do
  printf ' <%s>' "$arg" >> "$CALL_LOG"
done
printf '\n' >> "$CALL_LOG"
EOF
  chmod +x "$FAKE_MONITOR"
}

teardown() {
  rm -rf "$TEST_PROJECT"
  teardown_test_env
}

@test "codex shim: monitor project routes resume through codex-monitor" {
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" bash "$TYPES/codex/codex-shim.sh" resume --last'

  [ "$status" -eq 0 ]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <resume> <--> <--last>" "$CALL_LOG"
}

@test "codex shim: monitor project routes prompt launches through top-level codex" {
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" bash "$TYPES/codex/codex-shim.sh" "fix this"'

  [ "$status" -eq 0 ]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <codex> <--> <fix this>" "$CALL_LOG"
}

@test "codex shim: monitor project forwards a flags-only launch to codex-monitor (#386)" {
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" bash "$TYPES/codex/codex-shim.sh" --yolo'

  [ "$status" -eq 0 ]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <codex> <--> <--yolo>" "$CALL_LOG"
}

@test "codex shim: non-monitor project passes through to real codex" {
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null

  AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" \
    run bash "$TYPES/codex/codex-shim.sh" resume --last

  [ "$status" -eq 0 ]
  grep -q "real-codex <resume> <--last>" "$CALL_LOG"
  ! grep -q "^monitor" "$CALL_LOG"
}

@test "codex shim: noninteractive codex subcommands pass through even in monitor mode" {
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" \
    run bash "$TYPES/codex/codex-shim.sh" exec echo hi

  [ "$status" -eq 0 ]
  grep -q "real-codex <exec> <echo> <hi>" "$CALL_LOG"
  ! grep -q "^monitor" "$CALL_LOG"
}

@test "codex shim: --cd project is used for monitor detection" {
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" \
    run bash "$TYPES/codex/codex-shim.sh" --cd "$TEST_PROJECT" resume

  [ "$status" -eq 0 ]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <resume> <--> <--cd> <$TEST_PROJECT>" "$CALL_LOG"
}

@test "codex shim install: default prints shell function without installing bin wrapper" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME"

  run bash "$TYPES/codex/codex-shim-install.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"codex() {"* ]]
  [[ "$output" == *"codex-shim.sh"* ]]
  [ ! -e "$HOME/.agents/bin/codex" ]
}

@test "codex shim function: existing agmsg PATH wrapper is skipped when resolving real codex" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  bash "$TYPES/codex/codex-shim-install.sh" install >/dev/null
  [ -x "$HOME/.agents/bin/codex" ]

  local real_bin="$TEST_PROJECT/real-bin"
  mkdir -p "$real_bin"
  cp "$FAKE_CODEX" "$real_bin/codex"
  chmod +x "$real_bin/codex"

  PATH="$HOME/.agents/bin:$real_bin:$PATH" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" \
    run bash -c 'eval "$("$TYPES/codex/codex-shim-install.sh" function)"; cd "$TEST_PROJECT"; codex resume --last'

  [ "$status" -eq 0 ]
  grep -Fq "monitor real=$real_bin/codex <--project> <$TEST_PROJECT> <--codex-command> <resume> <--> <--last>" "$CALL_LOG"
  ! grep -Fq "monitor real=$HOME/.agents/bin/codex" "$CALL_LOG"
}

@test "codex shim function: non-agmsg PATH codex remains eligible as real codex" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME/.agents/bin"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  cp "$FAKE_CODEX" "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"

  PATH="$HOME/.agents/bin:$PATH" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" \
    run bash -c 'eval "$("$TYPES/codex/codex-shim-install.sh" function)"; cd "$TEST_PROJECT"; codex resume --last'

  [ "$status" -eq 0 ]
  grep -Fq "monitor real=$HOME/.agents/bin/codex <--project> <$TEST_PROJECT> <--codex-command> <resume> <--> <--last>" "$CALL_LOG"
}

@test "codex shim install: installed bin wrapper still finds skill scripts" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  bash "$TYPES/codex/codex-shim-install.sh" install >/dev/null
  [ -x "$HOME/.agents/bin/codex" ]

  PATH="$HOME/.agents/bin:$PATH" run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" codex resume'

  [ "$status" -eq 0 ]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <resume> <-->" "$CALL_LOG"
}

@test "codex shim: a raw symlink install still resolves its own script location (#387)" {
  # Installing codex-shim.sh directly as a symlink (ln -s .../codex-shim.sh
  # ~/.agents/bin/codex) is a documented install method -- the header comment
  # says exactly this. Before #387, dirname "$0" resolved to the symlink's
  # OWN directory rather than the real script's, so the relative delivery.sh
  # lookup pointed nowhere and the shim silently fell through to plain codex
  # with zero signal, in every monitor-mode project, unconditionally.
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME/.agents/bin"
  ln -s "$TYPES/codex/codex-shim.sh" "$HOME/.agents/bin/codex"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  PATH="$HOME/.agents/bin:$PATH" run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" codex resume'

  [ "$status" -eq 0 ]
  [[ "$output" != *"cannot find delivery.sh"* ]]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <resume> <-->" "$CALL_LOG"
}

@test "codex shim: _agmsg_resolve_self follows a relative-target symlink (#387)" {
  # A direct unit test of the resolution helper (extracted verbatim from the
  # shipped script via awk, so this exercises the real implementation) rather
  # than a full shim invocation -- avoids needing to fabricate a whole
  # relative skill-tree layout just to get a relative `ln -s` target that
  # still resolves to a real delivery.sh. Covers the non-absolute branch of
  # its target-reconstruction (`ln -s ../real/target.sh link`, as opposed to
  # an absolute target).
  local helper="$TEST_PROJECT/resolve-self.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    awk '/^_agmsg_resolve_self\(\)/,/^}/' "$TYPES/codex/codex-shim.sh"
    echo '_agmsg_resolve_self "$1"'
  } > "$helper"

  mkdir -p "$TEST_PROJECT/real/deep" "$TEST_PROJECT/bin"
  : > "$TEST_PROJECT/real/deep/target.sh"
  ln -s "../real/deep/target.sh" "$TEST_PROJECT/bin/link"

  run bash "$helper" "$TEST_PROJECT/bin/link"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_PROJECT/real/deep/target.sh" ]
}

@test "codex shim: _agmsg_resolve_self follows a multi-hop symlink chain (#387)" {
  local helper="$TEST_PROJECT/resolve-self.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    awk '/^_agmsg_resolve_self\(\)/,/^}/' "$TYPES/codex/codex-shim.sh"
    echo '_agmsg_resolve_self "$1"'
  } > "$helper"

  mkdir -p "$TEST_PROJECT/real" "$TEST_PROJECT/hop" "$TEST_PROJECT/bin"
  : > "$TEST_PROJECT/real/target.sh"
  ln -s "$TEST_PROJECT/real/target.sh" "$TEST_PROJECT/hop/hop1"
  ln -s "$TEST_PROJECT/hop/hop1" "$TEST_PROJECT/bin/link"

  run bash "$helper" "$TEST_PROJECT/bin/link"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_PROJECT/real/target.sh" ]
}

@test "codex shim: a multi-hop symlink chain still resolves its own script location (#387)" {
  # symlink -> symlink -> real script. _agmsg_resolve_self's while loop must
  # keep following until it reaches a non-symlink.
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME/.agents/bin" "$HOME/intermediate"
  ln -s "$TYPES/codex/codex-shim.sh" "$HOME/intermediate/codex-hop1"
  ln -s "$HOME/intermediate/codex-hop1" "$HOME/.agents/bin/codex"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  PATH="$HOME/.agents/bin:$PATH" run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_MONITOR_CMD="$FAKE_MONITOR" codex resume'

  [ "$status" -eq 0 ]
  [[ "$output" != *"cannot find delivery.sh"* ]]
  grep -q "monitor real=$FAKE_CODEX <--project> <$TEST_PROJECT> <--codex-command> <resume> <-->" "$CALL_LOG"
}

@test "codex shim: a broken install (missing delivery.sh) warns loudly instead of silently passing through (#387)" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME/.agents/bin"
  # A shim copied somewhere with no skill tree above it at all -- SCRIPT_DIR
  # resolves fine, but the relative delivery.sh three levels up genuinely
  # does not exist. This must be reported, not treated as "not a monitor
  # project".
  cp "$TYPES/codex/codex-shim.sh" "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"

  PATH="$HOME/.agents/bin:$PATH" run bash -c 'cd "$TEST_PROJECT" && AGMSG_REAL_CODEX="$FAKE_CODEX" codex'

  [ "$status" -eq 0 ]
  [[ "$output" =~ "cannot find delivery.sh" ]]
  grep -q "real-codex" "$CALL_LOG"
}

# --- shim ownership (#553): install.sh's own driver is tested separately in
# test_install.bats; these exercise codex-shim-install.sh's own refuse/force
# logic directly, against two independent copies of the codex driver dir
# standing in for two different installs.

_second_codex_dir() {
  local dir="$TEST_PROJECT/second-install/codex"
  mkdir -p "$dir"
  cp -R "$TYPES/codex/." "$dir/"
  printf '%s' "$dir"
}

@test "codex shim install: refuses to repoint a shim owned by a different install" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME"
  bash "$TYPES/codex/codex-shim-install.sh" install >/dev/null
  local shim="$HOME/.agents/bin/codex"
  local before; before="$(cat "$shim")"

  local second_dir; second_dir="$(_second_codex_dir)"
  run bash "$second_dir/codex-shim-install.sh" install
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF "owned by a different install"
  printf '%s' "$output" | grep -qF "$TYPES/codex"  # names the actual owner, not just "someone else"
  printf '%s' "$output" | grep -qF "AGMSG_CODEX_SHIM_FORCE=1"

  [ "$(cat "$shim")" = "$before" ]  # byte-for-byte unchanged
}

@test "codex shim install: AGMSG_CODEX_SHIM_FORCE=1 reclaims a shim owned by a different install" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME"
  bash "$TYPES/codex/codex-shim-install.sh" install >/dev/null

  local second_dir; second_dir="$(_second_codex_dir)"
  run bash -c "AGMSG_CODEX_SHIM_FORCE=1 bash '$second_dir/codex-shim-install.sh' install"
  [ "$status" -eq 0 ]
  grep -q "AGMSG_CODEX_SHIM_SCRIPT_DIR=$second_dir" "$HOME/.agents/bin/codex"
}

@test "codex shim status: names which install currently owns the shim" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME"
  bash "$TYPES/codex/codex-shim-install.sh" install >/dev/null

  run bash "$TYPES/codex/codex-shim-install.sh" status
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "owner: this install ($TYPES/codex)"

  local second_dir; second_dir="$(_second_codex_dir)"
  run bash "$second_dir/codex-shim-install.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"owner: a different install ($TYPES/codex)"* ]]
}

@test "codex shim install: a plain, non-agmsg codex binary is still refused regardless of ownership wording (#553 regression guard)" {
  # The pre-existing is_agmsg_shim guard, unrelated to ownership -- a real
  # user codex binary at the target path must never be touched or described
  # as "owned by a different install" (that phrasing is reserved for a shim
  # this tool itself generated).
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME/.agents/bin"
  printf '#!/usr/bin/env bash\necho real\n' > "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"
  local before; before="$(cat "$HOME/.agents/bin/codex")"

  run bash "$TYPES/codex/codex-shim-install.sh" install
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF "refusing to overwrite existing"
  refute grep -qF "owned by a different install" <(printf '%s' "$output")
  [ "$(cat "$HOME/.agents/bin/codex")" = "$before" ]
}

@test "codex shim status: a multi-line status output does not spuriously fail a piped grep -q check (#553 regression guard)" {
  # Measured, not theoretical: adding the second "owner:" line to status's
  # output broke install.sh's own \`status ... | grep -q '^installed:'\` check
  # under this script's \`pipefail\` -- grep exits the instant it matches the
  # first line, and status's still-pending write of the second line then hits
  # SIGPIPE, which pipefail reports as the pipeline failing even though grep
  # DID match. Pins the exact shape install.sh now avoids by capturing status
  # into a variable first; this test guards the underlying hazard directly so
  # a future caller that pipes status straight into grep -q reintroduces it.
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME"
  bash "$TYPES/codex/codex-shim-install.sh" install >/dev/null

  run bash -c "set -o pipefail; bash '$TYPES/codex/codex-shim-install.sh' status | grep -q '^installed:'"
  [ "$status" -ne 0 ]  # documents the hazard: this form is expected to fail today

  run bash -c "set -o pipefail; out=\"\$(bash '$TYPES/codex/codex-shim-install.sh' status)\"; printf '%s' \"\$out\" | grep -q '^installed:'"
  [ "$status" -eq 0 ]  # the capture-first form install.sh actually uses does not
}

@test "codex shim status/install: a tampered shim cannot execute code via ownership parsing (#553 security regression guard)" {
  # is_agmsg_shim's authenticity check is a grep for one marker string -- it
  # says nothing about the rest of a LOCAL, single-user, world-writable-by-
  # that-user path having been hand-edited afterward. An earlier version of
  # shim_owner_script_dir read the ownership line via `eval`, which turned
  # that gap into arbitrary code execution reachable from a read-only `status`
  # call. Plants a shim carrying the real marker (so is_agmsg_shim matches)
  # plus a line shaped exactly like the one that used to get eval'd, except
  # its "value" is a command substitution that -- if ever executed -- writes a
  # sentinel file. Both status and a plain (non-force) install must leave
  # that sentinel absent.
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME/.agents/bin"
  local sentinel="$TEST_PROJECT/pwned"
  cat > "$HOME/.agents/bin/codex" <<EOF
#!/usr/bin/env bash
# Optional Codex entrypoint shim for agmsg monitor mode.
export AGMSG_CODEX_SHIM_SCRIPT_DIR=\$(touch $sentinel)
exec true
EOF
  chmod +x "$HOME/.agents/bin/codex"

  run bash "$TYPES/codex/codex-shim-install.sh" status
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "owner: unknown"
  [ ! -e "$sentinel" ]

  # No `# agmsg-shim-owner:` line at all (this crafted file predates it, same
  # as any real shim written before this PR) reads as owner unknown, which
  # fails closed the same as a foreign owner would (#553 review: "unowned" and
  # "owner not recorded" are not the same claim, and treating them the same
  # would silently repeat #553's own bug against every pre-existing shim on
  # first contact with a second, differently-named install). The property
  # under test either way: nothing the tampered content contains ever runs.
  run bash "$TYPES/codex/codex-shim-install.sh" install
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF "before ownership tracking"
  [ ! -e "$sentinel" ]

  AGMSG_CODEX_SHIM_FORCE=1 run bash "$TYPES/codex/codex-shim-install.sh" install
  [ "$status" -eq 0 ]
  [ ! -e "$sentinel" ]
}

# --- agmsg_install_candidates / agmsg_only_one_install (#553 review): these
# were split from one function into two (list, then count) so a future #659
# could call the listing half instead of re-scanning ~/.agents/skills itself.
# agmsg_only_one_install answers "zero OTHER installs besides me (SCRIPT_DIR)"
# rather than "exactly one candidate total" (second review round): install.sh
# checks/refreshes the shim BEFORE it touches this install's own .agmsg
# marker, so during a fresh install self's own marker genuinely isn't on disk
# yet -- a plain total-candidate count would then undercount and let a
# genuinely second install claim a legacy shim it was never told to take.
# These probes set $0 the same way a real invocation does (bash <path>/
# codex-shim-install.sh ...), via bash -c's argv0 trick, so "self" resolves
# to a real, chosen path rather than whatever sourcing this from a bats
# helper would otherwise produce.
_run_candidate_probe() {
  local probe_home="$1" self_dir="$2"
  run bash -c "
    HOME='$probe_home'
    source '$TYPES/codex/codex-shim-install.sh' >/dev/null 2>&1
    agmsg_install_candidates
    echo '[end]'
    if agmsg_only_one_install; then echo only_one=true; else echo only_one=false; fi
  " "$self_dir/codex-shim-install.sh"
}

_candidate_lines() {
  echo "$output" | awk '/\[end\]/{exit}{print}'
}

@test "agmsg_only_one_install: fresh install, self's own marker not written yet, no one else present" {
  # The exact ordering gap review found: self is a real install about to
  # register itself, but hasn't yet -- agmsg_install_candidates must not be
  # the only thing that decides this; self must count even while invisible
  # on disk.
  export HOME="$TEST_PROJECT/home"
  local self_dir="$HOME/.agents/skills/agmsg/scripts/drivers/types/codex"
  # The skill directory tree (and this codex driver subdir within it) is
  # laid down by install.sh well before the shim step -- only the .agmsg
  # marker in the skill root is deferred. Create the tree, but not the
  # marker, to match that ordering exactly.
  mkdir -p "$self_dir"

  _run_candidate_probe "$HOME" "$self_dir"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "only_one=true"
  # nothing was listed before [end] -- an empty candidate set (self isn't on
  # disk yet either). awk (not a sed "1,/re/" range) because that range
  # never closes on line 1 itself, which is exactly this case ([end] IS
  # line 1) -- it would silently keep reading past it instead.
  [ -z "$(_candidate_lines)" ]
}

@test "agmsg_only_one_install: fresh install, self's marker not written yet, but ONE other install already exists" {
  # Same ordering gap as above, but this time there really is someone else
  # -- pins that the allowance is specifically about self being invisible,
  # not about being lenient whenever the total looks low.
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME/.agents/skills/agmsg"
  touch "$HOME/.agents/skills/agmsg/.agmsg"
  local self_dir="$HOME/.agents/skills/agmsg-dfr/scripts/drivers/types/codex"
  mkdir -p "$self_dir"

  _run_candidate_probe "$HOME" "$self_dir"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "only_one=false"
  local candidate_lines; candidate_lines="$(_candidate_lines | grep -c .)"
  [ "$candidate_lines" -eq 1 ]
}

@test "agmsg_only_one_install: self already registered, name containing a space, no one else present" {
  export HOME="$TEST_PROJECT/home"
  local self_dir="$HOME/.agents/skills/agmsg dev/scripts/drivers/types/codex"
  mkdir -p "$self_dir"
  touch "$HOME/.agents/skills/agmsg dev/.agmsg"

  _run_candidate_probe "$HOME" "$self_dir"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "only_one=true"
  # the whole name (including the embedded space) survives as one line, not
  # two, and is recognized as self (not an "other") -- agmsg_only_one_install
  # counts lines that don't match self's own skill root, so a name that got
  # word-split, or failed to compare equal to itself, would silently miscount.
  printf '%s' "$output" | grep -qF "$HOME/.agents/skills/agmsg dev"
  local candidate_lines; candidate_lines="$(_candidate_lines | grep -c .)"
  [ "$candidate_lines" -eq 1 ]
}

@test "agmsg_only_one_install: self plus one other, unmarked sibling not counted" {
  export HOME="$TEST_PROJECT/home"
  mkdir -p "$HOME/.agents/skills/one" "$HOME/.agents/skills/two"
  touch "$HOME/.agents/skills/one/.agmsg" "$HOME/.agents/skills/two/.agmsg"
  # an unmarked sibling directory must not be counted as a candidate
  mkdir -p "$HOME/.agents/skills/not-agmsg"
  local self_dir="$HOME/.agents/skills/one/scripts/drivers/types/codex"
  mkdir -p "$self_dir"

  _run_candidate_probe "$HOME" "$self_dir"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "only_one=false"
  local candidate_lines; candidate_lines="$(_candidate_lines | grep -c .)"
  [ "$candidate_lines" -eq 2 ]
  refute grep -qF "/not-agmsg" <(printf '%s' "$output")
}
