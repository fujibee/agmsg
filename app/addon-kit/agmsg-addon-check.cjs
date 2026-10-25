'use strict';
// agmsg-addon-check: check an app add-on repository the way the agmsg app
// checks an install (layout, addon.conf, limits, unsafe entries), so an author
// sees the same refusal before pushing that the app would show after.
//
//   node agmsg-addon-check.cjs [dir]      (dir defaults to the current directory)
//
// It only reads the directory: no network, no install, nothing under the
// agmsg home. The app's Rust installer (src-tauri/src/addons/install) and this
// file run the same fixture corpus (fixtures/install-cases.json), so both
// refuse exactly the same trees with the same words.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const LIMITS = { totalBytes: 200 * 1024 * 1024, files: 5000, fileBytes: 50 * 1024 * 1024 };
const PERMISSIONS = new Set(['messages:read', 'files:read', 'git:read', 'network']);
const KEYS = new Set(['title', 'entry', 'min_app', 'protocol', 'permissions', 'network', 'opens']);
const OPENS = new Set(['path', 'url']);
const NAME_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const RESERVED = /^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$/i;

function mb(n) {
  return (n / (1024 * 1024)).toFixed(1) + ' MB';
}

// ---------- addon.conf ----------

function parseConf(text) {
  const values = {};
  const errors = [];
  text.split(/\r?\n/).forEach((raw, i) => {
    const line = raw.trim();
    if (!line || line.startsWith('#')) return;
    const eq = line.indexOf('=');
    if (eq < 1) {
      errors.push({ line: i + 1, problem: 'expected key = value' });
      return;
    }
    const key = line.slice(0, eq).trim();
    const value = line.slice(eq + 1).replace(/\s+#.*$/, '').trim();
    if (!KEYS.has(key) && !/^why\.[a-z:]+$/.test(key)) {
      errors.push({ line: i + 1, problem: 'unknown key "' + key + '"' });
      return;
    }
    if (Object.prototype.hasOwnProperty.call(values, key)) {
      errors.push({ line: i + 1, problem: 'duplicate key "' + key + '"' });
      return;
    }
    values[key] = { value, line: i + 1 };
  });
  return { values, errors };
}

function list(v) {
  return v ? v.split(',').map((s) => s.trim()).filter(Boolean) : [];
}

function checkConf(confPath, rel) {
  const out = { errors: [], warnings: [], conf: null };
  const { values, errors } = parseConf(fs.readFileSync(confPath, 'utf8'));
  for (const e of errors) out.errors.push(rel + ' line ' + e.line + ': ' + e.problem + '.');
  const at = (k) => rel + ' line ' + values[k].line;

  if (!values.title || !values.title.value) out.errors.push(rel + ': "title" is required.');
  if (!values.protocol) out.errors.push(rel + ': "protocol" is required (protocol = 1).');
  else if (values.protocol.value !== '1') {
    out.errors.push(at('protocol') + ': protocol ' + values.protocol.value + ' is not known to this version (1).');
  }
  if (values.min_app && !/^\d+\.\d+\.\d+$/.test(values.min_app.value)) {
    out.errors.push(at('min_app') + ': min_app must look like 0.6.0.');
  }

  const perms = values.permissions ? list(values.permissions.value) : [];
  for (const p of perms) {
    if (!PERMISSIONS.has(p)) out.errors.push(at('permissions') + ': unknown permission "' + p + '".');
  }
  if (perms.includes('git:read') && !perms.includes('files:read')) {
    out.errors.push(at('permissions') + ': git:read needs files:read too.');
  }
  if (perms.includes('network')) {
    if (!values.network || !values.network.value) {
      out.errors.push(at('permissions') + ': network is declared but "network = *" or a list of origins is missing.');
    } else if (values.network.value !== '*') {
      for (const o of list(values.network.value)) {
        if (!/^https:\/\/[a-z0-9.-]+(:\d{1,5})?$/i.test(o)) {
          out.errors.push(at('network') + ': "' + o + '" is not an origin like https://api.example.com.');
        }
      }
    }
  } else if (values.network) {
    out.errors.push(at('network') + ': "network" is set but the network permission is not declared.');
  }
  for (const p of perms) {
    if (!values['why.' + p] || !values['why.' + p].value) out.warnings.push(rel + ': no "why.' + p + '" line; users see it next to the permission.');
  }
  for (const k of Object.keys(values)) {
    if (k.startsWith('why.') && !perms.includes(k.slice(4))) {
      out.warnings.push(at(k) + ': "' + k + '" is for a permission that is not declared.');
    }
  }
  if (values.opens) {
    for (const o of list(values.opens.value)) {
      if (!OPENS.has(o)) out.errors.push(at('opens') + ': unknown "' + o + '" (path or url).');
    }
  }
  out.conf = {
    entry: (values.entry && values.entry.value) || 'index.html',
    permissions: perms,
    network: values.network ? values.network.value : '',
  };
  return out;
}

// ---------- the tree the app would install ----------

// The app installs the committed tree of one commit, so in a git work tree
// check exactly the tracked files and report web/ files that are not tracked.
function collectFiles(root) {
  try {
    const outp = execFileSync('git', ['-C', root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    const tracked = new Set(
      execFileSync('git', ['-C', root, 'ls-files', '-z'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
        .split('\0').filter(Boolean)
    );
    const all = outp.split('\0').filter(Boolean);
    return { git: true, files: all.filter((f) => tracked.has(f)), untracked: all.filter((f) => !tracked.has(f)) };
  } catch (_) {
    const files = [];
    (function walk(dir) {
      for (const ent of fs.readdirSync(path.join(root, dir), { withFileTypes: true })) {
        if (ent.name === '.git' || ent.name === 'node_modules') continue;
        const rel = dir ? dir + '/' + ent.name : ent.name;
        if (ent.isDirectory()) walk(rel);
        else files.push(rel);
      }
    })('');
    return { git: false, files, untracked: [] };
  }
}

function checkTree(root, files, limits) {
  limits = limits || LIMITS;
  const errors = [];
  let total = 0;
  let largest = { file: '', size: 0 };
  const lower = new Map();
  for (const rel of files) {
    const abs = path.join(root, rel);
    let st;
    try {
      st = fs.lstatSync(abs);
    } catch (_) {
      continue; // deleted in the work tree; git still has it
    }
    if (st.isSymbolicLink()) errors.push('Refused: the repository contains a symbolic link at ' + rel + '. Add-ons may contain only plain files.');
    else if (!st.isFile()) errors.push('Refused: ' + rel + ' is not a plain file.');
    else if (st.nlink > 1) errors.push('Refused: the repository contains a hard link at ' + rel + '. Add-ons may contain only plain files.');
    for (const part of rel.split('/')) {
      if (RESERVED.test(part) || /[. ]$/.test(part) || /[:\\<>|?*"]/.test(part)) {
        errors.push('Refused: the repository contains a reserved file name at ' + rel + '. Add-ons may contain only plain files.');
        break;
      }
    }
    const key = rel.toLowerCase();
    if (lower.has(key)) errors.push('Refused: ' + rel + ' and ' + lower.get(key) + ' differ only in case.');
    lower.set(key, rel);
    total += st.size;
    if (st.size > largest.size) largest = { file: rel, size: st.size };
    if (st.size > limits.fileBytes) errors.push('Too large to install: ' + rel + ' is ' + mb(st.size) + ' (limit ' + mb(limits.fileBytes) + ' per file).');
  }
  if (files.length > limits.files) errors.push('Too large to install: ' + files.length + ' files (limit ' + limits.files + ').');
  if (total > limits.totalBytes) {
    errors.push('Too large to install: ' + mb(total) + ' (limit ' + mb(limits.totalBytes) + '). Largest file: ' + largest.file + ' (' + mb(largest.size) + ').');
  }
  return { errors, total, count: files.length, largest };
}

// What the add-on CSP will block at run time. HTML attributes are certain;
// JavaScript patterns are heuristics (bundled libraries can contain them in
// code paths never taken), so they are warnings.
function scanWeb(root, webFiles, conf) {
  const errors = [];
  const warnings = [];
  const allowed = conf.network === '*' ? null : list(conf.network);
  const external = /\b(?:src|href)\s*=\s*["'](https?:)?\/\/([^"'/]+)/gi;
  for (const rel of webFiles) {
    const ext = path.extname(rel).toLowerCase();
    if (!['.html', '.htm', '.js', '.mjs', '.css'].includes(ext)) continue;
    let text;
    try {
      text = fs.readFileSync(path.join(root, rel), 'utf8');
    } catch (_) {
      continue;
    }
    if (ext === '.html' || ext === '.htm') {
      if (/\son[a-z]+\s*=\s*["']/i.test(text)) errors.push(rel + ': inline event handlers (onclick="…") are blocked; use addEventListener.');
      if (/\b(?:src|href)\s*=\s*["']\/(?!\/)/i.test(text)) warnings.push(rel + ': absolute asset path ("/…"); the pane serves under a prefix, so use relative paths.');
      let m;
      while ((m = external.exec(text))) {
        const origin = 'https://' + m[2];
        if (!allowed || allowed.includes(origin)) continue;
        warnings.push(rel + ': loads ' + origin + ', which is blocked unless declared under network.');
      }
      if (/<script[^>]+src\s*=\s*["'](https?:)?\/\//i.test(text)) errors.push(rel + ': scripts from the network never load; bundle them into web/.');
    } else if (ext === '.js' || ext === '.mjs') {
      if (/\beval\s*\(|\bnew\s+Function\s*\(/.test(text)) warnings.push(rel + ': uses eval or new Function, which is blocked at run time.');
      if (/WebAssembly\.(instantiate|compile)/.test(text)) warnings.push(rel + ': uses WebAssembly, which is not available to add-ons yet.');
      if (/new\s+(Shared)?Worker\s*\(\s*URL\.createObjectURL/.test(text)) warnings.push(rel + ': starts a blob: worker, which is blocked; load the worker from a file in web/.');
    }
  }
  return { errors, warnings };
}

// The findings without printing: `check` prints them, the shared fixture tests compare them
// with the app's Rust installer (`fixtures/install-cases.json`).
function collect(root, limits) {
  const errors = [];
  const blocked = [];
  const warnings = [];
  const panesDir = path.join(root, 'app-panes');
  if (!fs.existsSync(path.join(root, 'agmsg-plugin.conf'))) {
    warnings.push('No agmsg-plugin.conf at the repository root (name, description).');
  }
  if (!fs.existsSync(panesDir)) {
    errors.push('No app add-on here (no app-panes/ folder). See https://github.com/fujibee/agmsg-addon-sample for the layout.');
    return { errors, blocked, warnings, t: null };
  }
  const panes = fs.readdirSync(panesDir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
  if (!panes.length) errors.push('app-panes/ has no add-on folder.');

  const tree = collectFiles(root);
  for (const pane of panes) {
    const rel = 'app-panes/' + pane + '/addon.conf';
    if (!NAME_RE.test(pane)) errors.push('app-panes/' + pane + ': names are lowercase letters, digits and "-".');
    if (!fs.existsSync(path.join(root, rel))) {
      errors.push(rel + ' is missing.');
      continue;
    }
    const c = checkConf(path.join(root, rel), rel);
    errors.push(...c.errors);
    warnings.push(...c.warnings);
    const webPrefix = 'app-panes/' + pane + '/web/';
    const entry = webPrefix + c.conf.entry;
    const webFiles = tree.files.filter((f) => f.startsWith(webPrefix));
    if (!fs.existsSync(path.join(root, entry))) {
      errors.push(entry + ' is missing. Add-ons must commit their built web/ folder.');
    } else if (tree.git && !webFiles.includes(entry)) {
      errors.push(entry + ' is not committed. The app installs only what is committed.');
    }
    const untrackedWeb = tree.untracked.filter((f) => f.startsWith(webPrefix));
    if (untrackedWeb.length) {
      warnings.push(untrackedWeb.length + ' file(s) in ' + webPrefix + ' are not committed yet (e.g. ' + untrackedWeb[0] + ').');
    }
    const s = scanWeb(root, webFiles.length ? webFiles : untrackedWeb, c.conf);
    blocked.push(...s.errors);
    warnings.push(...s.warnings);
  }
  const t = checkTree(root, tree.files, limits);
  errors.push(...t.errors);
  return { errors, blocked, warnings, t };
}

function check(root) {
  const c = collect(root);
  return report(c.errors, c.blocked, c.warnings, c.t);
}

function report(errors, blocked, warnings, t) {
  for (const e of errors) console.error('error: ' + e);
  for (const b of blocked) console.error('blocked: ' + b);
  for (const w of warnings) console.error('warning: ' + w);
  if (t) {
    console.log('checked ' + t.count + ' files, ' + mb(t.total) + (t.largest.file ? ', largest ' + t.largest.file + ' (' + mb(t.largest.size) + ')' : '') + '.');
  }
  if (errors.length) console.log(errors.length + ' error(s): the app would refuse to install this.');
  else if (blocked.length) console.log('The app would install this, but ' + blocked.length + ' thing(s) will be blocked when it runs.');
  else console.log('ok: the app would accept this layout.');
  return errors.length || blocked.length ? 1 : 0;
}

// ---------- command line ----------

function main(args) {
  if (args.length > 1 || (args[0] && args[0].startsWith('-'))) {
    console.error('usage: node agmsg-addon-check.cjs [dir]');
    return 2;
  }
  return check(path.resolve(args[0] || '.'));
}

if (require.main === module) process.exit(main(process.argv.slice(2)));

module.exports = { main, parseConf, checkConf, check, collect, LIMITS };
