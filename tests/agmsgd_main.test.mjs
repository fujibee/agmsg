import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { openInstallDb } from "../scripts/daemon/db.mjs";
import { readOwner } from "../scripts/daemon/owner.mjs";
import { gracefulStop, pollChannelHooks, pollCycle, pollOnce, prepareClaimWithCodexSchema, startup, stopExitCode } from "../scripts/daemon/main.mjs";
import { captureWatchState } from "../scripts/daemon/lifecycle.mjs";
import { createHash } from "node:crypto";

function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

function makeInstall() {
  const root = mkdtempSync(join(tmpdir(), "agmsgd-main-test-"));
  mkdirSync(join(root, "run"), { recursive: true });
  mkdirSync(join(root, "scripts"), { recursive: true });
  writeFileSync(join(root, "scripts", "x.sh"), "x\n");
  writeFileSync(join(root, "VERSION"), "1.0.0\n");
  const manifest = {
    install_id: "i1",
    gen: 1,
    version: "1.0.0",
    created_at: new Date().toISOString(),
    digest_algo: "sha256",
    files: [{ path: "scripts/x.sh", digest: sha256("x\n") }],
  };
  const manifestText = JSON.stringify(manifest);
  writeFileSync(join(root, "run", "install-manifest.json"), manifestText);
  return { root, manifest, manifestText };
}

test("startup: takes ownership, binds the socket, and marks ready", async () => {
  const { root } = makeInstall();
  try {
    const db = openInstallDb(join(root, "run", "install.db"));
    const started = await startup(db, {
      installRoot: root,
      expectedDesired: null,
      expectedOpGen: 0,
      version: "test",
      handlers: { onStop: async () => ({}), onStatus: async () => ({}) },
    });
    assert.equal(started.ok, true);
    assert.equal(readOwner(db).state, "ready");
    await started.controlHandle.close();
    db.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("startup: a refused takeOwnership never touches the control socket, and reports ok:false", async () => {
  const { root } = makeInstall();
  try {
    const db = openInstallDb(join(root, "run", "install.db"));
    // Wrong expectedOpGen -> takeOwnership refuses before ever trying to bind.
    const started = await startup(db, {
      installRoot: root,
      expectedDesired: null,
      expectedOpGen: 99,
      version: "test",
      handlers: { onStop: async () => ({}), onStatus: async () => ({}) },
    });
    assert.equal(started.ok, false);
    assert.equal(readOwner(db).state, "none", "a refused start must never move daemon_owner");
    db.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("pollOnce: continues when nothing changed, steps aside on drift, stops on an intent change", async () => {
  const { root, manifest, manifestText } = makeInstall();
  try {
    const db = openInstallDb(join(root, "run", "install.db"));
    const watchState = await captureWatchState(root, manifest, manifestText);

    let verdict = await pollOnce(db, root, { gen: 1, expectedOpGen: 0, watchState });
    assert.deepEqual(verdict, { action: "continue" });

    // Case: an explicit operation bumped op_gen since this process started.
    db.exec("UPDATE daemon_intent SET op_gen = 1");
    verdict = await pollOnce(db, root, { gen: 1, expectedOpGen: 0, watchState });
    assert.equal(verdict.action, "stop");
    assert.equal(verdict.reason, "normal");
    db.exec("UPDATE daemon_intent SET op_gen = 0"); // restore

    // Case: another writer holds the database. The tick is skipped, not fatal;
    // any other error is logged before it propagates.
    const context = { gen: 1, expectedOpGen: 0, watchState };
    const busy = Object.assign(new Error("database is locked"), { errcode: 5 });
    const locked = { prepare() { throw busy; } };
    assert.deepEqual(await pollCycle(locked, root, context, []), { action: "continue" });
    await assert.rejects(pollCycle({ prepare() { throw new Error("boom"); } }, root, context, []), /boom/);
    const log = readFileSync(join(root, "run", "agmsgd.log"), "utf8");
    assert.match(log, /database busy, retrying next poll/);
    assert.match(log, /unexpected error, exiting: Error: boom/);

    // Case: an in-place edit under scripts/ (the #963 case) with neither
    // the manifest nor the op_gen touched.
    writeFileSync(join(root, "scripts", "x.sh"), "tampered\n");
    verdict = await pollOnce(db, root, { gen: 1, expectedOpGen: 0, watchState });
    assert.equal(verdict.action, "step_aside");
    assert.equal(verdict.reason, "stepped_aside_for_update");

    db.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("gracefulStop: marks stopping, stops every channel hook, closes the socket, and records the reason", async () => {
  const { root } = makeInstall();
  try {
    const db = openInstallDb(join(root, "run", "install.db"));
    const started = await startup(db, {
      installRoot: root,
      expectedDesired: null,
      expectedOpGen: 0,
      version: "test",
      handlers: { onStop: async () => ({}), onStatus: async () => ({}) },
    });
    assert.equal(started.ok, true);

    let hookStopped = false;
    const hooks = [{ stop: async () => { hookStopped = true; } }];
    await gracefulStop(db, root, started.gen, started.controlHandle, hooks, "normal");

    assert.equal(hookStopped, true);
    const owner = readOwner(db);
    assert.equal(owner.state, "none");
    assert.equal(owner.last_end_reason, "normal");
    db.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("gracefulStop: a channel hook that throws is logged but does not stop the rest of shutdown", async () => {
  const { root } = makeInstall();
  try {
    const db = openInstallDb(join(root, "run", "install.db"));
    const started = await startup(db, {
      installRoot: root,
      expectedDesired: null,
      expectedOpGen: 0,
      version: "test",
      handlers: { onStop: async () => ({}), onStatus: async () => ({}) },
    });
    let secondHookRan = false;
    const hooks = [
      { stop: async () => { throw new Error("boom"); } },
      { stop: async () => { secondHookRan = true; } },
    ];
    await gracefulStop(db, root, started.gen, started.controlHandle, hooks, "normal");
    assert.equal(secondHookRan, true);
    assert.equal(readOwner(db).state, "none", "shutdown must still complete despite the throwing hook");
    db.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("channel setup is inside the prepared install lock and channel polls stay sequential", async () => {
  const { root } = makeInstall();
  try {
    const db = openInstallDb(join(root, "run", "install.db"));
    let released = false;
    const prepared = await prepareClaimWithCodexSchema(async () => ({
      db,
      release: () => { released = true; },
    }));
    assert.equal(released, false, "schema creation must finish before the caller releases the install lock");
    assert.doesNotThrow(() => db.prepare("SELECT state FROM beta_codex_seat").all());
    prepared.release();
    assert.equal(released, true);

    const order = [];
    await pollChannelHooks([
      { pollOnce: async () => { order.push("first:start"); await Promise.resolve(); order.push("first:end"); } },
      { pollOnce: async () => { order.push("second"); } },
    ]);
    assert.deepEqual(order, ["first:start", "first:end", "second"]);
    db.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("stepping aside for an update exits 0 so the service manager does not schedule a restart", () => {
  assert.equal(stopExitCode("stepped_aside_for_update"), 0);
  assert.equal(stopExitCode("normal"), 0);
  // The premise: both managers restart only after a failure, so exit 0 leaves the start to the installer.
  const script = readFileSync(join(import.meta.dirname, "..", "scripts", "daemon.sh"), "utf8");
  assert.match(script, /<key>SuccessfulExit<\/key><false\/>/);
  assert.match(script, /Restart=on-failure/);
});

test('a never-settling channel times out and the next channel and cycle still run', async () => {
  const logs = [];
  let runs = 0;
  const hooks = [{ name: 'stuck', pollOnce: () => new Promise(() => {}) }, { pollOnce: async () => { runs++; } }];
  await pollChannelHooks(hooks, line => logs.push(line), { timeoutMs: 15 });
  await pollChannelHooks(hooks, line => logs.push(line), { timeoutMs: 15 });
  assert.equal(runs, 2);
  assert.equal(logs.filter(line => line.includes('channel_poll_deadline')).length, 2);
});

test('a cycle deadline is visible in status and does not poison the next cycle', async () => {
  const { root, manifest, manifestText } = makeInstall();
  const db = openInstallDb(join(root, 'run', 'install.db'));
  try {
    const watchState = await captureWatchState(root, manifest, manifestText);
    const context = { gen: 1, expectedOpGen: 0, watchState, cycleDeadlineMs: 20, channelDeadlineMs: 100 };
    const hooks = [{ pollOnce: () => new Promise(() => {}) }];
    assert.deepEqual(await pollCycle(db, root, context, hooks), { action: 'continue' });
    assert.match(readFileSync(join(root, 'run', 'agmsgd.log'), 'utf8'), /poll_cycle_deadline/);
    assert.equal(JSON.parse(readFileSync(join(root, 'run', 'poll-timeout.json'))).reason, 'poll_cycle_deadline');
    assert.deepEqual(await pollCycle(db, root, context, []), { action: 'continue' });
  } finally { db.close(); rmSync(root, { recursive: true, force: true }); }
});

test('shutdown completes even when a channel stop never settles', async () => {
  const { root } = makeInstall();
  const db = openInstallDb(join(root, 'run', 'install.db'));
  try {
    const started = await startup(db, { installRoot: root, expectedDesired: null, expectedOpGen: 0, version: 'test', handlers: {} });
    let second = false;
    await gracefulStop(db, root, started.gen, started.controlHandle, [
      { stop: () => new Promise(() => {}) }, { stop: async () => { second = true; } },
    ], 'normal', { timeoutMs: 15 });
    assert.equal(second, true);
    assert.equal(readOwner(db).state, 'none');
    assert.match(readFileSync(join(root, 'run', 'agmsgd.log'), 'utf8'), /channel_stop_deadline/);
  } finally { db.close(); rmSync(root, { recursive: true, force: true }); }
});

for (const mode of ['signal', 'control', 'timer-shutdown-error']) {
  test(`main exits ${mode === 'timer-shutdown-error' ? 'with failure' : 'normally'} via ${mode} without leaving a live socket`, { timeout: 8000 }, async (t) => {
    if (mode === 'signal' && process.platform === 'win32') return t.skip('Windows does not deliver POSIX SIGTERM handlers');
    const { spawn } = await import('node:child_process');
    const { once } = await import('node:events');
    const { createConnection } = await import('node:net');
    const { root, manifest, manifestText } = makeInstall();
    const script = `
      import { main } from ${JSON.stringify(new URL('../scripts/daemon/main.mjs', import.meta.url).href)};
      import { openInstallDb } from ${JSON.stringify(new URL('../scripts/daemon/db.mjs', import.meta.url).href)};
      const db = openInstallDb(${JSON.stringify(join(root, 'run', 'install.db'))});
      const runtimeDb = ${mode === 'timer-shutdown-error' ? `new Proxy(db, { get(target, key) { if (key === 'prepare') return sql => { if (sql.includes("SET state = 'stopping'")) throw new Error('fixture shutdown database unavailable'); return target.prepare(sql); }; const value = target[key]; return typeof value === 'function' ? value.bind(target) : value; } })` : 'db'};
      await main(runtimeDb, { installRoot: ${JSON.stringify(root)}, manifest: ${JSON.stringify(manifest)}, manifestText: ${JSON.stringify(manifestText)}, expectedDesired: null, expectedOpGen: 0, version: 'test', pollIntervalMs: 15,
        createChannels: () => [{ name: 'stuck', pollOnce: () => { process.send('polling'); ${mode === 'timer-shutdown-error' ? `db.prepare('UPDATE daemon_intent SET op_gen = op_gen + 1').run(); return Promise.resolve();` : 'return new Promise(() => {});'} }, stop: () => new Promise(() => {}) }] });
    `;
    const child = spawn(process.execPath, ['--input-type=module', '-e', script], {
      env: { ...process.env, CODEX_HOME: join(root, 'profile') }, stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
    });
    let errors = '';
    child.stderr.on('data', data => { errors += data; });
    t.after(() => { if (child.exitCode === null) child.kill('SIGKILL'); });
    const exited = once(child, 'exit');
    await once(child, 'message');
    if (mode === 'signal') child.kill('SIGTERM');
    else if (mode === 'control') {
      const db = openInstallDb(join(root, 'run', 'install.db'));
      const owner = readOwner(db);
      db.close();
      const socket = createConnection(owner.socket);
      socket.on('data', () => {});
      await once(socket, 'connect');
      socket.write(JSON.stringify({ type: 'hello', role: 'control', protocol: 1 }) + '\n' + JSON.stringify({ type: 'stop' }) + '\n');
      await once(socket, 'end');
    }
    const [code] = await exited;
    assert.equal(code, mode === 'timer-shutdown-error' ? 1 : 0, errors);
    const db = openInstallDb(join(root, 'run', 'install.db'));
    if (mode !== 'timer-shutdown-error') assert.equal(readOwner(db).state, 'none');
    else assert.match(errors, /fixture shutdown database unavailable/);
    db.close();
    rmSync(root, { recursive: true, force: true });
  });
}
