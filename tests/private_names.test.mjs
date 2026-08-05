import assert from "node:assert/strict";
import test from "node:test";
import { SEAT_SHAPE, format, injectedPattern, readInjectedNames, scan }
  from "../scripts/internal/private-names.mjs";

const shapeOnly = () => [["shape", new RegExp(SEAT_SHAPE.source, SEAT_SHAPE.flags)]];
const named = (...names) => [
  ["shape", new RegExp(SEAT_SHAPE.source, SEAT_SHAPE.flags)],
  ["name", injectedPattern(names)],
];

test("a seat that does not exist yet is caught, because the shape is the rule", () => {
  // The point of matching a shape rather than a list: nobody has to remember to
  // add the next seat. A list would pass this and be wrong the day it is added.
  const found = scan("ask atlas-cc9 and borea-co42 about it", "x.md", shapeOnly());
  assert.deepEqual(found.map((f) => f.name), ["atlas-cc9", "borea-co42"]);
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
  assert.equal(scan("atlas-cc1", "x.sh", shapeOnly()).length, 1);
});

test("an injected name is found where it abuts CJK", () => {
  // Real input: the Japanese design docs write the handle straight against a
  // particle. Python's re would find nothing here (`の` is a word character to
  // it), which is how a scan run in the wrong language reports a clean tree.
  const found = scan("バイナリだけを持ち込む（noriの裁定、2026-07-25", "docs/design.ja.md",
    named("nori"));
  assert.deepEqual(found.map((f) => f.name), ["nori"]);
});

test("a hyphen is not a boundary, which is what stops double-reporting", () => {
  // The load-bearing difference from \b: to \b a hyphen IS a boundary, so
  // `atlas` would fire inside `atlas-cc1` and every seat name would be reported
  // twice. Pinned as a property of the boundary itself, not of one input.
  assert.equal(/\batlas\b/.test("atlas-cc1"), true, "what \\b would have done");
  assert.deepEqual(scan("atlas-cc1", "x.md", named("atlas")).map((f) => f.kind), ["shape"]);
});

test("an injected name is matched whatever its case, unlike the shape", () => {
  assert.equal(scan("Nori asked for this", "x.md", named("nori")).length, 1);
});

test("a name is found at the tail of a compound, but never twice", () => {
  // The two sides of the boundary answer different questions.
  //
  // LEFT accepts a separator: `<team>-<name>` publishes the name as plainly as
  // the bare word does. Refusing it missed 17 real occurrences on the tree.
  //
  // RIGHT refuses `-`, so a seat name is reported once — by the shape — and the
  // author is not sent to fix the same characters twice.
  const found = scan("atlas-cc1 and atlaslike and myatlas and re-atlas and atlas_1",
    "x.md", named("atlas"));
  assert.deepEqual(found.map((f) => `${f.kind}:${f.name}`),
    ["shape:atlas-cc1", "name:atlas", "name:atlas"]); // re-atlas, atlas_1
  assert.deepEqual(found.map((f) => f.text.includes("atlaslike")), [true, true, true],
    "same line; atlaslike and myatlas contributed no finding of their own");
});

test("a name hyphenated to an ordinary word falls to neither detector unless the refusal is narrow", () => {
  // The gap a blanket refusal of `-` on the right opens: `<name>-approved` is
  // not a seat shape, and a detector that refuses every `-` will not call it a
  // name either, so nothing reports it. Refusing only when a ROLE follows keeps
  // the no-double-report property and closes the gap.
  const line = "# atlas-approved interface, see atlas-code and atlas-cc1";
  const found = scan(line, "scripts/x.sh", named("atlas"));
  assert.deepEqual(found.map((f) => `${f.kind}:${f.name}`),
    ["shape:atlas-cc1", "name:atlas", "name:atlas"]); // -approved and -code
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

test("a finding carries the line it is on, so the report reads without the file", () => {
  const found = scan("one\ntwo atlas-cc1 three", "scripts/x.sh", shapeOnly());
  assert.deepEqual(found, [{
    source: "scripts/x.sh", line: 2, kind: "shape", name: "atlas-cc1",
    text: "two atlas-cc1 three",
  }]);
  // Default output must not contain the name or the line: this runs in CI, and
  // a CI log is as readable as the repository. Printing the handle while
  // flagging it for not being published is the failure reporting itself.
  const redacted = format(found);
  assert.deepEqual(redacted, ["scripts/x.sh:2: [shape] internal name, 9 chars"]);
  assert.ok(!redacted.join("\n").includes("atlas"), "the name reached the default output");
  assert.deepEqual(format(found, { reveal: true }),
    ['scripts/x.sh:2: [shape] "atlas-cc1" in: two atlas-cc1 three']);
});
