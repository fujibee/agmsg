import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { DatabaseSync } from 'node:sqlite';

import { createTerminalPokeChannel } from '../scripts/daemon/channels/terminal-poke.mjs';
import { ensureTerminalPokeChannelSchema } from '../scripts/daemon/channels/terminal-poke-store.mjs';
import { openInstallDb } from '../scripts/daemon/db.mjs';
import { openMessageStore, readUnreadSnapshot } from '../scripts/daemon/channels/codex-queue-store.mjs';

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
    verifiedInputBox: () => state.verifiedInputBox ?? true,
    nudgeText: (type, cmdName) => `agmsg: you have new messages. Run $${cmdName} to check your inbox.`,
    readDriver: () => ({ state: 'ok', driver: 'sqlite' }),
    openStore: () => ({ close() {} }),
    readSnapshot: (_store, _team, _agent, cursor = '') => ({
      state: 'ok',
      unread: state.unread !== false && state.sequence > (cursor ? JSON.parse(cursor).eventSeq : 0),
      upTo: JSON.stringify({ eventSeq: state.sequence, legacyId: 0 }),
    }),
    readOwnMarker: () => String(state.sequence),
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

test('two seats of one type in the same place under different spellings are each other\'s peers', async (t) => {
  const root = temporaryDirectory(t);
  const place = path.join(root, 'proj');
  mkdirSync(place);
  const seen = [];
  const { channel } = channelFixture(t, {
    listSeats: () => ({ state: 'ok', seats: [
      { team: 'test', agent: 'agy1', type: 'antigravity', project: place, teamConfig: {} },
      { team: 'test', agent: 'agy2', type: 'antigravity', project: `${place}/.`, teamConfig: {} },
    ] }),
    nudge: async (args) => { seen.push([args.agent, args.peers]); return { kind: 'ok', state: 'notified', reason: '' }; },
  });
  await channel.pollOnce();
  assert.deepEqual(seen.find(([agent]) => agent === 'agy1')?.[1], ['test/agy2']);
  assert.deepEqual(seen.find(([agent]) => agent === 'agy2')?.[1], ['test/agy1']);
  await channel.stop();
});

test('ambiguous panes are unaddressable, with the candidates as the reason, and nothing is confirmed', async (t) => {
  const { channel, state, db } = channelFixture(t);
  state.nudgeState = 'ambiguous';
  state.nudgeReason = 'herdr:/s:w1:p1 herdr:/s:w1:p2';
  await channel.pollOnce();
  assert.deepEqual(seatBrief(channel), { state: 'unaddressable', reason: 'ambiguous:herdr:/s:w1:p1 herdr:/s:w1:p2' });
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM beta_terminal_poke_queue WHERE state='confirmed'").get().n, 0);
  await channel.stop();
});

test('an empty message store goes through the channel poll as "no unread": no failure on the seat, no nudge', async (t) => {
  const fixture = channelFixture(t, { openStore: openMessageStore, readSnapshot: readUnreadSnapshot, readOwnMarker: undefined });
  // channelFixture put the store in AGMSG_STORAGE_PATH=root: a database with no tables yet.
  new DatabaseSync(path.join(fixture.state.options.installRoot, 'messages.db')).close();
  await fixture.channel.pollOnce();
  assert.equal(fixture.state.nudgeCalls, 0);
  assert.deepEqual(seatBrief(fixture.channel), { state: 'addressable', reason: '' });
  await fixture.channel.stop();
});

test('a store with only some of the message tables is still unreadable through the channel', async (t) => {
  const fixture = channelFixture(t, { openStore: openMessageStore, readSnapshot: readUnreadSnapshot, readOwnMarker: undefined });
  const store = new DatabaseSync(path.join(fixture.state.options.installRoot, 'messages.db'));
  store.exec('CREATE TABLE messages (id INTEGER PRIMARY KEY)');
  store.close();
  await fixture.channel.pollOnce();
  assert.equal(fixture.state.nudgeCalls, 0);
  assert.match(seatBrief(fixture.channel).reason, /^message_store_unreadable:.*no such table/);
  await fixture.channel.stop();
});

test('a store nothing was ever sent through is "no unread", not an unreadable store', () => {
  const store = new DatabaseSync(':memory:');
  assert.deepEqual(readUnreadSnapshot(store, 'test', 'agy1'), { state: 'ok', unread: false, upTo: JSON.stringify({ eventSeq: 0, legacyId: 0 }) });
  // Only some of the tables: still an error, not a guessed "no unread".
  store.exec('CREATE TABLE messages (id INTEGER PRIMARY KEY, team TEXT, to_agent TEXT, read_at TEXT)');
  assert.throws(() => readUnreadSnapshot(store, 'test', 'agy1'), /no such table/);
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

test('review: another seat\'s own message does not reset this seat\'s backoff (real store, not the fake readSnapshot above)', async (t) => {
  const { channel, state } = channelFixture(t);
  const store = new DatabaseSync(':memory:');
  t.after(() => store.close());
  store.exec(`
    CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, type TEXT, team TEXT, to_agent TEXT, agent TEXT, msg_id TEXT, legacy_id INTEGER);
    CREATE TABLE messages (id INTEGER PRIMARY KEY, team TEXT, to_agent TEXT, read_at TEXT);
    CREATE TABLE read_cursors (team TEXT, agent TEXT, local_position INTEGER);
    INSERT INTO events(id,type,team,to_agent) VALUES ('m1','message_sent','test','agy1');
  `);
  // A real store is closed by the channel after every poll (matching
  // production, where a fresh connection is opened each cycle); this test
  // reuses one in-memory db across two polls, so close() here is a no-op
  // and prepare() is the only thing the channel's own code actually calls.
  state.options.openStore = () => ({
    prepare: (...args) => store.prepare(...args),
    exec: (...args) => store.exec(...args),
    close() {},
  });
  state.options.readSnapshot = (handle, ...args) => readUnreadSnapshot(handle, ...args);
  state.options.readOwnMarker = undefined; // use the real default (readOwnUnreadMarker)
  const channel2 = (await import('../scripts/daemon/channels/terminal-poke.mjs')).createTerminalPokeChannel(state.options);
  state.nudgeState = 'not_ready:agent_status_blocked';
  await channel2.pollOnce();
  assert.equal(state.nudgeCalls, 1);
  state.hours = 0.001;
  // A message to a DIFFERENT agent in the same team: readUnreadSnapshot's
  // own `upTo` (the whole team's tip) moves, but agy1's own unread set has
  // not changed at all.
  store.exec("INSERT INTO events(id,type,team,to_agent) VALUES ('other','message_sent','test','someone-else');");
  await channel2.pollOnce();
  assert.equal(state.nudgeCalls, 1, 'an unrelated send must not reset this seat\'s backoff');
  await channel2.stop();
  await channel.stop();
});

test('review: the nudge call receives a cancellation signal, and stop() aborts it', async (t) => {
  const { channel, state } = channelFixture(t);
  let seenSignal;
  state.options.nudge = async ({ signal }) => { seenSignal = signal; return { kind: 'ok', state: 'notified', reason: '' }; };
  const channel2 = (await import('../scripts/daemon/channels/terminal-poke.mjs')).createTerminalPokeChannel(state.options);
  await channel2.pollOnce();
  assert.ok(seenSignal instanceof AbortSignal, 'the production nudge() call must be given a signal to cancel on');
  await channel2.stop();
  await channel.stop();
});

test('scope decision (2026-11-14): a type with no verified input-box marker gets no nudge, and is shown in status, not hidden', async (t) => {
  const { channel, state } = channelFixture(t, { verifiedInputBox: () => false });
  await channel.pollOnce();
  assert.equal(state.poked, 0, 'no process launch for a type nobody has checked on a real pane');
  assert.deepEqual(seatBrief(channel), { state: 'unaddressable', reason: 'no_verified_input_box:antigravity' });
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
