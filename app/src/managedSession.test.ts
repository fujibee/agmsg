import { describe, expect, it } from "vitest";
import {
  canFinalAck,
  directorArgv,
  exactDirector,
  inventoryRows,
  observedTurnSignal,
  type ManagedSessionResponse,
} from "./managedSession";

const activeResponse = (activeTurn: boolean | null): ManagedSessionResponse => ({
  schema_version: "1",
  state: "ACTIVE",
  result: "PASS",
  reason_code: null,
  session_id: "aases-session-123",
  inventory: {
    registration: "PRESENT",
    process: "PRESENT",
    pane: "PRESENT",
    worktree: { status: "PRESENT", dirty: false },
    generation: 4,
    active_turn: activeTurn,
    final_ack: "PENDING",
  },
});

describe("managed session activation", () => {
  it("selects only an exact registered director with a project", () => {
    expect(
      exactDirector([
        { name: "Director", types: ["codex"], project: "/tmp/a" },
        { name: "director", types: ["codex"], project: "" },
      ]),
    ).toBeNull();
    expect(exactDirector([{ name: "director", types: ["codex"], project: "/tmp/a" }])?.project).toBe("/tmp/a");
  });

  it("builds the director command as argv without a shell string", () => {
    expect(
      directorArgv(
        { name: "director", types: ["codex"], project: "/tmp/a" },
        [{ name: "codex", cli: "codex", options: ["--full-auto"] }],
        "agmsg",
      ),
    ).toEqual(["codex", "--full-auto", "/agmsg actas director"]);
  });
});

describe("managed session safety state", () => {
  it("maps only working and idle observations to turn signals", () => {
    expect(observedTurnSignal("working")).toBe("active");
    expect(observedTurnSignal("idle")).toBe("idle");
    expect(observedTurnSignal("blocked")).toBeNull();
    expect(observedTurnSignal("unknown")).toBeNull();
  });

  it("permits a final ACK only for a current generation observed idle", () => {
    expect(canFinalAck(activeResponse(false))).toBe(true);
    expect(canFinalAck(activeResponse(true))).toBe(false);
    expect(canFinalAck(activeResponse(null))).toBe(false);
  });

  it("keeps all seven inventory concepts distinct", () => {
    expect(inventoryRows(activeResponse(false)).map((row) => row.key)).toEqual([
      "registration",
      "process",
      "pane",
      "worktree",
      "generation",
      "active_turn",
      "final_ack",
    ]);
  });
});
