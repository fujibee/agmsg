// Which remembered grants a freshly opened pane may be given again. Rust
// re-checks every replayed grant (denylist, existence) as if it were new; this
// only decides which saved rows are worth trying.

export type Saved = { permission: string; scope: string };

const trimSlash = (p: string) => (p.length > 1 ? p.replace(/\/+$/, "") : p);

/** The saved folder that covers `requested` (the same folder or one above it); with no requested path, the first saved folder. */
export function pickSavedRoot(saved: Saved[], requested?: string): string | undefined {
  const roots = saved.filter((g) => g.permission === "files:read").map((g) => g.scope);
  if (requested === undefined || requested === "") return roots[0];
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
