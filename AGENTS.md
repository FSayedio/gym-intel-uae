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
- The learner runs branch, staging, commit, push, and PR commands. Do not run them on the learner's behalf.
- Never merge, enable auto-merge, force-push, discard work, expose credentials, recreate the repository, reinstall tools, or change global settings.
- Do not claim tests or CI exist until they actually do.
