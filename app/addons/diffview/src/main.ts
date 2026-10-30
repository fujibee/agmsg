import "./style.css";
import { app, errorText } from "../../_shared/kit";
import type { DiffFile, DiffHunk, DiffLine, DiffResult, DiffStatus } from "../../../addon-kit/protocol";
import { h } from "../../_shared/dom";
import { loadingView, setBusy, withBusy } from "../../_shared/busy";
import { baseName, rootLabel } from "../../_shared/format";
import { gapBefore, initialBase, sideBySide, wordDiff, type Range } from "./diff";

type Mode = "unified" | "split";

const LETTER: Record<DiffStatus, string> = { added: "A", modified: "M", deleted: "D", renamed: "R", copied: "C", typechange: "T" };

const state = {
  result: null as DiffResult | null,
  selected: 0,
  mode: "unified" as Mode,
  base: "",
  filter: "",
  whole: new Set<string>(), // files shown with all their lines
  loadSeq: 0, // bumped by every comparison; an older answer is dropped
  wholeSeq: new Map<string, number>(), // per file: the newest "Whole file" request
  hunk: -1,
};

const root = document.getElementById("root")!;
const totals = h("span", { class: "totals" });
const compare = h("span", { class: "dim" });
const fileList = h("div", { class: "files", role: "listbox", tabindex: "0", "aria-label": "Changed files" });
const fhead = h("div", { class: "fhead" });
const diffEl = h("div", { class: "diff", tabindex: "0" });
let reloadBtn: HTMLButtonElement | null = null; // the ⟳ button: busy while a comparison is running

function notice(title: string, text: string, error = false): HTMLElement {
  return h("div", { class: `notice${error ? " error" : ""}` }, h("h2", null, title), h("div", null, text));
}

// ---- text with word-level marks ----

function withMarks(text: string, ranges: Range[] | undefined): DocumentFragment {
  const frag = document.createDocumentFragment();
  if (!ranges || !ranges.length) {
    frag.append(text || " ");
    return frag;
  }
  let at = 0;
  for (const r of ranges) {
    if (r.start > at) frag.append(text.slice(at, r.start));
    frag.append(h("mark", { class: "w" }, text.slice(r.start, r.end)));
    at = r.end;
  }
  if (at < text.length) frag.append(text.slice(at));
  return frag;
}

/** Pair each run of deleted lines with the added lines after it, for word marks. */
function wordMarks(lines: DiffLine[]): Map<DiffLine, Range[]> {
  const out = new Map<DiffLine, Range[]>();
  let i = 0;
  while (i < lines.length) {
    const dels: DiffLine[] = [];
    const adds: DiffLine[] = [];
    while (i < lines.length && lines[i].type === "del") dels.push(lines[i++]);
    while (i < lines.length && lines[i].type === "add") adds.push(lines[i++]);
    if (!dels.length && !adds.length) { i++; continue; }
    for (let k = 0; k < Math.min(dels.length, adds.length); k++) {
      const w = wordDiff(dels[k].text, adds[k].text);
      out.set(dels[k], w.a);
      out.set(adds[k], w.b);
    }
  }
  return out;
}

// ---- rendering one file ----

function gapRow(cols: number, gap: number, h0: DiffHunk): HTMLTableRowElement {
  const label = gap > 0 ? `⋯ ${gap} unchanged line${gap === 1 ? "" : "s"}` : "";
  const sec = h0.section ? ` ${h0.section}` : "";
  return h("tr", { class: "gap" }, h("td", { colspan: cols }, `${label}${sec}`.trim() || "⋯"));
}

function unifiedTable(f: DiffFile): HTMLTableElement {
  const tb = h("tbody");
  f.hunks.forEach((hunk, k) => {
    const gap = gapBefore(f.hunks, k);
    if (gap > 0 || hunk.section) tb.append(gapRow(4, gap, hunk));
    const marks = wordMarks(hunk.lines);
    hunk.lines.forEach((l, i) => {
      const tr = h("tr", { class: `${l.type}${l.noEol ? " noeol" : ""}`, ...(i === 0 ? { "data-hunk": String(k) } : {}) },
        h("td", { class: "no" }, l.oldNo === null ? "" : String(l.oldNo)),
        h("td", { class: "no" }, l.newNo === null ? "" : String(l.newNo)),
        h("td", { class: "sg" }, l.type === "add" ? "+" : l.type === "del" ? "−" : ""),
        h("td", { class: "tx" }, withMarks(l.text, marks.get(l))),
      );
      tb.append(tr);
    });
  });
  const t = h("table", { class: "d" }, tb);
  const cg = h("colgroup", null, h("col", { style: "width:5.5ch" }), h("col", { style: "width:5.5ch" }), h("col", { style: "width:2ch" }), h("col"));
  t.prepend(cg);
  return t;
}

function splitTable(f: DiffFile): HTMLTableElement {
  const tb = h("tbody");
  f.hunks.forEach((hunk, k) => {
    const gap = gapBefore(f.hunks, k);
    if (gap > 0 || hunk.section) tb.append(gapRow(5, gap, hunk));
    const marks = wordMarks(hunk.lines);
    sideBySide(hunk.lines).forEach((row, i) => {
      const cell = (l: DiffLine | null) => {
        const n = l ? (l.type === "add" ? l.newNo : l.oldNo) : null;
        return [
          h("td", { class: "no" }, n === null ? "" : String(n)),
          h("td", { class: "tx" }, l ? withMarks(l.text, marks.get(l)) : ""),
        ];
      };
      const cls = row.left && row.right && row.left.type === "context" ? "" : "chg";
      const tr = h("tr", { class: cls, ...(i === 0 ? { "data-hunk": String(k) } : {}) },
        ...cell(row.left), h("td", { class: "mid" }), ...cell(row.right));
      // colour each half by its own line type
      const [lno, ltx, , rno, rtx] = [...tr.children] as HTMLElement[];
      if (row.left && row.left.type === "del") { lno.classList.add("delc"); ltx.classList.add("delc"); }
      if (row.right && row.right.type === "add") { rno.classList.add("addc"); rtx.classList.add("addc"); }
      if (!row.left) { lno.classList.add("emptyc"); ltx.classList.add("emptyc"); }
      if (!row.right) { rno.classList.add("emptyc"); rtx.classList.add("emptyc"); }
      tb.append(tr);
    });
  });
  const t = h("table", { class: "d sbs" }, tb);
  t.prepend(h("colgroup", null, h("col", { style: "width:5.5ch" }), h("col"), h("col", { style: "width:1px" }), h("col", { style: "width:5.5ch" }), h("col")));
  return t;
}

function renderFile(): void {
  const r = state.result;
  const f = r?.files[state.selected];
  state.hunk = -1;
  if (!r || !f) {
    fhead.replaceChildren();
    diffEl.replaceChildren(h("div", { class: "empty" }, r && r.files.length ? "Select a file." : ""));
    return;
  }
  const name = f.oldPath && f.oldPath !== f.path ? `${f.oldPath} → ${f.path}` : f.path;
  const whole = h("button", { "aria-pressed": String(state.whole.has(f.path)), title: "Show every line of this file, not just the changes" },
    "Whole file");
  whole.addEventListener("click", () => void withBusy(whole, () => toggleWhole(f)));
  fhead.replaceChildren(
    h("span", { class: `st ${f.status}`, title: f.status }, LETTER[f.status]),
    h("span", null, name),
    h("span", { class: "spacer" }),
    h("span", { class: "add" }, `+${f.additions}`), h("span", { class: "del" }, `−${f.deletions}`),
    ...(f.binary || f.tooLarge ? [] : [whole]),
  );
  diffEl.scrollTop = 0;
  if (f.binary) return void diffEl.replaceChildren(notice("Binary file", "Not shown as text."));
  if (f.tooLarge) return void diffEl.replaceChildren(notice("File too large to compare here", `+${f.additions} −${f.deletions} lines.`));
  if (!f.hunks.length) {
    const why = f.status === "renamed" || f.status === "copied" ? `${f.status}${f.similarity !== undefined ? `, ${f.similarity}% similar` : ""}, no content changes` : f.oldMode && f.newMode && f.oldMode !== f.newMode ? `mode ${f.oldMode} → ${f.newMode}` : "no content changes";
    return void diffEl.replaceChildren(notice("Nothing to show", why));
  }
  diffEl.replaceChildren(state.mode === "split" ? splitTable(f) : unifiedTable(f));
}

async function toggleWhole(f: DiffFile): Promise<void> {
  const r = state.result;
  if (!r) return;
  const path = f.path;
  const on = !state.whole.has(path);
  const seq = (state.wholeSeq.get(path) ?? 0) + 1;
  state.wholeSeq.set(path, seq);
  try {
    const part = await app.git.diff({ ...req(), path, context: on ? "all" : undefined });
    // Drop the answer if the comparison was replaced, or this file was asked again.
    if (state.result !== r || state.wholeSeq.get(path) !== seq) return;
    const nf = part.files.find((x) => x.path === path);
    if (!nf) return;
    const idx = r.files.findIndex((x) => x.path === path);
    if (idx < 0) return;
    r.files[idx] = nf;
    if (on) state.whole.add(path); else state.whole.delete(path);
    if (idx === state.selected) renderFile(); // another file may be showing by now
  } catch (e) {
    if (state.result === r && r.files[state.selected]?.path === path) {
      diffEl.replaceChildren(notice("Can't load the whole file", errorText(e), true));
    }
  }
}

// ---- file list ----

function renderList(): void {
  const r = state.result;
  fileList.replaceChildren();
  if (!r) return;
  const f = state.filter.toLowerCase();
  r.files.forEach((file, i) => {
    if (f && !file.path.toLowerCase().includes(f)) return;
    const row = h("div", { class: "file", role: "option", "aria-selected": String(i === state.selected), "data-i": String(i), title: file.path },
      h("span", { class: `st ${file.status}` }, LETTER[file.status]),
      h("span", { class: "nm" }, h("bdi", null, file.path)),
      h("span", { class: "cnt" }, h("span", { class: "add" }, `+${file.additions}`), " ", h("span", { class: "del" }, `−${file.deletions}`)),
    );
    row.addEventListener("click", () => select(i));
    fileList.append(row);
  });
  if (r.truncated) fileList.append(h("div", { class: "empty" }, "The file list was cut off. Narrow the comparison."));
}

function select(i: number): void {
  const r = state.result;
  if (!r || i < 0 || i >= r.files.length) return;
  state.selected = i;
  for (const row of fileList.querySelectorAll<HTMLElement>(".file")) {
    const on = Number(row.dataset.i) === i;
    row.setAttribute("aria-selected", String(on));
    if (on) row.scrollIntoView({ block: "nearest" });
  }
  renderFile();
}

function stepFile(d: number): void {
  const r = state.result;
  if (!r) return;
  const f = state.filter.toLowerCase();
  for (let i = state.selected + d; i >= 0 && i < r.files.length; i += d) {
    if (!f || r.files[i].path.toLowerCase().includes(f)) return select(i);
  }
}

function stepHunk(d: number): void {
  const starts = [...diffEl.querySelectorAll<HTMLElement>("[data-hunk]")];
  if (!starts.length) return;
  state.hunk = Math.max(0, Math.min(starts.length - 1, state.hunk + d));
  for (const s of starts) s.classList.remove("focus-hunk");
  const t = starts[state.hunk];
  t.classList.add("focus-hunk");
  t.scrollIntoView({ block: "center" });
}

// ---- loading ----

function req() {
  const base = state.base.trim();
  return base ? { base } : {};
}

async function load(): Promise<void> {
  const seq = ++state.loadSeq;
  diffEl.replaceChildren(loadingView("Loading…"));
  if (reloadBtn) setBusy(reloadBtn, true);
  state.whole.clear();
  state.wholeSeq.clear();
  try {
    const r = await app.git.diff({ ...req() });
    if (seq !== state.loadSeq) return; // a newer comparison was started
    state.result = r;
    state.selected = 0;
    const files = r.files.length;
    totals.replaceChildren(`${files} file${files === 1 ? "" : "s"} `, h("span", { class: "add" }, `+${r.additions}`), " ", h("span", { class: "del" }, `−${r.deletions}`));
    compare.textContent = `${r.base.rev} (${r.base.sha.slice(0, 7)}) → ${r.head.worktree ? "working tree" : `${r.head.rev ?? ""} (${(r.head.sha ?? "").slice(0, 7)})`}`;
    renderList();
    if (!files) {
      fhead.replaceChildren();
      diffEl.replaceChildren(notice("No changes", `Nothing differs: ${compare.textContent}.`));
    } else {
      renderFile();
    }
  } catch (e) {
    if (seq !== state.loadSeq) return;
    state.result = null;
    totals.replaceChildren();
    compare.textContent = "";
    fileList.replaceChildren();
    fhead.replaceChildren();
    diffEl.replaceChildren(notice("Can't compare", errorText(e), true));
  } finally {
    // Busy ends with the newest comparison, whether it worked or not (an older one finishing leaves it on).
    if (seq === state.loadSeq && reloadBtn) setBusy(reloadBtn, false);
  }
}

// ---- shell ----

async function main(): Promise<void> {
  let args;
  try {
    args = await app.openArgs();
  } catch (e) {
    root.replaceChildren(notice("Can't open", errorText(e), true));
    return;
  }
  state.base = initialBase(args.base);
  // No path when the folder was chosen in the app's dialog: use the granted root's own name.
  const rootName = args.path ? undefined : await app.fs.stat(".").then((e) => e.name, () => undefined);
  const label = args.path ? baseName(args.path.replace(/\/+$/, "")) || args.path : rootLabel(undefined, rootName, "repository");
  document.title = `Diff view: ${label}`;

  const baseInput = h("input", { class: "rev", type: "text", value: state.base, placeholder: "HEAD",
    "aria-label": "Base revision: branch, SHA or merge-base:<branch>", spellcheck: "false" });
  const apply = () => { state.base = baseInput.value; void load(); };
  baseInput.addEventListener("keydown", (e) => { if (e.key === "Enter") apply(); e.stopPropagation(); });
  const reload = h("button", { title: "Compare again" }, "⟳");
  reloadBtn = reload;
  reload.addEventListener("click", apply);

  const uni = h("button", { "aria-pressed": "true" }, "Unified");
  const spl = h("button", { "aria-pressed": "false" }, "Side by side");
  const setMode = (m: Mode) => {
    state.mode = m;
    uni.setAttribute("aria-pressed", String(m === "unified"));
    spl.setAttribute("aria-pressed", String(m === "split"));
    renderFile();
  };
  uni.addEventListener("click", () => setMode("unified"));
  spl.addEventListener("click", () => setMode("split"));

  const search = h("input", { type: "search", placeholder: "Filter files", "aria-label": "Filter changed files" });
  search.addEventListener("input", () => { state.filter = search.value.trim(); renderList(); });
  search.addEventListener("keydown", (e) => e.stopPropagation());

  const bar = h("div", { class: "bar" },
    h("span", { class: "title", title: label }, label),
    h("label", null, "Base", baseInput), reload,
    compare, h("span", { class: "spacer" }), totals,
    h("span", { class: "group" }, uni, spl),
  );
  const side = h("div", { class: "side" }, search, fileList);
  root.replaceChildren(bar, h("div", { class: "split" }, side, h("div", { class: "main" }, fhead, diffEl)));

  document.addEventListener("keydown", (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    switch (e.key) {
      case "n": stepFile(1); break;
      case "p": stepFile(-1); break;
      case "j": stepHunk(1); break;
      case "k": stepHunk(-1); break;
      default: return;
    }
    e.preventDefault();
  });

  await load();
}

void main();
