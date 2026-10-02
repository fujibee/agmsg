<!-- Hermes overlay. -->
<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. Hermes has no automatic delivery mode. Keep delivery `off` and check `__CMD_PREFIX____SKILL_NAME__` manually.
<!-- /agmsg:slot delivery -->
<!-- agmsg:slot execute-extra -->
hermes is not spawnable: its known prompt-taking modes exit after one turn, so `spawn` is refused rather than pretending to start an interactive seat.
<!-- /agmsg:slot execute-extra -->
<!-- agmsg:slot actas -->
If argument starts with "actas" followed by an agent name:
1. Parse the new role name and inspect the team roster when suggestions are needed.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" __AGENT_TYPE__`.
3. If needed, join with `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> __AGENT_TYPE__ "$(pwd)"`.
4. Set the session's active FROM to `<name>` for subsequent sends.
5. Tell the user which role is active.
After the identity claim is complete and, in monitor mode, the monitor tool has confirmed that the watcher is running and streaming, signal one-shot spawn readiness exactly once. If this session was launched by `spawn` — the environment variables `AGMSG_SPAWN_TEAM` and `AGMSG_SPAWN_NONCE` are set — use those exactly, quoted, rather than the team resolved above: they identify which team and which specific launch spawn is waiting on (the boot prompt only names the agent, and the same name can be registered under more than one team; the nonce stops a stale mark from an earlier abandoned or timed-out launch from satisfying this launch's wait):
   `~/.agents/skills/__SKILL_NAME__/scripts/ready.sh mark "$AGMSG_SPAWN_TEAM" '<name>' "$AGMSG_SPAWN_NONCE"`
Otherwise (a manual `/__SKILL_NAME__ actas`, not from spawn) use the team resolved above, quoted, with no nonce:
   `~/.agents/skills/__SKILL_NAME__/scripts/ready.sh mark '<team>' '<name>'`
This mark says only that actas bootstrap completed; it is not a watcher-liveness signal.
<!-- /agmsg:slot actas -->
<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.
Only `off` is supported for Hermes; reject `monitor`, `turn`, and `both`.
<!-- /agmsg:slot mode -->
