// How many terminal panes may hold a WebGL context at the same time.
//
// WebKit allows about 16 live WebGL contexts per page, and the oldest one is dropped when a new one is made past
// that. Every pane of the tab on screen asks for one, so a tab with many panes (agents an add-on starts beside it,
// or a long session) reached the limit: the oldest contexts were lost (an add-on's 3D board went first), the
// panes fell back to the DOM renderer one by one without any order, and nothing took a context again.
//
// Measured on the real app, one tab, an add-on pane and N terminal panes: up to 12 panes every pane kept WebGL and
// nothing was lost; at 16 the first context was lost and at 20 five were, after which the window's
// ResizeObserver fired 190-240 times a second. A pane holds a context only for as long as it has a slot here; the
// least recently used pane gives its slot up (and draws with the DOM renderer) before the page runs out, and takes
// one again when it is used. The other half of the page's contexts is left for add-on panes (a board takes two).

/** Terminal panes with a WebGL context at one time. The page's own limit is about 16; add-ons keep the rest. */
export const WEBGL_PANE_LIMIT = 8;

type Slot = { usedAt: number; release: () => void };

export type WebglBudget = {
  /** `id` takes a slot. If the budget is full, the slot of the least recently used other pane is released first. */
  claim(id: string, release: () => void): void;
  /** `id` was just used (focused, shown): it is the last to lose its slot. A pane without a slot is not affected. */
  touch(id: string): void;
  /** `id` no longer holds a context (it detached, lost it, or went away): its slot is free. */
  free(id: string): void;
  /** How many slots are taken. */
  size(): number;
};

export function createWebglBudget(limit: number, now: () => number = () => performance.now()): WebglBudget {
  const slots = new Map<string, Slot>();
  // `now()` can repeat within one tick: a counter keeps "least recently used" a strict order.
  let tick = 0;
  const stamp = () => now() * 1000 + tick++;
  return {
    claim(id, release) {
      slots.delete(id);
      while (slots.size >= limit) {
        let oldest: string | null = null;
        for (const [k, s] of slots) if (oldest === null || s.usedAt < slots.get(oldest)!.usedAt) oldest = k;
        if (oldest === null) break;
        const gone = slots.get(oldest)!;
        slots.delete(oldest);
        gone.release();
      }
      slots.set(id, { usedAt: stamp(), release });
    },
    touch(id) {
      const s = slots.get(id);
      if (s) s.usedAt = stamp();
    },
    free(id) {
      slots.delete(id);
    },
    size: () => slots.size,
  };
}

/** The one budget of the window. */
export const webglBudget = createWebglBudget(WEBGL_PANE_LIMIT);
