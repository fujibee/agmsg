// The size of one terminal cell, reported to the window so it can size the gap between panes.
//
// It used to be the pane's width divided by its columns. That is the cell plus the pixels left over after the last
// column, so the gap between panes (one cell) made the width of a pane, and the width of the pane made the gap.
// With wide panes the loop settled at once. With narrow ones (a tab of 16 or more panes, a few columns each) the
// column count flipped between two values, every pane changed width by about half a pixel about twelve times a
// second, and the window's ResizeObserver callbacks never stopped.
//
// xterm sets its screen element to `columns x cell width`, with the CSS width rounded to a whole pixel
// (Math.round(device canvas width / dpr)). So the screen width over the columns is the cell width with an error of
// up to half a pixel over the number of columns: negligible with a few dozen columns, as large as the cell itself
// with two. Two rules keep the report from feeding back:
//  - a grid with too few columns or rows reports nothing (the last good value stays), and
//  - a change smaller than the rounding error is not a change (updateCell), a real one (a font size step is about
//    half a pixel or more) is.

export type CellMeasure = { w: number; h: number };

/** Fewest columns and rows a grid needs for its measure to be trusted: the rounding error is then 0.5 / 8, about 0.06 px. */
export const MIN_CELL_COLS = 8;
export const MIN_CELL_ROWS = 4;

/** A change smaller than this is rounding, not a different cell. */
export const CELL_EPSILON_PX = 0.2;

/** The screen size over the grid, or null when the grid is too small or the screen is not laid out yet. */
export function measureCell(screen: { width: number; height: number } | null, cols: number, rows: number): CellMeasure | null {
  if (cols < MIN_CELL_COLS || rows < MIN_CELL_ROWS) return null;
  if (!screen || screen.width <= 0 || screen.height <= 0) return null;
  return { w: screen.width / cols, h: screen.height / rows };
}

/** The cell the window keeps: the old one unless the new measure differs by more than the rounding error. */
export function updateCell(prev: CellMeasure | null, next: CellMeasure): CellMeasure {
  if (prev && Math.abs(prev.w - next.w) < CELL_EPSILON_PX && Math.abs(prev.h - next.h) < CELL_EPSILON_PX) return prev;
  return next;
}
