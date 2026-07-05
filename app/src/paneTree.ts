// A tab's pane arrangement as a binary split tree, replacing the old flat
// `paneIds: string[]` + `layout: "vertical"|"horizontal"|"tile"` enum (see
// design doc, issue #317). Every function here is pure — no React state, no
// DOM, no Tauri APIs — so App.tsx only calls these and stores the resulting
// tree; it doesn't contain any tree-shape logic of its own. That separation
// is what makes this testable without a rendered component or a webview.
//
// Immutability convention used throughout: a function returns the SAME node
// reference when nothing changed in that subtree, and only allocates a new
// object on the path from the root to an actual change. Several functions
// below (spliceOutLeaf, swapLeaves, renameLeaf) rely on that reference
// equality to detect "was this the subtree that changed" without threading
// an extra found-flag through the recursion.

export type SplitAxis = "row" | "col";

export type SplitNode =
  | { kind: "leaf"; paneId: string }
  | { kind: "split"; axis: SplitAxis; ratio: number; a: SplitNode; b: SplitNode };

export type PaneRect = { left: number; top: number; width: number; height: number };

export type DropSide = "top" | "bottom" | "left" | "right";
export type DropZone = { kind: "swap" } | { kind: "split"; side: DropSide };

function leaf(paneId: string): SplitNode {
  return { kind: "leaf", paneId };
}

/** In-order leaf traversal — "which panes are in this tab", ignoring arrangement. */
export function leaves(node: SplitNode): string[] {
  if (node.kind === "leaf") return [node.paneId];
  return [...leaves(node.a), ...leaves(node.b)];
}

const FULL_RECT: PaneRect = { left: 0, top: 0, width: 100, height: 100 };

/** Walks the tree, splitting `rect` at each node's axis/ratio, returning every leaf's rect. */
export function computeRects(node: SplitNode, rect: PaneRect = FULL_RECT): Map<string, PaneRect> {
  if (node.kind === "leaf") return new Map([[node.paneId, rect]]);
  const { axis, ratio, a, b } = node;
  let rectA: PaneRect;
  let rectB: PaneRect;
  if (axis === "col") {
    const aWidth = rect.width * ratio;
    rectA = { ...rect, width: aWidth };
    rectB = { ...rect, left: rect.left + aWidth, width: rect.width - aWidth };
  } else {
    const aHeight = rect.height * ratio;
    rectA = { ...rect, height: aHeight };
    rectB = { ...rect, top: rect.top + aHeight, height: rect.height - aHeight };
  }
  const rectsA = computeRects(a, rectA);
  const rectsB = computeRects(b, rectB);
  return new Map([...rectsA, ...rectsB]);
}

/**
 * Removes a leaf, collapsing its parent (the sibling is promoted up to take
 * the parent's own place). Returns `null` if `node` itself was just that one
 * leaf (caller should close the window/tab, same as today when `paneIds`
 * empties). Returns `node` unchanged (same reference) if `paneId` isn't
 * found anywhere in this tree.
 */
export function spliceOutLeaf(node: SplitNode, paneId: string): SplitNode | null {
  if (node.kind === "leaf") {
    return node.paneId === paneId ? null : node;
  }
  const resultA = spliceOutLeaf(node.a, paneId);
  if (resultA === null) return node.b;
  if (resultA !== node.a) return { ...node, a: resultA };
  const resultB = spliceOutLeaf(node.b, paneId);
  if (resultB === null) return node.a;
  if (resultB !== node.b) return { ...node, b: resultB };
  return node;
}

function replaceLeaf(node: SplitNode, paneId: string, replacement: SplitNode): SplitNode {
  if (node.kind === "leaf") {
    return node.paneId === paneId ? replacement : node;
  }
  const a = replaceLeaf(node.a, paneId, replacement);
  if (a !== node.a) return { ...node, a };
  const b = replaceLeaf(node.b, paneId, replacement);
  if (b !== node.b) return { ...node, b };
  return node;
}

function contains(node: SplitNode, paneId: string): boolean {
  if (node.kind === "leaf") return node.paneId === paneId;
  return contains(node.a, paneId) || contains(node.b, paneId);
}

/**
 * Directional split-drop: replaces the `targetPaneId` leaf with a new split
 * node — `newPaneId` on the side the drop indicated, the target's existing
 * pane on the other side.
 *
 * If `newPaneId` is already present in `node` (the common same-window drag
 * case), it's spliced out FIRST, and `targetPaneId` is then re-located BY
 * PANE ID in the resulting (post-splice) tree — not by any path captured
 * before the splice. This matters when the target is the dragged pane's
 * sibling: splicing collapses their shared parent and promotes the sibling
 * to a new position, so a path captured beforehand would point at the wrong
 * node afterward. Searching fresh, post-splice, sidesteps that entirely.
 *
 * If `newPaneId` is NOT present (e.g. the caller already spliced it out of
 * another window's tree for a cross-window drop), it's inserted directly.
 *
 * Self-drop (`targetPaneId === newPaneId`) is a no-op: the target IS the
 * dragged pane, so there is nothing to move.
 *
 * A missing `targetPaneId` (not found anywhere in `node`) is also a no-op,
 * returning `node` unchanged (co1 review — was missing): without this
 * guard, splicing `newPaneId` out first and then failing to find
 * `targetPaneId` to replace would silently drop the dragged pane from the
 * tree entirely, since `replaceLeaf` is itself a no-op when the target
 * isn't found, but by then `newPaneId` has already been removed. Checked
 * against the ORIGINAL tree, before any splicing — splicing `newPaneId`
 * out never removes or moves an unrelated `targetPaneId` leaf, so its
 * presence there is equivalent to its presence in the post-splice tree.
 */
export function insertBeside(
  node: SplitNode,
  targetPaneId: string,
  side: DropSide,
  newPaneId: string,
): SplitNode {
  if (targetPaneId === newPaneId) return node;
  if (!contains(node, targetPaneId)) return node;

  const base = contains(node, newPaneId) ? (spliceOutLeaf(node, newPaneId) ?? node) : node;
  const axis: SplitAxis = side === "top" || side === "bottom" ? "row" : "col";
  const newIsFirst = side === "top" || side === "left";
  const replacement: SplitNode = {
    kind: "split",
    axis,
    ratio: 0.5,
    a: newIsFirst ? leaf(newPaneId) : leaf(targetPaneId),
    b: newIsFirst ? leaf(targetPaneId) : leaf(newPaneId),
  };
  return replaceLeaf(base, targetPaneId, replacement);
}

/**
 * Appends `newPaneId` as a new rightmost column, giving it 1/n of the total
 * width (n = leaf count after insertion) and uniformly compressing the
 * existing tree's share to (n-1)/n — matching today's "adding a pane evenly
 * redistributes all columns" behavior, rather than handing the new pane
 * half the screen.
 */
export function insertAsNewLeaf(node: SplitNode, newPaneId: string): SplitNode {
  const n = leaves(node).length + 1;
  return { kind: "split", axis: "col", ratio: (n - 1) / n, a: node, b: leaf(newPaneId) };
}

/**
 * Renames a single leaf's paneId in place — the cross-window swap building
 * block (see the design doc: cross-window swap is two independent
 * `renameLeaf` calls, one per tree, each renaming the OTHER tree's pane in).
 *
 * Only safe when `newId` isn't already present in `node` — callers must
 * apply at most one `renameLeaf` per tree (which is exactly what
 * cross-window swap does: `oldId`/`newId` each live in a different tree, so
 * neither call's `newId` can already be present in the tree it's applied
 * to). Calling this with a `newId` that already exists in `node` would
 * silently create two leaves sharing one paneId.
 */
export function renameLeaf(node: SplitNode, oldId: string, newId: string): SplitNode {
  if (node.kind === "leaf") {
    return node.paneId === oldId ? { ...node, paneId: newId } : node;
  }
  const a = renameLeaf(node.a, oldId, newId);
  const b = renameLeaf(node.b, oldId, newId);
  if (a === node.a && b === node.b) return node;
  return { ...node, a, b };
}

/** Exchanges two leaves' paneIds within the SAME tree (tree shape unchanged). */
export function swapLeaves(node: SplitNode, idA: string, idB: string): SplitNode {
  if (node.kind === "leaf") {
    if (node.paneId === idA) return { ...node, paneId: idB };
    if (node.paneId === idB) return { ...node, paneId: idA };
    return node;
  }
  const a = swapLeaves(node.a, idA, idB);
  const b = swapLeaves(node.b, idA, idB);
  if (a === node.a && b === node.b) return node;
  return { ...node, a, b };
}

function chainNodes(axis: SplitAxis, nodes: SplitNode[]): SplitNode {
  if (nodes.length === 1) return nodes[0];
  return { kind: "split", axis, ratio: 1 / nodes.length, a: nodes[0], b: chainNodes(axis, nodes.slice(1)) };
}

// Row sizes for the "tile" preset — same grouping as the pre-tree
// tileRowSizes in App.tsx: n=1→[1], 2→[2], 3→[2,1], 4→[2,2], 5→[3,2], ...
function tileRowSizes(n: number): number[] {
  const rows = n <= 2 ? 1 : Math.max(2, Math.ceil(n / 4));
  const base = Math.floor(n / rows);
  const extra = n % rows;
  return Array.from({ length: rows }, (_, i) => base + (i < extra ? 1 : 0));
}

/**
 * Discards whatever tree currently exists and rebuilds a fresh canonical
 * tree for `preset` from `paneIds` — a one-shot RESET, not a persisted mode
 * (confirmed with koit: picking Vertical/Horizontal/Tile from the menu just
 * re-arranges the tab back to that pattern; it doesn't lock out further
 * manual divider drags or split-drops afterward).
 */
export function presetTree(preset: "vertical" | "horizontal" | "tile", paneIds: string[]): SplitNode {
  if (paneIds.length === 0) throw new Error("presetTree requires at least one pane");
  if (paneIds.length === 1) return leaf(paneIds[0]);
  if (preset === "vertical") return chainNodes("col", paneIds.map(leaf));
  if (preset === "horizontal") return chainNodes("row", paneIds.map(leaf));
  // tile: equal-height rows, each row an equal-width chain of its own panes.
  const rows = tileRowSizes(paneIds.length);
  let idx = 0;
  const rowNodes = rows.map((size) => {
    const rowIds = paneIds.slice(idx, idx + size);
    idx += size;
    return chainNodes("col", rowIds.map(leaf));
  });
  return chainNodes("row", rowNodes);
}

function band(frac: number): 0 | 1 | 2 | 3 {
  return Math.min(3, Math.max(0, Math.floor(frac * 4))) as 0 | 1 | 2 | 3;
}

/**
 * Classifies a drop position (fraction of the target pane's own rendered
 * rect, 0–1 on each axis) into the 16-zone rule: divide each axis into 4
 * bands and call band 0/3 "outer", 1/2 "inner". Corner (outer×outer) and
 * center (inner×inner) both mean swap; an edge (exactly one axis outer)
 * means directional split-replace on that edge.
 */
export function classifyDrop(xFrac: number, yFrac: number): DropZone {
  const col = band(xFrac);
  const row = band(yFrac);
  const rowOuter = row === 0 || row === 3;
  const colOuter = col === 0 || col === 3;
  if (rowOuter === colOuter) return { kind: "swap" }; // corner or center
  if (rowOuter) return { kind: "split", side: row === 0 ? "top" : "bottom" };
  return { kind: "split", side: col === 0 ? "left" : "right" };
}

/**
 * Converts a minimum-pixel divider constraint into a ratio bound against a
 * node's own CURRENT rendered size in px (not a flat percent — a flat
 * percent clamp still compounds under nesting: two nested 10%-clamped
 * splits can produce a pane as small as 1% of the screen).
 */
export function minRatioForPx(minPx: number, totalPx: number): number {
  if (totalPx <= 0) return 0.5;
  return Math.min(0.5, minPx / totalPx);
}

export function clampRatio(ratio: number, minPx: number, totalPx: number): number {
  const min = minRatioForPx(minPx, totalPx);
  return Math.min(1 - min, Math.max(min, ratio));
}
