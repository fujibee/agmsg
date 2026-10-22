import { describe, expect, it } from "vitest";
import type { DiffLine } from "../../../addon-kit/protocol";
import { changeStarts, gapBefore, initialBase, sideBySide, wordDiff } from "./diff";

const L = (type: DiffLine["type"], text: string, oldNo: number | null, newNo: number | null): DiffLine => ({ type, text, oldNo, newNo });

describe("wordDiff", () => {
  it("marks only the changed words", () => {
    const { a, b } = wordDiff("const total = items.length;", "const total = items.size;");
    expect(a).toEqual([{ start: 20, end: 26 }]);
    expect(b).toEqual([{ start: 20, end: 24 }]);
  });
  it("marks an inserted word", () => {
    const { a, b } = wordDiff("a b", "a x b");
    expect(a).toEqual([]);
    expect(b).toEqual([{ start: 2, end: 4 }]);
  });
  it("marks nothing when the lines share no word", () => {
    expect(wordDiff("foo", "bar")).toEqual({ a: [], b: [] });
  });
  it("gives up on very long lines", () => {
    const long = "x ".repeat(3000);
    expect(wordDiff(long, long + "y")).toEqual({ a: [], b: [] });
  });
});

describe("sideBySide", () => {
  it("pairs deletions with the additions after them", () => {
    const rows = sideBySide([
      L("context", "a", 1, 1),
      L("del", "b", 2, null),
      L("del", "c", 3, null),
      L("add", "B", null, 2),
      L("context", "d", 4, 3),
    ]);
    expect(rows.map((r) => [r.left?.text ?? null, r.right?.text ?? null])).toEqual([
      ["a", "a"], ["b", "B"], ["c", null], ["d", "d"],
    ]);
  });
  it("leaves the left empty for a pure addition", () => {
    const rows = sideBySide([L("add", "x", null, 1)]);
    expect(rows).toEqual([{ left: null, right: expect.objectContaining({ text: "x" }) }]);
  });
});

describe("gapBefore", () => {
  const hunks = [
    { oldStart: 11, oldLines: 4, newStart: 11, newLines: 5, lines: [] },
    { oldStart: 30, oldLines: 3, newStart: 31, newLines: 3, lines: [] },
  ];
  it("counts unchanged lines before and between hunks", () => {
    expect(gapBefore(hunks, 0)).toBe(10);
    expect(gapBefore(hunks, 1)).toBe(15);
  });
});

describe("changeStarts", () => {
  it("finds the first line of every run of changes", () => {
    const lines = [L("add", "a", null, 1), L("context", "b", 1, 2), L("del", "c", 2, null), L("add", "d", null, 3)];
    expect(changeStarts(lines)).toEqual([0, 2]);
  });
});

describe("initialBase", () => {
  it("turns a branch or ref name into a merge-base comparison", () => {
    expect(initialBase("main")).toBe("merge-base:main");
    expect(initialBase("origin/dev")).toBe("merge-base:origin/dev");
  });
  it("keeps a full SHA and explicit forms as they are", () => {
    const sha = "9f3e1b0c2a7d4e8f6b5a1c3d2e4f5a6b7c8d9e0f";
    expect(initialBase(sha)).toBe(sha);
    expect(initialBase("merge-base:main")).toBe("merge-base:main");
  });
  it("is empty when nothing was given", () => {
    expect(initialBase(undefined)).toBe("");
    expect(initialBase("  ")).toBe("");
  });
});
