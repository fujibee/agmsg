// Shared seat deadlines and delivery observations. Only channel metadata is
// inspected: message bodies, socket tokens and transcript contents stay out.
import { assertPollActive, pollSignal, withDeadline, SEAT_DEADLINE_MS, PollDeadlineError } from './poll-deadline.mjs';
import { deliveryEvent, recordPollTimeout } from './log.mjs';

export function createSeatPoller({ db, installRoot, channel, saveTimeout, log, timeoutMs = SEAT_DEADLINE_MS }) {
  const prefix = channel === 'codex' ? 'beta_codex' : 'beta_claude';
  let current;
  let cancelled = false;
  const lifetime = new AbortController();
  const emit = (event, seat, reason, extra = {}) => deliveryEvent(log, { event, channel, seat, reason, ...extra });
  function snapshot(seat, before) {
    const state = db.prepare(`SELECT state, reason FROM ${prefix}_seat WHERE seat=?`).get(seat);
    if (before) return {
      state,
      rows: db.prepare(`SELECT * FROM ${prefix}_queue WHERE seat=? AND (id>? OR id=?)`).all(seat, before.lastId, before.rows[0]?.id ?? -1),
    };
    return {
      state,
      lastId: db.prepare(`SELECT id FROM ${prefix}_queue WHERE seat=? ORDER BY id DESC LIMIT 1`).get(seat)?.id ?? 0,
      rows: db.prepare(`SELECT id, state FROM ${prefix}_queue WHERE seat=? AND state='pending'`).all(seat),
    };
  }
  function observe(seat, before, completed) {
    const after = snapshot(seat, before);
    if (after.state && (before.state?.state !== after.state.state || before.state?.reason !== after.state.reason)) {
      emit('seat_state', seat, after.state.reason, { state: after.state.state });
    }
    for (const row of after.rows) {
      const old = before.rows.find(item => item.id === row.id);
      let children;
      try { children = JSON.parse(row.children); } catch { /* Claude has no children field */ }
      if (!old && completed && (channel === 'codex' ? row.queue_item_id || children?.result === 'queued' : row.state !== 'expired')) {
        emit('sent', seat, 'accepted', { cursor: row.up_to });
      }
      if (row.state === 'expired' && old?.state !== 'expired') {
        emit('expired', seat, children?.expiration_reason || after.state?.reason || 'attempt_expired');
      }
      if (!old && (children?.result && children.result !== 'queued' || row.state === 'expired' && !children)) {
        emit('failed', seat, children?.result_reason || children?.reason || after.state?.reason || 'delivery_failed');
      }
    }
  }
  function changeState(seat, work) {
    const before = db.prepare(`SELECT state, reason FROM ${prefix}_seat WHERE seat=?`).get(seat);
    work();
    const after = db.prepare(`SELECT state, reason FROM ${prefix}_seat WHERE seat=?`).get(seat);
    if (after && (before?.state !== after.state || before?.reason !== after.reason)) emit('seat_state', seat, after.reason, { state: after.state });
  }
  function reportTimeout(reason) {
    if (!current) return;
    const seat = current;
    changeState(seat, () => saveTimeout(seat, reason));
    emit('poll_timeout', seat, reason);
    recordPollTimeout(installRoot, { channel, seat, reason });
    current = undefined;
    return seat;
  }
  return {
    reportTimeout,
    changeState,
    cancel() { cancelled = true; lifetime.abort(new PollDeadlineError('channel_stopping')); },
    async poll(registration, work) {
      assertPollActive();
      const seat = JSON.stringify([registration.team, registration.agent]);
      const before = snapshot(seat);
      current = seat;
      let completed = false;
      let reported = false;
      try {
        const parent = pollSignal();
        const signal = parent ? AbortSignal.any([parent, lifetime.signal]) : lifetime.signal;
        await withDeadline(work, { timeoutMs, signal, reason: 'seat_poll_deadline' });
        completed = true;
      } catch (error) {
        if (cancelled) return;
        if (pollSignal()?.aborted) throw error;
        if (error.name !== 'PollDeadlineError') throw error;
        reportTimeout(error.message);
        reported = true;
      } finally {
        if (!reported && !cancelled && !pollSignal()?.aborted) observe(seat, before, completed);
        if (!pollSignal()?.aborted) current = undefined;
      }
    },
  };
}
