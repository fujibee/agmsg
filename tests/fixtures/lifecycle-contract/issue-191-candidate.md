# Public lifecycle capability candidate evidence

- Baseline: `660f67b60e74517299e3703a1f71672915db745e`
- Candidate command: `rtk bats --print-output-on-failure tests/test_lifecycle_contract.bats`
- Candidate result: `24/24` lifecycle contract assertions GREEN, including concurrent
  retry convergence, receipt/ACK layers, wake and processing lease replay,
  active/history projection, additive migration, export/restore, public API,
  atomic work registration plus launch outbox, transaction rollback failpoints,
  public notifier-error visibility, and explicit unsupported-driver behavior.
- Enforced-assertion gate: `33/33` GREEN for
  `tests/test_enforced_assertions.bats tests/test_lifecycle_contract.bats`.
- Focused upstream gate: `138/138` GREEN for storage contract, messaging,
  inbox, API, watch, and lifecycle contract suites.
- Upstream harness gate: `277/277` GREEN outside the sandbox (`3` platform
  skips).
- First exact-head full upstream gate: `1734/1734` GREEN for `rtk bats tests/`;
  the emitted
  BW02 warnings predate this change and point to minimum-version declarations
  in `test_remote_sync.bats` and `test_storage.bats`.
- Safeguard mutation: replace SQLite's
  `PRIMARY KEY(team,sender,operation_key)` with a key that also includes the
  generated message id, allowing every retry to insert independently.
- Mutation command: `bats --print-output-on-failure --filter 'concurrent retries' tests/test_lifecycle_contract.bats`
- Mutation result: RED at the convergence assertion (`status` was non-zero),
  proving the oracle detects removal of operation-key serialization.
- Restoration: the original primary key was restored immediately after the
  mutation run; the mutation is not part of the candidate diff.
- Review-fix safeguard mutations: omit atomic launch insertion; remove SQLite
  `-bail`; rename the processing-expiry reason; rename the public outbox-error
  event; and omit facade defaults for a trusted legacy external driver.
- Review-fix mutation result: the five corresponding tests ran `0/5`, each at
  its named contract assertion. All five mutations were immediately restored,
  then the same selection returned `5/5` GREEN.

The exact candidate head is recorded at the PR evidence gate after the
implementation and contract-documentation commits are fixed.
