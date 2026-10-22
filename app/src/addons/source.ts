// The live source behind the add-on screens: thin wrappers over the Tauri
// commands, taking `invoke` as a parameter so the swap from mock.ts is covered
// by tests with a mocked invoke. Rust decides everything; this only maps its
// answers to what the screens show. addon_list (installed and built-in
// add-ons) is not here yet: it lands with the Rust side and joins this file.

import type { EngineState } from "./types";

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
    async addPane(spec: { addon: string; name: string; openArgs: { path?: string; url?: string; base?: string } }) {
      return (await invoke("addon_pane_add", { spec })) as { id: number; url: string; port: number };
    },
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
