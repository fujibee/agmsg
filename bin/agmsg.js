#!/usr/bin/env node

// agmsg npm entry.
//
// This package does NOT contain the agmsg implementation. It is the single
// `agmsg` command's Node entry point, and it does two things only:
//
//   - `agmsg install` fetches the canonical setup.sh for this package's
//     version and runs it (equivalent to the README's
//     `bash <(curl -fsSL .../setup.sh)`; process substitution keeps the tty as
//     stdin, see agmsg #98).
//   - every other command is handed, unchanged, to the bash runtime that an
//     install put on disk (scripts/agmsg). Nothing is reimplemented here.
//
// Usage:
//   install [options]   Fetch and run the canonical setup.sh.
//   help, --help        Print usage.
//   --version           Print this package's and the installed runtime's version.
//   <anything else>     Run the installed runtime's command with the same args.

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

// The install location. `AGMSG_CMD=<name>` selects an install made with
// `--cmd <name>`; without it the default install is used. A named install that
// is missing is an error -- it never falls back to the default one.
function skillsRoot() {
  return path.join(os.homedir(), '.agents', 'skills');
}

function exists(p) {
  try {
    return fs.existsSync(p);
  } catch (_) {
    return false;
  }
}

// Sets out how to reach the runtime `agmsg` (scripts/agmsg, a bash script that
// install.sh copies into the install). Returns { runtime } on success or
// { error, lines } describing why it cannot be reached.
function resolveRuntime(env, skillsDirForTest) {
  const root = skillsDirForTest || skillsRoot();
  const named = env.AGMSG_CMD;
  if (named !== undefined && named !== '') {
    if (!/^[A-Za-z0-9._-]+$/.test(named) || named === '.' || named === '..') {
      return { error: true, lines: ['agmsg: AGMSG_CMD must be a plain install name, got "' + named + '".'] };
    }
    return checkInstall(path.join(root, named), 'AGMSG_CMD=' + named);
  }
  const def = path.join(root, 'agmsg');
  const found = checkInstall(def, 'the default install');
  if (!found.error) return found;
  if (exists(path.join(def, 'scripts'))) return found;
  // No default install: list others that have a runtime, without picking one.
  let others = [];
  try {
    others = fs.readdirSync(root).filter((n) => exists(path.join(root, n, 'scripts', 'agmsg')));
  } catch (_) { /* no skills directory */ }
  if (others.length > 0) {
    return {
      error: true,
      lines: ['agmsg: there is no default install, but these installs have the agmsg command:']
        .concat(others.map((n) => '  ' + n))
        .concat(['Pick one with AGMSG_CMD=<name> agmsg …'])
    };
  }
  return found;
}

function checkInstall(dir, label) {
  const runtime = path.join(dir, 'scripts', 'agmsg');
  if (exists(runtime)) return { runtime, dir };
  if (exists(path.join(dir, 'scripts'))) {
    return { error: true, lines: [
      'agmsg: ' + label + ' has no agmsg command (an older version). Update it:',
      '  agmsg install'
    ] };
  }
  return { error: true, lines: [
    'agmsg: ' + label + ' is not installed. Install first:',
    '  agmsg install'
  ] };
}

function printHelp() {
  process.stdout.write([
    'agmsg — cross-agent messaging',
    '',
    'Usage:',
    '  agmsg install [options]   install or update agmsg (runs the canonical setup.sh)',
    '  agmsg daemon <command>    manage the agmsgd beta daemon (start|stop|status|enable|disable)',
    '  agmsg --version           show this package and the installed runtime version',
    '  agmsg help                show this message',
    '',
    'Every command other than install is run by the agmsg install on this',
    'machine (AGMSG_CMD=<name> picks an install made with `--cmd <name>`).',
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

// Runs the runtime with the arguments exactly as given: an absolute path, no
// shell, inherited stdio, and the runtime's own exit status.
function runRuntime(runtime, args) {
  const result = spawnSync(bashCommand(), [toBashPath(runtime), ...args], { stdio: 'inherit' });
  if (result.error) {
    console.error('agmsg: failed to launch bash:', result.error.message);
    process.exit(1);
  }
  if (result.signal) {
    process.kill(process.pid, result.signal);
    return;
  }
  process.exit(result.status === null ? 1 : result.status);
}

// On Windows a bare `bash` can be the WSL launcher; prefer Git for Windows'.
function bashCommand() {
  if (process.platform === 'win32') {
    const pf = process.env.ProgramFiles || 'C:\\Program Files';
    const gitBash = path.join(pf, 'Git', 'bin', 'bash.exe');
    if (exists(gitBash)) return gitBash;
  }
  return 'bash';
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

  if (args[0] === 'install') {
    // Forward anything after `install` (e.g. `agmsg install --cmd m`) to
    // setup.sh, which passes "$@" through to install.sh.
    runInstaller(args.slice(1));
  } else if (args.length === 0 || args[0] === '--help' || args[0] === '-h' || args[0] === 'help') {
    printHelp();
    process.exit(args.length === 0 ? 2 : 0);
  } else if (args[0] === '--version' || args[0] === '-v') {
    process.stdout.write('agmsg ' + readVersion() + ' (npm entry)\n');
    const found = resolveRuntime(process.env);
    if (found.error) {
      process.stdout.write('runtime: not available\n');
    } else {
      const v = spawnSync(bashCommand(), [toBashPath(found.runtime), '--version'], { encoding: 'utf8' });
      process.stdout.write('runtime: ' + (v.status === 0 ? v.stdout.trim() : 'unreadable') + '\n');
    }
    process.exit(0);
  } else {
    const found = resolveRuntime(process.env);
    if (found.error) {
      console.error(found.lines.join('\n'));
      process.exit(2);
    }
    runRuntime(found.runtime, args);
  }
}

if (require.main === module) {
  main();
}

module.exports = { toBashPath, resolveRuntime, runRuntime };
