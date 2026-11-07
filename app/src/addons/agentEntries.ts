import type { MemberState } from "./source";

// What Settings → Add-ons shows about the members and agents add-ons made (the entries Rust keeps).
// An agent that may still be running after a crash is never reopened by itself: the person chooses (design Q7).

/** The entries worth a row: the ones with a team behind them, in the order Rust gave them; `claimed` is internal. */
export function visibleEntries(all: MemberState[]): MemberState[] {
  return all.filter((e) => e.state !== "claimed");
}

/** orphaned / unknown ask the person; joined and failed can be opened (the retry after a start that did not finish). */
export type EntryChoice = "choose" | "open" | null;

export function choiceFor(e: MemberState): EntryChoice {
  if (e.kind !== "agent") return null;
  if (e.state === "orphaned" || e.state === "unknown") return "choose";
  if (e.state === "joined" || e.state === "failed") return "open";
  return null;
}
