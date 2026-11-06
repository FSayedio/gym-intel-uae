# CSV import recovery (opt-in; not enabled by this change)

Before: an app interruption could leave a CSV job executing indefinitely and
block the existing backup/update guards. Recovery required stopping the app and
verifying the old worker and database sessions were gone.

After opting in: the worker locks its individual job row while importing. A
periodic process considers only marked CSV jobs, skips rows locked by a live
transaction, and makes released stale attempts available again. It never pauses
the whole app, uses no new table/service and does not recover source-check jobs.
Existing data validation, fingerprints, observation keys and three attempts remain.

## Ownership and ordering

1. New ImportMemberships jobs include csv_recovery_version=1 in metadata, including
   dashboard-update jobs. CSV contents remain in args; no new credential is needed.
2. The worker validates its snapshot, begins a transaction, locks its own Oban row
   and checks saved worker, queue, state, attempt, start time and CSV against the
   attempt it received. A missing or obsolete attempt is cancelled before writes.
3. The importer writes facts, notes and receipt inside that outer transaction.
   Its existing transaction nests on the same connection. All writes and the
   job-row lock stay together until commit/rollback.
4. Oban records the result after the transaction. The installed Basic engine
   checks executing state and attempted_at before acknowledging an attempt.
5. The recovery sweep locks eligible rows using FOR UPDATE SKIP LOCKED. It never
   steals a held lock. After acquiring a released row it requeues the attempt,
   or discards it if attempts are exhausted. It does not reset/extend attempts.
   A subsequent fetch assigns a new start time; old callbacks cannot acknowledge it.

An unlocked row does not prove that an old Elixir process died. An old process
may have paused before acquiring the lock, or after committing. Rechecking the
saved attempt under the lock fences the former; the fingerprint protects the
latter. Safety relies on CSV writes using this worker's guarded transaction and
on Oban's acknowledgement guards, not on a heartbeat or age alone. Administrative
SQL and direct calls to the lower-level MembershipImporter bypass this job
protocol and are not automatically coordinated recovery paths.

## Bounds and activation

- Worker execution limit: 120 seconds for one attempt.
- Database transaction budget: 110 seconds, with 30-second statement/idle limits
  and a one-second lock wait. These are SET LOCAL values, not global DB settings.
  PostgreSQL 18 transaction_timeout also bounds work if the BEAM is suspended.
- Every 30 seconds, consider at most 50 marked executing CSV jobs started more
  than three minutes ago. Age determines eligibility; the row lock and attempt
  checks determine whether recovery can proceed safely.
- If a lock cannot be acquired or the database is unavailable, leave the job
  unresolved and check later. Do not remove backup/update guards to force progress.
- Unmarked pre-upgrade jobs remain manual recovery cases. A marker is protocol
  versioning for cooperating application code, not an authentication boundary.
- Only CSV_IMPORT_RECOVERY_ENABLED=true opts in. It defaults off in runtime;
  this change adds no enabling value to Compose or Kubernetes manifests.
  Source checks retain their separate SOURCE_CHECKS_ENABLED flag. Test config
  disables automatic plugins even if these environment flags are present.
- Submission/diagnostic processes continue explicitly disabling Oban plugins and
  queues. An isolated integration test starts the recovery process intentionally.

Activation requires the ordinary reviewed build/deploy process and an explicit
configuration change. This document is not evidence of live activation. The
initial isolated measurement on 6 November 2026 imported 5,410 observations from
a 999,999-byte synthetic CSV in 6,045 ms. This supports substantial headroom for
the two-minute limit on the tested machine; it is not a throughput guarantee or
a promise that every valid file finishes under every possible load.

## Failure examples and evidence to require

| Scenario | Required result |
| --- | --- |
| Live attempt holds its row lock | Sweep skips it; unrelated eligible job can recover |
| Worker dies after inserting but before outer commit | Facts and receipt roll back; replacement imports once |
| Commit succeeds but acknowledgement is lost | Replacement sees the fingerprint and reports success without more rows |
| Old process resumes before obtaining its lock | Saved attempt mismatch prevents importer entry |
| Old completion/error/cancellation arrives after replacement starts | Oban's timestamp/state guard leaves the replacement unchanged |
| Overlong attempt is stopped | PostgreSQL releases/rolls back its owned transaction before recovery |
| Attempts exhausted | Discard, keep max_attempts=3; no infinite rescue loop |
| Legacy, source-check, fresh or terminal job | No automatic recovery mutation |

Tests belong in the isolated gym_intel_test database. The near-limit workload uses
synthetic example.com observations, measures row count/bytes/elapsed time and
cleans up its exact fixture records. A real queue test covers sweep, notification,
attempt two and completion. Full suite results, packaged release behaviour and
live deployment evidence must be reported separately; reading this guide proves none.

For the packaged automatic recovery rehearsal, build separate runtime/checks
images and run:

```sh
CSV_RECOVERY_REHEARSAL=true RELEASE_IMAGE=gym-intel-runtime:csv-recovery CHECK_IMAGE=gym-intel-checks:kubernetes sh scripts/verify-readiness.sh
```

The wrapper creates an internal test network, database and limited runtime role.
After killing its labelled worker and proving rollback, it ages only the exact
marked fixture job so the ordinary 30-second recovery tick can pick it up. It
does not call the manual cancel/retry path in this mode. Completion on attempt
two, unchanged replay counts and generated-resource cleanup must pass. CI uses
this automatic mode; the original manual rehearsal remains available by default.

Sources: installed Oban 2.24.1 Worker timeout and Basic engine acknowledgement
code; [PostgreSQL advisory/row locking](https://www.postgresql.org/docs/18/explicit-locking.html)
and [transaction timeout](https://www.postgresql.org/docs/18/runtime-config-client.html).

## Local implementation evidence — 6 November 2026

Verification applies to the working-tree implementation, not a published PR,
hosted CI result or deployment. Branch: codex/csv-import-recovery.

- Full isolated suite: 213 Elixir tests passed; 3 Node browser unit tests passed.
  Fresh advisory audit, formatting and warnings-as-errors compilation passed.
- Controlled interleavings passed for held locks, concurrent sweepers, worker
  death before commit, lost acknowledgement after commit, obsolete attempts,
  exhausted attempts, legacy/source-check exclusions and the real queue notifier.
- Accelerated installed-Oban timer test rolled back uncommitted writes. A separate
  server-side deadline test released the transaction while the old process was
  alive, then prevented that process from committing after replacement.
- A failed early deadline test exposed that changing an already nonzero
  transaction_timeout does not rearm its timer. The boundary now resets to zero
  before arming the intended budget; the corrected behavioural test passed.
- Packaged runtime configuration preserved both source-check and CSV-recovery
  opt-ins with network disabled and without starting the app.
- Both manual and automatic packaged interruption rehearsals passed using a fresh
  internal network, generated database and limited runtime role. Automatic mode
  completed the same interrupted job on attempt two, then replay added no facts
  or notes. Invalid input, permissions, migrations, workload and shutdown checks
  passed; generated resources were cleaned up.
- The automatic rehearsal's deliberate advisory-lock gate initially hit the
  production one-second lock timeout before the kill. Its fixture-only trigger
  now disables that lock timer to force the intended crash interleaving; normal
  execution/statement/transaction limits remain in place. Focused helper tests
  passed after the fixture correction. The production lock timeout is unchanged.
- Near-limit runs imported 5,410 rows / 999,999 bytes in approximately 6.0–6.2
  seconds on this machine. Packaged 1,000-row imports completed in approximately
  2–3 enqueue-to-completion seconds; the overlap ended with 1,500 unique rows.
- Live application image and disabled recovery flag were unchanged. Full-row
  hashes and counts of memberships, notes and file receipts matched the existing
  6/6/2 live baseline. No real gym import or live schema change was performed.

Remaining delivery steps: review, stage, commit, push, hosted CI, learner merge,
then a separately reviewed activation/deployment. Existing unmarked stuck jobs
are not automatically enrolled by enabling the feature.
