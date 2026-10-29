import type { Translate } from "./model";

// How old an open request is, in words: "just now", "3 min ago", "2 h ago", then a date.
// The full local date and time (in the timezone setting) goes in the title attribute.

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** How often the bar re-reads the clock. */
export const TICK_MS = 30_000;

export function relativeTime(iso: string, now: number, timeZone: string, t: Translate): { text: string; title: string } {
  const at = new Date(iso).getTime();
  if (Number.isNaN(at)) return { text: iso, title: iso };
  const title = formatIn(at, timeZone, { dateStyle: "medium", timeStyle: "medium" }) ?? iso;
  const age = now - at;
  // A clock a little ahead of ours reads as "just now" rather than a negative age.
  if (age < MINUTE) return { text: t("addons.request.ago.now"), title };
  if (age < HOUR) return { text: t("addons.request.ago.minutes", { count: Math.floor(age / MINUTE) }), title };
  if (age < DAY) return { text: t("addons.request.ago.hours", { count: Math.floor(age / HOUR) }), title };
  return { text: formatIn(at, timeZone, { dateStyle: "medium" }) ?? iso.slice(0, 10), title };
}

function formatIn(ms: number, timeZone: string, o: Intl.DateTimeFormatOptions): string | undefined {
  try {
    return new Intl.DateTimeFormat(undefined, { ...o, timeZone }).format(new Date(ms));
  } catch {
    return undefined;
  }
}
