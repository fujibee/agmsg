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

/** Splits `rect` into its two children's rects for a `split` node's axis/ratio. */
function splitRect(rect: PaneRect, axis: SplitAxis, ratio: number): [PaneRect, PaneRect] {
  if (axis === "col") {
    const aWidth = rect.width * ratio;
    return [{ ...rect, width: aWidth }, { ...rect, left: rect.left + aWidth, width: rect.width - aWidth }];
  }
  const aHeight = rect.height * ratio;
  return [{ ...rect, height: aHeight }, { ...rect, top: rect.top + aHeight, height: rect.height - aHeight }];
}

/** Walks the tree, splitting `rect` at each node's axis/ratio, returning every leaf's rect. */
export function computeRects(node: SplitNode, rect: PaneRect = FULL_RECT): Map<string, PaneRect> {
  if (node.kind === "leaf") return new Map([[node.paneId, rect]]);
  const [rectA, rectB] = splitRect(rect, node.axis, node.ratio);
  const rectsA = computeRects(node.a, rectA);
  const rectsB = computeRects(node.b, rectB);
  return new Map([...rectsA, ...rectsB]);
}

/** A path of child-selectors from the root down to one specific `split` node. */
export type SplitPath = ("a" | "b")[];

/**
 * Immutably replaces the node at `path` with `fn(nodeAtPath)`. The general
 * path-walking machinery `updateRatioAtPath` below is one instance of;
 * `transposeGrid`'s lazy per-segment divider grab is another (see there).
 * Returns `node` unchanged (same reference) if `path` runs into a leaf
 * before it's exhausted — same stale-path safety as `updateRatioAtPath`.
 */
export function applyAtPath(node: SplitNode, path: SplitPath, fn: (n: SplitNode) => SplitNode): SplitNode {
  if (path.length === 0) return fn(node);
  if (node.kind === "leaf") return node;
  const [head, ...rest] = path;
  if (head === "a") {
    const a = applyAtPath(node.a, rest, fn);
    return a === node.a ? node : { ...node, a };
  }
  const b = applyAtPath(node.b, rest, fn);
  return b === node.b ? node : { ...node, b };
}

/**
 * Immutably updates the ratio of the `split` node at `path`. Safe to reuse a
 * `path` across an uninterrupted sequence of calls (e.g. every `mousemove`
 * during one divider drag) — a ratio update never changes the tree's shape,
 * so a path captured at drag-start stays valid for the whole gesture. It is
 * NOT safe to reuse a path across a splice/insert (see `insertBeside`'s own
 * doc for why paths go stale there).
 */
export function updateRatioAtPath(node: SplitNode, path: SplitPath, ratio: number): SplitNode {
  return applyAtPath(node, path, (n) => (n.kind === "split" ? { ...n, ratio } : n));
}

export type DividerInfo =
  | {
      kind: "single";
      path: SplitPath;
      axis: SplitAxis;
      /** The seam itself — a degenerate 0-width (col) or 0-height (row) slice, for positioning the divider line in the UI. */
      rect: PaneRect;
      /** The full UN-split parent rect (what `rect` here was before this node's own split) — drag math needs this to convert a pixel delta back into a ratio, since ratio is relative to the PARENT's size, not the whole stage. */
      bounds: PaneRect;
      ratio: number;
    }
  | {
      kind: "grid-segment";
      /** Path to the aligned-grid split node itself (BEFORE transposing — see transposeGrid). */
      basePath: SplitPath;
      /** Path, within `basePath`'s `a` child's own shape, to this segment's leaf-pair. Doubles as the path to this segment's own independent node once transposeGrid has been applied at `basePath` — the transposed structure mirrors `a`'s shape exactly (see transposeGrid's doc). */
      segmentPath: SplitPath;
      axis: SplitAxis;
      rect: PaneRect;
      /** This segment's own slice of the grid — already correct for drag math even before transposing, since transposeGrid doesn't change rendered geometry (only which future drags are independent). */
      bounds: PaneRect;
      ratio: number;
    };

/**
 * True if `a` and `b` have identical tree SHAPE (same nesting) and the same
 * ratio at every corresponding split node — i.e. they'd form visually
 * aligned columns (or rows) if placed side by side, regardless of which
 * specific panes occupy the leaves. This is the "aligned grid" check
 * `collectDividers` and `transposeGrid` both use.
 *
 * The ratio comparison is intentionally exact (`===`), not a tolerance
 * range: the moment a manual drag nudges one side's ratio even slightly
 * off the other's, the grid is no longer aligned and per-segment grabbing
 * should stop offering itself — falling back to one whole-grid divider is
 * the confirmed-correct behavior once symmetry breaks (see transposeGrid's
 * own doc), not a bug to loosen this into tolerating.
 */
export function sameShapeAndRatio(a: SplitNode, b: SplitNode): boolean {
  if (a.kind === "leaf" || b.kind === "leaf") return a.kind === "leaf" && b.kind === "leaf";
  return a.axis === b.axis && a.ratio === b.ratio && sameShapeAndRatio(a.a, b.a) && sameShapeAndRatio(a.b, b.b);
}

function leafPaths(node: SplitNode, path: SplitPath = []): SplitPath[] {
  if (node.kind === "leaf") return [path];
  return [...leafPaths(node.a, [...path, "a"]), ...leafPaths(node.b, [...path, "b"])];
}

function orderedLeafRects(node: SplitNode, rect: PaneRect): PaneRect[] {
  if (node.kind === "leaf") return [rect];
  const [rectA, rectB] = splitRect(rect, node.axis, node.ratio);
  return [...orderedLeafRects(node.a, rectA), ...orderedLeafRects(node.b, rectB)];
}

// One segment per leaf position in `node.a`'s own shape (equivalently
// `node.b`'s — sameShapeAndRatio guarantees they match), each covering just
// that segment's own slice of the seam instead of the whole thing.
function gridSegments(
  node: Extract<SplitNode, { kind: "split" }>,
  rect: PaneRect,
  rectA: PaneRect,
  basePath: SplitPath,
): DividerInfo[] {
  const segmentPaths = leafPaths(node.a);
  const segmentRects = orderedLeafRects(node.a, rectA);
  return segmentPaths.map((segmentPath, i) => {
    const segRect = segmentRects[i];
    const seam: PaneRect =
      node.axis === "col"
        ? { left: rectA.left + rectA.width, top: segRect.top, width: 0, height: segRect.height }
        : { left: segRect.left, top: rectA.top + rectA.height, width: segRect.width, height: 0 };
    // This segment's bounds AFTER transposing — what its own independent
    // node's rect becomes — span the segment's own slice on the axis
    // node.a/node.b were divided along, but the FULL original rect on the
    // OTHER axis. E.g. for row(colChain, colChain), a column's eventual
    // row-node spans that column's own width but the WHOLE original height
    // (both rows combined), not just the one row segRect came from — using
    // segRect's height directly here would be wrong (co1/self-review catch:
    // the naive version undersized every segment's drag bounds to just its
    // own row/column instead of the full space its transposed node owns).
    const bounds: PaneRect =
      node.axis === "col"
        ? { left: rect.left, top: segRect.top, width: rect.width, height: segRect.height }
        : { left: segRect.left, top: rect.top, width: segRect.width, height: rect.height };
    return { kind: "grid-segment", basePath, segmentPath, axis: node.axis, rect: seam, bounds, ratio: node.ratio };
  });
}

/**
 * Walks the tree, returning one `DividerInfo` per internal `split` node's
 * seam — a plain `"single"` divider spanning the whole seam ordinarily, or,
 * when that node's two children are themselves an ALIGNED grid (see
 * sameShapeAndRatio), one `"grid-segment"` divider per column/row instead —
 * letting each be dragged independently (see transposeGrid). Recursion into
 * `node.a`/`node.b`'s own children happens unconditionally either way; only
 * how THIS ONE seam is represented changes.
 */
export function collectDividers(node: SplitNode, rect: PaneRect = FULL_RECT, path: SplitPath = []): DividerInfo[] {
  if (node.kind === "leaf") return [];
  const [rectA, rectB] = splitRect(rect, node.axis, node.ratio);
  const isAlignedGrid = node.a.kind !== "leaf" && node.b.kind !== "leaf" && sameShapeAndRatio(node.a, node.b);
  const thisSeam: DividerInfo[] = isAlignedGrid
    ? gridSegments(node, rect, rectA, path)
    : [
        {
          kind: "single",
          path,
          axis: node.axis,
          rect:
            node.axis === "col"
              ? { left: rectA.left + rectA.width, top: rect.top, width: 0, height: rect.height }
              : { left: rect.left, top: rectA.top + rectA.height, width: rect.width, height: 0 },
          bounds: rect,
          ratio: node.ratio,
        },
      ];
  return [...thisSeam, ...collectDividers(node.a, rectA, [...path, "a"]), ...collectDividers(node.b, rectB, [...path, "b"])];
}

function zipPairs(a: SplitNode, b: SplitNode, pairAxis: SplitAxis, pairRatio: number): SplitNode {
  if (a.kind === "leaf" && b.kind === "leaf") {
    return { kind: "split", axis: pairAxis, ratio: pairRatio, a, b };
  }
  // sameShapeAndRatio (checked by transposeGrid before calling) guarantees
  // both are "split" here, with matching axis/ratio to each other.
  const splitA = a as Extract<SplitNode, { kind: "split" }>;
  const splitB = b as Extract<SplitNode, { kind: "split" }>;
  return {
    kind: "split",
    axis: splitA.axis,
    ratio: splitA.ratio,
    a: zipPairs(splitA.a, splitB.a, pairAxis, pairRatio),
    b: zipPairs(splitA.b, splitB.b, pairAxis, pairRatio),
  };
}

/**
 * Transposes an ALIGNED grid — a split whose two children are themselves
 * matching chains (same shape, same ratios at every level; see
 * sameShapeAndRatio) — into the orthogonal arrangement. E.g.
 * row(colChain, colChain) with identical column ratios on both sides
 * becomes col(rowChain, rowChain), where each new row-pair has its OWN
 * (initially identical) ratio, independent of the others:
 *   row(col(1,2;c), col(3,4;c); r)  ⇄  col(row(1,3;r), row(2,4;r); c)
 *
 * Visually a no-op at the moment of transpose regardless of size —
 * computeRects produces IDENTICAL leaf rects before and after (only which
 * FUTURE divider drags are independent of each other changes). This is what
 * makes per-column (or per-row) independent divider dragging possible on an
 * aligned N-way grid without a true N-ary grid data structure: as long as
 * the grid stays aligned, grabbing one column's own seam lazily transposes
 * just that one seam into its own independent node, rather than needing
 * every divider to already be independently addressable up front.
 *
 * Self-inverse ONLY for the 2-column/2-row case (co1 review — the doc here
 * previously overclaimed this generally): transposing
 * row(col(1,2;c),col(3,4;c);r) twice does return the original tree, because
 * the transposed result col(row(1,3;r),row(2,4;r);c) is ITSELF a valid
 * aligned-grid input (its two children match). For 3+ columns this doesn't
 * hold — e.g. transposing a 3-column grid produces
 * col(row(1,4;r), col(row(2,5;r),row(3,6;r);c2); c1), whose own two
 * top-level children (a 1-level pair vs. a 2-level chain) no longer match
 * each other, so a second transposeGrid call is just a no-op rather than
 * reconstructing the original 2-row form. This is fine for how the app
 * actually uses this: grabbing a segment transposes once and then only
 * drags that segment's own node — nothing ever needs to un-transpose.
 *
 * Returns `node` unchanged if it isn't an aligned grid (not a split whose
 * two children are themselves matching further-split chains) — the plain
 * single-divider, whole-grid-drag fallback applies there, same as any
 * asymmetric or manually-adjusted tree today. Deliberately scoped to
 * exactly this one shape — a further generalization to partially-aligned
 * nested arrangements is out of scope (confirmed with koit).
 */
export function transposeGrid(node: SplitNode): SplitNode {
  if (node.kind === "leaf") return node;
  const { axis, ratio, a, b } = node;
  if (a.kind === "leaf" || b.kind === "leaf") return node; // not a chain on either side
  if (!sameShapeAndRatio(a, b)) return node; // not aligned
  const innerAxis: SplitAxis = axis === "row" ? "col" : "row";
  return {
    kind: "split",
    axis: innerAxis,
    ratio: a.ratio,
    a: zipPairs(a.a, b.a, axis, ratio),
    b: zipPairs(a.b, b.b, axis, ratio),
  };
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

/** Value-equality for two DropZones — used to skip a state update (and thus a re-render) on every dragover tick that lands in the same zone as before. */
export function sameZone(a: DropZone, b: DropZone): boolean {
  return a.kind === "swap" ? b.kind === "swap" : b.kind === "split" && a.side === b.side;
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
