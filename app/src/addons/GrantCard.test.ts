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
});
