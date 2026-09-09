#!/usr/bin/env node
// bridge検査用。実CLIの認証・storeには接続しない。
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import { createInterface } from 'node:readline';
const mode = process.env.FAKE_AGY_MODE || 'success';
const args = process.argv.slice(2);
const conversation = args.includes('--conversation') ? args[args.indexOf('--conversation') + 1] : 'fixture-conversation';
let turn = 0;
const emit = async (event) => {
  const line = JSON.stringify(event) + '\n';
  if (mode === 'split') {
    process.stdout.write(line.slice(0, 7));
    await new Promise(resolve => setTimeout(resolve, 5));
    process.stdout.write(line.slice(7));
  } else process.stdout.write(line);
};
for await (const line of createInterface({input: process.stdin})) {
  const input = JSON.parse(line);
  if (input.event !== 'user') process.exit(4);
  turn++;
  if (turn === 1) await emit({event:'init', conversation_id:conversation});
  if (turn > 1 && (mode === 'attack' || mode === 'append-failure')) {
    const install=process.env.FIXTURE_INSTALL;
    spawnSync('bash',[install+'/scripts/send.sh','fixture','sender','worker','late B'],{env:process.env});
    if(mode==='append-failure') {
      // 空記録は読めるが追記不可の反例。親のstream検知を別に検証する。
      for(const name of fs.readdirSync(install+'/run'))if(name.endsWith('.violations'))fs.chmodSync(install+'/run/'+name,0o400);
    }
    spawnSync('bash',[install+'/scripts/inbox.sh','fixture','worker'],{env:process.env});
    spawnSync('bash',[install+'/scripts/check-inbox.sh','antigravity',process.cwd()],{env:process.env});
    await emit({event:'step_update',step_update:{conversation_id:conversation,step_type:'tool',tool_name:'run_command',tool_info:{parameters:{CommandLine:'bash '+install+'/scripts/inbox.sh fixture worker'}}}});
  }
  if (mode === 'crash' && turn > 1) process.exit(7);
  if (mode === 'broken' && turn > 1) { process.stdout.write('{broken\n'); continue; }
  await emit({event:'step_update', step_update:{conversation_id:conversation, step_type:'agent_response', text_delta:`turn ${turn}`}});
  await emit({event:'result', result:{conversation_id:conversation, status:'SUCCESS', response:`turn ${turn}`}});
}
