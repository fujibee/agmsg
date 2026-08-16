import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { driver } from "../scripts/internal/remote-sync.mjs";
import { runSealBatch, sealBatchParallelism, sealBatchWindows,
  sealEnvelope } from "../scripts/internal/sync-cipher.mjs";

const HELPER = fileURLToPath(new URL("../scripts/internal/sync-cipher.mjs", import.meta.url));

// Run the helper CLI end to end. The point of several of these tests is what
// the process does with a stream it has not finished reading, so the input has
// to arrive on a real pipe.
function runHelper(args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [HELPER, ...args], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}

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

// A page is bounded by its message count, but a body is legal up to
// max_blob_bytes, so a legal 1000-message page can be a gigabyte. Holding all
// of it would turn input a caller is entitled to send into an OOM.
test("a streamed batch is cut into windows bounded by count and by bytes", async () => {
  const lines = Array.from({ length: 10 }, (_, index) => JSON.stringify(request(index)));

  const byCount = [];
  for await (const window of sealBatchWindows(lines, { requests: 4, bytes: 1 << 30 })) {
    byCount.push(window.length);
  }
  assert.deepEqual(byCount, [4, 4, 2]);

  // Byte-bounded: each line here is well over the limit, so no window may hold
  // more than the one request that crossed it.
  const byBytes = [];
  for await (const window of sealBatchWindows(lines, { requests: 1000, bytes: 8 })) {
    byBytes.push(window.length);
  }
  assert.deepEqual(byBytes, Array.from({ length: 10 }, () => 1));
});

test("the byte bound counts utf-8 bytes, not utf-16 code units", async () => {
  const value = request(0);
  value.projection.body = "ほ".repeat(500);
  const line = JSON.stringify(value);
  assert.ok(Buffer.byteLength(line, "utf8") > line.length * 2, "fixture must be multi-byte");

  const windows = [];
  for await (const window of sealBatchWindows(Array(4).fill(line),
    { requests: 1000, bytes: line.length + 50 })) {
    windows.push(window.length);
  }
  // Each line alone is past the bound in bytes. Counted as code units it would
  // take two of them, and the window would hold twice what it was told to.
  assert.deepEqual(windows, [1, 1, 1, 1]);
});

test("windowing does not renumber results the caller has to match up", async () => {
  // Bodies large enough that the real byte bound cuts the batch into several
  // windows; indices must still run 0..n-1 across the whole input.
  const big = "x".repeat(600_000);
  const requests = Array.from({ length: 30 }, (_, index) => {
    const value = request(index);
    value.projection.body = `${index}:${big}`;
    return value;
  });
  const { code, stdout } = await runHelper(["seal-batch", String(requests.length)],
    `${requests.map((value) => JSON.stringify(value)).join("\n")}\n`);
  const results = stdout.split("\n").filter(Boolean).map((line) => JSON.parse(line));

  assert.equal(code, 0);
  assert.equal(results.length, requests.length);
  assert.deepEqual(results.map((result) => result.index).sort((a, b) => a - b),
    requests.map((_, index) => index));
  for (const result of results) {
    assert.equal(result.status, "ok");
    assert.deepEqual(result.envelope, sealEnvelope(requests[result.index]));
  }
});

// A thread that cannot be created at all — the process is out of them, the
// system is out of memory. Distinct from a thread that dies while working, and
// it used to escape the fallback entirely: spawning happened before the
// try/finally, so a throw skipped both the cleanup and the main-thread sweep.
test("a pool that cannot be spawned still seals every message", async () => {
  const requests = Array.from({ length: 20 }, (_, index) => request(index));
  for (const failFrom of [0, 2]) {
    const sink = collect(requests.length);
    let spawned = 0;
    await runSealBatch(requests, { parallelism: 4, onResult: sink.onResult,
      spawnWorker: () => {
        if (spawned >= failFrom) throw new Error("EAGAIN: cannot create thread");
        spawned += 1;
        return dyingWorkerFactory({ dieAfter: 1000 })();
      } });

    assert.equal(sink.order.length, requests.length, `failFrom=${failFrom}`);
    for (const [index, result] of sink.results.entries()) {
      assert.equal(result.status, "ok");
      assert.deepEqual(result.envelope, sealEnvelope(requests[index]));
    }
  }
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
