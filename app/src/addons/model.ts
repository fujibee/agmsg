// Pure helpers for the add-on screens: the text keys and parameters for each
// state, so the components stay thin and the decisions are testable without
// rendering. Strings themselves live in the locale files under `addons.*`.

import { PERMISSIONS } from "./types";
import type { AddonPaneDecl, Grant, InstallError, InstalledAddon, NetworkScope, Permission } from "./types";

export type Translate = (key: string, options?: Record<string, unknown>) => string;

export function shortSha(sha: string): string {
  return sha.slice(0, 7);
}

const PERMISSION_KEY: Record<Exclude<Permission, "network">, string> = {
  "messages:read": "messagesRead",
  "files:read": "filesRead",
  "git:read": "gitRead",
  "team:join": "teamJoin",
  "messages:send": "messagesSend",
  "agents:spawn": "agentsSpawn",
};

/** The plain-words row for one declared permission in the dialogs. */
export function permissionRow(p: Permission, network: NetworkScope): { key: string; params: Record<string, string> } {
  if (p === "network") {
    if (network.kind === "any") return { key: "addons.permission.networkAny", params: {} };
    const hosts = network.kind === "origins" ? network.origins.map(originHost).join(", ") : "";
    return { key: "addons.permission.network", params: { hosts } };
  }
  return { key: `addons.permission.${PERMISSION_KEY[p]}`, params: {} };
}

function originHost(origin: string): string {
  return origin.replace(/^https?:\/\//, "");
}

/** All permissions an add-on's panes declare, in the fixed order, without repeats. */
export function declaredPermissions(addon: InstalledAddon): Permission[] {
  const set = new Set<Permission>();
  for (const pane of addon.panes) for (const p of pane.permissions) set.add(p);
  return PERMISSIONS.filter((p) => set.has(p));
}

/** The network scope of an add-on: the widest one any of its panes declares. */
export function addonNetwork(addon: InstalledAddon): NetworkScope {
  let origins: string[] = [];
  for (const pane of addon.panes) {
    if (pane.network.kind === "any") return { kind: "any" };
    if (pane.network.kind === "origins") origins = [...new Set([...origins, ...pane.network.origins])];
  }
  return origins.length ? { kind: "origins", origins } : { kind: "none" };
}

/** True when the add-on talks to or starts agents, which work with their own permissions (the dialog says so in a second block). */
export function reachesAgents(perms: Iterable<Permission>): { send: boolean; spawn: boolean } {
  const set = new Set(perms);
  return { send: set.has("messages:send"), spawn: set.has("agents:spawn") };
}

/** True when a read permission and `network` are declared together (the dialog then says it can send what it reads). */
export function canSendWhatItReads(pane: Pick<AddonPaneDecl, "permissions">): boolean {
  const has = (p: Permission) => pane.permissions.includes(p);
  return has("network") && (has("messages:read") || has("files:read") || has("git:read"));
}

export function grantsOf(grants: Grant[], addonId: string): Grant[] {
  return grants.filter((g) => g.addonId === addonId);
}

const GRANT_KEY = {
  "messages:read": "addons.grant.messages",
  "files:read": "addons.grant.files",
  "team:join": "addons.grant.join",
  "messages:send": "addons.grant.send",
  "agents:spawn": "addons.grant.spawn",
} as const;

/** "Reads messages: team-a" / "Reads files: ~/proj (remembered)". */
export function grantText(t: Translate, g: Grant): string {
  const key = GRANT_KEY[g.permission as keyof typeof GRANT_KEY] ?? "addons.grant.files";
  const base = t(key, { scope: g.scope });
  return g.remember && g.permission === "files:read" ? `${base} ${t("addons.grant.remembered")}` : base;
}

/** The key and parameters of an inline install error (the install-failure table). */
export function installErrorText(e: InstallError): { key: string; params: Record<string, string | number> } {
  const key = `addons.installError.${e.code}`;
  switch (e.code) {
    case "repo_not_found":
      return { key, params: { owner: e.owner, repo: e.repo } };
    case "ref_not_found":
      return { key, params: { repo: e.repo, ref: e.ref } };
    case "no_app_panes":
      return { key, params: { repo: e.repo } };
    case "conf_invalid":
      return { key, params: { pane: e.pane, line: e.line, problem: e.problem } };
    case "entry_missing":
      return { key, params: { pane: e.pane, entry: e.entry } };
    case "min_app":
      return { key, params: { minApp: e.minApp, appVersion: e.appVersion } };
    case "protocol_unknown":
      return { key, params: { protocol: e.protocol } };
    case "too_large":
      return { key, params: { measured: e.measured, limit: e.limit, largest: e.largestFile } };
    case "unsafe_entry":
      return { key: `${key}.${e.what}`, params: { path: e.path } };
    case "github_error":
      return { key, params: { status: e.status } };
    case "rate_limited":
      return { key, params: { time: e.retryAfter } };
    case "already_installed":
      return { key, params: { sha: e.sha } };
    case "message":
      return { key, params: { message: e.message } };
  }
}

/** Validates the `owner/repo[@ref]` field. null = not valid yet (Install stays disabled). */
export function parseRepoInput(raw: string): { owner: string; repo: string; ref: string | null } | null {
  const m = /^([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\/([A-Za-z0-9._-]{1,100})(?:@([^\s@]{1,200}))?$/.exec(raw.trim());
  if (!m) return null;
  if (m[2] === "." || m[2] === "..") return null;
  return { owner: m[1], repo: m[2], ref: m[3] ?? null };
}

/** The chips in a pane header: one per active grant, plus the network scope. */
export function grantChips(
  grants: Pick<Grant, "permission" | "scope">[],
  network: NetworkScope,
  t: Translate,
): { key: string; label: string }[] {
  const chips = grants.map((g) => ({ key: `${g.permission}:${g.scope}`, label: g.scope }));
  if (network.kind === "any") chips.push({ key: "network:*", label: t("addons.pane.networkAnyChip") });
  else if (network.kind === "origins")
    chips.push({ key: "network", label: t("addons.pane.networkChip", { hosts: network.origins.map(originHost).join(", ") }) });
  return chips;
}

export type PermissionDiff = {
  /** Permissions the new version declares that the old one did not. */
  added: Permission[];
  /** The network list got wider (any site, or an origin that was not there). */
  networkWider: boolean;
  /** `network` is now declared together with a read permission it was not combined with before. */
  networkWithRead: boolean;
  /** True when anything above means the grants of the changed permissions are cleared and the user is asked again. */
  asksAgain: boolean;
};

function paneParts(p: AddonPaneDecl): { perms: Set<Permission>; origins: string[]; any: boolean } {
  return {
    perms: new Set(p.permissions),
    origins: p.network.kind === "origins" ? p.network.origins : [],
    any: p.network.kind === "any",
  };
}

const READS: Permission[] = ["messages:read", "files:read", "git:read"];
const combined = (perms: Set<Permission>) => perms.has("network") && READS.some((r) => perms.has(r));

/**
 * S8: what an update changes in the permissions (design §2, "Update"). Compared
 * per pane (by name), then aggregated for the dialog: a capability one pane
 * gains is not hidden because another pane already had it. A pane that is new
 * counts as entirely added.
 */
export function permissionDiff(oldPanes: AddonPaneDecl[], newPanes: AddonPaneDecl[]): PermissionDiff {
  const added = new Set<Permission>();
  let networkWider = false;
  let networkWithRead = false;
  for (const np of newPanes) {
    const n = paneParts(np);
    const op = oldPanes.find((x) => x.name === np.name);
    const o = op ? paneParts(op) : { perms: new Set<Permission>(), origins: [] as string[], any: false };
    for (const p of n.perms) if (!o.perms.has(p)) added.add(p);
    // Wider: any site where it was not any site; or an origin that was not allowed before (any site already covers every origin).
    const wider = n.any ? !o.any : !o.any && n.origins.some((x) => !o.origins.includes(x));
    if (wider) networkWider = true;
    if (combined(n.perms) && !combined(o.perms)) networkWithRead = true;
  }
  const list = PERMISSIONS.filter((p) => added.has(p));
  return { added: list, networkWider, networkWithRead, asksAgain: list.length > 0 || networkWider || networkWithRead };
}
