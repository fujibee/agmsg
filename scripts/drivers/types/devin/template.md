<!-- Devin overlay. -->
<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. Devin has no agmsg automatic delivery hook. Keep delivery `off` and check `__CMD_PREFIX____SKILL_NAME__` manually.
<!-- /agmsg:slot delivery -->
<!-- agmsg:slot execute-extra -->
Devin is not spawnable: an interactive boot mode that can be pre-seeded with agmsg's initial `actas` prompt has not yet been verified, so `spawn` is refused rather than pretending to start a seat. This is unrelated to Hermes's own spawn limitation (#279) and may be revisited separately.
<!-- /agmsg:slot execute-extra -->
<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.
Only `off` is supported for Devin; reject `monitor`, `turn`, and `both`.
<!-- /agmsg:slot mode -->
