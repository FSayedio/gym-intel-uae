# Private update status and automatic report retention

Kubernetes stores its reports separately. For offline, read-only evidence use
`sh scripts/update-status.sh --directory "$HOME/Library/Application Support/Gym Intel UAE/kubernetes-backups"`.
`sh scripts/k8s.sh status` additionally queries the running cluster. The saved
report format and retention below are shared across both deployments.

## What, why and how

Before: the update command printed progress, then removed its temporary submission
log. A closed terminal or interrupted connection made it harder to distinguish
queued, committed, backed up and cleaned up. A late lock-cleanup failure could
also follow an earlier overall PASS line.

After: accepted lifecycle attempts persist small, fixed-schema summaries under
the managed private backup root's `update-reports/` directory. Progress is saved
before external work; confirmed outcomes follow explicit acknowledgments. The
final PASS now follows lock housekeeping and successful status publication and
retention, not just the database calls.

Read the saved reports without running an update:

```bash
sh scripts/update-status.sh
```

Use `--directory /absolute/private/path` when the update used an alternate backup
root. The reader performs no Docker/database/network operations, creates no
directories and never retries, restores, cancels jobs or removes locks. Exit zero
means the report was readable, **not** that an update is healthy or successful.
Missing reports are explicitly not proof that no older import ran. Old updates
are not retroactively reconstructed.

Illustrative failed-backup report:

```text
Outcome: failed
Last observed phase: backup-verification
Import commit: confirmed
Backup verification: unknown
Data/job cleanup commit: not_attempted
Lock housekeeping: confirmed
Report retention: confirmed
```

`confirmed` means the command observed the expected acknowledgment/evidence.
`not_attempted` means the stage was not entered (or validation explicitly rejected
input before enqueueing). `unknown` means work may have happened but was not
confirmed; it is not a synonym for rolled back. Examples:

- Enqueue/worker wait failure can leave committed data; the known job ID/SHA is
  retained when the release emitted its safe queued marker before failure.
- Backup can publish a verified copy before later retention/cleanup fails.
- Losing the connection around database COMMIT can leave cleanup's outcome
  unknown; deletion-count output before COMMIT is not proof of completion.
- Lock-housekeeping failure makes the overall command fail even when data work
  succeeded. The report distinguishes those outcomes instead of printing success.
- SIGKILL/host failure can bypass final reporting. The last progress record remains
  `in_progress_or_interrupted`; neither the file nor a PID/lock proves liveness.
  The queued ID may be unknown while the submitting subprocess has not returned.
- An incomplete final report leaves its exit code unknown, not an asserted zero.
  Terminal output/exit status still matters when report storage itself fails.

## Rolling-two policy and privacy

- Keep the latest **two finished-attempt summaries**, including failures. A
  monotonic sequence orders attempts independently of same-second/backward clocks.
  Save/validate an atomic replacement before pruning the oldest exact report file.
- An active attempt may temporarily add a third record. Its lock-referenced report
  is protected. Stale locks are never guessed away; normal updates must not overlap.
- No additional runs means the last two reports remain. This is replacement-based
  retention, not a timer, permanent audit trail, alert or storage-wide garbage sweep.
- Directories are private mode 700 and files mode 600, owned by the invoking user.
  Files contain fixed allowlisted status fields, UTC times, sequence, exit code,
  job ID/SHA and verified bundle basename when known. No CSV, input filenames,
  credentials, raw stacktraces or free-text exception payloads are saved.
- A format/semantic validator rejects malformed, oversized, public, symlinked or
  contradictory records before display/pruning. Saved files are never sourced or
  evaluated. Unexpected files stop pruning; they are not silently deleted.
- Failed replacement writes preserve existing summaries. Reporting/retention
  failures return nonzero; last saved progress can remain uncertain. No filesystem
  durability guarantee is possible after disk loss/power failure. Private status
  records are not cryptographic proof against the same privileged user editing them.
- Reports live outside PostgreSQL and are not included in its logical archives.
  They add neither off-device protection nor encryption. Existing job/backup/raw
  input retention policies are unchanged; this does not erase their older copies.

## Components and verification

`update-dashboard.sh` owns stage evidence and finalization; `status/common.sh`
validates, atomically writes and prunes summaries; `update-status.sh` only reads
them. The release emits safe queued/not-queued markers, allowing a failed attempt
to identify its job without printing its immutable CSV arguments.

Tests use copied scripts/stub Docker commands for failures, retention, storage
errors, hostile records, housekeeping and a real SIGKILL of only the disposable
test script. The synthetic recovery rehearsal verifies reports against actual
packaged worker/backup outcomes and input rejection. No real-host power-loss,
COMMIT-network-loss, distributed coordination or monitoring guarantee is claimed.

See the [update lifecycle](update_lifecycle.md) for the actual data workflow and
[runbook](operator_runbook.md) for safe job/database verification. A saved success
is historical operational evidence, not a fresh health check or proof of source
accuracy. Investigate the recorded phase before deliberately retrying.
