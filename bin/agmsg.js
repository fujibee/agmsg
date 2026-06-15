#!/usr/bin/env node

// agmsg npm bootstrapper.
//
// This package does NOT contain the agmsg implementation. It exists to
// reserve the "agmsg" name on npm and to give users a convenient
// `npx agmsg install` entry point that defers to the canonical shell
// installer maintained at https://github.com/fujibee/agmsg.
//
// All real installation, configuration, and runtime logic lives in the
// canonical setup.sh. This bootstrapper fetches that script to a tempfile
// and exec's it directly — equivalent to the README's
//
//   bash <(curl -fsSL https://raw.githubusercontent.com/fujibee/agmsg/main/setup.sh)
//
// form, which is process-substitution and preserves the user's tty as
// stdin. We deliberately do NOT pipe the curl output into bash: piping
// makes the installer's stdin the wrapper script stream, and install.sh's
// interactive command-name prompt would `read -r` the next line of
// setup.sh as the command name. See agmsg #98.
//
// Subcommands:
//   install   Fetch and run the canonical setup.sh (default if no args).
//   --help    Print this message and exit 0.
//   --version Print the bootstrapper version and exit 0.

const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const SETUP_URL = 'https://raw.githubusercontent.com/fujibee/agmsg/main/setup.sh';
const REPO_URL = 'https://github.com/fujibee/agmsg';
const HOMEPAGE = 'https://agmsg.cc';

function readVersion() {
  try {
    const pkgPath = path.join(__dirname, '..', 'package.json');
    return JSON.parse(fs.readFileSync(pkgPath, 'utf8')).version;
  } catch (_) {
    return '?';
  }
}

function printHelp() {
  process.stdout.write([
    'agmsg — npm bootstrapper for cross-agent messaging',
    '',
    'This package is a thin wrapper. The real installer lives at:',
    '  ' + REPO_URL,
    '',
    'Usage:',
    '  npx agmsg              run the canonical setup.sh (same as `agmsg install`)',
    '  npx agmsg install      run the canonical setup.sh',
    '  npx agmsg --help       show this message',
    '  npx agmsg --version    show this bootstrapper\'s version',
    '',
    'After install, restart your agent (Claude Code / Codex / Gemini CLI /',
    'Copilot CLI / Antigravity / OpenCode / Hermes Agent) and run the agmsg skill command',
    'to join a team.',
    '',
    'Homepage: ' + HOMEPAGE,
    'Issues:   ' + REPO_URL + '/issues',
    ''
  ].join('\n'));
}

function runInstaller(passthroughArgs) {
  // Fetch the canonical setup.sh to a private tempdir, then exec it directly
  // with bash. This keeps the installer's stdin wired to the parent process's
  // tty rather than a pipe stream — which matters because install.sh has an
  // interactive `Command name [agmsg]:` prompt that would otherwise read the
  // next line of setup.sh as the command name. See agmsg #98 for the full
  // diagnosis. install.sh now guards itself with `[ -t 0 ]` (PR #99), so this
  // bootstrapper plus a still-vulnerable install.sh would also work; doing it
  // correctly here is defense-in-depth and lets future interactive prompts
  // in setup.sh keep working for real-tty users.
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agmsg-bootstrap-'));
  const setupPath = path.join(tmpDir, 'setup.sh');

  try {
    const fetch = spawnSync('curl', ['-fsSL', '-o', setupPath, SETUP_URL], { stdio: 'inherit' });
    if (fetch.error) {
      console.error('agmsg: failed to launch curl:', fetch.error.message);
      process.exit(1);
    }
    if (fetch.status !== 0) {
      console.error('agmsg: curl exited ' + fetch.status + ' fetching ' + SETUP_URL);
      process.exit(fetch.status || 1);
    }

    const result = spawnSync('bash', [setupPath, ...passthroughArgs], { stdio: 'inherit' });
    if (result.error) {
      console.error('agmsg: failed to launch bash:', result.error.message);
      process.exit(1);
    }
    process.exit(result.status === null ? 1 : result.status);
  } finally {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (_) { /* best-effort */ }
  }
}

const args = process.argv.slice(2);

if (args.length === 0 || args[0] === 'install') {
  // Forward anything after `install` (e.g. `agmsg install --cmd m`) to
  // setup.sh, which passes "$@" through to install.sh.
  const passthrough = args[0] === 'install' ? args.slice(1) : args;
  runInstaller(passthrough);
} else if (args[0] === '--help' || args[0] === '-h' || args[0] === 'help') {
  printHelp();
  process.exit(0);
} else if (args[0] === '--version' || args[0] === '-v') {
  process.stdout.write('agmsg bootstrapper ' + readVersion() + '\n');
  process.stdout.write('canonical project: ' + REPO_URL + '\n');
  process.exit(0);
} else {
  console.error('agmsg: unknown argument: ' + args[0]);
  console.error('Run `npx agmsg --help` for usage.');
  process.exit(2);
}
