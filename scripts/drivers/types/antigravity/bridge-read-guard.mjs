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
  if(out.status===1) { const e=Error(`cannot verify pid ${pid}`);e.code='ENOENT';throw e; }
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
  if(out.status!==0) throw Error('failed to read or lock the violation record');
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
  if(out.status!==0) throw Error('failed to read or lock the violation record');
  const rows=out.stdout.trim()?out.stdout.trim().split('\n').map(JSON.parse):[];
  for(const r of rows) if(r.event!=='read-denied'||!Number.isInteger(r.pid)) throw Error('corrupt violation record');
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
      && !state.batch?.protection_id && state.batch?.phase==='completed' && state.batch.messages.length===ids.length
      && JSON.stringify([...ids].sort())===JSON.stringify(state.batch.messages.map(m=>m.id).sort())
      && fs.readFileSync(reservation.actas,'utf8').trim()===reservation.owner;
    if(authorized && violations(reservation.violations).length===0) process.exit(0);
    const row=JSON.stringify({event:'read-denied',pid:Number(pid)})+'\n';
    // The input contains no message body; keep refusing even if this write fails.
    if(process.platform==='darwin') _darwinLocked(reservation.violations,row,true);
    else spawnSync('flock',['-w','3',`${reservation.violations}.lock`,'bash','-c','cat >> "$1"','guard',reservation.violations],{input:row});
    console.error('agmsg: refusing to mark messages read while the bridge manages delivery');
  // Keep the refusal code 13 unchanged: callers already branch on it and
  // fail-closed behavior is the existing contract. Only the diagnostic wording
  // differs, because an inspection failure and an unsupported host need
  // different operator actions. (#1090 review)
  } catch (e) {
    if (e instanceof PlatformUnsupported) console.error(`agmsg: ${e.message}`);
    else console.error('agmsg: bridge reservation or authorization check failed');
  }
  process.exit(13);
}

const sameIds=(a,b)=>Array.isArray(a)&&Array.isArray(b)&&a.length>0&&a.length===b.length
  &&new Set(a).size===a.length&&a.every(x=>typeof x==='string'&&x.length>0)
  &&JSON.stringify([...a].sort())===JSON.stringify([...b].sort());
export function validateReservation(file,team,agent) {
  const reservation=read(file),state=read(reservation.state);
  const nonempty=x=>typeof x==='string'&&x.length>0;
  const token=x=>typeof x==='string'&&/^[0-9a-f]{64}$/.test(x);
  if(!nonempty(reservation.owner)||!Number.isInteger(reservation.pid)||reservation.pid<=0
    ||!nonempty(reservation.start)||!nonempty(reservation.state)||!nonempty(reservation.actas)
    ||!nonempty(reservation.violations)||!token(reservation.capHash)
    ||!state||![1,2].includes(state.schemaVersion)||!nonempty(state.project)
    ||state.team!==team||state.role!==agent||state.owner!==reservation.owner)throw Error('malformed reservation');
  const b=state.batch;
  if(b!==null) {
    if(!b||!nonempty(b.id)||!['prepared','sent','uncertain','completed'].includes(b.phase)
      ||!Array.isArray(b.messages)||!sameIds(b.messages.map(m=>m.id),b.messages.map(m=>m.id))
      ||b.messages.some(m=>m.team!==team||m.to!==agent||!nonempty(m.from)||typeof m.body!=='string'||!nonempty(m.at)))throw Error('malformed batch');
    if(b.original_ids&&!sameIds(b.original_ids,b.messages.map(m=>m.id)))throw Error('malformed original set');
    if('protection_id' in b||'claim_token' in b||'claim_ids' in b||'claim_owner' in b) {
      if(!token(b.protection_id)||!token(b.claim_token)||!nonempty(b.claim_owner)
        ||!sameIds(b.claim_ids,b.claim_ids)||b.claim_ids.some(id=>!b.messages.some(m=>m.id===id)))throw Error('malformed protected batch');
    }
  }
  return {reservation,state};
}
export function authorizeProtected(file,pid,operation,request,cap) {
  const {reservation,state}=validateReservation(file,request.team,request.agent);
  const parent=proc(Number(pid)),owner=proc(reservation.pid);
  const base=cap&&parent.ppid===reservation.pid&&owner.start===reservation.start&&owner.state!=='Z'
    &&createHash('sha256').update(cap).digest('hex')===reservation.capHash
    &&state.team===request.team&&state.role===request.agent&&state.owner===reservation.owner
    &&fs.readFileSync(reservation.actas,'utf8').trim()===reservation.owner
    &&violations(reservation.violations).length===0;
  if(!base)throw Error('protected delivery authorization failed');
  const batch=state.batch;
  if(operation==='admit')return;
  if(operation==='claim') {
    if(batch||request.owner!==reservation.owner)throw Error('cannot acquire over a saved batch');
    return;
  }
  if(!batch||!Array.isArray(batch.messages)||!sameIds(batch.original_ids||batch.messages.map(m=>m.id),batch.messages.map(m=>m.id)))throw Error('saved original batch mismatch');
  if(operation==='recover') {
    const recovery=state.recovery;
    if(!recovery||!Number.isInteger(recovery.pid)||recovery.pid<=0||typeof recovery.start!=='string'||!recovery.start||recovery.batch_id!==batch.id||request.batch_id!==batch.id
      ||!sameIds(request.ids,batch.messages.map(m=>m.id))||!sameIds(recovery.ids,request.ids))throw Error('unconfirmed recovery');
    try {const old=proc(recovery.pid);if(old.start===recovery.start&&old.state!=='Z')throw Error('recovery owner is alive');}
    catch(e){if(e.code!=='ENOENT')throw e;}
    return;
  }
  if(!sameIds(request.ids,batch.claim_ids)||request.owner!==batch.claim_owner
    ||request.token!==batch.claim_token||request.protection_id!==batch.protection_id
    ||! /^[0-9a-f]{64}$/.test(request.token||'')||! /^[0-9a-f]{64}$/.test(request.protection_id||''))throw Error('saved claim mismatch');
  if(operation==='ack'&&batch.phase==='completed')return;
  if(operation==='renew'&&['prepared','sent'].includes(batch.phase))return;
  if(operation==='release'&&batch.phase==='prepared')return;
  throw Error('operation is not authorized in the saved phase');
}

// The shell has already checked producer success and lossless JSON/UTF-8.
// Validate the complete protected result before exposing any record or
// adopting recovery state; never repair a malformed group or infer its IDs.
export function validateProtectedOutput(text,operation,file,team,agent) {
  const {state}=validateReservation(file,team,agent);
  const fail=()=>{throw Error('malformed protected delivery output');};
  const wireBytes=Buffer.byteLength(text)+(text&&!text.endsWith('\n')?1:0);
  if(wireBytes>(operation==='receive'?1048576:4194304))fail();
  const token=x=>typeof x==='string'&&/^[0-9a-f]{64}$/.test(x);
  const nonempty=x=>typeof x==='string'&&x.length>0&&!x.includes('\0');
  const keys=(record,expected)=>record&&typeof record==='object'&&!Array.isArray(record)
    &&Object.keys(record).length===expected.length&&Object.keys(record).every(key=>expected.includes(key));
  const messageKeys=['type','id','team','from','to','body','at'];
  const fenceKeys=['claim_token','protection_id','claim_expires_at'];
  const idSet=ids=>{
    if(!Array.isArray(ids)||ids.some(id=>!nonempty(id))||new Set(ids).size!==ids.length)fail();
    return new Set(ids);
  };
  const message=(m,protectedRow=false)=>keys(m,protectedRow?[...messageKeys,...fenceKeys]:messageKeys)
    &&m.type==='message_sent'&&nonempty(m.id)&&m.team===team&&m.to===agent
    &&nonempty(m.from)&&nonempty(m.at)&&typeof m.body==='string'&&!m.body.includes('\0');
  const fence=r=>token(r.claim_token)&&token(r.protection_id)
    &&Number.isSafeInteger(r.claim_expires_at)&&r.claim_expires_at>0;
  if(operation==='receive') {
    if(!text)return;
    const rows=text.trimEnd().split('\n').map(JSON.parse);
    if(rows.length>20||rows.some(m=>!message(m,true)||!fence(m)))fail();
    idSet(rows.map(m=>m.id));
    if(rows.some(m=>m.claim_token!==rows[0].claim_token||m.protection_id!==rows[0].protection_id
      ||m.claim_expires_at!==rows[0].claim_expires_at)
      ||rows.reduce((sum,m)=>sum+Buffer.byteLength(m.body),0)>65536)fail();
    return;
  }
  if(operation!=='recover-batch'||!state.batch)fail();
  const result=JSON.parse(text);
  if(!keys(result,['original_ids','already_read_ids','claim_ids','messages',...fenceKeys]))fail();
  const original=idSet(result.original_ids),readIds=idSet(result.already_read_ids),claimIds=idSet(result.claim_ids);
  const saved=new Map(state.batch.messages.map(m=>[m.id,m]));
  if(!fence(result)||original.size!==saved.size||[...original].some(id=>!saved.has(id))
    ||readIds.size+claimIds.size!==original.size||[...readIds].some(id=>!original.has(id)||claimIds.has(id))
    ||[...claimIds].some(id=>!original.has(id))||!Array.isArray(result.messages)
    ||result.messages.length!==claimIds.size)fail();
  idSet(result.messages.map(m=>m.id));
  for(const m of result.messages) {
    const prior=saved.get(m.id);
    if(!message(m)||!claimIds.has(m.id)||!prior
      ||['id','team','from','to','body','at'].some(key=>m[key]!==prior[key]))fail();
  }
}

if(process.argv[2]==='validate-output') {
  try {validateProtectedOutput(fs.readFileSync(0,'utf8'),...process.argv.slice(3));}
  catch {console.error('agmsg: malformed protected delivery output');process.exit(13);}
}
if(process.argv[2]==='scope') {
  try {
    const [file,team,agent]=process.argv.slice(3);validateReservation(file,team,agent);
  } catch {process.exit(13);}
}
if(process.argv[2]==='protected') {
  try {
    const data=fs.readFileSync(0,'utf8'),end=data.indexOf('\n');
    if(end<1)throw Error('capability missing');
    authorizeProtected(process.argv[3],process.argv[4],process.argv[5],JSON.parse(data.slice(end+1)),data.slice(0,end));
  } catch {console.error('agmsg: protected delivery authorization failed');process.exit(13);}
}
if(process.argv[2]==='request') {
  try {
    const raw=fs.readFileSync(0,'utf8'),input=raw.trim()?JSON.parse(raw):{};
    if(!input||typeof input!=='object'||Array.isArray(input)||Object.keys(input).some(k=>!['owner','token','protection_id','ids','batch_id'].includes(k)))throw Error('bad request');
    for(const k of ['owner','token','protection_id','batch_id'])if(k in input&&(typeof input[k]!=='string'||!input[k]||input[k].includes('\0')))throw Error('bad scalar');
    if('ids' in input&&(!Array.isArray(input.ids)||new Set(input.ids).size!==input.ids.length||input.ids.some(x=>typeof x!=='string'||!x||x.includes('\0'))))throw Error('bad ids');
    process.stdout.write(JSON.stringify({team:process.argv[3],agent:process.argv[4],owner:process.argv[5],...input}));
  }catch{process.exit(13);}
}
if(process.argv[2]==='fields') {
  const request=JSON.parse(fs.readFileSync(0,'utf8'));
  for(const k of ['owner','token','protection_id','batch_id'])if(k in request)console.log(`${k}|${Buffer.from(request[k]).toString('hex')}`);
  for(const id of request.ids||[])console.log(`id|${Buffer.from(id).toString('hex')}`);
}
if(process.argv[2]==='saved-batch') {
  const r=read(process.argv[3]);process.stdout.write(JSON.stringify(read(r.state).batch));
}
