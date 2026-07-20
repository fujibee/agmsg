import type { RawState } from "./agentStatus";

export type Presence = "PRESENT" | "ABSENT" | "UNKNOWN";
export type ManagedSessionState = "ACTIVE" | "DRAINING" | "INACTIVE";
export type ManagedSessionResult = "PASS" | "DENY";
export type FinalAck = "ACKNOWLEDGED" | "PENDING";

export type ManagedSessionInventory = {
  registration: Presence;
  process: Presence;
  pane: Presence;
  worktree: { status: Presence; dirty: boolean | null };
  generation: number | null;
  active_turn: boolean | null;
  final_ack: FinalAck | null;
};

export type ManagedSessionResponse = {
  schema_version: "1";
  state: ManagedSessionState;
  result: ManagedSessionResult;
  reason_code: string | null;
  session_id: string;
  inventory: ManagedSessionInventory | null;
};

export type ManagedDirector = {
  name: string;
  types: string[];
  project: string;
};

export type SpawnableType = {
  name: string;
  cli: string;
  options: string[];
};

export type InventoryRow = {
  key: keyof ManagedSessionInventory;
  value: string;
};

export function exactDirector(members: ManagedDirector[]): ManagedDirector | null {
  return members.find((member) => member.name === "director" && member.project.trim() !== "") ?? null;
}

export function directorArgv(
  director: ManagedDirector,
  spawnableTypes: SpawnableType[],
  commandName: string,
): string[] | null {
  const type = director.types.find((name) => spawnableTypes.some((candidate) => candidate.name === name));
  const spawnable = type ? spawnableTypes.find((candidate) => candidate.name === type) : undefined;
  if (!spawnable?.cli) return null;
  return [spawnable.cli, ...spawnable.options, `/${commandName} actas director`];
}

export function observedTurnSignal(state: RawState): "active" | "idle" | null {
  if (state === "working") return "active";
  if (state === "idle") return "idle";
  return null;
}

export function canFinalAck(response: ManagedSessionResponse | null): boolean {
  return Boolean(
    response?.state === "ACTIVE" &&
      response.inventory?.generation != null &&
      response.inventory.active_turn === false,
  );
}

export function inventoryRows(response: ManagedSessionResponse | null): InventoryRow[] {
  const inventory = response?.inventory;
  const unavailable = "UNKNOWN";
  return [
    { key: "registration", value: inventory?.registration ?? unavailable },
    { key: "process", value: inventory?.process ?? unavailable },
    { key: "pane", value: inventory?.pane ?? unavailable },
    {
      key: "worktree",
      value: inventory
        ? `${inventory.worktree.status} / ${inventory.worktree.dirty == null ? "UNKNOWN" : inventory.worktree.dirty ? "DIRTY" : "CLEAN"}`
        : unavailable,
    },
    { key: "generation", value: inventory?.generation == null ? unavailable : String(inventory.generation) },
    {
      key: "active_turn",
      value: inventory?.active_turn == null ? unavailable : inventory.active_turn ? "ACTIVE" : "IDLE",
    },
    { key: "final_ack", value: inventory?.final_ack ?? unavailable },
  ];
}
