// Diagnostic-only (issue #383, Windows Codex CLI cursor flicker): pure
// parsing/aggregation of the escape sequences co1's static investigation
// flagged as relevant — DEC synchronized-output (?2026h/l), cursor
// visibility (?25h/l), DECSCUSR (cursor style/blink), and cursor-moving
// CSIs. Kept DOM/React-free so it's unit-testable without a rendered
// terminal (this repo's convention — see paneTree.ts). Not wired into any
// normal-release code path; only the diagnostic branch's capture feeds it.

export type EscapeKind = "sync-begin" | "sync-end" | "cursor-show" | "cursor-hide" | "decscusr" | "cursor-move";

export type EscapeEvent = {
  kind: EscapeKind;
  raw: string;
};

// Matches, in order of preference (first alternative that matches wins):
// sync begin/end, cursor show/hide, DECSCUSR (CSI Ps SP q), then a broad
// cursor-motion CSI set (CUU/CUD/CUF/CUB/CHA/CUP, `\x1b[<row>;<col>H|f`).
// Deliberately narrow rather than "any CSI" — SGR (color, ends in 'm'),
// erase (J/K), and scroll-region sequences are noise for this purpose.
const ESCAPE_PATTERN =
  /\x1b\[\?2026h|\x1b\[\?2026l|\x1b\[\?25h|\x1b\[\?25l|\x1b\[\d*\ q|\x1b\[\d*(?:;\d*)?[ABCDGHf]/g;

function classify(raw: string): EscapeKind {
  if (raw === "\x1b[?2026h") return "sync-begin";
  if (raw === "\x1b[?2026l") return "sync-end";
  if (raw === "\x1b[?25h") return "cursor-show";
  if (raw === "\x1b[?25l") return "cursor-hide";
  if (raw.endsWith(" q")) return "decscusr";
  return "cursor-move";
}

// A chunk that splits an escape sequence across a PTY read boundary is a
// known, accepted gap — reassembling across chunks would need buffering
// state this function deliberately doesn't carry. Good enough for a
// diagnostic capture, not a terminal emulator.
export function scanEscapes(chunk: string): EscapeEvent[] {
  const events: EscapeEvent[] = [];
  for (const match of chunk.matchAll(ESCAPE_PATTERN)) {
    events.push({ kind: classify(match[0]), raw: match[0] });
  }
  return events;
}

export type EscapeSummary = {
  counts: Record<EscapeKind, number>;
  // begin-end / hide-show: 0 means every open was matched by a close: the
  // signal co1's investigation most wants (an unmatched sync-begin, e.g.,
  // would mean the reporter's terminal never got told to resume painting).
  syncPairBalance: number;
  cursorVisibilityPairBalance: number;
  recentTimeline: EscapeEvent[];
};

const ZERO_COUNTS: Record<EscapeKind, number> = {
  "sync-begin": 0,
  "sync-end": 0,
  "cursor-show": 0,
  "cursor-hide": 0,
  decscusr: 0,
  "cursor-move": 0,
};

export function summarizeEscapes(events: EscapeEvent[], recentLimit = 40): EscapeSummary {
  const counts = { ...ZERO_COUNTS };
  for (const e of events) counts[e.kind] += 1;
  return {
    counts,
    syncPairBalance: counts["sync-begin"] - counts["sync-end"],
    cursorVisibilityPairBalance: counts["cursor-hide"] - counts["cursor-show"],
    recentTimeline: events.slice(-recentLimit),
  };
}

export type DiagnosticReportParams = {
  summary: EscapeSummary;
  cursorBlinkEnabled: boolean;
  hideCursorWhileWorking: boolean;
  appVersion: string;
  capturedAt: string;
};

// A human-pasteable plain-text report — this is what the diagnostic modal's
// Copy button puts on the clipboard. Toggle state/app version/timestamp are
// embedded so a pasted report is self-describing (see #383 diag scope: the
// reporter isn't asked to judge which run is which).
export function formatDiagnosticReport(params: DiagnosticReportParams): string {
  const { summary, cursorBlinkEnabled, hideCursorWhileWorking, appVersion, capturedAt } = params;
  const lines = [
    "agmsg cursor flicker diagnostic capture (issue #383)",
    `app version: ${appVersion}`,
    `captured at: ${capturedAt}`,
    `toggles: cursorBlink=${cursorBlinkEnabled ? "on" : "off"} hideCursorWhileWorking=${hideCursorWhileWorking ? "on" : "off"}`,
    "",
    "counts:",
    `  sync-begin (?2026h): ${summary.counts["sync-begin"]}`,
    `  sync-end   (?2026l): ${summary.counts["sync-end"]}`,
    `  sync pair balance (begin-end, 0=balanced): ${summary.syncPairBalance}`,
    `  cursor-hide (?25l): ${summary.counts["cursor-hide"]}`,
    `  cursor-show (?25h): ${summary.counts["cursor-show"]}`,
    `  cursor-visibility pair balance (hide-show, 0=balanced): ${summary.cursorVisibilityPairBalance}`,
    `  DECSCUSR (cursor style/blink changes): ${summary.counts.decscusr}`,
    `  cursor-move CSIs: ${summary.counts["cursor-move"]}`,
    "",
    `recent timeline (most recent ${summary.recentTimeline.length}):`,
    ...summary.recentTimeline.map((e, i) => `  ${i + 1}. ${e.kind} ${JSON.stringify(e.raw)}`),
  ];
  return lines.join("\n");
}
