#!/usr/bin/env node

import { validateEndpoint } from "./remote-sync.mjs";

const args = process.argv.slice(2);
if (args.length !== 1) {
  console.error("agmsg: internal error: validate-endpoint.mjs needs exactly one argument");
  process.exit(1);
}

const result = validateEndpoint(args[0]);
if (!result.ok) {
  console.error(`agmsg: ${result.message}`);
  process.exit(1);
}
