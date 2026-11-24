// Positive daemon liveness across caller sandboxes. Socket replies take
// precedence; a recent owner-authored heartbeat also proves it is running,
// unless this caller shares the executor's pid view and finds its pid gone.
import { readFileSync, writeFileSync, renameSync, rmSync, existsSync, realpathSync, readlinkSync } from 'node:fs';
import { createConnection } from 'node:net';
import { platform } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { openInstallDb, withImmediateTransaction } from './db.mjs';
import { PROTOCOL_VERSION } from './control.mjs';

export const HEARTBEAT_MAX_AGE_MS = 20_000;
export const HEARTBEAT_RECHECK_MS = 5_000;
export const heartbeatPath = root => join(root, 'run', 'agmsgd-heartbeat.json');

// Linux only: the pid namespace this process sees. A sandboxed caller (Codex's
// Linux sandbox) gets its own, so it cannot see the executor's pid at all.
// macOS and Windows have no pid namespaces; null there.
export function pidNamespace(plat = platform(), readlink = readlinkSync) {
  if (plat !== 'linux') return null;
  try { return readlink('/proc/self/ns/pid'); } catch { return null; }
}

// "No such process" for this pid (ESRCH). EPERM means it exists; anything
// else cannot tell. The boot id is not consulted: a fresh heartbeat already
// belongs to this boot, and an unreadable boot id must not read as dead.
export function pidGone(pid) {
  try { process.kill(pid, 0); return false; } catch (error) { return error?.code === 'ESRCH'; }
}

// True only when the caller's "no such process" is trustworthy: the same pid
// view as the executor that wrote the heartbeat (any caller on macOS/Windows;
// on Linux, the namespace the heartbeat recorded). A heartbeat without a
// namespace on Linux, a missing pid, or a "cannot tell" leaves the heartbeat
// in charge.
export function executorProvedDead(owner, record, { plat = platform(), ownNs = pidNamespace(plat), gone = pidGone } = {}) {
  const pid = Number(owner?.executor_pid);
  if (!Number.isSafeInteger(pid) || pid <= 1) return false;
  if (plat === 'linux' && (!record?.pid_ns || record.pid_ns !== ownNs)) return false;
  return gone(pid) === true;
}

export function readHeartbeat(root, { installId, gen }, now = Date.now()) {
  let record;
  try { record = JSON.parse(readFileSync(heartbeatPath(root), 'utf8')); }
  catch (error) {
    return { state: error.code === 'ENOENT' ? 'missing' : 'invalid', reason: error.code ?? 'invalid JSON' };
  }
  if (!record || !installId || record.install_id !== installId || record.gen !== gen ||
      !Number.isSafeInteger(record.sequence) || record.sequence < 1 || !Number.isFinite(Date.parse(record.at))) {
    return { state: 'invalid', reason: 'heartbeat identity or fields do not match the owner' };
  }
  const ageMs = now - Date.parse(record.at);
  return { state: ageMs >= 0 && ageMs <= HEARTBEAT_MAX_AGE_MS ? 'fresh' : 'stale', ageMs, record };
}

// The transaction fences ownership/intent changes until the atomic rename is
// complete. One small file replacement per poll, no child process or per-seat
// work. A stop cannot be followed by another write from the stopped owner.
export function writeHeartbeat(db, root, { gen, expectedOpGen }, sequence, now = Date.now()) {
  return withImmediateTransaction(db, () => {
    const owner = db.prepare(`SELECT m.install_id FROM daemon_owner o CROSS JOIN meta m
      CROSS JOIN daemon_intent i WHERE o.gen = ? AND o.state = 'ready'
      AND i.desired = 'on' AND i.op_gen = ?`).get(gen, expectedOpGen);
    if (!owner) return false;
    const path = heartbeatPath(root);
    const temporary = `${path}.${gen}.${process.pid}.tmp`;
    const pidNs = pidNamespace();
    writeFileSync(temporary, JSON.stringify({ install_id: owner.install_id, gen, sequence, at: new Date(now).toISOString(), ...(pidNs ? { pid_ns: pidNs } : {}) }) + '\n', { mode: 0o600 });
    renameSync(temporary, path);
    return true;
  });
}

export function clearHeartbeat(db, root, gen) {
  return withImmediateTransaction(db, () => {
    const installId = db.prepare('SELECT install_id FROM meta').get()?.install_id;
    let record;
    try { record = JSON.parse(readFileSync(heartbeatPath(root), 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return; throw error; }
    if (record.install_id === installId && record.gen === gen) rmSync(heartbeatPath(root), { force: true });
  });
}

export function queryDaemon(socketPath, type, timeoutMs = 2000) {
  return new Promise(resolve => {
    const socket = createConnection(socketPath);
    let buffer = '', finished = false;
    const done = result => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => done(null), timeoutMs);
    socket.on('connect', () => {
      socket.write(JSON.stringify({ type: 'hello', protocol: PROTOCOL_VERSION, role: 'control' }) + '\n');
      socket.write(JSON.stringify({ type }) + '\n');
    });
    socket.on('data', chunk => {
      buffer += chunk.toString('utf8');
      for (const line of buffer.split('\n')) {
        try { const message = JSON.parse(line); if (message?.type === type) done(message); } catch { /* incomplete frame */ }
      }
    });
    socket.on('error', () => done(null));
    socket.on('end', () => done(null));
  });
}

export async function observeLiveness(root, { owner, installId }, { now = Date.now, query = queryDaemon, provedDead = executorProvedDead } = {}) {
  if (owner?.state !== 'ready') {
    const heartbeat = readHeartbeat(root, { installId, gen: owner?.gen }, now());
    return { running: false, heartbeat: heartbeat.state === 'fresh' ? { state: 'invalid', reason: 'owner is not ready' } : heartbeat };
  }
  const response = owner.socket ? await query(owner.socket, 'status') : null;
  if (response?.gen === owner.gen) return { running: true, source: 'socket', heartbeat: null };
  const heartbeat = readHeartbeat(root, { installId, gen: owner.gen }, now());
  if (heartbeat.state === 'fresh' && provedDead(owner, heartbeat.record)) {
    // The heartbeat file outlives a killed executor by up to HEARTBEAT_MAX_AGE_MS.
    return { running: false, source: null, heartbeat: { state: 'contradicted', reason: 'the recorded executor is not running' } };
  }
  return { running: heartbeat.state === 'fresh', source: heartbeat.state === 'fresh' ? 'heartbeat' : null, heartbeat };
}

export function readLivenessRecord(root) {
  const db = openInstallDb(join(root, 'run', 'install.db'), { readonly: true });
  try {
    return { owner: db.prepare('SELECT * FROM daemon_owner').get(), installId: db.prepare('SELECT install_id FROM meta').get()?.install_id };
  } finally { db.close(); }
}

export async function checkStartLiveness(root, {
  read = readLivenessRecord, observe = observeLiveness,
  wait = ms => new Promise(resolve => setTimeout(resolve, ms)),
} = {}) {
  let result = await observe(root, read(root));
  if (result.running || result.heartbeat.state === 'missing' || result.heartbeat.state === 'contradicted') return result;
  // An existing but stale/invalid file gets exactly one five-second recheck.
  // Re-read ownership too: another caller may have started a new generation.
  await wait(HEARTBEAT_RECHECK_MS);
  result = await observe(root, read(root));
  return result;
}

if (existsSync(process.argv[1] ?? '') && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
  const root = process.argv[2];
  try {
    const result = process.argv.includes('--start')
      ? await checkStartLiveness(root)
      : await observeLiveness(root, readLivenessRecord(root));
    if (result.running) console.log(`running:${result.source}`);
    else {
      if (result.heartbeat.state === 'invalid') console.error(`agmsgd heartbeat could not be used: ${result.heartbeat.reason}`);
      console.log('not_running');
    }
  } catch (error) {
    console.error(`agmsgd liveness could not be checked: ${error.message}`);
    process.exitCode = 1;
  }
}
