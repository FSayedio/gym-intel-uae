# CI and manual review governance

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
APK package resolution and build-tool downloads are not fully pinned, so this
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
```

These checks use the existing local PostgreSQL service but only test databases,
with owner credentials confined to short-lived checks/client tasks. Source tests
may reuse `gym_intel_test`; the release smoke test always creates a fresh
generated database. The hosted job uses a fresh PostgreSQL service every time.
The original no-argument
`sh scripts/test-database.sh` still runs migrations and tests as before.
Do not point either script at development, rename the development DB, drop a
volume, or expose local passwords to reproduce a CI run.

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
full-stack startup, backup/restore, load tests,
or clean-machine reproduction. Those remain later roadmap items. Hosted checks
can also fail due to registry access, runner availability, quotas or infrastructure;
the logs must distinguish that from an application regression.

The dependency command still reports the previously recorded Decimal 3.1.1
security advisory. Locked-dependency verification does not fail on advisories or
remediate them. Assessment/remediation remains open; do not describe green CI as
a dependency-security clearance.

References: [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[PostgreSQL service containers](https://docs.github.com/en/actions/tutorials/use-containerized-services/create-postgresql-service-containers),
[protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches),
[Mix formatting](https://hexdocs.pm/mix/Mix.Tasks.Format.html), and
[locked dependency checks](https://hexdocs.pm/mix/Mix.Tasks.Deps.Get.html).
