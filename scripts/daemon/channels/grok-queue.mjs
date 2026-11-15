// agmsgd native delivery for grok-build seats in agmsgd mode: nudges a
// registered seat's own grok leader over ACP (grok-queue-io.mjs) on an
// unread transition. Mirrors terminal-poke.mjs's shape (registration +
// per-seat backoff over a simple nudge primitive), not codex-queue.mjs's
// heavier pending/confirmed/expired queue table: acceptance here is
// observed synchronously within one process launch (queueChangedAccepts),
// so there is no cross-poll pending state to reconcile.
//
// One process launch per seat per unread TRANSITION, never per poll cycle.

import { join } from "node:path";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { createSeatBook } from "../seat-book.mjs";
import { assertPollActive, pollSignal, SEAT_DEADLINE_MS } from "../poll-deadline.mjs";
import { createSeatPoller } from "../seat-poll.mjs";
import { logLine } from "../log.mjs";
import { optedOutOfAgmsgd } from "./delivery-choice.mjs";
import { withImmediateTransaction } from "../db.mjs";
import {
  messageStorePath,
  openMessageStore,
  readStorageDriver,
  readUnreadSnapshot,
} from "./codex-queue-store.mjs";
import { leaderSocketDirIsLax, listGrokRegistrations, readGrokWitness } from "./grok-queue-store.mjs";
import { pokeNudgeText } from "./terminal-poke-types.mjs";
import { runGrokNudge } from "./grok-queue-io.mjs";

const NUDGE_TIMEOUT_MS = 10_000;
// Same shape as terminal-poke's own backoff (review precedent, #1973): a
// pending notice retries with backoff, never every poll cycle; a NEW unread
// transition for that seat resets it to the first step immediately.
const PENDING_BACKOFF_START_MS = 30_000;
const PENDING_BACKOFF_MAX_MS = 5 * 60_000;

export function seatKey(team, agent) {
  return JSON.stringify([team, agent]);
}

function storagePaths(installRoot, env) {
  return {
    storageDir: env.AGMSG_STORAGE_PATH || join(installRoot, "db"),
    configPath: env.AGMSG_CONFIG || join(homedir(), ".agents", "agmsg", "config.json"),
  };
}

// See terminal-poke.mjs's own identical function for why this, not
// readUnreadSnapshot's team-wide upTo, is the backoff key (#1973 review).
function readOwnUnreadMarker(store, team, agent) {
  const eventRow = store.prepare(`
    SELECT COALESCE(MAX(seq), 0) AS n FROM events WHERE type = 'message_sent' AND team = ? AND to_agent = ?
  `).get(team, agent);
  const legacyRow = store.prepare(`
    SELECT COALESCE(MAX(id), 0) AS n FROM messages WHERE team = ? AND to_agent = ?
  `).get(team, agent);
  return `${eventRow?.n ?? 0}:${legacyRow?.n ?? 0}`;
}

function saveSeat(book, { seat, state, reason = "" }) {
  assertPollActive();
  book.set(seat, { state, reason });
}

// Minimal queue bookkeeping, same shape as terminal-poke.mjs's own -- this
// channel's acceptance is observed synchronously inside the nudge call, not
// reconciled from a later poll, but createSeatPoller still reads this table
// per seat to emit its own sent/expired log events (see grok-queue-store.mjs's
// schema comment).
function setQueueState(db, id, state) {
  assertPollActive();
  withImmediateTransaction(db, () => {
    db.prepare("UPDATE beta_grok_queue_queue SET state = ? WHERE id = ? AND state = 'pending'").run(state, id);
  });
}

function createSendAttempt(db, { seat, upTo, expectedOpGen }, now) {
  assertPollActive();
  let rowId;
  withImmediateTransaction(db, () => {
    const intent = db.prepare("SELECT desired, op_gen FROM daemon_intent").get();
    if (intent?.desired !== "on" || intent.op_gen !== expectedOpGen) {
      throw new Error("daemon_intent_changed");
    }
    db.prepare("UPDATE beta_grok_queue_queue SET state = 'expired' WHERE seat = ? AND state = 'pending'").run(seat);
    const result = db.prepare(`
      INSERT INTO beta_grok_queue_queue (seat, up_to, state, created_at)
      VALUES (?, ?, 'pending', ?)
    `).run(seat, upTo, new Date(now()).toISOString());
    rowId = Number(result.lastInsertRowid);
  });
  return rowId;
}

// Liveness check for the witness's own recorded pid -- a process that is
// definitely gone means the seat's session has ended and a nudge would
// reach nobody; an unresolvable check (permission, foreign pid namespace)
// is NOT treated as dead, same conservative direction every other liveness
// check in this codebase takes (actas_lock_sid_alive's three-valued result).
function pidAlive(pid) {
  const n = Number(pid);
  if (!Number.isInteger(n) || n <= 0) return false;
  try {
    process.kill(n, 0);
    return true;
  } catch (error) {
    if (error?.code === "ESRCH") return false;
    return true; // EPERM or anything else: cannot tell, assume alive
  }
}

// PATH wins when `grok` is actually on it; only then do the two documented
// install locations get tried (2026-11-15 review, NG3) -- a user who put
// their own `grok` on PATH is never second-guessed. A spawn with none of
// these found still gets attempted against the bare name "grok" so
// spawn_failed:ENOENT (grok-queue-io.mjs) is still the reported reason,
// rather than inventing a fourth, unreachable path here.
export function resolveGrokExecutable(env) {
  const pathDirs = (env.PATH || "").split(process.platform === "win32" ? ";" : ":").filter(Boolean);
  const onPath = pathDirs.some((dir) => existsSync(join(dir, "grok")));
  if (onPath) return "grok"; // let spawn's own PATH search resolve it
  const grokHome = env.GROK_HOME || join(homedir(), ".grok");
  const candidates = [
    join(homedir(), ".local", "bin", "grok"),
    join(grokHome, "bin", "grok"),
  ];
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  return "grok"; // nothing found anywhere: let spawn report ENOENT
}

function classifyWitness(result) {
  if (result.state === "missing") return { ok: false, reason: "not_registered_for_agmsgd" };
  if (result.state === "unreadable") return { ok: false, reason: `witness_${result.reason}` };
  const { witness } = result;
  if (!pidAlive(witness.pid)) return { ok: false, reason: "process_gone" };
  if (witness.first_turn_done !== true) return { ok: false, reason: "first_turn_pending" };
  if (typeof witness.leader_socket !== "string" || witness.leader_socket.length === 0) {
    return { ok: false, reason: "leader_socket_unknown" };
  }
  if (typeof witness.cwd !== "string" || witness.cwd.length === 0) {
    return { ok: false, reason: "cwd_unknown" };
  }
  return { ok: true, witness };
}

export function createGrokQueueChannel({
  db,
  installRoot,
  expectedOpGen,
  env = process.env,
  seatDeadlineMs = SEAT_DEADLINE_MS,
  timeoutMs = NUDGE_TIMEOUT_MS,
  now = Date.now,
  log = (message) => logLine(installRoot, message),
  listSeats = listGrokRegistrations,
  readWitness = (team, agent) => readGrokWitness(installRoot, team, agent),
  nudgeText = (cmdName) => pokeNudgeText(installRoot, "grok-build", cmdName),
  readDriver = readStorageDriver,
  openStore = openMessageStore,
  readSnapshot = readUnreadSnapshot,
  readOwnMarker = readOwnUnreadMarker,
  nudge = (args) => runGrokNudge(args),
  checkSocketPerms = leaderSocketDirIsLax,
  grokExecutable = (callEnv) => resolveGrokExecutable(callEnv),
  cmdName = installRoot.split(/[\\/]/).filter(Boolean).pop() ?? "agmsg",
}) {
  let stopped = false;
  const book = createSeatBook(now);
  let rosterReasons = new Map();
  let activePoll = null;
  let activePollSignal;
  let resumeAfter;
  const pendingBackoff = new Map();
  // The last own-unread marker a nudge was actually confirmed accepted for
  // (see readOwnUnreadMarker). readSnapshot's own "unread" bit stays true
  // until the seat's REAL read_cursors move -- which happens only once
  // grok's Stop hook actually runs check-inbox.sh for the turn this nudge
  // caused -- so without this, a slow or stalled turn would relaunch a
  // nudge every single poll cycle for the identical already-accepted
  // unread set. In-memory only, like pendingBackoff: a daemon restart just
  // allows one extra nudge for an already-notified set, which is the safe
  // direction.
  const lastNotifiedMarker = new Map();

  const seatPoller = createSeatPoller({
    db, book, installRoot, channel: "grok_queue", log, timeoutMs: seatDeadlineMs,
    saveTimeout: (seat, reason) => saveSeat(book, { seat, state: "pending", reason }),
  });

  async function pollSeat(seat, paths) {
    const { team, agent, project } = seat;
    const key = seatKey(team, agent);

    const optedOut = optedOutOfAgmsgd(installRoot, "grok-build", project);
    if (optedOut) {
      saveSeat(book, { seat: key, state: "unaddressable", reason: `delivery_chosen_${optedOut}` });
      return;
    }

    const witnessResult = classifyWitness(readWitness(team, agent));
    if (!witnessResult.ok) {
      saveSeat(book, { seat: key, state: "unaddressable", reason: witnessResult.reason });
      return;
    }

    let driver;
    try {
      driver = readDriver(paths.configPath);
    } catch (error) {
      saveSeat(book, { seat: key, state: "pending", reason: `storage_config_unreadable:${error.message}` });
      return;
    }
    if (driver.state !== "ok") {
      saveSeat(book, { seat: key, state: "pending", reason: driver.reason });
      return;
    }
    if (driver.driver !== "sqlite") {
      saveSeat(book, { seat: key, state: "unaddressable", reason: "storage_driver_unsupported" });
      return;
    }

    let storePath;
    try {
      storePath = messageStorePath({ storageDir: paths.storageDir, team, teamConfig: seat.teamConfig });
    } catch (error) {
      saveSeat(book, { seat: key, state: "pending", reason: `message_store_path_unreadable:${error.message}` });
      return;
    }
    let store;
    try {
      store = openStore(storePath);
    } catch (error) {
      saveSeat(book, { seat: key, state: "pending", reason: `message_store_unreadable:${error.message}` });
      return;
    }
    let snapshot;
    let ownMarker = "";
    try {
      snapshot = readSnapshot(store, team, agent, "");
      ownMarker = readOwnMarker(store, team, agent);
    } catch (error) {
      saveSeat(book, { seat: key, state: "pending", reason: `message_store_unreadable:${error.message}` });
      return;
    } finally {
      try { store.close(); } catch { /* keep the read result */ }
    }

    // Observational only (§10, 2026-10-31): a lax permission on the leader
    // socket's own directory is reported, never a reason to withhold
    // delivery -- surfaced as the "addressable"/"notified" state's own
    // reason text rather than a separate refusal.
    const permsWarning = checkSocketPerms(witnessResult.witness.leader_socket) ? "socket_dir_perms_lax" : "";

    if (!snapshot.unread || stopped) {
      pendingBackoff.delete(key);
      saveSeat(book, { seat: key, state: "addressable", reason: permsWarning });
      return;
    }

    if (lastNotifiedMarker.get(key) === ownMarker) {
      // Already successfully nudged for this exact unread set; the turn it
      // caused has not yet marked it read in the real store. Not a new
      // transition, so no relaunch -- same book state as last time.
      return;
    }

    const backoff = pendingBackoff.get(key);
    if (backoff && backoff.upTo === ownMarker && now() < backoff.nextAttemptAt) {
      return; // same unread set as the last refused attempt, not due yet
    }

    let id;
    try {
      id = createSendAttempt(db, { seat: key, upTo: ownMarker, expectedOpGen }, now);
    } catch (error) {
      if (error.message !== "daemon_intent_changed") throw error;
      return;
    }

    let result;
    try {
      result = await nudge({
        executable: grokExecutable(env),
        leaderSocket: witnessResult.witness.leader_socket,
        sessionId: witnessResult.witness.session_id,
        cwd: witnessResult.witness.cwd,
        text: nudgeText(cmdName),
        timeoutMs,
        env,
        signal: pollSignal(),
      });
    } catch (error) {
      result = { kind: "failed", reason: `nudge_error:${error?.code ?? error?.message ?? String(error)}` };
    }

    if (result.kind === "ok") {
      setQueueState(db, id, "confirmed");
      pendingBackoff.delete(key);
      lastNotifiedMarker.set(key, ownMarker);
      saveSeat(book, { seat: key, state: "notified", reason: permsWarning });
      return;
    }
    setQueueState(db, id, "expired");
    bumpBackoff(key, ownMarker);
    const reason = result.kind === "timeout" ? "nudge_timeout"
      : result.kind === "cancelled" ? "nudge_cancelled"
      : `nudge_failed:${result.reason ?? "unknown"}`;
    saveSeat(book, { seat: key, state: "pending", reason });
  }

  function bumpBackoff(key, upTo) {
    const previous = pendingBackoff.get(key);
    const delayMs = previous && previous.upTo === upTo
      ? Math.min(previous.delayMs * 2, PENDING_BACKOFF_MAX_MS)
      : PENDING_BACKOFF_START_MS;
    pendingBackoff.set(key, { nextAttemptAt: now() + delayMs, delayMs, upTo });
  }

  function recordSkippedTeams(skipped) {
    const current = new Map(skipped.map(({ team, reason }) => [team, reason]));
    for (const [team, reason] of current) {
      if (rosterReasons.get(team) === reason) continue;
      log(`channel: grok-queue roster for team ${team} skipped (${reason})`);
      saveSeat(book, { seat: seatKey(team, ""), state: "unaddressable", reason });
    }
    for (const seat of book.keys()) {
      let parsed;
      try { parsed = JSON.parse(seat); } catch { continue; }
      if (Array.isArray(parsed) && parsed[1] === "" && !current.has(parsed[0])) {
        assertPollActive();
        book.delete(seat);
      }
    }
    rosterReasons = current;
  }

  async function pollOnce({ signal } = {}) {
    if (stopped) return;
    if (activePoll && !activePollSignal?.aborted) return activePoll;
    activePollSignal = pollSignal() ?? signal;
    const operation = (async () => {
      const roster = listSeats(join(installRoot, "teams"));
      if (roster.state !== "ok") {
        log(`channel: grok-queue roster unavailable (${roster.reason})`);
        return;
      }
      const paths = storagePaths(installRoot, env);
      recordSkippedTeams(roster.skipped ?? []);
      const seats = [...roster.seats];
      const registeredKeys = new Set(seats.map(({ team, agent }) => seatKey(team, agent)));
      for (const { team } of roster.skipped ?? []) registeredKeys.add(seatKey(team, ""));
      for (const key of book.keys()) {
        if (!registeredKeys.has(key)) {
          pendingBackoff.delete(key);
          lastNotifiedMarker.delete(key);
          saveSeat(book, { seat: key, state: "unaddressable", reason: "seat_registration_missing" });
        }
      }
      const start = seats.findIndex(seat => seatKey(seat.team, seat.agent) === resumeAfter) + 1;
      const ordered = [...seats.slice(start), ...seats.slice(0, start)];
      for (const seat of ordered) {
        if (stopped || pollSignal()?.aborted || signal?.aborted) break;
        resumeAfter = seatKey(seat.team, seat.agent);
        try {
          await seatPoller.poll(seat, () => pollSeat(seat, paths));
        } catch (error) {
          if (pollSignal()?.aborted || signal?.aborted) break;
          log(`channel: grok-queue seat ${seat.team}/${seat.agent} could not be checked (${error.message})`);
        }
      }
      book.pollFinished();
    })().finally(() => { if (activePoll === operation) activePoll = null; });
    activePoll = operation;
    return operation;
  }

  return {
    name: "grok_queue",
    reportTimeout: seatPoller.reportTimeout,
    seatKind: "grok_queue",
    seats: () => book.snapshot(),
    pollOnce,
    async stop() {
      stopped = true;
      seatPoller.cancel();
      await activePoll;
    },
  };
}
