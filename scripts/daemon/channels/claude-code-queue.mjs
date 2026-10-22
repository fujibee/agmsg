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
  observeTranscript,
  transcriptEndPosition,
  resolveTranscriptPath,
  resolvePendingDelivery,
  sendClaudeCodeMessage,
  latestPermissionMode,
} from "./claude-code-queue-io.mjs";

const SEND_TIMEOUT_MS = 5_000;

// What the seat's Claude Code did with a nudge it set aside. It is not
// "addressable": the message is not reaching the model, so the seat must be
// served some other way (watch.sh checks for this exact reason prefix).
export const PEER_HELD_REASON = "peer_held: the seat's Claude Code is holding messages from agmsgd (see its crossSessionInbound setting and permission mode)";

function observedSeat(reason) {
  return reason === "peer_held"
    ? { state: "blocked", reason: PEER_HELD_REASON }
    : { state: "addressable", reason };
}

function registrationProjects(teamConfig, agent) {
  const registrations = teamConfig?.agents?.[agent]?.registrations;
  return Array.isArray(registrations)
    ? registrations.filter((item) => item?.type === "claude-code").map((item) => item.project).filter((value) => typeof value === "string" && value)
    : [];
}

function readPending(db, seat) {
  return db.prepare(`
    SELECT id, messaging_socket, transcript_path, transcript_pos, up_to, nonce, state, created_at, tried_modes
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

function createPending(db, { seat, messagingSocket, transcriptPath, transcriptPos, upTo, nonce, triedModes, expectedOpGen }, now) {
  let rowId;
  withImmediateTransaction(db, () => {
    const intent = db.prepare("SELECT desired, op_gen FROM daemon_intent").get();
    if (intent?.desired !== "on" || intent.op_gen !== expectedOpGen) {
      throw new Error("daemon_intent_changed");
    }
    const current = db.prepare("SELECT id FROM beta_claude_queue WHERE seat = ? AND state = 'pending'").get(seat);
    if (current) throw new Error("seat_already_pending");
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

function pendingObservation(pending, observe) {
  return resolvePendingDelivery({ observation: observe(pending.transcript_path, pending.nonce, pending.transcript_pos) });
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
  socketAlive = checkSocketOwnership,
  hostPlatform = process.platform,
  readMode = latestPermissionMode,
  transcriptPathOf = resolveTranscriptPath,
}) {
  let stopped = false;
  // Sockets a nudge found gone when it connected. A named pipe cannot be
  // checked beforehand, so without this each poll would add a queue row that
  // fails at once until the seat records another pipe.
  const goneSockets = new Set();
  let activePoll = null;

  async function pollSeat(registration, paths) {
    const { team, agent, teamConfig, registered = true } = registration;
    const seat = seatKey(team, agent);
    const pending = readPending(db, seat);
    // A project that chose something other than agmsgd gets no nudges, including
    // a re-send of one already waiting.
    const chosen = readSession(join(installRoot, "run"), team, agent);
    const optedOut = chosen.state === "present" && chosen.record.type === "claude-code"
      ? optedOutOfAgmsgd(installRoot, "claude-code", chosen.record.project)
      : "";
    if (optedOut) {
      if (pending) setQueueState(db, pending.id, "expired");
      saveSeat(db, { seat, messagingSocket: chosen.record.messaging_socket, state: "unaddressable", reason: `delivery_chosen_${optedOut}` }, now);
      return;
    }
    let retryMode = "";
    let carriedModes = [];
    // At most one nudge is outstanding per seat, and an outstanding one is not
    // re-sent on a timer: Claude Code holds a message received mid-work until
    // the work pauses, so a long wait is normal, not a loss. It is re-sent only
    // when the thing it was sent to is gone, or when the seat set it aside and
    // the other way of sending has not been tried (see below).
    if (pending) {
      const observation = pendingObservation(pending, observe);
      if (observation.state === "confirmed") {
        setQueueState(db, pending.id, "confirmed");
        saveSeat(db, { seat, messagingSocket: pending.messaging_socket, state: "addressable" }, now);
        return;
      }
      if (!registered) {
        setQueueState(db, pending.id, "expired");
        saveSeat(db, { seat, messagingSocket: pending.messaging_socket, state: "unaddressable", reason: "seat_registration_missing" }, now);
        return;
      }
      const session = readSession(join(installRoot, "run"), team, agent);
      const record = session.state === "present" ? session.record : null;
      const transcriptNow = record
        ? transcriptPathOf(record.claude_config_dir, record.project, record.session, hostPlatform)
        : "";
      // The nudge is out of date when its socket is gone, or the seat's record
      // now names another socket or session (/compact, restart, --resume).
      // Nothing else makes it stale: not the time that has passed.
      // Only a socket that is plainly absent counts as gone. A check that merely
      // could not run (stat failed, wrong owner) proves nothing about the nudge
      // the seat still holds, and sending another would duplicate it.
      const socketCheck = socketAlive(pending.messaging_socket);
      const socketGone = socketCheck.reason === "messaging_socket_missing";
      const recordMoved = record && (
        record.messaging_socket !== pending.messaging_socket ||
        (transcriptNow && transcriptNow !== pending.transcript_path));
      if (!socketGone && !recordMoved && observation.reason === "peer_held" && socketCheck.state === "ok") {
        // The seat's Claude Code set the nudge aside. Whatever mode it was sent
        // under is not accepted there (a bypass seat wants its mode named, a
        // prompting one wants none), so it is sent once the other way.
        // The ways tried are kept on the nudge's own row, so a daemon restart
        // does not give a held nudge a fresh budget.
        const tried = pending.tried_modes ? pending.tried_modes.split(",") : [];
        const other = tried[tried.length - 1] === "bypass" ? "plain" : "bypass";
        if (!tried.includes(other)) {
          retryMode = other;
          carriedModes = tried;
          setQueueState(db, pending.id, "expired");
        }
      }
      if (retryMode === "") {
        if (!socketGone && !recordMoved) {
          saveSeat(db, { seat, messagingSocket: pending.messaging_socket, ...observedSeat(socketCheck.state === "ok" ? observation.reason : socketCheck.reason) }, now);
          return;
        }
        setQueueState(db, pending.id, "expired");
      }
    }
    if (!registered) return;
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

    const transcriptPath = transcriptPathOf(record.claude_config_dir, record.project, record.session, hostPlatform);
    if (!transcriptPath) {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: "transcript_path_unresolvable" }, now);
      return;
    }
    // A record whose socket no longer exists (the seat is restarting and has
    // not written its new one yet) has nowhere to be nudged. Make no queue
    // row for it: each poll would add one that expires at once. Once the seat
    // records a socket that exists, this passes and the nudge goes out.
    if (socketAlive(record.messaging_socket).reason === "messaging_socket_missing" || goneSockets.has(record.messaging_socket)) {
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "unaddressable", reason: "messaging_socket_missing" }, now);
      return;
    }
    // Say bypass only for a seat whose conversation is in bypass mode (or, after
    // a hold, once as the one other try); every other seat gets no claim.
    const mode = retryMode || (readMode(transcriptPath) === "bypassPermissions" ? "bypass" : "plain");
    const nonce = newNonce();
    let id;
    try {
      id = createPending(db, { seat, messagingSocket: record.messaging_socket, transcriptPath, transcriptPos: transcriptEndPosition(transcriptPath), upTo: snapshot.upTo, nonce, triedModes: [...carriedModes, mode], expectedOpGen }, now);
    } catch (error) {
      if (error.message !== "daemon_intent_changed" && error.message !== "seat_already_pending") throw error;
      return;
    }

    const result = await send({ socketPath: record.messaging_socket, nonce, body: inboxNudge(nonce), token: record.messaging_token, fromMode: mode === "bypass" ? "bypass" : "", timeoutMs });
    if (result.state !== "sent") {
      setQueueState(db, id, "expired");
      if (result.reason === "socket_error:ENOENT") {
        goneSockets.add(record.messaging_socket);
        saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "unaddressable", reason: "messaging_socket_missing" }, now);
        return;
      }
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "blocked", reason: `send_failed:${result.reason}` }, now);
      return;
    }
    const firstCheck = pendingObservation(readPending(db, seat), observe);
    if (firstCheck.state === "confirmed") {
      setQueueState(db, id, "confirmed");
      saveSeat(db, { seat, messagingSocket: record.messaging_socket, state: "addressable" }, now);
      return;
    }
    saveSeat(db, { seat, messagingSocket: record.messaging_socket, ...observedSeat(firstCheck.reason) }, now);
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
