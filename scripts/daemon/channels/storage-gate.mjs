#!/usr/bin/env node
// Exit 0 only when agmsgd's Claude channel will accept this install's storage
// config. It calls the channel's own reader (readStorageDriver) with the same
// config path the channel resolves, so the answer cannot drift from the
// daemon's rules. Used by actas-claim.sh and the claude-code SessionStart plug
// before they declare the native channel (and drop the Monitor).
import { homedir } from "node:os";
import { join } from "node:path";
import { readStorageDriver } from "./codex-queue-store.mjs";

try {
  const configPath = process.env.AGMSG_CONFIG || join(homedir(), ".agents", "agmsg", "config.json");
  const driver = readStorageDriver(configPath);
  process.exit(driver.state === "ok" && driver.driver === "sqlite" ? 0 : 1);
} catch {
  process.exit(1);
}
