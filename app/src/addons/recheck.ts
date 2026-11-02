// "Check again" in Settings → Add-ons and the reason shown for it. The Rust gate gives every reason
// a stable code (`Verdict.codes`); everything here goes by code, never by the English text.

/** A check is running or about to run. */
export function isChecking(codes: string[]): boolean {
  return codes.length > 0 && (codes[0] === "checking" || codes[0] === "check-pending");
}

/**
 * Offered only when the check ended off for a reason running it again could change: a failure or a
 * timeout. Not while it is running, and not when the only reason is "not verified" or an
 * unsupported platform (asking again gives the same answer).
 */
export function offersRecheck(codes: string[]): boolean {
  if (codes.length === 0 || isChecking(codes)) return false;
  return !codes.every((c) => c === "not-verified" || c === "platform-unsupported");
}

/** The user-facing message key for a gate reason code; unknown codes get the general one. */
const REASON_KEYS: Record<string, string> = {
  "not-verified": "addons.reason.notVerified",
  "platform-unsupported": "addons.reason.platform",
  "webrtc-available": "addons.reason.network",
  "webrtc-udp": "addons.reason.network",
  "webrtc-no-setting": "addons.reason.network",
  "webrtc-setting-failed": "addons.reason.network",
  "frame-guard": "addons.reason.navigation",
  "probe-nav-unproven": "addons.reason.navigation",
  "probe-self-navigation": "addons.reason.navigation",
  "probe-no-violation": "addons.reason.navigation",
  "probe-not-run": "addons.reason.isolation",
  "probe-origin": "addons.reason.isolation",
  "probe-csp": "addons.reason.isolation",
  "probe-wrong-nonce": "addons.reason.isolation",
  "check-timeout": "addons.reason.unfinished",
  "check-start-failed": "addons.reason.unfinished",
};

/** Distinct message keys for the codes, in order (several codes can share one message). */
export function reasonKeys(codes: string[]): string[] {
  const keys = codes.map((c) => REASON_KEYS[c] ?? "addons.reason.generic");
  return keys.filter((k, i) => keys.indexOf(k) === i);
}
