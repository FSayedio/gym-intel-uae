---
name: ecc-verification
description: Choose and report evidence for Gym Intel changes after implementation and before a PR, distinguishing local checks, hosted CI and deployed behaviour.
license: MIT
---

# Verify the claimed outcome

Read the root AGENTS.md and inspect the current scripts and CI workflow before
choosing commands. Explain and show each command before execution. Select checks
for the actual change and supported environment; the following are entrypoints,
not an instruction to run every rehearsal for every edit.

| Change | Relevant existing evidence |
| --- | --- |
| Skills, instructions or documentation only | Validate skill metadata where relevant, links and command references; review the diff and run git diff --check. Application tests are normally not applicable. |
| Elixir, importer, migrations or dashboard SQL | In the active Kind setup, sh scripts/k8s.sh tests runs isolated checks. For the separate Compose development backend, sh scripts/test-database.sh --ci runs the shared CI checks. Read prerequisites first; never start a second active pipeline just to test. |
| Browser request or rendering behaviour | The shared CI checks include Node unit tests; the built runtime can be checked with sh scripts/verify-renderer.sh using synthetic pages. |
| Release, recovery or orchestration | Select the relevant verify-release.sh, verify-recovery.sh, verify-readiness.sh or verify-kubernetes.sh procedure under scripts/ after reading its setup and side effects. |

The shared scripts/ci-checks.sh checks locked dependencies, Hex advisories,
formatting, compilation with warnings as errors, isolated migrations/tests and
browser unit tests. It requires MIX_ENV=test, RUN_DB_TESTS=true,
DATABASE_NAME=gym_intel_test and test credentials; do not run it directly against
the development database. Use the documented wrapper for the chosen backend.

Review the diff for unintended changes and credential/log exposure without
printing sensitive values. A text search is not a security audit. Do not invent
coverage, static-analysis tooling or a security clearance.

Report each relevant check as PASS, FAIL, NOT RUN or NOT APPLICABLE with its
command, actual result and limitation. Record the branch/revision and whether
evidence applies to working-tree edits or a committed revision.

Separate local results from hosted CI and target acceptance. Inspect the latest
tested PR revision before claiming CI success. Merge does not deploy an image;
claim deployed behaviour only after verifying the intended running version and
outcome. Instruction files guide the agent; they do not enforce GitHub checks.

Resolve failures within scope and rerun affected checks. If a required check
cannot run, state the dependency and avoid calling the change fully verified.
Finish with Before / Action / After / Evidence, remaining limitations and the
current Git workflow step. Keep commit, push, PR and learner merge distinct.

Adapted from ECC's verification-loop skill. Exact source, changes and MIT
attribution are recorded in [UPSTREAM.ecc.json](../UPSTREAM.ecc.json) and
[LICENSE.ecc](../LICENSE.ecc).
