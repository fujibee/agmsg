#!/usr/bin/env node

// Stand-in cipher helper that records how the driver called it — one log line
// per invocation, "<mode> <request count>" — then delegates to the real helper.
// Lets a test assert that a page was sealed by ONE batched call rather than one
// helper process per message.

import { appendFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import process from "node:process";

const args = process.argv.slice(2);
const mode = args[0] ?? "seal";
let input = "";
for await (const chunk of process.stdin) input += chunk;
const count = mode === "seal-batch" ? input.split(/\r?\n/u).filter(Boolean).length : 1;
appendFileSync(process.env.AGMSG_SYNC_TEST_INVOCATION_LOG, `${mode} ${count}\n`, { mode: 0o600 });
const result = spawnSync(process.execPath,
  [process.env.AGMSG_SYNC_REAL_CIPHER_HELPER, ...args], { input, maxBuffer: 64 * 1024 * 1024 });
process.stdout.write(result.stdout);
process.stderr.write(result.stderr);
process.exitCode = result.status ?? 1;
