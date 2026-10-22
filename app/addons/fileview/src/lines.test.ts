import { describe, expect, it } from "vitest";
import { LineBuffer, looksBinary, splitHighlighted } from "./lines";

describe("splitHighlighted", () => {
  it("reopens a span that crosses a line break", () => {
    expect(splitHighlighted('<span class="c">a\nb</span>\nc')).toEqual([
      '<span class="c">a</span>',
      '<span class="c">b</span>',
      "c",
    ]);
  });
  it("keeps plain and nested spans well-formed", () => {
    const out = splitHighlighted('<span class="a">x<span class="b">y\nz</span></span>');
    expect(out).toEqual([
      '<span class="a">x<span class="b">y</span></span>',
      '<span class="a"><span class="b">z</span></span>',
    ]);
  });
  it("leaves entities alone", () => {
    expect(splitHighlighted("a &lt; b")).toEqual(["a &lt; b"]);
  });
});

describe("LineBuffer", () => {
  const enc = (s: string) => new TextEncoder().encode(s);
  it("carries a partial line across chunks", () => {
    const b = new LineBuffer();
    expect(b.push(enc("one\ntw"), false)).toEqual(["one"]);
    expect(b.push(enc("o\nthree"), true)).toEqual(["two", "three"]);
  });
  it("does not split a multi-byte character", () => {
    const b = new LineBuffer();
    const bytes = enc("あい\n");
    expect(b.push(bytes.slice(0, 4), false)).toEqual([]);
    expect(b.push(bytes.slice(4), true)).toEqual(["あい"]);
  });
  it("drops the final empty line and CR", () => {
    expect(new LineBuffer().push(enc("a\r\nb\r\n"), true)).toEqual(["a", "b"]);
  });
});

describe("looksBinary", () => {
  it("is true for a NUL byte", () => {
    expect(looksBinary(new Uint8Array([104, 0, 105]))).toBe(true);
    expect(looksBinary(new TextEncoder().encode("plain"))).toBe(false);
  });
});
