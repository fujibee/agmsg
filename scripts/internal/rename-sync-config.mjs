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
if (!metadata.isFile() || metadata.isSymbolicLink() ||
    (process.platform !== "win32" && (metadata.mode & 0o077) !== 0)) {
  throw new Error("remote sync config must be a private regular file");
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
