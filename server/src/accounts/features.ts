import type { Profile } from "../config.js";

// What a client may rely on, by profile. A client reads these lists and uses a
// listed feature; anything else keeps today's manual path, and a name it does
// not know is ignored. Never branch on a host name.
//
// Origin-level: readable before any team exists, from unauthenticated
// GET /v1/health.
export function originFeatures(profile: Profile): string[] {
  return profile === "accounts" ? ["device-approval"] : [];
}

// Team-level: from authenticated GET /v1/capabilities, after connect.
export function teamFeatures(profile: Profile): string[] {
  return profile === "accounts" ? ["devices"] : [];
}
