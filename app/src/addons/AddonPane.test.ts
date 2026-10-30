import { describe, expect, it } from "vitest";
const css = readSource("../App.css", import.meta.url);
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { readSource } from "../readSource";
import { AddonPane } from "./AddonPane";
import { failureActions } from "./FailureCard";
import { grantChips } from "./model";
import { mockGrantNeeds } from "./mock";
import type { PaneState } from "./types";

const t = (key: string, o?: Record<string, unknown>) => `[${key}${o ? " " + JSON.stringify(o) : ""}]`;
const noop = () => {};
const render = (state: PaneState, extra: Record<string, unknown> = {}) =>
  renderToStaticMarkup(
    createElement(AddonPane, {
      t,
      title: "Diff view",
      chips: [{ key: "a", label: "~/proj" }],
      state,
      onReload: noop,
      onClose: noop,
      onGrant: noop,
      onFailure: noop,
      ...extra,
    }),
  );

describe("AddonPane", () => {
  it("always has Reload and close in the header, with a chip per grant", () => {
    const html = render({ kind: "frame" });
    expect(html).toContain("addons.pane.reload");
    expect(html).toContain("pane.closeTitle");
    expect(html).toContain("~/proj");
  });
  it("shows the grant card, a failure card, or the frame — never an empty body", () => {
    expect(render({ kind: "grant", need: mockGrantNeeds.files })).toContain("addon-grant-card");
    expect(render({ kind: "failure", failure: { code: "load_timeout" } })).toContain("addon-failure-card");
    expect(render({ kind: "frame" })).toContain("addon-frame-placeholder");
  });
  it("shows who asked, and a dev badge, only when given", () => {
    expect(render({ kind: "frame" })).not.toContain("askedBy");
    expect(render({ kind: "frame" }, { askedBy: "alice", devFolder: "/x" })).toContain("addons.pane.askedBy");
  });
  it("the add-on's own bar is at the bottom, under the body, and is not an app pane header", () => {
    const html = render({ kind: "frame" }, { askedBy: "alice", devFolder: "/x", blocked: "read (denied)" });
    expect(html).not.toContain("pane-header ");
    expect(html).not.toContain('class="pane-header');
    expect(html.indexOf("addon-pane-body")).toBeLessThan(html.indexOf("addon-pane-status"));
    const bar = html.slice(html.indexOf("addon-pane-status"));
    for (const x of ["~/proj", "addons.pane.dev", "addons.pane.askedBy", "addons.pane.blocked", "addons.pane.reload", "pane.closeTitle"]) expect(bar).toContain(x);
  });
  it("the bar is still there, with ⟳, when it has nothing else to say", () => {
    const html = render({ kind: "frame" }, { chips: [], hideTitle: true, hideClose: true });
    expect(html).toContain("addon-pane-status");
    expect(html.slice(html.indexOf("addon-pane-status"))).toContain("addons.pane.reload");
    expect(html.slice(html.indexOf("addon-pane-status"))).not.toContain("pane.closeTitle");
  });
  it("a refusal notice has a × when the host can clear it", () => {
    expect(render({ kind: "frame" }, { blocked: "x" })).not.toContain("addon-blocked-close");
    expect(render({ kind: "frame" }, { blocked: "x", onClearBlocked: noop })).toContain("addon-blocked-close");
  });
  it("long text can be cut but the buttons cannot: the bar has the shrink rules and every cut text has its full text in title", () => {
    expect(css).toMatch(/\.addon-pane-status-btn \{[^}]*flex-shrink: 0/);
    expect(css).toMatch(/\.addon-pane-status > :not\(\.addon-pane-status-btn\)[^{]*\{[^}]*min-width: 0[^}]*overflow: hidden[^}]*text-overflow: ellipsis/);
    expect(css).toMatch(/\.addon-blocked-text \{[^}]*text-overflow: ellipsis/);
    const html = render({ kind: "frame" }, { chips: [{ key: "a", label: "~/a/very/long/path", note: "read" }], askedBy: "alice", devFolder: "/x", blocked: "read (denied)", onClearBlocked: noop });
    expect(html).toContain('class="addon-chip" title="~/a/very/long/path · read"');
    expect(html).toMatch(/class="addon-badge" title="/);
    expect(html).toMatch(/class="addon-asked-by" title="/);
    expect(html).toMatch(/class="addon-blocked-text" title="/);
    // the reload and close buttons are the shrink-proof class
    expect(html.match(/class="addon-pane-status-btn"/g)?.length).toBe(2);
  });
  it("the host-drawn header variant omits the title and ×", () => {
    const html = render({ kind: "frame" }, { hideTitle: true, hideClose: true });
    expect(html).not.toContain("addon-pane-title");
    expect(html).not.toContain("pane.closeTitle");
  });
});

describe("failure cards", () => {
  it("each failure offers its one next step", () => {
    expect(failureActions({ code: "digest_mismatch" })).toEqual(["reinstall", "remove"]);
    expect(failureActions({ code: "load_timeout" })).toEqual(["reload"]);
    expect(failureActions({ code: "path_missing", path: "/x" })).toEqual(["chooseAnother"]);
    expect(failureActions({ code: "revoked", permission: "messages:read", scope: "t" })).toEqual(["allowAgain"]);
    expect(failureActions({ code: "open_failed", message: "m" })).toEqual(["reload"]);
    expect(failureActions({ code: "init_too_large" })).toEqual(["reload"]);
    expect(failureActions({ code: "pane_closed", reason: "r" })).toEqual(["reload", "remove"]);
  });
});

describe("grantChips", () => {
  it("adds a network chip for origins and for any site", () => {
    const g = [{ permission: "files:read" as const, scope: "~/p" }];
    expect(grantChips(g, { kind: "none" }, t).map((c) => c.label)).toEqual(["~/p"]);
    expect(grantChips(g, { kind: "origins", origins: ["https://a.test"] }, t)).toHaveLength(2);
    expect(grantChips([], { kind: "any" }, t)[0].key).toBe("network:*");
  });
});
