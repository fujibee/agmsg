// agmsgd fallback delivery for any seat type with no native channel
// (antigravity, gemini, copilot, opencode, hermes, and any future type):
// nudges the seat's own pane through scripts/internal/terminal-nudge.sh,
// which reuses poke.sh unchanged. Mirrors claude-code-queue.mjs's shape.
//
// One process launch per seat per unread TRANSITION, never per poll cycle:
// a seat with nothing new since its last notified cursor is never spawned.

import { join } from "node:path";
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
import { listTerminalPokeRegistrations } from "./terminal-poke-store.mjs";
import { pokeDeliveryEnabled, pokeNudgeText } from "./terminal-poke-types.mjs";
import { runTerminalNudge } from "./terminal-poke-io.mjs";

const NUDGE_TIMEOUT_MS = 15_000;

export function seatKey(team, agent) {
  return JSON.stringify([team, agent]);
}

function storagePaths(installRoot, env) {
  return {
    storageDir: env.AGMSG_STORAGE_PATH || join(installRoot, "db"),
    configPath: env.AGMSG_CONFIG || join(homedir(), ".agents", "agmsg", "config.json"),
  };
}

function latestNotifiedCursor(db, seat) {
  const row = db.prepare(`
    SELECT up_to FROM beta_terminal_poke_queue WHERE seat = ? AND state = 'confirmed'
    ORDER BY id DESC LIMIT 1
  `).get(seat);
  return row?.up_to ?? "";
}

function saveSeat(book, { seat, state, reason = "" }) {
  assertPollActive();
  book.set(seat, { state, reason });
}

function setQueueState(db, id, state) {
  assertPollActive();
  withImmediateTransaction(db, () => {
    db.prepare("UPDATE beta_terminal_poke_queue SET state = ? WHERE id = ? AND state = 'pending'").run(state, id);
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
    // An earlier attempt for this seat that never confirmed (the daemon
    // restarted mid-attempt, say) never blocks a new one.
    db.prepare("UPDATE beta_terminal_poke_queue SET state = 'expired' WHERE seat = ? AND state = 'pending'").run(seat);
    const result = db.prepare(`
      INSERT INTO beta_terminal_poke_queue (seat, up_to, state, created_at)
      VALUES (?, ?, 'pending', ?)
    `).run(seat, upTo, new Date(now()).toISOString());
    rowId = Number(result.lastInsertRowid);
  });
  return rowId;
}

// agmsgd withholds a write while the seat is not idle or its pane is
// unreachable; the notice stays pending and is retried next cycle (§10
// class A -- nothing here stops agmsg, it only defers one write). A seat no
// channel can reach at all is shown in status (§10 class D), never silently
// dropped.
function classifyNudgeState(state) {
  if (state === "notified") return { confirm: true, seatState: "notified", reason: "" };
  if (state === "no_pane") return { confirm: false, seatState: "unaddressable", reason: "no_pane" };
  if (state === "pane_gone") return { confirm: false, seatState: "unaddressable", reason: "pane_gone" };
  if (state.startsWith("not_ready:")) return { confirm: false, seatState: "pending", reason: state };
  if (state.startsWith("unknown:")) return { confirm: false, seatState: "pending", reason: state };
  if (state === "busy") return { confirm: false, seatState: "pending", reason: "input_in_progress" };
  if (state === "box_not_found") return { confirm: false, seatState: "pending", reason: "input_box_not_found" };
  if (state === "unreachable") return { confirm: false, seatState: "pending", reason: "terminal_unreachable" };
  if (state === "pane_cannot_receive") return { confirm: false, seatState: "pending", reason: "pane_cannot_receive" };
  if (state === "unsupported") return { confirm: false, seatState: "unaddressable", reason: "driver_unsupported" };
  return { confirm: false, seatState: "pending", reason: `nudge_${state}` };
}

export function createTerminalPokeChannel({
  db,
  installRoot,
  expectedOpGen,
  env = process.env,
  seatDeadlineMs = SEAT_DEADLINE_MS,
  timeoutMs = NUDGE_TIMEOUT_MS,
  now = Date.now,
  log = (message) => logLine(installRoot, message),
  listSeats = listTerminalPokeRegistrations,
  pokeDelivery = (type) => pokeDeliveryEnabled(installRoot, type),
  nudgeText = (type, cmdName) => pokeNudgeText(installRoot, type, cmdName),
  readDriver = readStorageDriver,
  openStore = openMessageStore,
  readSnapshot = readUnreadSnapshot,
  nudge = (args) => runTerminalNudge(args),
  nudgeScriptPath = join(installRoot, "scripts", "internal", "terminal-nudge.sh"),
  cmdName = installRoot.split(/[\\/]/).filter(Boolean).pop() ?? "agmsg",
}) {
  let stopped = false;
  const book = createSeatBook(now);
  let rosterReasons = new Map();
  let activePoll = null;
  let activePollSignal;
  let resumeAfter;

  const seatPoller = createSeatPoller({
    db, book, installRoot, channel: "terminal_poke", log, timeoutMs: seatDeadlineMs,
    saveTimeout: (seat, reason) => saveSeat(book, { seat, state: "pending", reason }),
  });

  async function pollSeat(seat, paths) {
    const { team, agent, type, project } = seat;
    const key = seatKey(team, agent);

    const optedOut = optedOutOfAgmsgd(installRoot, type, project);
    if (optedOut) {
      saveSeat(book, { seat: key, state: "unaddressable", reason: `delivery_chosen_${optedOut}` });
      return;
    }
    if (!pokeDelivery(type)) {
      saveSeat(book, { seat: key, state: "unaddressable", reason: "poke_delivery_opted_out" });
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
    try {
      snapshot = readSnapshot(store, team, agent, latestNotifiedCursor(db, key));
    } catch (error) {
      saveSeat(book, { seat: key, state: "pending", reason: `message_store_unreadable:${error.message}` });
      return;
    } finally {
      try { store.close(); } catch { /* keep the read result */ }
    }

    if (!snapshot.unread || stopped) {
      saveSeat(book, { seat: key, state: "addressable", reason: "" });
      return;
    }

    let id;
    try {
      id = createSendAttempt(db, { seat: key, upTo: snapshot.upTo, expectedOpGen }, now);
    } catch (error) {
      if (error.message !== "daemon_intent_changed") throw error;
      return;
    }

    let result;
    try {
      result = await nudge({
        scriptPath: nudgeScriptPath,
        team,
        agent,
        body: nudgeText(type, cmdName),
        timeoutMs,
        env,
      });
    } catch (error) {
      result = { kind: "failed", reason: `nudge_error:${error?.code ?? error?.message ?? String(error)}` };
    }

    if (result.kind !== "ok") {
      setQueueState(db, id, "expired");
      saveSeat(book, { seat: key, state: "pending", reason: `nudge_${result.kind}:${result.reason ?? "unknown"}` });
      return;
    }

    const classified = classifyNudgeState(result.state);
    if (classified.confirm) {
      setQueueState(db, id, "confirmed");
    } else {
      setQueueState(db, id, "expired");
    }
    saveSeat(book, { seat: key, state: classified.seatState, reason: classified.reason });
  }

  function recordSkippedTeams(skipped) {
    const current = new Map(skipped.map(({ team, reason }) => [team, reason]));
    for (const [team, reason] of current) {
      if (rosterReasons.get(team) === reason) continue;
      log(`channel: terminal-poke roster for team ${team} skipped (${reason})`);
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
      const roster = listSeats(join(installRoot, "teams"), { pokeDeliveryEnabled: pokeDelivery });
      if (roster.state !== "ok") {
        log(`channel: terminal-poke roster unavailable (${roster.reason})`);
        return;
      }
      const paths = storagePaths(installRoot, env);
      recordSkippedTeams(roster.skipped ?? []);
      const seats = [...roster.seats];
      const registeredKeys = new Set(seats.map(({ team, agent }) => seatKey(team, agent)));
      for (const { team } of roster.skipped ?? []) registeredKeys.add(seatKey(team, ""));
      for (const key of book.keys()) {
        if (!registeredKeys.has(key)) {
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
          log(`channel: terminal-poke seat ${seat.team}/${seat.agent} could not be checked (${error.message})`);
        }
      }
      book.pollFinished();
    })().finally(() => { if (activePoll === operation) activePoll = null; });
    activePoll = operation;
    return operation;
  }

  return {
    name: "terminal_poke",
    reportTimeout: seatPoller.reportTimeout,
    seatKind: "terminal_poke",
    seats: () => book.snapshot(),
    pollOnce,
    async stop() {
      stopped = true;
      seatPoller.cancel();
      await activePoll;
    },
  };
}
