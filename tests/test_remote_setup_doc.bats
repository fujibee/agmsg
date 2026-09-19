#!/usr/bin/env bats

# The remote-setup walkthroughs offer the Compose path (#665) and point at
# `server/compose.yaml` for its values instead of restating them.
#
# The contract is narrower than "no compose value appears here", and the
# difference is the point:
#
#   credentials and database settings   NOT duplicated. Two copies of a
#                                       password disagree eventually, and the
#                                       copy in the walkthrough is the one
#                                       someone pastes.
#   the published port                  IS written. A reader needs it to run
#                                       the health check, so hiding it behind
#                                       a link would be worse. It is pinned
#                                       against compose.yaml instead.
#
# Both are derived FROM compose.yaml, so both survive the value changing.
#
# WHICH FILES: derived by glob, never named (#676). The first version of this
# guard read `docs/remote-setup.md` and nothing else, and `docs/remote-setup.ja.md`
# arrived an hour later carrying the same port — unguarded, silently. Naming one
# file is how the next one arrives unwatched, so a third translation is covered
# on the day it lands without anyone editing this file or the CI classifier.
#
# WHICH CHECKS: every one below is language-neutral, because the set they run
# over is not. Commands, ports, connection strings and link targets are the
# same in any language; headings are not, so an in-page link is resolved
# against the headings of the file it lives in rather than against English.

COMPOSE="${BATS_TEST_DIRNAME}/../server/compose.yaml"
SERVER_README="${BATS_TEST_DIRNAME}/../server/README.md"
DOCS="${BATS_TEST_DIRNAME}/../docs"

# Every walkthrough, one path per line. Empty output is a failure at the call
# site, not a quiet pass: a glob that stops matching would make every check
# below vacuous.
walkthroughs() {
  ls "$1"/remote-setup*.md 2>/dev/null
}

# An environment value out of compose.yaml, by key.
compose_value() {
  sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "$COMPOSE" | head -1
}

# compose's published HOST port — the side a reader curls.
compose_host_port() {
  sed -n 's/^[[:space:]]*-[[:space:]]*"\([0-9][0-9]*\):[0-9][0-9]*"[[:space:]]*$/\1/p' "$COMPOSE" | head -1
}

# GitHub's heading anchor: lowercase, spaces to hyphens, ASCII punctuation
# dropped. Only ASCII punctuation is removed — an allow-list of `a-z0-9-` would
# erase a Japanese heading entirely and make every ja anchor "resolve" to the
# empty string.
#
# Emits a trailing newline on purpose: `heading_anchors` calls this per heading
# and greps the result with `-x`, so without one every anchor in a file arrives
# concatenated into a single line and nothing ever matches. `$( )` strips it at
# the call sites that compare directly.
slug() {
  printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr ' ' '-' \
    | sed 's/[]`~!@#$%^&*()+=<>?,./:;"'"'"'|{}\\[]//g'
}

# The headings of a markdown file, as anchors, one per line.
heading_anchors() {
  sed -n 's/^#\{1,6\}[[:space:]]*//p' "$1" | while IFS= read -r h; do slug "$h"; done
}

# The heading of the network-boundary section, identified by what the section
# DOES rather than what it is called: it is the one whose body points at
# server/README.md#compose-configuration.
#
# Named structurally because the name is translated. The alternative — a table
# of "Network boundary" / "ネットワーク境界" / whatever comes third — is the
# enumeration this whole change exists to remove.
boundary_heading() {
  awk '/^#{1,6}[[:space:]]/{h=$0} /server\/README\.md#compose-configuration/{print h; exit}' "$1" \
    | sed 's/^#\{1,6\}[[:space:]]*//'
}

# Everything wrong with one walkthrough, one problem per line. Empty means
# clean. Takes its inputs so a fixture can be checked the same way the real
# tree is — a guard that can only run against the repo cannot be shown to fail.
check_walkthrough() {
  local doc="$1" compose_password="$2" port="$3" readme="$4" problems="" used anchors a bh bslug

  grep -q 'docker compose up -d --build' "$doc" \
    || problems="${problems}${doc}: does not offer the Compose path
"
  grep -q 'docker compose version' "$doc" \
    || problems="${problems}${doc}: does not tell the reader how to confirm Compose is actually present (#704)
"
  grep -q '/v1/health' "$doc" \
    || problems="${problems}${doc}: never reaches the health check
"
  if grep -F -q -- "$compose_password" "$doc"; then
    problems="${problems}${doc}: restates compose.yaml's password
"
  fi
  if grep -q 'postgresql://' "$doc"; then
    problems="${problems}${doc}: spells out a connection string
"
  fi

  used="$(grep -o 'http://127\.0\.0\.1:[0-9]*' "$doc" | sed 's|.*:||' | sort -u)"
  if [ -z "$used" ]; then
    problems="${problems}${doc}: names no localhost health-check URL
"
  elif [ "$used" != "$port" ]; then
    problems="${problems}${doc}: localhost port(s) [$(echo $used)] are not compose's $port
"
  fi

  # Links into server/README.md, resolved against that file's headings.
  anchors="$(grep -o '(\.\./server/README\.md#[a-z0-9-]*)' "$doc" \
    | sed 's|(\.\./server/README\.md#||; s|)||' | sort -u)"
  if [ -z "$anchors" ]; then
    problems="${problems}${doc}: links into server/README.md nowhere
"
  fi
  for a in $anchors; do
    heading_anchors "$readme" | grep -q -x -- "$a" \
      || problems="${problems}${doc}: points at server/README.md#${a}, not a heading there
"
  done

  # In-page links, resolved against THIS file's own headings — which is what
  # makes the check work for a translation whose headings are translated.
  anchors="$(grep -o ']([#][^)]*)' "$doc" | sed 's|](#||; s|)||' | sort -u)"
  if [ -z "$anchors" ]; then
    problems="${problems}${doc}: has no in-page section links
"
  fi
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    heading_anchors "$doc" | grep -q -x -- "$a" \
      || problems="${problems}${doc}: points at #${a}, not a heading in this file
"
  done <<EOF
$anchors
EOF

  # The route to the network-boundary warning, both halves. "Every in-page link
  # resolves" does not cover a REQUIRED link going missing (review): deleting
  # the boundary heading, or the link to it, leaves the other in-page links
  # resolving perfectly. In a document that recommends a stack publishing a
  # port with a development password, that route is load-bearing.
  bh="$(boundary_heading "$doc")"
  if [ -z "$bh" ]; then
    problems="${problems}${doc}: no section carries the network-boundary warning (nothing links to server/README.md#compose-configuration)
"
  else
    bslug="$(slug "$bh")"
    grep -q -F -- "](#${bslug})" "$doc" \
      || problems="${problems}${doc}: nothing links to its network-boundary section (#${bslug})
"
  fi

  printf '%s' "$problems"
}

@test "remote-setup: the walkthroughs are found by glob, not by name" {
  # The positive control for everything below. If the glob stops matching, each
  # per-file check would iterate over nothing and report clean.
  n="$(walkthroughs "$DOCS" | wc -l | tr -d ' ')"
  [ "$n" -ge 2 ] || return 1
  walkthroughs "$DOCS" | grep -q 'remote-setup\.md$' || return 1
  walkthroughs "$DOCS" | grep -q 'remote-setup\.ja\.md$' || return 1
}

@test "remote-setup: every walkthrough holds the contract" {
  password="$(compose_value POSTGRES_PASSWORD)"
  port="$(compose_host_port)"
  # Non-empty first: an empty password would match every file, and an empty
  # port would make the comparison meaningless.
  [ -n "$password" ] || return 1
  [ -n "$port" ] || return 1

  problems=""
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    problems="${problems}$(check_walkthrough "$doc" "$password" "$port" "$SERVER_README")"
  done <<EOF
$(walkthroughs "$DOCS")
EOF
  [ -z "$problems" ] || { printf '%s\n' "$problems" >&2; return 1; }
}

@test "remote-setup: a THIRD walkthrough is covered the day it lands" {
  # The whole point of #676. Two files passing proves only that someone
  # remembered the second one; this adds a third that no line anywhere names,
  # and breaks it, so the coverage is demonstrated rather than asserted.
  password="$(compose_value POSTGRES_PASSWORD)"
  port="$(compose_host_port)"
  [ -n "$password" ] || return 1

  fixture="$BATS_TEST_TMPDIR/docs"
  mkdir -p "$fixture"
  cp "$DOCS/remote-setup.md" "$fixture/remote-setup.md"
  cp "$DOCS/remote-setup.ja.md" "$fixture/remote-setup.ja.md"
  # A third translation, correct except for one stale port.
  sed "s|http://127\.0\.0\.1:${port}|http://127.0.0.1:9999|" \
    "$DOCS/remote-setup.md" > "$fixture/remote-setup.de.md"

  # It is found without being named.
  walkthroughs "$fixture" | grep -q 'remote-setup\.de\.md$' || return 1
  n="$(walkthroughs "$fixture" | wc -l | tr -d ' ')"
  [ "$n" -eq 3 ] || return 1

  problems=""
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    problems="${problems}$(check_walkthrough "$doc" "$password" "$port" "$SERVER_README")"
  done <<EOF
$(walkthroughs "$fixture")
EOF

  # The third file is reported, and only the third.
  printf '%s' "$problems" | grep -q 'remote-setup\.de\.md: localhost port' || {
    echo "the third walkthrough's stale port was not reported. problems: [$problems]" >&2
    return 1
  }
  printf '%s' "$problems" | grep -q 'remote-setup\.md:' && {
    echo "a clean walkthrough was reported: [$problems]" >&2
    return 1
  }
  printf '%s' "$problems" | grep -q 'remote-setup\.ja\.md:' && {
    echo "a clean walkthrough was reported: [$problems]" >&2
    return 1
  }
  return 0
}

@test "remote-setup: the port check reads the JAPANESE file too" {
  # Named separately because "every walkthrough holds the contract" passing
  # does not say which files it opened. This breaks ja specifically.
  password="$(compose_value POSTGRES_PASSWORD)"
  port="$(compose_host_port)"
  fixture="$BATS_TEST_TMPDIR/ja"
  mkdir -p "$fixture"
  sed "s|http://127\.0\.0\.1:${port}|http://127.0.0.1:9999|" \
    "$DOCS/remote-setup.ja.md" > "$fixture/remote-setup.ja.md"
  problems="$(check_walkthrough "$fixture/remote-setup.ja.md" "$password" "$port" "$SERVER_README")"
  printf '%s' "$problems" | grep -q 'localhost port' || {
    echo "a stale port in the Japanese walkthrough went unreported: [$problems]" >&2
    return 1
  }
}

@test "remote-setup: a translated in-page link resolves against its own headings" {
  # The reason the anchor check is not English-only: ja's boundary section is
  # `### ネットワーク境界` and links to `(#ネットワーク境界)`. An anchor slug
  # built from an ASCII allow-list would reduce both to the empty string and
  # "resolve" every Japanese link to nothing.
  [ "$(slug 'ネットワーク境界')" = 'ネットワーク境界' ] || return 1
  [ "$(slug 'Network boundary')" = 'network-boundary' ] || return 1
  [ "$(slug 'Run from source')" = 'run-from-source' ] || return 1
  heading_anchors "$DOCS/remote-setup.ja.md" | grep -q -x 'ネットワーク境界' || return 1
}

@test "remote-setup: editing ANY walkthrough does not skip this suite" {
  # Everything above is decoration if the suite does not run on the change it
  # is watching for. The `changes` job maps `docs/*` to docs_only=true, which
  # skips every bats shard.
  #
  # The workflow's own `case` is lifted out and RUN: order is only one of the
  # ways an arm can stop working, and the classifier is what actually decides.
  workflow="${BATS_TEST_DIRNAME}/../.github/workflows/tests.yml"
  block="$(awk '/contract_test_files=/,/^ *done <<< "\$changed"$/' "$workflow")"
  [ -n "$block" ] || return 1

  # `run bash -c`, not a `$( )` around the eval: bash 3.2 — which is what CI's
  # macOS runner has — cannot parse a `case` inside command substitution.
  classify='changed="$1"; docs_only=true; app_changed=false; server_changed=false; sync_changed=false; contracts_needed=false; eval "$2"; echo "$docs_only"'

  # Every walkthrough that exists, derived — not a list to keep in step.
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    rel="docs/$(basename "$doc")"
    run bash -c "$classify" _ "$rel" "$block"
    [ "$status" -eq 0 ] || return 1
    [ "$output" = false ] || { echo "$rel is treated as docs-only" >&2; return 1; }
  done <<EOF
$(walkthroughs "$DOCS")
EOF

  # And one that does not exist yet, because that is the case this fixes.
  run bash -c "$classify" _ docs/remote-setup.de.md "$block"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = false ] || { echo "a future translation is treated as docs-only" >&2; return 1; }

  # The guard test itself: editing this file has to run the suite too, same
  # as editing what it guards.
  run bash -c "$classify" _ tests/test_remote_setup_doc.bats "$block"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = false ] || { echo "tests/test_remote_setup_doc.bats is treated as docs-only" >&2; return 1; }

  # Still an exception, not a hole through the docs tree.
  run bash -c "$classify" _ docs/spec/v1.md "$block"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = true ] || return 1
}

@test "remote-setup: editing a walkthrough runs the suite WITHOUT also forcing the age-v1/jsonl contracts (#706)" {
  # docs_only=false is necessary to keep the bats suite running on a
  # walkthrough edit, but it used to be sufficient to also run age-v1-contract
  # and storage-jsonl, which never read this file. contracts_needed is the
  # same classifier's independent verdict for those two jobs specifically.
  workflow="${BATS_TEST_DIRNAME}/../.github/workflows/tests.yml"
  block="$(awk '/contract_test_files=/,/^ *done <<< "\$changed"$/' "$workflow")"
  [ -n "$block" ] || return 1

  classify='changed="$1"; docs_only=true; app_changed=false; server_changed=false; sync_changed=false; contracts_needed=false; eval "$2"; echo "$contracts_needed"'

  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    rel="docs/$(basename "$doc")"
    run bash -c "$classify" _ "$rel" "$block"
    [ "$status" -eq 0 ] || return 1
    [ "$output" = false ] || { echo "$rel forces the age-v1/jsonl contracts to run" >&2; return 1; }
  done <<EOF
$(walkthroughs "$DOCS")
EOF

  run bash -c "$classify" _ docs/remote-setup.de.md "$block"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = false ] || { echo "a future translation forces the age-v1/jsonl contracts to run" >&2; return 1; }

  # The bug `tests/test_remote_setup_doc.bats` alone exposed, and the bug an
  # earlier fix here left standing for these four: `tests/test_remote*.bats`
  # matches all five by name, and only test_remote.bats (checked below) is
  # a file either contract actually reads. Naming test_remote_setup_doc.bats
  # as its own exception fixed one of five and left the other four
  # unmeasured -- checking only "one representative passes" is how that
  # went unnoticed the first time, so every non-contract file this glob
  # matches is asserted here, not a sample of them.
  for f in tests/test_remote_setup_doc.bats tests/test_remote_forget.bats \
    tests/test_remote_status_liveness.bats tests/test_remote_sync.bats \
    tests/test_remote_sync_engine.bats; do
    run bash -c "$classify" _ "$f" "$block"
    [ "$status" -eq 0 ] || return 1
    [ "$output" = false ] || { echo "$f forces the age-v1/jsonl contracts to run" >&2; return 1; }
  done

  # Positive control, part 1: contracts_needed must be able to become true
  # for a file the derived set actually holds, or the assertions above would
  # pass just as well with a flag that is always false. test_remote.bats is
  # the sixth file this SAME glob matches, and the one real reason the glob
  # cannot simply be deleted -- it has age-gated tests and must keep being
  # discovered as one. (Its own marker string is not spelled out here on
  # purpose: this file would then match the very derivation it is testing.)
  run bash -c "$classify" _ tests/test_remote.bats "$block"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = true ] || { echo "tests/test_remote.bats no longer triggers the age-v1/jsonl contracts" >&2; return 1; }

  # Positive control, part 2: a change entirely outside the test_remote*.bats
  # glob, through the separate scripts/* arm, must still trigger it too --
  # that arm is untouched by this fix and this proves it stayed that way.
  run bash -c "$classify" _ scripts/lib/storage.sh "$block"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = true ] || { echo "a storage-layer change no longer triggers the age-v1/jsonl contracts" >&2; return 1; }
}
