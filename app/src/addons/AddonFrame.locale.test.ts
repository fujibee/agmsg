// The real AddonFrame with the real relay and a real i18n instance, run without a DOM: a tiny hook runtime stands in
// for React's renderer (refs and effects with dependency checks), the port is a real MessageChannel. It proves that
// changing the app's language reaches the add-on's open port as exactly one locale event, without a reload.
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ReactElement } from "react";
import i18next from "i18next";

type Slot = { current?: unknown; deps?: unknown[]; cleanup?: unknown };
const rt = { slots: [] as Slot[], idx: 0, pending: [] as (() => void)[] };
const instance = i18next.createInstance();

vi.mock("react", async () => {
  const actual = await vi.importActual<typeof import("react")>("react");
  return {
    ...actual,
    useRef: (init: unknown) => {
      const i = rt.idx++;
      rt.slots[i] ??= { current: init };
      return rt.slots[i];
    },
    useEffect: (fn: () => unknown, deps: unknown[]) => {
      const i = rt.idx++;
      const prev = rt.slots[i];
      if (prev && prev.deps && prev.deps.length === deps.length && prev.deps.every((d, k) => Object.is(d, deps[k]))) return;
      rt.pending.push(() => {
        (prev?.cleanup as (() => void) | undefined)?.();
        rt.slots[i] = { deps, cleanup: fn() };
      });
    },
  };
});
vi.mock("react-i18next", () => ({ useTranslation: () => ({ i18n: instance }) }));

const invokeCalls: string[] = [];
vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(async (cmd: string) => {
    invokeCalls.push(cmd);
    if (cmd === "addon_pane_loaded") return 1;
    if (cmd === "addon_feed_init") return { init: { agmsg: 1, type: "init" }, queued: [] };
    return { agmsg: 1, type: "response", ok: true, result: {} };
  }),
}));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn(async () => () => {}) }));

const loc = (locale: string) => ({ agmsg: 1, type: "locale", locale });
const settle = () => new Promise((r) => setTimeout(r, 40));

afterEach(() => {
  rt.slots = [];
  rt.idx = 0;
  rt.pending = [];
  invokeCalls.length = 0;
});

async function mount(declaresMessages: boolean) {
  await instance.init({ lng: "en", fallbackLng: "en", resources: { en: { translation: {} }, ja: { translation: {} }, de: { translation: {} } } });
  const { AddonFrame } = await import("./AddonFrame");
  const props = { paneInstance: 3, url: "http://127.0.0.1:5000/tok/", title: "T", declaresMessages, reloadKey: 0 };
  const render = () => {
    rt.idx = 0;
    rt.pending = [];
    const el = AddonFrame(props) as ReactElement<{ ref: { current: unknown }; onLoad: () => void }>;
    for (const run of rt.pending) run();
    return el;
  };
  const el = render();
  const got: unknown[] = [];
  const posted: unknown[] = [];
  el.props.ref.current = {
    contentWindow: {
      postMessage: (msg: unknown, _t: string, transfer: MessagePort[]) => {
        posted.push(msg);
        transfer[0].onmessage = (e) => got.push(e.data);
      },
    },
  };
  el.props.onLoad();
  await vi.waitFor(() => expect(got.length).toBeGreaterThan(0));
  await settle();
  const unmount = () => {
    for (const s of rt.slots) (s.cleanup as (() => void) | undefined)?.();
  };
  return { render, got, posted, unmount };
}

describe("AddonFrame: the app's language reaches the open port", () => {
  it("one language change posts exactly one locale event to the same port, with no reload and no feed refetch", async () => {
    const s = await mount(true);
    expect(s.got).toEqual([loc("en"), { agmsg: 1, type: "init" }]);
    const loads = invokeCalls.filter((c) => c === "addon_pane_loaded").length;
    const feeds = invokeCalls.filter((c) => c === "addon_feed_init").length;

    await instance.changeLanguage("ja");
    s.render();
    await settle();

    expect(s.got).toEqual([loc("en"), { agmsg: 1, type: "init" }, loc("ja")]);
    expect(s.posted).toHaveLength(1); // one port handed over; none replaced
    expect(invokeCalls.filter((c) => c === "addon_pane_loaded")).toHaveLength(loads);
    expect(invokeCalls.filter((c) => c === "addon_feed_init")).toHaveLength(feeds);
  });

  it("a pane without messages gets the language too, and a re-render in the same language sends nothing", async () => {
    const s = await mount(false);
    expect(s.got).toEqual([loc("en")]);
    await instance.changeLanguage("de");
    s.render();
    s.render();
    await settle();
    expect(s.got).toEqual([loc("en"), loc("de")]);
  });

  it("after the frame is gone a language change reaches nothing", async () => {
    const s = await mount(false);
    s.unmount();
    await instance.changeLanguage("ja");
    s.render();
    await settle();
    expect(s.got).toEqual([loc("en")]);
  });
});
