<!-- Devin overlay. -->
<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. Devin has no agmsg automatic delivery hook. Keep delivery `off` and check `__CMD_PREFIX____SKILL_NAME__` manually.
<!-- /agmsg:slot delivery -->
<!-- agmsg:slot execute-extra -->
Devin is spawnable: `spawn` launches `devin [--model <id>] -- "<actas prompt>"`, which starts an interactive session seeded with the initial `actas` prompt. Delivery stays `off`, so a spawned Devin seat sees new messages only when it checks its inbox itself.
<!-- /agmsg:slot execute-extra -->
<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.
Only `off` is supported for Devin; reject `monitor`, `turn`, and `both`.
<!-- /agmsg:slot mode -->
