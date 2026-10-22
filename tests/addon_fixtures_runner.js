'use strict';
// Runs the shared install fixtures (app/addon-kit/fixtures/install-cases.json)
// through `npx agmsg addon check`. The app's Rust installer runs the same file
// (src-tauri/src/addons/install), so both refuse exactly the same things.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { collect, LIMITS } = require('../bin/addon.js');

const corpus = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'app', 'addon-kit', 'fixtures', 'install-cases.json'), 'utf8'));
let failed = 0;
let n = 0;

function materialize(entries) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'addon-fixture-'));
  for (const e of entries) {
    const abs = path.join(root, e.path);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    if (e.type === 'file') {
      if (e.size !== undefined) fs.writeFileSync(abs, Buffer.alloc(e.size, 0x61));
      else fs.writeFileSync(abs, e.text || '');
    } else if (e.type === 'symlink') fs.symlinkSync(e.target, abs);
    else if (e.type === 'hardlink') fs.linkSync(path.join(root, e.of), abs);
    else throw new Error('unsupported fixture entry type ' + e.type);
  }
  return root;
}

for (const c of corpus.cases) {
  if (c.archiveOnly) continue;
  n++;
  const root = materialize(c.entries);
  const limits = Object.assign({}, LIMITS, c.limits || {});
  const r = collect(root, limits);
  const got = r.errors.slice().sort();
  const want = c.expect.errors.slice().sort();
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'ok ' : 'not ok ') + n + ' - ' + c.name);
  if (!ok) {
    failed++;
    console.log('# want: ' + JSON.stringify(want));
    console.log('# got:  ' + JSON.stringify(got));
  }
  fs.rmSync(root, { recursive: true, force: true });
}
console.log('1..' + n);
process.exit(failed ? 1 : 0);
