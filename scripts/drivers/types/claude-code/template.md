---
description: Agent messaging — check inbox, send messages, view history
---

Agent messaging command. **IMPORTANT: Always use the provided scripts. NEVER directly read or edit config files, DB, or team data. There is NO register.sh — use join.sh to join a team.**

**Shell requirement:** All agmsg scripts are Bash scripts. Always execute them via `bash`, never via PowerShell or cmd directly. If your default shell is not Bash (e.g. PowerShell on Windows), wrap every command with `bash -lc '...'`. Example: `bash -lc '~/.agents/skills/__SKILL_NAME__/scripts/send.sh myteam alice bob "hello"'`. Do NOT construct DB paths manually — the scripts handle path resolution internally. If you need to redirect storage, use `AGMSG_STORAGE_PATH` (the supported override).

## Identity

If you already know your AGENT and TEAMS from a previous `/__SKILL_NAME__` call in this session, skip to **Execute** below.

Otherwise, run: `~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" claude-code`

Four possible outputs:

**A) Single identity:**
`agent=<name> teams=<t1,t2,...> type=claude-code project=<path>`
→ Remember AGENT and TEAMS, then go to **Execute**.

**B) Multiple identities:**
`multiple=true agents=<n1,n2,...> teams=<t1,t2,...> type=claude-code project=<path>`
→ Ask the user which agent name to use for this session, then go to **Execute**.

**C) Not in a team:**
`not_joined=true available_teams=<t1,t2,...>` (or `available_teams=none`)
→ Show the user the available teams from the output, then:

  Before first-time setup, inspect the user's request. If they ask to join, import, or bring in a team that already exists on a server, do not call `join.sh`. Go directly to `remote pull` under Execute. First run `~/.agents/skills/__SKILL_NAME__/scripts/team-list.sh --json --scope all`; if a same-named local team has `binding_state` `none` or `disconnected`, stop and ask the user how to proceed. After pull succeeds, return to Identity setup so the user can register a new local agent in the pulled team.

  > **First-time setup required.**
  > Joining a team so this agent can send and receive messages.
  > - **Team name**: a group of agents that can message each other (available: <list from output>)
  > - **Agent name**: this agent's identity within the team

  1. Ask: "Enter a team name (joins existing or creates new)"
  2. If the team name given already appears in `available_teams`, run `~/.agents/skills/__SKILL_NAME__/scripts/team.sh <team>` to see the current roster (name, type, project) and note the names already in use. Look for a naming convention already in play (e.g. a shared base name with role and number suffixes (`<base>-<role><n>`), or names derived from the team name) and, when one exists, propose 2-3 unused names that extend it; otherwise propose 2-3 short, distinctive identity names (not a bare tool-type label like `codex`/`cc`). Either way, names must not collide with the roster. Then ask: "Enter a name for this agent (suggestions: <name1>, <name2>, <name3> — or type your own)". For a brand-new team, skip the roster check and just ask: "Enter a name for this agent".
  3. **You MUST use join.sh** — run: `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <agent_name> claude-code "$(pwd)"`
  4. Show the result and explain:

  > **Joined!** You can now use `/__SKILL_NAME__` to check and send messages.
  > - `/__SKILL_NAME__` — check inbox
  > - `/__SKILL_NAME__ send <agent> <message>` — send a message
  > - `/__SKILL_NAME__ team` — list team members
  > - `/__SKILL_NAME__ history` — message history
  > - `/__SKILL_NAME__ mode <monitor|turn|both|off>` — switch delivery mode
  > - `/__SKILL_NAME__ actas <name>` — switch to another role in this project (creates if needed)
  > - `/__SKILL_NAME__ drop <name>` — remove a role from this project
  > - `/__SKILL_NAME__ spawn <type> <name>` — launch a new agent in a tmux pane / terminal and have it actas <name>
  > - `/__SKILL_NAME__ despawn <name>` — tear down a member you spawned (graceful, or `--force`)

  5. **REQUIRED — Do NOT skip this step.** Ask the user to pick a delivery mode using exactly this prompt:

     ```
     Choose delivery mode for incoming messages:

       1) monitor — Real-time push (~5s latency)
                     SessionStart hook + Monitor tool streams events.
                     Recommended.

       2) turn    — Check inbox at the end of each assistant turn
                     Stop hook pulls after each response.

       3) both    — monitor primary, turn as fallback
                     Redundant safety net.

       4) off     — No automatic delivery
                     Manual /__SKILL_NAME__ only.

     [1]:
     ```

     - **Wait for the user's answer before proceeding.** Empty input means `1` (monitor).
     - Map the chosen number to a mode and run:
       `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> claude-code "$(pwd)"`
     - Read the `AGMSG-DIRECTIVE` block printed by `delivery.sh` and follow it (invoke Monitor or TaskStop as instructed).

  6. Then check inbox for the newly joined team.

**D) Suggestions for reuse:**
`suggest=true agents=<n1,n2,...> teams=<t1,t2,...> type=claude-code project=<path> available_teams=<t1,t2,...>`
→ No exact registration exists for this project, but there are same-type agent names registered elsewhere.

  1. Show the suggested agent names to the user.
  2. Ask whether to reuse one of those names or choose a new one.
  3. Ask for the team name to join (existing or new).
  4. Run: `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <agent_name> claude-code "$(pwd)"`
  5. Then continue with the normal post-join flow above.

## Execute

**Only use scripts in `~/.agents/skills/__SKILL_NAME__/scripts/` — do not read or modify files under `teams/` or `db/` directly.** Treat the storage layout as internal: never construct a database path or invoke `sqlite3` directly. The scripts resolve the active store, including `AGMSG_STORAGE_PATH` overrides.

**Ensure monitor is running first.** Before processing any subcommand below, check whether this session already has an `agmsg inbox stream` Monitor task in its TaskList. If not, and the project's delivery mode is `monitor` or `both` (check via `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status claude-code "$(pwd)"`), invoke the Monitor tool now:

- command: `~/.agents/skills/__SKILL_NAME__/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" claude-code`
- description: `agmsg inbox stream`
- persistent: true

Then continue with the user's subcommand. This catches the case where the user invokes `/__SKILL_NAME__` as the first prompt before the SessionStart-hook directive has been acted on.

**Permission prompts.** Every command here runs through the Bash tool, so each call is gated by the permission system until the script directory is allowlisted. Without this the user is asked to confirm essentially every `__SKILL_NAME__` call. Add to `~/.claude/settings.json` (or project-level `.claude/settings.local.json`):

```json
{
  "permissions": {
    "allow": [
      "Bash(~/.agents/skills/__SKILL_NAME__/scripts/*)",
      "Bash(/Users/<you>/.agents/skills/__SKILL_NAME__/scripts/*)",
      "Bash(bash ~/.agents/skills/__SKILL_NAME__/scripts/*)",
      "Bash(bash /Users/<you>/.agents/skills/__SKILL_NAME__/scripts/*)"
    ]
  }
}
```

Four entries because a rule matches the command string as written, and these scripts are invoked both as `~/...` and as an absolute path, with or without an explicit `bash` prefix. Replace `/Users/<you>` with the user's home directory.

**Every subcommand needs its own match.** Per [Claude Code's permission docs](https://code.claude.com/docs/en/permissions), a rule must match each subcommand independently, and the recognized separators are `&&`, `||`, `;`, `|`, `|&`, `&`, and newlines. Chaining two `__SKILL_NAME__` scripts is fine — both match the entries above. The prompt returns when a subcommand those entries do not cover rides along: `delivery.sh status … ; printenv AGMSG_SPAWNED` prompts because of the `printenv`, not because of the `;`. Splitting it into its own call does not remove that prompt — it only keeps it from gating the `__SKILL_NAME__` call. Allowlist the command as well if it needs to be prompt-free.

**Sandbox compatibility.** When Claude Code's sandbox is enabled, `watch.sh` (monitor mode) runs inside the sandbox and needs to write pidfiles and SQLite WAL files under `~/.agents/skills/__SKILL_NAME__/`. If monitor mode fails with write/permission errors there, add an allowlist entry to `~/.claude/settings.json` (or project-level `.claude/settings.local.json`):

```json
{
  "sandbox": {
    "filesystem": {
      "allowWrite": [
        "~/.agents/skills/__SKILL_NAME__/"
      ]
    }
  }
}
```

The allowlist does not enable sandboxing by itself. Use `/sandbox` in Claude Code to choose a sandbox mode, or add `"enabled": true` alongside `"filesystem"` under `"sandbox"` to configure it in settings. The allowlist has no effect until sandboxing is enabled.

The allowlist merges across scopes and takes effect immediately — no restart needed. (The `BASH_SOURCE`-empty case under the sandbox — the Bash tool runs commands via pipe/eval, so `BASH_SOURCE[0]` is empty inside sourced functions — is handled internally: `watch.sh` resolves `SKILL_DIR` from `$0` and `storage.sh` falls back to it. No user configuration needed.)

**If no arguments provided (DEFAULT action — always do this when the command is invoked without arguments):**
1. **IMMEDIATELY** run inbox check for each TEAM: `~/.agents/skills/__SKILL_NAME__/scripts/inbox.sh $TEAM $AGENT`
2. Do NOT ask the user what to do — just run the inbox check.
3. If there are messages, read and respond appropriately. To reply:
   `~/.agents/skills/__SKILL_NAME__/scripts/send.sh $TEAM $AGENT <to_agent> "<message>"`

If argument is "history":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/history.sh $TEAM $AGENT`

If argument starts with "team list" (e.g. "team list", "team list --json", "team list --scope project"):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/team-list.sh <the rest of the args after "team list", unchanged>`
2. This is a distinct command from bare "team" below — check for "team list" FIRST so "list" is never mistaken for a team name.

If argument is "team":
1. For each TEAM, run: `~/.agents/skills/__SKILL_NAME__/scripts/team.sh $TEAM`

If argument starts with "send" (e.g. "send misaki check the server"):
1. Parse target agent and message from the arguments
2. Determine which team the target agent belongs to, then run:
   `~/.agents/skills/__SKILL_NAME__/scripts/send.sh $TEAM $AGENT <to_agent> "<message>"`

If argument starts with "actas" followed by an agent name (e.g. "actas alice"):
1. Parse the new role name. If none was given (e.g. bare "actas", or the user asks you to suggest one), run `~/.agents/skills/__SKILL_NAME__/scripts/team.sh <team>` for each TEAM to see the current roster. Look for a naming convention already in play (e.g. a shared base name with role and number suffixes (`<base>-<role><n>`), or names derived from the team name) and, when one exists, propose 2-3 unused names that extend it; otherwise propose 2-3 short, distinctive identity names (not a bare tool-type label). Either way, names must not collide with the roster. Ask the user to pick one or type their own before continuing.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" claude-code` to see whether the role is already registered for this (project, type).
3. If the name does not appear in the output, join under the existing team. Read TEAMS from the in-session whoami state (it may be a single team or comma-separated). For a single team, run `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> claude-code "$(pwd)"`. For multiple teams, ask the user which team to join the new role into, then run join.sh for that team.
4. **Pre-flight claim** the actas exclusivity lock so this role isn't already owned by another live session: `~/.agents/skills/__SKILL_NAME__/scripts/actas-claim.sh "$(pwd)" claude-code <name> "$CLAUDE_CODE_SESSION_ID"`. Read the `status=` line of the output:
    - `status=ok ...`: proceed to step 5.
    - `status=held team=<team> owner=<sid>`: another live session currently owns `<name>` in `<team>`. Tell the user: "Cannot actas as `<name>` — it is held by session `<sid>` in team `<team>`. Run `/__SKILL_NAME__ drop <name>` in that session first, then retry." Then abort — do NOT touch the running Monitor.
    - `status=not_registered`: shouldn't happen if step 3 ran; treat as an error.
5. **Switch receive too — exclusive role mode.**
   a. Run TaskList. Find any task whose description begins with "agmsg inbox stream".
   b. **If a matching task is found**: TaskStop it.
   c. **If no matching task is found** (typical when /__SKILL_NAME__ actas runs as the first command of a fresh session — SessionStart hasn't fired the Monitor directive yet, or you're invoking actas before the agent acted on it): skip TaskStop entirely. There is no Monitor to stop. Do NOT attempt TaskStop with a guessed or empty task_id — it will fail with "Invalid tool parameters" and confuse the flow.
   d. Run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status claude-code "$(pwd)"` and read its **first line**.
      - **`mode: monitor` or `mode: both`**: invoke a fresh Monitor, regardless of whether step b or c applied:
        - command: `~/.agents/skills/__SKILL_NAME__/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" claude-code <name>`
        - description: `agmsg inbox stream (acting as <name>)`
        - persistent: true
      - **`mode: turn`**: leave it stopped, silently. `has_st=1` is the one case `delivery.sh` can actually confirm was a deliberate choice — someone configured turn-based delivery for this project — so `actas` starting nothing here needs no explanation.
      - **`mode: off (no agmsg delivery hooks installed for this project)`**: leave it stopped (`actas` must not start automatic delivery a project wasn't configured for), but **do not treat this as silently deliberate**. `delivery.sh` cannot tell whether someone ran `mode off` here or this project was simply never configured — both leave the exact same settings file (#687 review round 3). **Tell the user** — e.g. "agmsg delivery hooks are not installed for this project; automatic delivery remains stopped. Run `/__SKILL_NAME__ mode <choice>` if you want to configure it." Keep it matter-of-fact, not a warning. Do not report `actas` as complete without saying this.
      - **`mode: off (unrecognized: ...)`**: leave it stopped too (same rule — do not guess a mode), but this is a stronger case than the no-hooks-installed one above: `delivery.sh` could not even find or read a settings file for this project, most often because the working directory does not match how the project was actually registered. **Tell the user explicitly** — e.g. "agmsg could not find a delivery configuration for this project at `<path from the message>` — delivery is stopped, but this may mean the project isn't registered here rather than that it was deliberately turned off. Check the path, or run `/__SKILL_NAME__ mode <choice>` to configure it explicitly." Do not report `actas` as complete without saying this — a silent stop here is indistinguishable from the other off cases and is what let this go unnoticed before (#687).
   The 4th argument to `watch.sh` restricts the subscription to messages addressed to `<name>` only — other roles' inbound messages stop reaching this session until another `actas` or session end.
6. Set the session's active FROM to `<name>` — use `<name>` in every `send.sh` call for the rest of this session.
7. Tell the user: "Now acting as `<name>`. Sends use `<name>` as from; receive restricted to `<name>` only."
8. **Only if this session was NOT launched via `spawn`** — check the environment variable `AGMSG_SPAWNED` (e.g. `printenv AGMSG_SPAWNED`): `spawn` exports `AGMSG_SPAWNED=1` and already named the session `<team>-<agent>` via `-n`, so when it is set, **skip this tip entirely**. When it is UNSET (a human typed `claude` then actas'd, so the session has no convention name), additionally suggest to the user: "Tip: rename this session to `<team>-<name>` with `/rename <team>-<name>` so it's easy to find in the `/resume` picker and stays labeled after a restart." `/rename` is a user-typed slash command — you cannot invoke it yourself, so only suggest it.

If argument starts with "drop" followed by an agent name (e.g. "drop alice"):
1. Parse the role name.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" claude-code <name> "$CLAUDE_CODE_SESSION_ID"` to remove only that role's registration for this project. If the role has no other registrations left, reset.sh also drops it from the team config. The 4th argument releases any actas exclusivity locks this session held on the role so peers can pick it up immediately (see #62).
3. If the session's active FROM was `<name>`, clear that state. Then:
   a. Run TaskList. Find any task whose description begins with "agmsg inbox stream".
   b. **If a matching task is found**: TaskStop it.
   c. **If no matching task is found**: skip TaskStop. Do NOT attempt TaskStop with a guessed or empty task_id.
   d. Run `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status claude-code "$(pwd)"` and read its **first line**.
      - **`mode: monitor` or `mode: both`**: invoke a fresh Monitor with the default subscription (no `actas` name filter — receives every (team, agent) pair currently registered for this project that isn't held by another session):
        - command: `~/.agents/skills/__SKILL_NAME__/scripts/watch.sh $CLAUDE_CODE_SESSION_ID "$(pwd)" claude-code`
        - description: `agmsg inbox stream`
        - persistent: true
      - **`mode: turn`**: leave it stopped, silently — the one case `delivery.sh` can confirm was deliberate.
      - **`mode: off (no agmsg delivery hooks installed for this project)`**: leave it stopped, but say so — same reasoning as the `actas` step this mirrors: this state is indistinguishable from "never configured" (#687 review round 3), so do not report it as deliberate. Do not report the drop as complete without mentioning it.
      - **`mode: off (unrecognized: ...)`**: leave it stopped, but say so with the stronger diagnostic — same reasoning as the `actas` step this mirrors (#687). Do not report the drop as complete without mentioning it.
4. Tell the user: "Dropped role `<name>` from this project."

If argument starts with "spawn" (e.g. "spawn codex reviewer", "spawn claude-code alice --window"):
1. Parse `<type>` (must be `claude-code` or `codex`), `<name>`, and any options (`--project`, `--team`, `--window`, `--split h|v`, `--terminal`, `--no-wait`, `--ready-timeout <secs>`).
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/spawn.sh <type> <name> --project "$(pwd)" [options]`
   - spawn.sh pre-joins `<name>`, then opens a tmux pane/window (when this session is inside tmux) or a new OS terminal, and launches the target CLI with `/__SKILL_NAME__ actas <name>` as its initial prompt.
   - By default it BLOCKS until the new agent's watcher attaches and prints `status=ready` — so you can message `<name>` right away. It prints `status=timeout` and exits 3 if not ready within `--ready-timeout` (default 90s); pass `--no-wait` for fire-and-forget. Codex skips the wait (no Monitor).
   - It refuses early if `<name>` is already held by another live session, if the target CLI is not installed, or if there is no tmux and no usable terminal (headless).
3. Show the script's output. Do NOT TaskStop or relaunch this session's own Monitor — spawn affects a separate, newly launched agent, not this session's subscription.

If argument starts with "despawn" (e.g. "despawn reviewer", "despawn alice --force"):
1. Parse `<name>` and any options (`--force`, `--timeout <secs>`). `despawn` is the inverse of `spawn` — it tears down a member you previously spawned.
2. Determine which team `<name>` belongs to (as with `send`), then run:
   `~/.agents/skills/__SKILL_NAME__/scripts/despawn.sh <team> $AGENT <name> [--force] [--timeout <secs>]`
   - Default (graceful): sends a `ctrl:despawn` control message to `<name>`. The member's watcher drops its own role (releasing the actas lock + registration) and closes its own tmux pane, which ends the agent CLI. Blocks until the lock releases, up to `--timeout` (default 30s), then prints `status=ok`. On timeout it prints `status=timeout` and exits 3 — the member's watcher didn't respond (dead watcher, or a codex member with no Monitor); retry with `--force`.
   - `--force`: skips the message and tears the member down from the placement recorded at spawn time — kills its tmux pane/window and drops its registration. Use when the member's watcher can't respond.
3. Show the script's output. Do NOT TaskStop or relaunch this session's own Monitor — despawn affects the spawned member, not this session's subscription.

If argument is "mode" (no further args):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status claude-code "$(pwd)"`
2. Show the output to the user.

If argument starts with "mode" followed by a mode name (e.g. "mode monitor"):
1. Parse the mode (one of `monitor`, `turn`, `both`, `off`).
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> claude-code "$(pwd)"`
3. Read the `AGMSG-DIRECTIVE` block in the command output and follow it (invoke Monitor or TaskStop as instructed).

If argument is "hook on" (legacy alias):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set turn claude-code "$(pwd)"`
2. Tell the user: "Delivery mode set to 'turn' (legacy hook on behavior). Consider using /__SKILL_NAME__ mode monitor for real-time push."

If argument is "hook off" (legacy alias):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set off claude-code "$(pwd)"`
2. Tell the user: "Delivery mode set to 'off'."

If argument is "config":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/config.sh show`
2. Show the output to the user.

If argument starts with "config set" (e.g. "config set hook.check_interval 30"):
1. Parse key and value from the arguments.
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/config.sh set <key> <value>`

If argument is "version":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/version.sh`
2. Show the output — the installed version (git-describe provenance recorded at install time).

If argument is "reset":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" claude-code`
2. Tell the user the result.

If argument starts with "rename" but not "rename-team":
1. Accept only an explicit user request. Parse either `<team> <old_name> <new_name>`, or `<old_name> <new_name>` only when this agent belongs to exactly one team.
2. Never invent either name. Before execution, repeat the resolved team, old name, and new name and ask the user to confirm. Wait for confirmation.
3. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/rename.sh <team> <old_name> <new_name>`
4. Show the result. For a connected team, the `member_renamed` journal event propagates the rename to other machines.

If argument starts with "rename-team":
1. Accept only an explicit user request. Parse `<old_team> <new_team>`.
2. Never invent either team name. Before execution, repeat the old and new team names and ask the user to confirm. Wait for confirmation.
3. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/rename-team.sh <old_team> <new_team>`
4. Show the result.

If argument starts with "remote connect":
1. Parse the required `--endpoint <url>` and `<team>`, plus optional `--e2ee`.
2. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh connect --endpoint <url> [--e2ee] <team>`
3. Show the output to the user. Plain sync is the default; pass `--e2ee` only when the user explicitly requests end-to-end encryption. The choice is fixed by the first connect.
4. End by showing this copy-paste command for the other machine, with the actual endpoint and team substituted: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh pull --endpoint <actual-url> <actual-team>`

If argument starts with "remote pull":
1. When the user asks to join or bring in a team that already exists on a server, NEVER use `join.sh`, create a team, or create a same-named local team. Always use remote pull.
2. Before pulling, check for a same-named local team. If one already exists without an active remote connection, stop and ask the user how to proceed; do not overwrite, merge, connect, or rename it on your own.
3. Parse the required `--endpoint <url>` and `<team>`, plus optional `--team-id <uuid>`.
4. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh pull --endpoint <url> [--team-id <uuid>] <team>`
5. Show the output to the user.

Machine B needs its own install, not just its own environment variables.
Only `remote.sh`, `remote-sync.sh`, `key.sh` and the two internal helpers read
`AGMSG_SYNC_CONNECTION_DIR`; `send.sh`, `history.sh`, `team.sh` and `inbox.sh`
resolve the team config from the install directory. So a pull driven by
environment variables alone succeeds, and the send that is supposed to confirm
it then reports the team as missing — the failure lands one step after the
cause. See "Use a separate install for testing" in `docs/remote-setup.md`.

**What e2ee changes, and what it doesn't.** The local store stays plaintext either way — `history`, `inbox`, and `send` read and write exactly the same regardless of a team's encryption setting. Only the SERVER side differs: an e2ee team's server rows carry `cipher: age-v1` and hold sealed ciphertext, so `from`, `to`, and `body` are not readable there; a plain team's rows are not sealed. Keys never pass through the server — moving one to another machine means carrying a handoff bundle by hand (`key handoff` above).

**Readable local history is therefore not evidence that a team is unencrypted.** To state whether a given team is e2ee, ask the program — `remote status <team>` below — never infer it from what you can read locally.

If argument starts with "remote unlock":
1. Parse `<team>`, `--bundle <file>`, and `--confirm-digest <sha256>`.
2. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh unlock <team> --bundle <file> --confirm-digest <sha256>`
3. The snapshot digest must be compared over a separate live channel. Never infer or auto-confirm it. The bundle is permanent secret key material; tell the user to transfer and handle it only through their own trusted channel, never by pasting it into agent chat.
4. Show the complete result, including the imported-envelope count and engine PID.
5. The advanced form with repeatable `--snapshot` plus `--identity` or `--identity-stdin` remains available when explicitly requested.

If argument starts with "remote status":
1. Parse an optional `<team>` and `--json`.
2. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh status [<team>] [--json]`
3. Show the output to the user.

If argument starts with "remote sync start":
1. Parse the required `<team>`.
2. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh sync start <team>`
3. Show the output to the user.

If argument starts with "remote disconnect":
1. Parse the required `<team>`.
2. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh disconnect <team>`
3. Show the output to the user.

If argument starts with "remote forget":
1. Parse the required `<team>`. This permanently deletes that team's local roster, history, keys, trust, and sync state, but never changes the server.
2. Do not add `--yes` yourself. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/remote.sh forget <team>`
3. The command requires the user to confirm in their terminal. If this agent has no interactive terminal, show the deletion summary and tell the user to rerun the displayed command directly; never bypass confirmation for them.

If argument starts with "key generate" followed by an optional team name:
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/key.sh generate [<team>]`
2. Show the full output to the user, including the mandatory key-backup notice — do not summarize it away.

If argument starts with "key show":
1. Parse an optional team name and `--reveal-secret`.
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/key.sh show [<team>] [--reveal-secret]`
3. `--reveal-secret` requires a real interactive terminal and is refused in agent mode — if the user wants to reveal a secret, tell them to run it themselves directly in their own terminal rather than through you.
4. Show the output to the user.

If argument starts with "key handoff" followed by a team name:
1. Parse optional `--out <file>` and run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/key.sh handoff <team> [--out <file>]`
2. The output bundle contains every epoch identity and is itself permanent secret key material. Never read it into agent chat or display its contents.
3. Show the bundle path, latest snapshot digest, and full secrecy warning.

If argument starts with "key import" followed by a team name:
1. **Do not ask the user to paste the private identity into this chat, and do not run this command yourself.** This identity is a permanent secret. Tell the user to run this directly in their own terminal:
   ```
   read -rsp 'Identity: ' IDENTITY; echo
   printf '%s' "$IDENTITY" | ~/.agents/skills/__SKILL_NAME__/scripts/key.sh import <team> --identity-stdin
   unset IDENTITY
   ```
2. Ask them to paste back only the command's output (never the identity itself) once it's done.
3. **No advanced/automation env-var path is offered for key import** — not even a pre-existing, before-session variable. An identity file is a permanent secret; always use the human-in-own-terminal flow above.

If argument starts with "key rotate" followed by a team name:
1. Rotation mints a replacement epoch for a team that already has a key and announces it on the roster journal. It requires an existing current key, an identity journal (connect or migrate the team first), and `age`; it refuses with a message naming whichever is missing.
2. Confirm with the user before running it. It changes the team's key state, and every other machine has to receive the new identity out of band.
3. Run: `bash ~/.agents/skills/__SKILL_NAME__/scripts/key.sh rotate <team>`
4. Show the output: epoch, key_id, and recipient fingerprint. The private key is never written to the journal. Revealing it needs `key show <team> --key-id <id> --reveal-secret`, which is refused in agent mode — tell the user to run that in their own terminal.
5. Messages before the acknowledged rotation boundary remain readable with the old key.

Device pairing (`key request` / `key approve`) is not implemented — they are not `key.sh` subcommands, so a call prints usage and exits 1. If the user asks for one, tell them so instead of attempting to run it.
