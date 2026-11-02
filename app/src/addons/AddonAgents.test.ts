import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { AddonAgents } from "./AddonAgents";
import type { MemberState } from "./source";

const t = (key: string, o?: Record<string, unknown>) => `[${key}${o ? " " + JSON.stringify(o) : ""}]`;
const e = (over: Partial<MemberState>): MemberState => ({ key: "k1", addon: "o/r", team: "t", kind: "agent", name: "white", type: "claude-code", state: "running", ...over });
const render = (entries: MemberState[], left: string[] = []) =>
  renderToStaticMarkup(createElement(AddonAgents, { t, entries, left: new Set(left), onOpen: () => {}, onLeave: () => {}, onRefresh: () => {} }));

describe("AddonAgents", () => {
  it("says so when there is nothing", () => {
    expect(render([])).toContain("addons.agents.none");
  });
  it("shows the pid and the open-new / leave choice for an orphaned agent", () => {
    const html = render([e({ state: "orphaned", pid: 4242 })]);
    expect(html).toContain("&quot;pid&quot;:4242");
    expect(html).toContain("addons.agents.orphanedHelp");
    expect(html).toContain("addons.agents.openNew");
    expect(html).toContain("addons.agents.leave");
  });
  it("uses the unknown wording for an agent that may have started", () => {
    expect(render([e({ state: "unknown" })])).toContain("addons.agents.unknownHelp");
  });
  it("keeps a left entry listed but without buttons", () => {
    const html = render([e({ state: "orphaned", pid: 1 })], ["k1"]);
    expect(html).toContain("white");
    expect(html).not.toContain("addons.agents.openNew");
  });
  it("offers no choice for a running agent or a member", () => {
    const html = render([e({ state: "running", pid: 9 }), e({ key: "k2", kind: "member", name: "chess", state: "joined" })]);
    expect(html).not.toContain("addons.agents.openNew");
    expect(html).not.toContain("addons.agents.open]");
  });
});
