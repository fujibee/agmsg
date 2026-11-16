// Read-only view of grok-build seat registrations and their SessionStart/
// Stop witness files (see scripts/internal/grok-session-witness.sh / its two
// wrapper scripts). Mirrors codex-queue-store.mjs's listCodexRegistrations
// shape, narrowed to type === "grok-build".

import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";

// Same shape as terminal-poke-store.mjs's own table (review precedent,
// #1973): seat-poll.mjs's createSeatPoller reads `${prefix}_queue` by seat
// to emit sent/expired log events, for every registered channel, so each
// channel needs this even when (as here) acceptance is observed
// synchronously within one nudge call rather than reconciled across polls.
export const GROK_QUEUE_CHANNEL_SCHEMA = `
CREATE TABLE IF NOT EXISTS beta_grok_queue_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  seat TEXT NOT NULL,
  up_to TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'confirmed', 'expired')),
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS beta_grok_queue_queue_one_pending
  ON beta_grok_queue_queue(seat) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS beta_grok_queue_queue_latest
  ON beta_grok_queue_queue(seat, id DESC);
`;

export function ensureGrokQueueChannelSchema(db) {
  db.exec("BEGIN IMMEDIATE;");
  try {
    db.exec(GROK_QUEUE_CHANNEL_SCHEMA);
    db.exec("COMMIT;");
  } catch (error) {
    try { db.exec("ROLLBACK;"); } catch { /* preserve the schema error */ }
    throw error;
  }
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return { missing: true };
    return { unreadable: true, reason: error.message };
  }
}

// The most recent registration of type grok-build, scanning from the END
// of the array -- same shape as terminal-poke-store.mjs's own
// latestNonNativeRegistration. A seat can carry more than one historical
// registration (re-joins for a different project), and the LATEST one's
// project is the one that is actually live -- an older entry's project is
// not what optedOutOfAgmsgd (keyed by exact project path) should be asked
// about (the review on #1979: listGrokRegistrations never returned a
// project at all, so an opted-out seat's choice never matched and it kept
// getting delivered to via a stale witness).
function latestGrokRegistration(registrations) {
  if (!Array.isArray(registrations)) return null;
  for (let index = registrations.length - 1; index >= 0; index -= 1) {
    if (registrations[index]?.type === "grok-build") return registrations[index];
  }
  return null;
}

// Enumerates only roles whose current registration explicitly names
// grok-build. Mirrors listCodexRegistrations's own malformed-team handling
// (#1973 review precedent): one bad team is reported under `skipped`, every
// other team is still enumerated.
export function listGrokRegistrations(teamsDir) {
  let entries;
  try {
    entries = readdirSync(teamsDir, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return { state: "ok", seats: [] };
    return { state: "unreadable", reason: "team_roster_unreadable" };
  }
  const seats = [];
  const skipped = [];
  for (const entry of entries) {
    if (entry.isSymbolicLink()) {
      skipped.push({ team: entry.name, reason: "team_roster_symlink" });
      continue;
    }
    if (!entry.isDirectory()) continue;
    const config = readJson(join(teamsDir, entry.name, "config.json"));
    if (config?.missing) continue;
    if (config?.unreadable || !config || typeof config !== "object" || !config.agents || typeof config.agents !== "object" || Array.isArray(config.agents)) {
      skipped.push({ team: entry.name, reason: "team_roster_malformed" });
      continue;
    }
    for (const [agent, value] of Object.entries(config.agents)) {
      const regs = value && Array.isArray(value.registrations) ? value.registrations : [];
      const registration = latestGrokRegistration(regs);
      if (registration) {
        seats.push({ team: entry.name, agent, project: registration.project ?? "", teamConfig: config });
      }
    }
  }
  return { state: "ok", seats, skipped };
}

// Same key scheme as grok-session-witness.sh's agmsg_grok_witness_key:
// SHA-1 of "<team>\x1f<agent>", computed with node:crypto so both sides
// agree on a MACHINE WITH A REAL SHA-1 TOOL on the bash side (see that
// file's own comment on agmsg_sha1's cksum fallback -- an extremely bare
// machine lacking shasum/sha1sum/openssl is the one case these could
// disagree, and is out of scope here).
export function grokWitnessKey(team, agent) {
  return createHash("sha1").update(`${team}\x1f${agent}`, "utf8").digest("hex");
}

export function grokWitnessPath(installRoot, team, agent) {
  return join(installRoot, "run", `grok-seat.${grokWitnessKey(team, agent)}.json`);
}

// Linux real-machine round (2026-11-15): grok-session-start.sh's own
// bounded active_sessions.json retry, and grok-stop.sh's own one-shot
// attempt at the end of the first turn, can both still come up empty --
// previously reported only to stderr, which grok discards for a passive
// hook, so the reason was otherwise invisible. Read here so `agmsg daemon
// status` can show it (class D) instead.
export function grokPendingPath(installRoot, team, agent) {
  return join(installRoot, "run", `grok-seat-pending.${grokWitnessKey(team, agent)}`);
}

// Returns the recorded reason text, or "" when no pending-reason file
// exists (the common case: either a witness exists, or neither hook has
// ever run for this seat yet). Unreadable is folded into "" too -- there
// is nothing more specific to say than the witness's own "missing" state
// already says.
export function readGrokPendingReason(installRoot, team, agent) {
  try {
    return readFileSync(grokPendingPath(installRoot, team, agent), "utf8").trim();
  } catch {
    return "";
  }
}

// Reads one seat's witness file. Returns:
//   { state: "ok", witness: {...} }               -- read and parsed
//   { state: "missing" }                           -- no SessionStart has run yet
//   { state: "unreadable", reason }                -- present but unusable
export function readGrokWitness(installRoot, team, agent) {
  const path = grokWitnessPath(installRoot, team, agent);
  const parsed = readJson(path);
  if (parsed?.missing) return { state: "missing" };
  if (parsed?.unreadable || typeof parsed !== "object" || parsed === null) {
    return { state: "unreadable", reason: parsed?.reason ?? "witness_malformed" };
  }
  const required = ["session_id", "pid", "leader_socket", "first_turn_done"];
  if (required.some((key) => !(key in parsed))) {
    return { state: "unreadable", reason: "witness_incomplete" };
  }
  return { state: "ok", witness: parsed };
}

// agmsg turns on use_leader (see lib/grok-config.sh), so the leader socket's
// own directory permissions are the one thing worth a status warning here --
// group/other access to it means another local account could reach this
// seat's leader. This is observational only: §10 (automatic stops need the
// maintainer's own decision, 2026-10-31) means a lax permission is reported,
// never refused -- delivery still proceeds. Returns true when the socket's
// PARENT directory is readable/writable/searchable by group or other
// (POSIX mode bits 0o077); false when it is already 0700-or-tighter, or
// when the directory cannot be statted at all (nothing to warn about that
// is actually known).
export function leaderSocketDirIsLax(leaderSocketPath) {
  try {
    const stat = statSync(dirname(leaderSocketPath));
    return (stat.mode & 0o077) !== 0;
  } catch {
    return false;
  }
}
