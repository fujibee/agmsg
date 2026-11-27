import type { Profile } from "../config.js";
import type { EscrowBackendName } from "../escrow.js";
import { hasLimits, type Limits } from "../limits.js";

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
export function teamFeatures(
  profile: Profile,
  escrowBackend: EscrowBackendName = "none",
  limits?: Limits,
): string[] {
  const features: string[] = [];
  if (profile === "accounts") {
    features.push("devices");
    // key-escrow only when this server will actually hold wrapped keys.
    if (escrowBackend !== "none") features.push("key-escrow");
  }
  // Listed only while the operator set one, in any profile: a refusal the
  // server enforces is one a client is told about.
  if (limits && hasLimits(limits)) features.push("limits");
  return features;
}
