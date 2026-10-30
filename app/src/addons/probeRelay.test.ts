// Runs the startup probe's relay (the code the app evaluates in the main page) against a small fake
// page: one instance per probe, so a failed or timed-out probe followed by "Check again" works, and
// nothing left over from an old probe can touch the new one.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore: vite's ?raw import
import relaySource from "../../src-tauri/src/addons/probe/relay.js?raw";

type Listener = (e: any) => void;
type Frame = { src: string; parentNode: object | null; contentWindow: { name: string }; remove(): void; setAttribute(): void; style: { cssText: string }; id: string };

function fakePage() {
  const winL: Record<string, Listener[]> = {};
  const docL: Record<string, Listener[]> = {};
  const frames: Frame[] = [];
  const reports: any[] = [];
  const body = {
    appendChild(f: Frame) {
      f.parentNode = body;
      frames.push(f);
    },
  };
  const add = (m: Record<string, Listener[]>) => (t: string, l: Listener) => void (m[t] ||= []).push(l);
  const del = (m: Record<string, Listener[]>) => (t: string, l: Listener) => void (m[t] = (m[t] || []).filter((x) => x !== l));
  const win: any = {
    addEventListener: add(winL),
    removeEventListener: del(winL),
    __TAURI_INTERNALS__: { invoke: (cmd: string, args: any) => (reports.push({ cmd, ...args }), Promise.resolve({})) },
  };
  const doc: any = {
    body,
    addEventListener: add(docL),
    removeEventListener: del(docL),
    createElement: () => {
      const f: Frame = { src: "", parentNode: null, contentWindow: { name: "frame" + frames.length }, id: "", style: { cssText: "" }, setAttribute() {}, remove() { f.parentNode = null; } };
      return f;
    },
  };
  const start = (target: string, wait = 2600) => {
    const code = (relaySource as string).replace("__TARGET__", JSON.stringify(target)).replace("__SRC__", JSON.stringify("http://127.0.0.1:1/t/#x")).replace("__FINAL_WAIT_MS__", String(wait));
    new Function("window", "document", code)(win, doc);
    return frames[frames.length - 1];
  };
  const fromFrame = (f: Frame, data: any) => (winL.message || []).slice().forEach((l) => l({ source: f.contentWindow, data }));
  const violation = (uri: string, directive = "frame-src") => (docL.securitypolicyviolation || []).slice().forEach((l) => l({ disposition: "enforce", effectiveDirective: directive, blockedURI: uri }));
  return { start, fromFrame, violation, frames, reports, count: () => (winL.message || []).length + (docL.securitypolicyviolation || []).length };
}

const report = (nonce: string, extra: object = {}) => ({ agmsgProbe: 1, report: { nonce, started: true, controlNavOk: true, ...extra } });

describe("probe relay", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("relays the final answer with the violation seen for its own target", () => {
    const p = fakePage();
    const f = p.start("T1");
    p.fromFrame(f, { ...report("n1"), final: false });
    p.violation("T1");
    p.fromFrame(f, { ...report("n1", { navRefused: true }), final: true });
    expect(p.reports).toHaveLength(1);
    expect(p.reports[0].report).toMatchObject({ nonce: "n1", navViolationDirective: "frame-src", navViolationUri: "T1", navRefused: true });
    expect(p.reports[0].report.finalMissing).toBeUndefined();
    expect(f.parentNode).toBeNull();
    vi.advanceTimersByTime(10000);
    expect(p.reports).toHaveLength(1);
    expect(p.count()).toBe(0);
  });

  it("submits the interim answer marked final_missing when the final one never comes", () => {
    const p = fakePage();
    const f = p.start("T1", 2600);
    p.violation("T1");
    p.fromFrame(f, { ...report("n1"), final: false });
    vi.advanceTimersByTime(2599);
    expect(p.reports).toHaveLength(0);
    vi.advanceTimersByTime(2);
    expect(p.reports).toHaveLength(1);
    expect(p.reports[0].report).toMatchObject({ nonce: "n1", finalMissing: true, navViolationUri: "T1" });
  });

  it("ignores answers from any other window and violations of another target", () => {
    const p = fakePage();
    const f = p.start("T1");
    (p as any).fromFrame({ contentWindow: { name: "stranger" } }, { ...report("n1"), final: true });
    p.violation("T-other");
    p.violation("T1", "img-src");
    p.fromFrame(f, { ...report("n1"), final: true });
    expect(p.reports[0].report).toMatchObject({ navViolationDirective: "", navViolationUri: "" });
  });

  it("a check that timed out can be run again: the new probe sees its own violation and its answer", () => {
    const p = fakePage();
    const f1 = p.start("T1");
    p.fromFrame(f1, { ...report("n1"), final: false });
    // the old probe's gate deadline passes with no answer; the user presses Check again
    const f2 = p.start("T2");
    expect(f1.parentNode).toBeNull();
    p.violation("T2");
    p.fromFrame(f2, { ...report("n2"), final: false });
    p.fromFrame(f2, { ...report("n2", { navRefused: true }), final: true });
    expect(p.reports).toHaveLength(1);
    expect(p.reports[0].report).toMatchObject({ nonce: "n2", navViolationDirective: "frame-src", navViolationUri: "T2" });
  });

  it("a late timer or answer of the old probe cannot remove or answer for the new frame", () => {
    const p = fakePage();
    const f1 = p.start("T1", 2600);
    p.fromFrame(f1, { ...report("n1"), final: false }); // the old interim timer is now pending
    vi.advanceTimersByTime(1000);
    const f2 = p.start("T2", 2600);
    vi.advanceTimersByTime(5000); // the old timer's moment passes
    expect(p.reports).toHaveLength(0);
    expect(f2.parentNode).not.toBeNull();
    p.fromFrame(f1, { ...report("n1"), final: true }); // a late answer of the old frame
    expect(p.reports).toHaveLength(0);
    p.fromFrame(f2, { ...report("n2"), final: false });
    vi.advanceTimersByTime(2700);
    expect(p.reports).toHaveLength(1);
    expect(p.reports[0].report).toMatchObject({ nonce: "n2", finalMissing: true });
  });

  it("keeps one set of listeners however often a probe is started", () => {
    const p = fakePage();
    p.start("T1");
    p.start("T2");
    p.start("T3");
    expect(p.count()).toBe(2); // one message and one violation listener
  });
});
