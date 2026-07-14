// Timezone-aware formatting for chat/team-room timestamps. agmsg's message
// store writes created_at as UTC (strftime('%Y-%m-%dT%H:%M:%SZ', 'now') —
// see init-db.sh), so displaying it correctly always requires a conversion;
// there is no "just show the string" option (see issue #393).

/** Sentinel stored/selected value meaning "follow the OS timezone live",
 * rather than freezing whatever was detected at first launch. */
export const AUTO_TIMEZONE = "auto";

export function detectTimeZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone;
  } catch {
    return "UTC";
  }
}

/** All IANA zone names the runtime knows about, for the Settings dropdown.
 * `Intl.supportedValuesOf` landed in evergreen webviews in 2022 — Tauri v2's
 * minimum WebView2/WebKit versions are new enough, but this degrades to
 * just the detected zone (still usable, just not a full picker) rather than
 * throwing on an unexpectedly old webview. */
export function listTimeZones(): string[] {
  const intl = Intl as unknown as { supportedValuesOf?: (key: string) => string[] };
  try {
    const zones = intl.supportedValuesOf?.("timeZone");
    if (zones && zones.length > 0) return zones;
  } catch {
    // fall through to the single-zone fallback below
  }
  return [detectTimeZone()];
}

/** Formats a UTC ISO 8601 timestamp as 24-hour HH:MM:SS in `timeZone`.
 * Built from Intl.DateTimeFormat's parts (not its formatted string) to
 * avoid locale-specific punctuation/midnight-as-"24:00" quirks across
 * webview engines — this only ever needs three zero-padded numbers. */
export function formatMessageTime(createdAt: string, timeZone: string): string {
  const d = new Date(createdAt);
  if (Number.isNaN(d.getTime())) return createdAt.slice(11, 19);
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hour12: false,
    }).formatToParts(d);
    const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "00";
    return `${get("hour")}:${get("minute")}:${get("second")}`;
  } catch {
    return createdAt.slice(11, 19);
  }
}

/** Resolves the "auto" sentinel to a real IANA zone; passes an explicit
 * override through unchanged. */
export function resolveTimeZone(selected: string): string {
  return selected === AUTO_TIMEZONE ? detectTimeZone() : selected;
}
