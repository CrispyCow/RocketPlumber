# Rocket Plumber — Claude Code Instructions

You are an expert at crafting clear, concise and idiomatic Julia code. You have an extensive understanding of this code base, and it is in your interest to maintain the highest levels of code quality within it for future maintainability.

Rocket Plumber (working title: HexFlow, still prevalent throughout the codebase) is a spaceship-building simulation game with deep fluid mechanics modelled on circuit simulation. Players construct ships from pipes and components on a hex grid, then fly them to destinations in space with realistic manoeuvre dynamics.

---

## Coding Style and Conventions

### Spelling and Language

Use **Australian English** spellings throughout (e.g., "colour", "behaviour", "manoeuvre", "initialise").

### Documentation

- **Docstrings over inline comments** for function/type documentation
  - Single-line: `"Description here"` (double quotes; keep them short)
  - Multi-line: `"""Description here"""`
- Docstrings should convey purpose, not repeat name/signature or describe step-by-step workings. Only include detailed notes for genuine complexity or non-obvious quirks
- **Base function extensions** (`Base.convert`, `Base.promote_rule`, `Base.:+`, etc.): always include docstrings explaining the behaviour — the implementation alone can be confusing
- **Inline comments** should convey intent and explain complex logic, not narrate obvious operations

### Comment Style

- **Simple functions** (getters, conversions): rely on docstrings, minimal inline comments
- **Intermediate complexity** (rendering helpers, data manipulation): comment unintuitive operations and edge cases; combine related operations under a single explanatory comment
- **Complex algorithms** (graph traversal, MNA solver, physics): keep substantial explanatory comments; reference external resources where applicable; retain comments that explain non-obvious invariants

**Comment placement:**
- Single line of code: inline after the code
- Few lines (2–5): comment above the block
- Larger sections: block comments `#= ... =#`

Replace multiple single-line comments with one describing the block. Keep "why" comments, remove "what" comments that restate obvious code. Brief inline comments on struct fields are valuable — keep unless completely redundant.

### Section Dividers

Major sections:
```julia
# ===============================================================
# Section Title
# ===============================================================
```

Minor sections:
```julia
#= ---------- Section Name ----------- =#
```

### Line Length and Argument Layout

- **Short signatures** (fits on one line): keep on a single line
- **Medium signatures**: break at `;` — positional args on first line, kwargs each on their own indented line
- **Long signatures**: break positional args onto first continuation line, then one kwarg per line
- Don't split a line that reads comfortably at ~120–140 columns
- Exception: rendering function signatures in component definition files — keep on one line

### Code Quality

- **Readability over performance** outside hot inner loops
- **Idiomatic Julia**: use dispatch, iterators, `map`, `filter`, `filter!`, `copyto!` where they improve clarity
- **Early returns and guard clauses** to reduce nesting depth
- Extract duplicate code into helper functions when it improves maintainability; don't add excessive helpers that just add indirection
- Use `get_component`, `get_ship`, etc. when available instead of direct dict/struct access

### Performance

- **Hot inner loops** (MNA matrix stamping, particle physics per-particle): minimise allocations; prefer in-place operations, pre-allocated buffers, `sizehint!`
- **Type stability**: important in hot loops; only suggest easy wins that don't change interfaces; note complex optimisations for future benchmarking passes
- Don't over-optimise code outside hot inner loops

### Naming Conventions

- `*BehavFrag` — reusable behavioural fragments (do not subtype `ComponentBehavior`/`PipeBehavior`)
- `*CompBehav` — concrete tile-placed component behaviours (subtype `ComponentBehavior`)
- `*PipeBehav` — concrete pipe-segment behaviours (subtype `PipeBehavior`)
- `*DockStat` — docking status subtypes
- `*State` — mutable state containers (e.g., `TankState`, `SwitchState`, `LearningSystemState`)

---

## Package Overview

Organised in dependency layers (each depends only on layers above it). Full details in `local_packages/CLAUDE.md`.

| Layer | Package | Purpose |
|-------|---------|---------|
| Foundation | `HexFrame` | Hex-grid coordinates, adjacency, rotation algebra |
| Foundation | `HexFluids` | Fluid type system and declarations |
| Foundation | `HexElements` | Circuit element types |
| Foundation | `SquirrelNoise` | Deterministic noise / RNG |
| Core | `HexComponentsAPI` | Abstract component/pipe interfaces |
| Core | `FlowMap` | Game/ship data model, docking, space map |
| Core | `FlowEngine` | MNA solver, fluid propagation, temperatures |
| App State | `HexFlowControl` | `GameState`, `InputState`, `ViewState` |
| Simulation | `HexFlowCalculator` | Background sim loop, commands, snapshots |
| Proc Gen | `HexFlowProcGen` | Ship generation, encounters, manoeuvre planning |
| Learning | `HexFlowLearningSystem` | Tutorial types, triggers, learning state |
| Rendering | `RenderEngine` | OpenGL abstraction |
| Rendering | `HexFlowRendering` | Game rendering, shaders, particles |
| Rendering | `HexFlowTelemetry` | Diagnostic timers |
| Components | (see `local_packages/components/CLAUDE.md`) | Component behaviours |

---

## Runtime Architecture

### Two-Thread Model

- **Main thread**: GLFW event polling, OpenGL rendering (`custom_rendering!`), CImGui UI (`ui_rendering!`), input handling (`user_handler!`)
- **Background thread**: `flowcalculator_loop!` — fixed-timestep accumulator (target 60 UPS)

### Command System

The render thread **never directly mutates `GameMap`**. All changes flow through typed `MapEditCommand` subtypes enqueued via `try_enqueue_command!`. Commands are sandbox-validated (deep-copy trial run) before applying to the real map.

### Snapshot-Based Decoupling

After each tick, the background thread deep-copies all state into a `FlowCalculatorSnapshot` published via a lock-guarded `Ref`. The render thread reads the latest snapshot each frame.

---

## Running the Project

```shell
# Smoke test first
julia --project=. --threads=2,1 --gcthreads=1,1 src/auto_test_launch.jl

# Development (interactive, uses Revise for hot-reload)
julia --project=. --threads=2,1 --gcthreads=1,1 src/repl_launch.jl

# Production
julia --project=. --threads=2,1 --gcthreads=1,1 src/julia_main.jl

# Texture packer
cd tools/TexturePacker && julia --project=. src/TexturePacker.jl textures outputs/TileTextureAtlas1

# Package tests
cd local_packages/<PackageName> && julia --project=. -e "using Pkg; Pkg.test()"
```

At least 2 threads are required. The app requires OpenGL/GLFW/CImGui bindings — headless CI will fail.

Use `src/auto_test_launch.jl` as the first-pass smoke test after most gameplay changes so the game proves it can boot into the simulation loop without crashing. If the work adds or changes behaviour that should be exercised manually, follow it with `src/repl_launch.jl`.
