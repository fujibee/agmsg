import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {read,proc,PlatformUnsupported} from '../../../lib/bridge-read-guard.mjs';
const run=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../../../run');
const [command,project]=process.argv.slice(2);
for(const name of fs.existsSync(run)?fs.readdirSync(run):[]) {
  if(!name.startsWith('antigravity-reservation.')||!name.endsWith('.json'))continue;
  const r=read(path.join(run,name)),s=read(r.state);
  if(s.project!==path.resolve(project))continue;
  // `catch{}` folded every failure into "not running": on a host where proc()
  // cannot work, status said 停止/要確認 and stop left the reservation behind,
  // both without saying why. An unsupported platform is not a dead process.
  let live=false;try{live=proc(r.pid).start===r.start;}catch(e){if(e instanceof PlatformUnsupported)throw e;}
  if(command==='status'){const paused=s.manualResumeRequired||s.humanInputActive||s.durableAttention;console.log(`runtime: ${s.role} ${r.kind==='tui-pty'?'tui-pty':'headless'} ${live?(paused?'paused':s.batch?'busy':'running'):'停止/要確認'}`);continue;}
  if(r.kind==='tui-pty'&&live)throw Error('稼働中のTUI monitorがあります。明示stopしてからmodeを変更してください');
  if(live){process.kill(r.pid,'SIGTERM');for(let i=0;i<340;i++){await new Promise(r=>setTimeout(r,100));try{if(proc(r.pid).start!==r.start)break;}catch{break;}}}
  if(fs.existsSync(path.join(run,name)))throw Error('停止またはbatch解決が未完了。mode設定を保持');
}
