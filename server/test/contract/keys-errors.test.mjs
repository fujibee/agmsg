import { randomBytes } from "node:crypto";
import { expect, it } from "vitest";
import { assertKeyMetadata, assertKeyEpoch, assertKeyHandoffHeader } from "./keys.contract.mjs";

const checks = [
  ["protocol metadata", value => assertKeyMetadata({ protocol_version: value }, "fixture-team")],
  ["epoch response", value => assertKeyEpoch({ epoch: value }, 1)],
  ["decrypted handoff", value => assertKeyHandoffHeader({ format_version: value, type: "agmsg_age_v1_handoff", snapshots: [], identities: [] })],
];

it.each(checks)("does not expose reflected private material in %s assertion diagnostics", (_label, check) => {
  const sentinel = `private-reflection-${randomBytes(16).toString("hex")}`;
  for (const malicious of [sentinel, { private_value: sentinel }, [sentinel]]) {
    let failure;
    try { check(malicious); } catch (error) { failure = error; }
    expect(failure).toBeInstanceOf(Error);
    const report = JSON.stringify({
      message: failure.message,
      stack: failure.stack,
      actual: failure.actual,
      expected: failure.expected,
    });
    expect(report).not.toContain(sentinel);
  }
});
