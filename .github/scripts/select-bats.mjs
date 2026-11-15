#!/usr/bin/env node
// Decide which tests/*.bats files a pull request can skip.
//
//   select-bats.mjs --changed FILE [--map TSV] [--root DIR]   print files to SKIP
//   select-bats.mjs --explain FILE [--map TSV] [--root DIR]   say why each one runs
//
// FILE holds the changed paths, one per line (git diff --name-only). The map is
// .github/scripts/bats-inputs.tsv, built from a trace of every test file by
// build-bats-inputs.mjs: per test, the repository files it opened, executed or
// probed ("F"), and the directories it listed ("D"). A test is skipped only
// when none of the changed paths is one of its inputs.
//
// The selection only ever leans toward running more. Every one of these runs
// the whole suite (nothing is printed):
//   - the map is missing, unreadable, or lists no tests;
//   - a changed path is under .github/ (the CI definition and this tool);
//   - a changed path is touched by nearly every test (the "U" rows);
//   - a changed path is not a tracked file at the head (a deletion, or the old
//     side of a rename);
//   - a changed path is a tracked file the map does not know and that is not
//     plainly outside the suite (app/, server/, docs/, site/, *.md): a new or
//     never-exercised file is treated as an input of everything.
// The table was traced at one commit, on Linux. A test that is itself, or reads
// a file that is, changed since the trace (blob differs from the "H" row, or no
// row), gone, unreadable, or branching on the platform (Darwin, uname, OSTYPE)
// is not skipped: its dependencies cannot be established from the trace, and
// unknown means run. Regenerating the table (bats-trace.yml) makes the changed
// ones skippable again.
//
// A test file that is itself in the diff always runs. Any error exits non-zero
// with no output, and the caller runs everything.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const OUTSIDE = [/^app\//, /^server\//, /^docs\//, /^site\//, /\.md$/, /^llms(-full)?\.txt$/, /^LICENSE$/];
const ALWAYS_ALL = [/^\.github\//];
// A test that ran install.sh / uninstall.sh / setup.sh from the repository
// copies the whole runtime tree (the traced `cp` is ignored, see
// build-bats-inputs.mjs), so these paths are inputs of every such test.
const COPIED = [/^scripts\//, /^templates\//, /^SKILL\.md$/, /^VERSION$/, /^openai\.yaml$/, /^plugins\//, /^\.claude-plugin\//];

function args(argv) {
  const o = { root: process.cwd(), map: '', mode: '', file: '' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--root') o.root = argv[++i];
    else if (a === '--map') o.map = argv[++i];
    else if (a === '--changed' || a === '--explain') { o.mode = a.slice(2); o.file = argv[++i]; }
    else throw new Error(`unknown argument: ${a}`);
  }
  if (!o.mode) throw new Error('usage: select-bats.mjs --changed FILE | --explain FILE [--map TSV] [--root DIR]');
  if (!o.map) o.map = join(o.root, '.github/scripts/bats-inputs.tsv');
  return o;
}

function main() {
  const o = args(process.argv.slice(2));
  const explain = o.mode === 'explain';
  const cur = new Map(); // tracked path -> blob id at the head
  for (const e of execFileSync('git', ['-C', o.root, 'ls-files', '-s', '-z'], { encoding: 'utf8', maxBuffer: 1 << 26 }).split('\0').filter(Boolean)) {
    const tab = e.indexOf('\t');
    cur.set(e.slice(tab + 1), e.slice(0, tab).split(' ')[1]);
  }
  const tracked = [...cur.keys()];
  const trackedSet = new Set(tracked);
  const tests = tracked.filter((p) => /^tests\/[^/]+\.bats$/.test(p)).sort();
  if (tests.length === 0) throw new Error('no tests/*.bats found');

  const universal = new Set();
  const files = new Map(); // test -> Set(path)
  const dirs = new Map();  // test -> [dir]
  const known = new Set(); // every path some test touches
  const mapped = new Set();
  const traced = new Map(); // path -> blob id when traced
  for (const line of readFileSync(o.map, 'utf8').split('\n')) {
    if (!line || line.startsWith('#')) continue;
    const c = line.split('\t');
    if (c[0] === 'U' && c.length === 2) { universal.add(c[1]); known.add(c[1]); }
    else if (c[0] === 'F' && c.length === 3) {
      mapped.add(c[1]);
      if (!files.has(c[1])) files.set(c[1], new Set());
      files.get(c[1]).add(c[2]); known.add(c[2]);
    } else if (c[0] === 'D' && c.length === 3) {
      mapped.add(c[1]);
      if (!dirs.has(c[1])) dirs.set(c[1], []);
      dirs.get(c[1]).push(c[2]);
    } else if (c[0] === 'H' && c.length === 3) {
      traced.set(c[1], c[2]);
    } else if (c[0] === 'C' && c.length === 2) {
      mapped.add(c[1]);
      if (!files.has(c[1])) files.set(c[1], new Set());
      files.get(c[1]).add('\0copied');
    }
  }
  if (mapped.size === 0) throw new Error('the input map lists no tests');

  const changed = readFileSync(o.file, 'utf8').split('\n').map((s) => s.trim()).filter(Boolean);
  if (changed.length === 0) throw new Error('empty changed list');

  const everything = (why) => { if (explain) process.stdout.write(`RUN-ALL\t${why}\n`); };
  for (const c of changed) {
    if (ALWAYS_ALL.some((re) => re.test(c))) return everything(`${c} is part of the CI definition`);
    if (!trackedSet.has(c)) return everything(`${c} is not a tracked file at the head (deleted or renamed)`);
    if (universal.has(c)) return everything(`${c} is read by nearly every test`);
    if (!known.has(c) && !OUTSIDE.some((re) => re.test(c)) && !/^tests\/[^/]+\.bats$/.test(c)) {
      // A tracked file nobody was seen touching. Unless a listing of its
      // directory accounts for it (checked per test below), assume it matters.
      const listed = [...dirs.values()].some((ds) => ds.some((d) => c.startsWith(`${d}/`)));
      if (!listed) return everything(`${c} is not in the input map`);
    }
  }

  // A file the table cannot vouch for makes every test that reads it (or is it)
  // run. Either its content changed since the trace (blob differs, no row, gone,
  // unreadable), or it branches on the platform (Darwin, uname, OSTYPE): the
  // trace is Linux only, so what a macOS branch reads was never observed, and a
  // path built at run time cannot be recovered from the text. Unknown means run.
  const untrusted = new Map();
  const isUntrusted = (p) => {
    if (untrusted.has(p)) return untrusted.get(p);
    let bad = false;
    if (p === '\0copied') bad = false;
    else if (!cur.has(p) || traced.get(p) !== cur.get(p)) bad = true;
    else {
      try { bad = /\b(Darwin|darwin|uname|OSTYPE)\b/.test(readFileSync(join(o.root, p), 'utf8')); } catch { bad = true; }
    }
    untrusted.set(p, bad);
    return bad;
  };

  const skip = [];
  for (const t of tests) {
    let why = '';
    if (!mapped.has(t)) why = 'is not in the input map';
    else if (changed.includes(t)) why = 'is itself changed';
    else if (isUntrusted(t) || [...(files.get(t) || [])].some(isUntrusted)) why = 'itself or a file it reads changed since the table was traced, or branches on the platform';
    else {
      const f = files.get(t) || new Set();
      if (files.has(t) && files.get(t).has('\0copied')) f.add('\0copied');
      const d = dirs.get(t) || [];
      for (const c of changed) {
        if (f.has(c)) { why = `reads ${c}`; break; }
        if (f.has('\0copied') && COPIED.some((re) => re.test(c))) { why = `installs from the repository, which includes ${c}`; break; }
        if (d.some((x) => c.startsWith(`${x}/`))) { why = `lists the directory of ${c}`; break; }
      }
    }
    if (why) { if (explain) process.stdout.write(`run\t${t}\t${why}\n`); }
    else { skip.push(t); process.stdout.write(explain ? `skip\t${t}\n` : `${t}\n`); }
  }
}

try { main(); } catch (e) { process.stderr.write(`select-bats: ${e.message}\n`); process.exit(2); }
