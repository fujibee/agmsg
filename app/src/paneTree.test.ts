import { describe, expect, it } from "vitest";
import {
  applyAtPath,
  classifyDrop,
  clampRatio,
  collectDividers,
  computeRects,
  dividerDragKey,
  insertAsNewLeaf,
  insertBeside,
  leaves,
  minRatioForPx,
  presetTree,
  renameLeaf,
  sameShapeAndRatio,
  sameZone,
  spliceOutLeaf,
  swapLeaves,
  transposeGrid,
  updateRatioAtPath,
  type DividerInfo,
  type SplitNode,
} from "./paneTree";

const leaf = (paneId: string): SplitNode => ({ kind: "leaf", paneId });
const split = (
  axis: "row" | "col",
  ratio: number,
  a: SplitNode,
  b: SplitNode,
): SplitNode => ({ kind: "split", axis, ratio, a, b });

describe("leaves", () => {
  it("returns a single-element list for a bare leaf", () => {
    expect(leaves(leaf("p1"))).toEqual(["p1"]);
  });

  it("returns leaves in left-to-right (in-order) order for a nested tree", () => {
    const tree = split("col", 0.5, leaf("p1"), split("row", 0.5, leaf("p2"), leaf("p3")));
    expect(leaves(tree)).toEqual(["p1", "p2", "p3"]);
  });
});

describe("computeRects", () => {
  it("gives a single leaf the full rect", () => {
    const rects = computeRects(leaf("p1"));
    expect(rects.get("p1")).toEqual({ left: 0, top: 0, width: 100, height: 100 });
  });

  it("splits a col node left/right by ratio", () => {
    const tree = split("col", 0.25, leaf("p1"), leaf("p2"));
    const rects = computeRects(tree);
    expect(rects.get("p1")).toEqual({ left: 0, top: 0, width: 25, height: 100 });
    expect(rects.get("p2")).toEqual({ left: 25, top: 0, width: 75, height: 100 });
  });

  it("splits a row node top/bottom by ratio", () => {
    const tree = split("row", 0.75, leaf("p1"), leaf("p2"));
    const rects = computeRects(tree);
    expect(rects.get("p1")).toEqual({ left: 0, top: 0, width: 100, height: 75 });
    expect(rects.get("p2")).toEqual({ left: 0, top: 75, width: 100, height: 25 });
  });

  it("recurses correctly through a nested 2x2 tile tree", () => {
    // row split: top row [p1,p2], bottom row [p3,p4], each 50/50.
    const tree = split(
      "row",
      0.5,
      split("col", 0.5, leaf("p1"), leaf("p2")),
      split("col", 0.5, leaf("p3"), leaf("p4")),
    );
    const rects = computeRects(tree);
    expect(rects.get("p1")).toEqual({ left: 0, top: 0, width: 50, height: 50 });
    expect(rects.get("p2")).toEqual({ left: 50, top: 0, width: 50, height: 50 });
    expect(rects.get("p3")).toEqual({ left: 0, top: 50, width: 50, height: 50 });
    expect(rects.get("p4")).toEqual({ left: 50, top: 50, width: 50, height: 50 });
  });

  // Invariant (aggie review, recommendation 4): rects tile the unit rect
  // exactly for a range of generated trees, not just the hand-picked cases
  // above — no gaps, no overlaps, areas sum to the whole.
  it("invariant: leaf rects always tile the full rect with no gaps or overlaps", () => {
    const trees: SplitNode[] = [
      presetTree("vertical", ["a", "b", "c", "d", "e"]),
      presetTree("horizontal", ["a", "b", "c"]),
      presetTree("tile", ["a", "b", "c", "d", "e", "f", "g"]),
      split("col", 0.3, split("row", 0.6, leaf("a"), leaf("b")), split("row", 0.2, leaf("c"), leaf("d"))),
    ];
    for (const tree of trees) {
      const rects = computeRects(tree);
      let area = 0;
      for (const r of rects.values()) area += (r.width / 100) * (r.height / 100);
      expect(area).toBeCloseTo(1, 9);
    }
  });
});

describe("updateRatioAtPath", () => {
  it("updates the root node's ratio at an empty path", () => {
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    expect(updateRatioAtPath(tree, [], 0.3)).toEqual(split("col", 0.3, leaf("p1"), leaf("p2")));
  });

  it("updates a nested node's ratio, leaving the rest of the tree untouched", () => {
    const tree = split("col", 0.5, leaf("p1"), split("row", 0.5, leaf("p2"), leaf("p3")));
    const result = updateRatioAtPath(tree, ["b"], 0.75);
    expect(result).toEqual(split("col", 0.5, leaf("p1"), split("row", 0.75, leaf("p2"), leaf("p3"))));
  });

  it("is a no-op when the path runs into a leaf (stale path safety)", () => {
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    expect(updateRatioAtPath(tree, ["a", "b"], 0.9)).toBe(tree);
  });
});

describe("collectDividers", () => {
  it("returns one 'single' divider per internal split node, at the seam between its children", () => {
    const tree = split("col", 0.25, leaf("p1"), leaf("p2"));
    const dividers = collectDividers(tree);
    expect(dividers).toEqual([
      {
        kind: "single",
        path: [],
        axis: "col",
        ratio: 0.25,
        rect: { left: 25, top: 0, width: 0, height: 100 },
        bounds: { left: 0, top: 0, width: 100, height: 100 },
      },
    ]);
  });

  it("returns no dividers for a bare leaf", () => {
    expect(collectDividers(leaf("solo"))).toEqual([]);
  });

  it("returns 'single' (not grid-segment) dividers for a non-aligned tree — one per split node, each with its own seam and PARENT bounds (not the whole stage)", () => {
    const tree = split("col", 0.5, leaf("p1"), split("row", 0.5, leaf("p2"), leaf("p3")));
    const dividers = collectDividers(tree);
    expect(dividers).toHaveLength(2);
    const single = dividers.filter((d): d is Extract<DividerInfo, { kind: "single" }> => d.kind === "single");
    expect(single).toHaveLength(2);
    expect(single.find((d) => d.path.length === 0)).toEqual({
      kind: "single",
      path: [],
      axis: "col",
      ratio: 0.5,
      rect: { left: 50, top: 0, width: 0, height: 100 },
      bounds: { left: 0, top: 0, width: 100, height: 100 },
    });
    expect(single.find((d) => d.path.length === 1)).toEqual({
      kind: "single",
      path: ["b"],
      axis: "row",
      ratio: 0.5,
      rect: { left: 50, top: 50, width: 50, height: 0 },
      // The nested divider's bounds are its OWN parent's rect (the "b" child
      // of the root split — half the stage), not the full stage.
      bounds: { left: 50, top: 0, width: 50, height: 100 },
    });
  });

  it("a path from collectDividers round-trips through updateRatioAtPath", () => {
    const tree = split("col", 0.5, leaf("p1"), split("row", 0.5, leaf("p2"), leaf("p3")));
    const dividers = collectDividers(tree).filter(
      (d): d is Extract<DividerInfo, { kind: "single" }> => d.kind === "single",
    );
    const nested = dividers.find((d) => d.path.length === 1)!;
    const result = updateRatioAtPath(tree, nested.path, 0.8);
    expect(result).toEqual(split("col", 0.5, leaf("p1"), split("row", 0.8, leaf("p2"), leaf("p3"))));
  });

  it("returns 'grid-segment' dividers (not one 'single') for the seam between two aligned column-chains", () => {
    // A 2x2 tile: top row [p1,p2], bottom row [p3,p4], both rows split 50/50.
    const tree = split(
      "row",
      0.5,
      split("col", 0.5, leaf("p1"), leaf("p2")),
      split("col", 0.5, leaf("p3"), leaf("p4")),
    );
    const dividers = collectDividers(tree);
    // 1 root seam (as 2 segments, one per column) + 1 nested seam per row (2 rows) = 4 total.
    expect(dividers).toHaveLength(4);
    const segments = dividers.filter(
      (d): d is Extract<DividerInfo, { kind: "grid-segment" }> => d.kind === "grid-segment",
    );
    expect(segments).toHaveLength(2);
    expect(segments).toEqual(
      expect.arrayContaining([
        {
          kind: "grid-segment",
          basePath: [],
          segmentPath: ["a"],
          axis: "row",
          ratio: 0.5,
          rect: { left: 0, top: 50, width: 50, height: 0 },
          bounds: { left: 0, top: 0, width: 50, height: 100 },
        },
        {
          kind: "grid-segment",
          basePath: [],
          segmentPath: ["b"],
          axis: "row",
          ratio: 0.5,
          rect: { left: 50, top: 50, width: 50, height: 0 },
          bounds: { left: 50, top: 0, width: 50, height: 100 },
        },
      ]),
    );
  });

  it("falls back to a single divider when the two sides don't match ratios (not aligned)", () => {
    const tree = split(
      "row",
      0.5,
      split("col", 0.3, leaf("p1"), leaf("p2")), // different ratio from below
      split("col", 0.7, leaf("p3"), leaf("p4")),
    );
    const dividers = collectDividers(tree);
    const root = dividers.find((d) => d.kind === "single" && d.path.length === 0);
    expect(root).toMatchObject({ kind: "single", path: [] });
  });
});

describe("spliceOutLeaf", () => {
  it("returns null when removing the only leaf", () => {
    expect(spliceOutLeaf(leaf("p1"), "p1")).toBeNull();
  });

  it("promotes the sibling when removing one of two leaves", () => {
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    expect(spliceOutLeaf(tree, "p1")).toEqual(leaf("p2"));
    expect(spliceOutLeaf(tree, "p2")).toEqual(leaf("p1"));
  });

  it("collapses the correct parent in a nested tree, leaving the rest intact", () => {
    const tree = split("col", 0.5, leaf("p1"), split("row", 0.5, leaf("p2"), leaf("p3")));
    expect(spliceOutLeaf(tree, "p2")).toEqual(split("col", 0.5, leaf("p1"), leaf("p3")));
  });

  it("returns the same reference unchanged when the paneId isn't present", () => {
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    expect(spliceOutLeaf(tree, "nope")).toBe(tree);
  });
});

describe("insertAsNewLeaf", () => {
  it("appends as a new rightmost column with ratio (n-1)/n", () => {
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    const result = insertAsNewLeaf(tree, "p3");
    expect(result).toEqual(split("col", 2 / 3, tree, leaf("p3")));
    expect(leaves(result)).toEqual(["p1", "p2", "p3"]);
  });

  it("gives a fresh single pane ratio 1/2 against the new leaf", () => {
    const result = insertAsNewLeaf(leaf("p1"), "p2");
    expect(result).toEqual(split("col", 0.5, leaf("p1"), leaf("p2")));
  });
});

describe("insertBeside", () => {
  it("splits the target on the indicated side, non-sibling drop (path stable)", () => {
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    // p2 dragged onto p1's "left" zone: p1 -> [p2 | p1], p2 unchanged elsewhere.
    const result = insertBeside(tree, "p1", "left", "p2");
    expect(result).toEqual(split("col", 0.5, leaf("p2"), leaf("p1")));
    expect(leaves(result)).toEqual(["p2", "p1"]);
  });

  it("resolves all four sides correctly", () => {
    expect(insertBeside(leaf("t"), "t", "top", "n")).toEqual(split("row", 0.5, leaf("n"), leaf("t")));
    expect(insertBeside(leaf("t"), "t", "bottom", "n")).toEqual(split("row", 0.5, leaf("t"), leaf("n")));
    expect(insertBeside(leaf("t"), "t", "left", "n")).toEqual(split("col", 0.5, leaf("n"), leaf("t")));
    expect(insertBeside(leaf("t"), "t", "right", "n")).toEqual(split("col", 0.5, leaf("t"), leaf("n")));
  });

  it("is a no-op on self-drop (target === dragged)", () => {
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    expect(insertBeside(tree, "p1", "left", "p1")).toBe(tree);
  });

  // co1 + aggie review: without this guard, splicing newPaneId out FIRST
  // and only then failing to find a nonexistent targetPaneId would return
  // "the tree minus newPaneId" — silently dropping the dragged pane
  // entirely rather than leaving it in place. Reachable via a real UI race
  // (the target pane closes, e.g. its agent exits, in the moment between
  // drag-start and drop).
  it("is a no-op when targetPaneId doesn't exist in the tree (real race: target closed mid-drag)", () => {
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    expect(insertBeside(tree, "gone", "left", "p2")).toBe(tree);
    expect(leaves(insertBeside(tree, "gone", "left", "p2"))).toEqual(["p1", "p2"]);
  });

  it("re-locates the target by paneId after splicing out a SIBLING drop (path is not stable here)", () => {
    // p2 and p3 are siblings under one parent, itself p1's sibling.
    const tree = split("col", 0.5, leaf("p1"), split("row", 0.5, leaf("p2"), leaf("p3")));
    // Drag p2 onto p3's "top" zone: splicing p2 out promotes p3 up to
    // replace their shared parent — p3's position changes as a result.
    // insertBeside must find p3 in the POST-splice tree, not the original.
    const result = insertBeside(tree, "p3", "top", "p2");
    expect(result).toEqual(split("col", 0.5, leaf("p1"), split("row", 0.5, leaf("p2"), leaf("p3"))));
    expect(leaves(result)).toEqual(["p1", "p2", "p3"]);
  });

  it("inserts a pane not present in the tree directly (cross-window base case)", () => {
    // Caller already spliced "new" out of another window's tree.
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    const result = insertBeside(tree, "p2", "right", "new");
    expect(result).toEqual(split("col", 0.5, leaf("p1"), split("col", 0.5, leaf("p2"), leaf("new"))));
  });
});

describe("renameLeaf / swapLeaves (cross-window swap building blocks)", () => {
  it("renameLeaf swaps a single leaf's id, leaving structure untouched", () => {
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    expect(renameLeaf(tree, "p1", "p3")).toEqual(split("col", 0.5, leaf("p3"), leaf("p2")));
  });

  it("swapLeaves exchanges two leaves within the same tree, shape unchanged", () => {
    const tree = split("col", 0.7, leaf("p1"), leaf("p2"));
    const result = swapLeaves(tree, "p1", "p2");
    expect(result).toEqual(split("col", 0.7, leaf("p2"), leaf("p1")));
  });

  it("cross-window swap composes as one renameLeaf call per tree", () => {
    const treeA = split("col", 0.5, leaf("a1"), leaf("a2"));
    const treeB = leaf("b1");
    const newA = renameLeaf(treeA, "a1", "b1");
    const newB = renameLeaf(treeB, "b1", "a1");
    expect(leaves(newA)).toEqual(["b1", "a2"]);
    expect(leaves(newB)).toEqual(["a1"]);
  });

  it("swapLeaves is a no-op when neither id is present", () => {
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    expect(swapLeaves(tree, "x", "y")).toBe(tree);
  });
});

describe("presetTree", () => {
  it("guards the single-pane case: returns a bare leaf, not a degenerate split", () => {
    expect(presetTree("vertical", ["only"])).toEqual(leaf("only"));
    expect(presetTree("tile", ["only"])).toEqual(leaf("only"));
  });

  it("throws for an empty pane list", () => {
    expect(() => presetTree("vertical", [])).toThrow();
  });

  it("vertical: an evenly-weighted chain of col splits", () => {
    const tree = presetTree("vertical", ["a", "b", "c"]);
    expect(leaves(tree)).toEqual(["a", "b", "c"]);
    const rects = computeRects(tree);
    expect(rects.get("a")!.width).toBeCloseTo(100 / 3, 6);
    expect(rects.get("b")!.width).toBeCloseTo(100 / 3, 6);
    expect(rects.get("c")!.width).toBeCloseTo(100 / 3, 6);
  });

  it("horizontal: an evenly-weighted chain of row splits", () => {
    const tree = presetTree("horizontal", ["a", "b"]);
    const rects = computeRects(tree);
    expect(rects.get("a")).toEqual({ left: 0, top: 0, width: 100, height: 50 });
    expect(rects.get("b")).toEqual({ left: 0, top: 50, width: 100, height: 50 });
  });

  it("tile: matches today's tileRowSizes grouping (equal row heights, equal column widths per row)", () => {
    // n=5 -> rows [3, 2]
    const tree = presetTree("tile", ["a", "b", "c", "d", "e"]);
    expect(leaves(tree)).toEqual(["a", "b", "c", "d", "e"]);
    const rects = computeRects(tree);
    for (const id of ["a", "b", "c"]) expect(rects.get(id)!.height).toBeCloseTo(50, 6);
    for (const id of ["d", "e"]) expect(rects.get(id)!.height).toBeCloseTo(50, 6);
    for (const id of ["a", "b", "c"]) expect(rects.get(id)!.width).toBeCloseTo(100 / 3, 6);
    for (const id of ["d", "e"]) expect(rects.get(id)!.width).toBeCloseTo(50, 6);
  });
});

describe("classifyDrop (16-zone rule)", () => {
  // The worked example from the design doc: number cells 1-16 row-major
  // (1,2,3,4 top row; 5,6,7,8 next; ...), center of each cell.
  const cellCenter = (cellNumber: number): [number, number] => {
    const idx = cellNumber - 1;
    const row = Math.floor(idx / 4);
    const col = idx % 4;
    return [(col + 0.5) / 4, (row + 0.5) / 4];
  };

  it.each([
    [1, { kind: "swap" }],
    [2, { kind: "split", side: "top" }],
    [3, { kind: "split", side: "top" }],
    [4, { kind: "swap" }],
    [5, { kind: "split", side: "left" }],
    [6, { kind: "swap" }],
    [7, { kind: "swap" }],
    [8, { kind: "split", side: "right" }],
    [9, { kind: "split", side: "left" }],
    [10, { kind: "swap" }],
    [11, { kind: "swap" }],
    [12, { kind: "split", side: "right" }],
    [13, { kind: "swap" }],
    [14, { kind: "split", side: "bottom" }],
    [15, { kind: "split", side: "bottom" }],
    [16, { kind: "swap" }],
  ] as const)("cell %i classifies as %o", (cell, expected) => {
    const [x, y] = cellCenter(cell);
    expect(classifyDrop(x, y)).toEqual(expected);
  });
});

describe("sameZone", () => {
  it("treats any two swap zones as equal", () => {
    expect(sameZone({ kind: "swap" }, { kind: "swap" })).toBe(true);
  });

  it("treats split zones with the same side as equal", () => {
    expect(sameZone({ kind: "split", side: "top" }, { kind: "split", side: "top" })).toBe(true);
  });

  it("treats split zones with different sides as unequal", () => {
    expect(sameZone({ kind: "split", side: "top" }, { kind: "split", side: "bottom" })).toBe(false);
  });

  it("treats swap and split as unequal regardless of side", () => {
    expect(sameZone({ kind: "swap" }, { kind: "split", side: "left" })).toBe(false);
  });
});

describe("clampRatio / minRatioForPx", () => {
  it("does not clamp a ratio comfortably inside the pixel-derived bound", () => {
    expect(clampRatio(0.5, 100, 1000)).toBeCloseTo(0.5, 9);
  });

  it("clamps to the pixel-derived minimum, not a flat percent", () => {
    // 120px minimum against a 400px total => 30% floor.
    expect(minRatioForPx(120, 400)).toBeCloseTo(0.3, 9);
    expect(clampRatio(0.05, 120, 400)).toBeCloseTo(0.3, 9);
    expect(clampRatio(0.95, 120, 400)).toBeCloseTo(0.7, 9);
  });

  it("never returns a bound at or beyond 0.5 in either direction", () => {
    expect(minRatioForPx(500, 400)).toBeLessThanOrEqual(0.5);
  });
});

describe("invariants (aggie review, recommendation 4)", () => {
  it("round-trip: leaves(spliceOutLeaf(insertAsNewLeaf(t, id), id)) === leaves(t)", () => {
    const trees: SplitNode[] = [
      leaf("solo"),
      presetTree("vertical", ["a", "b", "c"]),
      presetTree("tile", ["a", "b", "c", "d", "e"]),
    ];
    for (const tree of trees) {
      const inserted = insertAsNewLeaf(tree, "NEW");
      const spliced = spliceOutLeaf(inserted, "NEW");
      expect(spliced && leaves(spliced)).toEqual(leaves(tree));
    }
  });

  it("every ratio stays within the open interval (0, 1) after a sequence of operations", () => {
    let tree = presetTree("tile", ["a", "b", "c", "d"]);
    tree = insertAsNewLeaf(tree, "e");
    tree = insertBeside(tree, "a", "top", "e");
    tree = swapLeaves(tree, "b", "c");

    const walk = (node: SplitNode): void => {
      if (node.kind === "leaf") return;
      expect(node.ratio).toBeGreaterThan(0);
      expect(node.ratio).toBeLessThan(1);
      walk(node.a);
      walk(node.b);
    };
    walk(tree);
  });
});

describe("applyAtPath", () => {
  it("applies fn to the root when path is empty", () => {
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    const result = applyAtPath(tree, [], (n) => (n.kind === "split" ? { ...n, ratio: 0.9 } : n));
    expect(result).toEqual(split("col", 0.9, leaf("p1"), leaf("p2")));
  });

  it("applies fn at a nested path, leaving the rest of the tree untouched", () => {
    const tree = split("col", 0.5, leaf("p1"), split("row", 0.5, leaf("p2"), leaf("p3")));
    const result = applyAtPath(tree, ["b"], (n) => (n.kind === "leaf" ? n : { ...n, ratio: 0.1 }));
    expect(result).toEqual(split("col", 0.5, leaf("p1"), split("row", 0.1, leaf("p2"), leaf("p3"))));
  });

  it("is a no-op (same reference) when the path runs into a leaf", () => {
    const tree = split("col", 0.5, leaf("p1"), leaf("p2"));
    expect(applyAtPath(tree, ["a", "b"], (n) => n)).toBe(tree);
  });
});

describe("sameShapeAndRatio", () => {
  it("two bare leaves always match, regardless of paneId", () => {
    expect(sameShapeAndRatio(leaf("p1"), leaf("p2"))).toBe(true);
  });

  it("a leaf never matches a split", () => {
    expect(sameShapeAndRatio(leaf("p1"), split("col", 0.5, leaf("p2"), leaf("p3")))).toBe(false);
  });

  it("matches two splits with the same axis, ratio, and recursively matching children", () => {
    const a = split("col", 0.5, leaf("p1"), leaf("p2"));
    const b = split("col", 0.5, leaf("p3"), leaf("p4"));
    expect(sameShapeAndRatio(a, b)).toBe(true);
  });

  it("rejects a different axis", () => {
    const a = split("col", 0.5, leaf("p1"), leaf("p2"));
    const b = split("row", 0.5, leaf("p3"), leaf("p4"));
    expect(sameShapeAndRatio(a, b)).toBe(false);
  });

  it("rejects a different ratio", () => {
    const a = split("col", 0.5, leaf("p1"), leaf("p2"));
    const b = split("col", 0.3, leaf("p3"), leaf("p4"));
    expect(sameShapeAndRatio(a, b)).toBe(false);
  });

  it("rejects mismatched depth (a 3-column chain vs. a 2-column chain)", () => {
    const a = split("col", 0.5, leaf("p1"), split("col", 0.5, leaf("p2"), leaf("p3")));
    const b = split("col", 0.5, leaf("p4"), leaf("p5"));
    expect(sameShapeAndRatio(a, b)).toBe(false);
  });

  it("matches arbitrarily deep chains as long as every level's axis and ratio line up", () => {
    const a = split("col", 0.4, leaf("p1"), split("col", 0.6, leaf("p2"), leaf("p3")));
    const b = split("col", 0.4, leaf("p4"), split("col", 0.6, leaf("p5"), leaf("p6")));
    expect(sameShapeAndRatio(a, b)).toBe(true);
  });
});

describe("transposeGrid", () => {
  it("is a no-op for a bare leaf", () => {
    const solo = leaf("solo");
    expect(transposeGrid(solo)).toBe(solo);
  });

  it("is a no-op when either side is a bare leaf (not a chain)", () => {
    const tree = split("row", 0.5, leaf("p1"), split("col", 0.5, leaf("p2"), leaf("p3")));
    expect(transposeGrid(tree)).toBe(tree);
  });

  it("is a no-op when the two sides don't match (not aligned)", () => {
    const tree = split(
      "row",
      0.5,
      split("col", 0.3, leaf("p1"), leaf("p2")),
      split("col", 0.7, leaf("p3"), leaf("p4")),
    );
    expect(transposeGrid(tree)).toBe(tree);
  });

  it("transposes a 2x2 aligned grid: row(col(1,2;c), col(3,4;c); r) -> col(row(1,3;r), row(2,4;r); c)", () => {
    const tree = split(
      "row",
      0.5,
      split("col", 0.5, leaf("1"), leaf("2")),
      split("col", 0.5, leaf("3"), leaf("4")),
    );
    const result = transposeGrid(tree);
    expect(result).toEqual(
      split("col", 0.5, split("row", 0.5, leaf("1"), leaf("3")), split("row", 0.5, leaf("2"), leaf("4"))),
    );
  });

  it("generalizes to a 3-column aligned grid", () => {
    const row = (leftId: string, rest: SplitNode) => split("col", 0.4, leaf(leftId), rest);
    const tree = split(
      "row",
      0.5,
      row("1", split("col", 0.6, leaf("2"), leaf("3"))),
      row("4", split("col", 0.6, leaf("5"), leaf("6"))),
    );
    const result = transposeGrid(tree);
    expect(leaves(result)).toEqual(["1", "4", "2", "5", "3", "6"]);
    // Each column becomes its own independent row-pair, same 0.5 starting ratio.
    expect(result).toEqual(
      split(
        "col",
        0.4,
        split("row", 0.5, leaf("1"), leaf("4")),
        split("col", 0.6, split("row", 0.5, leaf("2"), leaf("5")), split("row", 0.5, leaf("3"), leaf("6"))),
      ),
    );
  });

  it("is self-inverse for the 2-column/2-row case: transposing twice (with no drag in between) returns the original tree", () => {
    const tree = split(
      "row",
      0.5,
      split("col", 0.5, leaf("1"), leaf("2")),
      split("col", 0.5, leaf("3"), leaf("4")),
    );
    expect(transposeGrid(transposeGrid(tree))).toEqual(tree);
  });

  // co1 review: self-inverse does NOT generalize past 2 columns/rows — a
  // transposed 3-column grid's own top-level children no longer match each
  // other (a 1-level leaf-pair vs. a 2-level chain), so a second
  // transposeGrid call is just a no-op rather than reconstructing the
  // original. Documented as an accepted limitation, not a bug: the app
  // never needs to un-transpose (a grabbed segment only ever drags its own
  // node afterward).
  it("is NOT self-inverse for 3+ columns — transposing twice is a no-op, not a round-trip", () => {
    const row = (leftId: string, rest: SplitNode) => split("col", 0.4, leaf(leftId), rest);
    const tree = split(
      "row",
      0.5,
      row("1", split("col", 0.6, leaf("2"), leaf("3"))),
      row("4", split("col", 0.6, leaf("5"), leaf("6"))),
    );
    const once = transposeGrid(tree);
    const twice = transposeGrid(once);
    expect(twice).toBe(once); // second call is a no-op (not aligned anymore)
    expect(twice).not.toEqual(tree);
  });

  it("is visually a no-op: computeRects gives identical rects before and after transposing", () => {
    const tree = split(
      "row",
      0.3,
      split("col", 0.7, leaf("1"), leaf("2")),
      split("col", 0.7, leaf("3"), leaf("4")),
    );
    const before = computeRects(tree);
    const after = computeRects(transposeGrid(tree));
    for (const id of ["1", "2", "3", "4"]) {
      expect(after.get(id)).toEqual(before.get(id));
    }
  });

  it("end-to-end: grabbing a grid-segment, transposing, then dragging only moves that one segment", () => {
    const tree = split(
      "row",
      0.5,
      split("col", 0.5, leaf("1"), leaf("2")),
      split("col", 0.5, leaf("3"), leaf("4")),
    );
    const segment = collectDividers(tree).find(
      (d): d is Extract<DividerInfo, { kind: "grid-segment" }> => d.kind === "grid-segment" && d.segmentPath[0] === "a",
    )!;
    const transposed = applyAtPath(tree, segment.basePath, transposeGrid);
    const dragPath = [...segment.basePath, ...segment.segmentPath];
    const dragged = updateRatioAtPath(transposed, dragPath, 0.8);

    // Column 1 (leaves 1,3) moved to the new ratio; column 2 (leaves 2,4)
    // is untouched, still at the original shared 0.5 — proving the two
    // columns are now independent instead of both moving together.
    const rects = computeRects(dragged);
    expect(rects.get("1")!.height).toBeCloseTo(80, 6);
    expect(rects.get("3")!.height).toBeCloseTo(20, 6);
    expect(rects.get("2")!.height).toBeCloseTo(50, 6);
    expect(rects.get("4")!.height).toBeCloseTo(50, 6);
  });
});

describe("dividerDragKey", () => {
  it("stays the same across a grid-segment transpose (regression, co1 review PR #390)", () => {
    // A 3-column aligned grid: transposing a grid-segment divider from one
    // of these turns the OTHER segments' dividers from "grid-segment" into
    // "single" (a 2x2 grid stays grid-shaped either way — this needed 3+
    // columns to reproduce). App.tsx keys its drag-highlight off this
    // identity precisely because the divider's own DOM node can get
    // unmounted by that shape change mid-drag.
    const row = (leftId: string, rest: SplitNode) => split("col", 0.4, leaf(leftId), rest);
    const tree = split(
      "row",
      0.5,
      row("1", split("col", 0.6, leaf("2"), leaf("3"))),
      row("4", split("col", 0.6, leaf("5"), leaf("6"))),
    );
    const before = collectDividers(tree);
    const grabbed = before.find((d) => d.kind === "grid-segment")!;
    expect(grabbed.kind).toBe("grid-segment");
    const keyBefore = dividerDragKey(grabbed);

    // Mirrors startPaneDividerDrag: transpose at the grabbed divider's own
    // basePath, exactly as grabbing it does.
    const transposed = applyAtPath(tree, (grabbed as Extract<DividerInfo, { kind: "grid-segment" }>).basePath, transposeGrid);
    const after = collectDividers(transposed);
    expect(after.some((d) => dividerDragKey(d) === keyBefore)).toBe(true);
  });
});
