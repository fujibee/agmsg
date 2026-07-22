---
name: agmsg
description: Cross-agent messaging via SQLite. Send messages between Claude Code, Codex, Gemini CLI, GitHub Copilot CLI, and other agents. No daemon, no network, no dependencies beyond bash and sqlite3.
---

# Agent Messaging

**IMPORTANT: Always use the provided scripts. NEVER directly read or edit config files, DB, or team data. There is NO register.sh — use join.sh to join a team.**

**Shell requirement:** All agmsg scripts are Bash scripts. Always execute them via `bash`, never via PowerShell or cmd directly. If your default shell is not Bash (e.g. PowerShell on Windows), wrap every command with `bash -lc '...'`. Example: `bash -lc '~/.agents/skills/agmsg/scripts/send.sh myteam alice bob "hello"'`. Do NOT construct DB paths manually — the scripts handle path resolution internally. If you need to redirect storage, use `AGMSG_STORAGE_PATH` (the supported override).

## How to use

### Step 0: First-run bootstrap

agmsg keeps its SQLite database, team registry, and runtime state under `~/.agents/skills/agmsg/`. The `./install.sh` install path creates that tree; the Claude Code plugin install path does not (the plugin marketplace flow only drops the skill content into `~/.claude/plugins/cache/`). Before any other command, bootstrap if needed:

```bash
if [ ! -d ~/.agents/skills/agmsg ]; then
  # Locate the plugin install script (any version), run it once.
  installer=$(ls ~/.claude/plugins/cache/fujibee-agmsg/agmsg/*/install.sh 2>/dev/null | head -1)
  if [ -n "$installer" ]; then
    bash "$installer" --cmd agmsg
  else
    echo "agmsg not installed. Either:" >&2
    echo "  - run ./install.sh in the agmsg repo, or" >&2
    echo "  - install via /plugin marketplace add fujibee/agmsg && /plugin install agmsg@fujibee-agmsg" >&2
    exit 1
  fi
fi
```

After this runs once, `~/.agents/skills/agmsg/` is populated and you can skip Step 0 on future invocations.

### Step 1: Check identity

```bash
~/.agents/skills/agmsg/scripts/whoami.sh "$(pwd)" <type>
# type: claude-code, codex, gemini, antigravity, copilot
# Returns: agent=... / multiple=true ... / suggest=true ... / not_joined=true ...
```

### Step 2a: If not in a team — join one

Ask the user for a team name. If it's an existing team, run `team.sh <team>` first to see the current roster and note the names already in use. Look for a naming convention already in play (e.g. a shared base name with role/number suffixes like `aggie-cc1`/`aggie-cc2`, or names derived from the team name) and, when one exists, propose 2-3 unused names that extend it; otherwise propose 2-3 short, distinctive identity names (not a bare tool-type label like `codex`/`cc`). Either way, names must not collide with the roster. For a brand-new team, skip the roster check and just ask. Then run:

```bash
~/.agents/skills/agmsg/scripts/join.sh <team> <agent_name> <type> "$(pwd)" [--force]
```

Do NOT manually edit config files. Always use join.sh. If the name was recently renamed away with `rename.sh`, join.sh refuses to revive it (printing the new name it maps to) instead of silently re-registering it — this guards against a CLI slash-command history resubmitting `actas <old_name>` after a rename. Pass `--force` only for a deliberate, unrelated reuse of that exact name.

### Step 2b: If already in a team — execute command

**Default (no arguments): IMMEDIATELY check inbox. Do NOT ask what to do.**

```bash
# Check inbox (marks messages as read) — DEFAULT action
~/.agents/skills/agmsg/scripts/inbox.sh <team> <agent_id>

# Send a message (from/to must already be registered in <team>; add --force to bypass)
~/.agents/skills/agmsg/scripts/send.sh <team> <from_agent> <to_agent> "<message>" [--force]

# Message history
~/.agents/skills/agmsg/scripts/history.sh <team> [agent_id] [limit]

# List team members
~/.agents/skills/agmsg/scripts/team.sh <team>

# Leave a team
~/.agents/skills/agmsg/scripts/leave.sh <team> <agent_id>

# Rename a team (moves dir, updates config + messages).
# After renaming, each existing member should re-run whoami.sh to refresh
# their cached team name in any running session.
~/.agents/skills/agmsg/scripts/rename-team.sh <old_team> <new_team>

# Show the installed version — the git-describe provenance string recorded at
# install time (tag + commits-since + abbreviated commit, plus -dirty when
# installed from a tree with uncommitted changes). See #117.
~/.agents/skills/agmsg/scripts/version.sh

# Clear registrations for the current project/type.
# A trailing <session_id> additionally releases any actas exclusivity locks
# this session held on <agent_id> so peers can pick them up immediately.
~/.agents/skills/agmsg/scripts/reset.sh "$(pwd)" <type> [agent_id] [session_id]

# Set delivery mode for this project.
#   monitor — real-time push via SessionStart + Monitor tool (claude-code only)
#   turn    — Stop-hook pulls at the end of each assistant turn
#   both    — monitor primary, turn as fallback
#   off     — no automatic delivery
~/.agents/skills/agmsg/scripts/delivery.sh set <mode> <type> "$(pwd)"
~/.agents/skills/agmsg/scripts/delivery.sh status <type> "$(pwd)"

# Multiple roles per project (one CC = one active role).
# Claude Code: `actas` claims an exclusivity lock for <name> across sessions
# and restarts the Monitor filtered to <name> only; peer watchers stop
# subscribing to <name> while this session holds the lock. `drop` releases.
# Codex: actas is send-side only (no stable session_id during slash commands
# → no peer-visible lock). See README "Codex caveat" for details.
# If <name> is new and none was given upfront (bare `actas`, or the user asks
# for a suggestion), check the target team's roster first (team.sh <team>).
# Look for a naming convention already in play (e.g. a shared base name with
# role/number suffixes like aggie-cc1/aggie-cc2, or names derived from the
# team name) and, when one exists, propose 2-3 unused names that extend it;
# otherwise propose 2-3 short, distinctive names. Either way, names must not
# collide with the roster. Ask the user to pick before continuing.
~/.agents/skills/agmsg/scripts/actas-claim.sh "$(pwd)" <type> <name> "$session_id"
~/.agents/skills/agmsg/scripts/reset.sh "$(pwd)" <type> <name> "$session_id"

# (Both of the above are normally driven by `/agmsg actas <name>` and
#  `/agmsg drop <name>` slash commands, which also handle the Monitor
#  TaskStop + relaunch dance described in the cmd template.)

# Spawn a NEW agent process that takes an actas identity on boot.
# Pre-joins <name> to a team, then launches the agent CLI in a tmux pane/window
# (when run inside tmux) or a new OS terminal, with `/agmsg actas <name>` as the
# initial prompt. By default it BLOCKS until the new agent's watcher attaches
# (prints `status=ready`), so a leader can send work right after spawn returns
# without losing it to the agent's cold start. claude-code/codex only; macOS
# primary, Linux/Windows best-effort. Non-tmux + no usable terminal (headless)
# errors out.
#   --project <path>     project to launch in (default: $PWD)
#   --team <team>        team to join into (default: auto-resolved from project)
#   --window             new tmux window instead of splitting the current one
#   --split h|v          tmux split direction (default h)
#   --terminal <tmpl>    terminal command template ({cmd} = path to the boot
#                        script) for the non-tmux path; overrides $AGMSG_TERMINAL
#                        / config spawn.terminal. macOS default uses `open -a`
#                        (no Automation/TCC permission prompt).
#   --no-wait            don't block on readiness (fire-and-forget)
#   --ready-timeout N    seconds to wait for readiness (default 90; on timeout
#                        prints status=timeout and exits 3). Codex skips the
#                        wait (it has no Monitor).
#   --boot-prompt <text>      hand the new agent an initial task: the boot prompt
#                        becomes the actas command followed (newline-separated)
#                        by <text>, so it claims its identity AND starts the task
#                        in its first turn. The only way to give a one-shot goal
#                        to a codex peer (no Monitor → a post-spawn send to its
#                        idle session is never noticed).
~/.agents/skills/agmsg/scripts/spawn.sh <claude-code|codex> <name> [options]

# Tear down a spawned member — the inverse of spawn.
# Default (graceful): sends a `ctrl:despawn` control message to <name>; the
# member's watcher drops its own role (releasing the actas lock + registration)
# and closes its own tmux pane, ending the agent. Blocks until the lock releases
# (--timeout, default 30s) then prints `status=ok`; on timeout prints
# status=timeout and exits 3 (retry with --force). Only an exclusive watcher
# dedicated to <name> acts on it — the despawning session is never torn down.
# --force: skip the message and tear the member down from the placement recorded
# at spawn time (kill its tmux pane/window, drop its registration) — for a dead
# watcher or a codex member (no Monitor). A hand-started member with no placement
# record can't be --forced.
#   --force              tear down from the recorded placement, no message
#   --timeout N          seconds to wait for graceful teardown (default 30)
~/.agents/skills/agmsg/scripts/despawn.sh <team> <from> <name> [--force] [--timeout N]
```

### Remote sync & end-to-end encryption (ADR 0007)

Connects a local team to a cloud/self-hosted sync endpoint and manages the
team's `age-v1` encryption key. Additive to everything above — a team works
purely locally without ever touching this. Login/token acquisition is out
of this script's scope (some provider tooling, or a self-hosted server's
own admin command, obtains the token); `connect` only ever receives one.

**Always use the `--*-stdin` forms below from an agent context.** The bare
positional forms (`<token>`, `<identity>`) exist only as a warned legacy
path for a human typing directly into their own terminal — from an agent,
they leak the secret into this session's own transcript/tool-result
history, which is exactly the kind of exposure `--token-stdin`/
`--identity-stdin` exist to avoid. Pipe the secret in; never pass it as
a literal argument in a command you construct.

```bash
# Connect a team to a sync endpoint. <token> is a short-lived, single-use
# exchange code (never the long-lived credential itself).
#   --force    rebind an already-connected team to a new token (requires
#              an explicit <team> — it cannot be inferred for this check)
printf '%s' "$TOKEN" | ~/.agents/skills/agmsg/scripts/remote.sh connect --endpoint <url> --token-stdin [<team>] [--force]

# If the team's capability response requires encryption and no local key
# exists yet, connect pauses to generate or import one before finishing —
# see the `key` commands below.

# Show connection state. With no <team>, lists every locally-known
# connected team (and whether each still needs a local encryption key).
~/.agents/skills/agmsg/scripts/remote.sh status [<team>]

# Disconnect a team: revokes the credential server-side (best-effort —
# local state is always cleared even if the server is unreachable), then
# clears the local sync driver override. Sends/reads keep working locally
# afterward; this does not touch the team's encryption key.
~/.agents/skills/agmsg/scripts/remote.sh disconnect <team>

# Read-only preflight check (currently: is `age` installed?). No token, no
# state change — safe to run any time, and the thing to point a user at
# when troubleshooting a missing dependency.
~/.agents/skills/agmsg/scripts/remote.sh doctor [<team>]

# Generate the first age-v1 key for a team (single-writer onboarding only —
# NOT the multi-writer cutover protocol, and NOT key rotation — see below).
# Prints a mandatory backup notice: there is no server-side recovery, and
# losing the device loses the key.
~/.agents/skills/agmsg/scripts/key.sh generate [<team>]

# Show the team's public recipient + fingerprint. --reveal-secret prints
# the private identity instead, after an interactive typed confirmation —
# refused outright when there's no TTY (i.e. never usable from agent mode).
~/.agents/skills/agmsg/scripts/key.sh show [<team>] [--reveal-secret]

# Install a private age identity obtained out-of-band (e.g. via
# `key.sh show <team> --reveal-secret` on another device that already has
# it). Rejected if it doesn't match the team's already-authorized key.
printf '%s' "$IDENTITY" | ~/.agents/skills/agmsg/scripts/key.sh import <team> --identity-stdin
```

**`key rotate` is NOT available in this release.** It refuses
unconditionally and changes no state — a design review found its
anti-rollback metadata insufficient (it can't detect a wholesale
config.json rollback, and doesn't use the age-v1 profile's pinned
canonical epoch-snapshot shape), so it's held back rather than shipping a
protection that isn't actually there. Do not suggest it as a working
command.

Slash-command surface (SKILL.md / per-type templates), same mapping
pattern as every command above:

```
/agmsg remote connect --endpoint <url>   (paste the token when prompted)
/agmsg remote status
/agmsg remote disconnect <team>
/agmsg remote doctor
/agmsg key generate [<team>]
/agmsg key show [<team>] [--reveal-secret]
/agmsg key import <team>   (paste the identity when prompted)
```

Additional dependencies beyond bash/sqlite3 (only needed if these commands
are used): `curl` (the exchange/revoke calls), `python3` (parsing the
exchange response), and `age`/`age-keygen` (E2EE — `remote.sh doctor`
checks for these and `key.sh`'s own commands refuse to run without them).

## Sandbox compatibility (Claude Code)

When Claude Code's sandbox is enabled, `watch.sh` (monitor mode) runs inside the sandbox and needs to write pidfiles and SQLite WAL files under `~/.agents/skills/agmsg/`. Add an allowlist entry to `~/.claude/settings.json` (or project-level `.claude/settings.local.json`):

```json
{
  "sandbox": {
    "filesystem": {
      "allowWrite": [
        "~/.agents/skills/agmsg/"
      ]
    }
  }
}
```

The allowlist merges across scopes and takes effect immediately — no restart needed. If agmsg was installed under a custom command name (e.g. `m`), adjust the path accordingly.

**Note on `BASH_SOURCE`**: The sandboxed Bash tool runs commands via pipe/eval, so `BASH_SOURCE[0]` is empty inside sourced functions like `storage.sh`. This is handled internally — `watch.sh` resolves `SKILL_DIR` from `$0` (which works correctly when invoked as a command), and `storage.sh` falls back to that value. No user configuration needed.

## Architecture

- **Storage**: SQLite with WAL mode in `~/.agents/skills/agmsg/db/messages.db`
- **Teams**: `~/.agents/skills/agmsg/teams/<name>/config.json`
- **Concurrency**: WAL allows multiple readers + 1 writer without conflicts
- **No daemon**: Direct DB access via `sqlite3` CLI
- **Dependencies**: bash, sqlite3 (no python3 required) for core messaging; `remote`/`key` (ADR 0007) additionally need `curl`, `python3`, and `age`/`age-keygen`, but only if those commands are used
