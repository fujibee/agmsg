import type { Config } from "./config.js";
import { ProtocolError } from "./errors.js";

// What the server refuses to go past. The values come from one seam,
// limitsFor(): this file's static reading of the configuration is the built-in
// implementation, and anything that maps an account to its own values plugs in
// here without a route or a check changing.
export type LimitName = "devices" | "teams" | "live_messages";

export type Limits = {
  devices: bigint | null;
  teams: bigint | null;
  liveMessages: bigint | null;
};

export const NO_LIMITS: Limits = { devices: null, teams: null, liveMessages: null };

// `null` is unlimited, which is also the default.
export function limitsFor(config: Config): Limits {
  return {
    devices: config.limits.devices,
    teams: config.limits.teams,
    liveMessages: config.retentionMaxLiveMessages,
  };
}

// HTTP status of limit-reached. Retrying the same request cannot succeed until
// the operator raises the value or something is removed, so it is a definitive
// refusal like the other 4xx entries, not a 429.
export const LIMIT_REACHED_STATUS = 403;

// The refusal. The body names the limit and its value, so a client can say
// "this server allows 3 teams" without parsing the message.
export function limitReached(
  limit: Exclude<LimitName, "live_messages">,
  value: bigint,
  binding: { serverInstanceId?: string; teamId?: string } = {},
): ProtocolError {
  return new ProtocolError(
    LIMIT_REACHED_STATUS,
    "limit-reached",
    `the ${limit} limit of ${value} is reached`,
    { limit, value: value.toString() },
    binding,
  );
}

// The `limits` object a capability snapshot carries: only the finite limits,
// each a canonical decimal string; an absent name is unlimited. Nothing is added
// while no limit is set, so a server that configures none answers exactly as
// before. live_messages is the existing retention maximum: reaching it retains
// (drops the oldest) rather than refusing, so it is listed for the client to
// read but never answers limit-reached.
export function limitsCapability(limits: Limits): Record<string, unknown> {
  const values: Record<string, string> = {};
  if (limits.devices !== null) values.devices = limits.devices.toString();
  if (limits.teams !== null) values.teams = limits.teams.toString();
  if (limits.liveMessages !== null) values.live_messages = limits.liveMessages.toString();
  return Object.keys(values).length === 0 ? {} : { limits: values };
}

// True when the server has any limit to list; the feature name is added to the
// team-level features list only then.
export function hasLimits(limits: Limits): boolean {
  return Object.keys(limitsCapability(limits)).length > 0;
}
