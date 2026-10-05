// Polls the existing message stores and nudges registered Codex seats through
// the local Codex queue. It never writes message data or read cursors.

import { createHash } from "node:crypto";
import { homedir, hostname } from "node:os";
import { isAbsolute, join, resolve, sep } from "node:path";
import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { logLine } from "../log.mjs";
import { withImmediateTransaction } from "../db.mjs";
import {
  listCodexRegistrations,
  messageStorePath,
  openMessageStore,
  readRoleSession,
  readStorageDriver,
  readUnreadSnapshot,
} from "./codex-queue-store.mjs";
import {
  classifyCodexSeat,
  inboxNudge,
  newNonce,
  readQueuedItem,
  readRolloutNonce,
  resolvePendingQueue,
  runCodexQueue,
} from "./codex-queue-io.mjs";
import { captureProcessGroup, observeProcessGroup } from "./process-group.mjs";
import { processStartWitness } from "./process-group.mjs";
import { checkWindowsCodexQueueGate } from "./windows-codex-queue.mjs";

const QUEUE_TIMEOUT_MS = 10_000;

export function seatKey(team, agent) {
  return JSON.stringify([team, agent]);
}

export function sameProject(left, right) {
  if (typeof left !== "string" || !left || typeof right !== "string" || !right) return false;
  if (!isAbsolute(left) || !isAbsolute(right)) return false;
  const normalize = (value) => {
    let candidate = value;
    if (process.platform === "win32") {
      candidate = candidate.replace(/\\/g, "/");
      const gitBash = candidate.match(/^\/([A-Za-z])(?:\/(.*))?$/);
      if (gitBash) candidate = `${gitBash[1]}:/${gitBash[2] ?? ""}`;
      candidate = candidate.replace(/^([a-z]):/, (_, drive) => `${drive.toUpperCase()}:`);
    }
    let result = resolve(candidate).split(sep).join("/");
    if (process.platform === "win32") result = result.toLowerCase();
    return result;
  };
  const a = normalize(left);
  const b = normalize(right);
  return a === b;
}

function registrationProjects(teamConfig, agent) {
  const registrations = teamConfig?.agents?.[agent]?.registrations;
  return Array.isArray(registrations)
    ? registrations.filter((item) => item?.type === "codex").map((item) => item.project).filter((value) => typeof value === "string" && value)
    : [];
}

function readPending(db, seat) {
  return db.prepare(`
    SELECT id, codex_home, thread, up_to, nonce, queue_item_id, state, children, created_at
    FROM beta_codex_queue WHERE seat = ? AND state = 'pending' ORDER BY id DESC LIMIT 1
  `).get(seat);
}

function pendingSeats(db) {
  const rows = db.prepare("SELECT DISTINCT seat FROM beta_codex_queue WHERE state = 'pending'").all();
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
    SELECT up_to FROM beta_codex_queue WHERE seat = ? AND state = 'confirmed'
    ORDER BY id DESC LIMIT 1
  `).get(seat);
  return row?.up_to ?? "";
}

function saveSeat(db, { seat, thread = null, codexHome = null, state, reason = "" }, now) {
  withImmediateTransaction(db, () => {
    db.prepare(`
      INSERT INTO beta_codex_seat (seat, thread, codex_home, state, reason, checked_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(seat) DO UPDATE SET thread=COALESCE(excluded.thread, beta_codex_seat.thread),
        codex_home=COALESCE(excluded.codex_home, beta_codex_seat.codex_home),
        state=excluded.state, reason=excluded.reason, checked_at=excluded.checked_at
    `).run(seat, thread, codexHome, state, reason, new Date(now()).toISOString());
  });
}

function setQueueState(db, id, state, queueItemId = undefined) {
  withImmediateTransaction(db, () => {
    if (queueItemId === undefined) {
      db.prepare("UPDATE beta_codex_queue SET state = ? WHERE id = ? AND state = 'pending'").run(state, id);
    } else {
      db.prepare("UPDATE beta_codex_queue SET state = ?, queue_item_id = ? WHERE id = ? AND state = 'pending'")
        .run(state, queueItemId, id);
    }
  });
}

function recordChildStart(db, id, pid, captureGroup) {
  let group;
  try {
    group = captureGroup(pid);
  } catch {
    group = { state: "unreadable", reason: "child_start_witness_unavailable" };
  }
  withImmediateTransaction(db, () => {
    db.prepare("UPDATE beta_codex_queue SET children = ? WHERE id = ? AND state = 'pending'")
      .run(JSON.stringify(group), id);
  });
}

function recordChildResult(db, id, result) {
  withImmediateTransaction(db, () => {
    const row = db.prepare("SELECT children FROM beta_codex_queue WHERE id = ? AND state = 'pending'").get(id);
    if (!row) return;
    let children;
    try { children = JSON.parse(row.children); } catch { children = { state: "unreadable", reason: "child_group_record_malformed" }; }
    if (children.state === "incomplete" && result.kind === "failed" && result.reason?.startsWith("spawn_failed:")) {
      children = { state: "absent", kind: result.kind };
    } else {
      children.result = result.kind;
    }
    db.prepare("UPDATE beta_codex_queue SET children = ? WHERE id = ? AND state = 'pending'")
      .run(JSON.stringify(children), id);
  });
}

function createPending(db, { seat, codexHome, thread, upTo, nonce, expectedOpGen }, now) {
  let rowId;
  withImmediateTransaction(db, () => {
    const intent = db.prepare("SELECT desired, op_gen FROM daemon_intent").get();
    if (intent?.desired !== "on" || intent.op_gen !== expectedOpGen) {
      throw new Error("daemon_intent_changed");
    }
    const current = db.prepare("SELECT id FROM beta_codex_queue WHERE seat = ? AND state = 'pending'").get(seat);
    if (current) throw new Error("seat_already_pending");
    const result = db.prepare(`
      INSERT INTO beta_codex_queue (seat, codex_home, thread, up_to, nonce, queue_item_id, state, children, created_at)
      VALUES (?, ?, ?, ?, ?, NULL, 'pending', 'incomplete', ?)
    `).run(seat, codexHome, thread, upTo, nonce, new Date(now()).toISOString());
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

function bridgeState(runDir, team, agent, projects) {
  let files;
  try {
    files = readdirSync(runDir).filter((name) => name.startsWith("codex-bridge.") && name.endsWith(".pid"));
  } catch (error) {
    if (error?.code === "ENOENT") return "stopped";
    return "unknown";
  }
    const identity = `${team}/${agent}`;
  for (const pidName of files) {
    const pidPath = join(runDir, pidName);
    const metaPath = `${pidPath.slice(0, -4)}.meta`;
    let pidText;
    let metaText;
    try {
      const pidStat = lstatSync(pidPath);
      if (!pidStat.isFile() || pidStat.isSymbolicLink()) return "unknown";
      const metaStat = lstatSync(metaPath);
      if (!metaStat.isFile() || metaStat.isSymbolicLink()) return "unknown";
      pidText = readFileSync(pidPath, "utf8").trim();
      metaText = readFileSync(metaPath, "utf8");
    } catch {
      return "unknown";
    }
    const fields = Object.create(null);
    for (const line of metaText.split(/\r?\n/)) {
      const at = line.indexOf("=");
      if (at > 0 && !(line.slice(0, at) in fields)) fields[line.slice(0, at)] = line.slice(at + 1);
    }
    if (!fields.identities) return "unknown";
    if (!fields.identities.split(",").includes(identity) || fields.type !== "codex") continue;
    if (!/^\d+$/.test(pidText) || fields.pid !== pidText) return "unknown";
    if (!projects.some((project) => sameProject(project, fields.project))) return "unknown";
    // A live PID alone can be a recycled process. Require the bridge's own
    // per-PID lease, matching its recorded pair/project set and start token.
    const leasePath = join(runDir, `codex-bridge-lease.${pidText}`);
    let leaseText;
    try {
      const leaseStat = lstatSync(leasePath);
      if (!leaseStat.isFile() || leaseStat.isSymbolicLink()) return "unknown";
      leaseText = readFileSync(leasePath, "utf8");
    } catch {
      return "unknown";
    }
    const lease = Object.create(null);
    for (const line of leaseText.split(/\r?\n/)) {
      const at = line.indexOf("=");
      if (at > 0 && !(line.slice(0, at) in lease)) lease[line.slice(0, at)] = line.slice(at + 1);
      else if (at > 0) return "unknown";
    }
    const leaseKeys = Object.keys(lease).sort().join(",");
    if (leaseKeys !== "host,pairs,pid,project,start,startsrc,v") return "unknown";
    const pairHashes = fields.identities.split(",").map((pair) => createHash("sha1").update(pair.replace("/", "\t")).digest("hex")).sort();
    const expectedPairs = createHash("sha1").update(pairHashes.join("\n")).digest("hex");
    const expectedProject = createHash("sha1").update(fields.project).digest("hex");
    if (lease.v !== "1" || lease.pid !== pidText || lease.project !== expectedProject || lease.pairs !== expectedPairs || lease.host !== hostname() || !lease.start) return "unknown";
    const startPrefix = lease.startsrc === "proc" ? "linux" : lease.startsrc === "ps" ? "darwin" : lease.startsrc === "pwsh" ? "windows" : "";
    if (!startPrefix || processStartWitness(Number(pidText)) !== `${startPrefix}:${lease.start}`) return "unknown";
    try {
      process.kill(Number(pidText), 0);
      return "running";
    } catch (error) {
      if (error?.code === "ESRCH") continue;
      if (error?.code === "EPERM") return "running";
      return "unknown";
    }
  }
  return "stopped";
}

// This is intentionally fail-closed. A pending reservation left by a daemon
// crash before the child result was recorded cannot safely be retried here.
async function pendingObservation(pending, now, observeGroup) {
  let children;
  try { children = JSON.parse(pending.children); } catch { return { state: "pending", reason: "child_group_record_unreadable" }; }
  if (children.state === "incomplete") return { state: "pending", reason: "queue_child_state_incomplete", childrenUnresolved: true };
  if (children.state === "complete") {
    let group;
    try { group = observeGroup(children); } catch { group = { state: "unreadable", reason: "child_group_observation_failed" }; }
    if (group?.state !== "absent") return { state: "pending", reason: group?.reason ?? "queue_child_still_running", childrenUnresolved: true };
  } else if (children.state !== "absent") {
    return { state: "pending", reason: children.reason ?? "child_group_record_unreadable", childrenUnresolved: true };
  }
  const createdAt = Date.parse(pending.created_at);
  const ageMs = Number.isFinite(createdAt) ? now() - createdAt : NaN;
  const queueObservation = pending.queue_item_id
    ? readQueuedItem(pending.codex_home, pending.queue_item_id, pending.thread)
    : { state: "absent" };
  return readRolloutNonce(pending.codex_home, pending.thread, pending.nonce).then((rolloutObservation) =>
    resolvePendingQueue({ queueObservation, rolloutObservation, ageMs }));
}

export function createCodexQueueChannel({
  db,
  installRoot,
  expectedOpGen,
  env = process.env,
  executable = "codex",
  timeoutMs = QUEUE_TIMEOUT_MS,
  now = Date.now,
  log = (message) => logLine(installRoot, message),
  listSeats = listCodexRegistrations,
  readSession = readRoleSession,
  readDriver = readStorageDriver,
  openStore = openMessageStore,
  readSnapshot = readUnreadSnapshot,
  queue = runCodexQueue,
  captureGroup = captureProcessGroup,
  observeGroup = observeProcessGroup,
  hostPlatform = process.platform,
  windowsGate = checkWindowsCodexQueueGate,
}) {
  let stopped = false;
  let activeController = null;
  let activePoll = null;

  async function pollSeat(registration, paths, blockedCodexHomes) {
    const { team, agent, teamConfig, registered = true } = registration;
    const seat = seatKey(team, agent);
    const registeredProjects = registrationProjects(teamConfig, agent);
    const bridge = bridgeState(join(installRoot, "run"), team, agent, registeredProjects);
    const pending = readPending(db, seat);
    if (pending) {
      const observation = await pendingObservation(pending, now, observeGroup);
      if (observation.childrenUnresolved && pending.codex_home) blockedCodexHomes.add(pending.codex_home);
      if (!registered) {
        if (observation.state === "confirmed") setQueueState(db, pending.id, "confirmed");
        else if (observation.state === "expired") setQueueState(db, pending.id, "expired");
        saveSeat(db, { seat, thread: pending.thread, codexHome: pending.codex_home, state: "unaddressable", reason: "seat_registration_missing" }, now);
        return;
      }
      if (hostPlatform === "win32") {
        const gate = windowsGate({ executable, env });
        if (gate.state !== "ok") {
          if (observation.state === "confirmed") setQueueState(db, pending.id, "confirmed");
          else if (observation.state === "expired") setQueueState(db, pending.id, "expired");
          const reason = observation.state === "pending"
            ? `${gate.reason};pending:${observation.reason}`
            : gate.reason;
          saveSeat(db, { seat, thread: pending.thread, codexHome: pending.codex_home, state: "blocked", reason }, now);
          return;
        }
      }
      if (observation.state === "confirmed") {
        setQueueState(db, pending.id, "confirmed");
        const knownBridge = bridge === "stopped" || bridge === "running";
        saveSeat(db, { seat, thread: pending.thread, codexHome: pending.codex_home, state: !knownBridge ? "blocked" : bridge === "running" ? "bridged" : "addressable", reason: !knownBridge ? "bridge_state_unknown" : bridge === "running" ? "bridge_running" : "" }, now);
        return;
      } else if (observation.state === "expired") {
        setQueueState(db, pending.id, "expired");
      } else {
        const knownBridge = bridge === "stopped" || bridge === "running";
        saveSeat(db, {
          seat,
          thread: pending.thread,
          codexHome: pending.codex_home,
          state: !knownBridge ? "blocked" : bridge === "running" ? "bridged" : "addressable",
          reason: !knownBridge ? `bridge_state_unknown;pending:${observation.reason}` : bridge === "running" ? `bridge_running;pending:${observation.reason}` : observation.reason,
        }, now);
        return;
      }
    }
    if (!registered) return;
    if (bridge !== "stopped" && bridge !== "running") {
      saveSeat(db, { seat, state: "blocked", reason: "bridge_state_unknown" }, now);
      return;
    }
    if (bridge === "running") {
      saveSeat(db, { seat, state: "bridged", reason: "bridge_running" }, now);
      return;
    }
    const session = readSession(join(installRoot, "run"), team, agent);
    if (session.state !== "present") {
      saveSeat(db, { seat, state: "unaddressable", reason: session.reason ?? "role_session_missing" }, now);
      return;
    }
    const record = session.record;
    if (record.team !== team || record.agent !== agent) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason: "role_session_identity_mismatch" }, now);
      return;
    }
    if (record.type !== "codex") {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason: "role_session_type_mismatch" }, now);
      return;
    }
    let queueExecutable = executable;
    if (hostPlatform === "win32") {
      const gate = windowsGate({ executable, env });
      if (gate.state !== "ok") {
        saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason: gate.reason }, now);
        return;
      }
      queueExecutable = gate.executable;
    }
    let driver;
    try {
      driver = readDriver(paths.configPath);
    } catch (error) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason: `storage_config_unreadable:${error.message}` }, now);
      return;
    }
    if (driver.state !== "ok") {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason: driver.reason }, now);
      return;
    }
    if (driver.driver !== "sqlite") {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason: "storage_driver_unsupported" }, now);
      return;
    }
    const projects = registeredProjects;
    if (projects.length === 0 || !projects.some((project) => sameProject(project, record.project))) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason: "role_session_project_mismatch" }, now);
      return;
    }
    let storePath;
    try {
      storePath = messageStorePath({ storageDir: paths.storageDir, team, teamConfig });
    } catch (error) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason: `message_store_path_unreadable:${error.message}` }, now);
      return;
    }
    let store;
    try {
      store = openStore(storePath);
    } catch (error) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason: `message_store_unreadable:${error.message}` }, now);
      return;
    }

    let snapshot;
    try {
      snapshot = readSnapshot(store, team, agent, latestConfirmedCursor(db, seat));
    } catch (error) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason: `message_store_unreadable:${error.message}` }, now);
      return;
    } finally {
      try { store.close(); } catch { /* keep the read result */ }
    }

    const nonce = newNonce();
    const rollout = await readRolloutNonce(record.codex_home, record.thread, nonce);
    const classification = classifyCodexSeat({ roleSession: record, bridgeState: "stopped", rolloutState: rollout.state === "absent" || rollout.state === "present" ? "valid" : "invalid" });
    if (classification.state !== "addressable") {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: classification.state, reason: classification.reason }, now);
      return;
    }
    if (blockedCodexHomes.has(record.codex_home)) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "addressable", reason: "shared_codex_home_queue_pending" }, now);
      return;
    }
    if (!snapshot.unread || stopped) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "addressable" }, now);
      return;
    }

    let id;
    try {
      id = createPending(db, { seat, codexHome: record.codex_home, thread: record.thread, upTo: snapshot.upTo, nonce, expectedOpGen }, now);
    } catch (error) {
      if (error.message !== "daemon_intent_changed" && error.message !== "seat_already_pending") throw error;
      return;
    }

    activeController = new AbortController();
    let result;
    try {
      result = await queue({
        executable: queueExecutable,
        codexHome: record.codex_home,
        thread: record.thread,
        message: inboxNudge(nonce),
        timeoutMs,
        signal: activeController.signal,
        onChildStart: (pid) => recordChildStart(db, id, pid, captureGroup),
      });
    } finally {
      activeController = null;
    }
    recordChildResult(db, id, result);
    if (result.kind === "archived" || result.kind === "no_rollout") {
      setQueueState(db, id, "expired");
      const reason = result.kind === "archived" ? "thread_archived" : "codex_home_mismatch";
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason }, now);
      return;
    }
    if (result.kind === "queued") {
      setQueueState(db, id, "pending", result.queueItemId);
      const firstCheck = await pendingObservation(readPending(db, seat), now, observeGroup);
      if (firstCheck.state === "confirmed") {
        setQueueState(db, id, "confirmed");
        saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "addressable" }, now);
        return;
      }
      if (firstCheck.childrenUnresolved && record.codex_home) blockedCodexHomes.add(record.codex_home);
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "addressable", reason: firstCheck.reason }, now);
      return;
    }
    saveSeat(db, {
      seat,
      thread: record.thread,
      codexHome: record.codex_home,
      state: "addressable",
      reason: `queue_${result.kind}:${result.reason ?? "unknown"}`,
    }, now);
  }

  async function pollOnce() {
    if (stopped) return;
    if (activePoll) return activePoll;
    activePoll = (async () => {
      const roster = listSeats(join(installRoot, "teams"));
      if (roster.state !== "ok") {
        log(`channel: Codex roster unavailable (${roster.reason})`);
        return;
      }
      const paths = storagePaths(installRoot, env);
      const blockedCodexHomes = new Set();
      const seats = [...roster.seats];
      const registeredKeys = new Set(seats.map(({ team, agent }) => seatKey(team, agent)));
      const unsettledSeats = pendingSeats(db);
      const pendingKeys = new Set(unsettledSeats.map(({ team, agent }) => seatKey(team, agent)));
      for (const { team, agent } of unsettledSeats) {
        const key = seatKey(team, agent);
        if (!registeredKeys.has(key)) seats.push({ team, agent, teamConfig: null, registered: false });
      }
      const knownKeys = new Set([...registeredKeys, ...pendingKeys]);
      for (const row of db.prepare("SELECT seat FROM beta_codex_seat").all()) {
        if (!knownKeys.has(row.seat)) {
          saveSeat(db, { seat: row.seat, state: "unaddressable", reason: "seat_registration_missing" }, now);
        }
      }
      // Sequential processing also serializes codex queue writes that share a
      // CODEX_HOME, avoiding Codex's measured concurrent-write loss.
      for (const seat of seats) {
        if (stopped) break;
        try {
          await pollSeat(seat, paths, blockedCodexHomes);
        } catch (error) {
          log(`channel: Codex seat ${seat.team}/${seat.agent} could not be checked (${error.message})`);
        }
      }
    })().finally(() => { activePoll = null; });
    return activePoll;
  }

  return {
    pollOnce,
    async stop() {
      stopped = true;
      activeController?.abort();
      await activePoll;
    },
  };
}
