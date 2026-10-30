import { app, errorText } from "../../_shared/kit";
import type { FsEntry } from "../../../addon-kit/protocol";
import { clear, h } from "../../_shared/dom";
import { loadingView, spinner } from "../../_shared/busy";
import { baseName, dirName, formatBytes, toBytes } from "../../_shared/format";
import { highlight, imageType, isMarkdown, languageFor } from "./lang";
import { LineBuffer, looksBinary, splitHighlighted } from "./lines";
import { renderMarkdown } from "./markdown";
import { resolveRelative } from "./paths";

const CHUNK = 256 * 1024; // one fs.read page of a text file
const HIGHLIGHT_MAX = 1024 * 1024; // beyond this a file is shown as plain text
const IMAGE_MAX = 10 * 1024 * 1024; // the broker's cap for one read
const MARKDOWN_MAX = 2 * 1024 * 1024; // rendered view needs the whole file

async function readChunk(path: string, offset?: number, length?: number): Promise<{ bytes: Uint8Array; eof: boolean }> {
  const r = await app.fs.read(path, offset === undefined ? undefined : { offset, length: length as number });
  return { bytes: toBytes(r), eof: r.eof };
}

async function readBytes(path: string, offset?: number, length?: number): Promise<Uint8Array> {
  return (await readChunk(path, offset, length)).bytes;
}

export class Viewer {
  readonly el: HTMLElement;
  private bar: HTMLElement;
  private body: HTMLElement;
  private token = 0;
  private objectUrls: string[] = [];
  private wrap = false;
  private mdSource = false;
  private current: { path: string; entry: FsEntry; name: string } | null = null;
  onNavigate: (path: string) => void = () => {};

  constructor() {
    this.bar = h("div", { class: "bar" });
    this.body = h("div", { class: "viewer", tabindex: "0" });
    this.el = h("div", { class: "main" }, this.bar, this.body);
    this.empty("Select a file to view it.");
  }

  empty(text: string): void {
    this.release();
    this.bar.replaceChildren(h("span", { class: "dim" }, " "));
    this.body.replaceChildren(h("div", { class: "empty" }, text));
  }

  private release(): void {
    this.token++;
    for (const u of this.objectUrls) URL.revokeObjectURL(u);
    this.objectUrls = [];
  }

  private blobUrl(bytes: Uint8Array, type: string): string {
    const u = URL.createObjectURL(new Blob([bytes as BlobPart], { type }));
    this.objectUrls.push(u);
    return u;
  }

  private notice(title: string, text: string, error = false): void {
    this.body.replaceChildren(h("div", { class: `notice${error ? " error" : ""}` }, h("h2", null, title), h("div", null, text)));
  }

  /**
   * `path` is what the broker is asked for (a single granted file is ".");
   * `name` is what the file is called, and decides how it is shown (image,
   * Markdown, language).
   */
  async open(path: string, entry: FsEntry, name: string = path): Promise<void> {
    this.release();
    const token = this.token;
    this.current = { path, entry, name };
    this.bar.replaceChildren(h("span", { class: "path", title: name }, name), h("span", { class: "dim" }, formatBytes(entry.size)));
    this.body.replaceChildren(loadingView("Loading…"));
    this.body.scrollTop = 0;
    try {
      const img = imageType(name);
      if (img) await this.showImage(path, entry, img, token, name);
      else if (isMarkdown(name) && !this.mdSource && entry.size <= MARKDOWN_MAX) await this.showMarkdown(path, entry, token, name);
      else await this.showText(path, entry, token, name);
    } catch (e) {
      if (token !== this.token) return;
      this.notice("Can't show this file", errorText(e), true);
    }
  }

  private controls(...extra: Node[]): void {
    const spacer = h("span", { class: "spacer" });
    this.bar.querySelectorAll(".ctl").forEach((n) => n.remove());
    const items = [spacer, ...extra];
    for (const n of items) (n as HTMLElement).classList?.add("ctl");
    this.bar.append(...items);
  }

  private async showImage(path: string, entry: FsEntry, type: string, token: number, name: string): Promise<void> {
    if (entry.size > IMAGE_MAX) {
      return this.notice("Image too large to preview", `${formatBytes(entry.size)} (limit ${formatBytes(IMAGE_MAX)}).`);
    }
    const bytes = await readBytes(path);
    if (token !== this.token) return;
    const img = h("img", { alt: baseName(name) });
    img.addEventListener("error", () => this.notice("Can't decode this image", `${baseName(name)} is not a valid ${type} file.`, true));
    img.src = this.blobUrl(bytes, type);
    img.addEventListener("load", () => {
      info.textContent = `${img.naturalWidth} × ${img.naturalHeight}`;
    });
    const info = h("div", { class: "dim" }, "");
    this.body.replaceChildren(h("div", { class: "imgwrap" }, img, info));
  }

  private async showMarkdown(path: string, entry: FsEntry, token: number, name: string): Promise<void> {
    const text = new TextDecoder().decode(await readBytes(path));
    if (token !== this.token) return;
    const doc = h("div", { class: "md" });
    doc.innerHTML = renderMarkdown(text); // markdown-it with html:false escapes raw HTML
    const dir = dirName(name);
    for (const a of doc.querySelectorAll("a")) {
      const href = a.getAttribute("href") || "";
      const target = resolveRelative(dir, href);
      a.addEventListener("click", (ev) => {
        ev.preventDefault(); // a pane never navigates away
        if (target && target !== ".") this.onNavigate(target);
      });
      if (!target) a.title = href; // external: shown, not followed
    }
    for (const img of doc.querySelectorAll("img")) {
      const src = img.getAttribute("src") || "";
      const target = resolveRelative(dir, src);
      img.removeAttribute("src");
      const type = target ? imageType(target) : null;
      if (!target || !type) {
        img.replaceWith(h("span", { class: "dim" }, `[image: ${img.alt || src}]`));
        continue;
      }
      void readBytes(target)
        .then((b) => {
          if (token === this.token) img.src = this.blobUrl(b, type);
        })
        .catch(() => img.replaceWith(h("span", { class: "dim" }, `[image not found: ${img.alt || src}]`)));
    }
    this.body.replaceChildren(doc);
    const toggle = h("button", { "aria-pressed": "false" }, "Source");
    toggle.addEventListener("click", () => {
      this.mdSource = true;
      void this.open(path, entry, name);
    });
    this.controls(toggle);
  }

  private async showText(path: string, entry: FsEntry, token: number, name: string): Promise<void> {
    const total = entry.size;
    const firstRead = await readChunk(path, 0, Math.min(Math.max(total, 1), CHUNK));
    const first = firstRead.bytes;
    if (token !== this.token) return;
    if (looksBinary(first)) {
      return this.notice("Binary file", `${formatBytes(total)}. Not shown as text.`);
    }
    const lang = total <= HIGHLIGHT_MAX ? languageFor(name) : null;
    const code = h("div", { class: `code${this.wrap ? " wrap" : ""}` });
    const more = h("div", { class: "more" });
    this.body.replaceChildren(code, more);

    const buf = new LineBuffer();
    let offset = 0;
    let lineNo = 0;
    let done = false;
    let loading = false;

    const append = (lines: string[]) => {
      let htmls: string[] | null = null;
      if (lang && lines.length) {
        try {
          htmls = splitHighlighted(highlight(lines.join("\n"), lang));
        } catch {
          htmls = null;
        }
      }
      const frag = document.createDocumentFragment();
      lines.forEach((text, i) => {
        const tx = h("span", { class: "tx" });
        if (htmls && htmls[i] !== undefined) tx.innerHTML = htmls[i]; // highlight.js output is escaped
        else tx.textContent = text || " ";
        frag.append(h("div", { class: "ln" }, h("span", { class: "no" }, String(++lineNo)), tx));
      });
      code.append(frag);
    };

    const page = async (bytes: Uint8Array, eof: boolean) => {
      offset += bytes.length;
      done = eof || bytes.length === 0;
      append(buf.push(bytes, done));
    };

    const updateMore = () => {
      clear(more);
      if (done) {
        more.append(h("span", null, `${lineNo} lines`));
        return;
      }
      const btn = h("button", null, "Load more");
      btn.addEventListener("click", () => void loadMore());
      more.append(btn, h("span", null, `${formatBytes(offset)} of ${formatBytes(total)} shown`));
    };

    const loadMore = async () => {
      if (loading || done) return;
      loading = true;
      // Busy: the button (when it was clicked) or a line (when the end scrolled into view) shows the page is coming.
      const btn = more.querySelector("button");
      if (btn) {
        btn.disabled = true;
        btn.setAttribute("aria-busy", "true");
        btn.append(spinner());
      } else {
        more.replaceChildren(h("span", { class: "dim", role: "status" }, "Loading more…", spinner()));
      }
      try {
        const next = await readChunk(path, offset, CHUNK);
        if (token !== this.token) return;
        await page(next.bytes, next.eof);
        updateMore();
      } catch (e) {
        more.replaceChildren(h("span", { class: "dim" }, `Stopped: ${errorText(e)}`));
      } finally {
        loading = false;
      }
    };

    await page(first, firstRead.eof);
    updateMore();
    // Fetch the next page on its own when the end comes into view.
    if (!done && "IntersectionObserver" in window) {
      const io = new IntersectionObserver((es) => {
        if (token !== this.token) return io.disconnect();
        if (es.some((e) => e.isIntersecting)) void loadMore().then(() => done && io.disconnect());
      }, { root: this.body });
      io.observe(more);
    }

    const wrapBtn = h("button", { "aria-pressed": String(this.wrap) }, "Wrap");
    wrapBtn.addEventListener("click", () => {
      this.wrap = !this.wrap;
      wrapBtn.setAttribute("aria-pressed", String(this.wrap));
      code.classList.toggle("wrap", this.wrap);
    });
    const extra: Node[] = [h("span", { class: "dim" }, lang ?? "plain text"), wrapBtn];
    if (isMarkdown(name) && this.mdSource) {
      const rendered = h("button", null, "Rendered");
      rendered.addEventListener("click", () => {
        this.mdSource = false;
        void this.open(path, entry, name);
      });
      extra.push(rendered);
    }
    this.controls(...extra);
  }

  reopenCurrent(): void {
    if (this.current) void this.open(this.current.path, this.current.entry, this.current.name);
  }
}
