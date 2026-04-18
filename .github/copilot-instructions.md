# Rocket Plumber -- AI Agent Instructions

You are an expert at crafting clear, concise and idiomatic Julia code. You have an extensive understanding of this code base, and it is in your interest to maintain the highest levels of code quality within it for future maintainability.

Rocket Plumber (working title: HexFlow, still prevalent throughout the codebase) is a spaceship-building simulation game with deep fluid mechanics modelled on circuit simulation. Players construct ships from pipes and components on a hex grid, then fly them to destinations in space with realistic manoeuvre dynamics.

---

## Coding Style and Conventions

### Spelling and Language

Use **Australian English** spellings throughout (e.g., "colour", "behaviour", "manoeuvre", "initialise").

### Documentation

- **Docstrings over inline comments** for function/type documentation
  - Single-line: `"Description here"` (double quotes for single-line docstrings; keep them short)
  - Multi-line: `"""Description here"""`
- **Overly verbose docstrings**: docstrings should convey the function's purpose, not repeat its name/signature or describe step-by-step workings. Only include detailed notes when there is genuine complexity or a non-obvious quirk worth flagging
- **Base function extensions** (`Base.convert`, `Base.promote_rule`, `Base.:+`, etc.): always include docstrings explaining the behaviour -- the implementation alone can be confusing
- **Inline comments** should convey intent and explain complex logic, not narrate obvious operations

### Comment Style

The goal is to balance readability with conciseness. The appropriate level of commenting depends on code complexity:

- **Simple functions** (getters, conversions): rely on docstrings, minimal inline comments
- **Intermediate complexity** (rendering helpers, data manipulation): comment unintuitive operations and edge cases. Combine multiple related operations under a single explanatory comment
- **Complex algorithms** (graph traversal, MNA solver, physics): keep substantial explanatory comments describing the mathematical/algorithmic concepts. Reference external resources where applicable. Retain comments that help readers understand non-obvious invariants or state

**Comment placement:**
- Single line of code: inline (same line) after the code
- Few lines (2--5): comment on its own line above the block
- Larger sections: block comments `#= ... =#`

**Comment consolidation**: replace multiple single-line comments with one describing the block; move single-line explanations inline; keep "why" comments, remove "what" comments that restate obvious code.

**Struct field comments**: brief inline comments on struct fields are valuable for documentation -- keep these unless completely redundant.

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

Do not excessively break function signatures across multiple lines. Follow these rules:

- **Short signatures** (fits comfortably on one line): keep everything on a single line
- **Medium signatures**: break at the `;` between positional and keyword arguments. Positional args on the first line; kwargs start on the next, each on its own indented line
- **Long signatures**: break positional args onto the first continuation line, then one kwarg per line
- **General principle**: don't split a line that reads comfortably at ~120--140 columns. Only break when a single line would genuinely be hard to scan
- The same rules apply to function calls, constructor invocations, and similar long expressions
- Exception: rendering function signatures in component definition files, where the args are always the same -- best to keep them on one line

### Code Quality

- **Readability over performance** outside hot inner loops
- **Idiomatic Julia**: use dispatch, iterators, and standard library functions (`map`, `filter`, `filter!`, `copyto!`) where they improve clarity
- **Early returns and guard clauses** to reduce nesting depth
- **Extract duplicate code** into helper functions when it improves maintainability. Do not add excessive helper functions that do not address code duplication -- they just add complexity and indirection
- **Accessor functions**: use `get_component`, `get_ship`, etc. when available instead of direct dict/struct access for better error messages and future flexibility

### Performance

- **Hot inner loops** (MNA matrix stamping per-element, particle physics per-particle): minimise allocations. Prefer in-place operations, pre-allocated buffers, `sizehint!`
- **Outer loops** (once per frame/tick): allocations are acceptable -- don't over-optimise
- **Type stability**: important in hot loops. Only suggest easy wins that don't change interfaces; note complex optimisations for future benchmarking passes
- Much of the codebase allocates more than necessary. This will be addressed in a future benchmarking-driven pass. Don't over-optimise code outside hot inner loops

### Naming Conventions

- `*BehavFrag` — reusable behavioural fragments (do not subtype `ComponentBehavior`/`PipeBehavior`)
- `*CompBehav` — concrete tile-placed component behaviours (subtype `ComponentBehavior`)
- `*PipeBehav` — concrete edge-placed pipe behaviours (subtype `PipeBehavior`)
- `*DockStat` — docking status subtypes
- `*State` — mutable state containers (e.g., `TankState`, `SwitchState`, `LearningSystemState`)

---

## Project Structure

### Packages

Organised in dependency layers (each layer depends only on those above it):

**Foundation** (no game-package dependencies):
- `HexFrame` — hex-grid coordinate types, conversions, adjacency queries, rotation algebra
- `HexFluids` — fluid tag types (`FluidTags` enum) with bitmask classification and priority resolution
- `HexElements` — circuit element types (`RelativeElement`, `AbsoluteElement`), element-type enum, coordinate mapping
- `SquirrelNoise` — deterministic noise functions (SquirrelNoise5 hash), counter-mode `SquirrelRNG`

**Core Logic:**
- `HexComponentsAPI` — abstract interfaces for `ComponentBehavior` and `PipeBehavior`, `ComponentOnTile` wrapper, `TunableProps`, `ActionInfo`
- `FlowMap` — data model (`GameMap`, `ShipMap`), ship management, docking system, space map, encounter/manoeuvre types, placement validation, bounds/geometry
- `FlowEngine` — MNA (Modified Nodal Analysis) circuit solver, `DerivedMapState`, `MNA_State`, graph pruning, fluid tag propagation. Depends on `FlowMap` (does not re-export it)

**Application State:**
- `HexFlowControl` — `GameState`, `InputState`, `ViewState`, `PlacementModes` enum, `SimSpeed` enum, `ExitReason` enum, view transform matrix, input edge-detection helpers, closure-based console buffer

**Simulation:**
- `HexFlowCalculator` — background-thread simulation loop, command system (`MapEditCommand` subtypes), `FlowCalculatorSnapshot`, `FlowCalculatorIPC`, `update_map!`/`update_mna!` orchestration, manoeuvre phase state machine

**Procedural Generation:**
- `HexFlowProcGen` — ship surface generation (random tile walks), component/pipe placement strategies, encounter point system (spawn/recycle via bounds-check), `SpaceMapState`, manoeuvre planning (closest-approach, intercept delta-v), ship generation configs

**Learning/Tutorial System:**
- `HexFlowLearningSystem` — tutorial types (`SandboxTutorialDef`, `SandboxTutorialLevel`, `InGameTutorialDef`, `TutorialStep`, `LearningEntry`, `LearningInputs`), trigger/step-blocker predicates, `LearningSystemState` (render-thread runtime), tutorial flow helpers for the persistent learning state stored on `GameMap`
- `FlowMap` — persistent learning state (`TutorialState`, `LearningProgress`, `SandboxLearningState`) stored on `GameMap`, plus save/load reconstruction hooks

**Rendering:**
- `RenderEngine` — low-level OpenGL abstraction (`GLObjectMap`, `RenderCommand`, typed shader programs, VAOs, textures, UBOs, sprites)
- `HexFlowRendering` — game-specific rendering (4 render programs, sprite/tile/pipe helpers, particle system, animation functions, render height constants, GLSL shaders)
- `HexFlowTelemetry` — diagnostic `TimerOutput` instances and tick-gated printing

**Component Implementation Packages** (under `local_packages/components/`):
- `HexFlowBasicComponents` — reusable fragments (`PlainSpriteBehavFrag`, `BasicElemBehavFrag`, `StallBehavFrag`, `BinaryStateBehavFrag`, `FloatStateBehavFrag`, `FluidTagBehavFrag`, `HorizontalFlipOnlyBehavFrag`, `NoRotationBehavFrag`) and `BasicCompBehav`
- `HexFlowTankComponents` — gas/liquid tanks (Thevenin equivalent) and pressure-fed tanks (separate gas headspace), charge tracking, stall protection
- `HexFlowNozzleComponents` — nozzles, switched nozzles, decomp chambers with thrust calculation and particle exhaust
- `HexFlowPumpComponents` — turbopumps (gas-driven) and electric pumps (battery-powered) with energy management
- `HexFlowSwitchComponents` — bool switches, stepped adjustable valves, and on/off valves in two sizes (`LargeValve`, `TinyValve`)
- `HexFlowPipeComponents` — tile-based pipe components (`ScrapTilePipeCompBehav`, `BigTilePipeCompBehav`)
- `HexFlowBasicPipes` — edge-based pipe behaviours (`ScrapPipeBehav`, `BigPipeBehav`)

### Tools
- `tools/TexturePacker/` — sprite atlas generator: trims transparency, packs PNGs into atlas + JSON metadata
- `tools/map_encoder/` — JLD2 map to human-readable text converter and AI-generated map validator
- `tools/EncounterBalance/` — encounter balancing and analysis tools
- `tools/map_diagnostics/` — map debugging and MNA diagnostic utilities
- `tools/local_package_updater.jl` — helper for updating local package dependencies
- `tools/review_instructions.md` — review checklist and supporting notes for instruction/documentation audits

### Top-Level Source Files (`src/`)
- `repl_launch.jl` — development entry point (Revise, loading screens, hot-reload)
- `julia_main.jl` — production entry point (no Revise, artifact verification, `@main` for JuliaC)
- `gameloop.jl` — main game loop: GL init, snapshot management, rendering pipeline, FlowCalculator IPC, learning system tick
- `map_loading.jl` — JLD2 serialisation and reconstruction hooks for current save formats
- `interactions.jl` — all input handling: keyboard/mouse polling, cursor transforms, click detection, placement ghost rendering, docking beam rendering, FlowCalculator command enqueueing
- `components.jl` — concrete component/pipe instances, procedural generation `roll_component`/`roll_pipe` specialisations, ship generation configs and weights
- `tutorials.jl` — `LearningEntry` definitions for sandbox and in-game tutorials, demo map includes
- `ui_common.jl` — shared UI constants, ImGui typed input helpers, formatting utilities
- `ui_game.jl` — in-game ImGui windows: inspector (dispatched on coord type), velocity tracker, toolbar, property box, space map overlay with encounter planning
- `ui_menus.jl` — pause menu, developer utilities (proc gen tools, docking viewer)
- `ui_learning.jl` — Learning Helper overlay and Tutorial Detail pane UI
- `recording.jl` — in-game screen recording (FFmpeg H.264) and PNG screenshots, `RecordingState`, frame capture via `glReadPixels`
- `startmenu.jl` — main menu loop (Launch Teaser, New Game, Load Game, Tutorials, Quit), session state machine (`MapSession`/`SandboxSession` with level progression)
- `initial_window_setup.jl` — GLFW window creation, OpenGL context, CImGui/ImPlot setup, scroll/FPS callbacks
- `demo_maps/mapgen_*.jl` — map generator functions for tutorial levels (8 currently in use)

---

## Data Model

### Game Map (Multi-Ship)

- **`GameMap`** (in `FlowMap`): top-level container with `ships::Dict{Symbol, ShipMap}` (always has `:primary`), `space_map::AbstractSpaceMap`, and `learning_system::AbstractLearningSystem`
- **`ShipMap`**: per-ship data with `components`, `pipe_behaviors`, `ship_tiles`, `docking_status`

Ship management: `add_ship!`, `remove_ship!`, `get_all_ship_names`, `has_ship`, `get_ship`, `offset_ship!`.
Multi-ship queries: `has_component_any_ship`, `get_component_any_ship`, `find_ship_for_surface`, `find_valid_ship_for_placement`, `find_ship_with_component`, `find_ship_with_pipe`, `find_ship_for_node`, `would_bridge_ships`.

Note: `get_all_components(gamemap; ship_name=:primary)` only returns components for one named ship. For cross-ship scans, loop `get_all_ship_names(gamemap)`.

### Coordinate System (HexFrame)

Six coordinate types for flat-top hexagonal grids:
- **`CartesianCoord`** — screen/world space (1.0 = hex centre to vertex)
- **`TileCoord`** — integer axial, identifies a hex tile
- **`AxialCoord`** — continuous axial for sub-tile precision
- **`VertexCoord`** — hex vertex, canonicalised via `to_proper`
- **`EdgeCoord`** — hex edge between two vertices
- **`NodeCoord`** — circuit node (6 axis directions + `NODE_INTERNAL` + `GROUND`)

`HexAxis` enum: `Q_POS=0, R_NEG=1, S_POS=2, Q_NEG=3, R_POS=4, S_NEG=5` -- forms Z/6Z rotation group. Each increment = 60 degrees.

### Circuit Elements (HexElements)

Components define circuit contributions via `RelativeElement` (tile-local), mapped to `AbsoluteElement` (map-global) via `map_element()` / `produce_abs_elements()`.

Five element types (`ElementTypes` enum): `CONST_RESISTOR`, `CONST_VOLTAGE`, `CONST_CURRENT`, `C_DEP_CURRENT` (CCCS), `V_DEP_VOLTAGE` (VCVS).

### Fluid System (HexFluids)

`FluidTags` enum with bitmask encoding. Concrete: `COLD_GAS`, `MONOPROP_LIQUID`, `MONOPROP_GAS`. Behaviour (wildcard): `ANY_GAS`, `ANY_LIQUID`. Sentinel: `NONE`. Per-node tag bundles use `NodeFluidTags`. Resolution via `prioritise_fluidtag()`.

### Space Map and Encounters

- `SpaceMapEmpty` (velocity only, tutorials; defined in `FlowMap`) or `SpaceMapState` (full simulation with encounters; defined in `HexFlowProcGen`)
- `ManoeuvreData`: 4 active phases (`PHASE_APPROACH_BURN`, `PHASE_COAST`, `PHASE_CAPTURE_BURN`, `PHASE_ENCOUNTER_READY`)

### Docking System

Three `DockingStatus` subtypes: `ConnectedDockStat`, `ApproachingDockStat`, `DepartingDockStat`. State machine in `update_docking!`.

---

## Runtime Architecture

### Two-Thread Model

- **Main thread**: GLFW event polling, OpenGL rendering (`custom_rendering!`), CImGui UI (`ui_rendering!`), input handling (`user_handler!`)
- **Background thread**: `flowcalculator_loop!` -- fixed-timestep accumulator (target 60 UPS), processes commands, runs simulation, publishes snapshots

### Simulation Tick Ordering

Each tick in the background thread runs in this order:
1. `update_docking!` -- advance docking animations
2. `update_manoeuvre_phase!` -- manoeuvre state machine transitions
3. `update_components!` -- tick all component behaviours
4. `update_map!` -- rebuild circuit graph (enumerate, prune, fluid propagation, MNA setup)
5. `update_mna!` -- solve circuit (node voltages, source currents)
6. `handle_thrusters!` -- sum thrust vectors, integrate velocity
7. `step_space_map_time!` -- advance encounter system
8. Deep-copy all state and publish `FlowCalculatorSnapshot`

### Command System

The render thread **never directly mutates `GameMap`**. All changes flow through typed `MapEditCommand` subtypes:
`SetTileCommand`, `SetPipeBehaviorCommand`, `MoveCommand{T}`, `DeleteAtCommand{T}`, `ClickTileCommand`, `DoActionCommand`, `AddShipSurfaceCommand`, `RemoveShipSurfaceCommand`, `MapOverrideCommand`, `AddEncounterShipCommand`, `RedockShipCommand`.

Commands are enqueued via `try_enqueue_command!`. Processing uses sandbox validation (deep-copy trial run) before applying to the real map.

### Snapshot-Based Decoupling

After each tick, the background thread deep-copies all state into a `FlowCalculatorSnapshot` and publishes via a lock-guarded `Ref`. The render thread reads the latest snapshot each frame.

---

## Rendering System

**Four render programs:**

| Program | Effect |
|---------|--------|
| `BaseSpriteRenderProgram` | General textured sprites with horizontal clipping |
| `LiquidSpriteRenderProgram` | Animated fBm noise-based liquid flow |
| `GasSpriteRenderProgram` | Animated blocky pixel-noise gas effect |
| `ParticleRenderProgram` | Points to billboarded quads via geometry shader |

**Render helper functions**: `render_basic_tile`, `render_basic_pipe`, `render_basic_sprite`, `render_liquid_tile`, `render_gas_tile`, `render_liquid_sprite`, `render_gas_sprite`, `render_beam!`, `render_pipe`, `setup_basesprite_uniforms`. Most return `RenderCommand`; `render_pipe` returns `Vector{RenderCommand}` and `render_beam!` pushes to a queue.

**Render height constants** (ascending Z-order, defined in `HexFlowRendering`, not exported -- use `HexFlowRendering.RENDER_HEIGHT_*`):

| Constant | Value | Purpose |
|----------|-------|---------|
| `RENDER_HEIGHT_TRACTOR_BEAM` | -1100 | Docking beam visuals |
| `RENDER_HEIGHT_BACKGROUND` | -1000 | Ship surface tiles |
| `RENDER_HEIGHT_PIPE_BASE` | -10 | Base pipe sprite |
| `RENDER_HEIGHT_PIPE` | 0 | Pipe fluid mask |
| `RENDER_HEIGHT_COMPONENT_BEHIND` | 1000 | Behind-component art (fluid masks, energy bars) |
| `RENDER_HEIGHT_COMPONENT_STATIC` | 2000 | Static component sprites |
| `RENDER_HEIGHT_COMPONENT_ANIM` | 3000 | Animated overlays (flames, smoke) |
| `RENDER_HEIGHT_NODE` | 100000 | Node vertices |
| `RENDER_HEIGHT_OVERLAY_BASE` | 101000 | UI overlays (stall icons) |

Ghost previews use `render_height_offset = Int32(100000)`. See `src/render_height.md` for full documentation.

**Asset loading modes** (detected via `isdefined(Main, :Revise)`):
- Dev mode: shader/texture paths point to source files for hot-reload
- Production mode: paths resolved from `Artifacts.toml`

---

## Component System

Components use a **fragment composition** pattern. Complex behaviours are built from small reusable `*BehavFrag` structs. Concrete types (`*CompBehav` for tiles, `*PipeBehav` for edges) compose fragments and delegate interface methods. See `local_packages/components/component_module_guide.md` for the full authoring guide.

### ComponentBehavior Interface (tile-placed)

**Mandatory methods:**
- `produce_rel_elements(behav)` -- declare circuit elements in tile-local coordinates
- `get_tunables(behav)` -- expose editable parameters for the properties UI
- `set_tunables(behav, tunables)` -- return new instance with updated values (immutable update via `@set`)
- `render_base_elem!(queue, behav; glmap, rotation, position, pos_offset, render_height_offset, kwargs...)` -- push render commands

**Optional methods** (with sensible defaults): `render_map_elem!`, `get_fluidtags`, `update_flowbehav!`, `on_click!`, `get_thrust`, `collect_effect_particles!`, `map_rotation`, `can_be_moved`, `placement_valid`, `get_component_dry_mass`, `get_component_wet_mass`, `get_component_mass`, `get_actions`, `do_action!`.

### PipeBehavior Interface (edge-placed)

**Mandatory methods:** `get_conductance`, `get_pipe_tunables`, `set_pipe_tunables`, `render_pipe_base!`

**Optional methods:** `render_pipe_map!`, `get_pipe_fluidtags`, `can_pipe_be_moved`, `produce_abs_elements`, `get_tile_pipe_equivalent`.

### Existing Components

Concrete instances defined in `src/components.jl` (`component_list` has 15 entries):
- **Tanks**: `TriGasTank`, `TriLiquidTank` (both `ThevininTankCompBehav`), `PressureFedLiquidTank` (`PressureFedTankCompBehav`)
- **Nozzles**: `TinyNozzle`, `SmallNozzle`, `MediumNozzle`, `SwitchedTinyNozzle`, `BasicDecompChamber`
- **Pumps**: `TurboPump`, `ElecTurboPump`, `ElecTransferPump`
- **Valves**: `LargeAdjValve`, `TinyAdjValve` (stepped), `LargeOnOffValve`, `TinyOnOffValve` (bool) — all `StandardValveCompBehav{S,V}`
- **Pipes (edge)**: `ScrapPipe` (2.0 S), `BigPipe` (10.0 S)

---

## Running the Project

### Development (recommended)

```shell
julia --project=. --threads=2,1 --gcthreads=1,1 src/repl_launch.jl
```

Uses Revise for hot-reloading. The FlowCalculator runs on a background thread -- **at least 2 threads are required**. Running the launch script after making changes is the primary way to surface compile-time and runtime errors, unless told otherwise.

### Production

```shell
julia --project=. --threads=2,1 --gcthreads=1,1 src/julia_main.jl
```

No Revise. Verifies required artifacts before loading. Defines `@main` for JuliaC compilation.

### Texture Packer

```shell
cd tools/TexturePacker
julia --project=. src/TexturePacker.jl textures outputs/TileTextureAtlas1
```

### Package Tests

```shell
cd local_packages/<PackageName>
julia --project=. -e "using Pkg; Pkg.test()"
```

Packages with tests: `FlowMap`, `FlowEngine`, `HexFlowCalculator`, `HexFlowProcGen`, `HexFlowRendering`, `HexFrame`, `HexFluids`, `HexFlowLearningSystem`, `SquirrelNoise`.

**Note:** the app requires OpenGL/GLFW/system libs and CImGui bindings. Running the UI from headless CI will fail.

---

## What to Check When Editing

### Modifying Render Programs
- Update the program singleton type, uniform struct, and `uniforms_type` mapping
- Uniform struct field names must match GLSL uniform names exactly
- Call `setup_glprog!` to compile and discover uniform locations
- Don't change shader attribute layouts without updating `VboAttribFormat` and VAO callers

### Adding Sprites/Textures
- Add source PNGs to `tools/TexturePacker/textures/`
- Run the texture packer to regenerate the atlas and JSON
- `setup_glsprite!` loads metadata from the atlas JSON
- Access via `getdata_glsprite(g_globjmap, :SpriteName)`

### Adding Components
- See `local_packages/components/component_module_guide.md` for the full authoring guide
- Create a new package under `local_packages/components/`
- Follow fragment composition pattern: define `*BehavFrag` structs, compose into `*CompBehav`
- All 4 mandatory interface methods must be implemented
- Register `roll_component(::Val{:YourKind}, ...)` in `src/components.jl` for proc-gen support
- Add concrete instances to `src/components.jl`

### Modifying Public APIs
- When modifying exported struct fields or function signatures, search for the symbol across the entire repo -- packages re-export and `using` each other extensively
- JLD2 serialisation may need reconstruction hooks in `src/map_loading.jl` when load-time control is required

### Circuit/Electrical Changes
- Preserve pruning/ground-search ordering in `FlowEngine`: `prune` then `ground_search` then `clear_dangling_dependants`
- The iterative prune loop in `update_map!` runs until hash-convergence
- Adding new `ElementTypes` requires updating MNA matrix stamping (`MNA_getA`, `MNA_getZ`) and `abs_element_get_current`

### Modifying GameMap/Save-Related Structs
- Adding fields to `GameMap` or types stored within it (e.g., `TutorialState`) requires a JLD2 `rconvert` reconstruction hook in `src/map_loading.jl` if you need older saves to keep loading
- Struct defaults alone are not sufficient when loading files that predate the new field
