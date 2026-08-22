# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.3] - 2026-08-22

### Added
- Emit push.posted when the POST is over, before the acks are written (#918)

### Fixed
- Name the sync engine in the update warning, not just watch.sh (#964)
- Reap a same-(project,role) orphan before spawning (#906 link 2) (#943)
- Preserve exact identity pairs in check-inbox (#721)
- Exit when another writer owns the thread (#906 link 1) (#935)
- Make the failure cap reach and bound the re-arm rate (#906 link 3) (#941)
- Retry a busy apply that races EPIPE, keeping the hung-driver bound (#931)
- A pulled field that is an array must not become shell words (#930)
- Report a busy store as busy, not as a failed check, and wait for it (#920)
- Say which check returned 13 (#911)

### Performance
- Index the two lookups that made import scale with the store (#956)
- Quote SQL literals with a bash expansion, not a fork (#948)
- A release PR is a version bump, not a third full matrix (#945)
- Parse a pull page with one jq, framed by NUL, with no eval (#908, #940) (#942)
- Check a pulled wire id without a process (#939)
- Find the first gap once, not once per candidate (#932)
- One jq per acknowledgement, not six forks (#927)
- Quote each pulled message's fields once, not at 42 fork sites (#908) (#925)
- Index events.legacy_id, looked up by value everywhere (#926)

## [1.2.2] - 2026-08-20

### Fixed
- Keep curl's stderr on the GET path, in the shape the POST side ended up with (#850) (#854)
- Correct a binding an older release left writable, and say what to run if you do not upgrade (#902)
- Keep curl's stderr, and hold the temporaries in one condemned directory (#850) (#903)
- Pass the history and unread-marker SQL on stdin (#777) (#899)
- Pull a team larger than a command line, and say what it is doing (#882) (#895)
- Keep the binding a re-point replaces instead of destroying it (#884)
- Pin count-invisible heavy test files apart, raise the shard timeout with real margin (#885)
- Derive --update's type re-detection from the same list as TPL_TYPE (#846) (#880)
- Take the basename of the whole ps comm path (#770) (#771)
- Map grok-build to grok in the pid walk (#860)
- Fold sentinel '-' into the empty session-id path (#857)

### Documentation
- Say that main takes squash commits only (#845)

## [1.2.1] - 2026-08-18

### Added
- Windows can use the hosted service: connect reaches the server, the fingerprint is real, and doctor names a wedged lock (#868)

### Fixed
- Bound the wait on the local child without spawning anything to do it (#821)
- Record provenance when git answers in another path space (#830) (#842)
- Stop telling every agent that key rotate is unavailable (#841)
- The guard was on the wrong job's step, and it silenced a real one

## [1.2.0] - 2026-08-15

### Fixed
- The probe must not own a name two callers can share
- The probe needs jq's status too, and a cached refusal must still speak
- Require -b where sending needs it, and control the two values
- Ask jq for binary output, and refuse a jq that cannot give it
- Compare a command line and a path in one alphabet
- Control the retake, and correct what the field report actually was
- The cleanup after the wait must not speak for another engine
- Let go of the registry lock before waiting for readiness
- One cleanup path for the staged input, not two
- Stage the input only for the driver that holds the lock
- Hand the driver its input as a file, not down a pipe
- Take the name out of the test, and check the call not its spelling
- Check a pid we minted with the probe that can see it
- Cleanup does not get to speak for the write
- Write into a directory this call created, not a name it tested
- Create and fill the private temp in one redirection
- Create the private temp with builtins, not with mktemp
- Publish the new contents only if all of them were written
- Create the temp narrow instead of narrowing it after the write
- Write the team binding with a mode, not with the umask's leftovers
- An error page is not a protocol mismatch (#814)
- A start that never began is a failed start, not a silent return (#810)

### Documentation
- State the reason, not who gave it
- A pushed head is not a shipped one
- The header said builtins while calling three commands

## [1.2.0-rc.6] - 2026-08-15

### Added
- Do not start a team whose server has refused (#773)
- Start a connected team's engine when an agent turns up
- Keep the engine up when the server refuses, and let the reason be read
- Default to the whole installation, narrow with --project/--type/--team (#654)
- Say when another watcher is receiving for the same roles

### Fixed
- Close fd 3 and 4 on the spawn line, where the repo-wide check reads
- Give both sides of the probe the same remaining seconds
- Let the probe bound itself, and reap it before removing its files
- Reap a timed-out refusal probe instead of leaving it to the machine
- Put the refusal lookup under the same budget as the start
- Close every inherited descriptor in the background start, not just 0/1/2
- Stop asking whether the child is alive, and let go of the caller's streams
- Enforce the negative, keep the remedy runnable, and reap the deliberate children
- Cross each trigger, bound the wait, and make the assertions enforceable
- Delete the dead restore, and make degraded entropy refuse rather than guess
- Keep the holder beside the lock, and tidy it when the lock goes
- Keep the phrase callers already match on
- One token per lock, a holder that survives, and real entropy
- Prove the lock is ours before releasing it, and quote the remedy
- Budget the registry-lock wait in seconds, not in attempts (#779)
- Let a leaked registry lock say who left it, and that it is stuck
- Claim the pidfile before displacing the previous holder (#595)
- The child's stderr reaches the log undecoded
- A diagnostic never continues someone else's half-line
- Every log line names the process that wrote it
- Refuse a line carrying more than one JSON value (#780)
- Carry the detected type to the scripts that WRITE with it (#801)
- Validate the type the caller asked for, and stop dispatch guessing one (#783)
- Carry the reason when the binding path cannot be resolved
- Correct what the previous commit claimed about the identity catch
- Say which condition failed, and which field an exit came from
- Do not report a refusal older than the last successful cycle
- Make main's collapse reachable, and keep the path when it fires
- Deliver with exit 0 when the poll failed part-way (#658) (#745)
- Decide liveness with the EPERM-aware check, not a bare kill -0
- Let the filter file carry its own owner, so a predecessor cannot delete it
- Scope the sharing warning to one project, and describe before appearing
- Print a command per team, not a template with a hole in it
- Say the engine is not running, in both places that can say it

### Performance
- Read a pulled message with one jq, not eighteen (#780)

### Documentation
- Let the reversal record say one thing about why the start fails
- Narrow a claim I disproved myself two commits later
- Delete a comment describing the control this one replaced
- Point key.sh at the current design, and stop asserting the move has happened
- Move the connect onboarding design to agmsg-cloud, and drop labels that point at nothing
- Make the promise about this document weak enough to be true
- Label what stands behind each claim, instead of asserting they all cite
- Add a Japanese translation, and consolidate the derivation it mirrors
- Make the printed command cover the sentence it supports
- Widen the evidence to the tree, then widen the claim back to match it
- Say which path was measured, instead of calling it "the supported path"
- Trace the second route to age-v1 instead of leaving it open
- Name which half of the policy check protects you, and close the open question
- Audit the profile this document cites, and correct two claims it got wrong
- State what remote sync protects, and what it does not
- Say "documented, and measured otherwise" in all three places, not one
- Carry main's correction — the discard is documented, not measured
- Narrow the deletion rationale -- the subject was removed, not moved
- Remove two superseded designs, and stop citing one as normative
- Derive where the old ownership claim appears, instead of fixing the reported line
- The two files are removed by their owners, and those are not the same owner
- Make the comments say what the code now does

### Reverted
- Drop the refusal lookup; the loop it prevented no longer exists

## [1.2.0-rc.5] - 2026-08-12

### Added
- Status can say whether anything has actually synced

### Fixed
- Restore all three traps the acquire takes, not just EXIT
- Chain the caller's EXIT trap around the lock, and drop two tests that could not fail
- Prove lock ownership in-process, and release only the lock taken
- The team lock covers the engine spawn
- Judge the cycle record before signalling, and keep its cleanup out of stop's verdict
- A cycle record that cannot be cleared stops the start
- Clear the cycle record where a new engine begins, and narrow what its absence claims

## [1.2.0-rc.4] - 2026-08-11

### Added
- Set-endpoint moves a connected team's address, identity-checked

### Fixed
- The manual path, and a guard that never ran on an rc
- Cut a release from the branch you are on
- Do not name a cause this path did not establish (#731)
- Say a live engine was left behind, not that a pidfile was kept (#731)
- Say when a machine cannot name its own team
- A failing cycle names the cause it already had
- One CA setting for both clients, and a cycle error that names the cause
- Treat NODE_EXTRA_CA_CERTS presence, not truthiness, as "explicitly set"
- Bridge CURL_CA_BUNDLE into NODE_EXTRA_CA_CERTS
- Bring set-endpoint's engine restart under the same rule (#730)
- Say "start requested", and test the callers that say it (#730)
- The failure note names a stream, not a position (#730)
- A sync engine that cannot start says so (#730)
- Self must count as a candidate before its own marker exists (review)
- Let a provably-sole install migrate its own legacy shim (review)
- Fail closed on legacy/unowned shims; scope --update forcing (review)
- Stop evaling shim-derived content; state the consequence of forcing (review)
- Refuse to clobber a Codex shim owned by a different install (#553)
- Snapshot the binding for update atomically, under one lock
- Give legacy bindings a revision before the CAS snapshots it
- Gate the stored-config write on the binding it verified
- Make set-endpoint's remedy reachable and its write CAS-guarded
- One shape predicate for both status forms, not two (review)
- Distinguish an unreadable team config from never-connected (#650)
- Stop asserting bare off was deliberate (review)
- Treat an unreadable/malformed settings file as unrecognized too (review)
- Distinguish an unrecognized project from a deliberate off (#687)
- Key the install stamp per process, not per session (#684)
- Stop a watcher that is running code its installation no longer has (#684)
- Collapse out-of-shape server error codes in send()'s message
- Derive contracts_needed for tests/test_remote*.bats instead of naming exceptions (review)
- Stop tests/test_remote_setup_doc.bats from forcing the age-v1/jsonl contracts (#706)
- Stop a malformed JSON body from also reaching the terminal raw (review)
- Sanitize the untrusted error code and pin the real transport error (review)
- Stop discarding resolve-team's stderr and its actual cause (#726)
- Use one endpoint validator

### Changed
- Split candidate listing out of agmsg_only_one_install (review)

### Documentation
- A red run does not mean nothing shipped
- Remove a publish path that cannot exist
- Document pull-bootstrap coverage and the restart gap
- Describe the five callers that exist, not the four that did (#730)

## [1.2.0-rc.3] - 2026-08-10

### Fixed
- Carry every events column through the per-team move (#710)
- Validate the host on the https path too (#717)
- Validate the port, and make the agreement check mean what it says (#717)
- The refusal names the zone, and the list names what is allowed (#717)
- Refuse an IPv6 zone index on both sides (#717)
- An octet with a leading zero is not an address as written (#717)
- Same input, same answer, and bind the call site (#717)
- Allow plaintext http to a private IP, not just loopback (#717)
- Narrow /v1/health's catch to actual DB unreachability (#705)
- Stop the bound failing open, and give the cap a contract
- The cap is bytes, so count the record in bytes
- The log's ceiling was claimed, not delivered
- Let the watcher say what it is doing, and stop the fallback standing down
- Fix(ci): stop age-v1/jsonl contracts from running on a

### Documentation
- Scope the Compose check to the Compose path (review)
- Make "Docker with Compose" a checkable requirement (#704)
- The comment still carried the mechanism I had already retracted
- Narrow the overview to what the walk establishes (#702)
- Leave the main path to the main path (#702)
- Make the bundle a step, and say the local address is the endpoint
- The join step named an install the walkthrough never made

## [1.2.0-rc.2] - 2026-08-08

### Fixed
- Prove the count, assert all three states, require exactly one (#689)
- Ask whether the column is there before naming it (#689)
- The reader set was derived too narrowly (#689)
- Write every message to the legacy table again (#689)
- Refuse to migrate a team whose source read cursor is not an integer
- Advance the per-team store's event sequence floor past any copied cursor (#695)
- "has ever connected" is not "is connected"
- The first way out reproduced the command that had just failed
- Name the way out, on the two screens that only named the problem
- Compare held pairs as strings, not as patterns (#683)
- Step aside while a pair is held, and say when it comes back (#683)
- Release a pair another session has claimed (#683)
- Stop classifying "required, no local key" as either encrypted or not
- Scope the status-output description to a connected team, name the third value

### Documentation
- Repair a sentence the attribution removal cut in half
- Explain what e2ee actually changes, so readable history isn't read as plaintext (#682)

## [1.2.0-rc.1] - 2026-08-08

### Added
- Show who holds which lock, watcher, and bridge for a project (#640)
- Name the lock and its cc-instance when an exclusion empties the set (#618)

### Fixed
- A printed command carries the path it has to be run from
- Say what the check established, not what it suspects (#669)
- Refuse to project from a file sqlite could not read (#669)
- One path converter, and a readfile failure that says so (#669)
- Derive npm's dist-tag from the version, so an rc is not `latest`
- Narrow the ps fakes to the one question they stand in for
- Drop a watermark wait this branch can never satisfy
- Stop losing earlier teams' messages when a later team's query fails (#653)
- Probe watcher pidfiles with the local pid probe (#613)
- Drop a hardcoded pid and wait for a killed child in the bats suite (#606)
- Don't let a failed mkdir -p abort the seat write (#602)

### Documentation
- Make joining from machine B a step, and translate (#672)
- Retract the premise of the previous commit message (#669)
- The port IS copied from compose, so pin it instead
- Put the short way to start a server in the walkthrough

## [1.1.13] - 2026-08-01

### Fixed
- Resolve the app-server from the port file when the variable is absent (#591)
- Route every shell-minted pid through the local probe (#567) (#584)
- Seat a role from the app-server's loaded threads, not rollout files (#583)
- Probe the app-server with the local-pid helper, not the tasklist one (#567) (#582)

## [1.1.12] - 2026-07-31

### Added
- Monitor delivery via opencode-sentinel plugin
- Size a push batch in bytes and split it on 413 (re-land #609)
- Size a push batch in bytes and split it when the server says 413
- Answer /v1/health with the team the caller asked about
- Add an authenticated-bundle ingress for disaster restore
- Add `agmsg export` — dump a team's message history as JSONL (#597)
- One file to hand over — handoff bundles the chain and its identities (#573)
- Pull a team by name
- Look a team up by name
- Start a background sync engine on connect, stop it on disconnect
- Stop taking a roster from the server (#530)
- Add pull, the command a second machine runs
- Let the engine pull a team it has never seen
- Answer a pull with one consistent team snapshot
- Let a second machine read a team it does not have
- Upload the history a legacy store already has
- Make the store layout a per-team driver choice
- Register a client-owned team with POST /v1/connect
- Migrate existing history into the per-team stores
- Give each team its own message store
- Thread a team selector through store resolution

### Fixed
- Quote the project path into the generated monitor commands
- Harden monitor rule + docs per Copilot review
- Add cmd_prefix=$ so spawned actas uses $agmsg, not /agmsg
- Keep opencode worker resident via TUI --prompt instead of run --interactive
- Bound watch-once by its lifetime, not by its polling (#558) (#560)
- Parse the app-server port through ANSI color sequences (#512)
- Compare status metadata project as canonical normalized paths (#511)
- Validate project_path in set instead of mkdir-ing whatever it is given (#508)
- A process you cannot signal is not a process that is gone (#505)
- Balance the case pattern paren for bash 3.2
- Deliver before reporting, and take the boundary out of `||`
- Never mark a message read that the run then throws away
- Decide from the declaration, and ask the driver about history
- Run the engine when this machine can read, not when the team is plain
- The locked team keeps its state, the caller keeps the route
- Say why mkdir failed instead of calling everything a timeout
- The caller can own the "what to do next" lines (#639)
- Print an unlock command the operator can actually run
- Keep the capability out of the terminal (#635)
- Shell-quote the recovery command, and run it in the test
- Make the refusals' recovery instructions actually work
- Check the server's identity and declaration before adopting
- A connect that already registered resumes instead of dead-ending
- Enforce the team's declared cipher on write, fail-closed
- Settle only from a batch that agrees, and name a remedy that works
- Settle an undeclared team from a message it stores, never from connect
- Let a repeat connect fill a declaration the team never had
- Carry the team's declared cipher instead of inferring it from arrivals
- Keep the per-line fd guard the repo already requires
- Close the fds around the sourced plug's spawn too
- The monitor leaks the same way, and it starts a daemon
- Close inherited descriptors by range, not by name
- Connect no longer calls the server's team name an org
- Keep the acks a failed split already earned (#623)
- Check the script on disk, not the directory it would sit in
- Pin every mapped script, and answer before anything is installed
- An unknown verb names the command to run instead
- A cursor that is not a number is not proof of containment
- Hand the roster driver its file, so a second machine can find it (#610)
- Route the oversized event's detail through errorCode too
- Read the error code from either shape a server sends
- Name the local row when a single message is too large
- A cursor that moved on is not a cursor that went missing (#607)
- Prove the destination has the rows before deleting them (#604)
- Answer health from the team row, not from the request header
- A partial binding claim is refused, a plain 401 is not
- Stop reporting every server error as a binding mismatch
- The captured bundle is 0600, not whatever the umask was
- Keep the current epoch until the rotation is confirmed (#585)
- Validate a name lookup answer and bound its size
- Order the registered_at backfill after messages exists
- A pulled team starts the sync engine
- Close fd 3 and 4 when spawning the sync engine
- Page and compare team_seq numerically, not as text
- List members that have no local registration (#540)
- Resolve the migration's team config from the connection dir
- Report age as optional, because it is
- Run main when invoked through a symlinked path
- Make the api.sh fallback actually deliver live messages (#525)
- The sync harness teams are on the shared layout
- Stop calling the migration that installing must not run
- Move a store only when the team owns one
- Ask agmsg where the store is instead of guessing
- Read the event log, and stop dropping non-numeric ids
- Read the team's store, not the store root
- Pass the team to storage_init in the sync-client harness
- Repair the readers the per-team split broke
- Restore the FIFO path the merge dropped
- Pass the team through the last selector-less callers
- Move the team's store with the team
- Escape tombstone updates directly
- Keep platform checks portable
- Stream large SQLite messages on stdin

### Changed
- Name the flag what it holds
- Rename the layout axis to partition (#580)

### Documentation
- Add agmsg-bubblelog and agmsg-tui to the showcase and README (#571)
- Describe the monitor fallback as instructed, not enforced
- Document monitor mode via opencode-sentinel plugin
- Mark spawn as supported via --prompt
- Document safe Git Bash quoting from PowerShell
- Document the permission allowlist agmsg needs on Claude Code (#551)
- State the reason instead of naming the author
- Put the SKILL.md paragraph after step 5, as in the templates
- Machine B needs its own install, not just its own env vars
- Five files read the connection dir, not four
- A second machine is a separate install, not three env vars
- Say that nothing checks the cursor storage class
- Mark the string error shape as a bridge, not a second contract
- The health comment still described the 404 that was replaced
- State what protects the capture and what does not
- The disaster route does put plaintext on disk — say so
- User-facing remote setup guide; dogfood doc to ref (#554)
- Handoff map for the test_remote.bats rewrite (not for merge)
- Two machines rotating at once
- Say which key seals the rotation record
- How a key gets replaced
- Say that run/ is left alone on purpose
- Take 0003 back out of reference
- Separate minting ids from rewriting history
- File superseded work as reference, and start the remote-sync design
- Put everything unpublished under draft/
- Mark the authorization seam as unadopted (#510)
- Hand a host one authentication result to authorize against (#509)
- Specify device pairing end to end (#506)

## [1.1.11] - 2026-07-27

### Added
- Offer monitor as the default delivery mode, drop the beta framing (#497)
- Support spawning into herdr panes (#495)
- Drag files onto a pane to insert their path (#481)
- Adaptive catch-up so a backlog doesn't crawl at 100/5s
- Add team-list.sh (agmsg team list --json, koit-approved)
- Add status --json and pending list/abort (ADR 0007 addendum)
- Consume connected team credentials
- Add scripts/remote.sh (connect/status/disconnect/doctor) per ADR 0007
- Add scripts/key.sh (generate/show/import/rotate) per ADR 0007
- Add JSONL Stage-1 synchronization
- Configure reference server retention
- Add explicit retention gap recovery
- Synchronize composite read state
- Add Stage 2 read-state server API
- Unify local read cursors across delivery paths
- Driver-level store-existence check, not a messages.db file gate (#207)
- Jsonl storage driver (jq default + duckdb opt-in) (#207)
- Flip send + mark + watch to the event log (#206 step 3)
- Route inbox/check-inbox/history reads through the facade (#206 phase 1)
- Formalize event-log schema v1 + compaction contract (#205)
- Driver facade + sqlite driver + contract test suite (#204)
- Render terminals via WebGL, attached only to the active pane (#446)

### Fixed
- Stop the bridge launcher duplicating children and burning a core (#496)
- Make the turn watchdog an idle timeout, not a fixed ceiling (#443)
- Mark read_at on live delivery so a later inbox.sh does not replay it (#439)
- Memoize the sqlite3 -escape probe instead of re-running it (#494)
- Treat kill -0 EPERM as alive under the command sandbox (#447)
- Fail loudly on shifted args instead of running with zero subscriptions (#477)
- Add -g to macOS Terminal/iTerm launch so it doesn't steal focus (#470)
- Make record-session project arg optional, reject poison records (#473)
- Avoid two-line grep -c count breaking record-session integer test (#484)
- Bound the self-clean race in the watcher re-invocation test (#440)
- Shell-quote delivery hook command paths (F14) (#487)
- Close #87-class SQLi/path-hazard gaps in rename/leave/reset/rename-team/team/api (#482)
- Resolve symlinks before trampoline compare; doctor checks node
- Detect the macOS CLT python3 trampoline, not just PATH presence
- Close the python3 dependency-tiering gap on the remote path
- Close the integer-overflow bypass in AGMSG_TEAM_LIST_MAX_TEAMS validation (co1 delta review round 2)
- Validate AGMSG_TEAM_LIST_MAX_TEAMS as a positive integer (co1 delta review)
- Fail closed on incompleteness; shrink v1 schema
- Wire 'agmsg team list' into actual dispatch entry points (co1 P1)
- Stop binding config JSON via .param set (#87-class tokenizer bug)
- Hide imported identity at TTY
- Separate token input from E2EE prompts
- Preserve unverified exchange recovery state
- Bound onboarding HTTP responses
- Validate connected authentication authorities
- Distinguish persisted cipher configuration
- Align onboarding with protocol binding
- Validate env-var name before shell use; drop advanced path for key import
- Sharpen encryption-bootstrap wording for first-time setup (B3)
- Never let the agent construct or run token/identity commands
- Wire remote/key slash-command dispatch into all per-type templates
- Add EXIT/INT/TERM cleanup traps to remaining secret-bearing temp files (nonblocking follow-up)
- Address E1-E3 delta review findings (local-disconnect CAS, strict 200-only revoke, JSON-serializer credential write)
- Address D1-D5 delta review findings (force-CAS bypass, orphaned-revoke recovery, credential-file atomicity, duplicate-key/unknown-field rejection, docs)
- Address delta review findings R1-R5 (pending-file argv leak, URL-parse HTTPS bypasses, post-commit idempotency, force+omitted-team gap, UUIDv7 validation)
- Address adversarial review findings B1/B3/B5/B6 (secret-argv leaks, unsafe auto-generate default, force-revoke ordering, resumable pending commit, strict response validation)
- Address adversarial review findings B2/B4/B7
- Reject active age stanza namespaces
- Confine age GREASE handling
- Accept bounded age GREASE stanzas
- Bound reprocess pagination
- Make JSONL sync transitions atomic
- Harden JSONL synchronization state
- Honor resolved Node runtime for resync
- Enforce strict resync input framing
- Bind read state to authoritative identities
- Make Stage 2 recovery converge
- Close Stage 2 synchronization edge cases
- Preserve read state across renames
- Enforce safe read cursor coverage
- Read messages from the event log too, not just the legacy table
- Assert against the event log, not the legacy messages table
- Escape interpolated names in rename/rename-team SQL (#223, #87)
- Jsonl compact keys reads by tuple, not a space-join (co1 #221)
- Make the jsonl driver parse under macOS bash 3.2 (#207, #221 CI)
- Jsonl mark aborts on a failed existing-reads scan (co1 #207 residual)
- Jsonl driver must not swallow failures as ok (co1 #207 review)
- Watch-once stale-wake token = unread-set digest, not a max id (#207)
- Document --limit semantics + make storage_history agent truly optional (co1 #206 review)
- Export skips unknown event types; pin high-water with a tail-duplicate test (co1 #205 review)
- Describe is a metadata op; surface backend errors; chronological reads (co1 re-review, #204)
- Legacy read, pipefail framing, §1.4 control ops (co1 review, #204)

### Performance
- Seal a bulk push page in parallel (#502)

### Changed
- Extract the v1 data plane as a registerable Fastify plugin

### Documentation
- State how to pronounce agmsg (#498)
- Preserve identity migration and denial gates
- Consolidate pre-merge remote decisions
- Pin clean-device connect entrypoint
- Enforce manifest-first backfill writes
- Prove promoted read-state mapping
- Bound onboarding promotion recovery
- Unify local-first onboarding activation
- Define local-first onboarding
- Correct the dependency model to 5 tiers, not 3
- Add ADR 0007 (remote connect onboarding UX)
- Document remote.sh/key.sh commands and slash-command mapping
- Pin resync JSONL framing
- Close resync retry and status gaps
- Define retention gap resynchronization
- Clarify local read-state identity
- Close Stage 2 frontier edge cases
- Define Stage 2 read-state synchronization
- Note rename.sh/rename-team.sh/api.sh as sqlite-coupled known gaps
- Correct the ctrl:despawn cursor-advance comment (co1 step-3 review)
- Clarify stdout framing, cursor token, watch tip (co1 review, #203)
- Storage contract §2 — messages-only, opaque cursor, recipient-scoped read (#203)
- Draft ADR 0003 — storage axis driver ABI, contract, scope (proposed)

## [1.1.10] - 2026-07-19

### Fixed
- Allow launcher-reserved bridge PID (#444)

## [1.1.9] - 2026-07-19

### Added
- Isolate Codex monitor bridges by role (#425)
- Free shell tab, unattached to any agent (#431)
- Add session-only dismiss to outdated-CLI banner (#430)
- Extend join/actas prompts with roster-aware name suggestions (#421)
- Remember the last active tab per team (#417)

### Fixed
- Tombstone renamed-away names so join/actas can't silently revive them (#427)
- Don't let co-located app-v* tags pollute the recorded core VERSION (#432)
- Resolve shim through symlinks, warn when monitor mode isn't actually reached (#429)
- Skip Monitor directive for .claude/worktrees sub-sessions (#428)
- Grace fallback for thread/resume failure on Codex 0.142+ (rebase of #276) (#426)
- Stop Claude Code 2.1.x daemon from hijacking pid resolution (#424)
- Mark only the displayed messages as read (#361)
- Replace flaky ls -t rollout lookup with find + portable mtime sort (#423)
- Bound the stdin read so a never-closed pipe cannot freeze the agent pane (#422)
- Convert team config paths for readfile() via agmsg_sql_readfile_path (#396)
- Fix Codex monitor multi-identity delivery (#419)
- Auto-decline approval requests, arm the turn watchdog on externally-active turns (#420)
- Add Shell requirement to all type templates (#345)
- Validate team name before resolving roster config path (#418)
- Give team-status-rail its own gray for zero-pane teams (#413)

### Documentation
- Clarify sandbox and storage guidance (#362)
- Fix leftover OpenCode references in cursor template (#398)

## [1.1.8] - 2026-07-15

### Added
- Sidebar per-section + buttons, replacing the New dropdown (#407)
- Green status-unknown default, roomier team-status-rail rows (#406)
- Phase-lock agent-status and monitor pulse dots to wall clock (#403)
- Detect grok/grok-build agent status (#395)
- Persist UI settings across restarts (#391)
- Snap pane dividers to terminal cell units, herdr-style gaps (#390)
- Show agent and team status (#385)

### Fixed
- Filter non-numeric characters out of the font-size draft (#405)
- Reject unregistered from/to agents (#409)
- Resolve Codex leftovers and delivery_modes mismatch (#408)
- Forward args on a flags-only monitored launch (#404)
- Clean up the Settings font-size input (#401)
- Display chat timestamps in local time, not raw UTC (#394)
- Normalise Windows backslash paths before handing to bash/curl (#392)

### Performance
- Batch pty-output writes to one term.write() per animation frame (#402)

## [app-v0.1.5] - 2026-07-13

### Added
- 0.1.5 UI polish — sidebar collapse, chat pane min/max, Team Room toggle, About version, lucide icons (#377)

### Fixed
- Authenticode-sign Windows binaries during tauri build (#354)

## [1.1.7] - 2026-07-13

### Added
- Role-to-session affinity: named sessions, resume-by-role boot, tmux-resurrect (#339) (#344)

### Fixed
- Wrap boot script with bash -l for psmux on Windows (#335) (#363)
- Guard '/'-prefixed boot prompt against MSYS path conversion on Git Bash (#358)
- Stop ancestor project resolution from over-reaching to $HOME / other teams (#357) (#359)
- Bind the bridge to the role's recorded thread, not "loaded" (#350) (#353)
- Detect the real GEMINI_CLI env var, not GOOGLE_GEMINI_CLI (#351)

## [1.1.6] - 2026-07-05

### Added
- Aligned-grid seam-segment dragging + lazy transpose (issue #317, part 3) (#327)
- Wire pane split tree into rendering + drag-drop (issue #317, part 2) (#324)
- Pane split tree — pure data model + tests (issue #317, part 1) (#321)
- Expose pane layout in the View menu (#316)

### Fixed
- Correct boot script for Windows-tmux launch and per-type prefix (#282, #283) (#329)
- Strip inherited same-type session-identity env vars (#294) (#326)
- Match project registrations across Windows path forms (#268) (#328)
- Launch agents via cmd.exe on Windows so PATHEXT/aliases resolve (#314, #313) (#325)
- Resolve MSYS project paths to native on Windows spawn (#315) (#319)
- Normalize Windows drive-letter project path to POSIX before identity resolution (#275)

## [app-v0.1.3] - 2026-07-04

### Fixed
- Explicit PATH propagation to spawned processes, dscl shell fallback, diagnostic log (#312)
- V0.1.3 — import login shell PATH so agent spawn works from Finder (#311)

## [app-v0.1.2] - 2026-07-04

### Fixed
- Suppress bash's console window and profile-loading delay (#310)
- Fall back to USERPROFILE when HOME is unset (#309)
- Resolve Git Bash explicitly + bump version to 0.1.2 (#308)
- V0.1.2 — Windows bash path bug, banner overlap, update feedback (#306)

## [app-v0.1.1] - 2026-07-04

### Added
- Add update-cask.sh — automate the Homebrew tap bump (#304)

### Fixed
- V0.1.1 — agmsg-app pin fix, updater artifacts, outdated-CLI warning (#303)

### Documentation
- Add brew trust step to macOS install instructions (#301)

## [app-v0.1.0] - 2026-07-03

### Added
- Official agmsg desktop app (#298)

## [1.1.4] - 2026-07-03

### Added
- Add scripts/api.sh — read-only JSON entry point for non-bash consumers (#289)
- Enable spawn for antigravity, copilot, cursor, gemini, opencode (#278)
- Per-type spawn options via a configurable YAML file (#274)

### Fixed
- Fall back to a tarball download when git is unavailable (#296)
- Gate actas/drop's fresh Monitor on delivery mode (#280) (#281)
- Escape team/agent SQL values in history/inbox/check-inbox (#87) (#272)

### Documentation
- Add Japanese translations for Tier 1 contributor-facing docs (#291)
- AGMSG_HOME data-root override, env-var naming convention (#284)

## [1.1.3] - 2026-06-30

### Added
- Use brand logo mark + favicon set (#257)
- Redesign agmsg.cc landing with Astro + Tailwind (#213) (#249)
- Allow passing an initial prompt to the spawned agent (#212)

### Fixed
- Run watch-once.sh via bash so the codex bridge arms on Windows
- Prefer shell function monitor shim; skip agmsg wrapper when resolving real codex (#193)
- Drop monitor/both — Gemini has no Monitor tool (#258)
- Skip Monitor directive when watcher already alive (#246)
- Escape interpolated values as SQL string literals (#223)
- Add CIM fallback for /proc-less cmdline/comm (#225) (#234)
- Robust monitor — session-bind, orphan reaper, foolproof launch (#245)
- Report bridge liveness in delivery status (#232)
- Reject agent names that break JSON paths
- Pipe SQL via stdin to avoid ARG_MAX on large bodies

### Documentation
- Add agmsg logo asset kit (#255)

## [1.1.2] - 2026-06-27

### Added
- Add opt-in explicit-launch monitor delivery (#236)
- Add MSYS2 compat shim (#88) (#211)

### Fixed
- Start the watcher when GROK_SESSION_ID is empty (#236 follow-up) (#238)
- Keep Codex working across 0.142 upgrades (fail-open + stale app-server reuse) (#237)
- Serialize team config writes behind a per-team lock (#141) (#227)
- Open the message DB via a Windows-acceptable path (#197) (#226)
- Handle whoami suggest= identity and anchor agent= match (#224)
- Bound bridge app-server stalls (#209)

## [1.1.1] - 2026-06-25

### Added
- Add --model to launch a spawned agent on a chosen model (#220)
- Add grok-build agent type (xAI Grok Build CLI) (#216)

### Fixed
- Scope watcher teardown to (project, type), not project (#219)
- Exit on originating-session death so a quiet watcher can't hang (#67, #388) (#215)
- Quote Monitor command args so space-in-path survives (#188) (#200)
- Use tasklist for native pid liveness in agmsg_instance_alive (#134)

## [1.1.0] - 2026-06-22

### Added
- Add Cursor agent type (#189)
- Add Hermes Agent as a beta agent type
- Axis-generic driver discovery + external-plugin opt-in
- Drop the aliases= auto-redirect; explicit type selection only
- Pluggable agent-type registry

### Fixed
- Warn to re-register delivery hooks on --update (#190)
- Re-point an existing Codex monitor shim on --update
- Follow init-db move to internal/ in the Windows PowerShell smoke
- Readfile() config binding for single-quote-safe registry (#185)
- Strip CR from sqlite3 output so Windows Git Bash works (#180)
- Git Bash compatibility for the Codex bridge (#179)
- Cut-release.sh stops at the PR (no auto-merge / auto-publish) (#177)

### Changed
- Drop the Windows PowerShell launcher in favor of Git Bash
- Relocate types/ under scripts/drivers/types/
- Consolidate mode support into delivery_modes manifest
- Data-drive Windows hook wrapping via manifest
- Status as a Template Method plug
- Fold the codex runtime into types/codex/
- Move enable/disable side effects into type plugs
- Wire SKILL templates to type-dir manifests
- Extract codex bridge handoff into a type plug
- Drive Stop-hook status output from manifest stop_output=
- Per-type delivery as a Template Method plug
- Extract hook JSON primitives into lib/hooks-json.sh
- Move init-db to internal/, dispatch to windows/, drop hook.sh
- Move the codex subsystem into scripts/codex/

### Documentation
- Add supported-agents logo strip
- List hermes in the --agent-type help (co1 nit)
- Add docs/plugins.md + README section + plugins/ drop-in dir
- Refresh manifest table + paths for the 1.1.0 layout
- Lead Quick Start with npx, the zero-clone install path

## [1.0.6] - 2026-06-21

### Added
- Codex monitor bridge (beta) — app-server bridge + re-arm + fresh-session launch (#41) (#148)
- Add OpenCode as a supported agent type (#136)

### Fixed
- Pin install to the bootstrapper's version, not main (#173)
- Engage the monitor bridge on codex 0.141 (ws transport + loaded-thread discovery) (#174)
- Escape hook command values via json_object (#175)
- Stop orphaned watch.sh from advancing the shared watermark past undelivered messages (#145)
- Resolve Codex thread by physical path so symlinked project paths match (#160) (#164)
- Validate writefile() byte count, not just sqlite3 exit code (#166)
- Pass sqlite3 -escape off so the char(31) separator stays raw (#165)
- Write hook files with writefile() to avoid sqlite3 caret-escaping (#158)
- Validate team names to prevent teams/ path traversal (#147)

### Documentation
- Worker guardrails + empty-poll OOM case study (#163) (#167)
- Add llms.txt for AI-agent orientation (#155)

## [1.0.5] - 2026-06-17

### Added
- Add thin Windows PowerShell launcher (#128)
- Tear down spawned crew members (#109) (#129)

### Fixed
- Isolate parallel --continue/--resume sessions sharing a session_id (#132)

## [1.0.4] - 2026-06-15

### Added
- Record git-describe provenance version (/agmsg version) (#122)
- Add native Windows agmsg helpers (#103)
- Readiness handshake by default (status=ready / --no-wait / --ready-timeout) (#113)
- Launch a new agent into tmux/terminal and auto-actas (#105)

### Fixed
- Busy_timeout on all DB connections — concurrent writes no longer drop (SQLITE_BUSY) (#115)
- Make the `monitor` mode and `delivery.sh set` work under Claude Code's sandboxed Bash tool (#106)
- Persist per-session watermark so restarts don't drop messages (#107) (#111)
- Resolve session's real project from subdir/worktree (#92) (#110)

### Documentation
- Show all four install paths (#90)

## [1.0.3] - 2026-06-11

### Fixed
- Download setup.sh to a tempfile instead of piping curl into bash (#98) (#100)
- Refuse interactive prompt when stdin is not a tty (#98) (#99)
- Avoid E2BIG on large settings.local.json (#95) (#97)

### Documentation
- README + agmsg.cc rework for PH-launch traffic conversion (#94)

## [1.0.2] - 2026-06-08

### Added
- Add CLI type auto-detection (#69)
- Add .claude-plugin/ manifests for Claude Code plugin marketplace (#81)
- Add GitHub Copilot CLI support (turn mode) (#74)
- Actas exclusivity lock — fix same-team multi-identity message leakage (#62) (#65)
- Override message store path via AGMSG_STORAGE_PATH (#59)
- Add support for gemini and antigravity (agy) agents (#45)

### Fixed
- Unblock npm Trusted Publisher OIDC + bin path
- Support native Windows (Git Bash + Codex hooks) (#73)
- Scope set turn/off watcher kill to the target project (#86)
- SKILL.md self-bootstrap and substitute name placeholder (#83) (#85)

### Documentation
- Add PRIVACY.md (required by Anthropic community marketplace submission) (#82)
- Handle empty TaskList explicitly to stop fresh-session loop (#71)
- Storage driver pluginization design (epic #51) (#52)

[1.2.3]: https://github.com/fujibee/agmsg/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/fujibee/agmsg/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/fujibee/agmsg/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/fujibee/agmsg/compare/v1.2.0-rc.6...v1.2.0
[1.2.0-rc.6]: https://github.com/fujibee/agmsg/compare/v1.2.0-rc.5...v1.2.0-rc.6
[1.2.0-rc.5]: https://github.com/fujibee/agmsg/compare/v1.2.0-rc.4...v1.2.0-rc.5
[1.2.0-rc.4]: https://github.com/fujibee/agmsg/compare/v1.2.0-rc.3...v1.2.0-rc.4
[1.2.0-rc.3]: https://github.com/fujibee/agmsg/compare/v1.2.0-rc.2...v1.2.0-rc.3
[1.2.0-rc.2]: https://github.com/fujibee/agmsg/compare/v1.2.0-rc.1...v1.2.0-rc.2
[1.2.0-rc.1]: https://github.com/fujibee/agmsg/compare/v1.1.13...v1.2.0-rc.1
[1.1.13]: https://github.com/fujibee/agmsg/compare/app-v0.4.0...v1.1.13
[1.1.12]: https://github.com/fujibee/agmsg/compare/v1.1.11...v1.1.12
[1.1.11]: https://github.com/fujibee/agmsg/compare/v1.1.10...v1.1.11
[1.1.10]: https://github.com/fujibee/agmsg/compare/app-v0.3.0...v1.1.10
[1.1.9]: https://github.com/fujibee/agmsg/compare/app-v0.2.0...v1.1.9
[1.1.8]: https://github.com/fujibee/agmsg/compare/app-v0.1.5...v1.1.8
[app-v0.1.5]: https://github.com/fujibee/agmsg/compare/v1.1.7...app-v0.1.5
[1.1.7]: https://github.com/fujibee/agmsg/compare/app-v0.1.4...v1.1.7
[1.1.6]: https://github.com/fujibee/agmsg/compare/app-v0.1.3...v1.1.6
[app-v0.1.3]: https://github.com/fujibee/agmsg/compare/app-v0.1.2...app-v0.1.3
[app-v0.1.2]: https://github.com/fujibee/agmsg/compare/app-v0.1.1...app-v0.1.2
[app-v0.1.1]: https://github.com/fujibee/agmsg/compare/v1.1.5...app-v0.1.1
[app-v0.1.0]: https://github.com/fujibee/agmsg/compare/v1.1.4...app-v0.1.0
[1.1.4]: https://github.com/fujibee/agmsg/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/fujibee/agmsg/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/fujibee/agmsg/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/fujibee/agmsg/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/fujibee/agmsg/compare/v1.0.6...v1.1.0
[1.0.6]: https://github.com/fujibee/agmsg/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/fujibee/agmsg/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/fujibee/agmsg/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/fujibee/agmsg/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/fujibee/agmsg/releases/tag/v1.0.2

