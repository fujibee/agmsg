#!/usr/bin/env node
// Decide whether a pull request needs the macOS legs of the bats suite.
//
//   mac-needed.mjs --changed FILE --diff FILE [--patterns TSV]
//
// FILE (--changed) lists the changed paths, one per line; --diff is the unified
// diff (git diff -U0 base...head). Prints "true <reason>" or "false". macOS is
// needed when the change can behave differently on BSD userlands or on macOS:
//   - anything under .github/ (the CI definition), scripts/lib/compat.sh, an
//     installer (install.sh, uninstall.sh, setup.sh), the daemon, a file or test
//     named for launchd / macOS / Darwin;
//   - an ADDED line in a .sh/.bash/.bats/.mjs file that matches a row of
//     mac-patterns.tsv (GNU/BSD command differences and platform words).
// Every doubt answers true: an error exits non-zero with no output, and the
// workflow treats that as "needed". Pushes to main and release PRs never ask;
// they run macOS in full.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

function args(argv) {
  const o = { changed: '', diff: '', patterns: join(here, 'mac-patterns.tsv') };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--changed') o.changed = argv[++i];
    else if (argv[i] === '--diff') o.diff = argv[++i];
    else if (argv[i] === '--patterns') o.patterns = argv[++i];
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  if (!o.changed || !o.diff) throw new Error('usage: mac-needed.mjs --changed FILE --diff FILE [--patterns TSV]');
  return o;
}

const PATHS = [
  [/^\.github\//, 'CI definition'],
  [/^scripts\/lib\/compat\.sh$/, 'scripts/lib/compat.sh'],
  [/^(install|uninstall|setup)\.sh$/, 'installer'],
  [/^scripts\/daemon(\.sh|\/)/, 'daemon'],
  [/(launchd|launchctl|macos|darwin)/i, 'named for macOS'],
];
const CODE = /\.(sh|bash|bats|mjs)$/;

function main() {
  const o = args(process.argv.slice(2));
  const changed = readFileSync(o.changed, 'utf8').split('\n').map((s) => s.trim()).filter(Boolean);
  if (changed.length === 0) throw new Error('empty changed list');
  const diff = readFileSync(o.diff, 'utf8');
  if (diff.trim() === '') throw new Error('empty diff');
  const pats = [];
  for (const line of readFileSync(o.patterns, 'utf8').split('\n')) {
    if (!line || line.startsWith('#')) continue;
    const tab = line.indexOf('\t');
    if (tab < 1) throw new Error(`bad pattern row: ${line}`);
    pats.push([line.slice(0, tab), new RegExp(line.slice(tab + 1))]);
  }
  if (pats.length === 0) throw new Error('no patterns');

  for (const c of changed) {
    for (const [re, why] of PATHS) if (re.test(c)) return `true ${c}: ${why}`;
  }
  let file = '';
  for (const line of diff.split('\n')) {
    if (line.startsWith('+++ ')) { file = line.slice(4).replace(/^b\//, ''); continue; }
    if (!line.startsWith('+') || line.startsWith('+++')) continue;
    if (!CODE.test(file)) continue;
    const text = line.slice(1);
    for (const [name, re] of pats) if (re.test(text)) return `true ${file}: added line matches ${name}`;
  }
  return 'false no macOS-sensitive path or added line';
}

try { process.stdout.write(`${main()}\n`); } catch (e) { process.stderr.write(`mac-needed: ${e.message}\n`); process.exit(2); }
