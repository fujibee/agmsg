import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { BusyButton, BusyTracker, LoadingView } from "./busy";
import { readSource } from "./readSource";

const appCss = readSource("./App.css", import.meta.url);

describe("BusyTracker", () => {
  const rig = () => {
    const seen: string[][] = [];
    return { seen, t: new BusyTracker((k) => seen.push([...k].sort())) };
  };
  it("is busy while the work runs and clear after", async () => {
    const { t, seen } = rig();
    let release!: () => void;
    const p = t.run("a", () => new Promise<void>((r) => (release = r)));
    expect(t.has("a")).toBe(true);
    release();
    await p;
    expect(t.has("a")).toBe(false);
    expect(seen).toEqual([["a"], []]);
  });
  it("a failure also ends the busy state, and the error still reaches the caller", async () => {
    const { t } = rig();
    await expect(t.run("a", async () => Promise.reject(new Error("boom")))).rejects.toThrow("boom");
    expect(t.has("a")).toBe(false);
  });
  it("a second start of the same key is ignored while it runs; other keys run at once", async () => {
    const { t } = rig();
    let n = 0;
    let release!: () => void;
    const first = t.run("a", () => new Promise<void>((r) => ((n += 1), (release = r))));
    expect(await t.run("a", async () => void (n += 10))).toBeUndefined();
    const other = t.run("b", async () => void (n += 100));
    release();
    await Promise.all([first, other]);
    expect(n).toBe(101);
  });
});

describe("BusyButton", () => {
  it("busy: disabled, aria-busy and a spinner; not busy: a plain button", () => {
    const on = renderToStaticMarkup(createElement(BusyButton, { busy: true, className: "x" }, "Save"));
    expect(on).toContain('aria-busy="true"');
    expect(on).toContain("disabled");
    expect(on).toContain("busy-spinner");
    const off = renderToStaticMarkup(createElement(BusyButton, { busy: false }, "Save"));
    expect(off).not.toContain("aria-busy");
    expect(off).not.toContain("disabled");
    expect(off).not.toContain("busy-spinner");
  });
  it("stays disabled when it was disabled for another reason", () => {
    expect(renderToStaticMarkup(createElement(BusyButton, { disabled: true }, "Save"))).toContain("disabled");
  });
});

describe("the spinner", () => {
  it("is shown only after a short delay and stops moving for people who ask for less motion", () => {
    expect(appCss.length).toBeGreaterThan(0);
    expect(appCss).toMatch(/\.busy-spinner\s*\{[^}]*animation:[^}]*150ms/);
    expect(appCss).toMatch(/prefers-reduced-motion[^{]*\{[\s\S]*?\.busy-spinner/);
  });
  it("a loading view announces itself as a status", () => {
    expect(renderToStaticMarkup(createElement(LoadingView, { text: "Opening…" }))).toMatch(/role="status"[^>]*>.*busy-spinner.*Opening…/);
  });
});
