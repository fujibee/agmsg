#!/usr/bin/env node
import { lstat, open, readFile, rename, unlink } from "node:fs/promises";
import { join } from "node:path";
import process from "node:process";
import { createHash } from "node:crypto";

const [root, oldTeam, newTeam, mode, expectedSource, expectedTarget] = process.argv.slice(2);
if (!root || !oldTeam || !newTeam || (mode && !["--plan", "--resume"].includes(mode))) {
  throw new Error("usage: rename-sync-config.mjs <storage-root> <old-team> <new-team> [--plan | --resume <source-hash> <target-hash>]");
}
const directory = join(root, "remote-sync");
const source = join(directory, `${encodeURIComponent(oldTeam)}.json`);
const target = join(directory, `${encodeURIComponent(newTeam)}.json`);
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
async function syncDirectory() {
  if (process.platform === "win32") return;
  const handle = await open(directory, "r");
  try { await handle.sync(); } finally { await handle.close(); }
}
async function privateFile(file) {
  let metadata;
  try { metadata = await lstat(file); }
  catch (error) { if (error?.code === "ENOENT") return null; throw error; }
  if (metadata.isSymbolicLink()) throw new Error("remote sync config must not be a symbolic link");
  if (!metadata.isFile()) throw new Error("remote sync config must be a regular file");
  if (process.platform !== "win32" && (metadata.mode & 0o077) !== 0) {
    throw new Error("remote sync config must not be readable or writable by group or others");
  }
  return readFile(file);
}
const prior = await privateFile(source);
const published = await privateFile(target);
if (mode === "--resume") {
  if (![expectedSource, expectedTarget].every((value) => value === "absent" || /^[a-f0-9]{64}$/.test(value ?? ""))) {
    throw new Error("invalid remote sync operation fingerprints");
  }
  if (prior && digest(prior) !== expectedSource) throw new Error("source remote sync config differs from operation");
  if (published && digest(published) !== expectedTarget) throw new Error("target remote sync config differs from operation");
  if (published) {
    if (prior) await unlink(source);
    await syncDirectory();
    process.exit(0);
  }
  if (!prior && expectedSource === "absent" && expectedTarget === "absent") process.exit(0);
  if (!prior) throw new Error("recorded remote sync config is missing");
} else if (published) {
  throw new Error("target remote sync config already exists");
}
if (!prior) {
  if (mode === "--plan") console.log(JSON.stringify({ source: "absent", target: "absent" }));
  process.exit(0);
}
const config = JSON.parse(prior.toString("utf8"));
if (config.local_team !== oldTeam) throw new Error("remote sync config local team mismatch");
config.local_team = newTeam;
const planned = `${JSON.stringify(config, null, 2)}\n`;
if (mode === "--plan") {
  console.log(JSON.stringify({ source: digest(prior), target: digest(planned) }));
  process.exit(0);
}
if (mode === "--resume" && digest(planned) !== expectedTarget) {
  throw new Error("planned remote sync config differs from operation");
}
const temporary = `${target}.${process.pid}.tmp`;
const handle = await open(temporary, "wx", 0o600);
try {
  await handle.writeFile(planned, "utf8");
  await handle.sync();
} finally {
  await handle.close();
}
try {
  await rename(temporary, target);
  await unlink(source);
  await syncDirectory();
} catch (error) {
  try { await unlink(temporary); } catch {}
  throw error;
}
