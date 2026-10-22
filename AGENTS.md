# Gym Intel UAE Working Agreement

## Project boundaries

- Build a local pipeline: CSV -> Elixir + Oban -> PostgreSQL -> Grafana.
- Run exactly three local Docker services using ARM64-compatible images.
- Do not add Phoenix, custom APIs or forms, Redis, Kubernetes, or scraping.
- Track branch footprint, published prices and commitments, opening hours, documented equipment, and facilities.
- Every fact needs a source, observation date, and correct geographic and branch scope. Missing information stays unknown.
- Work in three iterations through Friday, 11 September 2026: working MVP, reliability, then measurement and reproducibility.
- Reduce scope before sacrificing understanding or verification.

## Learning-first workflow

- Prefer small, practical steps. Before each command, explain its purpose, expected result, and verification.
- Keep these steps distinct: edit -> stage -> commit locally -> push to GitHub -> open PR -> review -> merge -> update local main.
- At each checkpoint, report the current branch, workflow step, evidence of changes, Git/GitHub status, the learner's next action, and unfinished work.
- The assistant shows each relevant command, explains its purpose and expected result, executes it, and reports the actual output. This includes Git commands; keep staging, committing, pushing and opening a PR as distinct, explicitly announced steps. Do not treat command execution permission as permission to merge or discard work.
- Never merge, enable auto-merge, force-push, discard work, expose credentials, recreate the repository, reinstall tools, or change global settings.
- Do not claim tests or CI exist until they actually do.

## Feature-planning checkpoint (Matt Pocock's grill-me)

- Before planning a substantial feature or PR, or when the learner asks to be grilled, read `.agents/skills/grill-me/SKILL.md` and its companion `.agents/skills/grilling/SKILL.md`. If the host has no separate Skill tool, load the companion instructions directly; do not pretend a tool invocation occurred.
- Keep the upstream skill files unchanged. The learner's preferences here take precedence over its default batch-question format: one feature and one concise question at a time. Give a recommended answer, explain its tradeoff, and wait for the learner's response.
- Establish the intended user outcome, before/after example, scope and non-goals, responsible components or code segments, inputs and outputs, failure behaviour, and verification evidence. Explore dependent decisions only after their prerequisites are settled. Look up repository facts instead of asking the learner to rediscover them.
- Explain unfamiliar concepts before asking the learner to decide. Use a concrete example rather than testing unexplained jargon. Preserve the what/why/how teaching style and show commands before executing them.
- Do not reopen settled gym research or expand the application scope without a real requirement or new evidence. The four currently loaded gym brands are the working dataset for this development iteration, not a claim of equivalent memberships or a permanent UAE-wide shortlist.
- Finish with a concise agreed plan and unresolved points. Start substantial implementation only after the learner confirms shared understanding. Continue to verify and review the resulting work; a planning interview is not evidence that the feature works.
- Do not force an interview for a small, explicit fix, factual question, status check, or already-approved step. Pause at an actual decision, not after every routine action.
- Upstream: `mattpocock/skills`, revision `5beb35b040e3de97e54fa9e386d7e42d15c295c2`. Source and licence records are in `.agents/skills/UPSTREAM.json` and `.agents/skills/LICENSE.mattpocock`.
