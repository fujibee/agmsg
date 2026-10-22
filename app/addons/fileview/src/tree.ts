import { app, errorText } from "../../_shared/kit";
import type { FsEntry } from "../../../addon-kit/protocol";
import { h } from "../../_shared/dom";
import { formatBytes, joinPath } from "../../_shared/format";

export function sortEntries(entries: FsEntry[]): FsEntry[] {
  return [...entries].sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === "dir" ? -1 : 1;
    return a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });
  });
}

interface Node {
  path: string;
  entry: FsEntry;
  row: HTMLElement;
  children?: HTMLUListElement;
  loaded: boolean;
}

/**
 * Lazy file tree. Folders load on first expand; keyboard: arrows move, right /
 * left open / close or step in / out, Enter or Space opens.
 */
export class Tree {
  readonly el: HTMLElement;
  private rootList: HTMLUListElement;
  private nodes = new Map<string, Node>();
  private selected: Node | null = null;
  private filter = "";
  onOpen: (path: string, entry: FsEntry) => void = () => {};

  constructor() {
    this.rootList = h("ul", { role: "group" });
    const search = h("input", { type: "search", placeholder: "Filter loaded files", "aria-label": "Filter loaded files" });
    search.addEventListener("input", () => {
      this.filter = search.value.trim().toLowerCase();
      this.applyFilter();
    });
    const tree = h("div", { class: "tree", role: "tree", tabindex: "0" }, this.rootList);
    tree.addEventListener("keydown", (e) => this.onKey(e));
    this.el = h("div", { class: "side" }, search, tree);
  }

  async loadRoot(): Promise<void> {
    await this.loadChildren(".", this.rootList);
  }

  private async loadChildren(dir: string, into: HTMLUListElement): Promise<void> {
    let list;
    try {
      list = await app.fs.list(dir);
    } catch (e) {
      into.replaceChildren(h("li", { class: "child-note", role: "none" }, `Could not list: ${errorText(e)}`));
      throw e;
    }
    into.replaceChildren();
    for (const entry of sortEntries(list.entries)) into.append(this.makeNode(dir, entry));
    if (list.truncated) {
      into.append(h("li", { class: "child-note", role: "none" }, "This folder has more entries than can be listed; only the first are shown."));
    }
    this.applyFilter();
  }

  private makeNode(dir: string, entry: FsEntry): HTMLLIElement {
    const path = joinPath(dir, entry.name);
    const isDir = entry.kind === "dir";
    const twist = h("span", { class: "twist", "aria-hidden": "true" }, isDir ? "▸" : "");
    const row = h(
      "div",
      { class: `row ${isDir ? "dir" : "file"}`, role: "treeitem", "data-path": path, "aria-selected": "false",
        ...(isDir ? { "aria-expanded": "false" } : {}) },
      twist,
      h("span", { class: "name", title: path }, entry.name),
      !isDir && h("span", { class: "size" }, formatBytes(entry.size)),
    );
    row.style.paddingLeft = `${6 + 14 * (path.split("/").length - 1)}px`;
    const li = h("li", { role: "none" }, row);
    const node: Node = { path, entry, row, loaded: false };
    this.nodes.set(path, node);
    row.addEventListener("click", () => void this.activate(node));
    return li;
  }

  private async activate(node: Node): Promise<void> {
    this.select(node);
    if (node.entry.kind === "dir") await this.toggle(node);
    else this.onOpen(node.path, node.entry);
  }

  private select(node: Node): void {
    this.selected?.row.setAttribute("aria-selected", "false");
    this.selected = node;
    node.row.setAttribute("aria-selected", "true");
    node.row.scrollIntoView({ block: "nearest" });
  }

  private async toggle(node: Node, open?: boolean): Promise<void> {
    const expanded = node.row.getAttribute("aria-expanded") === "true";
    const want = open ?? !expanded;
    if (want === expanded) return;
    const twist = node.row.firstElementChild as HTMLElement;
    if (!want) {
      node.children?.setAttribute("hidden", "");
      node.row.setAttribute("aria-expanded", "false");
      twist.textContent = "▸";
      return;
    }
    if (!node.children) {
      node.children = h("ul", { role: "group" });
      node.row.parentElement!.append(node.children);
    }
    node.children.removeAttribute("hidden");
    node.row.setAttribute("aria-expanded", "true");
    twist.textContent = "▾";
    if (!node.loaded) {
      node.loaded = true;
      try {
        await this.loadChildren(node.path, node.children);
      } catch {
        node.loaded = false; // shown in the list; collapse and expand again to retry
      }
    }
  }

  /** Expand the folders down to `path` and select it. */
  async reveal(path: string): Promise<void> {
    const parts = path.split("/");
    let cur = "";
    for (let i = 0; i < parts.length - 1; i++) {
      cur = joinPath(cur || ".", parts[i]);
      const n = this.nodes.get(cur);
      if (!n) return;
      await this.toggle(n, true);
    }
    const target = this.nodes.get(path);
    if (target) this.select(target);
  }

  private visibleRows(): HTMLElement[] {
    return [...this.el.querySelectorAll<HTMLElement>(".row")].filter((r) => {
      for (let p: HTMLElement | null = r; p && p !== this.el; p = p.parentElement) if (p.hidden) return false;
      return true;
    });
  }

  private onKey(e: KeyboardEvent): void {
    const rows = this.visibleRows();
    if (!rows.length) return;
    const cur = this.selected ? rows.indexOf(this.selected.row) : -1;
    const go = (i: number) => {
      const n = this.nodes.get(rows[Math.max(0, Math.min(rows.length - 1, i))].dataset.path!);
      if (n) this.select(n);
    };
    const node = this.selected;
    switch (e.key) {
      case "ArrowDown": go(cur + 1); break;
      case "ArrowUp": go(cur < 0 ? 0 : cur - 1); break;
      case "Home": go(0); break;
      case "End": go(rows.length - 1); break;
      case "ArrowRight":
        if (node?.entry.kind === "dir") {
          if (node.row.getAttribute("aria-expanded") === "true") go(cur + 1);
          else void this.toggle(node, true);
        }
        break;
      case "ArrowLeft":
        if (node?.entry.kind === "dir" && node.row.getAttribute("aria-expanded") === "true") void this.toggle(node, false);
        else if (node) {
          const parent = this.nodes.get(node.path.includes("/") ? node.path.slice(0, node.path.lastIndexOf("/")) : "");
          if (parent) this.select(parent);
        }
        break;
      case "Enter":
      case " ":
        if (node) void this.activate(node);
        break;
      default: return;
    }
    e.preventDefault();
  }

  private applyFilter(): void {
    const f = this.filter;
    // Show a row if its name matches, or it is a folder holding a match.
    const keep = new Set<string>();
    if (f) {
      for (const [path, n] of this.nodes) {
        if (n.entry.name.toLowerCase().includes(f)) {
          for (let p = path; ; p = p.slice(0, p.lastIndexOf("/"))) {
            keep.add(p);
            if (!p.includes("/")) break;
          }
        }
      }
    }
    for (const [path, n] of this.nodes) {
      (n.row.parentElement as HTMLElement).hidden = f !== "" && !keep.has(path);
    }
  }
}
