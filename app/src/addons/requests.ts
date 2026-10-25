// Turns a team's messages into the S10 bar items (design §7): which rows are
// requests, which are refused and why, and what the bar offers for each. The
// checks that need the app (is this row local, does the path exist, is the pane
// installed) come in through RequestContext; mock.ts supplies stand-ins and the
// app side fills them in. The envelope itself is parsed in openRequest.ts.

import { parseOpenRequest, type OpenRequest, type PaneTarget, type RefusalReason } from "./openRequest";
import type { AddonPaneDecl, Message } from "./types";

/** A message row plus what the store knows about where it came from. */
export type RequestRow = Message & { origin?: unknown };

export type RequestContext = {
  /** The team this tab shows; only requests addressed to its app-user are shown. */
  team: string;
  appUser: string;
  /** Provably accepted on this machine, not received through sync. Mocked until the app side fills it in. */
  isLocalOrigin: (row: RequestRow) => boolean;
  /** The requester's member id matches the row's accepted `from`. */
  requesterMatches: (req: OpenRequest, row: RequestRow) => boolean;
  /** The add-on pane declarations, or null when `owner/repo` is not installed. Built-ins are always installed. */
  installedPane: (target: PaneTarget) => AddonPaneDecl | "builtin" | null;
  pathExists: (path: string) => boolean;
  /** No TTL is implemented yet; the hook stays so an expired state can show. */
  isExpired: (req: OpenRequest, row: RequestRow) => boolean;
  /** request_ids already opened or dismissed. */
  handled: ReadonlySet<string>;
};

export type BarStatus =
  | "open" // [Open] / Dismiss
  | "not_installed" // Install…
  | "not_found_here" // Open disabled
  | "expired" // no Open
  | "args_not_allowed" // malformed for this pane, no Open
  | "unavailable" // installed but cannot be opened now (off, files changed), no Open
  | "denied_path" // the path is a protected location, no Open
  | "bad_requester"; // the requester did not match the sender, no Open

export type BarItem = {
  requestId: string;
  from: string;
  at: string;
  pane: string;
  request: OpenRequest;
  status: BarStatus;
  /** The host's own words for why Open is off, when it gave any. */
  detail?: string;
  /** For not_installed: the add-on to offer to install. */
  installTarget?: string;
};

export type RowNote =
  | { kind: "malformed"; reason: RefusalReason; detail?: string }
  | { kind: "other_machine" }
  | { kind: "unproven" };

export type RequestScan = { items: BarItem[]; notes: Map<string, RowNote> };

/** What a pane accepts in args: fileview/diffview take path (diffview also base), browser takes url. */
export function argsAllowed(target: PaneTarget, args: OpenRequest["args"], addonOpens?: AddonPaneDecl["opens"]): boolean {
  const keys = Object.keys(args);
  const only = (allowed: string[], required: string[]) => keys.every((k) => allowed.includes(k)) && required.every((k) => keys.includes(k));
  switch (target.kind) {
    case "fileview":
      return only(["path"], ["path"]);
    case "diffview":
      return only(["path", "base"], ["path"]);
    case "browser":
      return only(["url"], ["url"]);
    case "addon":
      if (addonOpens === "path") return only(["path"], ["path"]);
      if (addonOpens === "url") return only(["url"], ["url"]);
      return keys.length === 0;
  }
}

export function scanRequests(rows: RequestRow[], ctx: RequestContext): RequestScan {
  const items: BarItem[] = [];
  const notes = new Map<string, RowNote>();
  const seen = new Set<string>();
  for (const row of rows) {
    if (row.team !== ctx.team || row.to !== ctx.appUser) continue;
    const parsed = parseOpenRequest(row.body);
    if (parsed.kind === "none") continue;
    // Provenance first: a synced row never gets a bar, whatever its body says.
    if (!ctx.isLocalOrigin(row)) {
      notes.set(row.id, { kind: "other_machine" });
      continue;
    }
    if (parsed.kind === "refused") {
      notes.set(row.id, { kind: "malformed", reason: parsed.reason, detail: parsed.detail });
      continue;
    }
    const req = parsed.request;
    if (ctx.handled.has(req.requestId) || seen.has(req.requestId)) continue;
    seen.add(req.requestId);

    const item: BarItem = { requestId: req.requestId, from: row.from, at: row.created_at, pane: req.pane, request: req, status: "open" };
    const installed = ctx.installedPane(req.target);
    if (!installed) {
      item.status = "not_installed";
      item.installTarget = req.target.kind === "addon" ? `${req.target.owner}/${req.target.repo}` : undefined;
    } else if (!argsAllowed(req.target, req.args, installed === "builtin" ? undefined : installed.opens)) {
      item.status = "args_not_allowed";
    } else if (!ctx.requesterMatches(req, row)) {
      item.status = "bad_requester";
    } else if (ctx.isExpired(req, row)) {
      item.status = "expired";
    } else if (req.args.path !== undefined && !ctx.pathExists(req.args.path)) {
      item.status = "not_found_here";
    }
    items.push(item);
  }
  return { items, notes };
}

export function canOpen(item: BarItem): boolean {
  return item.status === "open";
}
