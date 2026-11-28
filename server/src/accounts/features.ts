import type { Profile } from "../config.js";
import type { EscrowBackendName } from "../escrow.js";
import { hasLimits, type Limits } from "../limits.js";

// What a client may rely on, by profile. A client reads these lists and uses a
// listed feature; anything else keeps today's manual path, and a name it does
// not know is ignored. Never branch on a host name.
//
// Origin-level: readable before any team exists, from unauthenticated
// GET /v1/health.
//
// key-escrow is listed here as well as at team level: a client decides which
// cipher a team connects with before /v1/connect, so it must learn that keys are
// escrowed before any team exists. Same rule as at team level: only with a
// backend, only in the accounts profile.
export function originFeatures(
  profile: Profile,
  escrowBackend: EscrowBackendName = "none",
): string[] {
  if (profile !== "accounts") return [];
  return escrowBackend === "none"
    ? ["device-approval", "env-markers"]
    : ["device-approval", "env-markers", "key-escrow"];
}

// Team-level: from authenticated GET /v1/capabilities, after connect.
// roster-snapshot has no profile dependency -- the open profile has it too.
export function teamFeatures(
  profile: Profile,
  escrowBackend: EscrowBackendName = "none",
  limits?: Limits,
): string[] {
  const features: string[] = ["roster-snapshot"];
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
