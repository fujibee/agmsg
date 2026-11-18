import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { extendPathFromRecord, recordedToolDirs, TOOL_PATH_FILE } from "../scripts/daemon/tool-path.mjs";

function root() {
  const dir = mkdtempSync(join(tmpdir(), "agmsgd-tool-path-test-"));
  mkdirSync(join(dir, "run"), { recursive: true });
  return dir;
}

test("recorded directories are appended to a minimal PATH, system directories first", () => {
  const dir = root();
  try {
    const cli = join(dir, "clibin");
    mkdirSync(cli);
    writeFileSync(join(dir, "run", TOOL_PATH_FILE), `${cli}\n`);
    const env = { PATH: "/usr/bin:/bin:/usr/sbin:/sbin" };
    assert.deepEqual(extendPathFromRecord(dir, env, "darwin"), { added: [cli], error: "" });
    assert.equal(readFileSync(join(dir, "run", `${TOOL_PATH_FILE}.applied`), "utf8"), `${cli}\n`, "what was read is recorded as applied");
    assert.equal(env.PATH, `/usr/bin:/bin:/usr/sbin:/sbin:${cli}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("relative, missing, duplicate and already-present entries are not added", () => {
  const dir = root();
  try {
    const cli = join(dir, "clibin");
    mkdirSync(cli);
    writeFileSync(join(dir, "run", TOOL_PATH_FILE), `relative/x:${join(dir, "gone")}:${cli}:${cli}:/usr/bin\n`);
    assert.deepEqual(recordedToolDirs(dir), [cli, "/usr/bin"]);
    const env = { PATH: "/usr/bin:/bin" };
    extendPathFromRecord(dir, env, "linux");
    assert.equal(env.PATH, `/usr/bin:/bin:${cli}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("no record, or Windows, leaves PATH unchanged", () => {
  const dir = root();
  try {
    const env = { PATH: "/usr/bin:/bin" };
    assert.deepEqual(extendPathFromRecord(dir, env, "darwin"), { added: [], error: "" });
    writeFileSync(join(dir, "run", TOOL_PATH_FILE), `${dir}\n`);
    assert.deepEqual(extendPathFromRecord(dir, env, "win32"), { added: [], error: "" });
    assert.equal(env.PATH, "/usr/bin:/bin");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a record that exists but cannot be read is reported, not folded into 'nothing recorded'", () => {
  const dir = root();
  try {
    mkdirSync(join(dir, "run", TOOL_PATH_FILE));
    const env = { PATH: "/usr/bin:/bin" };
    const result = extendPathFromRecord(dir, env, "darwin");
    assert.deepEqual(result.added, []);
    assert.match(result.error, /could not read run\/agmsgd-tool-path \(EISDIR/);
    assert.equal(env.PATH, "/usr/bin:/bin");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
