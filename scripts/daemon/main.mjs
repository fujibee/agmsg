// Starts, runs, and stops one agmsgd process. Ties
// owner.mjs / control.mjs / lifecycle.mjs / log.mjs / status.mjs together;
// none of the actual CAS/socket/verification logic lives here.
//
// Split into separately-callable pieces on purpose: shutdown is handled
// in one place and in a known order.
// startup() / pollOnce() / gracefulStop() are each independently testable
// without wiring real signal handlers or a real interval timer, which
// main() (the actual CLI entrypoint) only assembles.
//
// channelHooks are polled from the daemon's single event loop and stopped
// before the control socket closes.

import { takeOwnership, markReady, markStopping, revertToNone, stopNormally } from "./owner.mjs";
import { createControlServer } from "./control.mjs";
import { captureWatchState, watchForDrift } from "./lifecycle.mjs";
import { logLine } from "./log.mjs";
import { classify } from "./status.mjs";
import { createCodexQueueChannel } from "./channels/codex-queue.mjs";
import { ensureCodexChannelSchema } from "./channels/codex-queue-store.mjs";

export const POLL_INTERVAL_MS = 5000;

export async function prepareClaimWithCodexSchema(prepareClaim) {
  const prepared = await prepareClaim();
  ensureCodexChannelSchema(prepared.db);
  return prepared;
}

export async function pollChannelHooks(channelHooks, log = () => {}) {
  for (const hook of channelHooks) {
    try {
      await hook.pollOnce();
    } catch (error) {
      log(`channel: poll failed: ${error.message}`);
    }
  }
}

// Takes ownership and binds the control socket. Returns
// {ok: true, gen, controlHandle, db} or {ok: false, reason, db} -- a
// refusal from takeOwnership OR a bind failure, both reported the same
// shape so the caller (main()) can log+exit either without a separate
// branch. A bind failure additionally reverts daemon_owner back to 'none'.
// When supplied, prepareClaim rechecks the install while holding its lock
// and returns the database plus a release callback; that lock stays held
// through ownership claim and socket readiness.
export async function startup(db, { installRoot, expectedDesired, expectedOpGen, version, handlers, prepareClaim }) {
  let releaseInstallLock = () => {};
  try {
    if (prepareClaim) {
      const prepared = await prepareClaim();
      db = prepared.db;
      releaseInstallLock = prepared.release;
    }

    const owned = takeOwnership(db, { installRoot, expectedDesired, expectedOpGen, version });
    if (!owned.ok) return { ...owned, db };

    let controlHandle;
    try {
      controlHandle = await createControlServer(owned.socket, handlers);
    } catch (error) {
      revertToNone(db, owned.gen, "bind_failed");
      logLine(installRoot, `startup: bind failed for gen ${owned.gen}: ${error.message}`);
      return { ok: false, reason: `bind failed: ${error.message}`, db };
    }
    markReady(db, owned.gen);
    logLine(installRoot, `startup: gen ${owned.gen} ready at ${owned.socket}`);
    return { ok: true, gen: owned.gen, controlHandle, db };
  } finally {
    releaseInstallLock();
  }
}

// One poll cycle. Returns
// {action: "continue"} | {action: "step_aside", reason} |
// {action: "stop", reason} -- callers act on the verdict; this function
// itself performs no shutdown steps.
export async function pollOnce(db, installRoot, { gen, expectedOpGen, watchState }) {
  const drift = await watchForDrift(installRoot, watchState);
  if (drift.changed) {
    return { action: "step_aside", reason: "stepped_aside_for_update" };
  }
  const intent = db.prepare("SELECT op_gen FROM daemon_intent").get();
  if (intent.op_gen !== expectedOpGen) {
    // An explicit operation happened since
    // this process started; step aside regardless of what desired says
    // now, so an old process from an off->on->off sequence never keeps
    // running just because desired flipped back to on again later.
    return { action: "stop", reason: "normal" };
  }
  return { action: "continue" };
}

// The one place shutdown happens: mark stopping -> stop
// every registered channel -> close the control socket -> record the
// normal stop. `reason` becomes daemon_owner.last_end_reason (status.mjs
// pattern-matches "stepped_aside_for_update" specifically; anything else
// falls through to its generic "stopped" text).
export async function gracefulStop(db, installRoot, gen, controlHandle, channelHooks, reason) {
  markStopping(db, gen);
  for (const hook of channelHooks) {
    try {
      await hook.stop();
    } catch (error) {
      logLine(installRoot, `shutdown: a channel's stop() threw: ${error.message}`);
    }
  }
  await controlHandle.close();
  stopNormally(db, gen, reason);
  logLine(installRoot, `shutdown: gen ${gen} stopped (${reason})`);
}

// The actual CLI entrypoint: wires startup(), a real interval timer for
// pollOnce(), real SIGTERM handling, and control.mjs's stop/status
// handlers, onto db/manifest values the caller (agmsgd's bootstrap) has
// already verified. Exit codes: 0 for a declined
// start or a normal/SIGTERM stop, 75 for stepping aside for an update, 1
// for a bind failure or any other unexpected error.
export async function main(db, { installRoot, manifest, manifestText, expectedDesired, expectedOpGen, version, prepareClaim }) {
  const channelHooks = [];
  let controlHandle;
  let gen;
  let stopping = false;
  let timer;

  async function doStop(reason) {
    if (stopping) return;
    stopping = true;
    clearInterval(timer);
    await gracefulStop(db, installRoot, gen, controlHandle, channelHooks, reason);
    process.exit(reason === "stepped_aside_for_update" ? 75 : 0);
  }

  const started = await startup(db, {
    installRoot,
    expectedDesired,
    expectedOpGen,
    version,
    prepareClaim: prepareClaim ? async () => {
      const prepared = await prepareClaimWithCodexSchema(prepareClaim);
      db = prepared.db;
      return prepared;
    } : undefined,
    handlers: {
      onStop: async () => {
        // Fires from inside a control-socket request; the response itself
        // must still go out before the process exits, so this only
        // schedules the stop rather than awaiting it inline.
        setImmediate(() => doStop("normal"));
        return { gen };
      },
      onStatus: async () => classify({ owner: { gen, state: "ready", version }, intent: {}, alive: true, reachable: true }),
    },
  });
  db = started.db ?? db;
  if (!started.ok) {
    logLine(installRoot, `startup declined: ${started.reason}`);
    db.prepare("INSERT INTO daemon_start_attempts (at, reason, executor_pid) VALUES (?, ?, ?)").run(
      new Date().toISOString(),
      started.reason,
      process.pid,
    );
    process.exit(started.reason.startsWith("bind failed") ? 1 : 0);
    return;
  }
  gen = started.gen;
  controlHandle = started.controlHandle;
  channelHooks.push(createCodexQueueChannel({ db, installRoot, expectedOpGen }));

  process.on("SIGTERM", () => doStop("normal"));

  const watchState = await captureWatchState(installRoot, manifest, manifestText);
  let polling = false;
  timer = setInterval(async () => {
    if (stopping || polling) return;
    polling = true;
    try {
      const verdict = await pollOnce(db, installRoot, { gen, expectedOpGen, watchState });
      if (verdict.action !== "continue") {
        await doStop(verdict.reason);
        return;
      }
      await pollChannelHooks(channelHooks, (message) => logLine(installRoot, message));
    } finally {
      polling = false;
    }
  }, POLL_INTERVAL_MS);
}
