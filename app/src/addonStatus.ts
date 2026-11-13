// What the window tells the host about the agent panes, so an add-on that reads a team can learn each agent's state.
// Pure: App.tsx feeds in the panes and their states and invokes `addon_agent_status` for each report returned.

import type { RawState } from "./agentStatus";

/** One open agent pane: the window's own pane id (never sent to an add-on), its tab's team, member name, agent type and state. */
export type AgentPaneRow = { paneId: string; team: string; name: string; type: string; state: RawState };

/** What the host is told: the same row, or `closed` for a pane that went away. */
export type StatusReport = { team: string; pane: string; name: string; kind: string; state: RawState | "closed"; at: number };

type PaneLike = { id: string; label: string; agentType?: string; shell?: boolean; kind?: "addon" };
type WindowLike = { team: string; leafIds: string[] };

/**
 * The agent panes that are open: a pane that runs a member's CLI (it has an agent type) in a tab of a team, not a shell,
 * an add-on pane or the plain-shell fallback, and not one whose process has ended. A pane that has reported no state yet
 * is `unknown`.
 */
export function agentPaneRows(
  windows: WindowLike[],
  panes: PaneLike[],
  status: Record<string, { state: RawState } | undefined>,
  ended: ReadonlySet<string>,
): AgentPaneRow[] {
  const byId = new Map(panes.map((p) => [p.id, p]));
  const rows: AgentPaneRow[] = [];
  for (const w of windows) {
    for (const id of w.leafIds) {
      const p = byId.get(id);
      if (!p || !p.agentType || p.shell || p.kind === "addon" || ended.has(id)) continue;
      rows.push({ paneId: id, team: w.team, name: p.label, type: p.agentType, state: status[id]?.state ?? "unknown" });
    }
  }
  return rows;
}

/**
 * The reports to make now, given what was last reported (`sent`, by pane id) and the agent panes open now: a pane that is
 * new or whose state changed is reported with its state, a pane that is gone is reported once as `closed`. Nothing is
 * reported for a pane whose state is the one already reported. `next` is the new `sent`.
 */
export function diffAgentStatus(sent: ReadonlyMap<string, AgentPaneRow>, now: AgentPaneRow[], at: number): { reports: StatusReport[]; next: Map<string, AgentPaneRow> } {
  const reports: StatusReport[] = [];
  const next = new Map<string, AgentPaneRow>();
  for (const row of now) {
    next.set(row.paneId, row);
    const before = sent.get(row.paneId);
    if (before && before.state === row.state && before.team === row.team) continue;
    // a pane that moved to another team's tab is closed there first, so no team keeps a row for it
    if (before && before.team !== row.team) reports.push({ team: before.team, pane: before.paneId, name: before.name, kind: before.type, state: "closed", at });
    reports.push({ team: row.team, pane: row.paneId, name: row.name, kind: row.type, state: row.state, at });
  }
  for (const [paneId, before] of sent) {
    if (!next.has(paneId)) reports.push({ team: before.team, pane: paneId, name: before.name, kind: before.type, state: "closed", at });
  }
  return { reports, next };
}
