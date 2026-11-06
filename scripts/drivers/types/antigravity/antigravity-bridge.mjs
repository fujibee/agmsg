import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn,spawnSync} from 'node:child_process';
import {randomBytes,randomUUID,createHash} from 'node:crypto';
import {once} from 'node:events';
import {read,atomic,proc,violations} from './bridge-read-guard.mjs';
const here=path.dirname(fileURLToPath(import.meta.url));
const root=path.resolve(here,'../../../..');
const transport=path.join(here,'inbox-transport.sh');
const downNotice=path.join(root,'scripts/lib/down-notice.sh');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const shutdownDelay=ms=>new Promise(r=>setTimeout(r,ms).unref());
const encodePart=value=>[...Buffer.from(String(value))].map(byte=>/[A-Za-z0-9._-]/.test(String.fromCharCode(byte))?String.fromCharCode(byte):`%${byte.toString(16).toUpperCase().padStart(2,'0')}`).join('');
export function forbiddenTool(event) {
  const s=event.step_update;
  if(event.event!=='step_update'||s?.step_type!=='tool') return false;
  const p=s.tool_info?.parameters;
  const command=p?.CommandLine ?? p?.command ?? p?.cmd;
  return typeof command==='string' && /(?:^|[\s/'";|&])(check-inbox|inbox)\.sh(?:[\s'";|&]|$)|\$agmsg\s*(?:$|[;|&])/.test(command);
}
export class Bridge {
  constructor(options) {
    this.o=options;this.project=path.resolve(options.project);this.team=options.team;this.role=options.name;
    this.cap=randomBytes(32).toString('hex');this.owner=`${randomUUID()}.${process.pid}`;
    this.start=proc(process.pid).start;this.phase='STARTING';this.busy=false;this.stopping=false;this.failed=false;this.restarts=0;
    // Budgets that used to end the bridge now only pace its recovery. The options
    // exist so tests can shrink them; the defaults are the shipped values.
    this.initMs=Number(options['init-ms']||60000);this.turnMs=Number(options['turn-ms']||330000);
    this.delays=(options['restart-delays']||'1000,5000,15000,60000,300000').split(',').map(Number);
    this.graceMs=Number(options['grace-ms']||30000);this.downAfterMs=Number(options['down-after-ms']||600000);
    this.troubles=new Map();this.noticed=false;this.noticeCleared=false;this.ackAt=0;this.ackFails=0;
    const [actas,state]=this.call('paths').trim().split('\n');this.file=state;this.actas=actas;
    const key=`${encodePart(this.team)}__${encodePart(this.role)}`;
    this.reservation=path.join(root,'run',`read-reservation.${key}.json`);
    this.legacyReservation=path.join(root,'run',`antigravity-reservation.${key}.json`);
    this.violation=this.reservation+'.violations';
  }
  call(command,extra=[]) {
    const r=spawnSync('bash',[transport,command,this.project,this.team,this.role,this.owner,...extra],{encoding:'utf8'});
    if(r.status!==0) {
      const error=Error(`${command} failed: ${r.stderr.trim()}`);
      if(r.signal==='SIGINT'||r.signal==='SIGTERM')error.code='SIGNAL_TRANSPORT';
      else if(command==='peek')error.code='PEEK_TRANSPORT';
      throw error;
    }
    return r.stdout;
  }
  save(){atomic(this.file,this.state);}
  log(text){console.log(`${new Date().toLocaleString('sv-SE',{timeZone:'Asia/Tokyo'})} JST ${this.role} ${this.phase} conversation=${this.state?.conversation_id||'-'} batch=${this.state?.batch?.id||'-'} ${text}`);}
  // One run/down record for this bridge (scripts/lib/down-notice.sh), set when a
  // recovery has gone on for downAfterMs or the bridge cannot continue by itself,
  // cleared when delivery is healthy again. Each call is one bash.
  notice(action,state='',reason='',recovery='') {
    const script='source "$1"; shift; key="$(down_notice_key antigravity.bridge "$1/$2")"; act="$3"; shift 3; if [ "$act" = clear ]; then down_notice_clear "$key"; else down_notice_set "$key" "$@"; fi';
    const r=spawnSync('bash',['-c',script,'agmsg-notice',downNotice,this.team,this.role,action,state,reason,recovery],{encoding:'utf8'});
    if(r.status!==0)console.error(`down notice ${action} failed: ${(r.stderr||'').trim()}`);
    return r.status===0;
  }
  recoveryCommand(){return `bash ${path.join(here,'antigravity-monitor.sh')} --project ${this.project} --team ${this.team} --name ${this.role} --command status`;}
  trouble(kind,reason) {
    if(!this.troubles.has(kind))this.troubles.set(kind,{since:Date.now(),reason});
    const t=this.troubles.get(kind);t.reason=reason;
    if(!this.noticed&&Date.now()-t.since>=this.downAfterMs&&this.notice('set','down',`Antigravity delivery for ${this.role}@${this.team} has not recovered since ${new Date(t.since).toISOString()}: ${reason}. The bridge keeps retrying.`,this.recoveryCommand()))this.noticed=true;
  }
  healthy(kind) {
    this.troubles.delete(kind);
    if(this.noticed&&!this.troubles.size&&this.notice('clear'))this.noticed=false;
  }
  check() {
    this.call('verify');
    const r=read(this.reservation);
    if(r.owner!==this.owner||r.start!==this.start) throw Error('reservation ownership mismatch');
    if(violations(this.violation).length) throw Error('detected a mark-read attempt through the regular inbox');
    if(this.failed) throw Error('NEEDS_ATTENTION');
  }
  async acquire() {
    fs.mkdirSync(path.join(root,'run'),{recursive:true,mode:0o700});
    this.state=fs.existsSync(this.file)?read(this.file):{schemaVersion:1,project:this.project,team:this.team,role:this.role,conversation_id:null,batch:null};
    if(this.state.schemaVersion!==1||this.state.project!==this.project||this.state.team!==this.team||this.state.role!==this.role) throw Error('state mismatch');
    const existing=[this.reservation,this.legacyReservation].filter(file=>fs.existsSync(file));
    if(existing.length>1) throw Error('multiple reservation formats exist');
    if(existing.length===1) {
      const old=read(existing[0]);
      try {if(proc(old.pid).start===old.start) throw Error('bridge is already running');} catch(e){if(e.code!=='ENOENT') throw e;}
      if(this.state.batch && this.state.batch.phase!=='completed' && !this.o.action) throw Error('unresolved batch: use status/resolve');
      if(old.state!==this.file) throw Error('a reservation exists for another project');
      fs.unlinkSync(existing[0]);
    }
    const modeFile=path.join(this.project,'.agent/rules/agmsg.md');
    if(!this.o.action && !fs.readFileSync(modeFile,'utf8').includes('<!-- agmsg:antigravity:monitor -->'))throw Error('monitor configuration is required');
    this.call('claim');
    this.state.owner=this.owner;this.save();
    // Create new reservations exclusively; reclaim a dead one only after actas is acquired.
    if(!fs.existsSync(this.violation)) fs.writeFileSync(this.violation,'',{flag:'wx',mode:0o600});
    fs.closeSync(fs.openSync(this.violation+'.lock','a',0o600));
    atomic(this.reservation,{type:'antigravity',owner:this.owner,pid:process.pid,start:this.start,state:this.file,actas:this.actas,violations:this.violation,capHash:createHash('sha256').update(this.cap).digest('hex')});
    if(this.o.action) {
      const b=this.state.batch;
      if(!b||b.id!==this.o.batch||b.messages.map(m=>m.id).join(',')!==this.o['confirm-ids']) throw Error('recovery batch or ID confirmation mismatch');
      // Only explicit recovery clears the violation latch; model execution is limited to replay.
      fs.writeFileSync(this.violation,'',{mode:0o600});
      if(this.o.action==='ack') {b.phase='completed';this.save();await this.ack(false);return false;}
      if(this.o.action!=='replay') throw Error('action must be ack or replay');
      b.phase='prepared';this.save();this.replay=true;
    } else if(this.state.batch) {
      if(this.state.batch.phase!=='completed') throw Error('unresolved batch');
      await this.ack();
    }
    return true;
  }
  // A resident ack that cannot finish (the violation lock is busy, or the ack
  // command failed) keeps the completed batch and tries again with a growing
  // delay; only an explicit recovery run reports the failure and ends.
  async ack(resident=true) {
    try {this.check();}
    catch(error) {
      if(!resident||error.code!=='GUARD_BUSY') throw error;
      this.phase='ACK_PENDING';this.trouble('guard',error.message);return false;
    }
    this.phase='ACK_PENDING';this.acking=true;
    const ids=this.state.batch.messages.map(m=>m.id);
    const c=spawn('bash',[transport,'ack',this.project,this.team,this.role,this.owner],{stdio:['pipe','pipe','pipe','pipe']});
    let err='';c.stderr.on('data',d=>err+=d);c.stdout.resume();c.stdin.on('error',()=>{});c.stdio[3].on('error',()=>{});
    c.stdio[3].end(this.cap+'\n');c.stdin.end(JSON.stringify(ids));
    const [code]=await once(c,'close');this.acking=false;
    if(code!==0) {
      if(!resident) throw Error(`ack failed: ${err}`);
      this.ackAt=Date.now()+this.delays[Math.min(this.ackFails++,this.delays.length-1)];
      this.trouble('ack',`ack failed: ${err.trim()}`);this.log(`ack failed, trying again later: ${err.trim()}`);return false;
    }
    this.ackFails=0;this.ackAt=0;this.healthy('ack');
    this.state.batch=null;this.save();this.phase='IDLE';return true;
  }
  async input(content,initial=false) {
    for(let i=0;;i++) {
      try {this.check();break;}
      catch(error) {if(!initial||error.code!=='GUARD_BUSY'||i>=4) throw error;await sleep(2000);}
    }
    if(this.busy) throw Error('duplicate input');
    this.busy=true;this.phase=initial?'INITIALIZING':'BUSY';this.delta=false;
    if(!initial) {this.state.batch.phase='sent';this.save();}
    this.deadline=Date.now()+(initial?this.initMs:this.turnMs);
    await new Promise((resolve,reject)=>this.child.stdin.write(JSON.stringify({event:'user',message:{content}})+'\n',error=>error?reject(error):resolve()));
  }
  async launch() {
    const args=['--input-format','stream-json','--output-format','stream-json','--print-timeout','5m'];
    if(this.state.conversation_id) args.push('--conversation',this.state.conversation_id);
    if(this.o.model) args.push('--model',this.o.model);
    const executable=this.o.agy||'agy';
    // Do not inherit the fd3 capability value; connect only stdin, stdout, and stderr.
    this.child=spawn(executable,args,{cwd:this.project,stdio:['pipe','pipe','pipe']});
    this.childStart=null;try{this.childStart=proc(this.child.pid).start;}catch{}
    const child=this.child;
    child.stderr.on('data',d=>process.stderr.write(d));child.stdin.on('error',e=>{if(child===this.child)this.troubleChild(e);});
    let buffer='';this.queue=Promise.resolve();
    child.stdout.setEncoding('utf8');
    child.stdout.on('data',chunk=>{
      buffer+=chunk;
      if(Buffer.byteLength(buffer)>8*1024*1024) return this.fail(Error('NDJSON size limit exceeded'));
      let n;while((n=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,n);buffer=buffer.slice(n+1);if(!line)continue;
        this.queue=this.queue.then(()=>this.event(JSON.parse(line))).catch(e=>this.fail(e));}
    });
    child.on('error',e=>{if(child===this.child)this.troubleChild(e);});
    child.on('close',()=>{this.queue.then(()=>{
      if(child!==this.child||this.restarting||this.stopping||this.failed)return;
      if(buffer&&this.phase!=='INITIALIZING')return this.fail(Error('child exited during a turn'));
      this.troubleChild(Error('child exited'));
    });});
    await this.input(`You are the agmsg headless worker. team=${this.team}, role=${this.role}, project=${this.project}. The bridge exclusively handles delivery and marking messages read. Do not call inbox.sh, check-inbox.sh, or bare $agmsg. To reply, use bash ${root}/scripts/send.sh ${this.team} ${this.role} <recipient> --stdin. Report operations that cannot be approved. Reply only with initialization complete.`,true);
  }
  // A child that fails before it has been given a batch (initializing or idle, or
  // holding a batch that was never sent or already finished) is replaced, again
  // and again with a growing delay; a child that fails mid-turn keeps the
  // existing uncertain-batch stop, because the batch may have been acted on.
  canRestart() {
    const b=this.state?.batch;
    return (!this.busy||this.phase==='INITIALIZING')&&(!b||b.phase==='prepared'||b.phase==='completed');
  }
  recoverable(error){return error.code==='GUARD_BUSY'||error.code==='EPIPE'||error.code==='ERR_STREAM_DESTROYED';}
  troubleChild(error) {
    if(this.stopping||this.failed||this.restarting)return;
    if(!this.canRestart())return this.fail(error);
    this.restartChild(error.message).catch(e=>this.fail(e));
  }
  async endChild() {
    const child=this.child;
    if(!child||child.exitCode!==null||child.signalCode!==null)return;
    child.stdin.end();
    const ended=once(child,'close').catch(()=>{});
    await Promise.race([ended,shutdownDelay(this.graceMs)]);
    if(child.exitCode===null&&child.signalCode===null){
      try{if(proc(child.pid).start===this.childStart)child.kill('SIGTERM');}catch{}
      await Promise.race([ended,shutdownDelay(3000)]);
      if(child.exitCode===null&&child.signalCode===null)throw Error('owned child did not exit; retaining reservation');
    }
  }
  async restartChild(reason) {
    if(this.restarting)return;
    this.restarting=true;
    this.busy=false;this.deadline=null;this.delta=false;this.phase='RESTARTING';
    this.trouble('child',reason);this.log(`replacing the child: ${reason}`);
    await this.endChild();
    await sleep(this.delays[Math.min(this.restarts++,this.delays.length-1)]);
    this.restarting=false;
    if(this.stopping||this.failed)return;
    try {await this.launch();}
    catch(error) {if(!this.recoverable(error))throw error;this.troubleChild(error);}
  }
  async event(e) {
    if(this.failed||this.stopping)return;
    const id=e.conversation_id??e.step_update?.conversation_id??e.result?.conversation_id;
    if(id && this.state.conversation_id && id!==this.state.conversation_id)throw Error('conversation mismatch');
    if(e.event==='init') {
      if(!id)throw Error('init event has no ID');this.state.conversation_id=id;this.save();this.call('record',[id]);return;
    }
    if(e.event==='step_update') {
      if(forbiddenTool(e))throw Error('detected an inbox operation in the stream');
      if(e.step_update?.text_delta){process.stdout.write(e.step_update.text_delta);this.delta=true;}return;
    }
    if(e.event!=='result'){this.log(`unknown event ${e.event}`);return;}
    if(!this.busy)throw Error('result has no matching input');
    // The result is in; only the violation lock is busy. Hold it and look again
    // on the next poll instead of ending the bridge.
    try {this.check();}
    catch(error) {
      if(error.code!=='GUARD_BUSY') throw error;
      this.pendingResult=e;this.deadline=null;this.trouble('guard',error.message);return;
    }
    if(e.result?.status!=='SUCCESS'||!this.state.conversation_id)throw Error(`unfinished result ${e.result?.status}`);
    if(!this.delta && e.result.response)console.log(e.result.response);
    const initial=this.phase==='INITIALIZING';this.busy=false;this.deadline=null;this.restarts=0;this.healthy('child');
    if(!initial){this.state.batch.phase='completed';this.save();await this.ack();}
    if(this.phase==='ACK_PENDING')return;
    this.phase='IDLE';this.log('ready');
    // The first time this process is ready, a record left by an earlier bridge goes.
    if(!this.noticeCleared){this.noticeCleared=true;if(this.notice('clear'))this.noticed=false;}
    if(initial&&this.replay){this.replay=false;await this.input(JSON.stringify(this.state.batch));}
  }
  async tick() {
    try {this.check();}
    catch(error) {if(error.code==='GUARD_BUSY'){this.trouble('guard',error.message);return;}throw error;}
    this.healthy('guard');
    if(this.restarting)return;
    if(this.pendingResult) {
      const held=this.pendingResult;this.pendingResult=null;
      this.queue=this.queue.then(()=>this.event(held)).catch(error=>this.fail(error));
      return;
    }
    if(this.deadline&&Date.now()>this.deadline) {
      // Nothing was handed to the model yet while initializing: replace the child.
      // A turn that ran out of time may or may not have been acted on: uncertain.
      if(this.phase==='INITIALIZING')return this.troubleChild(Error('init time exceeded'));
      throw Error('turn time exceeded');
    }
    if(this.busy||this.acking)return;
    if(this.state.batch?.phase==='completed') {if(Date.now()>=this.ackAt)await this.ack();return;}
    if(this.phase!=='IDLE')return;
    let rows;
    try { rows=this.call('peek').trim(); }
    catch(error) {
      if((error.code==='PEEK_TRANSPORT'||error.code==='SIGNAL_TRANSPORT')&&!this.busy&&this.phase==='IDLE'&&!this.state?.batch) this.stop().catch(stopError=>console.error(stopError.message));
      else this.fail(error);
      return;
    }
    if(this.stopping||this.failed)return;
    if(!rows)return;
    const messages=rows.split('\n').map(JSON.parse);let bytes=0;const batch=[];
    for(const m of messages){const size=Buffer.byteLength(m.body);if(size>65536)throw Error(`message size limit exceeded id=${m.id}`);if(bytes+size>65536)break;bytes+=size;batch.push(m);}
    this.state.batch={id:randomUUID(),phase:'prepared',messages:batch};this.save();
    try {await this.input(JSON.stringify(this.state.batch));}
    catch(error) {if(error.code!=='GUARD_BUSY')throw error;this.trouble('guard',error.message);}
  }
  fail(error) {
    // An in-flight peek ending after SIGINT/SIGTERM is normal shutdown; do not
    // overwrite it with NEEDS_ATTENTION and race reservation release.
    if(this.stopping)return;
    if(this.failed)return;this.failed=true;this.phase='NEEDS_ATTENTION';
    if(this.state?.batch&&this.state.batch.phase!=='completed'){this.state.batch.phase='uncertain';try{this.save();}catch{}}
    this.log(error.message);
    // The bridge ends here and nothing starts it again: say so, with the way back.
    const b=this.state?.batch;
    this.noticed=this.notice('set','down',`Antigravity delivery for ${this.role}@${this.team} stopped: ${error.message}${b?`; batch ${b.id} is kept unread (${b.phase}) and is not acknowledged or replayed on its own`:''}`,
      b?`${this.recoveryCommand()} (then rerun with --action ack or --action replay --batch ${b.id} --confirm-ids <ids>)`:`bash ${path.join(here,'antigravity-monitor.sh')} --project ${this.project} --team ${this.team} --name ${this.role}`)||this.noticed;
    this.stop().catch(e=>console.error(e.message));
  }
  async stop() {
    if(this.stopping)return;this.stopping=true;clearInterval(this.timer);
    await this.endChild();
    if(this.state?.batch){this.log('batch retained; status/resolve required');process.exitCode=1;return;}
    // process group signal may kill a transport child while verify/release is
    // running.  Revalidate the durable owner record locally, then remove only
    // our own reservation and matching actas lock.
    const reservation=read(this.reservation);
    if(reservation.owner!==this.owner||reservation.start!==this.start)throw Error('reservation ownership mismatch');
    if(fs.readFileSync(this.actas,'utf8').trim()!==this.owner)throw Error('actas ownership mismatch');
    fs.unlinkSync(this.reservation);
    fs.unlinkSync(this.actas);
    this.phase='STOPPED';this.log('stopped');
    // A stop somebody asked for is not a down bridge; one after a failure is.
    if(this.noticed&&!this.failed&&this.notice('clear'))this.noticed=false;
  }
  async run(){
    if(!await this.acquire()){await this.stop();return;}
    try {await this.launch();}
    catch(error) {if(!this.recoverable(error))throw error;this.troubleChild(error);}
    this.timer=setInterval(()=>{if(this.ticking||this.stopping)return;this.ticking=true;this.tick().catch(e=>{
      if(e.code==='SIGNAL_TRANSPORT'&&!this.busy&&this.phase==='IDLE'&&!this.state?.batch)this.stop().catch(stopError=>console.error(stopError.message));
      else this.fail(e);
    }).finally(()=>this.ticking=false);},Number(this.o.poll||2000));
    process.once('SIGINT',()=>this.stop());process.once('SIGTERM',()=>this.stop());
  }
}
const invokedPath=process.argv[1]&&fs.existsSync(process.argv[1])?fs.realpathSync(process.argv[1]):'';
const modulePath=fs.realpathSync(fileURLToPath(import.meta.url));
if(invokedPath===modulePath) {
  const o={};for(let i=2;i<process.argv.length;i+=2){if(!process.argv[i].startsWith('--')||!process.argv[i+1])throw Error('arguments must use --key value');o[process.argv[i].slice(2)]=process.argv[i+1];}
  if(!o.project||!o.team||!o.name)throw Error('--project, --team, and --name are required');
  const b=new Bridge(o);
  if(o.command==='status') {
    const status=fs.existsSync(b.file)?read(b.file):{status:'not started'};
    const n=spawnSync('bash',['-c','source "$1"; key="$(down_notice_key antigravity.bridge "$2/$3")"; down_notice_list | while IFS=$\'\\t\' read -r c s since reason rec; do [ "$c" = "$key" ] && printf "%s since %s: %s (recover with: %s)" "$s" "$since" "$reason" "$rec"; done; :','agmsg-notice',downNotice,b.team,b.role],{encoding:'utf8'});
    if(n.stdout)status.down_notice=n.stdout;
    console.log(JSON.stringify(status,null,2));
  }
  else b.run().catch(e=>{console.error(e.message);process.exitCode=1;});
}
