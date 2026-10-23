# CI and manual review governance

## Kubernetes acceptance

The Kubernetes migration adds a separate `Kubernetes acceptance (ARM64)` job.
It installs checksum-verified project-local kubectl/Kind, creates a disposable
single-node cluster, then runs `sh scripts/verify-kubernetes.sh`: fresh migrations,
actual role denials, three synthetic update/backup/cleanup cycles, rejected input,
PostgreSQL/Grafana pod replacement with persistent storage, actual dashboard
queries and the full source/database suite. Test credentials are generated for
that namespace, never copied from a real developer environment. Jobs/pods and
the synthetic namespace are cleaned up; private archives/CSV arguments are not
uploaded as artifacts.

The original `CI checks (ARM64)` job remains. Both jobs must be green on the PR's
latest revision before the learner merges. This is the existing manual policy,
not newly enforced branch protection. A successful local run does not establish
hosted CI success; inspect the PR checks separately.

Local migration evidence on 23 October 2026: 184 tests passed inside Kubernetes,
the source/target protected-state hash matched, four real offers were queried
through Grafana, and Kubernetes-side backup restoration passed. See the final PR
for the exact revision and complete acceptance/hosted results.

## Earlier Compose/source evidence

Feature 6 extends the original source checks below with separate checks/runtime
images and a final-image live-job smoke test. The job remains `CI checks (ARM64)`;
manual review/merge policy is unchanged. Feature 6's latest
[PR run](https://github.com/FSayedio/gym-intel-uae/actions/runs/39918378815)
passed for `688fab5`; the
[post-merge run](https://github.com/FSayedio/gym-intel-uae/actions/runs/39918887601)
passed for `03cf1df`. Those are dated baseline results, not approval of later
changes. See the [current handoff](reviewer_handoff.md) and
[operator runbook](operator_runbook.md); earlier checkpoints are
[archived](reviewer_history.md).

## Before, action, after

- **Before:** checks were run locally and reported in PR text, but GitHub did not
  automatically execute them. The repository had no committed formatter inputs.
- **Action:** `.github/workflows/ci.yml` runs on PRs targeting `main` and pushes to
  `main`. It validates Compose, builds the existing ARM64 Dockerfile, and invokes
  `scripts/ci-checks.sh` against disposable PostgreSQL. `.formatter.exs` defines
  formatting inputs for project/config/source/test files and migrations.
- **After:** a bad change has an observable failed check. For example, broken
  duplicate detection fails the existing integration tests instead of relying
  only on someone remembering to run them. This is not proof of source accuracy,
  full application readiness or production safety.

## What runs, where, and with what access

The standard `ubuntu-24.04-arm` GitHub-hosted runner matches the architecture of
our local images. It uses the account's Actions-minute allowance; private-repo
usage can be billed beyond that allowance depending on account settings. No
account upgrade, paid larger runner, visibility change or spending-setting change
is part of this feature. Jobs time out after 20 minutes; a newer commit cancels
an obsolete run for the same PR.

The workflow uses a read-only `contents` token and an exact checkout revision,
with persisted Git credentials disabled. That token is not passed to the test
container. The Dockerfile now has a tool-filled `checks` target and a non-root
`runtime` target. Source checks run in the former; the live smoke check runs
the latter. Builder/runtime bases are digest-pinned after the first Feature 6
hosted run exposed differing cached/registry Alpine versions. Both now use
Alpine 3.24.3, with the compatibility guard retained. PostgreSQL/Grafana tags,
APK package resolution and Rebar downloads are not fully pinned, so this
is not a claim of bit-for-bit reproducible builds or a vulnerability clearance.

The PostgreSQL service belongs only to that GitHub job; its host port binds to
loopback, not all interfaces. `ci-only-password` is a
disposable test credential, not a repository secret, personal credential or local
database password. It is written to a runner-temporary file for the current
password-file configuration. No `.secrets` files or named development volumes
are uploaded or mounted. The job is not a fourth long-running local service.

`scripts/ci-checks.sh` requires all of:

- `MIX_ENV=test`
- `RUN_DB_TESTS=true`
- `DATABASE_NAME=gym_intel_test`
- A nonempty test password file via `DATABASE_PASSWORD_FILE`

It refuses other settings before running Mix. The test helper independently
refuses database integration tests against any other database name. Credentials
for creating/migrating the disposable test database are never needed by the
running development app.

The shared script runs, in order:

```sh
mix deps.get --check-locked
mix hex.audit
mix format --check-formatted
mix compile --warnings-as-errors
mix ecto.create
mix ecto.migrate
mix test --no-start
```

The hosted PostgreSQL service starts with only its default `postgres` database;
the script creates `gym_intel_test` and applies migrations from scratch. It does
not start the application supervisor or normal Oban imports queue. Database and
dashboard SQL tests use synthetic sandbox data; no import into development is
performed. The real CSV snapshots are read as test fixtures, not re-collected.

After source checks, `scripts/verify-release.sh` creates a second, uniquely named
test database and temporary migrator/runtime roles on that disposable service.
It uses the actual runtime image to apply fresh migrations, start the supervised
worker, enqueue a synthetic CSV twice, verify two completed jobs but one stored
observation/note/fingerprint, and stop the worker gracefully. It also checks
non-root execution, absent build CLIs, missing-credential failure and invalid
input rejection. The runtime worker never receives the owner/migrator secret.
The test cleans up only its own generated resources and fails if cleanup fails.
This is independent of sandbox/unit tests; it is not a hosted Grafana/full-stack
or fresh-machine reproduction test.

The recovery feature adds a separate `scripts/verify-recovery.sh` step. It runs
the actual backup/restore entrypoints against a disposable synthetic PostgreSQL
and app fixture with no host ports or development volumes/secrets. It verifies
pause/resume, full restored baselines, real role denials and identity/note probes,
rejects corrupted archives (including one with a recomputed checksum) and a
weakened source permission profile, and preserves the previous good backup.
The checks image includes the OpenSSL CLI for filesystem/checksum unit tests;
this does not add it to the final runtime image. No private archive/log is uploaded.
See [Database recovery](database_recovery.md) for limits and local commands.

The operational-readiness extension additionally rebuilds a fresh Grafana against
that synthetic restored copy. A temporary internal Docker network has no host
ports or live mounts. A standalone HTTP probe checks Git-matching queries, the
exact synthetic offer/price, reader connectivity and fresh admin authentication;
the full PostgreSQL baseline must remain unchanged and no worker connects. The
default database-only verifier still uses `--network none`. CI explicitly pulls
the ARM64 Grafana image before the rehearsal and passes its checks-image tag.
Generated replacement resources are deleted, not switched into service. This is
not a physical-machine loss or live persistent-target cutover test.

`scripts/verify-compose.sh` checks the rendered model with default and alternate
host ports. Both must retain localhost bindings, original internal ports, three
ARM64 services, the runtime target, correct app secret and named-volume keys.
It also requires the two read-only PostgreSQL directory mounts and matching
authentication-config path, guarding against the stale individual-file binds
observed during the local upgrade.
It does not start/recreate containers or prove those host ports are available.

## Inspecting a result

Open a PR's Checks section, select **CI checks (ARM64)**, then inspect the failed
step. Results are tied to a commit: an older green revision does not approve a
newer commit. Missing, skipped, cancelled, timed-out or infrastructure-failed
runs are not successful verification.

For a local rerun after the normal local setup, build the image from this checkout
and use the same shared check script through the test-only wrapper:

```sh
docker compose build app
sh scripts/test-database.sh --ci
sh scripts/verify-compose.sh
sh scripts/verify-release.sh
sh scripts/verify-recovery.sh
```

These checks use the existing local PostgreSQL service but only test databases,
with owner credentials confined to short-lived checks/client tasks. Source tests
may reuse `gym_intel_test`; the release smoke test always creates a fresh
generated database. The hosted job uses a fresh PostgreSQL service every time.
The original no-argument
`sh scripts/test-database.sh` still runs migrations and tests as before.
Do not point either script at development, rename the development DB, drop a
volume, or expose local passwords to reproduce a CI run.

## Bounded setup, workload and interruption rehearsal

The operational-readiness entrypoint creates a separate internal network and a
fresh temporary PostgreSQL instance. It does not use the development server,
volumes, `.secrets/`, backups or host ports:

```sh
docker build --target checks --tag gym-intel-checks:local .
docker build --target runtime --tag gym-intel-runtime:readiness-verify .
RELEASE_IMAGE=gym-intel-runtime:readiness-verify sh scripts/verify-readiness.sh
```

The existing release smoke test runs first against a generated database/roles on
that new server: fresh migrations, non-root worker, actual queued jobs and invalid
input rejection. PostgreSQL is limited to 768 MiB/one CPU with 512 MiB tmpfs; the
worker and one-off verification tasks are limited to 512 MiB/one CPU. Docker/image
versions/identities are printed. Temporary clients/resources and generated
credentials are removed; cleanup errors fail the command. No permanent fourth
service, global installation, alert or scheduled health check is introduced.

| Check | Before -> action -> required after |
| --- | --- |
| Abrupt interruption | A test-only trigger reaches an advisory-lock wait inside the import transaction -> kill only the labelled generated worker, confirm its exit, then terminate the uniquely named test gate holder's database session -> the disconnected worker session disappears; prior complete facts, notes and file markers remain byte-for-byte equal; the exact job remains executing/attempt one. |
| Deliberate recovery | With the worker and its database sessions demonstrably gone, remove the test trigger and cancel/retry that exact synthetic job through Oban -> restart the same worker; the same job completes on attempt two, with one observation/note/fingerprint. |
| Replay | Submit the recovered snapshot again -> one more completed job, no additional observation/note/marker. |
| Bounded workload | Submit 1,000 validated synthetic rows, replay identical bytes, then submit rows 501–1,500 -> 1,500 workload observations/notes, not 2,000; exact marker counts verified after each stage. |
| Actual dashboard queries | Analyze the fixture tables and run both tracked data-panel SQL queries as a temporary restricted reader with EXPLAIN ANALYZE/BUFFERS JSON -> both select 1,502 eligible rows, including the two earlier smoke/crash offers; record timings, plan structure and block activity. |

The CSVs are strictly below **1,000,000 bytes**, use `TEST ONLY` names and
`example.com` sources, and never become real gym observations. The fixture helper
refuses non-generated database/role names; the extended release mode requires the
wrapper's labelled internal network. A transaction gate, not a lucky sleep, proves
the worker was killed mid-import. The interrupt is a SIGKILL of that one generated
container; Docker Desktop, PostgreSQL and live services are never killed.

The gate is deliberately released only after the worker exits: removing a client
container alone need not immediately interrupt a sleeping PostgreSQL session.
The harness terminates only its uniquely named gate-holder backend in the generated
database, not the worker's backend; PostgreSQL must independently discard that
disconnected worker's uncommitted transaction. An ordering regression test guards
this sequence.

### Recovery is manual under the current Oban configuration

No orphan-rescue/Lifeline service is configured. The stager can make scheduled or
retryable jobs available; it does not turn an abandoned executing job into a retry.
`Oban.retry_job` ignores executing jobs. The rehearsal verifies supported exact-job
`cancel_job` then `retry_job` calls only after the old worker is demonstrably dead.
Its one-off process disables queues/plugins/peer and also checks the exact worker,
queue, attempt and synthetic CSV. It cannot start another import while inspecting.

This is not permission to cancel arbitrary live executing jobs: a real worker may
still be running, and a lost acknowledgment may follow a committed transaction.
Control submissions, identify the exact job/worker, establish its absence and
inspect committed fingerprint/data evidence before agreeing a deliberate recovery.
Do not reset attempts, delete jobs/markers or resubmit blindly to hide a failure.
No automatic production rescue policy was added by this verification work.

### What the measurements do and do not establish

- Enqueue-to-completion seconds include process startup and one-second polling;
  they are coarse end-to-end measurements, not importer-only CPU time.
- Query plans run over a populated, analyzed, predominantly warm fixture. Summaries
  include actual rows, execution/planning times, scan/sort/index nodes and block
  counters. No index is added merely because a sequential scan appears.
- `docker stats` is a current worker-memory/CPU sample, not a peak. Where supported,
  cgroup `memory.peak` is separately reported for the worker, not the whole system.
- The 120-second per-job observation window is a bounded test deadline, not a
  production SLA. These are correctness/measurement checks, not a saturation test,
  simultaneous-reader benchmark, 1,502-bar browser-rendering test or capacity claim.
- A hosted ARM64 run provides independent runner evidence only after that exact
  revision passes. Fresh local containers alone are not a second-machine result.
  Neither test installs Docker on a blank Mac or reproduces host power failure,
  disk loss, network loss around COMMIT, or failure after commit before job ack.
- Results go to normal command/CI output; this adds no permanent measurement-report
  store or artifacts containing CSVs/secrets. Existing hosted log retention is
  unchanged. No off-device disaster recovery is claimed.

The new workflow step runs the same fresh-server rehearsal after release/recovery
checks. All new results remain tied to the tested working tree/commit, not to an
older green run. See [recovery procedures](database_recovery.md) for real-incident
boundaries and [runbook](operator_runbook.md) for manual checks.

### Local measurement evidence (23 October 2026)

The ARM64 working-tree rehearsal exited zero using Elixir 1.20.4, OTP 29,
Oban 2.24.1 and PostgreSQL 18.6. It observed:

| Check | Observed result |
| --- | --- |
| Interrupt and recover | Killed worker exited 137; existing facts/notes/markers unchanged; exact job completed on attempt two; replay added no observations or notes. |
| First 1,000-row file | 179,564 bytes; completion observed after 2 seconds; 1,000 workload observations and notes. |
| Identical replay | Completion observed within the same whole-second clock tick (reported 0 seconds); still 1,000 workload observations and notes. This is not a zero-duration claim. |
| Rows 501–1,500 | 180,532 bytes; completion observed after 2 seconds; 1,500 unique workload observations and notes, four total markers including smoke/recovery fixtures. |
| Chart/table SQL as reader | Both returned 1,502 eligible offers; execution 7.984/7.578 ms, planning 1.011/0.875 ms; each reported 77 shared-hit blocks, zero read/temp blocks and an in-memory sort. |
| Worker memory | Current sample 125.7 MiB of its 512 MiB limit; cgroup peak 154,488,832 bytes (about 147 MiB). Not whole-stack memory. |

These are one local run's observations under the bounds above, not thresholds,
fresh-host acceptance, hosted-CI evidence or a production capacity promise.

The same working tree's full source/database check subsequently reported **180
passed** (seed `332957`), including formatting and the online dependency audit.
The standalone packaged-release smoke check, full recovery/rolling-two rehearsal
and default/alternate-port Compose checks also exited zero. A separate networkless
Hex audit exited one with `Could not audit these locked packages`, confirming
that missing registry data does not produce a clean audit result. Existing
dependency/test warnings remain; this is not a claim that all upstream warnings
or security risks are eliminated.

## Agreed manual merge policy

The private repository's branch-protection and ruleset endpoints returned HTTP
403 requesting an upgrade or a public repository. `main` reported unprotected.
We agreed to keep it private, make no paid account change, and use a manual rule:

1. Keep the `codex/<short-feature-name>` branch convention for new work. Do not
   rename or rewrite old branches merely to make history uniform.
2. Record Before, Action, After, Evidence and remaining limits in the PR.
3. Require a successful CI result for the latest reviewed PR revision.
4. The learner reviews the diff and evidence. Do not claim an independent human
   review or formal GitHub approval when there was none.
5. The learner merges using **Create a merge commit**. The assistant never merges
   or enables auto-merge. A red check means stop, fix and rerun.
6. Update local `main` with `git pull --ff-only`, verify it matches GitHub, and
   remove only the finished branch labels as a separate cleanup step.

These are documented expectations, **not a technical merge lock**. GitHub can
still allow someone to merge a failed PR or push to `main`. Do not report required
checks or protected branches as configured. Revisit server enforcement only
after an explicit future account/visibility decision; never silently upgrade,
make the repository public or alter global settings.

## Completion evidence and limits

Feature 3 is not complete just because YAML exists. Its delivery must record a
successful hosted PR run and the exact tested revision, review/merge, and local
`main` synchronization. The `push` event can only be verified after merging into
`main`; report that result separately. A manual policy is the agreed replacement
for unavailable enforcement, not a claim that enforcement was delivered.

This does not add static analysis, coverage thresholds, visual browser automation,
off-device disaster recovery, load tests or clean-machine
reproduction. The recovery extension verifies a bounded local-style logical
capture and isolated restore, not a production backup service. Other gaps remain
later roadmap items. Hosted checks
can also fail due to registry access, runner availability, quotas or infrastructure;
the logs must distinguish that from an application regression.

The operational-readiness change requires Decimal `~> 3.1.2`, the patch line that
fixes the previously recorded rounding-allocation advisory. The lock file records
the exact resolved version. The application has no direct `Decimal.round` call;
this is dependency remediation, not a claim of a demonstrated application exploit.

After locked-dependency resolution, `mix hex.audit` checks the locked packages for
known advisories and retirements. A finding or failed registry lookup stops the
shared script before compilation, migrations or tests. CI removes inherited
`HEX_OFFLINE`, `HEX_IGNORE_ADVISORIES` and `HEX_IGNORE_RETIREMENTS` overrides; no
advisory exemption is configured in this project. A network/registry failure is a
failed verification, not evidence that dependencies are safe. Do not bypass that
failure to merge. This covers Hex package advisories, not OS/container scanning,
unknown vulnerabilities or complete supply-chain security. There is no periodic
security run between PR/push events yet.

The Dockerfile pins Hex 2.6.0 inside the build/checks image. The previous cached
Hex 2.5.4 audit returned zero after registry timeouts by using cached records;
the disconnected-registry check caught this false pass. Requiring the new task
and exercising its actual failure path is necessary: merely adding an audit
command to YAML is not proof of fail-closed behaviour. No host tool installation
or global configuration change is required.

The hosted job runs a checks container with networking disabled and bounded
memory/CPU. It requires both a nonzero audit exit and the specific registry-audit
failure, and rejects the success message. An unrelated Docker/command failure is
not accepted as proof. The normal online audit still has to pass separately.

Script tests use a stub Mix executable (no database or network) to verify ordering
and failure propagation. The real audit and full test/recovery runs are separate
evidence, tied to the tested revision.

References: [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[PostgreSQL service containers](https://docs.github.com/en/actions/tutorials/use-containerized-services/create-postgresql-service-containers),
[protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches),
[Mix formatting](https://hexdocs.pm/mix/Mix.Tasks.Format.html), and
[locked dependency checks](https://hexdocs.pm/mix/Mix.Tasks.Deps.Get.html),
[Hex advisory audit](https://hex.hexdocs.pm/Mix.Tasks.Hex.Audit.html), and
[Decimal 3.1.2 security fix](https://github.com/ericmj/decimal/releases/tag/v3.1.2).
