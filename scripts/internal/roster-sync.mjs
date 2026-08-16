#!/usr/bin/env node

import { randomUUID } from "node:crypto";
import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import process from "node:process";
import { sealEnvelope } from "./sync-cipher.mjs";

const [operation, configPath, serverId, remoteTeamId, protocolText, limitText] =
  process.argv.slice(2);
const teamDir = dirname(configPath);
const journalPath = join(teamDir, "roster.jsonl");
const statePath = join(teamDir, "roster-sync.json");
const bindingKey = `${serverId}:${remoteTeamId}:${protocolText}`;

function readJsonlInput() {
  return readFileSync(0, "utf8").split(/\r?\n/u).filter(Boolean).map((line) => JSON.parse(line));
}

function readJournal() {
  try {
    return readFileSync(journalPath, "utf8").split(/\r?\n/u).filter(Boolean)
      .map((line) => JSON.parse(line));
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
}

function readState() {
  try {
    const state = JSON.parse(readFileSync(statePath, "utf8"));
    if (state.format_version !== 1 || typeof state.bindings !== "object") {
      throw new Error("roster sync state is invalid");
    }
    return state;
  } catch (error) {
    if (error.code === "ENOENT") return { format_version: 1, bindings: {} };
    throw error;
  }
}

function writeAtomic(path, contents) {
  const temporary = `${path}.tmp.${process.pid}.${randomUUID()}`;
  writeFileSync(temporary, contents, { encoding: "utf8", mode: 0o600 });
  renameSync(temporary, path);
}

function writeJournal(records) {
  writeAtomic(journalPath, records.map((record) => JSON.stringify(record)).join("\n"));
}

function writeState(state) {
  writeAtomic(statePath, `${JSON.stringify(state)}\n`);
}

function timestamp(value) {
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/u.test(value) ?
    `${value.slice(0, -1)}.000000Z` : value;
}

function projection(record) {
  if (record.type === "key_rotated") {
    return {
      kind: record.type,
      mutation_id: record.id,
      epoch: record.epoch,
      key_id: record.key_id,
      fingerprint: record.fingerprint,
      occurred_at: timestamp(record.at),
    };
  }
  const common = {
    kind: record.type,
    mutation_id: record.id,
    member_id: record.member_id,
  };
  if (record.type === "member_renamed") {
    return { ...common, from: record.from, to: record.to, occurred_at: timestamp(record.at) };
  }
  return { ...common, name: record.name, occurred_at: timestamp(record.at) };
}

function mutation(value) {
  if (value.kind === "key_rotated") {
    return {
      type: value.kind,
      id: value.mutation_id,
      epoch: value.epoch,
      key_id: value.key_id,
      fingerprint: value.fingerprint,
      at: value.occurred_at,
    };
  }
  const common = {
    type: value.kind,
    id: value.mutation_id,
    member_id: value.member_id,
  };
  if (value.kind === "member_renamed") {
    return { ...common, from: value.from, to: value.to, at: value.occurred_at };
  }
  return { ...common, name: value.name, at: value.occurred_at };
}

function sameRecord(left, right) {
  return JSON.stringify(projection(left)) === JSON.stringify(projection(right));
}

function syncRecord(mutationId, serverSeq, wireId) {
  return {
    type: "roster_synced",
    mutation_id: mutationId,
    server_seq: serverSeq,
    wire_id: wireId,
    server_instance_id: serverId,
    remote_team_id: remoteTeamId,
  };
}

function binding(state) {
  state.bindings[bindingKey] ??= { reservations: {}, transport_cursor: "0" };
  return state.bindings[bindingKey];
}

function prepare() {
  const input = readJsonlInput();
  const request = input.find((record) => record.type === "sync_prepare");
  const limit = Number(limitText);
  if (!request || !Number.isInteger(limit) || limit < 1 || limit > 1000) {
    throw new Error("roster prepare input is invalid");
  }
  const records = readJournal();
  const state = readState();
  const target = binding(state);
  const synced = new Set(records.filter((record) =>
    record.type === "roster_synced" &&
    record.server_instance_id === serverId &&
    record.remote_team_id === remoteTeamId).map((record) => record.mutation_id));
  const mutations = records.filter((record) =>
    ["member_joined", "member_left", "member_renamed", "key_rotated"].includes(record.type) &&
    !synced.has(record.id) &&
    (request.allow_new || target.reservations[record.id])).slice(0, limit);

  for (const record of mutations) {
    let reserved = target.reservations[record.id];
    if (!reserved) {
      if (!request.allow_new) continue;
      const wireId = randomUUID();
      const envelope = sealEnvelope({
        type: "sync_seal",
        envelope_v: request.envelope_v,
        cipher: request.cipher,
        key_id: request.key_id,
        recipients: request.recipients,
        max_blob_bytes: request.max_blob_bytes,
        wire_id: wireId,
        team_id: remoteTeamId,
        protocol_version: Number(protocolText),
        projection: projection(record),
      });
      reserved = { wire_id: wireId, envelope };
      target.reservations[record.id] = reserved;
    }
  }
  writeState(state);
  process.stdout.write(`${JSON.stringify({
    type: "roster_sync_state", transport_cursor: target.transport_cursor,
  })}\n`);
  for (const record of mutations) {
    const reserved = target.reservations[record.id];
    if (!reserved) continue;
    process.stdout.write(`${JSON.stringify({
      type: "roster_sync_push_candidate",
      local_position: record.id,
      local_id: record.id,
      id: reserved.wire_id,
      envelope: reserved.envelope,
      projection: projection(record),
    })}\n`);
  }
}

function reconcile() {
  const acknowledgements = readJsonlInput();
  const records = readJournal();
  const state = readState();
  const target = binding(state);
  const existing = new Set(records.filter((record) =>
    record.type === "roster_synced" &&
    record.server_instance_id === serverId &&
    record.remote_team_id === remoteTeamId).map((record) => record.mutation_id));
  for (const ack of acknowledgements) {
    const reserved = target.reservations[ack.local_position];
    if (!reserved || reserved.wire_id !== ack.id ||
        !["stored", "duplicate"].includes(ack.disposition)) {
      throw new Error("roster acknowledgement does not match a reservation");
    }
    reserved.server_seq = ack.server_seq;
    if (!existing.has(ack.local_position)) {
      records.push(syncRecord(ack.local_position, ack.server_seq, ack.id));
      existing.add(ack.local_position);
    }
  }
  writeJournal(records);
  writeState(state);
  process.stdout.write(`${JSON.stringify({
    type: "roster_sync_reconcile_result", count: acknowledgements.length,
  })}\n`);
}

function apply() {
  const input = readJsonlInput();
  const records = readJournal();
  const state = readState();
  const target = binding(state);
  const mutations = new Map(records.filter((record) =>
    ["member_joined", "member_left", "member_renamed", "key_rotated"].includes(record.type))
    .map((record) => [record.id, record]));
  const synced = new Set(records.filter((record) =>
    record.type === "roster_synced" &&
    record.server_instance_id === serverId &&
    record.remote_team_id === remoteTeamId).map((record) => record.mutation_id));
  for (const item of input) {
    if (item.type === "sync_pull_cursor") {
      target.transport_cursor = item.next_after;
      continue;
    }
    if (item.type !== "sync_pull_message" || item.status !== "importable" ||
        !["member_joined", "member_left", "member_renamed", "key_rotated"]
          .includes(item.projection?.kind)) {
      throw new Error("roster pull input is invalid");
    }
    const incoming = mutation(item.projection);
    const prior = mutations.get(incoming.id);
    if (prior && !sameRecord(prior, incoming)) {
      throw new Error("roster mutation id maps to different content");
    }
    if (!prior) {
      records.push(incoming);
      mutations.set(incoming.id, incoming);
    }
    if (!synced.has(incoming.id)) {
      records.push(syncRecord(incoming.id, item.server_seq, item.id));
      synced.add(incoming.id);
    }
    process.stdout.write(`${JSON.stringify({
      type: "roster_sync_apply_outcome",
      id: item.id,
      server_seq: item.server_seq,
      status: prior ? "reconciled" : "imported",
    })}\n`);
  }
  writeJournal(records);
  writeState(state);
}

try {
  if (operation === "prepare") prepare();
  else if (operation === "reconcile") reconcile();
  else if (operation === "apply") apply();
  else throw new Error("unknown roster sync operation");
} catch (error) {
  process.stderr.write(`agmsg: roster sync ${operation} failed: ${error.message}\n`);
  process.exitCode = 13;
}
