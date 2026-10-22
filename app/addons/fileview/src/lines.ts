/**
 * Split highlight.js output into one HTML string per line. A <span> that is
 * open at a line break is closed there and reopened on the next line, so every
 * line is well-formed on its own.
 */
export function splitHighlighted(html: string): string[] {
  const lines: string[] = [];
  const open: string[] = [];
  let cur = "";
  const re = /<span[^>]*>|<\/span>|\n|[^<\n]+|</g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html))) {
    const t = m[0];
    if (t === "\n") {
      lines.push(cur + "</span>".repeat(open.length));
      cur = open.join("");
    } else if (t.startsWith("<span")) {
      open.push(t);
      cur += t;
    } else if (t === "</span>") {
      open.pop();
      cur += t;
    } else {
      cur += t;
    }
  }
  lines.push(cur + "</span>".repeat(open.length));
  return lines;
}

/** Looks like binary: a NUL byte near the start, or a lot of undecodable bytes. */
export function looksBinary(bytes: Uint8Array): boolean {
  const n = Math.min(bytes.length, 8000);
  for (let i = 0; i < n; i++) if (bytes[i] === 0) return true;
  return false;
}

/**
 * Carries a partial last line from one chunk to the next, so a file can be
 * decoded and rendered a page at a time.
 */
export class LineBuffer {
  private decoder = new TextDecoder("utf-8");
  private rest = "";

  /** Feed bytes; returns the complete lines they finished. */
  push(bytes: Uint8Array, last: boolean): string[] {
    const text = this.rest + this.decoder.decode(bytes, { stream: !last });
    const parts = text.split("\n");
    this.rest = last ? "" : (parts.pop() as string);
    if (last && parts.length && parts[parts.length - 1] === "") parts.pop();
    return parts.map((l) => (l.endsWith("\r") ? l.slice(0, -1) : l));
  }
}
