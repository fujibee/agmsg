import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  observeTranscript,
  resolvePendingDelivery,
  QUEUE_CONFIRMATION_TTL_MS,
} from '../scripts/daemon/channels/claude-code-queue-io.mjs';

function temporaryDirectory(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'agmsg-cc-queue-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

// Load-bearing property: a `queue-operation`/`enqueue` line fires on mere
// receipt, Held or not, so it must NEVER by itself cause a seat to be marked
// delivered -- never notify on evidence that could just as well be a hold.
// Only the `type:"user"` line whose `origin.body` carries the nonce counts.
// This reproduces both line shapes measured against a live Claude Code
// transcript in one file and asserts the queue-operation line alone is not
// enough, while the user/origin.body line is.
test('observeTranscript: a queue-operation enqueue line is not delivery evidence; only the user/origin.body line is', (t) => {
  const dir = temporaryDirectory(t);
  const transcriptPath = path.join(dir, 'session.jsonl');
  const nonce = 'abc123-test-nonce';
  const marker = `[agmsg:${nonce}] New messages are waiting. Check your agmsg inbox.`;

  // Only the enqueue line present (held, or not yet acted on) — must read as
  // absent, not delivered.
  writeFileSync(transcriptPath, `${JSON.stringify({
    type: 'queue-operation',
    operation: 'enqueue',
    content: `<cross-session-message from="agmsgd">${marker}</cross-session-message>`,
  })}\n`);
  let observation = observeTranscript(transcriptPath, nonce);
  assert.equal(observation.state, 'absent');
  let resolved = resolvePendingDelivery({ observation, ageMs: 1000, ttlMs: QUEUE_CONFIRMATION_TTL_MS });
  assert.equal(resolved.state, 'pending');

  // The real delivered record appended afterward (as the genuine sequence
  // measured: enqueue first, then the delivered user line) — now it must
  // read as delivered/confirmed.
  writeFileSync(transcriptPath, `${JSON.stringify({
    type: 'queue-operation',
    operation: 'enqueue',
    content: `<cross-session-message from="agmsgd">${marker}</cross-session-message>`,
  })}\n${JSON.stringify({
    type: 'user',
    isMeta: true,
    message: { role: 'user', content: 'Another Claude session sent a message...' },
    origin: { kind: 'peer', from: 'agmsgd', verifiedPeerPid: 12345, name: 'agmsgd', fromMode: 'bypass', body: marker },
  })}\n`);
  observation = observeTranscript(transcriptPath, nonce);
  assert.equal(observation.state, 'delivered');
  resolved = resolvePendingDelivery({ observation, ageMs: 1000, ttlMs: QUEUE_CONFIRMATION_TTL_MS });
  assert.equal(resolved.state, 'confirmed');
});

// #1577 review: a transcript that is genuinely missing (its session/project
// no longer has a live file to write to) must eventually expire with a
// reason, not poll forever -- but a transcript that merely failed to read
// (a transient fs error) must stay pending indefinitely, since that one
// really could resolve on the next read. Distinguishing these two is the
// property this test pins.
test('resolvePendingDelivery: a missing transcript expires at the TTL; a read failure never does', () => {
  const missing = { state: 'unreadable', reason: 'transcript_missing' };
  const readFailed = { state: 'unreadable', reason: 'transcript_read_failed' };

  const missingBeforeTtl = resolvePendingDelivery({ observation: missing, ageMs: 1000, ttlMs: QUEUE_CONFIRMATION_TTL_MS });
  assert.equal(missingBeforeTtl.state, 'pending');
  const missingAfterTtl = resolvePendingDelivery({ observation: missing, ageMs: QUEUE_CONFIRMATION_TTL_MS + 1, ttlMs: QUEUE_CONFIRMATION_TTL_MS });
  assert.equal(missingAfterTtl.state, 'expired');
  assert.equal(missingAfterTtl.reason, 'transcript_missing');

  const readFailedAfterTtl = resolvePendingDelivery({ observation: readFailed, ageMs: QUEUE_CONFIRMATION_TTL_MS + 1, ttlMs: QUEUE_CONFIRMATION_TTL_MS });
  assert.equal(readFailedAfterTtl.state, 'pending');
});
