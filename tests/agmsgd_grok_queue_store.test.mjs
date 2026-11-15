import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  grokWitnessKey,
  grokWitnessPath,
  leaderSocketDirIsLax,
  listGrokRegistrations,
  readGrokWitness,
} from '../scripts/daemon/channels/grok-queue-store.mjs';

function temporaryDirectory(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'agmsgd-grok-queue-store-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test('grokWitnessKey is a stable SHA-1 of team and agent, independent of call order elsewhere', () => {
  assert.equal(grokWitnessKey('t1', 'gagent'), '05efad1c10586f4fc660d9d2a1cc05a90949d5c8');
  assert.notEqual(grokWitnessKey('t1', 'gagent'), grokWitnessKey('gagent', 't1'));
});

test('listGrokRegistrations lists only type grok-build, excluding other types in the same team', (t) => {
  const root = temporaryDirectory(t);
  const teamsDir = path.join(root, 'teams');
  mkdirSync(path.join(teamsDir, 'myteam'), { recursive: true });
  writeFileSync(path.join(teamsDir, 'myteam', 'config.json'), JSON.stringify({
    agents: {
      ga1: { registrations: [{ type: 'grok-build', project: '/p1' }] },
      other: { registrations: [{ type: 'codex', project: '/p2' }] },
    },
  }));
  const result = listGrokRegistrations(teamsDir);
  assert.equal(result.state, 'ok');
  assert.equal(result.seats.length, 1);
  assert.equal(result.seats[0].agent, 'ga1');
});

test('listGrokRegistrations reports one malformed team under skipped, others unaffected', (t) => {
  const root = temporaryDirectory(t);
  const teamsDir = path.join(root, 'teams');
  mkdirSync(path.join(teamsDir, 'bad'), { recursive: true });
  writeFileSync(path.join(teamsDir, 'bad', 'config.json'), 'not json');
  mkdirSync(path.join(teamsDir, 'good'), { recursive: true });
  writeFileSync(path.join(teamsDir, 'good', 'config.json'), JSON.stringify({
    agents: { ga1: { registrations: [{ type: 'grok-build', project: '/p1' }] } },
  }));
  const result = listGrokRegistrations(teamsDir);
  assert.equal(result.state, 'ok');
  assert.equal(result.seats.length, 1);
  assert.equal(result.skipped.length, 1);
  assert.equal(result.skipped[0].team, 'bad');
});

test('listGrokRegistrations with no teams directory at all is an empty, ok roster', (t) => {
  const root = temporaryDirectory(t);
  const result = listGrokRegistrations(path.join(root, 'teams'));
  assert.deepEqual(result, { state: 'ok', seats: [] });
});

test('readGrokWitness: missing file is reported as missing, not unreadable', (t) => {
  const root = temporaryDirectory(t);
  mkdirSync(path.join(root, 'run'), { recursive: true });
  const result = readGrokWitness(root, 't1', 'gagent');
  assert.deepEqual(result, { state: 'missing' });
});

test('readGrokWitness: a complete witness reads back exactly as written', (t) => {
  const root = temporaryDirectory(t);
  mkdirSync(path.join(root, 'run'), { recursive: true });
  const witness = { team: 't1', agent: 'gagent', session_id: 's1', pid: 1234, cwd: '/p', leader_socket: '/tmp/l.sock', started_at: '2026-11-15T00:00:00Z', first_turn_done: true };
  writeFileSync(grokWitnessPath(root, 't1', 'gagent'), JSON.stringify(witness));
  const result = readGrokWitness(root, 't1', 'gagent');
  assert.equal(result.state, 'ok');
  assert.deepEqual(result.witness, witness);
});

test('readGrokWitness: a witness missing a required field is unreadable, not silently accepted', (t) => {
  const root = temporaryDirectory(t);
  mkdirSync(path.join(root, 'run'), { recursive: true });
  writeFileSync(grokWitnessPath(root, 't1', 'gagent'), JSON.stringify({ session_id: 's1' }));
  const result = readGrokWitness(root, 't1', 'gagent');
  assert.equal(result.state, 'unreadable');
  assert.equal(result.reason, 'witness_incomplete');
});

test('readGrokWitness: invalid JSON is unreadable, not a crash', (t) => {
  const root = temporaryDirectory(t);
  mkdirSync(path.join(root, 'run'), { recursive: true });
  writeFileSync(grokWitnessPath(root, 't1', 'gagent'), 'not json');
  const result = readGrokWitness(root, 't1', 'gagent');
  assert.equal(result.state, 'unreadable');
});

test('leaderSocketDirIsLax: group/other access on the socket directory is reported', (t) => {
  const root = temporaryDirectory(t);
  const dir = path.join(root, 'grokhome');
  mkdirSync(dir);
  chmodSync(dir, 0o755);
  assert.equal(leaderSocketDirIsLax(path.join(dir, 'leader.sock')), true);
});

test('leaderSocketDirIsLax: a 0700 directory is not flagged', (t) => {
  const root = temporaryDirectory(t);
  const dir = path.join(root, 'grokhome');
  mkdirSync(dir);
  chmodSync(dir, 0o700);
  assert.equal(leaderSocketDirIsLax(path.join(dir, 'leader.sock')), false);
});

test('leaderSocketDirIsLax: a directory that cannot be statted is not flagged (nothing known to warn about)', () => {
  assert.equal(leaderSocketDirIsLax('/no/such/dir/leader.sock'), false);
});
