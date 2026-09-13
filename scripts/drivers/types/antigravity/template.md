<!-- This file is an overlay for the shared SKILL.md. -->

<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
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

     `monitor` requires explicitly starting either the dedicated headless bridge or `antigravity-tui-monitor.sh`. While the TUI monitor is active, do not call bare `__CMD_PREFIX____SKILL_NAME__`, `inbox.sh`, or `check-inbox.sh`; use the pending state reported by the supervisor instead.
<!-- /agmsg:slot delivery -->

<!-- agmsg:slot mode -->
If argument is "mode" (no further args):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status __AGENT_TYPE__ "$(pwd)"`
2. Show the output to the user.

If argument starts with "mode" followed by a mode name:
1. Antigravity supports `monitor`, `turn`, and `off`; `both` is not supported. `monitor` requires explicitly starting `antigravity-monitor.sh` or `antigravity-tui-monitor.sh`.
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`

If argument is "hook on", run `delivery.sh set turn __AGENT_TYPE__ "$(pwd)"`.
If argument is "hook off", run `delivery.sh set off __AGENT_TYPE__ "$(pwd)"`.
<!-- /agmsg:slot mode -->

<!-- agmsg:slot execute-extra -->
First run `bash ~/.agents/skills/__SKILL_NAME__/scripts/drivers/types/antigravity/antigravity-tui-monitor.sh status --project <project> --team <team> --name <role>`. If the output reports that the `tui-pty` runtime has not started, apply the default no-argument behavior above as written. Any other line containing `tui-pty` means the Antigravity TUI monitor is active: **do not apply that default behavior**, and do not call bare `__CMD_PREFIX____SKILL_NAME__`, `inbox.sh`, or `check-inbox.sh`. Use this status command (`tui-monitor status`) for any required state checks; it neither redisplays message bodies nor marks them read. Acknowledge receipt to the TUI monitor with exactly one line, `AGMSG_RECEIVED:<batch-id>`, using the batch ID from the envelope header.

If argument is "resume":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/antigravity-resume.sh "$(pwd)"`
2. Show the output. This resumes only when exactly one paused Antigravity TUI is registered for the current project; zero or multiple paused TUI instances fail closed.

If `agy-tui` stopped after detecting a read attempt through the ordinary inbox path, do not run bare `__CMD_PREFIX____SKILL_NAME__`, `inbox.sh`, or `check-inbox.sh` again. After confirming that no batch is pending, run `~/.agents/bin/agy-tui reset-guard --project "$(pwd)" --team <team> --name <role>` to clear only the read-denied guard; it does not read or acknowledge messages.
<!-- /agmsg:slot execute-extra -->

<!-- agmsg:slot actas -->
If argument starts with "actas" followed by an agent name:
1. Parse the new role name and inspect the team roster when suggestions are needed.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" __AGENT_TYPE__`.
3. If needed, join with `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> __AGENT_TYPE__ "$(pwd)"`.
4. Set the session's active FROM to `<name>` for subsequent sends.
5. Tell the user: "Now acting as `<name>`. Sends will use `<name>` as the from agent. The headless monitor delivers to a separate worker; the TUI monitor delivers to the same TUI in which it was explicitly started."
<!-- /agmsg:slot actas -->
