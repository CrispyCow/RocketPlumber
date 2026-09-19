---
name: rocket-plumber-code-style
description: Apply Rocket Plumber's Julia code style when writing, editing, refactoring, reviewing, or formatting project code. Prioritise local consistency, semantic line layout, useful comments and whitespace, restrained helper extraction, typing and dispatch conventions, and per-file Runic policy.
---

# Rocket Plumber Code Style

Write code that is easy to read top-to-bottom and easy to navigate later. Prefer meaningful structure, local consistency, and explicit intent over mechanical style rules or generic "clean code" transformations.

More local `AGENTS.md` guidance takes precedence.

## Local consistency

Inspect nearby code before choosing a style. Closely related code should generally look alike.

Match established local conventions for function form, guard clauses, argument style, naming, field comments, ordering, and section structure. Local consistency can outweigh the ideal formatting choice for one line in isolation.

Make new code look like it belongs beside the code around it.

## Line layout

There is no fixed line-length target.

Keep an expression on one line when it reads comfortably. Otherwise, choose its layout based primarily on which reading direction matters more:

- Favour horizontal flow when the operation or its arguments should be read as a sequence.
- Favour vertical flow when individual arguments or values benefit from being scanned or compared.

```julia
render_sprite(renderer, texture, source_rect, destination_rect, rotation, centre, flip_horizontal, opacity)
```

```julia
configure_solver(
    pressure_tolerance = solver_pressure_tolerance,
    maximum_iterations = nonlinear_iteration_limit,
    convergence_strategy = selected_convergence_strategy,
)
```

Multiline layout does not require one argument per line. When vertical framing helps but the arguments still read as a sequence, keep related arguments together:

```julia
function publish_snapshot!(
        publish_fn::Function, gamemap::GameMap, derived::DerivedMapState,
        mna_state::MNA_State, gamestate::GameState, timestamp::Float64
    )
```

Argument count, keyword arguments, or raw character count do not by themselves justify vertical layout.

Apply the same rule to function signatures, with a bias toward keeping them horizontal. A signature is often primarily a list of names and types; expand it only when doing so genuinely helps.

Rendering code is the canonical case for long horizontal calls: each call performs one visual operation, and seeing the sequence of operations is more useful than vertically inspecting routine arguments.

Use short-form definitions freely for simple expressions that fit cleanly on one line. When they become substantial, use `function ... end` with meaningful intermediate steps rather than a complicated multiline expression after `=`.

## Comments and whitespace

Use blank lines to separate logical groups. Group by meaning, not line count; even one line may deserve separation when it forms a distinct step.

Leave a blank line before a simple final action group, such as `CImGui.End()` followed by `return nothing` or `return result`. Keep a return with preceding calculations when they form one coherent group.

Use terse comments above meaningful blocks when naming the block helps the reader navigate the function without parsing it first.

```julia
# Build the network
nodes = build_nodes(active_components)
branches = build_branches(active_components)
graph = build_connectivity(nodes, branches)

# Initialise solver state
pressures = initialise_pressures(nodes)
flows = zeros(length(branches))
```

Block-heading comments should be short fragments with no trailing punctuation. Group broadly enough to avoid comment noise. A single obvious statement normally needs no heading.

Use short inline comments for individual lines that are surprising or immediately raise a "why?" question.

```julia
scale *= 0.5  # Assets are authored at double resolution
```

Use block comments for genuine multi-line explanation such as algorithms, invariants, mathematics, or non-obvious workarounds.

### Section dividers

Use section dividers as file-level navigation for self-contained concepts.

```julia
# ===============================================================
# Section Title
# ===============================================================
```

```julia
#= ---------- Section Name ----------- =#
```

Sections are semantic, not size-based. Preserve established patterns within a family of files; for example, if each component behaviour gets a minor section, keep that structure even when one component is short.

For new file structures, prefer a small number of meaningful sections over many small ones.

## Keep coherent logic together

Prefer coherent operations inline where they can be read sequentially.

Extract a helper when it provides real value through reuse, a genuinely self-contained concept, or a distinct responsibility that is clearer in isolation.

Use a high bar for one-off helpers. If extraction only gives a short block a name, keep the block inline and put a terse comment above it.

A long function is not a problem by itself. A long, well-grouped sequential function is often clearer than a short coordinator that requires jumping through several one-off helpers.

Do not split functions merely to reduce their line count.

## Runic and file headers

Files may declare their formatting policy in a header:

```julia
#=
Scope: Concrete fluid components and their shared behaviour implementations
Formatter: Runic
=#
```

An optional `Note` may record a stable file-wide constraint.

Formatter states:

- `Formatter: Runic` — run Runic on the file after editing it.
- `Formatter: None` — deliberately no automatic formatter.
- no `Formatter` declaration — not yet migrated; do not run Runic automatically.

The style guide still applies to modified code in unmarked files. The marker controls formatter use, not coding style.

Do not add `Formatter: Runic` during an ordinary edit. Add it only as part of a deliberate migration/style pass.

Choose structural layout, whitespace, and comments before running Runic.

Write explicit returns in long-form functions. Side-effect-only functions will commonly end with `return nothing`; write it deliberately rather than relying on Runic to add it.

## Docstrings

Most `function ... end` definitions should have a short docstring describing what the function does and any important quirk.

```julia
"Update FPS counter in window title using exponential moving average"
function update_fps_counter!(...)
```

Prefer terse descriptions over formal documentation. Do not routinely add argument-by-argument, return-value, or Doxygen-style sections.

One-line methods should have a docstring when their behaviour is meaningful or non-trivial. Repetitive delegation, forwarding, and obvious interface glue generally do not need one.

## Julia conventions

Prefer idiomatic Julia and established local conventions.

- Use Australian English in new project-owned comments, docstrings, and identifiers. Preserve external API spellings and do not churn existing code solely to change spelling.
- Prefer early checks and exits that reduce nesting.
- Simple short-circuit guards are fine, but keep neighbouring guard style consistent. If one guard needs an explicit `if`, usually use `if` for the group.
- Use `isnothing(x)` and `!isnothing(x)` for `nothing` checks.
- Use ternaries for simple two-way value selection; use normal control flow for substantial branches and avoid nested ternaries.
- Use intermediate variables when they name meaningful quantities or clarify a calculation. Do not decompose simple expressions mechanically.
- Prefer comprehensions, `map`, `filter`, broadcasting, and similar idioms while the operation stays simple. Use an explicit loop when the internal logic becomes substantial.
- Use broadcasting when expressing element-wise operations clearly; avoid intricate dotted expressions.
- Group related imports and exports on shared lines where readable. Prefer whole-package imports unless selective imports or qualification solve a specific problem.
- Keep behaviour-specific constants near the code that uses them. Leave ordinary literals such as `2`, `0.5`, and `+1` inline when clear.
- Prefer descriptive names over arbitrary one-letter variables. Conventional mathematical names are fine when their meaning is genuinely obvious.
- Use terse inline struct-field comments when they add useful information such as units, interpretation, or constraints. Follow the surrounding struct style.

## Types, dispatch, and mutation

Annotate function arguments with the types the function is actually designed and tested for. Prefer the expected concrete type; use abstract or unconstrained arguments intentionally when broader behaviour is part of the contract.

Struct fields should be explicitly typed and concrete by default. Broader field types should be deliberate.

Lean into multiple dispatch when behaviour varies by type. Keep shared logic shared and dispatch only the genuinely type-specific parts where practical.

Use `!` consistently for functions that mutate an argument, including large game-state objects. Put the mutated argument first where practical.

Prefer immutable structs for small value-like data where practical. Mutation remains appropriate for large or genuinely stateful structures and reusable buffers.

Use accessors where they provide a real abstraction boundary: unstable representations, validated lookups, or compositional APIs. Direct field access is fine when simple and intentional.

## Performance

Prefer clear, idiomatic code by default. Keep allocations in mind where they can be avoided naturally with views, in-place operations, buffer reuse, broadcasting, or suitable data structures.

Reserve `@inbounds`, `@simd`, and intrusive optimisation for known hot paths or explicit benchmark-informed optimisation work.

## Applying the style

Apply style improvements mainly to modified code and its immediate surroundings. Small adjacent clean-ups are welcome when they improve local consistency, but touching a file does not imply reformatting the whole file.

Do not add speculative TODOs or notes by default. Use them when work is consciously deferred or a specific insight is worth preserving.

Test code should broadly follow the same conventions, but prioritise useful coverage and clear failures over documentation or stylistic polish.

Do not introduce custom macros merely as a style or refactoring technique; they should come from an explicit design decision.

Before finishing, check that:

- new code matches its neighbours
- long expressions use the layout that exposes the useful structure
- whitespace and terse comments make meaningful blocks easy to find
- one-off helpers have not replaced clearer inline logic
- the file's formatter policy has been respected
