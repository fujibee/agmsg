import { describe, expect, it } from "vitest";
import { formatDiagnosticReport, scanEscapes, summarizeEscapes } from "./escapeCapture";

const ESC = "\x1b";

describe("scanEscapes", () => {
  it("finds no events in plain text", () => {
    expect(scanEscapes("hello world\n")).toEqual([]);
  });

  it("classifies sync-begin and sync-end", () => {
    const events = scanEscapes(`${ESC}[?2026htext${ESC}[?2026l`);
    expect(events.map((e) => e.kind)).toEqual(["sync-begin", "sync-end"]);
  });

  it("classifies cursor-show and cursor-hide", () => {
    const events = scanEscapes(`${ESC}[?25l${ESC}[?25h`);
    expect(events.map((e) => e.kind)).toEqual(["cursor-hide", "cursor-show"]);
  });

  it("classifies DECSCUSR", () => {
    const events = scanEscapes(`${ESC}[2 q`);
    expect(events).toEqual([{ kind: "decscusr", raw: `${ESC}[2 q` }]);
  });

  it("classifies cursor-motion CSIs", () => {
    const events = scanEscapes(`${ESC}[3A${ESC}[10;5H`);
    expect(events.map((e) => e.kind)).toEqual(["cursor-move", "cursor-move"]);
  });

  it("ignores unrelated CSIs like SGR color and erase-line", () => {
    expect(scanEscapes(`${ESC}[31m${ESC}[K`)).toEqual([]);
  });

  it("scans a chunk with several interleaved sequences in order", () => {
    const chunk = `${ESC}[?2026h${ESC}[5;1Htext${ESC}[?25l${ESC}[?2026l`;
    const events = scanEscapes(chunk);
    expect(events.map((e) => e.kind)).toEqual(["sync-begin", "cursor-move", "cursor-hide", "sync-end"]);
  });
});

describe("summarizeEscapes", () => {
  it("zero-counts every kind for an empty event list", () => {
    const summary = summarizeEscapes([]);
    expect(summary.counts).toEqual({
      "sync-begin": 0,
      "sync-end": 0,
      "cursor-show": 0,
      "cursor-hide": 0,
      decscusr: 0,
      "cursor-move": 0,
    });
    expect(summary.syncPairBalance).toBe(0);
    expect(summary.cursorVisibilityPairBalance).toBe(0);
    expect(summary.recentTimeline).toEqual([]);
  });

  it("reports a positive sync pair balance when begin outnumbers end (unclosed sync)", () => {
    const events = scanEscapes(`${ESC}[?2026h${ESC}[?2026h${ESC}[?2026l`);
    expect(summarizeEscapes(events).syncPairBalance).toBe(1);
  });

  it("reports a positive cursor-visibility balance when hide outnumbers show", () => {
    const events = scanEscapes(`${ESC}[?25l${ESC}[?25l${ESC}[?25h`);
    expect(summarizeEscapes(events).cursorVisibilityPairBalance).toBe(1);
  });

  it("caps the recent timeline to the given limit, keeping the most recent", () => {
    const events = scanEscapes(`${ESC}[?25h${ESC}[?25l${ESC}[?25h`);
    const summary = summarizeEscapes(events, 2);
    expect(summary.recentTimeline).toHaveLength(2);
    expect(summary.recentTimeline[0].kind).toBe("cursor-hide");
    expect(summary.recentTimeline[1].kind).toBe("cursor-show");
  });
});

describe("formatDiagnosticReport", () => {
  it("embeds toggle state, app version, and timestamp so the report is self-describing", () => {
    const report = formatDiagnosticReport({
      summary: summarizeEscapes(scanEscapes(`${ESC}[?2026h${ESC}[?2026l`)),
      cursorBlinkEnabled: false,
      hideCursorWhileWorking: true,
      appVersion: "0.2.0",
      capturedAt: "2026-07-18T00:00:00.000Z",
    });
    expect(report).toContain("app version: 0.2.0");
    expect(report).toContain("captured at: 2026-07-18T00:00:00.000Z");
    expect(report).toContain("cursorBlink=off");
    expect(report).toContain("hideCursorWhileWorking=on");
    expect(report).toContain("sync pair balance (begin-end, 0=balanced): 0");
  });

  it("lists the recent timeline entries with their raw sequence", () => {
    const report = formatDiagnosticReport({
      summary: summarizeEscapes(scanEscapes(`${ESC}[?25l`)),
      cursorBlinkEnabled: true,
      hideCursorWhileWorking: false,
      appVersion: "0.2.0",
      capturedAt: "2026-07-18T00:00:00.000Z",
    });
    expect(report).toContain("1. cursor-hide");
  });
});
