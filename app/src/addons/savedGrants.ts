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

/** Which team powers were remembered for exactly this team. */
export function pickSavedPowers(saved: Saved[], team: string): { join: boolean; send: boolean; spawn: boolean } {
  const has = (p: string) => saved.some((g) => g.permission === p && g.scope === team);
  return { join: has("team:join"), send: has("messages:send"), spawn: has("agents:spawn") };
}

type PowerSource = {
  grantTeam(id: number, team: string): Promise<{ ok: boolean }>;
  setPower(id: number, power: "team:join" | "messages:send" | "agents:spawn", on: boolean): Promise<{ ok: boolean }>;
};

/**
 * A reopened pane declares `powers`. If every one was remembered for exactly this team, grant the team and set each
 * power again (Rust re-checks them as if new) so the card is not asked twice; anything missing, or any failure, asks.
 */
export async function replaySavedPowers(
  source: PowerSource,
  paneId: number,
  team: string,
  powers: ("team:join" | "messages:send" | "agents:spawn")[],
  saved: Saved[],
): Promise<boolean> {
  const have = pickSavedPowers(saved, team);
  if (!powers.every((p) => (p === "team:join" ? have.join : p === "messages:send" ? have.send : have.spawn))) return false;
  if (!(await source.grantTeam(paneId, team)).ok) return false;
  for (const p of powers) if (!(await source.setPower(paneId, p, true)).ok) return false;
  return true;
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
