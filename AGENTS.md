# Rocket Plumber - Codex Agent Instructions

These instructions are for Codex agents working in this repository. Keep the
existing GitHub Copilot and Claude guidance files; this file sits alongside
them and should not replace them.

Rocket Plumber, still often named HexFlow in code, is a spaceship-building
simulation game with fluid mechanics modelled on circuit simulation. Players
construct ships from pipes and components on a hex grid, then fly them to
destinations in space with realistic manoeuvre dynamics.

## How To Work In This Repo

- Read the most local `AGENTS.md` before editing files in a subdirectory.
- Use the existing `CLAUDE.md` files as supporting context when you need more
  domain detail; keep this file focused on Codex-specific workflow and high
  signal repository conventions.
- Preserve user changes. Do not revert unrelated dirty files.
- Prefer small, scoped changes that follow nearby Julia style and package
  boundaries.
- Search before changing public APIs. Packages re-export and import each other
  extensively, so symbol changes can have broad reach.
- Use Australian English in comments, docs, UI text, and tests.

## Coding Style

- Write clear, idiomatic Julia using dispatch and standard library functions
  where they improve readability.
- Prefer guard clauses and early returns over deep nesting.
- Use accessor helpers such as `get_component`, `get_ship`, and related APIs
  when available instead of reaching into backing dictionaries directly.
- Extract duplicate code only when it improves maintainability. Avoid helper
  functions that only add indirection.
- Keep lines intact when they read comfortably at about 120-140 columns.
- For medium signatures, break at `;`: positional arguments on the first line
  and keyword arguments on their own indented lines.
- For long signatures, place positional arguments on the first continuation
  line and then use one keyword argument per line.
- Keep rendering function signatures in component definition files on one line
  when they follow the repeated local pattern.

## Documentation And Comments

- Prefer docstrings for function and type documentation.
- Single-line docstrings use `"Description here"` and should stay short.
- Multi-line docstrings use `"""Description here"""`.
- Docstrings should state purpose, not restate the signature or narrate every
  implementation step.
- Always add docstrings for Base extensions such as `Base.convert`,
  `Base.promote_rule`, and operator overloads.
- Inline comments should explain intent, invariants, and non-obvious behaviour.
  Avoid comments that restate the code.
- Brief inline comments on struct fields are useful and should usually stay.

Section dividers:

```julia
# ===============================================================
# Section Title
# ===============================================================
```

```julia
#= ---------- Section Name ----------- =#
```

## Performance

- Minimise allocations in hot inner loops such as MNA matrix stamping and
  per-particle physics. Prefer in-place operations, pre-allocated buffers, and
  `sizehint!`.
- Outside hot loops, prioritise readable code over speculative optimisation.
- Type stability matters in hot paths. Make simple interface-preserving
  improvements when obvious; leave larger optimisation work for benchmarking.

## Architecture Notes

- The render thread must not directly mutate `GameMap`. Changes should flow
  through typed `MapEditCommand` values enqueued with `try_enqueue_command!`.
- The background thread publishes a deep-copied `FlowCalculatorSnapshot`; render
  code should read snapshots rather than live simulation state.
- `GameMap` stores components and pipes in global dictionaries. Ownership is on
  `PlacedComponent.ship` and `PlacedPipe.ship`.
- Adding fields to saved structs may require JLD2 reconstruction hooks in
  `src/map_loading.jl`; defaults alone are not enough for old saves.
- Preserve FlowEngine graph update ordering unless the task explicitly changes
  it: prune, ground search, dangling dependant cleanup, convergence loop.

## Package Layout

- Foundation: `HexFrame`, `HexFluids`, `HexElements`, `SquirrelNoise`
- Core: `HexComponentsAPI`, `FlowMap`, `FlowEngine`
- App state: `HexFlowControl`
- Simulation: `HexFlowCalculator`
- Procedural generation: `HexFlowProcGen`
- Learning/tutorials: `HexFlowLearningSystem`
- Rendering: `RenderEngine`, `HexFlowRendering`, `HexFlowTelemetry`
- Component implementations: `local_packages/components/`

See `local_packages/AGENTS.md`, `local_packages/components/AGENTS.md`, and
`src/AGENTS.md` for area-specific context.

## Running And Testing

Use PowerShell from the repository root unless a package-specific command says
otherwise.

```powershell
# First-pass gameplay smoke test
julia --project=. --threads=2,1 --gcthreads=1,1 src/auto_test_launch.jl

# Interactive development launch
julia --project=. --threads=2,1 --gcthreads=1,1 src/repl_launch.jl

# Production launch
julia --project=. --threads=2,1 --gcthreads=1,1 src/julia_main.jl

# Package tests
Set-Location local_packages/<PackageName>
julia --project=. -e "using Pkg; Pkg.test()"
```

At least two Julia threads are required. The app needs OpenGL, GLFW, and CImGui
bindings; headless environments may fail even when code is correct.

Run `src/auto_test_launch.jl` after most gameplay changes. If the change affects
behaviour that needs manual inspection, follow with `src/repl_launch.jl`.
`src/auto_test_launch.jl` can take longer than 3 minutes to boot and complete;
use a timeout of at least 6 minutes before treating it as hung.
