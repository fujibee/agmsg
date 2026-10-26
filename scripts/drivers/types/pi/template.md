<!-- Pi overlay for the shared SKILL.md. -->

<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. **REQUIRED — Do NOT skip this step.** Ask the user to pick a delivery mode using exactly this prompt:

     ```
     Choose delivery mode for incoming messages:

       1) turn    — Check inbox after each assistant turn
                     A project Pi extension (.pi/extensions/agmsg.ts) polls
                     inbox.sh when the agent settles. Zero extra setup.

       2) monitor — In-process polling (~15s)
                     The same extension polls unread messages on a timer and
                     injects them into this session (Pi's session store has a
                     writer lease, so an external watcher cannot inject).

       3) off     — No automatic delivery
                     Manual __CMD_PREFIX____SKILL_NAME__ only.

     [1]:
     ```

     Empty input means `1` (turn). Map `1`→`turn`, `2`→`monitor`, `3`→`off`, then run:
     `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`
<!-- /agmsg:slot delivery -->

<!-- agmsg:slot mode -->
If argument is "mode" (no further args):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status __AGENT_TYPE__ "$(pwd)"`
2. Show the output to the user.

If argument starts with "mode" followed by a mode name:
1. Pi supports `turn`, `monitor`, and `off`; `both` is not supported.
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`

If argument is "hook on", run `delivery.sh set turn __AGENT_TYPE__ "$(pwd)"`.
If argument is "hook off", run `delivery.sh set off __AGENT_TYPE__ "$(pwd)"`.
<!-- /agmsg:slot mode -->

<!-- agmsg:slot actas -->
If argument starts with "actas" followed by an agent name:
1. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" __AGENT_TYPE__`. If `<name>` is not listed, join with `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> __AGENT_TYPE__ "$(pwd)"`.
2. Use the role as the active FROM. Pi's extension injects into the current session regardless of role; incoming messages addressed to `<name>` appear here.
<!-- /agmsg:slot actas -->
