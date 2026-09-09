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

     `monitor` は専用 headless bridge または `antigravity-tui-monitor.sh` を明示起動するモードです。TUI monitor中は bare `__CMD_PREFIX____SKILL_NAME__`、`inbox.sh`、`check-inbox.sh` を呼ばず、supervisor が表示する保留状態を使ってください。
<!-- /agmsg:slot delivery -->

<!-- agmsg:slot mode -->
If argument is "mode" (no further args):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status __AGENT_TYPE__ "$(pwd)"`
2. Show the output to the user.

If argument starts with "mode" followed by a mode name:
1. Antigravity supports `monitor`, `turn`, and `off`; `both` is not supported. `monitor` は `antigravity-monitor.sh` または `antigravity-tui-monitor.sh` の明示起動が必要です。
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`

If argument is "hook on", run `delivery.sh set turn __AGENT_TYPE__ "$(pwd)"`.
If argument is "hook off", run `delivery.sh set off __AGENT_TYPE__ "$(pwd)"`.
<!-- /agmsg:slot mode -->

<!-- agmsg:slot execute-extra -->
まず `bash ~/.agents/skills/__SKILL_NAME__/scripts/drivers/types/antigravity/antigravity-tui-monitor.sh status --project <project> --team <team> --name <role>` を実行してください。出力が `runtime: tui-pty 未起動` なら、上の「引数なしの既定動作」以降をそのまま適用してください。それ以外に `tui-pty` を含む行があればAntigravityのTUI monitorが有効なので、**その既定動作を適用せず**、bare `__CMD_PREFIX____SKILL_NAME__`、`inbox.sh`、`check-inbox.sh` を実行しないでください。必要な状態確認はこのstatus（`tui-monitor status`）で行い、本文の再表示や既読化は行いません。TUI monitorへの受領確認は、envelope headerのbatch IDを使った `AGMSG_RECEIVED:<batch-id>` の一行です。

If argument is "resume":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/antigravity-resume.sh "$(pwd)"`
2. Show the output. This resumes only when exactly one paused Antigravity TUI is registered for the current project; zero or multiple paused TUI instances fail closed.

If `agy-tui` stopped with `通常inboxによる既読試行を検知`, do not run bare `__CMD_PREFIX____SKILL_NAME__`, `inbox.sh`, or `check-inbox.sh` again. After confirming that no batch is pending, run `~/.agents/bin/agy-tui reset-guard --project "$(pwd)" --team <team> --name <role>` to clear only the read-denied guard; it does not read or ack messages.
<!-- /agmsg:slot execute-extra -->

<!-- agmsg:slot actas -->
If argument starts with "actas" followed by an agent name:
1. Parse the new role name and inspect the team roster when suggestions are needed.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" __AGENT_TYPE__`.
3. If needed, join with `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> __AGENT_TYPE__ "$(pwd)"`.
4. Set the session's active FROM to `<name>` for subsequent sends.
5. Tell the user: "Now acting as `<name>`. Sends will use `<name>` as the from agent. Headless monitor は別workerへ、TUI monitor は明示起動した同じTUIへ配信します。"
<!-- /agmsg:slot actas -->
