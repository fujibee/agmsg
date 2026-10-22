import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
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
