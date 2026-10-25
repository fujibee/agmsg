// What the S10 bar shows for the open requests a seat sent as ordinary
// messages (design §7). The host reads the messages and decides every verdict;
// these are only the shapes the screens draw. Nothing here parses a message.

export type BarStatus =
  | "open" // [Open] / Dismiss
  | "not_installed" // Install…
  | "not_found_here" // the path is not on this computer, no Open
  | "args_not_allowed" // the request does not match what the pane opens with, no Open
  | "unavailable" // installed but cannot be opened now (off, files changed), no Open
  | "denied_path"; // the path is a protected location, no Open

export type BarItem = {
  /** `<message id>:<line index>`: one line of one message. */
  requestId: string;
  from: string;
  team: string;
  at: string;
  addonId: string;
  pane: string;
  path?: string;
  status: BarStatus;
  /** The host's own words for why Open is off, when it gave any. */
  detail?: string;
  /** For not_installed: the add-on to offer to install. */
  installTarget?: string;
};

/** A line that starts like a request but cannot be read: shown with the reason, no Open, can be dismissed. */
export type RowNote = { kind: "malformed"; reason: string; detail?: string };

export type RequestScan = { items: BarItem[]; notes: Map<string, RowNote> };

export function canOpen(item: BarItem): boolean {
  return item.status === "open";
}
