// Linux専用。flockは呼出し側と共通の記録ロックを使用する。
import fs from 'node:fs';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
export function proc(pid) {
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
  } catch {console.error('agmsg: bridge予約/認可の検査に失敗しました');}
  process.exit(13);
}
