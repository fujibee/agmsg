// A fixed-window counter: the window opens on the first hit for a key and
// closes an hour later. In memory, so per process; the reference server runs as
// one process. Swept so a caller cycling keys cannot grow the map without bound.
const HOUR_MS = 60 * 60 * 1000;

export class FixedWindowCounter {
  private readonly windows = new Map<string, { count: number; resetAt: number }>();

  // True if the action is allowed (and counted), false if `key` is over `limit`.
  hit(key: string, limit: number, now: number): boolean {
    const window = this.windows.get(key);
    if (!window || now >= window.resetAt) {
      this.windows.set(key, { count: 1, resetAt: now + HOUR_MS });
      return true;
    }
    if (window.count >= limit) return false;
    window.count += 1;
    return true;
  }

  // True when `key` has used up `limit` in its current window. Counts nothing.
  over(key: string, limit: number, now: number): boolean {
    const window = this.windows.get(key);
    return window !== undefined && now < window.resetAt && window.count >= limit;
  }

  sweep(now: number): void {
    for (const [key, window] of this.windows) {
      if (now >= window.resetAt) this.windows.delete(key);
    }
  }
}

export const DEVICE_LIMITS = {
  issuePerAddressPerHour: 20,
  // Sign-in and approval attempts, per source address. The owner secret is the
  // only credential here, so guessing it is bounded by this and by its length.
  signInPerAddressPerHour: 10,
  actionsPerAddressPerHour: 60,
  // Polls of POST /v1/device/token per address: a machine polls every 5 seconds
  // (720 an hour), so this leaves room for five machines behind one address.
  tokenPollsPerAddressPerHour: 3600,
  // Device codes that match no grant, per address. A real machine presents the
  // code it was issued, so a run of unknown ones is guessing.
  unknownDeviceCodesPerAddressPerHour: 60,
  // Wrong or unknown user codes entered per address; a real code is 40 bits.
  codeAttemptsPerAddressPerHour: 30,
} as const;
