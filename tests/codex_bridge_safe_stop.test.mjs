import assert from "node:assert/strict";
import { createRequire } from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const {
  bridgeStopRequestMatches,
  isMsysWindows,
  parseBridgeStopRecord,
} = require("../scripts/drivers/types/codex/codex-bridge.js");

const valid = [
  "v=1",
  `project=${"a".repeat(40)}`,
  `pairs=${"b".repeat(40)}`,
  "host=win-host",
  "pid=123",
  "start=638622100000000000",
  "startsrc=pwsh",
  `nonce=${"c".repeat(40)}`,
  "expires=1800000000",
].join("\n") + "\n";

test("safe-stop request accepts only the exact ordered v1 schema", () => {
  const record = parseBridgeStopRecord(valid);
  assert.equal(record.pid, "123");
  assert.equal(record.startsrc, "pwsh");

  for (const malformed of [
    valid.replace("v=1\n", "v=2\n"),
    valid.replace("host=win-host\n", ""),
    valid.replace("pid=123\n", "pid=123\npid=123\n"),
    valid.replace("startsrc=pwsh", "startsrc=proc"),
    valid.replace(`nonce=${"c".repeat(40)}`, "nonce=short"),
    valid.replace("expires=1800000000\n", "expires=1800000000\nextra=x\n"),
    valid.slice(0, -1),
  ]) assert.equal(parseBridgeStopRecord(malformed), null);
});

test("Windows detection includes MSYS families but excludes CYGWIN", () => {
  const prior = process.env.MSYSTEM;
  try {
    for (const value of ["MINGW64_NT-10.0", "MSYS_NT-10.0", "CLANGARM64_NT-10.0"]) {
      process.env.MSYSTEM = value;
      assert.equal(isMsysWindows(), true, value);
    }
    for (const value of ["CYGWIN_NT-10.0", "", "Linux"]) {
      process.env.MSYSTEM = value;
      assert.equal(isMsysWindows(), false, value);
    }
  } finally {
    if (prior === undefined) delete process.env.MSYSTEM;
    else process.env.MSYSTEM = prior;
  }
});

test("safe-stop identity, TTL, and nonce checks fail closed", () => {
  const request = parseBridgeStopRecord(valid);
  const expected = {
    pid: "123",
    host: "win-host",
    project: "a".repeat(40),
    pairs: "b".repeat(40),
    startsrc: "pwsh",
    start: "638622100000000000",
    now: 1799999999,
    acceptedNonce: "",
  };
  assert.equal(bridgeStopRequestMatches(request, expected), true);
  for (const override of [
    { pid: "124" },
    { host: "other-host" },
    { project: "d".repeat(40) },
    { pairs: "e".repeat(40) },
    { start: "638622100000000001" },
    { now: 1800000001 },
    { acceptedNonce: "c".repeat(40) },
  ]) assert.equal(bridgeStopRequestMatches(request, { ...expected, ...override }), false);
});
