import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {read,proc,PlatformUnsupported} from './bridge-read-guard.mjs';
const run=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../../../run');
const [command,project]=process.argv.slice(2);
for(const name of fs.existsSync(run)?fs.readdirSync(run):[]) {
  if(!((name.startsWith('read-reservation.')||name.startsWith('antigravity-reservation.'))&&name.endsWith('.json')))continue;
  const legacy=name.startsWith('antigravity-reservation.');
  const r=read(path.join(run,name));
  if(legacy ? (Object.prototype.hasOwnProperty.call(r,'type') && r.type!=='antigravity') : r.type!=='antigravity')continue;
  const s=read(r.state);
  if(s.project!==path.resolve(project))continue;
  // Only ENOENT proves that the monitor exited. Every other read failure must
  // stay visible: an unreadable process must not be treated as a dead one.
  let live=false;try{live=proc(r.pid).start===r.start;}catch(e){
    if(e instanceof PlatformUnsupported)throw e;
    if(e?.code!=='ENOENT')throw Error(`Antigravity process identity is unreadable; refusing to change mode: ${e.message}`);
  }
  if(command==='status'){const paused=s.manualResumeRequired||s.humanInputActive||s.durableAttention;console.log(`runtime: ${s.role} ${r.kind==='tui-pty'?'tui-pty':'headless'} ${live?(paused?'paused':s.batch?'busy':'running'):'stopped/needs-attention'}`);continue;}
  if(r.kind==='tui-pty'&&live)throw Error('A TUI monitor is running. Stop it explicitly before changing mode');
  if(live){process.kill(r.pid,'SIGTERM');for(let i=0;i<340;i++){await new Promise(r=>setTimeout(r,100));try{if(proc(r.pid).start!==r.start)break;}catch(e){
    if(e?.code==='ENOENT')break;
    throw Error(`Antigravity process identity is unreadable while stopping; refusing to change mode: ${e.message}`);
  }}}
  if(fs.existsSync(path.join(run,name)))throw Error('The monitor is still running or its batch is unresolved; keeping the mode setting');
}
