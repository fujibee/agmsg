import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {once} from 'node:events';
import {forbiddenTool} from '../scripts/drivers/types/antigravity/antigravity-bridge.mjs';
const repo=path.resolve(import.meta.dirname,'..');
const delay=ms=>new Promise(r=>setTimeout(r,ms));
// 並列時は各fixtureが複数のbash/node子プロセスを生成するため、15秒では
// 正常なNEEDS_ATTENTION到達をtimeoutと誤判定しうる。上限を60秒にする。
async function waitFor(fn){for(let i=0;i<600;i++){if(fn())return;await delay(100);}throw Error('待機timeout');}
function fixture(driver='sqlite',mode='success',extra={}) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'agmsg-agy-test-'));
  const install=path.join(dir,'install'),project=path.join(dir,'project');
  fs.mkdirSync(install);fs.mkdirSync(project);
  fs.cpSync(path.join(repo,'scripts'),path.join(install,'scripts'),{recursive:true});
  fs.copyFileSync(path.join(repo,'tests/fixtures/fake-antigravity.mjs'),path.join(dir,'fake.mjs'));
  const fake=path.join(dir,'agy');fs.writeFileSync(fake,`#!/bin/sh\nexec '${process.execPath}' '${dir}/fake.mjs' "$@"\n`,{mode:0o700});
  const env={...process.env,AGMSG_STORAGE_DRIVER:driver,AGMSG_STORAGE_PATH:path.join(install,'db'),AGMSG_CONFIG:path.join(dir,'config.json'),FAKE_AGY_MODE:mode,FIXTURE_INSTALL:install,...extra};
  const sh=(name,args=[])=>{const r=spawnSync('bash',[path.join(install,'scripts',name),...args],{env,encoding:'utf8'});assert.equal(r.status,0,r.stderr+r.stdout);return r.stdout;};
  sh('join.sh',['fixture','worker','antigravity',project]);
  sh('join.sh',['fixture','sender','codex',project]);
  sh('delivery.sh',['set','monitor','antigravity',project]);
  let output='';const child=spawn('bash',[path.join(install,'scripts/drivers/types/antigravity/antigravity-monitor.sh'),'--project',project,'--team','fixture','--name','worker','--agy',fake,'--poll','100'],{env,stdio:['pipe','pipe','pipe'],detached:true});
  const children=[child];
  child.stdout.on('data',d=>output+=d);child.stderr.on('data',d=>output+=d);
  const unread=()=>sh('drivers/types/antigravity/inbox-transport.sh',['peek',project,'fixture','worker',state().owner]).trim();
  const state=()=>{const f=fs.readdirSync(path.join(install,'run')).find(f=>f.endsWith('.state.json'));return JSON.parse(fs.readFileSync(path.join(install,'run',f),'utf8'));};
  return {dir,install,project,env,sh,child,state,unread,output:()=>output,track(c){children.push(c);},async close(){
    for(const c of children){
      if(c.exitCode===null){try{process.kill(-c.pid,'SIGTERM');}catch{} await Promise.race([once(c,'close'),delay(5000)]);}
      if(c.exitCode===null&&c.signalCode===null)c.kill('SIGKILL');
    }
  }};
}
for(const driver of ['sqlite','jsonl'])test(`隔離${driver}: 2通をSUCCESS後だけ既読化`,async()=>{
  const f=fixture(driver);try {
    await waitFor(()=>f.output().includes('ready'));
    f.sh('send.sh',['fixture','sender','worker','first']);
    await waitFor(()=>f.output().includes('turn 2')&&f.state().batch===null);
    f.sh('send.sh',['fixture','sender','worker','second']);
    await waitFor(()=>f.output().includes('turn 3')&&f.state().batch===null);
    assert.equal(f.unread(),'');assert.equal(f.state().conversation_id,'fixture-conversation');
  }catch(e){e.message+='\n'+f.output();throw e;}finally{await f.close();}
});
test('stream tool検知は命令だけを見る',()=>{
  const base={event:'step_update',step_update:{step_type:'tool',tool_info:{parameters:{CommandLine:'bash /tmp/inbox.sh team role'}}}};
  assert.equal(forbiddenTool(base),true);
  assert.equal(forbiddenTool({event:'step_update',step_update:{step_type:'agent_response',text_delta:'inbox.sh'}}),false);
  base.step_update.tool_info={parameters:{CommandLine:'echo safe'},output:'inbox.sh'};
  assert.equal(forbiddenTool(base),false);
});

test('予約なしの陽性対照ではinboxの既読化が進む',async()=>{
  const f=fixture();
  try {
    await waitFor(()=>f.output().includes('ready'));
    await f.close();
    f.sh('send.sh',['fixture','sender','worker','positive control']);
    const out=f.sh('inbox.sh',['fixture','worker']);
    assert.match(out,/positive control/);
  } finally { await f.close(); }
});

test('既知turn rulefileだけをmonitor markerへ移行する',async()=>{
  const f=fixture();
  try {
    await waitFor(()=>f.output().includes('ready'));
    await f.close();
    f.sh('delivery.sh',['set','turn','antigravity',f.project]);
    const turn=fs.readFileSync(path.join(f.project,'.agent/rules/agmsg.md'),'utf8');
    assert.match(turn,/PostToolUse/);
    f.sh('delivery.sh',['set','monitor','antigravity',f.project]);
    assert.match(fs.readFileSync(path.join(f.project,'.agent/rules/agmsg.md'),'utf8'),/^<!-- agmsg:antigravity:monitor -->/);
  } finally { await f.close(); }
});

test('未知rulefileのmonitor移行は拒否して内容を保持する',async()=>{
  const f=fixture();
  try {
    await waitFor(()=>f.output().includes('ready'));
    await f.close();
    const file=path.join(f.project,'.agent/rules/agmsg.md');
    fs.writeFileSync(file,'# local rule\n');
    const r=spawnSync('bash',[path.join(f.install,'scripts/delivery.sh'),'set','monitor','antigravity',f.project],{env:f.env,encoding:'utf8'});
    assert.notEqual(r.status,0);
    assert.equal(fs.readFileSync(file,'utf8'),'# local rule\n');
  } finally { await f.close(); }
});

test('二重起動を拒否する',async()=>{
  const f=fixture();
  try {
    await waitFor(()=>f.output().includes('ready'));
    const second=spawnSync('bash',[path.join(f.install,'scripts/drivers/types/antigravity/antigravity-monitor.sh'),'--project',f.project,'--team','fixture','--name','worker','--agy',path.join(f.dir,'agy'),'--poll','100'],{env:f.env,encoding:'utf8'});
    assert.notEqual(second.status,0);
  } finally { await f.close(); }
});

test('IDLE中のpeek停止はNEEDS_ATTENTIONへ遷移せず予約を解放する',async()=>{
  const barrier=path.join(os.tmpdir(),`agmsg-peek-${process.pid}-${Date.now()}`);
  const f=fixture('sqlite','success',{AGMSG_TEST_PEEK_BARRIER:barrier});
  try {
    await waitFor(()=>f.output().includes('ready')&&fs.existsSync(`${barrier}.reached`));
    f.child.kill('SIGTERM');
    fs.writeFileSync(`${barrier}.release`,'');
    await waitFor(()=>f.child.exitCode!==null);
    assert.doesNotMatch(f.output(),/NEEDS_ATTENTION/);
    assert.match(f.output(),/停止/);
    assert.equal(f.state().batch,null);
    assert.equal(fs.readdirSync(path.join(f.install,'run')).some(name=>name.startsWith('antigravity-reservation.')&&name.endsWith('.json')),false);
    assert.equal(fs.readdirSync(path.join(f.install,'run')).some(name=>name.startsWith('actas.fixture__worker.')),false);
  } finally { fs.rmSync(`${barrier}.release`,{force:true}); fs.rmSync(`${barrier}.reached`,{force:true}); await f.close(); }
});

test('IDLE中のpeek非0終了後のgroup停止は正常停止として扱う',async()=>{
  const failure=path.join(os.tmpdir(),`agmsg-peek-failure-${process.pid}-${Date.now()}`);
  const f=fixture('sqlite','success',{AGMSG_TEST_PEEK_FAILURE:failure});
  try {
    await waitFor(()=>f.output().includes('ready'));
    await waitFor(()=>fs.existsSync(`${failure}.reached`));
    assert.equal(fs.existsSync(`${failure}.reached`),true);
    try { process.kill(-f.child.pid,'SIGTERM'); } catch {}
    await waitFor(()=>f.child.exitCode!==null);
    assert.doesNotMatch(f.output(),/NEEDS_ATTENTION/);
    assert.match(f.output(),/停止/);
    assert.equal(f.state().batch,null);
    assert.equal(fs.readdirSync(path.join(f.install,'run')).some(name=>name.startsWith('antigravity-reservation.')&&name.endsWith('.json')),false);
    assert.equal(fs.readdirSync(path.join(f.install,'run')).some(name=>name.startsWith('actas.fixture__worker.')),false);
  } finally { fs.rmSync(`${failure}.reached`,{force:true}); await f.close(); }
});

test('IDLE中peek subprocessのSIGTERM終了は正常停止として扱う',async()=>{
  const signal=path.join(os.tmpdir(),`agmsg-peek-signal-${process.pid}-${Date.now()}`);
  const f=fixture('sqlite','success',{AGMSG_TEST_PEEK_SIGNAL:signal});
  try {
    await waitFor(()=>fs.existsSync(`${signal}.reached`));
    await waitFor(()=>f.child.exitCode!==null);
    assert.doesNotMatch(f.output(),/NEEDS_ATTENTION/);
    assert.match(f.output(),/停止/);
    assert.equal(f.state().batch,null);
    assert.equal(fs.readdirSync(path.join(f.install,'run')).some(name=>name.startsWith('antigravity-reservation.')&&name.endsWith('.json')),false);
    assert.equal(fs.readdirSync(path.join(f.install,'run')).some(name=>name.startsWith('actas.fixture__worker.')),false);
  } finally { fs.rmSync(`${signal}.reached`,{force:true}); await f.close(); }
});

test('本文上限超過はNEEDS_ATTENTIONとして停止する',async()=>{
  const f=fixture();
  try {
    await waitFor(()=>f.output().includes('ready'));
    f.sh('send.sh',['fixture','sender','worker','x'.repeat(65537)]);
    await waitFor(()=>f.output().includes('NEEDS_ATTENTION'));
    assert.match(f.output(),/本文上限超過/);
    assert.equal(f.state().batch,null);
  } finally { await f.close(); }
});

test('IDLE中verifyのSIGTERM終了は正常停止として扱う',async()=>{
  const signal=path.join(os.tmpdir(),`agmsg-verify-signal-${process.pid}-${Date.now()}`);
  const f=fixture('sqlite','success',{AGMSG_TEST_VERIFY_SIGNAL:signal});
  try {
    await waitFor(()=>f.output().includes('ready'));
    await waitFor(()=>f.child.exitCode!==null);
    assert.doesNotMatch(f.output(),/NEEDS_ATTENTION/);
    assert.match(f.output(),/停止/);
    assert.equal(f.state().batch,null);
    assert.equal(fs.readdirSync(path.join(f.install,'run')).some(name=>name.startsWith('antigravity-reservation.')&&name.endsWith('.json')),false);
    assert.equal(fs.readdirSync(path.join(f.install,'run')).some(name=>name.startsWith('actas.fixture__worker.')),false);
  } finally { fs.rmSync(`${signal}.count`,{force:true}); await f.close(); }
});

test('completed batchの明示ack復旧はモデルを再実行しない',async()=>{
  const f=fixture('sqlite','attack');
  try {
    await waitFor(()=>f.output().includes('ready'));
    f.sh('send.sh',['fixture','sender','worker','recover me']);
    await waitFor(()=>f.output().includes('NEEDS_ATTENTION'));
    const before=f.state();
    const ids=before.batch.messages.map(m=>m.id);
    await f.close();
    const r=spawnSync('bash',[path.join(f.install,'scripts/drivers/types/antigravity/antigravity-monitor.sh'),'--project',f.project,'--team','fixture','--name','worker','--agy',path.join(f.dir,'agy'),'--action','ack','--batch',before.batch.id,'--confirm-ids',ids.join(',' )],{env:f.env,encoding:'utf8'});
    assert.equal(r.status,0,r.stderr+r.stdout);
    const after=f.state();
    assert.equal(after.batch,null);
    assert.equal(after.conversation_id,'fixture-conversation');
  } finally { await f.close(); }
});

test('uncertain batchの明示replayは保存済みIDと本文を再投入する',async()=>{
  const f=fixture('sqlite','attack');
  try {
    await waitFor(()=>f.output().includes('ready'));
    f.sh('send.sh',['fixture','sender','worker','replay me']);
    await waitFor(()=>f.output().includes('NEEDS_ATTENTION'));
    const before=f.state();
    const ids=before.batch.messages.map(m=>m.id);
    const body=before.batch.messages[0].body;
    await f.close();
    f.env.FAKE_AGY_MODE='success';
    const child=spawn('bash',[path.join(f.install,'scripts/drivers/types/antigravity/antigravity-monitor.sh'),'--project',f.project,'--team','fixture','--name','worker','--agy',path.join(f.dir,'agy'),'--action','replay','--batch',before.batch.id,'--confirm-ids',ids.join(',') ,'--poll','100'],{env:f.env,stdio:['pipe','pipe','pipe'],detached:true});
    f.track(child);
    let output='';child.stdout.on('data',d=>output+=d);child.stderr.on('data',d=>output+=d);
    await waitFor(()=>f.state().batch===null);
    child.kill('SIGTERM');
    await Promise.race([once(child,'close'),delay(5000)]);
    assert.match(output,/turn 2/);
    if (f.state().batch) {
      assert.equal(f.state().batch.messages.length,1);
      assert.equal(f.state().batch.messages[0].body,'late B');
    }
    assert.equal(body,'replay me');
  } finally { await f.close(); }
});

for(const mode of ['attack','append-failure','crash','broken'])test(`異常 ${mode}: batchを保持し自動ackしない`,async()=>{
  const f=fixture('sqlite',mode);try {
    await waitFor(()=>f.output().includes('ready'));
    f.sh('send.sh',['fixture','sender','worker','batch A']);
    await waitFor(()=>f.output().includes('NEEDS_ATTENTION'));
    assert.equal(f.state().batch.phase,'uncertain');
    const unread=f.unread().split('\n').map(JSON.parse);
    assert.equal(unread.length,mode==='attack'||mode==='append-failure'?2:1);
    assert.equal(f.state().batch.messages.length,1);
  }catch(e){e.message+='\n'+f.output();throw e;}finally{await f.close();}
});
