<!-- Hermes overlay. -->
<!-- agmsg:slot delivery -->
  5. Hermes has no automatic delivery mode. Keep delivery `off` and check `__CMD_PREFIX____SKILL_NAME__` manually.
<!-- /agmsg:slot delivery -->
<!-- agmsg:slot execute-extra -->
hermes is not spawnable: its known prompt-taking modes exit after one turn, so `spawn` is refused rather than pretending to start an interactive seat.
<!-- /agmsg:slot execute-extra -->
<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.
Only `off` is supported for Hermes; reject `monitor`, `turn`, and `both`.
<!-- /agmsg:slot mode -->
