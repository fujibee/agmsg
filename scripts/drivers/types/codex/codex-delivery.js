"use strict";

const { spawnSync } = require("child_process");
const crypto = require("crypto");
const path = require("path");

const CONTROL_TIMEOUT_MS = 10000;
const TTL_SECONDS = 60;
const RENEW_INTERVAL_MS = 20000;
const CLAIM_MAX_BYTES = 1048576;
const CLAIM_LIMIT = 32;
const PROMPT_MAX_BYTES = 2097152;

function validText(value) {
  return typeof value === "string" && !value.includes("\0");
}

// All machine data travels on stdin. The script names and capability program
// are fixed; neither a message nor an identity becomes shell source or argv.
class DeliveryClient {
  constructor(scriptsDir, bash, cwd) {
    this.scriptsDir = scriptsDir;
    this.bash = bash;
    this.cwd = cwd;
    this.owner = `codex-bridge:${process.pid}:${crypto.randomBytes(16).toString("hex")}`;
    this.supported = null;
    this.bytesSupported = null;
    this.oversized = false;
  }

  run(args, input) {
    return spawnSync(this.bash, args, {
      cwd: this.cwd, encoding: "utf8", input,
      timeout: CONTROL_TIMEOUT_MS, killSignal: "SIGKILL", maxBuffer: 64 * 1024 * 1024,
    });
  }

  capability() {
    if (this.supported !== null) return this.supported;
    const result = this.run(["-c", 'source "$1/lib/storage.sh"; source "$1/lib/delivery-claims.sh"; agmsg_storage_load || exit 13; agmsg_delivery_claims_supported', "_", this.scriptsDir]);
    if (result.error || (result.status !== 0 && result.status !== 1)) {
      throw new Error("delivery capability check failed");
    }
    this.supported = result.status === 0;
    return this.supported;
  }

  requireBytesCapability() {
    if (this.bytesSupported === null) {
      const result = this.run(["-c", 'source "$1/lib/storage.sh"; source "$1/lib/delivery-claims.sh"; agmsg_storage_load || exit 13; agmsg_delivery_claims_bytes_supported', "_", this.scriptsDir]);
      if (result.error || (result.status !== 0 && result.status !== 1)) throw new Error("bounded delivery capability check failed");
      this.bytesSupported = result.status === 0;
    }
    if (!this.bytesSupported) throw new Error("inline claims require delivery-claims-bytes-v1 support");
  }

  operation(operation, request) {
    const result = this.run([path.join(this.scriptsDir, "delivery-claims.sh"), operation], JSON.stringify(request));
    if (result.error || result.status !== 0) {
      // stderr can contain SQL/data supplied by a corrupt store. Keep routine
      // diagnostics bounded and do not copy bodies or claim tokens into logs.
      throw new Error(`delivery ${operation} failed${result.error ? ` (${result.error.code || "runtime error"})` : ` (exit ${result.status})`}`);
    }
    return result.stdout || "";
  }

  claim(pair) {
    this.requireBytesCapability();
    this.oversized = false;
    const output = this.operation("claim", { team: pair.team, agent: pair.name, owner: this.owner, ttl: TTL_SECONDS, limit: CLAIM_LIMIT, max_bytes: CLAIM_MAX_BYTES });
    let records;
    try {
      if (Buffer.byteLength(output) > CLAIM_MAX_BYTES) throw new Error("size");
      if (!output) return null;
      if (!output.endsWith("\n")) throw new Error("framing");
      records = output.slice(0, -1).split("\n").map((line) => JSON.parse(line));
      const terminal = records[records.length - 1];
      const oversized = terminal && terminal.type === "delivery_oversized";
      if (oversized) {
        if (Object.keys(terminal).length !== 1) throw new Error("status");
        records.pop();
      }
      if (records.length > CLAIM_LIMIT) throw new Error("limit");
      const ids = new Set();
      const token = records[0]?.claim_token;
      if (records.length && !/^[0-9a-f]{64}$/.test(token)) throw new Error("token");
      for (const record of records) {
        if (!record || record.type !== "message_sent" || !validText(record.id) || !record.id || ids.has(record.id) ||
            record.team !== pair.team || record.to !== pair.name || !validText(record.from) ||
            !validText(record.body) || !validText(record.at) || record.claim_token !== token ||
            !Number.isSafeInteger(record.claim_expires_at) || record.claim_expires_at <= 0) throw new Error("record");
        ids.add(record.id);
      }
      this.oversized = !!oversized;
    } catch (_) {
      // An ambiguous response may conceal a committed lease. Never guess a
      // partial set/token to release it; the undisclosed lease must expire.
      throw new Error("malformed delivery claim response; unread lease retained until expiry");
    }
    return records.length ? new DeliveryBatch(this, pair, records) : null;
  }
}

class DeliveryBatch {
  constructor(client, pair, records) {
    this.client = client;
    this.pair = pair;
    this.records = records;
    this.request = { team: pair.team, agent: pair.name, owner: client.owner,
      token: records[0].claim_token, ids: records.map((record) => record.id) };
    this.state = "NOT_SENT";
    this.failed = false;
    this.timer = null;
  }

  text() {
    const body = this.records.map((record) => `  [${record.at}] ${record.from}: ${record.body.replace(/\n/g, "\\n").replace(/\t/g, "\\t")}`);
    return `${body.length} new message(s):\n\n${body.join("\n")}\n`;
  }

  control(operation) {
    const request = operation === "renew" ? { ...this.request, ttl: TTL_SECONDS } : this.request;
    if (this.client.operation(operation, request) !== "ok\n") throw new Error(`malformed delivery ${operation} response`);
  }

  renew() {
    if (this.failed) throw new Error("delivery lease renewal previously failed");
    try { this.control("renew"); }
    catch (error) { this.failed = true; throw error; }
  }

  attempted() { this.state = "UNKNOWN"; }

  // Synchronous, bounded child calls serialize timer, ACK and shutdown work on
  // the JS event loop. There is no outstanding renewal promise to drain. A
  // control timeout is UNKNOWN: never ACK/release after an ambiguous renewal.
  waitFor(response, intervalMs = RENEW_INTERVAL_MS) {
    const failed = new Promise((_, reject) => {
      this.timer = setInterval(() => {
        try { this.renew(); }
        catch (error) { this.stopRenewing(); reject(error); }
      }, intervalMs);
      this.timer.unref?.();
    });
    return Promise.race([response, failed]);
  }

  stopRenewing() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  release(rejectedBeforeExecution = false) {
    this.stopRenewing();
    if (this.state !== "NOT_SENT" && (this.failed || !rejectedBeforeExecution)) return;
    this.control("release");
    this.state = "RELEASED";
  }

  ack() {
    this.stopRenewing();
    this.renew(); // fresh fence immediately before the accepted-turn receipt
    try { this.control("ack"); }
    catch (_) { this.control("ack"); } // exact token retry; a read marker alone is never success
    this.state = "ACKED";
  }
}

function acceptedTurn(result, observedId, conflictingStart = false) {
  const turn = result && result.turn;
  return !!(turn && validText(turn.id) && turn.id && Array.isArray(turn.items) &&
    ["inProgress", "completed", "interrupted", "failed"].includes(turn.status) &&
    !conflictingStart && (!observedId || observedId === turn.id));
}

module.exports = { DeliveryClient, DeliveryBatch, acceptedTurn, CONTROL_TIMEOUT_MS, CLAIM_MAX_BYTES, PROMPT_MAX_BYTES };
