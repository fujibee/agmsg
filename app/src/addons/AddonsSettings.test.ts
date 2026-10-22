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
});
