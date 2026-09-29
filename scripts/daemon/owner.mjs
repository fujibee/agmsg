// daemon_owner compare-and-swap lifecycle.
//
// daemon_intent itself is written only by scripts/daemon.sh (the explicit
// CLI operations, directly via sqlite3 -- bash cannot call into this file),
// never from here. This file only READS daemon_intent, to condition taking
// ownership on it still matching what the launcher observed.
//
// The install-op lock (run/install-op.lock.db, PR 2) is a SEPARATE
// mechanism the entrypoint holds only while loading code; by the time
// takeOwnership() runs, that lock has already been
// released. daemon_owner's own gen-conditioned CAS is self-contained and
// needs no external lock.

import { join } from "node:path";
import { currentExecutor, isAlive } from "./executor.mjs";
import { withImmediateTransaction } from "./db.mjs";

export function readOwner(db) {
  return db.prepare("SELECT * FROM daemon_owner").get();
}

export function readIntent(db) {
  return db.prepare("SELECT * FROM daemon_intent").get();
}

function socketPath(installRoot, gen) {
  return join(installRoot, "run", `agmsgd.${gen}.sock`);
}

// Read daemon_owner, and if the current owner is
// state='none' or confirmed dead, take the next gen and move to
// 'starting' -- ALSO requiring, in the same read, that daemon_intent still
// matches what the caller (the launcher) already observed. Returns
// `{ok: true, gen, socket}` for the caller to go bind, or
// `{ok: false, reason}` -- the caller (agmsgd's entrypoint) is responsible
// for writing daemon_start_attempts and exiting 0 on a refusal; this
// function only decides, it does not log.
//
// `version` is this process's own build/version string, recorded in
// daemon_owner.version once ownership is taken.
export function takeOwnership(db, { installRoot, expectedDesired, expectedOpGen, version }) {
  return withImmediateTransaction(db, () => {
    const intent = readIntent(db);
    if (intent.desired !== expectedDesired || intent.op_gen !== expectedOpGen) {
      return { ok: false, reason: "intent changed since the launcher read it" };
    }

    const owner = readOwner(db);
    let refuse = null;
    if (owner.state !== "none") {
      if (owner.executor_pid == null) {
        refuse = "owner state is not none but has no recorded executor";
      } else {
        const alive = isAlive({ pid: owner.executor_pid, bootId: owner.executor_boot_id });
        if (alive === true) refuse = "current owner is alive";
        else if (alive === null) refuse = "current owner's liveness cannot be determined";
        // alive === false (confirmed dead): fall through, this call takes over.
      }
    }
    if (refuse) return { ok: false, reason: refuse };

    const gen = owner.gen + 1;
    const executor = currentExecutor();
    const socket = socketPath(installRoot, gen);
    const startedAt = new Date().toISOString();
    db.prepare(
      `UPDATE daemon_owner SET gen = ?, state = 'starting',
         executor_pid = ?, executor_started_at = ?, executor_boot_id = ?,
         socket = ?, version = ?, started_at = ?,
         last_end_reason = NULL, last_end_at = NULL, last_end_gen = NULL
       WHERE gen = ?`,
    ).run(gen, executor.pid, startedAt, executor.bootId, socket, version, startedAt, owner.gen);
    return { ok: true, gen, socket };
  });
}

// Step 3: bind succeeded -- move 'starting' -> 'ready', conditioned on gen
// A no-op-safe false return (rather than throwing) if some
// other actor already moved this gen off 'starting' -- that should not
// happen in beta (single-threaded event loop, nothing else CASes this gen),
// but the condition costs nothing and documents the invariant.
export function markReady(db, gen) {
  const result = db
    .prepare("UPDATE daemon_owner SET state = 'ready' WHERE gen = ? AND state = 'starting'")
    .run(gen);
  return result.changes > 0;
}

// Bind failed: move back to 'none',
// conditioned on gen, and record why via last_end (this IS this gen's own
// CAS back to none, so last_end is the right place to record completion).
export function revertToNone(db, gen, reason) {
  const at = new Date().toISOString();
  const result = db
    .prepare(
      `UPDATE daemon_owner SET state = 'none', socket = NULL,
         last_end_reason = ?, last_end_at = ?, last_end_gen = ?
       WHERE gen = ? AND state = 'starting'`,
    )
    .run(reason, at, gen, gen);
  return result.changes > 0;
}

// Normal stop: this gen's own
// CAS from any running state to 'none', with last_end. Callers (main.mjs)
// must have already stopped accepting control requests, closed the
// listening socket, and confirmed their own child process group is empty
// BEFORE calling this -- this function only performs the final state
// transition, it does not do any of that stopping itself.
export function stopNormally(db, gen, reason = "normal") {
  const at = new Date().toISOString();
  const result = db
    .prepare(
      `UPDATE daemon_owner SET state = 'none', socket = NULL,
         last_end_reason = ?, last_end_at = ?, last_end_gen = ?
       WHERE gen = ? AND state != 'none'`,
    )
    .run(reason, at, gen, gen);
  return result.changes > 0;
}

// Called at the top of main.mjs's transition into 'stopping', before doing
// the actual shutdown work -- lets a reader (status.mjs) see the daemon is
// mid-shutdown rather than still 'ready'.
export function markStopping(db, gen) {
  const result = db
    .prepare("UPDATE daemon_owner SET state = 'stopping' WHERE gen = ? AND state = 'ready'")
    .run(gen);
  return result.changes > 0;
}
