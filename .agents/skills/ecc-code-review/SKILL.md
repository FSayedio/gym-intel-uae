---
name: ecc-code-review
description: Review Gym Intel changes for concrete correctness, recovery, security and scope regressions before a PR or when a review is requested.
license: MIT
---

# Review with concrete evidence

Read the root AGENTS.md and the agreed before/after outcome. Identify the review
scope: inspect git diff and git diff --staged for local edits, include new
untracked files, or compare the full PR branch with its base for published work.
Read surrounding callers, tests and configuration before judging a change.

Prioritise issues relevant to the changed component:

- Elixir and Ecto: input conversion, error paths, transaction boundaries and
  compatibility between validation and PostgreSQL constraints.
- Oban: job state versus data state, bounded retries, cancellation, interruption,
  duplicate execution and whether recovery can overlap a live worker.
- Database and dashboard: typed identity, atomic receipts/rows/notes, query
  selection, unknown versus zero and the agreed advertised-charge scope.
- Operations: credentials and permissions, backup/restore and rolling retention,
  image delivery, probes and the actual deployment target.
- Skills and docs: precise triggers, valid references, executable command
  examples, attribution and consistency with the learner's working agreement.

For every finding, give a severity, exact file/line, concrete triggering input
or state, bad outcome and suggested correction. Explain why existing guards do
not prevent it. Keep unverified questions separate from confirmed defects.
Severity must reflect demonstrated impact; a generic preference is not a blocker.
Report related findings together and allow a clean review with zero findings.

Avoid stack changes, blanket style rules, reopening settled product choices or
unrelated backlog expansion. Call out unchanged code only when it explains a
changed path or an independently significant issue, clearly labelled as such.

Report scope, findings, evidence inspected or executed, and remaining limits.
Label self-review honestly; do not claim an independent agent/human review unless
one occurred. No automatic delegation, model change or merge is authorised by
this skill. An assessment of readiness is not permission to merge.

After a corrective edit, recheck the affected paths and relevant verification
evidence. Preserve the Before / Action / After / Evidence explanation in the PR.

Adapted from ECC's code-reviewer agent into a project skill. Exact source, changes
and MIT attribution are recorded in [UPSTREAM.ecc.json](../UPSTREAM.ecc.json) and
[LICENSE.ecc](../LICENSE.ecc).
