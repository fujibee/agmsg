// arch-11 §5's decision table ("デーモンの状態と、利用の意図"), scoped to
// beta's install.db (meta / daemon_owner / daemon_intent /
// daemon_start_attempts only -- no seat_route, sync_status, stuck,
// ctrl_state, invokes: those are 2.0.0-only and are reported as "ベータで
// は受け持たない" wherever a caller lists all 8 arch-11 categories, not as
// "0 rows").
//
// Callable two ways:
//   - as a library: classify({owner, intent, alive}) -- the pure decision,
//     used by control.mjs's onStatus handler (running INSIDE the daemon
//     that already knows its own state) and by tests.
//   - as a CLI (`node status.mjs <installRoot>`): reads install.db
//     read-only, checks the recorded executor's liveness itself (works
//     whether or not the daemon is actually running), and additionally
//     tries the control socket if the record says 'ready' -- a record
//     that says ready but a socket that refuses the connection is exactly
//     arch-11 §5's "ready, but does not connect" row, which only an
//     external prober (not the daemon answering about itself) can ever
//     observe. Prints one JSON line to stdout; exit code follows the
//     table's own exit column.

import { createConnection } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { isAlive } from "./executor.mjs";
import { openInstallDb } from "./db.mjs";
import { PROTOCOL_VERSION } from "./control.mjs";

const STARTING_STOPPING_GRACE_MS = 30_000;

// The pure decision (arch-11 §5's table). `now` is injectable for tests.
export function classify({ owner, intent, alive, reachable }, now = Date.now()) {
  const desired = intent?.desired ?? null;

  if (owner.state === "ready") {
    if (reachable) {
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
    const alive =
      owner.state === "none" || owner.executor_pid == null
        ? null
        : isAlive({ pid: owner.executor_pid, bootId: owner.executor_boot_id });
    return { owner, intent, alive };
  } finally {
    db.close();
  }
}

// Attempts one hello+status round trip against the recorded socket, with a
// short deadline -- a prober must never hang the CLI command it backs.
function probeSocket(socketPath, timeoutMs = 2000) {
  return new Promise((resolve) => {
    const socket = createConnection(socketPath);
    let buf = "";
    const done = (result) => {
      socket.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => done(false), timeoutMs);
    socket.on("connect", () => {
      socket.write(`${JSON.stringify({ type: "hello", protocol: PROTOCOL_VERSION, role: "control" })}\n`);
      socket.write(`${JSON.stringify({ type: "status" })}\n`);
    });
    socket.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      if (buf.includes('"type":"status"')) {
        clearTimeout(timer);
        done(true);
      }
    });
    socket.on("error", () => {
      clearTimeout(timer);
      done(false);
    });
  });
}

async function main() {
  const installRoot = process.argv[2];
  if (!installRoot) {
    process.stderr.write("usage: status.mjs <installRoot>\n");
    process.exit(2);
  }
  let owner, intent, alive;
  try {
    ({ owner, intent, alive } = readOwnerAndIntentReadOnly(installRoot));
  } catch (error) {
    // arch-11 §3c: an input that can be detected as an error is reported at
    // that entry point, with a nonzero exit -- not a raw stack trace, and
    // not folded into "never started" (which is itself a legitimate 0).
    process.stderr.write(`agmsgd status: could not read install.db: ${error.message}\n`);
    process.exit(1);
  }
  const reachable = owner.state === "ready" && owner.socket ? await probeSocket(owner.socket) : false;
  const result = classify({ owner, intent, alive, reachable });

  // The node:sqlite experimental-feature warning is surfaced here, always
  // -- not hidden, not treated as a failure (arch-11 §4 #7).
  process.stdout.write(
    `${JSON.stringify({ ...result, node_sqlite_experimental: true, node_version: process.version })}\n`,
  );
  process.exit(result.exitCode);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main();
}
