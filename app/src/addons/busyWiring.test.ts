import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { AddonsSettings } from "./AddonsSettings";
import { AddonPane } from "./AddonPane";
import { GrantCard } from "./GrantCard";
import { ConfirmInstallDialog, RemoveDialog } from "./Dialogs";
import { OpenRequestBar, OpenRequestNotes } from "./OpenRequestBar";
import { toOpenView, type OpenRowRaw } from "./openRequests";
import { closeIfStill } from "../busy";
import { FRAME_LOAD_TIMEOUT_MS, frameKey, watchLoad } from "./frameLoad";
import { mockEngine, mockGrantNeeds, mockSnapshot, mockStage } from "./mock";

const t = (key: string, o?: Record<string, unknown>) => `[${key}${o ? " " + JSON.stringify(o) : ""}]`;
const noop = () => {};
const busyCount = (html: string) => (html.match(/aria-busy="true"/g) ?? []).length;
const settings = (busy: string[]) =>
  renderToStaticMarkup(
    createElement(AddonsSettings, {
      t, snapshot: mockSnapshot, engine: mockEngine, installError: null, onInstall: noop, onRevoke: noop, onCheckUpdate: noop,
      onRemove: noop, onOpenRequestsChange: noop, onLoadFromFolder: noop, onDevReload: noop, busy: new Set(busy),
    }),
  );

describe("buttons that wait for Rust are busy", () => {
  it("Settings: nothing busy at rest; Install and Load from folder show it while they run", () => {
    expect(busyCount(settings([]))).toBe(0);
    const install = settings(["install"]);
    expect(install).toMatch(/<button type="submit" class="addon-btn primary" disabled="" aria-busy="true">\[addons\.install\.button\]<span class="busy-spinner"/);
    expect(busyCount(install)).toBe(1);
    expect(settings(["load"])).toMatch(/aria-busy="true">\[addons\.developer\.loadFromFolder\]/);
  });
  it("Settings: Check for updates and Revoke are busy per add-on / per grant, and only that one", () => {
    const a = mockSnapshot.addons.find((x) => !x.builtin && !x.dev);
    expect(a).toBeDefined();
    if (!a) return;
    expect(busyCount(settings([`check:${a.id}`]))).toBe(1);
    expect(settings([`check:${a.id}`])).toMatch(/aria-busy="true">\[addons\.installed\.checkUpdates\]/);
    const g = mockSnapshot.grants.findIndex((x) => x.addonId === a.id);
    expect(g).toBeGreaterThanOrEqual(0);
    expect(settings([`revoke:${a.id}:${g}`])).toMatch(/aria-busy="true">\[addons\.grant\.revoke\]/);
  });
  it("the install and remove dialogs: the confirming button is busy, Cancel waits", () => {
    const install = renderToStaticMarkup(createElement(ConfirmInstallDialog, { t, staged: mockStage("o", "r"), onInstall: noop, onCancel: noop, busy: true }));
    expect(install).toMatch(/<button type="button" class="primary" disabled="" aria-busy="true">/);
    expect(install).toMatch(/<button type="button" autoFocus="" disabled="">\[common\.cancel\]|disabled=""[^>]*>\[common\.cancel\]/);
    const rest = renderToStaticMarkup(createElement(ConfirmInstallDialog, { t, staged: mockStage("o", "r"), onInstall: noop, onCancel: noop }));
    expect(busyCount(rest)).toBe(0);
    const remove = renderToStaticMarkup(createElement(RemoveDialog, { t, title: "X", openPanes: 0, onRemove: noop, onCancel: noop, busy: true }));
    expect(remove).toMatch(/aria-busy="true">\[addons\.remove\.confirm\]/);
    expect(remove).toContain('class="modal busy"');
  });
  it("the grant card: the running choice shows the spinner, the others are only disabled", () => {
    const card = (choice?: "once" | "always") =>
      renderToStaticMarkup(createElement(GrantCard, { t, title: "Files", need: mockGrantNeeds.files, onChoose: noop, pending: true, pendingChoice: choice }));
    const once = card("once");
    expect(busyCount(once)).toBe(1);
    expect(once).toMatch(/aria-busy="true">\[addons\.card\.allowOnce\]/);
    expect((once.match(/disabled=""/g) ?? []).length).toBe(3);
    expect(busyCount(card(undefined))).toBe(0);
  });
  it("the open-request bar: Open or Dismiss is busy for its own row, and the row waits", () => {
    const row: OpenRowRaw = {
      requestId: "1:0", id: "1", team: "agmsg", from: "alice", created_at: "2026-10-25T08:40:00Z",
      addonId: "builtin:diffview", pane: "diffview", path: "/p", verdict: "ready", pathState: "exists",
    };
    const items = toOpenView({ appUser: "me", rows: [row], truncated: false }).items;
    const bar = (busy: string[]) => renderToStaticMarkup(createElement(OpenRequestBar, { t, items, timeZone: "UTC", busy: new Set(busy), onOpen: noop, onDismiss: noop, onInstall: noop }));
    expect(busyCount(bar([]))).toBe(0);
    const opening = bar(["open:1:0"]);
    expect(opening).toMatch(/aria-busy="true">\[addons\.request\.open\]/);
    expect(opening).toMatch(/disabled="">\[addons\.request\.dismiss\]/);
    expect(bar(["dismiss:1:0"])).toMatch(/aria-busy="true">\[addons\.request\.dismiss\]/);
    const notes = renderToStaticMarkup(createElement(OpenRequestNotes, { t, busy: new Set(["dismiss:2:0"]), notes: [{ requestId: "2:0", note: { kind: "malformed", reason: "bad_option" } }], onDismiss: noop }));
    expect(notes).toMatch(/aria-busy="true">\[addons\.request\.dismiss\]/);
  });
  it("a pane that is still opening says so with a spinner instead of an empty frame", () => {
    const html = renderToStaticMarkup(createElement(AddonPane, { t, title: "File view", chips: [], state: { kind: "frame" }, onReload: noop, onClose: noop, onGrant: noop, onFailure: noop }));
    expect(html).toMatch(/addon-frame-placeholder[^>]*><div class="addon-loading" role="status"[^>]*><span class="busy-spinner"[^>]*><\/span><span>\[addons\.pane\.opening/);
  });
});

describe("a dialog that is busy cannot be closed from outside, and a late answer closes only its own dialog", () => {
  const onClose = (el: unknown) => (el as { props: { onClose?: () => void } }).props.onClose;
  it("busy: Escape and a click on the backdrop (both go to the Modal's onClose) do nothing", () => {
    const cancel = () => {};
    expect(onClose(ConfirmInstallDialog({ t, staged: mockStage("o", "r"), onInstall: noop, onCancel: cancel, busy: true }))).toBeUndefined();
    expect(onClose(ConfirmInstallDialog({ t, staged: mockStage("o", "r"), onInstall: noop, onCancel: cancel }))).toBe(cancel);
    expect(onClose(RemoveDialog({ t, title: "X", openPanes: 0, onRemove: noop, onCancel: cancel, busy: true }))).toBeUndefined();
    expect(onClose(RemoveDialog({ t, title: "X", openPanes: 0, onRemove: noop, onCancel: cancel }))).toBe(cancel);
  });
  it("an answer closes the dialog it was started for and leaves a newer one open", () => {
    const first = { stagingId: "s1" };
    const second = { stagingId: "s2" };
    const same = (a: { stagingId: string }, b: { stagingId: string }) => a.stagingId === b.stagingId;
    expect(closeIfStill(first, first, same)).toBeNull();
    expect(closeIfStill(second, first, same)).toBe(second);
    expect(closeIfStill(null, first, same)).toBeNull();
    expect(closeIfStill("B", "A", (a, b) => a === b)).toBe("B");
  });
});

describe("the frame's load deadline", () => {
  it("runs for a mounted frame that has not loaded while the pane shows it; not otherwise", () => {
    const k = frameKey(7, 0);
    expect(watchLoad(k, "", "frame")).toBe(true);
    expect(watchLoad(k, k, "frame")).toBe(false); // loaded
    expect(watchLoad("", "", "frame")).toBe(false); // no frame yet
    expect(watchLoad(k, "", "failure")).toBe(false); // the pane already shows a card
    expect(watchLoad(k, "", "grant")).toBe(false);
  });
  it("a reload or a new pane instance is a different frame, so an old load does not stand in for it", () => {
    expect(frameKey(7, 0)).not.toBe(frameKey(7, 1));
    expect(frameKey(7, 0)).not.toBe(frameKey(8, 0));
    expect(watchLoad(frameKey(7, 1), frameKey(7, 0), "frame")).toBe(true);
  });
  it("is 15 seconds", () => {
    expect(FRAME_LOAD_TIMEOUT_MS).toBe(15_000);
  });
});
