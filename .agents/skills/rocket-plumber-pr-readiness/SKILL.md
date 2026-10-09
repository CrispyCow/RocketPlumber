---
name: rocket-plumber-pr-readiness
description: Review a completed Rocket Plumber feature branch for readiness before a PR is proposed or merged.
---

# Rocket Plumber PR Readiness

## Understand the net change

- Read applicable root and nested `AGENTS.md` instructions.
- Inspect Git status and note pre-existing working-tree changes. Preserve unrelated user changes.
- Find the branch's merge base with `main` using `git merge-base main HEAD`.
  Review the complete resulting diff with `git diff <merge-base> HEAD`, rather
  than only the latest commit.

## Review and simplify

- Check correctness, accidental changes, unnecessary complexity, and obvious simplifications.
- For Julia code, read and apply the existing
  [rocket-plumber-code-style](../rocket-plumber-code-style/SKILL.md) skill.
- Keep review proportional to the change; avoid architectural redesign or broad cleanup.
- Make straightforward fixes where useful, then re-review the complete resulting diff,
  including those fixes and any new files.

## Check repository consequences

- Apply the changelog rule from `AGENTS.md` to the branch's net player-facing result,
  rather than its intermediate implementation history.
- When an update is warranted, ensure `CHANGELOG.md` under `Unreleased` concisely
  describes the resulting player-visible behaviour. Rewrite, combine, or remove
  existing unreleased entries when the branch supersedes earlier unreleased work.
  Do not invent an entry merely because this skill is being run.
- Check other applicable repository-wide invariants in `AGENTS.md`, including save
  compatibility and package dependency direction when affected.

## Verify readiness

Run checks and tests proportional to the affected area using the existing repository guidance.
Finish with a concise readiness summary covering:

- meaningful review findings or fixes;
- changelog status: `updated` or `not required`;
- exactly which tests and checks ran, and which relevant checks were not run;
- remaining concerns, if any.
