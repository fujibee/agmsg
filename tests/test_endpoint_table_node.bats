#!/usr/bin/env bats

# The endpoint specification, driven through the continued-sync call site.
# Connect and pull use the same validateEndpoint() implementation through its
# CLI adapter, so there is no second verdict to compare. Keeping an agreement
# test after deleting the second implementation would make a test that cannot
# fail look like coverage.
#
# Driven through connectedBinding(), not through the rule function it calls.
# Testing the helper directly would leave the call site unbound: reverting
# connectedBinding to its old inline loopback list keeps the helper correct and
# every such test green, while continued sync goes back to refusing LAN
# addresses — precisely the "pull works, sync dies" failure this defends.

load test_helper

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  TABLE="$(endpoint_table_path)"
}

endpoint_table_path() {
  printf '%s\n' "${AGMSG_ENDPOINT_TABLE:-$BATS_TEST_DIRNAME/fixtures/endpoint-verdicts.jsonl}"
}

@test "endpoint table: the per-sync check answers every row as the table says (#717)" {
  # One node process for the whole table rather than one per row: 50-odd
  # interpreter starts is the difference between a test that runs on every push
  # and one that gets marked slow and skipped.
  run env AGMSG_ENDPOINT_TABLE="$TABLE" AGMSG_SCRIPTS="$SCRIPTS" \
    node --input-type=module -e '
      import { readFileSync } from "node:fs";
      const { connectedBinding } = await import(
        `${process.env.AGMSG_SCRIPTS}/internal/remote-sync.mjs`
      );

      const path = process.env.AGMSG_ENDPOINT_TABLE;
      const lines = readFileSync(path, "utf8").split("\n").filter((l) => l.trim());
      if (lines.length === 0) {
        console.error(`${path}: no rows. An empty table passes every test it has.`);
        process.exit(1);
      }

      // What continued sync actually calls. Everything but the endpoint is a
      // fixed, valid binding, so the only thing under test is the endpoint.
      const accepts = (endpoint) => {
        try {
          connectedBinding({
            name: "demo",
            remote_binding: {
              endpoint,
              server_instance_id: "018f3f7e-0000-7000-8000-000000000000",
              remote_team_id: "018f3f7e-0000-7000-8000-000000000001",
              protocol_version: 1,
              connected_at: "2026-07-20T13:00:00.000Z",
              disconnected_at: null,
              capabilities: { write_allowed_ciphers: ["none"] },
            },
          }, "demo");
          return true;
        } catch {
          return false;
        }
      };

      let checked = 0, disagreed = 0;
      for (const [i, line] of lines.entries()) {
        const { endpoint, verdict } = JSON.parse(line);
        if (verdict !== "allow" && verdict !== "deny") {
          console.error(`${path}:${i + 1}: verdict must be allow or deny, got ${verdict}`);
          process.exit(1);
        }
        const got = accepts(endpoint) ? "allow" : "deny";
        checked += 1;
        if (got !== verdict) {
          console.error(`connectedBinding: ${endpoint} -> ${got}, table says ${verdict}`);
          disagreed += 1;
        }
      }
      console.log(`checked=${checked} disagreed=${disagreed}`);
      process.exit(disagreed === 0 ? 0 : 1);
    '

  echo "$output"
  [ "$status" -eq 0 ]
  # A driver that read no rows exits 1 above, but assert the count here too:
  # it also pins the number of specification rows this harness actually walked.
  grep -qF "checked=$(grep -c . "$TABLE") disagreed=0" <<<"$output"
}

@test "endpoint table: the default resolves to the shipped fixture (#722)" {
  unset AGMSG_ENDPOINT_TABLE
  [ "$(endpoint_table_path)" = "$BATS_TEST_DIRNAME/fixtures/endpoint-verdicts.jsonl" ]
}
