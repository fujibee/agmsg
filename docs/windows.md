# Windows PowerShell launcher

agmsg's implementation remains the Bash script set under `scripts/`. The
PowerShell launcher is a thin platform shim: it finds Git Bash, checks that
`sqlite3` is available from Git Bash, sets UTF-8-oriented child process
environment, and delegates to `scripts/dispatch.sh`. The dispatcher then calls
the existing `scripts/*.sh` commands. Neither script reads or writes the SQLite
database directly.

This is separate from Codex sandbox permissions. The launcher improves the
Windows invocation path; Codex sandbox write access is handled with
`writable_roots` as described in the README's Codex sandbox section.

## Requirements

- Git for Windows, including Git Bash (`bash.exe`)
- `sqlite3` executable from Git Bash
- An installed agmsg skill tree, or a cloned repository when running from source

The launcher searches for Git Bash in this order:

1. `$env:GIT_BASH`
2. `$env:AGMSG_BASH`
3. `C:\Program Files\Git\bin\bash.exe`
4. `C:\Program Files\Git\usr\bin\bash.exe`
5. `C:\Program Files (x86)\Git\bin\bash.exe`
6. `bash.exe` on `PATH`, preferring Git for Windows and avoiding the WindowsApps
   WSL shim when possible

## Install the optional profile function

If you installed the default `agmsg` command:

```powershell
pwsh -ExecutionPolicy Bypass -File "$HOME\.agents\skills\agmsg\scripts\windows\install-agmsg.ps1" -WhatIf
pwsh -ExecutionPolicy Bypass -File "$HOME\.agents\skills\agmsg\scripts\windows\install-agmsg.ps1"
```

Run the installer from the PowerShell host you use. Use `powershell` instead of
`pwsh` if you use Windows PowerShell rather than PowerShell 7; each host has its
own profile path.

The installer adds or updates a marked block in your PowerShell profile:

```powershell
function agmsg {
    & '<launcher>\agmsg.ps1' @args
}
```

If you installed agmsg under a custom command name, pass the matching launcher
and function name:

```powershell
pwsh -ExecutionPolicy Bypass -File "$HOME\.agents\skills\m\scripts\windows\install-agmsg.ps1" -FunctionName m
```

The Git Bash installer does not write a top-level `~/.agents/<cmd>.ps1`
shortcut. PowerShell integration is kept under the installed skill tree and is
enabled by the marked profile block above.

## Usage

```powershell
agmsg
agmsg send claude-fable "確認しました"
agmsg history
agmsg team
agmsg mode off
agmsg mode turn
agmsg join emeria game-maker
```

For Codex sessions, `mode monitor` and `mode both` are rejected because Codex
does not have Claude Code's Monitor tool.

You can pass identity explicitly:

```powershell
agmsg -Team emeria -Agent game-maker inbox
agmsg -Team emeria -Agent game-maker send claude-fable "確認しました"
```

Or set identity for the current PowerShell session:

```powershell
$env:AGMSG_TEAM = "emeria"
$env:AGMSG_AGENT = "game-maker"
agmsg inbox
```

If neither `-Team` / `-Agent` nor `AGMSG_TEAM` / `AGMSG_AGENT` are set, the
launcher calls:

```bash
scripts/whoami.sh "$(pwd)" codex
```

It auto-selects only a single identity response:

```text
agent=<name> teams=<t1,t2,...> type=codex project=<path>
```

For `multiple=true`, `not_joined=true`, or `suggest=true`, it prints the
current `whoami.sh` output and command examples, then exits non-zero rather than
guessing.

## Command mapping

| PowerShell command | Delegated script |
| --- | --- |
| `agmsg`, `agmsg inbox` | `scripts/dispatch.sh` -> `scripts/inbox.sh` |
| `agmsg send <to> <message>` | `scripts/dispatch.sh` -> `scripts/send.sh` |
| `agmsg history` | `scripts/dispatch.sh` -> `scripts/history.sh` |
| `agmsg team [team]` | `scripts/dispatch.sh` -> `scripts/team.sh` |
| `agmsg config ...` | `scripts/dispatch.sh` -> `scripts/config.sh` |
| `agmsg mode [mode]` | `scripts/dispatch.sh` -> `scripts/delivery.sh` |
| `agmsg join <team> <agent>` | `scripts/dispatch.sh` -> `scripts/join.sh` |
| `agmsg reset [agent]`, `agmsg drop <agent>` | `scripts/dispatch.sh` -> `scripts/reset.sh` |
| `agmsg actas <agent>` | `scripts/dispatch.sh` -> `scripts/identities.sh` / `scripts/join.sh` with follow-up env guidance |

Message bodies are passed across the PowerShell to Git Bash boundary as argv
values and are handed to `send.sh` by the Bash dispatcher, so spaces, quotes,
Japanese text, and emoji are preserved without reimplementing message storage
in PowerShell.
