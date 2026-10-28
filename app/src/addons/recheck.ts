// "Check again" in Settings → Add-ons: when it is offered and what it shows. The engine state's
// reasons come from the Rust gate as plain English.

const NOT_VERIFIED = "add-ons are not verified on WebView2 yet";

/** A check is running or about to run (the gate's own wording for those states). */
export function isChecking(reasons: string[]): boolean {
  return reasons.length > 0 && /^(checking again|the startup check has not run)/.test(reasons[0]);
}

/**
 * Offered only when the check ended off for a reason running it again could change: a failure or a
 * timeout. Not while it is running, and not when the only reason is "not verified" (a build that is
 * simply not enabled on this engine yet: asking again gives the same answer).
 */
export function offersRecheck(reasons: string[]): boolean {
  if (reasons.length === 0 || isChecking(reasons)) return false;
  return !reasons.every((r) => r === NOT_VERIFIED);
}
