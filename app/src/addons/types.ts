// Shared types for the add-on screens. The protocol types (what an add-on and
// the broker exchange) come from the author kit unchanged; the rest is the
// app-side data the Settings screens and the pane read, shaped like the Rust
// records in the design (index.tsv / grants.tsv, the addon.conf fields).

export type * from "../../addon-kit/protocol";
import type { PermissionDiff } from "./model";
import type { ErrorCode } from "../../addon-kit/protocol";

export type Permission = "messages:read" | "files:read" | "git:read" | "network" | "team:join" | "messages:send" | "agents:spawn";

export const PERMISSIONS: readonly Permission[] = ["messages:read", "files:read", "git:read", "network", "team:join", "messages:send", "agents:spawn"];

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
  /** Live list only: the files on disk match what was pinned. False means it cannot be opened. */
  digestOk?: boolean;
  /** Live list only: panes whose addon.conf was refused, in the words `check` uses. */
  problems?: string[];
  /** A developer copy loaded from a folder (`dev:<slug>`): `label` is the folder name for the DEV badge. */
  dev?: { label: string; copy: string };
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
  | { code: "already_installed"; sha: string }
  /** Rust's own words for a failure of the install table (live installs); shown as they are. */
  | { code: "message"; message: string };

export type UnsafeEntryKind = "symlink" | "hardlink" | "outside_path" | "reserved_name";

/** The grant a pane is waiting for (S6). */
export type GrantNeed =
  | { permission: "messages:read"; team: string; why?: string }
  | { permission: "files:read"; path: string; fileCount: number | null; denied: boolean; why?: string };

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
  | { code: "revoked"; permission: Exclude<Permission, "network">; scope: string }
  /** Rust refused to open the pane (gate off, unknown add-on, bad conf); its words are shown as they are. */
  | { code: "open_failed"; message: string }
  | { code: "init_too_large" }
  /** Rust closed the pane because its files changed after it was opened (addon-pane-failed); `reason` is its words. */
  | { code: "pane_closed"; reason: string };

/** A grant chip in the pane header. */
/** One thing allowed for the pane, shown in its header; `note` is an extra line about it (a `.env` file in the folder). */
export type GrantChip = { key: string; label: string; note?: string };

/** The broker's refusal codes, so a card can name one. */
export type BrokerErrorCode = ErrorCode;

/** What a tab's `Pane` (kind "addon") carries: which add-on pane it shows. */
export type AddonPaneRef = {
  addonId: string;
  paneName: string;
  title: string;
  askedBy?: string;
  /** What the pane was opened with (a request's args, or the folder picked). */
  openArgs?: { path?: string; url?: string; base?: string };
};

/** What the confirm dialog (S3 install, S8 update) is built from: the staged files. */
export type StagedInstall = {
  addonId: string;
  title: string;
  sha: string;
  archiveSha256: string;
  panes: AddonPaneDecl[];
  /** Set for an update: the commit being replaced and its panes, so the dialog can show the difference. */
  from?: { sha: string; panes: AddonPaneDecl[] };
  /** Live updates: Rust's own answer to "does this ask again", used instead of comparing panes here. */
  diff?: PermissionDiff;
  /** Live: names the staged files in Rust (confirm / cancel by this id). */
  stagingId?: string;
  /** Live updates: what each pane gains or loses (Rust decides per pane), and the panes the new version no longer has. */
  paneChanges?: PaneChange[];
  removedPanes?: string[];
};

export type PaneChange = {
  pane: string;
  added: string[];
  removed: string[];
  networkWidened: boolean;
  networkNewlyCombined: boolean;
  asksAgain: boolean;
};

/** S2: where a fetch is. */
export type FetchProgress =
  | { step: "resolving"; sha?: string }
  | { step: "downloading"; doneMb?: number; totalMb?: number }
  | { step: "checking"; files?: number; sizeMb?: number };
