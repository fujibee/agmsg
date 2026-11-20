<!-- Grok Build overlay. -->
<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. **REQUIRED — Do NOT skip this step.** Choose `turn`, `monitor`, or `off` delivery (empty input means `turn`), then run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`.
<!-- /agmsg:slot delivery -->
<!-- agmsg:slot execute-extra -->
Grok Build has no SessionStart monitor handshake; monitor delivery attaches when the agent loads its rule. Turn delivery remains the fallback.

Check `delivery.sh status __AGENT_TYPE__ "$(pwd)"`'s first line before starting or re-arming the `monitor` tool. `mode: agmsgd` means agmsgd's own grok-queue channel already delivers to this seat directly — do not call the `monitor` tool at all, including after a "monitors were killed" resume reminder or once the prior watch hits its runtime cap; a watch started for a seat in this mode reports it is stopping and exits right away on its own. Only `mode: turn`/`mode: monitor`/`mode: off` calls for the behavior above.
<!-- /agmsg:slot execute-extra -->
<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.
For `mode turn|monitor|off`, run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`; reject `both`.
<!-- /agmsg:slot mode -->
