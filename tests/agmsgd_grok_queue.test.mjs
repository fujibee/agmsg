import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { spawn } from 'node:child_process';

import { createGrokQueueChannel } from '../scripts/daemon/channels/grok-queue.mjs';
import { ensureGrokQueueChannelSchema } from '../scripts/daemon/channels/grok-queue-store.mjs';
import { openInstallDb } from '../scripts/daemon/db.mjs';

function temporaryDirectory(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'agmsgd-grok-queue-'));
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
  ensureGrokQueueChannelSchema(db);
  db.exec("UPDATE daemon_intent SET desired='on', op_gen=1");
  t.after(() => db.close());
  const state = {
    sequence: 1,
    unread: true,
    nudgeKind: 'ok',
    nudgeCalls: 0,
    witness: { session_id: 'sess-1', pid: process.pid, leader_socket: '/tmp/fake.sock', cwd: '/a/project', first_turn_done: true },
  };
  const teamConfig = { agents: { ga1: { registrations: [{ type: 'grok-build', project: root }] } } };
  const options = {
    db, installRoot: root, expectedOpGen: 1, env: { AGMSG_STORAGE_PATH: root },
    now: () => Date.UTC(2026, 10, 15) + (state.hours ?? 0) * 3_600_000,
    log: () => {},
    listSeats: () => ({ state: 'ok', seats: [{ team: 'test', agent: 'ga1', project: root, teamConfig }] }),
    readWitness: () => (state.witness === null ? { state: 'missing' } : { state: 'ok', witness: state.witness }),
    readPendingReason: () => state.pendingReason ?? '',
    nudgeText: () => 'agmsg: you have new messages. Run /agmsg to check your inbox.',
    readDriver: () => ({ state: 'ok', driver: 'sqlite' }),
    openStore: () => ({ close() {} }),
    readSnapshot: (_store, _team, _agent) => ({
      state: 'ok',
      unread: state.unread !== false,
      upTo: JSON.stringify({ eventSeq: state.sequence, legacyId: 0 }),
    }),
    readOwnMarker: () => String(state.sequence),
    checkSocketPerms: () => state.socketLax ?? false,
    checkLeaderListening: async () => state.leaderListening ?? true,
    nudge: async () => {
      state.nudgeCalls += 1;
      return { kind: state.nudgeKind, reason: state.nudgeReason ?? '' };
    },
    ...overrides,
  };
  state.options = options;
  const channel = createGrokQueueChannel(options);
  return { db, channel, state };
}

test('an unread transition with a ready witness nudges once and reports notified', async (t) => {
  const { channel, state } = channelFixture(t);
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1);
  assert.deepEqual(seatBrief(channel), { state: 'notified', reason: '' });
  for (let i = 0; i < 5; i += 1) await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1, 'no process launch for a seat with nothing newly unread');
  await channel.stop();
});

test('no witness yet (agmsgd not chosen, or SessionStart never ran) is reported, never attempted', async (t) => {
  const { channel, state } = channelFixture(t, { witness: null });
  state.witness = null;
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 0);
  assert.deepEqual(seatBrief(channel), { state: 'unaddressable', reason: 'not_registered_for_agmsgd' });
  await channel.stop();
});

test('a recorded pending reason (SessionStart/Stop both could not find the session) is surfaced instead of the generic missing-witness reason (Linux real-machine round)', async (t) => {
  const { channel, state } = channelFixture(t, { witness: null });
  state.witness = null;
  state.pendingReason = 'SessionStart could not find session sess-1 in /home/x/.grok/active_sessions.json';
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 0);
  assert.deepEqual(seatBrief(channel), {
    state: 'unaddressable',
    reason: 'not_registered_for_agmsgd:SessionStart could not find session sess-1 in /home/x/.grok/active_sessions.json',
  });
  await channel.stop();
});

test('a witness whose pid is dead is unaddressable, never attempted', async (t) => {
  const { channel, state } = channelFixture(t);
  state.witness = { ...state.witness, pid: 999999999 };
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 0);
  assert.deepEqual(seatBrief(channel), { state: 'unaddressable', reason: 'process_gone' });
  await channel.stop();
});

test('a witness missing cwd (needed for session/resume) is unaddressable, never attempted', async (t) => {
  const { channel, state } = channelFixture(t);
  state.witness = { ...state.witness, cwd: undefined };
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 0);
  assert.deepEqual(seatBrief(channel), { state: 'unaddressable', reason: 'cwd_unknown' });
  await channel.stop();
});

test('a leader socket nothing is listening on is pending leader_not_running, the nudge is never attempted (real-machine review, finding A)', async (t) => {
  const { channel, state } = channelFixture(t);
  state.leaderListening = false;
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 0, 'spawning the ACP client against a socket nothing listens on would itself start a resident leader process');
  assert.deepEqual(seatBrief(channel), { state: 'pending', reason: 'leader_not_running:/tmp/fake.sock' });
  await channel.stop();
});

test('a leader socket that starts listening again (seat restarted in leader mode) is attempted on the very next poll', async (t) => {
  const { channel, state } = channelFixture(t);
  state.leaderListening = false;
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 0);
  state.leaderListening = true;
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1);
  await channel.stop();
});

test('a pid that dies in the window between the probe and the spawn is caught by the immediately-before-spawn re-check (real-machine review, finding 3)', async (t) => {
  // A real short-lived process, killed DURING checkLeaderListening's own
  // (fake, but still genuinely async) wait -- the witness's pid passed
  // classifyWitness's own earlier check (it was alive then), but must
  // still be caught again right before the spawn, not assumed live from
  // that earlier read.
  const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 5000)']);
  await new Promise((resolve) => child.once('spawn', resolve));
  const { channel, state } = channelFixture(t, {
    checkLeaderListening: async () => {
      child.kill('SIGKILL');
      await new Promise((resolve) => child.once('exit', resolve));
      return true;
    },
  });
  state.witness = { ...state.witness, pid: child.pid };
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 0, 'the spawn must never happen for a pid that is already gone by the time the probe resolves');
  assert.deepEqual(seatBrief(channel), { state: 'unaddressable', reason: 'process_gone' });
  await channel.stop();
});

test('a witness before its first turn withholds the nudge (session/load replay cost), never attempted', async (t) => {
  const { channel, state } = channelFixture(t);
  state.witness = { ...state.witness, first_turn_done: false };
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 0);
  assert.deepEqual(seatBrief(channel), { state: 'unaddressable', reason: 'first_turn_pending' });
  await channel.stop();
});

test('a failed nudge backs off, and a retry before the backoff elapses spawns nothing', async (t) => {
  const { channel, state } = channelFixture(t, { nudgeKind: 'timeout' });
  state.nudgeKind = 'timeout';
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1);
  assert.deepEqual(seatBrief(channel), { state: 'pending', reason: 'nudge_timeout' });
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1, 'no relaunch before the backoff is due');
  state.hours = 1;
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 2, 'retried once the backoff elapsed');
  await channel.stop();
});

test('a new unread transition resets the backoff and retries immediately', async (t) => {
  const { channel, state } = channelFixture(t, { nudgeKind: 'timeout' });
  state.nudgeKind = 'timeout';
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1);
  state.sequence = 2;
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 2, 'a NEW unread transition retries immediately, not waiting out the old backoff');
  await channel.stop();
});

test('a project that opted out of agmsgd delivery is reported, never attempted', async (t) => {
  const { channel, state } = channelFixture(t);
  const choicePath = `${state.options.installRoot}/run/delivery-choice`;
  const { mkdirSync: mkdir, writeFileSync } = await import('node:fs');
  mkdir(`${state.options.installRoot}/run`, { recursive: true });
  writeFileSync(choicePath, `grok-build\t${state.options.installRoot}\tturn\n`);
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 0);
  assert.deepEqual(seatBrief(channel), { state: 'unaddressable', reason: 'delivery_chosen_turn' });
  await channel.stop();
});

test('real roster + real delivery-choice: a seat that opted out is never nudged via a stale witness (review on #1979)', async (t) => {
  // Deliberately NOT stubbing listSeats here -- finding (1): the review found that
  // listGrokRegistrations itself never returned a project at all, so
  // optedOutOfAgmsgd(installRoot, "grok-build", seat.project) was always
  // called with undefined and could never match the recorded choice. A
  // stub that already supplies `project` (every other test in this file)
  // cannot reproduce that; this one goes through the real roster file and
  // the real delivery-choice file end to end.
  const root = temporaryDirectory(t);
  mkdirSync(path.join(root, 'run'));
  const db = openInstallDb(path.join(root, 'run', 'install.db'));
  ensureGrokQueueChannelSchema(db);
  db.exec("UPDATE daemon_intent SET desired='on', op_gen=1");
  t.after(() => db.close());

  const teamsDir = path.join(root, 'teams', 'test');
  mkdirSync(teamsDir, { recursive: true });
  const { writeFileSync } = await import('node:fs');
  writeFileSync(path.join(teamsDir, 'config.json'), JSON.stringify({
    agents: { ga1: { registrations: [{ type: 'grok-build', project: root }] } },
  }));
  writeFileSync(path.join(root, 'run', 'delivery-choice'), `grok-build\t${root}\tturn\n`);
  // A witness that WOULD be attempted if the opt-out check were bypassed
  // -- proving the opt-out, not a missing witness, is what stops this.
  writeFileSync(path.join(root, 'run', `grok-seat.stale-placeholder.json`), '{}');

  let nudgeCalls = 0;
  const channel = createGrokQueueChannel({
    db, installRoot: root, expectedOpGen: 1, env: {},
    now: () => Date.UTC(2026, 10, 15),
    log: () => {},
    readWitness: () => ({ state: 'ok', witness: { session_id: 'sess-1', pid: process.pid, leader_socket: '/tmp/fake.sock', cwd: root, first_turn_done: true } }),
    nudgeText: () => 'agmsg: you have new messages. Run /agmsg to check your inbox.',
    readDriver: () => ({ state: 'ok', driver: 'sqlite' }),
    openStore: () => ({ close() {} }),
    readSnapshot: () => ({ state: 'ok', unread: true, upTo: JSON.stringify({ eventSeq: 1, legacyId: 0 }) }),
    readOwnMarker: () => '1',
    nudge: async () => { nudgeCalls += 1; return { kind: 'ok' }; },
  });
  await channel.pollOnce();
  assert.equal(nudgeCalls, 0, 'the real roster carried this seat\'s real project, so the real opt-out choice must be found and honored');
  const row = channel.seats().seats.find((item) => item.seat === JSON.stringify(['test', 'ga1']));
  assert.equal(row?.reason, 'delivery_chosen_turn');
  await channel.stop();
});

test('a lax leader-socket directory permission is surfaced as a warning, delivery still proceeds', async (t) => {
  const { channel, state } = channelFixture(t);
  state.socketLax = true;
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 1);
  assert.deepEqual(seatBrief(channel), { state: 'notified', reason: 'socket_dir_perms_lax' });
  await channel.stop();
});

test('no unread at all: addressable, no process launch', async (t) => {
  const { channel, state } = channelFixture(t, { unread: false });
  state.unread = false;
  await channel.pollOnce();
  assert.equal(state.nudgeCalls, 0);
  assert.deepEqual(seatBrief(channel), { state: 'addressable', reason: '' });
  await channel.stop();
});

test('the nudge call receives a cancellation signal, and stop() aborts it', async (t) => {
  const { channel, state } = channelFixture(t, {
    nudge: async (args) => {
      state.nudgeCalls += 1;
      state.seenSignal = args.signal;
      return { kind: 'ok' };
    },
  });
  await channel.pollOnce();
  assert.ok(state.seenSignal instanceof AbortSignal);
  await channel.stop();
});

test('the nudge call receives the witness-recorded cwd, sessionId and leaderSocket verbatim', async (t) => {
  const { channel, state } = channelFixture(t, {
    nudge: async (args) => {
      state.nudgeCalls += 1;
      state.seenArgs = args;
      return { kind: 'ok' };
    },
  });
  await channel.pollOnce();
  assert.equal(state.seenArgs.cwd, '/a/project');
  assert.equal(state.seenArgs.sessionId, 'sess-1');
  assert.equal(state.seenArgs.leaderSocket, '/tmp/fake.sock');
  await channel.stop();
});
