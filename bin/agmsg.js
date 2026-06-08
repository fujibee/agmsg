#!/usr/bin/env node

// agmsg npm bootstrapper.
//
// This package does NOT contain the agmsg implementation. It exists to
// reserve the "agmsg" name on npm and to give users a convenient
// `npx agmsg install` entry point that defers to the canonical shell
// installer maintained at https://github.com/fujibee/agmsg.
//
// All real installation, configuration, and runtime logic lives in the
// upstream repo. This bootstrapper just runs:
//
//   bash <(curl -fsSL https://raw.githubusercontent.com/fujibee/agmsg/main/setup.sh)
//
// Subcommands:
//   install   Fetch and run the canonical setup.sh (default if no args).
//   --help    Print this message and exit 0.
//   --version Print the bootstrapper version and exit 0.

const { spawnSync } = require('child_process');
const fs = require('fs');
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
    'Copilot CLI / Antigravity / OpenCode) and run the agmsg skill command',
    'to join a team.',
    '',
    'Homepage: ' + HOMEPAGE,
    'Issues:   ' + REPO_URL + '/issues',
    ''
  ].join('\n'));
}

function runInstaller() {
  // We deliberately invoke `bash -c "curl ... | bash"` rather than piping
  // through Node's HTTP stack. The canonical installer is bash; that's the
  // path upstream tests and supports. We pass `-fsSL` so curl fails on
  // HTTP errors rather than piping an error page into bash.
  const cmd = 'curl -fsSL "' + SETUP_URL + '" | bash';
  const result = spawnSync('bash', ['-c', cmd], { stdio: 'inherit' });
  if (result.error) {
    console.error('agmsg: failed to launch bash:', result.error.message);
    process.exit(1);
  }
  process.exit(result.status === null ? 1 : result.status);
}

const args = process.argv.slice(2);

if (args.length === 0 || args[0] === 'install') {
  runInstaller();
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
