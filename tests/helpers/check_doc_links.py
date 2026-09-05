#!/usr/bin/env python3
"""Report relative document pointers that do not resolve.

Reads either a git repository (default) or a plain directory (--no-git), so the
same extraction can be run against a fixture whose breakage is known. Prints one
BROKEN line per unresolved pointer and exits 1 if there were any.

Three pointer forms are checked, because a document breaks the same way in all
three and a parser that sees only the first reports a clean tree:

  inline           [text](target)
  reference use    [text][label]        -- the label must be defined
  reference define [label]: target      -- a relative target must resolve
"""
import os
import re
import subprocess
import sys

SKIP = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//|#)")
INLINE = re.compile(r"\]\(\s*([^)\s]+?)\s*(?:\s+\"[^\"]*\")?\)")
REF_USE = re.compile(r"\[[^\]\n]+\]\[([^\]\n]*)\]")
REF_DEF = re.compile(r"^\s{0,3}\[([^\]\n]+)\]:\s*(\S+)", re.M)


def strip_code(text):
    """Remove fenced blocks and inline code spans.

    Both hold examples and regular expressions -- `[a-z0-9._-]{0,63}` reads as a
    reference-style link to any matcher that does not strip them first.
    """
    text = re.sub(r"^```.*?^```", "", text, flags=re.S | re.M)
    return re.sub(r"`[^`\n]*`", "", text)


def markdown_files(root, use_git):
    if use_git:
        out = subprocess.run(["git", "-C", root, "ls-files", "*.md"],
                             capture_output=True, text=True, check=True).stdout
        return out.split()
    found = []
    for base, _, names in os.walk(root):
        for n in names:
            if n.endswith(".md"):
                found.append(os.path.relpath(os.path.join(base, n), root))
    return sorted(found)


def resolves(root, rel, target):
    bare = target.split("#", 1)[0]
    if not bare:
        return True
    return os.path.exists(
        os.path.normpath(os.path.join(root, os.path.dirname(rel), bare)))


def main():
    args = [a for a in sys.argv[1:] if a != "--no-git"]
    use_git = "--no-git" not in sys.argv[1:]
    root = args[0]
    files = markdown_files(root, use_git)

    broken = []
    counts = {"inline": 0, "ref_use": 0, "ref_def": 0}
    for rel in files:
        text = strip_code(open(os.path.join(root, rel), encoding="utf-8").read())

        for target in INLINE.findall(text):
            # docs/adr/template.md shows the supersede form with the number left
            # blank; that is a slot to fill, not a pointer to follow.
            if SKIP.match(target) or "XXXX" in target:
                continue
            counts["inline"] += 1
            if not resolves(root, rel, target):
                broken.append(f"{rel} -> {target}")

        defined = {}
        for label, target in REF_DEF.findall(text):
            defined[label.lower()] = target
            counts["ref_def"] += 1
            if SKIP.match(target) or "XXXX" in target:
                continue
            if not resolves(root, rel, target):
                broken.append(f"{rel} -> [{label}]: {target}")

        for label in REF_USE.findall(text):
            if not label:
                continue
            counts["ref_use"] += 1
            if label.lower() not in defined:
                broken.append(f"{rel} -> [{label}] has no definition")

    print("parsed {inline} inline links, {ref_use} reference uses, "
          "{ref_def} reference definitions".format(**counts),
          f"across {len(files)} markdown files")
    for b in broken:
        print("BROKEN:", b)
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
