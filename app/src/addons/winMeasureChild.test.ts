import { describe, expect, it } from "vitest";
import child from "../../src-tauri/m1/win-measure/addon/app-panes/net/web/child.js?raw";

// The measurement child runs inside srcdoc frames, where location.href is about:srcdoc. Run it with stand-ins for
// the page objects, as it would be where srcdoc is allowed to execute, and check what it does.
function runChild(name: string) {
  const posted: Record<string, unknown>[] = [];
  const frames: { name?: string; srcdoc?: string; onload?: () => void }[] = [];
  const listeners: ((e: { data: unknown }) => void)[] = [];
  const timers: (() => void)[] = [];
  const win: Record<string, unknown> = {
    name,
    addEventListener: (_: string, fn: (e: { data: unknown }) => void) => listeners.push(fn),
    location: { href: "about:srcdoc" },
  };
  const doc = {
    currentScript: { src: "http://127.0.0.1:5000/tok/child.js?n=abc" },
    addEventListener: () => {},
    createElement: () => { const f = {}; frames.push(f); return f; },
    body: { appendChild: () => {} },
  };
  const parent = { postMessage: (m: Record<string, unknown>) => posted.push(m) };
  new Function("window", "document", "parent", "location", "setTimeout", "URL", child)(
    win, doc, parent, win.location, (fn: () => void) => timers.push(fn), URL,
  );
  return { posted, frames, listeners, timers };
}

describe("measurement child", () => {
  it("reports WebRTC names, then creates the nested child from its own script address", () => {
    const r = runChild("srcdoc");
    expect(r.posted.find((m) => m.kind === "realm")).toMatchObject({ label: "srcdoc", present: "" });
    expect(r.posted.some((m) => m.kind === "attempt" && m.label === "nested")).toBe(true);
    expect(r.frames.length).toBe(0); // waits for the parent's acknowledgement
    r.listeners.forEach((l) => l({ data: { agmsg_ack: true } }));
    expect(r.frames.length).toBe(1);
    expect(r.frames[0].srcdoc).toContain("http://127.0.0.1:5000/tok/child.js?n=");
    expect(r.posted.some((m) => m.kind === "realm" && String(m.present).startsWith("threw"))).toBe(false);
  });
  it("creates the nested child once even if the acknowledgement and the timer both fire", () => {
    const r = runChild("srcdoc");
    r.listeners.forEach((l) => l({ data: { agmsg_ack: true } }));
    r.timers.forEach((t) => t());
    expect(r.frames.length).toBe(1);
  });
  it("a nested or other child does not create another level", () => {
    const r = runChild("nested");
    expect(r.frames.length).toBe(0);
    expect(r.posted.some((m) => m.kind === "attempt")).toBe(false);
  });
});
