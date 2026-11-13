import { describe, expect, it } from "vitest";
import { agentPaneRows, diffAgentStatus, syncAgentStatus, type AgentPaneRow, type StatusReport } from "./addonStatus";

const panes = [
  { id: "white-1", label: "white", agentType: "claude-code" },
  { id: "black-2", label: "black", agentType: "codex" },
  { id: "sh-3", label: "shell", shell: true },
  { id: "chess-4", label: "Chess", kind: "addon" as const },
  { id: "plain-5", label: "plain" }, // the bash fallback: no agent type
  { id: "gray-6", label: "gray", agentType: "codex" },
];
const windows = [
  { team: "t", leafIds: ["white-1", "black-2", "sh-3", "chess-4", "plain-5"] },
  { team: "u", leafIds: ["gray-6"] },
];

const row = (paneId: string, state: AgentPaneRow["state"], team = "t", name = paneId): AgentPaneRow => ({ paneId, team, name, type: "codex", state });

describe("agentPaneRows", () => {
  it("lists only agent panes, with their tab's team, and unknown until a state is reported", () => {
    const rows = agentPaneRows(windows, panes, { "white-1": { state: "working" } }, new Set());
    expect(rows).toEqual([
      { paneId: "white-1", team: "t", name: "white", type: "claude-code", state: "working" },
      { paneId: "black-2", team: "t", name: "black", type: "codex", state: "unknown" },
      { paneId: "gray-6", team: "u", name: "gray", type: "codex", state: "unknown" },
    ]);
  });

  it("leaves out a pane whose process has ended", () => {
    const rows = agentPaneRows(windows, panes, {}, new Set(["black-2"]));
    expect(rows.map((r) => r.name)).toEqual(["white", "gray"]);
  });
});

describe("diffAgentStatus", () => {

  it("reports a new pane, and says nothing when nothing changed", () => {
    const first = diffAgentStatus(new Map(), [row("a", "idle")], 10);
    expect(first.reports).toEqual([{ team: "t", pane: "a", name: "a", kind: "codex", state: "idle", at: 10 }]);
    expect(diffAgentStatus(first.next, [row("a", "idle")], 11).reports).toEqual([]);
  });

  it("reports each actual change of state once", () => {
    const first = diffAgentStatus(new Map(), [row("a", "idle")], 10);
    const second = diffAgentStatus(first.next, [row("a", "working")], 20);
    expect(second.reports).toEqual([{ team: "t", pane: "a", name: "a", kind: "codex", state: "working", at: 20 }]);
    expect(diffAgentStatus(second.next, [row("a", "working")], 21).reports).toEqual([]);
  });

  it("reports a pane that went away once as closed, and nothing after", () => {
    const first = diffAgentStatus(new Map(), [row("a", "working"), row("b", "idle")], 10);
    const second = diffAgentStatus(first.next, [row("b", "idle")], 30);
    expect(second.reports).toEqual([{ team: "t", pane: "a", name: "a", kind: "codex", state: "closed", at: 30 }]);
    expect(diffAgentStatus(second.next, [row("b", "idle")], 31).reports).toEqual([]);
  });

  it("closes a pane in its old team when its tab moves to another team", () => {
    const first = diffAgentStatus(new Map(), [row("a", "idle", "t")], 10);
    const moved = diffAgentStatus(first.next, [row("a", "idle", "u")], 20);
    expect(moved.reports.map((r) => [r.team, r.state])).toEqual([["t", "closed"], ["u", "idle"]]);
  });

  it("makes no report at all when there are no agent panes", () => {
    expect(diffAgentStatus(new Map(), [], 1).reports).toEqual([]);
  });
});

describe("syncAgentStatus", () => {
  // The host's board as the Rust side keeps it: a row per pane, a closed report removes it.
  const board = new Map<string, string>();
  const host = (failNext: { n: number }) => async (r: StatusReport) => {
    if (failNext.n > 0) {
      failNext.n -= 1;
      throw new Error("invoke failed");
    }
    if (r.state === "closed") board.delete(r.pane);
    else board.set(r.pane, r.state);
  };

  it("repeats a report that failed, so the board converges and no closed pane stays", async () => {
    board.clear();
    const sent = new Map<string, AgentPaneRow>();
    const logs: string[] = [];
    const fail = { n: 0 };
    await syncAgentStatus(sent, [row("a", "idle"), row("b", "working")], 1, host(fail), (l) => logs.push(l));
    expect([...board]).toEqual([["a", "idle"], ["b", "working"]]);

    fail.n = 1; // the closing of "a" fails
    await syncAgentStatus(sent, [row("b", "working")], 2, host(fail), (l) => logs.push(l));
    expect(board.get("a")).toBe("idle"); // still on the host's board
    expect(sent.has("a")).toBe(true); // and still unreported here
    expect(logs).toHaveLength(1);
    expect(logs[0]).toContain("closed");

    await syncAgentStatus(sent, [row("b", "idle")], 3, host(fail), (l) => logs.push(l)); // the next change resends it
    expect([...board]).toEqual([["b", "idle"]]);
    expect(sent.has("a")).toBe(false);
  });

  it("does not lose a state change whose call failed", async () => {
    board.clear();
    const sent = new Map<string, AgentPaneRow>();
    const fail = { n: 0 };
    await syncAgentStatus(sent, [row("a", "idle")], 1, host(fail), () => {});
    fail.n = 1;
    await syncAgentStatus(sent, [row("a", "working")], 2, host(fail), () => {});
    expect(board.get("a")).toBe("idle");
    await syncAgentStatus(sent, [row("a", "working")], 3, host(fail), () => {});
    expect(board.get("a")).toBe("working");
  });

  it("keeps a failed close of the old team until it succeeds when the pane moved to another team", async () => {
    const teamBoard = new Map<string, string>(); // "team/pane" -> state
    const call = (fail: { n: number }) => async (r: StatusReport) => {
      if (fail.n > 0) {
        fail.n -= 1;
        throw new Error("invoke failed");
      }
      if (r.state === "closed") teamBoard.delete(`${r.team}/${r.pane}`);
      else teamBoard.set(`${r.team}/${r.pane}`, r.state);
    };
    const sent = new Map<string, AgentPaneRow>();
    const fail = { n: 0 };
    await syncAgentStatus(sent, [row("a", "idle", "t")], 1, call(fail), () => {});
    fail.n = 1; // only the close in team t fails
    await syncAgentStatus(sent, [row("a", "idle", "u")], 2, call(fail), () => {});
    expect([...teamBoard.keys()]).toEqual(["t/a"]);
    await syncAgentStatus(sent, [row("a", "working", "u")], 3, call(fail), () => {});
    expect([...teamBoard]).toEqual([["u/a", "working"]]); // t's snapshot is empty now
  });
});
