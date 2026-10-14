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
- `build/` is a workspace project for build-only JuliaC. `build/build.jl`
  produces relocatable distributions under the ignored `build/outputs/` directory.

See the nested guides for package responsibilities and area-specific
invariants. Keep detailed type and function inventories next to the code they
describe rather than expanding this file.

## Cross-Cutting Invariants

- Maintain `CHANGELOG.md` under `Unreleased` for notable player-facing differences
  from the latest release; describe player-visible behaviour rather than implementation.
- Revise or remove unreleased entries when later work supersedes them. Internal
  or insignificant changes need no entry.
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
julia --project=. --threads=2,1 scripts/smoke_test.jl

# Interactive development launch
julia --project=dev --threads=2,1 scripts/repl_launch.jl

# Production entry point
julia --project=. --threads=2,1 -m RocketPlumber

# Distribution build (precompilation runs inside the script's GLFW null scope)
julia --project=build -e 'using Pkg; Pkg.instantiate(; allow_autoprecomp = false)'
julia --project=build build/build.jl
```

Start verification with the affected package suite; use the application smoke
test for integration or gameplay changes. The all-package runner and PR CI
targeting `main` cover the root package and `local_packages/`, excluding the
graphical smoke test and separate tool suites such as `tools/TimelapseExport`.
Report exactly which local checks ran and which display-dependent checks did not.

The separate, manually triggered Distribution builds workflow compiles Windows
ZIPs and Linux tarballs and uploads them to private draft GitHub Releases in
`RocketPlumberPrivate`. Each full run/attempt gets a unique draft targeting the
selected source commit; individual job reruns reuse that draft. Drafts remain
in place after failures. The workflow does not run graphical checks.
Distribution compilation uses substantial memory; run only one local build at
a time and monitor available RAM when verifying it. Distribution jobs use Avrea
8-vCPU, 32 GB Linux and Windows runners; release preparation and PR tests use
standard GitHub runners. The shared build script budgets six image-compilation
threads and leaves build worker, GC and BLAS thread counts at Julia's defaults
unless configured by the caller.
Package precompilation stays serial to avoid multiplying compiler pools and
memory usage. These defaults target both CI and 8-core, 32 GB development machines.

All launch paths need a display/OpenGL context and at least two default Julia
worker threads. The graphical smoke test runs for 1200 simulation ticks
(twenty seconds at 60 UPS), taking about half a minute when warm; compilation
or a slower machine may take longer.
Runtime shaders and the texture atlas are source-controlled inside
`HexFlowRendering`. The TexturePacker inputs remain under
`tools/TexturePacker/textures/`.

All launch paths accept independent, opt-in flags: `--gc-log` prints Julia's
native GC logs; `--telemetry` prints periodic TimerOutputs tables and saves a
cumulative shutdown report under Documents' `RocketPlumber-saves/logs/telemetry/`, excluding each
stream's first (warm-up) sample. Smoke-only `--duration <seconds>` (default and
minimum 20) moves the exit marker without changing scripted action ticks.
