---
name: ecc-search-first
description: Research existing solutions before designing a substantial Gym Intel feature, adding a dependency, or writing a reusable helper.
license: MIT
---

# Research before custom code

Follow the root AGENTS.md and preserve the agreed outcome and scope. Keep factual
research ahead of the planning decisions it informs. Small explicit fixes and
already-settled implementation steps do not need a new research interview.

1. State the concrete problem and before/after example. Search the repository,
   tests and installed dependencies for an existing solution first.
2. Use authoritative library documentation and implementation for the installed
   version. For Elixir dependencies, consult Hex and upstream releases/source.
   State missing access or incomplete research rather than claiming no solution exists.
3. Compare the viable options: use existing functionality, extend it, build a
   small custom solution, or retain the current behaviour. Assess failure modes,
   maintenance, licence, compatibility and operational cost.
4. Recommend an option with evidence links and a practical tradeoff. Feed actual
   unresolved decisions into the existing grill-me checkpoint, one question at
   a time; do not ask the learner to rediscover repository facts.

For interrupted imports, establish what an installed recovery mechanism checks
before recommending it: an elapsed-time threshold alone does not prove the old
worker stopped. Compare duplicate execution risks as well as duplicate saved rows.

Keep research bounded to the task. This skill does not authorise installing
dependencies, changing global settings, launching agents or contacting gyms.
Explain and show task-relevant commands before executing them as AGENTS.md requires.

Adapted from ECC's search-first skill. Exact source, changes and MIT attribution
are recorded in [UPSTREAM.ecc.json](../UPSTREAM.ecc.json) and
[LICENSE.ecc](../LICENSE.ecc).
