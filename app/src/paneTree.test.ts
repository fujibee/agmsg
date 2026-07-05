import { describe, expect, it } from "vitest";
import {
  classifyDrop,
  clampRatio,
  computeRects,
  insertAsNewLeaf,
  insertBeside,
  leaves,
  minRatioForPx,
  presetTree,
  renameLeaf,
  spliceOutLeaf,
  swapLeaves,
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
