// Linux専用。flockは呼出し側と共通の記録ロックを使用する。
import fs from 'node:fs';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';

// Linux 専用なのは この module の2つの操作です ---- proc() が /proc/<pid>/stat を読み、
// violations() が flock を spawn する。launcher 2本は OS を見て断りますが、ここへは
// launcher を通らない経路が2つ在ります: _delivery.sh が antigravity-mode.mjs を直接
// node で起動し、bridge-read-guard.sh も この module を直接 起動します。
//
// 断りは **操作の中**に置きます。import 時に投げる版を一度 書きましたが、それは
// `delivery.sh set off antigravity` を macOS で壊しました ---- off は mode.mjs stop を
// 通り、**delivery を切ることは どのホストでも できなければならない**。予約が1件も
// 無ければ proc() は呼ばれないので、その場合は今までどおり成功します。
//
// 型を分けてあるのは、呼び出し側が「読めなかった」を握り潰せるからです。
// antigravity-mode.mjs は proc() を try{...}catch{} で包み、失敗を live=false に畳んで
// いました ---- macOS では「動いていない」と嘘をつき、stop は予約を残したまま失敗する。
// PlatformUnsupported はそこで rethrow されます。
//
// mjs 側の macOS 移植(proc の OS 分岐と flock の置き換え)は別 issue です。(#1090 レビュー)
export class PlatformUnsupported extends Error {}
function _requireLinux(what) {
  if (process.platform !== 'linux') {
    throw new PlatformUnsupported(
      `Antigravity の ${what} は Linux 専用です`
      + `（このホストは ${process.platform}）。`
    );
  }
}
export function proc(pid) {
  _requireLinux('プロセス生存判定 (/proc/<pid>/stat)');
  const fields=fs.readFileSync(`/proc/${pid}/stat`,'utf8').split(') ').slice(1).join(') ').split(' ');
  return {ppid:Number(fields[1]),start:fields[19],state:fields[0]};
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
  _requireLinux('違反記録の読取 (flock)');
  const out=spawnSync('flock',['-w','3',`${file}.lock`,'cat',file],{encoding:'utf8'});
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
    spawnSync('flock',['-w','3',`${reservation.violations}.lock`,'bash','-c','cat >> "$1"','guard',reservation.violations],{input:row});
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
