---
name: rocket-plumber-style-migration
description: Use for a deliberate, conservative single-file Rocket Plumber style-migration pass. Bring an existing Julia file toward the current project style, opt it into Runic where appropriate, minimise functional changes and diff churn, then have a fresh same-class sub-agent independently review the final diff.
---

# Rocket Plumber Style Migration

Migrate one existing source file at a time to the current Rocket Plumber style with a light touch, while allowing small, low-risk presentation and documentation improvements.

This is primarily a presentation and documentation pass, not a refactor.

Before editing:

1. Read all applicable `AGENTS.md` instructions.
2. Read and apply the `rocket-plumber-code-style` skill.
3. Inspect the target file and nearby code for local conventions.
4. Inspect the current Git status and record any pre-existing diff for the target file. Preserve unrelated existing work.

## Migration approach

Prefer leaving marginal existing choices alone. Change code where the improvement is clear rather than trying to make every line ideal.

Be reasonably willing to make small, low-risk presentation and documentation changes during this pass, including navigation comments when they improve scanability. The conservative boundary applies primarily to executable structure and behaviour; do not let it discourage useful, local improvements. Follow `rocket-plumber-code-style` for the details, and avoid broad, repetitive, or speculative additions.

Focus on:

- logical whitespace and grouping
- terse block-navigation comments
- useful inline comments on surprising lines
- concise docstrings
- semantic horizontal versus vertical line layout
- section structure
- obvious local consistency issues
- mechanical formatting

Preserve good existing comments and structure.

Do not treat the file as needing a rewrite simply because it predates the current style.

## Keep the pass effectively non-functional

Avoid structural or behavioural changes during this pass.

In particular, do not:

- extract or add helper functions merely for style
- reorganise algorithms or control flow
- redesign APIs
- change signatures or type contracts
- broadly rename identifiers
- move responsibilities between functions
- perform optimisation work
- make unrelated refactors

Small, obviously semantics-preserving normalisations are acceptable when they directly apply the style guidance, for example:

```julia
x === nothing
```

to:

```julia
isnothing(x)
```

When there is any meaningful doubt about behavioural equivalence, leave the code unchanged.

## File header and Runic

This is a deliberate migration pass, so an unmarked file may be opted into Runic.

Add the standard header with an accurate, stable scope:

```julia
#=
Scope: Concise description of the file's responsibility
Formatter: Runic
=#
```

If an existing header already contains `Formatter: None`, preserve it unless the user explicitly asks to change that decision.

Do not add dates, filenames, authors, change histories, or other metadata that requires routine maintenance.

After the intentional edits, run Runic on the target file.

Inspect the resulting diff carefully. Runic is not permission to accept unrelated churn: revert incidental changes outside the intended migration scope where practical.

## Checks

After formatting:

1. inspect the complete final diff against the pre-edit baseline
2. check especially for accidental expression, control-flow, signature, return, mutation, constant, or ordering changes
3. run relevant existing tests or checks when they are straightforward to run
4. do not create new test infrastructure solely for this style pass

Prepare a concise migration summary containing:

- the main kinds of style changes made
- every change beyond comments, documentation, whitespace, or mechanical formatting, however small
- tests or checks run
- anything deliberately left unchanged because it would require a more invasive change

## Independent review

After the migration diff is complete, delegate a **read-only review to a fresh sub-agent**.

Use the same model/capability class and reasoning configuration as the parent agent where the harness supports this.

- Prefer normal inheritance from the parent session.
- If model or reasoning controls are exposed, match the parent.
- Do not deliberately select a different, stronger, or more expensive model for the review.
- Do not fail the workflow merely because the harness does not expose or verify the inherited model.

Give the reviewer:

- the target file
- the applicable repository instructions
- the `rocket-plumber-code-style` skill
- the pre-edit baseline if the file already had changes
- the complete final diff
- the migration summary, including all non-presentation changes

The reviewer must independently inspect the actual diff rather than relying on the migration summary.

Give the reviewer this task:

> Review this single-file style migration as an independent, read-only reviewer.
>
> The intended change is conservative and effectively non-functional.
>
> First verify behavioural equivalence. Pay particular attention to changed expressions or conditions, reordered operations, control flow, mutation, returns, signatures and types, constants or calculations, externally visible names, and any formatter-produced change that may affect semantics.
>
> Then review the style pass against the applicable `AGENTS.md` instructions and `rocket-plumber-code-style` skill. Check especially for unnecessary churn, inaccurate documentation, poor semantic line layout, weak whitespace grouping, and structural refactoring that did not belong in this pass. Also consider whether the conservative pass missed any clear, low-risk presentation or documentation improvements.
>
> Confirm that the file header is accurate and that the Runic migration is appropriate.
>
> Do not edit files.
>
> Report findings in severity order and distinguish:
>
> - likely behavioural changes or bugs
> - changes needing human inspection
> - style issues
> - harmless observations
>
> If there are no meaningful issues, say so explicitly.

## Respond to the review

Assess the review findings rather than accepting them mechanically.

Fix clear accidental behavioural changes and clear style mistakes that remain within the migration scope.

Do not use reviewer feedback as justification for expanding into a larger refactor.

After any fixes:

- rerun Runic when applicable
- inspect the diff again
- rerun affected checks when appropriate

A second sub-agent review is unnecessary for trivial presentation-only corrections. Use another fresh review when the response to the first review materially changes executable behaviour or substantially changes the reviewed diff.

## User feedback

When the harness provides an interactive question/feedback tool, use it after the review and any obvious fixes to present:

- a concise migration summary
- any changes beyond presentation/formatting
- reviewer findings
- fixes made in response
- remaining marginal choices or concerns

Ask whether the user wants any adjustments and incorporate that feedback in the same task.

If no such tool is available, provide the same information in the final response. Do not block completion merely because interactive feedback is unavailable.

## Scope

Keep the workflow to the single requested file and directly necessary checks.

Style improvements may extend to immediately adjacent code within that file when needed for local consistency, but do not turn the migration into a broader repository clean-up.
