import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ConfirmInstallDialog, FetchProgressView, RemoveDialog } from "./Dialogs";
import { permissionDiff } from "./model";
import { mockSnapshot } from "./mock";
import type { AddonPaneDecl, StagedInstall } from "./types";

const t = (key: string, o?: Record<string, unknown>) => `[${key}${o ? " " + JSON.stringify(o) : ""}]`;
const noop = () => {};
const pane = (permissions: AddonPaneDecl["permissions"], network: AddonPaneDecl["network"] = { kind: "none" }): AddonPaneDecl => ({
  name: "v", title: "V", permissions, network, opens: "", why: { "messages:read": "Draws messages." },
});
const office = mockSnapshot.addons[2];
const staged = (extra: Partial<StagedInstall> = {}): StagedInstall => ({
  addonId: office.id, title: "Office", sha: "a".repeat(40), archiveSha256: "b".repeat(64), panes: office.panes, ...extra,
});

describe("ConfirmInstallDialog", () => {
  it("never makes Install the default: Cancel is autofocused, Install is not", () => {
    const html = renderToStaticMarkup(createElement(ConfirmInstallDialog, { t, staged: staged(), onInstall: noop, onCancel: noop }));
    expect(html).toMatch(/<button type="button" autofocus="">\[common\.cancel\]/);
    expect(html).not.toMatch(/autofocus[^>]*>\[addons\.confirm\.install\]/);
    expect(html).not.toContain("<form");
  });
  it("shows the author's why line, the send warning, and never-list", () => {
    const html = renderToStaticMarkup(createElement(ConfirmInstallDialog, { t, staged: staged(), onInstall: noop, onCancel: noop }));
    expect(html).toContain("messages as an office.");
    expect(html).toContain("addons.confirm.sends");
    expect(html).toContain("addons.confirm.never");
    expect(html).toContain("addons.confirm.noReview");
  });
  it("an update highlights the new permission and says it asks again", () => {
    const from = { sha: "c".repeat(40), panes: [pane(["messages:read"])] };
    const html = renderToStaticMarkup(createElement(ConfirmInstallDialog, { t, staged: staged({ from }), onInstall: noop, onCancel: noop }));
    expect(html).toContain("addon-perm-new");
    expect(html).toContain("addons.confirm.asksAgain");
    expect(html).toContain("addons.confirm.update]");
  });
});

describe("permissionDiff", () => {
  it("equal or fewer permissions carry over", () => {
    expect(permissionDiff([pane(["messages:read", "files:read"])], [pane(["messages:read"])]).asksAgain).toBe(false);
  });
  it("a new permission asks again", () => {
    expect(permissionDiff([pane(["messages:read"])], [pane(["messages:read", "files:read"])])).toMatchObject({ added: ["files:read"], asksAgain: true });
  });
  it("a wider network list asks again, a narrower one does not", () => {
    const a = pane(["network"], { kind: "origins", origins: ["https://a.test"] });
    const ab = pane(["network"], { kind: "origins", origins: ["https://a.test", "https://b.test"] });
    expect(permissionDiff([a], [ab]).networkWider).toBe(true);
    expect(permissionDiff([ab], [a]).asksAgain).toBe(false);
    expect(permissionDiff([a], [pane(["network"], { kind: "any" })]).networkWider).toBe(true);
  });
  it("network newly combined with a read permission asks again", () => {
    const d = permissionDiff([pane(["messages:read"]), pane(["network"])].slice(0, 1), [pane(["messages:read", "network"], { kind: "any" })]);
    expect(d.networkWithRead).toBe(true);
  });
});

describe("remove and fetch", () => {
  it("remove: Cancel is the default, danger button removes", () => {
    const html = renderToStaticMarkup(createElement(RemoveDialog, { t, title: "Office", openPanes: 2, onRemove: noop, onCancel: noop }));
    expect(html).toContain("autofocus");
    expect(html).toContain("primary danger");
  });
  it("fetch steps render and can be cancelled", () => {
    for (const progress of [{ step: "resolving" as const }, { step: "downloading" as const, doneMb: 3, totalMb: 9 }, { step: "checking" as const, files: 30, sizeMb: 24 }]) {
      expect(renderToStaticMarkup(createElement(FetchProgressView, { t, progress, onCancel: noop }))).toContain("common.cancel");
    }
  });
});

describe("permissionDiff per pane", () => {
  const named = (name: string, permissions: AddonPaneDecl["permissions"], network: AddonPaneDecl["network"] = { kind: "none" }): AddonPaneDecl => ({
    ...pane(permissions, network),
    name,
  });
  const a = { kind: "origins" as const, origins: ["https://a.test"] };

  it("a capability one pane gains is not hidden because another pane already had it", () => {
    const oldPanes = [named("reader", ["files:read"]), named("net", ["network"], a)];
    const newPanes = [named("reader", ["files:read", "network"], a), named("net", [])];
    expect(permissionDiff(oldPanes, newPanes)).toEqual({
      added: ["network"],
      networkWider: true,
      networkWithRead: true,
      asksAgain: true,
    });
  });
  it("a pane that is new on update counts as entirely added", () => {
    const d = permissionDiff([named("a", ["messages:read"])], [named("a", ["messages:read"]), named("b", ["files:read", "network"], { kind: "any" })]);
    expect(d).toMatchObject({ added: ["files:read", "network"], networkWider: true, networkWithRead: true, asksAgain: true });
  });
  it("any site narrowed to a bounded list is narrower, not wider", () => {
    const d = permissionDiff([named("a", ["network"], { kind: "any" })], [named("a", ["network"], a)]);
    expect(d).toEqual({ added: [], networkWider: false, networkWithRead: false, asksAgain: false });
  });
  it("a bounded list widened to any site, or by one origin, is wider", () => {
    expect(permissionDiff([named("a", ["network"], a)], [named("a", ["network"], { kind: "any" })]).networkWider).toBe(true);
    expect(permissionDiff([named("a", ["network"], a)], [named("a", ["network"], { kind: "origins", origins: ["https://a.test", "https://b.test"] })]).networkWider).toBe(true);
  });
  it("a removed pane and unchanged panes ask nothing", () => {
    expect(permissionDiff([named("a", ["files:read"]), named("b", ["messages:read"])], [named("a", ["files:read"])]).asksAgain).toBe(false);
  });
});
