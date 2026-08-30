# Public lifecycle capability candidate evidence

- Baseline: `660f67b60e74517299e3703a1f71672915db745e`
- Candidate command: `rtk bats --print-output-on-failure tests/test_lifecycle_contract.bats`
- Candidate result: `34/34` lifecycle contract assertions GREEN, including concurrent
  retry convergence, receipt/ACK layers, wake and processing lease replay,
  active/history projection, additive migration, export/restore, public API,
  atomic work registration plus launch outbox, transaction rollback failpoints,
  public notifier-error visibility, byte-exact export/restore, empty-identity and
  U+0000 rejection, reload-safe unsupported-driver behavior, and explicit
  unsupported-driver behavior, expiry fencing, control-token canonicalization,
  transaction-wide import rollback, sender-scoped outbox identity, malformed
  JSONL rejection, expired-lease projection, and Unicode C1 rejection.
- Enforced-assertion gate: `43/43` GREEN for
  `tests/test_enforced_assertions.bats tests/test_lifecycle_contract.bats`.
- Focused upstream gate: `192/192` GREEN for storage contract, messaging,
  inbox, API, watch, and lifecycle contract suites.
- Compatibility gate: `86/86` GREEN for the Bash 3.2-sensitive local quoting,
  remote sync, and lifecycle contract suites.
- Upstream harness gate: `281/281` GREEN outside the sandbox (`3` platform
  skips).
- Previous candidate full upstream gate: `1744/1744` GREEN for `rtk bats tests/`
  outside the sandbox; the sandbox run was discarded after its localhost-listen
  `EPERM` caused unrelated codex-bridge failures. The accepted run included the
  same codex-bridge tests as GREEN. The emitted
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
- Third-review RED: expired processing/outbox owners, faulted import rollback,
  and control-bearing tokens initially ran `0/3`. After the fixes the same
  selection ran `3/3` GREEN. Safeguard mutation then disabled expiry CAS,
  control-token filtering, and SQLite `-bail`; the selection returned `0/3`
  before immediate restoration and the lifecycle suite returned `30/30`.
- Fourth-review RED: sender-shared operation keys, malformed/incomplete JSONL,
  expired-lease active projection, and Unicode C1 tokens initially ran `0/4`.
  After the fixes the same selection ran `4/4` GREEN. Safeguard mutation then
  removed message-scoped outbox identity, import record validation, the active
  lease-expiry predicate, and C1 filtering; the selection returned `0/4`
  before immediate restoration and the lifecycle suite returned `34/34`.
- Exact baseline migration: `issue-277-rev1.sql` reproduces revision 1's event,
  legacy-message, read-cursor, and metadata shape with linked read state; the
  candidate migrates it additively to revision 2 and preserves every asserted
  id, body, cursor, metadata value, and legacy read timestamp.

The exact candidate head is recorded at the PR evidence gate after the
implementation and contract-documentation commits are fixed.
