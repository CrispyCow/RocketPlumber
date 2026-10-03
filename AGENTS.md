# Rocket Plumber Repository Guide

Rocket Plumber, still often named HexFlow in code, is a spaceship-building
simulation game with fluid mechanics modelled on circuit simulation. Players
construct ships from pipes and components on a hex grid, then fly them to
destinations in space with realistic manoeuvre dynamics.

## Working In This Repository

- Prefer small, scoped changes that follow nearby Julia style and package
  boundaries.
- Preserve user changes. Do not revert unrelated dirty files.
- Search the whole repository before changing exported names, struct fields,
  constructors, or public function signatures. Packages re-export and import
  each other extensively.
- Treat code, tests, and `Project.toml` files as authoritative when prose has
  drifted. Update the closest `AGENTS.md` when durable structure, workflow, or
  local conventions change.
- Check the nearest nested `AGENTS.md` before editing under `src/`,
  `local_packages/`, or `tools/`; those files contain the specialised context
  intentionally omitted here.

## Coding Style and Conventions

Use **Australian English** for new project-owned names, comments, documentation,
and other prose. Preserve terminology and spellings imposed by external APIs,
libraries, and existing interfaces.

For Julia code, apply the `rocket-plumber-code-style` skill in
`.agents/skills/rocket-plumber-code-style/SKILL.md`. The skill contains the
full style guidance; the rules below are the most important defaults.

### Core Style

* **Match nearby code first.** Prefer established local conventions and keep
  related definitions visually consistent.
* **No fixed line-length target.** Keep calls and signatures horizontal when
  their role in the surrounding flow matters more than inspecting individual
  arguments. Split vertically when the arguments themselves are the important
  information. Bias function signatures toward staying on one line.
* **Keep coherent logic together.** Do not extract one-off helper functions
  merely to name a short block or reduce function length. Long, well-structured
  sequential functions are fine; use whitespace and terse comments to expose
  their structure.
* **Use whitespace and comments for navigation.** Separate logical groups with
  blank lines. Use short fragment comments above meaningful blocks and brief
  inline comments for individual surprising lines. Avoid comments that merely
  narrate obvious code.
* **Prefer low nesting.** Handle exceptional or irrelevant cases early where
  practical. Keep neighbouring guard clauses in a consistent style.

### Julia Conventions

* Most `function ... end` definitions should have a short docstring describing
  their purpose and important quirks. Avoid argument-by-argument or
  Doxygen-style documentation. Trivial delegation and interface glue need not
  be documented individually.
* Annotate arguments with the types the function is actually designed for.
  Prefer concrete types by default; use abstract or unconstrained types
  deliberately when broader behaviour is intended.
* Struct fields should be explicitly typed and concrete by default.
* Prefer multiple dispatch over explicit type branching when behaviour varies
  by type, while keeping shared logic shared.
* Use `!` consistently for functions that mutate an argument, and put the
  mutated argument first where practical.
* Use `isnothing(x)` / `!isnothing(x)` for `nothing` checks.
* Prefer idiomatic comprehensions, `map`, `filter`, broadcasting, and similar
  constructs while they remain simple; use an explicit loop when the logic
  becomes substantial.
* Write explicit returns in long-form functions. Side-effect-only functions
  commonly end with `return nothing`.
* Prefer clear code over speculative micro-optimisation. Keep allocations in
  mind, but reserve `@inbounds`, `@simd`, and similar optimisation for known
  hot paths or benchmark-informed work.

### Runic

Source files may declare a formatter in their header:

```julia
#=
Scope: Description of the file's responsibility
Formatter: Runic
=#
```

* `Formatter: Runic` — run Runic on the file after editing it.
* `Formatter: None` — deliberately do not run an automatic formatter.
* No formatter declaration — do not run Runic automatically; the file has not
  yet been migrated.

Do not add `Formatter: Runic` during an ordinary edit. Formatter migration is a
deliberate style pass.

### Scope of Style Changes

Apply style improvements primarily to modified code and its immediate
surroundings. Avoid broad reformatting during ordinary changes; follow the
file's formatter policy and keep adjacent cleanup small and directly useful.


## Repository Map

- `src/` is the application and integration layer: the `RocketPlumber` module,
  game/UI loops, persistence adapters, component registration, and demo maps.
- `local_packages/` contains the reusable Julia packages. Each package has its
  own environment; component API and implementations live under
  `local_packages/components/`.
- `tools/` contains developer-facing maintenance, asset-generation, analysis,
  export, and similar utilities.
- `.agents/skills/` contains reusable agent workflows and their specialist
  instructions, scripts, and resources.
- The repository root is the `RocketPlumber` Julia package. Its
  `src/RocketPlumber.jl` module is the application assembly point; use
  `RocketPlumber.launch()` for normal startup. The root `Project.toml` and
  `Manifest.toml` define the package and its workspace.
- `dev/` is a workspace project for development-only dependencies such as
  Revise. Use it for interactive development; local packages remain path
  dependencies rather than workspace members. Standalone tools may own separate
  environments.

See the nested guides for package responsibilities and area-specific
invariants. Keep detailed type and function inventories next to the code they
describe rather than expanding this file.

## Cross-Cutting Invariants

- The main thread owns GLFW, OpenGL, CImGui, rendering, and input. The
  background calculator thread owns authoritative simulation mutation.
- UI and input code send `MapEditCommand` values through
  `try_enqueue_command!`; render code reads `FlowCalculatorSnapshot` values and
  must not mutate the live `GameMap`.
- Changes to saved structs require an explicit compatibility review of
  `local_packages/HexFlowPersistence/src/migrations.jl` and historical tests;
  field defaults alone do not migrate old saves.
- Preserve established package dependency direction. Inspect the affected
  `Project.toml` files before adding a cross-package import.

## Running And Verification

Run commands from the repository root unless a package-local command says otherwise.

```shell
# Set up the shared package and development workspace
julia --project=dev -e 'using Pkg; Pkg.instantiate()'

# Test one local package
julia --project=local_packages/<PackageName> -e 'using Pkg; Pkg.test()'

# Discover or run the root application and all local-package test suites
julia tools/run_all_package_tests.jl --list
julia tools/run_all_package_tests.jl

# Scripted full-application smoke test
julia --project=. --threads=2,1 --gcthreads=1,1 scripts/smoke_test.jl

# Interactive development launch
julia --project=dev --threads=2,1 --gcthreads=1,1 scripts/repl_launch.jl

# Production entry point
julia --project=. --threads=2,1 --gcthreads=1,1 -m RocketPlumber
```

Choose verification proportional to the change: start with the affected
package suite, then use the application smoke test for integration or gameplay
changes. The all-package runner includes the root `RocketPlumber` test suite and
packages under `local_packages/`, not the separate `tools/TimelapseExport` suite.

The GitHub Actions test workflow runs the all-package test sweep for pull
requests targeting `main`. It does not run the graphical smoke test or separate
tool tests. Report exactly which local checks were run and which
display-dependent checks were not run.

All game launch paths need a display/OpenGL context and at least two default
Julia worker threads. The smoke test opens a real window and is not headless.
Its script runs for 1200 simulation ticks (about twenty seconds at 60 UPS); a
warmed graphical run took about half a minute including startup and teardown.
Fresh compilation or a slower machine may take longer.
Runtime shaders and the texture atlas are source-controlled inside
`HexFlowRendering`. The TexturePacker inputs remain under
`tools/TexturePacker/textures/`.

All three launch paths accept `--telemetry` to enable periodic TimerOutputs
tables and a cumulative shutdown report under ignored `logs/telemetry/`.
Telemetry is disabled by default; the first periodic sample per stream is
printed as warm-up and excluded from the cumulative report. The smoke launcher
also accepts `--duration <seconds>` (at least 20, default 20) to move its final
exit marker without changing the scripted action ticks.
