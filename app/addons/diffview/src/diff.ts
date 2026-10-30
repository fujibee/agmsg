import type { DiffHunk, DiffLine } from "../../../addon-kit/protocol";

export interface Range {
  start: number;
  end: number; // exclusive
}

const TOKEN = /[A-Za-z0-9_]+|\s+|[^A-Za-z0-9_\s]/g;
const MAX_WORDDIFF_CHARS = 2000;
const MAX_WORDDIFF_TOKENS = 400;

/**
 * Word-level changes between two lines: the character ranges of `a` that were
 * removed and of `b` that were added. Tokens are words, whitespace runs and
 * single punctuation marks; the common tokens come from an LCS.
 */
export function wordDiff(a: string, b: string): { a: Range[]; b: Range[] } {
  if (a.length > MAX_WORDDIFF_CHARS || b.length > MAX_WORDDIFF_CHARS) return { a: [], b: [] };
  const ta: string[] = a.match(TOKEN) ?? [];
  const tb: string[] = b.match(TOKEN) ?? [];
  if (ta.length > MAX_WORDDIFF_TOKENS || tb.length > MAX_WORDDIFF_TOKENS) return { a: [], b: [] };
  const n = ta.length;
  const m = tb.length;
  // lcs[i][j] = LCS length of ta[i..] and tb[j..]
  const lcs: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i][j] = ta[i] === tb[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  const ra: Range[] = [];
  const rb: Range[] = [];
  let i = 0, j = 0, pa = 0, pb = 0;
  const push = (rs: Range[], start: number, len: number) => {
    const last = rs[rs.length - 1];
    if (last && last.end === start) last.end += len;
    else rs.push({ start, end: start + len });
  };
  while (i < n && j < m) {
    if (ta[i] === tb[j]) {
      pa += ta[i].length; pb += tb[j].length; i++; j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      push(ra, pa, ta[i].length); pa += ta[i].length; i++;
    } else {
      push(rb, pb, tb[j].length); pb += tb[j].length; j++;
    }
  }
  while (i < n) { push(ra, pa, ta[i].length); pa += ta[i].length; i++; }
  while (j < m) { push(rb, pb, tb[j].length); pb += tb[j].length; j++; }
  // Nothing but whitespace in common: the whole line changed, and the line colour says so.
  if (!ta.some((t) => /\S/.test(t) && tb.includes(t))) return { a: [], b: [] };
  return { a: ra, b: rb };
}

/** One row of a side-by-side view; either side may be empty. */
export interface SideRow {
  left: DiffLine | null;
  right: DiffLine | null;
}

/**
 * Lay a hunk out in two columns: context lines on both sides, and each run of
 * deletions paired index by index with the additions that follow it.
 */
export function sideBySide(lines: DiffLine[]): SideRow[] {
  const rows: SideRow[] = [];
  let i = 0;
  while (i < lines.length) {
    const l = lines[i];
    if (l.type === "context") {
      rows.push({ left: l, right: l });
      i++;
      continue;
    }
    const dels: DiffLine[] = [];
    const adds: DiffLine[] = [];
    while (i < lines.length && lines[i].type === "del") dels.push(lines[i++]);
    while (i < lines.length && lines[i].type === "add") adds.push(lines[i++]);
    const n = Math.max(dels.length, adds.length);
    for (let k = 0; k < n; k++) rows.push({ left: dels[k] ?? null, right: adds[k] ?? null });
  }
  return rows;
}

/** Unchanged lines between hunk k and k+1 (and before the first), for the "⋯" rows. */
export function gapBefore(hunks: DiffHunk[], k: number): number {
  const h = hunks[k];
  if (k === 0) return Math.max(0, h.oldStart - 1);
  const prev = hunks[k - 1];
  return Math.max(0, h.oldStart - (prev.oldStart + prev.oldLines));
}

/** Index in `lines` of each change run start, for next/previous change keys. */
export function changeStarts(lines: DiffLine[]): number[] {
  const out: number[] = [];
  lines.forEach((l, i) => {
    if (l.type !== "context" && (i === 0 || lines[i - 1].type === "context")) out.push(i);
  });
  return out;
}

/**
 * The open argument `base=<X>` means "changes since the merge base with X": a
 * branch or ref name becomes merge-base:<X>; a full 40-hex SHA stays a direct
 * comparison. The field in the view keeps the explicit forms.
 */
export function initialBase(arg: string | undefined): string {
  const b = (arg ?? "").trim();
  if (!b || /^[0-9a-f]{40}$/i.test(b) || b.startsWith("merge-base:")) return b;
  return `merge-base:${b}`;
}

