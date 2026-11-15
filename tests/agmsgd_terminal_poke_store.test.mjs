import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { listTerminalPokeRegistrations } from '../scripts/daemon/channels/terminal-poke-store.mjs';

function temporaryDirectory(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'agmsgd-terminal-poke-store-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function writeTeam(teamsDir, team, agents) {
  mkdirSync(path.join(teamsDir, team), { recursive: true });
  writeFileSync(path.join(teamsDir, team, 'config.json'), JSON.stringify({ agents }));
}

test('a seat with only a non-native registration is listed', (t) => {
  const teamsDir = temporaryDirectory(t);
  writeTeam(teamsDir, 'test', { agy1: { registrations: [{ type: 'antigravity', project: '/a' }] } });
  const result = listTerminalPokeRegistrations(teamsDir);
  assert.equal(result.state, 'ok');
  assert.deepEqual(result.seats.map((s) => [s.team, s.agent, s.type]), [['test', 'agy1', 'antigravity']]);
});

test('a seat with any native-channel registration is excluded entirely', (t) => {
  const teamsDir = temporaryDirectory(t);
  writeTeam(teamsDir, 'test', {
    alice: { registrations: [{ type: 'claude-code', project: '/a' }] },
    bob: { registrations: [{ type: 'codex', project: '/b' }] },
  });
  const result = listTerminalPokeRegistrations(teamsDir);
  assert.deepEqual(result.seats, []);
});

test('a seat whose type opted out via poke_delivery=no is excluded', (t) => {
  const teamsDir = temporaryDirectory(t);
  writeTeam(teamsDir, 'test', { g1: { registrations: [{ type: 'gemini', project: '/g' }] } });
  const result = listTerminalPokeRegistrations(teamsDir, { pokeDeliveryEnabled: (type) => type !== 'gemini' });
  assert.deepEqual(result.seats, []);
});

test('an unreadable team config is reported in skipped, not silently dropped, and does not hide other teams', (t) => {
  const teamsDir = temporaryDirectory(t);
  mkdirSync(path.join(teamsDir, 'broken'));
  writeFileSync(path.join(teamsDir, 'broken', 'config.json'), 'not json');
  writeTeam(teamsDir, 'ok', { g1: { registrations: [{ type: 'gemini', project: '/g' }] } });
  const result = listTerminalPokeRegistrations(teamsDir);
  assert.deepEqual(result.skipped, [{ team: 'broken', reason: 'team_roster_malformed' }]);
  assert.deepEqual(result.seats.map((s) => s.team), ['ok']);
});

test('an agent with no registrations at all is not listed', (t) => {
  const teamsDir = temporaryDirectory(t);
  writeTeam(teamsDir, 'test', { nobody: { registrations: [] } });
  const result = listTerminalPokeRegistrations(teamsDir);
  assert.deepEqual(result.seats, []);
});

test('a missing teams directory is simply an empty roster', (t) => {
  const teamsDir = path.join(temporaryDirectory(t), 'does-not-exist');
  const result = listTerminalPokeRegistrations(teamsDir);
  assert.equal(result.state, 'ok');
  assert.deepEqual(result.seats, []);
});
