import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn,spawnSync} from 'node:child_process';
import {randomBytes,randomUUID,createHash} from 'node:crypto';
import {once} from 'node:events';
import {read,atomic,proc,violations} from '../../../lib/bridge-read-guard.mjs';
const here=path.dirname(fileURLToPath(import.meta.url));
const root=path.resolve(here,'../../../..');
const transport=path.join(here,'inbox-transport.sh');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const shutdownDelay=ms=>new Promise(r=>setTimeout(r,ms).unref());
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
    const [actas,state]=this.call('paths').trim().split('\n');this.file=state;this.actas=actas;
    this.reservation=path.join(root,'run',`antigravity-reservation.${path.basename(actas).slice(6,-8)}.json`);
    this.violation=this.reservation+'.violations';
  }
  call(command,extra=[]) {
    const r=spawnSync('bash',[transport,command,this.project,this.team,this.role,this.owner,...extra],{encoding:'utf8'});
    if(r.status!==0) {
      const error=Error(`${command}失敗: ${r.stderr.trim()}`);
      if(r.signal==='SIGINT'||r.signal==='SIGTERM')error.code='SIGNAL_TRANSPORT';
      else if(command==='peek')error.code='PEEK_TRANSPORT';
      throw error;
    }
    return r.stdout;
  }
  save(){atomic(this.file,this.state);}
  log(text){console.log(`${new Date().toLocaleString('sv-SE',{timeZone:'Asia/Tokyo'})} JST ${this.role} ${this.phase} conversation=${this.state?.conversation_id||'-'} batch=${this.state?.batch?.id||'-'} ${text}`);}
  check() {
    this.call('verify');
    const r=read(this.reservation);
    if(r.owner!==this.owner||r.start!==this.start) throw Error('予約所有権不一致');
    if(violations(this.violation).length) throw Error('通常inboxによる既読試行を検知');
    if(this.failed) throw Error('NEEDS_ATTENTION');
  }
  async acquire() {
    fs.mkdirSync(path.join(root,'run'),{recursive:true,mode:0o700});
    this.state=fs.existsSync(this.file)?read(this.file):{schemaVersion:1,project:this.project,team:this.team,role:this.role,conversation_id:null,batch:null};
    if(this.state.schemaVersion!==1||this.state.project!==this.project||this.state.team!==this.team||this.state.role!==this.role) throw Error('state不一致');
    if(fs.existsSync(this.reservation)) {
      const old=read(this.reservation);
      try {if(proc(old.pid).start===old.start) throw Error('bridge既に稼働中');} catch(e){if(e.code!=='ENOENT') throw e;}
      if(this.state.batch && this.state.batch.phase!=='completed' && !this.o.action) throw Error('未解決batch: status/resolveを使用');
      if(old.state!==this.file) throw Error('別projectの予約あり');
    }
    const modeFile=path.join(this.project,'.agent/rules/agmsg.md');
    if(!this.o.action && !fs.readFileSync(modeFile,'utf8').includes('<!-- agmsg:antigravity:monitor -->'))throw Error('monitor設定が必要');
    this.call('claim');
    this.state.owner=this.owner;this.save();
    // 新規予約は排他生成。死んだ予約の引継ぎはactas獲得後のみ。
    if(!fs.existsSync(this.violation)) fs.writeFileSync(this.violation,'',{flag:'wx',mode:0o600});
    fs.closeSync(fs.openSync(this.violation+'.lock','a',0o600));
    atomic(this.reservation,{owner:this.owner,pid:process.pid,start:this.start,state:this.file,actas:this.actas,violations:this.violation,capHash:createHash('sha256').update(this.cap).digest('hex')});
    if(this.o.action) {
      const b=this.state.batch;
      if(!b||b.id!==this.o.batch||b.messages.map(m=>m.id).join(',')!==this.o['confirm-ids']) throw Error('復旧batch/ID確認不一致');
      // 明示復旧だけが違反ラッチを解決する。モデル再実行はreplayに限定。
      fs.writeFileSync(this.violation,'',{mode:0o600});
      if(this.o.action==='ack') {b.phase='completed';this.save();await this.ack();return false;}
      if(this.o.action!=='replay') throw Error('actionはack|replay');
      b.phase='prepared';this.save();this.replay=true;
    } else if(this.state.batch) {
      if(this.state.batch.phase!=='completed') throw Error('未解決batch');
      await this.ack();
    }
    return true;
  }
  async ack() {
    this.check();this.phase='ACK_PENDING';
    const ids=this.state.batch.messages.map(m=>m.id);
    const c=spawn('bash',[transport,'ack',this.project,this.team,this.role,this.owner],{stdio:['pipe','pipe','pipe','pipe']});
    let err='';c.stderr.on('data',d=>err+=d);c.stdout.resume();c.stdin.on('error',()=>{});c.stdio[3].on('error',()=>{});
    c.stdio[3].end(this.cap+'\n');c.stdin.end(JSON.stringify(ids));
    const [code]=await once(c,'close');if(code!==0) throw Error(`ack失敗: ${err}`);
    this.state.batch=null;this.save();this.phase='IDLE';
  }
  async input(content,initial=false) {
    this.check();if(this.busy) throw Error('入力重複');
    this.busy=true;this.phase=initial?'INITIALIZING':'BUSY';this.delta=false;
    if(!initial) {this.state.batch.phase='sent';this.save();}
    this.deadline=Date.now()+(initial?60000:330000);
    await new Promise((resolve,reject)=>this.child.stdin.write(JSON.stringify({event:'user',message:{content}})+'\n',error=>error?reject(error):resolve()));
  }
  async launch() {
    const args=['--input-format','stream-json','--output-format','stream-json','--print-timeout','5m'];
    if(this.state.conversation_id) args.push('--conversation',this.state.conversation_id);
    if(this.o.model) args.push('--model',this.o.model);
    const executable=this.o.agy||'agy';
    // fd3能力値はこの子へ継承しない。stdin/stdout/stderrだけを接続する。
    this.child=spawn(executable,args,{cwd:this.project,stdio:['pipe','pipe','pipe']});
    this.childStart=null;try{this.childStart=proc(this.child.pid).start;}catch{}
    const child=this.child;
    child.stderr.on('data',d=>process.stderr.write(d));child.stdin.on('error',e=>this.fail(e));
    let buffer='';this.queue=Promise.resolve();
    child.stdout.setEncoding('utf8');
    child.stdout.on('data',chunk=>{
      buffer+=chunk;
      if(Buffer.byteLength(buffer)>8*1024*1024) return this.fail(Error('NDJSON上限超過'));
      let n;while((n=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,n);buffer=buffer.slice(n+1);if(!line)continue;
        this.queue=this.queue.then(()=>this.event(JSON.parse(line))).catch(e=>this.fail(e));}
    });
    child.on('error',e=>this.fail(e));
    child.on('close',()=>{this.queue.then(async()=>{
      if(this.stopping||this.failed)return;
      if(buffer||this.busy||this.state.batch)return this.fail(Error('ターン途中で子終了'));
      if(!this.state.conversation_id||this.restarts>=3)return this.fail(Error('再起動予算超過'));
      const delay=[1000,5000,15000][this.restarts++];await sleep(delay);
      if(!this.stopping) await this.launch().catch(e=>this.fail(e));
    });});
    await this.input(`あなたはagmsg headless workerです。team=${this.team}, role=${this.role}, project=${this.project}。受信と既読はbridge専用。inbox.sh/check-inbox.sh/引数なし$agmsgを呼ばない。返信が必要なら bash ${root}/scripts/send.sh ${this.team} ${this.role} <送信先> --stdin を使用。承認不能の操作は報告する。初期化完了とだけ返答。`,true);
  }
  async event(e) {
    if(this.failed||this.stopping)return;
    const id=e.conversation_id??e.step_update?.conversation_id??e.result?.conversation_id;
    if(id && this.state.conversation_id && id!==this.state.conversation_id)throw Error('conversation不一致');
    if(e.event==='init') {
      if(!id)throw Error('init IDなし');this.state.conversation_id=id;this.save();this.call('record',[id]);return;
    }
    if(e.event==='step_update') {
      if(forbiddenTool(e))throw Error('stream内inbox取得操作を検知');
      if(e.step_update?.text_delta){process.stdout.write(e.step_update.text_delta);this.delta=true;}return;
    }
    if(e.event!=='result'){this.log(`未知event ${e.event}`);return;}
    if(!this.busy)throw Error('対応入力のないresult');
    this.check();
    if(e.result?.status!=='SUCCESS'||!this.state.conversation_id)throw Error(`未完了result ${e.result?.status}`);
    if(!this.delta && e.result.response)console.log(e.result.response);
    const initial=this.phase==='INITIALIZING';this.busy=false;this.deadline=null;this.restarts=0;
    if(!initial){this.state.batch.phase='completed';this.save();await this.ack();}
    this.phase='IDLE';this.log('ready');
    if(initial&&this.replay){this.replay=false;await this.input(JSON.stringify(this.state.batch));}
  }
  async tick() {
    this.check();if(this.deadline&&Date.now()>this.deadline)throw Error('ターン時間超過');
    if(this.busy||this.phase!=='IDLE')return;
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
    for(const m of messages){const size=Buffer.byteLength(m.body);if(size>65536)throw Error(`本文上限超過 id=${m.id}`);if(bytes+size>65536)break;bytes+=size;batch.push(m);}
    this.state.batch={id:randomUUID(),phase:'prepared',messages:batch};this.save();
    await this.input(JSON.stringify(this.state.batch));
  }
  fail(error) {
    // SIGINT/SIGTERM後のin-flight peek終了は正常停止の一部であり、
    // NEEDS_ATTENTIONへ上書きして予約解放を競合させない。
    if(this.stopping)return;
    if(this.failed)return;this.failed=true;this.phase='NEEDS_ATTENTION';
    if(this.state?.batch&&this.state.batch.phase!=='completed'){this.state.batch.phase='uncertain';try{this.save();}catch{}}
    this.log(error.message);this.stop().catch(e=>console.error(e.message));
  }
  async stop() {
    if(this.stopping)return;this.stopping=true;clearInterval(this.timer);
    const child=this.child;
    if(child&&child.exitCode===null&&child.signalCode===null){
      child.stdin.end();
      const ended=once(child,'close').catch(()=>{});
      await Promise.race([ended,shutdownDelay(30000)]);
      if(child.exitCode===null&&child.signalCode===null){
        try{if(proc(child.pid).start===this.childStart)child.kill('SIGTERM');}catch{}
        await Promise.race([ended,shutdownDelay(3000)]);
        if(child.exitCode===null&&child.signalCode===null)throw Error('自所有の子が終了せず予約保持');
      }
    }
    if(this.state?.batch){this.log('batch保持。status/resolveが必要');process.exitCode=1;return;}
    // process group signal may kill a transport child while verify/release is
    // running.  Revalidate the durable owner record locally, then remove only
    // our own reservation and matching actas lock.
    const reservation=read(this.reservation);
    if(reservation.owner!==this.owner||reservation.start!==this.start)throw Error('予約所有権不一致');
    if(fs.readFileSync(this.actas,'utf8').trim()!==this.owner)throw Error('actas所有権不一致');
    fs.unlinkSync(this.reservation);
    fs.unlinkSync(this.actas);
    this.phase='STOPPED';this.log('停止');
  }
  async run(){
    if(!await this.acquire()){await this.stop();return;}
    await this.launch();
    this.timer=setInterval(()=>{if(this.ticking||this.stopping)return;this.ticking=true;this.tick().catch(e=>{
      if(e.code==='SIGNAL_TRANSPORT'&&!this.busy&&this.phase==='IDLE'&&!this.state?.batch)this.stop().catch(stopError=>console.error(stopError.message));
      else this.fail(e);
    }).finally(()=>this.ticking=false);},Number(this.o.poll||2000));
    process.once('SIGINT',()=>this.stop());process.once('SIGTERM',()=>this.stop());
  }
}
if(process.argv[1]===fileURLToPath(import.meta.url)) {
  const o={};for(let i=2;i<process.argv.length;i+=2){if(!process.argv[i].startsWith('--')||!process.argv[i+1])throw Error('引数は --key value');o[process.argv[i].slice(2)]=process.argv[i+1];}
  if(!o.project||!o.team||!o.name)throw Error('--project --team --name が必要');
  const b=new Bridge(o);
  if(o.command==='status')console.log(JSON.stringify(fs.existsSync(b.file)?read(b.file):{status:'未起動'},null,2));
  else b.run().catch(e=>{console.error(e.message);process.exitCode=1;});
}
