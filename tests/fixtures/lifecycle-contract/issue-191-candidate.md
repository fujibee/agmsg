# Public lifecycle capability candidate evidence

- Baseline: `660f67b60e74517299e3703a1f71672915db745e`
- Candidate command: `rtk bats --print-output-on-failure tests/test_lifecycle_contract.bats`
- Candidate result: `27/27` lifecycle contract assertions GREEN, including concurrent
  retry convergence, receipt/ACK layers, wake and processing lease replay,
  active/history projection, additive migration, export/restore, public API,
  atomic work registration plus launch outbox, transaction rollback failpoints,
  public notifier-error visibility, byte-exact export/restore, empty-identity and
  U+0000 rejection, reload-safe unsupported-driver behavior, and explicit
  unsupported-driver behavior.
- Enforced-assertion gate: `36/36` GREEN for
  `tests/test_enforced_assertions.bats tests/test_lifecycle_contract.bats`.
- Focused upstream gate: `185/185` GREEN for storage contract, messaging,
  inbox, API, watch, and lifecycle contract suites.
- Compatibility gate: `79/79` GREEN for the Bash 3.2-sensitive local quoting,
  remote sync, and lifecycle contract suites.
- Upstream harness gate: `277/277` GREEN outside the sandbox (`3` platform
  skips).
- Current candidate full upstream gate: `1744/1744` GREEN for `rtk bats tests/`
  outside the sandbox; the sandbox run was discarded after its localhost-listen
  `EPERM` caused unrelated codex-bridge failures. The accepted run included the
  same codex-bridge tests as GREEN. The emitted
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
- Second-review RED: the four new boundary checks initially produced `23/27`
  (export/import trailing LF, driver reload isolation, empty identities/errors,
  and U+0000 ingestion all RED). After the fixes the same lifecycle suite is
  `27/27` GREEN; local quoting is separately restored to `6/6` GREEN.

The exact candidate head is recorded at the PR evidence gate after the
implementation and contract-documentation commits are fixed.
