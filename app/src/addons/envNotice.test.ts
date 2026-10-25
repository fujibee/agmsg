import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { envNoticeKey } from "./envNotice";
import { createLiveSource } from "./source";
import { AddonPane } from "./AddonPane";

describe(".env notice", () => {
  it("says nothing when none was found, even if the look stopped early", () => {
    expect(envNoticeKey({ found: false, truncated: true, network: true })).toBeNull();
  });
  it("tells a pane without network that the folder has one, and a network pane that it cannot read it", () => {
    expect(envNoticeKey({ found: true, truncated: false, network: false })).toBe("addons.env.found");
    expect(envNoticeKey({ found: true, truncated: false, network: true })).toBe("addons.env.foundNetwork");
  });
  it("asks Rust about the pane, not about a path the UI names", async () => {
    const calls: [string, Record<string, unknown> | undefined][] = [];
    const s = createLiveSource(async (cmd, args) => {
      calls.push([cmd, args]);
      return { found: true, truncated: false, network: true };
    });
    expect(await s.folderEnvNotice(7)).toEqual({ ok: true, value: { found: true, truncated: false, network: true } });
    expect(calls).toEqual([["addon_folder_env_notice", { id: 7 }]]);
  });
  it("the folder chip carries the note next to the folder", () => {
    const t = (k: string) => `[${k}]`;
    const html = renderToStaticMarkup(
      createElement(AddonPane, {
        t, title: "Viewer", state: { kind: "frame" }, chips: [{ key: "root:/p", label: "/p", note: "This folder has a .env file." }],
        onReload: () => {}, onClose: () => {}, onGrant: () => {}, onFailure: () => {}, frame: null,
      } as never),
    );
    expect(html).toContain("/p");
    expect(html).toContain("This folder has a .env file.");
  });
});
