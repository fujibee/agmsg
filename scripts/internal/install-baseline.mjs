import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";

// The installation can be updated while an engine runs (#963): the engine
// would then execute updated scripts from code held in memory from before the
// update, and used to find out only by running a half-written driver script.
//
// What counts as an update is the installer's own record, not the state of the
// scripts/ tree. install.sh moves the completion record aside before it touches
// scripts/ and writes the new one and VERSION when it is done; an engine that
// sees either move has been updated under. A file added or edited under
// scripts/ by hand is not an update: the code in memory and on disk is the
// code it started from, and a stood-down sync engine does not come back by
// itself (#1863). The agmsgd daemon makes the same distinction.
//
// The failure direction is deliberate, in both phases: an OBSERVATION
// failure is not evidence.
//   - Baseline phase: VERSION cannot be read, or the record cannot be read
//     for a reason other than being absent -> the detector stays OFF (null).
//     A record that is absent at start (an install older than the record) is a
//     valid baseline; the record appearing later is then the install finishing.
//   - Check phase: a read that fails for any reason but the record being
//     absent proves nothing.
//
// scriptsRoot is <install>/scripts; the record and VERSION sit beside it.
async function readText(path, readFileCall) {
  try { return { text: await readFileCall(path, "utf8") }; }
  catch (error) { return { error }; }
}

export async function collectInstallBaseline(scriptsRoot, dependencies = {}) {
  const readFileCall = dependencies.readFileCall ?? readFile;
  const installRoot = dirname(scriptsRoot);
  const version = await readText(join(installRoot, "VERSION"), readFileCall);
  if (version.error) return null; // incomplete observation: the detector stays OFF
  const record = await readText(join(installRoot, "run", "install-manifest.json"), readFileCall);
  if (record.error && record.error.code !== "ENOENT") return null;
  return { version: version.text, record: record.error ? null : record.text };
}

// Returns the path whose change proves an update, or null.
export async function installChangedAgainst(scriptsRoot, baseline, dependencies = {}) {
  const readFileCall = dependencies.readFileCall ?? readFile;
  const installRoot = dirname(scriptsRoot);
  const recordPath = join(installRoot, "run", "install-manifest.json");
  const record = await readText(recordPath, readFileCall);
  if (record.error) {
    // Moved aside while an install runs: that is the update starting. Any other
    // failure to read it is no evidence either way.
    if (record.error.code === "ENOENT" && baseline.record !== null) return recordPath;
  } else if (record.text !== baseline.record) {
    return recordPath;
  }
  const versionPath = join(installRoot, "VERSION");
  const version = await readText(versionPath, readFileCall);
  if (!version.error && version.text !== baseline.version) return versionPath;
  return null;
}
