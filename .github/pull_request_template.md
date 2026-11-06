## Why

<!-- Before: what problem or learning goal does this PR address? -->

<!-- Research: for substantial features or new dependencies, link the existing solutions checked, the selected approach and its tradeoff. For a small fix, mark not applicable rather than inventing research. -->

## What changed

<!-- Action: list the small, specific changes. After: give a concrete resulting example. -->

## How verified

<!-- Evidence: give commands, observed outputs and the tested revision. Do not claim tests or CI ran unless they exist and ran. -->

<!-- Distinguish local checks, hosted CI and deployed verification. Mark checks not run or not applicable explicitly. -->

## Review

<!-- State the diff scope, concrete findings and their resolution, remaining questions, and whether this was self-review or an independent review. A review is not permission to merge. -->

## Risks / limitations

<!-- What remains unknown, incomplete, or deliberately out of scope? -->

## One thing I should be able to explain

<!-- In your own words, explain one important idea you learned from this PR. -->

## Manual merge checklist

<!-- This is our process, not GitHub-enforced branch protection. See docs/ci.md. -->

- [ ] The latest PR revision has a successful `CI checks (ARM64)` result. A missing, cancelled or skipped run is not a pass.
- [ ] The learner reviewed the changes, Before / Action / After / Evidence, and remaining limitations.
- [ ] Any failed checks were fixed and rerun successfully; they are not being waived silently.
- [ ] Merge using **Create a merge commit**. No auto-merge or force-push.
- [ ] After merging, update local `main` with `git pull --ff-only`, verify the merge, then clean up only the merged feature-branch labels.
