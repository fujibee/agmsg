import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { classify, readOwnerAndIntentReadOnly } from "../scripts/daemon/status.mjs";
import { openInstallDb } from "../scripts/daemon/db.mjs";

const baseOwner = { gen: 1, version: "1.6.0", socket: "/tmp/x.sock" };

test("enabled intent never reports a never-started or dead executor as healthy", () => {
  for (const owner of [{ ...baseOwner, gen: 0, state: "none" }, { ...baseOwner, state: "ready" }]) {
    const result = classify({ owner, intent: { desired: "on" }, alive: false, reachable: true,
      lastAttempt: { reason: "restart limit reached" } });
    assert.equal(result.exitCode, 1);
    assert.match(result.text, /restart limit reached/);
    assert.match(result.text, /agmsg daemon start/);
    assert.match(result.text, /agmsg daemon disable/);
  }
});

test("a digest-mismatch start failure advises --update instead of daemon start (#1761)", () => {
  const r = classify({ owner: { ...baseOwner, state: "none" }, intent: { desired: "on" }, alive: false, reachable: true,
    lastAttempt: { reason: "digest verification failed: digest mismatch: scripts/daemon/schema.sql" } });
  assert.equal(r.exitCode, 1);
  assert.match(r.text, /install\.sh --update/);
  assert.match(r.text, /npx agmsg@latest install --update/);
  assert.doesNotMatch(r.text, /\(recommended\)/);
});

test("ready + reachable -> running, exit 0", () => {
  const r = classify({ owner: { ...baseOwner, state: "ready" }, intent: { desired: "on" }, alive: true, reachable: true });
  assert.equal(r.exitCode, 0);
  assert.match(r.text, /running/);
});

test("ready + NOT reachable -> exit 1, names the mismatch", () => {
  const r = classify({ owner: { ...baseOwner, state: "ready" }, intent: { desired: "on" }, alive: true, reachable: false });
  assert.equal(r.exitCode, 1);
  assert.match(r.text, /does not answer/);
});

test("starting, alive, within 30s grace -> exit 0; past grace or dead -> exit 1", () => {
  const now = Date.now();
  const recent = new Date(now - 5_000).toISOString();
  const old = new Date(now - 60_000).toISOString();

  let r = classify(
    { owner: { ...baseOwner, state: "starting", started_at: recent }, intent: {}, alive: true },
    now,
  );
  assert.equal(r.exitCode, 0);

  r = classify(
    { owner: { ...baseOwner, state: "starting", started_at: old }, intent: {}, alive: true },
    now,
  );
  assert.equal(r.exitCode, 1, "past the 30s grace window must warn even while alive");

  r = classify(
    { owner: { ...baseOwner, state: "starting", started_at: recent }, intent: {}, alive: false },
    now,
  );
  assert.equal(r.exitCode, 1, "a confirmed-dead executor must warn even within the grace window");

  r = classify(
    { owner: { ...baseOwner, state: "starting", started_at: recent }, intent: {}, alive: null },
    now,
  );
  assert.equal(r.exitCode, 1, "undetermined liveness must warn, not pass silently");
});

test("none + intent off -> exit 0, names it as deliberate", () => {
  const r = classify({ owner: { ...baseOwner, gen: 3, state: "none" }, intent: { desired: "off", set_at: "t" }, alive: null });
  assert.equal(r.exitCode, 0);
  assert.match(r.text, /not in use/);
});

test("none + gen 0 (never started) -> exit 0, never says 'not installed'", () => {
  const r = classify({ owner: { ...baseOwner, gen: 0, state: "none" }, intent: {}, alive: null });
  assert.equal(r.exitCode, 0);
  assert.match(r.text, /never been started/);
  assert.doesNotMatch(r.text, /not installed/i);
});

test("none + bind_failed last_end -> exit 1, names the reason", () => {
  const r = classify({
    owner: { ...baseOwner, state: "none", last_end_reason: "bind_failed", last_end_at: "t", last_end_gen: 1 },
    intent: { desired: "on" },
    alive: null,
  });
  assert.equal(r.exitCode, 1);
  assert.match(r.text, /failed to start/);
});

test("none + stepped_aside_for_update -> exit 1, says the new version has not started", () => {
  const r = classify({
    owner: { ...baseOwner, state: "none", last_end_reason: "stepped_aside_for_update", last_end_at: "t" },
    intent: { desired: "on" },
    alive: null,
  });
  assert.equal(r.exitCode, 1);
  assert.match(r.text, /stopped for an update/);
});

test("none + intent on + normal stop -> exit 1, distinct from no-recorded-intent", () => {
  let r = classify({
    owner: { ...baseOwner, state: "none", last_end_reason: "normal" },
    intent: { desired: "on" },
    alive: null,
  });
  assert.equal(r.exitCode, 1);
  assert.match(r.text, /intent is on/);

  r = classify({
    owner: { ...baseOwner, state: "none", last_end_reason: "normal" },
    intent: {},
    alive: null,
  });
  assert.equal(r.exitCode, 1);
  assert.match(r.text, /No intent/);

  // Never collapse a real problem into exit 0.
  assert.notEqual(r.exitCode, 0);
});

test("a start refusal from before the current owner's claim is not the last attempt (read-only status)", () => {
  const root = mkdtempSync(join(tmpdir(), "agmsgd-status-"));
  mkdirSync(join(root, "run"));
  const db = openInstallDb(join(root, "run", "install.db"));
  try {
    db.prepare("INSERT INTO daemon_start_attempts (at, reason, executor_pid) VALUES (?, ?, ?)")
      .run("2000-01-01T00:00:00.000Z", "intent changed since the launcher read it", 1);
    // A running owner: claimed after that refusal, never ended.
    db.prepare("UPDATE daemon_owner SET gen = 1, state = 'ready', executor_pid = ?, started_at = ?, executor_started_at = ?, last_end_at = NULL")
      .run(process.pid, "2026-01-01T00:00:00.000Z", "2026-01-01T00:00:00.000Z");
  } finally {
    db.close();
  }
  assert.equal(readOwnerAndIntentReadOnly(root).lastAttempt, undefined);
  const again = openInstallDb(join(root, "run", "install.db"));
  try {
    again.prepare("INSERT INTO daemon_start_attempts (at, reason, executor_pid) VALUES (?, ?, ?)")
      .run("2026-06-01T00:00:00.000Z", "no usable Node found", 2);
  } finally {
    again.close();
  }
  assert.equal(readOwnerAndIntentReadOnly(root).lastAttempt.reason, "no usable Node found");
});
