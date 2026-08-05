#!/usr/bin/env node
// Fails when an internal team name appears anywhere this repository publishes.
//
// Scope is defined by `git ls-files`, not by a directory or extension list: the
// repository is the published artifact, so a new file type is in scope the
// moment it is committed and nobody has to remember to add it here. Binary
// files are recognised by content (a NUL byte), never by their name.
//
// Usage:
//   AGMSG_PRIVATE_NAMES="name1,name2" node scripts/check-private-names.mjs
//   AGMSG_PRIVATE_NAMES_FILE=/path/to/list node scripts/check-private-names.mjs
//   AGMSG_PRIVATE_NAMES=none node scripts/check-private-names.mjs   # loud skip
//
// Exit codes: 0 clean, 1 findings, 2 misconfigured.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { SEAT_SHAPE, format, injectedPattern, readInjectedNames, scan }
  from "./internal/private-names.mjs";

// One entry, and it is load-bearing that there is only one.
//
// A test for a shape matcher has to contain the shape, so this file cannot be
// scanned like any other. That is the whole justification — and it holds only
// because the fixtures in it are FICTIONAL. Measured: with this exclusion
// lifted, the test file yields 16 shape findings and zero real names, while the
// checker and its library yield zero of either. An exclusion that covered a
// real name would be hiding the thing it was written to find.
//
// The first draft of this list had three entries and hid 29 real names,
// including examples quoted in the library's own comments. Keep it at one, and
// keep the fixtures fictional. Nothing can add itself here.
const SELF = new Set(["tests/private_names.test.mjs"]);

function trackedFiles() {
  return execFileSync("git", ["ls-files", "-z"], { maxBuffer: 1 << 28 })
    .toString("utf8").split("\0").filter(Boolean);
}

function main() {
  let injected;
  try {
    injected = readInjectedNames(process.env, (path) => readFileSync(path, "utf8"));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    return 2;
  }

  if (injected.names === null) {
    // Not a skip. The shape half would still pass on a tree full of handles
    // that have no shape, and a green from that reads as "no internal names
    // here" — which is the claim this check exists to make, and it would be
    // false. Say what is missing and how to say "yes, really, none".
    process.stderr.write(
      "check-private-names: no name list was supplied, so this check cannot make\n" +
      "the claim it exists to make. Set AGMSG_PRIVATE_NAMES (comma or newline\n" +
      "separated) or AGMSG_PRIVATE_NAMES_FILE. To run the shape half ALONE and\n" +
      "accept that unshaped names go unchecked, set AGMSG_PRIVATE_NAMES=none.\n",
    );
    return 2;
  }

  if (injected.declaredNone) {
    process.stderr.write(
      "\n==============================================================\n" +
      "  check-private-names: RUNNING WITH NO NAME LIST\n" +
      "  Only the seat-shape pattern ran. Names that have no shape --\n" +
      "  a person's handle, a project nickname -- were NOT checked.\n" +
      "  A pass here does NOT mean the tree is clean.\n" +
      "==============================================================\n\n",
    );
  }

  const patterns = [
    ["shape", SEAT_SHAPE],
    ["name", injectedPattern(injected.names)],
  ];

  const findings = [];
  let scanned = 0;
  for (const file of trackedFiles()) {
    if (SELF.has(file)) continue;
    let text;
    try {
      const bytes = readFileSync(file);
      if (bytes.includes(0)) continue; // binary, by content
      text = bytes.toString("utf8");
    } catch {
      continue; // submodule, symlink to nowhere, removed under us
    }
    scanned += 1;
    findings.push(...scan(text, file, patterns));
  }

  // Off in CI, where the log is as public as the repository. `--show` is for a
  // terminal you are looking at.
  const reveal = process.argv.includes("--show");
  if (findings.length > 0) {
    process.stdout.write(`${format(findings, { reveal }).join("\n")}\n`);
    const files = new Set(findings.map((f) => f.source)).size;
    process.stderr.write(
      `\ncheck-private-names: ${findings.length} internal name(s) in ${files} file(s), ` +
      `out of ${scanned} scanned.\nRewrite the sentence so it states the reason ` +
      `rather than who gave it; there is deliberately no way to silence a finding.\n`,
    );
    return 1;
  }
  process.stderr.write(`check-private-names: clean (${scanned} files scanned).\n`);
  return 0;
}

process.exitCode = main();
