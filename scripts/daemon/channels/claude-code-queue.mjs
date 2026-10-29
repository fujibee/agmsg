// Polls the existing message stores and nudges registered Claude Code seats
// through their own cross-session-messaging socket. It never writes message
// data or read cursors. Mirrors codex-queue.mjs's shape; see
// memory/design/2026-09-22-agmsgd-arch-8-delivery-driver.md §12/§12.1 and
// memory/design/2026-10-05-cross-session-messaging-socket-measurement.md for
// the measurements this channel's gates come from.
//
// No CLI child process or transcript confirmation is needed: a completed
// socket write advances this seat's notification cursor.

import { assertPollActive, pollSignal, SEAT_DEADLINE_MS } from '../poll-deadline.mjs';
import { createSeatPoller } from '../seat-poll.mjs';
import { homedir } from "node:os";
import { join } from "node:path";
import { logLine } from "../log.mjs";
import { optedOutOfAgmsgd } from "./delivery-choice.mjs";
import { withImmediateTransaction } from "../db.mjs";
import {
  messageStorePath,
  openMessageStore,
  readStorageDriver,
  readUnreadSnapshot,
} from "./codex-queue-store.mjs";
import { sameProject, seatKey } from "./codex-queue.mjs";
import {
  listClaudeCodeRegistrations,
  readClaudeRoleSession,
} from "./claude-code-queue-store.mjs";
import {
  checkSocketOwnership,
  inboxNudge,
  newNonce,
  resolveTranscriptPath,
  sendClaudeCodeMessage,
  latestPermissionMode,
} from "./claude-code-queue-io.mjs";

const SEND_TIMEOUT_MS = 5_000;

function registrationProjects(teamConfig, agent) {
  const registrations = teamConfig?.agents?.[agent]?.registrations;
  return Array.isArray(registrations)
    ? registrations.filter((item) => item?.type === "claude-code").map((item) => item.project).filter((value) => typeof value === "string" && value)
    : [];
}

// Keep the existing schema enum: confirmed now means the socket write completed.
function latestNotifiedCursor(db, seat) {
  const row = db.prepare(`
    SELECT up_to FROM beta_claude_queue WHERE seat = ? AND state = 'confirmed'
    ORDER BY id DESC LIMIT 1
  `).get(seat);
  return row?.up_to ?? "";
}

function saveSeat(db, { seat, messagingSocket = null, state, reason = "" }, now) {
  assertPollActive();
  withImmediateTransaction(db, () => {
    db.prepare(`
      INSERT INTO beta_claude_seat (seat, messaging_socket, state, reason, checked_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(seat) DO UPDATE SET messaging_socket=COALESCE(excluded.messaging_socket, beta_claude_seat.messaging_socket),
        state=excluded.state, reason=excluded.reason, checked_at=excluded.checked_at
    `).run(seat, messagingSocket, state, reason, new Date(now()).toISOString());
  });
}

function setQueueState(db, id, state) {
  assertPollActive();
  withImmediateTransaction(db, () => {
    db.prepare("UPDATE beta_claude_queue SET state = ? WHERE id = ? AND state = 'pending'").run(state, id);
  });
}

function createSendAttempt(db, { seat, messagingSocket, transcriptPath, transcriptPos, upTo, nonce, triedModes, expectedOpGen }, now) {
  assertPollActive();
  let rowId;
  withImmediateTransaction(db, () => {
    const intent = db.prepare("SELECT desired, op_gen FROM daemon_intent").get();
    if (intent?.desired !== "on" || intent.op_gen !== expectedOpGen) {
      throw new Error("daemon_intent_changed");
    }
    // Old confirmation-gated rows never block a new attempt after upgrade.
    db.prepare("UPDATE beta_claude_queue SET state = 'expired' WHERE seat = ? AND state = 'pending'").run(seat);
    const result = db.prepare(`
      INSERT INTO beta_claude_queue (seat, messaging_socket, transcript_path, transcript_pos, up_to, nonce, state, created_at, tried_modes)
      VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)
    `).run(seat, messagingSocket, transcriptPath, transcriptPos, upTo, nonce, new Date(now()).toISOString(), triedModes.join(","));
    rowId = Number(result.lastInsertRowid);
  });
  return rowId;
}

function storagePaths(installRoot, env) {
  return {
    storageDir: env.AGMSG_STORAGE_PATH || join(installRoot, "db"),
    configPath: env.AGMSG_CONFIG || join(homedir(), ".agents", "agmsg", "config.json"),
  };
}

export function createClaudeCodeQueueChannel({
  db,
  installRoot,
  expectedOpGen,
  env = process.env,
  seatDeadlineMs = SEAT_DEADLINE_MS,
  timeoutMs = SEND_TIMEOUT_MS,
  now = Date.now,
  log = (message) => logLine(installRoot, message),
  listSeats = listClaudeCodeRegistrations,
  readSession = readClaudeRoleSession,
  readDriver = readStorageDriver,
  openStore = openMessageStore,
  readSnapshot = readUnreadSnapshot,
  send = sendClaudeCodeMessage,
  socketAlive = checkSocketOwnership,
  hostPlatform = process.platform,
  readMode = latestPermissionMode,
  transcriptPathOf = resolveTranscriptPath,
}) {
  let stopped = false;
  let rosterReasons = new Map();
  let activePoll = null;
  let activePollSignal;
  let resumeAfter;
  const seatPoller = createSeatPoller({
    db, installRoot, channel: 'claude-code', log, timeoutMs: seatDeadlineMs,
    saveTimeout: (seat, reason) => saveSeat(db, { seat, state: 'blocked', reason }, now),
  });

  async function pollSeat(registration, paths) {
    const { team, agent, teamConfig } = registration;
    const seat = seatKey(team, agent);
    // A project that chose something other than agmsgd gets no nudges.
    const chosen = readSession(join(installRoot, "run"), team, agent);
    const optedOut = chosen.state === "present" && chosen.record.type === "claude-code"
      ? optedOutOfAgmsgd(installRoot, "claude-code", chosen.record.project)
      : "";
    if (optedOut) {
      saveSeat(db, { seat, messagingSocket: chosen.record.messaging_socket, state: "unaddressable", reason: `delivery_chosen_${optedOut}` }, now);
      return;
    }
    const session = readSession(join(installRoot, "run"), team, agent);
    if (session.state !== "present") {
      saveSeat(db, { seat, state: "unaddressable", reason: session.reason ?? "role_session_missing" }, now);
      return;
    }
    const record = session.record;
    if (record.team !== team || record.agent !== agent) {
      saveSeat(db, { seat, state: "blocked", reason: "role_session_identity_mismatch" }, now);
      return;
    }
    if (record.type !== "claude-code") {
      saveSeat(db, { seat, state: "blocked", reason: "role_session_type_mismatch" }, now);
      return;
    }
    if (record.messaging_blocked) {
      saveSeat(db, { seat, state: "unaddressable", reason: record.messaging_blocked }, now);
      return;
    }
    if (!record.messaging_socket) {
      saveSeat(db, { seat, state: "unaddressable", reason: "messaging_destination_missing" }, now);
      return;
    }
    const registeredProjects = registrationProjects(teamConfig, agent);
    if (registeredProjects.length === 0 || !registeredProjects.some((project) => sameProject(project, record.project))) {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: "role_session_project_mismatch" }, now);
      return;
    }
    let driver;
    try {
      driver = readDriver(paths.configPath);
    } catch (error) {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: `storage_config_unreadable:${error.message}` }, now);
      return;
    }
    if (driver.state !== "ok") {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: driver.reason }, now);
      return;
    }
    if (driver.driver !== "sqlite") {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: "storage_driver_unsupported" }, now);
      return;
    }
    let storePath;
    try {
      storePath = messageStorePath({ storageDir: paths.storageDir, team, teamConfig });
    } catch (error) {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: `message_store_path_unreadable:${error.message}` }, now);
      return;
    }
    let store;
    try {
      store = openStore(storePath);
    } catch (error) {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: `message_store_unreadable:${error.message}` }, now);
      return;
    }
    let snapshot;
    try {
      snapshot = readSnapshot(store, team, agent, latestNotifiedCursor(db, seat));
    } catch (error) {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: `message_store_unreadable:${error.message}` }, now);
      return;
    } finally {
      try { store.close(); } catch { /* keep the read result */ }
    }
    // Check every poll, including idle seats. A socket recreated at the same
    // path is eligible immediately; there is no persistent absence cache.
    const socketCheck = socketAlive(record.messaging_socket);
    if (socketCheck.reason === "messaging_socket_missing") {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "unaddressable", reason: "messaging_socket_missing" }, now);
      return;
    }
    if (socketCheck.state !== "ok") {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: socketCheck.reason ?? "messaging_socket_unreadable" }, now);
      return;
    }
    if (!snapshot.unread || stopped) {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "addressable" }, now);
      return;
    }

    // Preserve the existing wire-mode hint, but never wait for or require a
    // transcript. This bounded best-effort read is not delivery confirmation.
    let mode = "plain";
    let transcriptPath = "";
    try {
      if (record.claude_config_dir && record.session) {
        transcriptPath = transcriptPathOf(record.claude_config_dir, record.project, record.session, hostPlatform) || "";
        if (transcriptPath && readMode(transcriptPath) === "bypassPermissions") mode = "bypass";
      }
    } catch { /* unavailable mode metadata must not prevent a socket send */ }
    const nonce = newNonce();
    let id;
    try {
      id = createSendAttempt(db, { seat, messagingSocket: record.messaging_socket, transcriptPath, transcriptPos: null, upTo: snapshot.upTo, nonce, triedModes: [mode], expectedOpGen }, now);
    } catch (error) {
      if (error.message !== "daemon_intent_changed") throw error;
      return;
    }

    let result;
    try {
      result = await send({ socketPath: record.messaging_socket, nonce, body: inboxNudge(nonce, { installRoot, team, agent }), token: record.messaging_token, fromMode: mode === "bypass" ? "bypass" : "", timeoutMs });
    } catch (error) {
      result = { state: "failed", reason: `send_error:${error?.code ?? error?.message ?? String(error)}` };
    }
    if (result.state !== "sent") {
      setQueueState(db, id, "expired");
      if (result.reason === "socket_error:ENOENT" || result.reason === "messaging_socket_missing") {
        saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "unaddressable", reason: "messaging_socket_missing" }, now);
      } else {
        saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: `send_failed:${result.reason}` }, now);
      }
      return;
    }
    // A completed socket write is delivery. Keep the snapshot cursor on the
    // existing confirmed row; neither inbox reads nor transcript evidence gate
    // later nudges for unread messages beyond that cursor.
    setQueueState(db, id, "confirmed");
    saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "addressable" }, now);
  }

  // A team whose roster entry is unusable is skipped alone. Its reason is kept
  // as a team-level row (agent "") so `agmsg daemon status` shows it, and logged
  // only when it first appears or changes.
  function recordSkippedTeams(skipped) {
    const current = new Map(skipped.map(({ team, reason }) => [team, reason]));
    for (const [team, reason] of current) {
      if (rosterReasons.get(team) === reason) continue;
      log(`channel: Claude Code roster for team ${team} skipped (${reason})`);
      saveSeat(db, { seat: seatKey(team, ""), state: "unaddressable", reason }, now);
    }
    // Compare against the stored rows, not only this process's memory: a row
    // written before a restart must go once its team is readable again.
    for (const { seat } of db.prepare("SELECT seat FROM beta_claude_seat").all()) {
      let parsed;
      try { parsed = JSON.parse(seat); } catch { continue; }
      if (Array.isArray(parsed) && parsed[1] === "" && !current.has(parsed[0])) {
        assertPollActive();
        withImmediateTransaction(db, () => db.prepare("DELETE FROM beta_claude_seat WHERE seat = ?").run(seat));
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
        log(`channel: Claude Code roster unavailable (${roster.reason})`);
        return;
      }
      const paths = storagePaths(installRoot, env);
      recordSkippedTeams(roster.skipped ?? []);
      const seats = [...roster.seats];
      const registeredKeys = new Set(seats.map(({ team, agent }) => seatKey(team, agent)));
      for (const { team } of roster.skipped ?? []) registeredKeys.add(seatKey(team, ""));
      for (const row of db.prepare("SELECT seat FROM beta_claude_seat").all()) {
        if (!registeredKeys.has(row.seat)) {
          seatPoller.changeState(row.seat, () => saveSeat(db, { seat: row.seat, state: "unaddressable", reason: "seat_registration_missing" }, now));
        }
      }
      // Continue after an interrupted seat so repeated cycle deadlines cannot
      // starve the tail of a large roster.
      const start = seats.findIndex(seat => seatKey(seat.team, seat.agent) === resumeAfter) + 1;
      const ordered = [...seats.slice(start), ...seats.slice(0, start)];
      for (const seat of ordered) {
        if (stopped || pollSignal()?.aborted || signal?.aborted) break;
        resumeAfter = seatKey(seat.team, seat.agent);
        try {
          await seatPoller.poll(seat, () => pollSeat(seat, paths));
        } catch (error) {
          if (pollSignal()?.aborted || signal?.aborted) break;
          log(`channel: Claude Code seat ${seat.team}/${seat.agent} could not be checked (${error.message})`);
        }
      }
    })().finally(() => { if (activePoll === operation) activePoll = null; });
    activePoll = operation;
    return operation;
  }

  return {
    name: 'claude-code',
    reportTimeout: seatPoller.reportTimeout,
    pollOnce,
    async stop() {
      stopped = true;
      seatPoller.cancel();
      await activePoll;
    },
  };
}
