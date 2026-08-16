#!/usr/bin/env node

// Stand-in cipher helper: records the wire id of every seal request the driver
// makes — including the ones a crash keeps out of the store — then delegates to
// the real helper. Mirrors the real helper's modes, so `seal` takes one request
// object and `seal-batch` takes one request per line.

import { appendFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import process from "node:process";

const args = process.argv.slice(2);
const mode = args[0] ?? "seal";
let input = "";
for await (const chunk of process.stdin) input += chunk;
const requests = mode === "seal-batch" ?
  input.split(/\r?\n/u).filter(Boolean).map((line) => JSON.parse(line)) : [JSON.parse(input)];
for (const request of requests) {
  appendFileSync(process.env.AGMSG_SYNC_TEST_WIRE_LOG, `${request.wire_id}\n`, { mode: 0o600 });
}
const result = spawnSync(process.execPath,
  [process.env.AGMSG_SYNC_REAL_CIPHER_HELPER, ...args], { input, maxBuffer: 64 * 1024 * 1024 });
process.stdout.write(result.stdout);
process.stderr.write(result.stderr);
process.exitCode = result.status ?? 1;
