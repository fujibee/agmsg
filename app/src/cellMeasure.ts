// The size of one terminal cell, reported to the window so it can size the gap between panes.
//
// It used to be the pane's width divided by its columns. That is the cell plus the leftover pixels that do not fit
// one more column, and the gap between panes is made of this value: the width of a pane depended on the gap and
// the gap on the width. With wide panes the loop settled at once. With narrow ones (a tab of 16 or more panes, a
// few columns each) it did not: the columns flipped between two counts, every pane changed width by a fraction of a
// pixel about twelve times a second, and the window's ResizeObserver callbacks never stopped.
//
// xterm sets the width of its screen element to exactly `columns x cell width` (and the height to `rows x cell
// height`), so the cell is that size divided by the grid. It does not depend on how wide the pane is.

export type CellMeasure = { w: number; h: number };

/**
 * `screen` is the size of xterm's screen element, `container` the pane's own size (the fallback while the screen is
 * not laid out yet). Returns null when nothing usable is known.
 */
export function measureCell(
  screen: { width: number; height: number } | null,
  container: { width: number; height: number },
  cols: number,
  rows: number,
): CellMeasure | null {
  if (cols <= 0 || rows <= 0) return null;
  const source = screen && screen.width > 0 && screen.height > 0 ? screen : container;
  if (source.width <= 0 || source.height <= 0) return null;
  return { w: source.width / cols, h: source.height / rows };
}
