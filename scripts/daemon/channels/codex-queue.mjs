// Polls the existing message stores and nudges registered Codex seats through
// the local Codex queue. It never writes message data or read cursors.

import { createHash } from "node:crypto";
import { homedir, hostname } from "node:os";
import { delimiter, dirname, isAbsolute, join, resolve, sep } from "node:path";
import { accessSync, constants, lstatSync, readFileSync, readdirSync, statSync } from "node:fs";
import { logLine } from "../log.mjs";
import { optedOutOfAgmsgd } from "./delivery-choice.mjs";
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
  QUEUE_KILL_GRACE_MS,
  classifyCodexSeat,
  inboxNudge,
  newNonce,
  runCodexQueue,
} from "./codex-queue-io.mjs";
import { captureProcessGroup, observeProcessGroup, processStartWitness } from "./process-group.mjs";
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

function latestNotifiedCursor(db, seat) {
  const row = db.prepare(`
    SELECT up_to FROM beta_codex_queue WHERE seat = ? AND (state = 'confirmed' OR queue_item_id IS NOT NULL OR CASE WHEN json_valid(children) THEN json_extract(children, '$.result') END = 'queued')
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

function setQueueState(db, id, state, reason = undefined) {
  withImmediateTransaction(db, () => {
    if (state === "expired" && reason) {
      const row = db.prepare("SELECT children FROM beta_codex_queue WHERE id = ? AND state = 'pending'").get(id);
      if (!row) return;
      let children;
      try { children = JSON.parse(row.children); } catch { /* preserve a damaged record below */ }
      if (!children || typeof children !== "object" || Array.isArray(children)) children = { state: "unreadable", record: row.children };
      children.expiration_reason = reason;
      db.prepare("UPDATE beta_codex_queue SET state = ?, children = ? WHERE id = ? AND state = 'pending'")
        .run(state, JSON.stringify(children), id);
    } else {
      db.prepare("UPDATE beta_codex_queue SET state = ? WHERE id = ? AND state = 'pending'").run(state, id);
    }
  });
}

function recordChildStart(db, id, pid, captureGroup, log = () => {}) {
  let group;
  try {
    group = captureGroup(pid, (detail) => log(`codex queue: child start witness unavailable for pid ${pid}: ${detail}`));
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
    try { children = JSON.parse(row.children); } catch { children = null; }
    if (!children || typeof children !== "object" || Array.isArray(children)) children = { state: "unreadable", reason: "child_group_record_malformed" };
    const failedBeforeStart = result.kind === "failed" && result.started === false;
    if (failedBeforeStart) {
      children = { state: "absent", result: result.kind, reason: result.reason };
    } else {
      children.result = result.kind;
      children.result_reason = result.reason ?? "";
    }
    db.prepare("UPDATE beta_codex_queue SET children = ?, state = ?, queue_item_id = COALESCE(?, queue_item_id) WHERE id = ? AND state = 'pending'")
      .run(JSON.stringify(children), failedBeforeStart ? "expired" : "pending", result.kind === "queued" ? result.queueItemId : null, id);
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
    if (error?.code === "ENOENT") return { state: "stopped", reason: "" };
    return { state: "unknown", reason: `bridge_state_unknown:${runDir}:directory_read_failed` };
  }
  const identity = `${team}/${agent}`;
  let stoppedReason = "";
  for (const pidName of files) {
    const pidPath = join(runDir, pidName);
    const metaPath = `${pidPath.slice(0, -4)}.meta`;
    const unknown = (file, reason) => ({ state: "unknown", reason: `bridge_state_unknown:${file}:${reason}` });
    const ownFile = pidName === `codex-bridge.${team}.${agent}.pid`;
    let pidText;
    let metaText;
    try {
      const metaStat = lstatSync(metaPath);
      if (!metaStat.isFile() || metaStat.isSymbolicLink()) {
        if (ownFile) return unknown(metaPath, "not_regular_file");
        continue;
      }
      metaText = readFileSync(metaPath, "utf8");
    } catch (error) {
      if (ownFile) return unknown(metaPath, `read_failed:${error?.code ?? "unknown"}`);
      continue;
    }
    const fields = Object.create(null);
    for (const line of metaText.split(/\r?\n/)) {
      const at = line.indexOf("=");
      if (at > 0 && !(line.slice(0, at) in fields)) fields[line.slice(0, at)] = line.slice(at + 1);
    }
    if (!fields.identities) {
      if (ownFile) return unknown(metaPath, "identities_missing");
      continue;
    }
    if (!fields.identities.split(",").includes(identity)) continue;
    if (fields.type !== "codex") return unknown(metaPath, "type_missing_or_invalid");
    try {
      const pidStat = lstatSync(pidPath);
      if (!pidStat.isFile() || pidStat.isSymbolicLink()) return unknown(pidPath, "not_regular_file");
      pidText = readFileSync(pidPath, "utf8").trim();
    } catch (error) { return unknown(pidPath, `read_failed:${error?.code ?? "unknown"}`); }
    if (!/^\d+$/.test(pidText) || !Number.isSafeInteger(Number(pidText)) || Number(pidText) < 2 || fields.pid !== pidText) return unknown(metaPath, "pid_missing_or_mismatch");
    // A dead bridge's stale files cannot retain ownership. Probe before any
    // lease or start-witness comparison, which necessarily fails for dead PIDs.
    try { process.kill(Number(pidText), 0); } catch (error) {
      if (error?.code === "ESRCH") { stoppedReason = `bridge_stopped:${pidPath}:pid_absent`; continue; }
      if (error?.code !== "EPERM") return unknown(pidPath, `pid_probe_failed:${error?.code ?? "unknown"}`);
    }
    if (!projects.some((project) => sameProject(project, fields.project))) return unknown(metaPath, "project_missing_or_mismatch");
    // A live PID alone can be a recycled process. Require the bridge's own
    // per-PID lease, matching its recorded pair/project set and start token.
    const leasePath = join(runDir, `codex-bridge-lease.${pidText}`);
    let leaseText;
    try {
      const leaseStat = lstatSync(leasePath);
      if (!leaseStat.isFile() || leaseStat.isSymbolicLink()) return unknown(leasePath, "not_regular_file");
      leaseText = readFileSync(leasePath, "utf8");
    } catch (error) {
      return unknown(leasePath, `read_failed:${error?.code ?? "unknown"}`);
    }
    const lease = Object.create(null);
    for (const line of leaseText.split(/\r?\n/)) {
      const at = line.indexOf("=");
      if (at > 0 && !(line.slice(0, at) in lease)) lease[line.slice(0, at)] = line.slice(at + 1);
      else if (at > 0) return unknown(leasePath, "duplicate_field");
    }
    const leaseKeys = Object.keys(lease).sort().join(",");
    if (leaseKeys !== "host,pairs,pid,project,start,startsrc,v") return unknown(leasePath, "fields_missing_or_invalid");
    const pairHashes = fields.identities.split(",").map((pair) => createHash("sha1").update(pair.replace("/", "\t")).digest("hex")).sort();
    const expectedPairs = createHash("sha1").update(pairHashes.join("\n")).digest("hex");
    const expectedProject = createHash("sha1").update(fields.project).digest("hex");
    if (lease.v !== "1" || lease.pid !== pidText || lease.project !== expectedProject || lease.pairs !== expectedPairs || lease.host !== hostname() || !lease.start) return unknown(leasePath, "identity_mismatch");
    const startPrefix = lease.startsrc === "proc" ? "linux" : lease.startsrc === "ps" ? "darwin" : lease.startsrc === "pwsh" ? "windows" : "";
    if (!startPrefix || processStartWitness(Number(pidText)) !== `${startPrefix}:${lease.start}`) return unknown(leasePath, "start_witness_missing_or_mismatch");
    try {
      process.kill(Number(pidText), 0);
      return { state: "running", reason: "bridge_running" };
    } catch (error) {
      if (error?.code === "ESRCH") { stoppedReason = `bridge_stopped:${pidPath}:pid_absent`; continue; }
      if (error?.code === "EPERM") return { state: "running", reason: "bridge_running" };
      return unknown(pidPath, `pid_probe_failed:${error?.code ?? "unknown"}`);
    }
  }
  return { state: "stopped", reason: stoppedReason };
}

// Pending rows reserve a writer, never wait for Codex to consume a nudge.
// Old 1.6.0 receipts are delivery evidence too. Every unresolved reservation,
// including a crash before child registration, has the same maximum lifetime.
function pendingObservation(pending, now, observeGroup, timeoutMs, ages) {
  let children;
  try { children = JSON.parse(pending.children); } catch { /* incomplete or damaged record */ }
  let reason = "child_group_record_unreadable";
  if (children?.state === "absent") return {
    state: pending.queue_item_id || children.result === "queued" ? "confirmed" : "expired",
    reason: children.result_reason || children.reason || "queue_result_unavailable",
  };
  if (children?.state === "complete" || (children?.state === "unreadable" && children.pgid !== undefined)) {
    let group;
    try { group = observeGroup(children); } catch { group = { state: "unreadable", reason: "child_group_observation_failed" }; }
    if (group?.state === "absent") return {
      state: pending.queue_item_id || children.result === "queued" ? "confirmed" : "expired",
      reason: children.result_reason || "queue_result_unavailable",
    };
    reason = group?.reason ?? "queue_child_still_running";
  } else if (pending.children === "incomplete" || children?.state === "incomplete") {
    reason = "queue_child_state_incomplete";
  } else if (children?.reason) reason = children.reason;
  const clock = now();
  // A corrupt/future timestamp must not become a permanent reservation. The
  // first observation supplies a bounded fallback age for that row.
  if (!ages.has(pending.id)) {
    const created = Date.parse(pending.created_at);
    ages.set(pending.id, Number.isFinite(created) && created <= clock ? created : clock);
  }
  const start = ages.get(pending.id);
  if (clock - start >= timeoutMs + QUEUE_KILL_GRACE_MS) {
    return { state: "expired", reason: `queue_child_timeout:${reason}` };
  }
  return { state: "pending", reason, childrenUnresolved: true };
}

export function createCodexQueueChannel({
  db,
  installRoot,
  expectedOpGen,
  env = process.env,
  executable,
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
  const pendingAges = new Map();
  const homeKey = (home) => hostPlatform === "win32" ? resolve(home).toLowerCase() : resolve(home);

  async function pollSeat(registration, paths, blockedCodexHomes) {
    const { team, agent, teamConfig, registered = true } = registration;
    const seat = seatKey(team, agent);
    const registeredProjects = registrationProjects(teamConfig, agent);
    const bridge = bridgeState(join(installRoot, "run"), team, agent, registeredProjects);
    let pending = readPending(db, seat);
    if (pending && registered) {
      // A reservation made for another thread than the one this seat's record
      // names now is about a conversation that is gone. It is dropped and the
      // current thread gets the nudge, but only once its child is shown to be
      // finished: an old writer that may still be running keeps the Codex home
      // blocked exactly as before.
      const current = readSession(join(installRoot, "run"), team, agent);
      if (current.state === "present" && current.record.thread && current.record.thread !== pending.thread) {
        const old = pendingObservation(pending, now, observeGroup, timeoutMs, pendingAges);
        if (!old.childrenUnresolved) {
          setQueueState(db, pending.id, "expired", old.state === "expired" ? old.reason : undefined);
          pending = null;
        }
      }
    }
    if (pending) {
      const observation = pendingObservation(pending, now, observeGroup, timeoutMs, pendingAges);
      if (observation.childrenUnresolved && pending.codex_home) blockedCodexHomes.add(homeKey(pending.codex_home));
      if (observation.state !== "pending") {
        setQueueState(db, pending.id, observation.state, observation.reason);
        pendingAges.delete(pending.id);
      }
      if (!registered) {
        saveSeat(db, { seat, thread: pending.thread, codexHome: pending.codex_home, state: "unaddressable", reason: "seat_registration_missing" }, now);
        return;
      }
      // Keep an expiration visible for this poll; retry on the next one.
      if (observation.state !== "confirmed") {
        saveSeat(db, { seat, thread: pending.thread, codexHome: pending.codex_home,
          state: bridge.state === "running" ? "bridged" : bridge.state === "unknown" ? "blocked" : "addressable",
          reason: bridge.state === "unknown" ? `${bridge.reason};pending:${observation.reason}` : observation.reason }, now);
        return;
      }
    }
    if (!registered) return;
    if (bridge.state !== "stopped" && bridge.state !== "running") {
      saveSeat(db, { seat, state: "blocked", reason: bridge.reason }, now);
      return;
    }
    if (bridge.state === "running") {
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
    const runtime = db.prepare('SELECT codex_path, node_path FROM meta').get();
    let queueExecutable = executable ?? runtime?.codex_path;
    const queueEnv = { ...env, PATH: [runtime?.node_path ? dirname(runtime.node_path) : '', queueExecutable && isAbsolute(queueExecutable) ? dirname(queueExecutable) : '', env.PATH ?? ''].filter(Boolean).join(delimiter) };
    if (hostPlatform === "win32") {
      const gate = windowsGate({ executable: queueExecutable, env: queueEnv });
      if (gate.state !== "ok") {
        saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason: gate.reason }, now);
        return;
      }
      queueExecutable = gate.executable;
    }
    try {
      if (!isAbsolute(queueExecutable ?? '')) throw new Error('not_absolute');
      if (!statSync(queueExecutable).isFile()) throw new Error('not_file');
      accessSync(queueExecutable, constants.X_OK);
    } catch {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: 'blocked', reason: 'codex_executable_unavailable:run_agmsg_daemon_enable' }, now);
      return;
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
    // A project that chose something other than agmsgd gets no new notices.
    const optedOut = optedOutOfAgmsgd(installRoot, "codex", record.project);
    if (optedOut) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "unaddressable", reason: `delivery_chosen_${optedOut}` }, now);
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
      snapshot = readSnapshot(store, team, agent, latestNotifiedCursor(db, seat));
    } catch (error) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason: `message_store_unreadable:${error.message}` }, now);
      return;
    } finally {
      try { store.close(); } catch { /* keep the read result */ }
    }

    const nonce = newNonce();
    // The queue CLI owns thread classification; no rollout/queue DB read gates
    // acceptance or the next unread snapshot.
    const classification = classifyCodexSeat({ roleSession: record, bridgeState: "stopped" });
    if (classification.state !== "addressable") {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: classification.state, reason: classification.reason }, now);
      return;
    }
    if (blockedCodexHomes.has(homeKey(record.codex_home))) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "addressable", reason: "shared_codex_home_queue_pending" }, now);
      return;
    }
    if (!snapshot.unread || stopped) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "addressable", reason: bridge.reason }, now);
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
        env: queueEnv,
        codexHome: record.codex_home,
        thread: record.thread,
        message: inboxNudge(nonce),
        timeoutMs,
        signal: activeController.signal,
        onChildStart: (pid) => recordChildStart(db, id, pid, captureGroup, log),
      });
    } finally {
      activeController = null;
    }
    recordChildResult(db, id, result);
    if (result.kind === "failed" && result.started === false) {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "addressable", reason: result.reason }, now);
      return;
    }
    // recordChildResult persisted the receipt atomically with the result. A
    // pending writer reserves CODEX_HOME, but its snapshot is already notified.
    const child = pendingObservation(readPending(db, seat), now, observeGroup, timeoutMs, pendingAges);
    if (child.state !== "pending") setQueueState(db, id, child.state, child.reason);
    if (child.childrenUnresolved) blockedCodexHomes.add(homeKey(record.codex_home));
    if (result.kind === "archived" || result.kind === "no_rollout") {
      const reason = result.kind === "archived" ? "thread_archived" : "codex_home_mismatch";
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "blocked", reason }, now);
      return;
    }

    if (result.kind === "queued") {
      saveSeat(db, { seat, thread: record.thread, codexHome: record.codex_home, state: "addressable", reason: child.state === "expired" || child.childrenUnresolved ? child.reason : bridge.reason }, now);
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
      const pendingRows = db.prepare("SELECT id, codex_home, queue_item_id, children, created_at FROM beta_codex_queue WHERE state='pending'").all();
      const activeIds = new Set(pendingRows.map(row => row.id));
      for (const id of pendingAges.keys()) if (!activeIds.has(id)) pendingAges.delete(id);
      for (const row of pendingRows) {
        if (pendingObservation(row, now, observeGroup, timeoutMs, pendingAges).childrenUnresolved && row.codex_home) blockedCodexHomes.add(homeKey(row.codex_home));
      }
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
