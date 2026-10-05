// Polls the existing message stores and nudges registered Claude Code seats
// through their own cross-session-messaging socket. It never writes message
// data or read cursors. Mirrors codex-queue.mjs's shape; see
// memory/design/2026-09-22-agmsgd-arch-8-delivery-driver.md §12/§12.1 and
// memory/design/2026-10-05-cross-session-messaging-socket-measurement.md for
// the measurements this channel's gates come from.
//
// Deliberately simpler than the Codex channel: there is no CLI child process
// to spawn and observe, no bridge, and (per plan, 2026-10-05) no Windows
// support yet — a named-pipe + mandatory-auth-line variant is separate work.

import { homedir } from "node:os";
import { join } from "node:path";
import { logLine } from "../log.mjs";
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
  QUEUE_CONFIRMATION_TTL_MS,
  inboxNudge,
  newNonce,
  observeTranscript,
  resolveTranscriptPath,
  resolvePendingDelivery,
  sendClaudeCodeMessage,
} from "./claude-code-queue-io.mjs";

const SEND_TIMEOUT_MS = 5_000;

function registrationProjects(teamConfig, agent) {
  const registrations = teamConfig?.agents?.[agent]?.registrations;
  return Array.isArray(registrations)
    ? registrations.filter((item) => item?.type === "claude-code").map((item) => item.project).filter((value) => typeof value === "string" && value)
    : [];
}

function readPending(db, seat) {
  return db.prepare(`
    SELECT id, messaging_socket, transcript_path, up_to, nonce, state, created_at
    FROM beta_claude_queue WHERE seat = ? AND state = 'pending' ORDER BY id DESC LIMIT 1
  `).get(seat);
}

function pendingSeats(db) {
  const rows = db.prepare("SELECT DISTINCT seat FROM beta_claude_queue WHERE state = 'pending'").all();
  const seats = [];
  for (const row of rows) {
    try {
      const pair = JSON.parse(row.seat);
      if (!Array.isArray(pair) || pair.length !== 2) continue;
      const [team, agent] = pair;
      const validSegment = (value) => typeof value === "string" && value.length > 0 && value !== "." && value !== ".." &&
        !value.startsWith("-") && !/[\\/\u0000-\u001f\u007f]/.test(value);
      if (validSegment(team) && validSegment(agent)) seats.push({ team, agent });
    } catch { /* malformed historical key cannot safely identify a seat */ }
  }
  return seats;
}

function latestConfirmedCursor(db, seat) {
  const row = db.prepare(`
    SELECT up_to FROM beta_claude_queue WHERE seat = ? AND state = 'confirmed'
    ORDER BY id DESC LIMIT 1
  `).get(seat);
  return row?.up_to ?? "";
}

function saveSeat(db, { seat, messagingSocket = null, state, reason = "" }, now) {
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
  withImmediateTransaction(db, () => {
    db.prepare("UPDATE beta_claude_queue SET state = ? WHERE id = ? AND state = 'pending'").run(state, id);
  });
}

function createPending(db, { seat, messagingSocket, transcriptPath, upTo, nonce, expectedOpGen }, now) {
  let rowId;
  withImmediateTransaction(db, () => {
    const intent = db.prepare("SELECT desired, op_gen FROM daemon_intent").get();
    if (intent?.desired !== "on" || intent.op_gen !== expectedOpGen) {
      throw new Error("daemon_intent_changed");
    }
    const current = db.prepare("SELECT id FROM beta_claude_queue WHERE seat = ? AND state = 'pending'").get(seat);
    if (current) throw new Error("seat_already_pending");
    const result = db.prepare(`
      INSERT INTO beta_claude_queue (seat, messaging_socket, transcript_path, up_to, nonce, state, created_at)
      VALUES (?, ?, ?, ?, ?, 'pending', ?)
    `).run(seat, messagingSocket, transcriptPath, upTo, nonce, new Date(now()).toISOString());
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

async function pendingObservation(pending, now, observe) {
  const createdAt = Date.parse(pending.created_at);
  const ageMs = Number.isFinite(createdAt) ? now() - createdAt : NaN;
  const observation = observe(pending.transcript_path, pending.nonce);
  return resolvePendingDelivery({ observation, ageMs, ttlMs: QUEUE_CONFIRMATION_TTL_MS });
}

export function createClaudeCodeQueueChannel({
  db,
  installRoot,
  expectedOpGen,
  env = process.env,
  timeoutMs = SEND_TIMEOUT_MS,
  now = Date.now,
  log = (message) => logLine(installRoot, message),
  listSeats = listClaudeCodeRegistrations,
  readSession = readClaudeRoleSession,
  readDriver = readStorageDriver,
  openStore = openMessageStore,
  readSnapshot = readUnreadSnapshot,
  send = sendClaudeCodeMessage,
  observe = observeTranscript,
  hostPlatform = process.platform,
}) {
  let stopped = false;
  let activePoll = null;

  async function pollSeat(registration, paths) {
    const { team, agent, teamConfig, registered = true } = registration;
    const seat = seatKey(team, agent);
    const pending = readPending(db, seat);
    if (pending) {
      const observation = await pendingObservation(pending, now, observe);
      if (!registered) {
        if (observation.state === "confirmed") setQueueState(db, pending.id, "confirmed");
        else if (observation.state === "expired") setQueueState(db, pending.id, "expired");
        saveSeat(db, { seat, messagingSocket: pending.messaging_socket, state: "unaddressable", reason: "seat_registration_missing" }, now);
        return;
      }
      if (observation.state === "confirmed") {
        setQueueState(db, pending.id, "confirmed");
        saveSeat(db, { seat, messagingSocket: pending.messaging_socket, state: "addressable" }, now);
        return;
      }
      if (observation.state === "expired") {
        setQueueState(db, pending.id, "expired");
        saveSeat(db, { seat, messagingSocket: pending.messaging_socket, state: "blocked", reason: observation.reason }, now);
        return;
      }
      // Still pending — includes the "held" case: Held is worth surfacing as
      // a status, but it is not a delivery confirmation, so the seat must
      // never be marked notified on it alone.
      saveSeat(db, { seat, messagingSocket: pending.messaging_socket, state: "addressable", reason: observation.reason }, now);
      return;
    }
    if (!registered) return;
    if (hostPlatform === "win32") {
      saveSeat(db, { seat, state: "blocked", reason: "windows_not_supported_yet" }, now);
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
    if (!record.messaging_socket || !record.claude_config_dir || !record.session) {
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
      snapshot = readSnapshot(store, team, agent, latestConfirmedCursor(db, seat));
    } catch (error) {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: `message_store_unreadable:${error.message}` }, now);
      return;
    } finally {
      try { store.close(); } catch { /* keep the read result */ }
    }
    if (!snapshot.unread || stopped) {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "addressable" }, now);
      return;
    }

    const transcriptPath = resolveTranscriptPath(record.claude_config_dir, record.project, record.session);
    if (!transcriptPath) {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: "transcript_path_unresolvable" }, now);
      return;
    }
    const nonce = newNonce();
    let id;
    try {
      id = createPending(db, { seat, messagingSocket: record.messaging_socket, transcriptPath, upTo: snapshot.upTo, nonce, expectedOpGen }, now);
    } catch (error) {
      if (error.message !== "daemon_intent_changed" && error.message !== "seat_already_pending") throw error;
      return;
    }

    const result = await send({ socketPath: record.messaging_socket, nonce, body: inboxNudge(nonce), timeoutMs });
    if (result.state !== "sent") {
      setQueueState(db, id, "expired");
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: `send_failed:${result.reason}` }, now);
      return;
    }
    const firstCheck = await pendingObservation(readPending(db, seat), now, observe);
    if (firstCheck.state === "confirmed") {
      setQueueState(db, id, "confirmed");
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "addressable" }, now);
      return;
    }
    saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "addressable", reason: firstCheck.reason }, now);
  }

  async function pollOnce() {
    if (stopped) return;
    if (activePoll) return activePoll;
    activePoll = (async () => {
      const roster = listSeats(join(installRoot, "teams"));
      if (roster.state !== "ok") {
        log(`channel: Claude Code roster unavailable (${roster.reason})`);
        return;
      }
      const paths = storagePaths(installRoot, env);
      const seats = [...roster.seats];
      const registeredKeys = new Set(seats.map(({ team, agent }) => seatKey(team, agent)));
      const unsettledSeats = pendingSeats(db);
      const pendingKeys = new Set(unsettledSeats.map(({ team, agent }) => seatKey(team, agent)));
      for (const { team, agent } of unsettledSeats) {
        const key = seatKey(team, agent);
        if (!registeredKeys.has(key)) seats.push({ team, agent, teamConfig: null, registered: false });
      }
      const knownKeys = new Set([...registeredKeys, ...pendingKeys]);
      for (const row of db.prepare("SELECT seat FROM beta_claude_seat").all()) {
        if (!knownKeys.has(row.seat)) {
          saveSeat(db, { seat: row.seat, state: "unaddressable", reason: "seat_registration_missing" }, now);
        }
      }
      for (const seat of seats) {
        if (stopped) break;
        try {
          await pollSeat(seat, paths);
        } catch (error) {
          log(`channel: Claude Code seat ${seat.team}/${seat.agent} could not be checked (${error.message})`);
        }
      }
    })().finally(() => { activePoll = null; });
    return activePoll;
  }

  return {
    pollOnce,
    async stop() {
      stopped = true;
      await activePoll;
    },
  };
}
