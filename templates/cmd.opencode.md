---
description: Agent messaging — check inbox, send messages, view history, manage teams
---

Agent messaging via agmsg. Uses the agmsg_* custom tools to send and receive messages between CLI AI agents (opencode, Claude Code, Gemini CLI, etc.) via a shared SQLite database.

## Identity

If you already know your AGENT and TEAMS from a previous session, skip to **Execute** below.

Otherwise, call the `agmsg_whoami` tool to check your identity:

**A) User is joined:**
The tool returns `{ "joined": true, "agents": [...], "teams": [...] }`.
→ Remember AGENT and TEAMS, then go to **Execute**.

**B) User is not joined, suggestions exist:**
The tool returns `{ "joined": false, "suggest": true, "suggestedAgents": [...], "suggestedTeams": [...], "availableTeams": [...] }`.
→ Ask the user: "You're not in a team yet. Previous agents found: <names>. Join an existing team or create a new one? Agent name?"
→ Call `agmsg_join` with the chosen team and agent name.

**C) User is not joined, no suggestions:**
The tool returns `{ "joined": false, "availableTeams": [...] }`.
→ Ask the user for a team name (new or existing from the list) and an agent name.
→ Call `agmsg_join` with the chosen team and agent name.

**D) After joining**, ask the user to pick a delivery mode:
```
Choose delivery mode for incoming messages:
  1) turn    — Check inbox at the end of each assistant turn
  2) off     — Manual agmsg only (use tools explicitly)
```
→ Call `agmsg_mode` with the chosen mode.

## Execute

All operations use the agmsg_* tools directly — no shell commands needed.

**Default (no arguments) — IMMEDIATELY check inbox:**
→ Call `agmsg_inbox` for each team the user belongs to.
→ Do NOT ask — just run it.

**Send a message:**
→ Call `agmsg_send` with team, from, to, message.

**View history:**
→ Call `agmsg_history` with team (optionally agent and limit).

**List team members:**
→ Call `agmsg_team` with team.

**Check/change delivery mode:**
→ Call `agmsg_mode` (with or without mode value).

**Join another team or re-join:**
→ Call `agmsg_join` with team, agent, type.