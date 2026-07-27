#!/usr/bin/env node
// Cross-platform benchmark for the real sealing path (sealEnvelope), used to
// size the "bulk seal an existing team's whole history" experience.
//
// Measures the FULL engine path -- canonical JSON projection, header/binding
// validation, plaintext framing, and the per-message `age` subprocess spawn --
// not bare `age`. The driver IPC is deliberately excluded: remote-sync.mjs
// invokes the storage driver once per BATCH, so it does not multiply per
// message.
//
// Usage:
//   node bench/seal-bench.mjs --n 400 --parallel 8 --recipient age1...
//   node bench/seal-bench.mjs --worker ...        (internal)
//
// Emits one JSON object per run on stdout.
//
// Message sizes are synthesized from the observed dogfood distribution
// (N=878 real agmsg messages: mean 778 B, p50 565 B, p90 1625 B, p99 3405 B,
// max 6895 B) rather than shipping real message text. Only the size profile
// matters here -- age's cost is dominated by process spawn, and no real
// content or per-message metadata leaves the machine that produced it.

import { spawn } from "node:child_process";
import { cpus } from "node:os";
import { fileURLToPath } from "node:url";
import process from "node:process";

const SELF = fileURLToPath(import.meta.url);
const { sealEnvelope } = await import(
  new URL("../scripts/internal/sync-cipher.mjs", import.meta.url).href
);

const TEAM_ID = "018f1e2a-1234-7abc-89ab-0123456789ab"; // valid UUIDv7 shape

// Piecewise-linear inverse CDF through the observed percentiles above.
const SIZE_QUANTILES = [
  [0.0, 6],
  [0.25, 330],
  [0.5, 565],
  [0.75, 1002],
  [0.9, 1625],
  [0.99, 3405],
  [1.0, 6895],
];

function sizeAt(q) {
  for (let i = 1; i < SIZE_QUANTILES.length; i += 1) {
    const [q1, s1] = SIZE_QUANTILES[i];
    if (q <= q1) {
      const [q0, s0] = SIZE_QUANTILES[i - 1];
      const t = q1 === q0 ? 0 : (q - q0) / (q1 - q0);
      return Math.max(1, Math.round(s0 + t * (s1 - s0)));
    }
  }
  return SIZE_QUANTILES[SIZE_QUANTILES.length - 1][1];
}

// Deterministic low-discrepancy sweep of the quantile axis, so every worker
// and every platform seals the same size profile regardless of slice size.
function sizeForIndex(i) {
  const golden = 0.618033988749895;
  return sizeAt((0.5 + i * golden) % 1);
}

const ALPHABET = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,-\n";

function bodyOfSize(n, seed) {
  let out = "";
  let x = (seed * 2654435761) >>> 0;
  for (let i = 0; i < n; i += 1) {
    x = (x * 1664525 + 1013904223) >>> 0;
    out += ALPHABET[x % ALPHABET.length];
  }
  return out;
}

function inputFor(i, recipient) {
  const second = i % 60;
  const minute = Math.floor(i / 60) % 60;
  const hour = Math.floor(i / 3600) % 24;
  const stamp = `2026-01-01T${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}:${String(second).padStart(2, "0")}.000000Z`;
  return {
    type: "sync_seal",
    envelope_v: 1,
    max_blob_bytes: 1_048_576,
    wire_id: crypto.randomUUID(),
    team_id: TEAM_ID,
    protocol_version: 1,
    cipher: "age-v1",
    key_id: "epoch-bench-1",
    recipients: [recipient],
    projection: {
      body: bodyOfSize(sizeForIndex(i), i),
      created_at: stamp,
      from_agent: "bench-sender",
      to_agent: "bench-receiver",
    },
  };
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) {
        out[key] = true;
      } else {
        out[key] = next;
        i += 1;
      }
    }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const recipient = args.recipient || process.env.BENCH_RECIPIENT;
if (!recipient) {
  console.error("seal-bench: --recipient (or BENCH_RECIPIENT) is required");
  process.exit(2);
}

function stats(samples) {
  const s = [...samples].sort((a, b) => a - b);
  const n = s.length;
  const at = (q) => s[Math.min(n - 1, Math.floor(n * q))];
  return {
    n,
    mean_ms: +(s.reduce((a, b) => a + b, 0) / n).toFixed(4),
    min_ms: +s[0].toFixed(3),
    p50_ms: +at(0.5).toFixed(3),
    p90_ms: +at(0.9).toFixed(3),
    p99_ms: +at(0.99).toFixed(3),
    max_ms: +s[n - 1].toFixed(3),
  };
}

if (args.worker) {
  const start = Number(args.start || 0);
  const count = Number(args.count || 0);
  // Warm up outside the measured window: the first spawn in a fresh process
  // pays page-cache and loader costs that do not recur.
  sealEnvelope(inputFor(start, recipient));
  const samples = [];
  const t0 = performance.now();
  for (let i = 0; i < count; i += 1) {
    const input = inputFor(start + i, recipient);
    const s0 = performance.now();
    sealEnvelope(input);
    samples.push(performance.now() - s0);
  }
  const wall = performance.now() - t0;
  process.stdout.write(JSON.stringify({ worker: true, wall_ms: wall, ...stats(samples) }) + "\n");
  process.exit(0);
}

const total = Number(args.n || 400);
const parallel = args.parallel === "cpus" ? cpus().length : Number(args.parallel || 1);
const label = args.label || `p${parallel}`;

const slices = [];
let assigned = 0;
for (let k = 0; k < parallel; k += 1) {
  const count = Math.floor(total / parallel) + (k < total % parallel ? 1 : 0);
  slices.push({ start: assigned, count });
  assigned += count;
}

const t0 = performance.now();
const results = await Promise.all(
  slices.map(
    ({ start, count }) =>
      new Promise((resolve, reject) => {
        const child = spawn(
          process.execPath,
          [SELF, "--worker", "--start", String(start), "--count", String(count), "--recipient", recipient],
          { stdio: ["ignore", "pipe", "inherit"], env: process.env },
        );
        let buf = "";
        child.stdout.on("data", (d) => {
          buf += d;
        });
        child.on("error", reject);
        child.on("close", (code) => {
          if (code !== 0) return reject(new Error(`worker exited ${code}`));
          try {
            resolve(JSON.parse(buf.trim().split("\n").pop()));
          } catch (e) {
            reject(e);
          }
        });
      }),
  ),
);
const wall = performance.now() - t0;

const sealed = results.reduce((a, r) => a + r.n, 0);
const meanInner =
  results.reduce((a, r) => a + r.mean_ms * r.n, 0) / sealed;

console.log(
  JSON.stringify({
    label,
    platform: process.platform,
    arch: process.arch,
    node: process.versions.node,
    cpus: cpus().length,
    parallel,
    messages: sealed,
    wall_ms: +wall.toFixed(1),
    effective_ms_per_msg: +(wall / sealed).toFixed(4),
    msgs_per_sec: +((sealed / wall) * 1000).toFixed(1),
    in_worker_mean_ms: +meanInner.toFixed(4),
    workers: results.map((r) => ({ n: r.n, mean_ms: r.mean_ms, p50_ms: r.p50_ms, p90_ms: r.p90_ms, p99_ms: r.p99_ms, max_ms: r.max_ms })),
    projected_90k_minutes: +(((wall / sealed) * 90000) / 1000 / 60).toFixed(2),
  }),
);
