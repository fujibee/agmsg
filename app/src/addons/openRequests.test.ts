import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createLiveSource, type Invoke } from "./source";
import { seatInstruction, toOpenView, type OpenRowRaw, type OpenScanRaw } from "./openRequests";
import { OpenRequestBar, OpenRequestMessages, OpenRequestNotes, messageLines } from "./OpenRequestBar";
import { relativeTime } from "./relativeTime";
import en from "../i18n/locales/en.json";
import ja from "../i18n/locales/ja.json";

const t = (key: string, o?: Record<string, unknown>) => `[${key}${o ? " " + JSON.stringify(o) : ""}]`;
const noop = () => {};
const row = (n: string, o: Partial<OpenRowRaw> = {}): OpenRowRaw => ({
  requestId: `${n}:0`, id: n, team: "agmsg", from: "alice", created_at: "2026-10-25T08:40:00Z",
  addonId: "builtin:diffview", pane: "diffview", path: "/p", verdict: "ready", pathState: "exists", ...o,
});
const scan = (rows: OpenRowRaw[], o: Partial<OpenScanRaw> = {}): OpenScanRaw => ({ appUser: "me", rows, truncated: false, ...o });

describe("toOpenView", () => {
  it("only a ready row gets Open; every other verdict keeps the line with Rust's reason", () => {
    const v = toOpenView(scan([
      row("1"),
      row("2", { verdict: "not_installed", addonId: "o/r", pane: "viewer", path: undefined, installTarget: "o/r" }),
      row("3", { verdict: "unavailable", detail: "add-ons are off on this computer: x" }),
      row("4", { verdict: "args_not_allowed" }),
      row("5", { verdict: "not_found_here", pathState: "missing" }),
      row("6", { verdict: "denied_path", detail: "/Users/me/.ssh is protected." }),
    ]));
    expect(v.items.map((i) => [i.requestId, i.status])).toEqual([
      ["1:0", "open"], ["2:0", "not_installed"], ["3:0", "unavailable"], ["4:0", "args_not_allowed"], ["5:0", "not_found_here"], ["6:0", "denied_path"],
    ]);
    expect(v.items[1].installTarget).toBe("o/r");
    expect(v.items[2].detail).toBe("add-ons are off on this computer: x");
    expect(v.items[0]).toMatchObject({ from: "alice", team: "agmsg", addonId: "builtin:diffview", pane: "diffview", path: "/p" });
  });
  it("a refused line is a note with Rust's reason, keyed by its request id", () => {
    const v = toOpenView(scan([
      row("1", { verdict: "refused", addonId: undefined, pane: undefined, path: undefined, refusal: { reason: "bad_option", detail: "junk" } }),
    ]));
    expect(v.items).toEqual([]);
    expect(v.notes.get("1:0")).toEqual({ kind: "malformed", reason: "bad_option", detail: "junk" });
  });
  it("a row the UI does not understand is never shown as openable", () => {
    const v = toOpenView(scan([row("1", { verdict: "from_the_future" as never }), row("2", { addonId: undefined })]));
    expect(v.items).toEqual([]);
    expect(v.notes.size).toBe(2);
  });
  it("notice and truncation pass through", () => {
    const v = toOpenView(scan([row("1")], { notice: "This team has no app-user.", truncated: true }));
    expect(v.notice).toBe("This team has no app-user.");
    expect(v.truncated).toBe(true);
  });
});

describe("the bar and messages", () => {
  const items = toOpenView(scan([row("1"), row("2", { verdict: "denied_path", detail: "Protected." })])).items;
  const bar = (list = items, extra: object = {}) =>
    renderToStaticMarkup(createElement(OpenRequestBar, { t, items: list, timeZone: "UTC", onOpen: noop, onDismiss: noop, onInstall: noop, ...extra }));
  it("names the sender and the team, says the sender is not verified on every line, and shows Rust's reason as it is", () => {
    const html = bar();
    expect(html.match(/addons\.request\.unverified/g)?.length).toBe(2);
    expect(html).toContain("Protected.");
    expect(html).toContain("&quot;agent&quot;:&quot;alice&quot;");
    expect(html).toContain("&quot;team&quot;:&quot;agmsg&quot;");
    expect(html).toContain("builtin:diffview diffview");
  });
  it("a denied line has Open disabled", () => {
    expect(bar([items[1]])).toMatch(/<button type="button" disabled="">\[addons\.request\.open\]/);
  });
  it("a refused line is a note with a Dismiss and no Open", () => {
    const html = renderToStaticMarkup(createElement(OpenRequestNotes, { t, notes: [{ requestId: "1:0", note: { kind: "malformed", reason: "bad_option" } }], onDismiss: noop }));
    expect(html).toContain("addons.request.reason.bad_option");
    expect(html).toContain("addons.request.dismiss");
    expect(html).not.toContain("addons.request.open");
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

describe("the lines under the bar", () => {
  const base = { t, error: null, actionError: null };
  const all = { ...base, error: "state_unreadable: broken", actionError: { code: "not_openable", message: "No." }, notice: "No app-user.", truncated: true };
  it("every line has a × to close it", () => {
    const html = renderToStaticMarkup(createElement(OpenRequestMessages, all));
    expect(html.match(/class="addon-request-note-close"/g)?.length).toBe(4);
    expect(html).toContain("addons.request.close");
  });
  it("only the refused click is a one-off; a read that keeps failing, a host notice and truncation stay until closed", () => {
    expect(messageLines(all).map((l) => [l.key, l.sticky])).toEqual([
      ["readFailed", true],
      ["notice", true],
      ["truncated", true],
      ["actionFailed", false],
    ]);
  });
  it("shows nothing when there is nothing to say", () => {
    expect(renderToStaticMarkup(createElement(OpenRequestMessages, base))).toBe("");
  });
  it("a request that was opened or dismissed is not in the next read, so it has no row", () => {
    const next = toOpenView(scan([row("2")])).items;
    const html = renderToStaticMarkup(createElement(OpenRequestBar, { t, items: next, timeZone: "UTC", onOpen: noop, onDismiss: noop, onInstall: noop }));
    expect(html.match(/addon-request-unverified/g)?.length).toBe(1);
    expect(renderToStaticMarkup(createElement(OpenRequestBar, { t, items: [], timeZone: "UTC", onOpen: noop, onDismiss: noop, onInstall: noop }))).toBe("");
  });
});

describe("how old a request is", () => {
  const at = "2026-10-29T08:00:00Z";
  const ms = Date.parse(at);
  const age = (delta: number, tz = "UTC") => relativeTime(at, ms + delta, tz, t);
  it("says just now, minutes, hours, then a date", () => {
    expect(age(0).text).toBe("[addons.request.ago.now]");
    expect(age(59_000).text).toBe("[addons.request.ago.now]");
    expect(age(3 * 60_000).text).toBe('[addons.request.ago.minutes {"count":3}]');
    expect(age(59 * 60_000).text).toBe('[addons.request.ago.minutes {"count":59}]');
    expect(age(2 * 3_600_000).text).toBe('[addons.request.ago.hours {"count":2}]');
    expect(age(23 * 3_600_000 + 59 * 60_000).text).toBe('[addons.request.ago.hours {"count":23}]');
    expect(age(24 * 3_600_000).text).toContain("2026");
    expect(age(24 * 3_600_000).text).not.toContain("ago");
  });
  it("a clock ahead of ours reads as just now", () => {
    expect(age(-5 * 60_000).text).toBe("[addons.request.ago.now]");
  });
  it("the title is the local date and time in the chosen timezone", () => {
    const utc = age(0, "UTC").title;
    const tokyo = age(0, "Asia/Tokyo").title;
    expect(utc).toMatch(/8:00:00/);
    expect(tokyo).toMatch(/5:00:00/); // 17:00 in Tokyo; 12- or 24-hour clocks both contain "5:00:00" / "17:00:00"
    expect(tokyo).not.toBe(utc);
  });
  it("an unreadable time is shown as it came, an unknown zone does not throw", () => {
    expect(relativeTime("not-a-date", ms, "UTC", t)).toEqual({ text: "not-a-date", title: "not-a-date" });
    expect(() => age(0, "Not/AZone")).not.toThrow();
  });
  it("the bar shows the relative text and keeps the exact time in title", () => {
    const html = renderToStaticMarkup(createElement(OpenRequestBar, { t, items: toOpenView(scan([row("1")])).items, timeZone: "UTC", onOpen: noop, onDismiss: noop, onInstall: noop }));
    expect(html).toMatch(/class="addon-request-time" title="[^"]+"/);
    expect(html).not.toMatch(/08:40:00/);
  });
});

describe("the text for seats", () => {
  // The real English text, with {{x}} filled in the way i18next does.
  const fill = (key: string, o?: Record<string, unknown>) =>
    String((en.addons.openRequests as Record<string, string>)[key.split(".").pop()!]).replace(/\{\{(\w+)\}\}/g, (_, k) => String(o?.[k]));
  const seat = { team: "agmsg", appUser: "me-app", scriptsDir: "/Users/me/.agents/skills/agmsg/scripts" };
  const made = seatInstruction(fill, seat);
  const text = made.ok ? made.text : "";
  it("fills in the team, the app user and the scripts folder in a ready-to-run send command", () => {
    expect(made.ok).toBe(true);
    expect(text).toContain('/Users/me/.agents/skills/agmsg/scripts/send.sh agmsg <your seat name> me-app "agmsg-app open builtin:fileview fileview path=/absolute/path/to/folder"');
    expect(text).not.toContain("{{");
  });
  it("says it is not a shell command and that the body is one line, not quoted", () => {
    expect(text.startsWith("This is not a shell command.")).toBe(true);
    expect(text).toContain("send it as an agmsg message to me-app in team agmsg");
    expect(text).toContain("exactly this one line, not quoted, not in a code block");
    expect(text.split("\n")).toContain("agmsg-app open <addon-id> <pane> [path=<absolute path>]");
  });
  it("uses the scripts folder it is given, not a fixed one, and drops a trailing slash", () => {
    const r = seatInstruction(fill, { ...seat, scriptsDir: "/tmp/base/scripts/" });
    expect(r.ok && r.text).toContain("/tmp/base/scripts/send.sh agmsg");
    expect(r.ok && r.text).not.toContain(".agents");
  });
  it("gives a reason, and no text, without a team, an app user or the scripts folder", () => {
    expect(seatInstruction(fill, { ...seat, team: "" })).toEqual({ ok: false, reason: "noTeam" });
    expect(seatInstruction(fill, { ...seat, appUser: "" })).toEqual({ ok: false, reason: "noAppUser" });
    expect(seatInstruction(fill, { ...seat, scriptsDir: "" })).toEqual({ ok: false, reason: "noScripts" });
  });
  it("Japanese has the same placeholders and the same command line", () => {
    const en_ = en.addons.openRequests.seatText, ja_ = ja.addons.openRequests.seatText;
    const ph = (x: string) => (x.match(/\{\{\w+\}\}/g) ?? []).sort().join();
    expect(ph(ja_)).toBe(ph(en_));
    expect(ja_.split("\n").filter((l) => l.includes("send.sh"))).toEqual(en_.split("\n").filter((l) => l.includes("send.sh")));
  });
});

describe("open-request commands", () => {
  it("send the names and argument shapes Rust expects and return its refusal words", async () => {
    const calls: [string, Record<string, unknown> | undefined][] = [];
    const invoke: Invoke = async (cmd, args) => {
      calls.push([cmd, args]);
      if (cmd === "addon_open_requests") throw { code: "state_unreadable", message: "The handled-request record cannot be read." };
      if (cmd === "addon_open_request_open") return { requestId: "1:0", from: "alice", addonId: "builtin:diffview", pane: "diffview", openArgs: { path: "/p" } };
      return null;
    };
    const s = createLiveSource(invoke);
    expect(await s.openRequests("agmsg")).toEqual({ ok: false, error: { code: "state_unreadable", message: "The handled-request record cannot be read." } });
    expect(await s.openRequestOpen("agmsg", "1:0")).toMatchObject({ ok: true, value: { addonId: "builtin:diffview", openArgs: { path: "/p" } } });
    expect(await s.openRequestDismiss("agmsg", "1:0")).toEqual({ ok: true, value: null });
    expect(calls).toEqual([
      ["addon_open_requests", { team: "agmsg" }],
      ["addon_open_request_open", { spec: { team: "agmsg", requestId: "1:0" } }],
      ["addon_open_request_dismiss", { spec: { team: "agmsg", requestId: "1:0" } }],
    ]);
  });
});
