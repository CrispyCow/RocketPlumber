# src/ — Top-Level Source Files

## Key Files

- `repl_launch.jl` — development entry point (Revise, loading screens, hot-reload)
- `auto_test_launch.jl` — non-interactive smoke-test entry point that boots into the gameplay loop and exits after a tick cap
- `julia_main.jl` — production entry point (no Revise, artifact verification, `@main` for JuliaC)
- `gameloop.jl` — main game loop: GL init, snapshot management, rendering pipeline, FlowCalculator IPC, learning system tick
- `map_loading.jl` — JLD2 serialisation and reconstruction hooks for current save formats
- `interactions.jl` — all input handling: keyboard/mouse polling, cursor transforms, click detection, placement ghost rendering, docking beam rendering, FlowCalculator command enqueueing
- `components.jl` — concrete component/pipe instances, `roll_component`/`roll_pipe` specialisations, ship generation configs and weights
- `tutorials.jl` — `LearningEntry` definitions for sandbox and in-game tutorials, demo map includes
- `ui_common.jl` — shared UI constants, ImGui typed input helpers, formatting utilities
- `ui_game.jl` — in-game ImGui windows: inspector (dispatched on coord type), velocity tracker, toolbar, property box, space map overlay with encounter planning
- `ui_galaxy_escape.jl` — exclusive Galaxy Escape victory report and its formatting/drawing helpers
- `ui_menus.jl` — pause menu, developer utilities (proc gen tools, docking viewer)
- `ui_learning.jl` — Learning Helper overlay and Tutorial Detail pane UI
- `recording.jl` — screen recording (FFmpeg H.264) and PNG screenshots, `RecordingState`, frame capture via `glReadPixels`
- `startmenu.jl` — main menu loop (Launch Teaser, New Game, Load Game, Tutorials, Quit), session state machine (`MapSession`/`SandboxSession` with level progression)
- `initial_window_setup.jl` — GLFW window creation, OpenGL context, CImGui/ImPlot setup, scroll/FPS callbacks
- `demo_maps/mapgen_*.jl` — map generator functions for tutorial levels (8 currently in use)

---

## Data Model

### Game Map (Multi-Ship)

- **`GameMap`** (in `FlowMap`): top-level container with:
	- `ships::Dict{Symbol, ShipState}` — always has `:primary`. Each `ShipState` carries docking and render-offset state. It is a lightweight container — it does **not** own components, pipes, or surface tiles.
	- `components::Dict{TileCoord, PlacedComponent}` — global components dict for the whole gamemap. Ownership is encoded on the value: `PlacedComponent.ship::Symbol`.
	- `pipe_behaviors::Dict{PipeCoord, PlacedPipe}` — global pipes dict. Ownership is encoded on the value: `PlacedPipe.ship::Symbol`.
	- `space_map::AbstractSpaceMap`, `learning_system::AbstractLearningSystem`.
- **`ShipBlueprint`**: detached construction payload used to build encounter ships, demo maps, and tile-by-tile generation. Carries its own `components` / `pipe_behaviors` dicts plus `ship_tiles`. Merged into a `GameMap` via `merge_ship!`.

Ship management: `add_ship!`, `remove_ship!`, `get_all_ship_names`, `has_ship`, `get_ship_state`, `merge_ship!`, `swap_primary!`, `get_ship_blueprint`, `offset_ship!`.

Cross-ship queries: `find_ships_adjacent_to_coord`, `find_ship_for_placement`, `find_ship_containing`, `get_surface_shiptag`, `get_component_shiptag`, `get_pipe_shiptag`, `find_ship_surface_containing_node`, `find_ship_pipes_containing_node`, `find_ship_for_node`, `is_on_surface_tile_any_ship`.

Component / pipe access (all routed off the global dicts; ownership is encoded on the value's `.ship` field):

- Single-coord: `get_component`, `has_component`, `set_component!`, `delete_component!`, and pipe equivalents. None take a `ship_name` kwarg — to filter by ship, read `.ship` on the returned `PlacedComponent` / `PlacedPipe`. To set with a specific ship, construct the wrapper with that ship: `PlacedComponent(behav, rot, ship)` / `PlacedPipe(behav, ship)`.
- Bulk: `get_components(gamemap)` and `get_pipes(gamemap)` return the underlying shared dicts. `count_components(gamemap; ship_name=...)` and `count_pipes(gamemap; ship_name=...)` provide zero-allocation counts and still accept `ship_name` as a filter.
- Lazy iteration: `each_component_of_ship(gamemap, ship_name)` / `each_pipe_of_ship(gamemap, ship_name)` for per-ship values, `each_component_of_type(gamemap, SomeBehav)` / `each_pipe_of_type(gamemap, SomePipeBehav)` for per-type values. If you need coords as well, filter `get_components(gamemap)` or `get_pipes(gamemap)` pairs rather than reaching into the backing fields directly.

### Coordinate System (HexFrame)

Six coordinate types for flat-top hexagonal grids:
- `CartesianCoord` — screen/world space (1.0 = hex centre to vertex)
- `TileCoord` — integer axial, identifies a hex tile
- `AxialCoord` — continuous axial for sub-tile precision
- `VertexCoord` — hex vertex, canonicalised via `to_proper`
- `PipeCoord` — canonical pipe segment between two vertices
- `NodeCoord` — circuit node (6 axis directions + `NODE_INTERNAL` + `GROUND`)

`HexAxis` enum: `Q_POS=0, R_NEG=1, S_POS=2, Q_NEG=3, R_POS=4, S_NEG=5` — forms Z/6Z rotation group; each increment = 60°.

### Fluid System (HexFluids)

**Type enums** (`UInt32` with bitmask encoding — upper 16 bits encode phase):
- `FluidType`: `COLD_GAS`, `MONOPROP_LIQUID`, `MONOPROP_GAS` (concrete fluids)
- `FluidConstraint`: `IS_GAS`, `IS_LIQUID` (phase-only constraints)
- `is_gas(ft)` / `is_liquid(ft)` work on both enums and `nothing`
- `nothing` replaces the old `NONE` sentinel throughout (e.g., `EncounterPoint.fuel_tag::Union{FluidType, Nothing}`)

**Fluid declarations** (all isbits types):
- `FluidSource(fluid_type, temperature)` — concrete fluid with source temperature
- `FluidTypeRule(fluid_type)` — concrete fluid type constraint (no source)
- `FluidConstraintRule(constraint)` — gas/liquid phase constraint
- `FluidDeclaration = Union{FluidSource, FluidTypeRule, FluidConstraintRule}`
- `RelativeFluidDeclaration` / `AbsoluteFluidDeclaration` — coordinate-wrapped versions

**Propagation:**
- `propagate_fluid_types!(derivedmapstate)` — BFS from source nodes, resolves per-node fluid types
- `compute_region_temperatures!(derivedmapstate, mna_state)` — flow-weighted average temperature per connected region
- Exhaust velocity: `v_e(T) = v_e_ref × √(T / T_ref)`

### Simulation Tick Order (background thread)

1. `update_docking!` — advance docking animations
2. `update_manoeuvre_phase!` — manoeuvre state machine transitions
3. `update_components!` — tick all component behaviours
4. `update_map!` — rebuild circuit graph (enumerate, prune, fluid type propagation, region temperatures, MNA setup)
5. `update_mna!` — solve circuit (node voltages, source currents)
6. `handle_thrusters!` — sum thrust vectors, integrate velocity
7. `step_space_map_time!` — advance encounter system
8. Deep-copy all state and publish `FlowCalculatorSnapshot`

### Space Map and Encounters

- `SpaceMapEmpty` (velocity only, tutorials; in `FlowMap`) or `SpaceMapState` (full simulation; in `HexFlowProcGen`)
- `ManoeuvreData`: 4 active phases — `PHASE_APPROACH_BURN`, `PHASE_COAST`, `PHASE_CAPTURE_BURN`, `PHASE_ENCOUNTER_READY`

### Docking System

Three `DockingStatus` subtypes: `ConnectedDockStat`, `ApproachingDockStat`, `DepartingDockStat`. State machine in `update_docking!`.

---

## Rendering System

**Four render programs:**

| Program | Effect |
|---------|--------|
| `BaseSpriteRenderProgram` | General textured sprites with two-axis texture-coordinate clipping |
| `LiquidSpriteRenderProgram` | Animated fBm noise-based liquid flow |
| `GasSpriteRenderProgram` | Animated blocky pixel-noise gas effect |
| `ParticleRenderProgram` | Points to billboarded quads via geometry shader |

**Render helpers**: `render_basic_tile`, `render_basic_pipe`, `render_basic_sprite`, `render_liquid_tile`, `render_gas_tile`, `render_liquid_sprite`, `render_gas_sprite`, `render_beam!`, `render_pipe`, `setup_basesprite_uniforms`. Most return `RenderCommand`; `render_pipe` returns `Vector{RenderCommand}`; `render_beam!` pushes to a queue.

**Render height constants** (ascending Z-order, defined in `HexFlowRendering` — not exported, use `HexFlowRendering.RENDER_HEIGHT_*`):

| Constant | Value | Purpose |
|----------|-------|---------|
| `RENDER_HEIGHT_TRACTOR_BEAM` | -1100 | Docking beam visuals |
| `RENDER_HEIGHT_BACKGROUND` | -1000 | Ship surface tiles |
| `RENDER_HEIGHT_PIPE_RANK_MULTIPLIER` | 10 | Pipe stacking-rank band spacing |
| `RENDER_HEIGHT_COMPONENT_BEHIND` | 1000 | Behind-component art (fluid masks, energy bars) |
| `RENDER_HEIGHT_COMPONENT_STATIC` | 2000 | Static component sprites |
| `RENDER_HEIGHT_COMPONENT_ANIM` | 3000 | Animated overlays (flames, smoke) |
| `RENDER_HEIGHT_NODE` | 100000 | Node vertices |
| `RENDER_HEIGHT_OVERLAY_BASE` | 101000 | UI overlays (stall icons) |

Ghost previews use `render_height_offset = Int32(100000)`. See `src/render_height.md` for full documentation.

**Asset loading modes** (detected via `isdefined(Main, :Revise)`):
- Dev: shader/texture paths point to source files for hot-reload
- Production: paths resolved from `Artifacts.toml`

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

### Circuit/Electrical Changes
- Preserve pruning/ground-search ordering in `FlowEngine`: `prune` → `ground_search` → `clear_dangling_dependants`
- The iterative prune loop in `update_map!` runs until hash-convergence
- Adding new `ElementTypes` requires updating MNA matrix stamping (`MNA_getA`, `MNA_getZ`) and `abs_element_get_current`

### Modifying GameMap/Save-Related Structs
- Adding fields to `GameMap` or types stored within it (e.g., `TutorialState`) requires a JLD2 `rconvert` reconstruction hook in `src/map_loading.jl` if older saves must keep loading
- Struct defaults alone are not sufficient when loading files that predate the new field
