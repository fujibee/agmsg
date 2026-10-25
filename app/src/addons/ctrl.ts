// The real S10 rows. Rust reads the team's messages, decides where each came
// from and what can be done with it, and hands back a verdict per row; this file
// only turns that into the bar items and notes the screens draw. The UI never
// re-decides origin, requester or path: a row it holds is a picture, and Open
// is checked again by Rust from the store.

import { parseOpenRequest, type RefusalReason } from "./openRequest";
import type { BarItem, BarStatus, RequestScan, RowNote } from "./requests";

export type CtrlVerdict =
  | "ready"
  | "not_installed"
  | "unavailable"
  | "args_not_allowed"
  | "bad_requester"
  | "not_found_here"
  | "denied_path"
  | "synced"
  | "unproven"
  | "refused";

/** One row of addon_ctrl_rows: the message plus the host's judgement. */
export type CtrlRowRaw = {
  id: string;
  team: string;
  from: string;
  to: string;
  body: string;
  created_at: string;
  origin: "local" | "synced" | "unproven";
  verdict: CtrlVerdict;
  detail?: string;
  installTarget?: string;
  requesterMatches: boolean;
  pathState?: "exists" | "missing" | "denied";
  /** Always "unverified" in this build: the sender's name is recorded, not proven. */
  tokenCheck: string;
  refusal?: { reason: string; detail?: string };
  requestId?: string;
};

export type CtrlScanRaw = {
  appUser: string | null;
  rows: CtrlRowRaw[];
  handled: string[];
  truncated: boolean;
  notice?: string;
};

export type CtrlOpened = {
  requestId: string;
  from: string;
  addonId: string;
  pane: string;
  openArgs: { path?: string; url?: string; base?: string };
};

export type CtrlScanView = RequestScan & {
  /** Why there is nothing to show, in Rust's words (no app-user, several app-users). */
  notice?: string;
  /** Older requests were left out. */
  truncated: boolean;
};

const BAR_STATUS: Partial<Record<CtrlVerdict, BarStatus>> = {
  ready: "open",
  not_installed: "not_installed",
  unavailable: "unavailable",
  args_not_allowed: "args_not_allowed",
  bad_requester: "bad_requester",
  not_found_here: "not_found_here",
  denied_path: "denied_path",
};

const REASONS: readonly RefusalReason[] = [
  "missing_payload", "extra_content", "too_large", "bad_json", "bad_shape", "bad_pane",
  "unknown_arg_key", "bad_arg_value", "bad_requester", "bad_request_id", "request_id_reused",
];
const asReason = (r: string): RefusalReason => ((REASONS as readonly string[]).includes(r) ? (r as RefusalReason) : "bad_shape");

export function toCtrlView(raw: CtrlScanRaw): CtrlScanView {
  const items: BarItem[] = [];
  const notes = new Map<string, RowNote>();
  for (const row of raw.rows) {
    switch (row.verdict) {
      case "synced":
        notes.set(row.id, { kind: "other_machine" });
        continue;
      case "unproven":
        notes.set(row.id, { kind: "unproven" });
        continue;
      case "refused":
        notes.set(row.id, { kind: "malformed", reason: asReason(row.refusal?.reason ?? ""), detail: row.refusal?.detail });
        continue;
    }
    const status = BAR_STATUS[row.verdict];
    const parsed = parseOpenRequest(row.body);
    // Rust parsed this body already; if the UI's reading of it disagrees, show it as malformed, never as openable.
    if (!status || parsed.kind !== "request") {
      notes.set(row.id, { kind: "malformed", reason: parsed.kind === "refused" ? parsed.reason : "bad_shape", detail: parsed.kind === "refused" ? parsed.detail : undefined });
      continue;
    }
    items.push({
      requestId: parsed.request.requestId,
      from: row.from,
      at: row.created_at,
      pane: parsed.request.pane,
      request: parsed.request,
      status,
      detail: row.detail,
      installTarget: row.installTarget,
    });
  }
  return { items, notes, notice: raw.notice, truncated: raw.truncated };
}
