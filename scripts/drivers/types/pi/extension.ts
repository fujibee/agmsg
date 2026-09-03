import { execFileSync } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// agmsg-delivery-mode: __AGMSG_DELIVERY_MODE__
const AGMSG_DELIVERY_MODE = "__AGMSG_DELIVERY_MODE__";
const AGMSG_SKILL_DIR = __AGMSG_SKILL_DIR_JSON__;
const AGMSG_POLL_MS = __AGMSG_POLL_MS__;

function runScript(script: string, args: string[]): string {
  return execFileSync(
    "bash",
    [`${AGMSG_SKILL_DIR}/scripts/${script}`, ...args],
    { encoding: "utf-8", timeout: 15000 },
  );
}

function parseWhoami(output: string): { agent: string; teams: string[] } | null {
  const agent = /(?:^|\n)agent=(\S+)/.exec(output)?.[1];
  const teams = /(?:^|\n)teams=(\S+)/.exec(output)?.[1];
  if (!agent || !teams) return null;
  return { agent, teams: teams.split(",").filter(Boolean) };
}

function resolveIdentity(cwd: string): { agent: string; teams: string[] } | null {
  let whoami: string;
  try {
    whoami = runScript("whoami.sh", [cwd, "pi"]);
  } catch {
    return null;
  }
  if (whoami.includes("not_joined=true") || whoami.includes("multiple=true")) {
    return null;
  }
  return parseWhoami(whoami);
}

function collectUnread(cwd: string): string {
  const id = resolveIdentity(cwd);
  if (!id) return "";
  const chunks: string[] = [];
  for (const team of id.teams) {
    try {
      const out = runScript("inbox.sh", [team, id.agent, "--quiet"]).trim();
      if (out) chunks.push(out);
    } catch {
      // Keep polling even if one team store is missing or busy.
    }
  }
  return chunks.join("\n\n");
}

async function deliverUnread(pi: ExtensionAPI, ctx: ExtensionContext): Promise<void> {
  const body = collectUnread(ctx.cwd);
  if (!body) return;
  if (ctx.hasUI) {
    ctx.ui.notify("New agmsg message received", "info");
  }
  await pi.sendMessage(
    {
      customType: "agmsg-delivery",
      content: `[New agmsg message]:\n${body}`,
      display: true,
    },
    { triggerTurn: true, deliverAs: "steer" },
  );
}

export default function (pi: ExtensionAPI) {
  let pollingInterval: ReturnType<typeof setInterval> | undefined;

  pi.on("session_start", async (_event, ctx) => {
    if (pollingInterval) {
      clearInterval(pollingInterval);
      pollingInterval = undefined;
    }
    if (AGMSG_DELIVERY_MODE === "monitor") {
      pollingInterval = setInterval(() => {
        void deliverUnread(pi, ctx);
      }, AGMSG_POLL_MS);
      void deliverUnread(pi, ctx);
    }
  });

  pi.on("agent_settled", async (_event, ctx) => {
    if (AGMSG_DELIVERY_MODE === "turn") {
      void deliverUnread(pi, ctx);
    }
  });

  pi.on("session_shutdown", () => {
    if (pollingInterval) {
      clearInterval(pollingInterval);
      pollingInterval = undefined;
    }
  });

  pi.registerTool({
    name: "agmsg_send",
    description: "Send an agmsg message to another agent on this machine",
    parameters: Type.Object({
      recipient: Type.String({ description: "Recipient agent name" }),
      message: Type.String({ description: "Message body" }),
    }),
    execute: async (_toolCallId, { recipient, message }, _signal, _onUpdate, ctx) => {
      const id = resolveIdentity(ctx.cwd);
      if (!id) {
        throw new Error("agmsg: this project is not joined as a single pi identity; run /agmsg to join.");
      }
      const team = id.teams[0];
      if (!team) {
        throw new Error("agmsg: no team is registered for this identity.");
      }
      const output = runScript("send.sh", [team, id.agent, recipient, message]);
      return {
        content: [{ type: "text", text: output.trim() || "Message sent." }],
        details: {},
      };
    },
  });

  pi.registerTool({
    name: "agmsg_inbox",
    description: "Check this agent's agmsg inbox and mark unread messages as read",
    parameters: Type.Object({}),
    execute: async (_toolCallId, _params, _signal, _onUpdate, ctx) => {
      const id = resolveIdentity(ctx.cwd);
      if (!id) {
        throw new Error("agmsg: this project is not joined as a single pi identity; run /agmsg to join.");
      }
      const chunks: string[] = [];
      for (const team of id.teams) {
        const output = runScript("inbox.sh", [team, id.agent]).trim();
        if (output) chunks.push(output);
      }
      return {
        content: [{ type: "text", text: chunks.join("\n\n") || "No new messages." }],
        details: {},
      };
    },
  });
}
