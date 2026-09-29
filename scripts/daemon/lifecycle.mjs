// Completion-record verification and update detection (T3 "更新").
//
// The manifest itself (run/install-manifest.json, its .prev, and the
// install-op lock at run/install-op.lock.db) is PR 2's own format -- this
// file only reads it. Confirmed shape (2026-09-29):
//   { install_id, gen, version, created_at, digest_algo: "sha256",
//     files: [{ path, digest }, ...] }
// `path` is relative to installRoot (the SKILL_DIR), `files` sorted by path.

import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { collectInstallBaseline, installChangedAgainst } from "../internal/install-baseline.mjs";

const MANIFEST_NAME = "install-manifest.json";
const LOCK_NAME = "install-op.lock.db";

// True if some other process currently holds run/install-op.lock.db's
// BEGIN EXCLUSIVE (PR 2). Non-blocking: `busy_timeout = 0` makes a
// contended BEGIN EXCLUSIVE fail immediately instead of waiting, so this
// never stalls waiting for the lock it is only trying to observe.
function isInstallLockHeld(installRoot) {
  const lockPath = join(installRoot, "run", LOCK_NAME);
  if (!existsSync(lockPath)) return false;
  const db = new DatabaseSync(lockPath);
  try {
    db.exec("PRAGMA busy_timeout = 0;");
    try {
      db.exec("BEGIN EXCLUSIVE;");
      db.exec("ROLLBACK;");
      return false;
    } catch {
      return true;
    }
  } finally {
    db.close();
  }
}

// Reads the completion record and classifies it into the 3 states T3
// distinguishes: 'complete' (manifest present -- carries it), 'updating'
// (no manifest, .prev present, lock held), 'crashed' (no manifest, .prev
// present, lock free -- an update that died mid-way), 'missing' (neither
// file -- installed by an install.sh old enough to never have written one).
export function readCompletionState(installRoot) {
  const manifestPath = join(installRoot, "run", MANIFEST_NAME);
  const prevPath = `${manifestPath}.prev`;
  if (existsSync(manifestPath)) {
    return {
      state: "complete",
      manifest: JSON.parse(readFileSync(manifestPath, "utf8")),
      manifestText: readFileSync(manifestPath, "utf8"),
    };
  }
  if (existsSync(prevPath)) {
    return { state: isInstallLockHeld(installRoot) ? "updating" : "crashed" };
  }
  return { state: "missing" };
}

// Enumerates every regular file under <installRoot>/scripts, sorted by
// path relative to installRoot (matching the manifest's own path form and
// sort order). A symlink ANYWHERE under scripts/ is a verification
// failure, not a skip -- T3 "symlinkは記録に入れず、scripts/の下に
// symlinkがあれば照合の失敗として扱う".
function collectScriptFiles(installRoot) {
  const files = [];
  const root = join(installRoot, "scripts");
  function walk(dir, relPrefix) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const abs = join(dir, entry.name);
      const rel = relPrefix ? `${relPrefix}/${entry.name}` : entry.name;
      if (entry.isSymbolicLink()) {
        throw new Error(`symlink under scripts/: ${rel}`);
      } else if (entry.isDirectory()) {
        walk(abs, rel);
      } else if (entry.isFile()) {
        files.push(rel);
      }
    }
  }
  walk(root, "scripts");
  files.sort();
  return files;
}

function sha256File(installRoot, relPath) {
  const data = readFileSync(join(installRoot, relPath));
  return createHash("sha256").update(data).digest("hex");
}

// install.db's meta.install_id is the source of truth (install.sh, PR 2);
// the manifest carries only a copy. A mismatch means the manifest belongs
// to a different install than the one this install.db actually is --
// verified separately from the digest check below, and checked first,
// since a digest match against the wrong install's manifest proves nothing.
export function verifyInstallId(db, manifest) {
  const row = db.prepare("SELECT install_id FROM meta").get();
  if (row.install_id !== manifest.install_id) {
    return {
      ok: false,
      reason: `install_id mismatch: install.db has ${row.install_id ?? "(none)"}, manifest has ${manifest.install_id}`,
    };
  }
  return { ok: true };
}

// Full startup verification (T3 "起動側"): every file the manifest lists
// must exist with a matching digest, no extra files, no missing files, no
// symlinks. Returns {ok: true} or {ok: false, reason}. Never throws for an
// ordinary mismatch -- only collectScriptFiles's symlink case surfaces as
// a caught, reported mismatch rather than an uncaught exception.
export function verifyDigest(installRoot, manifest) {
  if (manifest.digest_algo !== "sha256") {
    return { ok: false, reason: `unsupported digest_algo: ${manifest.digest_algo}` };
  }
  let onDisk;
  try {
    onDisk = collectScriptFiles(installRoot);
  } catch (error) {
    return { ok: false, reason: error.message };
  }
  const expected = [...manifest.files].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const onDiskSet = new Set(onDisk);
  const expectedPaths = expected.map((f) => f.path);
  const expectedSet = new Set(expectedPaths);

  const missing = expectedPaths.filter((p) => !onDiskSet.has(p));
  if (missing.length > 0) return { ok: false, reason: `missing file(s): ${missing.join(", ")}` };

  const extra = onDisk.filter((p) => !expectedSet.has(p));
  if (extra.length > 0) return { ok: false, reason: `unexpected file(s): ${extra.join(", ")}` };

  for (const { path, digest } of expected) {
    const actual = sha256File(installRoot, path);
    if (actual !== digest) return { ok: false, reason: `digest mismatch: ${path}` };
  }
  return { ok: true };
}

// Returns true iff the completion record is no longer 'complete' since
// `lastKnownManifestText` was captured (an install/uninstall started).
function completionRecordChanged(installRoot, lastKnownManifestText) {
  const now = readCompletionState(installRoot);
  return now.state !== "complete" || now.manifestText !== lastKnownManifestText;
}

// Captured once, right after a successful startup verification, and handed
// to watchForDrift() every cycle thereafter (T3 "動いているagmsgd").
// `scriptsBaseline` is null when collectInstallBaseline itself could not
// observe the tree (see that function's own doc) -- watchForDrift treats a
// null baseline the same way collectInstallBaseline's own caller always
// has: the digest half of the check is simply off, not a false positive.
export async function captureWatchState(installRoot, manifest, manifestText) {
  return {
    manifestText,
    version: manifest.version,
    scriptsBaseline: await collectInstallBaseline(join(installRoot, "scripts")),
  };
}

// The running daemon's per-cycle re-check (T3 "動いているagmsgd"): stand
// aside if EITHER (a) the completion record stopped being 'complete' (an
// install/uninstall started), OR (b) the VERSION string or any file under
// scripts/ changed IN PLACE without the manifest moving at all -- the #963
// case, detected via install-baseline.mjs against the baseline
// captureWatchState took at startup. Returns {changed: false} or
// {changed: true, reason}.
export async function watchForDrift(installRoot, watchState) {
  if (completionRecordChanged(installRoot, watchState.manifestText)) {
    return { changed: true, reason: "completion record is no longer complete" };
  }
  let currentVersion;
  try {
    currentVersion = readFileSync(join(installRoot, "VERSION"), "utf8").trim();
  } catch {
    return { changed: true, reason: "VERSION file could not be read" };
  }
  if (currentVersion !== watchState.version) {
    return { changed: true, reason: `VERSION changed: ${watchState.version} -> ${currentVersion}` };
  }
  if (watchState.scriptsBaseline) {
    const changedPath = await installChangedAgainst(join(installRoot, "scripts"), watchState.scriptsBaseline);
    if (changedPath) return { changed: true, reason: `scripts/ changed in place: ${changedPath}` };
  }
  return { changed: false };
}
