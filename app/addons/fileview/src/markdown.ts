import MarkdownIt from "markdown-it";
import { highlight } from "./lang";

// html:false means raw HTML in the document is shown as text, never parsed.
const md: MarkdownIt = new MarkdownIt({
  html: false,
  linkify: false,
  highlight(code, lang) {
    if (!lang) return "";
    try {
      return `<pre class="hl"><code>${highlight(code, lang === "sh" ? "bash" : lang)}</code></pre>`;
    } catch {
      return ""; // unknown language: markdown-it falls back to escaped text
    }
  },
});

export function renderMarkdown(src: string): string {
  return md.render(src);
}
