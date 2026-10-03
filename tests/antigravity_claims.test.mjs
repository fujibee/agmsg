import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {spawn,spawnSync} from 'node:child_process';
import {once} from 'node:events';
const repo=path.resolve(import.meta.dirname,'..');
const shellQuote=value=>"'"+value.replaceAll("'","'\\''")+"'";
async function fixture() {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'agmsg-protected-'));
  const install=path.join(dir,'install'),project=path.join(dir,'project');
  fs.mkdirSync(project);fs.mkdirSync(install);fs.cpSync(path.join(repo,'scripts'),path.join(install,'scripts'),{recursive:true});
  const env={AGMSG_STORAGE_DRIVER:'sqlite',AGMSG_STORAGE_PATH:path.join(install,'db'),AGMSG_CONFIG:path.join(dir,'config.json'),AGMSG_SELF_NAME:'off'};
  const previous={};for(const [k,v] of Object.entries(env)){previous[k]=process.env[k];process.env[k]=v;}
  const sh=(name,args=[],input)=>spawnSync('bash',[path.join(install,'scripts',name),...args],{encoding:'utf8',input});
  for(const [name,args] of [['join.sh',['protected','bob','antigravity',project]],['join.sh',['protected','alice','codex',project]],['delivery.sh',['set','monitor','antigravity',project]]]) {
    const r=sh(name,args);assert.equal(r.status,0,r.stdout+r.stderr);
  }
  const {Bridge}=await import(pathToFileURL(path.join(install,'scripts/drivers/types/antigravity/antigravity-bridge.mjs')));
  const bridge=new Bridge({project,team:'protected',name:'bob'});
  const sql=query=>{const r=spawnSync('sqlite3',[path.join(install,'db/messages.db'),query],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
  const send=body=>{const r=sh('send.sh',['protected','alice','bob',body]);assert.equal(r.status,0,r.stderr);return r.stdout;};
  const api=(op,request)=>sh('delivery-claims.sh',[op],JSON.stringify({team:'protected',agent:'bob',...request}));
  async function rawDelivery(command,request={},mode='direct') {
    const args=[path.join(install,'scripts/drivers/types/antigravity/inbox-transport.sh'),command,project,'protected','bob',bridge.owner];
    const child=mode==='grandchild'
      ?spawn(process.execPath,['-e','const{spawnSync}=require("node:child_process");const r=spawnSync("bash",process.argv.slice(1),{stdio:[0,1,2,3]});process.exit(r.status??1)',...args],{stdio:['pipe','pipe','pipe','pipe']})
      :spawn('bash',args,{stdio:mode==='missing-cap'?['pipe','pipe','pipe']:['pipe','pipe','pipe','pipe']});
    let stdout='',stderr='';child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);
    child.stdin.on('error',()=>{});child.stdin.end(JSON.stringify(request));
    if(child.stdio[3]){child.stdio[3].on('error',()=>{});child.stdio[3].end(bridge.cap+'\n');}
    const [status]=await once(child,'close');return {status,stdout,stderr};
  }
  function saveRows(rows) {
    bridge.state.batch={id:'batch',phase:'prepared',original_ids:rows.map(m=>m.id),claim_ids:rows.map(m=>m.id),claim_owner:bridge.owner,
      claim_token:rows[0].claim_token,protection_id:rows[0].protection_id,claim_expires_at:rows[0].claim_expires_at,
      messages:rows.map(({claim_token,protection_id,claim_expires_at,...m})=>m)};bridge.save();
  }
  return {dir,install,project,bridge,sql,send,api,saveRows,sh,rawDelivery,close(){for(const [k,v] of Object.entries(previous)){if(v===undefined)delete process.env[k];else process.env[k]=v;}}};
}

test('a generic NOT_SENT release drains under a published reservation without marking read',async()=>{
  const f=await fixture();try {
    f.send('not attempted');const acquired=f.api('claim',{owner:'generic',ttl:600,limit:20});assert.equal(acquired.status,0,acquired.stderr);
    const row=JSON.parse(acquired.stdout);await f.bridge.acquire();
    await assert.rejects(f.bridge.delivery('receive'),/claims_active/);
    const released=f.api('release',{owner:'generic',token:row.claim_token,ids:[row.id]});assert.equal(released.status,0,released.stderr);
    assert.equal(f.sql('SELECT count(*) FROM delivery_claims;'),'0');
    assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'0');
    assert.equal(f.sql('SELECT count(*) FROM messages WHERE read_at IS NULL;'),'1');
    const rows=(await f.bridge.delivery('receive')).trim().split('\n').map(JSON.parse);assert.deepEqual(rows.map(m=>m.id),[row.id]);
    assert.equal(fs.readFileSync(f.bridge.violation,'utf8'),'');
  }finally{f.close();}
});

test('real transport drains generic ACK/receipt/release, refuses renewal and protects its own fence',async()=>{
  const f=await fixture();try {
    f.send('generic accepted');let r=f.api('claim',{owner:'generic',ttl:600,limit:20});assert.equal(r.status,0,r.stderr);
    const old=JSON.parse(r.stdout);
    await f.bridge.acquire();assert.equal(f.bridge.deliveryMode,'claims');
    await assert.rejects(f.bridge.delivery('receive'),/claims_active/);
    r=f.api('renew',{owner:'generic',token:old.claim_token,ttl:600,ids:[old.id]});assert.equal(r.status,13);
    r=f.api('ack',{owner:'generic',token:old.claim_token,ids:[old.id]});assert.equal(r.status,0,r.stderr);
    r=f.api('ack',{owner:'generic',token:old.claim_token,ids:[old.id]});assert.equal(r.status,0,r.stderr);
    assert.equal(fs.readFileSync(f.bridge.violation,'utf8'),'');
    f.send('protected delivery');const rows=(await f.bridge.delivery('receive')).trim().split('\n').map(JSON.parse);f.saveRows(rows);
    r=f.api('ack',{owner:f.bridge.owner,token:rows[0].claim_token,ids:[rows[0].id]});assert.equal(r.status,13);
    await f.bridge.renew();
    await assert.rejects(f.bridge.delivery('finish',f.bridge.claimRequest()),/authorization/);
    f.bridge.state.batch.phase='completed';f.bridge.save();await f.bridge.ack();
    r=f.api('ack',{owner:f.bridge.owner,token:rows[0].claim_token,ids:[rows[0].id]});assert.equal(r.status,13);
    fs.unlinkSync(f.bridge.reservation);
    r=f.api('ack',{owner:f.bridge.owner,token:rows[0].claim_token,ids:[rows[0].id]});assert.equal(r.status,13,'protected receipt stays protected without role state');
  }finally{f.close();}
});

test('real FD3 guard rejects wrong capability, subset and stale token without latching contention',async()=>{
  const f=await fixture();try {
    await f.bridge.acquire();f.send('one');f.send('two');
    const rows=(await f.bridge.delivery('receive')).trim().split('\n').map(JSON.parse);f.saveRows(rows);
    const cap=f.bridge.cap;f.bridge.cap='wrong';await assert.rejects(f.bridge.renew(),/authorization/);f.bridge.cap=cap;
    const req=f.bridge.claimRequest();await assert.rejects(f.bridge.delivery('renew',{...req,ids:req.ids.slice(0,1)}),/authorization/);
    await assert.rejects(f.bridge.delivery('renew',{...req,token:'a'.repeat(64)}),/authorization/);
    await f.bridge.renew();assert.equal(fs.readFileSync(f.bridge.violation,'utf8'),'');
  }finally{f.close();}
});

test('actual FD3 transport refuses missing capability, grandchild, stale start and actas mismatch',async()=>{
  const f=await fixture();try {
    await f.bridge.acquire();f.send('guarded');const rows=(await f.bridge.delivery('receive')).trim().split('\n').map(JSON.parse);f.saveRows(rows);
    const request=f.bridge.claimRequest(),saved=fs.readFileSync(f.bridge.reservation,'utf8');
    for(const mode of ['missing-cap','grandchild','stale-start','actas-mismatch']) {
      if(mode==='stale-start'){const r=JSON.parse(saved);r.start+='-stale';fs.writeFileSync(f.bridge.reservation,JSON.stringify(r));}
      if(mode==='actas-mismatch')fs.writeFileSync(f.bridge.actas,'other-owner\n');
      const result=await f.rawDelivery('renew',request,['missing-cap','grandchild'].includes(mode)?mode:'direct');
      assert.notEqual(result.status,0,mode);assert.equal(result.stdout,'',mode);
      assert.equal(f.sql('SELECT token FROM delivery_claims;'),request.token,mode);
      assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'0',mode);
      fs.writeFileSync(f.bridge.reservation,saved);fs.writeFileSync(f.bridge.actas,f.bridge.owner+'\n');
    }
    await f.bridge.renew();assert.equal(fs.readFileSync(f.bridge.violation,'utf8'),'');
  }finally{f.close();}
});

test('maintenance installed first blocks published bridge, and publication during begin cancels maintenance',async()=>{
  const f=await fixture();try {
    // Acquire enough normal context to use the actual private admission check.
    await f.bridge.acquire();fs.unlinkSync(f.bridge.reservation);
    const source=path.join(f.install,'scripts/lib/storage.sh');
    const run=body=>spawnSync('bash',['-c','source "$1"; agmsg_storage_load; '+body,'fixture',source],{encoding:'utf8'});
    let r=run('_sqlite_delivery_maintenance_begin_db "$(agmsg_db_path protected)" fixture protected');assert.equal(r.status,0,r.stderr);
    const barrier=JSON.parse(r.stdout);await assert.rejects(f.bridge.acquire(),/maintenance_active/);
    assert.ok(fs.existsSync(f.bridge.reservation));
    f.sql(`DELETE FROM delivery_maintenance;`);fs.unlinkSync(f.bridge.reservation);
    const reservation=JSON.stringify({type:'antigravity',state:f.bridge.file});
    fs.writeFileSync(path.join(f.dir,'reservation.json'),reservation);
    r=run('source "$(dirname "$1")/delivery-maintenance.sh"; '+
      'eval "$(declare -f _sqlite_delivery_maintenance_begin_db | sed \'1s/_sqlite_delivery_maintenance_begin_db/_begin_original/\')"; '+
      '_sqlite_delivery_maintenance_begin_db(){ _begin_original "$@"; cp "$2" "'+f.bridge.reservation+'"; }; '+
      'agmsg_dm_begin "$(agmsg_db_path protected)" "'+path.join(f.dir,'reservation.json')+'" protected');
    assert.notEqual(r.status,0);assert.match(r.stderr,/durable read reservation/);
    assert.equal(f.sql('SELECT count(*) FROM delivery_maintenance;'),'0');
  }finally{f.close();}
});

test('stream attempt is durable before a failing write and message input contains no claim credentials',async()=>{
  const f=await fixture();try {
    await f.bridge.acquire();f.send('body');const rows=(await f.bridge.delivery('receive')).trim().split('\n').map(JSON.parse);f.saveRows(rows);
    const content=f.bridge.deliveryContent();assert.doesNotMatch(content,/claim_token|protection_id/);
    f.bridge.child={stdin:{write(_data,done){assert.equal(JSON.parse(fs.readFileSync(f.bridge.file,'utf8')).batch.phase,'sent');done(Error('partial stream write'));}}};
    await assert.rejects(f.bridge.input(content),/partial stream write/);
    const exitCode=process.exitCode;f.bridge.fail(Error('partial stream write'));process.exitCode=exitCode;
    assert.equal(f.bridge.state.batch.phase,'uncertain');assert.equal(f.sql('SELECT count(*) FROM delivery_claims;'),'1');
  }finally{f.close();}
});

test('verified-dead tokenless and expired recovery reconciles mixed reads and all-read replay stays silent',async()=>{
  for(const tokenless of [true,false]) {
    const f=await fixture();try {
      await f.bridge.acquire();f.send('already read');f.send('still unread');
      const rows=(await f.bridge.delivery('receive')).trim().split('\n').map(JSON.parse);f.saveRows(rows);
      const ids=rows.map(m=>m.id),b=f.bridge.state.batch;
      b.phase='uncertain';
      const deadOwner='recovery.2147483647';f.bridge.state.owner=deadOwner;
      if(tokenless){delete b.claim_token;delete b.protection_id;delete b.claim_ids;delete b.claim_owner;f.sql('DELETE FROM delivery_claims;');}
      else {b.claim_owner=deadOwner;f.sql(`UPDATE delivery_claims SET owner='${deadOwner}',expires_at=0;`);}
      f.bridge.save();fs.writeFileSync(f.bridge.actas,deadOwner+'\n');
      const reservation=JSON.parse(fs.readFileSync(f.bridge.reservation,'utf8'));
      Object.assign(reservation,{owner:deadOwner,pid:2147483647,start:'dead'});fs.writeFileSync(f.bridge.reservation,JSON.stringify(reservation));
      f.sql(`INSERT INTO events(type,id,team,agent,msg_id,at) VALUES('message_read','fixture-read','protected','bob','${ids[0]}','now');`);
      assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'1');
      const replacement=new f.bridge.constructor({project:f.project,team:'protected',name:'bob',action:'replay',batch:'batch','confirm-ids':ids.join(',')});
      assert.equal(await replacement.acquire(),true);
      assert.deepEqual(replacement.state.batch.original_ids.sort(),[...ids].sort());
      assert.deepEqual(replacement.state.batch.claim_ids,[ids[1]]);
      assert.equal(JSON.parse(replacement.deliveryContent()).messages.length,1);
      replacement.state.batch.phase='completed';replacement.save();
      // Simulate successful ACK followed by crash before clearing saved state.
      await replacement.delivery('finish',replacement.claimRequest());
      assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'2','only the unread original member gains a read event');
      assert.equal(f.sql(`SELECT count(*) FROM events WHERE type='message_read' AND msg_id='${ids[1]}';`),'1');
      assert.equal(f.sql('SELECT count(*) FROM delivery_ack_receipts;'),'1');
      const old=JSON.parse(fs.readFileSync(replacement.reservation,'utf8'));
      replacement.state.owner=deadOwner;replacement.save();fs.writeFileSync(replacement.actas,deadOwner+'\n');
      Object.assign(old,{owner:deadOwner,pid:2147483647,start:'dead'});fs.writeFileSync(replacement.reservation,JSON.stringify(old));
      const retry=new f.bridge.constructor({project:f.project,team:'protected',name:'bob',action:'replay',batch:'batch','confirm-ids':ids.join(',')});
      assert.equal(await retry.acquire(),false,'already-read recovery must not launch/reinject');
      assert.equal(retry.state.batch,null);
      assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'2','lost ACK reply recovery cannot duplicate read events');
      assert.equal(f.sql('SELECT count(*) FROM delivery_claims;'),'0');
    }finally{f.close();}
  }
});

test('reservation publication after generic commit withholds payload and bridge waits for expiry',async()=>{
  const f=await fixture();try {
    await f.bridge.acquire();f.send('must remain undisclosed');
    const saved=path.join(f.dir,'saved-reservation.json');fs.copyFileSync(f.bridge.reservation,saved);fs.unlinkSync(f.bridge.reservation);
    const source=path.join(f.install,'scripts/lib/storage.sh');
    const r=spawnSync('bash',['-c',
      'source "$1"; agmsg_storage_load; source "$(dirname "$1")/delivery-claims.sh"; '+
      'eval "$(declare -f storage_claim_unread | sed \'1s/storage_claim_unread/_original_claim/\')"; '+
      'storage_claim_unread(){ _original_claim "$@"; cp "$AGY_TEST_SAVED_RESERVATION" "$AGY_TEST_RESERVATION"; }; '+
      'agmsg_delivery_claim_unread protected bob generic 600 20',
      'fixture',source],{encoding:'utf8',env:{...process.env,AGY_TEST_SAVED_RESERVATION:saved,AGY_TEST_RESERVATION:f.bridge.reservation}});
    assert.equal(r.status,13,r.stderr);assert.equal(r.stdout,'');
    assert.equal(f.sql('SELECT count(*) FROM delivery_claims;'),'1');
    await assert.rejects(f.bridge.delivery('receive'),/claims_active/);
    f.sql('UPDATE delivery_claims SET expires_at=0;');
    const rows=(await f.bridge.delivery('receive')).trim().split('\n').map(JSON.parse);assert.equal(rows.length,1);
    assert.equal(rows[0].body,'must remain undisclosed');
    assert.equal(fs.readFileSync(f.bridge.violation,'utf8'),'');
  }finally{f.close();}
});

test('reservation validation accepts dead tokenless and orphan states but refuses corrupt identity',async()=>{
  const f=await fixture();try {
    await f.bridge.acquire();
    const mod=await import(pathToFileURL(path.join(f.install,'scripts/drivers/types/antigravity/bridge-read-guard.mjs')));
    const reservation=JSON.parse(fs.readFileSync(f.bridge.reservation,'utf8'));
    reservation.pid=2147483647;reservation.start='dead';fs.writeFileSync(f.bridge.reservation,JSON.stringify(reservation));
    mod.validateReservation(f.bridge.reservation,'protected','bob');
    f.bridge.state.batch={id:'old',phase:'uncertain',messages:[{id:'legacy',team:'protected',from:'a',to:'bob',body:'body',at:'now'}]};f.bridge.save();
    mod.validateReservation(f.bridge.reservation,'protected','bob');
    f.bridge.state.role='carol';f.bridge.save();
    assert.throws(()=>mod.validateReservation(f.bridge.reservation,'protected','bob'),/malformed/);
    assert.equal(fs.readFileSync(f.bridge.violation,'utf8'),'');
  }finally{f.close();}
});

test('protected controls require exact ok-LF without clearing durable state or claims',async()=>{
  const f=await fixture();try {
    await f.bridge.acquire();f.send('retain until a verified control response');
    const rows=(await f.bridge.delivery('receive')).trim().split('\n').map(JSON.parse);f.saveRows(rows);
    const driver=path.join(f.install,'scripts/drivers/storage/sqlite-delivery.sh'),original=fs.readFileSync(driver,'utf8');
    const malformed=[['empty',''],['arbitrary','nope\n'],['duplicate','ok\nok\n'],['NUL','ok\0\n'],['missing LF','ok'],['extra LF','ok\n\n']];
    for(const command of ['renew','finish','relinquish']) {
      f.bridge.state.batch.phase=command==='finish'?'completed':'prepared';f.bridge.save();
      const saved=fs.readFileSync(f.bridge.file,'utf8');
      const claims=f.sql('SELECT * FROM delivery_claims;');
      for(const [label,output] of malformed) {
        const producer='process.stdout.write(Buffer.from('+JSON.stringify(Buffer.from(output).toString('base64'))+',"base64"))';
        fs.writeFileSync(driver,original+'\n_sqlite_bridge_claim_change(){ node -e '+shellQuote(producer)+'; }\n');
        const r=await f.rawDelivery(command,f.bridge.claimRequest());
        assert.equal(r.status,13,command+' '+label+': '+r.stderr);assert.equal(r.stdout,'',command+' '+label);
        assert.match(r.stderr,/malformed protected control output/);
        assert.equal(fs.readFileSync(f.bridge.file,'utf8'),saved);
        assert.equal(f.sql('SELECT * FROM delivery_claims;'),claims);
        assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'0');
        assert.equal(f.sql('SELECT count(*) FROM delivery_ack_receipts;'),'0');
      }
    }
    fs.writeFileSync(driver,original);
    assert.equal(await f.bridge.delivery('relinquish',f.bridge.claimRequest()),'ok\n');
    assert.equal(f.sql('SELECT count(*) FROM delivery_claims;'),'0');
    assert.equal(f.sql('SELECT count(*) FROM messages WHERE read_at IS NULL;'),'1');
  }finally{f.close();}
});

test('a non-SQLite generic claims driver cannot enter protected mode or invoke SQLite primitives',async()=>{
  const f=await fixture();try {
    await f.bridge.acquire();f.send('must remain unread');
    const marker=path.join(f.dir,'private-primitive-called');
    const driver=path.join(f.install,'scripts/drivers/storage/sqlite.sh');
    fs.appendFileSync(driver,'\nagmsg_storage_driver(){ printf "synthetic\\n"; }\n'+
      '_sqlite_bridge_ready(){ touch '+shellQuote(marker)+'; return 99; }\n'+
      '_sqlite_bridge_claim_unread(){ touch '+shellQuote(marker)+'; return 99; }\n');
    const saved=fs.readFileSync(f.bridge.file,'utf8');
    for(const command of ['admit','receive']) {
      const r=await f.rawDelivery(command);
      assert.equal(r.status,13,r.stderr);assert.equal(r.stdout,'');
      assert.match(r.stderr,/protected claims require the SQLite driver/);
      assert.equal(fs.existsSync(marker),false);
      assert.equal(fs.readFileSync(f.bridge.file,'utf8'),saved);
      assert.equal(f.sql('SELECT count(*) FROM delivery_claims;'),'0');
      assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'0');
    }
  }finally{f.close();}
});

test('a committed protected ACK with corrupted reply retains its batch and retries the same receipt',async()=>{
  const f=await fixture();try {
    await f.bridge.acquire();f.send('accepted before the control reply is corrupted');
    const rows=(await f.bridge.delivery('receive')).trim().split('\n').map(JSON.parse);f.saveRows(rows);
    f.bridge.state.batch.phase='completed';f.bridge.save();
    const saved=fs.readFileSync(f.bridge.file,'utf8'),request=f.bridge.claimRequest();
    const driver=path.join(f.install,'scripts/drivers/storage/sqlite-delivery.sh'),original=fs.readFileSync(driver,'utf8');
    fs.appendFileSync(driver,'\neval "$(declare -f _sqlite_bridge_claim_change | sed \'1s/_sqlite_bridge_claim_change/_fixture_real_control/\')"\n'+
      '_sqlite_bridge_claim_change(){ _fixture_real_control "$@" >/dev/null || return $?; printf "nope\\n"; }\n');
    await assert.rejects(f.bridge.ack(),/malformed protected control output/);
    assert.equal(fs.readFileSync(f.bridge.file,'utf8'),saved);assert.deepEqual(f.bridge.claimRequest(),request);
    assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'1');
    assert.equal(f.sql('SELECT count(*) FROM delivery_ack_receipts;'),'1');
    assert.equal(f.sql('SELECT count(*) FROM delivery_claims;'),'0');
    fs.writeFileSync(driver,original);
    await f.bridge.ack();
    assert.equal(f.bridge.state.batch,null);assert.equal(JSON.parse(fs.readFileSync(f.bridge.file,'utf8')).batch,null);
    assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'1');
    assert.equal(f.sql('SELECT count(*) FROM delivery_ack_receipts;'),'1');
    assert.equal(f.sql('SELECT count(*) FROM messages WHERE read_at IS NULL;'),'0');
  }finally{f.close();}
});

test('malformed protected receive output stays private after the real lease commits',async()=>{
  for(const mode of ['raw-nul','duplicate-key','producer-error','wire-limit','wrong-recipient','different-fence']) {
    const f=await fixture();try {
      await f.bridge.acquire();f.send('must not escape');
      const driver=path.join(f.install,'scripts/drivers/storage/sqlite-delivery.sh');
      const corrupt=mode==='raw-nul'?"process.stdout.write(s+'\\0')":
        mode==='duplicate-key'?"process.stdout.write(s.replace('{','{\\\"type\\\":\\\"other\\\",'))":
        mode==='producer-error'?"process.stdout.write(s);process.exitCode=13":
        mode==='wire-limit'?"process.stdout.write(' '.repeat(1048576)+s)":
        mode==='wrong-recipient'?"const r=JSON.parse(s);r.to='other';console.log(JSON.stringify(r))":
        "const r=JSON.parse(s);console.log(JSON.stringify(r));r.id='other-id';r.claim_token='a'.repeat(64);console.log(JSON.stringify(r))";
      fs.appendFileSync(driver,'\neval "$(declare -f _sqlite_bridge_claim_unread | sed \'1s/_sqlite_bridge_claim_unread/_fixture_original_receive/\')"\n'+
        '_sqlite_bridge_claim_unread(){ _fixture_original_receive "$@" | node -e '+shellQuote("let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{"+corrupt+'});')+'; }\n');
      const before=fs.readFileSync(f.bridge.file,'utf8'),r=await f.rawDelivery('receive');
      assert.equal(r.status,13,mode+': '+r.stderr);assert.equal(r.stdout,'',mode);
      assert.equal(fs.readFileSync(f.bridge.file,'utf8'),before);
      assert.equal(f.sql('SELECT count(*) FROM delivery_claims;'),'1');
      assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'0');
      assert.equal(f.sql('SELECT count(*) FROM messages WHERE read_at IS NULL;'),'1');
    }finally{f.close();}
  }
});

test('malformed protected recovery partition or message leaves saved batch and unread claim intact',async()=>{
  for(const mode of ['partition','changed-message','leaked-credential','wire-limit']) {
    const f=await fixture();try {
      await f.bridge.acquire();f.send('saved message');const rows=(await f.bridge.delivery('receive')).trim().split('\n').map(JSON.parse);f.saveRows(rows);
      f.bridge.state.batch.phase='uncertain';
      f.bridge.state.recovery={batch_id:'batch',ids:rows.map(m=>m.id),pid:2147483647,start:'dead'};f.bridge.save();
      const driver=path.join(f.install,'scripts/drivers/storage/sqlite-delivery.sh');
      const corrupt=mode==='partition'?'r.already_read_ids=r.claim_ids':
        mode==='changed-message'?'r.messages[0].body="changed"':
        mode==='leaked-credential'?'r.messages[0].claim_token=r.claim_token':"process.stdout.write(' '.repeat(4194304))";
      fs.appendFileSync(driver,'\neval "$(declare -f _sqlite_bridge_claim_recover | sed \'1s/_sqlite_bridge_claim_recover/_fixture_original_recover/\')"\n'+
        '_sqlite_bridge_claim_recover(){ _fixture_original_recover "$@" | node -e '+shellQuote("let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{const r=JSON.parse(s);"+corrupt+';console.log(JSON.stringify(r))});')+'; }\n');
      const before=fs.readFileSync(f.bridge.file,'utf8');
      const result=await f.rawDelivery('recover-batch',{batch_id:'batch',ids:rows.map(m=>m.id)});
      assert.equal(result.status,13,mode+': '+result.stderr);assert.equal(result.stdout,'');
      assert.equal(fs.readFileSync(f.bridge.file,'utf8'),before);
      assert.equal(f.sql('SELECT count(*) FROM delivery_claims;'),'1');
      assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'0');
    }finally{f.close();}
  }
});

test('actual TUI partial PTY write retains the protected database claim and unread body',async()=>{
  const f=await fixture();try {
    f.send('partial PTY body');
    const module=path.join(f.install,'scripts/drivers/types/antigravity/antigravity-tui-supervisor.py');
    const script=`
import importlib.util,json,os,pty,sqlite3,tty
from types import SimpleNamespace
spec=importlib.util.spec_from_file_location('supervisor',${JSON.stringify(module)})
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
s=m.Supervisor(SimpleNamespace(project=${JSON.stringify(f.project)},team='protected',name='bob',poll=0))
s.acquire()
checks=iter([True,False]);s.injection_ready=lambda: next(checks)
s.maybe_poll()
assert s.delivery_mode=='claims' and s.state['batch']['phase']=='prepared'
token=s.state['batch']['claim_token']
master,slave=pty.openpty();tty.setraw(slave);s.master=master
write=os.write
def partial(fd,data):
    if fd!=master: return write(fd,data)
    saved=json.loads(s.state_file.read_text())
    assert saved['batch']['phase']=='sent' and saved['supervisorPhase']=='INJECTED'
    assert write(fd,data[:1])==1
    return 1
m.os.write=partial
try:
    try: s.inject();raise AssertionError('partial write was accepted')
    except RuntimeError as e: assert 'partial PTY delivery write' in str(e)
finally:
    m.os.write=write
    assert os.read(slave,1)==b'\\x1b'
    os.close(master);os.close(slave)
saved=json.loads(s.state_file.read_text())
assert saved['batch']['phase']=='uncertain' and saved['supervisorPhase']=='NEEDS_ATTENTION'
db=sqlite3.connect(${JSON.stringify(path.join(f.install,'db/messages.db'))})
assert db.execute('SELECT token FROM delivery_claims').fetchall()==[(token,)]
assert db.execute('SELECT count(*) FROM messages WHERE read_at IS NULL').fetchone()[0]==1
assert db.execute("SELECT count(*) FROM events WHERE type='message_read'").fetchone()[0]==0
assert db.execute('SELECT count(*) FROM delivery_ack_receipts').fetchone()[0]==0
assert s.reservation.exists()
`;
    const result=spawnSync('python3',['-c',script],{encoding:'utf8',timeout:30000});
    assert.equal(result.status,0,result.stderr||result.stdout);
  }finally{f.close();}
});

test('stream recovery CLI confirms opaque comma/newline IDs without ambiguous CSV',async()=>{
  const f=await fixture();try {
    await f.bridge.acquire();f.send('opaque saved body');f.send('second saved body');
    const opaque="opaque,comma\n\t'\\tail";
    f.sql("UPDATE events SET id='"+opaque.replaceAll("'","''")+"' WHERE type='message_sent' AND body='opaque saved body';");
    const rows=(await f.bridge.delivery('receive')).trim().split('\n').map(JSON.parse);f.saveRows(rows);
    const ids=rows.map(m=>m.id),deadOwner='recovery.2147483647';
    f.bridge.state.batch.phase='uncertain';f.bridge.state.batch.claim_owner=deadOwner;f.bridge.state.owner=deadOwner;f.bridge.save();
    f.sql("UPDATE delivery_claims SET owner='"+deadOwner+"',expires_at=0;");fs.writeFileSync(f.bridge.actas,deadOwner+'\n');
    const reservation=JSON.parse(fs.readFileSync(f.bridge.reservation,'utf8'));
    Object.assign(reservation,{owner:deadOwner,pid:2147483647,start:'dead'});fs.writeFileSync(f.bridge.reservation,JSON.stringify(reservation));
    const cli=path.join(f.install,'scripts/drivers/types/antigravity/antigravity-bridge.mjs');
    const args=[cli,'--project',f.project,'--team','protected','--name','bob','--action','ack','--batch','batch'];
    const before=fs.readFileSync(f.bridge.file,'utf8');
    const refused=spawnSync(process.execPath,[...args,'--confirm-ids',ids.join(',')],{encoding:'utf8',timeout:30000});
    assert.equal(refused.status,1);assert.match(refused.stderr,/use repeated --confirm-id/);
    assert.equal(fs.readFileSync(f.bridge.file,'utf8'),before);
    assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'0');
    const accepted=spawnSync(process.execPath,[...args,...ids.flatMap(id=>['--confirm-id',id])],{encoding:'utf8',timeout:30000});
    assert.equal(accepted.status,0,accepted.stderr||accepted.stdout);
    assert.equal(f.sql("SELECT count(*) FROM events WHERE type='message_read';"),'2');
    assert.equal(f.sql('SELECT count(*) FROM delivery_claims;'),'0');
    assert.equal(f.sql('SELECT count(*) FROM messages WHERE read_at IS NULL;'),'0');
  }finally{f.close();}
});
