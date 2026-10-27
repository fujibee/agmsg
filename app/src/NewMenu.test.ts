import { describe, expect, it, vi } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { NewMenu, newMenuEntries, nextIndex, placeMenu, type NewMenuVariant } from "./NewMenu";
import { openNowRef } from "./addons/AddonsSettings";
import { mockEngine, mockEngineOff, mockSnapshot } from "./addons/mock";

const t = (key: string, o?: Record<string, unknown>) => `[${key}${o ? " " + JSON.stringify(o) : ""}]`;
const base = () => ({
  t,
  onClose: vi.fn(),
  team: "agmsg" as string | null,
  addonEngine: mockEngine,
  addons: mockSnapshot.addons,
  onTeam: vi.fn(),
  onAgent: vi.fn(),
  onShell: vi.fn(),
  onOpenAddon: vi.fn(),
  onInstall: vi.fn(),
});
const render = (variant: NewMenuVariant, open: boolean, extra: Partial<ReturnType<typeof base>> = {}) =>
  renderToStaticMarkup(createElement(NewMenu, { ...base(), ...extra, variant, open, onToggle: () => {} }));
const entries = (variant: NewMenuVariant, extra: Partial<ReturnType<typeof base>> = {}) => newMenuEntries({ ...base(), ...extra, variant });

describe("the + menu in the tab bar", () => {
  it("lists Shell first, then File view, Diff view, each installed pane, and Install add-ons", () => {
    const keys = entries("tabs").map((e) => e.key);
    expect(keys).toEqual(["shell", "sep", "fileview", "diffview", "shinshin86/agmsg-office/agmsg-office", "install"]);
    const html = render("tabs", true);
    const order = ["tabs.shellLabel", "addons.menu.fileViewEntry", "addons.menu.diffViewEntry", "addons.menu.addonPane", "addons.menu.install"].map((k) => html.indexOf(k));
    expect(order.every((i) => i >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
    expect(html).toContain("agmsg office");
    expect(html).toContain('role="menu"');
  });
  it("is closed until the + is pressed, and the + is the button that opens it", () => {
    const html = render("tabs", false);
    expect(html).not.toContain("addons.menu.fileViewEntry");
    expect(html).toMatch(/class="tab-new-shell"[^>]*aria-haspopup="menu"/);
    expect(html).toContain('aria-expanded="false"');
    expect(render("tabs", true)).toContain('aria-expanded="true"');
  });
  it("Shell is never disabled, and choosing it closes the menu and opens a shell", () => {
    const p = base();
    const shell = newMenuEntries({ ...p, variant: "tabs", team: null }).find((e) => e.key === "shell")!;
    expect(shell.disabled).toBe(false);
    shell.run();
    expect(p.onClose).toHaveBeenCalledTimes(1);
    expect(p.onShell).toHaveBeenCalledTimes(1);
  });
  it("File view, Diff view and add-on panes open through the pane path with their own refs; Install opens Settings", () => {
    const p = base();
    const list = newMenuEntries({ ...p, variant: "tabs" });
    list.find((e) => e.key === "fileview")!.run();
    expect(p.onOpenAddon).toHaveBeenLastCalledWith({ addonId: "builtin:fileview", paneName: "fileview", title: "[addons.menu.fileView]" });
    list.find((e) => e.key === "diffview")!.run();
    expect(p.onOpenAddon).toHaveBeenLastCalledWith({ addonId: "builtin:diffview", paneName: "diffview", title: "[addons.menu.diffView]" });
    list.find((e) => e.key === "shinshin86/agmsg-office/agmsg-office")!.run();
    expect(p.onOpenAddon).toHaveBeenLastCalledWith({ addonId: "shinshin86/agmsg-office", paneName: "agmsg-office", title: "agmsg office" });
    expect(p.onClose).toHaveBeenCalledTimes(3);
    list.find((e) => e.key === "install")!.run();
    expect(p.onInstall).toHaveBeenCalledTimes(1);
  });
  it("the pane entries are off without a team or while add-ons are off, with the reason; Shell and Install stay on", () => {
    const noTeam = entries("tabs", { team: null });
    expect(noTeam.find((e) => e.key === "fileview")?.disabled).toBe(true);
    const off = entries("tabs", { addonEngine: mockEngineOff });
    expect(off.find((e) => e.key === "diffview")?.disabled).toBe(true);
    expect(off.find((e) => e.key === "diffview")?.title).toContain("navigation control");
    expect(off.find((e) => e.key === "shell")?.disabled).toBe(false);
    expect(off.find((e) => e.key === "install")?.disabled).toBe(false);
  });
  it("a disabled add-on is not listed", () => {
    const addons = mockSnapshot.addons.map((a) => (a.id === "shinshin86/agmsg-office" ? { ...a, enabled: false } : a));
    expect(entries("tabs", { addons }).some((e) => e.label.includes("agmsg office"))).toBe(false);
  });
  it("arrow keys skip disabled items and wrap around", () => {
    const enabled = [true, false, true, true];
    expect(nextIndex(enabled, 0, 1)).toBe(2);
    expect(nextIndex(enabled, 3, 1)).toBe(0);
    expect(nextIndex(enabled, 0, -1)).toBe(3);
    expect(nextIndex(enabled, -1, 1)).toBe(0);
    expect(nextIndex([false, false], 0, 1)).toBe(-1);
  });
});

describe("where the tab-bar menu goes", () => {
  const vp = { w: 1000, h: 700 };
  it("sits under its button when there is room", () => {
    expect(placeMenu({ left: 120, bottom: 40 }, 220, vp)).toEqual({ left: 120, top: 42, maxHeight: 700 - 42 - 8 });
  });
  it("is pulled left so its right edge stays inside the window (+ near the right edge)", () => {
    const p = placeMenu({ left: 950, bottom: 40 }, 220, vp);
    expect(p.left).toBe(1000 - 220 - 8);
    expect(p.left + 220).toBeLessThanOrEqual(1000 - 8);
  });
  it("never starts left of the window edge, even for a menu wider than the window", () => {
    expect(placeMenu({ left: -30, bottom: 40 }, 220, vp).left).toBe(8);
    expect(placeMenu({ left: 10, bottom: 40 }, 2000, vp).left).toBe(8);
  });
  it("is no taller than the space below it, with a floor so it stays usable in a very short window", () => {
    expect(placeMenu({ left: 0, bottom: 300 }, 220, vp).maxHeight).toBe(700 - 302 - 8);
    expect(placeMenu({ left: 0, bottom: 690 }, 220, vp).maxHeight).toBe(120);
  });
});

describe("the + menu in the collapsed rail", () => {
  it("has exactly Team… and Agent…, no pane entries", () => {
    expect(entries("rail").map((e) => e.key)).toEqual(["team", "agent"]);
    const html = render("rail", true);
    expect(html).toContain("sidebar.newMenu.team");
    expect(html).toContain("sidebar.newMenu.agent");
    for (const k of ["fileViewEntry", "diffViewEntry", "addonPane", "addons.menu.install", "tabs.shellLabel"]) expect(html).not.toContain(k);
    expect(html).toContain('class="rail-icon-btn"');
  });
  it("Agent… needs a team; Team… does not", () => {
    const list = entries("rail", { team: null });
    expect(list.find((e) => e.key === "agent")?.disabled).toBe(true);
    expect(list.find((e) => e.key === "team")?.disabled).toBe(false);
  });
});

describe("Open now", () => {
  it("opens the first pane of the add-on just installed, and nothing when it has none", () => {
    expect(openNowRef({ kind: "installed", addonId: "a/b", title: "Bee", paneName: "main" })).toEqual({ addonId: "a/b", paneName: "main", title: "Bee" });
    expect(openNowRef({ kind: "installed", addonId: "a/b", title: "Bee" })).toBeNull();
  });
});
