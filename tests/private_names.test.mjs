import assert from "node:assert/strict";
import test from "node:test";
import { SEAT_SHAPE, format, injectedPattern, readInjectedNames, scan }
  from "../scripts/internal/private-names.mjs";

// Every fixture is assembled at run time. Written out, a test for a shape
// matcher necessarily CONTAINS the shape -- and this file would then have to be
// excluded from the scan, which is an exclusion the next edit can quietly fill
// with a real name. Assembling them means the exclusion list is empty and this
// file is scanned like any other.
const seat = (base, role, index = "") => [base, "-", role, index].join("");
const A = ["at", "las"].join("");          // a base
const B = ["nor", "th", "-", "star"].join(""); // a base with a hyphen in it
const H = ["no", "ri"].join("");           // a handle, no shape

const shapeOnly = () => [["shape", new RegExp(SEAT_SHAPE.source, SEAT_SHAPE.flags)]];
const named = (...names) => [
  ["shape", new RegExp(SEAT_SHAPE.source, SEAT_SHAPE.flags)],
  ["name", injectedPattern(names)],
];

test("a seat that does not exist yet is caught, because the shape is the rule", () => {
  // The point of matching a shape rather than a list: nobody has to remember to
  // add the next seat. A list would pass this and be wrong the day it is added.
  const found = scan(`ask ${seat(A, "cc", "9")} and ${seat("bor" + "ea", "co", "42")} about it`, "x.md", shapeOnly());
  assert.deepEqual(found.map((f) => f.name), [seat(A, "cc", "9"), seat("bor" + "ea", "co", "42")]);
});

test("the roles are cc and co only — x and it match platform triples", () => {
  // Widening the alternation is the obvious next idea and it is wrong:
  // linux-x64 and friends appear hundreds of times, and a check that cries
  // wolf gets turned off. This pins the narrowness on purpose.
  const line = "linux-x64 win32-x64 darwin-x64 freebsd-x64 try-it legacy-x";
  assert.deepEqual(scan(line, "x.md", shapeOnly()), []);
});

test("the shape is case-sensitive, so 'non-CC runtimes' is not a seat", () => {
  // Measured on the tree: matching case-insensitively adds exactly this hit and
  // no real one. Seat names are lowercase by construction.
  assert.deepEqual(scan("# present (older CC, non-CC runtimes).", "x.sh", shapeOnly()), []);
  assert.equal(scan(seat(A, "cc", "1"), "x.sh", shapeOnly()).length, 1);
});

test("an injected name is found where it abuts CJK", () => {
  // Real input: the Japanese design docs write the handle straight against a
  // particle. Python's re would find nothing here (`の` is a word character to
  // it), which is how a scan run in the wrong language reports a clean tree.
  const found = scan(`バイナリだけを持ち込む（${H}の裁定、2026-07-25`, "docs/design.ja.md",
    named(H));
  assert.deepEqual(found.map((f) => f.name), [H]);
});

test("a hyphenated base is a seat, and neither detector may drop it", () => {
  // The hole that ended the no-double-report idea. A base can contain hyphens,
  // and with a base of `[a-z][a-z0-9]*` the shape matched `<a>-<b>-cc1` from
  // neither end -- not from `<a>` (`-<b>` is not a role) and not from `<b>` (the
  // preceding hyphen is refused). The bare-name detector then suppressed itself
  // too, on the theory that the shape had it. Nothing reported it.
  const found = scan(seat(B, "cc", "1"), "x.md", named(B));
  assert.deepEqual(found.map((f) => `${f.kind}:${f.name}`),
    [`shape:${seat(B, "cc", "1")}`, `name:${B}`]);
});

test("a seat built on a listed name is reported by both, and that is the point", () => {
  // Two findings, one edit. Three attempts to report it once each opened a hole
  // somewhere else -- left hyphen, right hyphen, role-suppression -- because
  // every one of them worked by making a detector stay quiet. A duplicate costs
  // a reader a moment; a hole costs a published name.
  const found = scan(seat(A, "cc", "1"), "x.md", named(A));
  assert.deepEqual(found.map((f) => `${f.kind}:${f.name}`),
    [`shape:${seat(A, "cc", "1")}`, `name:${A}`]);
});

test("a name is found wherever it is separated, and nowhere it is not", () => {
  const found = scan(`${A}like and my${A} and re-${A} and ${A}_1 and team-${A}`,
    "x.md", named(A));
  assert.deepEqual(found.map((f) => f.name), [A, A, A]); // re-, _1, team-
});

test("a name hyphenated to an ordinary word is still the name", () => {
  // `<name>-approved` is not a seat shape. An earlier right-hand boundary
  // refused every `-` and dropped it between the two detectors; found in review
  // against the real tree.
  const found = scan(`# ${A}-approved interface, see ${A}-code`, "scripts/x.sh", named(A));
  assert.deepEqual(found.map((f) => f.name), [A, A]);
});

test("a supplied name cannot widen itself through regex metacharacters", () => {
  const found = scan("kXit and k.it", "x.md", named("k.it"));
  assert.deepEqual(found.map((f) => f.name), ["k.it"]);
});

test("no names supplied is reported as absent, not as an empty list", () => {
  // The distinction the runner turns into exit 2. An empty list that looked
  // like "nothing to check" would make the whole check silently vacuous.
  assert.deepEqual(readInjectedNames({}, () => ""), { names: null, declaredNone: false });
  assert.deepEqual(readInjectedNames({ AGMSG_PRIVATE_NAMES: "none" }, () => ""),
    { names: [], declaredNone: true });
  assert.deepEqual(readInjectedNames({ AGMSG_PRIVATE_NAMES: "a,b" }, () => ""),
    { names: ["a", "b"], declaredNone: false });
  assert.deepEqual(readInjectedNames({ AGMSG_PRIVATE_NAMES_FILE: "f" }, () => "a\nb"),
    { names: ["a", "b"], declaredNone: false });
  assert.throws(() => readInjectedNames(
    { AGMSG_PRIVATE_NAMES: "a", AGMSG_PRIVATE_NAMES_FILE: "f" }, () => ""),
  /both set/u);
});

test("an all-blank list is absent too, so whitespace cannot disarm the check", () => {
  assert.equal(injectedPattern([" ", "", "\t"]), null);
});

test("a list file may explain itself without its prose becoming names", () => {
  // The list is maintained by hand, so it needs somewhere to say why a name is
  // on it. Untreated, `# a person's handle` is read as a name and the checker
  // starts matching the prose of its own configuration.
  const file = `# why this list exists\n${H}   # a handle\n\n${A}\n`;
  assert.deepEqual(
    readInjectedNames({ AGMSG_PRIVATE_NAMES_FILE: "f" }, () => file).names
      .map((name) => name.trim()).filter(Boolean),
    [H, A],
  );
});

test("a list file that is only comments is absent, not empty", () => {
  // Otherwise the check runs with no names, finds nothing, and reports clean --
  // the vacuous green the whole design is built to refuse.
  assert.deepEqual(
    readInjectedNames({ AGMSG_PRIVATE_NAMES_FILE: "f" }, () => "# nothing here\n\n"),
    { names: null, declaredNone: false },
  );
});

test("a finding carries the line it is on, so the report reads without the file", () => {
  const found = scan(`one\ntwo ${seat(A, "cc", "1")} three`, "scripts/x.sh", shapeOnly());
  assert.deepEqual(found, [{
    source: "scripts/x.sh", line: 2, kind: "shape", name: seat(A, "cc", "1"),
    text: `two ${seat(A, "cc", "1")} three`,
  }]);
  // Default output must not contain the name or the line: this runs in CI, and
  // a CI log is as readable as the repository. Printing the handle while
  // flagging it for not being published is the failure reporting itself.
  const redacted = format(found);
  assert.deepEqual(redacted, [`scripts/x.sh:2: [shape] internal name, ${seat(A, "cc", "1").length} chars`]);
  assert.ok(!redacted.join("\n").includes(A), "the name reached the default output");
  assert.deepEqual(format(found, { reveal: true }),
    [`scripts/x.sh:2: [shape] "${seat(A, "cc", "1")}" in: two ${seat(A, "cc", "1")} three`]);
});
