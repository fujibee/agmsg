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

// Deliberately empty, and it stays that way.
//
// A test for a shape matcher has to exercise the shape -- but it does not have
// to CONTAIN one. tests/private_names.test.mjs assembles every fixture at run
// time (`[base, "-", role].join("")`), so its source holds no seat-shaped
// literal and no listed name, and it is scanned like every other file.
//
// The earlier version excluded three files and hid 29 real names, including
// examples quoted in this checker's own comments. Review then made the sharper
// point: "the fixtures are fictional today" describes the current contents, it
// does not bind the next edit. An exclusion is a place a real name can be added
// later and never reported. There is no such place now.
const SELF = new Set();

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
    // Declared, not defaulted — an unset list is exit 2, so reaching here means
    // someone wrote `none`. The banner still states the limit, because the
    // limit is real whether or not it was chosen on purpose.
    process.stderr.write(
      "\n==============================================================\n" +
      "  check-private-names: SHAPE ONLY (no name list, by declaration)\n" +
      "  Seat-shaped names were checked. Names with no shape -- a\n" +
      "  person's handle, a project nickname -- were NOT.\n" +
      "  A pass here means \"no seat-shaped name\", NOT \"clean\".\n" +
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
    // Lines as well as findings. The two detectors overlap on purpose -- a seat
    // built on a listed name is reported by both -- so a raw count reads as
    // more work than it is. The line count is the number of edits.
    const lines = new Set(findings.map((f) => `${f.source}:${f.line}`)).size;
    process.stderr.write(
      `\ncheck-private-names: ${findings.length} finding(s) on ${lines} line(s) ` +
      `in ${files} file(s), out of ${scanned} scanned.\nRewrite the sentence so it ` +
      `states the reason rather than who gave it; there is deliberately no way to ` +
      `silence a finding.\n`,
    );
    return 1;
  }
  process.stderr.write(`check-private-names: clean (${scanned} files scanned).\n`);
  return 0;
}

process.exitCode = main();
