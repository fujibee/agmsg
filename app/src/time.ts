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

export function isValidTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat(undefined, { timeZone });
    return true;
  } catch {
    return false;
  }
}

// One formatter per zone, reused across every message/render — a chat
// history with hundreds of visible messages would otherwise construct a
// fresh Intl.DateTimeFormat per message per render for what's always the
// same (timeZone, options) pair.
const formatterCache = new Map<string, Intl.DateTimeFormat>();
function formatterFor(timeZone: string): Intl.DateTimeFormat {
  let formatter = formatterCache.get(timeZone);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      // hour12: false alone is ambiguous — depending on the ICU version,
      // "false" can still resolve to the h24 cycle (which renders midnight
      // as "24", not "00"). hourCycle: "h23" is the unambiguous way to pin
      // 0-23 with midnight as "00" (caught by CI running a different Node
      // than local dev — see the midnight regression test).
      hourCycle: "h23",
    });
    formatterCache.set(timeZone, formatter);
  }
  return formatter;
}

/** Formats a UTC ISO 8601 timestamp as 24-hour HH:MM:SS in `timeZone`.
 * Built from Intl.DateTimeFormat's parts (not its formatted string) to
 * avoid locale-specific punctuation/midnight-as-"24:00" quirks across
 * webview engines — this only ever needs three zero-padded numbers. */
export function formatMessageTime(createdAt: string, timeZone: string): string {
  const d = new Date(createdAt);
  if (Number.isNaN(d.getTime())) return createdAt.slice(11, 19);
  try {
    const parts = formatterFor(timeZone).formatToParts(d);
    const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "00";
    return `${get("hour")}:${get("minute")}:${get("second")}`;
  } catch {
    return createdAt.slice(11, 19);
  }
}

/** Resolves the "auto" sentinel to a real IANA zone; passes a valid
 * explicit override through unchanged. Falls back to the auto-detected
 * zone for anything invalid (a corrupted localStorage value, or a zone
 * name the runtime no longer recognizes) rather than letting an unknown
 * zone reach Intl.DateTimeFormat, which would make formatMessageTime fall
 * back to the raw UTC slice — silently reintroducing #393 for that one
 * stored value. */
export function resolveTimeZone(selected: string): string {
  if (selected === AUTO_TIMEZONE) return detectTimeZone();
  return isValidTimeZone(selected) ? selected : detectTimeZone();
}
