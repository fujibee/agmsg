#!/usr/bin/env node

import { closeSync, fstatSync, fsyncSync, ftruncateSync, openSync, readFileSync,
  writeSync } from "node:fs";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import process from "node:process";
import { parseStrictJsonl } from "./strict-jsonl.mjs";
import { sealEnvelope } from "./sync-cipher.mjs";

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const UUID_V7 = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const SEQUENCE = /^(?:0|[1-9][0-9]*)$/u;
const MAX_SEQUENCE = 9_223_372_036_854_775_807n;

function fail(message, code = 13) {
  const error = new Error(message);
  error.exitCode = code;
  throw error;
}

function sequence(value, label) {
  if (typeof value !== "string" || !SEQUENCE.test(value) || BigInt(value) > MAX_SEQUENCE) {
    fail(`${label} is invalid`);
  }
  return value;
}

function binding(localTeam, serverInstanceId, remoteTeamId, protocolVersion) {
  if (!localTeam || !UUID_V7.test(serverInstanceId) || !UUID_V7.test(remoteTeamId) ||
      protocolVersion !== 1) fail("sync binding is invalid");
  return { local_team: localTeam, server_instance_id: serverInstanceId,
    remote_team_id: remoteTeamId, protocol_version: protocolVersion };
}

function sameBinding(record, target) {
  return record?.binding?.local_team === target.local_team &&
    record.binding.server_instance_id === target.server_instance_id &&
    record.binding.remote_team_id === target.remote_team_id &&
    record.binding.protocol_version === target.protocol_version;
}

function readRecords(path) {
  const bytes = readFileSync(path);
  const records = [];
  let start = 0;
  while (start < bytes.length) {
    const newline = bytes.indexOf(0x0a, start);
    if (newline === -1) fail("JSONL log ends with an incomplete record");
    if (newline > start) {
      let value;
      try {
        const line = new TextDecoder("utf-8", { fatal: true })
          .decode(bytes.subarray(start, newline + 1));
        const parsed = parseStrictJsonl(line);
        if (parsed.length !== 1) fail("JSONL log contains an invalid record");
        [value] = parsed;
      }
      catch { fail("JSONL log contains an invalid record"); }
      records.push({ value, start, end: newline + 1 });
    }
    start = newline + 1;
  }
  return records;
}

function appendRecord(path, value) {
  const bytes = Buffer.from(`${JSON.stringify(value)}\n`, "utf8");
  const fd = openSync(path, "a+", 0o600);
  const oldSize = fstatSync(fd).size;
  try {
    let written;
    const injectedPartial = Number(process.env.AGMSG_SYNC_TEST_PARTIAL_APPEND_BYTES ?? "0");
    if (Number.isInteger(injectedPartial) && injectedPartial > 0) {
      written = writeSync(fd, bytes, 0, Math.min(injectedPartial, bytes.length));
      fail("injected JSONL partial append", 75);
    }
    written = writeSync(fd, bytes, 0, bytes.length);
    if (written !== bytes.length) fail("JSONL append was not one complete write");
    fsyncSync(fd);
  } catch (error) {
    try {
      ftruncateSync(fd, oldSize);
      fsyncSync(fd);
    } catch (rollbackError) {
      rollbackError.cause = error;
      throw rollbackError;
    }
    throw error;
  } finally {
    closeSync(fd);
  }
}

function uuid7() {
  const bytes = randomBytes(16);
  const millis = BigInt(Date.now()) & ((1n << 48n) - 1n);
  for (let index = 0; index < 6; index += 1) {
    bytes[index] = Number((millis >> BigInt((5 - index) * 8)) & 0xffn);
  }
  bytes[6] = 0x70 | (bytes[6] & 0x0f);
  bytes[8] = 0x80 | (bytes[8] & 0x3f);
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function canonicalCreatedAt(value) {
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/u.test(value) ?
    `${value.slice(0, -1)}.000000Z` : value;
}

function envelopeEqual(left, right) {
  return left?.v === right?.v && left?.cipher === right?.cipher &&
    left?.key_id === right?.key_id && left?.blob === right?.blob;
}

function localPayloadDigest(message) {
  const hash = createHash("sha256");
  for (const value of [message.local_id, message.from_agent, message.to_agent,
    message.body, canonicalCreatedAt(message.at)]) {
    const bytes = Buffer.from(value, "utf8");
    const length = Buffer.allocUnsafe(4);
    length.writeUInt32BE(bytes.length);
    hash.update(length); hash.update(bytes);
  }
  return hash.digest("hex");
}

function storedGeneration(records) {
  let generation = null;
  for (const { value } of records) {
    const candidate = value.type === "sync_generation" ? value.generation : value.driver_generation;
    if (candidate !== undefined) {
      if (!UUID_V4.test(candidate) && !UUID_V7.test(candidate)) {
        fail("JSONL sync generation is invalid");
      }
      generation = candidate;
    }
  }
  return generation;
}

function currentGeneration(records) {
  return storedGeneration(records) ?? randomUUID();
}

function fold(records, target) {
  const reservationsByLocalId = new Map();
  const reservationsByWire = new Map();
  const reservationPositionsByWire = new Map();
  const acknowledgements = new Map();
  const quarantineByWire = new Map();
  const wireBySequence = new Map();
  const conflictsByLocalId = new Map();
  const conflictsByWire = new Map();
  let transportCursor = "0";
  const applyConflicts = (conflicts) => {
    if (!Array.isArray(conflicts)) fail("JSONL conflict list is invalid");
    for (const conflict of conflicts) {
      if (conflict?.kind === "local_payload_conflict" &&
          conflict.status === "corrupt_state" &&
          typeof conflict.local_id === "string" &&
          /^[0-9a-f]{64}$/u.test(conflict.expected_digest) &&
          /^[0-9a-f]{64}$/u.test(conflict.observed_digest) &&
          conflict.expected_digest !== conflict.observed_digest) {
        conflictsByLocalId.set(conflict.local_id, conflict);
      } else if (conflict?.kind === "ack_sequence_conflict" &&
          conflict.status === "corrupt_state" && UUID_V4.test(conflict.id)) {
        sequence(conflict.expected_server_seq, "conflict expected_server_seq");
        sequence(conflict.observed_server_seq, "conflict observed_server_seq");
        if (conflict.expected_server_seq === conflict.observed_server_seq) {
          fail("JSONL acknowledgement conflict is not conflicting");
        }
        conflictsByWire.set(conflict.id, conflict);
      } else if (conflict?.kind === "ack_wire_conflict" &&
          conflict.status === "corrupt_state" &&
          UUID_V4.test(conflict.id) && UUID_V4.test(conflict.expected_id) &&
          conflict.id !== conflict.expected_id) {
        sequence(conflict.server_seq, "conflict server_seq");
        conflictsByWire.set(conflict.id, conflict);
      } else {
        fail("JSONL conflict is invalid");
      }
    }
  };
  for (const { value } of records) {
    if (!sameBinding(value, target)) continue;
    if (value.type === "sync_prepare_commit") {
      if (!Array.isArray(value.reservations) ||
          (value.conflicts !== undefined && !Array.isArray(value.conflicts))) {
        fail("JSONL reservation commit is invalid");
      }
      applyConflicts(value.conflicts ?? []);
      for (const reservation of value.reservations ?? []) {
        if (!UUID_V4.test(reservation.id) || typeof reservation.local_id !== "string" ||
            (reservation.payload_digest !== undefined &&
              !/^[0-9a-f]{64}$/u.test(reservation.payload_digest)) ||
            !reservation.envelope || typeof reservation.driver_generation !== "string") {
          fail("JSONL reservation is invalid");
        }
        sequence(reservation.local_position, "reservation local_position");
        const priorLocal = reservationsByLocalId.get(reservation.local_id);
        const priorWire = reservationsByWire.get(reservation.id);
        if ((priorLocal && (priorLocal.id !== reservation.id ||
              (priorLocal.payload_digest !== undefined &&
                reservation.payload_digest !== undefined &&
                priorLocal.payload_digest !== reservation.payload_digest) ||
              !envelopeEqual(priorLocal.envelope, reservation.envelope))) ||
            (priorWire && (priorWire.local_id !== reservation.local_id ||
              !envelopeEqual(priorWire.envelope, reservation.envelope)))) {
          fail("JSONL reservation identity conflicts with prior state");
        }
        reservationsByLocalId.set(reservation.local_id, reservation);
        reservationsByWire.set(reservation.id, reservation);
        const positions = reservationPositionsByWire.get(reservation.id) ?? new Set();
        positions.add(reservation.local_position);
        reservationPositionsByWire.set(reservation.id, positions);
      }
    } else if (value.type === "sync_conflict_commit") {
      if (!Array.isArray(value.conflicts) || value.conflicts.length < 1) {
        fail("JSONL conflict commit is invalid");
      }
      applyConflicts(value.conflicts);
    } else if (value.type === "sync_reconcile_commit") {
      if (!Array.isArray(value.acks) ||
          (value.conflicts !== undefined && !Array.isArray(value.conflicts))) {
        fail("JSONL acknowledgement commit is invalid");
      }
      sequence(value.push_cursor, "stored push_cursor");
      for (const ack of value.acks) {
        sequence(ack.server_seq, "stored acknowledgement server_seq");
        sequence(ack.local_position, "stored acknowledgement local_position");
        const reservation = reservationsByWire.get(ack.id);
        const prior = acknowledgements.get(ack.id);
        const sequenceWire = wireBySequence.get(ack.server_seq);
        if (!reservation || !reservationPositionsByWire.get(ack.id)?.has(ack.local_position) ||
            (prior && prior.server_seq !== ack.server_seq) ||
            (sequenceWire && sequenceWire !== ack.id)) {
          fail("JSONL acknowledgement conflicts with prior state");
        }
        acknowledgements.set(ack.id, ack);
        wireBySequence.set(ack.server_seq, ack.id);
      }
      applyConflicts(value.conflicts ?? []);
    } else if (value.type === "sync_pull_commit") {
      sequence(value.transport_cursor, "stored transport_cursor");
      if (BigInt(value.transport_cursor) < BigInt(transportCursor) || !Array.isArray(value.messages)) {
        fail("JSONL pull commit is invalid");
      }
      for (const message of value.messages ?? []) {
        sequence(message.server_seq, "stored pull server_seq");
        if (!UUID_V4.test(message.id) || !message.envelope ||
            !["imported", "reconciled", "corrupt_state", "unsupported_cipher", "pending_key",
              "authentication_failed", "malformed", "policy_violation"].includes(message.status)) {
          fail("JSONL pull outcome is invalid");
        }
        const prior = quarantineByWire.get(message.id);
        const priorSequenceWire = wireBySequence.get(message.server_seq);
        const immutableConflict = (priorSequenceWire && priorSequenceWire !== message.id) ||
          (prior && (prior.server_seq !== message.server_seq ||
            !envelopeEqual(prior.envelope, message.envelope)));
        if (immutableConflict && message.status !== "corrupt_state") {
          fail("JSONL pull outcome hides an immutable conflict");
        }
        quarantineByWire.set(message.id, {
          ...prior, ...message, local_event: message.local_event ?? prior?.local_event ?? null,
        });
        if (!wireBySequence.has(message.server_seq)) {
          wireBySequence.set(message.server_seq, message.id);
        }
        const reservation = reservationsByWire.get(message.id);
        if (message.status === "reconciled" && reservation) {
          const priorAck = acknowledgements.get(message.id);
          if (priorAck && priorAck.server_seq !== message.server_seq) {
            fail("JSONL pull echo conflicts with its acknowledgement");
          }
          acknowledgements.set(message.id, { type: "sync_push_ack", id: message.id,
            local_position: reservation.local_position, server_seq: message.server_seq,
            disposition: "duplicate" });
        }
      }
      transportCursor = value.transport_cursor;
    }
  }
  return { reservationsByLocalId, reservationsByWire, acknowledgements,
    reservationPositionsByWire, quarantineByWire, wireBySequence, transportCursor,
    conflictsByLocalId, conflictsByWire };
}

function localMessages(records, localTeam) {
  return records.filter(({ value }) => value.type === "message_sent" && value.team === localTeam)
    .map(({ value, end }) => ({ local_position: String(end), local_id: value.id,
      body: value.body, at: value.at, from_agent: value.from, to_agent: value.to }));
}

function pushCursor(messages, state) {
  let cursor = "0";
  for (const message of messages) {
    if (state.conflictsByLocalId.has(message.local_id)) break;
    const reservation = state.reservationsByLocalId.get(message.local_id);
    if (!reservation || !state.acknowledgements.has(reservation.id)) break;
    cursor = message.local_position;
  }
  return cursor;
}

function validatePrepare(records) {
  if (records.length !== 1) fail("prepare requires exactly one record");
  const input = records[0];
  const keys = Object.keys(input).sort().join(",");
  if (keys !== "allow_new,cipher,envelope_v,key_id,max_blob_bytes,recipients,type" ||
      input.type !== "sync_prepare" || input.envelope_v !== 1 ||
      !["none", "age-v1"].includes(input.cipher) || typeof input.allow_new !== "boolean" ||
      !Number.isInteger(input.max_blob_bytes) || input.max_blob_bytes < 1 ||
      !Array.isArray(input.recipients)) fail("sync_prepare record is invalid");
  if ((input.cipher === "none" && (input.key_id !== null || input.recipients.length !== 0)) ||
      (input.cipher === "age-v1" && (typeof input.key_id !== "string" ||
        input.recipients.length < 1 || input.recipients.length > 256))) {
    fail("sync_prepare cipher selection is invalid");
  }
  return input;
}

function prepare(path, target, limit, inputText) {
  const input = validatePrepare(parseStrictJsonl(inputText));
  let records = readRecords(path);
  const generationWasMissing = storedGeneration(records) === null;
  const generation = currentGeneration(records);
  const state = fold(records, target);
  const messages = localMessages(records, target.local_team);
  const pending = [];
  const newReservations = [];
  const newConflicts = [];
  const observedDigests = new Map();
  for (const message of messages) {
    const digest = localPayloadDigest(message);
    const priorDigest = observedDigests.get(message.local_id) ??
      state.reservationsByLocalId.get(message.local_id)?.payload_digest;
    if (priorDigest && priorDigest !== digest &&
        !state.conflictsByLocalId.has(message.local_id) &&
        !newConflicts.some((conflict) => conflict.local_id === message.local_id)) {
      newConflicts.push({ kind: "local_payload_conflict", status: "corrupt_state",
        reason: "one local message id has different immutable payloads", local_id: message.local_id,
        expected_digest: priorDigest, observed_digest: digest });
    }
    if (!observedDigests.has(message.local_id)) observedDigests.set(message.local_id, digest);
  }
  const newlyConflictedIds = new Set(newConflicts.map((conflict) => conflict.local_id));
  for (const message of messages) {
    if (pending.length >= limit) break;
    if (state.conflictsByLocalId.has(message.local_id) || newlyConflictedIds.has(message.local_id)) {
      continue;
    }
    const payloadDigest = localPayloadDigest(message);
    const existing = state.reservationsByLocalId.get(message.local_id);
    if (existing && !state.acknowledgements.has(existing.id)) {
      const rebound = { ...existing, driver_generation: generation,
        local_position: message.local_position, payload_digest: payloadDigest };
      pending.push(rebound);
      if (existing.driver_generation !== generation ||
          existing.local_position !== message.local_position) newReservations.push(rebound);
      continue;
    }
    if (existing || !input.allow_new) continue;
    const wireId = randomUUID();
    const envelope = sealEnvelope({ type: "sync_seal", envelope_v: 1,
      cipher: input.cipher, key_id: input.key_id, recipients: input.recipients,
      max_blob_bytes: input.max_blob_bytes, wire_id: wireId,
      team_id: target.remote_team_id, protocol_version: target.protocol_version,
      projection: { body: message.body, created_at: canonicalCreatedAt(message.at),
        from_agent: message.from_agent, to_agent: message.to_agent } });
    if (process.env.AGMSG_SYNC_TEST_ABORT_AFTER_SEAL === "1") fail("aborted after seal", 75);
    const reservation = { driver_generation: generation,
      local_position: message.local_position, local_id: message.local_id,
      payload_digest: payloadDigest, id: wireId, envelope };
    pending.push(reservation); newReservations.push(reservation);
  }
  if (generationWasMissing || newReservations.length > 0 || newConflicts.length > 0) {
    appendRecord(path, { type: "sync_prepare_commit", binding: target,
      driver_generation: generation, reservations: newReservations, conflicts: newConflicts,
      committed_at: new Date().toISOString() });
  }
  process.stdout.write(`${JSON.stringify({ type: "sync_state", driver_generation: generation,
    transport_cursor: state.transportCursor })}\n`);
  for (const reservation of pending) {
    process.stdout.write(`${JSON.stringify({ type: "sync_push_candidate",
      local_position: reservation.local_position, local_id: reservation.local_id,
      id: reservation.id, envelope: reservation.envelope })}\n`);
  }
}

function reconcile(path, target, inputText) {
  const acks = parseStrictJsonl(inputText);
  if (acks.length < 1 || acks.length > 1000) fail("reconcile requires 1..1000 acknowledgements");
  const seenPositions = new Set();
  const seenWires = new Set();
  const seenSequences = new Set();
  let previousSequence = -1n;
  for (const ack of acks) {
    if (!ack || Object.keys(ack).sort().join(",") !==
        "disposition,id,local_position,server_seq,type" || ack.type !== "sync_push_ack" ||
        !UUID_V4.test(ack.id) || !["stored", "duplicate"].includes(ack.disposition)) {
      fail("sync_push_ack is invalid");
    }
    sequence(ack.local_position, "ack local_position");
    sequence(ack.server_seq, "ack server_seq");
    if (seenPositions.has(ack.local_position) || seenWires.has(ack.id) ||
        seenSequences.has(ack.server_seq) || BigInt(ack.server_seq) <= previousSequence) {
      fail("ack mapping is not unique and ordered");
    }
    seenPositions.add(ack.local_position); seenWires.add(ack.id);
    seenSequences.add(ack.server_seq); previousSequence = BigInt(ack.server_seq);
  }
  const records = readRecords(path);
  const generation = currentGeneration(records);
  const state = fold(records, target);
  const messages = localMessages(records, target.local_team);
  const accepted = [];
  const conflicts = [];
  for (const ack of acks) {
    const reservation = state.reservationsByWire.get(ack.id);
    if (!reservation || !state.reservationPositionsByWire.get(ack.id)?.has(ack.local_position)) {
      fail("ack does not match a durable reservation");
    }
    const prior = state.acknowledgements.get(ack.id);
    const sequenceWire = state.wireBySequence.get(ack.server_seq);
    if (state.conflictsByWire.has(ack.id)) {
      continue;
    }
    if (prior && prior.server_seq !== ack.server_seq) {
      conflicts.push({ kind: "ack_sequence_conflict", status: "corrupt_state",
        reason: "one wire id has different immutable server sequences", id: ack.id,
        expected_server_seq: prior.server_seq,
        observed_server_seq: ack.server_seq });
      continue;
    }
    if (sequenceWire && sequenceWire !== ack.id) {
      conflicts.push({ kind: "ack_wire_conflict", status: "corrupt_state",
        reason: "one server sequence maps to different wire ids", id: ack.id,
        expected_id: sequenceWire, server_seq: ack.server_seq });
      continue;
    }
    accepted.push(ack);
  }
  for (const ack of accepted) state.acknowledgements.set(ack.id, ack);
  for (const conflict of conflicts) state.conflictsByWire.set(conflict.id, conflict);
  if (accepted.length > 0 || conflicts.length > 0) appendRecord(path, {
    type: "sync_reconcile_commit", binding: target, driver_generation: generation,
    acks: accepted, conflicts, push_cursor: pushCursor(messages, state),
    committed_at: new Date().toISOString() });
  process.stdout.write(`${JSON.stringify({ type: "sync_reconcile_result",
    push_cursor: pushCursor(messages, state) })}\n`);
}

function validatePull(records) {
  if (records.length < 1 || records.at(-1)?.type !== "sync_pull_cursor") {
    fail("pull page must end with a cursor");
  }
  const cursor = records.at(-1);
  sequence(cursor.next_after, "pull cursor");
  const messages = records.slice(0, -1);
  let previous = -1n;
  for (const message of messages) {
    if (message?.type !== "sync_pull_message" || !UUID_V4.test(message.id) ||
        !message.envelope || !["importable", "unsupported_cipher", "pending_key",
          "authentication_failed", "malformed", "policy_violation"].includes(message.status)) {
      fail("sync_pull_message is invalid");
    }
    sequence(message.server_seq, "pull server_seq");
    if (BigInt(message.server_seq) <= previous) fail("pull messages are not ordered");
    previous = BigInt(message.server_seq);
    if (message.status === "importable") {
      const rosterKind = ["member_joined", "member_left", "member_renamed", "key_rotated"]
        .includes(message.projection?.kind);
      const chatProjection = message.projection && message.projection.kind === undefined &&
        typeof message.projection.body === "string" &&
        typeof message.projection.from_agent === "string" &&
        typeof message.projection.to_agent === "string" &&
        typeof message.projection.created_at === "string";
      if (!rosterKind && !chatProjection) fail("importable pull message has no supported projection");
    }
  }
  return { messages, cursor: cursor.next_after };
}

function apply(path, target, inputText) {
  const input = validatePull(parseStrictJsonl(inputText));
  const records = readRecords(path);
  const generation = currentGeneration(records);
  const state = fold(records, target);
  if (BigInt(input.cursor) < BigInt(state.transportCursor)) {
    fail("pull cursor cannot move backwards");
  }
  const replay = input.messages.length > 0 && input.cursor === state.transportCursor;
  // A storage driver must not assume its page is contiguous, and must not
  // assume the cursor equals its own last row. Roster mutations consume the
  // same team_seq space as messages, but the engine routes them to the roster
  // driver and never hands them here, so from this side the sequence has holes
  // and the page may end on a row we never saw. Contiguity is checked where the
  // whole page is still visible — remote-sync.mjs `pull page sequence is not
  // contiguous`. Assert only what survives the split: ordering (validatePull)
  // and a cursor that covers every row we were given. For the same reason a
  // page can be empty here and still advance: two machines that connect and
  // sync before anyone speaks exchange roster rows only, and this driver is
  // handed the cursor alone. Only "cannot move backwards" survives.
  if (!replay) {
    const last = input.messages.at(-1);
    if (last && BigInt(input.cursor) < BigInt(last.server_seq)) {
      fail("pull cursor does not cover the page");
    }
  } else if (input.messages.some((message) =>
    BigInt(message.server_seq) > BigInt(state.transportCursor))) {
    fail("pull replay exceeds the durable cursor");
  }
  const committed = [];
  for (const source of input.messages) {
    const prior = state.quarantineByWire.get(source.id);
    if (replay && !prior) fail("pull replay has no durable prior outcome");
    const reservation = state.reservationsByWire.get(source.id);
    const acknowledgement = state.acknowledgements.get(source.id);
    const sequenceWire = state.wireBySequence.get(source.server_seq);
    let status = source.status;
    let reason = source.reason ?? "";
    let localEvent = null;
    if ((sequenceWire && sequenceWire !== source.id) ||
        (acknowledgement && acknowledgement.server_seq !== source.server_seq) ||
        (prior && (prior.server_seq !== source.server_seq ||
          !envelopeEqual(prior.envelope, source.envelope))) ||
        (reservation && !envelopeEqual(reservation.envelope, source.envelope))) {
      status = "corrupt_state"; reason = "wire, sequence, or envelope mapping conflict";
    } else if (["imported", "reconciled", "corrupt_state"].includes(prior?.status)) {
      status = prior.status; reason = prior.reason ?? reason;
    } else if (reservation && status === "importable") {
      status = "reconciled";
    } else if (!reservation && status === "importable") {
      if (source.projection.kind === undefined) {
        localEvent = prior?.local_event ?? { type: "message_sent", id: uuid7(), team: target.local_team,
          from: source.projection.from_agent, to: source.projection.to_agent,
          body: source.projection.body, at: source.projection.created_at };
      }
      status = "imported";
    }
    const storedLocalEvent = prior?.local_event ? null : localEvent;
    const message = { ...source, status, reason, local_event: storedLocalEvent };
    committed.push(message);
    state.quarantineByWire.set(source.id, { ...message,
      local_event: localEvent ?? prior?.local_event ?? null });
    if (!state.wireBySequence.has(source.server_seq)) {
      state.wireBySequence.set(source.server_seq, source.id);
    }
  }
  appendRecord(path, { type: "sync_pull_commit", binding: target,
    driver_generation: generation, messages: committed,
    transport_cursor: input.cursor, committed_at: new Date().toISOString() });
  const corruptCount = [...state.quarantineByWire.values()]
    .filter((message) => message.status === "corrupt_state").length;
  process.stdout.write(`${JSON.stringify({ type: "sync_apply_result",
    transport_cursor: input.cursor, corrupt_count: corruptCount })}\n`);
  for (const message of committed) {
    process.stdout.write(`${JSON.stringify({ type: "sync_apply_outcome", id: message.id,
      server_seq: message.server_seq, status: message.status })}\n`);
  }
}

function reprocessToken(message) {
  return `${message.server_seq}:${message.id}`;
}

function parseReprocessToken(value) {
  if (value === undefined || value === "") return null;
  const separator = value.indexOf(":");
  if (separator < 1) fail("reprocess page token is invalid");
  const serverSeq = sequence(value.slice(0, separator), "reprocess page server_seq");
  const id = value.slice(separator + 1);
  if (!UUID_V4.test(id)) fail("reprocess page wire id is invalid");
  return { server_seq: serverSeq, id };
}

function afterReprocessToken(message, after) {
  if (!after) return true;
  const sequenceOrder = BigInt(message.server_seq) - BigInt(after.server_seq);
  return sequenceOrder > 0n || (sequenceOrder === 0n && message.id > after.id);
}

function reprocess(path, target, limit, afterText) {
  const after = parseReprocessToken(afterText);
  let records = readRecords(path);
  let generation = storedGeneration(records);
  if (!generation) {
    generation = randomUUID();
    appendRecord(path, { type: "sync_prepare_commit", binding: target,
      driver_generation: generation, reservations: [], conflicts: [],
      committed_at: new Date().toISOString() });
    records = readRecords(path);
  }
  const state = fold(records, target);
  process.stdout.write(`${JSON.stringify({ type: "sync_state", driver_generation: generation,
    transport_cursor: state.transportCursor })}\n`);
  const eligible = [...state.quarantineByWire.values()]
    .filter((message) => ["unsupported_cipher", "pending_key", "authentication_failed",
      "malformed", "policy_violation"].includes(message.status))
    .sort((left, right) => BigInt(left.server_seq) < BigInt(right.server_seq) ? -1 :
      BigInt(left.server_seq) > BigInt(right.server_seq) ? 1 : left.id.localeCompare(right.id))
    .filter((message) => afterReprocessToken(message, after));
  const candidates = eligible.slice(0, limit);
  for (const message of candidates) {
    process.stdout.write(`${JSON.stringify({ type: "sync_reprocess_candidate",
      server_seq: message.server_seq, id: message.id,
      server_received_at: message.server_received_at, envelope: message.envelope,
      prior_status: message.status })}\n`);
  }
  const hasMore = eligible.length > limit;
  process.stdout.write(`${JSON.stringify({ type: "sync_reprocess_page",
    next_after: hasMore ? reprocessToken(candidates.at(-1)) : null,
    has_more: hasMore })}\n`);
}

async function stdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

async function main() {
  const [operation, path, localTeam, server, remote, protocolText, extra, pageAfter] =
    process.argv.slice(2);
  if (operation === "rotate-generation") {
    readRecords(path);
    appendRecord(path, { type: "sync_generation", generation: randomUUID(),
      created_at: new Date().toISOString() });
    if (process.env.AGMSG_SYNC_TEST_ABORT_AFTER_ROTATE_APPEND === "1") {
      fail("aborted after replacement generation append", 75);
    }
    return;
  }
  const target = binding(localTeam, server, remote, Number(protocolText));
  const input = await stdin();
  if (operation === "prepare") {
    const limit = Number(extra);
    if (!Number.isInteger(limit) || limit < 1 || limit > 1000) fail("prepare limit is invalid");
    prepare(path, target, limit, input);
  } else if (operation === "reconcile") {
    reconcile(path, target, input);
  } else if (operation === "apply") {
    apply(path, target, input);
  } else if (operation === "reprocess") {
    const limit = Number(extra);
    if (input.trim() !== "" || !Number.isInteger(limit) || limit < 1 || limit > 1000) {
      fail("reprocess input or limit is invalid");
    }
    reprocess(path, target, limit, pageAfter);
  } else {
    fail("unknown JSONL sync operation", 2);
  }
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = error.exitCode ?? 13;
});
