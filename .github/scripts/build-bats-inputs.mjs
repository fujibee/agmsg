#!/usr/bin/env node
// Turn strace path lists (trace-filter.awk output) into the bats input table.
//
//   build-bats-inputs.mjs <inputs.tsv>...   > .github/scripts/bats-inputs.tsv
//
// Run from the repository root at the commit the traces were taken from. Each
// input row is "<test>\tF|D\t<exe>\t<path>" (see trace-filter.awk); a path is mapped to the tracked file it
// names by its longest trailing run of path parts (tests copy scripts/ into a
// temporary directory, so only the tail is stable). A path that maps to no
// tracked file is dropped.
//
// Output rows (tab separated, sorted):
//   U <path>               touched by at least UNIVERSAL of the tests: a change
//                          here runs every test
//   C <test>               the test runs install.sh / uninstall.sh / setup.sh from
//                          the repository, which copies the runtime tree
//   F <test> <path>        a file the test opened, executed, stat'ed or probed
//   D <test> <dir>         a directory the test listed or globbed: a file added
//                          to or removed from it runs the test
//   M <test>               the test was also traced on macOS (eslogger, see
//                          mac-trace-filter.mjs) with no sign of lost events, so
//                          its macOS branches have been observed; a test without
//                          this row is never skipped on account of a platform
//                          branch it reads
//   H <path> <blob>        the git blob id of every file named above (and of each
//                          test file) at the traced commit; the selector treats
//                          a file whose blob has since changed as one whose
//                          dependencies are no longer what was traced
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const UNIVERSAL = 0.9;
const tracked = execFileSync('git', ['ls-files', '-z'], { encoding: 'utf8', maxBuffer: 1 << 26 }).split('\0').filter(Boolean);
const trackedSet = new Set(tracked);
const dirSet = new Set();
for (const p of tracked) { const a = p.split('/'); for (let i = 1; i < a.length; i++) dirSet.add(a.slice(0, i).join('/')); }

const memo = new Map();
const mapPath = (raw, wantDir) => {
  const key = (wantDir ? 'D' : 'F') + raw;
  if (memo.has(key)) return memo.get(key);
  const parts = raw.split('/').filter((x) => x && x !== '.' && x !== '..');
  let hit = '';
  for (let i = 0; i < parts.length; i++) {
    const cand = parts.slice(i).join('/');
    if (parts.length - i < 2 && !(i === parts.length - 1 && !cand.includes('/') && trackedSet.has(cand) && !/^\./.test(cand))) continue;
    if (wantDir ? dirSet.has(cand) : trackedSet.has(cand)) { hit = cand; break; }
  }
  memo.set(key, hit);
  return hit;
};

// Every test's setup copies scripts/ into a temporary skill directory with cp,
// which opens every script whether the test uses it or not. Counting those
// reads would make every test an input-reader of every script, so reads of
// scripts/ made by cp are not inputs. What the test then runs out of the copy is
// seen through the program that opens it, and is.
const COPIERS = new Set(['cp', 'rsync', 'tar', 'ditto']);
const mac = new Set();   // tests with a clean macOS trace
const bad = new Set();   // tests whose macOS trace cannot be trusted
const files = new Map(); // test -> Set(path)
const dirs = new Map();  // test -> Set(dir)
const copies = new Set();
for (const f of process.argv.slice(2)) {
  const isMac = /(^|\/)inputs-mac-/.test(f);
  for (const line of readFileSync(f, 'utf8').split('\n')) {
    const [t, kind, exe, raw] = line.split('\t');
    if (t === 'X') { bad.add(kind); continue; }
    if (!t || !raw) continue;
    if (isMac) mac.add(t);
    if (!files.has(t)) { files.set(t, new Set()); dirs.set(t, new Set()); }
    if (kind === 'D') {
      const d = mapPath(raw, true);
      if (d && !(COPIERS.has(exe) && /^(scripts|templates)(\/|$)/.test(d))) dirs.get(t).add(d);
      continue;
    }
    const p = mapPath(raw, false);
    if (!p) continue;
    if (COPIERS.has(exe) && (p.startsWith('scripts/') || p.startsWith('templates/'))) continue;
    files.get(t).add(p);
    if (/^(install|uninstall|setup)\.sh$/.test(p) && !COPIERS.has(exe)) copies.add(t);
  }
}

const tests = [...files.keys()].sort();
const count = new Map();
for (const t of tests) for (const p of files.get(t)) count.set(p, (count.get(p) || 0) + 1);
const universal = new Set([...count].filter(([, n]) => n >= UNIVERSAL * tests.length).map(([p]) => p));
const out = [];
for (const p of universal) out.push(`U\t${p}`);
for (const t of tests) {
  if (mac.has(t) && !bad.has(t)) out.push(`M\t${t}`);
  if (copies.has(t)) out.push(`C\t${t}`);
  for (const p of files.get(t)) if (!universal.has(p) && p !== t) out.push(`F\t${t}\t${p}`);
  for (const d of dirs.get(t)) out.push(`D\t${t}\t${d}`);
}
const blobs = new Map();
for (const e of execFileSync('git', ['ls-files', '-s', '-z'], { encoding: 'utf8', maxBuffer: 1 << 26 }).split('\0').filter(Boolean)) {
  const tab = e.indexOf('\t');
  blobs.set(e.slice(tab + 1), e.slice(0, tab).split(' ')[1]);
}
const hashed = new Set(tests);
for (const t of tests) for (const p of files.get(t)) hashed.add(p);
for (const p of universal) hashed.add(p);
for (const p of hashed) if (blobs.has(p)) out.push(`H\t${p}\t${blobs.get(p)}`);
process.stdout.write(`# generated by build-bats-inputs.mjs from ${tests.length} traced test files\n`);
process.stdout.write(out.sort().join('\n') + '\n');
