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

test('許可画面・draftでは投入せず、preparedだけを空の入力欄へ再投入する', () => {
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
draw('過去の受信本文: Requesting permission\\r\\n過去の受信本文: Do you want to proceed?\\r\\n>\\r\\n? for shortcuts  Gemini 3.8 Flash · high')
assert s.input_ready(), '過去の本文の語句で配送を止めない'
for tail in [b'\\x1b[', b'\\x1b]title', b'\\xe3']:
    draw('>\\r\\n? for shortcuts')
    s.screen.feed(tail)
    assert not s.input_ready(), '描画途中は投入しない'
draw('>\\r\\n? for shortcuts  Gemini 3.8 Flash · high')
s.last_output = module.time.monotonic()
assert not s.input_ready(), '出力直後は投入しない'
s.last_output = 0
s.state['manualResumeRequired'] = True
s.maybe_poll()
assert sent == [], '保存されたpauseも保持する'
s.state['manualResumeRequired'] = False
s.maybe_poll()
assert sent == ['injected']
s.maybe_poll()
assert sent == ['injected'], 'sent batchは自動再送しない'
s.state['batch']['phase'] = 'uncertain'
s.maybe_poll()
assert sent == ['injected'], 'uncertain batchは自動再送しない'
`);
});

test('注入直前に未処理のchild出力または人間入力があればpreparedで保留する', () => {
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
s.inject = lambda: (_ for _ in ()).throw(AssertionError('pending I/O中にinjectした'))
saw = {'calls': 0}
def pending_after_peek(*_args):
    saw['calls'] += 1
    return ([], [], []) if saw['calls'] == 1 else ([99], [], [])
module.select.select = pending_after_peek
s.maybe_poll()
assert s.state['batch']['phase'] == 'prepared'
`);
});

test('実agy 1.1.27の画面断片はidleだけを注入可能と判定する', () => {
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

test('狭幅のfooter/NAV折返しは最下部だけを再構成し、本文の語句ではidleと誤認しない', () => {
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
assert not ready('本文末尾: ? for shortcuts  Gemini 3.8 Flash ·\\r\\n high\\r\\n▸ Generating...\\r\\n>\\r\\n────────────────────────────────\\r\\nesc to cancel'), '本文のfooter語句を生成中と誤認しない'
assert not ready('? for shortcuts quoted in body\\r\\n▸ Generating...\\r\\n>\\r\\n────────────────────────────────\\r\\nesc to cancel'), '行頭footer語句を生成中と誤認しない'
assert not ready('>\\r\\n? for shortcuts\\r\\nRequesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n↑/↓ Navigate\\r\\nesc to cancel'), '本文idle署名を許可modalと誤認しない'
for cols in (18,23,24,27,28,40,80,120):
    s=module.Supervisor.__new__(module.Supervisor)
    s.screen=module.TerminalScreen(24,cols); s.last_output=0
    s.screen.feed(('>\\r\\n'+'─'*cols+'\\r\\n? for shortcuts  Gemini 3.8 Flash · high').encode())
    assert s.input_ready(), (cols,s.screen.lines())
s=module.Supervisor.__new__(module.Supervisor)
s.screen=module.TerminalScreen(24,120); s.last_output=0
s.screen.feed('>\\r\\n? for shortcuts  Gemini 3.8 Flash · high\\r\\nRequesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n↑/↓ Navigate\\r\\nesc to cancel'.encode())
assert not s.input_ready(), '本文全体がfooterを模しても許可modalへ注入しない'
s=module.Supervisor.__new__(module.Supervisor)
s.screen=module.TerminalScreen(24, 40); s.last_output=0
s.screen.feed('Requesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n↑/↓ Navigate · tab Amend · ctrl+g\\r\\n edit/expand command\\r\\nesc to cancel  Gemini 3.8 Flash ·\\r\\n high'.encode())
assert s.permission_input_ready(), 'permissionのNAV/footer折返しを許可する'
`);
});

test('本文にidle署名を含むbatchはack後の後続自動配送を停止する', () => {
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

test('idle署名を含むbatchのackはmanual resumeを要求する', () => {
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

test('alternate screen切替は以前に検知した未知CSIを正常状態へ戻さない', () => {
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
assert screen.uncertain is True, '切替は旧画面を消しても未知CSIの検知を消さない'
`);
});

test('agy Read表示のDECST8CとCBTは画面モデルで扱い、それ以外のWはfail-closedにする', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
screen = module.TerminalScreen(4, 40)
screen.feed(b'\\x1b[?5W')
assert not screen.uncertain, 'agyのDECST8Cは既定tab stopと同じ'
screen.feed(b'123456789012\\x1b[ZX')
assert screen.lines()[0].startswith('12345678X012')
assert not screen.uncertain, 'Read後に出るCBTでreceipt判定を停止しない'
screen.feed(b'\\x1b[?4W')
assert screen.uncertain, '観測していないtab制御は許容しない'
`);
});

test('TUI envelope は複数メッセージをID順に一対一で表現する', () => {
  runPython(`
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
s = module.Supervisor.__new__(module.Supervisor)
batch = {'id': 'batch-1', 'messages': [
  {'id': 'm-1', 'from': 'agy', 'at': '2026-09-06T06:00:00Z', 'body': '一件目'},
  {'id': 'm-2', 'from': 'claude', 'at': '2026-09-06T06:01:00Z', 'body': '二件目\\x1b'},
]}
text = s.envelope(batch)
assert '[agmsg batch id=batch-1 ' in text
assert 'count=2' in text
assert text.index('id=m-1') < text.index('id=m-2')
assert text.count('[/agmsg message]') == 2
assert '\\\\x1b' in text
assert 'AGMSG_RECEIVED:batch-1' not in text
assert 'ASCIIコロン（U+003A）、batch idを空白なしで連結' in text
`);
});

test('TUI注入はbracketed pasteとCRを付け、送信状態を保存する', () => {
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
  {'id': 'm-1', 'from': 'agy', 'at': '2026-09-06T06:00:00Z', 'body': '本文'},
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

test('通常の人間入力は耐久pauseを立てず一時保留にする', () => {
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
assert notice.getvalue().count('空の入力待ちに戻れば自動再開') == 1
`);
});

test('通常入力はnon-idle後の安定idleでだけ自動復帰する', () => {
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
assert s.state['humanInputActive'] is True, '古いidleだけでは解除しない'
ready['value'] = False
s.update_human_input_state()
assert s.state['humanInputSawNonIdle'] is True
ready['value'] = True
s.update_human_input_state()
now['value'] += 0.59
s.update_human_input_state()
assert s.state['humanInputActive'] is True, '安定期間未満では解除しない'
ready['value'] = False
s.update_human_input_state()
assert s.human_idle_since is None, '途中の非idleで安定観測をリセットする'
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
assert s.state['humanInputActive'] is True, '未解決batchでは解除しない'
`);
});

test('再起動復帰は新screenの安定idleだけを要求し、耐久状態は解除しない', () => {
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

test('実測済みの許可UIだけは受信turn中の人間確認入力を許可する', () => {
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
assert s.permission_input_ready()
s.screen = screen('trust')
assert s.permission_input_ready()
for name in ('idle', 'generating'):
    s.screen = screen(name)
    assert not s.permission_input_ready(), name
s.screen = module.TerminalScreen(28, 120)
s.screen.feed(b'Requesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n? for shortcuts')
assert not s.permission_input_ready(), '受信本文の語句だけで許可しない'
s.screen = module.TerminalScreen(24, 120)
s.screen.feed('Requesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n↑/↓ Navigate · tab Amend\\r\\n▸ Generating...\\r\\n>\\r\\n────────────────────────────────\\r\\nesc to cancel'.encode())
assert not s.permission_input_ready(), '生成中chromeと受信本文の語句・Nav行を許可UIと誤認しない'
s.screen = module.TerminalScreen(24, 120)
s.screen.feed('Requesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n↑/↓ Navigate · tab Amend\\r\\nesc to cancel'.encode())
assert s.permission_input_ready(), 'Nav行を本文で供給できる合成画面は判定上modalと区別できない'
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
assert s.permission_input_ready(), 'Orca実画面の長いpermission選択肢も許可UIとして認識する'
diagnostic = s.permission_screen_diagnostic()
assert 'rows=40,cols=154' in diagnostic
assert "'request': [1]" in diagnostic
assert "'footer': [9]" in diagnostic
assert 'whoami.sh' not in diagnostic, 'command本文を診断へ含めない'
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
assert s.permission_input_ready(), '長い引用付き選択肢の折返しが12行を超えても許可UIとして認識する'
s.screen = module.TerminalScreen(24, 120)
s.screen.feed('Requesting permission for:\\r\\nDo you want to proceed?\\r\\n> 1. Yes\\r\\n  4. No\\r\\n↑/↓ Navigate · tab Amend\\r\\n▸ Generating...\\r\\n>\\r\\n────────────────────────────────\\r\\nesc to cancel'.encode())
assert not s.permission_input_ready(), 'navとfooterの間に通常画面がある合成表示は許可しない'
s.screen = module.TerminalScreen(24, 120)
s.screen.feed('> 1. Yes\\r\\nRequesting permission for:\\r\\nDo you want to proceed?\\r\\n↑/↓ Navigate · tab Amend\\r\\nesc to cancel'.encode())
assert not s.permission_input_ready(), '必須要素の並びが許可modalと異なる合成表示は許可しない'
s.state = {'batch': {'id': 'batch', 'phase': 'sent'}, 'manualResumeRequired': True,
           'humanInputActive': False, 'humanInputSawNonIdle': False,
           'supervisorPhase': 'WAITING_FOR_RESULT'}
s.human_idle_since = None
s.save = lambda: None
notice = io.StringIO()
with contextlib.redirect_stderr(notice): s.allow_permission_input()
assert s.state['batch']['phase'] == 'sent'
assert s.state['manualResumeRequired'] is True, '既存の耐久pauseには触らない'
assert s.state['humanInputActive'] is True
assert s.state['humanInputSawNonIdle'] is True
assert s.state['supervisorPhase'] == 'WAITING_FOR_RESULT'
assert '受領確認後、空の入力待ちに戻れば自動再開' in notice.getvalue()
`);
});

test('child描画と親入力が同時readyならpermission画面を先に反映する', () => {
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

test('permission入力と同時の部分再描画でmodalが消えても直前画面で分類する', () => {
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

test('read-denied停止には安全な復旧案内を表示する', () => {
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
    s.fail('通常inboxによる既読試行を検知')
assert 'agy-tui reset-guard' in out.getvalue()
assert 'ackせず停止します' in out.getvalue()
assert s.state['durableAttention'] is True
`);
});

test('reset-guardは停止中かつbatchなしの場合だけviolationを解除する', () => {
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
    assert '未解決batch' in str(error)
else:
    raise AssertionError('未解決batchを拒否しなかった')
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
    assert '稼働中' in str(error)
else:
    raise AssertionError('稼働中supervisorを拒否しなかった')
assert s.violations.read_text() == 'keep'
assert calls == ['claim', 'release', 'claim', 'release']
`);
});

test('receiptはread chunk境界をまたいでも画面上の完全行として判定できる', () => {
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

test('狭いagy画面で物理行に折り返されたreceiptもUUID全体で照合する', () => {
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
assert not screen.has_line(expected), '連続行がUUID全体を構成しなければackしない'
`);
});

test('本文が折り返しreceipt全体を含むbatchはack対象にしない', () => {
  runPython(`
import importlib.util
spec = importlib.util.spec_from_file_location('supervisor', ${JSON.stringify(supervisor)})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
receipt = 'AGMSG_RECEIVED:203b95e7-b27e-4584-890a-aecb99599438'
assert module.Supervisor.batch_contains_receipt({'receipt': receipt, 'messages': [
  {'body': '調査用\\n  AGMSG_RECEIVED:203b95e7-b27e-4584-890a-\\n  aecb99599438'},
]})
assert not module.Supervisor.batch_contains_receipt({'receipt': receipt, 'messages': [
  {'body': '[agmsg batch id=203b95e7-b27e-4584-890a-aecb99599438]'},
  {'body': 'AGMSG_RECEIVED:<batch-id>'},
]})
`);
});

test('実agy型の差分描画を復元し、alternate screen切替では旧画面を捨てる', () => {
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

test('全角セルの片側上書きや編集で偽receiptを合成しない', () => {
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

test('受信turn中のresizeは画面判定を不確実にする', () => {
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

test('親terminalのwinsizeをagy PTYへ同期する', () => {
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

test('TUI monitor は対話端末でない起動を拒否する', () => {
  const wrapper = new URL('../scripts/drivers/types/antigravity/antigravity-tui-monitor.sh', import.meta.url).pathname;
  const result = spawnSync('bash', [wrapper, '--help'], { encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /対話端末/);
  const status = spawnSync('bash', [wrapper, 'status', '--project', '/tmp', '--team', 'no-such-team', '--name', 'no-such-role'], { encoding: 'utf8' });
  assert.equal(status.status, 0, status.stderr);
  assert.match(status.stdout, /tui-pty 未起動/);
});

test('偽TUIを実PTYで起動し、受信後のreceipt確認からackまで進める', async () => {
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
  const child = spawn('script', ['-qefc', command, '/dev/null'], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk.toString(); });
  child.stderr.on('data', chunk => { output += chunk.toString(); });
  const waitFor = async predicate => {
    for (let i = 0; i < 200; i += 1) {
      if (predicate()) return;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error(`待機timeout: ${output}`);
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
    assert.equal(afterPermission.manualResumeRequired, false, '許可確認で耐久pauseを立てない');
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
    assert.match(run('delivery.sh', ['status', 'antigravity', project]), /runtime: worker tui-pty 停止\/要確認/);
    const deadStatus = spawnSync('python3', [supervisorPath, '--action', 'status', '--project', project, '--team', 'fixture', '--name', 'worker'], { env, encoding: 'utf8' });
    assert.equal(deadStatus.status, 0, deadStatus.stderr);
    assert.match(deadStatus.stdout, /runtime: worker tui-pty 停止\/要確認/);
    assert.match(stop.stdout, /停止要求を送信しました/);
    assert.match(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8'), /"phase": "uncertain"|"phase":"uncertain"/);
    const unresolvedBeforeRecovery = JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8'));
    const restartRejected = spawnSync('python3', [supervisorPath, '--project', project, '--team', 'fixture', '--name', 'worker', '--agy', fake], { env, encoding: 'utf8' });
    assert.notEqual(restartRejected.status, 0);
    assert.match(restartRejected.stderr, /未解決batch/);
    assert.deepEqual(
      JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')),
      unresolvedBeforeRecovery,
      '未解決batchによる通常起動拒否でstateを変更しない',
    );
    const rejected = spawnSync('python3', [supervisorPath, '--action', 'ack', '--project', project, '--team', 'fixture', '--name', 'worker', '--batch', uncertain.batch.id, '--confirm-id', 'wrong-id'], { env, encoding: 'utf8' });
    assert.notEqual(rejected.status, 0);
    assert.deepEqual(
      JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8')),
      unresolvedBeforeRecovery,
      'ID不一致による復旧拒否でstateを変更しない',
    );
    const replayState = JSON.parse(fs.readFileSync(path.join(install, 'run', stateFile), 'utf8'));
    replayState.humanInputActive = true;
    replayState.humanInputSawNonIdle = true;
    fs.writeFileSync(path.join(install, 'run', stateFile), JSON.stringify(replayState));
    const replayCommand = 'stty rows 40 cols 120; exec ' + ['python3', supervisorPath, '--action', 'replay', '--project', project, '--team', 'fixture', '--name', 'worker', '--agy', fake, '--batch', uncertain.batch.id, '--confirm-id', uncertain.batch.messages[0].id].map(quote).join(' ');
    const replay = spawn('script', ['-qefc', replayCommand, '/dev/null'], { env: { ...env, TEST_REPLAY_RECEIPT: '1' }, stdio: ['pipe', 'pipe', 'pipe'] });
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
    assert.equal(afterReplay.humanInputActive, false, '明示replayは旧セッションの通常入力pauseを解除する');
    assert.equal(afterReplay.humanInputSawNonIdle, false);
  } finally {
    if (child.exitCode === null) child.stdin.write('\x04');
    await Promise.race([once(child, 'close'), new Promise(resolve => setTimeout(resolve, 5000))]);
    if (child.exitCode === null) child.kill('SIGKILL');
  }
});
