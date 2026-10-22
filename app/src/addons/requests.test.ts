import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { mockRequestContext, mockRequestRows } from "./mock";
import { argsAllowed, scanRequests, type RequestContext, type RequestRow } from "./requests";
import { OpenRequestBar } from "./OpenRequestBar";

const ctx = (o: Partial<RequestContext> = {}): RequestContext => ({ ...mockRequestContext, ...o });
const t = (key: string, o?: Record<string, unknown>) => `[${key}${o ? " " + JSON.stringify(o) : ""}]`;
const noop = () => {};

describe("scanRequests", () => {
  it("builds bar items with the status each refusal needs", () => {
    const { items } = scanRequests(mockRequestRows, ctx());
    expect(items.map((i) => [i.requestId, i.status])).toEqual([
      ["r1", "open"],
      ["r2", "not_installed"],
      ["r3", "not_found_here"],
    ]);
    expect(items[1].installTarget).toBe("someone/viewer");
  });
  it("shows only requests addressed to this team's app-user", () => {
    expect(scanRequests(mockRequestRows, ctx({ appUser: "someone-else" })).items).toEqual([]);
    expect(scanRequests(mockRequestRows, ctx({ team: "other" })).items).toEqual([]);
  });
  it("a row that is not provably local never gets a bar, only a note", () => {
    const r = scanRequests(mockRequestRows, ctx({ isLocalOrigin: () => false }));
    expect(r.items).toEqual([]);
    expect(r.notes.get("1")).toEqual({ kind: "other_machine" });
  });
  it("a malformed local request is a note with the reason, never a bar", () => {
    const bad: RequestRow = { ...mockRequestRows[0], id: "x", body: mockRequestRows[0].body.replace('"path"', '"cmd"') };
    const r = scanRequests([bad], ctx());
    expect(r.items).toEqual([]);
    expect(r.notes.get("x")).toMatchObject({ kind: "malformed", reason: "unknown_arg_key", detail: "cmd" });
  });
  it("acts on a request_id once, and skips handled ones", () => {
    const twice = [mockRequestRows[0], { ...mockRequestRows[0], id: "dup" }];
    expect(scanRequests(twice, ctx()).items).toHaveLength(1);
    expect(scanRequests(mockRequestRows, ctx({ handled: new Set(["r1", "r2", "r3"]) })).items).toEqual([]);
  });
  it("expired and requester-mismatch take the Open button away", () => {
    expect(scanRequests([mockRequestRows[0]], ctx({ isExpired: () => true })).items[0].status).toBe("expired");
    expect(scanRequests([mockRequestRows[0]], ctx({ requesterMatches: () => false })).items[0].status).toBe("bad_requester");
  });
  it("ordinary messages are ignored", () => {
    expect(scanRequests([{ ...mockRequestRows[0], body: "hi" }], ctx())).toEqual({ items: [], notes: new Map() });
  });
});

describe("argsAllowed", () => {
  it("matches the pane's opens", () => {
    expect(argsAllowed({ kind: "fileview" }, { path: "/p" })).toBe(true);
    expect(argsAllowed({ kind: "fileview" }, { path: "/p", base: "main" })).toBe(false);
    expect(argsAllowed({ kind: "diffview" }, { base: "main" })).toBe(false);
    expect(argsAllowed({ kind: "browser" }, { url: "https://a.test" })).toBe(true);
    expect(argsAllowed({ kind: "addon", owner: "a", repo: "b", pane: "c" }, {}, "")).toBe(true);
    expect(argsAllowed({ kind: "addon", owner: "a", repo: "b", pane: "c" }, { path: "/p" }, "")).toBe(false);
  });
});

describe("OpenRequestBar", () => {
  const bar = (rows: RequestRow[]) =>
    renderToStaticMarkup(
      createElement(OpenRequestBar, { t, items: scanRequests(rows, ctx()).items, formatTime: (s) => s, onOpen: noop, onDismiss: noop, onInstall: noop }),
    );
  it("renders nothing without requests", () => expect(bar([])).toBe(""));
  it("one request: a line with Open and Dismiss, no collapse", () => {
    const html = bar([mockRequestRows[0]]);
    expect(html).toContain("addons.request.open");
    expect(html).toContain("addons.request.dismiss");
    expect(html).not.toContain("<details");
  });
  it("several requests collapse into N open requests", () => {
    const html = bar(mockRequestRows);
    expect(html).toContain("<details");
    expect(html).toContain("&quot;count&quot;:3");
  });
  it("not installed offers Install and a disabled Open; not found here disables Open", () => {
    const html = bar([mockRequestRows[1]]);
    expect(html).toContain("addons.request.install");
    expect(html).toMatch(/disabled=""[^>]*>\[addons\.request\.open\]/);
    expect(bar([mockRequestRows[2]])).toMatch(/disabled=""[^>]*>\[addons\.request\.open\]/);
  });
});
