// Which remembered grants a freshly opened pane may be given again. Rust
// re-checks every replayed grant (denylist, existence) as if it were new; this
// only decides which saved rows are worth trying.

export type Saved = { permission: string; scope: string };

const trimSlash = (p: string) => (p.length > 1 ? p.replace(/\/+$/, "") : p);

/** The saved folder that covers `requested` (the same folder or one above it). With no requested path (opened from the menu) none: the person picks the folder. */
export function pickSavedRoot(saved: Saved[], requested?: string): string | undefined {
  const roots = saved.filter((g) => g.permission === "files:read").map((g) => g.scope);
  if (requested === undefined || requested === "") return undefined;
  const want = trimSlash(requested);
  return roots.find((r) => {
    const root = trimSlash(r);
    return want === root || want.startsWith(root === "/" ? "/" : `${root}/`);
  });
}

/** The saved team grant for exactly this team. */
export function pickSavedTeam(saved: Saved[], team: string): string | undefined {
  return saved.find((g) => g.permission === "messages:read" && g.scope === team)?.scope;
}

/** The saved folder grant for exactly this real path (a folder picked from the menu; a saved parent does not count). */
export function pickSavedFolder(saved: Saved[], real: string): string | undefined {
  const want = trimSlash(real);
  return saved.find((g) => g.permission === "files:read" && trimSlash(g.scope) === want)?.scope;
}

type PickSource = {
  savedGrants(id: string, pane: string): Promise<{ ok: true; value: Saved[] } | { ok: false }>;
  resolveFolder(path: string): Promise<{ ok: true; value: string } | { ok: false }>;
  grantRoot(id: number, path: string): Promise<{ ok: true; realPath: string } | { ok: false }>;
};

/**
 * A folder was picked from the menu. If it is exactly one the person saved with "Always", grant it again
 * (Rust checks it as if new) and skip the card; anything else, or any doubt, shows the card.
 * Saved grants are read now, so a Revoke done since the pane opened counts.
 */
export async function replayPickedFolder(
  source: PickSource,
  pane: { addonId: string; paneName: string; paneId: number },
  picked: string,
): Promise<{ realPath: string } | null> {
  const saved = await source.savedGrants(pane.addonId, pane.paneName);
  if (!saved.ok) return null;
  const real = await source.resolveFolder(picked);
  if (!real.ok) return null;
  const scope = pickSavedFolder(saved.value, real.value);
  if (scope === undefined) return null;
  const g = await source.grantRoot(pane.paneId, real.value);
  return g.ok ? { realPath: g.realPath } : null;
}
