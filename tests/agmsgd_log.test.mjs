import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { logLine, logPath } from "../scripts/daemon/log.mjs";

test("logLine appends and rotates at 1 MiB, keeping exactly one prior generation", () => {
  const root = mkdtempSync(join(tmpdir(), "agmsgd-log-test-"));
  mkdirSync(join(root, "run"), { recursive: true });
  try {
    logLine(root, "first line");
    const path = logPath(root);
    assert.match(readFileSync(path, "utf8"), /first line/);

    // Force the file past the rotation threshold without writing 1 MiB
    // through the real API one line at a time.
    writeFileSync(path, "x".repeat(1024 * 1024 + 1));
    logLine(root, "after rotation");
    assert.equal(existsSync(`${path}.1`), true, "the oversized file must be rotated aside");
    assert.match(readFileSync(path, "utf8"), /after rotation/);
    assert.ok(statSync(`${path}.1`).size >= 1024 * 1024);

    // A second rotation must not accumulate a .2 -- exactly one prior
    // generation is kept, per T3 "ほか".
    writeFileSync(path, "y".repeat(1024 * 1024 + 1));
    logLine(root, "second rotation");
    assert.equal(existsSync(`${path}.2`), false);
    assert.match(readFileSync(`${path}.1`, "utf8"), /^y+$/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
