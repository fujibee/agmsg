# Public lifecycle capability candidate evidence

- Baseline: `660f67b60e74517299e3703a1f71672915db745e`
- Candidate command: `rtk bats --print-output-on-failure tests/test_lifecycle_contract.bats`
- Candidate result: `17/17` lifecycle contract assertions GREEN, including concurrent
  retry convergence, receipt/ACK layers, wake and processing lease replay,
  active/history projection, additive migration, export/restore, public API,
  and explicit unsupported-driver behavior.
- Enforced-assertion gate: `26/26` GREEN for
  `tests/test_enforced_assertions.bats tests/test_lifecycle_contract.bats`.
- Focused upstream gate: `130/130` GREEN for storage contract, messaging,
  inbox, API, watch, and lifecycle contract suites.
- Upstream harness gate: `248/248` GREEN outside the sandbox (`3` platform
  skips).
- Full upstream gate: `1734/1734` GREEN for `rtk bats tests/`; the emitted
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

The exact candidate head is recorded at the PR evidence gate after the
implementation and contract-documentation commits are fixed.
