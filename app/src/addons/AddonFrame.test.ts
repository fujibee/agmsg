import { describe, expect, it, vi } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn() }));

describe("AddonFrame", () => {
  it("is sandboxed to allow-scripts only", async () => {
    const { AddonFrame, ADDON_FRAME_SANDBOX } = await import("./AddonFrame");
    expect(ADDON_FRAME_SANDBOX).toBe("allow-scripts");
    const html = renderToStaticMarkup(
      createElement(AddonFrame, { paneInstance: 1, url: "http://127.0.0.1:5000/tok/", title: "T", declaresMessages: true, reloadKey: 0 }),
    );
    expect(html).toContain('sandbox="allow-scripts"');
    expect(html).not.toContain("allow-same-origin");
    expect(html).toContain('src="http://127.0.0.1:5000/tok/"');
  });
});
