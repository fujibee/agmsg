import { describe, expect, it } from "vitest";
import { measureCell } from "./cellMeasure";

describe("measureCell", () => {
  it("is the screen size over the grid, whatever width the pane has", () => {
    // 21 columns of 7.2 px, in panes of different widths: the leftover pixels must not change the answer
    const cell = (paneWidth: number) => measureCell({ width: 21 * 7.2, height: 30 * 15 }, { width: paneWidth, height: 460 }, 21, 30);
    expect(cell(152)).toEqual(cell(158));
    expect(cell(152)!.w).toBeCloseTo(7.2, 9);
    expect(cell(152)!.h).toBe(15);
  });

  it("falls back to the pane's own size only while the screen is not laid out", () => {
    expect(measureCell(null, { width: 160, height: 300 }, 20, 20)).toEqual({ w: 8, h: 15 });
    expect(measureCell({ width: 0, height: 0 }, { width: 160, height: 300 }, 20, 20)).toEqual({ w: 8, h: 15 });
  });

  it("gives nothing for an empty grid or an empty size", () => {
    expect(measureCell({ width: 10, height: 10 }, { width: 10, height: 10 }, 0, 5)).toBeNull();
    expect(measureCell({ width: 10, height: 10 }, { width: 10, height: 10 }, 5, 0)).toBeNull();
    expect(measureCell(null, { width: 0, height: 0 }, 5, 5)).toBeNull();
  });
});
