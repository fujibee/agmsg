import type { Grant, InstalledAddon } from "./types";
import type { Outcome, SavedGrantRaw } from "./source";

/** The remembered grants of every add-on that keeps them: built-ins and installed ones (a developer copy never saves any). */
export async function collectSavedGrants(
  addons: InstalledAddon[],
  savedGrants: (id: string, pane: string) => Promise<Outcome<SavedGrantRaw[]>>,
): Promise<{ grants: Grant[]; failure: string | null }> {
  const grants: Grant[] = [];
  let failure: string | null = null;
  for (const a of addons) {
    if (a.dev) continue;
    for (const p of a.panes) {
      const r = await savedGrants(a.id, p.name);
      if (!r.ok) {
        failure ??= r.error.message;
        continue;
      }
      for (const g of r.value)
        if (g.permission === "files:read" || g.permission === "messages:read")
          grants.push({ addonId: a.id, pane: p.name, permission: g.permission, scope: g.scope, remember: true, grantedAt: g.grantedAt });
    }
  }
  return { grants, failure };
}
