import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  renameSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import {
  completionRecordChanged,
  readCompletionState,
  verifyDigest,
  verifyInstallId,
} from "../scripts/daemon/lifecycle.mjs";
import { openInstallDb } from "../scripts/daemon/db.mjs";

function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

function makeInstall() {
  const root = mkdtempSync(join(tmpdir(), "agmsgd-lifecycle-test-"));
  mkdirSync(join(root, "run"), { recursive: true });
  mkdirSync(join(root, "scripts", "lib"), { recursive: true });
  writeFileSync(join(root, "scripts", "team.sh"), "team\n");
  writeFileSync(join(root, "scripts", "lib", "storage.sh"), "storage\n");
  const files = [
    { path: "scripts/team.sh", digest: sha256("team\n") },
    { path: "scripts/lib/storage.sh", digest: sha256("storage\n") },
  ];
  const manifest = {
    install_id: "test-install",
    gen: 1,
    version: "0.0.0-test",
    created_at: new Date().toISOString(),
    digest_algo: "sha256",
    files,
  };
  writeFileSync(join(root, "run", "install-manifest.json"), JSON.stringify(manifest));
  return { root, manifest };
}

test("readCompletionState: missing / complete / crashed / updating", () => {
  const { root, manifest } = makeInstall();
  try {
    const complete = readCompletionState(root);
    assert.equal(complete.state, "complete");
    assert.deepEqual(complete.manifest, manifest);

    // Simulate "install started" (rename to .prev, no new record yet).
    rmSync(join(root, "run", "install-manifest.json.prev"), { force: true });
    renameSync(
      join(root, "run", "install-manifest.json"),
      join(root, "run", "install-manifest.json.prev"),
    );
    assert.equal(readCompletionState(root).state, "crashed", "no lock held -> update died mid-way");

    // Now hold the install-op lock -- must read as "updating", not "crashed".
    const lockPath = join(root, "run", "install-op.lock.db");
    const holder = new DatabaseSync(lockPath);
    holder.exec("BEGIN EXCLUSIVE;");
    try {
      assert.equal(readCompletionState(root).state, "updating");
    } finally {
      holder.exec("ROLLBACK;");
      holder.close();
    }

    rmSync(join(root, "run", "install-manifest.json.prev"));
    assert.equal(readCompletionState(root).state, "missing", "no manifest, no .prev");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("verifyDigest: clean install passes; a missing file, an extra file, an edited file, and a symlink all fail", () => {
  const { root, manifest } = makeInstall();
  try {
    assert.deepEqual(verifyDigest(root, manifest), { ok: true });

    // Edited file: digest mismatch.
    
    writeFileSync(join(root, "scripts", "team.sh"), "tampered\n");
    assert.equal(verifyDigest(root, manifest).ok, false);
    writeFileSync(join(root, "scripts", "team.sh"), "team\n"); // restore

    // Missing file.
    unlinkSync(join(root, "scripts", "lib", "storage.sh"));
    let r = verifyDigest(root, manifest);
    assert.equal(r.ok, false);
    assert.match(r.reason, /missing/);
    writeFileSync(join(root, "scripts", "lib", "storage.sh"), "storage\n"); // restore

    // Extra file not in the manifest.
    writeFileSync(join(root, "scripts", "extra.sh"), "surprise\n");
    r = verifyDigest(root, manifest);
    assert.equal(r.ok, false);
    assert.match(r.reason, /unexpected/);
    unlinkSync(join(root, "scripts", "extra.sh"));

    // A symlink anywhere under scripts/ fails verification outright, even
    // though it points at an otherwise-correct file.
    symlinkSync(join(root, "scripts", "team.sh"), join(root, "scripts", "team-link.sh"));
    r = verifyDigest(root, manifest);
    assert.equal(r.ok, false);
    assert.match(r.reason, /symlink/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("verifyInstallId: matches, mismatches, and a never-set install.db all report correctly", () => {
  const { root, manifest } = makeInstall();
  try {
    const db = openInstallDb(join(root, "run", "install.db"));
    // Never set: meta.install_id is NULL, must mismatch (not silently pass).
    assert.equal(verifyInstallId(db, manifest).ok, false);

    db.exec(`UPDATE meta SET install_id = '${manifest.install_id}'`);
    assert.equal(verifyInstallId(db, manifest).ok, true);

    db.exec("UPDATE meta SET install_id = 'some-other-install'");
    const r = verifyInstallId(db, manifest);
    assert.equal(r.ok, false);
    assert.match(r.reason, /mismatch/);
    db.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("completionRecordChanged: false while the manifest is untouched, true once it moves", () => {
  const { root } = makeInstall();
  try {
    const first = readCompletionState(root);
    assert.equal(completionRecordChanged(root, first.manifestText), false);

    
    renameSync(
      join(root, "run", "install-manifest.json"),
      join(root, "run", "install-manifest.json.prev"),
    );
    assert.equal(completionRecordChanged(root, first.manifestText), true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
