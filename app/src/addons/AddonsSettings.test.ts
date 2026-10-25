import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { AddonsSettings } from "./AddonsSettings";
import { GrantCard } from "./GrantCard";
import { mockEngine, mockEngineOff, mockGrantNeeds, mockSnapshot } from "./mock";
import en from "../i18n/locales/en.json";

const t = (key: string, o?: Record<string, unknown>) => `[${key}${o ? " " + JSON.stringify(o) : ""}]`;
const noop = () => {};
type Props = Parameters<typeof AddonsSettings>[0];
const base: Props = {
  t,
  snapshot: mockSnapshot,
  engine: mockEngine,
  installError: null,
  onInstall: noop,
  onRevoke: noop,
  onCheckUpdate: noop,
  onRemove: noop,
  onOpenRequestsChange: noop,
  onLoadFromFolder: noop,
};
const render = (props: Partial<Props>) => renderToStaticMarkup(createElement(AddonsSettings, { ...base, ...props }));

describe("AddonsSettings", () => {
  it("has a button that copies the text for seats, with a hint", () => {
    const html = render({});
    expect(html).toContain("addons.openRequests.copy]");
    expect(html).toContain("addons.openRequests.copyHint");
  });
  it("shows built-ins, installed add-ons with Revoke, and a disabled Install for an empty input", () => {
    const html = render({});
    expect(html).toContain("File view");
    expect(html).toContain("shinshin86/agmsg-office");
    expect(html).toContain("addons.grant.revoke");
    expect(html).toMatch(/<button type="submit" disabled=""/);
  });
  it("keeps Developer collapsed (no open attribute)", () => {
    expect(render({})).toMatch(/<details class="addon-developer">/);
  });
  it("shows an install error inline", () => {
    const html = render({ installError: { code: "ref_not_found", repo: "a/b", ref: "v9" } });
    expect(html).toContain("addons.installError.ref_not_found");
    expect(html).toContain('role="alert"');
  });
  it("engine off: reason shown, no install form, installed list still removable", () => {
    const html = render({ engine: mockEngineOff });
    expect(html).toContain("addons.engineOff");
    expect(html).toContain("navigation control");
    expect(html).not.toContain("addon-install-form");
    expect(html).toContain("addons.installed.remove");
    expect(html).not.toContain("addons.installed.checkUpdates");
  });
});

describe("GrantCard", () => {
  const card = (need: keyof typeof mockGrantNeeds) =>
    renderToStaticMarkup(createElement(GrantCard, { t, title: "T", need: mockGrantNeeds[need], onChoose: noop }));
  it("messages: Allow and Not now only", () => {
    const html = card("messages");
    expect(html).toContain("addons.card.allow]");
    expect(html).not.toContain("allowAlways");
  });
  it("files: once, always, not now", () => {
    const html = card("files");
    for (const k of ["allowOnce", "allowAlways", "notNow"]) expect(html).toContain(`addons.card.${k}`);
  });
  it("denied path: refusal with no Allow button", () => {
    const html = card("filesDenied");
    expect(html).toContain("addons.card.denied");
    expect(html).not.toContain("addons.card.allow");
  });
});

describe("locale keys", () => {
  it("every key the screens use exists in en", () => {
    const flat = (o: unknown, p = ""): string[] =>
      typeof o === "object" && o ? Object.entries(o).flatMap(([k, v]) => flat(v, p ? `${p}.${k}` : k)) : [p];
    const keys = flat(en.addons, "addons");
    for (const k of ["addons.tab.addons", "addons.card.allowOnce", "addons.installError.unsafe_entry.symlink", "addons.engineOff"]) {
      expect(keys).toContain(k);
    }
  });

  it("without an install pipeline the input is disabled with a note, and no Remove / Check / Developer", () => {
    const html = render({ canInstall: false });
    expect(html).toContain("addons.install.later");
    expect(html).toMatch(/<input[^>]*disabled/);
    expect(html).not.toContain("addons.installed.remove");
    expect(html).not.toContain("addons.developer.title");
  });
  it("an add-on whose files changed after install says it can't open", () => {
    const addons = mockSnapshot.addons.map((a) => (a.id === "builtin:fileview" ? { ...a, digestOk: false } : a));
    const html = render({ snapshot: { ...mockSnapshot, addons } });
    expect(html).toContain("addon-digest-bad");
    expect(html).toContain("addons.failure.digest_mismatch");
  });
  it("Always for this folder is disabled while grants cannot persist", () => {
    const need = { permission: "files:read" as const, path: "/p", fileCount: null, denied: false };
    const off = renderToStaticMarkup(createElement(GrantCard, { t, title: "X", need, canRemember: false, onChoose: noop }));
    expect(off).toMatch(/<button[^>]*disabled[^>]*>\[addons\.card\.allowAlways\]/);
    expect(renderToStaticMarkup(createElement(GrantCard, { t, title: "X", need, onChoose: noop }))).not.toMatch(/disabled/);
  });
  it("a failed add-on list is shown with a retry, not as an empty list with no reason", () => {
    const html = render({ listError: "LIST SENTINEL FAILURE", onRetryList: noop });
    expect(html).toContain("addons.listFailed");
    expect(html).toContain("LIST SENTINEL FAILURE");
    expect(html).toContain("addons.listRetry");
    expect(render({})).not.toContain("addons.listFailed");
  });
  it("shows a notice above the installed list, and developer copies with a DEV badge, Reload and Remove", () => {
    const dev = { ...mockSnapshot.addons[0], id: "dev:x", builtin: false, dev: { label: "my-folder", copy: "dev copy 1" } };
    const html = render({
      notice: { kind: "info", text: "Up to date (abc1234)." },
      snapshot: { ...mockSnapshot, addons: [...mockSnapshot.addons, dev] },
    });
    expect(html).toContain("Up to date (abc1234).");
    expect(html).toContain("&quot;folder&quot;:&quot;my-folder&quot;");
    expect(html).toContain("addons.developer.reload");
    // a dev copy is not in the installed list (no updates, no saved grants)
    expect(html.split("addons.developer.title")[0]).not.toContain("dev:x");
  });
  it("a failed grants read is shown with a retry instead of an empty grants list", () => {
    const html = render({ grantsError: "GRANTS SENTINEL FAILURE", onRetryGrants: noop });
    expect(html).toContain("addons.grantsFailed");
    expect(html).toContain("GRANTS SENTINEL FAILURE");
  });
  it("while add-ons are off, a failed grants read and a failed Remove still show their reasons", () => {
    const html = render({
      engine: mockEngineOff,
      grantsError: "GRANTS OFF SENTINEL",
      notice: { kind: "error", text: "REMOVE OFF SENTINEL" },
      listError: "LIST OFF SENTINEL",
    });
    expect(html).toContain("GRANTS OFF SENTINEL");
    expect(html).toContain("REMOVE OFF SENTINEL");
    expect(html).toContain("LIST OFF SENTINEL");
  });
});
