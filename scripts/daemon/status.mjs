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
//     observe. Prints one JSON line to stdout; exit code follows the
//     table's own exit column.

import { existsSync, realpathSync } from "node:fs";
import { createConnection } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { isAlive } from "./executor.mjs";
import { openInstallDb } from "./db.mjs";
import { PROTOCOL_VERSION } from "./control.mjs";

const STARTING_STOPPING_GRACE_MS = 30_000;

// The pure decision. `now` is injectable for tests.
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
    // An input that can be detected as an error is reported at
    // that entry point, with a nonzero exit -- not a raw stack trace, and
    // not folded into "never started" (which is itself a legitimate 0).
    process.stderr.write(`agmsgd status: could not read install.db: ${error.message}\n`);
    process.exit(1);
  }
  const reachable = owner.state === "ready" && owner.socket ? await probeSocket(owner.socket) : false;
  const result = classify({ owner, intent, alive, reachable });

  // The node:sqlite experimental-feature warning is surfaced here, always
  // -- not hidden, not treated as a failure.
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
  process.stdout.write(
    `${JSON.stringify({ ...result, node_sqlite_experimental: true, node_version: process.version })}\n`,
  );
  process.exitCode = result.exitCode;
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
