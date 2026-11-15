#!/usr/bin/env node
// Reduce an `eslogger` JSON stream to the distinct paths one test's process
// tree looked at, in the same rows trace-filter.awk prints for Linux:
//
//   sudo eslogger exec fork exit open stat access readlink lookup readdir \
//        chdir getattrlist | mac-trace-filter.mjs <test> <out.tsv> <marker-dir>
//
//   <test>\tF|D\t<exe>\t<path>     (D: a directory listing)
//   X\t<test>\t<reason>             attribution is not trustworthy for this test
//
// Attribution is by process tree, not by time. The driver (mac-trace-one.sh)
// brackets the test with three marker files that show up in the stream as
// ordinary open events:
//   <dir>/ready   opened by anything: the tracer is live (answered by <dir>/ack)
//   <dir>/start   opened by the process that then exec's the test: its pid is
//                 the root of the tree
//   <dir>/end     opened after the test returned: stop
// Only events whose process is the root or a descendant of it (by fork event, or
// by parent pid for a child whose fork was missed) are kept, so nothing else
// the machine does is mixed in.
//
// Doubt is reported, never hidden: a gap in eslogger's per-client sequence
// numbers means events were dropped (X), and so does an end of input before the
// end marker.

import { createInterface } from 'node:readline';
import { appendFileSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';

const [test, out, dir] = process.argv.slice(2);
if (!test || !out || !dir) {
  process.stderr.write('usage: mac-trace-filter.mjs <test> <out.tsv> <marker-dir>\n');
  process.exit(2);
}

const tree = new Set();
const seen = new Set();
const rows = [];
let phase = 'wait';      // wait -> run -> done
let lastSeq = null;
let dropped = false;
let touched = 0;

const key = (ev) => Object.keys(ev.event || {})[0] || '';
const pidOf = (p) => (p && p.audit_token && p.audit_token.pid) ?? (p && p.pid);

function pathsOf(type, body) {
  if (!body || typeof body !== 'object') return [];
  if (type === 'lookup') {
    const d = body.source_dir && body.source_dir.path;
    const r = body.relative_target;
    return d && r ? [`${d}/${r}`] : [];
  }
  const found = [];
  const walk = (o, depth) => {
    if (!o || typeof o !== 'object' || depth > 4) return;
    for (const [k, v] of Object.entries(o)) {
      if (k === 'path' && typeof v === 'string') found.push(v);
      else if (v && typeof v === 'object' && k !== 'stat' && k !== 'args' && k !== 'env') walk(v, depth + 1);
    }
  };
  walk(body, 0);
  return found;
}

function emit(kind, exe, p) {
  if (!p) return;
  const k = `${kind}\t${exe}\t${p}`;
  if (seen.has(k)) return;
  seen.add(k);
  rows.push(`${test}\t${kind}\t${exe}\t${p}`);
}

function finish(reason) {
  if (phase === 'done') return;
  phase = 'done';
  if (reason) rows.push(`X\t${test}\t${reason}`);
  if (dropped) rows.push(`X\t${test}\tevents were dropped (sequence gap)`);
  if (touched === 0) rows.push(`X\t${test}\tno event was attributed to the test`);
  appendFileSync(out, rows.join('\n') + (rows.length ? '\n' : ''));
  writeFileSync(`${dir}/done`, 'done\n');
  process.exit(0);
}

const rl = createInterface({ input: process.stdin });
rl.on('line', (line) => {
  if (phase === 'done' || !line) return;
  let ev;
  try { ev = JSON.parse(line); } catch { return; }
  // global_seq_num counts every message the client is delivered, whatever its
  // type (seq_num counts per event type, so it is not consecutive across them).
  // A hole means eslogger dropped messages.
  const seq = ev.global_seq_num;
  if (typeof seq === 'number') {
    if (phase === 'run' && lastSeq !== null && seq !== lastSeq + 1) dropped = true;
    lastSeq = seq;
  }

  const type = key(ev);
  const body = ev.event && ev.event[type];
  const pid = pidOf(ev.process);
  const ppid = ev.process && ev.process.ppid;
  const exe = basename((ev.process && ev.process.executable && ev.process.executable.path) || '-');
  const paths = pathsOf(type, body);

  // Markers travel through the same stream as everything else.
  if (type === 'open' || type === 'lookup' || type === 'stat' || type === 'access' || type === 'getattrlist') {
    for (const p of paths) {
      if (p === `${dir}/ready`) { writeFileSync(`${dir}/ack`, 'ack\n'); return; }
      if (p === `${dir}/start` && phase === 'wait') { tree.add(pid); phase = 'run'; return; }
      if (p === `${dir}/end` && phase === 'run') { finish(''); return; }
    }
  }
  if (phase !== 'run') return;

  if (type === 'fork') {
    const child = pidOf(body && body.child);
    if (tree.has(pid) && child !== undefined) tree.add(child);
    return;
  }
  if (!tree.has(pid)) {
    if (!tree.has(ppid)) return;
    tree.add(pid); // a child whose fork event was not seen
  }
  if (type === 'exit') return;
  touched++;
  if (type === 'exec') {
    const e = body && body.target && body.target.executable && body.target.executable.path;
    emit('F', exe, e);
    return;
  }
  const kind = type === 'readdir' ? 'D' : 'F';
  for (const p of paths) emit(kind, exe, p);
});
rl.on('close', () => finish('input ended before the end marker'));
