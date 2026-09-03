---
name: __SKILL_NAME__
description: Cross-agent messaging via SQLite. Send messages between Claude Code, Codex, Gemini CLI, Pi, and other agents. No daemon, no network, no dependencies beyond bash and sqlite3.
---

Agent messaging command. **IMPORTANT: Always use the provided scripts. NEVER directly read or edit config files, DB, or team data. There is NO register.sh — use join.sh to join a team.**

**Shell requirement:** All agmsg scripts are Bash scripts. Always execute them via `bash`, never via PowerShell or cmd directly. If your default shell is not Bash (e.g. PowerShell on Windows), wrap every command with `bash -lc '...'`. Example: `bash -lc '~/.agents/skills/__SKILL_NAME__/scripts/send.sh myteam alice bob "hello"'`. Do NOT construct DB paths manually — the scripts handle path resolution internally. If you need to redirect storage, use `AGMSG_STORAGE_PATH` (the supported override).

## Identity

If you already know your AGENT and TEAMS from a previous `/__SKILL_NAME__` call in this session, skip to **Execute** below.

Otherwise, run: `~/.agents/skills/__SKILL_NAME__/scripts/whoami.sh "$(pwd)" pi`

Four possible outputs:

**A) Single identity:**
`agent=<name> teams=<t1,t2,...> type=pi project=<path>`
→ Remember AGENT and TEAMS, then go to **Execute**.

**B) Multiple identities:**
`multiple=true agents=<n1,n2,...> teams=<t1,t2,...> type=pi project=<path>`
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
  3. **You MUST use join.sh** — run: `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <agent_name> pi "$(pwd)"`
  4. Show the result and explain:

  > **Joined!** You can now use `/__SKILL_NAME__` to check and send messages.
  > - `/__SKILL_NAME__` — check inbox
  > - `/__SKILL_NAME__ send <agent> <message>` — send a message
  > - `/__SKILL_NAME__ team` — list team members
  > - `/__SKILL_NAME__ history` — message history

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
                     Manual /__SKILL_NAME__ only.

     [1]:
     ```

     - **Wait for the user's answer before proceeding.** Empty input means `1` (turn).
     - Map the chosen number to a mode (`1`→`turn`, `2`→`monitor`, `3`→`off`) and run:
       `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> pi "$(pwd)"`
     - Tell the user to `/reload` (or restart Pi) so the project extension is picked up. `both` is not supported. Do NOT launch `watch.sh`.

  6. Then check inbox for the newly joined team.

**D) Suggestions for reuse:**
`suggest=true agents=<n1,n2,...> teams=<t1,t2,...> type=pi project=<path> available_teams=<t1,t2,...>`
→ No exact registration exists for this project, but there are same-type agent names registered elsewhere.

  1. Show the suggested agent names to the user.
  2. Ask whether to reuse one of those names or choose a new one.
  3. Ask for the team name to join (existing or new).
  4. Run: `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <agent_name> pi "$(pwd)"`
  5. Then continue with the normal post-join flow above.

## Execute

**Only use scripts in `~/.agents/skills/__SKILL_NAME__/scripts/` — do not read or modify files under `teams/` or `db/` directly.**

Incoming messages in `turn`/`monitor` are delivered by the project Pi extension at `.pi/extensions/agmsg.ts` (written by `delivery.sh`). Do **not** start `watch.sh` or any background watcher — Pi's session store rejects concurrent writers, so injection has to happen in-process. If delivery was just enabled and the extension is not loaded yet, ask the user to `/reload`. In `off` mode there is no extension; skip this.

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

If argument is "config":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/config.sh show`
2. Show the output to the user.

If argument starts with "config set" (e.g. "config set hook.check_interval 30"):
1. Parse key and value from the arguments.
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/config.sh set <key> <value>`


If argument starts with "actas" followed by an agent name (e.g. "actas alice"):
1. Parse the new role name. If none was given (e.g. bare "actas", or the user asks you to suggest one), run `~/.agents/skills/__SKILL_NAME__/scripts/team.sh <team>` for each TEAM to see the current roster. Look for a naming convention already in play (e.g. a shared base name with role and number suffixes (`<base>-<role><n>`), or names derived from the team name) and, when one exists, propose 2-3 unused names that extend it; otherwise propose 2-3 short, distinctive identity names (not a bare tool-type label). Either way, names must not collide with the roster. Ask the user to pick one or type their own before continuing.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/identities.sh "$(pwd)" pi` to see whether the role is already registered for this (project, type).
3. If the name does not appear in the output, join under the existing team. For a single team, run `~/.agents/skills/__SKILL_NAME__/scripts/join.sh <team> <name> pi "$(pwd)"`. For multiple teams, ask the user which team to join the new role into.
4. Set the session's active FROM to `<name>` for every `send.sh` call until another `actas`. The Pi extension re-resolves identity on each poll, so there is no watcher to switch.
5. Tell the user: "Now acting as `<name>`. Sends use `<name>` as from."

If argument starts with "drop" followed by an agent name (e.g. "drop alice"):
1. Parse the role name.
2. Run `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" pi <name>` to remove that role's registration.
3. If the session's active FROM was `<name>`, clear that state.
4. Tell the user: "Dropped role `<name>` from this project."

If argument is "mode" (no further args):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh status pi "$(pwd)"`
2. Show the output to the user.

If argument starts with "mode" followed by a mode name (e.g. "mode turn"):
1. Parse the mode. Pi supports `turn`, `monitor`, and `off` — reject `both` with: "Pi does not support `both`; use `turn`, `monitor`, or `off`."
2. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set <mode> pi "$(pwd)"`
3. Tell the user to `/reload` (or restart Pi) so the project extension matches the new mode. Do not start or stop `watch.sh`.

If argument is "hook on" (legacy alias):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set turn pi "$(pwd)"`
2. Tell the user: "Delivery mode set to 'turn' (legacy hook on behavior)."

If argument is "hook off" (legacy alias):
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/delivery.sh set off pi "$(pwd)"`
2. Tell the user: "Delivery mode set to 'off'."

If argument is "reset":
1. Run: `~/.agents/skills/__SKILL_NAME__/scripts/reset.sh "$(pwd)" pi`
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
