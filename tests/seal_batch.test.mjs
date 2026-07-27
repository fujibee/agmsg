import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { driver } from "../scripts/internal/remote-sync.mjs";
import { runSealBatch, sealBatchParallelism,
  sealEnvelope } from "../scripts/internal/sync-cipher.mjs";

// cipher "none" is deterministic, so a batch envelope can be compared byte for
// byte against the single-request seal the driver used before. What is under
// test here is the scheduler and the worker fan-out, not the cipher; the age
// profile is covered by the shared vectors and by test_sync_cipher.bats.
function request(index) {
  return { type: "sync_seal", envelope_v: 1, cipher: "none", key_id: null, recipients: [],
    max_blob_bytes: 1_048_576, wire_id: randomUUID(),
    team_id: "018f3f7e-0000-7000-8000-000000000001", protocol_version: 1,
    projection: { body: `bulk message ${index} with a quote " and a backslash \\`,
      created_at: "2026-07-27T00:00:00.000000Z", from_agent: "alice", to_agent: "bob" } };
}

function collect(total) {
  const results = new Array(total).fill(null);
  const order = [];
  return { results, order,
    onResult(result) {
      assert.equal(results[result.index], null, `index ${result.index} was emitted twice`);
      results[result.index] = result;
      order.push(result.index);
    } };
}

test("a batch fans out over real worker threads and seals byte-identically", async () => {
  const requests = Array.from({ length: 64 }, (_, index) => request(index));
  const sink = collect(requests.length);
  await runSealBatch(requests, { onResult: sink.onResult });

  assert.equal(sink.order.length, requests.length);
  for (const [index, result] of sink.results.entries()) {
    assert.equal(result.status, "ok");
    assert.deepEqual(result.envelope, sealEnvelope(requests[index]));
  }
  // The point of the batch. If this ever runs everything on one thread the
  // envelopes are still correct and every other assertion here still passes —
  // so the fan-out has to be asserted directly.
  const threads = new Set(sink.results.map((result) => result.worker));
  assert.ok(threads.size > 1, `expected several worker threads, saw ${[...threads]}`);
  assert.ok(!threads.has(0), "no request should have been sealed on the main thread");
});

test("a short page stays on the calling thread", async () => {
  const requests = Array.from({ length: 4 }, (_, index) => request(index));
  const sink = collect(requests.length);
  await runSealBatch(requests, { onResult: sink.onResult });

  assert.deepEqual(sink.order, [0, 1, 2, 3]);
  assert.deepEqual(sink.results.map((result) => result.worker), [0, 0, 0, 0]);
  assert.equal(sealBatchParallelism(4, 16), 1);
});

test("parallelism is one worker per eight requests, capped at the core count", () => {
  assert.equal(sealBatchParallelism(1, 16), 1);
  assert.equal(sealBatchParallelism(7, 16), 1);
  assert.equal(sealBatchParallelism(8, 16), 1);
  assert.equal(sealBatchParallelism(16, 16), 2);
  assert.equal(sealBatchParallelism(1000, 16), 16);
  assert.equal(sealBatchParallelism(1000, 2), 2);
});

// A worker that stops answering — OOM-killed, a native crash inside age, a
// terminate from outside. The scheduler is driven through the injected spawn
// seam because a thread cannot be told to die at a chosen task from outside.
function dyingWorkerFactory({ dieAfter, only = null }) {
  let spawned = 0;
  return () => {
    const id = (spawned += 1);
    const worker = new EventEmitter();
    let handled = 0;
    worker.postMessage = ({ index, request: value }) => {
      handled += 1;
      if ((only === null || only === id) && handled > dieAfter) {
        // Death is asynchronous, exactly as a real worker's 'exit' is: the task
        // is already in flight and its promise is pending.
        setImmediate(() => worker.emit("exit", 1));
        return;
      }
      setImmediate(() => worker.emit("message",
        { index, worker: 100 + id, status: "ok", envelope: sealEnvelope(value) }));
    };
    worker.terminate = () => {};
    return worker;
  };
}

test("a worker that dies mid-batch loses none of its messages", async () => {
  const requests = Array.from({ length: 40 }, (_, index) => request(index));
  const sink = collect(requests.length);
  await runSealBatch(requests, { parallelism: 4, onResult: sink.onResult,
    spawnWorker: dyingWorkerFactory({ dieAfter: 3, only: 2 }) });

  assert.equal(sink.order.length, requests.length, "every request must produce exactly one result");
  for (const [index, result] of sink.results.entries()) {
    assert.equal(result.status, "ok", `index ${index}: ${result.message ?? ""}`);
    assert.deepEqual(result.envelope, sealEnvelope(requests[index]));
  }
  assert.ok(sink.results.some((result) => result.worker === 102),
    "the doomed worker should have sealed something before dying");
});

test("a batch whose whole pool dies still seals every message", async () => {
  const requests = Array.from({ length: 40 }, (_, index) => request(index));
  const sink = collect(requests.length);
  await runSealBatch(requests, { parallelism: 4, onResult: sink.onResult,
    spawnWorker: dyingWorkerFactory({ dieAfter: 0 }) });

  assert.equal(sink.order.length, requests.length);
  for (const [index, result] of sink.results.entries()) {
    assert.equal(result.status, "ok");
    assert.deepEqual(result.envelope, sealEnvelope(requests[index]));
  }
  // Nothing survived to seal on, so the caller's thread finished the page.
  assert.deepEqual([...new Set(sink.results.map((result) => result.worker))], [0]);
});

test("a request that no worker can complete is reported, not dropped", async () => {
  const requests = Array.from({ length: 12 }, (_, index) => request(index));
  const sink = collect(requests.length);
  // Every worker dies on its first task, and the pool is large enough that the
  // scheduler exhausts MAX_ATTEMPTS on the first index before it runs dry.
  await runSealBatch(requests, { parallelism: 3, onResult: sink.onResult,
    spawnWorker: dyingWorkerFactory({ dieAfter: 0 }) });

  assert.equal(sink.order.length, requests.length);
  assert.deepEqual([...new Set(sink.order)].sort((a, b) => a - b),
    requests.map((_, index) => index));
});

// The seal progress a bulk page reports travels driver stderr -> engine stderr.
// The engine used to hold driver stderr back and only quote it in a failure
// message, which would have made "progress" arrive after the work was over.
test("driver stderr is forwarded to the operator, not only quoted on failure", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "agmsg-driver-stderr-"));
  const script = join(scratch, "fake-driver.sh");
  await writeFile(script, ["#!/usr/bin/env bash",
    "printf 'agmsg: sealing 5/10 (50%%)\\n' >&2",
    "printf '{\"type\":\"sync_state\"}\\n'", ""].join("\n"), { mode: 0o700 });

  const captured = [];
  const realWrite = process.stderr.write.bind(process.stderr);
  process.stderr.write = (chunk) => { captured.push(String(chunk)); return true; };
  process.env.AGMSG_SYNC_DRIVER = script;
  try {
    await driver("prepare", { local_team: "demo", server_instance_id: "s",
      remote_team_id: "r", protocol_version: 1 }, [], ["10"]);
  } finally {
    process.stderr.write = realWrite;
    delete process.env.AGMSG_SYNC_DRIVER;
    await rm(scratch, { recursive: true });
  }
  assert.match(captured.join(""), /agmsg: sealing 5\/10 \(50%\)/u);
});

test("one malformed request fails alone and the rest of the page seals", async () => {
  const requests = Array.from({ length: 24 }, (_, index) => request(index));
  requests[7].wire_id = "not-a-uuid";
  const sink = collect(requests.length);
  await runSealBatch(requests, { parallelism: 3, onResult: sink.onResult });

  assert.equal(sink.results[7].status, "error");
  assert.equal(sink.results[7].state, "malformed");
  for (const [index, result] of sink.results.entries()) {
    if (index === 7) continue;
    assert.equal(result.status, "ok");
    assert.deepEqual(result.envelope, sealEnvelope(requests[index]));
  }
});
