# Session resume & tmux-resurrect

This is the long-form reference for bringing a role back into its previous
conversation, introduced briefly in the [README](../README.md#bring-a-role-back-with-its-context-session-resume).
Most users only need the README summary; reach for this page when wiring up
tmux-resurrect, or when a pane comes back empty and you want to know why.

A role `(team, agent)` has a durable link to the CLI session that last embodied
it. The moment a session `actas`'s a role, agmsg records `(team, agent) → session`
(an advisory file under the skill's `run/` directory). Two things consume that
record:

- **`spawn`** resumes a role's recorded session by default (see
  [actas.md](actas.md) for the multi-role model `spawn` builds on).
- the **tmux-resurrect hook** re-seats each role pane into its session after a
  tmux-server restart.

Resume is supported for **Claude Code** (`--resume <uuid>`) and **Codex**
(`codex resume <id>`); other agent types have no resume equivalent and always
boot fresh.

## Setup

Install [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) (and,
optionally, [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) for
automatic periodic saves). Then add one line to `~/.tmux.conf`:

```tmux
set -g @resurrect-hook-post-restore-all '~/.agents/skills/agmsg/scripts/internal/resurrect-panes.sh'
```

Reload tmux (`tmux source-file ~/.tmux.conf`) and the hook runs on every restore.

> **Do not add the agent CLI to `@resurrect-processes`.** Re-running the saved
> command verbatim is wrong in both directions: a fresh-boot command line would
> start *another* brand-new session, and a name-based resume command line stalls
> on the interactive `/resume` picker. The hook exists precisely to avoid both.

Sessions you start by hand (`claude`, then `/agmsg actas <name>`) rather than via
`spawn` have no convention name, so tmux-resurrect can't recognize the pane.
Rename them so the pane title and `/resume` picker stay meaningful — `spawn`-born
sessions are already named this way:

```
/rename myteam-alice
```

## How it works

- **At `actas` time**, agmsg records `(team, agent) → session id` (plus the
  display name `myteam-alice`, the agent type, and the project).
- **At restore time**, tmux-resurrect brings the window/pane layout back with
  each pane as a plain shell (because the CLI is deliberately *not* in
  `@resurrect-processes`). The hook then reads the resurrect save file and, for
  each pane whose saved title or `-n <name>` argv marker matches a recorded role,
  resolves that role's current session and relaunches it into the pane with
  `tmux send-keys` — the same resume-or-fresh command `spawn` builds.

The hook never guesses: it matches the whole `<team>-<agent>` name (never split on
`-`), and it acts only on panes that restored as a shell.

## Restoring

**Full restore** — the whole tmux server went down (reboot, crash):

```sh
tmux kill-server        # or a reboot
# start tmux again, then:
# prefix + Ctrl-r        (tmux-resurrect restore)
```

**Partial restore** — you only want to revive specific sessions, leaving the
rest running:

```sh
tmux kill-session -t myteam-alice
# prefix + Ctrl-r
```

Partial restore is safe: the hook **skips any pane whose role is still held by a
live session**, and it never touches a pane that came back running something, so
your surviving sessions are left alone.

## What comes back automatically, and what doesn't

| Pane | On restore |
| --- | --- |
| A `claude-code` role with a recorded session | **Auto-seated** — resumed into its session, context restored, role re-armed |
| A role whose lock is held by a **live** session elsewhere | **Skipped** — it's already seated; reseating would double-launch |
| A pane with no role marker (a hand-started session never renamed; a codex pane) | Left as a **plain shell** — `spawn` or `actas` it again |
| A role whose recorded transcript is gone | Boots **fresh** (the stale record is ignored) |

## Manual fallback

If a pane didn't auto-seat and you want it back by hand, resume in the pane and
re-run `actas`:

```sh
claude --resume <uuid>          # or: claude --resume myteam-alice  (picker)
# then, in the resumed session:
/agmsg actas alice
```

The recorded session id lives in the skill's `run/role-session.*` files — read it
if you need the exact uuid (these are advisory state; only read them, never edit).

## Notes

- **Resume restores context only.** A resumed session has no running watcher and
  an unverified exclusivity lock, so re-running `actas` on resume is what
  re-establishes the role-filtered watcher, re-claims the lock, and sets the
  active FROM. `spawn` and the hook pass the `actas` prompt automatically; a
  manual `--resume` needs the `actas` step yourself (a role-aware SessionStart
  directive prompts for it).
- **`--fresh`** on `spawn` forces a brand-new session even when the role is
  resumable.
- **Untrusted directory.** Resuming into a directory the CLI hasn't seen before
  shows its "trust this folder?" prompt before it processes anything. Spawned and
  resurrected panes run in already-trusted project directories, so this only
  appears for a brand-new hand-started location.
