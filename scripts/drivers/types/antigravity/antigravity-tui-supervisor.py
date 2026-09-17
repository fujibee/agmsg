#!/usr/bin/env python3
"""POSIX PTY owner for one Antigravity TUI and one agmsg role.

The supervisor and its headless sibling use the same process identity contract
on Linux and macOS. Windows remains refused by the shell wrapper because it
does not provide the POSIX PTY and advisory-lock primitives used here.
"""
import argparse, codecs, errno, fcntl, hashlib, json, os, pty, re, select, shlex, signal, struct, subprocess, sys, termios, time, tty, unicodedata, uuid
from pathlib import Path

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
TRANSPORT=str(HERE/'inbox-transport.sh')

def encode_component(value):
    return ''.join(chr(byte) if chr(byte).isalnum() and byte < 128 or chr(byte) in '._-' else f'%{byte:02X}' for byte in str(value).encode())

def atomic(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp=path.with_name(path.name+f'.{os.getpid()}.tmp')
    fd=os.open(tmp, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(value, f, ensure_ascii=False); f.write('\n'); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)

class StartTimeUnreadable(OSError):
    """We could not find out when a pid started -- NOT that the pid is gone.

    Deliberately not a subclass of FileNotFoundError: the three call sites that
    displace a reservation catch FileNotFoundError to mean "gone", and this must
    not land there. Being an OSError keeps it in the family a caller would
    reasonably catch when it wants to handle every read problem itself.
    """

def proc_start(pid):
    """Return the process start token from the native POSIX process table.

    A pid alone is not an identity: pids are recycled, and every comparison of
    this value in this file exists to separate "the same process" from "a
    different process that inherited its number".

    Linux uses /proc clock ticks; macOS uses the shared libproc helper, which
    supplies parent, state, and a microsecond start token from one kernel
    snapshot. A read failure remains a separate exception from a confirmed
    missing pid.

    TWO exception types, and the split is the whole point. Callers catch
    FileNotFoundError to mean "that pid is gone" and then unlink a reservation,
    reclaim it, or run a recovery. Only a genuine ENOENT may reach them. Anything
    else -- EACCES on a hardened /proc, EIO, a /proc that is not mounted -- is
    StartTimeUnreadable, which those handlers do NOT catch, so it propagates and
    the act does not happen.

    A live supervisor whose process table cannot be read must therefore keep its
    reservation rather than being mistaken for a stale process.
    """
    if sys.platform == 'darwin':
        try:
            result=subprocess.run([sys.executable,str(ROOT/'scripts/drivers/types/antigravity/mac-process-info.py'),str(pid)],capture_output=True,text=True)
        except OSError as exc:
            raise StartTimeUnreadable(f'pid {pid} の起動時刻を判定できません (libproc: {exc.strerror})') from exc
        if result.returncode == 1:
            raise FileNotFoundError(errno.ENOENT, f'pid {pid} is not running')
        if result.returncode != 0:
            raise StartTimeUnreadable(f'pid {pid} の起動時刻を判定できません (libproc)')
        fields=result.stdout.strip().split('\t')
        if len(fields)!=3 or not fields[2].startswith('darwin:'):
            raise StartTimeUnreadable(f'pid {pid} の起動時刻を判定できません (libproc output)')
        return fields[2]
    if sys.platform != 'linux':
        raise StartTimeUnreadable(f'pid {pid} の起動時刻を判定できません (unsupported platform: {sys.platform})')
    try:
        raw=Path(f'/proc/{pid}/stat').read_text()
    except FileNotFoundError as exc:
        # ENOENT, and the only reading that means "gone" -- but only if /proc is
        # actually there. On a system with no /proc at all, every pid looks
        # absent, and that is a fact about the system, not about the process.
        if not Path('/proc').is_dir():
            raise StartTimeUnreadable(f'pid {pid} の起動時刻を判定できません (/proc がありません)') from exc
        raise
    except OSError as exc:
        raise StartTimeUnreadable(f'pid {pid} の起動時刻を判定できません (/proc/{pid}/stat: {exc.strerror})') from exc
    token=raw.split(') ',1)[1].split()[19]
    if not token.isdigit():
        raise StartTimeUnreadable(f'pid {pid} の起動時刻を判定できません (/proc/{pid}/stat の 22 番目が数値ではありません)')
    return token

def process_still(pid, start):
    """True if pid is the SAME process that token was taken from, False if it is
    positively gone. Raises StartTimeUnreadable when we could not find out.

    One place, deliberately. The three callers that use this are each about to
    take something away from whoever holds the reservation, and each of them had
    its own `except` clause. Three separate handlers is how the fourth one comes
    out facing the other way -- the same reason inbox-transport.sh has a single
    _owner_check. "Could not read" never reaches them as False.
    """
    try:
        return proc_start(pid)==start
    except FileNotFoundError:
        return False

def tui_reservation_state(project, team, role, pid):
    """How the seat's published TUI reservation sees `pid`.

    'live' / 'gone' / 'unknown' when a reservation for this seat names that pid,
    None when nothing on disk names it. The refusal message below is the only
    caller: it turns an owner token into something an operator can act on, so a
    reservation it cannot parse must not be reported as a verdict about the
    process. Every unreadable file is skipped rather than raised on -- this runs
    on the failure path of a claim, and a bad file there would replace a message
    that already says something true with one that says nothing.
    """
    for file in list((ROOT/'run').glob('read-reservation.*.json'))+list((ROOT/'run').glob('antigravity-reservation.*.json')):
        try:
            reservation=json.loads(file.read_text())
            if reservation.get('kind')!='tui-pty' or int(reservation.get('pid'))!=pid: continue
            state=json.loads(Path(reservation['state']).read_text())
            if state.get('project')!=str(Path(project).absolute()) or state.get('team')!=team or state.get('role')!=role: continue
        except (OSError,KeyError,TypeError,ValueError,json.JSONDecodeError):
            continue
        try: return 'live' if process_still(pid,reservation['start']) else 'gone'
        except (StartTimeUnreadable,OSError,KeyError,TypeError,ValueError): return 'unknown'
    return None

def explain_claim_refusal(detail, project, team, role):
    """Turn `held:<owner>` into the state of the world plus the next command.

    Shaped after the Codex bridge report in
    `scripts/drivers/types/codex/_delivery.sh:163` -- subject line carrying
    `<team>/<role> <state> (<why>)`, then the remedy as an indented sentence,
    then the command itself indented under it. The same class of problem
    (something else holds this seat, so it is not available here) already has an
    answer in this project, and antigravity should not invent a second one.

    What the raw verdict leaves out is all of it. The token is `<uuid>.<pid>`:
    the uuid is minted per supervisor and identifies nothing a reader can look
    up, and the pid is not labelled as one -- so the operator sees a bare number
    and no way to learn that a TUI supervisor for this very seat is still
    running, nor that `stop` reaches it from any terminal. The reservation this
    seat publishes already holds those facts, and `status` already renders them.

    Anything this cannot decode is returned untouched: an unrecognised verdict
    keeps its original wording rather than being dressed up as a diagnosis.
    """
    if not detail.startswith('held:'): return detail
    pid=detail[len('held:'):].rsplit('.',1)[-1]
    if not pid.isdigit(): return detail
    seat=f'--project {shlex.quote(str(Path(project).absolute()))} --team {shlex.quote(team)} --name {shlex.quote(role)}'
    state=tui_reservation_state(project,team,role,int(pid))
    if state=='live':
        return (f'{team}/{role} 稼働中のTUI supervisorが保持しています (PID {pid})\n'
                f'  停止してから起動し直してください。別の端末・別のセッションから起動したものにも届きます:\n'
                f'    agy-tui stop {seat}\n'
                f'  状態の確認: agy-tui status {seat}')
    if state in ('gone','unknown'):
        why='既に終了しています' if state=='gone' else '生死を判定できません'
        return (f'{team}/{role} このseatのTUI予約はPID {pid}を指していますが、その processは{why}\n'
                f'  状態を確認してから判断してください:\n'
                f'    agy-tui status {seat}')
    return (f'{team}/{role} PID {pid}が保持していますが、このseatのTUI予約はそのpidを指していません\n'
            f'  別種のセッションが同じroleを保持している可能性があります。状態を確認してください:\n'
            f'    agy-tui status {seat}')

class TerminalScreen:
    """Fail-closed VT screen model limited to the range needed for receipt checks."""
    def __init__(self, rows, cols):
        self.rows=max(1,rows); self.cols=max(1,cols); self.cells=[[' ']*self.cols for _ in range(self.rows)]
        self.row=0; self.col=0; self.saved=(0,0); self.state='normal'; self.sequence=''; self.decoder=codecs.getincrementaldecoder('utf-8')('replace'); self.uncertain=False; self.uncertain_reason=None; self.alternate_screen=False
    def mark_uncertain(self, reason):
        self.uncertain=True
        if self.uncertain_reason is None:self.uncertain_reason=reason
    def resize(self, rows, cols):
        rows=max(1,rows); cols=max(1,cols)
        if (rows,cols)==(self.rows,self.cols): return False
        new=[[' ']*cols for _ in range(rows)]
        for r in range(min(rows,self.rows)):
            for c in range(min(cols,self.cols)): new[r][c]=self.cells[r][c]
        self.rows=rows; self.cols=cols; self.cells=new; self.row=min(self.row,rows-1); self.col=min(self.col,cols-1)
        for r in range(self.rows): self._normalize_row(r)
        self.mark_uncertain('resize')
        return True
    def clear(self):
        self.cells=[[' ']*self.cols for _ in range(self.rows)]; self.row=0; self.col=0
    def _scroll(self):
        while self.row>=self.rows: self.cells.pop(0); self.cells.append([' ']*self.cols); self.row-=1
    def _linefeed(self): self.row+=1; self._scroll()
    @staticmethod
    def _wide_lead(cell):
        return bool(cell) and unicodedata.east_asian_width(cell[0]) in ('W','F')
    def _detach_cell(self, row, col):
        if not (0<=col<self.cols): return
        if self.cells[row][col]=='':
            self.cells[row][col]=' '
            if col and self._wide_lead(self.cells[row][col-1]): self.cells[row][col-1]=' '
        elif self._wide_lead(self.cells[row][col]):
            self.cells[row][col]=' '
            if col+1<self.cols and self.cells[row][col+1]=='': self.cells[row][col+1]=' '
    def _normalize_row(self, row):
        for col in range(self.cols):
            cell=self.cells[row][col]
            if cell=='':
                if not col or not self._wide_lead(self.cells[row][col-1]): self.cells[row][col]='�'
            elif self._wide_lead(cell) and (col+1>=self.cols or self.cells[row][col+1]!=''):
                self.cells[row][col]='�'
    def _clear_range(self, row, start, end):
        start=max(0,start); end=min(self.cols,end)
        if start<end and self.cells[row][start]=='': start=max(0,start-1)
        if start<end and end<self.cols and self.cells[row][end]=='': end+=1
        self.cells[row][start:end]=[' ']*(end-start)
    def _write(self, ch):
        width=0 if unicodedata.combining(ch) else 2 if unicodedata.east_asian_width(ch) in ('W','F') else 1
        if width==0:
            if self.col: self.cells[self.row][self.col-1]+=ch
            return
        if self.col+width>self.cols: self.col=0; self._linefeed()
        self._detach_cell(self.row,self.col)
        if width==2:self._detach_cell(self.row,self.col+1)
        self.cells[self.row][self.col]=ch
        if width==2 and self.col+1<self.cols:self.cells[self.row][self.col+1]=''
        self.col+=width
        if self.col>=self.cols:self.col=self.cols
    @staticmethod
    def _params(body):
        body=body.lstrip('?><=!')
        body=re.sub(r'[ -/]', '', body)
        return [int(x) if x.isdigit() else 0 for x in body.split(';')] if body else [0]
    def _csi(self, sequence):
        final=sequence[-1]; body=sequence[:-1]; p=self._params(body); n=p[0] or 1
        if final=='A': self.row=max(0,self.row-n)
        elif final=='B': self.row=min(self.rows-1,self.row+n)
        elif final=='C': self.col=min(self.cols,self.col+n)
        elif final=='D': self.col=max(0,self.col-n)
        elif final=='E': self.row=min(self.rows-1,self.row+n); self.col=0
        elif final=='F': self.row=max(0,self.row-n); self.col=0
        elif final=='G': self.col=min(self.cols-1,n-1)
        elif final=='Z' and not body.startswith(('?','>','=')):
            # CBT (Cursor Backward Tabulation) appears in agy 1.1.27 Read output.
            # Handle only the default eight-column tab stops initialized by DECST8C.
            for _ in range(n): self.col=max(0,((max(1,self.col)-1)//8)*8)
        elif final in ('H','f'):
            self.row=min(self.rows-1,max(0,(p[0] or 1)-1)); self.col=min(self.cols-1,max(0,(p[1] if len(p)>1 else 1)-1))
        elif final=='d': self.row=min(self.rows-1,max(0,n-1))
        elif final=='J':
            if p[0] in (2,3): self.clear()
            elif p[0]==0:
                self._clear_range(self.row,self.col,self.cols)
                for r in range(self.row+1,self.rows):self.cells[r]=[' ']*self.cols
            elif p[0]==1:
                for r in range(self.row):self.cells[r]=[' ']*self.cols
                self._clear_range(self.row,0,self.col+1)
        elif final=='K':
            if p[0]==0:self._clear_range(self.row,self.col,self.cols)
            elif p[0]==1:self._clear_range(self.row,0,self.col+1)
            elif p[0]==2:self.cells[self.row]=[' ']*self.cols
        elif final=='X': self._clear_range(self.row,self.col,min(self.cols,self.col+n))
        elif final=='P':
            end=min(self.cols,self.col+n); self.cells[self.row][self.col:]=self.cells[self.row][end:]+[' ']*(end-self.col)
            self._normalize_row(self.row)
        elif final=='@':
            self.cells[self.row][self.col:]=([' ']*n+self.cells[self.row][self.col:])[:self.cols-self.col]
            self._normalize_row(self.row)
        elif final=='s': self.saved=(self.row,self.col)
        elif final=='u' and not body.startswith(('?','>','=')): self.row,self.col=self.saved
        elif final in ('h','l') and body.startswith('?') and any(value in (47,1047,1049) for value in p):
            # agy 1.1.27 uses the alternate screen as the normal screen throughout.
            # Discard the old screen on a switch and require a complete idle render again.
            self.alternate_screen=final=='h'; self.clear()
        elif final=='W' and body=='?5':
            # DECST8C restores tab stops from column nine every eight columns, matching CBT/HT defaults.
            pass
        elif final in ('m','h','l','p','q','t','u','~'): pass
        else:self.mark_uncertain(f'unsupported-csi:{body}{final}')
    def feed(self, data):
        for ch in self.decoder.decode(data):
            if self.state=='osc':
                if ch=='\x07':self.state='normal'
                elif ch=='\x1b':self.state='osc-esc'
                continue
            if self.state=='osc-esc':
                self.state='normal' if ch=='\\' else 'osc'
                continue
            if self.state=='esc':
                if ch=='[':self.state='csi';self.sequence=''
                elif ch==']':self.state='osc'
                elif ch in ('(',')','#'):self.state='esc-one'
                elif ch=='7':self.saved=(self.row,self.col);self.state='normal'
                elif ch=='8':self.row,self.col=self.saved;self.state='normal'
                elif ch=='D':self._linefeed();self.state='normal'
                elif ch=='E':self._linefeed();self.col=0;self.state='normal'
                elif ch=='M':self.row=max(0,self.row-1);self.state='normal'
                elif ch=='c':self.clear();self.state='normal'
                elif ch in ('=','>'):self.state='normal'
                else:self.mark_uncertain(f'unsupported-esc:{ord(ch):02x}');self.state='normal'
                continue
            if self.state=='esc-one':
                self.state='normal'
                continue
            if self.state=='csi':
                self.sequence+=ch
                if '@'<=ch<='~':self._csi(self.sequence);self.state='normal';self.sequence=''
                continue
            if ch=='\x1b':self.state='esc'
            elif ch=='\r':self.col=0
            elif ch=='\n':self._linefeed()
            elif ch=='\b':self.col=max(0,self.col-1)
            elif ch=='\t':self.col=min(self.cols,((self.col//8)+1)*8)
            elif ch>=' ':self._write(ch)
    def lines(self): return [''.join(line).rstrip() for line in self.cells]
    def _expected_end(self, expected):
        lines=self.lines()
        # On narrow terminals agy's renderer wraps one logical receipt across physical rows.
        # Require the complete expected value, including its UUID; do not join across blank rows.
        for start in range(len(lines)):
            joined=''
            for end in range(start,len(lines)):
                piece=lines[end].strip()
                if not piece: break
                joined+=piece
                if joined==expected: return end
                if not expected.startswith(joined): break
        return None
    def has_line(self, expected): return self._expected_end(expected) is not None
    def lines_after(self, expected):
        end=self._expected_end(expected)
        return None if end is None else '\n'.join(self.lines()[end+1:])
    def tail_with_prefix(self, prefix):
        """Match only physical wraps that fit at the bottom of the screen."""
        lines=self.lines(); end=len(lines)-1
        while end>=0 and not lines[end].strip(): end-=1
        if end<0:return None
        # The agy 1.1.27 footer and status observed in practice fit within 64 cells.
        # Use only the rows required by the width and never reach into the body.
        budget=max(3,(64+self.cols-1)//self.cols+1)
        logical=''
        for row in range(end,max(-1,end-budget),-1):
            logical=lines[row].strip()+logical
            if logical.startswith(prefix): return row,end
        return None
    def run_before_with_prefix(self, before, prefix):
        """Reconstruct wraps from only the three physical rows before a position."""
        lines=self.lines(); end=before-1
        while end>=0 and not lines[end].strip(): end-=1
        if end<0:return None
        logical=''
        for start in range(end,max(-1,end-3),-1):
            logical=lines[start].strip()+logical
            if logical.startswith(prefix): return start,end
        return None

class Supervisor:
    HUMAN_IDLE_STABLE_SECONDS=0.6
    def __init__(self, args):
        self.a=args; self.project=str(Path(args.project).absolute()); self.owner=f'{uuid.uuid4()}.{os.getpid()}'
        self.start=proc_start(os.getpid()); self.cap=uuid.uuid4().hex+uuid.uuid4().hex
        paths=self.call('paths').splitlines(); self.actas=Path(paths[0])
        key=f'{encode_component(args.team)}__{encode_component(args.name)}'
        self.state_file=ROOT/'run'/f'antigravity-tui-pty.{key}.state.json'
        self.reservation=ROOT/'run'/f'read-reservation.{key}.json'; self.legacy_reservation=ROOT/'run'/f'antigravity-reservation.{key}.json'; self.violations=Path(str(self.reservation)+'.violations')
        self.state={'schemaVersion':2,'project':self.project,'team':args.team,'role':args.name,'owner':self.owner,'supervisorPhase':'STARTING','manualResumeRequired':False,'humanInputActive':False,'humanInputSawNonIdle':False,'durableAttention':False,'batch':None}
        self.master=None; self.child=None; self.old=None; self.screen=None; self.stopping=False; self.stop_reason=None; self.buffer=''; self.result_buffer=''; self.permission_raw_window=''; self.last_poll=0; self.last_output=time.monotonic(); self.human_idle_since=None; self.human_input_restart_recovery=False; self.resume_requested=False; self.resize_requested=False; self.acquired=False
        signal.signal(signal.SIGTERM, self.request_stop)
        signal.signal(signal.SIGINT, self.request_stop)
        signal.signal(signal.SIGUSR1, self.request_resume)
        signal.signal(signal.SIGWINCH, self.request_resize)
    def request_stop(self, signum, _frame):
        self.stop_reason=f'外部停止要求({signal.Signals(signum).name})'
    def request_resume(self, _signum, _frame):
        self.resume_requested=True
    def request_resize(self, _signum, _frame):
        self.resize_requested=True
    def pause_for_human_input(self):
        already_paused=self.state.get('humanInputActive',False)
        self.state['humanInputActive']=True; self.state['humanInputSawNonIdle']=False; self.human_idle_since=None; self.save()
        if not already_paused:
            print('\r\n[agmsg] 人間の入力中は自動配送を保留します。空の入力待ちに戻れば自動再開します',file=sys.stderr)
    def permission_input_rejection_reason(self):
        """Return None for the permission UI, otherwise a fail-closed diagnostic reason."""
        screen=getattr(self,'screen',None)
        if not screen:return 'screen-missing'
        if screen.uncertain:return screen.uncertain_reason or 'screen-uncertain'
        if screen.state!='normal':return f'screen-state:{screen.state}'
        if screen.decoder.getstate()[0]:return 'decoder-pending'
        visible=[line.strip() for line in screen.lines() if line.strip()]
        if not visible:return 'screen-empty'
        # Require both the modal footer and nearby choices so message text cannot trigger a false match.
        footer=screen.tail_with_prefix('esc to cancel')
        if footer:
            nav=screen.run_before_with_prefix(footer[0], '↑/↓ Navigate · tab Amend')
            if nav is None:return 'permission-nav-missing'
            # Long commands and choices wrap to multiple physical rows at the terminal width.
            # Reconstruct at most 16 logical rows ending at the navigation immediately before the footer.
            physical_budget=max(16,(1024+screen.cols-1)//screen.cols)
            start=max(0,nav[0]-physical_budget)
            modal=''.join(line.strip() for line in screen.lines()[start:nav[1]+1])
            required=('Requesting permission for:','Do you want to proceed?','> 1. Yes')
            positions=[modal.find(token) for token in required]
            if any(position<0 for position in positions):return 'permission-body-incomplete'
            if positions!=sorted(positions):return 'permission-body-order'
            return None
        if screen.tail_with_prefix('↑/↓ Navigate · enter Confirm'):
            tail=visible[-8:]
            if ('Do you trust the contents of this project?' in tail
                    and '> Yes, I trust this folder' in tail):return None
            return 'trust-body-incomplete'
        return 'permission-footer-missing'
    def permission_screen_diagnostic(self):
        """Return only permission-UI structure; never record command text or other screen content."""
        screen=getattr(self,'screen',None)
        if not screen:return 'screen=missing'
        lines=screen.lines()
        tokens={
            'request':'Requesting permission for:',
            'proceed':'Do you want to proceed?',
            'yes':'> 1. Yes',
            'navigate':'Navigate',
            'amend':'Amend',
            'footer':'esc to cancel',
        }
        positions={name:[i for i,line in enumerate(lines) if token in line]
                   for name,token in tokens.items()}
        raw=getattr(self,'permission_raw_window','')
        raw_seen={name:(token in raw) for name,token in tokens.items()}
        footer=screen.tail_with_prefix('esc to cancel')
        start=max(0,(footer[0] if footer else len(lines))-8)
        end=min(len(lines),(footer[1]+1 if footer else len(lines)))
        tail=[]
        for i in range(start,end):
            line=lines[i]
            flags=''.join(name[0].upper() for name,token in tokens.items() if token in line) or '-'
            tail.append(f'{i}:len={len(line)}:flags={flags}')
        return (f'rows={screen.rows},cols={screen.cols},cursor={screen.row},{screen.col},'
                f'positions={positions},raw_seen={raw_seen},tail=[{";".join(tail)}]')
    def permission_input_ready(self):
        """Relay human confirmation input only for a permission UI that was observed as valid."""
        return self.permission_input_rejection_reason() is None
    def allow_permission_input(self):
        # The current batch waits for its receipt; preserve durable pause and set only a temporary input pause.
        self.state['humanInputActive']=True; self.state['humanInputSawNonIdle']=True; self.human_idle_since=None; self.save()
        print('\r\n[agmsg] 許可UIへの人間入力をrelayしました。受領確認後、空の入力待ちに戻れば自動再開します',file=sys.stderr)
    @staticmethod
    def read_winsize(fd):
        return fcntl.ioctl(fd, termios.TIOCGWINSZ, struct.pack('HHHH', 0, 0, 0, 0))
    def sync_winsize(self):
        if self.master is None:return
        winsize=self.read_winsize(sys.stdin.fileno())
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, winsize)
        if getattr(self,'screen',None):
            rows,cols,_,_=struct.unpack('HHHH',winsize)
            if (rows,cols)!=(self.screen.rows,self.screen.cols):
                if self.state.get('supervisorPhase')=='WAITING_FOR_RESULT': self.screen.resize(rows,cols)
                else: self.screen=TerminalScreen(rows,cols)
        try:
            if self.child and proc_start(self.child)==self.state.get('childStart'): os.kill(self.child,signal.SIGWINCH)
        except (FileNotFoundError,ProcessLookupError): pass
    def call(self, command, extra=(), input=None, cap=False):
        fds=()
        passfds=()
        preexec=None
        if cap:
            r,w=os.pipe(); os.write(w,(self.cap+'\n').encode()); os.close(w); fds=(r,); passfds=(r,3)
            preexec=lambda: os.dup2(r,3)
        try:
            p=subprocess.run(['bash',TRANSPORT,command,self.project,self.a.team,self.a.name,self.owner,*extra],input=input,text=True,capture_output=True,pass_fds=passfds,preexec_fn=preexec)
        finally:
            for fd in fds: os.close(fd)
        if p.returncode:
            detail=(p.stderr.strip() or p.stdout.strip() or f'exit {p.returncode}')
            # One place, so both callers of the claim (startup and reset-guard) get it.
            if command=='claim': detail=explain_claim_refusal(detail,self.project,self.a.team,self.a.name)
            raise RuntimeError(f'{command}失敗: {detail}')
        return p.stdout
    def save(self): atomic(self.state_file,self.state)
    @staticmethod
    def migrate_state(state):
        version=state.get('schemaVersion',1)
        if version==1:
            state.update({'schemaVersion':2,'humanInputActive':False,'humanInputSawNonIdle':False,
                          'durableAttention':state.get('supervisorPhase')=='NEEDS_ATTENTION'})
        elif version!=2:
            raise RuntimeError(f'未対応state schemaVersion={version}')
        return state
    def fail(self, why):
        if self.state.get('batch') and self.state['batch'].get('phase')!='completed': self.state['batch']['phase']='uncertain'
        self.state['durableAttention']=True; self.state['supervisorPhase']='NEEDS_ATTENTION'; self.save()
        message=f'\r\n{why}; ackせず停止します'
        if why=='通常inboxによる既読試行を検知':
            message+='\n復旧: 入力欄を空にしてから `agy-tui reset-guard --project <project> --team <team> --name <role>` を実行してください'
        print(message,file=sys.stderr); self.stopping=True
    def check_guard(self):
        reservation=json.loads(self.reservation.read_text())
        if reservation['owner']!=self.owner or reservation['start']!=self.start: raise RuntimeError('予約所有権不一致')
        if proc_start(os.getpid())!=self.start: raise RuntimeError('supervisor start token不一致')
        if self.actas.read_text().strip()!=self.owner: raise RuntimeError('actas所有権不一致')
        if self.violations.exists() and self.violations.read_text().strip(): raise RuntimeError('通常inboxによる既読試行を検知')
        if self.child and proc_start(self.child)!=self.state.get('childStart'): raise RuntimeError('agy child start token不一致')
    def unresolved_batch_message(self, state):
        batch=state['batch']; batch_id=str(batch.get('id','unknown'))
        messages=batch.get('messages',[]); ids=[str(message.get('id','unknown')) for message in messages]
        common=(f'--project {shlex.quote(self.project)} --team {shlex.quote(self.a.team)} '
                f'--name {shlex.quote(self.a.name)}')
        confirm=' '.join(f'--confirm-id {shlex.quote(message_id)}' for message_id in ids)
        recovery=f'--batch {shlex.quote(batch_id)} {confirm}'.rstrip()
        return '\n'.join([
            '前回の受信を安全に既読確定できなかったため、新しいagy TUIを開始しません。',
            f'batch: {batch_id} phase={batch.get("phase")} messages={len(messages)}',
            f'message IDs: {", ".join(ids) if ids else "なし"}',
            'これは未処理とは限りません。次の基準で復旧方法を選んでください。',
            '1. 状態を確認:',
            f'   agy-tui status {common}',
            '2. agy画面で同じbatchのAGMSG_RECEIVED行と返信を確認済みの場合だけ既読確定:',
            f'   agy-tui ack {common} {recovery}',
            '3. agyがメッセージを受信していない場合は再配送（重複処理に注意）:',
            f'   agy-tui replay {common} {recovery}',
            '判断できない場合はackせず、statusの出力とagy画面を確認してください。',
        ])
    def acquire(self):
        mode=Path(self.project)/'.agent/rules/agmsg.md'
        if not mode.exists() or '<!-- agmsg:antigravity:monitor -->' not in mode.read_text(): raise RuntimeError('monitor設定が必要')
        existing=[file for file in (self.reservation,self.legacy_reservation) if file.exists()]
        if len(existing)>1: raise RuntimeError('複数の予約形式が存在します')
        if existing:
            old=json.loads(existing[0].read_text())
            # ValueError stays here: it is about the RECORD (a pid that is not a
            # number), not about the process. The "is it gone" question is
            # process_still's, once, and an unreadable /proc propagates out of
            # this block rather than being read as gone.
            try:
                if process_still(int(old['pid']),old['start']): raise RuntimeError('既存Antigravity bridge/TUI supervisor が稼働中です')
            except (ProcessLookupError,ValueError): pass
            if self.state_file.exists():
                old_state=json.loads(self.state_file.read_text())
                if old_state.get('batch') and old_state['batch'].get('phase')!='completed': raise RuntimeError(self.unresolved_batch_message(old_state))
            existing[0].unlink()
        if self.state_file.exists():
            saved=self.migrate_state(json.loads(self.state_file.read_text()))
            if any(saved.get(k)!=self.state[k] for k in ('project','team','role')): raise RuntimeError('state不一致')
            self.state=saved
            self.state['owner']=self.owner
            self.human_input_restart_recovery=bool(self.state.get('humanInputActive'))
        self.claim_reservation()
    def claim_reservation(self):
        self.call('claim'); self.state['owner']=self.owner; self.save(); self.violations.parent.mkdir(mode=0o700,exist_ok=True)
        self.violations.touch(mode=0o600,exist_ok=True); Path(str(self.violations)+'.lock').touch(mode=0o600,exist_ok=True)
        # The bridge read guard hashes the value read from fd 3 without its newline.
        atomic(self.reservation,{'type':'antigravity','owner':self.owner,'pid':os.getpid(),'start':self.start,'state':str(self.state_file),'actas':str(self.actas),'violations':str(self.violations),'capHash':hashlib.sha256(self.cap.encode()).hexdigest(),'kind':'tui-pty'})
        self.acquired=True
    def reset_guard(self):
        if not self.state_file.exists(): raise RuntimeError('復旧対象のstateがありません')
        state=self.migrate_state(json.loads(self.state_file.read_text()))
        if any(state.get(k)!=self.state[k] for k in ('project','team','role')): raise RuntimeError('state不一致')
        if state.get('batch'): raise RuntimeError('未解決batchがあります。reset-guardでは解除できません')
        self.call('claim')
        try:
            if self.reservation.exists():
                reservation=json.loads(self.reservation.read_text())
                if reservation.get('state')!=str(self.state_file) or reservation.get('kind')!='tui-pty': raise RuntimeError('別の予約が存在します')
                if 'pid' not in reservation or 'start' not in reservation: raise RuntimeError('予約情報が壊れています')
                try:
                    if process_still(int(reservation['pid']),reservation['start']): raise RuntimeError('TUI supervisorが稼働中です')
                except (ProcessLookupError,ValueError): pass
            self.violations.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
            lock_path=Path(str(self.violations)+'.lock')
            with lock_path.open('a') as lock:
                acquired=False
                for _ in range(50):
                    try:
                        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB); acquired=True; break
                    except BlockingIOError:
                        time.sleep(0.1)
                if not acquired: raise RuntimeError('violations lockを取得できません')
                self.violations.write_text('')
                state['durableAttention']=False
                if state.get('supervisorPhase')=='NEEDS_ATTENTION': state['supervisorPhase']='WAITING_FOR_IDLE'
                atomic(self.state_file,state)
            print('read-denied guardを解除しました。未読メッセージとack状態は変更していません')
        finally:
            self.call('release')
    def launch(self):
        winsize=self.read_winsize(sys.stdin.fileno())
        pid, master=pty.fork()
        if pid==0:
            fcntl.ioctl(0,termios.TIOCSWINSZ,winsize)
            attrs=termios.tcgetattr(0); attrs[3]&=~(termios.ECHO|termios.ECHONL); termios.tcsetattr(0,termios.TCSANOW,attrs)
            os.chdir(self.project); os.execvp(self.a.agy,[self.a.agy])
        rows,cols,_,_=struct.unpack('HHHH',winsize)
        self.child=pid; self.master=master; self.screen=TerminalScreen(rows,cols); self.old=termios.tcgetattr(sys.stdin.fileno()); tty.setraw(sys.stdin.fileno())
        self.state.update({'childPid':pid,'childStart':proc_start(pid),'supervisorPhase':'WAITING_FOR_IDLE'}); self.save()
        self.sync_winsize()
    def envelope(self, batch):
        out=[f'[agmsg batch id={batch["id"]} count={len(batch["messages"])}]']
        for m in batch['messages']:
            body=m['body'].replace('\x1b','\\x1b')
            out += [f'[agmsg message id={m["id"]}]',f'from: {m["from"]}',f'at: {m["at"]}','body:',body,'[/agmsg message]']
        out += ['[/agmsg batch]','この受信を読んだら、英字 AGMSG_RECEIVED、ASCIIコロン（U+003A）、batch idを空白なしで連結した1行だけを最初に出力し、その後に通常どおり処理してください。形式を調べるためのツール実行は不要です。']
        return '\n'.join(out)
    @staticmethod
    def batch_contains_receipt(batch):
        """Reject forged receipts by joining stripped physical lines as the renderer does."""
        receipt=batch.get('receipt','')
        return bool(receipt) and any(receipt in ''.join(line.strip() for line in m.get('body','').splitlines()) for m in batch.get('messages',[]))
    @staticmethod
    def batch_contains_idle_signature(batch):
        """Pause later automatic injection until explicit resume when the body imitates an idle screen."""
        return any(re.search(r'(?m)^>\s*$\n\? for shortcuts\b', m.get('body','')) for m in batch.get('messages',[]))
    def inject(self):
        b=self.state['batch']; data=self.envelope(b).encode()
        os.write(self.master,b'\x1b[200~'+data+b'\x1b[201~\r')
        b['phase']='sent'; b['receipt']=f'AGMSG_RECEIVED:{b["id"]}'
        b['manualResumeAfterAck']=self.batch_contains_idle_signature(b)
        self.result_buffer=''
        self.permission_raw_window=''
        if getattr(self,'screen',None):self.screen.uncertain=False;self.screen.uncertain_reason=None
        self.state['supervisorPhase']='INJECTED'; self.save(); self.state['supervisorPhase']='WAITING_FOR_RESULT'; self.save()
    @staticmethod
    def failure_signature(text):
        clean=re.sub(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))','',text)
        return any(re.match(r'^\s*(?:error|cancel(?:led)?|interrupt(?:ed)?|permission denied|trust required|picker)\s*[:：]', line, re.I) for line in clean.splitlines())
    def ack(self):
        self.check_guard()
        b=self.state['batch']; b['phase']='completed'; self.state['supervisorPhase']='ACK_PENDING'; self.save()
        try: self.call('ack',input=json.dumps([m['id'] for m in b['messages']]),cap=True)
        except Exception:
            b['phase']='uncertain'; self.state['durableAttention']=True; self.state['supervisorPhase']='NEEDS_ATTENTION'; self.save(); raise
        pause_after_ack=b.pop('manualResumeAfterAck',False)
        self.state['batch']=None; self.state['supervisorPhase']='WAITING_FOR_IDLE'
        if pause_after_ack:
            self.human_input_seen=True; self.state['manualResumeRequired']=True
            print('\r\n[agmsg] 本文にidle画面の署名を検知したため、後続の自動配送を停止しました。再開: $agmsg resume',file=sys.stderr)
        self.save()
    def maybe_poll(self):
        if time.monotonic()-self.last_poll<self.a.poll: return
        self.check_guard()
        if (not self.injection_ready() or self.state.get('humanInputActive') or
                self.state.get('manualResumeRequired') or self.state.get('durableAttention')): return
        if self.state['batch']:
            if self.state['batch'].get('phase')=='prepared': self.inject()
            return
        self.last_poll=time.monotonic(); rows=self.call('peek').strip()
        if not rows:return
        msgs=[json.loads(x) for x in rows.splitlines()]; chosen=[]; size=0
        for m in msgs:
            n=len(m['body'].encode())
            if n>65536: self.fail(f'本文上限超過 id={m["id"]}'); return
            if size+n>65536: break
            chosen.append(m);size+=n
        if not chosen:return
        self.state['batch']={'id':str(uuid.uuid4()),'phase':'prepared','messages':chosen}; self.state['supervisorPhase']='PREPARED'; self.save()
        # Recheck screen transitions and human input during peek/save immediately before injection.
        if self.injection_ready(): self.inject()
    def input_ready(self):
        # A footer alone cannot distinguish a permission screen from an in-progress input; require an empty input field too.
        screen=getattr(self,'screen',None)
        if not screen or screen.uncertain or screen.state!='normal' or screen.decoder.getstate()[0]: return False
        last_output=getattr(self,'last_output',0)
        if last_output>0 and time.monotonic()-last_output<0.3: return False
        footer=screen.tail_with_prefix('? for shortcuts')
        if footer is None:return False
        footer_text=''.join(line.strip() for line in screen.lines()[footer[0]:footer[1]+1])
        if ' ·' not in footer_text:return False
        # Inspect only the bottom footer and the input area above it, not the whole body.
        # On narrow terminals the footer's right-hand status wraps physically.
        before=[line.strip() for line in screen.lines()[:footer[0]] if line.strip()]
        while before and all(ch in '─━-' for ch in before[-1]): before.pop()
        return bool(before) and before[-1]=='>'
    def injection_ready(self):
        if not self.input_ready(): return False
        master=getattr(self,'master',None)
        if master is None:return True
        # Defer when child output is not reflected in the screen model or human input is pending.
        readable,_,_=select.select([sys.stdin.fileno(),master],[],[],0)
        return not readable and self.input_ready()
    def update_human_input_state(self):
        if not self.state.get('humanInputActive'): return
        if (self.state.get('batch') or self.state.get('manualResumeRequired') or
                self.state.get('durableAttention') or
                (self.violations.exists() and bool(self.violations.read_text().strip()))):
            self.human_idle_since=None; return
        ready=self.injection_ready()
        if not ready:
            self.human_idle_since=None
            if not self.human_input_restart_recovery and not self.state.get('humanInputSawNonIdle'):
                self.state['humanInputSawNonIdle']=True; self.save()
            return
        if not self.human_input_restart_recovery and not self.state.get('humanInputSawNonIdle'):
            self.human_idle_since=None; return
        now=time.monotonic()
        if self.human_idle_since is None:
            self.human_idle_since=now; return
        if now-self.human_idle_since<self.HUMAN_IDLE_STABLE_SECONDS:return
        self.state['humanInputActive']=False; self.state['humanInputSawNonIdle']=False
        self.human_input_restart_recovery=False; self.human_idle_since=None; self.save()
        print('\r\n[agmsg] 空の入力待ちを確認したため自動配送を再開しました',file=sys.stderr)
    def loop(self):
        while not self.stopping:
            if self.resize_requested:
                self.resize_requested=False; self.sync_winsize()
            if self.resume_requested:
                self.resume_requested=False
                if self.state.get('supervisorPhase')=='WAITING_FOR_RESULT': self.fail('受信turn中のresume要求を拒否'); continue
                self.state['manualResumeRequired']=False; self.state['humanInputActive']=False; self.state['humanInputSawNonIdle']=False; self.human_input_restart_recovery=False; self.human_idle_since=None; self.state['supervisorPhase']='WAITING_FOR_IDLE'; self.save()
                print('\r\nmonitor再開要求を受け付けました。空の入力待ち画面を確認してから配送します',file=sys.stderr)
            if self.stop_reason:
                if self.state.get('batch') and self.state['batch'].get('phase')!='completed': self.fail(self.stop_reason)
                break
            permission_before_reason=(self.permission_input_rejection_reason()
                                      if self.state.get('supervisorPhase')=='WAITING_FOR_RESULT'
                                      else 'not-waiting-for-result')
            permission_before_read=permission_before_reason is None
            r,_,_=select.select([sys.stdin.fileno(),self.master],[],[],0.2)
            # If child rendering and parent input are ready together, update the screen model first.
            # This prevents an unreflected permission footer from being mistaken for normal input.
            if self.master in r:
                data=os.read(self.master,65536)
                if not data: self.fail('agy TUIが終了'); break
                self.last_output=time.monotonic()
                os.write(sys.stdout.fileno(),data); self.screen.feed(data); text=data.decode(errors='replace'); self.buffer=(self.buffer+text)[-65536:]
                b=self.state.get('batch')
                if b and self.state.get('supervisorPhase')=='WAITING_FOR_RESULT':
                    self.result_buffer=(self.result_buffer+text)[-16384:]
                    self.permission_raw_window=(getattr(self,'permission_raw_window','')+text)[-65536:]
                    receipt_tail=self.screen.lines_after(b.get('receipt'))
                    if receipt_tail is not None:
                        if self.batch_contains_receipt(b): self.fail('受信本文にreceipt全体が含まれるためackしない')
                        elif self.screen.uncertain:self.fail(f'未対応のterminal制御列をreceipt turn中に検知（理由={self.screen.uncertain_reason or "unknown"}）')
                        elif self.failure_signature(receipt_tail): self.fail('TUI error/cancel/permission signatureを検知')
                        else: self.ack()
            if sys.stdin.fileno() in r:
                data=os.read(sys.stdin.fileno(),4096)
                if not data: self.stopping=True; break
                if (self.state.get('supervisorPhase')=='WAITING_FOR_RESULT'
                        and (permission_before_read or self.permission_input_ready())): self.allow_permission_input()
                elif self.state.get('supervisorPhase')=='WAITING_FOR_RESULT':
                    reason=self.permission_input_rejection_reason()
                    diagnostic=self.permission_screen_diagnostic()
                    self.fail(f'受信turn中の人間入力を検知（permission拒否理由=before:{permission_before_reason}, after:{reason}; screen={diagnostic}）')
                else: self.pause_for_human_input()
                os.write(self.master,data)
            self.update_human_input_state()
            self.maybe_poll()
    def run(self):
        self.acquire()
        if (self.state.get('batch') or {}).get('phase')=='completed': self.ack()
        self.launch(); self.loop()
    def close(self):
        if self.old: termios.tcsetattr(sys.stdin.fileno(),termios.TCSADRAIN,self.old)
        if self.child:
            try: os.write(self.master,b'\x04')
            except (OSError,TypeError): pass
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                try:
                    if proc_start(self.child)!=self.state.get('childStart'): break
                except (FileNotFoundError,ProcessLookupError): break
                time.sleep(0.05)
            try:
                if proc_start(self.child)==self.state.get('childStart'): os.kill(self.child,signal.SIGHUP)
            except (FileNotFoundError,ProcessLookupError): pass
        if not self.state.get('batch'):
            try:
                r=json.loads(self.reservation.read_text())
                if r['owner']==self.owner and r['start']==self.start and self.actas.read_text().strip()==self.owner: self.reservation.unlink(); self.actas.unlink(missing_ok=True)
            except Exception: pass

def recover(a):
    s=Supervisor(a)
    reservation_file=next((file for file in (s.reservation,s.legacy_reservation) if file.exists()),None)
    if reservation_file is None or not s.state_file.exists(): raise RuntimeError('復旧対象の予約/stateがありません')
    reservation=json.loads(reservation_file.read_text()); state=s.migrate_state(json.loads(s.state_file.read_text())); batch=state.get('batch')
    try: live=process_still(int(reservation['pid']),reservation['start'])
    except ValueError: live=False
    if live: raise RuntimeError('復旧対象のsupervisorが稼働中です')
    if not batch or batch.get('id')!=a.batch: raise RuntimeError('復旧batch IDが一致しません')
    expected=sorted(a.confirm_ids or []); actual=sorted(m['id'] for m in batch.get('messages',[]))
    if expected!=actual: raise RuntimeError('復旧batchのID集合が一致しません')
    s.state=state; s.state['durableAttention']=False; reservation_file.unlink(); s.violations.write_text('')
    s.claim_reservation()
    try:
        if a.action=='ack':
            s.state['batch']['phase']='completed'; s.state['supervisorPhase']='ACK_PENDING'; s.save(); s.ack()
            print('復旧ackを完了しました')
        else:
            # Replay explicitly sends the batch to a new agy child, so do not carry over the
            # old session's temporary input pause. Durable manual pause is a separate axis.
            s.state['humanInputActive']=False; s.state['humanInputSawNonIdle']=False
            s.state['batch']['phase']='prepared'; s.state['supervisorPhase']='PREPARED'; s.save(); s.launch(); s.loop()
    finally:
        s.close()

def main():
    p=argparse.ArgumentParser(); p.add_argument('--project',required=True);p.add_argument('--team',required=True);p.add_argument('--name',required=True);p.add_argument('--agy',default='agy');p.add_argument('--poll',type=float,default=2);p.add_argument('--action',choices=['run','status','stop','resume','reset-guard','ack','replay'],default='run');p.add_argument('--batch');p.add_argument('--confirm-id',dest='confirm_ids',action='append')
    a=p.parse_args()
    if a.action in ('ack','replay'):
        if not a.batch or not a.confirm_ids: raise RuntimeError('--batch と --confirm-id が必要です')
        recover(a); return
    if a.action=='reset-guard':
        try: Supervisor(a).reset_guard()
        except Exception as e: print(f'reset-guard失敗: {e}',file=sys.stderr); sys.exit(1)
        return
    if a.action in ('status','stop','resume'):
        matches=[]
        try:
            files=list((ROOT/'run').glob('read-reservation.*.json'))+list((ROOT/'run').glob('antigravity-reservation.*.json'))
            for file in files:
                try:
                    reservation=json.loads(file.read_text())
                    legacy=file.name.startswith('antigravity-reservation.')
                    if (reservation.get('type')!='antigravity' and not (legacy and 'type' not in reservation)): continue
                    state=json.loads(Path(reservation['state']).read_text())
                    if state.get('project')!=str(Path(a.project).absolute()) or state.get('team')!=a.team or state.get('role')!=a.name or reservation.get('kind')!='tui-pty': continue
                    live=False
                    try: live=process_still(int(reservation['pid']),reservation['start'])
                    except FileNotFoundError: live=False
                    except ValueError as exc: raise RuntimeError(f'TUI reservation is malformed: {file}: {exc}') from exc
                    except StartTimeUnreadable as exc: raise RuntimeError(f'TUI process identity is unreadable: {file}: {exc}') from exc
                    matches.append((file,reservation,state,live))
                except FileNotFoundError as exc:
                    raise RuntimeError(f'TUI reservation disappeared while reading: {file}: {exc}') from exc
                except (OSError,KeyError,TypeError,ValueError,json.JSONDecodeError) as exc:
                    raise RuntimeError(f'TUI reservation is unreadable or malformed: {file}: {exc}') from exc
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            sys.exit(1)
        if a.action=='status':
            if not matches: print('runtime: tui-pty 未起動'); return
            for _,reservation,state,live in matches:
                batch=state.get('batch')
                paused=state.get('manualResumeRequired') or state.get('humanInputActive') or state.get('durableAttention')
                status='停止/要確認' if not live else 'paused' if paused else 'busy' if batch else 'running'
                print(f"runtime: {state.get('role')} tui-pty {status}")
                if batch:
                    print(f"batch: {batch.get('id')} phase={batch.get('phase')} messages={len(batch.get('messages',[]))}")
                    for message in batch.get('messages',[]): print(f"message: id={message.get('id')} from={message.get('from')} at={message.get('at')}")
            return
        live=[x for x in matches if x[3]]
        if len(live)!=1:
            print('停止/再開対象のTUI supervisorが一意に特定できません', file=sys.stderr)
            sys.exit(1)
        _,reservation,_,_=live[0]
        if a.action=='resume':
            os.kill(int(reservation['pid']),signal.SIGUSR1)
            print('再開要求を送信しました。入力欄を空にしたことを確認済みの場合だけ使用してください')
            return
        os.kill(int(reservation['pid']),signal.SIGTERM)
        print('停止要求を送信しました')
        return
    s=Supervisor(a)
    try:s.run()
    except Exception as e:
        # A refusal before acquire does not own the existing supervisor state. Saving the initial
        # state via fail() would overwrite a batch that must be preserved with batch=None.
        if s.acquired:s.fail(str(e))
        else:print(str(e),file=sys.stderr)
        sys.exit(1)
    finally:s.close()
if __name__=='__main__': main()
