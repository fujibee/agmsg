// The live source behind the add-on screens: thin wrappers over the Tauri
// commands, taking `invoke` as a parameter so the swap from mock.ts is covered
// by tests with a mocked invoke. Rust decides everything; this only maps its
// answers to what the screens show.

import type { AddonPaneDecl, EngineState, InstalledAddon, NetworkScope, Permission, StagedInstall } from "./types";
import { PERMISSIONS } from "./types";

/** addon_list's rows (camelCase JSON). Rust never returns a path. */
export type AddonInfoRaw = {
  id: string;
  kind: "builtin" | "installed" | "dev";
  source: string;
  commit: string;
  title: string;
  panes: {
    name: string;
    title: string;
    entry: string;
    permissions: string[];
    network: string;
    opens: string[];
    why: Record<string, string>;
  }[];
  digestOk: boolean;
  enabled: boolean;
  problems: string[];
};

export function parseNetwork(n: string): NetworkScope {
  if (n === "") return { kind: "none" };
  if (n === "*") return { kind: "any" };
  return { kind: "origins", origins: n.split(",").map((o) => o.trim()).filter(Boolean) };
}

type PaneRaw = { name: string; title: string; permissions: string[]; network: string; opens: string[]; why: Record<string, string> };

export function toPaneDecl(p: PaneRaw): AddonPaneDecl {
  return {
    name: p.name,
    title: p.title,
    permissions: p.permissions.filter((x): x is Permission => (PERMISSIONS as readonly string[]).includes(x)),
    network: parseNetwork(p.network),
    // A pane that opens with both path and url shows as the first; the add-on's own list is Rust's to enforce.
    opens: p.opens[0] === "path" || p.opens[0] === "url" ? p.opens[0] : "",
    why: p.why as AddonPaneDecl["why"],
  };
}

export function toInstalledAddon(r: AddonInfoRaw): InstalledAddon {
  return {
    id: r.id,
    builtin: r.kind === "builtin",
    sha: r.kind === "installed" ? r.commit : "",
    archiveSha256: "",
    payloadDigest: "",
    panes: r.panes.map(toPaneDecl),
    installedAt: "",
    enabled: r.enabled,
    digestOk: r.digestOk,
    problems: r.problems,
    ...(r.kind === "dev" ? { dev: { label: r.source, copy: r.commit } } : {}),
  };
}

/** addon_install_start / addon_check_update: what the confirm dialog is built from. */
export type ConfirmRaw = {
  stagingId: string;
  repo: string;
  sha: string;
  archiveSha256: string;
  treeDigest: string;
  panes: (PaneRaw & { entry: string; canSendWhatItReads: boolean })[];
  warnings: string[];
  files: number;
  bytes: number;
  previousSha: string | null;
  asksAgain: boolean;
  addedPermissions: string[];
  removedPermissions: string[];
  networkWidened: boolean;
  networkNewlyCombined: boolean;
  removedPanes?: string[];
  paneChanges?: { pane: string; added: string[]; removed: string[]; networkWidened: boolean; networkNewlyCombined: boolean; asksAgain: boolean }[];
};

export function toStaged(c: ConfirmRaw): StagedInstall {
  const panes = c.panes.map(toPaneDecl);
  return {
    addonId: c.repo,
    title: panes[0]?.title ?? c.repo,
    sha: c.sha,
    archiveSha256: c.archiveSha256,
    panes,
    stagingId: c.stagingId,
    ...(c.previousSha
      ? {
          from: { sha: c.previousSha, panes: [] },
          paneChanges: c.paneChanges ?? [],
          removedPanes: c.removedPanes ?? [],
          diff: {
            added: c.addedPermissions.filter((x): x is Permission => (PERMISSIONS as readonly string[]).includes(x)),
            networkWider: c.networkWidened,
            networkWithRead: c.networkNewlyCombined,
            asksAgain: c.asksAgain,
          },
        }
      : {}),
  };
}

export type InstallDone = { id: string; repo: string; sha: string; previousSha: string | null; closedPanes: number[] };
export type DevEntryRaw = { id: string; label: string; panes: string[]; copy: number };
export type SavedGrantRaw = { permission: string; scope: string; grantedAt: string };

export type Outcome<T> = { ok: true; value: T } | { ok: false; error: CommandError };

async function attempt<T>(fn: () => Promise<T>): Promise<Outcome<T>> {
  try {
    return { ok: true, value: await fn() };
  } catch (e) {
    return { ok: false, error: toCommandError(e) };
  }
}

/** What addon_pane_add returns: the frame URL and what Rust read from addon.conf. */
export type AddedPane = { id: number; url: string; port: number; commit: string; title: string; permissions: string[]; network: string };

export type Invoke = (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;

/** A refusal from Rust as the screens use it. */
export type CommandError = { code: string; message: string };

export function toCommandError(e: unknown): CommandError {
  if (typeof e === "object" && e !== null && typeof (e as CommandError).code === "string") {
    const c = e as CommandError;
    return { code: c.code, message: String(c.message ?? "") };
  }
  return { code: "error", message: typeof e === "string" ? e : String((e as Error)?.message ?? e) };
}

export type GrantRootResult = { ok: true; realPath: string } | { ok: false; error: CommandError };

export function createLiveSource(invoke: Invoke) {
  return {
    /** addon_gate_status → the engine state; a failure to ask counts as off, with the reason. */
    async engine(): Promise<EngineState> {
      try {
        const g = (await invoke("addon_gate_status")) as { enabled: boolean; reasons: string[] };
        return g.enabled ? { ok: true } : { ok: false, reasons: g.reasons };
      } catch (e) {
        return { ok: false, reasons: [toCommandError(e).message] };
      }
    },
    async list(): Promise<InstalledAddon[]> {
      return ((await invoke("addon_list")) as AddonInfoRaw[]).map(toInstalledAddon);
    },
    /** Rust resolves the pinned directory, checks its digest and builds the grants itself; a refusal is a string. */
    async addPane(spec: { addonId: string; pane: string; openArgs: { path?: string; url?: string; base?: string } }): Promise<AddedPane> {
      return (await invoke("addon_pane_add", { spec })) as AddedPane;
    },
    installStart: (source: string, opId: string) =>
      attempt(async () => toStaged((await invoke("addon_install_start", { spec: { source, opId } })) as ConfirmRaw)),
    checkUpdate: (id: string, opId: string) =>
      attempt(async () => toStaged((await invoke("addon_check_update", { spec: { id, opId } })) as ConfirmRaw)),
    installConfirm: (stagingId: string) => attempt(async () => (await invoke("addon_install_confirm", { spec: { stagingId } })) as InstallDone),
    installCancel: (stagingId: string) => attempt(async () => void (await invoke("addon_install_cancel", { spec: { stagingId } }))),
    remove: (id: string) => attempt(async () => void (await invoke("addon_remove", { spec: { id } }))),
    devLoad: (path: string) => attempt(async () => (await invoke("addon_dev_load", { spec: { path } })) as DevEntryRaw),
    devRemove: (id: string) => attempt(async () => void (await invoke("addon_dev_remove", { spec: { id } }))),
    savedGrants: (id: string, pane: string) =>
      attempt(async () => (await invoke("addon_saved_grants", { spec: { id, pane } })) as SavedGrantRaw[]),
    /** Remember a grant the user just gave: bound to the pane instance they clicked Allow in and the commit it runs, so Rust refuses it if either changed. */
    saveGrant: (id: string, pane: string, permission: "files:read" | "messages:read", scope: string, paneId: number, commit: string) =>
      attempt(async () => void (await invoke("addon_save_grant", { spec: { id, pane, permission, scope, paneId, commit } }))),
    forgetGrant: (id: string, pane: string, permission: string, scope: string) =>
      attempt(async () => (await invoke("addon_forget_grant", { spec: { id, pane, permission, scope } })) as { forgotten: boolean; closedPanes: number[] }),
    async removePane(id: number): Promise<void> {
      await invoke("addon_pane_remove", { id });
    },
    async grantTeam(id: number, team: string): Promise<{ ok: true } | { ok: false; error: CommandError }> {
      try {
        await invoke("addon_grant_team", { id, team });
        return { ok: true };
      } catch (e) {
        return { ok: false, error: toCommandError(e) };
      }
    },
    async grantRoot(id: number, path: string): Promise<GrantRootResult> {
      try {
        return { ok: true, realPath: (await invoke("addon_grant_root", { id, path })) as string };
      } catch (e) {
        return { ok: false, error: toCommandError(e) };
      }
    },
    async revokeTeam(id: number): Promise<void> {
      await invoke("addon_revoke_team", { id });
    },
    async revokeRoot(id: number): Promise<void> {
      await invoke("addon_revoke_root", { id });
    },
  };
}

export type LiveSource = ReturnType<typeof createLiveSource>;
