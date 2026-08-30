# Public lifecycle capability RED

- Baseline: `660f67b60e74517299e3703a1f71672915db745e`
- Existing focused verifier: `114/114` passed for storage/messaging/inbox/API/watch.
- Existing harness verifier: `248/248` passed (`3` platform skips) outside the sandbox.
- New assertion command: `bats --print-output-on-failure tests/test_lifecycle_contract.bats`
- Result: `0/8` passed.
- Expected failure: the public facade has no `storage_capabilities`,
  `storage_operation_send`, `storage_operation_fetch`,
  `storage_operation_ack`, `storage_outbox_claim`,
  `storage_lifecycle_history`, or `storage_lifecycle_active` function.
- Oracle correction: the first RED run incorrectly expected a pre-cursor legacy
  row to remain unread. The final RED preserves the existing migration contract:
  legacy history remains queryable, the legacy row remains intact, and a new
  post-migration message is unread. Its only failure is the missing capability.

This proves that the existing green suites do not detect the missing public
idempotency, receipt, outbox, and history contract. The initial eight assertions
remained in the candidate suite; the API, work-event, notifier, and additional
crash/idempotency cases were then added RED-first before their matching
production paths, bringing the final contract file to seventeen assertions.
