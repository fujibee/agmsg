// The real S10 rows. Rust reads the current team's messages to its app-user,
// finds the whole lines that ask to open a pane, and hands back a verdict per
// line; this file only turns that into the bar items and notes the screens draw.
// The UI never re-decides anything: a row it holds is a picture, and Open is
// checked again by Rust from the store.

import type { BarItem, BarStatus, RequestScan, RowNote } from "./requests";

export type OpenVerdict = "ready" | "not_installed" | "unavailable" | "args_not_allowed" | "not_found_here" | "denied_path" | "refused";

/** One line of one message, as addon_open_requests returns it. */
export type OpenRowRaw = {
  requestId: string;
  id: string;
  team: string;
  from: string;
  created_at: string;
  addonId?: string;
  pane?: string;
  path?: string;
  verdict: OpenVerdict;
  detail?: string;
  installTarget?: string;
  pathState?: "exists" | "missing" | "denied";
  refusal?: { reason: string; detail?: string };
};

export type OpenScanRaw = {
  appUser: string | null;
  rows: OpenRowRaw[];
  truncated: boolean;
  notice?: string;
};

export type OpenedRequest = {
  requestId: string;
  from: string;
  addonId: string;
  pane: string;
  openArgs: { path?: string; url?: string; base?: string };
};

export type OpenScanView = RequestScan & {
  /** Why there is nothing to show, in Rust's words (no app-user, several app-users). */
  notice?: string;
  /** Older requests were left out. */
  truncated: boolean;
};

const BAR_STATUS: Record<Exclude<OpenVerdict, "refused">, BarStatus> = {
  ready: "open",
  not_installed: "not_installed",
  unavailable: "unavailable",
  args_not_allowed: "args_not_allowed",
  not_found_here: "not_found_here",
  denied_path: "denied_path",
};

export function toOpenView(raw: OpenScanRaw): OpenScanView {
  const items: BarItem[] = [];
  const notes = new Map<string, RowNote>();
  for (const row of raw.rows) {
    const status = row.verdict === "refused" ? undefined : BAR_STATUS[row.verdict];
    // A verdict the UI does not know, or a row with no target, is never shown as openable.
    if (!status || !row.addonId || !row.pane) {
      notes.set(row.requestId, { kind: "malformed", reason: row.refusal?.reason ?? "unreadable", detail: row.refusal?.detail ?? row.detail });
      continue;
    }
    items.push({
      requestId: row.requestId,
      from: row.from,
      team: row.team,
      at: row.created_at,
      addonId: row.addonId,
      pane: row.pane,
      path: row.path,
      status,
      detail: row.detail,
      installTarget: row.installTarget,
    });
  }
  return { items, notes, notice: raw.notice, truncated: raw.truncated };
}

/** What the "copy text for your seats" button copies: how a seat asks the app to open a pane. */
export const SEAT_INSTRUCTION = [
  "To ask the agmsg app to open an add-on pane for the user, send a message to the app user with this on a line of its own (not quoted, not in a code block):",
  "agmsg-app open <addon-id> <pane> [path=<absolute path>]",
  "Example: agmsg-app open builtin:fileview fileview path=/Users/me/project",
  "Built-in panes: builtin:fileview fileview, builtin:diffview diffview. The user has to click Open in the app; nothing opens by itself.",
].join("\n");
