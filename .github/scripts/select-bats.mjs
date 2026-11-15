#!/usr/bin/env node
// Decide which tests/*.bats files a pull request can skip.
//
//   select-bats.mjs [--root DIR] --changed FILE      print the files to SKIP
//   select-bats.mjs [--root DIR] --explain FILE      print, per test, why it runs
//   select-bats.mjs [--root DIR] --dump              print test -> input closure
//
// FILE holds the changed paths, one per line (git diff --name-only).
//
// A test file runs unless EVERY changed path is outside its inputs. Its inputs
// are found from the tree itself, not from a table someone has to keep up to
// date: starting from the test file, follow every tracked file it names (a full
// or partial path, or the base name of a file with an extension, in the file's
// text), then everything those files name, and so on. A directory named with at
// least two path parts (scripts/lib/, scripts/drivers/terminals) pulls in its
// whole subtree, because such a name is usually a prefix for a computed file
// name. The helper every test loads is followed the same way, so a change under
// the helpers or the libraries it names runs everything that loads them.
//
// The selection only ever leans toward running more:
//   - a changed path that is not a tracked file at the head (a deletion or a
//     rename's old side) runs every test;
//   - a changed path under .github/ or any other file the graph does not
//     place outside the suite's reach runs every test (see ALWAYS_ALL);
//   - a test whose text reads the repository wholesale (git ls-files, a
//     recursive grep, a find rooted in the repository) is an "all inputs"
//     test and runs for any change;
//   - any error (unreadable file, no git, bad arguments) exits non-zero with
//     no output, and the caller runs everything.
//
// Over-approximating an edge only costs a test that did not need to run; it
// never skips one. Under-approximating is the failure to guard against, so the
// scan is deliberately generous (base names, comments and strings count).

import { execFileSync } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

// Paths whose change always runs the whole suite: the CI definition itself and
// the helpers that decide what runs.
const ALWAYS_ALL = [/^\.github\//, /^package(-lock)?\.json$/, /^\.bats/, /^bats\//];

// A test that reads the repository as a whole cannot be bounded by naming.
const WHOLE_TREE = [
  /git\s+(-C\s+\S+\s+)?ls-files/,
  /git\s+(-C\s+\S+\s+)?(diff|log|grep|rev-parse)/,
  /grep\s+-[A-Za-z]*[rR]/,
  /\brg\b/,
  /find\s+["']?\$?\{?(BATS_TEST_DIRNAME|REPO_ROOT|ROOT|REPO|SRC)\b/,
];

function parseArgs(argv) {
  const o = { root: process.cwd(), mode: '', file: '' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--root') o.root = argv[++i];
    else if (a === '--changed' || a === '--explain') { o.mode = a.slice(2); o.file = argv[++i]; }
    else if (a === '--dump') o.mode = 'dump';
    else if (a === '--big') { o.mode = 'big'; o.file = argv[++i]; }
    else if (a === '--edges') { o.mode = 'edges'; o.file = argv[++i]; }
    else throw new Error(`unknown argument: ${a}`);
  }
  if (!o.mode) throw new Error('usage: select-bats.mjs [--root DIR] --changed FILE | --explain FILE | --dump');
  return o;
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  const tracked = execFileSync('git', ['-C', o.root, 'ls-files', '-z'], { encoding: 'utf8', maxBuffer: 1 << 26 })
    .split('\0').filter(Boolean);
  const trackedSet = new Set(tracked);
  const tests = tracked.filter((p) => /^tests\/[^/]+\.bats$/.test(p)).sort();
  if (tests.length === 0) throw new Error('no tests/*.bats found');

  // Lookup tables: full path, trailing path parts, base name; directories.
  const bySuffix = new Map();
  const dirs = new Map();
  const add = (m, k, v) => { if (!m.has(k)) m.set(k, []); m.get(k).push(v); };
  for (const p of tracked) {
    const parts = p.split('/');
    for (let i = 0; i < parts.length; i++) add(bySuffix, parts.slice(i).join('/'), p);
    for (let i = 2; i < parts.length; i++) add(dirs, parts.slice(0, i).join('/'), p);
  }
  // A directory with 2+ path parts also matches by its trailing parts, so
  // scripts/drivers/terminals named as drivers/terminals still lands.
  const dirSuffix = new Map();
  for (const [d, files] of dirs) {
    const parts = d.split('/');
    for (let i = 0; i < parts.length; i++) add(dirSuffix, parts.slice(i).join('/'), files);
  }

  const textCache = new Map();
  const readText = (p) => {
    if (textCache.has(p)) return textCache.get(p);
    let t = '';
    try {
      const abs = join(o.root, p);
      const st = statSync(abs);
      if (st.isFile() && st.size <= 2_000_000) {
        const buf = readFileSync(abs);
        if (!buf.includes(0)) t = buf.toString('utf8');
      }
    } catch { /* a missing or unreadable file contributes no edges */ }
    textCache.set(p, t);
    return t;
  };

  const edgeCache = new Map();
  const edges = (p) => {
    if (edgeCache.has(p)) return edgeCache.get(p);
    const out = new Set();
    // Documents and data are leaves: a README that names a script does not
    // make a test depend on that script through it. Code files (and the
    // extensionless launchers under scripts/) are followed.
    if (!/\.(sh|bash|bats|mjs|js|cjs|ts|py|awk)$/.test(p) && !(p.startsWith('scripts/') && !/\.[A-Za-z0-9]+$/.test(p))) {
      edgeCache.set(p, out);
      return out;
    }
    // Whole-line comments name files without running them; drop them.
    const text = readText(p).split('\n').filter((l) => !/^\s*(#|\/\/)/.test(l)).map((l) => l.replace(/\s#\s.*$/, '')).join('\n');
    // In a test file any mention counts. In a script or library a bare name
    // ("see delivery.sh", a case pattern on $0) is prose or a match, not a
    // call: only a path-qualified token ("$DIR/delivery.sh") counts there.
    const isTest = p.startsWith('tests/');
    for (const raw of text.match(/[A-Za-z0-9_.\/-]{3,}/g) || []) {
      if (!isTest && !raw.includes('/')) continue;
      let tok = raw.replace(/^(\.\.?\/)+/, '').replace(/^\/+/, '');
      const isDirTok = tok.endsWith('/');
      tok = tok.replace(/\/+$/, '').replace(/\/\.$/, '');
      if (!tok) continue;
      const hit = bySuffix.get(tok);
      if (hit && !isDirTok) for (const f of hit) out.add(f);
      const base = tok.split('/').pop();
      if (/\.[A-Za-z0-9]+$/.test(base)) {
        const b = bySuffix.get(base);
        if (b) for (const f of b) out.add(f);
      }
      if (isDirTok) {
        // "$base/storage/$name.sh": the leading part is a variable, so try
        // every trailing run of path parts.
        const parts = tok.split('/');
        for (let i = 0; i < parts.length; i++) {
          const d = dirSuffix.get(parts.slice(i).join('/'));
          if (d) for (const files of d) for (const f of files) out.add(f);
        }
      }
    }
    out.delete(p);
    edgeCache.set(p, out);
    return out;
  };

  const closureOf = (seed) => {
    const seen = new Set([seed]);
    const q = [seed];
    while (q.length) {
      const cur = q.pop();
      for (const n of edges(cur)) if (!seen.has(n)) { seen.add(n); q.push(n); }
    }
    return seen;
  };

  const closures = new Map();
  const wholeTree = new Set();
  for (const t of tests) {
    closures.set(t, closureOf(t));
    const own = readText(t);
    if (WHOLE_TREE.some((re) => re.test(own))) wholeTree.add(t);
  }

  if (o.mode === 'big') { const c = closures.get(o.file); const r = [...c].map((f) => [edges(f).size, f]).sort((a, b) => b[0] - a[0]).slice(0, 15); for (const [n, f] of r) process.stdout.write(`${n}\t${f}\n`); return; }
  if (o.mode === "edges") { const p=o.file; const e=[...edges(p)]; process.stdout.write(e.length+"\n"+e.sort().join("\n")+"\n"); return; }
  if (o.mode === "dump") {
    for (const t of tests) {
      const c = [...closures.get(t)].sort();
      process.stdout.write(`${t}\t${wholeTree.has(t) ? 'ALL' : c.length}\n`);
    }
    return;
  }

  const changed = readFileSync(o.file, 'utf8').split('\n').map((s) => s.trim()).filter(Boolean);
  if (changed.length === 0) throw new Error('empty changed list');
  const runAll = (why) => {
    if (o.mode === 'explain') process.stdout.write(`RUN-ALL\t${why}\n`);
    process.exit(0);
  };
  for (const c of changed) {
    if (!trackedSet.has(c)) runAll(`${c} is not a tracked file at the head (deleted or renamed)`);
    if (ALWAYS_ALL.some((re) => re.test(c))) runAll(`${c} is part of the CI definition`);
  }

  const skip = [];
  for (const t of tests) {
    let why = '';
    if (wholeTree.has(t)) why = 'reads the repository wholesale';
    else {
      const c = closures.get(t);
      const hit = changed.find((p) => c.has(p));
      if (hit) why = `inputs include ${hit}`;
    }
    if (why) { if (o.mode === 'explain') process.stdout.write(`run\t${t}\t${why}\n`); }
    else {
      skip.push(t);
      if (o.mode === 'explain') process.stdout.write(`skip\t${t}\n`);
    }
  }
  if (o.mode === 'changed') for (const t of skip) process.stdout.write(`${t}\n`);
}

try { main(); } catch (e) { process.stderr.write(`select-bats: ${e.message}\n`); process.exit(2); }
