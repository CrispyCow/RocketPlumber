## Quick orientation for AI coding agents

Goal: make edits and implement features fast by knowing the project's structure, runtime flow, and key conventions.

- Primary packages: `FlowEngine`, `RenderEngine`, `HexFrame`, `HexElements`, `HexComponentsAPI`, `HexFluids`, `HexFlowControl`, `HexFlowCalculator`, `HexFlowRendering`, `HexFlowTelemetry`.
- Tools: `TexturePacker` (texture atlas generation), `map_encoder` (map encoding/comparison utilities).
- Entry-points:
  - **Development/REPL**: `src/repl_launch.jl` (uses Revise, shows loading screens, suitable for interactive development)
  - **Production/Compilation**: `src/julia_main.jl` (no Revise, loads upfront, defines @main for JuliaC compilation)
- Dependency layers: Foundation (`HexFrame`, `HexFluids`, `HexElements`) → Core Logic (`HexComponentsAPI`, `FlowEngine`) → Application State (`HexFlowControl`) → Simulation (`HexFlowCalculator`) → Rendering (`HexFlowRendering`) → Scripts (`src/*.jl`)

## Big-picture architecture

- Data model: `GameMap` (in `local_packages/FlowEngine/src/FlowEngine.jl`) holds `tiles::Dict{TileCoord, ComponentOnTile}`, `pipe_behaviors::Dict{EdgeCoord, PipeBehavior}`, and `ship_surface::Set{TileCoord}`.
- Derived state: `DerivedMapState` and `MNA_State` are computed from `GameMap` and used for physics/electrical solves.
- Application state: `GameState`, `InputState`, `ViewState`, `HintData`, and `PlacementModes` enum (in `local_packages/HexFlowControl/src/HexFlowControl.jl`) manage UI, player input, and game progression.
- Simulation logic: `FlowCalculator` loop, command system, and map update functions (in `local_packages/HexFlowCalculator`) run on background thread.
- Telemetry: `HexFlowTelemetry` provides diagnostic timing tools (`DiagnosticConfig`, timers for particles/map/MNA) for performance monitoring.
- Flow: UI/input -> mutate `GameMap` -> `update_components!` -> `update_map!` -> `update_mna!` -> render queue built -> `glrender` in `RenderEngine`.
- Rendering: `RenderEngine` provides the low-level OpenGL abstraction; `HexFlowRendering` provides game-specific rendering helpers including particle systems. Uses an object-map (`GLObjectMap`) and a command queue of `RenderCommand{Program,Uniforms}`. Programs are identified by empty singleton types (subtypes of `AbstractRenderProgram`) and uniforms are typed structs (subtypes of `AbstractRenderUniforms{P}`). The `RenderCommand` constructor infers the program type from the uniform struct.

## Files to inspect for common change tasks

- game loop and integration: `src/repl_launch.jl`, `src/gameloop.jl`
- window initialization: `src/initial_window_setup.jl` (OpenGL, GLFW, CImGui context setup)
- start menu and demo system: `src/startmenu.jl`, `src/demo.jl` (tutorial levels and menu navigation)
- application state types: `local_packages/HexFlowControl/src/HexFlowControl.jl` (`GameState`, `InputState`, `ViewState`, `HintData`, `PlacementModes`, `create_consolebuffer`, `get_viewtransform`)
- simulation logic: `local_packages/HexFlowCalculator/src/HexFlowCalculator.jl` (flowcalculator loop, commands, map updates, `FlowCalculatorSnapshot`, `FlowCalculatorIPC`)
- UI functions and input handlers: `src/gameloop.jl` (`user_handler!`, `ui_rendering!`, UI window functions), `src/interactions.jl` (`handle_inputs!`, `poll_keys!`, `flowcalc_*` placement/interaction functions)
- electrical/flow logic and MNA math: `local_packages/FlowEngine/src/FlowEngine.jl` (look for `MNA_getA`, `MNA_getZ`, `MNA_solve`, `update_map!`, `update_mna!`)
- low-level GL abstraction: `local_packages/RenderEngine/src/RenderEngine.jl` (look for `GLObjectMap`, `RenderCommand`, `uniforms_type`, `glrender`, `setup_glprog!`, `setup_gltex!`, `setup_glubo!`, `setup_static_glvao!`, `setup_dynamic_glvao!`, `setup_glsprite!`)
- game-specific rendering: `local_packages/HexFlowRendering/src/HexFlowRendering.jl` (render programs, render helpers, sprite setup, particle systems: `Particle`, `ParticleGroup`, `ParticleManager`, animation functions)
- telemetry and diagnostics: `local_packages/HexFlowTelemetry/src/HexFlowTelemetry.jl` (`DiagnosticConfig`, `particle_timer`, `map_timer`, `mna_timer`, `handle_diagnostics`)
- component API: `local_packages/components/HexComponentsAPI/src/HexComponentsAPI.jl`
- component implementations: `local_packages/components/HexFlow*Components/src/*.jl`
- component instances: `src/components.jl`
- texture packing helper: `tools/TexturePacker/src/TexturePacker.jl` (main module with `pack_textures`, `main` function)
- map encoding tools: `tools/map_encoder/encode_map.jl`, `tools/map_encoder/compare_maps.jl` (utilities for map serialization and comparison)
- shaders: `local_packages/HexFlowRendering/src/shaders/*.vert`, `*.frag`, and `*.geom`

## Project-specific conventions and patterns

- **Rendering Architecture**: `RenderEngine` provides low-level OpenGL abstractions (programs, textures, VAOs, UBOs). `HexFlowRendering` builds on this with game-specific programs (`BaseSpriteRenderProgram`, `LiquidSpriteRenderProgram`, `GasSpriteRenderProgram`, `UntexSpriteRenderProgram`, `ParticleRenderProgram`) and helper functions for tile/pipe rendering.
- **Particle System**: `HexFlowRendering` provides a particle system for visual effects. `Particle` structs are grouped into `ParticleGroup`s, which are managed by a `ParticleManager`. Key functions: `spawn_particles!`, `update_particle_physics!`, `render_particles!`, `thrust_dust_particle_effect!`.
- **OpenGL Programs**: Represented by zero-sized types (Example: `struct MyProg <: AbstractRenderProgram end`). Each program has a matching uniform struct `MyProgUniforms <: AbstractRenderUniforms{MyProg}` and implements `uniforms_type(::Type{MyProg}) = MyProgUniforms`.
- **RenderCommand Construction**: Use `RenderCommand(uniforms, :VAOName, draw_height::Int32)`. The constructor automatically infers the program type from the uniforms. Explicit draw heights required — see `src/render_height.md`.
- **Register GL assets** in the global `GLObjectMap` using: `setup_glprog!`, `setup_gltex!`, `setup_glubo!`, `setup_static_glvao!`, `setup_dynamic_glvao!`, `setup_glsprite!`.
- **Lookups**: Textures and UBOs use `Symbol` keys; programs use program type; VAOs stored within program data. Errors intentionally use `error(...)` on missing entries.
- **GameMap Structure**: `tiles::Dict{TileCoord, ComponentOnTile}` and `pipe_behaviors::Dict{EdgeCoord, PipeBehavior}`. All placed components wrapped in `ComponentOnTile` which adds rotation and delegates interface methods.
- To run the app from a shell in the repo root:
  - **Development** (recommended, with hot-reloading): `julia --project=. --threads=2 src/repl_launch.jl`
  - **Production** (testing before compilation): `julia --project=. --threads=2 src/julia_main.jl`
  This runs the script and performs initialization (OpenGL/GLFW/CImGui setup).
  Note: The FlowCalculator runs on a background thread and the app behaves correctly only when Julia is started with multiple threads (e.g. --threads=2). If you start Julia without extra threads the render loop will still run but the background simulation task may not execute as expected.
  You should execute these scripts after making changes to quickly surface compile-time and runtime errors, unless you are told not to
- Electrical model prefers explicit, allocation-conscious data structures (SmallVector, Dict sizing with `sizehint!`, sparse matrices). Keep hot-loop allocations low.

## Typical developer workflows (how to run & test)

- Interactive run (recommended for iterative development):
  - From repo root open Julia REPL with the appropriate project: `cd \Path\To\HexFlow; julia --project=.` then `include("src/repl_launch.jl")` from the REPL. The `src/repl_launch.jl` script uses Revise and expects local packages to be available via the workspace environment.
- Run the texture packer:
  - `cd tools/TexturePacker; julia --project=. src/TexturePacker.jl` (outputs placed in `tools/TexturePacker/outputs/`).
- Create/regenerate production artifacts:
  - `julia --project=. build/create_artifacts.jl` (creates `local_packages/HexFlowRendering/Artifacts.toml` from shaders and texture atlas).
- Run package tests (per-package Project.toml present):
  - Example: `cd local_packages/HexFrame; julia --project=. -e "using Pkg; Pkg.test()"` or activate root environment and test specific packages via Pkg.

Notes: the app requires OpenGL / GLFW / system libs and CImGui bindings (see `src/repl_launch.jl` for imports). Running the UI from headless CI may fail.

## Artifact system

HexFlow uses Julia's artifact system for production assets (shaders, texture atlases):
- **Development mode** (`repl_launch.jl`): Assets loaded directly from source files for instant hot-reload during development.
- **Production mode** (`julia_main.jl`): Assets loaded from artifacts defined in `local_packages/HexFlowRendering/Artifacts.toml`.

Artifacts are created by the build scripts in `build/` (see `build/build_common.jl::create_hexflow_artifacts()`). The build scripts check if artifacts are up-to-date by comparing source file modification times and skip regeneration if current. The `julia_main.jl` entry point verifies that required artifacts exist but does not create them — if artifacts are missing, it provides descriptive error messages with instructions.

To manually regenerate artifacts without a full build: `julia --project=. build/create_artifacts.jl`

## What to look for when editing

- When changing render programs: update the program type, uniform struct, `uniforms_type` mapping, and call `setup_glprog!` to compile and locate uniform locations.
- When adding sprites/textures: update `textures/TileTextureAtlas1.json` or `tools/TexturePacker/outputs/atlas.json` and run `setup_glsprite!(g_globjmap, :TileTextureAtlas1, "../../textures")` pattern from existing code.
- For flow/electrical fixes: tests of MNA behavior are exercised indirectly by the game loop; preserve pruning/ground-search ordering (`prune`, `ground_search`, `clear_dangling_dependants`) when changing node logic.

## Component authoring guide

This project composes components out of small, reusable behavioral fragments using the `HexComponentsAPI` interface. Components are organized in separate packages under `local_packages/components/`.

**For detailed guidance on creating new component modules**, see `local_packages/components/component_module_guide.md`.

### Component Structure (Quick Reference)

- **API Package**: `HexComponentsAPI` — defines abstract types and interfaces for both tile-based components (`ComponentBehavior`) and edge-based pipes (`PipeBehavior`)
- **Implementation Packages**: `local_packages/components/HexFlow*Components/` — each provides concrete behaviors using the fragment composition pattern
  - `HexFlowBasicComponents` — core reusable fragments and basic component
  - `HexFlowTankComponents` — tank components with charge/pressure management
  - `HexFlowNozzleComponents` — nozzle components with thrust calculations
  - `HexFlowPumpComponents` — turbopump and electric pump components
  - `HexFlowSwitchComponents` — switch and valve components with state management
  - `HexFlowPipeComponents` — tile-based pipe components (cross-pipes, T-junctions)
  - `HexFlowBasicPipes` — edge-based pipe behaviors (ScrapPipeBehav, BigPipeBehav)
- **Component Instances**: `src/components.jl` — creates const instances of components used in-game

### Interface Quick Reference

**ComponentBehavior** (tile-based) mandatory methods:
- `produce_rel_elements(behav)::NTuple{N, RelativeElement}` — return circuit elements
- `get_tunables(behav)::NTuple{N, TunableProps}` — return UI tunables
- `set_tunables(behav, tunables)` — return updated component
- `render_base_elem!(queue, behav; glmap, rotation, position, render_height_offset, kwargs...)` — push render commands

**PipeBehavior** (edge-based) mandatory methods:
- `get_conductance(behav)::Float64` — return pipe conductance
- `get_pipe_tunables(behav)::NTuple{N, TunableProps}` — return tunables
- `set_pipe_tunables(behav, tunables)` — return updated pipe
- `render_pipe_base!(queue, behav; glmap, rotation, position, render_height_offset, kwargs...)` — push render commands

Both interfaces provide optional methods with sensible defaults (see API package or component guide for full details).

### Key Patterns

- **Fragment composition**: Build complex behaviors from small `*BehavFrag` structs; delegate interface methods to fragments
- **Naming conventions**: `*BehavFrag` (fragments), `*CompBehav` (tile components), `*PipeBehav` (pipes)
- **Kwargs delegation**: Always use `kwargs...` pattern without re-specifying defaults
- **Immutable updates**: Use `@set` from Accessors.jl for functional updates
- **ComponentOnTile wrapper**: All placed components wrapped with rotation; delegates to inner component

## Examples drawn from the codebase

- Render command creation: `RenderCommand(uniforms, :basetile, draw_height::Int32)` (see `RenderEngine` — the inner constructor sets program automatically). See `src/render_height.md` for layer guidance.
- Accessing textures: `getid_gltex(g_globjmap, :texname)` and `getdata_glsprite(g_globjmap, :sprite_name)`.
- Rendering helpers: `render_basic_tile(glmap, :MySprite, rotation, position; colour=..., scale=..., transparency=..., draw_height=...)` from `HexFlowRendering`. Also available: `render_liquid_tile`, `render_gas_tile`, `render_basic_pipe` with similar signatures.
- Animation functions (from `HexFlowRendering`): `animation_sprite_picker(sprites_tuple, gameticks, speed_div)`, `animation_vibe_offset(gameticks)`, `animation_rotate(gameticks, speed)`.
- Main loop sequence (high-level): `update_components!` -> `update_map!` -> `update_mna!` -> `tile_queued_render!` -> `glrender` (`src/gameloop.jl`).
- Component delegation pattern: `render_base_elem!(queue, comp::MyComp; kwargs...) = render_base_elem!(queue, comp.sprite; kwargs...)`

## Coding style and documentation preferences

### Documentation and Comments

- **Spelling**: Use Australian English spellings throughout the codebase.
- **Docstrings**: Prefer docstrings over inline comments for documenting functions and types.
  - Single-line docstrings: Use single quotes `"Description here"` to keep file length reasonable.
  - Multi-line docstrings: Use triple quotes `"""Description here"""`.
  - Base function extensions: Always include docstrings when extending Base functions (e.g., `Base.convert`, `Base.:+`) to explain the behavior.
- **Comment style**: Balance readability with conciseness. Comments should convey intent and explain complex logic, not narrate every operation.
  - Simple functions (coordinate conversions, getters/setters): Rely on docstrings; minimal inline comments.
  - Intermediate complexity (rendering helpers, data manipulation): Comment unintuitive operations and edge cases.
  - Complex algorithms (graph traversal, MNA solvers, physics): Keep substantial explanatory comments describing the mathematical/algorithmic concepts.
- **Comment placement**:
  - Single line of code: Place comment inline (same line) after the code.
  - Few lines (2-5): Place comment on its own line just above the code block.
  - Larger sections: Use block comments `#= ... =#` to explain the section.
- **Section dividers**:
  - Major sections: `# ===============================================================` style with centered title.
  - Minor sections: `#= ---------- Section Name ----------- =#` style.

### Code Quality Priorities

- **Readability over performance** outside of critical hot loops. In hot loops, limiting allocations matters more than CPU cycles.
- **Idiomatic Julia**: Use dispatch, iterators, and standard library functions (`map`, `filter`, `filter!`, `copyto!`) where they improve clarity.
- **Type stability**: Important for hot loops. Only suggest easy wins that don't change interfaces; note more complex optimizations for future optimization passes.
- **Allocation minimization**: Many parts of the code allocate more than necessary. This will be addressed in separate benchmarking-driven optimization passes. Don't over-optimize code outside hot loops.

### Code Structure

- **Early returns and guard clauses**: Prefer these to reduce nesting depth.
- **Functional patterns**: Prefer `filter!`, `copyto!`, and similar stdlib functions over bespoke implementations when simpler.
- **Duplicate code**: Extract into helper functions when it improves maintainability.
- **Function grouping**: Keep related functions together under appropriate section headings.

## Guiding rules for automated edits

- Preserve type stability in hot loops. Prefer adding a new typed field to `MNA_State` rather than switching representations in-place.
- When modifying public APIs (struct fields, exported function names), update all packages that `using` them (search for the symbol across the repo). Use project-local `using` patterns in top-level `src/repl_launch.jl` and `src/julia_main.jl`.
- Avoid touching shader attribute layouts without updating `VboAttribFormat` usage and `setup_static_glvao!` or `setup_dynamic_glvao!` callers.
