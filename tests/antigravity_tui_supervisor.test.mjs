import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import test from 'node:test';

const supervisor = new URL('../scripts/drivers/types/antigravity/antigravity-tui-supervisor.py', import.meta.url).pathname;
const repo = new URL('..', import.meta.url).pathname.replace(/\/$/, '');
const agyScreenFixture = new URL('./fixtures/agy-1.1.27-screen-transcripts.json', import.meta.url).pathname;

function runPython(source) {
  const result = spawnSync('python3', ['-c', source], {
    encoding: 'utf8',
    env: { ...process.env, PYTHONPYCACHEPREFIX: '/tmp/agmsg-pycache' },
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
}

test('does not inject on a permission screen or draft; only reinjects a prepared batch into an empty input field', () => {
  runPython(`
import importlib.util
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
s = module.Supervisor.__new__(module.Supervisor)
s.a = SimpleNamespace(poll=0)
s.last_poll = 0
s.human_input_seen = False
s.master = None
s.state = {'batch': {'id': 'replay', 'phase': 'prepared'}}
s.check_guard = lambda: None
sent = []
def inject():
    sent.append('injected')
    s.state['batch']['phase'] = 'sent'
s.inject = inject
def draw(text):
    s.screen = module.TerminalScreen(30, 120)
    s.screen.feed(text.encode())
for text in [
    '? for shortcuts',
    '> draft\\r\\n? for shortcuts',
    '>\\r\\nsecond draft line\\r\\n? for shortcuts',
    '>\\r\\n? for shortcuts\\r\\n> draft\\r\\n? for shortcuts',
    'Requesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\nesc to cancel',
    'Do you trust the contents of this project?\\r\\n> Yes, I trust this folder\\r\\nNavigate · enter Confirm',
    '> /\\r\\n/help\\r\\n/clear\\r\\nesc to cancel',
    '▸ Generating...\\r\\n>\\r\\nesc to cancel',
    'error: command failed\\r\\n> draft\\r\\n? for shortcuts',
]:
    draw(text)
    s.maybe_poll()
    assert sent == []
draw('>\\r\\n? for shortcuts    Gemini 3.8 Flash · high')
assert s.input_ready()
draw('past receive body: Requesting permission\\r\\npast receive body: Do you want to proceed?\\r\\n>\\r\\n? for shortcuts  Gemini 3.8 Flash · high')
assert s.input_ready(), 'wording from a past body must not stop delivery'
for tail in [b'\\x1b[', b'\\x1b]title', b'\\xe3']:
    draw('>\\r\\n? for shortcuts')
    s.screen.feed(tail)
    assert not s.input_ready(), 'must not inject mid-render'
draw('>\\r\\n? for shortcuts  Gemini 3.8 Flash · high')
s.last_output = module.time.monotonic()
assert not s.input_ready(), 'must not inject immediately after output'
s.last_output = 0
s.state['manualResumeRequired'] = True
s.maybe_poll()
assert sent == [], 'a saved pause is also honored'
s.state['manualResumeRequired'] = False
s.maybe_poll()
assert sent == ['injected']
s.maybe_poll()
assert sent == ['injected'], 'a sent batch is not automatically resent'
s.state['batch']['phase'] = 'uncertain'
s.maybe_poll()
assert sent == ['injected'], 'an uncertain batch is not automatically resent'
`);
});

test('holds a batch in prepared when unprocessed child output or human input exists right before injection', () => {
  runPython(`
import importlib.util
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
s = module.Supervisor.__new__(module.Supervisor)
s.a = SimpleNamespace(poll=0)
s.last_poll = 0
s.last_output = 0
s.human_input_seen = False
s.state = {'batch': None, 'manualResumeRequired': False, 'supervisorPhase': 'WAITING_FOR_IDLE'}
s.check_guard = lambda: None
s.call = lambda command: '{"id":"m1","body":"test"}' if command == 'peek' else ''
s.save = lambda: None
s.input_ready = lambda: True
s.master = 99
s.inject = lambda: (_ for _ in ()).throw(AssertionError('injected while I/O was pending'))
saw = {'calls': 0}
def pending_after_peek(*_args):
    saw['calls'] += 1
    return ([], [], []) if saw['calls'] == 1 else ([99], [], [])
module.select.select = pending_after_peek
s.maybe_poll()
assert s.state['batch']['phase'] == 'prepared'
`);
});

test('real agy 1.1.27 screen fragments are judged injectable only when idle', () => {
  runPython(`
import importlib.util
import json
from pathlib import Path
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
fixtures = json.loads(Path(${JSON.stringify(agyScreenFixture)}).read_text())
for name, fixture in fixtures.items():
    screen = module.TerminalScreen(fixture['rows'], fixture['cols'])
    s = module.Supervisor.__new__(module.Supervisor)
    s.screen = screen
    s.last_output = 0
    data = fixture['transcript'].encode()
    results = []
    for offset in range(0, len(data), 64):
        screen.feed(data[offset:offset+64])
        results.append(s.input_ready())
    assert screen.alternate_screen is fixture.get('alternate_screen', True), name
    assert screen.uncertain is False, name
    if fixture['idle']:
        assert results[-1] is True, (name, screen.lines())
    else:
        assert not any(results), (name, screen.lines())
`);
});

test('a narrow-width footer/NAV wrap is reconstructed from only the bottom rows, and body text is never mistaken for idle', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
def ready(text):
    s=module.Supervisor.__new__(module.Supervisor)
    s.screen=module.TerminalScreen(24, 40)
    s.last_output=0
    s.screen.feed(text.encode())
    return s.input_ready()
assert ready('>\\r\\n────────────────────────────────────────\\r\\n? for shortcuts  Gemini 3.8 Flash ·\\r\\n high')
assert not ready('body tail: ? for shortcuts  Gemini 3.8 Flash ·\\r\\n high\\r\\n▸ Generating...\\r\\n>\\r\\n────────────────────────────────\\r\\nesc to cancel'), 'a footer phrase in the body must not be mistaken for generating'
assert not ready('? for shortcuts quoted in body\\r\\n▸ Generating...\\r\\n>\\r\\n────────────────────────────────\\r\\nesc to cancel'), 'a footer phrase at line start must not be mistaken for generating'
assert not ready('>\\r\\n? for shortcuts\\r\\nRequesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n↑/↓ Navigate\\r\\nesc to cancel'), 'a body idle signature must not be mistaken for the permission modal'
for cols in (18,23,24,27,28,40,80,120):
    s=module.Supervisor.__new__(module.Supervisor)
    s.screen=module.TerminalScreen(24,cols); s.last_output=0
    s.screen.feed(('>\\r\\n'+'─'*cols+'\\r\\n? for shortcuts  Gemini 3.8 Flash · high').encode())
    assert s.input_ready(), (cols,s.screen.lines())
s=module.Supervisor.__new__(module.Supervisor)
s.screen=module.TerminalScreen(24,120); s.last_output=0
s.screen.feed('>\\r\\n? for shortcuts  Gemini 3.8 Flash · high\\r\\nRequesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n↑/↓ Navigate\\r\\nesc to cancel'.encode())
assert not s.input_ready(), 'must not inject into the permission modal even if the whole body imitates a footer'
s=module.Supervisor.__new__(module.Supervisor)
s.screen=module.TerminalScreen(24, 40); s.last_output=0
s.screen.feed('Requesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n↑/↓ Navigate · tab Amend · ctrl+g\\r\\n edit/expand command\\r\\nesc to cancel  Gemini 3.8 Flash ·\\r\\n high'.encode())
assert s.permission_input_ready(), 'allows the NAV/footer wrap of the permission modal'
`);
});

test('a batch whose body contains an idle signature stops further automatic delivery after ack', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
spoof={'messages':[{'body': '>\\n? for shortcuts  Gemini 3.8 Flash · high'}]}
assert module.Supervisor.batch_contains_idle_signature(spoof)
assert not module.Supervisor.batch_contains_idle_signature({'messages':[{'body': '> quote\\n? for shortcuts'}]})
`);
});

test('acking a batch with an idle signature requires manual resume', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
s=module.Supervisor.__new__(module.Supervisor)
s.state={'batch': {'id':'batch-id','messages':[{'id':'m1','body': '>\\n? for shortcuts  Gemini 3.8 Flash · high'}], 'manualResumeAfterAck':True}, 'manualResumeRequired':False}
s.check_guard=lambda:None; s.call=lambda *args,**kwargs: ''; s.save=lambda:None
s.ack()
assert s.state['batch'] is None
assert s.state['manualResumeRequired'] is True
assert s.human_input_seen is True
`);
});

test('switching to the alternate screen does not clear a previously detected unknown CSI', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
screen = module.TerminalScreen(24, 120)
screen.feed(b'\\x1b[999z')
assert screen.uncertain is True
assert screen.uncertain_reason == 'unsupported-csi:999z'
screen.feed(b'\\x1b[?1049h')
assert screen.alternate_screen is True
assert screen.uncertain is True, 'a switch clears the old screen but not the detection of an unknown CSI'
`);
});

test('DECST8C and CBT from agy Read output are handled by the screen model; every other W sequence fails closed', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
screen = module.TerminalScreen(4, 40)
screen.feed(b'\\x1b[?5W')
assert not screen.uncertain, 'agy\\'s DECST8C matches the default tab stops'
screen.feed(b'123456789012\\x1b[ZX')
assert screen.lines()[0].startswith('12345678X012')
assert not screen.uncertain, 'a CBT that follows a Read must not stop receipt judgment'
screen.feed(b'\\x1b[?4W')
assert screen.uncertain, 'an unobserved tab control is not tolerated'
`);
});

test('the TUI envelope represents multiple messages one-to-one in ID order', () => {
  runPython(`
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
s = module.Supervisor.__new__(module.Supervisor)
batch = {'id': 'batch-1', 'messages': [
  {'id': 'm-1', 'from': 'agy', 'at': '2026-09-06T06:00:00Z', 'body': 'first item'},
  {'id': 'm-2', 'from': 'claude', 'at': '2026-09-06T06:01:00Z', 'body': 'second item\\x1b'},
]}
text = s.envelope(batch)
assert '[agmsg batch id=batch-1 ' in text
assert 'count=2' in text
assert text.index('id=m-1') < text.index('id=m-2')
assert text.count('[/agmsg message]') == 2
assert '\\\\x1b' in text
assert 'AGMSG_RECEIVED:batch-1' not in text
assert 'an ASCII colon (U+003A), and the batch id with no spaces' in text
`);
});

test('TUI injection wraps bracketed paste and CR, and saves the sent state', () => {
  runPython(`
import importlib.util
import os
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
r, w = os.pipe()
s = module.Supervisor.__new__(module.Supervisor)
s.master = w
s.state = {'batch': {'id': 'batch-2', 'messages': [
  {'id': 'm-1', 'from': 'agy', 'at': '2026-09-06T06:00:00Z', 'body': 'body text'},
]}, 'supervisorPhase': 'PREPARED'}
s.save = lambda: None
s.inject()
data = os.read(r, 65536)
assert data.startswith(b'\\x1b[200~')
assert data.endswith(b'\\x1b[201~\\r')
assert s.state['batch']['phase'] == 'sent'
assert s.state['supervisorPhase'] == 'WAITING_FOR_RESULT'
assert s.state['batch']['receipt'] == 'AGMSG_RECEIVED:batch-2'
os.close(r); os.close(w)
`);
});

test('normal human input holds temporarily without raising a durable pause', () => {
  runPython(`
import contextlib
import importlib.util
import io
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
s = module.Supervisor.__new__(module.Supervisor)
s.state = {'manualResumeRequired': False, 'humanInputActive': False, 'humanInputSawNonIdle': False, 'supervisorPhase': 'WAITING_FOR_IDLE'}
s.human_idle_since = None
s.save = lambda: None
notice = io.StringIO()
with contextlib.redirect_stderr(notice):
    s.pause_for_human_input()
    s.pause_for_human_input()
assert s.state['manualResumeRequired'] is False
assert s.state['humanInputActive'] is True
assert s.state['humanInputSawNonIdle'] is False
assert s.state['supervisorPhase'] == 'WAITING_FOR_IDLE'
assert notice.getvalue().count('resume when the empty input prompt returns') == 1
`);
});

test('normal input auto-resumes only after a stable idle following non-idle', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
s = module.Supervisor.__new__(module.Supervisor)
s.HUMAN_IDLE_STABLE_SECONDS = 0.6
s.state = {'batch': None, 'manualResumeRequired': False, 'humanInputActive': True,
           'humanInputSawNonIdle': False, 'durableAttention': False}
s.human_input_restart_recovery = False
s.human_idle_since = None
s.save = lambda: None
s.violations = type('Violations', (), {'exists': lambda self: False})()
ready = {'value': True}
s.injection_ready = lambda: ready['value']
now = {'value': 10.0}
module.time.monotonic = lambda: now['value']
s.update_human_input_state()
assert s.state['humanInputActive'] is True, 'an old idle alone does not clear it'
ready['value'] = False
s.update_human_input_state()
assert s.state['humanInputSawNonIdle'] is True
ready['value'] = True
s.update_human_input_state()
now['value'] += 0.59
s.update_human_input_state()
assert s.state['humanInputActive'] is True, 'does not clear before the stable period elapses'
ready['value'] = False
s.update_human_input_state()
assert s.human_idle_since is None, 'a non-idle in the middle resets the stability observation'
ready['value'] = True
s.update_human_input_state()
now['value'] += 0.61
s.update_human_input_state()
assert s.state['humanInputActive'] is False

for field, value in [('manualResumeRequired', True), ('durableAttention', True)]:
    s.state.update({'humanInputActive': True, 'humanInputSawNonIdle': True,
                    'manualResumeRequired': False, 'durableAttention': False})
    s.state[field] = value
    s.human_idle_since = None
    now['value'] += 1
    s.update_human_input_state()
    now['value'] += 1
    s.update_human_input_state()
    assert s.state['humanInputActive'] is True, field
s.state.update({'batch': {'phase': 'prepared'}, 'humanInputActive': True,
                'manualResumeRequired': False, 'durableAttention': False})
s.update_human_input_state()
assert s.state['humanInputActive'] is True, 'does not clear while a batch is unresolved'
`);
});

test('restart recovery requires only a stable idle on the new screen, and does not clear the durable state', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
s = module.Supervisor.__new__(module.Supervisor)
s.HUMAN_IDLE_STABLE_SECONDS = 0.6
s.state = {'batch': None, 'manualResumeRequired': False, 'humanInputActive': True,
           'humanInputSawNonIdle': False, 'durableAttention': False}
s.human_input_restart_recovery = True
s.human_idle_since = None
s.save = lambda: None
s.violations = type('Violations', (), {'exists': lambda self: False})()
s.injection_ready = lambda: True
now = {'value': 20.0}
module.time.monotonic = lambda: now['value']
s.update_human_input_state()
now['value'] += 0.61
s.update_human_input_state()
assert s.state['humanInputActive'] is False
assert s.human_input_restart_recovery is False
`);
});

test('only a measured, verified permission UI allows human confirmation input during a receive turn', () => {
  runPython(`
import contextlib
import importlib.util
import io
import json
from pathlib import Path
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
fixtures = json.loads(Path(${JSON.stringify(agyScreenFixture)}).read_text())
def screen(name):
    fixture=fixtures[name]
    value=module.TerminalScreen(fixture['rows'], fixture['cols'])
    value.feed(fixture['transcript'].encode())
    return value
s = module.Supervisor.__new__(module.Supervisor)
s.screen = screen('permission')
s.permission_raw_window = fixtures['permission']['transcript'] + '\\nRAW_WINDOW_SECRET_MARKER'
assert s.permission_input_ready()
s.screen = screen('trust')
assert s.permission_input_ready()
for name in ('idle', 'generating'):
    s.screen = screen(name)
    assert not s.permission_input_ready(), name
s.screen = module.TerminalScreen(28, 120)
s.screen.feed(b'Requesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n? for shortcuts')
assert not s.permission_input_ready(), 'must not allow on wording from the received body alone'
s.screen = module.TerminalScreen(24, 120)
s.screen.feed('Requesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n↑/↓ Navigate · tab Amend\\r\\n▸ Generating...\\r\\n>\\r\\n────────────────────────────────\\r\\nesc to cancel'.encode())
assert not s.permission_input_ready(), 'must not mistake generating-state chrome plus received-body wording and a Nav line for the permission UI'
s.screen = module.TerminalScreen(24, 120)
s.screen.feed('Requesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n↑/↓ Navigate · tab Amend\\r\\nesc to cancel'.encode())
assert s.permission_input_ready(), 'a synthetic screen that can supply the Nav line via the body is indistinguishable from the modal by this judgment'
s.screen = module.TerminalScreen(40, 154)
s.screen.feed(('Command\\r\\n' +
    'Requesting permission for:\\r\\n' +
    '   ~/.agents/skills/agmsg/scripts/whoami.sh "$(pwd)" agy\\r\\n' +
    'Do you want to proceed?\\r\\n' +
    '> 1. Yes\\r\\n' +
    '  2. Yes, and always allow in this conversation for commands that start with ~/.agents/skills/agmsg/scripts/whoami.sh "$(pwd)" agy\\r\\n' +
    '  3. Yes, and always allow for commands that start with ~/.agents/skills/agmsg/scripts/whoami.sh "$(pwd)" agy (Persist to settings.json)\\r\\n' +
    '  4. No\\r\\n' +
    '  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command\\r\\n' +
    'esc to cancel  Gemini 3.8 Flash · high').encode())
assert s.permission_input_ready(), 'a real Orca screen with long permission choices is also recognized as the permission UI'
diagnostic = s.permission_screen_diagnostic()
assert 'rows=40,cols=154' in diagnostic
assert "'request': [1]" in diagnostic
assert "'footer': [9]" in diagnostic
assert "'navigate': True" in diagnostic
assert 'whoami.sh' not in diagnostic, 'must not include command text in the diagnostic'
assert 'RAW_WINDOW_SECRET_MARKER' not in diagnostic, 'must not include the raw-output-window body in the diagnostic'
s.screen = module.TerminalScreen(40, 120)
s.screen.feed(('Command\\r\\n' +
    'Requesting permission for:\\r\\n' +
    '   ~/.agents/skills/agmsg/scripts/whoami.sh "/home/joel/projects/babelbiblenet-v2"\\r\\n' +
    'Do you want to proceed?\\r\\n' +
    '> 1. Yes\\r\\n' +
    "  2. Yes, and always allow in this conversation for commands that start with '~/.agents/skills/agmsg/scripts/whoami.sh'\\r\\n" +
    "  3. Yes, and always allow for commands that start with '~/.agents/skills/agmsg/scripts/whoami.sh' (Persist to settings.json)\\r\\n" +
    '  4. No\\r\\n' +
    '  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command\\r\\n' +
    'esc to cancel  Gemini 3.8 Flash · high').encode())
assert s.permission_input_ready(), 'recognized as the permission UI even when a long quoted choice wraps past 12 lines'
s.screen = module.TerminalScreen(24, 120)
s.screen.feed('Requesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n  4. No\\r\\n↑/↓ Navigate · tab Amend\\r\\n▸ Generating...\\r\\n>\\r\\n────────────────────────────────\\r\\nesc to cancel'.encode())
assert not s.permission_input_ready(), 'must not allow a synthetic display with a normal screen between nav and footer'
s.screen = module.TerminalScreen(24, 120)
s.screen.feed('> 1. Yes\\r\\nRequesting permission for:\\r\\nDo you want to proceed?\\r\\n↑/↓ Navigate · tab Amend\\r\\nesc to cancel'.encode())
assert not s.permission_input_ready(), 'must not allow a synthetic display whose required-element order differs from the permission modal'
s.state = {'batch': {'id': 'batch', 'phase': 'sent'}, 'manualResumeRequired': True,
           'humanInputActive': False, 'humanInputSawNonIdle': False,
           'supervisorPhase': 'WAITING_FOR_RESULT'}
s.human_idle_since = None
s.save = lambda: None
notice = io.StringIO()
with contextlib.redirect_stderr(notice): s.allow_permission_input()
assert s.state['batch']['phase'] == 'sent'
assert s.state['manualResumeRequired'] is True, 'must not touch an existing durable pause'
assert s.state['humanInputActive'] is True
assert s.state['humanInputSawNonIdle'] is True
assert s.state['supervisorPhase'] == 'WAITING_FOR_RESULT'
assert 'resume after confirmation when the empty input prompt returns' in notice.getvalue()
`);
});

test('when child rendering and parent input are ready together, the permission screen is reflected first', () => {
  runPython(`
import importlib.util
import sys
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

events=[]
stdin_fd=sys.stdin.fileno()
master_fd=987654
class Screen:
    uncertain=False
    def feed(self, _data): events.append('child')
    def lines_after(self, _receipt): return None

s=module.Supervisor.__new__(module.Supervisor)
s.stopping=False; s.resize_requested=False; s.resume_requested=False; s.stop_reason=None
s.master=master_fd; s.screen=Screen(); s.last_output=0; s.buffer=''; s.result_buffer=''
s.state={'supervisorPhase':'WAITING_FOR_RESULT','batch':{'receipt':'AGMSG_RECEIVED:batch'}}
s.update_human_input_state=lambda: None
s.maybe_poll=lambda: None
s.permission_input_ready=lambda: events == ['child']
s.permission_input_rejection_reason=lambda: None if events == ['child'] else 'permission-before-child'
def allowed():
    events.append('allowed')
    s.stopping=True
s.allow_permission_input=allowed
def failed(reason):
    events.append('failed:'+reason)
    s.stopping=True
s.fail=failed

original_select=module.select.select
original_read=module.os.read
original_write=module.os.write
module.select.select=lambda *_args: ([stdin_fd,master_fd],[],[])
module.os.read=lambda fd,_size: b'permission-screen' if fd==master_fd else b'1'
module.os.write=lambda fd,data: len(data)
try:
    s.loop()
finally:
    module.select.select=original_select
    module.os.read=original_read
    module.os.write=original_write
assert events == ['child','allowed'], events
`);
});

test('a partial redraw simultaneous with permission input is classified by the screen just before it, even if the modal disappears', () => {
  runPython(`
import importlib.util
import sys
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

events=[]
stdin_fd=sys.stdin.fileno(); master_fd=987655
class Screen:
    uncertain=False; uncertain_reason=None; state='normal'
    class Decoder:
        def getstate(self): return (b'',0)
    decoder=Decoder()
    ready=True
    def feed(self, _data): self.ready=False; events.append('child-partial-redraw')
    def lines_after(self, _receipt): return None

s=module.Supervisor.__new__(module.Supervisor)
s.stopping=False; s.resize_requested=False; s.resume_requested=False; s.stop_reason=None
s.master=master_fd; s.screen=Screen(); s.last_output=0; s.buffer=''; s.result_buffer=''
s.state={'supervisorPhase':'WAITING_FOR_RESULT','batch':{'receipt':'AGMSG_RECEIVED:batch'}}
s.update_human_input_state=lambda: None; s.maybe_poll=lambda: None
s.permission_input_ready=lambda: s.screen.ready
s.permission_input_rejection_reason=lambda: None if s.screen.ready else 'permission-after-redraw'
def allowed(): events.append('allowed'); s.stopping=True
s.allow_permission_input=allowed
s.fail=lambda reason: (_ for _ in ()).throw(AssertionError(reason))

original_select=module.select.select; original_read=module.os.read; original_write=module.os.write
module.select.select=lambda *_args: ([stdin_fd,master_fd],[],[])
module.os.read=lambda fd,_size: b'partial-redraw' if fd==master_fd else b'1'
module.os.write=lambda fd,data: len(data)
try: s.loop()
finally:
    module.select.select=original_select; module.os.read=original_read; module.os.write=original_write
assert events == ['child-partial-redraw','allowed'], events
`);
});

test('a read-denied stop shows safe recovery guidance', () => {
  runPython(`
import contextlib
import importlib.util
import io
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
s = module.Supervisor.__new__(module.Supervisor)
s.state = {'batch': None}
s.save = lambda: None
s.stopping = False
out = io.StringIO()
with contextlib.redirect_stderr(out):
    s.fail('detected a mark-read attempt through the regular inbox')
assert 'agy-tui reset-guard' in out.getvalue()
assert 'stopping without ack' in out.getvalue()
assert s.state['durableAttention'] is True
`);
});

test('reset-guard clears the violation only while stopped and with no batch', () => {
  runPython(`
import importlib.util
import json
import tempfile
from pathlib import Path
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path(tempfile.mkdtemp())
s = module.Supervisor.__new__(module.Supervisor)
s.project = '/tmp/project'
s.a = SimpleNamespace(team='demo', name='agy')
s.owner = 'owner'
s.state = {'project': s.project, 'team': 'demo', 'role': 'agy'}
s.state_file = root / 'state.json'
s.reservation = root / 'reservation.json'
s.violations = root / 'reservation.json.violations'
s.actas = root / 'actas.lock'
s.state_file.write_text(json.dumps({**s.state, 'schemaVersion': 1, 'batch': None, 'supervisorPhase': 'NEEDS_ATTENTION'}))
s.violations.write_text('{"event":"read-denied","pid":1}\\n')
calls = []
s.call = lambda command: calls.append(command)
s.reset_guard()
assert s.violations.read_text() == ''
reset_state = json.loads(s.state_file.read_text())
assert reset_state['schemaVersion'] == 2
assert reset_state['durableAttention'] is False
assert reset_state['supervisorPhase'] == 'WAITING_FOR_IDLE'
assert calls == ['claim', 'release']
s.violations.write_text('keep')
s.state_file.write_text(json.dumps({**s.state, 'batch': {'id': 'batch-1', 'phase': 'completed'}}))
try:
    s.reset_guard()
except RuntimeError as error:
    assert 'unresolved batch' in str(error)
else:
    raise AssertionError('did not refuse an unresolved batch')
assert s.violations.read_text() == 'keep'
assert calls == ['claim', 'release']
s.state_file.write_text(json.dumps({**s.state, 'batch': None}))
s.reservation.write_text(json.dumps({
    'state': str(s.state_file),
    'kind': 'tui-pty',
    'pid': __import__('os').getpid(),
    'start': module.proc_start(__import__('os').getpid()),
}))
try:
    s.reset_guard()
except RuntimeError as error:
    assert 'running' in str(error)
else:
    raise AssertionError('did not refuse a running supervisor')
assert s.violations.read_text() == 'keep'
assert calls == ['claim', 'release', 'claim', 'release']
`);
});

test('a receipt is recognized as a complete line on screen even when it spans a read-chunk boundary', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
expected = 'AGMSG_RECEIVED:batch-3'
screen = module.TerminalScreen(4, 80)
screen.feed(b'AGMSG_REC')
assert not screen.has_line(expected)
screen.feed(b'EIVED:batch-3\\r\\n? for shortcuts')
assert screen.has_line(expected)
assert screen.lines_after(expected).splitlines()[0] == '? for shortcuts'
`);
});

test('on a narrow agy screen, a receipt wrapped across physical rows is still matched by its whole UUID', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
expected = 'AGMSG_RECEIVED:203b95e7-b27e-4584-890a-aecb99599438'
screen = module.TerminalScreen(6, 80)
screen.feed(b'  AGMSG_RECEIVED:203b95e7-b27e-4584-890a-\\r\\n  aecb99599438\\r\\n>\\r\\n? for shortcuts')
assert screen.has_line(expected)
assert screen.lines_after(expected).splitlines()[0] == '>'
screen = module.TerminalScreen(6, 80)
screen.feed(b'AGMSG_RECEIVED:203b95e7-b27e-4584-890a-\\r\\nother text')
assert not screen.has_line(expected), 'must not ack unless the consecutive lines form the entire UUID'
`);
});

test('a batch whose body contains the entire wrapped receipt is not ack-eligible', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
receipt = 'AGMSG_RECEIVED:203b95e7-b27e-4584-890a-aecb99599438'
assert module.Supervisor.batch_contains_receipt({'receipt': receipt, 'messages': [
  {'body': 'sample body\\n  AGMSG_RECEIVED:203b95e7-b27e-4584-890a-\\n  aecb99599438'},
]})
assert not module.Supervisor.batch_contains_receipt({'receipt': receipt, 'messages': [
  {'body': '[agmsg batch id=203b95e7-b27e-4584-890a-aecb99599438]'},
  {'body': 'AGMSG_RECEIVED:<batch-id>'},
]})
`);
});

test('reconstructs real-agy-style differential rendering, and discards the old screen on an alternate-screen switch', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
screen = module.TerminalScreen(40, 120)
target = 'AGMSG_RECEIVED:batch-4'
screen.feed(b'\\x1b[10;3HAGMSG_RECEIV')
screen.feed(b'\\x1b[10;15HED:batch-4\\r\\n')
assert screen.has_line(target)
assert screen.lines_after(target) is not None
assert not screen.uncertain
screen.feed(b'\\x1b[1z')
assert screen.uncertain
screen = module.TerminalScreen(40, 120)
screen.feed(b'stale primary screen')
screen.feed(b'\\x1b[?1049h')
assert screen.alternate_screen
assert not screen.uncertain
assert not any('stale primary screen' in line for line in screen.lines())
screen.feed(b'\\x1b[1z')
assert screen.uncertain
`);
});

test('a one-sided overwrite or edit of a full-width cell never synthesizes a forged receipt', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
target = 'AGMSG_RECEIVED:batch-wide'
for column in (15, 16):
    screen = module.TerminalScreen(3, 80)
    screen.feed('AGMSG_RECEIVED、batch-wide'.encode())
    screen.feed(f'\\x1b[1;{column}H:'.encode())
    assert not screen.has_line(target), screen.lines()
    assert not any(cell == '' and (index == 0 or not screen._wide_lead(screen.cells[0][index - 1])) for index, cell in enumerate(screen.cells[0]))
`);
});

test('a resize during a receive turn makes the screen judgment uncertain', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
target = 'AGMSG_RECEIVED:batch-resize'
screen = module.TerminalScreen(2, 80)
screen.feed((target + ' suffix').encode())
assert not screen.has_line(target)
assert screen.resize(2, len(target))
assert screen.has_line(target)
assert screen.uncertain
assert screen.uncertain_reason == 'resize'
`);
});

test('syncs the parent terminal winsize to the agy PTY', () => {
  runPython(`
import fcntl
import importlib.util
import os
import struct
import termios
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
outer_master, outer_slave = os.openpty()
inner_master, inner_slave = os.openpty()
expected = struct.pack('HHHH', 41, 121, 0, 0)
fcntl.ioctl(outer_slave, termios.TIOCSWINSZ, expected)
s = module.Supervisor.__new__(module.Supervisor)
s.master = inner_master
s.child = None
s.state = {'supervisorPhase': 'WAITING_FOR_RESULT'}
s.screen = module.TerminalScreen(40, 120)
s.read_winsize = lambda _fd: fcntl.ioctl(outer_slave, termios.TIOCGWINSZ, struct.pack('HHHH', 0, 0, 0, 0))
s.sync_winsize()
actual = fcntl.ioctl(inner_slave, termios.TIOCGWINSZ, struct.pack('HHHH', 0, 0, 0, 0))
assert actual == expected
assert (s.screen.rows, s.screen.cols) == (41, 121)
assert s.screen.uncertain
s.state = {'supervisorPhase': 'WAITING_FOR_IDLE'}
fcntl.ioctl(outer_slave, termios.TIOCSWINSZ, struct.pack('HHHH', 42, 122, 0, 0))
s.sync_winsize()
assert (s.screen.rows, s.screen.cols) == (42, 122)
assert not s.screen.uncertain
for fd in (outer_master, outer_slave, inner_master, inner_slave): os.close(fd)
`);
});

test('TUI monitor refuses to start from a non-interactive terminal', () => {
  const wrapper = new URL('../scripts/drivers/types/antigravity/antigravity-tui-monitor.sh', import.meta.url).pathname;
  const result = spawnSync('bash', [wrapper, '--help'], { encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /interactive terminal/);
  const status = spawnSync('bash', [wrapper, 'status', '--project', '/tmp', '--team', 'no-such-team', '--name', 'no-such-role'], { encoding: 'utf8' });
  assert.equal(status.status, 0, status.stderr);
  assert.match(status.stdout, /tui-pty not started/);
});

test('TUI status refuses an unreadable process identity', () => {
  runPython(`
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path(tempfile.mkdtemp())
(root / 'run').mkdir()
state = root / 'run' / 'state.json'
state.write_text(json.dumps({'project': '/tmp/project', 'team': 'fixture', 'role': 'worker'}))
foreign = root / 'run' / 'read-reservation.foreign.json'
foreign.write_text(json.dumps({'type': 'codex', 'state': str(root / 'missing-foreign-state.json')}))
missing_type = root / 'run' / 'read-reservation.missing.json'
missing_type.write_text(json.dumps({'state': str(root / 'missing-neutral-state.json')}))
reservation = root / 'run' / 'read-reservation.fixture__worker.json'
reservation.write_text(json.dumps({'type': 'antigravity', 'pid': os.getpid(), 'start': 'start', 'state': str(state), 'kind': 'tui-pty'}))
module.ROOT = root
def unreadable(_pid, _start):
    raise module.StartTimeUnreadable('synthetic read failure')
module.process_still = unreadable
sys.argv = ['supervisor.py', '--action', 'status', '--project', '/tmp/project', '--team', 'fixture', '--name', 'worker']
stderr = io.StringIO()
with contextlib.redirect_stderr(stderr):
    try:
        module.main()
    except SystemExit as exc:
        assert exc.code == 1
    else:
        raise AssertionError('status accepted an unreadable process identity')
assert 'TUI process identity is unreadable' in stderr.getvalue()
`);
});

test('launches a fake TUI on a real PTY and proceeds from post-receive receipt confirmation through ack', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agmsg-tui-pty-test-'));
  const install = path.join(dir, 'install');
  const project = path.join(dir, 'project');
  fs.mkdirSync(install);
  fs.mkdirSync(project);
  fs.cpSync(path.join(repo, 'scripts'), path.join(install, 'scripts'), { recursive: true });
  const fake = path.join(dir, 'agy');
  fs.writeFileSync(path.join(dir, 'fake.mjs'), `
process.stdin.setRawMode(true);
process.stdout.write('\\x1b[?5W>\\r\\n? for shortcuts  Gemini 3.8 Flash · high\\r\\n');
let input = '';
let permissionBatch = null;
process.stdin.on('data', chunk => {
  input += chunk.toString();
  if (permissionBatch) {
    if (!input.includes('1')) return;
    process.stdout.write('\\x1b[2J\\x1b[HAGMSG_RECEIVED:' + permissionBatch + '\\r\\n>\\r\\n? for shortcuts  Gemini 3.8 Flash · high\\r\\n');
    permissionBatch = null;
    input = '';
    return;
  }
  const match = input.match(/\\[agmsg batch id=([^ ]+) count=/);
  if (!match) {
    if (input === 'D') { process.stdout.write('\\x1b[2J\\x1b[H>\\r\\n? for shortcuts  Gemini 3.8 Flash · high\\r\\n'); input = ''; }
    return;
  }
  if (!input.includes('[/agmsg batch]')) return;
  if (input.includes('PERMISSION_THEN_RECEIPT')) {
    permissionBatch = match[1];
    process.stdout.write('\\x1b[2J\\x1b[HCommand\\r\\n\\r\\nRequesting permission for:\\r\\n   fake safe command\\r\\n\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n  2. No\\r\\n\\r\\n  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command\\r\\nesc to cancel                                                                        Gemini 3.8 Flash · high');
    input = '';
    return;
  }
  if (input.includes('NO_RECEIPT') && !process.env.TEST_REPLAY_RECEIPT) { process.stdout.write(input + '\\r\\n>\\r\\n? for shortcuts  Gemini 3.8 Flash · high\\r\\n'); input = ''; return; }
  const receipt = 'AGMSG_RECEIVED:' + match[1];
  if (input.includes('RENDER_THEN_RECEIPT')) process.stdout.write(input + '\\r\\n');
  process.stdout.write('\\x1b[2J\\x1b[H' + receipt + '\\r\\n>\\r\\n? for shortcuts  Gemini 3.8 Flash · high\\r\\n\\x1b[Z');
  input = '';
});
`);
  fs.writeFileSync(fake, `#!/bin/sh\nexec '${process.execPath}' '${path.join(dir, 'fake.mjs')}'\n`, { mode: 0o700 });
  const env = {
    ...process.env,
    AGMSG_STORAGE_DRIVER: 'sqlite',
    AGMSG_STORAGE_PATH: path.join(install, 'db'),
    AGMSG_CONFIG: path.join(dir, 'config.json'),
  };
  const run = (script, args) => {
    const result = spawnSync('bash', [path.join(install, 'scripts', script), ...args], { env, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    return result.stdout;
  };
  run('join.sh', ['fixture', 'worker', 'antigravity', project]);
  run('join.sh', ['fixture', 'sender', 'codex', project]);
  run('delivery.sh', ['set', 'monitor', 'antigravity', project]);

  const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
  const command = 'stty rows 40 cols 120; exec ' + [
    'bash', quote(path.join(install, 'scripts/drivers/types/antigravity/antigravity-tui-monitor.sh')),
    '--project', quote(project), '--team', 'fixture', '--name', 'worker', '--agy', quote(fake), '--poll', '0.05',
  ].join(' ');
  const ptyRelay = path.join(dir, 'pty-relay.py');
  if (process.platform === 'darwin') fs.writeFileSync(ptyRelay, `
import os
import pty
import select
import sys

pid, master = pty.fork()
if pid == 0:
    os.execlp('bash', 'bash', '-c', sys.argv[1])
while True:
    ready, _, _ = select.select([master, sys.stdin.buffer], [], [])
    if master in ready:
        try:
            data = os.read(master, 8192)
        except OSError:
            break
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    if sys.stdin.buffer in ready:
        data = os.read(sys.stdin.fileno(), 8192)
        if not data:
            break
        os.write(master, data)
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
`);
  const spawnPty = (cmd, childEnv) => process.platform === 'darwin'
    ? spawn('python3', [ptyRelay, cmd], { env: childEnv, stdio: ['pipe', 'pipe', 'pipe'] })
    : spawn('script', ['-qefc', cmd, '/dev/null'], { env: childEnv, stdio: ['pipe', 'pipe', 'pipe'] });
  const child = spawnPty(command, env);
  let output = '';
  child.stdout.on('data', chunk => { output += chunk.toString(); });
  child.stderr.on('data', chunk => { output += chunk.toString(); });
  const waitFor = async predicate => {
    for (let i = 0; i < 200; i += 1) {
      if (predicate()) return;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error(`wait timeout: ${output}`);
  };
  try {
    await waitFor(() => output.includes('? for shortcuts'));
    run('send.sh', ['fixture', 'sender', 'worker', 'PTY E2E']);
    await waitFor(() => output.includes('AGMSG_RECEIVED:') && fs.readdirSync(path.join(install, 'run')).some(name => name.endsWith('.state.json')));
    const stateFile = fs.readdirSync(path.join(install, 'run')).find(name => name.endsWith('.state.json'));
    await waitFor(() => JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')).batch === null);
    assert.match(output, /AGMSG_RECEIVED:/);
    assert.match(run('inbox.sh', ['fixture', 'worker']), /No new messages\./);
    child.stdin.write('D');
    await waitFor(() => JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')).humanInputActive === true);
    assert.match(run('delivery.sh', ['status', 'antigravity', project]), /runtime: worker tui-pty paused/);
    await waitFor(() => JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')).humanInputActive === false);
    assert.match(run('delivery.sh', ['status', 'antigravity', project]), /runtime: worker tui-pty running/);
    run('send.sh', ['fixture', 'sender', 'worker', 'RENDER_THEN_RECEIPT']);
    await waitFor(() => JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')).batch?.messages?.some(message => message.body === 'RENDER_THEN_RECEIPT'));
    await waitFor(() => JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')).batch === null);
    assert.match(run('inbox.sh', ['fixture', 'worker']), /No new messages\./);
    run('send.sh', ['fixture', 'sender', 'worker', 'PERMISSION_THEN_RECEIPT']);
    await waitFor(() => output.includes('Requesting permission for:'));
    await waitFor(() => JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')).batch?.phase === 'sent');
    child.stdin.write('1');
    await waitFor(() => JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')).batch === null);
    const afterPermission = JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8'));
    assert.equal(afterPermission.manualResumeRequired, false, 'a permission confirmation does not raise a durable pause');
    await waitFor(() => JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')).humanInputActive === false);
    run('send.sh', ['fixture', 'sender', 'worker', 'HELD_AFTER_PERMISSION']);
    await waitFor(() => JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')).batch?.messages?.some(message => message.body === 'HELD_AFTER_PERMISSION'));
    await waitFor(() => JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')).batch === null);
    run('send.sh', ['fixture', 'sender', 'worker', 'NO_RECEIPT']);
    await waitFor(() => JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')).batch?.phase === 'sent');
    await new Promise(resolve => setTimeout(resolve, 300));
    const uncertain = JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8'));
    assert.notEqual(uncertain.batch, null);
    const supervisorPath = path.join(install, 'scripts/drivers/types/antigravity/antigravity-tui-supervisor.py');
    const status = spawnSync('python3', [supervisorPath, '--action', 'status', '--project', project, '--team', 'fixture', '--name', 'worker'], { env, encoding: 'utf8' });
    assert.equal(status.status, 0, status.stderr);
    assert.match(status.stdout, /runtime: worker tui-pty busy/);
    const stop = spawnSync('python3', [supervisorPath, '--action', 'stop', '--project', project, '--team', 'fixture', '--name', 'worker'], { env, encoding: 'utf8' });
    assert.equal(stop.status, 0, stop.stderr);
    await waitFor(() => child.exitCode !== null);
    assert.match(run('delivery.sh', ['status', 'antigravity', project]), /runtime: worker tui-pty stopped\/needs-attention/);
    const deadStatus = spawnSync('python3', [supervisorPath, '--action', 'status', '--project', project, '--team', 'fixture', '--name', 'worker'], { env, encoding: 'utf8' });
    assert.equal(deadStatus.status, 0, deadStatus.stderr);
    assert.match(deadStatus.stdout, /runtime: worker tui-pty stopped\/needs-attention/);
    assert.match(stop.stdout, /Stop request sent/);
    assert.match(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8'), /"phase": "uncertain"|"phase":"uncertain"/);
    const unresolvedBeforeRecovery = JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8'));
    const restartRejected = spawnSync('python3', [supervisorPath, '--project', project, '--team', 'fixture', '--name', 'worker', '--agy', fake], { env, encoding: 'utf8' });
    assert.notEqual(restartRejected.status, 0);
    assert.match(restartRejected.stderr, /previous delivery could not be safely marked read/);
    assert.match(restartRejected.stderr, new RegExp('batch: ' + uncertain.batch.id + ' phase=uncertain messages=1'));
    assert.match(restartRejected.stderr, new RegExp('message IDs: ' + uncertain.batch.messages[0].id));
    assert.match(restartRejected.stderr, /does not necessarily mean the messages are unprocessed/);
    assert.match(restartRejected.stderr, /agy-tui status --project/);
    assert.match(restartRejected.stderr, /agy-tui ack --project/);
    assert.match(restartRejected.stderr, /agy-tui replay --project/);
    assert.match(restartRejected.stderr, /Mark read only after confirming the AGMSG_RECEIVED line and reply/);
    assert.match(restartRejected.stderr, /If you cannot decide, do not ack/);
    assert.deepEqual(
      JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')),
      unresolvedBeforeRecovery,
      'a normal-startup refusal from an unresolved batch does not change state',
    );
    const rejected = spawnSync('python3', [supervisorPath, '--action', 'ack', '--project', project, '--team', 'fixture', '--name', 'worker', '--batch', uncertain.batch.id, '--confirm-id', 'wrong-id'], { env, encoding: 'utf8' });
    assert.notEqual(rejected.status, 0);
    assert.deepEqual(
      JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')),
      unresolvedBeforeRecovery,
      'a recovery refusal from an ID mismatch does not change state',
    );
    const replayState = JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8'));
    replayState.humanInputActive = true;
    replayState.humanInputSawNonIdle = true;
    fs.writeFileSync(path.join(install, 'run', stateFile), JSON.stringify(replayState));
    const replayCommand = 'stty rows 40 cols 120; exec ' + ['python3', supervisorPath, '--action', 'replay', '--project', project, '--team', 'fixture', '--name', 'worker', '--agy', fake, '--batch', uncertain.batch.id, '--confirm-id', uncertain.batch.messages[0].id].map(quote).join(' ');
    const replay = spawnPty(replayCommand, { ...env, TEST_REPLAY_RECEIPT: '1' });
    let replayOutput = '';
    replay.stdout.on('data', chunk => { replayOutput += chunk.toString(); });
    replay.stderr.on('data', chunk => { replayOutput += chunk.toString(); });
    try {
      await waitFor(() => JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')).batch === null);
      assert.match(replayOutput, new RegExp('AGMSG_RECEIVED:' + uncertain.batch.id));
    } finally {
      spawnSync('python3', [supervisorPath, '--action', 'stop', '--project', project, '--team', 'fixture', '--name', 'worker'], { env, encoding: 'utf8' });
      await waitFor(() => replay.exitCode !== null);
    }
    assert.match(run('inbox.sh', ['fixture', 'worker']), /No new messages\./);
    const afterReplay = JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8'));
    assert.equal(afterReplay.humanInputActive, false, "an explicit replay clears the previous session's normal-input pause");
    assert.equal(afterReplay.humanInputSawNonIdle, false);
  } finally {
    if (child.exitCode === null) child.stdin.write('\x04');
    await Promise.race([once(child, 'close'), new Promise(resolve => setTimeout(resolve, 5000))]);
    if (child.exitCode === null) child.kill('SIGKILL');
  }
});

test('agy-tui passes only the arguments received after -- through unchanged to the spawned agy, and refuses an unknown option before it (#1291)', async () => {
  // The pass-through has to be scoped to an explicit --, not "whatever
  // agy-tui.sh does not recognize": review of the first version of this fix
  // found that agy-tui.sh's old catch-all treated ANY unrecognized option as
  // the start of pass-through, -- or not, so a typo like --tema would launch
  // agy carrying it instead of failing loudly. Both directions are pinned
  // here, through the real entry point (agy-tui.sh itself, not the Python
  // supervisor invoked directly -- bypassing agy-tui.sh would let this pass
  // even if the shell layer stopped forwarding args after -- correctly).
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agmsg-tui-argv-test-'));
  const install = path.join(dir, 'install');
  const project = path.join(dir, 'project');
  fs.mkdirSync(install);
  fs.mkdirSync(project);
  fs.cpSync(path.join(repo, 'scripts'), path.join(install, 'scripts'), { recursive: true });
  const env = {
    ...process.env,
    AGMSG_STORAGE_DRIVER: 'sqlite',
    AGMSG_STORAGE_PATH: path.join(install, 'db'),
    AGMSG_CONFIG: path.join(dir, 'config.json'),
  };
  const run = (script, args) => {
    const result = spawnSync('bash', [path.join(install, 'scripts', script), ...args], { env, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    return result.stdout;
  };
  run('join.sh', ['fixture', 'worker', 'antigravity', project]);
  run('delivery.sh', ['set', 'monitor', 'antigravity', project]);
  const dump = path.join(dir, 'argv-dump.txt');
  const fake = path.join(dir, 'agy');
  fs.writeFileSync(
    fake,
    `#!/bin/sh\nprintf '%s\\n' "$@" > ${JSON.stringify(dump)}\necho READY\nwhile :; do sleep 1; done\n`,
    { mode: 0o700 },
  );
  const agyTuiPath = path.join(install, 'scripts/drivers/types/antigravity/agy-tui.sh');

  // A typo before -- must be refused, not silently forwarded to agy.
  const typo = spawnSync(
    'bash',
    [agyTuiPath, 'status', '--project', project, '--team', 'fixture', '--name', 'worker', '--tema', 'oops'],
    { env, encoding: 'utf8' },
  );
  assert.notEqual(typo.status, 0);
  assert.match(typo.stderr, /unknown option --tema/);

  // A trailing -- with nothing after it must not crash: bash 3.2 (what CI's
  // macOS runners actually use) treats expanding an assigned-but-empty array
  // under `set -u` as an unbound-variable error, not silently-empty.
  const emptyDashDash = spawnSync(
    'bash',
    [agyTuiPath, 'status', '--project', project, '--team', 'fixture', '--name', 'worker', '--'],
    { env, encoding: 'utf8' },
  );
  assert.equal(emptyDashDash.status, 0, emptyDashDash.stderr + emptyDashDash.stdout);

  // --batch/--confirm-id are supervisor flags for ack/replay recovery, not
  // agy-tui's own -- they relied on the old catch-all to reach the
  // supervisor and were the actual CI failure once that catch-all became a
  // hard refusal: without an explicit exemption they read as a typo too.
  const ack = spawnSync(
    'bash',
    [agyTuiPath, 'ack', '--project', project, '--team', 'fixture', '--name', 'worker', '--batch', 'batch-1', '--confirm-id', 'message-1'],
    { env, encoding: 'utf8' },
  );
  assert.equal(ack.status, 1, ack.stderr + ack.stdout);
  assert.match(ack.stderr, /no reservation or state exists for recovery/);

  const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
  const command = 'stty rows 40 cols 120; exec ' + [
    'bash', agyTuiPath, '--project', project, '--team', 'fixture', '--name', 'worker',
    '--agy', fake, '--', '--dangerously-skip-permissions', '--extra-marker=agmsg-e2e-42',
  ].map(quote).join(' ');
  const ptyRelay = path.join(dir, 'pty-relay.py');
  if (process.platform === 'darwin') fs.writeFileSync(ptyRelay, `
import os
import pty
import select
import sys

pid, master = pty.fork()
if pid == 0:
    os.execlp('bash', 'bash', '-c', sys.argv[1])
while True:
    ready, _, _ = select.select([master, sys.stdin.buffer], [], [])
    if master in ready:
        try:
            data = os.read(master, 8192)
        except OSError:
            break
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    if sys.stdin.buffer in ready:
        data = os.read(sys.stdin.fileno(), 8192)
        if not data:
            break
        os.write(master, data)
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
`);
  const spawnPty = cmd => process.platform === 'darwin'
    ? spawn('python3', [ptyRelay, cmd], { env, stdio: ['pipe', 'pipe', 'pipe'] })
    : spawn('script', ['-qefc', cmd, '/dev/null'], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  const child = spawnPty(command);
  let output = '';
  child.stdout.on('data', chunk => { output += chunk.toString(); });
  child.stderr.on('data', chunk => { output += chunk.toString(); });
  try {
    for (let i = 0; i < 200 && !fs.existsSync(dump); i += 1) await new Promise(resolve => setTimeout(resolve, 50));
    assert.ok(fs.existsSync(dump), `could not detect the fake agy launch: ${output}`);
    const argv = fs.readFileSync(dump, 'utf8').split('\n').filter(Boolean);
    assert.deepEqual(argv, ['--dangerously-skip-permissions', '--extra-marker=agmsg-e2e-42']);
  } finally {
    child.kill('SIGKILL');
    await Promise.race([once(child, 'close'), new Promise(resolve => setTimeout(resolve, 3000))]);
  }
});

test('a claim refusal shows the pid of the holding supervisor and the stop command', () => {
  runPython(`
import importlib.util, json, os, tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

root = Path(tempfile.mkdtemp())
module.ROOT = root
(root / 'run').mkdir()
project = root / 'proj'
project.mkdir()
state = root / 'state.json'
state.write_text(json.dumps({'project': str(project.absolute()), 'team': 'demo', 'role': 'agy'}))
pid = os.getpid()
(root / 'run' / 'read-reservation.seat.json').write_text(json.dumps(
    {'type': 'antigravity', 'kind': 'tui-pty', 'pid': pid,
     'start': module.proc_start(pid), 'state': str(state)}))

verdict = 'held:00000000-0000-0000-0000-000000000000.%d' % pid
message = module.explain_claim_refusal(verdict, str(project), 'demo', 'agy')

# The verdict alone is what this replaces, so it must not survive as the answer.
assert message != verdict, 'the raw held: verdict is coming through unchanged'
assert 'demo/agy' in message, 'no mention of which seat this is about'
assert str(pid) in message, 'no pid of the holding process'
assert 'supervisor' in message, 'no mention of what is holding it'
assert 'agy-tui stop' in message, 'no next action given'
assert '--name agy' in message, 'the stop command does not point at this role'

# An owner token this cannot decode keeps its original wording rather than being
# dressed up as a diagnosis.
assert module.explain_claim_refusal('unknown:claim_failed', str(project), 'demo', 'agy') == 'unknown:claim_failed'
assert module.explain_claim_refusal('held:no-pid-here', str(project), 'demo', 'agy') == 'held:no-pid-here'
`);
});
