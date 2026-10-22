# Feature 3 — CI and manual review governance

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
container. The application image is built from the existing Dockerfile; this is
not the later multi-stage/non-root release-image enhancement. Docker image tags
still follow the existing project versions, not digest pins.

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
```

This uses the existing local PostgreSQL service but only `gym_intel_test`, with
owner credentials confined to the short-lived test task. It does not prove fresh
migrations locally when that test database already exists; the hosted job uses
a fresh PostgreSQL service every time. The original no-argument
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
role-permission integration checks, full-stack startup, backup/restore, load tests,
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
