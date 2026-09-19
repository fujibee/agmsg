<!-- Cursor CLI overlay. -->
<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. **REQUIRED — Do NOT skip this step.** Choose `turn` or `off` delivery (empty input means `turn`), then run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`. Cursor CLI has no monitor equivalent.
<!-- /agmsg:slot delivery -->
<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.
For `mode turn|off`, run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`; reject `monitor` and `both`.
<!-- /agmsg:slot mode -->
