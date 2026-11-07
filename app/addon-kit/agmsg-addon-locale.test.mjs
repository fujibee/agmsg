// The add-on SDK's language API, against a fake window and a fake port. No DOM.
import { afterEach, describe, expect, it, vi } from "vitest";
import { connect, pickLocale } from "./agmsg-addon.js";

function fakeWindow() {
  const parent = {};
  const listeners = [];
  const w = {
    parent,
    addEventListener: (_t, fn) => listeners.push(fn),
    removeEventListener: (_t, fn) => listeners.splice(listeners.indexOf(fn), 1),
  };
  const port = { onmessage: null, start() {}, postMessage() {} };
  return {
    w,
    handOverPort: () => listeners.slice().forEach((fn) => fn({ source: parent, data: { agmsg: 1, type: "port" }, ports: [port] })),
    emit: (data) => port.onmessage?.({ data }),
  };
}

afterEach(() => vi.unstubAllGlobals());

function app(opts = {}) {
  const f = fakeWindow();
  vi.stubGlobal("window", f.w);
  const a = connect({ errorOverlay: false, sample: false, sampleAfterMs: 30, ...opts });
  f.handOverPort();
  return { a, ...f };
}

const loc = (locale) => ({ agmsg: 1, type: "locale", locale });

describe("app.locale", () => {
  it("is en until the app says otherwise, then follows it", () => {
    const s = app();
    expect(s.a.locale).toBe("en");
    s.emit(loc("ja"));
    expect(s.a.locale).toBe("ja");
    s.emit(loc("pt-BR"));
    expect(s.a.locale).toBe("pt-BR");
  });

  it("fires onLocaleChange once per change, including the first word from the app, and not for a repeat", () => {
    const seen = [];
    const s = app();
    s.a.onLocaleChange((t) => seen.push(t));
    s.emit(loc("en"));
    s.emit(loc("en"));
    s.emit(loc("ja"));
    s.emit(loc("ja"));
    expect(seen).toEqual(["en", "ja"]);
  });

  it("the connect option and an unsubscribed callback behave", () => {
    const opt = [];
    const extra = [];
    const s = app({ onLocale: (t) => opt.push(t) });
    const off = s.a.onLocaleChange((t) => extra.push(t));
    s.emit(loc("de"));
    off();
    s.emit(loc("fr"));
    expect(opt).toEqual(["de", "fr"]);
    expect(extra).toEqual(["de"]);
  });

  it("ignores a locale event that is not a plain language tag", () => {
    const s = app();
    s.emit(loc("ja"));
    for (const bad of ["", "japanese!", "../x", 5, null, undefined, "x".repeat(200)]) s.emit(loc(bad));
    expect(s.a.locale).toBe("ja");
  });

  it("an event type it does not know is still ignored", () => {
    const s = app();
    s.emit({ agmsg: 1, type: "something-new", locale: "ja" });
    expect(s.a.locale).toBe("en");
  });

  it("a throwing callback does not stop the others or the update", () => {
    const seen = [];
    const s = app({ errorOverlay: false });
    vi.stubGlobal("document", {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    s.a.onLocaleChange(() => { throw new Error("boom"); });
    s.a.onLocaleChange((t) => seen.push(t));
    s.emit(loc("ko"));
    expect(seen).toEqual(["ko"]);
    expect(s.a.locale).toBe("ko");
    err.mockRestore();
    vi.unstubAllGlobals();
  });
});

describe("app.localeReady", () => {
  it("resolves with the app's language as soon as it arrives", async () => {
    const s = app();
    s.emit(loc("zh-TW"));
    await expect(s.a.localeReady).resolves.toBe("zh-TW");
  });

  it("resolves with en when nothing arrives (outside the app, or an older app), never hangs", async () => {
    vi.stubGlobal("window", fakeWindow().w);
    const a = connect({ errorOverlay: false, sample: false, sampleAfterMs: 20 });
    await expect(a.localeReady).resolves.toBe("en");
    expect(a.locale).toBe("en");
  });

  it("a word that arrives after the timeout still updates the value and fires the callbacks", async () => {
    const seen = [];
    const s = app();
    s.a.onLocaleChange((t) => seen.push(t));
    await expect(s.a.localeReady).resolves.toBe("en");
    s.emit(loc("fr"));
    expect(s.a.locale).toBe("fr");
    expect(seen).toEqual(["fr"]);
  });
});

describe("pickLocale", () => {
  const cases = [
    ["ja", ["en", "ja"], "ja"],
    ["JA", ["en", "ja"], "ja"],
    ["zh-TW", ["en", "zh-TW", "zh-CN"], "zh-TW"],
    ["pt-BR", ["en", "pt"], "pt"],
    ["pt-BR", ["en", "pt-BR", "pt"], "pt-BR"],
    ["zh-TW", ["en", "zh-CN"], "en"],
    ["ja", ["en"], "en"],
    ["ja", [], "en"],
    ["ja", undefined, "en"],
    [undefined, ["en", "ja"], "en"],
  ];
  for (const [tag, supported, want] of cases) {
    it(`${tag} in ${JSON.stringify(supported)} -> ${want}`, () => expect(pickLocale(tag, supported)).toBe(want));
  }
  it("uses the given fallback", () => expect(pickLocale("ja", ["fr", "de"], "de")).toBe("de"));
});
