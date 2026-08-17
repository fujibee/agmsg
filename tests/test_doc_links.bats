#!/usr/bin/env bats

# Relative pointers between documents are load-bearing and nothing was checking
# them. `docs/spec/vectors/age-v1-vectors.json` has shipped a
# `"profile_document": "../age-v1-profile.md"` that resolves to a path which
# does not exist, and the conformance vectors are what a second implementation
# reads first. A moved or renamed document breaks the same way and silently.
#
# Scope is deliberately narrow: does the target exist. Anchors are stripped
# rather than verified, because a missing heading and a missing file are
# different failures and only the second one makes a reader follow a dead path.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "every relative link in a tracked markdown file resolves" {
  run python3 - "$ROOT" <<'PY'
import os, re, subprocess, sys

root = sys.argv[1]
files = subprocess.run(
    ["git", "-C", root, "ls-files", "*.md"],
    capture_output=True, text=True, check=True).stdout.split()

# Inline links only. A bare `(text)` in prose is not a link, so the opening
# `](` is required, and the target must not be a URL, a mail address, or a
# pure anchor.
link = re.compile(r"\]\(\s*([^)\s]+?)\s*(?:\s+\"[^\"]*\")?\)")
skip = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//|#)")

broken = []
checked = 0
for rel in files:
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    # Fenced code blocks hold example commands and placeholder paths that are
    # not links to anything in this tree.
    text = re.sub(r"^```.*?^```", "", text, flags=re.S | re.M)
    for target in link.findall(text):
        if skip.match(target):
            continue
        target = target.split("#", 1)[0]
        if not target:
            continue
        # docs/adr/template.md shows the supersede form with the number left
        # blank; that is a slot to fill, not a pointer to follow.
        if "XXXX" in target:
            continue
        checked += 1
        resolved = os.path.normpath(os.path.join(os.path.dirname(path), target))
        if not os.path.exists(resolved):
            broken.append(f"{rel} -> {target}")

print(f"checked {checked} relative links in {len(files)} markdown files")
if broken:
    for b in broken:
        print("BROKEN:", b)
    sys.exit(1)

# A tree this size always has relative links; zero would mean the matcher
# stopped matching rather than that everything resolved.
if checked == 0:
    print("BROKEN: matched no relative links at all -- the matcher is blind")
    sys.exit(1)
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "every document pointer inside the conformance vectors resolves" {
  run python3 - "$ROOT" <<'PY'
import json, os, subprocess, sys

root = sys.argv[1]
files = [f for f in subprocess.run(
    ["git", "-C", root, "ls-files", "docs/spec/vectors/*.json"],
    capture_output=True, text=True, check=True).stdout.split()]

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
