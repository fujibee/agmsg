import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createLiveSource, type Invoke } from "./source";
import { toCtrlView, type CtrlRowRaw, type CtrlScanRaw } from "./ctrl";
import { OpenRequestBar, OpenRequestMessages, OpenRequestNotes } from "./OpenRequestBar";

const t = (key: string, o?: Record<string, unknown>) => `[${key}${o ? " " + JSON.stringify(o) : ""}]`;
const noop = () => {};
const body = (o: object = {}) =>
  `agmsg-ctrl v1 ctrl.app_open_pane\n${JSON.stringify({ pane: "diffview", args: { path: "/p", base: "main" }, requester: { member_id: "m1" }, request_id: "r1", ...o })}`;
const row = (id: string, o: Partial<CtrlRowRaw> = {}): CtrlRowRaw => ({
  id, team: "agmsg", from: "alice", to: "me", body: body({ request_id: `r-${id}` }), created_at: "2026-10-22T08:40:00Z",
  origin: "local", verdict: "ready", requesterMatches: true, tokenCheck: "unverified", requestId: `r-${id}`, ...o,
});
const scan = (rows: CtrlRowRaw[], o: Partial<CtrlScanRaw> = {}): CtrlScanRaw => ({ appUser: "me", rows, handled: [], truncated: false, ...o });

describe("toCtrlView", () => {
  it("only a ready row gets Open; every other verdict keeps the line with Rust's reason", () => {
    const v = toCtrlView(scan([
      row("1"),
      row("2", { verdict: "not_installed", installTarget: "o/r" }),
      row("3", { verdict: "unavailable", detail: "add-ons are off on this computer: x" }),
      row("4", { verdict: "args_not_allowed" }),
      row("5", { verdict: "bad_requester" }),
      row("6", { verdict: "not_found_here" }),
      row("7", { verdict: "denied_path", detail: "/Users/me/.ssh is protected." }),
    ]));
    expect(v.items.map((i) => [i.requestId, i.status])).toEqual([
      ["r-1", "open"], ["r-2", "not_installed"], ["r-3", "unavailable"], ["r-4", "args_not_allowed"],
      ["r-5", "bad_requester"], ["r-6", "not_found_here"], ["r-7", "denied_path"],
    ]);
    expect(v.items[1].installTarget).toBe("o/r");
    expect(v.items[2].detail).toBe("add-ons are off on this computer: x");
  });
  it("synced and unproven rows get a note, never a bar", () => {
    const v = toCtrlView(scan([row("1", { verdict: "synced", origin: "synced" }), row("2", { verdict: "unproven", origin: "unproven" })]));
    expect(v.items).toEqual([]);
    expect(v.notes.get("1")).toEqual({ kind: "other_machine" });
    expect(v.notes.get("2")).toEqual({ kind: "unproven" });
  });
  it("a refused row shows Rust's reason, including a reused request id", () => {
    const v = toCtrlView(scan([
      row("1", { verdict: "refused", refusal: { reason: "request_id_reused" } }),
      row("2", { verdict: "refused", refusal: { reason: "unknown_arg_key", detail: "deadline" } }),
      row("3", { verdict: "refused", refusal: { reason: "something_new" } }),
    ]));
    expect(v.notes.get("1")).toEqual({ kind: "malformed", reason: "request_id_reused", detail: undefined });
    expect(v.notes.get("2")).toEqual({ kind: "malformed", reason: "unknown_arg_key", detail: "deadline" });
    expect(v.notes.get("3")).toMatchObject({ kind: "malformed", reason: "bad_shape" });
  });
  it("a ready row the UI cannot read is shown as malformed, never as openable", () => {
    const v = toCtrlView(scan([row("1", { body: "agmsg-ctrl v1 ctrl.app_open_pane\n{nope" })]));
    expect(v.items).toEqual([]);
    expect(v.notes.get("1")).toMatchObject({ kind: "malformed", reason: "bad_json" });
  });
  it("a request with no token is accepted; notice and truncation pass through", () => {
    const v = toCtrlView(scan([row("1")], { notice: "This team has no app-user.", truncated: true }));
    expect(v.items[0].request.requester.token).toBeUndefined();
    expect(v.notice).toBe("This team has no app-user.");
    expect(v.truncated).toBe(true);
  });
});

describe("the bar and messages", () => {
  const items = toCtrlView(scan([row("1"), row("2", { verdict: "denied_path", detail: "Protected." })])).items;
  it("says the sender is not verified on every line, and shows Rust's reason as it is", () => {
    const html = renderToStaticMarkup(createElement(OpenRequestBar, { t, items, formatTime: (s) => s, onOpen: noop, onDismiss: noop, onInstall: noop }));
    expect(html.match(/addons\.request\.unverified/g)?.length).toBe(2);
    expect(html).toContain("Protected.");
  });
  it("a denied or unavailable line has Open disabled", () => {
    const html = renderToStaticMarkup(createElement(OpenRequestBar, { t, items: [items[1]], formatTime: (s) => s, onOpen: noop, onDismiss: noop, onInstall: noop }));
    expect(html).toMatch(/<button type="button" disabled="">\[addons\.request\.open\]/);
  });
  it("an unproven row has a note without any button", () => {
    const html = renderToStaticMarkup(createElement(OpenRequestNotes, { t, notes: [{ rowId: "2", note: { kind: "unproven" } }] }));
    expect(html).toContain("addons.request.note.unproven");
    expect(html).not.toContain("<button");
  });
  it("a failed read, a host notice, truncation and a refused click are each said", () => {
    const html = renderToStaticMarkup(createElement(OpenRequestMessages, {
      t, error: "state_unreadable: broken", actionError: { code: "not_openable", message: "No." }, notice: "No app-user.", truncated: true,
    }));
    for (const k of ["readFailed", "actionFailed", "truncated"]) expect(html).toContain(`addons.request.${k}`);
    expect(html).toContain("No app-user.");
    expect(renderToStaticMarkup(createElement(OpenRequestMessages, { t, error: null, actionError: null }))).toBe("");
  });
});

describe("ctrl commands", () => {
  it("send the names and argument shapes Rust expects and return its refusal words", async () => {
    const calls: [string, Record<string, unknown> | undefined][] = [];
    const invoke: Invoke = async (cmd, args) => {
      calls.push([cmd, args]);
      if (cmd === "addon_ctrl_rows") throw { code: "state_unreadable", message: "The handled-request record cannot be read." };
      if (cmd === "addon_ctrl_open") return { requestId: "r1", from: "alice", addonId: "builtin:diffview", pane: "diffview", openArgs: { path: "/p" } };
      return null;
    };
    const s = createLiveSource(invoke);
    expect(await s.ctrlRows("agmsg")).toEqual({ ok: false, error: { code: "state_unreadable", message: "The handled-request record cannot be read." } });
    expect(await s.ctrlOpen("agmsg", "r1")).toMatchObject({ ok: true, value: { addonId: "builtin:diffview", openArgs: { path: "/p" } } });
    expect(await s.ctrlDismiss("agmsg", "r1")).toEqual({ ok: true, value: null });
    expect(calls).toEqual([
      ["addon_ctrl_rows", { team: "agmsg" }],
      ["addon_ctrl_open", { spec: { team: "agmsg", requestId: "r1" } }],
      ["addon_ctrl_dismiss", { spec: { team: "agmsg", requestId: "r1" } }],
    ]);
  });
});
