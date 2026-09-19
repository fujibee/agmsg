import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { openEnvelope } from "../scripts/internal/sync-cipher.mjs";

const driver = new URL("../scripts/internal/roster-sync-driver.sh", import.meta.url).pathname;
const serverId = "018f3f7e-0000-7000-8000-000000000001";
const teamId = "018f3f7e-0000-7000-8000-000000000002";
const memberA = "018f3f7e-0000-7000-8000-000000000010";
const memberB = "018f3f7e-0000-7000-8000-000000000011";
const mutationA = "018f3f7e-0000-7000-8000-000000000020";
const mutationB = "018f3f7e-0000-7000-8000-000000000021";

function call(operation, config, input, extra = []) {
  const output = execFileSync("bash", [
    driver, operation, "demo", serverId, teamId, "1", ...extra,
  ], {
    input: input.map((record) => `${JSON.stringify(record)}\n`).join(""),
    encoding: "utf8",
    env: { ...process.env, AGMSG_SYNC_LOCAL_ROSTER_FILE: config },
  });
  return output.split(/\r?\n/u).filter(Boolean).map((line) => JSON.parse(line));
}

async function machine(root, memberId, mutationId) {
  const config = join(root, "config.json");
  const journal = join(root, "roster.jsonl");
  await writeFile(config, `${JSON.stringify({
    name: "demo",
    team_id: teamId,
    agents: {
      alice: {
        member_id: memberId,
        registrations: [{ type: memberId === memberA ? "codex" : "claude-code",
          project: root }],
      },
    },
  })}\n`);
  await writeFile(journal, `${JSON.stringify({
    type: "member_joined",
    id: mutationId,
    member_id: memberId,
    name: "alice",
    at: "2026-07-28T23:00:00Z",
  })}\n`);
  return { config, journal };
}

test("roster mutations use the message transport and converge by server sequence", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "agmsg-roster-sync-"));
  try {
    const aRoot = join(scratch, "a");
    const bRoot = join(scratch, "b");
    await Promise.all([mkdir(aRoot), mkdir(bRoot)]);
    const a = await machine(aRoot, memberA, mutationA);
    const b = await machine(bRoot, memberB, mutationB);
    const prepare = [{
      type: "sync_prepare",
      envelope_v: 1,
      cipher: "none",
      key_id: null,
      recipients: [],
      max_blob_bytes: 1_048_576,
      allow_new: true,
    }];
    const candidateA = call("prepare", a.config, prepare, ["10"])
      .find((record) => record.type === "roster_sync_push_candidate");
    const candidateB = call("prepare", b.config, prepare, ["10"])
      .find((record) => record.type === "roster_sync_push_candidate");
    assert.ok(candidateA);
    assert.ok(candidateB);

    const projectionA = await openEnvelope({
      envelope: candidateA.envelope,
      max_blob_bytes: 1_048_576,
    });
    const projectionB = await openEnvelope({
      envelope: candidateB.envelope,
      max_blob_bytes: 1_048_576,
    });
    assert.equal(projectionA.kind, "member_joined");
    assert.equal(projectionB.kind, "member_joined");

    // Machine B reaches the shared transport first. Both machines must
    // therefore converge on B's identity even though A wrote its local
    // mutation first in A's physical journal.
    call("reconcile", b.config, [{
      type: "sync_push_ack",
      local_position: mutationB,
      id: candidateB.id,
      server_seq: "1",
      disposition: "stored",
    }]);
    call("reconcile", a.config, [{
      type: "sync_push_ack",
      local_position: mutationA,
      id: candidateA.id,
      server_seq: "2",
      disposition: "stored",
    }]);
    call("apply", a.config, [{
      type: "sync_pull_message",
      server_seq: "1",
      id: candidateB.id,
      status: "importable",
      projection: projectionB,
    }, {
      type: "sync_pull_message",
      server_seq: "2",
      id: candidateA.id,
      status: "importable",
      projection: projectionA,
    }, { type: "sync_pull_cursor", next_after: "2" }]);
    call("apply", b.config, [{
      type: "sync_pull_message",
      server_seq: "1",
      id: candidateB.id,
      status: "importable",
      projection: projectionB,
    }, {
      type: "sync_pull_message",
      server_seq: "2",
      id: candidateA.id,
      status: "importable",
      projection: projectionA,
    }, { type: "sync_pull_cursor", next_after: "2" }]);

    const configA = JSON.parse(await readFile(a.config, "utf8"));
    const configB = JSON.parse(await readFile(b.config, "utf8"));
    assert.equal(configA.agents.alice.member_id, memberB);
    assert.equal(configB.agents.alice.member_id, memberB);
    assert.deepEqual(configA.agents.alice.registrations, [{
      type: "codex",
      project: aRoot,
    }]);
    assert.deepEqual(configB.agents.alice.registrations, [{
      type: "claude-code",
      project: bRoot,
    }]);
    assert.equal(Object.keys(configA.agents).length, 1);
    assert.equal(Object.keys(configB.agents).length, 1);
  } finally {
    await rm(scratch, { recursive: true });
  }
});

test("key rotation is transported as a fingerprint-only journal mutation", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "agmsg-key-rotation-sync-"));
  try {
    const config = join(scratch, "config.json");
    const mutationId = "018f3f7e-0000-7000-8000-000000000022";
    await writeFile(config, `${JSON.stringify({
      name: "demo", team_id: teamId, agents: {},
    })}\n`);
    await writeFile(join(scratch, "roster.jsonl"), `${JSON.stringify({
      type: "key_rotated",
      id: mutationId,
      epoch: "1",
      key_id: "epoch-20260729010000-abcd",
      fingerprint: "b".repeat(64),
      at: "2026-07-29T01:00:00Z",
    })}\n`);
    const candidate = call("prepare", config, [{
      type: "sync_prepare", envelope_v: 1, cipher: "none", key_id: null,
      recipients: [], max_blob_bytes: 1_048_576, allow_new: true,
    }], ["10"]).find((record) => record.type === "roster_sync_push_candidate");
    assert.equal(candidate.projection.kind, "key_rotated");
    const opened = await openEnvelope({ envelope: candidate.envelope, max_blob_bytes: 1_048_576 });
    assert.deepEqual(opened, candidate.projection);
    assert.equal(JSON.stringify(opened).includes("age1"), false);
    assert.equal(JSON.stringify(opened).includes("AGE-SECRET"), false);
  } finally {
    await rm(scratch, { recursive: true });
  }
});
