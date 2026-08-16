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

const RAW_BASE = 'https://raw.githubusercontent.com/fujibee/agmsg';
const REPO_URL = 'https://github.com/fujibee/agmsg';
const HOMEPAGE = 'https://agmsg.cc';

// Install the repo ref that matches THIS bootstrapper's version, so
// `npx agmsg@X` installs X — not whatever happens to be on main. We fetch
// setup.sh from the matching tag AND pass AGMSG_REF so setup.sh clones the
// same tag. Falls back to main only when the version can't be read (e.g. a
// dev checkout with no published tag). See #172.
//
// Bootstrappers published before this fix (<= 1.0.5) hardcoded main and
// cannot be retrofitted — `npx agmsg@1.0.5` will still pull main. Pinning
// holds from the first release that ships this file (1.0.6) onward.
function installRef() {
  const v = readVersion();
  return v && v !== '?' ? 'v' + v : 'main';
}

function readVersion() {
  try {
    const pkgPath = path.join(__dirname, '..', 'package.json');
    return JSON.parse(fs.readFileSync(pkgPath, 'utf8')).version;
  } catch (_) {
    return '?';
  }
}

// `agmsg <verb>` is the single most common wrong guess about this project,
// and it is a guess the documentation taught: a sweep of docs/design and
// docs/spec found 34 backticked commands written as `agmsg send …`,
// `agmsg key show …`, `agmsg team list …`. There is no such CLI. This package
// installs agmsg; the commands are scripts inside the install.
//
// Saying only "unknown argument" leaves the person exactly where they were.
// It has to name what to type instead.
//
// The verb→script map is a HINT, and the two halves of that are tested
// differently (review P1):
//
//   NOT promised: that it is complete. This package does not ship scripts/,
//     so it cannot enumerate them. A verb missing from here falls through to
//     the general form, which stays correct.
//   PROMISED: that every entry present is real. A renamed or deleted script
//     would otherwise make this print a specific path that does not exist —
//     WORSE than the general form, not merely less precise. The first version
//     of this comment claimed only precision could degrade; that was wrong,
//     and it was wrong for exactly the entries most likely to rot.
//
// test_bin_agmsg.bats pins every value against the repo's scripts/ — the
// list is asserted non-empty, not at a fixed size, so adding a verb here
// costs nothing while renaming a script fails the suite.
//
// That pin is about THIS repo. It cannot speak for the tree on a user's
// disk, so printNotACommand checks the actual file there before naming it.
const SCRIPT_FOR_VERB = {
  send: 'send.sh', history: 'history.sh', inbox: 'inbox.sh', join: 'join.sh',
  team: 'team.sh', key: 'key.sh', remote: 'remote.sh', whoami: 'whoami.sh',
  leave: 'leave.sh', rename: 'rename.sh', export: 'export.sh', config: 'config.sh',
  watch: 'watch.sh', spawn: 'spawn.sh', version: 'version.sh', api: 'api.sh',
};

// The default install location. Checked because this package's whole job is
// to install agmsg, so a person who has never run it reaches this branch too
// (review P1) — and for them every path below is a command that fails.
// Advice that assumes the install is advice they cannot follow.
function defaultSkillDir() {
  return path.join(os.homedir(), '.agents', 'skills', 'agmsg');
}

function exists(p) {
  try {
    return fs.existsSync(p);
  } catch (_) {
    return false;
  }
}

function printNotACommand(verb, skillDirForTest) {
  const dir = skillDirForTest || defaultSkillDir();
  const skill = '~/.agents/skills/agmsg/scripts';
  const script = Object.prototype.hasOwnProperty.call(SCRIPT_FOR_VERB, verb)
    ? SCRIPT_FOR_VERB[verb]
    : null;
  const scriptsDir = path.join(dir, 'scripts');

  // The contract differs by what is about to be printed, and that is the
  // point (review P1):
  //
  //   naming ONE script  -> that script file must exist. The repo-side pin
  //     proves the map matches THIS repo; it says nothing about the tree on
  //     the user's disk, which can be an old version, a partial update, or a
  //     broken install. Checking only that scripts/ exists reproduces the
  //     previous P1 one layer out — a directory is not the file.
  //   naming the DIRECTORY -> the directory must exist. Nothing more is
  //     claimed, so nothing more is checked.
  const haveScripts = exists(scriptsDir);
  const usable = script ? exists(path.join(scriptsDir, script)) : haveScripts;

  const lines = ['agmsg: `agmsg ' + verb + '` is not a command.', ''];

  if (!usable) {
    // Three situations that need different next steps, kept apart: never
    // installed, installed but without this command, and installed under
    // another name. Folding them together leaves someone without a recovery
    // step — which is what the first version of this message did.
    if (haveScripts) {
      lines.push('Your agmsg install does not contain that command. It may be an');
      lines.push('older version — update it:');
    } else {
      lines.push('agmsg does not look installed on this machine — this package is');
      lines.push('the installer for it. Install first:');
    }
    lines.push('');
    lines.push('  npx agmsg install');
    lines.push('');
    lines.push('After that, ' + (script ? 'that command is:' : 'the commands are:'));
    lines.push('');
    lines.push(script ? '  bash ' + skill + '/' + script + ' …'
                      : '  bash ' + skill + '/<name>.sh …');
    lines.push('');
    lines.push('(Already installed under a different name? Substitute it for');
    lines.push('`agmsg` in that path — nothing is put on your PATH.)');
  } else if (script) {
    lines.push('This package only installs agmsg. That one lives in your install:');
    lines.push('');
    lines.push('  bash ' + skill + '/' + script + ' …');
  } else {
    lines.push('This package only installs agmsg. The commands live in your install:');
    lines.push('');
    lines.push('  ls ' + skill + '/');
    lines.push('  bash ' + skill + '/<name>.sh …');
  }

  lines.push('');
  // The skill command is the path most people actually want — it is what the
  // install sets up, and it needs no paths.
  lines.push('Or ask your agent: run the agmsg skill command (/agmsg in Claude Code).');
  lines.push('`npx agmsg --help` covers what THIS package does.');
  console.error(lines.join('\n'));
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

// Normalise a native path to the forward-slash form that bash.exe and
// curl.exe accept on Windows. bash is an MSYS2 program: Windows gives it a
// raw command-line string rather than a real argv[], and MSYS's own argv
// reconstruction treats backslash as an escape character, so a native
// `C:\Users\...\setup.sh` argument gets corrupted (e.g. `\U`, `\T` are read
// as escapes) into a path that doesn't exist — "No such file or directory"
// for a file that's actually there. Forward slashes have no such ambiguity,
// and both bash and curl accept them on Windows. No-op on POSIX (no
// backslashes to replace). See #262.
function toBashPath(p) {
  return p.replace(/\\/g, '/');
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
  const ref = installRef();
  const setupUrl = RAW_BASE + '/' + ref + '/setup.sh';
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agmsg-bootstrap-'));
  // os.tmpdir()/path.join() return backslash-separated paths on Windows.
  // fs.rmSync (below) handles that form fine since it's a native Node call;
  // curl and bash are external processes, so they get the bash-safe form.
  const setupPath = toBashPath(path.join(tmpDir, 'setup.sh'));

  try {
    const fetch = spawnSync('curl', ['-fsSL', '-o', setupPath, setupUrl], { stdio: 'inherit' });
    if (fetch.error) {
      console.error('agmsg: failed to launch curl:', fetch.error.message);
      process.exit(1);
    }
    if (fetch.status !== 0) {
      console.error('agmsg: curl exited ' + fetch.status + ' fetching ' + setupUrl);
      process.exit(fetch.status || 1);
    }

    // Pin the clone inside setup.sh to the same ref we fetched it from.
    const result = spawnSync('bash', [setupPath, ...passthroughArgs], {
      stdio: 'inherit',
      env: Object.assign({}, process.env, { AGMSG_REF: ref })
    });
    if (result.error) {
      console.error('agmsg: failed to launch bash:', result.error.message);
      process.exit(1);
    }
    process.exit(result.status === null ? 1 : result.status);
  } finally {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (_) { /* best-effort */ }
  }
}

function main() {
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
    printNotACommand(args[0]);
    process.exit(2);
  }
}

if (require.main === module) {
  main();
}

module.exports = { toBashPath, SCRIPT_FOR_VERB, printNotACommand };
