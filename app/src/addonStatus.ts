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

/** What `sent` holds after the host accepted `r`: a closed pane is dropped, any other report is the pane's row. */
function accepted(sent: Map<string, AgentPaneRow>, r: StatusReport): void {
  if (r.state === "closed") sent.delete(r.pane);
  else sent.set(r.pane, { paneId: r.pane, team: r.team, name: r.name, type: r.kind, state: r.state });
}

/**
 * Sends the reports for the agent panes open now, one after another, and records a report in `sent` only once the host
 * has accepted it. A report that fails is logged and stays unrecorded, so the next call computes it again and sends it
 * again: no ended pane stays on the host's board and no change is lost.
 */
export async function syncAgentStatus(
  sent: Map<string, AgentPaneRow>,
  now: AgentPaneRow[],
  at: number,
  send: (r: StatusReport) => Promise<unknown>,
  log: (line: string) => void,
): Promise<void> {
  // A pane whose report failed is left alone for the rest of this run: a later report for it (the new team of a pane that
  // moved) must not overwrite the row of the old team before that team has been told the pane closed.
  const failed = new Set<string>();
  for (const r of diffAgentStatus(sent, now, at).reports) {
    if (failed.has(r.pane)) continue;
    try {
      await send(r);
      accepted(sent, r);
    } catch (e) {
      failed.add(r.pane);
      log(`addon agent status: could not report ${r.state} for ${r.name} (${String(e)}); it is sent again on the next change`);
    }
  }
}
