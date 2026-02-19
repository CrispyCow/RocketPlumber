# Rocket Plumber — AI Agent Instructions

Rocket Plumber (working title: HexFlow, still prevalent throughout the codebase) is a spaceship-building simulation game with deep fluid mechanics modelled on circuit simulation. Players construct ships from pipes and components on a hex grid, then fly them to destinations in space with realistic manoeuvre dynamics.

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
- `HexComponentsAPI` — abstract interfaces for `ComponentBehavior` and `PipeBehavior`, `ComponentOnTile` wrapper, `TunableProps`
- `FlowMap` — data model (`GameMap`, `ShipMap`), ship management, docking system, space map, encounter/manoeuvre types, placement validation, bounds/geometry
- `FlowEngine` — MNA (Modified Nodal Analysis) circuit solver, `DerivedMapState`, `MNA_State`, graph pruning, fluid tag propagation. Re-exports `FlowMap`.

**Application State:**
- `HexFlowControl` — `GameState`, `InputState`, `ViewState`, `PlacementModes` enum, view transform matrix, input edge-detection helpers, closure-based console buffer

**Simulation:**
- `HexFlowCalculator` — background-thread simulation loop, command system (`MapEditCommand` subtypes), `FlowCalculatorSnapshot`, `FlowCalculatorIPC`, `update_map!`/`update_mna!` orchestration, manoeuvre phase state machine

**Procedural Generation:**
- `HexFlowProcGen` — ship surface generation (random tile walks), component/pipe placement strategies, encounter point system (spawn/recycle/event queue), manoeuvre planning (closest-approach, intercept ΔV), ship generation configs

**Rendering:**
- `RenderEngine` — low-level OpenGL abstraction (`GLObjectMap`, `RenderCommand`, typed shader programs, VAOs, textures, UBOs, sprites)
- `HexFlowRendering` — game-specific rendering (4 render programs, sprite/tile/pipe helpers, particle system, animation functions, render height constants, GLSL shaders)
- `HexFlowTelemetry` — diagnostic `TimerOutput` instances and tick-gated printing

**Component Implementation Packages** (under `local_packages/components/`):
- `HexFlowBasicComponents` — reusable fragments (`PlainSpriteBehavFrag`, `BasicElemBehavFrag`, `StallBehavFrag`, `BinaryStateBehavFrag`, `FloatStateBehavFrag`) and `BasicCompBehav`
- `HexFlowTankComponents` — gas/liquid tanks with Thévenin equivalent circuits, charge tracking, stall protection
- `HexFlowNozzleComponents` — nozzles, switched nozzles, decomp chambers with thrust calculation and particle exhaust
- `HexFlowPumpComponents` — turbopumps (gas-driven) and electric pumps (battery-powered) with energy management
- `HexFlowSwitchComponents` — binary switches and adjustable valves with exponential open/close dynamics
- `HexFlowPipeComponents` — tile-based pipe components (`ScrapTilePipeCompBehav`, `BigTilePipeCompBehav`)
- `HexFlowBasicPipes` — edge-based pipe behaviours (`ScrapPipeBehav`, `BigPipeBehav`)

### Tools
- `tools/TexturePacker/` — sprite atlas generator: trims transparency, packs PNGs into atlas + JSON metadata
- `tools/map_encoder/` — JLD2 map ↔ human-readable text converter and AI-generated map validator

### Top-Level Source Files (`src/`)
- `repl_launch.jl` — development entry point (Revise, loading screens, hot-reload)
- `julia_main.jl` — production entry point (no Revise, artifact verification, `@main` for JuliaC)
- `gameloop.jl` — main game loop: GL init, map load/save (JLD2), snapshot management, rendering pipeline, FlowCalculator IPC
- `interactions.jl` — all input handling: keyboard/mouse polling, cursor transforms, click detection, placement ghost rendering, docking beam rendering, FlowCalculator command enqueueing
- `components.jl` — concrete component/pipe instances, procedural generation `roll_component`/`roll_pipe` specialisations, ship generation configs and weights
- `ui_common.jl` — shared UI constants, ImGui typed input helpers, formatting utilities
- `ui_game.jl` — in-game ImGui windows: inspector (dispatched on coord type), velocity tracker, toolbar, property box, space map overlay with encounter planning
- `ui_menus.jl` — pause menu, developer utilities (proc gen tools, docking viewer), tutorial hint box
- `startmenu.jl` — main menu loop (New Map, Load Map, Demo, Quit)
- `demo.jl` — 8 tutorial levels with pre-built maps and progressive hint text
- `initial_window_setup.jl` — GLFW window creation, OpenGL context, CImGui/ImPlot setup, scroll/FPS callbacks
- `demo_maps/mapgen_*.jl` — 10 map generator functions for tutorial levels

---

## Data Model

### Game Map (Multi-Ship)

- **`GameMap`** (in `FlowMap`): top-level container with `ships::Dict{Symbol, ShipMap}` (always has `:primary`) and `space_map::AbstractSpaceMap`
- **`ShipMap`**: per-ship data with:
  - `components::Dict{TileCoord, ComponentOnTile}` — tile-placed components
  - `pipe_behaviors::Dict{EdgeCoord, PipeBehavior}` — edge-placed pipes
  - `ship_tiles::Set{TileCoord}` — ship surface (valid placement area)
  - `docking_status::DockingStatus` — docking animation state

Ship management: `add_ship!`, `remove_ship!`, `get_all_ship_names`, `has_ship`, `get_ship`, `offset_ship!`.
Multi-ship queries: `has_component_any_ship`, `get_component_any_ship`, `find_ship_for_surface`, `find_valid_ship_for_placement`, `find_ship_with_component`, `find_ship_with_pipe`, `find_ship_for_node`, `would_bridge_ships`.

### Derived State (rebuilt each simulation tick)

- **`DerivedMapState`** (in `FlowEngine`): `allelements` / `prunedelements` (circuit element vectors), `allnodes` / `prunednodes` (node counts), `nodeconnections` (adjacency map using `SmallVector{12}`), `nodeprimefluidtags` / `nodeactualfluids` (fluid tags before/after propagation), `ship_surface_edge` (boundary tiles)
- **`MNA_State`** (in `FlowEngine`): `node_to_index` / `index_to_node` (bidirectional mapping), element partitions (`resistors`, `csources`, `vsources` dicts keyed by `ElementID`), `mat_A` (LU-decomposed), `mat_Z` (excitation vector), solved `node_voltages` / `vsource_currents`, `node_voltages_scaled` (normalised for rendering)

### Coordinate System (HexFrame)

Four coordinate systems for flat-top hexagonal grids:
- **`CartesianCoord`** (x, y :: Float64) — screen/world space (1.0 = hex centre to vertex)
- **`TileCoord`** (q, r :: Int16) — integer axial, identifies a hex tile
- **`AxialCoord`** (q, r :: Float64) — continuous axial for sub-tile precision
- **`VertexCoord`** (tile :: TileCoord, dir :: HexAxis) — hex vertex, canonicalised via `to_proper` to `Q_POS` or `Q_NEG`
- **`EdgeCoord`** (v1, v2 :: VertexCoord) — hex edge between two vertices
- **`NodeCoord`** (tile :: TileCoord, dir :: NodePos) — circuit node (6 axis directions + `NODE_INTERNAL` + `GROUND`)

All basic coord types are `FieldVector{2}`, enabling direct matrix multiplication with `StaticArrays`. Promotion: `TileCoord → AxialCoord → CartesianCoord`.

`HexAxis` enum (UInt8): `Q_POS=0, R_NEG=1, S_POS=2, Q_NEG=3, R_POS=4, S_NEG=5` — forms Z/6Z rotation group. Each increment = 60°. Rotation is modular addition.

Key functions: `to_cartesian`, `to_axial`, `round_to_tile`, `round_to_edge`, `glvec` (→ `SVector{2, Float32}` for OpenGL), `to_proper` (canonical form), `get_edges`, `get_tiles`, `get_adjacent_tiles_for_tile`, `get_adjacent_tiles_for_node`.

### Circuit Elements (HexElements)

Components define circuit contributions via `RelativeElement` (tile-local coordinates, produced by `produce_rel_elements`). These are mapped to `AbsoluteElement` (map-global coordinates) via `map_element()` / `produce_abs_elements()`, which applies rotation and assigns `ElementID`.

Five element types (`ElementTypes` enum): `CONST_RESISTOR` (value = conductance), `CONST_CURRENT`, `CONST_VOLTAGE`, `C_DEP_CURRENT` (CCCS with gain), `V_DEP_VOLTAGE` (VCVS with gain).

### Fluid System (HexFluids)

`FluidTags` enum with bitmask encoding: bit 7 = gas, bit 6 = liquid, bit 5 = behaviour (wildcard). Concrete types: `COLD_GAS`, `MONOPROP_LIQUID`, `MONOPROP_GAS`. Behaviour types: `ANY_GAS`, `ANY_LIQUID`. Classification: `is_gas()`, `is_liquid()`, `is_behavior()`. Resolution via `prioritise_fluidtag()` — concrete beats behaviour, incompatible fluids error.

Components declare fluid expectations via `get_fluidtags() → NodeFluidTags` (per-node-position tags). During simulation, tags propagate through connected nodes via `connect_fluidtags!`.

### Space Map and Encounters

- **`AbstractSpaceMap`**: `SpaceMapEmpty` (velocity only, used for tutorials) or `SpaceMapState` (full simulation with seed, position, time, encounters, manoeuvres, event queue)
- **`EncounterPoint`**: ship on a linear trajectory with base velocity, position, spawn time, and ship-type seed for proc-gen. Recycled when crossing spawn/disappear lines.
- **`EncounterEvent`**: time-ordered event in a `BinaryMinHeap` for encounter line crossings
- **`ManoeuvreData`**: intercept manoeuvre with 5-phase state machine: `PHASE_WAIT_APPROACH → PHASE_MAIN_BURN → PHASE_COAST → PHASE_DECEL_BURN → PHASE_ENCOUNTER_READY`. Tracks `burn_target_dv` / `burn_remaining_dv` in ship-space, `main_burn_dv` / `decel_burn_dv` in space-map-space.

### Docking System

Three `DockingStatus` subtypes:
- `ConnectedDockStat` — docked, no render offset
- `ApproachingDockStat` — animating towards dock (proximity-eased `RenderPosOffsetState`)
- `DepartingDockStat` — animating away; ship removed from `GameMap` when complete

State machine in `update_docking!`. Render offsets affect rendering via `get_ship_render_offset` / `get_render_offset`.

---

## Runtime Architecture

### Two-Thread Model

- **Main thread**: GLFW event polling → OpenGL rendering (`custom_rendering!`) → CImGui UI (`ui_rendering!`) → input handling (`user_handler!`)
- **Background thread**: `flowcalculator_loop!` — fixed-timestep accumulator (target 60 UPS), processes commands, runs simulation, publishes snapshots

### Simulation Pipeline (each tick in `flowcalculator_loop!`)

```
gamestate.ticks += 1
update_docking!(gamemap)                        # advance docking animations
update_components!(gamemap, mna_state)          # tick all component behaviours (tanks read current, switches update conductance, etc.)
update_map!(gamemap, derived, mna, tick)         # rebuild circuit graph:
  ├─ find_ship_surface_edgetiles!               # boundary tiles
  ├─ list_elements → list_nodes                 # enumerate circuit
  ├─ iterative: prune → ground_search → clear_dangling_dependants (until hash-stable)
  ├─ fluidtag_nodes → build_node_connection_map! → connect_fluidtags!
  └─ MNA_indexnodes → MNA_splitelements! → MNA_getA (LU decompose)
update_mna!(derived, mna, tick)                  # solve circuit:
  ├─ MNA_getZ → MNA_solve → node_voltages, vsource_currents
  └─ scale_voltage_dict (normalise for rendering)
handle_thrusters!(gamestate, gamemap, mna)       # sum thrust vectors, compute acceleration, integrate velocity
step_space_map_time!(space_map)                  # advance encounter system (events, line shifts)
update_manoeuvre_phase!(gamestate, gamemap)       # phase transitions for active manoeuvre
→ deep-copy all state → publish FlowCalculatorSnapshot
```

### Command System

The render thread **never directly mutates `GameMap`**. All changes flow through typed `MapEditCommand` subtypes:
- `SetTileCommand`, `SetPipeBehaviorCommand` — placement
- `MoveCommand{TileCoord}`, `MoveCommand{EdgeCoord}` — move with delta rotation
- `DeleteAtCommand` — deletion at any coord type
- `ClickTileCommand` — component interaction (with unrotated click site)
- `AddShipSurfaceCommand`, `RemoveShipSurfaceCommand` — surface editing
- `MapOverrideCommand` — full map replacement (for proc-gen, map loading)

Commands are created via factory functions (`create_set_tile_command`, etc.), enqueued via `try_enqueue_command!` into a bounded `Channel{MapEditCommand}` (capacity 32). Processing: sandbox validation (deep-copy trial run) → apply to real map or reject.

### Snapshot-Based Decoupling

After each simulation tick, the background thread deep-copies all state into a `FlowCalculatorSnapshot` (gamemap, derived, mna, gamestate, timestamp) and publishes via a lock-guarded `Ref`. The render thread reads the latest snapshot each frame — no further synchronisation needed.

`FlowCalculatorIPC` bundles all inter-thread communication: `FlowCalculatorSharedState` (atomic flags: `should_exit`, `is_paused`, `target_ups`, `actual_ups`), `CommandQueue`, `set_snapshot`/`get_snapshot` closures, `console_push`/`console_see` closures.

### Rendering Pipeline

```
custom_rendering!()
  ├─ background particles (thrust dust)
  ├─ ship_surface_queued_render!             # surface tiles with per-ship colour tint
  ├─ render_docking_beams!                   # tractor beams between ships (colour by status)
  ├─ tile_queued_render!                     # all components via render_map_elem!
  ├─ render_cursor_ghosts!                   # semi-transparent placement previews
  ├─ pipe_queued_render!                     # all pipes via render_pipe_map!
  ├─ node_queued_render!                     # circuit nodes with voltage-mapped colour
  └─ foreground particles (exhaust, effects)
→ commands sorted by (draw_height, program_type, VAO) → glrender batch draw
```

### Map Load/Save

JLD2 serialisation with multiple legacy format fallbacks via `rconvert` registrations and `JLD2.Upgrade` typemaps (maps old `FlowEngine.*` types to `FlowMap.*`).

---

## Rendering System

### RenderEngine (Low-Level GL Abstraction)

- **Programs** represented by zero-sized singleton types: `struct MyProg <: AbstractRenderProgram end`. Each program has a matching uniform struct `MyUniforms <: AbstractRenderUniforms{MyProg}` where **field names must match GLSL uniform names exactly**. Register mapping via `uniforms_type(::Type{MyProg}) = MyUniforms`.
- **`RenderCommand{P,U}`**: constructed as `RenderCommand(uniforms, :VAOName, draw_height::Int32)` — program type is automatically inferred from the uniforms type parameter.
- **`GLObjectMap`**: central registry. Programs keyed by singleton instance; textures, UBOs, sprites keyed by `Symbol`. VAOs are nested inside program data (static and dynamic). Textures auto-assign to sequential GL texture units (0–14; unit 15 = scratchpad).
- **`GLId{K}`**: phantom-typed wrapper around raw `GLuint` IDs preventing accidental type confusion.
- **`VboAttribFormat`**: describes vertex attribute layout (name, component count, GL type, normalised). Tightly packed, `GLfloat`-sized components assumed.
- **Setup functions**: `setup_glprog!` (compile shaders + discover uniform locations), `setup_gltex!` (upload image + auto-assign unit), `setup_glubo!` (allocate UBO), `setup_static_glvao!` (upload fixed geometry), `setup_dynamic_glvao!` (allocate updatable VBO), `setup_glsprite!` (load atlas JSON metadata with UV flipping for GL's bottom-left origin).
- **`glrender`**: batch render sorts by `(draw_height, program_type, VAO)` for state-change minimisation, then issues `glDrawElements` per command.

### HexFlowRendering (Game-Specific)

**Four render programs:**

| Program | Shaders | Effect |
|---------|---------|--------|
| `BaseSpriteRenderProgram` | BaseTile.vert + BaseTile.frag | General textured sprites with horizontal clipping |
| `LiquidSpriteRenderProgram` | BaseTile.vert + BaseTile_LiquidEffect.frag | Animated fBm noise-based liquid flow |
| `GasSpriteRenderProgram` | BaseTile.vert + BaseTile_GasEffect.frag | Animated blocky pixel-noise gas effect |
| `ParticleRenderProgram` | particle.vert + particle.geom + particle.frag | Points → billboarded quads via geometry shader |

**Render helper functions** (return `RenderCommand`): `render_basic_tile`, `render_basic_pipe`, `render_basic_sprite`, `render_liquid_tile`, `render_gas_tile`, `render_liquid_sprite`, `render_gas_sprite`, `render_beam!`, `render_pipe` (2-command: base + fluid mask).

**Render height constants** (ascending Z-order, defined in `HexFlowRendering`, not exported — use `HexFlowRendering.RENDER_HEIGHT_*`):

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

**Particle system**: `Particle` (immutable: position, velocity, creation/vanishing time) → `ParticleGroup` (mutable: `StructArray{Particle}` + colour + size) → `ParticleManager` (colour-keyed groups dict + cull buffer). Uses `StructArray` for SoA layout enabling zero-copy VBO upload via `reinterpret`. CPU-side viewport + ship-surface culling before upload. Max 10000 particles per draw batch.

**Animation helpers**: `animation_sprite_picker(sprites_tuple, gameticks, speed_div)`, `animation_vibe_offset(gameticks; speed, magnitude, octaves)`, `animation_rotate(gameticks, speed)`.

**GL init functions**: `viewtransform_glubo_init`, `set_view_ubo`, `texatlas1_gltex_init`, `basesprite_glprog_init`, `liquidsprite_glprog_init`, `gassprite_glprog_init`, `particle_glprog_init`.

**Asset loading modes** (detected via `isdefined(Main, :Revise)` in `__init__`):
- Dev mode: shader/texture paths point to source files for hot-reload
- Production mode: paths resolved from `Artifacts.toml` (keys: `"shaders"`, `"texture_atlas"`)

---

## Component System

### Architecture

Components use a **fragment composition** pattern. Complex behaviours are built from small reusable `*BehavFrag` structs that each handle a subset of the interface. Concrete types (`*CompBehav` for tiles, `*PipeBehav` for edges) compose fragments and delegate interface methods to them.

### ComponentBehavior Interface (tile-placed)

**Mandatory methods:**
- `produce_rel_elements(behav) → NTuple{N, RelativeElement}` — declare circuit elements in tile-local coordinates
- `get_tunables(behav) → NTuple{N, TunableProps}` — expose editable parameters for the properties UI
- `set_tunables(behav, tunables) → T` — return new instance with updated values (immutable update)
- `render_base_elem!(queue, behav; glmap, rotation, position, render_height_offset, kwargs...)` — push render commands

**Optional methods** (with sensible defaults): `render_map_elem!` (live rendering, defaults to `render_base_elem!`), `get_fluidtags`, `update_flowbehav!`, `on_click!`, `get_thrust`, `collect_effect_particles!`, `map_rotation`, `can_be_moved`, `placement_valid`.

### PipeBehavior Interface (edge-placed)

**Mandatory methods:** `get_conductance`, `get_pipe_tunables`, `set_pipe_tunables`, `render_pipe_base!`

**Optional methods:** `render_pipe_map!`, `get_pipe_fluidtags`, `can_pipe_be_moved`, `produce_abs_elements` (default creates single resistor from conductance), `get_tile_pipe_equivalent`.

### ComponentOnTile Wrapper

All placed components are wrapped in `ComponentOnTile(component::ComponentBehavior, rotation::HexAxis)`, stored in `ShipMap.components`. Delegates all interface methods to the inner component, injecting `rotation` into kwargs. `on_click!` additionally transforms `unrotated_clicksite` → `relative_clicksite` via the rotation matrix.

### Key Component Patterns

- **Mutable state isolation**: all mutable state lives in dedicated mutable structs (`TankState`, `SwitchState`, `BinaryStateBehavFrag`, `FloatStateBehavFrag`), while component structs are immutable. Shared references survive `set_tunables` reconstruction.
- **Immutable updates**: `set_tunables` returns a new instance via `@set` from Accessors.jl.
- **Kwargs delegation**: always forward `kwargs...` without re-specifying defaults.
- **Stall/unstall**: tanks and nozzles use `StallBehavFrag` to disable circuit elements on invalid states (negative charge/pressure). User clicks to unstall.
- **Element index constants**: define module-local `const` values to reference specific elements by index (e.g., `const tank_vsource_element_index = 1`).
- **Fluid-aware rendering**: components with fluid masks dispatch to `LiquidSpriteRenderProgram` / `GasSpriteRenderProgram` / `BaseSpriteRenderProgram` based on `derivedmapstate.nodeactualfluids`.

### Existing Components

Concrete instances defined in `src/components.jl`:
- **Tanks**: `TriGasTank` (linear V-Q, 3-port), `TriLiquidTank` (near-constant voltage, 3-port) — both `ThevininTankCompBehav` with series resistors
- **Nozzles**: `TinyNozzle`, `SmallNozzle`, `MediumNozzle` (basic), `SwitchedTinyNozzle` (solenoid-switched), `BasicDecompChamber` (liquid→gas conversion with dependent sources)
- **Pumps**: `TurboPump` (gas-driven with dependent current source), `ElecTurboPump` (battery + rotor), `ElecTransferPump` (battery + transfer)
- **Valves**: `BigAdjustableValve` (log-scale stepped, click position-based control)
- **Pipes (edge)**: `ScrapPipe` (2.0 S), `BigPipe` (10.0 S)

`component_list::Vector{ComponentBehavior}` — 11 components indexed by toolbar scroll wheel.

For detailed component creation guidance: `local_packages/components/component_module_guide.md`.

---

## Running the Project

### Development (recommended)

```shell
julia --project=. --threads=2 src/repl_launch.jl
```

Uses Revise for hot-reloading. The FlowCalculator runs on a background thread — **at least 2 threads are required**. Running the launch script after making changes is the primary way to surface compile-time and runtime errors, unless told otherwise.

### Production (pre-compilation testing)

```shell
julia --project=. --threads=2 src/julia_main.jl
```

No Revise. Verifies required artifacts (`shaders`, `texture_atlas`) before loading. Defines `@main` for JuliaC compilation.

### Texture Packer

```shell
cd tools/TexturePacker
julia --project=. src/TexturePacker.jl textures outputs/TileTextureAtlas1
```

Options: `--pack-method rect|row`, `--padding N`.

### Map Encoder

```shell
# Encode map to readable format
julia --project=. tools/map_encoder/encode_map.jl maps/simpleship1.jld2

# Generate mapgen function
julia --project=. tools/map_encoder/encode_map.jl maps/simpleship1.jld2 mapgen_out.jl

# Validate generated mapgen against original
julia --project=. tools/map_encoder/compare_maps.jl maps/simpleship1.jld2 src/demo_maps/mapgen_simpleship1.jl
```

### Package Tests

```shell
cd local_packages/HexFrame
julia --project=. -e "using Pkg; Pkg.test()"
```

**Note:** the app requires OpenGL/GLFW/system libs and CImGui bindings. Running the UI from headless CI will fail.

---

## Coding Style and Conventions

### Spelling and Language

Use **Australian English** spellings throughout (e.g., "colour", "behaviour", "manoeuvre", "initialise").

### Documentation

- **Docstrings over inline comments** for function/type documentation.
  - Single-line: `"Description here"` (single quotes to save vertical space)
  - Multi-line: `"""Description here"""`
- **Base function extensions** (`Base.convert`, `Base.promote_rule`, `Base.:+`, etc.): always include docstrings explaining the behaviour — the implementation alone can be confusing.
- **Inline comments** should convey intent and explain complex logic, not narrate obvious operations.

### Comment Style

The appropriate level of commenting depends on code complexity:

- **Simple functions** (getters, conversions): rely on docstrings, minimal inline comments
- **Intermediate complexity** (rendering helpers, data manipulation): comment unintuitive operations and edge cases
- **Complex algorithms** (graph traversal, MNA solver, physics): keep substantial explanatory comments describing the mathematical/algorithmic concepts

**Comment placement guidelines:**
- Single line of code → inline (same line) after the code
- Few lines (2–5) → comment on its own line above the block
- Larger sections → block comments `#= ... =#`

**Comment consolidation**: replace multiple single-line comments with one describing the block; move single-line explanations inline; keep "why" comments, remove "what" comments that restate obvious code.

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

### Code Quality

- **Readability over performance** outside hot inner loops.
- **Idiomatic Julia**: use dispatch, iterators, and standard library functions (`map`, `filter`, `filter!`, `copyto!`) where they improve clarity.
- **Early returns and guard clauses** to reduce nesting depth.
- **Extract duplicate code** into helper functions when it improves maintainability.
- **Functional patterns**: prefer `filter!`, `copyto!`, stdlib functions over bespoke loops when simpler.
- **Accessor functions**: use `get_component`, `get_ship`, etc. when available instead of direct dict/struct access for better error messages and future flexibility.

### Performance

- **Hot inner loops** (MNA matrix stamping per-element, particle physics per-particle): minimise allocations. Prefer in-place operations, pre-allocated buffers, `sizehint!`. An allocation that occurs once per element/particle in an inner loop called every tick matters.
- **Outer loops** (once per frame/tick): allocations are acceptable — don't over-optimise.
- **Type stability**: important in hot loops. Only suggest easy wins that don't change interfaces; note complex optimisations for future benchmarking passes.
- **Allocation-conscious data structures** in hot paths: `SmallVector` (SmallCollections.jl), `Dict` with `sizehint!`, sparse matrices.
- Much of the codebase allocates more than necessary. This will be addressed in a future benchmarking-driven pass. Don't over-optimise code outside hot inner loops.

### Naming Conventions

- `*BehavFrag` — reusable behavioural fragments (do not subtype `ComponentBehavior`/`PipeBehavior`)
- `*CompBehav` — concrete tile-placed component behaviours (subtype `ComponentBehavior`)
- `*PipeBehav` — concrete edge-placed pipe behaviours (subtype `PipeBehavior`)
- `*DockStat` — docking status subtypes

---

## Key Files for Common Tasks

| Task | Files |
|------|-------|
| Game loop and integration | `src/repl_launch.jl`, `src/gameloop.jl` |
| Window/GL initialisation | `src/initial_window_setup.jl` |
| Input handling and interactions | `src/interactions.jl` |
| Start menu and demo system | `src/startmenu.jl`, `src/demo.jl` |
| Demo map generators | `src/demo_maps/mapgen_*.jl` |
| Application state types | `local_packages/HexFlowControl/src/HexFlowControl.jl` |
| Simulation loop, commands, map updates | `local_packages/HexFlowCalculator/src/HexFlowCalculator.jl` |
| Data model (GameMap, ShipMap, space map, docking) | `local_packages/FlowMap/src/FlowMap.jl` |
| Circuit solver (MNA), derived state | `local_packages/FlowEngine/src/FlowEngine.jl` |
| Coordinate system and hex geometry | `local_packages/HexFrame/src/HexFrame.jl` |
| Circuit element types | `local_packages/HexElements/src/HexElements.jl` |
| Fluid tag system | `local_packages/HexFluids/src/HexFluids.jl` |
| Component/pipe interfaces | `local_packages/components/HexComponentsAPI/src/HexComponentsAPI.jl` |
| Component implementations | `local_packages/components/HexFlow*Components/src/*.jl` |
| Component instances and ship configs | `src/components.jl` |
| Low-level GL abstraction | `local_packages/RenderEngine/src/RenderEngine.jl` |
| Game rendering, particles, shaders | `local_packages/HexFlowRendering/src/HexFlowRendering.jl` |
| Shaders (GLSL) | `local_packages/HexFlowRendering/src/shaders/` |
| Render height documentation | `src/render_height.md` |
| Procedural generation and encounters | `local_packages/HexFlowProcGen/src/HexFlowProcGen.jl` |
| Noise/RNG utilities | `local_packages/SquirrelNoise/src/SquirrelNoise.jl` |
| Telemetry/diagnostics | `local_packages/HexFlowTelemetry/src/HexFlowTelemetry.jl` |
| In-game UI (inspector, toolbar, space map) | `src/ui_game.jl`, `src/ui_common.jl` |
| Menu UI (pause, dev utils, hints) | `src/ui_menus.jl` |
| Texture packing tool | `tools/TexturePacker/src/TexturePacker.jl` |
| Map encoding/validation tools | `tools/map_encoder/encode_map.jl`, `tools/map_encoder/compare_maps.jl` |
| Component authoring guide | `local_packages/components/component_module_guide.md` |

---

## What to Check When Editing

### Modifying Render Programs
- Update the program singleton type, uniform struct, and `uniforms_type` mapping
- Uniform struct field names must match GLSL uniform names exactly
- Call `setup_glprog!` to compile and discover uniform locations
- Don't change shader attribute layouts without updating `VboAttribFormat` and `setup_static_glvao!` / `setup_dynamic_glvao!` callers

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
- When modifying exported struct fields or function signatures, search for the symbol across the entire repo — packages re-export and `using` each other extensively
- JLD2 serialisation may need legacy format handling (see `rconvert` registrations in `src/gameloop.jl`)

### Circuit/Electrical Changes
- Preserve pruning/ground-search ordering in `FlowEngine`: `prune` → `ground_search` → `clear_dangling_dependants`
- The iterative prune loop in `update_map!` runs until hash-convergence
- Adding new `ElementTypes` requires updating MNA matrix stamping (`MNA_getA`, `MNA_getZ`) and `abs_element_get_current`
- Prefer adding new typed fields to `MNA_State` rather than switching representations in-place (preserves type stability)

---

## Code Examples

### Creating a RenderCommand
```julia
uniforms = BaseSpriteUniforms(uv_offset=..., uv_scale=..., ...)
cmd = RenderCommand(uniforms, :UnitQuad_VAO, Int32(RENDER_HEIGHT_COMPONENT_STATIC))
```

### Render Helpers
```julia
render_basic_tile(glmap, :MySprite, rotation, position; colour=..., scale=..., draw_height=...)
render_liquid_tile(glmap, :FluidSprite, rotation, position; gameticks=..., draw_height=...)
render_basic_pipe(glmap, :PipeSprite, rotation, position; draw_height=...)
```

### Animation Functions
```julia
sprite = animation_sprite_picker((:frame1, :frame2, :frame3), gameticks, 10)
offset = animation_vibe_offset(gameticks; magnitude=2.0)
rotmat = animation_rotate(gameticks, 5.0)
```

### Component Delegation
```julia
render_base_elem!(queue, comp::MyComp; kwargs...) = render_base_elem!(queue, comp.sprite_frag; kwargs...)
produce_rel_elements(comp::MyComp) = produce_rel_elements(comp.elem_frag)
```

### GL Resource Access
```julia
getid_gltex(g_globjmap, :TileTextureAtlas1)    # texture ID
getdata_glsprite(g_globjmap, :MySprite)         # sprite UV/crop metadata
```

### Main Loop Sequence
```julia
update_components! → update_map! → update_mna! → tile_queued_render! → glrender
```
