// POSIX process identity and advisory-lock helpers shared by the Antigravity
// bridge and mode controller.
import fs from 'node:fs';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';

// Linux reads /proc/<pid>/stat and uses the flock utility. macOS reads ps and
// uses Python fcntl for the same lock file. The direct mode and guard entry
// points use this module too, so the portability boundary lives here.
//
// Importing this module never rejects a host. An operation that does not need
// process inspection (for example disabling delivery with no reservation) must
// still work everywhere.
//
export class PlatformUnsupported extends Error {}
function _requirePosix(what) {
  if (process.platform !== 'linux' && process.platform !== 'darwin') {
    throw new PlatformUnsupported(`Antigravity ${what} requires POSIX process and lock primitives; this host (${process.platform}) is unsupported`);
  }
}
const darwinInfo=new URL('./mac-process-info.py',import.meta.url).pathname;
function _darwinProc(pid) {
  const out=spawnSync('python3',[darwinInfo,String(pid)],{encoding:'utf8'});
  if(out.status===1) { const e=Error(`pid ${pid} を確認できません`);e.code='ENOENT';throw e; }
  if(out.status!==0||!out.stdout.trim()) throw Error('macOS process identity is unreadable');
  const fields=out.stdout.trim().split('\t');
  if(fields.length!==3||!/^[0-9]+$/.test(fields[0])||!['R','Z'].includes(fields[1])||!/^darwin:[0-9]+:[0-9]{6}$/.test(fields[2])) throw Error('macOS process identity is malformed');
  return {ppid:Number(fields[0]),state:fields[1],start:fields[2]};
}
export function proc(pid) {
  _requirePosix('process inspection');
  if(process.platform==='linux') {
    const fields=fs.readFileSync(`/proc/${pid}/stat`,'utf8').split(') ').slice(1).join(') ').split(' ');
    return {ppid:Number(fields[1]),start:fields[19],state:fields[0]};
  }
  return _darwinProc(pid);
}
function _darwinLocked(file, data, append) {
  const script = [
    'import fcntl,sys,time',
    'lock=open(sys.argv[1], "a+")',
    'for _ in range(30):',
    '    try:',
    '        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB); break',
    '    except BlockingIOError:',
    '        time.sleep(0.1)',
    'else: raise SystemExit(1)',
    'if sys.argv[3] == "read":',
    '    sys.stdout.write(open(sys.argv[2]).read())',
    'else:',
    '    with open(sys.argv[2], "a") as target: target.write(sys.stdin.read())',
  ].join('\n');
  const out=spawnSync('python3',['-c',script,`${file}.lock`,file,append?'append':'read'],{encoding:'utf8',input:data||''});
  if(out.status!==0) throw Error('違反記録の読取/lock失敗');
  return out.stdout;
}
export function read(file) {return JSON.parse(fs.readFileSync(file,'utf8'));}
export function atomic(file,data) {
  const tmp=`${file}.${process.pid}.tmp`;
  const fd=fs.openSync(tmp,'wx',0o600);
  try {fs.writeFileSync(fd,JSON.stringify(data)+'\n');fs.fsyncSync(fd);} finally {fs.closeSync(fd);}
  fs.renameSync(tmp,file);
  const dir=fs.openSync(new URL('.',`file://${file}`).pathname,'r');
  try {fs.fsyncSync(dir);} finally {fs.closeSync(dir);}
}
export function violations(file) {
  _requirePosix('violation inspection');
  const out=process.platform==='darwin'
    ? {status:0,stdout:_darwinLocked(file,'',false)}
    : spawnSync('flock',['-w','3',`${file}.lock`,'cat',file],{encoding:'utf8'});
  if(out.status!==0) throw Error('違反記録の読取/lock失敗');
  const rows=out.stdout.trim()?out.stdout.trim().split('\n').map(JSON.parse):[];
  for(const r of rows) if(r.event!=='read-denied'||!Number.isInteger(r.pid)) throw Error('違反記録破損');
  return rows;
}
if(process.argv[2]==='check') {
  const [file,pid,team,role,...ids]=process.argv.slice(3);
  try {
    const reservation=read(file), state=read(reservation.state);
    const cap=fs.readFileSync(0,'utf8');
    const parent=proc(Number(pid));
    const owner=proc(reservation.pid);
    const authorized=cap && parent.ppid===reservation.pid && owner.start===reservation.start && owner.state!=='Z'
      && createHash('sha256').update(cap).digest('hex')===reservation.capHash
      && state.team===team && state.role===role && state.owner===reservation.owner
      && state.batch?.phase==='completed' && state.batch.messages.length===ids.length
      && JSON.stringify([...ids].sort())===JSON.stringify(state.batch.messages.map(m=>m.id).sort())
      && fs.readFileSync(reservation.actas,'utf8').trim()===reservation.owner;
    if(authorized && violations(reservation.violations).length===0) process.exit(0);
    const row=JSON.stringify({event:'read-denied',pid:Number(pid)})+'\n';
    // 入力は本文を含まない。書込みに失敗しても拒否を維持する。
    if(process.platform==='darwin') _darwinLocked(reservation.violations,row,true);
    else spawnSync('flock',['-w','3',`${reservation.violations}.lock`,'bash','-c','cat >> "$1"','guard',reservation.violations],{input:row});
    console.error('agmsg: bridgeが受領管理中のため既読化を拒否しました');
  // 失敗の理由を1つだけ 分けます。exit 13(拒否)は変えません ---- 呼び出し側が 13 で分岐して
  // いるのと、拒否側に倒すのは元から正しいためです。変えるのは**何と言うか**だけ:
  // 「検査に失敗しました」は、このホストでは検査が原理的にできない場合にも同じ文言でした。
  // 運用者の次の一手が違います(調べる vs このホストでは使えない)。(#1090 レビュー)
  } catch (e) {
    if (e instanceof PlatformUnsupported) console.error(`agmsg: ${e.message}`);
    else console.error('agmsg: bridge予約/認可の検査に失敗しました');
  }
  process.exit(13);
}
