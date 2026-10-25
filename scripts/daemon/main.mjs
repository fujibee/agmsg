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
import { logLine, deliveryEvent, recordPollTimeout } from "./log.mjs";
import { classify } from "./status.mjs";
import { createCodexQueueChannel } from "./channels/codex-queue.mjs";
import { ensureCodexChannelSchema } from "./channels/codex-queue-store.mjs";
import { createClaudeCodeQueueChannel } from "./channels/claude-code-queue.mjs";
import { ensureClaudeCodeChannelSchema } from "./channels/claude-code-queue-store.mjs";

import { withDeadline, PollDeadlineError, CHANNEL_DEADLINE_MS, CYCLE_DEADLINE_MS, STOP_DEADLINE_MS } from './poll-deadline.mjs';

export const POLL_INTERVAL_MS = 5000;

export async function prepareClaimWithCodexSchema(prepareClaim) {
  const prepared = await prepareClaim();
  ensureCodexChannelSchema(prepared.db);
  ensureClaudeCodeChannelSchema(prepared.db);
  return prepared;
}

export async function pollChannelHooks(channelHooks, log = () => {}, { timeoutMs = CHANNEL_DEADLINE_MS, signal, installRoot } = {}) {
  for (const [index, hook] of channelHooks.entries()) {
    if (signal?.aborted) break;
    const channel = hook.name ?? `channel_${index}`;
    try {
      await withDeadline(childSignal => hook.pollOnce({ signal: childSignal }), { timeoutMs, signal, reason: 'channel_poll_deadline' });
    } catch (error) {
      if (signal?.aborted) break;
      if (error instanceof PollDeadlineError) {
        const seat = hook.reportTimeout?.(error.message);
        if (!seat) deliveryEvent(log, { event: 'poll_timeout', channel, seat, reason: error.message });
        if (installRoot && !seat) recordPollTimeout(installRoot, { channel, seat, reason: error.message });
      } else log(`channel: poll failed: ${error.message}`);
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

// A transient lock held by another writer: the next poll simply tries again.
export function isBusyError(error) {
  return (error?.errcode & 0xff) === 5 || /database is (locked|busy)/i.test(String(error?.message ?? ""));
}

// One timer tick: the poll plus the channel polls. A busy database skips this
// tick; any other unexpected error is written to agmsgd.log before it
// propagates, so the exit is never silent.
export async function pollCycle(db, installRoot, context, channelHooks) {
  try {
    return await withDeadline(async signal => {
      const verdict = await pollOnce(db, installRoot, context);
      signal.throwIfAborted();
      if (verdict.action !== "continue") return verdict;
      await pollChannelHooks(channelHooks, message => logLine(installRoot, message), {
        timeoutMs: context.channelDeadlineMs ?? CHANNEL_DEADLINE_MS, signal, installRoot,
      });
      return verdict;
    }, { timeoutMs: context.cycleDeadlineMs ?? CYCLE_DEADLINE_MS, signal: context.signal, reason: 'poll_cycle_deadline' });
  } catch (error) {
    if (context.signal?.aborted) return { action: 'stop', reason: 'normal' };
    if (error instanceof PollDeadlineError) {
      let affected = false;
      for (const hook of channelHooks) affected = Boolean(hook.reportTimeout?.(error.message)) || affected;
      deliveryEvent(message => logLine(installRoot, message), { event: 'poll_timeout', channel: 'daemon', reason: error.message });
      if (!affected) recordPollTimeout(installRoot, { channel: 'daemon', reason: error.message });
      return { action: 'continue' };
    }
    if (isBusyError(error)) {
      logLine(installRoot, `poll: database busy, retrying next poll (${error.message})`);
      return { action: "continue" };
    }
    logLine(installRoot, `poll: unexpected error, exiting: ${error?.stack ?? error}`);
    throw error;
  }
}

// The one place shutdown happens: mark stopping -> stop
// every registered channel -> close the control socket -> record the
// normal stop. `reason` becomes daemon_owner.last_end_reason (status.mjs
// pattern-matches "stepped_aside_for_update" specifically; anything else
// falls through to its generic "stopped" text).
export async function gracefulStop(db, installRoot, gen, controlHandle, channelHooks, reason, { timeoutMs = STOP_DEADLINE_MS } = {}) {
  markStopping(db, gen);
  for (const hook of channelHooks) {
    try {
      await withDeadline(() => hook.stop(), { timeoutMs, signal: null, reason: 'channel_stop_deadline' });
    } catch (error) {
      logLine(installRoot, `shutdown: a channel's stop() threw: ${error.message}`);
    }
  }
  try {
    await withDeadline(() => controlHandle.close(), { timeoutMs, signal: null, reason: 'control_stop_deadline' });
  } catch (error) { logLine(installRoot, `shutdown: control close failed: ${error.message}`); }
  stopNormally(db, gen, reason);
  logLine(installRoot, `shutdown: gen ${gen} stopped (${reason})`);
}

// The actual CLI entrypoint: wires startup(), a real interval timer for
// pollOnce(), real SIGTERM handling, and control.mjs's stop/status
// handlers, onto db/manifest values the caller (agmsgd's bootstrap) has
// already verified. Exit codes: 0 for a declined
// start, a normal/SIGTERM stop or stepping aside for an update, 1 for a bind
// failure or any other unexpected error.
// The code a stopped daemon exits with. Stepping aside for an update exits 0 on
// purpose: the service managers restart only after a failure (launchd
// KeepAlive SuccessfulExit=false, systemd Restart=on-failure), and a restart
// during an update finds the install half replaced, is refused by the launcher
// and starts the manager's wait (60 s on launchd) before the installer's own
// start can bring the new version up. The installer starts it right after.
export function stopExitCode(_reason) {
  return 0;
}

export async function main(db, { installRoot, manifest, manifestText, expectedDesired, expectedOpGen, version, prepareClaim, createChannels, pollIntervalMs = POLL_INTERVAL_MS }) {
  const channelHooks = [];
  let controlHandle;
  let gen;
  let stopping = false;
  let timer;
  const lifetime = new AbortController();

  async function doStop(reason) {
    if (stopping) return;
    stopping = true;
    clearInterval(timer);
    lifetime.abort(new PollDeadlineError('daemon_stopping'));
    let exitCode = stopExitCode(reason);
    try {
      await gracefulStop(db, installRoot, gen, controlHandle, channelHooks, reason);
    } catch (error) {
      // The install may have disappeared, or its database may no longer be
      // writable. Never leave a stopped timer and live socket behind because
      // a second doStop() call sees stopping=true and returns immediately.
      exitCode = 1;
      logLine(installRoot, `shutdown: failed: ${error.message}`);
      process.stderr.write(`agmsgd: shutdown failed: ${error.message}\n`);
    } finally {
      process.exit(exitCode);
    }
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
  channelHooks.push(...(createChannels ? createChannels({ db, installRoot, expectedOpGen }) : [
    createCodexQueueChannel({ db, installRoot, expectedOpGen }),
    createClaudeCodeQueueChannel({ db, installRoot, expectedOpGen }),
  ]));

  process.on("SIGTERM", () => doStop("normal"));

  const watchState = await captureWatchState(installRoot, manifest, manifestText);
  let polling = false;
  timer = setInterval(async () => {
    if (stopping) return;
    if (polling) {
      deliveryEvent(message => logLine(installRoot, message), { event: 'poll_skipped', channel: 'daemon', reason: 'previous_cycle_running' });
      return;
    }
    polling = true;
    try {
      const verdict = await pollCycle(db, installRoot, { gen, expectedOpGen, watchState, signal: lifetime.signal }, channelHooks);
      if (verdict.action !== "continue") await doStop(verdict.reason);
    } catch (error) {
      logLine(installRoot, `poll: timer failed: ${error.message}`);
      await doStop('poll_failed');
    } finally {
      polling = false;
    }
  }, pollIntervalMs);
}
