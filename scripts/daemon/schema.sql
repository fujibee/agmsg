-- agmsgd beta schema for run/install.db.
--
-- Applied identically from both bash (scripts/daemon.sh, via `sqlite3 <db> <
-- this file`) and Node (owner.mjs, via node:sqlite exec()) -- one file so the
-- two sides can never drift into different table shapes for the same DB.
-- Every statement is idempotent: safe to re-run on every invocation, by
-- either side, in any order.
--
-- These are the ONLY 4 of the design's 6 beta tables this component (PR 3,
-- "agmsgd skeleton") owns. beta_codex_queue and beta_codex_seat belong to the
-- Codex channel/係 (a separate PR) and are created there, not here.
--
-- meta: one row. schema_version is written by install/agmsgd; node_path and
-- node_version are written ONLY by the enable/disable CLI (never by agmsgd
-- itself), per T3 "常駐の登録".
CREATE TABLE IF NOT EXISTS meta (
  schema_version INTEGER NOT NULL,
  node_path TEXT,
  node_version TEXT
);
INSERT INTO meta (schema_version, node_path, node_version)
  SELECT 1, NULL, NULL WHERE NOT EXISTS (SELECT 1 FROM meta);

-- daemon_owner: always exactly one row (never deleted, never a second row).
-- gen increases monotonically and is never reused. executor_* is the
-- (pid, start-time evidence, boot id) triple used to tell a live executor
-- from a reused pid. last_end is written ONLY by the owning gen's own CAS
-- when it transitions itself to state='none' (bind failure, stepped aside
-- for an update, or a normal stop) -- never by a start attempt that was
-- refused, and never by any reader (status/doctor).
CREATE TABLE IF NOT EXISTS daemon_owner (
  gen INTEGER NOT NULL,
  state TEXT NOT NULL,
  executor_pid INTEGER,
  executor_started_at TEXT,
  executor_boot_id TEXT,
  socket TEXT,
  version TEXT,
  started_at TEXT,
  last_end_reason TEXT,
  last_end_at TEXT,
  last_end_gen INTEGER,
  node_path TEXT,
  node_version TEXT
);
INSERT INTO daemon_owner (gen, state)
  SELECT 0, 'none' WHERE NOT EXISTS (SELECT 1 FROM daemon_owner);

-- daemon_intent: always exactly one row. Changed ONLY by an explicit
-- operation (start/stop/enable/disable/uninstall) -- never by a SIGTERM or
-- an OS/resident-manager restart. op_gen increases by 1 on every explicit
-- operation (inside the operation lock for start/enable/disable/uninstall;
-- without the lock for stop, per T3).
CREATE TABLE IF NOT EXISTS daemon_intent (
  desired TEXT NOT NULL,
  set_by TEXT,
  set_at TEXT,
  op_gen INTEGER NOT NULL
);
INSERT INTO daemon_intent (desired, set_by, set_at, op_gen)
  SELECT 'off', NULL, NULL, 0 WHERE NOT EXISTS (SELECT 1 FROM daemon_intent);

-- daemon_start_attempts: append-only history for display only (never a
-- safety-critical read). Written by the launcher and by a start attempt that
-- was refused ownership -- never touches daemon_owner.
CREATE TABLE IF NOT EXISTS daemon_start_attempts (
  at TEXT NOT NULL,
  reason TEXT NOT NULL,
  executor_pid INTEGER
);
