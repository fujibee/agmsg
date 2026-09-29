import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { openInstallDb } from "../scripts/daemon/db.mjs";
import {
  markReady,
  markStopping,
  readOwner,
  revertToNone,
  stopNormally,
  takeOwnership,
} from "../scripts/daemon/owner.mjs";
import { bootId } from "../scripts/daemon/executor.mjs";

function freshDb() {
  const dir = mkdtempSync(join(tmpdir(), "agmsgd-owner-test-"));
  const db = openInstallDb(join(dir, "install.db"));
  return { dir, db };
}

test("takeOwnership: none -> starting -> ready is a clean run", () => {
  const { dir, db } = freshDb();
  try {
    const r = takeOwnership(db, {
      installRoot: dir,
      expectedDesired: "off",
      expectedOpGen: 0,
      version: "test",
    });
    assert.equal(r.ok, true);
    assert.equal(r.gen, 1);
    assert.equal(readOwner(db).state, "starting");
    assert.equal(markReady(db, r.gen), true);
    assert.equal(readOwner(db).state, "ready");
  } finally {
    db.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("takeOwnership refuses when the current owner is alive", () => {
  const { dir, db } = freshDb();
  try {
    const first = takeOwnership(db, {
      installRoot: dir,
      expectedDesired: "off",
      expectedOpGen: 0,
      version: "v1",
    });
    assert.equal(first.ok, true);
    markReady(db, first.gen);

    const second = takeOwnership(db, {
      installRoot: dir,
      expectedDesired: "off",
      expectedOpGen: 0,
      version: "v2",
    });
    assert.equal(second.ok, false);
    assert.match(second.reason, /alive/);
    assert.equal(readOwner(db).gen, first.gen, "the alive owner's gen must not be disturbed");
  } finally {
    db.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("takeOwnership takes over when the recorded owner is confirmed dead", () => {
  const { dir, db } = freshDb();
  try {
    const first = takeOwnership(db, {
      installRoot: dir,
      expectedDesired: "off",
      expectedOpGen: 0,
      version: "v1",
    });
    markReady(db, first.gen);

    // Overwrite the recorded executor with one that has already exited, at
    // the current boot id -- i.e. confirmed dead, not merely absent.
    const dead = spawnSync(process.execPath, ["-e", "process.exit(0)"]);
    db.prepare("UPDATE daemon_owner SET executor_pid = ?, executor_boot_id = ? WHERE gen = ?").run(
      dead.pid,
      bootId(),
      first.gen,
    );

    const second = takeOwnership(db, {
      installRoot: dir,
      expectedDesired: "off",
      expectedOpGen: 0,
      version: "v2",
    });
    assert.equal(second.ok, true);
    assert.equal(second.gen, first.gen + 1, "gen must advance and never be reused");
  } finally {
    db.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("takeOwnership refuses when the intent changed since the launcher observed it", () => {
  const { dir, db } = freshDb();
  try {
    db.exec("UPDATE daemon_intent SET desired = 'on', op_gen = 5");
    const r = takeOwnership(db, {
      installRoot: dir,
      expectedDesired: "on",
      expectedOpGen: 4, // stale -- op_gen has since moved to 5
      version: "test",
    });
    assert.equal(r.ok, false);
    assert.match(r.reason, /intent changed/);
  } finally {
    db.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("revertToNone (bind failure) and stopNormally both record last_end under this gen's own CAS", () => {
  const { dir, db } = freshDb();
  try {
    const r = takeOwnership(db, {
      installRoot: dir,
      expectedDesired: "off",
      expectedOpGen: 0,
      version: "test",
    });
    assert.equal(revertToNone(db, r.gen, "bind failed"), true);
    let owner = readOwner(db);
    assert.equal(owner.state, "none");
    assert.equal(owner.last_end_reason, "bind failed");
    assert.equal(owner.last_end_gen, r.gen);

    const r2 = takeOwnership(db, {
      installRoot: dir,
      expectedDesired: "off",
      expectedOpGen: 0,
      version: "test",
    });
    markReady(db, r2.gen);
    assert.equal(markStopping(db, r2.gen), true);
    assert.equal(readOwner(db).state, "stopping");
    assert.equal(stopNormally(db, r2.gen, "normal"), true);
    owner = readOwner(db);
    assert.equal(owner.state, "none");
    assert.equal(owner.last_end_reason, "normal");
  } finally {
    db.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
