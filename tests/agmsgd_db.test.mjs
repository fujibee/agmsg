import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { openInstallDb, withImmediateTransaction } from "../scripts/daemon/db.mjs";

test("openInstallDb applies the schema idempotently; readOnly never migrates or writes", () => {
  const dir = mkdtempSync(join(tmpdir(), "agmsgd-db-test-"));
  const path = join(dir, "install.db");
  try {
    const db = openInstallDb(path);
    for (const table of ["meta", "daemon_owner", "daemon_intent"]) {
      const row = db.prepare(`SELECT count(*) AS n FROM ${table}`).get();
      assert.equal(row.n, 1, `${table} must have exactly one row after first open`);
    }
    assert.equal(
      db.prepare("SELECT count(*) AS n FROM daemon_start_attempts").get().n,
      0,
      "daemon_start_attempts is append-only history with no seed row",
    );
    db.close();

    // Re-opening (a second component, or a restart) must not add rows or
    // fail on the already-existing schema.
    const db2 = openInstallDb(path);
    assert.equal(db2.prepare("SELECT count(*) AS n FROM daemon_owner").get().n, 1);
    db2.close();

    // A readOnly open of a DB that was never created must not create it
    // (readOnly + a missing file is an error, not a silent bootstrap) and
    // must refuse to write to one that exists.
    const neverCreated = join(dir, "never.db");
    assert.throws(() => openInstallDb(neverCreated, { readonly: true }));

    const ro = openInstallDb(path, { readonly: true });
    assert.throws(() => ro.exec("INSERT INTO daemon_start_attempts (at, reason) VALUES ('x','y')"));
    ro.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("withImmediateTransaction commits on success and rolls back on throw", () => {
  const dir = mkdtempSync(join(tmpdir(), "agmsgd-db-test-"));
  const path = join(dir, "install.db");
  try {
    const db = openInstallDb(path);
    withImmediateTransaction(db, () => {
      db.exec("INSERT INTO daemon_start_attempts (at, reason) VALUES ('t1','ok')");
    });
    assert.equal(db.prepare("SELECT count(*) AS n FROM daemon_start_attempts").get().n, 1);

    assert.throws(() =>
      withImmediateTransaction(db, () => {
        db.exec("INSERT INTO daemon_start_attempts (at, reason) VALUES ('t2','bad')");
        throw new Error("boom");
      }),
    );
    assert.equal(
      db.prepare("SELECT count(*) AS n FROM daemon_start_attempts").get().n,
      1,
      "the row inserted before the throw must be rolled back",
    );
    db.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
