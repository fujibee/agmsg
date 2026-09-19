#!/usr/bin/env node
import { lstat, open, readFile, rename, unlink } from "node:fs/promises";
import { join } from "node:path";
import process from "node:process";

const [root, oldTeam, newTeam] = process.argv.slice(2);
if (!root || !oldTeam || !newTeam) {
  throw new Error("usage: rename-sync-config.mjs <storage-root> <old-team> <new-team>");
}
const directory = join(root, "remote-sync");
const source = join(directory, `${encodeURIComponent(oldTeam)}.json`);
const target = join(directory, `${encodeURIComponent(newTeam)}.json`);
try {
  await lstat(target);
  throw new Error("target remote sync config already exists");
} catch (error) {
  if (error?.code !== "ENOENT") throw error;
}
let metadata;
try {
  metadata = await lstat(source);
} catch (error) {
  if (error?.code === "ENOENT") process.exit(0);
  throw error;
}
// Each condition names itself, and the mode test is last so that no message
// above it can be about permissions -- on win32 that test does not run at all,
// and a message about privacy was the one thing a Windows operator could not
// act on (#781, same shape as remote-sync.mjs).
if (metadata.isSymbolicLink()) {
  throw new Error(`remote sync config must not be a symbolic link: ${source}`);
}
if (!metadata.isFile()) {
  throw new Error(`remote sync config must be a regular file: ${source}`);
}
if (process.platform !== "win32" && (metadata.mode & 0o077) !== 0) {
  throw new Error(
    `remote sync config must not be readable or writable by group or others: ${source}`);
}
const config = JSON.parse(await readFile(source, "utf8"));
if (config.local_team !== oldTeam) throw new Error("remote sync config local team mismatch");
config.local_team = newTeam;
const temporary = `${target}.${process.pid}.tmp`;
const handle = await open(temporary, "wx", 0o600);
try {
  await handle.writeFile(`${JSON.stringify(config, null, 2)}\n`, "utf8");
  await handle.sync();
} finally {
  await handle.close();
}
try {
  await rename(temporary, target);
  await unlink(source);
  if (process.platform !== "win32") {
    const directoryHandle = await open(directory, "r");
    try { await directoryHandle.sync(); } finally { await directoryHandle.close(); }
  }
} catch (error) {
  try { await unlink(temporary); } catch {}
  throw error;
}
