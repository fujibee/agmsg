// Shared types for the add-on screens. The protocol types (what an add-on and
// the broker exchange) come from the author kit unchanged; the rest is the
// app-side data the Settings screens and the pane read, shaped like the Rust
// records in the design (index.tsv / grants.tsv, the addon.conf fields).

export type * from "../../addon-kit/protocol";
import type { ErrorCode } from "../../addon-kit/protocol";

export type Permission = "messages:read" | "files:read" | "git:read" | "network";

export const PERMISSIONS: readonly Permission[] = ["messages:read", "files:read", "git:read", "network"];

/** `network` in addon.conf: nothing, any site (`*`), or a list of https origins. */
export type NetworkScope = { kind: "none" } | { kind: "any" } | { kind: "origins"; origins: string[] };

/** One pane an add-on adds (an app-panes/<name>/addon.conf). */
export type AddonPaneDecl = {
  name: string;
  title: string;
  permissions: Permission[];
  network: NetworkScope;
  /** What the pane is opened with. */
  opens: "path" | "url" | "";
  /** The author's one line per permission, shown in the dialogs. */
  why: Partial<Record<Permission, string>>;
};

/** A row of index.tsv, plus whether it ships inside the app. */
export type InstalledAddon = {
  /** `owner/repo`, or the built-in's name. */
  id: string;
  builtin: boolean;
  sha: string;
  archiveSha256: string;
  payloadDigest: string;
  panes: AddonPaneDecl[];
  installedAt: string;
  enabled: boolean;
};

/** A row of grants.tsv. `scope` is a stable team id for messages:read, a real path for files:read. */
export type Grant = {
  addonId: string;
  pane: string;
  permission: Exclude<Permission, "network">;
  scope: string;
  remember: boolean;
  grantedAt: string;
};

/** What the Settings screen reads. */
export type AddonsSnapshot = {
  addons: InstalledAddon[];
  grants: Grant[];
  /** Settings → Add-ons → Open requests from seats. */
  openRequests: "show" | "off";
};

/** Why add-ons are off on this computer (the engine check did not pass). */
/** addon_gate_status(): `reasons` are already plain English from the Rust side. */
export type EngineState = { ok: true } | { ok: false; reasons: string[] };

/** The install-failure table, one case per row. */
export type InstallError =
  | { code: "repo_not_found"; owner: string; repo: string }
  | { code: "ref_not_found"; repo: string; ref: string }
  | { code: "no_app_panes"; repo: string }
  | { code: "conf_invalid"; pane: string; line: number; problem: string }
  | { code: "entry_missing"; pane: string; entry: string }
  | { code: "min_app"; minApp: string; appVersion: string }
  | { code: "protocol_unknown"; protocol: number }
  | { code: "too_large"; measured: string; limit: string; largestFile: string }
  | { code: "unsafe_entry"; what: UnsafeEntryKind; path: string }
  | { code: "github_error"; status: number }
  | { code: "rate_limited"; retryAfter: string }
  | { code: "already_installed"; sha: string };

export type UnsafeEntryKind = "symlink" | "hardlink" | "outside_path" | "reserved_name";

/** The grant a pane is waiting for (S6). */
export type GrantNeed =
  | { permission: "messages:read"; team: string }
  | { permission: "files:read"; path: string; fileCount: number | null; denied: boolean };

/** What an open pane shows instead of (or before) its frame. */
export type PaneState =
  | { kind: "grant"; need: GrantNeed }
  | { kind: "failure"; failure: PaneFailure }
  | { kind: "frame" };

/** The in-pane failure table. */
export type PaneFailure =
  | { code: "digest_mismatch" }
  | { code: "load_timeout" }
  | { code: "path_missing"; path: string }
  | { code: "revoked"; permission: Exclude<Permission, "network">; scope: string };

/** A grant chip in the pane header. */
export type GrantChip = { key: string; label: string };

/** The broker's refusal codes, so a card can name one. */
export type BrokerErrorCode = ErrorCode;
