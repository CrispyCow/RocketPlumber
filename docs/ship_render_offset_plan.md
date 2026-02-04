# Ship Render Position Offset Implementation Plan

## Overview

Add a cosmetic rendering offset to ships for visual effects (e.g., ship docking animations). This offset affects rendering only - actual ship coordinates remain unchanged.

## Design Decisions (from clarifications)

- **Field type**: `AxialCoord` (consistent with coordinate system)
- **Node ambiguity**: Fall back to `:primary` ship offset (assumed zero)
- **Colour variation**: Surface tiles only, using existing colour kwarg tint
- **Interactions**: Block interactions on ships with non-zero offset (Option B)
- **Ghosts**: Ignore offset (consistent with blocking interactions)
- **Particles**: Spawn at offset positions for respective ships
- **Persistence**: Transient (zero in constructors, zeroed on save)
- **Testing**: Dev utils menu with ship selector and offset inputs

---

## Implementation Phases

### Phase 1: FlowEngine Data Model

**File**: `local_packages/FlowEngine/src/FlowEngine.jl`

1. **Add field to ShipMap**:
   ```julia
   @kwdef mutable struct ShipMap
       components::Dict{TileCoord, ComponentOnTile} = Dict{TileCoord, ComponentOnTile}()
       pipe_behaviors::Dict{EdgeCoord, PipeBehavior} = Dict{EdgeCoord, PipeBehavior}()
       ship_tiles::Set{TileCoord} = Set{TileCoord}([TileCoord(0, 0)])
       render_position_offset::AxialCoord = AxialCoord(0.0, 0.0)  # NEW
   end
   ```

2. **Add exports**:
   - `get_ship_render_offset`
   - `set_ship_render_offset!`
   - `clear_all_render_pos_offsets!`
   - `find_ship_for_node`

3. **Implement interface functions**:
   ```julia
   "Get the render position offset for a ship"
   get_ship_render_offset(gamemap::GameMap, ship_name::Symbol)::AxialCoord
   
   "Set the render position offset for a ship"
   set_ship_render_offset!(gamemap::GameMap, ship_name::Symbol, offset::AxialCoord)
   
   "Clear all ship render position offsets to zero"
   clear_all_render_pos_offsets!(gamemap::GameMap)
   
   "Find which ship a node belongs to based on adjacent surface tiles. Returns :primary as fallback."
   find_ship_for_node(node::NodeCoord, gamemap::GameMap)::Symbol
   ```

4. **Add helper for ship surface colour**:
   ```julia
   "Generate a subtle colour tint for a ship based on its name (deterministic hash)"
   get_ship_surface_colour(ship_name::Symbol)::SVector{4, Float32}
   ```

---

### Phase 2: HexFlowRendering - Low-level Helpers

**File**: `local_packages/HexFlowRendering/src/HexFlowRendering.jl`

1. **Update `render_basic_sprite`**: Add optional `pos_offset` kwarg
   - Apply offset to position before rendering
   - Accept any type compatible with `glvec()`

2. **Update `render_basic_tile`**: Forward `pos_offset` kwarg

3. **Update `render_basic_pipe`**: Forward `pos_offset` kwarg

4. **Update `render_liquid_sprite`/`render_gas_sprite`**: Forward `pos_offset` kwarg

5. **Update `render_liquid_tile`/`render_gas_tile`**: Forward `pos_offset` kwarg

---

### Phase 3: HexFlowRendering - Queued Render Functions

**File**: `local_packages/HexFlowRendering/src/HexFlowRendering.jl`

1. **Update `tile_queued_render!`**:
   - Get ship name in outer loop
   - Get ship render offset
   - Pass `pos_offset` to `render_map_elem!`

2. **Update `pipe_queued_render!`**:
   - Get ship name in outer loop
   - Get ship render offset  
   - Pass `pos_offset` to `render_pipe_map!`

3. **Update `node_queued_render!`**:
   - Accept `gamemap` parameter
   - For each node, call `find_ship_for_node` to get ship
   - Get ship render offset
   - Apply offset to position before rendering

4. **Update `ship_surface_queued_render!`**:
   - Iterate per-ship instead of combined surfaces
   - Get ship render offset
   - Get ship surface colour from name hash
   - Pass `pos_offset` and `colour` to `render_basic_tile`

---

### Phase 4: HexComponentsAPI - Interface Updates

**File**: `local_packages/components/HexComponentsAPI/src/HexComponentsAPI.jl`

1. **Document `pos_offset` kwarg** in interface docs for:
   - `render_base_elem!`
   - `render_map_elem!`
   - `render_pipe_base!`
   - `render_pipe_map!`
   - `collect_effect_particles!`

No code changes needed - kwargs are already forwarded via `kwargs...`.

---

### Phase 5: Component Implementations

**File**: `local_packages/components/HexFlowNozzleComponents/src/HexFlowNozzleComponents.jl`

1. **Update `collect_effect_particles!` for NozzleBehavFrag**:
   - Accept `pos_offset` kwarg (default zero)
   - Apply offset to particle spawn positions

---

### Phase 6: HexFlowRendering - Particle System

**File**: `local_packages/HexFlowRendering/src/HexFlowRendering.jl`

1. **Update `thrust_dust_particle_effect!`**:
   - Accept `gamemap` parameter
   - Iterate per-ship surface edges
   - Apply ship render offset to spawn positions

2. **Update `tile_particle_spawn!`**:
   - Pass ship render offset via kwargs to `collect_effect_particles!`

---

### Phase 7: Gameloop - Rendering Updates

**File**: `src/gameloop.jl`

1. **Update `custom_rendering!`**:
   - Pass `gamemap` to `thrust_dust_particle_effect!`
   - Update `node_queued_render!` call to pass `gamemap`

---

### Phase 8: Interactions - Block Offset Ships

**File**: `src/interactions.jl`

1. **Add helper function**:
   ```julia
   "Check if clicked coordinate is on a ship with non-zero render offset"
   is_on_offset_ship(coord, gamemap)::Bool
   ```

2. **Update interaction handlers**:
   - `flowcalc_tileplacer!` - early return if on offset ship
   - `flowcalc_pipeplacer!` - early return if on offset ship
   - `flowcalc_tilemover!` - early return if on offset ship
   - `flowcalc_delete!` - early return if on offset ship
   - `flowcalc_surfaceedit!` - early return if on offset ship
   - `flowcalc_click_handler!` - early return if on offset ship

---

### Phase 9: Dev Utils Menu

**File**: `src/gameloop.jl`

1. **Add to `ui_dev_utils_menu_render!`**:
   - New "Rendering" tree node
   - "Ship Render Offset" header
   - ListBox for ship names
   - Two InputFloat for Q and R offset values
   - "Apply Offset" button

2. **Add state variables to InputState gui_inputs**:
   - `:selected_ship_index`
   - `:render_offset_q`
   - `:render_offset_r`

---

### Phase 10: Map Save/Load

**File**: `src/gameloop.jl` (or wherever save/load is)

1. **Before saving**: Call `clear_all_render_pos_offsets!(gamemap)`

---

## Testing Plan

1. Run `repl_launch.jl`
2. Open Dev Utils menu (backslash key)
3. Navigate to Rendering > Ship Render Offset
4. Select a ship from the list
5. Enter Q and R offset values
6. Click Apply Offset
7. Verify:
   - Ship surface tiles render at offset position with subtle colour tint
   - Components on that ship render at offset position
   - Pipes on that ship render at offset position
   - Nodes on that ship render at offset position
   - Particles spawn at offset positions
   - Cannot interact with offset ship (clicks ignored)
   - Other ships remain unaffected

---

## Files Modified

1. `local_packages/FlowEngine/src/FlowEngine.jl` - Data model + interface
2. `local_packages/HexFlowRendering/src/HexFlowRendering.jl` - Render functions
3. `local_packages/components/HexFlowNozzleComponents/src/HexFlowNozzleComponents.jl` - Particle offset
4. `src/gameloop.jl` - Dev menu + render calls
5. `src/interactions.jl` - Block offset ship interactions
