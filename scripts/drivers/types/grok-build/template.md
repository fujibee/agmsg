<!-- Grok Build overlay. -->
<!-- agmsg:slot delivery -->
  5. **REQUIRED — Do NOT skip this step.** Choose `turn`, `monitor`, or `off` delivery (empty input means `turn`), then run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`.
<!-- /agmsg:slot delivery -->
<!-- agmsg:slot execute-extra -->
Grok Build has no SessionStart monitor handshake; monitor delivery attaches when the agent loads its rule. Turn delivery remains the fallback.
<!-- /agmsg:slot execute-extra -->
<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.
For `mode turn|monitor|off`, run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`; reject `both`.
<!-- /agmsg:slot mode -->
