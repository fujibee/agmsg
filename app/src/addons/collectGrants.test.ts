import { describe, expect, it } from "vitest";
import { collectSavedGrants } from "./collectGrants";
import { mockSnapshot } from "./mock";

const dev = { ...mockSnapshot.addons[0], id: "dev:x", builtin: false, dev: { label: "f", copy: "c" } };

describe("collectSavedGrants (the live loader)", () => {
  it("reads built-in and installed add-ons, never a developer copy", async () => {
    const asked: string[] = [];
    const r = await collectSavedGrants([...mockSnapshot.addons, dev], async (id, pane) => {
      asked.push(`${id}/${pane}`);
      return { ok: true, value: id === "builtin:fileview" ? [{ permission: "files:read", scope: "/p", grantedAt: "t" }] : [] };
    });
    expect(asked).toContain("builtin:fileview/fileview");
    expect(asked.some((a) => a.startsWith("dev:"))).toBe(false);
    expect(r.grants).toEqual([{ addonId: "builtin:fileview", pane: "fileview", permission: "files:read", scope: "/p", remember: true, grantedAt: "t" }]);
    expect(r.failure).toBeNull();
  });
  it("keeps going after a failed read and reports the first reason", async () => {
    const r = await collectSavedGrants(mockSnapshot.addons, async (id) =>
      id === "builtin:fileview" ? { ok: false, error: { code: "x", message: "boom" } } : { ok: true, value: [{ permission: "messages:read", scope: "t", grantedAt: "g" }] },
    );
    expect(r.failure).toBe("boom");
    expect(r.grants.length).toBeGreaterThan(0);
  });
});
