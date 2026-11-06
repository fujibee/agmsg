// The daemon status decision table is scoped to beta's install.db
// (meta / daemon_owner / daemon_intent / daemon_start_attempts only).
// seat_route, sync_status, stuck, and ctrl_state belong to a later release
// and are reported as unsupported wherever a caller lists all categories,
// not as "0 rows".
//
// Callable two ways:
//   - as a library: classify({owner, intent, alive}) -- the pure decision,
//     used by control.mjs's onStatus handler (running INSIDE the daemon
//     that already knows its own state) and by tests.
//   - as a CLI (`node status.mjs <installRoot>`): reads install.db
//     read-only, checks the recorded executor's liveness itself (works
//     whether or not the daemon is actually running), and additionally
//     tries the control socket if the record says 'ready' -- a record
//     that says ready but a socket that refuses the connection is the
//     "ready, but does not connect" case, which only an
//     external prober (not the daemon answering about itself) can ever
//     observe. Prints human-readable text, or JSON with --json; exit code follows the
//     table's own exit column.

import { readPollTimeout } from './log.mjs';
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { createConnection } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { isAlive } from "./executor.mjs";
import { readCompletionState, scriptsMismatches } from "./lifecycle.mjs";
import { openInstallDb } from "./db.mjs";
import { PROTOCOL_VERSION } from "./control.mjs";
import { listCodexRegistrations } from "./channels/codex-queue-store.mjs";

const STARTING_STOPPING_GRACE_MS = 30_000;

// The pure decision. `now` is injectable for tests.
export function classify({ owner, intent, alive, reachable, lastAttempt }, now = Date.now()) {
  const desired = intent?.desired ?? null;

  if (desired === "on" && owner.state === "ready" && alive === null) {
    return {
      text: "agmsgd's record cannot confirm that it is still running (it may have been written by an older version). Run agmsg daemon stop and then agmsg daemon start to refresh it. Unread messages are preserved.",
      exitCode: 1,
      gen: owner.gen,
    };
  }

  if (desired === "on" && !(owner.state === "ready" && alive === true && reachable)) {
    const reason = lastAttempt?.reason ?? owner.last_end_reason ??
      (owner.state === "ready" ? "executor or control socket unavailable" : owner.state);
    const detail = owner.last_end_reason === "bind_failed" ? "failed to start" :
      owner.last_end_reason === "stepped_aside_for_update" ? "stopped for an update; the new version has not started yet" : "stopped";
    // A digest mismatch means the installed files and the completion record
    // disagree -- restarting with the same files only fails again. Only
    // install.sh --update (or the npx installer) writes a fresh record.
    const advice = /digest/i.test(reason)
      ? "Run install.sh --update (or npx agmsg@latest install --update), then agmsg daemon start."
      : "Run agmsg daemon start (recommended), or agmsg daemon disable and restart Codex.";
    return {
      text: `agmsgd is ${detail} (intent is on; reason: ${reason}${owner.state === "ready" && !reachable ? "; does not answer on its control socket" : ""}). ${advice} Unread messages are preserved.`,
      exitCode: 1,
      gen: owner.gen,
    };
  }

  if (owner.state === "ready") {
    if (reachable && alive === true) {
      return {
        text: `agmsgd is running (gen ${owner.gen}, version ${owner.version ?? "unknown"})`,
        exitCode: 0,
        gen: owner.gen,
      };
    }
    return {
      text: "agmsgd's record says ready, but it does not answer on its control socket",
      exitCode: 1,
      gen: owner.gen,
    };
  }

  if (owner.state === "starting" || owner.state === "stopping") {
    const startedAt = owner.started_at ? Date.parse(owner.started_at) : NaN;
    const withinGrace = Number.isFinite(startedAt) && now - startedAt < STARTING_STOPPING_GRACE_MS;
    const ok = alive === true && withinGrace;
    return {
      text: `agmsgd is ${owner.state} (executor ${alive === true ? "alive" : alive === false ? "confirmed dead" : "cannot be determined"}, started ${owner.started_at ?? "unknown"})`,
      exitCode: ok ? 0 : 1,
      gen: owner.gen,
    };
  }

  // owner.state === "none" from here on.
  if (desired === "off") {
    return {
      text: `agmsgd is not in use (turned off deliberately${intent.set_at ? ` at ${intent.set_at}` : ""})`,
      exitCode: 0,
      gen: owner.gen,
    };
  }
  if (owner.gen === 0) {
    return { text: "agmsgd has never been started", exitCode: 0, gen: 0 };
  }
  if (owner.last_end_reason === "bind_failed") {
    return {
      text: `agmsgd failed to start (${owner.last_end_reason}, ${owner.last_end_at ?? "unknown time"}, gen ${owner.last_end_gen})`,
      exitCode: 1,
      gen: owner.gen,
    };
  }
  if (owner.last_end_reason === "stepped_aside_for_update") {
    return {
      text: `agmsgd stopped for an update (${owner.last_end_at ?? "unknown time"}). The new version has not started yet.`,
      exitCode: 1,
      gen: owner.gen,
    };
  }
  if (desired === "on") {
    return { text: "agmsgd is stopped (intent is on)", exitCode: 1, gen: owner.gen };
  }
  return {
    text: "agmsgd is stopped. No intent to use it is recorded.",
    exitCode: 1,
    gen: owner.gen,
  };
}

// Reads install.db read-only and checks the recorded executor's liveness --
// works whether or not agmsgd is actually running.
export function readOwnerAndIntentReadOnly(installRoot) {
  const db = openInstallDb(join(installRoot, "run", "install.db"), { readonly: true });
  try {
    const owner = db.prepare("SELECT * FROM daemon_owner").get();
    const intent = db.prepare("SELECT * FROM daemon_intent").get();
    const lastAttempt = db.prepare("SELECT at, reason FROM daemon_start_attempts WHERE at > ? ORDER BY at DESC, rowid DESC LIMIT 1").get(owner.last_end_at ?? "");
    let codexPending = [];
    try {
      codexPending = db.prepare("SELECT seat, created_at, children FROM beta_codex_queue WHERE state='pending' ORDER BY created_at, id").all();
    } catch (error) {
      if (!String(error?.message ?? "").includes("no such table")) throw error;
    }
    let codexExpired = [];
    try {
      codexExpired = db.prepare(`SELECT seat, state, created_at, children FROM beta_codex_queue
        WHERE state='expired' AND json_extract(CASE WHEN json_valid(children) THEN children ELSE '{}' END, '$.expiration_reason') IS NOT NULL
        ORDER BY id DESC LIMIT 100`).all();
    } catch (error) {
      if (!String(error?.message ?? "").includes("no such table")) throw error;
    }
    const alive =
      owner.state === "none" || owner.executor_pid == null
        ? null
        : isAlive({ pid: owner.executor_pid, bootId: owner.executor_boot_id, startedAt: owner.executor_started_at });
    return { owner, intent, alive, codexPending, codexExpired, lastAttempt };
  } finally {
    db.close();
  }
}

// One hello + one request round trip against the recorded socket, with a short
// deadline -- a prober must never hang the CLI command it backs. Resolves to
// the response object, or null when there was none in time.
export function queryDaemon(socketPath, type, timeoutMs = 2000) {
  return new Promise((resolve) => {
    const socket = createConnection(socketPath);
    let buf = "";
    const done = (result) => {
      socket.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => done(null), timeoutMs);
    socket.on("connect", () => {
      socket.write(`${JSON.stringify({ type: "hello", protocol: PROTOCOL_VERSION, role: "control" })}\n`);
      socket.write(`${JSON.stringify({ type })}\n`);
    });
    socket.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      for (const line of buf.split("\n")) {
        if (!line.startsWith("{")) continue;
        let msg;
        try { msg = JSON.parse(line); } catch { continue; }
        if (msg?.type === type) {
          clearTimeout(timer);
          done(msg);
          return;
        }
      }
    });
    socket.on("error", () => {
      clearTimeout(timer);
      done(null);
    });
  });
}

const probeSocket = async (socketPath, timeoutMs = 2000) => (await queryDaemon(socketPath, "status", timeoutMs)) !== null;

// What the running agmsgd last observed about its seats. It keeps that in
// memory only, so it is asked each time; with no running agmsgd there is
// nothing to show, and that is said instead of an empty list.
//   state: "ok" | "daemon_not_running" | "no_answer"
export async function readSeatsFromDaemon(owner, alive, timeoutMs = 2000) {
  if (owner?.state !== "ready" || !owner.socket || alive === false) return { state: "daemon_not_running" };
  const response = await queryDaemon(owner.socket, "seats", timeoutMs);
  if (response !== null) return { state: "ok", codex: response.codex, claude_code: response.claude_code };
  // No answer from a process that is known to be alive is "did not answer"; if
  // even its liveness cannot be confirmed (an old record without a boot id),
  // that is what is reported, not "stopped".
  return { state: alive === null ? "liveness_unconfirmed" : "no_answer" };
}

const inventoryOf = (seats, key) => seats.state === "ok"
  ? { state: seats[key]?.polled === false ? "not_polled_yet" : "ok", seats: seats[key]?.seats ?? [], polled: seats[key]?.polled ?? false }
  : { state: seats.state, seats: [] };

function formatSeatsNotice(seats) {
  if (seats.state === "daemon_not_running") return "Seats: agmsgd is not running; there is no seat state to show.\n";
  if (seats.state === "no_answer") return "Seats: agmsgd is running but did not answer in time; there is no seat state to show.\n";
  if (seats.state === "liveness_unconfirmed") return "Seats: agmsgd's process could not be confirmed to be running, so its seat state was not fetched.\n";
  const unpolled = ["codex", "claude_code"].filter((key) => seats[key]?.polled === false);
  if (unpolled.length === 2) return "Seats: agmsgd has not finished its first poll yet; seat state appears after it.\n";
  return "";
}

async function main() {
  const installRoot = process.argv[2];
  const json = process.argv.slice(3).includes("--json");
  const all = process.argv.slice(3).includes("--all");
  if (!installRoot) {
    process.stderr.write("usage: status.mjs <installRoot>\n");
    process.exit(2);
  }
  let owner, intent, alive, codexPending, codexExpired, lastAttempt;
  try {
    ({ owner, intent, alive, codexPending, codexExpired, lastAttempt } = readOwnerAndIntentReadOnly(installRoot));
  } catch (error) {
    // An input that can be detected as an error is reported at
    // that entry point, with a nonzero exit -- not a raw stack trace, and
    // not folded into "never started" (which is itself a legitimate 0).
    process.stderr.write(`agmsgd status: could not read install.db: ${error.message}\n`);
    process.exit(1);
  }
  const reachable = owner.state === "ready" && owner.socket ? await probeSocket(owner.socket) : false;
  const result = classify({ owner, intent, alive, reachable, lastAttempt });
  const seatState = reachable
    ? await readSeatsFromDaemon(owner, alive)
    : { state: owner.state !== "ready" || alive === false ? "daemon_not_running" : alive === null ? "liveness_unconfirmed" : "no_answer" };
  const codexSeats = inventoryOf(seatState, "codex");
  const claudeCodeSeats = inventoryOf(seatState, "claude_code");

  // The CLI suppresses Node's ExperimentalWarning category for managed SQLite
  // usage. Ordinary warnings and errors are still surfaced.
  //
  // `process.exitCode = ...` and returning, NOT `process.exit(...)`: when
  // stdout is a pipe rather than a TTY (exactly what capturing this
  // command's output does -- a test runner, `agmsg daemon status |
  // ...`), the write above is buffered, and `process.exit()` tears the
  // process down before that buffer flushes -- observed directly: this
  // printed nothing and still exited 0 under bats, where stdout is
  // captured through a pipe, while running the identical command directly
  // in an interactive terminal (a TTY, where the same write is
  // unbuffered) looked completely fine. Setting exitCode and letting the
  // event loop drain naturally waits for the flush first.
  let installVerifyWarning = currentInstallVerifyWarning(installRoot, owner, alive);
  if (installVerifyWarning === undefined) installVerifyWarning = readInstallVerifyWarning(installRoot, owner, alive);
  const pollTimeout = readPollTimeout(installRoot);
  const pollText = pollTimeout ? `Last poll timeout: ${pollTimeout.channel ?? 'unknown'} ${pollTimeout.seat ?? ''} ${pollTimeout.reason} (${pollTimeout.at ?? 'unknown time'})\n` : '';
  process.stdout.write(
    json ? `${JSON.stringify({ ...result, poll_timeout: pollTimeout, install_verify_warning: installVerifyWarning, codex_seats: codexSeats, claude_code_seats: claudeCodeSeats, codex_pending: codexPending, codex_expired: codexExpired, node_sqlite_experimental: true, node_version: process.version })}\n` : `${result.text}\n${formatInstallVerifyWarning(installVerifyWarning)}${pollText}${formatSeatsNotice(seatState)}${formatSkippedTeams("Claude Code", claudeCodeSeats)}${formatSkippedTeams("Codex", codexSeats)}${formatClaudeSeats(claudeCodeSeats, all)}${formatUnregisteredPending(installRoot, codexPending, all)}`,
  );
  process.exitCode = result.exitCode;
}

// What agmsgd found different between scripts/ and the install record when it
// started (written by the entrypoint; see recordVerifyProblems there). Only
// read for the running process's own file (named by its pid): a file left by
// an earlier run says nothing about this one.
export function readInstallVerifyWarning(installRoot, owner, alive) {
  if (alive !== true || owner?.executor_pid == null) return null;
  let warning;
  try { warning = JSON.parse(readFileSync(join(installRoot, 'run', `install-verify-warning.${owner.executor_pid}.json`), 'utf8')); } catch { return null; }
  if (warning?.pid !== owner.executor_pid) return null;
  if (!Array.isArray(warning.problems) || warning.problems.length === 0) return null;
  return warning;
}

// What differs between scripts/ and the install record right now, for a running
// agmsgd. A running agmsgd does not stop for such a difference (only the
// completion record moving stops it), so this is where it shows. Returns the
// warning, null when the tree matches the record NOW (the start-time warning is
// then out of date and must not be shown), or undefined when the comparison
// could not be made (no running pid, no complete record, unreadable): the
// caller may then fall back to the start-time warning.
export function currentInstallVerifyWarning(installRoot, owner, alive) {
  if (alive !== true || owner?.executor_pid == null) return undefined;
  let problems;
  try {
    const state = readCompletionState(installRoot);
    if (state.state !== 'complete') return undefined;
    problems = scriptsMismatches(installRoot, state.manifest);
  } catch { return undefined; }
  if (problems.length === 0) return null;
  return { pid: owner.executor_pid, at: new Date().toISOString(), problems, current: true };
}

function formatInstallVerifyWarning(warning) {
  if (!warning) return '';
  const wording = { missing: 'missing', unexpected: 'not in the record', digest_mismatch: 'differs from the record', symlink: 'symlink', unreadable: 'unreadable' };
  const list = warning.problems.map((p) => `${p.path} (${wording[p.kind] ?? p.kind})`).join(', ');
  return `Warning: agmsgd is running although scripts/ does not match its install record: ${list}. It keeps running. If this is not a change you made on purpose, run install.sh --update (or npx agmsg@latest install --update) to refresh the record.\n`;
}

function formatUnregisteredPending(installRoot, pending, all) {
  if (!pending.length) return "";
  let roster;
  try { roster = listCodexRegistrations(join(installRoot, "teams")); } catch { /* Do not guess that an unreadable roster is empty. */ }
  if (roster?.state !== "ok") return "Codex registrations could not be read; inspect pending confirmations with agmsg daemon status --json.\n";
  const registered = new Set(roster.seats.map(({ team, agent }) => JSON.stringify([team, agent])));
  const orphaned = pending.filter(row => !registered.has(row.seat));
  if (!orphaned.length) return "";
  let text = `Pending confirmations for unregistered seats: ${orphaned.length}. View the list with: agmsg daemon status --all\n`;
  if (all) {
    for (const row of orphaned) {
      let label;
      try { label = JSON.parse(row.seat).join("/"); } catch { label = "unidentified seat"; }
      text += `Codex ${label}: unregistered; past destination; confirmation pending since ${row.created_at}\n`;
    }
  }
  return text;
}

// A team skipped because its roster entry is unusable is stored as a
// team-level row (agent ""); it is always shown, never folded into "hidden".
function formatSkippedTeams(label, inventory) {
  let text = "";
  for (const seat of inventory?.seats ?? []) {
    let parsed;
    try { parsed = JSON.parse(seat.seat); } catch { continue; }
    if (Array.isArray(parsed) && parsed[1] === "" && /^team_roster_/.test(seat.reason ?? "")) {
      text += `${label} team ${parsed[0]}: skipped (${seat.reason}); other teams are unaffected\n`;
    }
  }
  return text;
}

function formatClaudeSeats(inventory, all) {
  let omitted = 0;
  const lines = [];
  for (const seat of inventory?.seats ?? []) {
    if (/^team_roster_/.test(seat.reason ?? "") && seat.seat.endsWith(',""]')) continue;
    const chosen = /^delivery_chosen_([a-z]+)$/.exec(seat.reason ?? "")?.[1];
    if (chosen) {
      let label;
      try { label = JSON.parse(seat.seat).join("/"); } catch { label = "unidentified seat"; }
      lines.push(`Claude Code ${label}: ${chosen === "monitor" ? "monitor (legacy)" : chosen} chosen; agmsgd does not deliver here`);
      continue;
    }
    if (!all && (seat.state === "unaddressable" || !seat.messaging_socket)) {
      omitted += 1;
      continue;
    }
    let label;
    try { label = JSON.parse(seat.seat).join("/"); } catch { label = "unidentified seat"; }
    lines.push(`Claude Code ${label}: last daemon observation: ${seat.state}${seat.reason ? ` (${seat.reason})` : ""}`);
  }
  if (omitted) lines.push(`Claude Code seats: ${omitted} unavailable destination records hidden. View them with: agmsg daemon status --all`);
  return lines.length ? `${lines.join("\n")}\n` : "";
}

// `fileURLToPath(import.meta.url)` is realpath'd by Node's own module
// loader (symlinks resolved); `process.argv[1]` is whatever the caller
// passed literally and is NOT realpath'd by Node. On any system where the
// temp/working directory itself sits behind a symlink -- macOS's
// /var -> /private/var is the common case -- a bare `===` between the two
// never matches, so this "am I the CLI entry" guard silently fails and
// main() never runs: the process still exits 0 (nothing here throws), but
// prints nothing beyond node:sqlite's own top-level-import warning.
// Observed exactly this way (bats invokes this file through a path under
// /var/folders while import.meta.url resolves through /private/var).
// realpathSync both sides so the comparison is meaningful regardless of
// which one the caller happened to pass.
if (existsSync(process.argv[1] ?? "") && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
