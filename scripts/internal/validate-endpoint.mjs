#!/usr/bin/env node

import { validateEndpoint } from "./remote-sync.mjs";

const args = process.argv.slice(2);
// `--stdin` reads the endpoint from standard input instead of argv, for an
// endpoint that is itself a credential and must not sit in a process list.
let endpoint;
if (args.length === 1 && args[0] === "--stdin") {
  const { readFileSync } = await import("node:fs");
  endpoint = readFileSync(0, "utf8");
} else if (args.length === 1) {
  endpoint = args[0];
} else {
  console.error("agmsg: internal error: validate-endpoint.mjs needs exactly one argument");
  process.exit(1);
}

const result = validateEndpoint(endpoint);
if (!result.ok) {
  console.error(`agmsg: ${result.message}`);
  process.exit(1);
}
