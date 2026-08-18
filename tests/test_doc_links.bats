#!/usr/bin/env bats

# Relative pointers between documents are load-bearing and nothing was checking
# them. `docs/spec/vectors/age-v1-vectors.json` shipped a `profile_document`
# resolving to a path that did not exist, and the conformance vectors are what a
# second implementation reads first. A moved or renamed document breaks the same
# way and silently.
#
# Scope is deliberately narrow: does the target exist. Anchors are stripped
# rather than verified, because a missing heading and a missing file are
# different failures and only the second makes a reader follow a dead path.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECK="$BATS_TEST_DIRNAME/helpers/check_doc_links.py"
}

@test "every relative pointer in a tracked markdown file resolves" {
  run python3 "$CHECK" "$ROOT"
  echo "$output"
  [ "$status" -eq 0 ]
  # A tree this size always has relative links; zero would mean the matcher
  # stopped matching rather than that everything resolved.
  [[ "$output" == *"parsed "* ]]
  [[ "$output" != *"parsed 0 inline links"* ]]
}

@test "the checker sees reference-style links, not only inline ones" {
  # The first version of this checker matched `](` alone. That form is not the
  # only one in the tree -- docs/spec/age-v1-profile.md uses
  # `[age v1 file][age-format]` with its definition further down -- so a broken
  # reference-style pointer was invisible to it. Asserting against a fixture
  # rather than against the repository keeps this true when the repository
  # happens to contain no broken example.
  local fix="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$fix"
  printf '%s\n' \
    '# fixture' \
    '' \
    'An [inline link](missing-inline.md).' \
    'A [reference link][gone] and an [undefined one][nowhere].' \
    'A regex in code is not a link: `[a-z0-9][a-z0-9._-]{0,63}`.' \
    '' \
    '[gone]: missing-target.md' \
    > "$fix/doc.md"

  run python3 "$CHECK" --no-git "$fix"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"doc.md -> missing-inline.md"* ]]
  [[ "$output" == *"[gone]: missing-target.md"* ]]
  [[ "$output" == *"[nowhere] has no definition"* ]]
  # The backticked character class must not be read as a reference link.
  [[ "$output" != *"a-z0-9"* ]]
}

@test "every document pointer inside the conformance vectors resolves" {
  run python3 - "$ROOT" <<'PY'
import json, os, subprocess, sys

root = sys.argv[1]
files = subprocess.run(
    ["git", "-C", root, "ls-files", "docs/spec/vectors/*.json"],
    capture_output=True, text=True, check=True).stdout.split()

broken = []
checked = 0
for rel in files:
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    target = doc.get("profile_document") if isinstance(doc, dict) else None
    if not target:
        continue
    checked += 1
    resolved = os.path.normpath(os.path.join(os.path.dirname(path), target))
    if not os.path.exists(resolved):
        broken.append(f"{rel} -> {target}")

print(f"checked {checked} profile_document pointers in {len(files)} vector files")
if broken:
    for b in broken:
        print("BROKEN:", b)
    sys.exit(1)

# The generator writes this field, so its absence means the field was renamed
# and this check went quiet rather than that it passed.
if checked == 0:
    print("BROKEN: no profile_document pointer found -- the field moved")
    sys.exit(1)
PY
  echo "$output"
  [ "$status" -eq 0 ]
}
