import { describe, expect, it } from "vitest";
import { appTypesInto, deliveryDot, deliveryFromMode } from "./paneDelivery";
import { routeMessage, shellPaneFrom } from "./App";
import de from "./i18n/locales/de.json";
import en from "./i18n/locales/en.json";
import es from "./i18n/locales/es.json";
import fr from "./i18n/locales/fr.json";
import ja from "./i18n/locales/ja.json";
import ko from "./i18n/locales/ko.json";
import ptBR from "./i18n/locales/pt-BR.json";
import zhCN from "./i18n/locales/zh-CN.json";
import zhTW from "./i18n/locales/zh-TW.json";

describe("deliveryFromMode", () => {
  it("monitor and both are the CLI's own delivery", () => {
    expect(deliveryFromMode("monitor")).toBe("native");
    expect(deliveryFromMode("both")).toBe("native");
  });

  it("the status line agmsgd prints for a Claude Code project is agmsgd", () => {
    expect(deliveryFromMode("agmsgd (agmsgd delivers to this project directly; no Monitor is started)")).toBe("agmsgd");
    expect(deliveryFromMode("agmsgd")).toBe("agmsgd");
  });

  it("anything else, or nothing, is left to the app", () => {
    for (const m of ["off", "turn", "", "unknown", "agmsgdx", "monitoring"]) expect(deliveryFromMode(m)).toBe("app");
    expect(deliveryFromMode(null)).toBe("app");
    expect(deliveryFromMode(undefined)).toBe("app");
  });
});

describe("appTypesInto", () => {
  it("only a pane nothing else delivers to is typed into", () => {
    expect(appTypesInto("app")).toBe(true);
    expect(appTypesInto("native")).toBe(false);
    expect(appTypesInto("agmsgd")).toBe(false);
  });
});

describe("deliveryDot", () => {
  it("an agent pane gets the dot of its delivery, each with its own class and tooltip", () => {
    expect(deliveryDot({ delivery: "agmsgd" })).toEqual({ className: "monitor-dot agmsgd", tipKey: "pane.deliveryTip.agmsgd" });
    expect(deliveryDot({ delivery: "native" })).toEqual({ className: "monitor-dot native", tipKey: "pane.deliveryTip.native" });
    expect(deliveryDot({ delivery: "app" })).toEqual({ className: "monitor-dot app", tipKey: "pane.deliveryTip.app" });
  });

  it("a pane with no delivery (a shell, an add-on pane, the shell an agent falls back to) has no dot", () => {
    expect(deliveryDot({})).toBeNull();
    expect(deliveryDot({ delivery: undefined })).toBeNull();
  });

  it("a free shell pane carries no delivery, so no dot", () => {
    const shell = shellPaneFrom({ cmd: "/bin/zsh", args: ["-il"], home: "/h" }, "sh-1", "shell", undefined);
    expect(shell).not.toBeNull();
    expect(shell!.delivery).toBeUndefined();
    expect(deliveryDot(shell!)).toBeNull();
  });

  it("every tooltip has a string in all nine locales, and the old two-state key is gone", () => {
    const locales = { en, ja, de, es, fr, ko, ptBR, zhCN, zhTW } as Record<string, { pane: Record<string, unknown> }>;
    for (const [name, loc] of Object.entries(locales)) {
      const tips = loc.pane.deliveryTip as Record<string, string>;
      for (const d of ["agmsgd", "native", "app"]) expect(tips[d], `${name}.${d}`).toBeTruthy();
      expect(loc.pane.monitorTip, `${name} monitorTip`).toBeUndefined();
    }
  });
});

describe("a pane that agmsgd delivers to is not typed into", () => {
  const leaf = (id: string) => ({ kind: "leaf", paneId: id }) as never;
  const windows = [{ team: "T", root: leaf("pane-1") }, { team: "T", root: leaf("pane-2") }, { team: "T", root: leaf("pane-3") }];
  const mk = (id: string, label: string, mode: string) => ({ id, label, native: !appTypesInto(deliveryFromMode(mode)) });
  const panes = [
    mk("pane-1", "claude", "agmsgd (agmsgd delivers to this project directly; no Monitor is started)"),
    mk("pane-2", "codex", "off"),
    mk("pane-3", "own", "monitor"),
  ];

  it("a Claude Code pane served by agmsgd gets no notice", () => {
    const r = routeMessage("T", { team: "T", to: "claude" }, windows, panes);
    expect(r.pane).toBeUndefined();
    expect(r.why).toContain("native");
  });

  it("a Codex pane with nothing of its own is still typed into", () => {
    expect(routeMessage("T", { team: "T", to: "codex" }, windows, panes).pane?.id).toBe("pane-2");
  });

  it("a pane with its own monitor gets no notice", () => {
    expect(routeMessage("T", { team: "T", to: "own" }, windows, panes).pane).toBeUndefined();
  });
});
