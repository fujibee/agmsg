<!-- OpenCode overlay. -->
<!-- agmsg:slot delivery -->
  5. **REQUIRED — Do NOT skip this step.** Choose `monitor`, `turn`, or `off` delivery (empty input means `monitor`), then run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`.
<!-- /agmsg:slot delivery -->
<!-- agmsg:slot execute-extra -->
OpenCode monitor delivery uses its rule-based watcher. If the sentinel monitor tools are unavailable, fall back to a turn-based inbox check.
<!-- /agmsg:slot execute-extra -->
<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.
For `mode monitor|turn|off`, run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`; reject `both`.
<!-- /agmsg:slot mode -->
