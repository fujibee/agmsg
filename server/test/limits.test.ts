import { describe, expect, it } from "vitest";
import { teamFeatures } from "../src/accounts/features.js";
import { errorBody } from "../src/errors.js";
import { limitReached, limitsCapability } from "../src/limits.js";

describe("limit-reached", () => {
  it("is a 403 whose body names the limit and its value", () => {
    const error = limitReached("teams", 5n, { serverInstanceId: "s", teamId: "t" });
    expect(error.statusCode).toBe(403);
    expect(errorBody(error)).toEqual({
      protocol_version: 1,
      server_instance_id: "s",
      team_id: "t",
      error: {
        code: "limit-reached",
        message: "the teams limit of 5 is reached",
        details: { limit: "teams", value: "5" },
      },
    });
  });
});

describe("the limits capability", () => {
  const none = { devices: null, teams: null, liveMessages: null };

  it("adds nothing while no limit is set", () => {
    expect(limitsCapability(none)).toEqual({});
  });

  it("lists only the finite values, as decimal strings", () => {
    expect(limitsCapability({ ...none, teams: 5n, liveMessages: 100000n })).toEqual({
      limits: { teams: "5", live_messages: "100000" },
    });
  });

  it("adds the feature name only while a limit is set, in either profile", () => {
    expect(teamFeatures("open", "none", none)).toEqual([]);
    expect(teamFeatures("open", "none", { ...none, teams: 5n })).toEqual(["limits"]);
    expect(teamFeatures("accounts", "none", none)).toEqual(["devices"]);
    expect(teamFeatures("accounts", "none", { ...none, devices: 3n })).toEqual(["devices", "limits"]);
  });
});
