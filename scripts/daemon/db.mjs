// Opens run/install.db with node:sqlite and applies scripts/daemon/schema.sql
// (idempotent -- see that file). One place so every Node component that
// touches install.db agrees on how it is opened and migrated.

import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const SCHEMA_PATH = join(dirname(fileURLToPath(import.meta.url)), "schema.sql");

// `readonly: true` opens the DB without applying the schema and without the
// ability to write -- for a reader (status.mjs) that must never create the
// tables a stopped/never-started daemon would otherwise leave missing, and
// must never be the thing that turns "not installed yet" into "installed,
// empty" just by looking.
export function openInstallDb(path, { readonly = false } = {}) {
  const db = new DatabaseSync(path, { readOnly: readonly, allowExtension: false });
  db.exec("PRAGMA busy_timeout = 5000;");
  if (!readonly) {
    db.exec(readFileSync(SCHEMA_PATH, "utf8"));
  }
  return db;
}

// Runs `fn(db)` inside a single BEGIN IMMEDIATE transaction, committing on
// return and rolling back on throw. BEGIN IMMEDIATE (not the default
// deferred BEGIN) takes the write lock up front. A deferred transaction
// that starts with a read and
// upgrades to a write partway through can hit SQLITE_BUSY at the upgrade
// point instead of at the start, which is a worse failure to reason about
// under contention.
export function withImmediateTransaction(db, fn) {
  db.exec("BEGIN IMMEDIATE;");
  try {
    const result = fn(db);
    db.exec("COMMIT;");
    return result;
  } catch (error) {
    try {
      db.exec("ROLLBACK;");
    } catch {
      // The connection may already be unusable (e.g. the process is about
      // to exit); the original error is what matters to the caller.
    }
    throw error;
  }
}
