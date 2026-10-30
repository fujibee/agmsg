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

/** Where a copied instruction cannot be built, and why (said to the person at the Copy button). */
export type SeatTextFailure = "noTeam" | "noAppUser" | "noScripts";

/** Single-quotes a word for bash; a quote inside it is closed, escaped and reopened. */
export function shellQuote(word: string): string {
  return `'${word.replace(/'/g, `'\\''`)}'`;
}

/** A folder path in a form bash accepts: a Windows path (C:\\Users\\me or \\\\host\\share) gets forward slashes, which Git Bash reads; others are left as they are. */
export function bashPath(p: string): string {
  const trimmed = p.replace(/[\\/]+$/, "");
  return /^[A-Za-z]:[\\/]/.test(trimmed) || trimmed.startsWith("\\\\") ? trimmed.replace(/\\/g, "/") : trimmed;
}

/** The ready-to-run send command for one team: every word that came from outside is quoted, so spaces and quotes cannot split it. */
export function sendCommand(seat: { team: string; appUser: string; scriptsDir: string }): string {
  const script = `${bashPath(seat.scriptsDir)}/send.sh`;
  const body = "agmsg-app open builtin:fileview fileview path=/absolute/path/to/folder";
  return ["bash", shellQuote(script), shellQuote(seat.team), "'<your seat name>'", shellQuote(seat.appUser), shellQuote(body)].join(" ");
}

/**
 * What the "copy instructions for agents" button copies: the request line, and the send command for it
 * with this team, its app user and the scripts folder the app really uses already filled in.
 * Without a team, an app user in it, or the scripts folder there is nothing true to copy, so it says why instead.
 */
export function seatInstruction(
  t: (key: string, o?: Record<string, unknown>) => string,
  seat: { team: string; appUser: string; scriptsDir: string },
): { ok: true; text: string } | { ok: false; reason: SeatTextFailure } {
  if (!seat.team) return { ok: false, reason: "noTeam" };
  if (!seat.appUser) return { ok: false, reason: "noAppUser" };
  if (!seat.scriptsDir) return { ok: false, reason: "noScripts" };
  return { ok: true, text: t("addons.openRequests.seatText", { team: seat.team, appUser: seat.appUser, command: sendCommand(seat) }) };
}
