import { createHash } from "node:crypto";
import { readFile, readdir, stat } from "node:fs/promises";
import { join } from "node:path";

// The installation can be updated while an engine runs (#963). watch.sh
// already detects that and stands down on its own; the engine used to find
// out only by executing a half-written driver script -- and only when its
// timing was unlucky enough to hit the write window (observed live: a
// mid-rewrite storage-sync-driver.sh failed to parse, and the fatal named a
// syntax error instead of the update).
//
// What is proof here went through review twice, and both cuts were the same
// disease: an observable standing in for the fact. "mtime newer than the
// engine's start clock" stands down every engine under a pre-existing
// future mtime (clock skew, an archive with preserved timestamps).
// "mtime changed against a baseline" stands down on a touch, a
// metadata-only correction, a same-content re-copy -- the code in memory
// and on disk still identical, and a stood-down sync engine does not come
// back by itself. The fact that matters is CONTENT: the engine must stand
// down exactly when the bytes on disk are no longer the bytes it started
// from. So the baseline holds a content digest per file; a path or mtime
// difference merely nominates a file for re-reading, and only a digest
// that actually differs -- or a path that did not exist at start, a new
// install artifact -- is proof. A benign mtime change is remembered so the
// file is not re-read every cycle; content is the identity, the mtime is
// only a cheap change hint.
//
// The failure direction is deliberate, in both phases: an OBSERVATION
// failure is not evidence.
//   - Baseline phase: one unreadable directory, one failed stat, one
//     unreadable file and the whole detector is disabled (null), not
//     partially armed. A partial baseline would recreate the false
//     positive: a pre-existing file unreadable at start and readable later
//     would look newly added. Disabled means exactly today's behavior.
//   - Check phase: an entry that cannot be listed, stat'ed, or read is
//     skipped and proves nothing. A rewrite that lands different bytes
//     under the exact baseline mtime defeats the hint and is never
//     re-read -- a miss, and a miss degrades to today's behavior, which
//     is the safe side. A file DELETED by an update is deliberately not
//     proof on its own; a real update always rewrites something.
//
// Extracted from remote-sync.mjs: this file is
// the one place the #963 detector lives now. remote-sync.mjs re-exports
// these two names unchanged, so `runLoop`'s own behavior there is
// untouched, and agmsgd's lifecycle.mjs imports the same two functions
// directly for its own per-cycle drift check.
export async function collectInstallBaseline(rootDir, dependencies = {}) {
  const readdirCall = dependencies.readdirCall ?? readdir;
  const statCall = dependencies.statCall ?? stat;
  const readFileCall = dependencies.readFileCall ?? readFile;
  const baseline = new Map();
  const pending = [rootDir];
  while (pending.length > 0) {
    const dir = pending.pop();
    let entries;
    try { entries = await readdirCall(dir, { withFileTypes: true }); }
    catch { return null; } // incomplete observation: the detector stays OFF
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) { pending.push(path); continue; }
      if (!entry.isFile()) continue; // links and specials are not install artifacts
      let stats, bytes;
      try {
        stats = await statCall(path);
        bytes = await readFileCall(path);
      } catch { return null; } // incomplete observation: the detector stays OFF
      baseline.set(path, {
        mtimeMs: stats.mtimeMs,
        digest: createHash("sha256").update(bytes).digest("hex"),
      });
    }
  }
  return baseline;
}

export async function installChangedAgainst(rootDir, baseline, dependencies = {}) {
  const readdirCall = dependencies.readdirCall ?? readdir;
  const statCall = dependencies.statCall ?? stat;
  const readFileCall = dependencies.readFileCall ?? readFile;
  const pending = [rootDir];
  while (pending.length > 0) {
    const dir = pending.pop();
    let entries;
    try { entries = await readdirCall(dir, { withFileTypes: true }); }
    catch { continue; } // unreadable now: no evidence either way
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) { pending.push(path); continue; }
      if (!entry.isFile()) continue;
      let stats;
      try { stats = await statCall(path); }
      catch { continue; } // vanished or unreadable: no evidence
      const known = baseline.get(path);
      if (known === undefined) return path; // did not exist at start: a new install artifact
      if (stats.mtimeMs === known.mtimeMs) continue; // no hint of change
      let digest;
      try { digest = createHash("sha256").update(await readFileCall(path)).digest("hex"); }
      catch { continue; } // could not re-read: no evidence
      if (digest !== known.digest) return path; // the bytes actually changed
      known.mtimeMs = stats.mtimeMs; // benign touch: remember it, content is the identity
    }
  }
  return null;
}
