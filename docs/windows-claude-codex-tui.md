# Windows: Claude Code Desktop + Codex CLI/TUI

This is a practical integration path for a Windows workstation where Claude
Code Desktop coordinates work and Codex runs as an interactive CLI session in
a terminal. It uses agmsg as the message transport and keeps the Codex side
visible in its TUI.

This is different from waking a Codex Desktop conversation. Codex Desktop
delivery is a separate, still-evolving path; see [Codex Desktop message
delivery](https://github.com/fujibee/agmsg/issues/263), [the opt-in Desktop
monitor](https://github.com/fujibee/agmsg/issues/374), and [restart role
persistence](https://github.com/fujibee/agmsg/issues/365).

## Project and team convention

agmsg identities are team-scoped and may have registrations from more than one
project. For day-to-day work, a simpler convention is useful:

- use one team for one logical work folder;
- give each participating session an explicit agent name;
- start both sessions from the intended work folder, or verify their explicit
  project registrations with `whoami` and `team`;
- keep separate worktrees or intentionally separate subdirectories distinct
  when they represent different work contexts.

The current project resolver can collapse subdirectories of one Git repository
to the repository root. If independent agmsg projects are required inside one
repository, follow [#146](https://github.com/fujibee/agmsg/issues/146) and
verify the resolved project before relying on delivery state.

## Windows prerequisites

agmsg's transport scripts run in Bash. On Windows, use Git Bash and ensure the
same Git Bash installation is used by every agent. If PowerShell resolves
`bash` to the WSL shim, the agents can silently use different home directories
and different SQLite stores.

For a fixed Git for Windows installation, the PowerShell profile can contain:

```powershell
Set-Alias bash 'C:\Program Files\Git\bin\bash.exe'
```

Install or update agmsg, then restart Claude Code Desktop and the Codex CLI so
that both sessions load the current skill and hooks.

## Start the Claude coordinator

Open Claude Code Desktop in the intended work folder and run:

```text
/agmsg
```

Join the existing team or create one, choose a stable name such as
`claude-desktop`, and select the delivery mode appropriate for the Claude
session. Claude monitor mode can receive messages without waiting for the next
manual turn, but the first turn after a restart is still the point at which the
session-start hook can attach.

## Start the Codex TUI peer

Open a normal terminal in the intended work folder and start Codex. In the new
Codex session, run the agmsg skill, join the same team, and choose a stable
name such as `codex-tui`:

```text
$agmsg
$agmsg actas codex-tui
```

For a visible CLI/TUI workflow, use `turn` delivery or manual inbox checks:

```text
$agmsg mode turn
```

With `turn`, an incoming message is checked at the end of the Codex turn. When
waiting for a new request, finish the current turn instead of repeatedly
polling the inbox. A manual check is useful for setup and troubleshooting, but
it can consume a message before monitor-style delivery sees it; see
[#600](https://github.com/fujibee/agmsg/issues/600).

## Verify the path

From Claude, send a short request to `codex-tui`, for example:

```text
Claude Code DesktopからのE2E試験です。agmsgでclaude-desktopへ ACK-WINDOWS-TUI を返信してください。
```

The Codex TUI should read the message through agmsg and send the ACK back to
`claude-desktop`. Confirm the reply in Claude. If the message does not arrive,
check the team and resolved project before changing delivery modes.

## Restart behavior

After restarting a Desktop or CLI session, send one harmless first turn such
as `再開` or `resume`, then invoke agmsg once. This gives the session-start
hook a turn in which to re-establish the role and receiver state. A successful
restart test should distinguish:

1. the team and role registration still exists;
2. the live receiver seat has been re-established; and
3. a message is visibly handled without being consumed by a manual check.

If the Codex endpoint is Codex Desktop rather than Codex CLI/TUI, do not assume
that this recipe provides proactive thread wake. Use the Desktop-specific
monitor work described in [#263](https://github.com/fujibee/agmsg/issues/263)
and [#374](https://github.com/fujibee/agmsg/issues/374).

## Troubleshooting checklist

- `whoami` resolves the intended agent type, team, and project path.
- `team` shows the expected peer names and no stale duplicate identity.
- The Claude and Codex sessions point at the same intended agmsg storage and
  team; on Windows, this usually means the same Git Bash and home directory.
- Codex `turn` delivery is allowed to reach the end of a turn.
- A restart has been followed by one first turn and one agmsg check.
- For broader state inspection, use `agmsg doctor` when available; it reports
  registrations, locks, watchers, bridges, and delivery warnings without
  repairing state.
