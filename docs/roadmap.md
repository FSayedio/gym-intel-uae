# Roadmap and open-work register

Updated 23 October 2026. This separates delivered software, the current
seven-feature milestone and future work. Counts are checklist items, not equal
effort, elapsed time or an overall project-completion percentage.

## Product objective and current boundary

Help someone choose a gym using objective, official, consistently defined facts;
different people can reasonably choose different gyms from the same evidence.
The delivered pricing slice is an offer explorer, not a winner or all-in-cost
ranking. Four recorded brands are not comprehensive or equally fresh UAE coverage.
More fields and code do not automatically establish comparability.

Current boundary: local manual CSV -> Elixir/Oban -> PostgreSQL -> Grafana,
three long-running ARM64 application workloads. The user explicitly authorised
the full local Kubernetes migration in one PR; see [scope and evidence](kubernetes.md).
No Phoenix, custom API/forms, scraping, Redis or cloud infrastructure is added.
The original September iteration dates are historical, not a new promised deadline.

## Current milestone: foundation and reliability

| Feature | Outcome | Delivery evidence / status |
| --- | --- | --- |
| 1. Security containment | Anonymous Viewer; authenticated database; separate runtime, migrator and reader roles | [PR #7](https://github.com/FSayedio/gym-intel-uae/pull/7), merged |
| 2. Dashboard correctness and presentation | Latest evidence handled without global-date blanking; graph, compact conditions table and visible limitations | [PR #8](https://github.com/FSayedio/gym-intel-uae/pull/8) and [PR #9](https://github.com/FSayedio/gym-intel-uae/pull/9), merged. Final agreed product is an offer explorer, not the superseded strict-cohort/filter layout. |
| 3. CI and review governance | Isolated ARM64 checks for PRs/main; manual latest-green policy | [PR #11](https://github.com/FSayedio/gym-intel-uae/pull/11), merged. Required checks/reviews are not technically enforced. |
| 4. Input/CSV hardening | Explicit numeric/date rules, bounded reading and compatible CSV validation | [PR #12](https://github.com/FSayedio/gym-intel-uae/pull/12), merged |
| 5. Observation integrity | Database-enforced typed identity; preserved internal notes/provenance; public view | [PR #13](https://github.com/FSayedio/gym-intel-uae/pull/13), merged |
| 6. Runtime packaging / Compose portability | Non-root release, separate checks image, explicit helpers, configurable ports, live-job verification | [PR #14](https://github.com/FSayedio/gym-intel-uae/pull/14), merged as `03cf1df`; PR and post-merge CI passed |
| 7. Documentation/operator cleanup | Current runbook/handoff, archived history, explicit roadmap and open gaps | [PR #15](https://github.com/FSayedio/gym-intel-uae/pull/15), merged as `e7dfb28`; PR/post-merge CI passed and local main synchronized |

**Baseline entering Feature 7: 6/7 merged at `03cf1df`.** This is a dated count,
not a live GitHub status. Feature 7's reviewed merge and local sync at `e7dfb28`
closed this milestone at **7/7—not the entire project**. Check delivery without relying on
an old chat message or an embedded "uncommitted" checkpoint:

```bash
git status --short --branch
gh pr list --state all --head codex/operator-handoff --json number,state,mergeCommit,url
```

An open PR is not merged; a merged PR does not itself update local main.
The earlier strict-cohort evidence gate was not met; it was not quietly certified.
The user subsequently approved the narrower explorer and visible conditions.

Feature 7 requires accurate instructions/links, commands matched to the
implementation, recorded verification/limits, diff review, latest-revision green
CI, learner merge, and local-main synchronization. Historical evidence stays
labelled. Writing a guide does not prove clean-machine setup or recovery.

## Subsequent milestones

These are known next areas, **not approved implementation batches or deadlines**.
Plan and verify one focused feature/PR at a time. Do not reopen gym research or
add filters merely to fill the list.

| Milestone | Before -> intended after | Completion evidence |
| --- | --- | --- |
| Operational recovery and visibility | Local state/manual checks -> recoverable, diagnosable operation | Private backups/retention and an independently verified restore; deliberate job-retention/redaction policy; observable failures; interruption tests; dependency follow-ups |
| Measurement and reproducibility | Passing small fixtures -> measured limits and repeatable setup | Independent clean ARM64 environment; supported versions; performance/concurrency/query evidence; indexes justified by plans; quality/browser checks tied to actual risks |
| Product/data enhancements | Recorded monthly offers -> additional useful, honestly comparable questions | Define each metric/cohort, audit uniform official-source coverage, preserve dates/scope/unknowns, test calculations/history, verify a useful display before adding complexity |
| Kubernetes deployment | Local Compose coordination -> separately verified cluster deployment using container images | Explicit scope revision; cluster/data/security model; image delivery; migrations; storage/recovery; probes/resources; networking and verified rollout |

Operational readiness matters before distributing or cluster-hosting the stack.
Kubernetes planning may explain tradeoffs earlier; a successful Compose run is
not cluster-deployment acceptance evidence.

### First operational-recovery feature

[Local database backup and verified restore](database_recovery.md) is the first
focused feature after the seven-item milestone. It adds on-demand whole-database
capture, a brief app pause/resume and an isolated restore rehearsal. It originally
kept seven copies; the [update lifecycle](update_lifecycle.md) changes that to two
verified backups, current-only observation cleanup and two finished import jobs.
Its associated PR/CI/review/merge establishes delivery; documentation alone is
not proof. Off-device
storage, scheduling, actual restore-to-live procedures, Grafana/credential
recovery, broader time-based job policies and monitoring remain separate work; this is not completion
of the operational-recovery/visibility milestone.

The [private status feature](update_status.md) adds read-only saved stage evidence
and automatic two-report retention. It distinguishes uncertain commits and late
housekeeping failures, not fresh system health. Alerting, metrics, off-device
recovery, abrupt real-host interruption drills and dependency follow-ups remain
open; saved summaries do not close the entire operations milestone.

The combined operational-readiness PR now covers three areas: dependency
remediation/advisory CI gating, local recovery procedures, and reproduction/
workload/interruption evidence. The user chose existing operator-triggered health
checks instead of scheduled checks/notifications; automated monitoring is not
claimed. Azure/off-device backups were also deferred rather than creating an
account, leaving laptop-loss protection explicitly open. The local recovery
extension reconstructs Git-managed Grafana with fresh credentials against a
verified restored copy; no live cutover or recovery of untracked UI state is
claimed. Independent-environment evidence must be verified, not inferred from
documentation. That operational-readiness work merged in PR #20; the current
authorised Kubernetes PR follows it.

Local working-tree verification for all three areas is recorded in
[CI and rehearsal evidence](ci.md#local-measurement-evidence-23-october-2026):
180 tests, packaged-release/recovery/Compose checks, a bounded 1,500-observation
workload and deliberate recovery of an interrupted import. This is local evidence,
not a merged delivery or hosted-CI result. Abrupt-job recovery remains an explicit
operator action; no automatic orphan-rescue policy was introduced.

## Kubernetes deployment milestone — authorised and implemented in this PR

The target is a local single-node ARM64 Kind cluster, with existing data restored
and compared, scoped Secrets, persistent claims, explicit migration Jobs,
loopback Grafana access and the same update/backup/retention workflow. See the
[complete before/action/after table](kubernetes.md#changes-reasons-and-examples).
The PR's acceptance/CI results establish delivery; this is not cloud production,
high availability or off-device disaster recovery. The prerequisite list below
is retained as the reasoning checklist, now answered by that guide.

Kubernetes replaces Compose's coordination role, not the containers themselves.
Compose remains a separate development/recovery option. Feature 6 supplied the
runtime artifact; this migration adds manifests, cluster preparation and verified
local operation, not cloud failover or a production-readiness guarantee.

The original prerequisite checklist below is now answered in the migration guide:

1. **Target/budget:** local learning cluster versus hosted deployment;
   architecture, machine headroom, costs and exposure. Selected: local ARM64 Kind,
   loopback access, no cloud provider or global settings change.
2. **Image delivery:** how the cluster receives a tested immutable image.
   Local `gym-intel-runtime:local` alone is not a registry delivery system.
3. **Data ownership:** cluster PostgreSQL versus an external service; persistent
   storage, credentials, backups, restore and retention. A PVC is not a backup.
4. **Change order:** controlled migration task with separate credentials,
   runtime worker and Grafana config; no migration on every replica startup.
   Preserve note-history rollback protections.
5. **Operations:** networking/access/TLS policy, secrets, readiness/liveness,
   resource limits, graceful shutdown, rollout/forward-fix and observability.
6. **Acceptance:** exercise import-to-dashboard in the target, permissions,
   restart/persistence and an approved recovery drill. State untested limits.

## Deferred review findings and operational gaps

The external **Gym Intel UAE Review**, dated 13 September 2026 at `80695af`
(PR #6), is historical evidence and suggestions—not instructions to apply all
recommendations. B/M/m identifiers below preserve traceability. Old-revision
claims are not current facts. This register retains known themes, not every
earlier in-chat roadmap estimate or a claimed verbatim two-bucket classification.

| Area / review reference | Why missed or deferred in the first slice | Incorporation path and current boundary |
| --- | --- | --- |
| Backup, retention and restore; review's untested recovery | First MVP proved import/display, not the data lifecycle. Upgrade archive checks did not test restoration. | The [recovery feature](database_recovery.md) and [update lifecycle](update_lifecycle.md) provide verified capture/two-copy retention. Off-device protection, scheduling and reviewed live-recovery/Grafana/credential procedures remain open. |
| Job retention (m2), diagnostics, observability | Durable snapshots solved mutable-file retries, not long-term privacy/storage/operations. | The [update lifecycle](update_lifecycle.md) keeps two finished import jobs after a verified backup and protects unfinished work. This is count-based cleanup, not a time-based privacy guarantee. Broader redaction, metrics and alerts remain open. |
| Performance/indexes (M4, m3) | Correctness for bounded small CSVs preceded measurement. Removing the blanket lock did not eliminate query cost. | Benchmark realistic loads and explain plans before batching/index changes. Uniqueness tests do not prove throughput or multi-app readiness. |
| Domain normalization, IDs, named branches (m6, m8, m16) | Flat sourced observations kept the pipeline small; canonical entities/UUID redesign was not required to prove it. | Define identifiers and branch-list semantics, then justify a compatible migration. Preserve source text/history; no inferred marketing-tier equivalence or blanket ID rewrite. |
| Provenance (m7) | Early file markers lacked a row link. | Feature 5 links new observations/notes to markers; old unknown provenance stays unknown. Every-occurrence/actor audit history remains unimplemented. |
| Monthly equivalents/history (M7) | Current scope displays monthly charges, not interpreted annual/prepaid offers. | Define billing/commitment/fee/VAT rules from evidence, test known/unknown cases, then design useful history/comparison. No inferred total costs today. |
| Labels/missing-price evidence/time controls (M6, M11, m9) | The initial filtered/history layout changed after user review. | Current graph has gym legend, branch/conditions and source/plan metadata; stored history is not an all-history panel. Revisit ambiguous multi-plan labels or time controls with a reproducible case, not by restoring obsolete panels/suffixes automatically. |
| Docs/operator entrypoints (M9, m10, m11, m12, m14) | Iterative checkpoints accumulated; initial grants/imports were manual. | Feature 6 added tested release helpers; Feature 7 records the sequence and archives old instructions. Dead-code/API-doc cleanup or complete setup automation needs a justified code PR. |
| Developer ergonomics/quality gates (m4, m5, M8) | Manual early checks did not cover all static tooling, coverage or quiet-test ergonomics. | CI now exists; choose Credo/Dialyzer/coverage/logging from concrete risks. Protected-branch enforcement needs an explicit account/visibility decision; governance remains manual. |
| Validation details (M3, M10, m1, m15) | Early examples missed CSV/text/date edge cases. | Feature 4 added explicit input/CSV rules and regression tests. The review's unverified uppercase-scheme concern remains a targeted test candidate, not a claimed fix. HTTP(S) syntax does not authenticate a source. New normalization must not silently rewrite evidence. |
| Dependency/security follow-up | Locked successful builds check consistency, not vulnerability absence. | Operational-readiness work upgrades Decimal 3.1.1 to the 3.1.2 security patch and adds a failing Hex advisory/retirement gate. See CI evidence and remaining limits; broader OS/image scanning and package pinning remain separate, with no security clearance claimed. |
| Broader official metrics/collection | First delivered slice was pricing, not uniform evidence for every metric. | Audit branch footprint, hours, equipment and facilities one metric at a time before fields/views. Do not guess gaps, scrape or contact gyms under current scope. |
| Custom UI/auth/upload/review/API/scraping | External review proposed a different application shape. These were deliberately excluded, not forgotten. | Retain as excluded unless user changes scope after examining need. Phoenix/Redis/custom APIs/forms are not prerequisites for closing this local milestone. |

Before implementing a deferred item: explain what/why/how with a concrete
before/after, identify components and failure behaviour, agree acceptance tests,
then edit -> stage -> commit -> push -> PR -> review -> learner merge -> update
main. Recording a gap is not evidence that it is fixed.
