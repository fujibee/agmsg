import { tool } from "@opencode-ai/plugin"

const SKILL_DIR = process.env.HOME + "/.agents/skills/agmsg"
const SKILL_NAME = "agmsg"

function sh(script: string, ...args: string[]) {
  const scriptPath = `${SKILL_DIR}/scripts/${script}`
  const escaped = args.map((a) => `'${a.replace(/'/g, "'\\''")}'`).join(" ")
  return Bun.$`bash ${scriptPath} ${escaped}`.text()
}

/**
 * Resolve agent identity: returns key=value pairs on stdout.
 */
async function whoami(project: string, type: string): Promise<Record<string, string>> {
  const out = await sh("whoami.sh", project, type)
  const result: Record<string, string> = {}
  for (const part of out.trim().split(/\s+/)) {
    const [k, ...vs] = part.split("=")
    result[k] = vs.join("=")
  }
  return result
}

export const agmsg_inbox = tool({
  description: "Check agmsg inbox for unread messages (marks them as read)",
  args: {
    team: tool.schema.string().describe("Team name to check inbox for"),
    agent: tool.schema.string().describe("Your agent name in the team"),
  },
  async execute(args) {
    const out = await sh("inbox.sh", args.team, args.agent)
    return out.trim() || "No new messages."
  },
})

export const agmsg_send = tool({
  description: "Send a message to another agent via agmsg",
  args: {
    team: tool.schema.string().describe("Team name"),
    from: tool.schema.string().describe("Your agent name"),
    to: tool.schema.string().describe("Recipient agent name"),
    message: tool.schema.string().describe("Message body"),
  },
  async execute(args) {
    const out = await sh("send.sh", args.team, args.from, args.to, args.message)
    return out.trim()
  },
})

export const agmsg_history = tool({
  description: "Show agmsg message history for a team (optionally filtered by agent)",
  args: {
    team: tool.schema.string().describe("Team name"),
    agent: tool.schema.string().optional().describe("Filter by agent name (optional)"),
    limit: tool.schema.number().optional().describe("Max messages to show (default 20)"),
  },
  async execute(args) {
    const limit = args.limit ?? 20
    const cmdArgs = [args.team]
    if (args.agent) cmdArgs.push(args.agent)
    cmdArgs.push(String(limit))
    const out = await sh("history.sh", ...cmdArgs)
    return out.trim()
  },
})

export const agmsg_team = tool({
  description: "List members of an agmsg team",
  args: {
    team: tool.schema.string().describe("Team name"),
  },
  async execute(args) {
    const out = await sh("team.sh", args.team)
    return out.trim()
  },
})

export const agmsg_whoami = tool({
  description: "Check your agmsg identity for the current project (returns agent name, teams, or 'not joined')",
  args: {
    type: tool.schema.string().default("opencode").describe("Agent type (opencode, claude-code, gemini, etc.)"),
  },
  async execute(_args, context) {
    const type = _args.type || "opencode"
    const project = context.worktree || context.directory || "."
    const ident = await whoami(project, type)
    if (ident["not_joined"]) {
      const teams = ident["available_teams"] === "none" ? [] : (ident["available_teams"] || "").split(",")
      return JSON.stringify({ joined: false, availableTeams: teams })
    }
    if (ident["suggest"]) {
      const agents = (ident["agents"] || "").split(",")
      const teams = (ident["teams"] || "").split(",")
      return JSON.stringify({ joined: false, suggest: true, suggestedAgents: agents, suggestedTeams: teams, availableTeams: (ident["available_teams"] || "").split(",") })
    }
    const agents = (ident["agents"] || ident["agent"] || "").split(",").filter(Boolean)
    const teams = (ident["teams"] || "").split(",").filter(Boolean)
    return JSON.stringify({ joined: true, agents, teams, multiple: ident["multiple"] === "true" })
  },
})

export const agmsg_join = tool({
  description: "Join an agmsg team (creates team if it doesn't exist)",
  args: {
    team: tool.schema.string().describe("Team name to join"),
    agent: tool.schema.string().describe("Your agent name in the team"),
    type: tool.schema.string().default("opencode").describe("Agent type (opencode, claude-code, gemini, etc.)"),
  },
  async execute(args, context) {
    const type = args.type || "opencode"
    const project = context.worktree || context.directory || "."
    const out = await sh("join.sh", args.team, args.agent, type, project)
    return out.trim()
  },
})

// Mode tool — wraps delivery.sh set/status
export const agmsg_mode = tool({
  description: "Set or check agmsg delivery mode. Modes: turn (check between turns), off (manual only)",
  args: {
    mode: tool.schema.string().optional().describe("Delivery mode: 'turn' or 'off'. Omit to check current status."),
    type: tool.schema.string().default("opencode").describe("Agent type (opencode, claude-code, gemini, etc.)"),
  },
  async execute(args, context) {
    const type = args.type || "opencode"
    const project = context.worktree || context.directory || "."

    if (args.mode) {
      const out = await sh("delivery.sh", "set", args.mode, type, project)
      return out.trim()
    } else {
      const out = await sh("delivery.sh", "status", type, project)
      return out.trim()
    }
  },
})