import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { createTerminalPokeChannel } from '../scripts/daemon/channels/terminal-poke.mjs';
import { ensureTerminalPokeChannelSchema } from '../scripts/daemon/channels/terminal-poke-store.mjs';
import { openInstallDb } from '../scripts/daemon/db.mjs';

function temporaryDirectory(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'agmsgd-terminal-poke-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function seatBrief(channel, seat) {
  const rows = channel.seats().seats;
  const row = seat ? rows.find((item) => item.seat === seat) : rows[0];
  return row && { state: row.state, reason: row.reason };
}

function channelFixture(t, overrides = {}) {
  const root = temporaryDirectory(t);
  mkdirSync(path.join(root, 'run'));
  const db = openInstallDb(path.join(root, 'run', 'install.db'));
  ensureTerminalPokeChannelSchema(db);
  db.exec("UPDATE daemon_intent SET desired='on', op_gen=1");
  t.after(() => db.close());
  const state = {
    sequence: 1,
    unread: true,
    nudgeState: 'notified',
    nudgeCalls: 0,
    poked: 0,
  };
  const teamConfig = { agents: { agy1: { registrations: [{ type: 'antigravity', project: root }] } } };
  const options = {
    db, installRoot: root, expectedOpGen: 1, env: { AGMSG_STORAGE_PATH: root },
    now: () => Date.UTC(2026, 10, 13) + (state.hours ?? 0) * 3_600_000,
    log: () => {},
    listSeats: () => ({ state: 'ok', seats: [{ team: 'test', agent: 'agy1', type: 'antigravity', project: root, teamConfig }] }),
    pokeDelivery: () => state.pokeDelivery ?? true,
    nudgeText: (type, cmdName) => `agmsg: you have new messages. Run $${cmdName} to check your inbox.`,
    readDriver: () => ({ state: 'ok', driver: 'sqlite' }),
    openStore: () => ({ close() {} }),
    readSnapshot: (_store, _team, _agent, cursor = '') => ({
      state: 'ok',
      unread: state.unread !== false && state.sequence > (cursor ? JSON.parse(cursor).eventSeq : 0),
      upTo: JSON.stringify({ eventSeq: state.sequence, legacyId: 0 }),
    }),
    nudge: async () => {
      state.nudgeCalls += 1;
      if (state.nudgeState === 'notified') state.poked += 1;
      return { kind: 'ok', state: state.nudgeState, reason: state.nudgeReason ?? '' };
    },
    ...overrides,
  };
  state.options = options;
  const channel = createTerminalPokeChannel(options);
  return { db, channel, state };
}

test('an unread transition nudges once and advances the cursor only when notified', async (t) => {
  const { db, channel, state } = channelFixture(t);
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1);
  assert.equal(state.poked, 1);
  const row = db.prepare('SELECT state, up_to FROM beta_terminal_poke_queue').get();
  assert.equal(row.state, 'confirmed');
  assert.deepEqual(JSON.parse(row.up_to), { eventSeq: 1, legacyId: 0 });
  assert.deepEqual(seatBrief(channel), { state: 'notified', reason: '' });
  // No new unread: a second poll must not spawn anything.
  for (let i = 0; i < 5; i += 1) await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1, 'no process launch for a seat with nothing pending');
  await channel.stop();
});

test('a new unread transition after a confirmed notify nudges again', async (t) => {
  const { channel, state } = channelFixture(t);
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1);
  state.sequence = 2;
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 2);
  await channel.stop();
});

test('a refusal (not_ready) leaves the notice pending and is retried on the next cycle, never dropped', async (t) => {
  const { db, channel, state } = channelFixture(t);
  state.nudgeState = 'not_ready:agent_status_blocked';
  await channel.pollOnce();
  assert.equal(state.poked, 0);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM beta_terminal_poke_queue WHERE state='confirmed'").get().n, 0);
  assert.deepEqual(seatBrief(channel), { state: 'pending', reason: 'not_ready:agent_status_blocked' });
  // Same unread, still pending: once the backoff window has passed, the
  // next cycle must try again, not drop it.
  state.nudgeState = 'notified';
  state.hours = 0.02; // 72s, past the 30s first backoff step
  await channel.pollOnce();
  assert.equal(state.poked, 1);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM beta_terminal_poke_queue WHERE state='confirmed'").get().n, 1);
  await channel.stop();
});

test('no_pane and pane_gone are reported as unaddressable, never silently dropped', async (t) => {
  const { channel, state } = channelFixture(t);
  state.nudgeState = 'no_pane';
  await channel.pollOnce();
  assert.deepEqual(seatBrief(channel), { state: 'unaddressable', reason: 'no_pane' });
  await channel.stop();
});

test('a project that opted out of agmsgd delivery gets no nudge', async (t) => {
  const root = temporaryDirectory(t);
  const { channel, state } = channelFixture(t, {
    installRoot: root,
  });
  // Re-create with an opted-out delivery choice file.
  mkdirSync(path.join(root, 'run'), { recursive: true });
  const db = openInstallDb(path.join(root, 'run', 'install.db'));
  const { ensureTerminalPokeChannelSchema: ensure } = await import('../scripts/daemon/channels/terminal-poke-store.mjs');
  ensure(db);
  db.exec("UPDATE daemon_intent SET desired='on', op_gen=1");
  t.after(() => db.close());
  const fs = await import('node:fs');
  fs.writeFileSync(path.join(root, 'run', 'delivery-choice'), `antigravity\t${root}\tmonitor\n`);
  const teamConfig = { agents: { agy1: { registrations: [{ type: 'antigravity', project: root }] } } };
  const optedOutState = { nudgeCalls: 0 };
  const optedOutChannel = (await import('../scripts/daemon/channels/terminal-poke.mjs')).createTerminalPokeChannel({
    db, installRoot: root, expectedOpGen: 1, env: {},
    now: () => Date.UTC(2026, 10, 13),
    log: () => {},
    listSeats: () => ({ state: 'ok', seats: [{ team: 'test', agent: 'agy1', type: 'antigravity', project: root, teamConfig }] }),
    pokeDelivery: () => true,
    readDriver: () => ({ state: 'ok', driver: 'sqlite' }),
    openStore: () => ({ close() {} }),
    readSnapshot: () => ({ state: 'ok', unread: true, upTo: JSON.stringify({ eventSeq: 1, legacyId: 0 }) }),
    nudge: async () => { optedOutState.nudgeCalls += 1; return { kind: 'ok', state: 'notified', reason: '' }; },
  });
  await optedOutChannel.pollOnce();
  assert.equal(optedOutState.nudgeCalls, 0, 'an opted-out project is never poked');
  assert.deepEqual(seatBrief(optedOutChannel), { state: 'unaddressable', reason: 'delivery_chosen_monitor' });
  await optedOutChannel.stop();
  await channel.stop();
});

test('a pending notice backs off instead of being retried every poll cycle (review-criteria §4)', async (t) => {
  const { channel, state } = channelFixture(t);
  state.nudgeState = 'not_ready:agent_status_blocked';
  await channel.pollOnce(); // attempt 1, at t=0
  assert.equal(state.nudgeCalls, 1);
  state.hours = 0.001; // a few seconds later -- well under the 30s first step
  await channel.pollOnce();
  await channel.pollOnce();
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1, 'no process launch before the backoff is due');
  await channel.stop();
});

test('backoff resets to the first step immediately when the unread set changes', async (t) => {
  const { channel, state } = channelFixture(t);
  state.nudgeState = 'not_ready:agent_status_blocked';
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1);
  state.hours = 0.001;
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1, 'still backing off for the SAME unread set');
  state.sequence = 2; // a new message arrived
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 2, 'a new unread transition retries immediately, backoff or not');
  await channel.stop();
});

test('a type with poke_delivery=no gets no nudge', async (t) => {
  const { channel, state } = channelFixture(t, { pokeDelivery: () => false });
  await channel.pollOnce();
  assert.equal(state.poked, 0);
  assert.deepEqual(seatBrief(channel), { state: 'unaddressable', reason: 'poke_delivery_opted_out' });
  await channel.stop();
});

test('a seat whose team roster becomes unreadable is reported, not hidden', async (t) => {
  const { channel, state } = channelFixture(t, {
    listSeats: () => ({ state: 'ok', seats: [], skipped: [{ team: 'test', reason: 'team_roster_malformed' }] }),
  });
  await channel.pollOnce();
  assert.deepEqual(seatBrief(channel, JSON.stringify(['test', ''])), { state: 'unaddressable', reason: 'team_roster_malformed' });
  assert.equal(state.poked, 0);
  await channel.stop();
});
