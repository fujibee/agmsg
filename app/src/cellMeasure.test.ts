import { describe, expect, it } from "vitest";
import { CELL_EPSILON_PX, MIN_CELL_COLS, measureCell, updateCell, type CellMeasure } from "./cellMeasure";

describe("measureCell", () => {
  it("is the screen size over the grid", () => {
    const cell = measureCell({ width: 21 * 7.2, height: 30 * 15 }, 21, 30)!;
    expect(cell.w).toBeCloseTo(7.2, 9);
    expect(cell.h).toBe(15);
  });

  it("reports nothing for a grid with too few columns or rows, or a screen that is not laid out", () => {
    expect(measureCell({ width: 30, height: 450 }, MIN_CELL_COLS - 1, 30)).toBeNull();
    expect(measureCell({ width: 60, height: 40 }, MIN_CELL_COLS, 3)).toBeNull();
    expect(measureCell(null, 20, 20)).toBeNull();
    expect(measureCell({ width: 0, height: 0 }, 20, 20)).toBeNull();
  });
});

describe("updateCell", () => {
  it("keeps the old cell for a change inside the rounding error and takes a real one", () => {
    const prev: CellMeasure = { w: 7.2, h: 15 };
    expect(updateCell(prev, { w: 7.2 + CELL_EPSILON_PX / 2, h: 15 })).toBe(prev);
    expect(updateCell(prev, { w: 7.8, h: 15 })).toEqual({ w: 7.8, h: 15 }); // a font size step
    expect(updateCell(null, { w: 7.2, h: 15 })).toEqual({ w: 7.2, h: 15 });
  });
});

// A model of what one pane does, from xterm's own rounding (DomRenderer / WebglRenderer set the canvas width to
// Math.round(device width / dpr)) and FitAddon (the parent's CSS width is parseInt'ed): the gap between panes is the
// reported cell, the room for the terminal is what is left of the pane's share, the columns follow from that, and the
// reported cell follows from the columns. Whatever is reported goes round again; a loop that does not settle is the
// layout loop that kept the window's ResizeObserver firing.
const DPR = 2;
const DEVICE_CELL = 15.3; // a fractional cell: 7.65 css px
const PAD = 7; // what the pane keeps for its own scrollbar and padding
const ROWS = 30;
type Report = (inner: number, cols: number, screenW: number, prev: CellMeasure | null) => CellMeasure | null;

function settle(share: number, report: Report): Set<string> {
  let cell: CellMeasure | null = null;
  const lastRuns: string[] = [];
  for (let i = 0; i < 60; i++) {
    const gap = cell ? cell.w : 8;
    const inner = Math.floor(share - gap - PAD);
    const cols = Math.max(1, Math.floor(inner / (DEVICE_CELL / DPR)));
    const screenW = Math.round(cols * DEVICE_CELL) / DPR;
    const next = report(inner, cols, screenW, cell);
    if (next) cell = next;
    if (i >= 40) lastRuns.push(cell ? `${cell.w.toFixed(4)}x${cell.h}` : "none");
  }
  return new Set(lastRuns);
}

const shares = Array.from({ length: 400 }, (_, k) => 12 + k * 0.37);
const unsettled = (report: Report) => shares.filter((s) => settle(s, report).size > 1);

// the cell as it was reported before: the pane's width over its columns
const oldReport: Report = (inner, cols) => ({ w: inner / cols, h: 15 });
// the screen over the columns with no further rule (the first fix)
const screenOnly: Report = (_i, cols, screenW) => ({ w: screenW / cols, h: 15 });
// what the window does now
const current: Report = (_i, cols, screenW, prev) => {
  const m = measureCell({ width: screenW, height: ROWS * 15 }, cols, ROWS);
  return m ? updateCell(prev, m) : null;
};

describe("the gap between panes settles (fractional cell, device pixel ratio 2, narrow grids)", () => {
  it("did not settle with the pane's width over its columns, or with the screen over the columns alone", () => {
    // the model reproduces the loop: without this the test below would prove nothing
    expect(unsettled(oldReport).length).toBeGreaterThan(0);
    expect(unsettled(screenOnly).length).toBeGreaterThan(0);
  });

  it("settles for every pane share from 12 px to 160 px", () => {
    expect(unsettled(current)).toEqual([]);
  });
});
