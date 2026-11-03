import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { GrantCard } from "./GrantCard";

const t = (key: string, o?: Record<string, unknown>) => `[${key}${o ? " " + JSON.stringify(o) : ""}]`;
const render = (send: boolean, spawn: boolean) =>
  renderToStaticMarkup(createElement(GrantCard, { t, title: "Chess", need: { permission: "powers", team: "t1", send, spawn }, onChoose: () => {} }));

describe("GrantCard powers", () => {
  it("lists only what was declared and offers Allow / Not now", () => {
    const html = render(false, false);
    expect(html).toContain("addons.permission.teamJoin");
    expect(html).not.toContain("messagesSend");
    expect(html).not.toContain("addons.confirm.agentsBody");
    expect(html).toContain("addons.card.allow]");
    expect(html).toContain("addons.card.notNow]");
  });
  it("says agents keep their own permissions once it can send or start them", () => {
    const send = render(true, false);
    expect(send).toContain("addons.permission.messagesSend");
    expect(send).toContain("addons.confirm.agentsBody");
    expect(send).not.toContain("addons.confirm.agentsMode");
    const spawn = render(true, true);
    expect(spawn).toContain("addons.permission.agentsSpawn");
    expect(spawn).toContain("addons.confirm.agentsMode");
    expect(spawn).toContain("addons.confirm.agentsFolder");
  });

  const withTrust = (state: "trusted" | "not trusted" | "config not found" | null, spawn = true, checked = false) =>
    renderToStaticMarkup(
      createElement(GrantCard, { t, title: "Chess", need: { permission: "powers", team: "t1", send: true, spawn }, trust: { state, checked, onChange: () => {} }, onChoose: () => {} }),
    );
  it("offers the folder-trust box only for agents:spawn, only when the folder is not trusted yet, unticked", () => {
    const html = withTrust("not trusted");
    expect(html).toContain("addons.trust.label");
    expect(html).toContain("addons.trust.note");
    expect(html).toContain('type="checkbox"');
    expect(html).not.toMatch(/checked=""/);
    expect(withTrust("not trusted", false)).not.toContain("addons.trust");
    expect(withTrust("not trusted", true, true)).toMatch(/checked=""/);
  });
  it("says so instead of offering the box when the folder is trusted, the config is missing, or it is not read yet", () => {
    expect(withTrust("trusted")).toContain("addons.trust.trusted");
    expect(withTrust("trusted")).not.toContain('type="checkbox"');
    expect(withTrust("config not found")).toContain("addons.trust.notFound");
    expect(withTrust(null)).not.toContain("addons.trust");
  });
  it("shows why the trust state could not be read, not 'not found', and still offers Allow", () => {
    const html = renderToStaticMarkup(
      createElement(GrantCard, { t, title: "Chess", need: { permission: "powers", team: "t1", send: true, spawn: true }, trust: { state: null, checked: false, onChange: () => {}, error: "EACCES" }, onChoose: () => {} }),
    );
    expect(html).toContain("addons.trust.readFailed");
    expect(html).not.toContain("addons.trust.notFound");
    expect(html).toContain("addons.card.allow");
  });
});
