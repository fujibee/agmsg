// Claude Code native-channel I/O: writes one line to a seat's own
// cross-session-messaging socket (https://code.claude.com/docs/en/cross-session-messaging)
// and verifies delivery by reading the seat's own transcript file. Measured
// 2026-10-05, memory/design/2026-10-05-cross-session-messaging-socket-measurement.md
// (and its addendum) and memory/design/2026-09-22-agmsgd-arch-8-delivery-driver.md
// §12/§12.1 — this file's shape follows directly from those measurements, not
// from the (partly inaccurate, per the same memo) public docs alone.
//
// This file knows only the Claude Code peer-socket wire format and transcript
// layout; the daemon loop and its install.db schema remain owned by the caller
// (claude-code-queue.mjs), matching codex-queue-io.mjs's split.

import { createHash, randomUUID } from "node:crypto";
import { createConnection } from "node:net";
import { closeSync, fstatSync, lstatSync, openSync, readSync, readdirSync } from "node:fs";
import process from "node:process";
import { StringDecoder } from "node:string_decoder";
import { isAbsolute } from "node:path";
import { setImmediate as yieldToLoop } from "node:timers/promises";

export { newNonce, inboxNudge } from "./codex-queue-io.mjs";

const SEND_TIMEOUT_MS = 5_000;
// Read fixed chunks; retain only bounded string summaries, never whole JSONL rows.
const TRANSCRIPT_CHUNK_BYTES = 64 * 1024;
const MAX_OBSERVATIONS = 256;

// Measured 2026-10-05: Claude Code encodes a project's cwd into its
// transcript directory name by replacing every "/" with "-"
// (e.g. /home/user/projects/example/sub -> -home-user-projects-example-sub).
// Only this simple case was measured; a cwd containing a literal "-" was not
// tested separately and is not known to collide in practice, so this is not
// claimed exhaustive.
export function encodeClaudeProjectDir(cwd) {
  if (typeof cwd !== "string" || !cwd) return "";
  return cwd.replace(/\//g, "-");
}

export function resolveTranscriptPath(claudeConfigDir, project, sessionId) {
  if (typeof claudeConfigDir !== "string" || !isAbsolute(claudeConfigDir)) return "";
  if (typeof project !== "string" || !isAbsolute(project)) return "";
  if (typeof sessionId !== "string" || !sessionId) return "";
  const encoded = encodeClaudeProjectDir(project);
  if (!encoded) return "";
  const expected = `${claudeConfigDir}/projects/${encoded}/${sessionId}.jsonl`;
  if (isFile(expected)) return expected;
  // The seat's conversation can live under another project directory than the
  // one its record names (it was started elsewhere). A session id is unique, so
  // exactly one match under the config dir is that conversation; none or
  // several keeps the expected path and the caller's own "missing" answer.
  if (!/^[A-Za-z0-9._-]+$/.test(sessionId) || sessionId.startsWith(".")) return expected;
  let dirs;
  try {
    dirs = readdirSync(`${claudeConfigDir}/projects`, { withFileTypes: true });
  } catch {
    return expected;
  }
  const found = [];
  for (const entry of dirs) {
    if (!entry.isDirectory()) continue;
    const candidate = `${claudeConfigDir}/projects/${entry.name}/${sessionId}.jsonl`;
    if (isFile(candidate)) found.push(candidate);
  }
  return found.length === 1 ? found[0] : expected;
}

function isFile(path) {
  try {
    return lstatSync(path).isFile();
  } catch {
    return false;
  }
}

// Refuses to write unless the path is a Unix domain socket owned by this
// process's own OS user: a socket path read from an untrusted or stale
// record must never be written to on trust alone. A symlinked path is
// refused the same way every other agmsg state-file reader on this codebase
// refuses one.
export function checkSocketOwnership(socketPath) {
  let stat;
  try {
    stat = lstatSync(socketPath);
  } catch (error) {
    if (error?.code === "ENOENT") return { state: "unreadable", reason: "messaging_socket_missing" };
    return { state: "unreadable", reason: "messaging_socket_stat_failed" };
  }
  if (stat.isSymbolicLink()) return { state: "unreadable", reason: "messaging_socket_symlink" };
  if (!stat.isSocket()) return { state: "unreadable", reason: "messaging_socket_not_a_socket" };
  if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
    return { state: "unreadable", reason: "messaging_socket_not_owned_by_self" };
  }
  return { state: "ok" };
}

// Sends the one-line JSON cross-session-message the socket accepts (measured
// shape). `from` is a fixed, non-socket string on purpose: it must not look
// like a reply address, since this is a one-way nudge, not a peer
// conversation.
export async function sendClaudeCodeMessage({
  socketPath,
  nonce,
  body,
  timeoutMs = SEND_TIMEOUT_MS,
  checkOwnership = checkSocketOwnership,
  connect = createConnection,
}) {
  const ownership = checkOwnership(socketPath);
  if (ownership.state !== "ok") return { state: "failed", reason: ownership.reason };

  const payload = {
    msgV: 1,
    msg_id: randomUUID(),
    type: "user",
    message: {
      role: "user",
      content: `<cross-session-message from="agmsgd" from-name="agmsgd" from-mode="bypass">\n${body}\n</cross-session-message>`,
    },
    priority: "next",
    from: "agmsgd",
  };
  const line = `${JSON.stringify(payload)}\n`;

  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { socket.destroy(); } catch { /* best effort */ }
      resolve(result);
    };
    const timer = setTimeout(() => finish({ state: "failed", reason: "send_timeout" }), timeoutMs);
    let socket;
    try {
      socket = connect(socketPath);
    } catch {
      clearTimeout(timer);
      resolve({ state: "failed", reason: "connect_failed" });
      return;
    }
    socket.on("error", (error) => finish({ state: "failed", reason: `socket_error:${error.code ?? error.message}` }));
    socket.on("connect", () => {
      socket.end(line, () => finish({ state: "sent", nonce, msgId: payload.msg_id }));
    });
  });
}

// Delivery evidence is unchanged: user/origin.body or a mid-turn
// queued_command attachment/prompt containing the nonce confirms delivery.
// Informational system/content means held. queue-operation/enqueue is mere
// receipt and never confirms a nudge (measured 2026-10-05 / 2026-10-15).
// Streaming JSON recognizer for the few string fields used as evidence. Other
// strings (including arbitrarily large tool results) retain only a marker-sized
// suffix. No complete row is buffered. Nesting beyond the guard is rejected,
// like malformed JSON, rather than allowing an untrusted row to grow memory.
function transcriptRow(marker) {
  const stack = [];
  const fields = {};
  let invalid = false, done = false, token = null;
  const fail = () => { invalid = true; };
  function valueSlot() {
    const frame = stack.at(-1);
    if (!frame) return done ? null : { scope: "root", key: "" };
    if (frame.kind === "object" && frame.state === "value") return { scope: frame.scope, key: frame.key };
    if (frame.kind === "array" && (frame.state === "value" || frame.state === "first")) return { scope: "other", key: "" };
    return null;
  }
  function finishValue() {
    const frame = stack.at(-1);
    if (frame) frame.state = "comma";
    else done = true;
  }
  function clearSlot(slot) {
    if (slot.scope === "root" && (slot.key === "origin" || slot.key === "attachment")) {
      for (const key of Object.keys(fields)) if (key.startsWith(`${slot.key}.`)) delete fields[key];
    }
    delete fields[`${slot.scope}.${slot.key}`];
  }
  function finishString() {
    const frame = stack.at(-1);
    if (token.key) { frame.key = token.short; frame.state = "colon"; }
    else {
      const name = `${token.slot.scope}.${token.slot.key}`;
      if (["root.type", "root.subtype", "root.content", "origin.body", "attachment.type", "attachment.prompt"].includes(name)) {
        fields[name] = { value: token.short, marker: token.match };
      }
      finishValue();
    }
    token = null;
  }
  function stringChar(char) {
    if (token.short !== null) token.short = token.short.length < 32 ? token.short + char : null;
    token.tail = (token.tail + char).slice(-marker.length);
    if (token.tail === marker) token.match = true;
  }
  const transitions = {
    sign: [[/[0]/, "zero"], [/[1-9]/, "int"]],
    zero: [[/[.]/, "dot"], [/[eE]/, "exp"]],
    int: [[/[0-9]/, "int"], [/[.]/, "dot"], [/[eE]/, "exp"]],
    dot: [[/[0-9]/, "frac"]], frac: [[/[0-9]/, "frac"], [/[eE]/, "exp"]],
    exp: [[/[+-]/, "expSign"], [/[0-9]/, "expInt"]],
    expSign: [[/[0-9]/, "expInt"]], expInt: [[/[0-9]/, "expInt"]],
  };
  function feed(char) {
    if (invalid) return;
    if (token?.kind === "string") {
      if (token.unicode !== null) {
        if (!/[0-9a-fA-F]/.test(char)) return fail();
        token.unicode += char;
        if (token.unicode.length === 4) { stringChar(String.fromCharCode(parseInt(token.unicode, 16))); token.unicode = null; }
      } else if (token.escape) {
        token.escape = false;
        if (char === "u") token.unicode = "";
        else if ('"\\/bfnrt'.includes(char)) stringChar(({ b: "\b", f: "\f", n: "\n", r: "\r", t: "\t" })[char] ?? char);
        else fail();
      } else if (char === "\\") token.escape = true;
      else if (char === '"') finishString();
      else if (char.charCodeAt(0) < 32) fail();
      else stringChar(char);
      return;
    }
    if (token?.kind === "literal") {
      if (token.index < token.expected.length) {
        if (char !== token.expected[token.index++]) fail();
        return;
      }
      token = null;
      finishValue();
      return feed(char);
    }
    if (token?.kind === "number") {
      const next = transitions[token.state].find(([pattern]) => pattern.test(char));
      if (next) { token.state = next[1]; return; }
      if (!["zero", "int", "frac", "expInt"].includes(token.state)) return fail();
      token = null;
      finishValue();
      return feed(char);
    }
    if (/^[ \t\r]$/.test(char)) return;
    const frame = stack.at(-1);
    if (char === '"' && frame?.kind === "object" && ["first", "key"].includes(frame.state)) {
      token = { kind: "string", key: true, short: "", tail: "", match: false, escape: false, unicode: null };
      return;
    }
    if (char === ":" && frame?.kind === "object" && frame.state === "colon") { frame.state = "value"; return; }
    if (char === "," && frame?.state === "comma") { frame.state = frame.kind === "object" ? "key" : "value"; return; }
    if ((char === "}" && frame?.kind === "object" || char === "]" && frame?.kind === "array") && ["first", "comma"].includes(frame.state)) {
      stack.pop(); finishValue(); return;
    }
    const slot = valueSlot();
    if (!slot) return fail();
    clearSlot(slot);
    if (char === "{" || char === "[") {
      if (stack.length >= 128) return fail();
      const scope = !stack.length && char === "{" ? "root" : slot.scope === "root" && ["origin", "attachment"].includes(slot.key) && char === "{" ? slot.key : "other";
      stack.push({ kind: char === "{" ? "object" : "array", scope, state: "first", key: "" });
    } else if (char === '"') token = { kind: "string", key: false, slot, short: "", tail: "", match: false, escape: false, unicode: null };
    else if ("tfn".includes(char)) token = { kind: "literal", expected: { t: "true", f: "false", n: "null" }[char], index: 1 };
    else if (char === "-" || /[0-9]/.test(char)) token = { kind: "number", state: char === "-" ? "sign" : char === "0" ? "zero" : "int" };
    else fail();
  }
  return {
    feed,
    finish() {
      feed(" ");
      if (invalid || !done || stack.length || token) return "absent";
      const value = (key) => fields[key]?.value;
      const match = (key) => fields[key]?.marker;
      if (value("root.type") === "user" && match("origin.body")) return "delivered";
      if (value("root.type") === "attachment" && value("attachment.type") === "queued_command" && match("attachment.prompt")) return "delivered";
      if (value("root.type") === "system" && value("root.subtype") === "informational" && match("root.content")) return "held";
      return "absent";
    },
  };
}

// One observer belongs to one channel lifetime. The LRU cap bounds abandoned
// entries; an evicted pending notice recovers by scanning its file once again.
export function createTranscriptObserver({
  maxEntries = MAX_OBSERVATIONS,
  read = readSync,
  cooperative = false,
  schedule = (signal) => yieldToLoop(undefined, { signal }),
} = {}) {
  const entries = new Map();
  function key(path, nonce) { return JSON.stringify([path, nonce]); }
  function put(path, nonce, entry) {
    const id = key(path, nonce);
    entries.delete(id);
    entries.set(id, entry);
    while (entries.size > Math.max(1, maxEntries)) entries.delete(entries.keys().next().value);
    return entry;
  }
  function fresh(stat, nonce, offset = 0) {
    return { dev: stat.dev, ino: stat.ino, offset, skipRemainder: false, state: "absent" };
  }
  function open(path) {
    const stat = lstatSync(path, { bigint: true });
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("not_regular_file");
    const fd = openSync(path, "r");
    try {
      const version = fstatSync(fd, { bigint: true });
      if (!version.isFile() || version.dev !== stat.dev || version.ino !== stat.ino) throw new Error("transcript_replaced");
      return { fd, stat: { dev: version.dev, ino: version.ino, size: Number(version.size) }, version };
    } catch (error) {
      closeSync(fd);
      throw error;
    }
  }
  function changed() {
    throw Object.assign(new Error("transcript_changed_during_read"), { code: "TRANSCRIPT_CHANGED" });
  }
  // Append-only growth is normal while a seat is working. It must preserve
  // checkpoints; replacement, shrink, or a same-size rewrite invalidates them.
  function assertAppendCompatible(fd, path, before) {
    const after = fstatSync(fd, { bigint: true });
    const current = lstatSync(path, { bigint: true });
    const compatible = (older, newer) => newer.isFile() && older.dev === newer.dev && older.ino === newer.ino
      && newer.size >= older.size && (newer.size > older.size || (older.mtimeNs === newer.mtimeNs && older.ctimeNs === newer.ctimeNs));
    if (!compatible(before, after) || !compatible(after, current)) changed();
    return current;
  }
  function checkCancelled(signal) {
    if (signal?.aborted) throw Object.assign(new Error("transcript_observation_cancelled"), { code: "OBSERVATION_CANCELLED" });
  }
  function* verifyRow(fd, path, version, start, end, expected, signal) {
    const before = assertAppendCompatible(fd, path, version);
    const hash = createHash("sha256");
    const buffer = Buffer.alloc(TRANSCRIPT_CHUNK_BYTES);
    let offset = start;
    while (offset < end) {
      checkCancelled(signal);
      const count = read(fd, buffer, 0, Math.min(buffer.length, end - offset), offset);
      if (!count) changed();
      hash.update(buffer.subarray(0, count));
      offset += count;
      yield;
      checkCancelled(signal);
    }
    // Confirm exact candidate bytes, including its terminator and starting
    // boundary. Unrelated appends may continue throughout this bounded reread.
    if (hash.digest("hex") !== expected || !atRowBoundary(fd, start)) changed();
    assertAppendCompatible(fd, path, before);
  }
  function atRowBoundary(fd, offset) {
    if (!offset) return true;
    const byte = Buffer.alloc(1);
    if (read(fd, byte, 0, 1, offset - 1) !== 1) throw new Error("transcript_boundary_unreadable");
    return byte[0] === 10;
  }
  function* scan(path, nonce, { signal } = {}) {
    if (typeof nonce !== "string" || !nonce) return { state: "unreadable", reason: "nonce_missing" };
    let fd;
    let finished = false;
    try {
      checkCancelled(signal);
      const opened = open(path);
      fd = opened.fd;
      const stat = opened.stat;
      let entry = entries.get(key(path, nonce));
      // Compare against the previous observation, not only this call's open:
      // a rewrite completed between polls may preserve both size and newline.
      const versionChanged = entry?.version && (opened.version.size < entry.version.size
        || (opened.version.size === entry.version.size
          && (opened.version.mtimeNs !== entry.version.mtimeNs || opened.version.ctimeNs !== entry.version.ctimeNs)));
      if (!entry || entry.dev !== stat.dev || entry.ino !== stat.ino || stat.size < entry.offset || versionChanged) entry = fresh(stat, nonce);
      // A checkpoint is useful only while it is still a JSONL boundary. A
      // same-inode rewrite may keep/grow the size while moving that boundary.
      if (entry.offset && !entry.skipRemainder) {
        if (!atRowBoundary(fd, entry.offset)) entry = fresh(stat, nonce);
        // Keep this one-byte guard separate from the next full chunk's budget.
        yield;
        checkCancelled(signal);
      }
      put(path, nonce, entry);
      // Growth keeps progress; delivery additionally verifies its exact row
      // bytes so short reads cannot splice evidence across a growing rewrite.
      const finish = () => {
        checkCancelled(signal);
        entry.version = assertAppendCompatible(fd, path, opened.version);
        finished = true;
        return { state: entry.state };
      };
      if (entry.state === "delivered") return finish();
      const buffer = Buffer.alloc(TRANSCRIPT_CHUNK_BYTES);
      let offset = entry.offset;
      let decoder = new StringDecoder("utf8");
      let row = transcriptRow(`[agmsg:${nonce}]`);
      let rowStart = offset;
      let rowHash = createHash("sha256");
      while (offset < stat.size) {
        checkCancelled(signal);
        const count = read(fd, buffer, 0, Math.min(buffer.length, stat.size - offset), offset);
        if (!count) break;
        let start = 0;
        while (start < count) {
          const newline = buffer.indexOf(10, start);
          const end = newline >= 0 && newline < count ? newline : count;
          rowHash.update(buffer.subarray(start, end === count ? end : end + 1));
          if (!entry.skipRemainder) {
            for (const char of decoder.write(buffer.subarray(start, end))) row.feed(char);
          }
          if (end === count) break;
          // Retain only complete-row checkpoints across observations. Reparse
          // an unfinished row next time so a rewrite cannot splice old JSON
          // parser state together with unrelated new bytes into evidence.
          if (!entry.skipRemainder) for (const char of decoder.end()) row.feed(char);
          const outcome = entry.skipRemainder ? "absent" : row.finish();
          entry.offset = offset + end + 1;
          entry.skipRemainder = false;
          decoder = new StringDecoder("utf8");
          row = transcriptRow(`[agmsg:${nonce}]`);
          if (outcome === "delivered") {
            // The candidate may have consumed the current chunk's budget;
            // yield before beginning its independently chunked proof reread.
            yield;
            yield* verifyRow(fd, path, opened.version, rowStart, entry.offset, rowHash.digest("hex"), signal);
            entry.state = outcome;
            return finish();
          }
          if (outcome === "held") entry.state = outcome;
          rowStart = entry.offset;
          rowHash = createHash("sha256");
          start = end + 1;
        }
        offset += count;
        yield;
        checkCancelled(signal);
      }
      return finish();
    } catch (error) {
      entries.delete(key(path, nonce));
      return { state: "unreadable", reason: signal?.aborted || error?.code === "OBSERVATION_CANCELLED" ? "transcript_observation_cancelled" : error?.code === "ENOENT" ? "transcript_missing" : error?.code === "TRANSCRIPT_CHANGED" ? "transcript_changed_during_read" : "transcript_read_failed" };
    } finally {
      if (!finished) entries.delete(key(path, nonce));
      if (fd !== undefined) closeSync(fd);
    }
  }
  // Both APIs drive exactly the same parser/checkpoint/row-proof generator.
  // Only the daemon's cooperative driver awaits between bounded work units.
  const observe = cooperative ? async (path, nonce, options = {}) => {
    const iterator = scan(path, nonce, options);
    try {
      for (;;) {
        const step = iterator.next();
        if (step.done) return step.value;
        try { await schedule(options.signal); }
        catch (error) { return iterator.throw(error).value; }
      }
    } finally { iterator.return(); }
  } : (path, nonce, options) => {
    const iterator = scan(path, nonce, options);
    try {
      for (;;) {
        const step = iterator.next();
        if (step.done) return step.value;
      }
    } finally { iterator.return(); }
  };
  // Called once, immediately before a new send. Missing files intentionally
  // leave no watermark, so the first successful observation recovers from zero.
  observe.begin = (path, nonce) => {
    let fd;
    try {
      const opened = open(path);
      fd = opened.fd;
      const entry = fresh(opened.stat, nonce, opened.stat.size);
      // EOF may be inside a row written before this notice. Its appended
      // suffix must never be considered a standalone delivery record.
      entry.skipRemainder = !atRowBoundary(fd, entry.offset);
      entry.version = assertAppendCompatible(fd, path, opened.version);
      put(path, nonce, entry);
    } catch { entries.delete(key(path, nonce)); }
    finally { if (fd !== undefined) closeSync(fd); }
  };
  observe.forget = (path, nonce) => entries.delete(key(path, nonce));
  observe.clear = () => entries.clear();
  return observe;
}

export function createAsyncTranscriptObserver(options = {}) {
  return createTranscriptObserver({ ...options, cooperative: true });
}

// Standalone callers recover the existing file; daemon channels retain their
// own incremental observer between polls rather than sharing global state.
export function observeTranscript(transcriptPath, nonce) {
  return createTranscriptObserver()(transcriptPath, nonce);
}

// Reads one transcript observation as a delivery state. There is deliberately
// no clock here: a nudge the seat has not shown yet is "pending" for as long as
// the same session and socket stay alive, however long that is. Claude Code
// holds a message received mid-work until the work pauses, so elapsed time says
// nothing about whether it was lost, and a wall clock jumps across a sleep.
// Only the caller's own evidence (socket gone, record changed) ends a pending
// nudge, and that is not decided here.
export function resolvePendingDelivery({ observation }) {
  if (observation?.state === "delivered") return { state: "confirmed", reason: "nonce_observed" };
  if (observation?.state === "unreadable") return { state: "pending", reason: observation.reason ?? "transcript_unreadable" };
  return { state: "pending", reason: observation?.state === "held" ? "peer_held" : "awaiting_confirmation" };
}
