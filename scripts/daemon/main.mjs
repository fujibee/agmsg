// Starts, runs, and stops one agmsgd process (arch-7 §2, T3). Ties
// owner.mjs / control.mjs / lifecycle.mjs / log.mjs / status.mjs together;
// none of the actual CAS/socket/verification logic lives here.
//
// Split into separately-callable pieces on purpose (T4's own note: "止め
// る合図を1か所で受け、T3の順で止める" -- ONE place, in a known order):
// startup() / pollOnce() / gracefulStop() are each independently testable
// without wiring real signal handlers or a real interval timer, which
// main() (the actual CLI entrypoint) only assembles.
//
// channelHooks (an array of {stop()}) is beta's plug point for the Codex
// queue channel -- a separate PR/component this file does not own. Empty
// in this PR; gracefulStop() already calls stop() on every registered
// hook, in the correct place in the shutdown order, so that PR only needs
// to register its hook, not restructure this file.

import { takeOwnership, markReady, markStopping, revertToNone, stopNormally } from "./owner.mjs";
import { createControlServer } from "./control.mjs";
import { captureWatchState, watchForDrift } from "./lifecycle.mjs";
import { logLine } from "./log.mjs";
import { classify } from "./status.mjs";

export const POLL_INTERVAL_MS = 5000;

// Takes ownership and binds the control socket. Returns
// {ok: true, gen, controlHandle} or {ok: false, reason} -- a refusal from
// takeOwnership OR a bind failure, both reported the same shape so the
// caller (main()) can log+exit either without a separate branch. A bind
// failure additionally reverts daemon_owner back to 'none' (arch-7 §1's
// step-2 failure path) before returning.
export async function startup(db, { installRoot, expectedDesired, expectedOpGen, version, handlers }) {
  const owned = takeOwnership(db, { installRoot, expectedDesired, expectedOpGen, version });
  if (!owned.ok) return owned;

  let controlHandle;
  try {
    controlHandle = await createControlServer(owned.socket, handlers);
  } catch (error) {
    revertToNone(db, owned.gen, "bind_failed");
    logLine(installRoot, `startup: bind failed for gen ${owned.gen}: ${error.message}`);
    return { ok: false, reason: `bind failed: ${error.message}` };
  }
  markReady(db, owned.gen);
  logLine(installRoot, `startup: gen ${owned.gen} ready at ${owned.socket}`);
  return { ok: true, gen: owned.gen, controlHandle };
}

// One poll cycle (T3 "動いているagmsgd" / "op_genの見張り"). Returns
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
    // T3: "自分が起動したときの値と違えば(desiredがonに戻っていても)係を
    // 退役させて普通の停止に入る" -- an explicit operation happened since
    // this process started; step aside regardless of what desired says
    // now, so an old process from an off->on->off sequence never keeps
    // running just because desired flipped back to on again later.
    return { action: "stop", reason: "normal" };
  }
  return { action: "continue" };
}

// The one place shutdown happens, in T3's order: mark stopping -> stop
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
// already verified. Exit codes match T3's own table: 0 for a declined
// start or a normal/SIGTERM stop, 75 for stepping aside for an update, 1
// for a bind failure or any other unexpected error (the "起こし直す" row).
export async function main(db, { installRoot, manifest, manifestText, expectedDesired, expectedOpGen, version }) {
  const channelHooks = []; // beta's Codex-queue channel plugs in here, separately.
  let controlHandle;
  let gen;
  let stopping = false;

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

  process.on("SIGTERM", () => doStop("normal"));

  const watchState = await captureWatchState(installRoot, manifest, manifestText);
  const timer = setInterval(async () => {
    if (stopping) return;
    const verdict = await pollOnce(db, installRoot, { gen, expectedOpGen, watchState });
    if (verdict.action !== "continue") await doStop(verdict.reason);
  }, POLL_INTERVAL_MS);
}
