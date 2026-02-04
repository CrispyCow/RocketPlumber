# Docking Status Implementation Plan

This document outlines the implementation plan for adding ship docking/connection state tracking with animated render offsets.

## Overview

This feature replaces the simple `render_position_offset::AxialCoord` field on `ShipMap` with a more sophisticated docking status system that:
1. Tracks whether a ship is connected, approaching, or departing
2. Encapsulates animated linear motion towards a target offset
3. Enables automatic ship removal when departing ships complete their motion
4. Supports approach animations when encountering new ships

---

## 1. New Types in FlowEngine.jl

### 1.1 RenderPosOffsetState Struct

**Location:** After existing imports, before struct definitions (around line 42)

```julia
"""
Encapsulates state for a linear maneuver in render offset space.
Used to animate ships moving between positions.
"""
@kwdef mutable struct RenderPosOffsetState
    current_offset::AxialCoord
    target_offset::AxialCoord
    offset_step::Float64  # Distance to move per update
end
```

**Methods:**

```julia
"Returns the current render offset position"
get_render_offset(state::RenderPosOffsetState)::AxialCoord = state.current_offset

"""
Moves current_offset one step closer to target_offset along the line between them.
Clamps to target if the step would overshoot. Returns true if target has been reached.
"""
function update_render_offset!(state::RenderPosOffsetState)::Bool
    diff = state.target_offset - state.current_offset
    distance = sqrt(diff.q^2 + diff.r^2)
    
    # Already at target or very close
    if distance <= state.offset_step
        state.current_offset = state.target_offset
        return true
    end
    
    # Move one step towards target
    direction_q = diff.q / distance
    direction_r = diff.r / distance
    state.current_offset = AxialCoord(
        state.current_offset.q + direction_q * state.offset_step,
        state.current_offset.r + direction_r * state.offset_step
    )
    return false
end
```

### 1.2 DockingStatus Abstract Type and Interface

**Location:** After RenderPosOffsetState

```julia
"""
Abstract type representing the docking/connection status of a ship.

All concrete subtypes must end with `DockStat` and implement:

    get_render_offset(status::DockingStatus)::Union{AxialCoord, Nothing}
        Returns the current render position offset, or nothing if no offset.

    update_render_offset!(status::DockingStatus)::Bool
        Updates any ongoing motion and returns true if motion is finished.
        For stationary states, returns false and does nothing.
"""
abstract type DockingStatus end
```

### 1.3 Concrete DockingStatus Types

```julia
"""
Ship is connected/docked with no render offset. This is the default/resting state.
"""
struct ConnectedDockStat <: DockingStatus end

get_render_offset(::ConnectedDockStat)::Nothing = nothing
update_render_offset!(::ConnectedDockStat)::Bool = false


"""
Ship is approaching/docking - moving from a distant position towards connected position.
When motion completes, should transition to ConnectedDockStat.
"""
struct ApproachingDockStat <: DockingStatus
    motion::RenderPosOffsetState
end

"Transparent constructor matching RenderPosOffsetState arguments"
function ApproachingDockStat(current_offset::AxialCoord, target_offset::AxialCoord, offset_step::Float64)
    return ApproachingDockStat(RenderPosOffsetState(current_offset, target_offset, offset_step))
end

get_render_offset(status::ApproachingDockStat)::AxialCoord = get_render_offset(status.motion)
update_render_offset!(status::ApproachingDockStat)::Bool = update_render_offset!(status.motion)


"""
Ship is departing - moving from connected position towards a distant position.
When motion completes, the ship should be removed from the GameMap.
"""
struct DepartingDockStat <: DockingStatus
    motion::RenderPosOffsetState
end

"Transparent constructor matching RenderPosOffsetState arguments"
function DepartingDockStat(current_offset::AxialCoord, target_offset::AxialCoord, offset_step::Float64)
    return DepartingDockStat(RenderPosOffsetState(current_offset, target_offset, offset_step))
end

get_render_offset(status::DepartingDockStat)::AxialCoord = get_render_offset(status.motion)
update_render_offset!(status::DepartingDockStat)::Bool = update_render_offset!(status.motion)
```

---

## 2. Modify ShipMap Struct

**File:** [FlowEngine.jl](../local_packages/FlowEngine/src/FlowEngine.jl#L45-L52)

**Current:**
```julia
@kwdef mutable struct ShipMap
    components::Dict{TileCoord, ComponentOnTile} = Dict{TileCoord, ComponentOnTile}()
    pipe_behaviors::Dict{EdgeCoord, PipeBehavior} = Dict{EdgeCoord, PipeBehavior}()
    ship_tiles::Set{TileCoord} = Set{TileCoord}([TileCoord(0, 0)])
    render_position_offset::AxialCoord = AxialCoord(0.0, 0.0)
end
```

**New:**
```julia
@kwdef mutable struct ShipMap
    components::Dict{TileCoord, ComponentOnTile} = Dict{TileCoord, ComponentOnTile}()
    pipe_behaviors::Dict{EdgeCoord, PipeBehavior} = Dict{EdgeCoord, PipeBehavior}()
    ship_tiles::Set{TileCoord} = Set{TileCoord}([TileCoord(0, 0)])
    docking_status::DockingStatus = ConnectedDockStat()
end
```

**New methods for ShipMap:**

```julia
"Get the render offset for a ship, returns AxialCoord(0,0) if no offset (ConnectedDockStat)"
function get_render_offset(ship::ShipMap)::AxialCoord
    offset = get_render_offset(ship.docking_status)
    return isnothing(offset) ? AxialCoord(0.0, 0.0) : offset
end

"Update render offset motion for a ship, returns true if motion is complete"
update_render_offset!(ship::ShipMap)::Bool = update_render_offset!(ship.docking_status)

"Get the docking status of a ship"
get_docking_status(ship::ShipMap)::DockingStatus = ship.docking_status

"Set the docking status of a ship"
function set_docking_status!(ship::ShipMap, status::DockingStatus)
    ship.docking_status = status
    return nothing
end
```

---

## 3. Modify GameMap Functions

**File:** [FlowEngine.jl](../local_packages/FlowEngine/src/FlowEngine.jl#L655-L680)

### 3.1 Replace Existing Render Offset Functions

**Remove these functions:**
- `get_ship_render_offset(gamemap::GameMap, ship_name::Symbol)::AxialCoord`
- `set_ship_render_offset!(gamemap::GameMap, ship_name::Symbol, offset::AxialCoord)`
- `clear_all_render_pos_offsets!(gamemap::GameMap)`

**Add these new functions:**

```julia
"Get the render offset for a ship by name (required argument, not kwarg)"
function get_ship_render_offset(gamemap::GameMap, ship_name::Symbol)::AxialCoord
    return get_render_offset(_get_ship(gamemap, ship_name))
end

"Get the docking status of a ship. Returns nothing if ship not found."
function get_docking_status(gamemap::GameMap, ship_name::Symbol)::Union{DockingStatus, Nothing}
    if !haskey(gamemap.ships, ship_name)
        return nothing
    end
    return get_docking_status(gamemap.ships[ship_name])
end

"Set the docking status of a ship. Errors if ship not found."
function set_docking_status!(gamemap::GameMap, ship_name::Symbol, status::DockingStatus)
    if !haskey(gamemap.ships, ship_name)
        error("Ship '$ship_name' not found. Available ships: $(collect(keys(gamemap.ships)))")
    end
    set_docking_status!(gamemap.ships[ship_name], status)
    return nothing
end

"""
Update docking state machine for a ship.
- ConnectedDockStat: do nothing
- ApproachingDockStat: update motion, transition to ConnectedDockStat when complete
- DepartingDockStat: update motion, remove ship from map when complete
"""
function update_docking!(gamemap::GameMap, ship_name::Symbol)
    status = get_docking_status(gamemap, ship_name)
    
    # Ship not present, do nothing
    if isnothing(status)
        return nothing
    end
    
    # ConnectedDockStat: no motion, do nothing
    if status isa ConnectedDockStat
        return nothing
    end
    
    # ApproachingDockStat: update motion, transition when complete
    if status isa ApproachingDockStat
        motion_complete = update_render_offset!(status)
        if motion_complete
            set_docking_status!(gamemap, ship_name, ConnectedDockStat())
        end
        return nothing
    end
    
    # DepartingDockStat: update motion, remove ship when complete
    if status isa DepartingDockStat
        motion_complete = update_render_offset!(status)
        if motion_complete
            remove_ship!(gamemap, ship_name)
        end
        return nothing
    end
    
    return nothing
end

"Clear all ships to ConnectedDockStat (used before saving maps)"
function clear_all_docking_statuses!(gamemap::GameMap)
    for (_, ship) in gamemap.ships
        set_docking_status!(ship, ConnectedDockStat())
    end
    return nothing
end
```

### 3.2 Update Exports

**Add to exports (around line 11):**
```julia
export RenderPosOffsetState, DockingStatus, ConnectedDockStat, ApproachingDockStat, DepartingDockStat
export get_render_offset, update_render_offset!, get_docking_status, set_docking_status!, update_docking!
export clear_all_docking_statuses!
```

**Remove from exports:**
```julia
# Remove: set_ship_render_offset!, clear_all_render_pos_offsets!
# Keep: get_ship_render_offset (signature unchanged), find_ship_for_node
```

---

## 4. Update HexFlowRendering.jl

**File:** [HexFlowRendering.jl](../local_packages/HexFlowRendering/src/HexFlowRendering.jl)

All places that currently access `ship.render_position_offset` directly need to be updated to use `get_render_offset(ship)` or `get_ship_render_offset(gamemap, ship_name)`.

### Locations to Update:

| Line | Current Code | New Code |
|------|--------------|----------|
| 498 | `ship_offset = ship.render_position_offset` | `ship_offset = get_render_offset(ship)` |
| 532 | `ship_offset = get_ship_render_offset(gamemap, ship_name)` | No change needed (function signature unchanged) |
| 562 | `ship_offset = ship.render_position_offset` | `ship_offset = get_render_offset(ship)` |
| 589 | `ship_offset = ship.render_position_offset` | `ship_offset = get_render_offset(ship)` |
| 892 | `ship_offset_vec = glvec(ship.render_position_offset)` | `ship_offset_vec = glvec(get_render_offset(ship))` |
| 954 | `ship_offset = ship.render_position_offset` | `ship_offset = get_render_offset(ship)` |
| 1083 | `ship_offset = ship.render_position_offset` | `ship_offset = get_render_offset(ship)` |

**Required import:** Add `get_render_offset` to imports from FlowEngine if not already exported.

---

## 5. Update gameloop.jl - JLD2 Migration

**File:** [gameloop.jl](../src/gameloop.jl#L184-L193)

**Current:**
```julia
JLD2.rconvert(::Type{FlowEngine.ShipMap}, nt::NamedTuple) = FlowEngine.ShipMap(
    components = get(nt, :components, Dict{TileCoord, ComponentOnTile}()),
    pipe_behaviors = get(nt, :pipe_behaviors, Dict{EdgeCoord, PipeBehavior}()),
    ship_tiles = get(nt, :ship_tiles, Set{TileCoord}([TileCoord(0, 0)])),
    render_position_offset = get(nt, :render_position_offset, HexFrame.AxialCoord(0.0, 0.0))
)
```

**New:**
```julia
JLD2.rconvert(::Type{FlowEngine.ShipMap}, nt::NamedTuple) = FlowEngine.ShipMap(
    components = get(nt, :components, Dict{TileCoord, ComponentOnTile}()),
    pipe_behaviors = get(nt, :pipe_behaviors, Dict{EdgeCoord, PipeBehavior}()),
    ship_tiles = get(nt, :ship_tiles, Set{TileCoord}([TileCoord(0, 0)])),
    docking_status = ConnectedDockStat()  # Old maps always load as connected
)
```

**Note:** Old maps with `render_position_offset` will have that field ignored and will load with `ConnectedDockStat()`. This is intentional - saved offset positions are session-specific and shouldn't persist.

---

## 6. Update HexFlowCalculator.jl - Main Loop

**File:** [HexFlowCalculator.jl](../local_packages/HexFlowCalculator/src/HexFlowCalculator.jl#L1025-L1040)

### 6.1 Add Import

Ensure `update_docking!` is available (should be via FlowEngine import).

### 6.2 Add Docking Update in Main Loop

**Location:** As the FIRST state update inside the `if !is_paused` block (before `update_components!`)

**Current:**
```julia
if !is_paused
    # Full update: advance game state
    gamestate.ticks += 1

    # Update state
    @timeit flowcalc_loop_timer "Component Updates" update_components!(gamemap, mna_state)
    update_map!(gamemap, derivedmapstate, mna_state, gamestate.ticks)
```

**New:**
```julia
if !is_paused
    # Full update: advance game state
    gamestate.ticks += 1

    # Update docking animations FIRST (before any other state updates)
    @timeit flowcalc_loop_timer "Docking Updates" begin
        for ship_name in collect(keys(gamemap.ships))  # collect() since we may modify during iteration
            update_docking!(gamemap, ship_name)
        end
    end

    # Update state
    @timeit flowcalc_loop_timer "Component Updates" update_components!(gamemap, mna_state)
    update_map!(gamemap, derivedmapstate, mna_state, gamestate.ticks)
```

**Note:** We use `collect(keys(...))` because `update_docking!` may call `remove_ship!` for departing ships, which would modify the dict during iteration. Docking updates run first so ships are removed cleanly before other systems try to access them.

---

## 7. Update HexFlowProcGen.jl - encounter_ship!

**File:** [HexFlowProcGen.jl](../local_packages/HexFlowProcGen/src/HexFlowProcGen.jl#L456-L478)

**Current:**
```julia
function encounter_ship!(gamemap::GameMap, shipoptions::ShipGenOptions, seed::UInt32, dir::HexFrame.HexAxis)
    newship = generate_ship(shipoptions, seed)
    newship_name = gensym(shipoptions.name)

    # offset ship until no surface overlap
    offset_newship = deepcopy(newship)
    while _is_surface_overlap(gamemap, offset_newship)
        offset = HexFrame.hex_neighbour_tiles[dir]
        offset_ship!(offset_newship, offset)
    end

    # add final gap
    MIN_SPACING = 3
    hnt = HexFrame.hex_neighbour_tiles[dir]
    final_offset = TileCoord(hnt.q * MIN_SPACING, hnt.r * MIN_SPACING)
    offset_ship!(offset_newship, final_offset)

    # add to gamemap
    add_ship!(gamemap, newship_name, offset_newship)
end
```

**New:**
```julia
function encounter_ship!(gamemap::GameMap, shipoptions::ShipGenOptions, seed::UInt32, dir::HexFrame.HexAxis)
    newship = generate_ship(shipoptions, seed)
    newship_name = gensym(shipoptions.name)

    # offset ship until no surface overlap
    offset_newship = deepcopy(newship)
    while _is_surface_overlap(gamemap, offset_newship)
        offset = HexFrame.hex_neighbour_tiles[dir]
        offset_ship!(offset_newship, offset)
    end

    # add final gap
    MIN_SPACING = 3
    hnt = HexFrame.hex_neighbour_tiles[dir]
    final_offset = TileCoord(hnt.q * MIN_SPACING, hnt.r * MIN_SPACING)
    offset_ship!(offset_newship, final_offset)
    
    # Calculate approach animation parameters
    # Start 20 tiles away in the approach direction and animate to zero offset
    APPROACH_DISTANCE_TILES = 20
    TARGET_APPROACH_DURATION_SECS = 5.0
    TARGET_UPS = 60.0  # updates per second
    
    # Convert tile distance to axial offset (using hex_vert_vecs for direction)
    direction_vec = HexFrame.hex_vert_vecs[dir]
    start_offset = AxialCoord(
        direction_vec.q * APPROACH_DISTANCE_TILES,
        direction_vec.r * APPROACH_DISTANCE_TILES
    )
    target_offset = AxialCoord(0.0, 0.0)
    
    # Calculate step size: total_distance / (duration * ups)
    total_distance = sqrt(start_offset.q^2 + start_offset.r^2)
    total_updates = TARGET_APPROACH_DURATION_SECS * TARGET_UPS
    offset_step = total_distance / total_updates
    
    # Set docking status to approaching
    set_docking_status!(offset_newship, ApproachingDockStat(start_offset, target_offset, offset_step))

    # add to gamemap
    add_ship!(gamemap, newship_name, offset_newship)
end
```

**Required imports in HexFlowProcGen:**
```julia
using FlowEngine: set_docking_status!, ApproachingDockStat, AxialCoord
# Or ensure these are re-exported appropriately
```

---

## 8. Update gameloop.jl - Dev Utils Menu

**File:** [gameloop.jl](../src/gameloop.jl#L820-L1010)

### 8.1 Add Delete Ship TreeNode

**Location:** Inside the "Tools" CollapsingHeader (after "Clear Map" button, around line 843)

```julia
if CImGui.TreeNode("Delete Ship")
    # Get current gamemap to list ships
    current_gamemap = (flowcalc_ipc.get_snapshot()).gamemap
    all_ship_names = get_all_ship_names(current_gamemap)
    
    # Filter out :primary
    deletable_ships = filter(n -> n != :primary, all_ship_names)
    deletable_ship_strings = safe_ship_display_name.(deletable_ships)
    
    if isempty(deletable_ships)
        CImGui.Text("No deletable ships (only primary exists)")
    else
        # Ship selection dropdown
        delete_ship_index = gui_listbox_int!(inputstate, :delete_ship_index, "Ship", deletable_ship_strings, Int32(0))
        delete_ship_index = clamp(delete_ship_index, Int32(0), Int32(max(0, length(deletable_ships) - 1)))
        inputstate.gui_inputs[:delete_ship_index] = delete_ship_index
        
        selected_delete_ship = deletable_ships[delete_ship_index + 1]
        
        if CImGui.Button("Delete Ship", (button_width, button_height))
            modified_map = deepcopy(current_gamemap)
            remove_ship!(modified_map, selected_delete_ship)
            enqueue_map_override!(flowcalc_ipc, modified_map)
            @info "Deleted ship $(selected_delete_ship)"
        end
    end
    CImGui.TreePop()
end
```

### 8.2 Add Depart Ship TreeNode

**Location:** After Delete Ship TreeNode

```julia
if CImGui.TreeNode("Depart Ship")
    # Get current gamemap to list ships
    current_gamemap = (flowcalc_ipc.get_snapshot()).gamemap
    all_ship_names = get_all_ship_names(current_gamemap)
    
    # Filter out :primary
    departable_ships = filter(n -> n != :primary, all_ship_names)
    departable_ship_strings = safe_ship_display_name.(departable_ships)
    
    if isempty(departable_ships)
        CImGui.Text("No departable ships (only primary exists)")
    else
        # Ship selection dropdown
        depart_ship_index = gui_listbox_int!(inputstate, :depart_ship_index, "Ship", departable_ship_strings, Int32(0))
        depart_ship_index = clamp(depart_ship_index, Int32(0), Int32(max(0, length(departable_ships) - 1)))
        inputstate.gui_inputs[:depart_ship_index] = depart_ship_index
        
        selected_depart_ship = departable_ships[depart_ship_index + 1]
        
        # Direction selection for departure
        if CImGui.Button("Depart Ship", (button_width, button_height))
            modified_map = deepcopy(current_gamemap)
            
            # Auto-calculate departure direction away from primary
            depart_dir = calculate_depart_direction(modified_map, selected_depart_ship)
            
            # Calculate departure animation parameters
            DEPART_DISTANCE_TILES = 20
            TARGET_DEPART_DURATION_SECS = 5.0
            TARGET_UPS = 60.0
            
            # Convert tile distance to axial offset
            direction_vec = HexFrame.hex_vert_vecs[depart_dir]
            target_offset = AxialCoord(
                direction_vec.q * DEPART_DISTANCE_TILES,
                direction_vec.r * DEPART_DISTANCE_TILES
            )
            start_offset = AxialCoord(0.0, 0.0)
            
            # Calculate step size
            total_distance = sqrt(target_offset.q^2 + target_offset.r^2)
            total_updates = TARGET_DEPART_DURATION_SECS * TARGET_UPS
            offset_step = total_distance / total_updates
            
            set_docking_status!(modified_map, selected_depart_ship, DepartingDockStat(start_offset, target_offset, offset_step))
            enqueue_map_override!(flowcalc_ipc, modified_map)
            @info "Ship $(selected_depart_ship) departing in direction $(depart_dir)"
        end
    end
    CImGui.TreePop()
end
```

**Helper function to add near the UI code:**
```julia
"Calculate departure direction as the HexAxis direction closest to the vector from primary to target ship"
function calculate_depart_direction(gamemap::GameMap, ship_name::Symbol)::HexAxis
    # Get centroids of both ships
    primary_surface = get_all_surface_tiles(gamemap; ship_name = :primary)
    ship_surface = get_all_surface_tiles(gamemap; ship_name = ship_name)
    
    # Calculate centroids in axial coordinates
    primary_centroid_q = sum(t.q for t in primary_surface) / length(primary_surface)
    primary_centroid_r = sum(t.r for t in primary_surface) / length(primary_surface)
    ship_centroid_q = sum(t.q for t in ship_surface) / length(ship_surface)
    ship_centroid_r = sum(t.r for t in ship_surface) / length(ship_surface)
    
    # Direction vector from primary to this ship
    dir_q = ship_centroid_q - primary_centroid_q
    dir_r = ship_centroid_r - primary_centroid_r
    dir_axial = AxialCoord(dir_q, dir_r)
    
    # Convert to cartesian for angle calculation
    dir_cart = to_cartesian(dir_axial)
    angle_rad = atan(dir_cart.y, dir_cart.x)
    angle_deg = rad2deg(angle_rad)
    
    # Normalize angle to [0, 360)
    angle_deg = mod(angle_deg, 360.0)
    
    # Map to nearest HexAxis (Q_POS=0°, S_NEG=60°, R_POS=120°, Q_NEG=180°, S_POS=240°, R_NEG=300°)
    hexRemove Existing Render Offset TreeNode in Dev Utils ✅ RESOLVED

**File:** [gameloop.jl](../src/gameloop.jl#L970-L1010)

**Decision:** Remove the "Ship Render Offset" TreeNode entirely. It served its purpose during development and is now superseded by the encounter/depart ship functionality.

**Implementation:** Delete the entire TreeNode block (approximately lines 970-1010). This includes:
- The `if CImGui.TreeNode("Ship Render Offset")` block
- Ship selection listbox
- Offset Q/R inputs
- "Apply Offset" button
- "Clear All Offsets" button

No replacement needed - the Delete Ship and Depart Ship TreeNodes provide all necessary functionality for managing ship positions.
## 9. Update interactions.jl - is_on_offset_ship

**File:** [interactions.jl](../src/interactions.jl#L443-L469)

The function `is_on_offset_ship` checks if a ship has a non-zero render offset. This needs to be updated to use the new accessor.

**Current check pattern:**
```julia
offset = get_ship_render_offset(gamemap, ship_name)
return offset != AxialCoord(0.0, 0.0)
```

This pattern still works because `get_ship_render_offset` signature is unchanged. **No changes needed** in interactions.jl.

---

## 10. Update Existing Render Offset TreeNode in Dev Utils

**File:** [gameloop.jl](../src/gameloop.jl#L970-L1010)

The existing "Ship Render Offset" TreeNode allows manually setting offsets. This is incompatible with the new docking status system.

**Options:**
1. **Remove it entirely** - the old manual offset feature is replaced by the docking system
2. **Modify it** to work with docking statuses (set to ApproachingDockStat/DepartingDockStat)
3. **Keep it for debugging** but have it override docking status

**Recommendation:** Remove it or replace with a simpler display (RenderPosOffsetState, DockingStatus, concrete statuses), modify ShipMap, update GameMap functions, update exports |
| `local_packages/HexFlowRendering/src/HexFlowRendering.jl` | Replace `ship.render_position_offset` with `get_render_offset(ship)` (7 locations) |
| `local_packages/HexFlowCalculator/src/HexFlowCalculator.jl` | Add docking update loop as FIRST update in `!is_paused` block |
| `local_packages/HexFlowProcGen/src/HexFlowProcGen.jl` | Update encounter_ship! with ApproachingDockStat |
| `src/gameloop.jl` | Update JLD2 migration, add calculate_depart_direction helper, add Delete/Depart Ship UI, REMOVE old
    current_gamemap = (flowcalc_ipc.get_snapshot()).gamemap
    
    for (ship_name, ship) in current_gamemap.ships
        status = get_docking_status(ship)
       Clarifications ✅ ALL RESOLVED(ship)
        status_str = string(typeof(status).name.name)
        CImGui.Text("$(safe_ship_display_name(ship_name)): $(status_str) @ ($(round(offset.q, digits=2)), $(round(offset.r, digits=2)))")
    end
    
    if CImGui.Button("Clear All to Connected", (button_width, button_height))
        modified_map = deepcopy(current_gamemap)
        clear_all_docking_statuses!(modified_map)
        enqueue_map_override!(flowcalc_ipc, modified_map)
        @info "Cleared all docking statuses to Connected"
    end
    
    CImGui.TreePop()
end
```

---

## 11. Summary of Files to Modify

| File | Changes |
|------|---------|
| `local_packages/FlowEngine/src/FlowEngine.jl` | Add new types, modify ShipMap, update GameMap functions, update exports |
| `local_packages/HexFlowRendering/src/HexFlowRendering.jl` | Replace `ship.render_position_offset` with `get_render_offset(ship)` (7 locations) |
| `local_packages/HexFlowCalculator/src/HexFlowCalculator.jl` | Add docking update loop in main flowcalculator_loop! |
| `local_packages/HexFlowProcGen/src/HexFlowProcGen.jl` | Update encounter_ship! with ApproachingDockStat |
| `src/gameloop.jl` | Update JLD2 migration, add Delete/Depart Ship UI, update Render Offset UI |
| `src/interactions.jl` | No changes needed (get_ship_render_offset signature unchanged) |

---

## 12. Questions for Clarification

### 12.1 Direction for Departing Ships ✅ RESOLVED

**Decision:** Auto-calculate direction away from primary ship, snapping to the nearest HexAxis direction.

**Implementation:**
```julia
"Calculate departure direction as the HexAxis direction closest to the vector from primary to target ship"
function calculate_depart_direction(gamemap::GameMap, ship_name::Symbol)::HexAxis
    # Get centroids of both ships
    primary_surface = get_all_surface_tiles(gamemap; ship_name = :primary)
    ship_surface = get_all_surface_tiles(gamemap; ship_name = ship_name)
    
    # Calculate centroids in axial coordinates
    primary_centroid_q = sum(t.q for t in primary_surface) / length(primary_surface)
    primary_centroid_r = sum(t.r for t in primary_surface) / length(primary_surface)
    ship_centroid_q = sum(t.q for t in ship_surface) / length(ship_surface)
    ship_centroid_r = sum(t.r for t in ship_surface) / length(ship_surface)
    
    # Direction vector from primary to this ship
    dir_q = ship_centroid_q - primary_centroid_q
    dir_r = ship_centroid_r - primary_centroid_r
    dir_axial = AxialCoord(dir_q, dir_r)
    
    # Convert to cartesian for angle calculation
    dir_cart = to_cartesian(dir_axial)
    angle_rad = atan(dir_cart.y, dir_cart.x)
    angle_deg = rad2deg(angle_rad)
    
    # Normalize angle to [0, 360)
    angle_deg = mod(angle_deg, 360.0)
    
    # Map to nearest HexAxis (Q_POS=0°, S_NEG=60°, R_POS=120°, Q_NEG=180°, S_POS=240°, R_NEG=300°)
    hex_angles = [
        (0.0, HexFrame.Q_POS),
        (60.0, HexFrame.S_NEG),
        (120.0, HexFrame.R_POS),
        (180.0, HexFrame.Q_NEG),
        (240.0, HexFrame.S_POS),
        (300.0, HexFrame.R_NEG)
    ]
    
    # Find closest angle with wrap-around
    best_axis = HexFrame.Q_POS
    min_diff = 360.0
    for (hex_angle, hex_axis) in hex_angles
        diff = abs(angle_deg - hex_angle)
        # Handle wrap-around
        diff = min(diff, 360.0 - diff)
        if diff < min_diff
            min_diff = diff
            best_axis = hex_axis
        end
    end
    
    return best_axis
end
```

This function should be added to **gameloop.jl** near the depart ship UI code.

### 12.2 Pause Behavior ✅ RESOLVED

**Decision:** Docking animations continue during pause (ships keep moving even when game is paused).

**Implementation:** Place `update_docking!` calls **inside** the `if !is_paused` block as the **first state update**, before `update_components!`.

```julia
if !is_paused
    # Full update: advance game state
    gamestate.ticks += 1

    # Update docking animations FIRST (before any other state updates)
    @timeit flowcalc_loop_timer "Docking Updates" begin
        for ship_name in collect(keys(gamemap.ships))
            update_docking!(gamemap, ship_name)
        end
    end

    # Update state
    @timeit flowcalc_loop_timer "Component Updates" update_components!(gamemap, mna_state)
    # ... rest of updates
```

**Rationale:** Animations should stop when paused, keeping behavior consistent with the rest of the game simulation. Docking is part of the game state, not just a visual effect.

### 12.3 Save/Load Behavior ✅ RESOLVED

**Decision:** Do NOT filter out ships during save. All information needed to continue docking is stored in the GameMap. Ships can be saved mid-departure or mid-approach and will continue their animation when loaded.

**Implementation:** No special save/load handling needed beyond the JLD2 migration for old maps. The `DockingStatus` types should serialize naturally since they contain all state (current_offset, target_offset, offset_step).

**Note:** May want to add `@struct_hash_equal` to the new types to ensure proper serialization.

### 12.4 Existing "Ship Render Offset" TreeNode ✅ RESOLVED

**Decision:** Remove it entirely. It served its purpose during development and is now superseded by the encounter/depart ship functionality.

**Implementation:** Delete the "Ship Render Offset" TreeNode from the dev utils menu (lines ~970-1010 in gameloop.jl).

### 12.5 HexFlowProcGen Dependencies

The `HexFlowProcGen` package will need to import the new types from FlowEngine. Currently it imports:
```julia
using FlowEngine: GameMap, ShipMap, add_ship!, offset_ship!, ...
```

Need to add:
```julia
using FlowEngine: set_docking_status!, ApproachingDockStat, AxialCoord
```

Or these could be re-exported via HexFrame if AxialCoord is already there (it is).

---

## 13. Testing Strategy

1. **Run the game** after implementing FlowEngine changes to verify ShipMap struct changes don't break loading
2. **Test old map loading** with a saved map from before the changes
3. **Test encounter_ship!** via the existing "Encounter Ship" button in dev utils
4. **Test delete ship** via new UI
5. **Test depart ship** via new UI and verify ship is removed when animation completes
6. **Run HexFlowProcGen tests** to verify encounter_ship! smoke test still passes

---

## 14. Potential Future Enhancements

1. **Easing functions** for approach/depart animations (currently linear)
2. **Sound effects** triggered by docking status changes
3. **Visual effects** (particles, trails) during approach/depart
4. **Automatic boarding mechanics** when ships become Connected
5. **Collision detection** to prevent ships occupying the same space during animations
Additional Implementation Notes

### Serialization

The new types (`RenderPosOffsetState`, `ConnectedDockStat`, `ApproachingDockStat`, `DepartingDockStat`) should include `@struct_hash_equal` declarations to ensure proper serialization with JLD2:

```julia
@struct_hash_equal RenderPosOffsetState
# Abstract types don't need @struct_hash_equal
@struct_hash_equal ConnectedDockStat
@struct_hash_equal ApproachingDockStat
@struct_hash_equal DepartingDockStat
```

### 5elper Function Location

The `calculate_depart_direction` function should be placed in **gameloop.jl** near the top of the file (after imports), as it's only used by the UI code and doesn't belong in a core package.

---

## 14. 