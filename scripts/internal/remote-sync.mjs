#!/usr/bin/env node
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { spawn } from "node:child_process";
import { appendFile, lstat, mkdir, open, readFile, readdir, rename, rm, rmdir, stat, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve, sep } from "node:path";
import process from "node:process";
import { closeSync, mkdtempSync, openSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { ageExecutableVersion, CipherStateError, openEnvelope,
  readNativeAgeIdentity } from "./sync-cipher.mjs";
import { parseStrictJson, parseStrictJsonl } from "./strict-jsonl.mjs";
export { parseStrictJson, parseStrictJsonl } from "./strict-jsonl.mjs";

const UUID_V7 = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const SEQUENCE = /^(0|[1-9][0-9]*)$/;
const TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const PROTOCOL = "1";
const MAX_SEQUENCE = 9_223_372_036_854_775_807n;
const MAX_CONNECTION_CONFIG_BYTES = 2 * 1024 * 1024;
// Held here as well as on the server, and deliberately not read from the
// answer: a bound a server can raise by saying so is not a bound. If the two
// ever disagree, the client refuses rather than accepts the larger list.
const MAX_TEAMS_PER_NAME = 16;

function usage() {
  return `usage:
  remote-sync.sh configure --team NAME --server URL --team-id UUID --minimum-security e2ee-required \\
    --cipher age-v1 --age-snapshot FILE [--age-snapshot FILE ...] \\
    --age-checkpoint REVISION:SHA256 \\
    --age-confirmation operator-live \\
    [--age-identity KEY_ID=FILE ...]
  remote-sync.sh export-age-snapshot --team NAME [--out FILE]
  remote-sync.sh verify-age-snapshot --team NAME --age-snapshot FILE
  remote-sync.sh export-age-handoff --team NAME --out FILE
  remote-sync.sh verify-age-handoff --team NAME --bundle FILE --out-dir DIRECTORY
  remote-sync.sh once --team NAME [--limit N]
  remote-sync.sh run --team NAME [--limit N] [--interval SECONDS]
  remote-sync.sh reprocess --team NAME [--limit N]
  remote-sync.sh resync --team NAME --accept-floor SEQUENCE
  remote-sync.sh unblock-read --team NAME --member-id UUID
  remote-sync.sh set-endpoint --team NAME

Run remote.sh connect first. The engine reads that team's connection binding
directly; the remote-sync data plane carries no per-request credential — see
docs/design/remote-sync.md.`;
}

function options(args) {
  const result = { _: [] };
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (!value.startsWith("--")) { result._.push(value); continue; }
    const next = args[index + 1];
    if (next === undefined || next.startsWith("--")) throw new Error(`missing value for ${value}`);
    const key = value.slice(2);
    if (key === "age-identity" || key === "age-snapshot") {
      if (!Array.isArray(result[key])) result[key] = [];
      result[key].push(next);
    } else {
      result[key] = next;
    }
    index += 1;
  }
  return result;
}

function requireName(value, label) {
  if (typeof value !== "string" || [...value].length < 1 || [...value].length > 128 ||
      value.startsWith("-") || value === "." || value === ".." ||
      /[./\\"\[\]\u0000-\u001f\u007f]/u.test(value) || value !== value.normalize("NFC")) {
    throw new Error(`${label} is invalid`);
  }
  return value;
}

function sequence(value, label) {
  if (typeof value !== "string" || !SEQUENCE.test(value) || BigInt(value) > MAX_SEQUENCE) {
    throw new Error(`${label} is not a canonical sequence`);
  }
  return value;
}

function configPath(team) {
  const root = process.env.AGMSG_SYNC_STORAGE_DIR;
  if (!root) throw new Error("AGMSG_SYNC_STORAGE_DIR is not set");
  return join(root, "remote-sync", `${encodeURIComponent(team)}.json`);
}

function teamConfigPath(team) {
  const connectionRoot = process.env.AGMSG_SYNC_CONNECTION_DIR ?? process.env.SKILL_DIR;
  if (!connectionRoot) throw new Error("sync connection root is unavailable");
  return join(connectionRoot, "teams", team, "config.json");
}

function replacementIdentityPath(team, epoch) {
  const connectionRoot = process.env.AGMSG_SYNC_CONNECTION_DIR ?? process.env.SKILL_DIR;
  if (!connectionRoot) throw new Error("sync connection root is unavailable");
  return join(connectionRoot, "run", "remote-credentials", team, "keys", `${epoch}.key`);
}

function rosterJournalPath(team) {
  return join(dirname(teamConfigPath(team)), "roster.jsonl");
}

// Where the engine records that a cycle has actually completed.
//
// `status` could report `connected (engine running, pid N)` forever while every
// cycle failed, because a live process is all it could see. The engine knows the
// difference and had nowhere to put it: the fact existed only in the log, and
// `status` deliberately does not read the log for state -- the one place it does
// is the start handshake, which is bounded and immediate. A rolling log is the
// wrong source for a durable claim (#756).
//
// It sits beside the pidfile, in the same run directory and derived the same
// way, because it has the same lifetime: both describe this engine, and both are
// meaningless once it is gone.
function cycleStampPath(team) {
  const connectionRoot = process.env.AGMSG_SYNC_CONNECTION_DIR ?? process.env.SKILL_DIR;
  if (!connectionRoot) throw new Error("sync connection root is unavailable");
  return join(connectionRoot, "run", `remote-sync.${team}.cycles.json`);
}

// Written after a cycle returns, which is the only place a cycle is known to
// have completed. Best-effort on purpose: an unwritable run directory must not
// take down syncing, which is the thing that is working. The cost of failing to
// write is that `status` under-reports -- it says "no cycle recorded" when one
// happened -- and that direction is the safe one. Claiming a success that did
// not happen is the failure this exists to prevent.
async function recordCycleSuccess(team, at, writeFileCall = writeFile) {
  try {
    const path = cycleStampPath(team);
    let first = at;
    try {
      const existing = JSON.parse(await readFile(path, "utf8"));
      if (typeof existing?.first_success_at === "string") first = existing.first_success_at;
    } catch { /* no stamp yet, or unreadable: this cycle is the first we can name */ }
    await writeFileCall(path, `${JSON.stringify({
      type: "sync_cycle_stamp", first_success_at: first, last_success_at: at,
    })}\n`);
  } catch { /* best-effort: never fail a working cycle over its own bookkeeping */ }
}

// A refusal the caller can act on, recorded where something can read it (#773).
//
// A remote may answer a write with a status meaning "the caller must do
// something" rather than "try again later". The engine used to treat that as a
// transport failure: not retryable, so it left the loop, and the process
// exited. `status` then said "engine stopped -- run: remote.sh sync start",
// which invites the one action that cannot work; starting it again produces
// the same refusal and the same exit, for as long as the server's answer
// stands.
//
// THE REASON WAS NEVER MISSING. `event()` writes `fatal` to stdout and
// `sync start` captures it into `run/remote-sync.<team>.log`, with a
// timestamp, at a known path. What was missing is a place to READ it from:
// `status` opens a pidfile and the cycle stamp, and nothing an agent consults
// mentions the log. So this is one more fact beside the cycle stamp, not a new
// mechanism -- the same move #760 made.
//
// WHAT IS STORED, AND WHAT IS DELIBERATELY NOT.
//
// Stored: the status, the code, the time, and the host from the endpoint the
// config already holds. Verbatim, as the server said them.
//
// Not stored: any sentence about what the refusal MEANS or what to do about
// it. This engine talks to *a* remote -- self-hosted, someone else's, or a
// service -- and it cannot know why a particular one refused. A sentence it
// invents is wrong for some server. Interpretation belongs to whoever operates
// that server, and the host is there so a reader knows who that is.
function refusalPath(team) {
  const connectionRoot = process.env.AGMSG_SYNC_CONNECTION_DIR ?? process.env.SKILL_DIR;
  if (!connectionRoot) throw new Error("sync connection root is unavailable");
  return join(connectionRoot, "run", `remote-sync.${team}.refusal.json`);
}

/**
 * A refusal is a 4xx the retry policy does not cover.
 *
 * BY CLASS, NOT BY NUMBER. There is one such status in use today, and it is
 * deliberately not named anywhere in this file — not in the code and not in
 * this comment, which a check enforces. A server may refuse for reasons this
 * protocol never enumerates, and every one of them is "the server decided, and
 * said so" rather than "ask again later"; naming one would invite the next
 * reader to special-case it, and the one after that to add a sentence about
 * what it means.
 *
 * Everything in the 4xx range that the retry policy does not cover lands here,
 * for that same reason. 5xx stays a transport failure and the retryable
 * statuses stay retryable, because `isRetryable` is asked first.
 *
 * 5xx stays a transport failure, and the retryable 4xx (408, 429) stay
 * retryable, because `isRetryable` is asked first.
 */
/** The host of an endpoint, or null when it cannot be read as a URL. */
function hostOf(endpoint) {
  try {
    return new URL(endpoint).host;
  } catch {
    return null;
  }
}

export function isRefusal(error) {
  const status = error?.status;
  if (typeof status !== "number") return false;
  if (isRetryable(error)) return false;
  return status >= 400 && status < 500;
}

/**
 * Write the refusal down. Best-effort, like the cycle stamp and for the same
 * reason: bookkeeping must never be the thing that takes syncing down.
 */
async function recordRefusal(team, fact, writeFileCall = writeFile) {
  try {
    await writeFileCall(refusalPath(team), `${JSON.stringify({
      type: "sync_refusal", ...fact,
    })}\n`);
  } catch { /* best-effort */ }
}

/**
 * Forget it, because a cycle has since succeeded.
 *
 * A refusal that outlives its truth is worse than no record: `status` would
 * keep reporting a server decision that has been reversed, and the operator
 * would keep acting on it.
 *
 * BEST-EFFORT, AND NOT WHAT MAKES THAT TRUE. This removal can fail — an
 * unwritable run directory, a permission change, a crash between the two
 * writes — and it is deliberately not retried or escalated, for the same
 * reason `recordCycleSuccess` is not: bookkeeping must never take down a cycle
 * that worked.
 *
 * What makes the guarantee hold is on the READING side: `remote.sh` compares
 * the record to the last successful cycle and reports nothing older. Deleting
 * can fail; comparing cannot. An earlier version of this comment said the two
 * facts were written in the same place and so could never disagree — they are,
 * and they still could, because one of the two writes is allowed to fail
 * (raised in review).
 */
async function clearRefusal(team, rmCall = rm) {
  try {
    await rmCall(refusalPath(team), { force: true });
  } catch { /* best-effort */ }
}

// What actually went wrong, when the thing that threw is a wrapper.
//
// `fetch` rejects with a bare `TypeError: fetch failed` whose own `code` is
// undefined; the diagnosis is one level down, in `cause`. Reporting
// `error.code ?? null` therefore logged `{"message":"fetch failed","code":null}`
// once a second, forever, for a TLS trust failure that Node had already named
// (`DEPTH_ZERO_SELF_SIGNED_CERT`, `UNABLE_TO_VERIFY_LEAF_SIGNATURE`, …). The
// operator who hit this had to reproduce the request by hand with curl and with
// a raw Node client to find out which one was refusing the certificate (#744).
//
// The chain is walked rather than read one level deep because an agent-wrapped
// or proxied request nests further. The depth bound is what makes that safe: a
// cause chain is not guaranteed to be a tree, and `a.cause = b; b.cause = a` is
// reachable from user-supplied errors. A visited-set was tried here as well and
// removed — with the bound in place it changes no output, and a mechanism no
// test can distinguish is one the next reader has to reason about for nothing.
function causeOf(error) {
  let current = error;
  let code = current?.code ?? null;
  let cause = null;
  for (let depth = 0; depth < 8 && current?.cause; depth += 1) {
    current = current.cause;
    if (code === null && current?.code !== undefined) code = current.code;
    if (typeof current?.message === "string" && current.message !== "") cause = current.message;
  }
  return { code, ...(cause === null ? {} : { cause }) };
}

async function journalKeyRotations(config) {
  let records;
  try {
    records = parseStrictJsonl(await readFile(rosterJournalPath(config.local_team), "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
  const sequences = new Map(records.filter((record) =>
    record.type === "roster_synced" &&
    record.server_instance_id === config.server_instance_id &&
    record.remote_team_id === config.remote_team_id)
    .map((record) => [record.mutation_id, sequence(record.server_seq, "key rotation server sequence")]));
  return records.filter((record) => record.type === "key_rotated" && sequences.has(record.id))
    .map((record) => ({ ...record, server_seq: sequences.get(record.id) }))
    .sort((left, right) => BigInt(left.server_seq) < BigInt(right.server_seq) ? -1 :
      BigInt(left.server_seq) > BigInt(right.server_seq) ? 1 : 0);
}

export async function activateKeyRotations(config) {
  const rotations = await journalKeyRotations(config);
  if (rotations.length === 0) {
    config.age_v1_runtime_history = [];
    return;
  }
  if (config.cipher_profile !== "age-v1" || !config.age_v1) {
    throw new Error("key rotation requires an age-v1 sync configuration");
  }
  const ageSnapshots = ageSnapshotChain(config.age_v1);
  const base = ageSnapshots[0].history;
  let revision = BigInt(base.at(-1).epoch_revision);
  const winners = [];
  const announcedEpochs = new Set();
  for (const rotation of rotations) {
    if (!UUID_V7.test(rotation.id ?? "") ||
        !SEQUENCE.test(rotation.epoch ?? "") ||
        BigInt(rotation.epoch) > MAX_SEQUENCE ||
        !/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(rotation.key_id ?? "") ||
        !/^[0-9a-f]{64}$/u.test(rotation.fingerprint ?? "")) {
      throw new Error("key rotation journal record is invalid");
    }
    if (BigInt(rotation.epoch) <= revision || announcedEpochs.has(rotation.epoch)) continue;
    announcedEpochs.add(rotation.epoch);
    winners.push(rotation);
  }
  const runtime = [];
  for (const rotation of winners) {
    const expectedRevision = revision + 1n;
    if (BigInt(rotation.epoch) !== expectedRevision) {
      throw new Error(
        `key rotation epoch ${rotation.epoch} is not the next epoch ${expectedRevision}`);
    }
    const ageSnapshot = ageSnapshots[Number(expectedRevision)];
    if (!ageSnapshot && await provisionLocalAgeSnapshot(config, rotation)) {
      ageSnapshots.push(ageSnapshotChain(config.age_v1).at(-1));
    }
    const confirmedAgeSnapshot = ageSnapshots[Number(expectedRevision)];
    if (!confirmedAgeSnapshot) {
      throw new Error(
        `key rotation at server sequence ${rotation.server_seq} selected epoch ` +
        `${rotation.epoch}; import its authority-confirmed epoch snapshot before sync can continue`);
    }
    if (BigInt(rotation.server_seq) === MAX_SEQUENCE) {
      throw new Error("key rotation cannot be activated at the final server sequence");
    }
    const epoch = confirmedAgeSnapshot.history.at(-1);
    const effectiveFrom = (BigInt(rotation.server_seq) + 1n).toString();
    if (epoch.epoch_revision !== rotation.epoch ||
        epoch.key_id !== rotation.key_id ||
        epoch.effective_from_seq !== effectiveFrom ||
        epoch.recipients.length !== 1 ||
        createHash("sha256").update(epoch.recipients[0], "utf8").digest("hex") !==
          rotation.fingerprint) {
      throw new Error(
        `authority-confirmed epoch snapshot ${rotation.epoch} does not match ` +
        `the key rotation at server sequence ${rotation.server_seq}`);
    }
    const identityPath = replacementIdentityPath(config.local_team, rotation.key_id);
    try {
      await lstat(identityPath);
    } catch (error) {
      if (error?.code === "ENOENT") {
        throw new Error(
          `key rotation at server sequence ${rotation.server_seq} selected epoch ` +
          `${rotation.epoch} with key_id=${rotation.key_id}; import that key out of band ` +
          "before sync can continue");
      }
      throw error;
    }
    const identity = readNativeAgeIdentity(identityPath);
    if (identity.recipient !== epoch.recipients[0]) {
      throw new Error(
        `replacement key ${rotation.key_id} for epoch ${rotation.epoch} does not match ` +
        "the authority-confirmed recipient manifest");
    }
    revision = expectedRevision;
    config.age_v1.identity_files[rotation.key_id] = identityPath;
    runtime.push(epoch);
  }
  config.age_v1_runtime_history = runtime;
}

// Whether this endpoint may be used, with the operator-facing reason when it
// may not. Connect, pull and continued sync all call this implementation; a
// second parser used to approximate it and disagreed in five separate ways
// (#722).
//
// The rule is "IP literal in a private range", not "loopback". What the strict
// parsing exists to stop is a NAME dressed as a safe host —
// `127.0.0.1.evil.com` reads like loopback and resolves wherever its owner
// points it. A literal has no such gap: what is written is where the
// connection goes. So names stay https-only (`localhost` excepted) and a LAN
// address over http is allowed, because two machines on a network you control
// talking over http is ordinary and should not require a tunnel.
//
// It takes the RAW endpoint, not a parsed hostname, and that is the whole
// difficulty. `new URL("http://2130706433/").hostname` is "127.0.0.1" — the
// platform helpfully rewrites decimal, hex and zero-padded octal forms into
// dotted quads, so a check on the parsed host accepts spellings a reader would
// never recognise as an address. The former Python entry validator rejected
// those spellings while Node accepted them. Measured: five forms disagreed
// before both call sites were moved to this raw-input implementation.
//
// The premise of the whole rule is "what is written in the URL is where the
// connection goes". A form that has to be decoded first is not that.
const GENERAL_HTTP_REFUSAL =
  "--endpoint must be https://, or http:// to a private IP address " +
  "(10/8, 172.16/12, 192.168/16, 169.254/16, 127/8, ::1, fc00::/7, " +
  "fe80::/10). Over plaintext http the message bodies of a team synced " +
  "without encryption cross the network in the clear. Either use https://, " +
  "or give the LAN IP of the server instead of a name " +
  "(http://192.168.1.10:8787), or connect with --e2ee so the contents are " +
  "sealed before they leave this machine.";

function rejected(message) {
  return { ok: false, message };
}

function rawAuthority(rawEndpoint) {
  return /^[a-z][a-z0-9+.-]*:\/\/([^/?#]*)/i.exec(rawEndpoint)?.[1];
}

function rawZoneHost(authority) {
  if (!authority?.startsWith("[")) return null;
  const end = authority.indexOf("]");
  if (end < 0) return null;
  const host = authority.slice(1, end);
  return host.includes("%") ? host : null;
}

function zoneRefusal(host) {
  return rejected(
    "--endpoint cannot carry an IPv6 zone index " +
    `(the '%...' part of '${host}'). Write the address without the zone ` +
    "(http://[fe80::1]:8787), or use another address. The zone names an " +
    "interface on this machine, and the URL parser the sync engine uses " +
    "rejects it outright — accepting it here would let the team connect " +
    "and then fail on every sync.",
  );
}

export function validateEndpoint(rawEndpoint) {
  // The WHATWG parser DELETES ASCII tab and newline (and trims leading and
  // trailing C0/space) before parsing, so a URL carrying them can validate
  // while the raw string -- which is what gets stored in the binding and
  // later read back line-wise by consumers such as `remote status` -- still
  // contains them. The premise of this validator (stated above) is that what
  // is written in the URL is where the connection goes; a byte the parser
  // silently removes breaks that premise, so it is refused rather than
  // repaired (#849 review).
  if (/[\u0000-\u001f\u007f]/.test(rawEndpoint)) {
    return rejected(
      "--endpoint must not contain control characters " +
      "(tab, newline, any byte below 0x20, or DEL)",
    );
  }
  const authority = rawAuthority(rawEndpoint);
  if (authority === undefined) {
    return rejected("--endpoint must start with https:// (or http:// to a private IP address)");
  }
  const zoneHost = rawZoneHost(authority);
  if (zoneHost !== null) return zoneRefusal(zoneHost);

  let url;
  try {
    url = new URL(rawEndpoint);
  } catch {
    if (authority !== undefined) {
      const hostPort = authority.includes("@") ? authority.slice(authority.lastIndexOf("@") + 1) : authority;
      const port = hostPort.startsWith("[")
        ? hostPort.slice(hostPort.indexOf("]") + 1)
        : hostPort.includes(":") ? hostPort.slice(hostPort.lastIndexOf(":")) : "";
      if (port.startsWith(":") && port.length > 1) {
        return rejected("--endpoint has an invalid port (must be a number from 0 to 65535)");
      }
      if (/\s|%(?![0-9a-f]{2})/i.test(hostPort)) {
        return rejected("--endpoint has a malformed host");
      }
    }
    return rejected("--endpoint could not be parsed as a URL");
  }
  if (url.protocol === "https:") return { ok: true };
  if (url.protocol !== "http:") {
    return rejected("--endpoint must start with https:// (or http:// to a private IP address)");
  }
  // `http://evil.com@192.168.1.1/` parses with host 192.168.1.1; the userinfo
  // is what a reader's eye lands on. The connect-time validator refuses these
  // outright and so does this, rather than relying on the host check behind it.
  if (url.username || url.password) {
    return rejected("--endpoint must not contain userinfo (user@ or user:pass@)");
  }

  if (authority === undefined || authority.includes("@")) {
    return rejected("--endpoint must not contain userinfo (user@ or user:pass@)");
  }

  let host;
  if (authority.startsWith("[")) {
    const end = authority.indexOf("]");
    if (end < 0) return rejected("--endpoint could not be parsed as a URL");
    host = authority.slice(1, end).toLowerCase();
  } else {
    host = authority.split(":")[0].toLowerCase();
    // Each octet is a bare decimal with NO leading zero. `\d{1,3}` would take
    // `192.168.01.1` and Number() would read `01` as 1, so it would pass here
    // while the former Python entry validator rejected it (found in review).
    // A leading zero is also how the octal forms are
    // written, and the point of this rule is that the address is readable as
    // written — `01` is not.
    const v4 = /^(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$/.exec(host);
    if (host === "localhost") return { ok: true };
    if (!v4) return rejected(GENERAL_HTTP_REFUSAL); // a name, or a form needing decoding
    const octets = v4.slice(1).map(Number);
    if (octets.some((o) => o > 255)) return rejected(GENERAL_HTTP_REFUSAL);
    const [a, b] = octets;
    if (a === 127) return { ok: true };                        // 127/8 loopback
    if (a === 10) return { ok: true };                         // 10/8
    if (a === 172 && b >= 16 && b <= 31) return { ok: true };  // 172.16/12
    if (a === 192 && b === 168) return { ok: true };           // 192.168/16
    if (a === 169 && b === 254) return { ok: true };           // 169.254/16 link-local
    return rejected(GENERAL_HTTP_REFUSAL);
  }

  const groups = ipv6Groups(host);
  if (groups === null) return rejected(GENERAL_HTTP_REFUSAL);
  // ::1
  if (groups.slice(0, 7).every((g) => g === 0) && groups[7] === 1) return { ok: true };
  const first = groups[0];
  if (first >= 0xfc00 && first <= 0xfdff) return { ok: true };  // fc00::/7 unique local
  if (first >= 0xfe80 && first <= 0xfebf) return { ok: true };  // fe80::/10 link-local
  return rejected(GENERAL_HTTP_REFUSAL);
}

// An IPv6 literal as eight numeric groups, or null when it is not one.
//
// Numeric, because the prefixes here are numeric ranges and the spelling does
// not track them: `fc::1` starts with the group 0x00fc, which is nowhere near
// fc00::/7, yet reads like it. A check on the leading characters accepts it —
// measured, that is what the first version of this did, and Node hands the
// short form through unchanged. `fe8::1` is the same trap against fe80::/10.
//
// Forms carrying an embedded IPv4 (`::ffff:192.168.1.1`) contain dots, fail the
// character test, and are refused.
function ipv6Groups(host) {
  if (!/^[0-9a-f:]+$/.test(host)) return null;
  const halves = host.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves.length === 2 ? (halves[1] ? halves[1].split(":") : []) : null;
  let groups;
  if (tail === null) {
    groups = head;
    if (groups.length !== 8) return null;
  } else {
    const fill = 8 - head.length - tail.length;
    if (fill < 0) return null;
    groups = [...head, ...new Array(fill).fill("0"), ...tail];
  }
  if (groups.some((g) => !/^[0-9a-f]{1,4}$/.test(g))) return null;
  return groups.map((g) => parseInt(g, 16));
}

// Exported so the endpoint rule can be exercised through the path production
// actually takes. A test that calls the helper directly leaves the CALL SITE
// unbound: revert this function to its old inline loopback list and every such
// test stays green while continued sync refuses LAN addresses again. That is
// the failure this whole change exists to prevent, so the test drives it from
// here (#717, review).
export function connectedBinding(value, team) {
  const binding = value?.remote_binding;
  if (value?.name !== team || !binding || typeof binding !== "object" ||
      typeof binding.endpoint !== "string" || binding.endpoint.length < 1 ||
      !UUID_V7.test(binding.server_instance_id ?? "") ||
      !UUID_V7.test(binding.remote_team_id ?? "") || binding.protocol_version !== 1 ||
      typeof binding.connected_at !== "string" || Number.isNaN(Date.parse(binding.connected_at)) ||
      binding.disconnected_at !== null || !binding.capabilities ||
      !Array.isArray(binding.capabilities.write_allowed_ciphers) ||
      binding.capabilities.write_allowed_ciphers.some((cipher) => typeof cipher !== "string")) {
    throw new Error("connected team binding is invalid or disconnected");
  }
  if (!validateEndpoint(binding.endpoint).ok) {
    throw new Error(
      "connected team endpoint must use HTTPS, or HTTP to a private IP address " +
      "(10/8, 172.16/12, 192.168/16, 169.254/16, 127/8, ::1, fc00::/7)");
  }
  endpoint(binding.endpoint, "/v1/health");
  return binding;
}

// What disqualifies a file this process is about to trust, said in the words of
// the condition that actually failed -- or null when nothing does.
//
// One function rather than a condition here and a sentence there. The two had
// drifted: the sentence named a permission problem while the condition had
// already excluded permissions on win32 (#781), so a Windows operator who hit a
// missing file, a symlink or an oversized one was told to go and look at modes
// that platform never carried. Someone did, after the same message on Linux had
// been a real `0664`. The message was right once and wrong once, for the same
// bytes.
//
// Returning the fault instead of throwing lets each caller name its own subject
// while the reason stays derived from the check that produced it.
export function authorityFileFault(stats, { maxBytes, privateFile }) {
  if (stats.isSymbolicLink()) return "must not be a symbolic link";
  if (!stats.isFile()) return "must be a regular file";
  if (maxBytes !== undefined && stats.size > maxBytes) {
    return `must not be larger than ${maxBytes} bytes (it is ${stats.size})`;
  }
  // POSIX modes only. Windows does not carry them, so this is not consulted
  // there -- and because it is the LAST thing consulted, no message above can
  // be about it. That ordering is the fix, not a detail of it.
  if (process.platform !== "win32" && (stats.mode & (privateFile ? 0o077 : 0o022)) !== 0) {
    // The mode it HAS, not only the mode it may not have. An operator reading
    // "must not be writable by group or others" cannot tell whether they are
    // looking at 0664 or 0666 or a directory bit, and the two remedies differ.
    // Printed the way `chmod` and `ls` speak, four digits, so it can be
    // compared with what `stat` prints without arithmetic.
    const mode = (stats.mode & 0o7777).toString(8).padStart(4, "0");
    return privateFile
      ? `must not be readable or writable by group or others (it is ${mode})`
      : `must not be writable by group or others (it is ${mode})`;
  }
  return null;
}

// The command that clears the fault above, or null when there is nothing to
// type. Same conditions, same function pair, deliberately: the sentence and
// the condition drifted apart once already (#781), and a remedy derived by
// re-reading the SENTENCE would drift the same way the moment the wording
// changes. This re-asks the stats.
//
// Only the permission fault has one. A symlink, a directory or an oversized
// file are not fixed by a mode change, and offering `chmod` for them would send
// someone to do the wrong thing confidently.
//
// `go-w` and `go-rwx` rather than `644` and `600`: the check is about the group
// and other bits, so the remedy touches those and leaves the owner's alone. A
// numeric mode would also silently strip a read bit the operator meant to keep.
// A path as ONE shell argument, for a command someone is expected to paste and
// run. Same scheme as scripts/lib/shquote.sh: wrap in single quotes and replace
// each embedded ' with '\'' -- close the quote, emit an escaped literal quote,
// reopen it.
//
// Not cosmetic. A team name is validated only against empty / `.` / `..` / `/`
// / `\` / a leading `-` / control characters (lib/validate.sh), so a space and
// a single quote are both legal in one, and the store lives under $HOME, which
// is outside our control entirely. An unquoted path turns the remedy we printed
// into a command that operates on a DIFFERENT file, or on several -- the worst
// possible outcome for a line whose whole job is "run this and you are fixed".
export function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

export function authorityFileRemedy(stats, { privateFile }) {
  if (process.platform === "win32") return null;
  if (stats.isSymbolicLink() || !stats.isFile()) return null;
  if ((stats.mode & (privateFile ? 0o077 : 0o022)) === 0) return null;
  return privateFile ? "chmod go-rwx" : "chmod go-w";
}
// One sentence, built in one place. `authorityFileFault` exists as a single
// function because the wording and the condition drifted apart once (#781);
// two call sites assembling the sentence around it is the same hazard one level
// out. Measured: unquoting the path at only the checkpoint site left the whole
// suite green, because nothing drove that site -- so the pin has to be on the
// construction, not on each caller.
//
// The remedy goes last, so the sentence still reads as a diagnosis first. An
// operator who already knows what to do stops at the path; one who does not
// gets a line to paste, quoted, about the file that is actually wrong.
export function authorityFileError(subject, path, stats, { maxBytes, privateFile }) {
  // `maxBytes` is forwarded, not dropped. Omitting it made this return null for
  // an oversized file whose caller had already decided there WAS a fault, and
  // the caller then threw that null. The suite caught it; the lesson is that a
  // wrapper around a predicate has to take every argument the predicate reads.
  const fault = authorityFileFault(stats, { maxBytes, privateFile });
  if (!fault) return null;
  const remedy = authorityFileRemedy(stats, { privateFile });
  return new Error(
    `${subject} ${fault}: ${path}` +
    (remedy ? ` — fix it with: ${remedy} ${shellQuote(path)}` : ""));
}


async function readBoundedAuthorityFile(path, maxBytes, privateFile) {
  const before = await lstat(path);
  const fault = authorityFileFault(before, { maxBytes, privateFile });
  if (fault) {
    // The path too: the previous message named a property without naming what
    // had it, on a machine that may hold several.
    throw authorityFileError(
      privateFile ? "remote credential" : "connected team binding",
      path, before, { maxBytes, privateFile });
  }
  const handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const metadata = await handle.stat();
    const changed = !metadata.isFile() || metadata.dev !== before.dev || metadata.ino !== before.ino ||
      metadata.size > maxBytes || (process.platform !== "win32" &&
      (metadata.mode & (privateFile ? 0o077 : 0o022)) !== 0);
    if (changed) throw new Error("connection authority changed while it was being opened");
    const chunks = [];
    let total = 0;
    for (;;) {
      const buffer = Buffer.alloc(Math.min(64 * 1024, maxBytes - total + 1));
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, null);
      if (bytesRead === 0) break;
      total += bytesRead;
      if (total > maxBytes) throw new Error("connection authority exceeds its byte limit");
      chunks.push(buffer.subarray(0, bytesRead));
    }
    return Buffer.concat(chunks);
  } finally {
    await handle.close();
  }
}

async function readConnectedBinding(team) {
  const bytes = await readBoundedAuthorityFile(
    teamConfigPath(team), MAX_CONNECTION_CONFIG_BYTES, false);
  const source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  return connectedBinding(parseStrictJson(source), team);
}

function ageTrustPath(config) {
  const root = process.env.AGMSG_SYNC_TRUST_DIR;
  if (!root) throw new Error("AGMSG_SYNC_TRUST_DIR is required for age-v1 and must survive sync-state reset");
  const resolvedRoot = resolve(root);
  const storageRoot = resolve(process.env.AGMSG_SYNC_STORAGE_DIR ?? "");
  if (resolvedRoot === storageRoot || resolvedRoot.startsWith(`${storageRoot}${sep}`)) {
    throw new Error("AGMSG_SYNC_TRUST_DIR must be outside the resettable sync storage directory");
  }
  return join(resolvedRoot,
    `age-v1-${config.server_instance_id}-${config.remote_team_id}-v${config.protocol_version}.json`);
}

async function writeConfig(path, value) {
  const directory = dirname(path);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const temporary = join(directory, `.${basename(path)}.${process.pid}.tmp`);
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  await rename(temporary, path);
}

async function readStoredSyncConfig(team) {
  const bytes = await readBoundedAuthorityFile(
    configPath(team), MAX_CONNECTION_CONFIG_BYTES, false);
  return parseStrictJson(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

export async function loadConfig(team) {
  const binding = await readConnectedBinding(team);
  const selectedCipher = binding.cipher_profile ?? "none";
  // "unknown" is what `pull` writes when the server holds no declaration for
  // the team. It is refused separately from a garbled value because the remedy
  // differs and is knowable: the setting is recorded the next time the machine
  // that already has the team sends to it. Starting the engine on a guess is
  // the failure this path exists to remove.
  if (selectedCipher === "unknown") {
    throw new Error(
      "the encryption setting for this team is not known to the server; it is recorded when the machine that already has the team next sends a message, after which pull the team here again");
  }
  if (!["none", "age-v1"].includes(selectedCipher)) {
    throw new Error("connected team binding selects an unsupported cipher profile");
  }
  let value;
  try {
    value = await readStoredSyncConfig(team);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    if (selectedCipher !== "none") {
      throw new Error(
        `connected team selected ${selectedCipher} but its authenticated sync configuration is missing`);
    }
    if (!binding.capabilities.write_allowed_ciphers.includes("none")) {
      throw new Error("connected team requires an authenticated age-v1 sync configuration");
    }
    value = {
      format_version: 1,
      local_team: team,
      server_url: binding.endpoint,
      server_instance_id: binding.server_instance_id,
      remote_team_id: binding.remote_team_id,
      protocol_version: binding.protocol_version,
      cipher_profile: "none",
      local_security_history: [{ local_security_revision: "0", effective_from_seq: "1",
        minimum_security_mode: "plaintext-allowed" }],
    };
  }
  value.cipher_profile ??= "none";
  if (binding.cipher_profile !== undefined && value.cipher_profile !== selectedCipher) {
    throw new Error("sync configuration cipher does not match the connected team binding");
  }
  if (value.server_url !== binding.endpoint ||
      value.server_instance_id !== binding.server_instance_id ||
      value.remote_team_id !== binding.remote_team_id ||
      value.protocol_version !== binding.protocol_version) {
    throw new Error("sync configuration does not match the connected team binding");
  }
  if (value.local_team !== team || value.protocol_version !== 1 ||
      !UUID_V7.test(value.server_instance_id) || !UUID_V7.test(value.remote_team_id)) {
    throw new Error("sync config binding is invalid");
  }
  validateLocalSecurityHistory(value.local_security_history);
  if (value.cipher_profile === "age-v1") {
    validateAgeConfiguration(value);
    // A local authority advance retains its checkpoint before atomically
    // replacing the sync config. Let that narrowly authenticated transition
    // finish first so a crash between those writes is retryable; every other
    // rollback still fails the retained-checkpoint comparison below.
    await activateKeyRotations(value);
    await validateRetainedAgeCheckpoint(value);
  }
  else if (value.cipher_profile !== "none") throw new Error("sync cipher profile is unsupported");
  return value;
}

async function localAgentRoster(team) {
  // One derivation for this path, shared with teamConfigPath: the connection
  // root when there is one, the skill directory only as the single-machine
  // default. This read used SKILL_DIR alone, so on a second machine — which
  // always has its own connection directory — it looked in a directory nothing
  // had written and reported the roster missing.
  const supplied = process.env.AGMSG_SYNC_LOCAL_ROSTER_FILE;
  const path = supplied || teamConfigPath(team);
  if (!path) throw new Error("local team roster path is unavailable");
  const value = JSON.parse(await readFile(path, "utf8"));
  if (!value?.agents || typeof value.agents !== "object" || Array.isArray(value.agents)) {
    throw new Error("local team roster is invalid");
  }
  const names = Object.keys(value.agents).map((name) => requireName(name, "local agent name")).sort();
  if (names.length > 1000 || new Set(names).size !== names.length) {
    throw new Error("local team roster is invalid");
  }
  return names;
}

function requireUnicodeScalars(value, label) {
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (index + 1 >= value.length || next < 0xdc00 || next > 0xdfff) {
        throw new Error(`${label} contains a lone surrogate`);
      }
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw new Error(`${label} contains a lone surrogate`);
    }
  }
}

export function canonicalJson(value) {
  if (value === null || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "string") {
    requireUnicodeScalars(value, "age snapshot string");
    return JSON.stringify(value);
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("age snapshot contains a non-finite number");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => {
      requireUnicodeScalars(key, "age snapshot key");
      return `${JSON.stringify(key)}:${canonicalJson(value[key])}`;
    }).join(",")}}`;
  }
  throw new Error("age snapshot contains a non-JSON value");
}

export function ageSnapshotDigest(value) {
  return createHash("sha256").update(canonicalJson(value), "utf8").digest("hex");
}

export function initialAgeSnapshot(teamConfig, team = teamConfig?.name) {
  const binding = connectedBinding(teamConfig, team);
  const current = teamConfig?.remote_key?.current;
  const epochs = teamConfig?.remote_key?.epochs;
  if (!current || !Array.isArray(epochs) || epochs.length !== 1 ||
      (current !== epochs[0] && canonicalJson(current) !== canonicalJson(epochs[0])) ||
      current.epoch_revision !== 0 || current.writer_generation !== 0 ||
      typeof current.key_id !== "string" ||
      !/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(current.key_id) ||
      typeof current.recipient !== "string" ||
      !/^age1[0-9a-z]{58}$/u.test(current.recipient) ||
      current.previous_snapshot_sha256 !== null) {
    throw new Error("team does not have one canonical initial age epoch");
  }
  return {
    profile: "age-v1",
    server_instance_id: binding.server_instance_id,
    team_id: binding.remote_team_id,
    epoch_revision: "0",
    writer_generation: "0",
    authorized_writers: [current.key_id],
    previous_snapshot_sha256: null,
    history: [{
      epoch_revision: "0",
      effective_from_seq: "1",
      cipher: "age-v1",
      key_id: current.key_id,
      recipients: [current.recipient],
    }],
  };
}

export function nextLocalAgeSnapshot(config, teamConfig, rotation) {
  const ageSnapshots = ageSnapshotChain(config.age_v1);
  const previous = ageSnapshots.at(-1);
  const localEpochs = teamConfig?.remote_key?.epochs;
  const localEpoch = Array.isArray(localEpochs) ? localEpochs.find((epoch) =>
    String(epoch?.epoch_revision) === rotation.epoch && epoch?.key_id === rotation.key_id) : null;
  if (!previous || !localEpoch ||
      localEpoch.key_id !== rotation.key_id ||
      localEpoch.recipient === undefined ||
      createHash("sha256").update(localEpoch.recipient, "utf8").digest("hex") !==
        rotation.fingerprint ||
      localEpoch.previous_snapshot_sha256 !== ageSnapshotDigest(previous)) {
    return null;
  }
  if (BigInt(rotation.server_seq) === MAX_SEQUENCE) {
    throw new Error("key rotation cannot be activated at the final server sequence");
  }
  const revision = sequence(rotation.epoch, "local key epoch revision");
  const writerGeneration = sequence(
    String(localEpoch.writer_generation), "local key writer generation");
  const snapshot = {
    ...previous,
    epoch_revision: revision,
    writer_generation: writerGeneration,
    authorized_writers: [localEpoch.key_id],
    previous_snapshot_sha256: ageSnapshotDigest(previous),
    history: [...previous.history, {
      epoch_revision: revision,
      effective_from_seq: (BigInt(rotation.server_seq) + 1n).toString(),
      cipher: "age-v1",
      key_id: localEpoch.key_id,
      recipients: [localEpoch.recipient],
    }],
  };
  return snapshot;
}

async function provisionLocalAgeSnapshot(config, rotation) {
  let bytes;
  try {
    bytes = await readBoundedAuthorityFile(
      teamConfigPath(config.local_team), MAX_CONNECTION_CONFIG_BYTES, false);
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
  const teamConfig = parseStrictJson(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  const snapshot = nextLocalAgeSnapshot(config, teamConfig, rotation);
  if (!snapshot) return false;
  const identityPath = replacementIdentityPath(config.local_team, rotation.key_id);
  const proposed = structuredClone(config);
  delete proposed.age_v1_runtime_history;
  proposed.age_v1.epoch_snapshots = [...ageSnapshotChain(config.age_v1), snapshot];
  delete proposed.age_v1.epoch_snapshot;
  proposed.age_v1.checkpoint = {
    epoch_revision: snapshot.epoch_revision,
    snapshot_sha256: ageSnapshotDigest(snapshot),
    writer_generation: snapshot.writer_generation,
    confirmed_at: new Date().toISOString(),
  };
  proposed.age_v1.identity_files[rotation.key_id] = identityPath;
  validateAgeConfiguration(proposed);
  validateConfiguredAgeIdentities(proposed);
  const retained = await retainAgeCheckpoint(proposed, "operator-live");
  proposed.age_v1.checkpoint.confirmed_at = retained.confirmation.confirmed_at;
  await writeConfig(configPath(config.local_team), proposed);
  Object.assign(config, proposed);
  return true;
}

export async function exportAgeSnapshot(args) {
  const team = requireName(args.team, "team");
  const bytes = await readBoundedAuthorityFile(
    teamConfigPath(team), MAX_CONNECTION_CONFIG_BYTES, false);
  const teamConfig = parseStrictJson(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  let snapshot;
  try {
    const config = await readStoredSyncConfig(team);
    if (config.cipher_profile !== "age-v1") throw new Error("team is not configured for age-v1");
    validateAgeConfiguration(config);
    await validateRetainedAgeCheckpoint(config);
    snapshot = ageSnapshotChain(config.age_v1).at(-1);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    snapshot = initialAgeSnapshot(teamConfig, team);
  }
  const canonical = canonicalJson(snapshot);
  const outputPath = args.out ? resolve(args.out) : null;
  if (outputPath) {
    const directory = dirname(outputPath);
    await mkdir(directory, { recursive: true });
    const temporary = join(directory, `.${basename(outputPath)}.${process.pid}.tmp`);
    await writeFile(temporary, canonical, { mode: 0o600, flag: "wx" });
    await rename(temporary, outputPath);
  } else {
    process.stdout.write(`${canonical}\n`);
  }
  process.stderr.write(`Snapshot SHA-256: ${ageSnapshotDigest(snapshot)}\n`);
}

export async function exportAgeHandoff(args) {
  const team = requireName(args.team, "team");
  if (!args.out) throw new Error("export-age-handoff requires --out");
  const config = await readStoredSyncConfig(team);
  if (config.cipher_profile !== "age-v1") throw new Error("team is not configured for age-v1");
  validateAgeConfiguration(config);
  await validateRetainedAgeCheckpoint(config);
  validateConfiguredAgeIdentities(config);
  const snapshots = ageSnapshotChain(config.age_v1);
  const latest = snapshots.at(-1);
  const identities = [];
  const seen = new Set();
  for (const epoch of latest.history) {
    if (seen.has(epoch.key_id)) continue;
    seen.add(epoch.key_id);
    const path = config.age_v1.identity_files[epoch.key_id];
    if (!path) throw new Error(`local identity is missing for ${epoch.key_id}`);
    const identity = (await readFile(path, "utf8")).trim();
    identities.push({ key_id: epoch.key_id, identity });
  }
  const bundle = {
    format_version: 1,
    type: "agmsg_age_v1_handoff",
    snapshots,
    identities,
  };
  const canonical = canonicalJson(bundle);
  const outputPath = resolve(args.out);
  const directory = dirname(outputPath);
  await mkdir(directory, { recursive: true });
  const temporary = join(directory, `.${basename(outputPath)}.${process.pid}.tmp`);
  await writeFile(temporary, canonical, { mode: 0o600, flag: "wx" });
  await rename(temporary, outputPath);
  process.stderr.write(`Snapshot SHA-256: ${ageSnapshotDigest(latest)}\n`);
}

export async function verifyAgeHandoff(args) {
  const team = requireName(args.team, "team");
  if (!args.bundle || !args["out-dir"]) {
    throw new Error("verify-age-handoff requires --bundle and --out-dir");
  }
  const text = await readFile(resolve(args.bundle), "utf8");
  const bundle = parseStrictJson(text);
  if (text.trim() !== canonicalJson(bundle)) {
    throw new Error("age handoff bundle must be RFC 8785 JCS without duplicate or noncanonical fields");
  }
  if (!bundle || bundle.format_version !== 1 || bundle.type !== "agmsg_age_v1_handoff" ||
      !Array.isArray(bundle.snapshots) || bundle.snapshots.length < 1 ||
      !Array.isArray(bundle.identities) ||
      Object.keys(bundle).sort().join(",") !== "format_version,identities,snapshots,type") {
    throw new Error("age handoff bundle is invalid");
  }
  const outputDirectory = resolve(args["out-dir"]);
  await mkdir(outputDirectory, { recursive: true, mode: 0o700 });
  const snapshotPaths = [];
  for (let index = 0; index < bundle.snapshots.length; index += 1) {
    const path = join(outputDirectory, `snapshot-${String(index).padStart(4, "0")}.json`);
    await writeFile(path, canonicalJson(bundle.snapshots[index]), { mode: 0o600, flag: "wx" });
    snapshotPaths.push(path);
  }
  const identityMappings = [];
  const seen = new Set();
  for (const entry of bundle.identities) {
    if (!entry || Object.keys(entry).sort().join(",") !== "identity,key_id" ||
        typeof entry.key_id !== "string" || !/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(entry.key_id) ||
        typeof entry.identity !== "string" || seen.has(entry.key_id)) {
      throw new Error("age handoff identity is invalid");
    }
    seen.add(entry.key_id);
    const path = join(outputDirectory, `identity-${entry.key_id}.key`);
    await writeFile(path, `${entry.identity.trim()}\n`, { mode: 0o600, flag: "wx" });
    identityMappings.push({ key_id: entry.key_id, path });
  }
  const binding = await readConnectedBinding(team);
  const latest = bundle.snapshots.at(-1);
  const digest = ageSnapshotDigest(latest);
  const config = {
    format_version: 1,
    local_team: team,
    server_url: binding.endpoint,
    server_instance_id: binding.server_instance_id,
    remote_team_id: binding.remote_team_id,
    protocol_version: binding.protocol_version,
    cipher_profile: "age-v1",
    local_security_history: [{ local_security_revision: "0", effective_from_seq: "1",
      minimum_security_mode: "e2ee-required" }],
    age_v1: {
      epoch_snapshots: bundle.snapshots,
      checkpoint: { epoch_revision: latest.epoch_revision, snapshot_sha256: digest,
        writer_generation: latest.writer_generation, confirmed_at: new Date().toISOString() },
      identity_files: Object.fromEntries(identityMappings.map(({ key_id, path }) => [key_id, path])),
      age_version: "verification-only",
    },
  };
  validateAgeConfiguration(config);
  const expectedKeyIds = [...new Set(latest.history.map((epoch) => epoch.key_id))];
  if (expectedKeyIds.length !== identityMappings.length ||
      expectedKeyIds.some((keyId) => !seen.has(keyId))) {
    throw new Error("age handoff bundle does not contain every epoch identity exactly once");
  }
  validateConfiguredAgeIdentities(config);
  const result = {
    type: "age_handoff_verified",
    snapshot_sha256: digest,
    epoch_revision: latest.epoch_revision,
    snapshot_paths: snapshotPaths,
    identities: identityMappings,
  };
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return result;
}

export async function verifyAgeSnapshot(args) {
  const team = requireName(args.team, "team");
  if (!args["age-snapshot"]) throw new Error("age-snapshot is required");
  const snapshotPaths = Array.isArray(args["age-snapshot"]) ?
    args["age-snapshot"] : [args["age-snapshot"]];
  if (snapshotPaths.length < 1 || snapshotPaths.some((path) => typeof path !== "string"))
    throw new Error("verify-age-snapshot requires at least one age-snapshot");
  const snapshots = [];
  for (const path of snapshotPaths) {
    const snapshotText = await readFile(resolve(path), "utf8");
    const value = parseStrictJson(snapshotText);
    if (snapshotText.trim() !== canonicalJson(value))
      throw new Error("age snapshot must be RFC 8785 JCS without duplicate or noncanonical fields");
    snapshots.push(value);
  }
  const snapshot = snapshots.at(-1);
  const binding = await readConnectedBinding(team);
  const digest = ageSnapshotDigest(snapshot);
  const config = {
    format_version: 1,
    local_team: team,
    server_url: binding.endpoint,
    server_instance_id: binding.server_instance_id,
    remote_team_id: binding.remote_team_id,
    protocol_version: binding.protocol_version,
    cipher_profile: "age-v1",
    local_security_history: [{
      local_security_revision: "0",
      effective_from_seq: "1",
      minimum_security_mode: "e2ee-required",
    }],
    age_v1: {
      epoch_snapshots: snapshots,
      checkpoint: {
        epoch_revision: snapshot.epoch_revision,
        snapshot_sha256: digest,
        writer_generation: snapshot.writer_generation,
        confirmed_at: new Date().toISOString(),
      },
      identity_files: {},
      age_version: "verification-only",
    },
  };
  validateAgeConfiguration(config);
  const epoch = snapshot.history.at(-1);
  if (epoch.recipients.length !== 1) {
    throw new Error("unlock requires an epoch with exactly one handed recipient");
  }
  const result = {
    type: "age_snapshot_verified",
    epoch_revision: snapshot.epoch_revision,
    snapshot_sha256: digest,
    key_id: epoch.key_id,
    recipient: epoch.recipients[0],
  };
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return result;
}

function ageSnapshotChain(age) {
  if (Array.isArray(age?.epoch_snapshots)) return age.epoch_snapshots;
  return age?.epoch_snapshot ? [age.epoch_snapshot] : [];
}

function validateLocalSecurityHistory(history) {
  if (!Array.isArray(history) || history.length < 1 || history.length > 4096) {
    throw new Error("local security history is invalid");
  }
  let priorRevision = -1n;
  let priorBoundary = 0n;
  for (const entry of history) {
    const revision = BigInt(sequence(entry.local_security_revision, "local security revision"));
    const boundary = BigInt(sequence(entry.effective_from_seq, "local security boundary"));
    if (revision <= priorRevision || boundary <= priorBoundary ||
        !["plaintext-allowed", "e2ee-required"].includes(entry.minimum_security_mode)) {
      throw new Error("local security history is not canonical");
    }
    priorRevision = revision;
    priorBoundary = boundary;
  }
  if (history[0].effective_from_seq !== "1") throw new Error("local security history must begin at 1");
}

export function validateAgeConfiguration(config) {
  const age = config.age_v1;
  const ageSnapshots = ageSnapshotChain(age);
  const latestAgeSnapshot = ageSnapshots.at(-1);
  const checkpoint = age?.checkpoint;
  if (!age || ageSnapshots.length < 1 || ageSnapshots.length > 4096 || !checkpoint ||
      !age.identity_files || typeof age.identity_files !== "object" || Array.isArray(age.identity_files) ||
      Object.entries(age.identity_files).some(([keyId, path]) =>
        !/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(keyId) || typeof path !== "string" || path.length < 1) ||
      typeof age.age_version !== "string" || age.age_version.length < 1) {
    throw new Error("age-v1 configuration is invalid");
  }
  let previousAgeSnapshot;
  let previousGeneration = -1n;
  const recipientManifests = new Map();
  for (let ageSnapshotIndex = 0;
    ageSnapshotIndex < ageSnapshots.length;
    ageSnapshotIndex += 1) {
    const ageSnapshot = ageSnapshots[ageSnapshotIndex];
    if (!ageSnapshot || ageSnapshot.profile !== "age-v1" ||
        ageSnapshot.server_instance_id !== config.server_instance_id ||
        ageSnapshot.team_id !== config.remote_team_id ||
        !Array.isArray(ageSnapshot.authorized_writers) ||
        ageSnapshot.authorized_writers.length < 1 ||
        new Set(ageSnapshot.authorized_writers).size !== ageSnapshot.authorized_writers.length ||
        ageSnapshot.authorized_writers.some((writer) =>
          typeof writer !== "string" || writer.length < 1) ||
        !Array.isArray(ageSnapshot.history) || ageSnapshot.history.length < 1 ||
        ageSnapshot.history.length > 4096) {
      throw new Error("age epoch snapshot is invalid");
    }
    const ageSnapshotRevision = BigInt(
      sequence(ageSnapshot.epoch_revision, "epoch_revision"));
    const writerGeneration = BigInt(sequence(ageSnapshot.writer_generation, "writer_generation"));
    if (ageSnapshotRevision !== BigInt(ageSnapshotIndex)) {
      throw new Error("age epoch snapshot chain has a missing revision");
    }
    if (writerGeneration <= previousGeneration) {
      throw new Error("age epoch snapshot writer generation is not strictly increasing");
    }
    const expectedPrevious = previousAgeSnapshot ? ageSnapshotDigest(previousAgeSnapshot) : null;
    if (ageSnapshot.previous_snapshot_sha256 !== expectedPrevious) {
      throw new Error("age epoch snapshot hash chain is broken");
    }
    let priorRevision = -1n;
    let priorBoundary = 0n;
    for (let historyIndex = 0; historyIndex < ageSnapshot.history.length; historyIndex += 1) {
      const entry = ageSnapshot.history[historyIndex];
      const revision = BigInt(sequence(entry.epoch_revision, "epoch history revision"));
      const boundary = BigInt(sequence(entry.effective_from_seq, "epoch history boundary"));
      if (revision !== BigInt(historyIndex) || boundary <= priorBoundary ||
          entry.cipher !== "age-v1" ||
          typeof entry.key_id !== "string" || !/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(entry.key_id) ||
          !Array.isArray(entry.recipients) || entry.recipients.length < 1 ||
          entry.recipients.length > 256 ||
          new Set(entry.recipients).size !== entry.recipients.length ||
          entry.recipients.some((recipient) =>
            typeof recipient !== "string" || !/^age1[0-9a-z]{58}$/u.test(recipient))) {
        throw new Error("age epoch history is not canonical");
      }
      const manifest = canonicalJson(entry.recipients);
      const existingManifest = recipientManifests.get(entry.key_id);
      if (existingManifest !== undefined && existingManifest !== manifest) {
        throw new Error("age key_id is bound to conflicting recipient manifests");
      }
      recipientManifests.set(entry.key_id, manifest);
      priorRevision = revision;
      priorBoundary = boundary;
    }
    if (ageSnapshot.history[0].effective_from_seq !== "1" ||
        priorRevision !== ageSnapshotRevision ||
        (previousAgeSnapshot &&
          canonicalJson(ageSnapshot.history.slice(0, -1)) !==
            canonicalJson(previousAgeSnapshot.history))) {
      throw new Error("age epoch snapshot does not contain the complete immutable history");
    }
    previousAgeSnapshot = ageSnapshot;
    previousGeneration = writerGeneration;
  }
  const digest = ageSnapshotDigest(latestAgeSnapshot);
  if (checkpoint.epoch_revision !== latestAgeSnapshot.epoch_revision ||
      checkpoint.snapshot_sha256 !== digest ||
      checkpoint.writer_generation !== latestAgeSnapshot.writer_generation ||
      typeof checkpoint.confirmed_at !== "string" || Number.isNaN(Date.parse(checkpoint.confirmed_at))) {
    throw new Error("age epoch checkpoint does not match the epoch snapshot");
  }
  return digest;
}

export function validateConfiguredAgeIdentities(config) {
  const latestAgeSnapshot = ageSnapshotChain(config.age_v1).at(-1);
  for (const [keyId, path] of Object.entries(config.age_v1.identity_files)) {
    const identity = readNativeAgeIdentity(path);
    const matchingEpochs = latestAgeSnapshot.history.filter((entry) => entry.key_id === keyId);
    if (matchingEpochs.length < 1 || matchingEpochs.some((entry) => !entry.recipients.includes(identity.recipient))) {
      throw new Error(`age identity for ${keyId} does not match its recipient manifest`);
    }
  }
}

function checkpointRecord(config, confirmation) {
  return {
    format_version: 1,
    profile: "age-v1",
    server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id,
    protocol_version: config.protocol_version,
    epoch_revision: config.age_v1.checkpoint.epoch_revision,
    snapshot_sha256: config.age_v1.checkpoint.snapshot_sha256,
    writer_generation: config.age_v1.checkpoint.writer_generation,
    confirmation: { method: confirmation, confirmed_at: config.age_v1.checkpoint.confirmed_at },
  };
}

function compareRetainedCheckpoint(config, retained) {
  const proposed = checkpointRecord(config, retained.confirmation?.method);
  if (retained.format_version !== 1 || retained.profile !== "age-v1" ||
      retained.server_instance_id !== proposed.server_instance_id || retained.team_id !== proposed.team_id ||
      retained.protocol_version !== proposed.protocol_version ||
      typeof retained.snapshot_sha256 !== "string" ||
      !/^[0-9a-f]{64}$/u.test(retained.snapshot_sha256) ||
      retained.confirmation?.method !== "operator-live" ||
      typeof retained.confirmation.confirmed_at !== "string" ||
      Number.isNaN(Date.parse(retained.confirmation.confirmed_at))) {
    throw new Error("retained age checkpoint is invalid");
  }
  const retainedRevision = BigInt(sequence(retained.epoch_revision, "retained epoch revision"));
  const proposedRevision = BigInt(sequence(proposed.epoch_revision, "proposed epoch revision"));
  const retainedGeneration = BigInt(sequence(retained.writer_generation, "retained writer generation"));
  const proposedGeneration = BigInt(sequence(proposed.writer_generation, "proposed writer generation"));
  const retainedAgeSnapshot = ageSnapshotChain(config.age_v1)
    .find((ageSnapshot) => ageSnapshot.epoch_revision === retained.epoch_revision);
  if (proposedRevision < retainedRevision || proposedGeneration < retainedGeneration ||
      !retainedAgeSnapshot ||
      ageSnapshotDigest(retainedAgeSnapshot) !== retained.snapshot_sha256 ||
      retainedAgeSnapshot.writer_generation !== retained.writer_generation) {
    throw new Error("age checkpoint rollback or same-revision conflict detected");
  }
  if (proposedRevision === retainedRevision &&
      (proposed.snapshot_sha256 !== retained.snapshot_sha256 ||
       proposedGeneration !== retainedGeneration)) {
    throw new Error("age checkpoint rollback or same-revision conflict detected");
  }
  return proposedRevision === retainedRevision ? "same" : "advance";
}

async function readRetainedCheckpointFile(path) {
  const metadata = await lstat(path);
  const checkpointFault = authorityFileError(
    "retained age checkpoint", path, metadata, { privateFile: true });
  if (checkpointFault) throw checkpointFault;
  const records = parseStrictJsonl(await readFile(path, "utf8"));
  if (records.length < 1 || records.length > 4096) {
    throw new Error("retained age checkpoint history is invalid");
  }
  return records;
}

export async function retainAgeCheckpoint(config, confirmation) {
  const path = ageTrustPath(config);
  let records;
  try {
    records = await readRetainedCheckpointFile(path);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  if (confirmation !== "operator-live") {
    throw new Error("age checkpoint import requires --age-confirmation operator-live");
  }
  if (records) {
    let current;
    for (const retained of records) {
      const relation = compareRetainedCheckpoint(config, retained);
      if (relation === "same") current = retained;
    }
    if (current) return current;
    if (records.length >= 4096) {
      throw new Error("retained age checkpoint history reached the 4096 entry limit");
    }
    const retained = checkpointRecord(config, confirmation);
    const handle = await open(path, "a", 0o600);
    try {
      await handle.writeFile(`${JSON.stringify(retained)}\n`, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    return retained;
  }
  const retained = checkpointRecord(config, confirmation);
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const trustDirectory = dirname(path);
  const directoryMetadata = await lstat(trustDirectory);
  // Not in the report that prompted this, and the same shape as the two above:
  // on win32 "private" is the half that was never checked, so it was the half
  // the message must not lead with. Fixing the other two and leaving this one
  // would have reproduced the defect from here.
  if (!directoryMetadata.isDirectory()) {
    throw new Error(`AGMSG_SYNC_TRUST_DIR must be a directory: ${trustDirectory}`);
  }
  if (process.platform !== "win32" && (directoryMetadata.mode & 0o077) !== 0) {
    throw new Error(
      `AGMSG_SYNC_TRUST_DIR must not be readable or writable by group or others: ${trustDirectory}`);
  }
  try {
    const handle = await open(path, "wx", 0o600);
    try {
      await handle.writeFile(`${JSON.stringify(retained)}\n`, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    if (process.platform !== "win32") {
      const directoryHandle = await open(dirname(path), "r");
      try {
        await directoryHandle.sync();
      } finally {
        await directoryHandle.close();
      }
    }
    return retained;
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    return retainAgeCheckpoint(config, confirmation);
  }
}

export async function validateRetainedAgeCheckpoint(config) {
  const records = await readRetainedCheckpointFile(ageTrustPath(config));
  let retained;
  for (const record of records) {
    if (compareRetainedCheckpoint(config, record) === "same") retained = record;
  }
  if (!retained) {
    throw new Error("sync config is behind the retained age checkpoint");
  }
  if (retained.confirmation.confirmed_at !== config.age_v1.checkpoint.confirmed_at) {
    throw new Error("sync config does not match the retained age checkpoint confirmation");
  }
}

function endpoint(base, path) {
  const root = new URL(base);
  if (root.username || root.password || root.search || root.hash) {
    throw new Error("server URL must not contain credentials, query, or fragment");
  }
  const prefix = root.pathname.replace(/\/$/, "");
  const separator = path.indexOf("?");
  const pathname = separator === -1 ? path : path.slice(0, separator);
  const query = separator === -1 ? "" : path.slice(separator + 1);
  root.pathname = `${prefix}${pathname}`;
  root.search = query;
  return root;
}

export async function request(config, path, init = {}) {
  // The data plane no longer authenticates per request — reaching the server is
  // the permission (docs/design/remote-sync.md and the server's scopedTeamId).
  // So request() carries no credential; it is now the same as requestPublic,
  // kept as the name the pre-pull data-plane callers use.
  return send(config, path, init, {});
}

// The pull routes carry no credential, for the reason /v1/connect has none:
// reaching the server is the permission. Everything after the header -- the
// protocol check, the binding validation, the retryable classification -- is
// the same, so it is shared rather than written twice.
export async function requestPublic(config, path, init = {}) {
  return send(config, path, init, {});
}

async function send(config, path, init, authHeaders) {
  const headers = {
    ...init.headers,
    "Agmsg-Protocol-Version": PROTOCOL,
    "Agmsg-Team-ID": config.remote_team_id,
    ...authHeaders,
  };
  const url = endpoint(config.server_url, path);
  let response;
  try {
    response = await fetch(url, {
      ...init, headers, redirect: "error", signal: AbortSignal.timeout(15_000),
    });
  } catch (error) {
    error.retryable = true;
    throw error;
  }
  const protocol = response.headers.get("agmsg-protocol-version");
  let text;
  try { text = await response.text(); } catch (error) {
    error.retryable = true;
    throw error;
  }
  let body;
  try { body = JSON.parse(text); } catch {
    if (!response.ok && [502, 503, 504].includes(response.status)) {
      const error = new Error(`HTTP ${response.status} intermediary failure`);
      error.status = response.status; error.retryable = true;
      throw error;
    }
    throw new Error(`HTTP ${response.status} returned invalid JSON`);
  }
  if (protocol !== PROTOCOL) {
    if (!response.ok && [502, 503, 504].includes(response.status)) {
      const error = new Error(`HTTP ${response.status} intermediary failure`);
      error.status = response.status; error.retryable = true;
      throw error;
    }
    throw new Error("response protocol version mismatch");
  }
  if (!response.ok) {
    validateErrorBinding(config, response.status, body);
    const code = errorCode(body);
    // The same boundary publicGet() draws (#726/#728), for the message ONLY.
    // This message reaches raw, unescaping sinks: main()'s stderr write lands
    // it unescaped in the daemon's logfile (`run >> logfile 2>&1`) and on the
    // operator's live terminal for the foreground subcommands -- one collapse
    // at this composition point covers both readers, because the allowed
    // alphabet is safe for the stricter of them (a terminal). error.code and
    // error.body keep the server's actual value: their only sinks are the
    // JSON-escaped event lines (cycle.error/fatal, push.oversized detail),
    // and collapsing them too would erase the hosted edge's snake_case codes
    // -- re-creating the "sync stopped with no reason in the log" failure the
    // errorCode() bridge exists to prevent.
    const safeCode = /^[a-z][a-z0-9-]{0,63}$/.test(code) ? code : "unknown-error";
    const error = new Error(`HTTP ${response.status} ${safeCode}`);
    error.status = response.status; error.code = code; error.body = body;
    throw error;
  }
  validateBinding(config, body);
  return body;
}

// Check the binding when the body actually carries one — not when the status
// code happens to be outside a list.
//
// The list was {400,401,426}, so every other error ran through validateBinding,
// which compares `body.team_id` to the configured one. An error body without a
// binding has `undefined` there, so it failed the comparison and every 403, 404,
// 409 and 500 arrived as "server/team binding mismatch". The one message that
// means "you are talking to the wrong team" was what a caller saw for a
// forbidden request, a missing team, a conflict, and a server crash alike.
//
// Checking presence instead is also the stronger rule: an error that DOES carry
// a binding is verified whatever its status, where the allowlist would have
// skipped a mismatched 400.
// The error code.
//
// THE PROTOCOL SHAPE IS THE NESTED ONE: `{ error: { code, message, details } }`,
// built by `errorBody()` in the reference server (server/src/errors.ts) — which
// is the definition, since server/spec/v1.md is marked SUPERSEDED. That is what
// a new implementation should emit and what a reader here should take as the
// contract.
//
// The bare-string branch is a BRIDGE, not a second valid shape. The hosted edge
// currently answers `{ error: "payload_too_large" }`, and reading only the
// nested form turned every one of its errors into `unknown-error` — a 413 that
// said nothing about being too large, which is how a real 9,784-message
// migration ended with a stopped sync and no reason in the log.
//
// Accepting both keeps that legible today; it does not make both correct. When
// the edge emits the nested shape, DELETE the string branch — leaving it is how
// "two shapes" quietly becomes the contract and a third implementation picks
// whichever it likes.
export function errorCode(body) {
  const error = body?.error;
  if (typeof error === "string" && error.length > 0) return error;
  if (typeof error?.code === "string" && error.code.length > 0) return error.code;
  return "unknown-error";
}

export function validateErrorBinding(config, status, body) {
  // An identity claim is server_instance_id or team_id. Those name WHICH server
  // and WHICH team, so a reply carrying either is asserting the binding and gets
  // checked at any status.
  const claimsIdentity = body?.server_instance_id !== undefined || body?.team_id !== undefined;
  // `protocol_version` alone is not an identity claim — every well-formed reply
  // in this protocol has one, including a plain 401. But once the server has
  // resolved the request far enough to answer 403/404/409/500, a body that
  // carries the protocol envelope and omits the identity is malformed for that
  // stage, and the old code refused it. Keeping that refusal is why this is not
  // simply "check when identity is present": the inversion must not loosen a
  // path (review).
  const preResolution = status === 400 || status === 401 || status === 426;
  const claimsProtocol = body?.protocol_version !== undefined;
  if (claimsIdentity || (!preResolution && claimsProtocol)) validateBinding(config, body);
}

// `teamId` is required, not optional: a health check that does not say which
// team it is asking about cannot be answered per-team, and an edge that routes
// by team would have to guess. Same header name as send() — one name for one
// fact, so a gateway does not have to know two.
async function health(serverUrl, teamId) {
  let response;
  try {
    response = await fetch(endpoint(serverUrl, "/v1/health"), {
      headers: { "Agmsg-Team-ID": teamId },
      redirect: "error", signal: AbortSignal.timeout(15_000),
    });
  } catch (error) {
    error.retryable = true;
    throw error;
  }
  if (response.headers.get("agmsg-protocol-version") !== PROTOCOL) {
    // AN ERROR PAGE IS NOT A PROTOCOL MISMATCH.
    //
    // A gateway that is down answers 502/503/504 with its own body and none of
    // our headers, so the version check fails for a reason that has nothing to
    // do with versions. `request()` already draws this line and names it
    // "intermediary failure"; this function did not, and this is the one the
    // engine's loop calls every cycle — so a 90-second outage ended both
    // engines permanently and silently, and the remote recovering did not
    // bring them back (#814).
    //
    // The distinction is what makes this safe: a 200 whose header says a
    // different version IS a real mismatch and must still be fatal. Only an
    // unsuccessful 502/503/504 is treated as weather.
    if (!response.ok && [502, 503, 504].includes(response.status)) {
      const error = new Error(`HTTP ${response.status} intermediary failure`);
      error.status = response.status;
      error.retryable = true;
      throw error;
    }
    throw new Error("health protocol version mismatch");
  }
  const body = await response.json();
  if (!response.ok || body.status !== "ok" || body.database !== "ok" || !UUID_V7.test(body.server_instance_id)) {
    const error = new Error("server health is unavailable or unbound");
    error.status = response.status;
    error.retryable = response.status === 503;
    throw error;
  }
  return body;
}

function validateBinding(config, body) {
  if (body?.protocol_version !== 1 || body?.server_instance_id !== config.server_instance_id ||
      body?.team_id !== config.remote_team_id) {
    throw new Error("server/team binding mismatch");
  }
}

export function validateMembers(config, value) {
  validateBinding(config, value);
  sequence(value.min_available_seq, "members min_available_seq");
  sequence(value.members_revision, "members_revision");
  if (!Array.isArray(value.members) || value.members.length > 1000) {
    throw new Error("members response is invalid");
  }
  const ids = new Set();
  const names = new Set();
  const registrationIds = new Set();
  let previous = "";
  for (const member of value.members) {
    if (!member || !UUID_V7.test(member.member_id) ||
        requireName(member.name, "member name") !== member.name ||
        !Array.isArray(member.registrations) || ids.has(member.member_id) ||
        names.has(member.name) || (previous && member.member_id <= previous)) {
      throw new Error("members response is not canonical");
    }
    let priorRegistration = "";
    for (const registration of member.registrations) {
      if (Object.keys(registration).sort().join(",") !==
          "installation_id,registration_id,type" ||
          !UUID_V7.test(registration.registration_id) ||
          !UUID_V7.test(registration.installation_id) ||
          typeof registration.type !== "string" ||
          !/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(registration.type) ||
          registrationIds.has(registration.registration_id) ||
          (priorRegistration && registration.registration_id <= priorRegistration)) {
        throw new Error("member registrations are not canonical");
      }
      registrationIds.add(registration.registration_id);
      priorRegistration = registration.registration_id;
    }
    ids.add(member.member_id); names.add(member.name); previous = member.member_id;
  }
  return value.members.map(({ member_id, name }) => ({ member_id, name }));
}

// One lifecycle for both drivers, because every way a driver call can fail has
// to end the same way: the promise settles exactly once, and no child outlives
// the call that started it.
//
// Each failure route used to be handled on its own and two of them escaped the
// promise entirely. A write to a driver that has stopped reading takes EPIPE on
// the *stdin stream*, and unparseable output throws inside the 'close' handler;
// an unhandled stream 'error' and a throw from a listener are both raised, not
// returned, so they bypassed the caller and killed the process. They now arrive
// here like any other failure.
//
// Killing on failure is the other half. Rejecting alone leaves the child
// running, which only trades "the process dies" for "the process cannot exit" --
// its handles pin the loop -- and lets failures pile up children as cycles
// retry.
//
// Every failure settles at 'exit' and drops our own ends of the pipes as it
// goes -- including the ordinary one, a driver that simply exits non-zero.
// 'close' waits for every stdio stream to end, and a driver's own grandchild
// inherits those pipes and can hold them open indefinitely; SIGKILL reaches the
// driver but nothing it started. So no failure route may depend on 'close', and
// only success does, because only success has to read all of stdout. What this
// process owns is what it can be sure of releasing, so that is what it releases:
// a grandchild is left to the operator, not chased through the process tree.
// A child's ending, said so that every platform's answer is legible.
//
// `signal ?? code` printed one number and hid which field produced it. On
// Windows/Git Bash a driver that died to a signal arrives through `code` as a
// raw wait status -- one report carried `3840` -- and the operator got a bare
// number with no way to tell it from an ordinary exit status (#782).
//
// Both fields are named, and a `code` outside the range an exit status can take
// is additionally shown DECOMPOSED rather than decoded. Under the POSIX
// encoding 3840 is `WIFEXITED` with status 15, while the report that raised it
// described a signal; nobody reproducing this has the platform to settle which
// layer produced the number. Printing both components lets the operator see
// which one is non-zero. Asserting one of them would put a second wrong
// sentence exactly where the first one was, which is the defect this fixes.
export function describeChildExit(code, signal) {
  if (signal) return `signal ${signal}`;
  if (typeof code !== "number") return "no exit status";
  if (code >= 0 && code <= 255) return `exit ${code}`;
  return `exit ${code}, outside the 0-255 an exit status can take; ` +
    `read as a wait status that is exit ${(code >> 8) & 0xff}, signal ${code & 0x7f}`;
}

// The team's binding path when this process can work one out, and nothing when
// it cannot. `teamConfigPath` throws without a connection root, and a caller
// that has none is a caller that still has to be able to run -- the path is for
// a sentence in a failure message, so it must not become a new way to fail.
// The team's binding path, or WHY there is none.
//
// `teamConfigPath` throws without a connection root, and a caller that has none
// still has to run -- the path is for a sentence in a failure message, so it
// must not become a new way to fail. That much was right the first time.
//
// What was wrong was returning `undefined` and dropping the reason. A failure
// turned into an ordinary value with nothing recorded is the shape #802
// collects, and it had no business being in a change whose whole subject is
// messages that say what actually happened. Swallowing is fine here. Going
// silent is not, so the reason travels with the fallback.
export function bindingPathOrReason(team, resolve = teamConfigPath) {
  try {
    return { path: resolve(team) };
  } catch (error) {
    return { unavailable: error instanceof Error ? error.message : String(error) };
  }
}

// What the diagnostic says about the binding: where it is, or why it cannot be
// named. Never nothing -- "and its binding" alone is the sentence that sent a
// reader looking for a file this process could not even locate.
function bindingNote(binding) {
  if (binding?.path !== undefined) return ` and its binding at ${binding.path}`;
  if (binding?.unavailable !== undefined) {
    return ` and its binding (its path could not be resolved: ${binding.unavailable})`;
  }
  return " and its binding";
}

// Hands the driver its input as a FILE rather than down a pipe.
//
// The driver takes that team's registry lock as its first act and holds it for
// the whole call, and every release route it has is a trap. So the parent must
// never end up in a position where it has to kill the driver: SIGKILL runs no
// trap and leaves `.config.lock` with no owner, and every later run for that
// team then waits on a directory nobody will remove. Measured, on one script
// with an EXIT/TERM trap: SIGTERM leaves no lock, SIGKILL leaves it.
//
// Sending SIGTERM instead is NOT the fix, and was measured not to be one.
// Bash defers a trap while it waits on a foreground child, so the driver --
// which is sitting in `node` -- does not run its release until that child ends;
// signalling the process group does work here, but on Windows Node's kill()
// ignores the signal and terminates forcefully whatever it is asked for, which
// is the platform the field report came from.
//
// So the kill is removed instead of being softened. Writing to a pipe was the
// one failure route that reached a LIVE driver: a write whose reader is gone
// raises on the stdin stream, and that arrived at fail() while the lock was
// held. A file cannot fail that way. It is complete before the child exists --
// therefore before the lock exists -- and the child still reads its stdin
// exactly as before, so no driver changes.
//
// ONLY the driver that holds the lock is handed its input this way, and the
// caller says which one that is. The storage driver has no registry lock, so
// nothing about it needs this, and giving it the same treatment would cost it
// two things for nothing: its input -- which after evaluatePull() is decrypted
// message content, on E2EE teams as much as plain ones -- would go to rest on
// disk where only a pipe carried it, and it would lose the bounded failure it
// has today, since a driver that stops reading a pipe fails at once while a
// driver handed a file is waited for. This is a fix for one caller and it is
// scoped to that caller.
function stageInput(input, staging) {
  // Filled IN PLACE, so that one cleanup path can undo whatever part of it got
  // made. The first version cleaned up inside here as well as at settle, which
  // is two routes doing the same job -- and the one in here could not be
  // reached by any test, so it was a guarantee nothing was holding up. There is
  // one route now, and the caller owns it.
  //
  // 0700 by mkdtemp and 0600 on the file. These records are message content,
  // and putting them in a file puts them at rest on disk, which a pipe did not.
  staging.directory = mkdtempSync(join(tmpdir(), "agmsg-driver-input-"));
  const path = join(staging.directory, "input.jsonl");
  writeFileSync(path, input.map((record) => `${JSON.stringify(record)}\n`).join(""),
    { mode: 0o600 });
  // A fresh read-only descriptor. Passing on the one the write used would hand
  // over a descriptor sitting at EOF, and the driver would read an empty input
  // and report a successful sync of nothing.
  staging.fd = openSync(path, "r");
  // Then take the name away immediately, while the descriptor stays open: the
  // spawn duplicates it into the child, so both sides keep reading a file that
  // nothing can any longer open by name, and a parent that dies leaves no
  // message content behind. Windows cannot unlink an open file, so there it
  // stays until the call settles -- which is why the directory is still tracked
  // and removed there rather than only here.
  try {
    rmSync(staging.directory, { recursive: true, force: true });
    staging.directory = null;
  } catch { /* Windows, or a tmpdir that will not allow it; settle cleans up */ }
}

// Removing a temp directory must not fail the call around it -- refusing a sync
// that completed, over a file the caller cannot act on, trades a real result
// for a cleanup detail. But it must not be SILENT either: what is left behind
// is message content, and a swallowed failure leaves it on disk with nobody
// told. So the failure is downgraded to a warning that names the directory,
// which is the one thing an operator needs to remove it.
export function discardInputDirectory(directory, reason) {
  try {
    rmSync(directory, { recursive: true, force: true });
  } catch (error) {
    process.emitWarning(
      `${reason}: driver input left at ${directory} (${error.message})`,
      "AgmsgDriverInputResidue");
  }
}

// How long to wait for a driver that has stopped reading its stdin to exit on
// its own before the pipe path's bound (the SIGKILL in runDriver's `fail`) is
// applied. Derived from the storage busy timeout, since the only exit worth
// waiting for is a busy child's, which comes that timeout after it starts
// waiting; a few seconds of teardown slack past it.
//
// Bounded on BOTH ends. Below: a value that is not a sane non-negative integer
// -- NaN, negative, or a huge one -- falls to the 5 s default. Above: the busy
// timeout is capped at an hour before the slack is added, so the result can
// never approach setTimeout's 32-bit millisecond limit. Past that limit Node
// clamps a delay to 1 ms and would kill a busy child almost at once -- the
// opposite of a grace -- so `Number.isSafeInteger` alone (which admits values
// far past the timer limit) is not enough; the cap is what closes that.
export function storageDriverExitGraceMs(busyTimeoutEnv = process.env.AGMSG_BUSY_TIMEOUT) {
  // Empty is the 5 s default, exactly as the child reads it: storage.sh and the
  // adapter use `${AGMSG_BUSY_TIMEOUT:-5000}`, where unset AND empty both mean
  // 5000. Number("") is 0, not that default -- so an empty value taken literally
  // would make the grace 5 s, equal to the child's busy timeout, and the SIGKILL
  // would fire at the same moment a busy child exits 11, dropping it again. So
  // normalise empty to the default before parsing, and keep this in step with
  // the child's own default if that ever changes.
  const raw = busyTimeoutEnv === undefined || busyTimeoutEnv === "" ? "5000" : busyTimeoutEnv;
  const busyTimeoutMs = Number(raw);
  const usable = Number.isSafeInteger(busyTimeoutMs) &&
    busyTimeoutMs >= 0 && busyTimeoutMs <= 3_600_000 ? busyTimeoutMs : 5000;
  return usable + 5000;
}

function runDriver({ args, label, operation, parse, input, rosterFile, team, bindingPath,
  holdsRegistryLock = false }) {
  return new Promise((resolve, reject) => {
    const childEnvironment = { ...process.env };
    delete childEnvironment.AGMSG_SYNC_TOKEN;
    delete childEnvironment.AGMSG_SYNC_CONNECTION_DIR;
    delete childEnvironment.AGMSG_SYNC_TRUST_DIR;
    for (const key of Object.keys(childEnvironment)) {
      if (/^(?:AGMSG_AGE_IDENTITY|AGMSG_SYNC_AGE_IDENTITY)/u.test(key)) {
        delete childEnvironment[key];
      }
    }
    // One named value may be set after the strip, and only this one: the roster
    // file the caller resolved. A general "extra environment" parameter would
    // make this boundary re-openable — any caller could put TOKEN, TRUST_DIR or
    // an age identity back, and the rule that they never cross would live in a
    // comment rather than in the function. Naming the single variable keeps the
    // guarantee where it can be checked.
    if (rosterFile) childEnvironment.AGMSG_SYNC_LOCAL_ROSTER_FILE = rosterFile;
    // The staged input, and the ONE place that undoes it. Whatever part of the
    // staging exists when something goes wrong -- a directory and no descriptor,
    // both, or neither -- this is what puts it back, and it is the only thing
    // that does. That matters more than it looks: the routes into it that a
    // test cannot reach are undone by the same lines as the route a test can,
    // so binding one binds them all.
    const staging = { directory: null, fd: null };
    const releaseInput = () => {
      if (staging.fd !== null) {
        try { closeSync(staging.fd); } catch { /* already closed */ }
        staging.fd = null;
      }
      // Already null whenever the file could be unlinked while still open,
      // which is everywhere except Windows.
      if (staging.directory !== null) {
        discardInputDirectory(staging.directory, "the driver call ended");
        staging.directory = null;
      }
    };

    let child;
    try {
      // Staged before the spawn, so before the lock: a failure to stage is a
      // failure with no child and no lock to leak. Only for the caller that
      // holds the lock -- everyone else keeps the pipe, and with it the bounded
      // failure a pipe gives and an input that never reaches disk.
      if (holdsRegistryLock) stageInput(input, staging);
      child = spawn("bash", args, {
        stdio: [staging.fd === null ? "pipe" : staging.fd, "pipe", "pipe"],
        env: childEnvironment,
      });
    } catch (error) {
      // Reached by a staging failure and by a synchronous spawn failure alike.
      // Neither leaves a child, and a synchronous spawn failure never reaches
      // 'error', so nothing else here would run for it.
      releaseInput();
      reject(error);
      return;
    }
    // Read once, here: `staging.fd` is nulled on release, so it cannot be asked
    // later whether there was ever a pipe to write to.
    const staged = staging.fd !== null;
    let stdout = ""; let stderr = ""; let settled = false; let failure = null;
    // The last stdin-write error, kept only so a child that exits 0 despite a
    // broken write is not reported as a silent success. See the stdin handler.
    let lastStdinError = null;
    // Armed when a stdin write loses its reader, cleared when the call settles.
    // See the stdin handler for what it bounds and why its length is what it is.
    let stdinExitTimer = null;

    const settle = (error, value) => {
      if (settled) return;
      settled = true;
      if (stdinExitTimer !== null) { clearTimeout(stdinExitTimer); stdinExitTimer = null; }
      releaseInput();
      if (error) reject(error); else resolve(value);
    };
    // Records the failure, stops the child, and lets go of our pipe ends; 'exit'
    // then settles. A child that never started -- a spawn failure -- has no
    // 'exit' to wait for, so that case settles here instead.
    const fail = (error) => {
      if (settled) return;
      failure ??= error;
      const running = child.pid !== undefined &&
        child.exitCode === null && child.signalCode === null;
      for (const stream of [child.stdin, child.stdout, child.stderr]) {
        stream?.destroy();
      }
      if (running) {
        try {
          // Unchanged, and it still matters: on the pipe path a write that
          // loses its reader arrives here with the driver alive, and leaving it
          // running would trade "the process dies" for "the process cannot
          // exit". What changed is only who can be on that path -- a driver
          // holding the registry lock is handed a file instead, so it is never
          // the one being killed. See the note on stageInput.
          child.kill("SIGKILL");
          return;
        } catch { /* already gone; fall through and settle now */ }
      }
      settle(failure, null);
    };

    child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
      // Forwarded as it arrives, not just quoted back in the failure message: a
      // bulk seal reports its progress here, and a backfill that only printed
      // how it went once it had finished would not be progress at all. stdout
      // is the JSONL event stream, so this is the only channel for it.
      process.stderr.write(chunk);
    });
    child.on("error", fail);
    // Only on the pipe path -- a staged input has no stdin stream to put this
    // on, and no write that could fail.
    //
    // A write to stdin that loses its reader is a SYMPTOM, not the verdict: the
    // child exited before the whole input was sent and closing its read end
    // turned the next write into EPIPE (on macOS -- socketpairs -- ENOTCONN or
    // EPIPE depending on how far the write got; the errno set is not closed).
    // The reason it exited is its exit code, and a busy `apply` exits 11 exactly
    // here -- its page is larger than the pipe buffer, so it waits out the busy
    // timeout and exits while the parent is still writing. Concluding
    // "stdin-write failed" on the errno, ahead of the exit, is what masked that
    // retryable 11 as an unrecoverable EPIPE and ended #910's reprocess.
    //
    // So stop writing and let 'exit' rule on the code. Keep the marker for
    // diagnostics, but do not settle on it here: `failure` stays unset, so
    // 'exit' reports the child's own answer.
    //
    // Not forever, though. This path keeps its pipe (the roster path stages, so
    // it never has a lost-reader write), and the pipe path's bound against a
    // child that stops reading AND does not exit is the SIGKILL in `fail` --
    // written for exactly this, so "the process dies" is not traded for "the
    // process cannot exit". Deferring to 'exit' must not drop that bound, so a
    // timer keeps it: if no exit arrives, `fail` runs and kills, as before.
    //
    // Its length (storageDriverExitGraceMs) is not a tuning knob and not a wait
    // the fast path ever feels: the only child worth waiting for is a busy one,
    // which exits the busy timeout after it starts waiting, so any bound past
    // that timeout catches every exit that is coming and delays only an
    // already-broken child's failure.
    //
    // `settled` first, so nothing here runs after the call has ended -- a stdin
    // error can arrive after 'exit' has already settled a non-zero exit, and
    // without this it would arm a fresh timer past the cleared one.
    child.stdin?.on("error", (error) => {
      if (settled) return;
      error.driverFailurePhase = "stdin-write";
      lastStdinError = error;
      child.stdin.destroy();
      if (stdinExitTimer === null) {
        stdinExitTimer = setTimeout(() => fail(error), storageDriverExitGraceMs());
        stdinExitTimer.unref?.();
      }
    });
    // Every failure ends here, at 'exit'. A driver that merely exits non-zero is
    // the ordinary case and it needs this as much as a stream error does: it too
    // can leave a grandchild holding the inherited pipes, and waiting for 'close'
    // would then wait forever for output nobody is going to end. Only success
    // goes on to 'close', because only success has to parse all of stdout.
    child.on("exit", (code, signal) => {
      if (failure) { fail(failure); return; }
      // A clean exit after a broken write is not a clean sync: the child cannot
      // have read input the parent never finished sending, so a "success" here
      // would be a sync of a truncated page. Report the write failure instead.
      if (code === 0 && !signal && lastStdinError) { fail(lastStdinError); return; }
      if (code === 0 && !signal) return;
      // The team and the binding path, because the previous fallback said
      // "inspect its team storage and binding" and named neither -- on a
      // machine that may hold several teams, that is an instruction with no
      // object. Both values are the caller's; this function is handed them
      // rather than reading them back out of `args`, where they sit behind a
      // positional index that has already been miscounted once.
      const subject = team === undefined ? "" : ` for team '${team}'`;
      const diagnostic = stderr.trim() ||
        "driver returned a non-zero exit without diagnostics; inspect that team's storage" +
          bindingNote(bindingPath);
      const error = new Error(
        `${label} ${operation} failed${subject} (${describeChildExit(code, signal)}): ${diagnostic}`);
      // The raw status, for the one caller that acts on a specific value -- the
      // storage adapter's "busy" exit, see `driver` -- without parsing its own
      // sentence back out of the message.
      error.driverExitCode = code;
      fail(error);
    });
    child.on("close", () => {
      if (failure) { settle(failure, null); return; }
      // Order-independent with the exit above: whichever of them ran, a stdin
      // write that lost its reader means the child cannot have received the
      // whole page, so 'close' must not settle success on a truncated input --
      // it fails closed on the recorded write error instead. The exit handler
      // catches this when the exit is seen first; this catches the case where
      // the write error was recorded only after a clean exit had returned.
      if (lastStdinError) { settle(lastStdinError, null); return; }
      try {
        settle(null, parse(stdout));
      } catch (error) {
        settle(error, null);
      }
    });
    // Nothing to write when the input was staged: it was complete on disk
    // before the spawn, and the child is already reading it.
    if (!staged) {
      child.stdin.end(input.map((record) => `${JSON.stringify(record)}\n`).join(""));
    }
  });
}

// The storage adapter's exit status for "the store was busy" -- another writer
// held it past the busy timeout (storage-sync-driver.sh says why it is 11). It
// is the one driver failure that is about the moment rather than the input:
// the same call succeeds once that writer is done. Every other non-zero exit
// is a decision (a failed check, an unsupported operation) and asking again
// does not change it, so nothing else is retried here.
export const STORAGE_BUSY_EXIT = 11;
// One wait is never longer than this; the budget is the total. The budget has
// to outlast a real writer, not a polite one: the first prepare on a pulled
// store held the lock for 63 s on the machine that filed #910 (155 s on a copy
// of the same data), and that is the writer that killed the reprocess this
// exists for. 5 minutes is that with margin for a slower disk.
//
// Constants, not an environment knob. The only reason to vary the budget was
// that the right value is not settled -- #919 removes that first-prepare lock,
// and the budget can come down then, here, in one place. A knob that accepts
// an arbitrary string is a surface that has to be validated (not a number, not
// finite, not safe) and each of those was a way back to "retry forever", the
// one outcome a budget exists to rule out; the tests inject the sleep and do
// not need a shorter budget. If an operator ever needs to tune this, that is
// the moment to add the surface, with the reason.
const STORAGE_BUSY_WAIT_CAP_MS = 30000;
const STORAGE_BUSY_RETRY_BUDGET_MS = 300000;

export async function driver(operation, config, input, extra = [], dependencies = {}) {
  const script = process.env.AGMSG_SYNC_DRIVER;
  if (!script) throw new Error("AGMSG_SYNC_DRIVER is not set");
  const sleepCall = dependencies.sleepCall ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  const eventCall = dependencies.eventCall ?? event;
  const budgetMs = STORAGE_BUSY_RETRY_BUDGET_MS;
  const run = () => runDriver({
    args: [script, operation, config.local_team, config.server_instance_id,
      config.remote_team_id, String(config.protocol_version), ...extra],
    label: "storage sync",
    operation,
    team: config.local_team,
    bindingPath: bindingPathOrReason(config.local_team),
    parse: (stdout) => (["resync-status", "resync"].includes(operation) ?
      parseStrictJsonl(stdout) : parseJsonl(stdout)),
    input,
  });
  // Retrying is safe ONLY because a busy call wrote nothing: every operation
  // that writes does so in one BEGIN IMMEDIATE transaction fed with -bail (or
  // as an argv statement, where the CLI stops at the first error), so a lock
  // lost at BEGIN leaves the store as it was, and the prepare's chunked
  // reservations are re-entrant by contract. The adapter exits 11 only when the
  // last statement was the busy one -- the operation returned at that point.
  let waitedMs = 0;
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await run();
    } catch (error) {
      if (error?.driverExitCode !== STORAGE_BUSY_EXIT) throw error;
      const waitMs = Math.min(STORAGE_BUSY_WAIT_CAP_MS, 1000 * 2 ** (attempt - 1));
      if (waitedMs + waitMs > budgetMs) {
        // The driver's own sentence stays in front; what is added is how long
        // this waited, so the operator can tell "held for minutes" from
        // "held forever".
        error.message += ` -- waited ${Math.round(waitedMs / 1000)} s for the store to come free ` +
          `(the ${budgetMs / 1000} s budget) and it did not`;
        error.code = "storage-busy";
        error.retryable = true;
        throw error;
      }
      await eventCall("driver.busy", { operation, attempt, wait_ms: waitMs, waited_ms: waitedMs });
      await sleepCall(waitMs);
      waitedMs += waitMs;
    }
  }
}

// The roster file to hand the driver, when this process can work it out.
//
// Passing an explicit path is what keeps the driver out of the location
// business: it receives one file rather than a directory to build a path from.
// When neither a connection root nor a skill directory is set there is nothing
// to derive, so nothing is passed and the driver's own fallback applies —
// failing here instead would break callers that never had a root to begin with.
function rosterFileFor(team) {
  const supplied = process.env.AGMSG_SYNC_LOCAL_ROSTER_FILE;
  if (supplied) return supplied;
  if (!(process.env.AGMSG_SYNC_CONNECTION_DIR ?? process.env.SKILL_DIR)) return undefined;
  return teamConfigPath(team);
}

export async function rosterDriver(operation, config, input, extra = []) {
  const script = process.env.AGMSG_SYNC_ROSTER_DRIVER ??
    join(dirname(fileURLToPath(import.meta.url)), "roster-sync-driver.sh");
  return runDriver({
    args: [script, operation, config.local_team, config.server_instance_id,
      config.remote_team_id, String(config.protocol_version), ...extra],
    label: "roster sync",
    operation,
    team: config.local_team,
    bindingPath: bindingPathOrReason(config.local_team),
    parse: parseJsonl,
    input,
    // This is the driver that takes the team's registry lock, as its first act,
    // and releases it only from a trap. It is the reason the input is staged in
    // a file: nothing here may ever be in a position to kill it. The storage
    // driver takes no such lock and is deliberately not given this.
    holdsRegistryLock: true,
    // The roster file, resolved here and handed over as one path — not the
    // directory it sits in. A directory would put the driver back in the
    // business of deriving locations, which is what AGMSG_SYNC_CONNECTION_DIR
    // was doing before it was stripped, and the driver has no business knowing
    // that layout.
    //
    // Set at this single point rather than by each subcommand that shells out.
    // `remote.sh pull` already passed this variable, and it was the ONLY caller
    // that did: every other path fell back to the driver's own guess, which
    // pointed at the skill directory and missed a second machine's teams
    // entirely. A per-subcommand fix would have left the next subcommand to
    // remember; there is nothing to remember now.
    // Derived only when a root exists to derive it from. teamConfigPath throws
    // otherwise, and throwing here would fail the call before the driver was
    // even started — turning a resolvable situation into a hard error for every
    // caller that has no connection root, which is what happened the first time
    // this was written unconditionally.
    rosterFile: rosterFileFor(config.local_team),
  });
}

function parseJsonl(value) {
  return value.split(/\r?\n/u).filter(Boolean).map((line) => JSON.parse(line));
}

async function event(name, fields = {}) {
  const record = { at: new Date().toISOString(), event: name, ...fields };
  const line = `${JSON.stringify(record)}\n`;
  process.stdout.write(line);
  if (process.env.AGMSG_SYNC_LOG_FILE) {
    await appendFile(process.env.AGMSG_SYNC_LOG_FILE, line, { encoding: "utf8", mode: 0o600 });
  }
}

async function logApplyOutcomes(config, records, applied) {
  for (const outcome of applied.filter((record) => record.type === "sync_apply_outcome")) {
    const source = records.find((record) => record.type === "sync_pull_message" && record.id === outcome.id);
    await event(outcome.status === "imported" ? "pull.import" :
      outcome.status === "reconciled" ? "pull.reconciled" : "pull.quarantined", {
      id: outcome.id, server_seq: outcome.server_seq, status: outcome.status,
      ...(outcome.status === "imported" && source?.projection &&
        (config.cipher_profile === "none" || process.env.AGMSG_SYNC_LOG_PLAINTEXT === "1") ? {
        from_agent: source.projection.from_agent, to_agent: source.projection.to_agent,
        body: source.projection.body,
      } : {}),
    });
  }
}

function currentPolicy(capabilities, serverSeq) {
  const target = BigInt(serverSeq);
  const candidates = capabilities.policy_history.filter((entry) =>
    BigInt(sequence(entry.effective_from_seq, "policy effective_from_seq")) <= target);
  if (candidates.length === 0) throw new Error("policy history has no effective entry");
  return candidates.reduce((best, entry) => BigInt(entry.policy_revision) > BigInt(best.policy_revision) ? entry : best);
}

function currentLocalPolicy(config, serverSeq) {
  const target = BigInt(serverSeq);
  const candidates = config.local_security_history.filter((entry) => BigInt(entry.effective_from_seq) <= target);
  if (candidates.length === 0) throw new Error("local security history has no effective entry");
  return candidates.reduce((best, entry) => BigInt(entry.local_security_revision) > BigInt(best.local_security_revision) ? entry : best);
}

function ageHistory(config) {
  const initial = ageSnapshotChain(config.age_v1)[0]?.history ?? [];
  return [
    ...initial,
    ...(config.age_v1_runtime_history ?? []),
  ];
}

function currentAgeEpoch(config, serverSeq) {
  const history = ageHistory(config);
  if (!Array.isArray(history) || history.length < 1) return null;
  const target = BigInt(sequence(serverSeq, "age epoch server_seq"));
  const candidates = history.filter((entry) =>
    BigInt(sequence(entry.effective_from_seq, "age epoch effective_from_seq")) <= target);
  if (candidates.length === 0) return null;
  return candidates.reduce((best, entry) =>
    BigInt(entry.epoch_revision) > BigInt(best.epoch_revision) ? entry : best);
}

export async function evaluatePull(config, capabilities, message) {
  sequence(message.server_seq, "message server_seq");
  if (!UUID_V4.test(message.id) || !TIMESTAMP.test(message.server_received_at) || typeof message.envelope !== "object") {
    return { status: "malformed", reason: "invalid message metadata" };
  }
  const serverPolicy = currentPolicy(capabilities, message.server_seq);
  const localPolicy = currentLocalPolicy(config, message.server_seq);
  if (!serverPolicy.accepted_envelope_versions.includes(message.envelope.v) ||
      !serverPolicy.write_allowed_ciphers.includes(message.envelope.cipher) ||
      (localPolicy.minimum_security_mode === "e2ee-required" && message.envelope.cipher === "none")) {
    return { status: "policy_violation", reason: "envelope violates effective policy",
      policy_revision: serverPolicy.policy_revision,
      local_security_revision: localPolicy.local_security_revision };
  }
  if (message.envelope.v !== 1 || !["none", "age-v1"].includes(message.envelope.cipher)) {
    return { status: "unsupported_cipher", reason: "cipher profile is not implemented",
      policy_revision: serverPolicy.policy_revision,
      local_security_revision: localPolicy.local_security_revision };
  }
  let identityFile;
  let openedEpoch;
  let effectiveEpoch;
  if (message.envelope.cipher === "age-v1") {
    if (config.cipher_profile !== "age-v1" || !config.age_v1) {
      return { status: "unsupported_cipher", reason: "age-v1 is not configured",
        policy_revision: serverPolicy.policy_revision,
        local_security_revision: localPolicy.local_security_revision };
    }
    effectiveEpoch = currentAgeEpoch(config, message.server_seq);
    if (!effectiveEpoch) {
      return { status: "policy_violation", reason: "envelope key_id violates effective epoch",
        policy_revision: serverPolicy.policy_revision,
        local_security_revision: localPolicy.local_security_revision };
    }
    openedEpoch = ageHistory(config).find((entry) =>
      entry.key_id === message.envelope.key_id &&
      BigInt(sequence(entry.effective_from_seq, "age epoch effective_from_seq")) <=
        BigInt(message.server_seq));
    if (!openedEpoch) {
      return { status: "policy_violation", reason: "envelope key_id violates effective epoch",
        policy_revision: serverPolicy.policy_revision,
        local_security_revision: localPolicy.local_security_revision };
    }
    identityFile = config.age_v1.identity_files?.[openedEpoch.key_id];
  }
  try {
    const projection = await openEnvelope({ envelope: message.envelope,
      protocol_version: config.protocol_version, team_id: config.remote_team_id,
      wire_id: message.id, identity_file: identityFile,
      expected_recipients: message.envelope.cipher === "age-v1" ?
        openedEpoch.recipients : undefined,
      max_blob_bytes: 1_048_576 });
    if (message.envelope.cipher === "age-v1" &&
        openedEpoch.key_id !== effectiveEpoch.key_id) {
      const announced = projection?.kind === "key_rotated" &&
        SEQUENCE.test(projection.epoch ?? "") &&
        BigInt(projection.epoch) === BigInt(effectiveEpoch.epoch_revision) &&
        BigInt(openedEpoch.epoch_revision) + 1n ===
          BigInt(effectiveEpoch.epoch_revision);
      if (!announced) {
        return { status: "policy_violation", reason: "envelope key_id violates effective epoch",
          policy_revision: serverPolicy.policy_revision,
          local_security_revision: localPolicy.local_security_revision };
      }
    }
    return { status: "importable", projection,
      policy_revision: serverPolicy.policy_revision,
      local_security_revision: localPolicy.local_security_revision };
  } catch (error) {
    const status = error instanceof CipherStateError ? error.state : "malformed";
    return { status, reason: error.message,
      policy_revision: serverPolicy.policy_revision,
      local_security_revision: localPolicy.local_security_revision };
  }
}

export function validateCapabilities(config, value) {
  validateBinding(config, value);
  sequence(value.current_seq, "current_seq"); sequence(value.min_available_seq, "min_available_seq");
  if (!Array.isArray(value.policy_history) || value.policy_history.length < 1 || value.policy_history.length > 4096 ||
      !Array.isArray(value.accepted_envelope_versions) || !Array.isArray(value.write_allowed_ciphers)) {
    throw new Error("capabilities response is invalid");
  }
  const current = BigInt(value.current_seq);
  const floor = BigInt(value.min_available_seq);
  if (floor > current) throw new Error("min_available_seq exceeds current_seq");
  const currentRevision = BigInt(sequence(value.policy_revision, "policy_revision"));
  const currentBoundary = BigInt(sequence(value.effective_from_seq, "effective_from_seq"));
  sequence(value.max_blob_bytes, "max_blob_bytes");
  if (BigInt(value.max_blob_bytes) < 1n || BigInt(value.max_blob_bytes) > 1_048_576n) {
    throw new Error("max_blob_bytes is outside the protocol limit");
  }
  validatePolicySet(value.accepted_envelope_versions, value.write_allowed_ciphers, "current policy");
  let previousRevision = -1n;
  let previousBoundary = 0n;
  for (const entry of value.policy_history) {
    const revision = BigInt(sequence(entry.policy_revision, "policy history revision"));
    const boundary = BigInt(sequence(entry.effective_from_seq, "policy history boundary"));
    validatePolicySet(entry.accepted_envelope_versions, entry.write_allowed_ciphers, "policy history");
    if (revision <= previousRevision || boundary <= previousBoundary) {
      throw new Error("policy history is not canonical ascending history");
    }
    previousRevision = revision; previousBoundary = boundary;
  }
  if (BigInt(value.policy_history[0].effective_from_seq) !== 1n) {
    throw new Error("policy history must begin at sequence 1");
  }
  const final = value.policy_history.at(-1);
  if (BigInt(final.policy_revision) !== currentRevision ||
      BigInt(final.effective_from_seq) !== currentBoundary ||
      !sameArray(final.accepted_envelope_versions, value.accepted_envelope_versions) ||
      !sameArray(final.write_allowed_ciphers, value.write_allowed_ciphers)) {
    throw new Error("current policy does not match final policy history entry");
  }
  if (value.next_sequence_boundary === null) {
    if (current !== MAX_SEQUENCE) throw new Error("next_sequence_boundary is unexpectedly null");
  } else {
    const next = BigInt(sequence(value.next_sequence_boundary, "next_sequence_boundary"));
    if (current === MAX_SEQUENCE || next !== current + 1n) {
      throw new Error("next_sequence_boundary does not follow current_seq");
    }
    if (previousBoundary > next) throw new Error("policy history starts beyond the next sequence boundary");
  }
}

function validatePolicySet(versions, ciphers, label) {
  if (!Array.isArray(versions) || versions.length < 1 ||
      versions.some((version) => !Number.isInteger(version) || version < 0 || version > 0xffff_ffff) ||
      new Set(versions).size !== versions.length || !Array.isArray(ciphers) ||
      ciphers.some((cipher) => typeof cipher !== "string" || !/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(cipher)) ||
      new Set(ciphers).size !== ciphers.length) {
    throw new Error(`${label} capability set is invalid`);
  }
}

function sameArray(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

export function plaintextWriteEligible(config, value) {
  validateCapabilities(config, value);
  const boundary = value.next_sequence_boundary;
  return boundary !== null && value.accepted_envelope_versions.includes(1) &&
    value.write_allowed_ciphers.includes("none") &&
    currentLocalPolicy(config, boundary).minimum_security_mode === "plaintext-allowed";
}

export function selectWriteProfile(config, value) {
  validateCapabilities(config, value);
  const boundary = value.next_sequence_boundary;
  const profile = config.cipher_profile ?? "none";
  if (boundary === null) return { eligible: false, reason: "sequence-exhausted", profile };
  if (!value.accepted_envelope_versions.includes(1) || !value.write_allowed_ciphers.includes(profile)) {
    return { eligible: false, reason: `${profile}-write-not-allowed`, profile };
  }
  const localPolicy = currentLocalPolicy(config, boundary);
  if (profile === "none") {
    return localPolicy.minimum_security_mode === "plaintext-allowed" ?
      { eligible: true, profile, key_id: null, recipients: [] } :
      { eligible: false, reason: "local-e2ee-required", profile };
  }
  if (profile === "age-v1") {
    const epoch = currentAgeEpoch(config, boundary);
    if (!epoch || !Array.isArray(epoch.recipients)) {
      return { eligible: false, reason: "age-epoch-unavailable", profile };
    }
    return { eligible: true, profile, key_id: epoch.key_id, recipients: epoch.recipients };
  }
  return { eligible: false, reason: "cipher-profile-unsupported", profile };
}

export function isRetryable(error) {
  if (error?.retryable === true) return true;
  return [408, 429, 500, 502, 503, 504].includes(error?.status);
}

export function validateAckMapping(candidates, acks) {
  if (!Array.isArray(acks) || acks.length !== candidates.length) {
    throw new Error("incomplete ack mapping");
  }
  const seenIds = new Set();
  const seenSequences = new Set();
  let previous = -1n;
  return acks.map((ack, index) => {
    const candidate = candidates[index];
    const fields = Object.keys(ack).sort().join(",");
    if (fields !== "disposition,id,server_seq" || ack.id !== candidate.id ||
        !["stored", "duplicate"].includes(ack.disposition)) {
      throw new Error("ack shape/order/id mismatch");
    }
    sequence(ack.server_seq, "ack server_seq");
    const current = BigInt(ack.server_seq);
    if (seenIds.has(ack.id) || seenSequences.has(ack.server_seq) || current <= previous) {
      throw new Error("ack sequence mapping is not strictly increasing and unique");
    }
    seenIds.add(ack.id); seenSequences.add(ack.server_seq); previous = current;
    return { type: "sync_push_ack", local_position: candidate.local_position, id: ack.id,
      server_seq: ack.server_seq, disposition: ack.disposition };
  });
}

export function readStateUpdateBatches(members, records) {
  const memberIds = new Set(members.map((member) => member.member_id));
  const frontiers = new Map();
  const exact = new Map(members.map((member) => [member.member_id, []]));
  const blocked = new Map();
  for (const record of records) {
    if (!memberIds.has(record.member_id)) throw new Error("driver emitted an unknown read member");
    if (record.type === "sync_read_frontier") {
      if (frontiers.has(record.member_id)) throw new Error("driver emitted duplicate read frontier");
      frontiers.set(record.member_id, sequence(record.server_seq, "prepared read frontier"));
    } else if (record.type === "sync_read_exact") {
      if (!UUID_V4.test(record.wire_id)) throw new Error("driver emitted an invalid exact wire ID");
      exact.get(record.member_id).push(record.wire_id);
    } else if (record.type === "sync_read_blocked") {
      if (blocked.has(record.member_id) ||
          !["member-name-mismatch", "read-state-limit-exceeded"].includes(record.reason)) {
        throw new Error("driver emitted an invalid blocked read member");
      }
      blocked.set(record.member_id, record.reason);
    } else {
      throw new Error("driver emitted an unknown read-state record");
    }
  }
  const entries = [];
  for (const member of members) {
    if (blocked.has(member.member_id)) {
      if (frontiers.has(member.member_id) || exact.get(member.member_id).length > 0) {
        throw new Error("driver emitted updates for a blocked read member");
      }
      continue;
    }
    const serverSeq = frontiers.get(member.member_id);
    if (serverSeq === undefined) throw new Error("driver omitted a member read frontier");
    const wires = exact.get(member.member_id);
    if (new Set(wires).size !== wires.length) throw new Error("driver emitted duplicate exact reads");
    if (wires.length === 0) {
      entries.push({ member_id: member.member_id, server_seq: serverSeq, exact_wire_ids: [] });
    } else {
      for (let offset = 0; offset < wires.length; offset += 1000) {
        entries.push({ member_id: member.member_id, server_seq: serverSeq,
          exact_wire_ids: wires.slice(offset, offset + 1000) });
      }
    }
  }
  const batches = [];
  let batch = []; let exactCount = 0; let batchMembers = new Set();
  for (const entry of entries) {
    if (batch.length >= 1000 || exactCount + entry.exact_wire_ids.length > 1000 ||
        batchMembers.has(entry.member_id)) {
      batches.push(batch); batch = []; exactCount = 0; batchMembers = new Set();
    }
    batch.push(entry); exactCount += entry.exact_wire_ids.length; batchMembers.add(entry.member_id);
  }
  if (batch.length > 0) batches.push(batch);
  return batches.length > 0 ? batches : [[]];
}

export function stage2ReadStateSupported(records) {
  if (!Array.isArray(records) || records.length !== 1 ||
      records[0]?.type !== "sync_driver_capabilities" ||
      !Array.isArray(records[0].capabilities) ||
      records[0].capabilities.some((value) => typeof value !== "string")) {
    throw new Error("driver capability response is invalid");
  }
  return records[0].capabilities.includes("stage2-read-state");
}

export function stage1ResyncSupported(records) {
  if (!Array.isArray(records) || records.length !== 1 ||
      records[0]?.type !== "sync_driver_capabilities" ||
      !Array.isArray(records[0].capabilities) ||
      records[0].capabilities.some((value) => typeof value !== "string") ||
      new Set(records[0].capabilities).size !== records[0].capabilities.length) {
    throw new Error("driver capability response is invalid");
  }
  return records[0].capabilities.includes("stage1-resync");
}

function strictKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).sort().join(",") !== [...expected].sort().join(",")) {
    throw new Error(`${label} shape is invalid`);
  }
}

function validDriverGeneration(value) {
  return typeof value === "string" && Buffer.byteLength(value, "utf8") >= 1 &&
    Buffer.byteLength(value, "utf8") <= 256 && !/[\u0000-\u001f\u007f]/u.test(value);
}

function validateResyncAudit(audit, floor, transportCursor, label) {
  strictKeys(audit, ["expected_transport_cursor", "accepted_floor", "gap_start",
    "gap_end", "reason"], label);
  const expected = BigInt(sequence(audit.expected_transport_cursor, `${label} expected cursor`));
  const accepted = BigInt(sequence(audit.accepted_floor, `${label} accepted floor`));
  const start = BigInt(sequence(audit.gap_start, `${label} gap start`));
  const end = BigInt(sequence(audit.gap_end, `${label} gap end`));
  const current = BigInt(sequence(transportCursor, `${label} transport cursor`));
  if (audit.accepted_floor !== floor || end !== accepted || start !== expected + 1n ||
      expected >= accepted || accepted > current || audit.reason !== "retention-gap-accepted") {
    throw new Error(`${label} is inconsistent`);
  }
  return audit;
}

export function validateResyncStatus(records, floor) {
  sequence(floor, "accepted floor");
  if (!Array.isArray(records) || records.length !== 1) {
    throw new Error("driver must emit exactly one resync status");
  }
  const status = records[0];
  strictKeys(status, ["type", "driver_generation", "transport_cursor", "audit"],
    "resync status");
  if (status.type !== "sync_resync_status" || !validDriverGeneration(status.driver_generation)) {
    throw new Error("resync status is invalid");
  }
  sequence(status.transport_cursor, "resync transport cursor");
  if (status.audit !== null) {
    validateResyncAudit(status.audit, floor, status.transport_cursor, "resync audit");
  }
  return status;
}

export function validateResyncResult(records, status, floor) {
  if (!Array.isArray(records) || records.length !== 1) {
    throw new Error("driver must emit exactly one resync result");
  }
  const result = records[0];
  strictKeys(result, ["type", "driver_generation", "expected_transport_cursor",
    "transport_cursor", "accepted_floor", "gap_start", "gap_end", "reason"],
  "resync result");
  if (result.type !== "sync_resync_result" ||
      result.driver_generation !== status.driver_generation ||
      result.transport_cursor !== floor) {
    throw new Error("resync result is invalid");
  }
  validateResyncAudit({
    expected_transport_cursor: result.expected_transport_cursor,
    accepted_floor: result.accepted_floor,
    gap_start: result.gap_start,
    gap_end: result.gap_end,
    reason: result.reason,
  }, floor, result.transport_cursor, "resync result");
  return result;
}

export function validateReadStatePage(config, value, pageLimit, pageAfter = null) {
  validateBinding(config, value);
  const floor = BigInt(sequence(value.min_available_seq, "read-state floor"));
  const current = BigInt(sequence(value.current_seq, "read-state current_seq"));
  if (floor > current || !Array.isArray(value.items) || value.items.length > pageLimit ||
      (value.has_more === true && value.items.length === 0) ||
      typeof value.has_more !== "boolean") {
    throw new Error("read-state response is invalid");
  }
  const afterKey = pageAfter === null ? null : [pageAfter.member_id,
    pageAfter.kind === "frontier" ? 0 : 1, pageAfter.wire_id ?? ""];
  let prior = afterKey;
  for (const item of value.items) {
    const fields = Object.keys(item).sort().join(",");
    if (!UUID_V7.test(item?.member_id) ||
        (item.kind === "frontier" && (fields !== "kind,member_id,server_seq" ||
          BigInt(sequence(item.server_seq, "read-state frontier")) < floor ||
          BigInt(item.server_seq) > current)) ||
        (item.kind === "exact" && (fields !== "kind,member_id,wire_id" || !UUID_V4.test(item.wire_id))) ||
        !["frontier", "exact"].includes(item.kind)) {
      throw new Error("read-state item is invalid");
    }
    const key = [item.member_id, item.kind === "frontier" ? 0 : 1, item.wire_id ?? ""];
    if (prior && (key[0] < prior[0] || (key[0] === prior[0] &&
        (key[1] < prior[1] || (key[1] === prior[1] && key[2] <= prior[2]))))) {
      throw new Error("read-state page order is not canonical");
    }
    prior = key;
  }
  const expectedNext = value.has_more && value.items.length > 0 ? (() => {
    const last = value.items.at(-1);
    return last.kind === "frontier" ? { member_id: last.member_id, kind: "frontier" } :
      { member_id: last.member_id, kind: "exact", wire_id: last.wire_id };
  })() : null;
  if (JSON.stringify(value.next_page_after) !== JSON.stringify(expectedNext)) {
    throw new Error("read-state next page key is inconsistent");
  }
  return value;
}

export async function consistentReadStateContext(config, initialCapabilities, fetcher = request) {
  let capabilities = initialCapabilities;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const roster = await fetcher(config, "/v1/members");
    const members = validateMembers(config, roster);
    if (roster.min_available_seq === capabilities.min_available_seq) {
      return { capabilities, members };
    }
    capabilities = await fetcher(config, "/v1/capabilities");
    validateCapabilities(config, capabilities);
  }
  const error = new Error("retention changed while loading the read-state context");
  error.retryable = true;
  throw error;
}

function parseCheckpoint(value) {
  const match = /^(0|[1-9][0-9]*):([0-9a-f]{64})$/u.exec(value ?? "");
  if (!match) throw new Error("age-checkpoint must be REVISION:SHA256");
  sequence(match[1], "age checkpoint revision");
  return { epoch_revision: match[1], snapshot_sha256: match[2] };
}

async function identityFiles(values) {
  const result = {};
  for (const value of values ?? []) {
    const separator = value.indexOf("=");
    const keyId = separator === -1 ? "" : value.slice(0, separator);
    const suppliedPath = separator === -1 ? "" : value.slice(separator + 1);
    if (!/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(keyId) || !suppliedPath || result[keyId]) {
      throw new Error("age-identity must be a unique KEY_ID=FILE mapping");
    }
    const path = resolve(suppliedPath);
    const metadata = await stat(path);
    if (!metadata.isFile()) throw new Error(`age identity for ${keyId} is not a file`);
    if (process.platform !== "win32" && (metadata.mode & 0o077) !== 0) {
      throw new Error(`age identity for ${keyId} must not be group/world accessible`);
    }
    result[keyId] = path;
  }
  return result;
}

async function existingConfig(team) {
  try {
    return await readStoredSyncConfig(team);
  }
  catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

export async function configure(args) {
  const team = requireName(args.team, "team");
  if (!UUID_V7.test(args["team-id"] ?? "")) throw new Error("team-id must be a canonical UUIDv7");
  const cipherProfile = args.cipher ?? "none";
  const minimumSecurity = args["minimum-security"];
  if (!["none", "age-v1"].includes(cipherProfile)) throw new Error("cipher must be none or age-v1");
  if ((cipherProfile === "none" && minimumSecurity !== "plaintext-allowed") ||
      (cipherProfile === "age-v1" && minimumSecurity !== "e2ee-required")) {
    throw new Error(`${cipherProfile} requires its explicit matching minimum-security mode`);
  }
  const serverUrl = new URL(args.server).toString().replace(/\/$/, "");
  const binding = await readConnectedBinding(team);
  if (serverUrl !== binding.endpoint || args["team-id"] !== binding.remote_team_id) {
    throw new Error("configure binding does not match remote.sh connect");
  }
  const ready = await health(serverUrl, binding.remote_team_id);
  if (ready.server_instance_id !== binding.server_instance_id) {
    throw new Error("health server instance does not match remote.sh connect");
  }
  // Read back what the server says the team is, and refuse if it disagrees.
  //
  // Sending the header alone would change nothing observable here — it would be
  // a field that exists and that nobody consults, which this file already has
  // one of (the handoff bundle's format_version is checked for `!== 1` and never
  // used to negotiate). The check is the reason the header is worth adding.
  //
  // Until now `remote_team_id` was whatever was passed in on the command line,
  // stored without ever being compared to the server. A mismatch stayed
  // invisible until the first push failed, far from the step that caused it.
  // Strict equality, with no exemption for a server that omits the field. An
  // `!== undefined` guard would let exactly the case this is meant to catch pass
  // silently — an endpoint that does not answer per-team looks identical to one
  // that agrees with us. Absent is not agreement.
  if (ready.team_id !== binding.remote_team_id) {
    throw new Error("health team does not match remote.sh connect");
  }
  const config = {
    format_version: 1, local_team: team, server_url: serverUrl,
    server_instance_id: ready.server_instance_id, remote_team_id: args["team-id"],
    protocol_version: 1, cipher_profile: cipherProfile,
    local_security_history: [{ local_security_revision: "0", effective_from_seq: "1",
      minimum_security_mode: minimumSecurity }],
  };
  if (cipherProfile === "age-v1") {
    if (!args["age-snapshot"] || !args["age-checkpoint"]) {
      throw new Error("age-v1 requires --age-snapshot and --age-checkpoint");
    }
    const ageSnapshotPaths = Array.isArray(args["age-snapshot"]) ?
      args["age-snapshot"] : [args["age-snapshot"]];
    const ageSnapshots = [];
    for (const ageSnapshotPath of ageSnapshotPaths) {
      const ageSnapshotText = await readFile(resolve(ageSnapshotPath), "utf8");
      const ageSnapshot = parseStrictJson(ageSnapshotText);
      if (ageSnapshotText.trim() !== canonicalJson(ageSnapshot)) {
        throw new Error("age snapshot must be RFC 8785 JCS without duplicate or noncanonical fields");
      }
      ageSnapshots.push(ageSnapshot);
    }
    const latestAgeSnapshot = ageSnapshots.at(-1);
    const checkpoint = parseCheckpoint(args["age-checkpoint"]);
    const confirmation = args["age-confirmation"];
    if (confirmation !== "operator-live") {
      throw new Error("age-v1 requires explicit --age-confirmation operator-live");
    }
    config.age_v1 = {
      epoch_snapshots: ageSnapshots,
      checkpoint: { ...checkpoint, writer_generation: latestAgeSnapshot.writer_generation,
        confirmed_at: new Date().toISOString() },
      identity_files: await identityFiles(args["age-identity"]),
      age_version: ageExecutableVersion(),
    };
    validateAgeConfiguration(config);
    validateConfiguredAgeIdentities(config);
  } else if (args["age-snapshot"] || args["age-checkpoint"] || args["age-confirmation"] ||
      args["age-identity"]) {
    throw new Error("age options require --cipher age-v1");
  }
  const previous = await existingConfig(team);
  if (previous) {
    previous.cipher_profile ??= "none";
    if (previous.local_team !== team || previous.protocol_version !== 1 ||
        !UUID_V7.test(previous.server_instance_id ?? "") ||
        !UUID_V7.test(previous.remote_team_id ?? "")) {
      throw new Error("existing sync config binding is invalid");
    }
    validateLocalSecurityHistory(previous.local_security_history);
    if (previous.server_instance_id !== config.server_instance_id ||
        previous.remote_team_id !== config.remote_team_id ||
        previous.server_url !== config.server_url ||
        previous.cipher_profile !== config.cipher_profile) {
      throw new Error("configure cannot replace an existing binding or cipher profile");
    }
    if (cipherProfile === "age-v1") {
      validateAgeConfiguration(previous);
      await validateRetainedAgeCheckpoint(previous);
      const previousSnapshots = ageSnapshotChain(previous.age_v1);
      const proposedSnapshots = ageSnapshotChain(config.age_v1);
      const prefixMatches = previousSnapshots.every((snapshot, index) =>
        proposedSnapshots[index] !== undefined &&
        ageSnapshotDigest(proposedSnapshots[index]) === ageSnapshotDigest(snapshot));
      if (!prefixMatches || proposedSnapshots.length < previousSnapshots.length) {
        throw new Error("configure cannot replace or truncate a confirmed age snapshot chain");
      }
      config.age_v1.identity_files = {
        ...previous.age_v1.identity_files,
        ...config.age_v1.identity_files,
      };
      validateAgeConfiguration(config);
      validateConfiguredAgeIdentities(config);
    }
  }
  const capabilities = await request(config, "/v1/capabilities");
  validateCapabilities(config, capabilities);
  if (cipherProfile === "age-v1") {
    const retained = await retainAgeCheckpoint(config, args["age-confirmation"]);
    config.age_v1.checkpoint.confirmed_at = retained.confirmation.confirmed_at;
  }
  await writeConfig(configPath(team), config);
  await event("configured", { team, server_instance_id: config.server_instance_id,
    remote_team_id: config.remote_team_id });
}

// The server sequences this client holds as ROSTER mutations rather than as
// messages (#968). The roster driver journals one `roster_synced` record per
// applied mutation -- on the engine pull path and on the bootstrap path alike,
// and since the same commit that put roster mutations on the transport -- so
// the journal is the complete list of sequences that will never have a
// message mapping. The read-state frontier check needs that list: without it
// every roster sequence reads as a hole, and the first hole is seq 1 (the
// founding member_joined) on every team.
//
// Failure direction: a journal that cannot be read, or a line that cannot be
// parsed, yields NO sequences, which leaves the frontier check exactly as it
// was -- pinned. A frontier is never advanced on evidence that was not read.
// And it SAYS so: a pinned frontier is also what #968 looked like before this
// change, so a silent fallback here would be indistinguishable from the bug it
// fixes. The event names the file and, for a torn journal, the line. A journal
// that does not exist yet is not an anomaly (a team has no roster before its
// first pull) and is the one case that stays quiet.
//
// The whole journal is read on every read-state cycle. It holds one record
// per roster mutation the team ever applied (30 on a 21,505-message team),
// so it grows with membership events, not with traffic; the storage driver
// bounds the list it will accept at 10,000 and refuses beyond that. Cutting
// it at the members' read floor would need that floor here, and it lives in
// storage (sync_read_members.remote_server_seq) -- a new driver op, if the
// list ever grows enough to matter.
export async function rosterSequencesFor(config, dependencies = {}) {
  const readFileCall = dependencies.readFileCall ?? readFile;
  const eventCall = dependencies.eventCall ?? event;
  const rosterFile = dependencies.rosterFile ?? rosterFileFor(config.local_team);
  if (!rosterFile) return [];
  const journalPath = join(dirname(rosterFile), "roster.jsonl");
  let text;
  try { text = await readFileCall(journalPath, "utf8"); }
  catch (error) {
    if (error?.code !== "ENOENT") {
      try {
        await eventCall("read-state.roster-journal-unreadable", { path: journalPath,
          reason: error?.code ?? error?.message ?? String(error) });
      } catch { /* logging is best-effort */ }
    }
    return [];
  }
  const sequences = new Set();
  const lines = text.split(/\r?\n/u);
  for (const [index, line] of lines.entries()) {
    if (!line) continue;
    let record;
    try { record = JSON.parse(line); }
    catch (error) { // a torn journal is no evidence -- and is named, with its line
      try {
        await eventCall("read-state.roster-journal-unreadable", { path: journalPath,
          line: index + 1, reason: error?.message ?? String(error) });
      } catch { /* logging is best-effort */ }
      return [];
    }
    if (record?.type !== "roster_synced" ||
        record.server_instance_id !== config.server_instance_id ||
        record.remote_team_id !== config.remote_team_id) continue;
    // The sequence DOMAIN, through the one validator the rest of this file
    // uses. Shape alone let 9223372036854775808..9999999999999999999 through
    // (review finding); on the driver side the temp table's INTEGER PRIMARY
    // KEY refuses such a value outright, so the whole read-prepare
    // transaction died with a datatype mismatch -- neither a 13 nor "no
    // evidence" (measured in review). A record outside the domain is corrupt
    // evidence, treated like a torn line: named, and the whole list withheld.
    try { sequence(record.server_seq, "roster journal server_seq"); }
    catch (error) {
      try {
        await eventCall("read-state.roster-journal-unreadable", { path: journalPath,
          line: index + 1, reason: error?.message ?? String(error) });
      } catch { /* logging is best-effort */ }
      return [];
    }
    sequences.add(record.server_seq);
  }
  return [...sequences].sort((a, b) => BigInt(a) < BigInt(b) ? -1 : 1);
}

export async function readStateCycle(config, limit, dependencies = {}) {
  const driverCall = dependencies.driverCall ?? driver;
  const requestCall = dependencies.requestCall ?? request;
  const eventCall = dependencies.eventCall ?? event;
  const localAgentsCall = dependencies.localAgentsCall ?? localAgentRoster;
  const rosterSequencesCall = dependencies.rosterSequencesCall ?? rosterSequencesFor;
  const driverCapabilities = await driverCall("capabilities", config, []);
  if (!stage2ReadStateSupported(driverCapabilities)) {
    await eventCall("read-state.skipped", { reason: "driver-capability-not-advertised" });
    return;
  }
  const initialCapabilities = await requestCall(config, "/v1/capabilities");
  validateCapabilities(config, initialCapabilities);
  const { capabilities, members } = await consistentReadStateContext(
    config, initialCapabilities, requestCall,
  );
  const localAgents = await localAgentsCall(config.local_team);
  // Say when the server knows members this machine's roster does not.
  //
  // Both numbers are already here: `members` is the server's membership, and
  // `localAgents` is the same `config.json` `agents` map that `team.sh` prints
  // from. Nothing else in this loop compares them, and until it did, a freshly
  // pulled machine reported `0 member(s)` with no indication that anything was
  // outstanding -- while this very cycle logged
  // `read-state.applied ... "member_count":3` every few seconds (#743).
  //
  // That line is about read cursors for three members, not a roster of three,
  // and it is the most convincing wrong thing in the log: the reporter and the
  // first person to trace this both read it as the roster arriving. The
  // correction is not to hide it but to put the other number beside it.
  //
  // A roster materialises from `member_joined` events in the MESSAGE stream, so
  // it cannot arrive until a connected machine's engine has pushed them. That
  // is a wait, not a fault, and the names are what make it actionable -- an
  // agent about to pick its own name needs to know which ones are taken, which
  // is the whole reason `docs/remote-setup.md` step 4 exists.
  const unmaterialised = members
    .filter((member) => !localAgents.includes(member.name))
    .map((member) => member.name);
  if (unmaterialised.length > 0) {
    await eventCall("roster.incomplete", {
      server_members: members.length,
      local_members: localAgents.length,
      missing: unmaterialised,
    });
  }
  const rosterSeqs = await rosterSequencesCall(config, dependencies);
  const prepared = await driverCall("read-prepare", config, [{ type: "sync_read_context",
    min_available_seq: capabilities.min_available_seq, current_seq: capabilities.current_seq,
    members, local_agents: localAgents, roster_seqs: rosterSeqs }]);
  const batches = readStateUpdateBatches(members, prepared);
  const pageLimit = Math.min(limit, 1000);
  let page;
  const blockedThisCycle = new Set();
  for (const updates of batches) {
    let remaining = updates.filter((update) => !blockedThisCycle.has(update.member_id));
    for (;;) {
      try {
        page = await requestCall(config, "/v1/read-state/sync", { method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ updates: remaining, page_after: null, page_limit: pageLimit }) });
        break;
      } catch (error) {
        const reportedMemberId = error?.body?.error?.details?.member_id;
        const memberId = remaining.some((update) => update.member_id === reportedMemberId)
          ? reportedMemberId
          : remaining.find((update) => update.exact_wire_ids.length > 0)?.member_id;
        if (error?.code !== "read-state-limit-exceeded" || !UUID_V7.test(reportedMemberId ?? "") ||
            !members.some((member) => member.member_id === reportedMemberId) ||
            !UUID_V7.test(memberId ?? "") || blockedThisCycle.has(memberId)) {
          throw error;
        }
        blockedThisCycle.add(memberId);
        await driverCall("read-block", config, [{ type: "sync_read_block", member_id: memberId,
          reason: "read-state-limit-exceeded" }]);
        remaining = remaining.filter((update) => update.member_id !== memberId);
        await eventCall("read-state.blocked", { member_id: memberId,
          reported_member_id: reportedMemberId, reason: "read-state-limit-exceeded" });
      }
    }
  }
  let pageAfter = null;
  let pageCount = 0;
  const seenFrontiers = new Set();
  for (;;) {
    if (pageAfter !== null) {
      page = await requestCall(config, "/v1/read-state/sync", { method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ updates: [], page_after: pageAfter, page_limit: pageLimit }) });
    }
    validateReadStatePage(config, page, pageLimit, pageAfter);
    for (const item of page.items) {
      if (item.kind === "frontier" && seenFrontiers.has(item.member_id)) {
        throw new Error("read-state stream repeated a member frontier");
      }
      if (item.kind === "frontier") seenFrontiers.add(item.member_id);
    }
    const records = [{ type: "sync_read_snapshot",
      min_available_seq: page.min_available_seq, current_seq: page.current_seq },
    ...page.items.map((item) => item.kind === "frontier" ?
      { type: "sync_read_frontier", member_id: item.member_id, server_seq: item.server_seq } :
      { type: "sync_read_exact", member_id: item.member_id, wire_id: item.wire_id })];
    const applied = await driverCall("read-apply", config, records);
    pageCount += 1;
    if (pageCount > 65_536 + members.length + 1) {
      throw new Error("read-state pagination exceeded the bounded stream size");
    }
    await eventCall("read-state.applied", { page: pageCount, item_count: page.items.length,
      result: applied[0] ?? null });
    if (!page.has_more) break;
    pageAfter = page.next_page_after;
  }
  if (seenFrontiers.size !== members.length ||
      members.some((member) => !seenFrontiers.has(member.member_id))) {
    throw new Error("read-state stream omitted a member frontier");
  }
}

// How many bytes of message JSON to put in one POST before splitting.
//
// Deliberately well under the server's 2 MiB body limit, because the client
// cannot know that limit: a proxy, a gateway, or a self-hosted deployment may
// impose a smaller one, and the only number we control is our own. Counting
// bytes rather than messages is the point — a thousand small messages and a
// thousand large ones were the same batch before this, and only the second kind
// was ever refused.
const PUSH_BYTE_BUDGET = 512 * 1024;

// The wire size of one message, measured the way the body is built rather than
// estimated from the blob. `+1` covers the comma that joins it to the next.
function wireBytes(candidate) {
  return Buffer.byteLength(
    JSON.stringify({ id: candidate.id, envelope: candidate.envelope }), "utf8") + 1;
}

// Split on the byte budget, never returning an empty group: a single message
// over the budget goes out alone and the server decides. Refusing to send it
// here would be this client inventing a limit the server never stated.
function byBudget(candidates, budget) {
  const groups = [];
  let current = [];
  let size = 0;
  for (const candidate of candidates) {
    const bytes = wireBytes(candidate);
    if (current.length > 0 && size + bytes > budget) {
      groups.push(current);
      current = [];
      size = 0;
    }
    current.push(candidate);
    size += bytes;
  }
  if (current.length > 0) groups.push(current);
  return groups;
}

// POST one group, halving on 413 until the server accepts it or one message is
// left. Overlap is safe: a resent id is a no-op server-side and still returns an
// ack (`disposition: "duplicate"`) carrying its stored position, so a retry that
// repeats already-stored messages neither duplicates rows nor loses acks.
//
// Bounded by construction: each retry halves a group of at least two, so the
// recursion depth is log2(group size) and a single message never splits again.
async function postGroup(config, group, requestCall, eventCall) {
  try {
    return await requestCall(config, "/v1/messages", { method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ messages: group.map(({ id, envelope }) => ({ id, envelope })) }) });
  } catch (error) {
    if (error?.status !== 413) throw error;
    if (group.length === 1) {
      // The end of the line, and it must be said plainly: this row cannot be
      // synced by any batching this client can do, and every later cycle will
      // pick it up and fail here again.
      //
      // Named by `local_id`, which is the id of the row in this machine's own
      // store — that is the thing an operator can look at or remove. `id` is the
      // wire reservation this push minted; it identifies nothing locally, so a
      // failure that quoted only that would say "sync is stuck" without saying
      // on what. The wire id is still reported, for correlating with the
      // server's logs, and the axis because a candidate can be a message or a
      // roster mutation and the two live in different places.
      const candidate = group[0];
      const bytes = wireBytes(candidate) - 1;
      const where = {
        local_id: candidate.local_id ?? null,
        local_position: candidate.local_position ?? null,
        sync_axis: candidate.sync_axis ?? null,
        wire_id: candidate.id,
      };
      // Through errorCode(), like every other reader: the caller may already
      // have parsed it (error.code), and if not, the body still has to be read
      // in both shapes. Reading `body.error.code` directly here would leave the
      // one event this change exists for saying `detail: null` against the
      // hosted edge — the case the whole bridge was added for.
      await eventCall("push.oversized", { ...where, bytes,
        detail: error?.code ?? errorCode(error?.body) });
      const stuck = new Error(
        `${where.sync_axis ?? "message"} ${where.local_id ?? candidate.id} ` +
        `(local_position ${where.local_position ?? "unknown"}, wire ${candidate.id}) ` +
        `is ${bytes} bytes and the server refuses it on its own (413); it cannot be ` +
        "pushed by splitting and will block this team's sync until it is removed or " +
        "the server's limit is raised");
      stuck.status = 413;
      Object.assign(stuck, where);
      throw stuck;
    }
    const middle = Math.ceil(group.length / 2);
    await eventCall("push.split", { count: group.length, halves: [middle, group.length - middle] });
    const first = await postGroup(config, group.slice(0, middle), requestCall, eventCall);
    const second = await carryAcks(first.acks, () =>
      postGroup(config, group.slice(middle), requestCall, eventCall));
    // Concatenated in send order, so the combined acks line up with the
    // candidates the caller passed in — validateAckMapping compares positionally.
    return { ...second, acks: [...first.acks, ...second.acks] };
  }
}

// One POST is atomic; several are not. When a later POST dies — 4xx, 5xx, a
// dropped socket — the rows the earlier ones stored are already committed on
// the server, and the acks proving it are in hand. Throwing them away leaves
// the client with no record of messages the server holds, which is the state
// this whole path exists to avoid. So the error carries them: every layer that
// concatenates acks concatenates them onto the failure too, and the top of the
// push sees one prefix no matter how deep the split recursed.
// Emit a diagnostic on a path that is already failing. Every other eventCall in
// this file is awaited bare, and should be: on the success path an unwritable
// event log is a real fault and failing the cycle is right. Here it is not —
// the cycle has already failed, an error is already on its way up, and letting
// the sink throw would replace that error with one about logging. Nothing is
// swallowed silently: the caller still throws what actually went wrong.
async function note(eventCall, name, payload) {
  try {
    await eventCall(name, payload);
  } catch {
    // Deliberately ignored; see above.
  }
}

async function carryAcks(earned, attempt) {
  try {
    return await attempt();
  } catch (error) {
    if (earned.length > 0 && error && typeof error === "object") {
      error.acks = [...earned, ...(error.acks ?? [])];
    }
    throw error;
  }
}

// Send every candidate, in order, as one or more POSTs.
async function postCandidates(config, candidates, requestCall, eventCall) {
  const groups = byBudget(candidates, PUSH_BYTE_BUDGET);
  if (groups.length > 1) {
    await eventCall("push.batched", { count: candidates.length, batches: groups.length });
  }
  let last;
  const acks = [];
  for (const group of groups) {
    last = await carryAcks(acks, () => postGroup(config, group, requestCall, eventCall));
    acks.push(...last.acks);
  }
  // The last response carries the freshest server state (current_seq, floor);
  // the acks are every group's, in the order they were sent.
  return { ...last, acks };
}

// A single sync cycle: push one page (up to pushLimit) + drain the pull side
// to exhaustion. pushLimit and pullLimit are decoupled — the pull page is
// sized generously so a large pull backlog drains in few round-trips, while
// pushLimit follows the adaptive cadence (see runLoop). Returns
// `{ pushSaturated }`: true when a FULL push page was prepared (more remains
// to push), which is the loop's catch-up signal. Dependency-injectable for
// tests (adaptive-sync-catchup design).
export async function cycle(config, { pushLimit, pullLimit }, dependencies = {}) {
  const healthCall = dependencies.healthCall ?? health;
  const requestCall = dependencies.requestCall ?? request;
  const driverCall = dependencies.driverCall ?? driver;
  const rosterDriverCall = dependencies.rosterDriverCall ??
    (dependencies.driverCall ? async (operation) => operation === "prepare" ?
      [{ type: "roster_sync_state", transport_cursor: "0" }] : [] : rosterDriver);
  const eventCall = dependencies.eventCall ?? event;
  const evaluateCall = dependencies.evaluateCall ?? evaluatePull;
  const logApplyCall = dependencies.logApplyCall ?? logApplyOutcomes;
  const readStateCycleCall = dependencies.readStateCycleCall ?? readStateCycle;
  const activateKeyRotationsCall = dependencies.activateKeyRotationsCall ?? activateKeyRotations;

  const ready = await healthCall(config.server_url, config.remote_team_id);
  if (ready.server_instance_id !== config.server_instance_id) throw new Error("health server instance changed");
  // Read back the team as well. Sending the header without checking the answer
  // would leave a field that exists and that nobody consults; the check is what
  // makes a server that has been re-pointed at another team fail here rather
  // than at the first push.
  if (ready.team_id !== config.remote_team_id) throw new Error("health team changed");
  const capabilities = await requestCall(config, "/v1/capabilities");
  validateCapabilities(config, capabilities);
  await eventCall("capabilities", { team: config.local_team, current_seq: capabilities.current_seq,
    policy_revision: capabilities.policy_revision,
    startup_nonce: process.env.AGMSG_SYNC_START_NONCE || undefined });

  const writeProfile = selectWriteProfile(config, capabilities);
  const prepareInput = [{ type: "sync_prepare", envelope_v: 1,
    cipher: writeProfile.profile, key_id: writeProfile.key_id ?? null,
    recipients: writeProfile.recipients ?? [], max_blob_bytes: Number(capabilities.max_blob_bytes),
    allow_new: writeProfile.eligible }];
  const [prepared, rosterPrepared] = await Promise.all([
    driverCall("prepare", config, prepareInput, [String(pushLimit)]),
    rosterDriverCall("prepare", config, prepareInput, [String(pushLimit)]),
  ]);
  const state = prepared.find((record) => record.type === "sync_state");
  // Registry mutations lead the page. They establish the identity needed to
  // interpret every following message, and UUIDv7 values minted in the same
  // millisecond are not a reliable cross-axis ordering key.
  const rosterCandidates = rosterPrepared
    .filter((record) => record.type === "roster_sync_push_candidate")
    .map((record) => ({ ...record, sync_axis: "roster" }));
  const rotationIndex = rosterCandidates.findIndex((record) =>
    record.projection?.kind === "key_rotated");
  const candidates = (rotationIndex === -1 ? [
    ...rosterCandidates,
    ...prepared.filter((record) => record.type === "sync_push_candidate")
      .map((record) => ({ ...record, sync_axis: "messages" })),
  ] : rosterCandidates.slice(0, rotationIndex + 1)).slice(0, pushLimit);
  if (!state) throw new Error("driver omitted sync_state");
  sequence(state.transport_cursor, "transport_cursor");
  await eventCall("push.prepared", { count: candidates.length, local_positions: candidates.map((item) => item.local_position),
    wire_ids: candidates.map((item) => item.id) });

  if (!writeProfile.eligible) {
    await eventCall("push.blocked", { reason: writeProfile.reason });
  } else if (candidates.length > 0) {
    // Record whatever the server acknowledged, then let the failure through.
    // Both have to reach the caller: the cycle failed, and some of it durably
    // succeeded. Reconciling first means a retry resends only what is actually
    // missing — and the acks arrive as `duplicate` for anything it does resend,
    // which the mapping already accepts.
    // Recording and reporting are separate calls on purpose. Folded together,
    // the caller cannot tell "the prefix was never written" from "the prefix
    // was written and the log was not" — and the failing path acts on exactly
    // that distinction.
    const recordAcks = async (acks) => {
      // Only a front prefix can be reconciled: the acks are in send order, so
      // acks[i] belongs to candidates[i]. Slicing to the acks' own length is
      // what makes the mapping's positional id check an assertion that this
      // really is an unbroken prefix — a gap shows up as an id mismatch.
      const ackRecords = validateAckMapping(candidates.slice(0, acks.length), acks);
      const messageAcks = ackRecords.filter((_, index) => candidates[index].sync_axis === "messages");
      const rosterAcks = ackRecords.filter((_, index) => candidates[index].sync_axis === "roster");
      const [reconciled, rosterReconciled] = await Promise.all([
        messageAcks.length > 0 ? driverCall("reconcile", config, messageAcks) : [],
        rosterAcks.length > 0 ? rosterDriverCall("reconcile", config, rosterAcks) : [],
      ]);
      return { ackRecords, reconciled, rosterReconciled };
    };
    // `emit` is the bare eventCall on the success path and note() on the failing
    // one. Nothing here runs before the write above.
    const reportAcks = async (emit, { ackRecords, reconciled, rosterReconciled }) => {
      await emit("push.ack", { acks: ackRecords.map(({ id, server_seq, disposition }) => ({ id, server_seq, disposition })) });
      await emit("push.reconciled", {
        result: reconciled[0] ?? null,
        roster_result: rosterReconciled[0] ?? null,
      });
    };
    let posted;
    try {
      posted = await postCandidates(config, candidates, requestCall, eventCall);
    } catch (error) {
      const earned = Array.isArray(error?.acks) ? error.acks : [];
      if (earned.length > 0) {
        // The try covers the durable write and nothing else. Widen it by one
        // event and a log failure starts arriving here as a write failure —
        // `push.partial-unrecorded` for a prefix that is on disk, and the next
        // reader resends what must not be resent. The boundary is the write,
        // not the function.
        let written = null;
        let writeFailure = null;
        try {
          written = await recordAcks(earned);
        } catch (failure) {
          writeFailure = failure;
          // Neither the rows nor a note of them. Report it, but keep it under
          // the transport error rather than in front of it — that error is the
          // reason any of this happened.
          if (error && typeof error === "object" && error.cause === undefined) {
            error.cause = failure;
          }
        }
        // Everything below is reporting, on a path that has already failed, so
        // none of it may throw: an unwritable log must not replace the
        // transport error on its way up.
        const emit = (name, payload) => note(eventCall, name, payload);
        await emit("push.partial", { acked: earned.length, of: candidates.length });
        if (written) {
          await reportAcks(emit, written);
        } else {
          await emit("push.partial-unrecorded", { reason: writeFailure.message });
        }
      }
      throw error;
    }
    // The POST is over and every ack is in hand; the durable write has not
    // started. This is the one boundary a reader of the log could not see:
    // push.ack and push.reconciled are both emitted after recordAcks, so
    // between push.prepared and push.ack sat the POST AND the reconcile with
    // nothing to tell them apart (#913). Through note(), never bare: this event
    // sits between the acks and the write that makes them durable, and a log
    // that cannot be written must not cost that write -- the same reason the
    // failing path above reports through note().
    await note(eventCall, "push.posted", { count: posted.acks.length });
    await reportAcks(eventCall, await recordAcks(posted.acks));
  }
  // A full push page (and eligible) means at least a full page was available,
  // so the loop treats it as "more remains" and stays in catch-up. An exactly-
  // full page (remainder 0) costs one extra probe cycle that finds nothing —
  // safe. Not eligible, or a short page, = push is drained.
  const pushSaturated = writeProfile.eligible && candidates.length === pushLimit;

  let cursor = state.transport_cursor;
  let pullCapabilities = capabilities;
  for (;;) {
    // Trap 1: the request param AND this validation must both use pullLimit —
    // fixing only one makes a legitimate full page throw "pull page is invalid".
    const page = await requestCall(config, `/v1/messages?after=${encodeURIComponent(cursor)}&limit=${pullLimit}`);
    sequence(page.next_after, "next_after");
    if (!Array.isArray(page.messages) || page.messages.length > pullLimit || typeof page.has_more !== "boolean") {
      throw new Error("pull page is invalid");
    }
    let expected = BigInt(cursor) + 1n;
    for (const message of page.messages) {
      sequence(message.server_seq, "message server_seq");
      if (BigInt(message.server_seq) !== expected) throw new Error("pull page sequence is not contiguous");
      expected += 1n;
    }
    const expectedNext = page.messages.at(-1)?.server_seq ?? cursor;
    if (page.next_after !== expectedNext || (page.has_more && page.messages.length === 0)) {
      throw new Error("pull page cursor/has_more is inconsistent");
    }
    if (BigInt(page.next_after) > BigInt(pullCapabilities.current_seq)) {
      pullCapabilities = await requestCall(config, "/v1/capabilities");
      validateCapabilities(config, pullCapabilities);
      if (BigInt(page.next_after) > BigInt(pullCapabilities.current_seq)) {
        throw new Error("capability history does not cover the pull page");
      }
    }
    const records = [];
    for (const message of page.messages) {
      const evaluated = await evaluateCall(config, pullCapabilities, message);
      const record = { type: "sync_pull_message", ...message, ...evaluated };
      if (record.status === "importable" && record.projection?.kind === "key_rotated") {
        await rosterDriverCall("apply", config, [record]);
        await activateKeyRotationsCall(config);
      } else {
        records.push(record);
      }
    }
    records.push({ type: "sync_pull_cursor", next_after: page.next_after });
    await eventCall("pull.received", { after: cursor, next_after: page.next_after,
      messages: page.messages.map((message) => ({ id: message.id, server_seq: message.server_seq })) });
    const cursorRecord = records.at(-1);
    const rosterRecords = records.filter((record) =>
      record.type === "sync_pull_message" && record.status === "importable" &&
      ["member_joined", "member_left", "member_renamed"].includes(record.projection?.kind));
    const messageRecords = records.filter((record) =>
      record.type !== "sync_pull_message" || !record.projection?.kind);
    const rosterApplied = rosterRecords.length > 0 ?
      await rosterDriverCall("apply", config, [...rosterRecords, cursorRecord]) : [];
    // The storage cursor is the transport checkpoint. Apply the idempotent
    // roster side first so a registry failure cannot advance past an event it
    // did not durably record; a later storage failure simply replays roster.
    const applied = await driverCall("apply", config, messageRecords);
    await logApplyCall(config, messageRecords, applied);
    await eventCall("pull.applied", {
      result: applied[0] ?? null,
      roster_result: rosterApplied[0] ?? null,
    });
    cursor = page.next_after;
    if (!page.has_more) break;
  }
  await readStateCycleCall(config, pullLimit, dependencies);
  return { pushSaturated };
}

// Adaptive catch-up loop (adaptive-sync-catchup design). Steady state is
// byte-for-byte the old behaviour: push a 100-page, wait `interval`. When a
// push page saturates (a full page prepared → backlog), the loop switches to
// catch-up: push at 1000 with NO inter-cycle wait, until a cycle is no longer
// saturated. The 100-vs-1000 page-size gap is itself the hysteresis band, so
// there is no threshold to flap around. Failure backoff is INDEPENDENT of the
// cadence: after any retryable failure the loop always backs off (exponential,
// capped), so a machine that can't reach the server never hot-loops even while
// catch-up would otherwise skip the wait.
// The installation can be updated while an engine runs (#963). watch.sh
// already detects that and stands down on its own; the engine used to find
// out only by executing a half-written driver script -- and only when its
// timing was unlucky enough to hit the write window (observed live: a
// mid-rewrite storage-sync-driver.sh failed to parse, and the fatal named a
// syntax error instead of the update).
//
// What is proof here went through review twice, and both cuts were the same
// disease: an observable standing in for the fact. "mtime newer than the
// engine's start clock" stands down every engine under a pre-existing
// future mtime (clock skew, an archive with preserved timestamps).
// "mtime changed against a baseline" stands down on a touch, a
// metadata-only correction, a same-content re-copy -- the code in memory
// and on disk still identical, and a stood-down sync engine does not come
// back by itself. The fact that matters is CONTENT: the engine must stand
// down exactly when the bytes on disk are no longer the bytes it started
// from. So the baseline holds a content digest per file; a path or mtime
// difference merely nominates a file for re-reading, and only a digest
// that actually differs -- or a path that did not exist at start, a new
// install artifact -- is proof. A benign mtime change is remembered so the
// file is not re-read every cycle; content is the identity, the mtime is
// only a cheap change hint.
//
// The failure direction is deliberate, in both phases: an OBSERVATION
// failure is not evidence.
//   - Baseline phase: one unreadable directory, one failed stat, one
//     unreadable file and the whole detector is disabled (null), not
//     partially armed. A partial baseline would recreate the false
//     positive: a pre-existing file unreadable at start and readable later
//     would look newly added. Disabled means exactly today's behavior.
//   - Check phase: an entry that cannot be listed, stat'ed, or read is
//     skipped and proves nothing. A rewrite that lands different bytes
//     under the exact baseline mtime defeats the hint and is never
//     re-read -- a miss, and a miss degrades to today's behavior, which
//     is the safe side. A file DELETED by an update is deliberately not
//     proof on its own; a real update always rewrites something.
export async function collectInstallBaseline(rootDir, dependencies = {}) {
  const readdirCall = dependencies.readdirCall ?? readdir;
  const statCall = dependencies.statCall ?? stat;
  const readFileCall = dependencies.readFileCall ?? readFile;
  const baseline = new Map();
  const pending = [rootDir];
  while (pending.length > 0) {
    const dir = pending.pop();
    let entries;
    try { entries = await readdirCall(dir, { withFileTypes: true }); }
    catch { return null; } // incomplete observation: the detector stays OFF
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) { pending.push(path); continue; }
      if (!entry.isFile()) continue; // links and specials are not install artifacts
      let stats, bytes;
      try {
        stats = await statCall(path);
        bytes = await readFileCall(path);
      } catch { return null; } // incomplete observation: the detector stays OFF
      baseline.set(path, {
        mtimeMs: stats.mtimeMs,
        digest: createHash("sha256").update(bytes).digest("hex"),
      });
    }
  }
  return baseline;
}

export async function installChangedAgainst(rootDir, baseline, dependencies = {}) {
  const readdirCall = dependencies.readdirCall ?? readdir;
  const statCall = dependencies.statCall ?? stat;
  const readFileCall = dependencies.readFileCall ?? readFile;
  const pending = [rootDir];
  while (pending.length > 0) {
    const dir = pending.pop();
    let entries;
    try { entries = await readdirCall(dir, { withFileTypes: true }); }
    catch { continue; } // unreadable now: no evidence either way
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) { pending.push(path); continue; }
      if (!entry.isFile()) continue;
      let stats;
      try { stats = await statCall(path); }
      catch { continue; } // vanished or unreadable: no evidence
      const known = baseline.get(path);
      if (known === undefined) return path; // did not exist at start: a new install artifact
      if (stats.mtimeMs === known.mtimeMs) continue; // no hint of change
      let digest;
      try { digest = createHash("sha256").update(await readFileCall(path)).digest("hex"); }
      catch { continue; } // could not re-read: no evidence
      if (digest !== known.digest) return path; // the bytes actually changed
      known.mtimeMs = stats.mtimeMs; // benign touch: remember it, content is the identity
    }
  }
  return null;
}

export async function runLoop(config, options, dependencies = {}) {
  const cycleCall = dependencies.cycleCall ?? cycle;
  const sleepCall = dependencies.sleepCall ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  const eventCall = dependencies.eventCall ?? event;
  const isRetryableCall = dependencies.isRetryableCall ?? isRetryable;
  const recordCycleCall = dependencies.recordCycleCall ?? recordCycleSuccess;
  const clearRefusalCall = dependencies.clearRefusalCall ?? clearRefusal;
  const recordRefusalCall = dependencies.recordRefusalCall ?? recordRefusal;
  const isRefusalCall = dependencies.isRefusalCall ?? isRefusal;
  const nowCall = dependencies.nowCall ?? (() => new Date().toISOString());
  const collectInstallBaselineCall = dependencies.collectInstallBaselineCall ?? collectInstallBaseline;
  const installChangedCall = dependencies.installChangedCall ?? installChangedAgainst;
  const scriptsRoot = dependencies.scriptsRoot ?? resolve(dirname(fileURLToPath(import.meta.url)), "..");

  // An explicit --limit is a ceiling for BOTH push and pull (request size /
  // memory / slow-link timeout); only the default lets the loop go large.
  const ceiling = options.limit !== undefined ? Math.min(1000, options.limit) : null;
  const steadyIntervalMs = (options.interval ?? 5) * 1000;
  const STEADY_PUSH_LIMIT = 100;
  const LARGE_LIMIT = 1000;
  const BASE_BACKOFF_MS = 1000;
  const MAX_BACKOFF_MS = 60000;

  // Taken once, before the loop: the reference the update check diffs
  // against. null means the tree could not be observed COMPLETELY, and an
  // incomplete baseline must disarm the whole detector rather than arm part
  // of it (see collectInstallBaseline).
  let installBaseline = null;
  try { installBaseline = await collectInstallBaselineCall(scriptsRoot); }
  catch { installBaseline = null; } // an observation failure is not evidence (#963)

  let catchUp = false; // start steady; the first cycle reveals any backlog
  let consecutiveFailures = 0;
  for (;;) {
    // Checked at the cycle boundary, BEFORE any driver can be spawned: past
    // this point the loop executes scripts from disk, and executing updated
    // scripts from an engine holding pre-update code is the mixed-version
    // state watch.sh refuses by name (#963). Returning -- not throwing --
    // makes this a stand-down, not a failure: main() finishes and the
    // process exits 0. The pidfile is left for `status` to call stale; its
    // stale line already names `remote.sh sync start <team>`.
    let updatedPath = null;
    if (installBaseline !== null) {
      try { updatedPath = await installChangedCall(scriptsRoot, installBaseline); }
      catch { updatedPath = null; } // an observation failure is not evidence (#963)
    }
    if (updatedPath !== null && updatedPath !== undefined) {
      try {
        await eventCall("stand-down", {
          reason: "install-updated",
          team: config.local_team,
          changed_path: String(updatedPath),
          message: "the agmsg installation was updated while this engine was running, so it is still executing the code from before the update. Standing down rather than appearing to work.",
          restart: `remote.sh sync start ${config.local_team}`,
        });
      } catch { /* logging is best-effort; the stand-down does not depend on it */ }
      return;
    }
    const pushLimit = ceiling ?? (catchUp ? LARGE_LIMIT : STEADY_PUSH_LIMIT);
    const pullLimit = ceiling ?? LARGE_LIMIT;
    try {
      const result = await cycleCall(config, { pushLimit, pullLimit }, dependencies);
      consecutiveFailures = 0;
      // Here, and nowhere earlier: this is the one point at which a cycle is
      // known to have finished rather than to have been attempted.
      //
      // Guarded HERE, not only inside the writer. The writer swallows its own
      // I/O errors, but that is the writer's promise, not this loop's guarantee
      // -- and a promise kept in the callee is one a future callee can break.
      // The loop's rule is that nothing about recording a success may cost the
      // success. Same shape as the `cycle.error` logging below.
      try {
        await recordCycleCall(config.local_team, nowCall());
        // A success outdates any refusal on record. Cleared HERE, beside the
        // stamp, so a reader that never looks at the timestamps still sees the
        // right thing most of the time — but the guarantee is the reader's
        // comparison, not this line, because this line may fail.
        await clearRefusalCall(config.local_team);
      } catch { /* bookkeeping is best-effort; the cycle already succeeded */ }
      catchUp = result?.pushSaturated === true;
      // catch-up removes the wait ONLY between successful, progress-making
      // cycles; steady keeps the interval. --interval never applies in
      // catch-up (a saturated cycle is moving real data, not empty-polling).
      if (!catchUp) await sleepCall(steadyIntervalMs);
    } catch (error) {
      // Best-effort: a logging failure must not abort failure handling or the
      // backoff below (event() can throw when AGMSG_SYNC_LOG_FILE append fails).
      try {
        await eventCall("cycle.error", { message: error.message, ...causeOf(error) });
      } catch { /* logging is best-effort */ }

      // A REFUSAL DOES NOT LEAVE THE LOOP (#773).
      //
      // It is not retryable — asking again does not change a decision — and it
      // is not a transport failure either: the server has answered, and said
      // what it decided. Exiting on it turns a recoverable condition into a
      // dead process whose `status` line recommends starting it again, which
      // reproduces the refusal and the exit.
      //
      // And the answer CAN change, out of band: someone pays, a quota resets,
      // an operator fixes a setting. Staying up means the next cycle recovers
      // with nobody typing anything. So this backs off to the longest interval
      // and keeps asking quietly, and the failure count is not advanced —
      // a refusal is not evidence that the transport is degrading.
      if (isRefusalCall(error)) {
        try {
          await recordRefusalCall(config.local_team, {
            status: error?.status ?? null,
            code: error?.code ?? null,
            at: nowCall(),
            // From the config the engine already holds. Not an interpretation:
            // it says WHERE the operator of that server would be reached.
            endpoint_host: hostOf(config.endpoint),
          });
        } catch { /* best-effort */ }
        try {
          await eventCall("cycle.refused", {
            status: error?.status ?? null, code: error?.code ?? null,
          });
        } catch { /* logging is best-effort */ }
        await sleepCall(MAX_BACKOFF_MS);
        continue;
      }

      if (!isRetryableCall(error)) throw error;
      consecutiveFailures += 1;
      const backoffMs = Math.min(MAX_BACKOFF_MS, BASE_BACKOFF_MS * 2 ** (consecutiveFailures - 1));
      await sleepCall(backoffMs); // always back off after a failure, in either cadence
    }
  }
}

function reprocessCandidateToken(candidate) {
  return `${candidate.server_seq}:${candidate.id}`;
}

function validateReprocessDriverPage(pending, limit, requestedAfter) {
  const recordKeys = (value) => Object.keys(value).sort().join(",");
  const states = pending.filter((record) => record.type === "sync_state");
  const candidates = pending.filter((record) => record.type === "sync_reprocess_candidate");
  const pages = pending.filter((record) => record.type === "sync_reprocess_page");
  if (states.length !== 1 || pages.length !== 1 || candidates.length > limit ||
      pending.length !== states.length + candidates.length + pages.length) {
    throw new Error("driver reprocess page shape is invalid");
  }
  const page = pages[0];
  if (recordKeys(page) !== "has_more,next_after,type" || typeof page.has_more !== "boolean" ||
      (page.has_more ? typeof page.next_after !== "string" : page.next_after !== null) ||
      (page.has_more && candidates.length === 0)) {
    throw new Error("driver reprocess pagination is invalid");
  }
  let previous = requestedAfter;
  for (const candidate of candidates) {
    if (recordKeys(candidate) !==
        "envelope,id,prior_status,server_received_at,server_seq,type" ||
        candidate.type !== "sync_reprocess_candidate" || !UUID_V4.test(candidate.id) ||
        typeof candidate.server_received_at !== "string" ||
        typeof candidate.prior_status !== "string" || !candidate.envelope) {
      throw new Error("driver reprocess candidate is invalid");
    }
    sequence(candidate.server_seq, "reprocess server_seq");
    const token = reprocessCandidateToken(candidate);
    if (previous !== null) {
      const separator = previous.indexOf(":");
      const previousSequence = sequence(previous.slice(0, separator), "reprocess page server_seq");
      const previousId = previous.slice(separator + 1);
      if (separator < 1 || !UUID_V4.test(previousId) ||
          BigInt(candidate.server_seq) < BigInt(previousSequence) ||
          (candidate.server_seq === previousSequence && candidate.id <= previousId)) {
        throw new Error("driver reprocess page did not advance");
      }
    }
    previous = token;
  }
  if (page.has_more && page.next_after !== previous) {
    throw new Error("driver reprocess next page token is inconsistent");
  }
  return { state: states[0], candidates, page };
}

export async function reprocessCycle(config, limit, dependencies = {}) {
  const healthCall = dependencies.healthCall ?? health;
  const requestCall = dependencies.requestCall ?? request;
  const driverCall = dependencies.driverCall ?? driver;
  const evaluateCall = dependencies.evaluateCall ?? evaluatePull;
  const eventCall = dependencies.eventCall ?? event;
  const logApplyCall = dependencies.logApplyCall ?? logApplyOutcomes;
  const rosterDriverCall = dependencies.rosterDriverCall ?? rosterDriver;
  const activateKeyRotationsCall = dependencies.activateKeyRotationsCall ?? activateKeyRotations;
  const ready = await healthCall(config.server_url, config.remote_team_id);
  if (ready.server_instance_id !== config.server_instance_id) throw new Error("health server instance changed");
  // Read back the team as well. Sending the header without checking the answer
  // would leave a field that exists and that nobody consults; the check is what
  // makes a server that has been re-pointed at another team fail here rather
  // than at the first push.
  if (ready.team_id !== config.remote_team_id) throw new Error("health team changed");
  const capabilities = await requestCall(config, "/v1/capabilities");
  validateCapabilities(config, capabilities);
  let after = null;
  let stableState = null;
  let total = 0;
  let imported = 0;
  let pageCount = 0n;
  const retentionFloor = BigInt(capabilities.min_available_seq);
  // Locally retained quarantine may cover both the server-retained suffix and
  // the unavailable prefix, so the authenticated lifetime sequence space is
  // floor + (current-floor), rather than only the current retained window.
  const authenticatedSequenceSpace = retentionFloor +
    (BigInt(capabilities.current_seq) - retentionFloor);
  const seenTokens = new Set();
  const seenSequences = new Set();
  for (;;) {
    pageCount += 1n;
    if (pageCount > authenticatedSequenceSpace + 1n) {
      throw new Error("driver reprocess walk exceeds authenticated sequence space");
    }
    const extra = [String(limit), ...(after === null ? [] : [after])];
    const pending = await driverCall("reprocess", config, [], extra);
    const { state, candidates, page } = validateReprocessDriverPage(pending, limit, after);
    sequence(state.transport_cursor, "transport_cursor");
    if (stableState && (state.transport_cursor !== stableState.transport_cursor ||
        state.driver_generation !== stableState.driver_generation)) {
      throw new Error("driver reprocess state changed between pages");
    }
    stableState ??= state;
    const records = [];
    const storageRecords = [];
    const rotationRecords = [];
    let pendingRosterRecords = [];
    const flushRosterRecords = async (cursorRecord) => {
      if (pendingRosterRecords.length === 0) return;
      await rosterDriverCall("apply", config,
        cursorRecord ? [...pendingRosterRecords, cursorRecord] : pendingRosterRecords);
      pendingRosterRecords = [];
    };
    for (const candidate of candidates) {
      const token = reprocessCandidateToken(candidate);
      if (seenTokens.has(token)) throw new Error("driver reprocess repeated a candidate");
      seenTokens.add(token);
      if (candidate.server_seq === "0") {
        throw new Error("driver reprocess candidate has no canonical server sequence");
      }
      if (seenSequences.has(candidate.server_seq)) {
        throw new Error("driver reprocess mapped one server sequence to multiple wire ids");
      }
      seenSequences.add(candidate.server_seq);
      if (BigInt(seenSequences.size) > authenticatedSequenceSpace) {
        throw new Error("driver reprocess candidate count exceeds authenticated sequence space");
      }
      if (BigInt(candidate.server_seq) > BigInt(capabilities.current_seq)) {
        throw new Error("quarantine sequence exceeds authenticated server state");
      }
      const message = { server_seq: candidate.server_seq, id: candidate.id,
        server_received_at: candidate.server_received_at, envelope: candidate.envelope };
      const evaluated = await evaluateCall(config, capabilities, message);
      const record = { type: "sync_pull_message", ...message, ...evaluated };
      storageRecords.push(record);
      if (record.status === "importable" && record.projection?.kind === "key_rotated") {
        // A rotation changes how every later sequence is interpreted. Flush
        // earlier roster mutations before publishing and activating it; a
        // page may interleave both kinds, and the journal is append-only.
        await flushRosterRecords(null);
        await rosterDriverCall("apply", config, [record]);
        await activateKeyRotationsCall(config);
        rotationRecords.push(record);
      } else {
        records.push(record);
        if (record.status === "importable" &&
            ["member_joined", "member_left", "member_renamed"].includes(
              record.projection?.kind)) {
          pendingRosterRecords.push(record);
        }
      }
    }
    if (candidates.length > 0) {
      const cursorRecord = { type: "sync_pull_cursor", next_after: state.transport_cursor };
      const rosterRecords = records.filter((record) =>
        record.status === "importable" &&
        ["member_joined", "member_left", "member_renamed"].includes(record.projection?.kind));
      const messageRecords = records.filter((record) => !record.projection?.kind);
      if (rosterRecords.length + messageRecords.length + rotationRecords.length !==
          storageRecords.length) {
        throw new Error("reprocess cannot apply this projection kind");
      }
      await flushRosterRecords(cursorRecord);
      const applied = await driverCall("apply", config, [...storageRecords, cursorRecord]);
      const messageIds = new Set(messageRecords.map((record) => record.id));
      await logApplyCall(config, messageRecords, applied.filter((record) =>
        record.type !== "sync_apply_outcome" || messageIds.has(record.id)));
      const candidateIds = new Set(candidates.map((candidate) => candidate.id));
      imported += applied.filter((record) =>
        record.type === "sync_apply_outcome" &&
        candidateIds.has(record.id) &&
        ["imported", "reconciled"].includes(record.status)).length;
      total += candidates.length;
    }
    if (!page.has_more) break;
    if (seenTokens.has(page.next_after) && page.next_after === after) {
      throw new Error("driver reprocess pagination looped");
    }
    after = page.next_after;
  }
  const remaining = validateReprocessDriverPage(
    await driverCall("reprocess", config, [], ["1"]), 1, null);
  const result = {
    count: total,
    imported_count: imported,
    blocking_remaining: remaining.candidates.length > 0,
    transport_cursor: stableState.transport_cursor,
  };
  await eventCall("reprocess.complete", result);
  return result;
}

function resultFromResyncAudit(status) {
  return {
    type: "sync_resync_result",
    driver_generation: status.driver_generation,
    expected_transport_cursor: status.audit.expected_transport_cursor,
    transport_cursor: status.audit.accepted_floor,
    accepted_floor: status.audit.accepted_floor,
    gap_start: status.audit.gap_start,
    gap_end: status.audit.gap_end,
    reason: status.audit.reason,
  };
}

export async function resyncCycle(config, acceptedFloor, dependencies = {}) {
  const driverCall = dependencies.driverCall ?? driver;
  const requestCall = dependencies.requestCall ?? request;
  const eventCall = dependencies.eventCall ?? event;
  const floor = sequence(acceptedFloor, "accepted floor");
  const driverCapabilities = await driverCall("capabilities", config, []);
  if (!stage1ResyncSupported(driverCapabilities)) {
    throw new Error("storage driver does not advertise stage1-resync");
  }
  const capabilities = await requestCall(config, "/v1/capabilities");
  validateCapabilities(config, capabilities);
  const status = validateResyncStatus(
    await driverCall("resync-status", config, [], [floor]), floor);
  const serverFloor = BigInt(capabilities.min_available_seq);
  const serverCurrent = BigInt(capabilities.current_seq);
  if (status.audit !== null) {
    if (BigInt(floor) > serverFloor || BigInt(status.transport_cursor) > serverCurrent) {
      throw new Error("recorded resync audit contradicts authenticated server state");
    }
    const result = resultFromResyncAudit(status);
    validateResyncResult([result], status, floor);
    await eventCall("resync.complete", { disposition: "already-accepted", result });
    return result;
  }
  if (floor !== capabilities.min_available_seq ||
      BigInt(status.transport_cursor) >= BigInt(floor) || BigInt(floor) > serverCurrent) {
    throw new Error("accepted floor does not match the active retention gap");
  }
  let retentionError;
  try {
    await requestCall(config,
      `/v1/messages?after=${encodeURIComponent(status.transport_cursor)}&limit=1`);
  } catch (error) {
    retentionError = error;
  }
  const details = retentionError?.body?.error?.details;
  if (retentionError?.status !== 410 || retentionError?.code !== "resync-required" ||
      retentionError.body?.min_available_seq !== floor ||
      details?.after !== status.transport_cursor || details?.min_available_seq !== floor) {
    throw new Error("server did not reproduce the authenticated retention gap");
  }
  const input = [{
    type: "sync_resync",
    expected_transport_cursor: status.transport_cursor,
    min_available_seq: floor,
    current_seq: capabilities.current_seq,
    reason: "retention-gap-accepted",
  }];
  const result = validateResyncResult(
    await driverCall("resync", config, input), status, floor);
  await eventCall("resync.complete", { disposition: "accepted", result });
  return result;
}

// A machine that has none of this taking a team from the server. It is not a
// cycle: there is no local team to reconcile against, no push side, and no
// credential. What it shares with the normal pull is the part that must not
// diverge -- evaluatePull decides what may be imported, then roster mutations
// and chat records go through the same two drivers as a connected cycle.
/**
 * A line of progress for a command that is otherwise silent for minutes (#882).
 *
 * STDERR, NEVER STDOUT. `cmd_pull` captures this process's stdout as the result
 * channel -- `result="$(... pull-bootstrap ...)"` -- so anything written there
 * is invisible until the command finishes AND rides in the same stream the
 * caller greps for `pull_bootstrap_result`. stderr is not redirected by that
 * caller, so it reaches the operator live and changes no parsing.
 *
 * WHY IT EXISTS: a verifier ran this against a real server, saw nothing for
 * five minutes, concluded it had hung, and killed it. On Linux the same command
 * takes 312 seconds and succeeds. Silence and a stall were indistinguishable,
 * so thirty minutes went into diagnosing a command that was working.
 *
 * The lines separate FETCHING from APPLYING on purpose. Applying spawns a child
 * process per batch; fetching does not. When this stops moving, which line it
 * stopped on says which half to look at -- and on Windows, where the report
 * came from, that is the whole question.
 */
function pullProgress(startedAt, message) {
  // Elapsed, because a terminal does not timestamp its own scrollback. Without
  // it a report of "it printed this and then stopped" cannot say whether the
  // stop was ten seconds or ten minutes -- and on the Linux run that finished,
  // the whole thing took 312 seconds, so a slow phase and a stuck one look the
  // same to whoever is watching.
  const elapsed = Math.round((Date.now() - startedAt) / 1000);
  process.stderr.write(`agmsg: [${elapsed}s] ${message}\n`);
}

export async function pullBootstrap(args, dependencies = {}) {
  const publicSnapshotCall = dependencies.publicSnapshotCall ?? publicSnapshot;
  const requestPublicCall = dependencies.requestPublicCall ?? requestPublic;
  const evaluateCall = dependencies.evaluateCall ?? evaluatePull;
  const driverCall = dependencies.driverCall ?? driver;
  const rosterDriverCall = dependencies.rosterDriverCall ?? rosterDriver;
  const eventCall = dependencies.eventCall ?? event;
  const team = requireName(args.team, "team");
  const teamId = args["team-id"] ?? "";
  if (!UUID_V7.test(teamId)) throw new Error("team-id must be a canonical UUIDv7");
  const serverUrl = args.endpoint ?? "";
  if (!serverUrl) throw new Error("endpoint is required");
  const limit = Number(args.limit ?? 1000);
  if (!Number.isInteger(limit) || limit < 1 || limit > 1000) throw new Error("limit must be 1..1000");

  // There is no connected binding yet, so this one call validates itself
  // rather than going through the checks the rest of the pull relies on.
  const pullStartedAt = Date.now();
  // THE HOST, NEVER THE ENDPOINT. A hosted endpoint is `https://host/t/<token>`
  // and that token IS the capability: anyone who reads it off a terminal, a
  // screen share, or a pasted log can connect as this team. This line is the
  // one people paste -- it exists because someone sat in front of a silent
  // command for 79 minutes and then wrote an issue about it.
  //
  // `hostOf` rather than anything written here: it is `new URL(...).host`, which
  // drops path, query, fragment AND userinfo, and is already the rule this file
  // uses for the refusal record `status` prints. `remote.sh` holds the same rule
  // in shell (`_remote_endpoint_display`), and the reason both drop the path
  // before the userinfo is that an `@` inside a path would otherwise decide
  // where the host ends -- a URL parser gets that right without being told.
  //
  // The team name is what makes host-only enough to name the destination: a
  // team has one endpoint.
  pullProgress(pullStartedAt,
    `pulling ${team} from ${hostOf(serverUrl) ?? "an unreadable endpoint"}` +
    " -- this can take several minutes");
  const teamSnapshot = await publicSnapshotCall(serverUrl, teamId);
  const config = {
    format_version: 1,
    local_team: team,
    server_url: serverUrl,
    server_instance_id: teamSnapshot.server_instance_id,
    remote_team_id: teamSnapshot.team_id,
    protocol_version: Number(PROTOCOL),
    cipher_profile: "none",
    local_security_history: [{
      local_security_revision: "0", effective_from_seq: "1",
      minimum_security_mode: "plaintext-allowed",
    }],
  };
  await eventCall("pull.bootstrap.snapshot", {
    team_id: teamSnapshot.team_id, team_name: teamSnapshot.team_name,
    min_available_seq: teamSnapshot.min_available_seq,
  });

  let cursor = String(teamSnapshot.min_available_seq ?? "0");
  let imported = 0;
  let ageV1Envelopes = 0;
  for (;;) {
    // The cursor is the SERVER's value, and this path does not put it through
    // `sequence()` before using it. A canonical sequence is digits; anything
    // else goes to a terminal as a placeholder rather than as itself, because
    // this line is pasted and control characters travel.
    const shownCursor = /^[0-9]{1,20}$/.test(cursor) ? cursor : "an unreadable cursor";
    pullProgress(pullStartedAt,
      `fetching messages after ${shownCursor} (${imported} pulled so far)`);
    const page = await requestPublicCall(config,
      `/v1/teams/${teamId}/messages?after=${cursor}&limit=${limit}`);
    pullProgress(pullStartedAt, `applying ${page.messages.length} messages`);
    const records = [];
    for (const message of page.messages) {
      if (message.envelope?.cipher === "age-v1") ageV1Envelopes += 1;
      records.push({ type: "sync_pull_message", ...message,
        ...(await evaluateCall(config, teamSnapshot, message)) });
    }
    const cursorRecord = { type: "sync_pull_cursor", next_after: page.next_after };
    const rosterRecords = records.filter((record) =>
      record.status === "importable" &&
      ["member_joined", "member_left", "member_renamed"].includes(record.projection?.kind));
    const messageRecords = records.filter((record) => !record.projection?.kind);
    if (rosterRecords.length + messageRecords.length !== records.length) {
      throw new Error("pull bootstrap cannot apply this projection kind");
    }
    const rosterApplied = rosterRecords.length > 0 ?
      await rosterDriverCall("apply", config, [...rosterRecords, cursorRecord]) : [];
    const applied = await driverCall("apply", config, [...messageRecords, cursorRecord]);
    await eventCall("pull.bootstrap.applied", {
      after: cursor, next_after: page.next_after,
      messages: page.messages.length, result: applied[0] ?? null,
      roster_result: rosterApplied[0] ?? null,
    });
    imported += page.messages.length;
    cursor = page.next_after;
    if (!page.has_more) break;
  }
  const result = {
    type: "pull_bootstrap_result", team: config.local_team,
    team_id: config.remote_team_id, team_name: teamSnapshot.team_name,
    server_instance_id: config.server_instance_id,
    // The binding the second machine records so it keeps syncing (the design's
    // "and continues"): the same capability snapshot connect stores, plus the
    // protocol version. Without it the pulled team has no connected binding and
    // the sync engine refuses to run.
    protocol_version: config.protocol_version,
    capabilities: teamSnapshot,
    imported,
    age_v1_envelopes: ageV1Envelopes,
  };
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return result;
}

// Resolve a team name to the teams carrying it. Like publicSnapshot this runs
// before any config exists, so it validates its own answer rather than going
// through the binding checks the rest of the client relies on.
export async function resolveTeam(args) {
  const serverUrl = args.endpoint ?? "";
  if (!serverUrl) throw new Error("endpoint is required");
  const name = args.name ?? "";
  if (!name) throw new Error("name is required");
  const body = await publicGet(serverUrl,
    `/v1/teams?name=${encodeURIComponent(name)}`);
  // Nothing here is trusted. One candidate's team_id becomes this machine's
  // team identity; several are printed for an operator to read. Both happen
  // before a local team exists, so a bad answer has to stop the command rather
  // than thin out into "no such team" or reach a terminal as raw bytes. The
  // messages below deliberately quote no server value, for the same reason.
  const keysOf = (value) => Object.keys(value).sort().join(",");
  if (body.protocol_version !== 1 || !UUID_V7.test(body.server_instance_id ?? "") ||
      body.team_name !== name || !Array.isArray(body.teams)) {
    throw new Error("team lookup answer is not a lookup result for the requested name");
  }
  if (body.teams.length > MAX_TEAMS_PER_NAME) {
    throw new Error("team lookup returned more candidates than the protocol allows");
  }
  const teams = body.teams.map((candidate) => {
    if (!candidate || typeof candidate !== "object" ||
        keysOf(candidate) !== "current_seq,registered_at,team_id,team_name" ||
        !UUID_V7.test(candidate.team_id ?? "") || candidate.team_name !== name ||
        !TIMESTAMP.test(candidate.registered_at ?? "")) {
      throw new Error("a team lookup candidate is not a valid candidate");
    }
    sequence(candidate.current_seq, "team lookup current_seq");
    // Rebuilt field by field so only what was checked travels onward.
    return {
      team_id: candidate.team_id, team_name: candidate.team_name,
      registered_at: candidate.registered_at, current_seq: candidate.current_seq,
    };
  });
  process.stdout.write(`${JSON.stringify({
    type: "team_lookup_result", team_name: name, teams,
  })}\n`);
}

async function publicGet(serverUrl, path) {
  let response;
  try {
    response = await fetch(endpoint(serverUrl, path), {
      headers: { "Agmsg-Protocol-Version": PROTOCOL },
      redirect: "error", signal: AbortSignal.timeout(15_000),
    });
  } catch (error) {
    error.retryable = true;
    throw error;
  }
  if (response.headers.get("agmsg-protocol-version") !== PROTOCOL) {
    throw new Error("response protocol version mismatch");
  }
  // Parsed from the raw text and the parse failure collapsed to a fixed
  // message, for the same reason the error code below is validated: a
  // malformed JSON body from an untrusted server reaches Node's own
  // SyntaxError.message as a fragment of the actual input, and that would
  // put raw response bytes on the operator's terminal now that this call's
  // stderr is not redirected away. send() below already avoids this shape
  // for the authenticated path; the public one needs the same boundary.
  let text;
  try { text = await response.text(); } catch (error) {
    error.retryable = true;
    throw error;
  }
  let body;
  try { body = JSON.parse(text); } catch {
    throw new Error(`HTTP ${response.status} returned invalid JSON`);
  }
  if (!response.ok) {
    // This message is no longer only for a log: the resolve-team CLI
    // subcommand's stderr now reaches the operator's terminal directly, and
    // this call runs before any local team or credential exists, so the
    // server answering is not trusted. errorCode(body) returns whatever the
    // server put there with no format guarantee -- that is correct for its
    // other callers, but here it would let raw server bytes (control
    // characters, terminal escapes) reach a real terminal. Only a code
    // shaped like this protocol's own (lowercase kebab-case, the same shape
    // as every code this project actually defines) is echoed; anything else
    // collapses to the same fixed word errorCode() itself already falls
    // back to when no code was given at all.
    const code = errorCode(body);
    const safeCode = /^[a-z][a-z0-9-]{0,63}$/.test(code) ? code : "unknown-error";
    const error = new Error(`HTTP ${response.status} ${safeCode}`);
    error.status = response.status;
    throw error;
  }
  return body;
}

async function publicSnapshot(serverUrl, teamId) {
  const body = await publicGet(serverUrl, `/v1/teams/${teamId}`);
  if (body.team_id !== teamId || !UUID_V7.test(body.server_instance_id ?? "")) {
    throw new Error("team snapshot is not bound to the requested team");
  }
  return body;
}

// The same per-team registry lock remote.sh takes around every binding write
// (scripts/lib/registry-lock.sh): mkdir on teams/<team>/.config.lock is the
// primitive, so the two sides of the connection pair -- the shell writing the
// binding, this file writing the stored sync config -- serialize against each
// other, not just against themselves. Spin bounded the same way (~10s).
async function withTeamConfigLock(team, fn) {
  const lockDir = join(dirname(teamConfigPath(team)), ".config.lock");
  for (let attempt = 0; ; attempt += 1) {
    try { await mkdir(lockDir); break; }
    catch (error) {
      if (error?.code !== "EEXIST") throw error;
      // Same exit as the shell side (registry-lock.sh): a holder that died
      // without its release trap (SIGKILL, power loss) leaves the directory,
      // and the way out is bounded failure that NAMES it -- never an
      // unbounded wait. Nothing sweeps stale locks anywhere in this tree;
      // matching the existing contract rather than inventing liveness
      // detection on one side of a shared primitive.
      if (attempt >= 1000) {
        throw new Error(`timed out acquiring the team registry lock at ${lockDir}; ` +
          "if no agmsg command is running against this team, remove that directory and re-run");
      }
      await new Promise((resolveSleep) => setTimeout(resolveSleep, 10));
    }
  }
  try {
    return await fn();
  } finally {
    await rmdir(lockDir).catch(() => {});
  }
}

// Align the stored sync configuration's server_url with the binding's endpoint
// after remote.sh has moved it. Only the ADDRESS moves: the identity triple
// (server_instance_id, remote_team_id, protocol_version) must match between the
// stored config and the binding, or this is not the same connection and nothing
// is written. The new address is then verified end-to-end -- request() checks
// the protocol header and validateBinding compares the response's identity
// against this config -- before the config is replaced. Without this step, an
// endpoint change would strand any team with a stored sync config: loadConfig
// refuses a config whose server_url differs from the binding, and configure
// refuses to replace an existing binding at all.
//
// One invariant covers both halves of the pair: EITHER file is written only
// under the team registry lock, and only against a binding_revision the writer
// verified. Binding writes (remote.sh) advance the revision under that lock;
// this write requires it unchanged, re-read under the same lock. Without the
// re-check, two concurrent set-endpoints interleave so that the slower
// alignment -- verified against a binding that has since moved again -- lands
// its stale config over the faster one's completed pair (#739 review). The
// network verification stays OUTSIDE the lock: holding a spin lock across a
// 15s-timeout request would starve every concurrent lifecycle command.
export async function setEndpoint(args) {
  const team = requireName(args.team, "team");
  const binding = await readConnectedBinding(team);
  let value;
  try {
    value = await readStoredSyncConfig(team);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    // Plain teams may have no stored sync config: loadConfig synthesizes one
    // from the binding on every start, so the moved endpoint is already the
    // one the engine will use. Nothing to write.
    await event("endpoint.aligned", { team, stored_config: false });
    return;
  }
  if (value.local_team !== team ||
      value.server_instance_id !== binding.server_instance_id ||
      value.remote_team_id !== binding.remote_team_id ||
      value.protocol_version !== binding.protocol_version) {
    throw new Error("stored sync configuration does not belong to this team's binding");
  }
  if (value.server_url === binding.endpoint) {
    await event("endpoint.aligned", { team, stored_config: true, changed: false });
    return;
  }
  const candidate = { ...value, server_url: binding.endpoint };
  const capabilities = await request(candidate, "/v1/capabilities");
  validateCapabilities(candidate, capabilities);
  await withTeamConfigLock(team, async () => {
    const current = await readConnectedBinding(team);
    if (current.endpoint !== binding.endpoint ||
        current.binding_revision !== binding.binding_revision) {
      throw new Error(
        "the team's binding moved while this alignment was verifying; nothing was written -- the newer set-endpoint owns the stored configuration now");
    }
    await writeConfig(configPath(team), candidate);
  });
  await event("endpoint.aligned", { team, stored_config: true, changed: true });
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const args = options(rest);
  if (!["configure", "export-age-snapshot", "verify-age-snapshot", "export-age-handoff",
        "verify-age-handoff", "once", "run", "reprocess", "resync",
        "unblock-read", "pull-bootstrap", "resolve-team", "set-endpoint"].includes(command)) {
    throw new Error(usage());
  }
  if (command === "configure") { await configure(args); return; }
  if (command === "export-age-snapshot") { await exportAgeSnapshot(args); return; }
  if (command === "verify-age-snapshot") { await verifyAgeSnapshot(args); return; }
  if (command === "export-age-handoff") { await exportAgeHandoff(args); return; }
  if (command === "verify-age-handoff") { await verifyAgeHandoff(args); return; }
  // Before any local team exists, so neither can go through loadConfig.
  if (command === "resolve-team") { await resolveTeam(args); return; }
  if (command === "pull-bootstrap") { await pullBootstrap(args); return; }
  // Before loadConfig: mid-change, the stored config's server_url still names
  // the old address, and loadConfig refuses exactly that mismatch.
  if (command === "set-endpoint") { await setEndpoint(args); return; }
  const team = requireName(args.team, "team");
  const limit = Number(args.limit ?? 100);
  if (!Number.isInteger(limit) || limit < 1 || limit > 1000) throw new Error("limit must be 1..1000");
  const config = await loadConfig(team);
  if (command === "unblock-read") {
    if (!UUID_V7.test(args["member-id"] ?? "")) throw new Error("member-id must be a canonical UUIDv7");
    const result = await driver("read-unblock", config, [{
      type: "sync_read_unblock", member_id: args["member-id"],
    }]);
    await event("read-state.unblocked", { member_id: args["member-id"], result: result[0] ?? null });
    return;
  }
  if (command === "resync") {
    await resyncCycle(config, args["accept-floor"] ?? "");
    return;
  }
  if (command === "reprocess") { await reprocessCycle(config, limit); return; }
  // An explicit --limit caps both push and pull; the default lets pull go large.
  const explicitCeiling = args.limit !== undefined ? Math.min(1000, limit) : null;
  if (command === "once") {
    await cycle(config, { pushLimit: explicitCeiling ?? 100, pullLimit: explicitCeiling ?? 1000 });
    return;
  }
  const interval = Number(args.interval ?? 5);
  if (!Number.isFinite(interval) || interval < 0.2) throw new Error("interval must be at least 0.2 seconds");
  await runLoop(config, {
    limit: args.limit !== undefined ? limit : undefined,
    interval: args.interval !== undefined ? interval : undefined,
  });
}

// realpath on both sides: on macOS a temp dir is /var/... symlinked to
// /private/var/..., and import.meta.url resolves the link while argv[1] does
// not. Compared as strings the guard silently fails to match, so the process
// runs main() never, exits 0, and prints nothing -- a no-op that looks like a
// success. Anything invoked through a symlinked path hits this.
if (process.argv[1] &&
    realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])) {
  main().catch(async (error) => {
    await event("fatal", { message: error.message, code: error.code ?? null });
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
