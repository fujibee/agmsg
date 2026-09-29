import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { openInstallDb } from "../scripts/daemon/db.mjs";
import { readOwner } from "../scripts/daemon/owner.mjs";
import { gracefulStop, pollOnce, startup } from "../scripts/daemon/main.mjs";
import { captureWatchState } from "../scripts/daemon/lifecycle.mjs";
import { createHash } from "node:crypto";

function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

function makeInstall() {
  const root = mkdtempSync(join(tmpdir(), "agmsgd-main-test-"));
  mkdirSync(join(root, "run"), { recursive: true });
  mkdirSync(join(root, "scripts"), { recursive: true });
  writeFileSync(join(root, "scripts", "x.sh"), "x\n");
  writeFileSync(join(root, "VERSION"), "1.0.0\n");
  const manifest = {
    install_id: "i1",
    gen: 1,
    version: "1.0.0",
    created_at: new Date().toISOString(),
    digest_algo: "sha256",
    files: [{ path: "scripts/x.sh", digest: sha256("x\n") }],
  };
  const manifestText = JSON.stringify(manifest);
  writeFileSync(join(root, "run", "install-manifest.json"), manifestText);
  return { root, manifest, manifestText };
}

test("startup: takes ownership, binds the socket, and marks ready", async () => {
  const { root } = makeInstall();
  try {
    const db = openInstallDb(join(root, "run", "install.db"));
    const started = await startup(db, {
      installRoot: root,
      expectedDesired: null,
      expectedOpGen: 0,
      version: "test",
      handlers: { onStop: async () => ({}), onStatus: async () => ({}) },
    });
    assert.equal(started.ok, true);
    assert.equal(readOwner(db).state, "ready");
    await started.controlHandle.close();
    db.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("startup: a refused takeOwnership never touches the control socket, and reports ok:false", async () => {
  const { root } = makeInstall();
  try {
    const db = openInstallDb(join(root, "run", "install.db"));
    // Wrong expectedOpGen -> takeOwnership refuses before ever trying to bind.
    const started = await startup(db, {
      installRoot: root,
      expectedDesired: null,
      expectedOpGen: 99,
      version: "test",
      handlers: { onStop: async () => ({}), onStatus: async () => ({}) },
    });
    assert.equal(started.ok, false);
    assert.equal(readOwner(db).state, "none", "a refused start must never move daemon_owner");
    db.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("pollOnce: continues when nothing changed, steps aside on drift, stops on an intent change", async () => {
  const { root, manifest, manifestText } = makeInstall();
  try {
    const db = openInstallDb(join(root, "run", "install.db"));
    const watchState = await captureWatchState(root, manifest, manifestText);

    let verdict = await pollOnce(db, root, { gen: 1, expectedOpGen: 0, watchState });
    assert.deepEqual(verdict, { action: "continue" });

    // Case: an explicit operation bumped op_gen since this process started.
    db.exec("UPDATE daemon_intent SET op_gen = 1");
    verdict = await pollOnce(db, root, { gen: 1, expectedOpGen: 0, watchState });
    assert.equal(verdict.action, "stop");
    assert.equal(verdict.reason, "normal");
    db.exec("UPDATE daemon_intent SET op_gen = 0"); // restore

    // Case: an in-place edit under scripts/ (the #963 case) with neither
    // the manifest nor the op_gen touched.
    writeFileSync(join(root, "scripts", "x.sh"), "tampered\n");
    verdict = await pollOnce(db, root, { gen: 1, expectedOpGen: 0, watchState });
    assert.equal(verdict.action, "step_aside");
    assert.equal(verdict.reason, "stepped_aside_for_update");

    db.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("gracefulStop: marks stopping, stops every channel hook, closes the socket, and records the reason", async () => {
  const { root } = makeInstall();
  try {
    const db = openInstallDb(join(root, "run", "install.db"));
    const started = await startup(db, {
      installRoot: root,
      expectedDesired: null,
      expectedOpGen: 0,
      version: "test",
      handlers: { onStop: async () => ({}), onStatus: async () => ({}) },
    });
    assert.equal(started.ok, true);

    let hookStopped = false;
    const hooks = [{ stop: async () => { hookStopped = true; } }];
    await gracefulStop(db, root, started.gen, started.controlHandle, hooks, "normal");

    assert.equal(hookStopped, true);
    const owner = readOwner(db);
    assert.equal(owner.state, "none");
    assert.equal(owner.last_end_reason, "normal");
    db.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("gracefulStop: a channel hook that throws is logged but does not stop the rest of shutdown", async () => {
  const { root } = makeInstall();
  try {
    const db = openInstallDb(join(root, "run", "install.db"));
    const started = await startup(db, {
      installRoot: root,
      expectedDesired: null,
      expectedOpGen: 0,
      version: "test",
      handlers: { onStop: async () => ({}), onStatus: async () => ({}) },
    });
    let secondHookRan = false;
    const hooks = [
      { stop: async () => { throw new Error("boom"); } },
      { stop: async () => { secondHookRan = true; } },
    ];
    await gracefulStop(db, root, started.gen, started.controlHandle, hooks, "normal");
    assert.equal(secondHookRan, true);
    assert.equal(readOwner(db).state, "none", "shutdown must still complete despite the throwing hook");
    db.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
