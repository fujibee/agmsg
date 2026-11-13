import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  pokeDeliveryEnabled,
  pokeNudgeText,
  typeConfGet,
  clearTypeConfCacheForTests,
} from '../scripts/daemon/channels/terminal-poke-types.mjs';

function temporaryDirectory(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'agmsgd-terminal-poke-types-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function writeTypeConf(root, type, text) {
  const dir = path.join(root, 'scripts', 'drivers', 'types', type);
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, 'type.conf'), text);
}

test.beforeEach(() => clearTypeConfCacheForTests());

test('a missing type.conf defaults poke delivery to on', (t) => {
  const root = temporaryDirectory(t);
  assert.equal(pokeDeliveryEnabled(root, 'nosuchtype'), true);
});

test('poke_delivery=no turns a type off', (t) => {
  const root = temporaryDirectory(t);
  writeTypeConf(root, 'gemini', 'poke_delivery=no\n');
  assert.equal(pokeDeliveryEnabled(root, 'gemini'), false);
});

test('poke_delivery set to anything else stays on', (t) => {
  const root = temporaryDirectory(t);
  writeTypeConf(root, 'gemini', 'poke_delivery=yes\n');
  assert.equal(pokeDeliveryEnabled(root, 'gemini'), true);
});

test('default nudge text uses the type\'s cmd_prefix and the given command name', (t) => {
  const root = temporaryDirectory(t);
  writeTypeConf(root, 'antigravity', 'cmd_prefix=$\n');
  assert.equal(
    pokeNudgeText(root, 'antigravity', 'agmsg'),
    'agmsg: you have new messages. Run $agmsg to check your inbox.',
  );
});

test('a cmd_prefix-less type defaults the nudge text prefix to /', (t) => {
  const root = temporaryDirectory(t);
  assert.equal(
    pokeNudgeText(root, 'unknown', 'agmsg'),
    'agmsg: you have new messages. Run /agmsg to check your inbox.',
  );
});

test('poke_nudge overrides the default text entirely', (t) => {
  const root = temporaryDirectory(t);
  writeTypeConf(root, 'gemini', 'poke_nudge=check your messages now\n');
  assert.equal(pokeNudgeText(root, 'gemini', 'agmsg'), 'check your messages now');
});

test('a quoted value has its surrounding quotes stripped, same as the shell reader', (t) => {
  const root = temporaryDirectory(t);
  writeTypeConf(root, 'gemini', 'poke_nudge="go check inbox"\n');
  assert.equal(typeConfGet(root, 'gemini', 'poke_nudge'), 'go check inbox');
});

test('a comment line and blank lines are ignored', (t) => {
  const root = temporaryDirectory(t);
  writeTypeConf(root, 'gemini', '# a comment\n\npoke_delivery=no\n');
  assert.equal(pokeDeliveryEnabled(root, 'gemini'), false);
});
