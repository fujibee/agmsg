<!-- This file is an overlay for the shared SKILL.md. -->

<!-- agmsg:slot delivery -->
  5. **REQUIRED — Do NOT skip this step.** Ask the user to pick a delivery mode:

     ```
     Choose delivery mode for incoming messages:

       1) turn — Check inbox at the end of each assistant turn
                  Stop hook pulls after each response.

       2) off  — No automatic delivery
                  Manual __CMD_PREFIX____SKILL_NAME__ only.

     [1]:
     ```

     Empty input means `1` (turn). Map `1`→`turn` and `2`→`off`, then run:
     `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`

     Antigravity has no Monitor tool, so `monitor` and `both` are not offered.
<!-- /agmsg:slot delivery -->

<!-- agmsg:slot mode -->
If argument is "mode" (no further args):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status __AGENT_TYPE__ "$(pwd)"`
2. Show the output to the user.

If argument starts with "mode" followed by a mode name:
1. Antigravity supports only `turn` and `off`; reject `monitor` and `both`.
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`

If argument is "hook on", run `delivery.sh set turn __AGENT_TYPE__ "$(pwd)"`.
If argument is "hook off", run `delivery.sh set off __AGENT_TYPE__ "$(pwd)"`.
<!-- /agmsg:slot mode -->
