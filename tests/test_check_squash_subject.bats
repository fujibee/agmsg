#!/usr/bin/env bats
#
# .github/scripts/check-squash-subject.sh: the subject a squash merge will
# write must match a cliff.toml rule, or it falls to the catch-all and is lost
# from the release notes without anyone having decided that. Three answers:
# a keep rule (green, in the notes), a skip rule (green, excluded on purpose),
# only the catch-all (red, lost). The checker does not bind new subjects to
# the Conventional shape, and this file pins all three answers, each with a
# control the other way:
#
#   - the RULE, against what git-cliff itself does (measured, and re-measured
#     here whenever git-cliff is installed): subjects that already landed and
#     were lost are red; kept ones are green; `chore(ci):` and `release:` hit
#     skip rules and are green although git-cliff drops them; a legacy group
#     rule greens a non-Conventional subject; the catch-all alone is red;
#   - the DERIVATION: the rules the script reads out of cliff.toml agree with
#     an independent scrape, in order and in kind;
#   - the SELECTION: a one-commit PR is judged by its commit's subject, a larger
#     PR by its title (measured on merged PRs, see the script header);
#   - the ZERO-TARGET answer: no subject, no commit count, an unreadable head,
#     an option without a value, or a cliff.toml the derivation cannot read
#     must be exit 2, never 0.

setup() {
  load 'test_helper'
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECK="$REPO_ROOT/.github/scripts/check-squash-subject.sh"
  export AGMSG_CLIFF_CONFIG="$REPO_ROOT/cliff.toml"
}

# The subjects this file judges, with the answer for each under the real
# cliff.toml: `keep` and `skip` are what git-cliff does (measured with
# git-cliff 2.10.1, 2026-09-07 -- `skip` rows are dropped by git-cliff, on
# purpose), `lost` is a subject only the catch-all matches. One table, read by
# the rule tests AND by the git-cliff cross-check, so the two cannot drift.
_subject_table() {
  cat <<'EOF'
keep|feat(spawn): set the pane's agent key at spawn so codex seats are not left nameless
keep|fix: refuse a non-string envelope.blob
keep|perf(sync): check a pulled wire id without a process
keep|feat!: drop the legacy index
keep|Add native Windows support for the launcher
keep|Role-to-session affinity: pin the seat
keep|feature-flag: kept by the ^feat rule, Conventional or not
keep|chore!: a breaking change that a skip rule matches first
keep|release!: a breaking release
keep|chore(ci)!: a breaking change with a scope
keep|wip!: a breaking change that only the catch-all matches
skip|chore(ci): pin the runner image
skip|release: 1.3.0
skip|ci: a Conventional subject that a skip rule excludes on purpose
skip|chore: native windows bits
lost|Naming is an invariant every entry point re-asserts, and the roster can see it (#1044)
lost|Remove internal handles from the published tree, and check for them by identifier context
lost|spawn: launch codex through the bundled monitor shim, and refuse a bare fallback
lost|Reduce repeated ciphertext literals in pull apply
lost|Feat: capitalised
lost|Something unrelated in the subject
EOF
}

# A one-line cliff.toml fixture with exactly the parsers given (`skip:<re>` or
# `keep:<re>`), preceded by any extra [git] lines, so the derivation can be
# pointed at a file whose contents the test controls.
_cliff_fixture() {   # <extra-git-lines> <rule>...
  local f="$BATS_TEST_TMPDIR/cliff-$RANDOM.toml" extra="$1" r
  shift
  {
    echo '[git]'
    [ -z "$extra" ] || printf '%s\n' "$extra"
    echo 'commit_parsers = ['
    for r in "$@"; do
      case "$r" in
        skip:*) printf '  { message = "%s", skip = true },\n' "${r#skip:}" ;;
        keep:*) printf '  { message = "%s", group = "x" },\n' "${r#keep:}" ;;
      esac
    done
    echo ']'
  } > "$f"
  printf '%s' "$f"
}

# A throwaway repository with one commit whose subject is given; prints the sha.
_repo_with_commit() {   # <subject>
  local d="$BATS_TEST_TMPDIR/repo"
  git init -q "$d"
  git -C "$d" -c user.name=t -c user.email=t@x commit -q --allow-empty -m "$1"
  git -C "$d" rev-parse HEAD
}

# --- the rule, both directions ------------------------------------------------------

@test "every subject in the table gets its answer: kept is green, skipped on purpose is green, lost is red" {
  local exp s rc word
  while IFS='|' read -r exp s; do
    run bash "$CHECK" --subject "$s"
    case "$exp" in keep) rc=0; word='git-cliff keeps it' ;; skip) rc=0; word='excludes it deliberately' ;; lost) rc=1; word='would be lost' ;; esac
    [ "$status" -eq "$rc" ] || { echo "expected $exp (exit $rc), got exit $status for: $s"; echo "$output"; return 1; }
    grep -qF "$word" <<<"$output" || { echo "expected the verdict to say '$word' for: $s"; echo "$output"; return 1; }
  done < <(_subject_table)
}

@test "the table itself has all three answers and both distinctions" {
  # A table missing an answer would make the test above vacuous. It must hold
  # a Conventional subject a skip rule EXCLUDES (green although git-cliff
  # drops it), a non-Conventional one a legacy group rule KEEPS, and subjects
  # only the catch-all matches.
  # Fixed strings: a `|` in a basic-regex grep is literal, but say so.
  _subject_table | grep -Fq 'skip|chore(ci):'
  _subject_table | grep -Fq 'skip|release:'
  _subject_table | grep -Fq 'keep|Add native Windows'
  _subject_table | grep -Fq 'keep|Role-to-session affinity'
  _subject_table | grep -Fq 'keep|chore!:'
  _subject_table | grep -Fq 'keep|wip!:'
  _subject_table | grep -Fq 'lost|spawn:'
  [ "$(_subject_table | grep -c '^keep|')" -ge 5 ]
  [ "$(_subject_table | grep -c '^skip|')" -ge 3 ]
  [ "$(_subject_table | grep -c '^lost|')" -ge 5 ]
}

@test "protect_breaking_commits: a breaking subject is kept past a skip rule and past the catch-all, and only when the flag says so" {
  # Measured with git-cliff 2.10.1: true keeps `chore!:` and `wip!:`, false
  # drops both; absent means false. Differential on one config, one key.
  export AGMSG_CLIFF_CONFIG
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture $'conventional_commits = true\nfilter_unconventional = false\nprotect_breaking_commits = true' 'skip:^chore' 'keep:^feat' 'skip:.*')"
  run bash "$CHECK" --subject 'chore!: breaking past a skip rule'
  [ "$status" -eq 0 ]
  grep -q 'a breaking change' <<<"$output"
  run bash "$CHECK" --subject 'wip!: breaking past the catch-all'
  [ "$status" -eq 0 ]
  grep -q 'a breaking change' <<<"$output"
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture $'conventional_commits = true\nfilter_unconventional = false\nprotect_breaking_commits = false' 'skip:^chore' 'keep:^feat' 'skip:.*')"
  run bash "$CHECK" --subject 'chore!: breaking past a skip rule'
  [ "$status" -eq 0 ]
  grep -q 'excludes it deliberately' <<<"$output"
  run bash "$CHECK" --subject 'wip!: breaking past the catch-all'
  [ "$status" -eq 1 ]
}

@test "a flag absent from cliff.toml takes git-cliff's default, and the output says it was defaulted" {
  # Measured defaults: conventional_commits true, filter_unconventional true,
  # protect_breaking_commits false. A default that is used silently is a
  # model nobody can check against the file.
  export AGMSG_CLIFF_CONFIG
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture 'filter_unconventional = false' 'skip:^chore' 'keep:^feat' 'skip:.*')"
  run bash "$CHECK" --subject 'wip!: breaking, but the flag is absent'
  [ "$status" -eq 1 ]
  grep -q 'protect_breaking_commits=false(default)' <<<"$output"
  grep -q 'conventional_commits=true(default)' <<<"$output"
  grep -q 'filter_unconventional=false(file)' <<<"$output"
  run bash "$CHECK" --parsers
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'config: conventional_commits=true(default) filter_unconventional=false(file) protect_breaking_commits=false(default)' ]
}

@test "conventional_commits=false switches breaking protection off, as measured" {
  export AGMSG_CLIFF_CONFIG
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture $'conventional_commits = false\nfilter_unconventional = false\nprotect_breaking_commits = true' 'skip:^chore' 'keep:^feat' 'skip:.*')"
  run bash "$CHECK" --subject 'wip!: not parsed as breaking when Conventional parsing is off'
  [ "$status" -eq 1 ]
}

@test "the footer blind spot is on the red side: a subject whose breaking mark is only in the body is red, and the script says why" {
  # Measured: git-cliff keeps `wip: ...` with a BREAKING CHANGE: footer under
  # protect_breaking_commits=true. The checker sees the subject only and
  # cannot; by decision it reports red rather than guessing green.
  grep -q 'BREAKING CHANGE' "$CHECK"
  grep -q 'blind spot' "$CHECK"
  run bash "$CHECK" --subject 'wip: footer breaking, subject shows nothing'
  [ "$status" -eq 1 ]
}

@test "the catch-all is not a decision: a subject only it matches is red, one an explicit skip rule matches is green" {
  # Differential pair on one subject; only one explicit skip rule differs.
  # Without this distinction the trailing `.*` skip rule would turn every
  # lost subject green.
  export AGMSG_CLIFF_CONFIG
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture 'filter_unconventional = false' 'keep:^feat' 'skip:.*')"
  run bash "$CHECK" --subject 'wip: not decided by anyone'
  [ "$status" -eq 1 ]
  grep -q 'no rule but the catch-all' <<<"$output"
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture 'filter_unconventional = false' 'keep:^feat' 'skip:^wip' 'skip:.*')"
  run bash "$CHECK" --subject 'wip: not decided by anyone'
  [ "$status" -eq 0 ]
  grep -q 'excludes it deliberately' <<<"$output"
}

@test "the table agrees with git-cliff itself when git-cliff is installed" {
  # The strongest control: the same subjects as commits in a fixture repo, the
  # real cliff.toml, and git-cliff's own --unreleased output. Skipped, visibly,
  # where git-cliff is absent (CI runners do not ship it).
  command -v git-cliff >/dev/null 2>&1 || skip "git-cliff not installed; the table is the measured record"
  local d="$BATS_TEST_TMPDIR/cliffrepo" cfg="$BATS_TEST_TMPDIR/cliff-ids.toml" exp s sha kept n=0
  # The real [git] section, verbatim -- the rules are used, not copied -- under
  # a template that prints commit ids, because the real template renders the
  # description with the type stripped and capitalised, which is not
  # comparable to a subject.
  {
    printf '[changelog]\nbody = """\n{%% for commit in commits %%}{{ commit.id }}\n{%% endfor %%}"""\n'
    awk '/^\[git\]/{f=1} f' "$REPO_ROOT/cliff.toml"
  } > "$cfg"
  grep -q '^commit_parsers' "$cfg" || { echo "the [git] section did not carry over"; return 1; }
  git init -q "$d"
  git -C "$d" -c user.name=t -c user.email=t@x commit -q --allow-empty -m 'chore: init'
  git -C "$d" tag v0.0.1
  : > "$BATS_TEST_TMPDIR/rows"
  while IFS='|' read -r exp s; do
    git -C "$d" -c user.name=t -c user.email=t@x commit -q --allow-empty -m "$s"
    printf '%s|%s|%s\n' "$(git -C "$d" rev-parse HEAD)" "$exp" "$s" >> "$BATS_TEST_TMPDIR/rows"
  done < <(_subject_table)
  kept="$(cd "$d" && git-cliff --config "$cfg" --unreleased --strip all 2>/dev/null | grep -E '^[0-9a-f]{40}$')"
  [ -n "$kept" ] || { echo "git-cliff listed nothing; the fixture or the template is broken"; return 1; }
  # git-cliff lists exactly the `keep` rows; `skip` and `lost` are both absent
  # from its output -- the difference between them is whether cliff.toml
  # decided it, which is what the checker adds.
  while IFS='|' read -r sha exp s; do
    n=$((n + 1))
    if grep -qx "$sha" <<<"$kept"; then
      [ "$exp" = keep ] || { echo "git-cliff KEPT a subject the table says $exp: $s"; return 1; }
    else
      [ "$exp" != keep ] || { echo "git-cliff DROPPED a subject the table says keep: $s"; return 1; }
    fi
  done < "$BATS_TEST_TMPDIR/rows"
  [ "$n" -eq "$(_subject_table | wc -l | tr -d ' ')" ]
}

@test "first match wins: a skip rule before a keep rule excludes, and the reverse keeps" {
  # Differential pair on one subject; only the order of the two rules differs.
  # Both are green, and the verdict must name which rule decided -- a
  # first-match bug would show up as the wrong rule number.
  export AGMSG_CLIFF_CONFIG
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture 'filter_unconventional = false' 'skip:^chore' 'keep:(?i)native windows' 'skip:.*')"
  run bash "$CHECK" --subject 'chore: native windows bits'
  [ "$status" -eq 0 ]
  grep -q 'on purpose by parser 1' <<<"$output"
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture 'filter_unconventional = false' 'keep:(?i)native windows' 'skip:^chore' 'skip:.*')"
  run bash "$CHECK" --subject 'chore: native windows bits'
  [ "$status" -eq 0 ]
  grep -q 'kept by parser 1' <<<"$output"
}

@test "filter_unconventional absent means git-cliff's default, which drops a non-Conventional subject before any rule" {
  # Measured: with the key absent, a subject that matches a keep rule is still
  # dropped unless it has the <type>: shape. Differential pair: same rules,
  # same subject, only the key differs.
  export AGMSG_CLIFF_CONFIG
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture '' 'keep:(?i)native windows' 'skip:.*')"
  run bash "$CHECK" --subject 'Add native Windows support'
  [ "$status" -eq 1 ]
  grep -q 'filter_unconventional is true' <<<"$output"
  grep -q 'filter_unconventional=true(default)' <<<"$output"
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture 'filter_unconventional = false' 'keep:(?i)native windows' 'skip:.*')"
  run bash "$CHECK" --subject 'Add native Windows support'
  [ "$status" -eq 0 ]
}

@test "the checker judges the subject line only (a body that would rescue it is out of scope, and says so)" {
  # Measured divergence, pinned so a change is deliberate: git-cliff also
  # searches the body with unanchored rules. The checker reads one line.
  grep -q 'judges the SUBJECT' "$CHECK"
  run bash "$CHECK" --subject 'Body rescue test subject'
  [ "$status" -eq 1 ]
}

# --- the derivation ---------------------------------------------------------------

@test "the rules are derived from cliff.toml, not retyped: a rule added there is honoured without editing the script" {
  export AGMSG_CLIFF_CONFIG
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture 'filter_unconventional = false' 'keep:^feat' 'skip:.*')"
  run bash "$CHECK" --subject 'wibble: a subject of a type nobody has yet'
  [ "$status" -eq 1 ]
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture 'filter_unconventional = false' 'keep:^feat' 'keep:^(wibble|wobble)' 'skip:.*')"
  run bash "$CHECK" --subject 'wibble: a subject of a type nobody has yet'
  [ "$status" -eq 0 ]
}

@test "--parsers agrees with an independent scrape of the real cliff.toml, in order and in kind" {
  # Canary for the parser in the script: a second, cruder scrape of the same
  # file must produce the same list. Both must see a skip rule, a keep rule,
  # an unanchored legacy rule and the trailing catch-all.
  local expected got
  expected="$(awk '/^commit_parsers *= *\[/{f=1; next} f && /^\]/{exit} f' "$REPO_ROOT/cliff.toml" \
    | grep -oE 'message *= *"[^"]*".*' \
    | awk -F'"' '{ kind = ($0 ~ /skip *= *true/) ? "skip" : "keep"; printf "%d\t%s\t%s\n", NR, kind, $2 }')"
  got="$(bash "$CHECK" --parsers | tail -n +2)"
  [ "$got" = "$expected" ] || { echo "script:"; echo "$got"; echo "scrape:"; echo "$expected"; return 1; }
  grep -qE $'\tskip\t\\^\\(chore' <<<"$got"
  grep -qE $'\tkeep\t\\^feat$' <<<"$got"
  grep -qF $'\tkeep\t(?i)native windows' <<<"$got"
  [ "$(tail -1 <<<"$got")" = "$(printf '%s\tskip\t.*' "$(wc -l <<<"$got" | tr -d ' ')")" ]
  # The three flags as the real file sets them, each marked as read from it.
  [ "$(bash "$CHECK" --parsers | head -1)" = 'config: conventional_commits=true(file) filter_unconventional=false(file) protect_breaking_commits=true(file)' ]
}

# --- the selection: which subject would land ------------------------------------

@test "a one-commit PR is judged by its commit subject, even when the PR title is fine" {
  # The asymmetric case that a title-only check gets wrong: #1043 landed
  # dropped under a fine-looking review, because the commit is what lands.
  local sha
  sha="$(_repo_with_commit 'Reduce repeated ciphertext literals in pull apply')"
  run bash "$CHECK" --title 'fix(sync): reduce repeated ciphertext literals' --commits 1 --head "$sha" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 1 ]
  grep -q "single commit's subject" <<<"$output"
  grep -q 'Reduce repeated ciphertext literals' <<<"$output"
}

@test "a one-commit PR with a good commit subject is green even when the title is bad" {
  local sha
  sha="$(_repo_with_commit 'fix(sync): reduce repeated ciphertext literals')"
  run bash "$CHECK" --title 'Reduce repeated ciphertext literals in pull apply' --commits 1 --head "$sha" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  grep -q "single commit's subject" <<<"$output"
}

@test "a multi-commit PR is judged by its title, and the commit subjects do not matter" {
  local sha
  sha="$(_repo_with_commit 'wip')"
  run bash "$CHECK" --title 'feat(spawn): set the agent key at spawn' --commits 2 --head "$sha" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  grep -q 'the PR title' <<<"$output"
  run bash "$CHECK" --title 'Set the agent key at spawn' --commits 2 --head "$sha" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 1 ]
  grep -q 'the PR title' <<<"$output"
}

@test "the verdict names what it checked and which rule decided, in all three answers" {
  # A green that does not say which subject it read is indistinguishable from
  # a green that read nothing; and the two greens must say which they are.
  run bash "$CHECK" --subject 'fix: something'
  [ "$status" -eq 0 ]
  grep -q 'Checked the subject given on the command line' <<<"$output"
  grep -q 'kept by parser' <<<"$output"
  run bash "$CHECK" --subject 'chore: something'
  [ "$status" -eq 0 ]
  grep -q 'Checked the subject given on the command line' <<<"$output"
  grep -q 'on purpose by parser' <<<"$output"
  run bash "$CHECK" --subject 'something'
  [ "$status" -eq 1 ]
  grep -q '^Checked: the subject given on the command line' <<<"$output"
  grep -q 'no rule but the catch-all' <<<"$output"
}

# --- zero targets are not a pass --------------------------------------------------

@test "no subject at all is exit 2, not green" {
  run bash "$CHECK"
  [ "$status" -eq 2 ]
  grep -q 'nothing to check is not a pass' <<<"$output"
}

@test "an option without its value is exit 2 and does not loop" {
  # `shift 2` with one argument left fails WITHOUT shifting; with no errexit
  # the loop would spin on the same argument forever. Bounded wait, so a
  # regression here is a red, not a hung suite.
  local pid i
  bash "$CHECK" --title >"$BATS_TEST_TMPDIR/out" 2>&1 &
  pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    echo "still running after 5s: the option loop did not terminate"
    return 1
  fi
  wait "$pid" && return 1
  [ $? -eq 2 ]
  grep -q 'needs a value' "$BATS_TEST_TMPDIR/out"
}

@test "a missing or non-numeric commit count is exit 2" {
  run bash "$CHECK" --title 'fix: fine' --head deadbeef
  [ "$status" -eq 2 ]
  run bash "$CHECK" --title 'fix: fine' --commits many --head deadbeef
  [ "$status" -eq 2 ]
  run bash "$CHECK" --title 'fix: fine' --commits 0 --head deadbeef
  [ "$status" -eq 2 ]
}

@test "a one-commit PR whose head cannot be read is exit 2, not judged by the title" {
  # The title is fine here on purpose: falling back to it would be a green
  # about a subject that was never read.
  run bash "$CHECK" --title 'fix: fine' --commits 1 --head 0000000000000000000000000000000000000000
  [ "$status" -eq 2 ]
  grep -q 'cannot read the subject' <<<"$output"
  run bash "$CHECK" --title 'fix: fine' --commits 1
  [ "$status" -eq 2 ]
}

@test "a multi-commit PR with no title is exit 2" {
  run bash "$CHECK" --commits 3 --head deadbeef
  [ "$status" -eq 2 ]
}

@test "a cliff.toml the derivation cannot read is exit 2 even for a good subject" {
  # Differential set on one good subject: only the config differs. Missing
  # file; parsers but no keep rule; parsers but no skip rule; then a usable one.
  export AGMSG_CLIFF_CONFIG
  AGMSG_CLIFF_CONFIG="$BATS_TEST_TMPDIR/missing.toml"
  run bash "$CHECK" --subject 'feat: fine'
  [ "$status" -eq 2 ]
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture '' 'skip:^chore' 'skip:.*')"
  run bash "$CHECK" --subject 'feat: fine'
  [ "$status" -eq 2 ]
  grep -q 'no usable commit_parsers' <<<"$output"
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture '' 'keep:^feat')"
  run bash "$CHECK" --subject 'feat: fine'
  [ "$status" -eq 2 ]
  AGMSG_CLIFF_CONFIG="$(_cliff_fixture '' 'keep:^feat' 'skip:.*')"
  run bash "$CHECK" --subject 'feat: fine'
  [ "$status" -eq 0 ]
}

@test "the workflow passes the three inputs the selection needs, and re-runs on a title edit" {
  # The script can only pick the landing subject if CI hands it the commit
  # count and the head; and a title fixed by editing is only re-checked if
  # `edited` is among the event types.
  local wf="$REPO_ROOT/.github/workflows/squash-subject.yml"
  grep -q 'check-squash-subject.sh' "$wf"
  grep -q 'github.event.pull_request.commits' "$wf"
  grep -q 'github.event.pull_request.head.sha' "$wf"
  grep -q 'github.event.pull_request.title' "$wf"
  grep -Eq 'types: \[.*edited.*\]' "$wf"
}
