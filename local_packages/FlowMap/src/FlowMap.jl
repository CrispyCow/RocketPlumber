module FlowMap

using HexFrame, HexComponentsAPI
import HexComponentsAPI: placement_valid

using StructEquality
using StaticArrays
using DataStructures: BinaryMinHeap

# Type Exports
export ShipMap, GameMap, RenderPosOffsetState
export DockingStatus, ConnectedDockStat, ApproachingDockStat, DepartingDockStat
export AbstractSpaceMap, SpaceMapEmpty, SpaceMapState, ManoeuvreData
export ManoeuvrePhase, PHASE_WAIT_APPROACH, PHASE_MAIN_BURN, PHASE_COAST, PHASE_DECEL_BURN, PHASE_ENCOUNTER_READY
export EncounterPoint, EncounterEvent
# Function Exports
export add_ship!, remove_ship!, get_all_ship_names, has_ship, get_ship, offset_ship!
# GameMap Abstraction Functions
export get_component, has_component, set_component!, delete_component!, delete_all_components!
export get_pipe, has_pipe, set_pipe!, delete_pipe!, delete_all_pipes!
export get_all_components, get_all_pipes
export count_components, count_pipes, count_surface_tiles
export delete_all_components!, delete_all_pipes!, delete_all_surface_tiles!
export is_on_surface_tile, set_surface_tile!, delete_surface_tile!, get_all_surface_tiles
export has_component_any_ship, get_component_any_ship, has_pipe_any_ship, get_pipe_any_ship, is_on_surface_tile_any_ship
# Convenience helpers that search all ships (useful for UI and queries where ship is not known)
export can_place_component_at, can_place_pipe_at, can_remove_surface_at, is_node_on_ship_surface
export get_all_surfaces_combined, find_ship_surface_edgetiles!
export get_axial_bounds, get_cartesian_bounds, get_surface_centroid
export find_ship_for_surface, find_ships_adjacent_to_coord, would_bridge_ships, find_valid_ship_for_placement, find_ship_with_component, find_ship_with_pipe
export find_ship_for_node
# Ship render and docking exports
export get_ship_render_offset, get_render_offset, update_render_offset!, get_approach_axis
export get_docking_status, set_docking_status!, update_docking!, clear_all_docking_statuses!
# Space map and velocity exports
export get_velocity, set_velocity!, get_space_map_seed, get_time_years, set_time_years!
export get_active_manoeuvre, set_active_manoeuvre!, clear_active_manoeuvre!, has_active_manoeuvre
export initialise_spacemap!, get_spacemap, get_mass
export get_position, set_position!, get_target_time, set_target_time!
export is_time_progressing, get_encounter_points

# ===============================================================
# Game State Struct Types
# ===============================================================

"""
Encapsulates state for a linear maneuver in render offset space.
Used to animate ships moving between positions.
"""
@kwdef mutable struct RenderPosOffsetState
    current_offset::AxialCoord
    target_offset::AxialCoord
    offset_step::Float64  # Distance to move per update
end
@struct_hash_equal RenderPosOffsetState

"Returns the current render offset position"
get_render_offset(state::RenderPosOffsetState)::AxialCoord = state.current_offset

"""
Moves current_offset one step closer to target_offset along the line between them.
Clamps to target if the step would overshoot. Returns true if target has been reached.
"""
function update_render_offset!(state::RenderPosOffsetState)::Bool
    diff = state.target_offset - state.current_offset
    distance_to_target = sqrt(diff.q^2 + diff.r^2)

    # Easing parameters based on current proximity to dock (zero offset)
    proximity_factor = 0.015
    min_speed = 0.005    # Ensure we actually finish moving

    current_offset_mag = sqrt(state.current_offset.q^2 + state.current_offset.r^2)

    # Calculate step size: Proportional to distance from dock, but clamped to max speed.
    step_size = clamp(current_offset_mag * proximity_factor, min_speed, state.offset_step)

    # If we're already at the target (or the next step would overshoot), snap to it
    if distance_to_target <= step_size || distance_to_target == 0.0
        state.current_offset = state.target_offset
        return true
    end

    # Move one step towards target
    direction_q = diff.q / distance_to_target
    direction_r = diff.r / distance_to_target
    state.current_offset = AxialCoord(
        state.current_offset.q + direction_q * step_size,
        state.current_offset.r + direction_r * step_size
    )
    return false
end

# Docking status types and interface
abstract type DockingStatus end

"""
Ship is connected/docked with no render offset. This is the default/resting state.
"""
struct ConnectedDockStat <: DockingStatus
    approach_axis::Union{HexAxis, Nothing}
end
@struct_hash_equal ConnectedDockStat
"Default constructor for a connected docking state with no saved approach axis."
ConnectedDockStat() = ConnectedDockStat(nothing)
get_render_offset(::ConnectedDockStat)::Union{AxialCoord, Nothing} = nothing
update_render_offset!(::ConnectedDockStat)::Bool = false
get_approach_axis(status::ConnectedDockStat)::Union{HexAxis, Nothing} = status.approach_axis

"""
Ship is approaching/docking - moving from a distant position towards connected position.
When motion completes, should transition to ConnectedDockStat.
"""
struct ApproachingDockStat <: DockingStatus
    motion::RenderPosOffsetState
    approach_axis::Union{HexAxis, Nothing}
end
@struct_hash_equal ApproachingDockStat
"Transparent constructor matching RenderPosOffsetState arguments"
function ApproachingDockStat(current_offset::AxialCoord, target_offset::AxialCoord, offset_step::Float64, approach_axis::Union{HexAxis, Nothing})
    return ApproachingDockStat(RenderPosOffsetState(current_offset, target_offset, offset_step), approach_axis)
end
get_render_offset(status::ApproachingDockStat)::AxialCoord = get_render_offset(status.motion)
update_render_offset!(status::ApproachingDockStat)::Bool = update_render_offset!(status.motion)
get_approach_axis(status::ApproachingDockStat)::Union{HexAxis, Nothing} = status.approach_axis

"""
Ship is departing - moving from connected position towards a distant position.
When motion completes, the ship should be removed from the GameMap.
"""
struct DepartingDockStat <: DockingStatus
    motion::RenderPosOffsetState
    approach_axis::Union{HexAxis, Nothing}
end
@struct_hash_equal DepartingDockStat
"Transparent constructor matching RenderPosOffsetState arguments"
function DepartingDockStat(current_offset::AxialCoord, target_offset::AxialCoord, offset_step::Float64, approach_axis::Union{HexAxis, Nothing})
    return DepartingDockStat(RenderPosOffsetState(current_offset, target_offset, offset_step), approach_axis)
end
get_render_offset(status::DepartingDockStat)::AxialCoord = get_render_offset(status.motion)
update_render_offset!(status::DepartingDockStat)::Bool = update_render_offset!(status.motion)
get_approach_axis(status::DepartingDockStat)::Union{HexAxis, Nothing} = status.approach_axis

# ===============================================================
# Space Map Types
# ===============================================================

"Abstract base for all space map representations."
abstract type AbstractSpaceMap end

"A single encounter point — a ship moving through space on a linear trajectory."
@kwdef mutable struct EncounterPoint
    index::Int                                          # Unique, permanent index (1-based)
    iteration::Int = 0                                  # Incremented each time this point is recycled
    base_velocity::Float64                              # Immutable speed magnitude (relative to player)
    position::SVector{2, Float64} = SVector(0.0, 0.0)   # Position at spawn_time
    velocity::SVector{2, Float64} = SVector(0.0, 0.0)   # Actual velocity vector (absolute)
    spawn_time::Float64 = 0.0                           # Time (years) when the current trajectory started
    ship_type_seed::UInt32 = UInt32(0)                  # Seed for proc-gen
end

"Event representing when an encounter point crosses the disappear line."
struct EncounterEvent
    time::Float64   # Predicted crossing time (years)
    index::Int      # Index into the encounter_points vector
end
Base.isless(a::EncounterEvent, b::EncounterEvent) = a.time < b.time

"""
Explicit phase for the manoeuvre state machine.
Transitions: WAIT_APPROACH → MAIN_BURN → COAST → DECEL_BURN → ENCOUNTER_READY
"""
@enum ManoeuvrePhase begin
    PHASE_WAIT_APPROACH     # Waiting for closest approach time
    PHASE_MAIN_BURN         # Velocity match + acceleration burn
    PHASE_COAST             # Coasting toward intercept
    PHASE_DECEL_BURN        # Deceleration / capture burn
    PHASE_ENCOUNTER_READY   # Burns complete — encounter triggers automatically
end

"""
Tracks an in-progress intercept manoeuvre via an explicit phase state machine.

Reference frames:
- `main_burn_dv`, `decel_burn_dv`:  **space-map space** — planned ΔV as full vectors.
  Direction is embedded in the vector (no separate direction field needed).
- `burn_target_dv`, `burn_remaining_dv`:  **ship space** — set at each phase transition
  by rotating the relevant space-map ΔV into ship space (where ship +X aligns with burn
  direction). Updated every tick by actual thrust.
"""
@kwdef mutable struct ManoeuvreData
    # ── Mutable state (updated during flight) ──
    phase::ManoeuvrePhase = PHASE_WAIT_APPROACH
    burn_target_dv::SVector{2, Float64} = SVector(0.0, 0.0)      # Ship-space: total ΔV the current burn aims to achieve
    burn_remaining_dv::SVector{2, Float64} = SVector(0.0, 0.0)    # Ship-space: ΔV still to apply in the current burn

    # ── Planned constants (set at planning time, immutable after construction) ──
    const main_burn_dv::SVector{2, Float64}                                        # Space-map-space ΔV for the main burn
    const decel_burn_dv::SVector{2, Float64}                                       # Space-map-space ΔV for the decel burn
    const closest_approach_time::Float64 = 0.0          # Time (years) when main burn begins
    const intercept_time::Float64 = 0.0                 # Time (years) when decel burn begins
    const target_encounter_index::Int = 0               # Index into encounter_points vector
    const trajectory_start_pos::SVector{2, Float64} = SVector(0.0, 0.0)  # Player position at plan time
    const trajectory_start_time::Float64 = 0.0          # Time when manoeuvre was planned
    const surplus_dv::Float64 = 0.0                     # Surplus ΔV over minimum (for display)
    const main_burn_position::SVector{2, Float64} = SVector(0.0, 0.0)    # Player position when first burn occurs (for rendering)
    const decel_burn_position::SVector{2, Float64} = SVector(0.0, 0.0)   # Position where intercept/second burn occurs (for rendering)
end
@struct_hash_equal ManoeuvreData

"Minimal space map placeholder that only stores ship velocity. Used for tutorials and old saves."
@kwdef mutable struct SpaceMapEmpty <: AbstractSpaceMap
    velocity::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
end
@struct_hash_equal SpaceMapEmpty

"Full space map state with seed, velocity, position, encounter points, and event queue."
@kwdef mutable struct SpaceMapState <: AbstractSpaceMap
    seed::UInt32 = UInt32(0)
    velocity::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    position::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    time_years::Float64 = 0.0
    target_time_years::Float64 = 0.0
    active_manoeuvre::Union{Nothing, ManoeuvreData} = nothing
    # Encounter system
    encounter_points::Vector{EncounterPoint} = EncounterPoint[]
    event_queue::BinaryMinHeap{EncounterEvent} = BinaryMinHeap{EncounterEvent}()
    neg_disappear_line_x::Float64 = -1600.0
    neg_spawn_line_x::Float64 = -1500.0
    pos_spawn_line_x::Float64 = 1500.0
    pos_disappear_line_x::Float64 = 1600.0
    last_line_step_x::Float64 = 0.0
    line_step_size::Float64 = 200.0
    viewport_half_width::Float64 = 1000.0
    viewport_half_height::Float64 = 500.0
end

# ===============================================================
# AbstractSpaceMap Accessor Functions
# ===============================================================

"Get the ship's current velocity vector."
get_velocity(sm::AbstractSpaceMap)::SVector{2, Float64} = sm.velocity

"Set the ship's velocity vector."
set_velocity!(sm::AbstractSpaceMap, v::SVector{2, Float64}) = (sm.velocity = v)

"Get the space map seed. Returns nothing for SpaceMapEmpty."
get_space_map_seed(::SpaceMapEmpty)::Nothing = nothing
get_space_map_seed(sm::SpaceMapState)::UInt32 = sm.seed

"Get the current time in years. Returns nothing for SpaceMapEmpty."
get_time_years(::SpaceMapEmpty)::Nothing = nothing
get_time_years(sm::SpaceMapState)::Float64 = sm.time_years

"Set the current time in years. No-op for SpaceMapEmpty."
set_time_years!(::SpaceMapEmpty, ::Float64) = nothing
set_time_years!(sm::SpaceMapState, t::Float64) = (sm.time_years = t)

"Get the active manoeuvre data, or nothing if none is active."
get_active_manoeuvre(::SpaceMapEmpty)::Nothing = nothing
get_active_manoeuvre(sm::SpaceMapState)::Union{Nothing, ManoeuvreData} = sm.active_manoeuvre

"Check whether a manoeuvre is currently active."
has_active_manoeuvre(::SpaceMapEmpty)::Bool = false
has_active_manoeuvre(sm::SpaceMapState)::Bool = !isnothing(sm.active_manoeuvre)

"Set an active manoeuvre on the space map. No-op for SpaceMapEmpty."
set_active_manoeuvre!(::SpaceMapEmpty, ::ManoeuvreData) = nothing
set_active_manoeuvre!(sm::SpaceMapState, m::ManoeuvreData) = (sm.active_manoeuvre = m)

"Clear any active manoeuvre. No-op for SpaceMapEmpty."
clear_active_manoeuvre!(::SpaceMapEmpty) = nothing
clear_active_manoeuvre!(sm::SpaceMapState) = (sm.active_manoeuvre = nothing)

# ===============================================================
# Position, Target Time, and Encounter Accessors
# ===============================================================

"Get the ship's current position vector."
get_position(::SpaceMapEmpty)::SVector{2, Float64} = SVector(0.0, 0.0)
get_position(sm::SpaceMapState)::SVector{2, Float64} = sm.position

"Set the ship's position vector. No-op for SpaceMapEmpty."
set_position!(::SpaceMapEmpty, ::SVector{2, Float64}) = nothing
set_position!(sm::SpaceMapState, p::SVector{2, Float64}) = (sm.position = p)

"Get the target time for time progression."
get_target_time(::SpaceMapEmpty)::Float64 = 0.0
get_target_time(sm::SpaceMapState)::Float64 = sm.target_time_years

"Set the target time for time progression. No-op for SpaceMapEmpty."
set_target_time!(::SpaceMapEmpty, ::Float64) = nothing
set_target_time!(sm::SpaceMapState, t::Float64) = (sm.target_time_years = t)

"Check whether time is currently being progressed (current < target)."
is_time_progressing(::SpaceMapEmpty)::Bool = false
is_time_progressing(sm::SpaceMapState)::Bool = sm.time_years < sm.target_time_years

"Get the encounter points vector. Empty for SpaceMapEmpty."
get_encounter_points(::SpaceMapEmpty) = EncounterPoint[]
get_encounter_points(sm::SpaceMapState) = sm.encounter_points

# ===============================================================
# Ship Map and Game Map Struct Types
# ===============================================================

"""
Holds the tiles and pipes that make up a single ship's map.
Also includes the ship surface which defines where components can be placed.
The docking_status represents the ship's docking/approach/depart state for cosmetic render offset animations.
"""
@kwdef mutable struct ShipMap
    components::Dict{TileCoord, ComponentOnTile} = Dict{TileCoord, ComponentOnTile}()
    pipe_behaviors::Dict{EdgeCoord, PipeBehavior} = Dict{EdgeCoord, PipeBehavior}()
    ship_tiles::Set{TileCoord} = Set{TileCoord}([TileCoord(0, 0)])
    docking_status::DockingStatus = ConnectedDockStat()
end
@struct_hash_equal ShipMap


"Top-level game map containing multiple named ships.  Always contains at least :primary."
@kwdef mutable struct GameMap
    ships::Dict{Symbol, ShipMap} = Dict(:primary => ShipMap())
    space_map::AbstractSpaceMap = SpaceMapEmpty()
end
@struct_hash_equal GameMap

"Construct a `GameMap` from a single `ShipMap`, using it as `:primary`"
function GameMap(ship::ShipMap)
    return GameMap(ships = Dict(:primary => ship))
end

# ===============================================================
# ShipMap Abstraction Functions
# ===============================================================

# Tile access for ShipMap
"Get the component at a tile coordinate on a ShipMap, or nothing if no component exists"
get_component(ship::ShipMap, coord::TileCoord) = get(ship.components, coord, nothing)

"Check if a component exists at a tile coordinate on a ShipMap"
has_component(ship::ShipMap, coord::TileCoord)::Bool = haskey(ship.components, coord)

"Set the component at a tile coordinate on a ShipMap"
function set_component!(ship::ShipMap, coord::TileCoord, component::ComponentOnTile)
    ship.components[coord] = component
    return nothing
end

"Set multiple components at tile coordinates on a ShipMap"
function set_component!(ship::ShipMap, components::AbstractDict{TileCoord, ComponentOnTile})
    for (coord, component) in components
        ship.components[coord] = component
    end
    return nothing
end

"Delete the component at a tile coordinate on a ShipMap"
function delete_component!(ship::ShipMap, coord::TileCoord)
    delete!(ship.components, coord)
    return nothing
end

"Iterate over all components in a ShipMap (returns pairs of TileCoord => ComponentOnTile)"
get_all_components(ship::ShipMap) = ship.components

# Pipe access for ShipMap
"Get the pipe behavior at an edge coordinate in a ShipMap, or nothing if no pipe exists"
get_pipe(ship::ShipMap, coord::EdgeCoord) = get(ship.pipe_behaviors, coord, nothing)

"Check if a pipe exists at an edge coordinate on a ShipMap"
has_pipe(ship::ShipMap, coord::EdgeCoord)::Bool = haskey(ship.pipe_behaviors, coord)

"Set the pipe behavior at an edge coordinate on a ShipMap"
function set_pipe!(ship::ShipMap, coord::EdgeCoord, pipe_behavior::PipeBehavior)
    ship.pipe_behaviors[coord] = pipe_behavior
    return nothing
end

"Set multiple pipe behaviors at edge coordinates on a ShipMap"
function set_pipe!(ship::ShipMap, pipes::AbstractDict{EdgeCoord, PipeBehavior})
    for (coord, pipe_behavior) in pipes
        ship.pipe_behaviors[coord] = pipe_behavior
    end
    return nothing
end

"Delete the pipe at an edge coordinate in a ShipMap"
function delete_pipe!(ship::ShipMap, coord::EdgeCoord)
    delete!(ship.pipe_behaviors, coord)
    return nothing
end

"Iterate over all pipes in a ShipMap (returns pairs of EdgeCoord => PipeBehavior)"
get_all_pipes(ship::ShipMap) = ship.pipe_behaviors

# Count functions for ShipMap
"Get the number of components in a ShipMap"
count_components(ship::ShipMap)::Int = length(ship.components)

"Get the number of pipes in a ShipMap"
count_pipes(ship::ShipMap)::Int = length(ship.pipe_behaviors)

"Get the number of ship surface tiles in a ShipMap"
count_surface_tiles(ship::ShipMap)::Int = length(ship.ship_tiles)

# Ship surface access for ShipMap
"Check if a coordinate is on the ship surface of a ShipMap"
is_on_surface_tile(coord::TileCoord, ship::ShipMap)::Bool = coord in ship.ship_tiles

"Add a tile coordinate to the ship surface on a ShipMap"
function set_surface_tile!(ship::ShipMap, coord::TileCoord)
    return push!(ship.ship_tiles, coord)
end

"Add multiple tile coordinates to the ship surface on a ShipMap"
function set_surface_tile!(ship::ShipMap, surface::AbstractSet{TileCoord})
    for coord in surface
        set_surface_tile!(ship, coord)
    end
    return nothing
end

"Remove a tile coordinate from the ship surface on a ShipMap. Returns true if removed, false if didn't exist"
function delete_surface_tile!(ship::ShipMap, coord::TileCoord)::Bool
    if coord in ship.ship_tiles
        delete!(ship.ship_tiles, coord)
        return true
    end
    return false
end

"Get all ship surface coordinates in a ShipMap (for rendering or iteration)"
get_all_surface_tiles(ship::ShipMap)::Set{TileCoord} = ship.ship_tiles

# Batch operations for ShipMap
"Delete all components from a ShipMap"
function delete_all_components!(ship::ShipMap)
    return empty!(ship.components)
end

"Delete all pipes from a ShipMap"
function delete_all_pipes!(ship::ShipMap)
    return empty!(ship.pipe_behaviors)
end

"Delete all surface tiles from a ShipMap"
function delete_all_surface_tiles!(ship::ShipMap)
    return empty!(ship.ship_tiles)
end

# ===============================================================
# GameMap Abstraction Functions
# ===============================================================
# These functions provide a clean, ship-routed interface to map internals.
# By default operations route to the `:primary` ship unless `ship_name` is supplied.

# Ship management
"Get a ShipMap by name or throw a descriptive error if it does not exist"
function _get_ship(gamemap::GameMap, ship_name::Symbol = :primary)::ShipMap
    if !haskey(gamemap.ships, ship_name)
        error("Ship '$ship_name' not found. Available ships: $(collect(keys(gamemap.ships)))")
    end
    return gamemap.ships[ship_name]
end

"Add a ShipMap to the GameMap under the provided symbol name; errors if the name already exists"
function add_ship!(gamemap::GameMap, name::Symbol, shipmap::ShipMap)
    if haskey(gamemap.ships, name)
        error("Ship '$name' already exists")
    end
    gamemap.ships[name] = shipmap
    return nothing
end

"Remove a ship from the GameMap by name (error if attempting to remove :primary)"
function remove_ship!(gamemap::GameMap, name::Symbol)
    if name == :primary
        error("Cannot remove primary ship")
    end
    delete!(gamemap.ships, name)
    return nothing
end

"Return a vector containing the Symbol names of all ships in the GameMap"
function get_all_ship_names(gamemap::GameMap)::Vector{Symbol}
    return collect(keys(gamemap.ships))
end

"Return true if a ship with the given name exists in the GameMap, false otherwise"
function has_ship(gamemap::GameMap, name::Symbol)::Bool
    return haskey(gamemap.ships, name)
end

"Get the ShipMap associated with `name` or throw if not found"
function get_ship(gamemap::GameMap, name::Symbol)::ShipMap
    return _get_ship(gamemap, name)
end

# Tile access
"Get the component at a tile coordinate on a specific ship, or nothing if no component exists"
get_component(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary) = get_component(_get_ship(gamemap, ship_name), coord)

"Check if a component exists at a tile coordinate on a specific ship"
has_component(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)::Bool = has_component(_get_ship(gamemap, ship_name), coord)

"Set the component at a tile coordinate on a specific ship"
function set_component!(gamemap::GameMap, coord::TileCoord, component::ComponentOnTile; ship_name::Symbol = :primary)
    set_component!(_get_ship(gamemap, ship_name), coord, component)
    return nothing
end

"Set multiple components at tile coordinates on a specific ship"
function set_component!(gamemap::GameMap, components::AbstractDict{TileCoord, ComponentOnTile}; ship_name::Symbol = :primary)
    set_component!(_get_ship(gamemap, ship_name), components)
    return nothing
end

"Delete the component at a tile coordinate on a specific ship"
function delete_component!(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)
    delete_component!(_get_ship(gamemap, ship_name), coord)
    return nothing
end

"Iterate over all components for a specific ship (returns pairs of TileCoord => ComponentOnTile)"
get_all_components(gamemap::GameMap; ship_name::Symbol = :primary) = get_all_components(_get_ship(gamemap, ship_name))


# Pipe access
"Get the pipe behavior at an edge coordinate on a specific ship, or nothing if no pipe exists"
get_pipe(gamemap::GameMap, coord::EdgeCoord; ship_name::Symbol = :primary) = get_pipe(_get_ship(gamemap, ship_name), coord)

"Check if a pipe exists at an edge coordinate on a specific ship"
has_pipe(gamemap::GameMap, coord::EdgeCoord; ship_name::Symbol = :primary)::Bool = has_pipe(_get_ship(gamemap, ship_name), coord)

"Set the pipe behavior at an edge coordinate on a specific ship"
function set_pipe!(gamemap::GameMap, coord::EdgeCoord, pipe_behavior::PipeBehavior; ship_name::Symbol = :primary)
    set_pipe!(_get_ship(gamemap, ship_name), coord, pipe_behavior)
    return nothing
end

"Set multiple pipe behaviors at edge coordinates on a specific ship"
function set_pipe!(gamemap::GameMap, pipes::AbstractDict{EdgeCoord, PipeBehavior}; ship_name::Symbol = :primary)
    set_pipe!(_get_ship(gamemap, ship_name), pipes)
    return nothing
end

"Delete the pipe at an edge coordinate on a specific ship"
function delete_pipe!(gamemap::GameMap, coord::EdgeCoord; ship_name::Symbol = :primary)
    delete_pipe!(_get_ship(gamemap, ship_name), coord)
    return nothing
end

"Iterate over all pipes for a specific ship (returns pairs of EdgeCoord => PipeBehavior)"
get_all_pipes(gamemap::GameMap; ship_name::Symbol = :primary) = get_all_pipes(_get_ship(gamemap, ship_name))

# Convenience helpers that search across all ships
"Check if any ship contains a component at the given tile coordinate; returns (found::Bool, ship::Union{Symbol, Nothing})"
function has_component_any_ship(gamemap::GameMap, coord::TileCoord)::Tuple{Bool, Union{Symbol, Nothing}}
    for (ship_name, ship) in gamemap.ships
        if has_component(ship, coord)
            return (true, ship_name)
        end
    end
    return (false, nothing)
end

"Get the first component found on any ship at the given tile coordinate; returns (component::Union{ComponentOnTile, Nothing}, ship::Union{Symbol, Nothing})"
function get_component_any_ship(gamemap::GameMap, coord::TileCoord)
    for (ship_name, ship) in gamemap.ships
        comp = get_component(ship, coord)
        if !isnothing(comp)
            return (comp, ship_name)
        end
    end
    return (nothing, nothing)
end

"Check if any ship contains a pipe at the given edge coordinate; returns (found::Bool, ship::Union{Symbol, Nothing})"
function has_pipe_any_ship(gamemap::GameMap, coord::EdgeCoord)::Tuple{Bool, Union{Symbol, Nothing}}
    for (ship_name, ship) in gamemap.ships
        if has_pipe(ship, coord)
            return (true, ship_name)
        end
    end
    return (false, nothing)
end

"Get the first pipe found on any ship at the given edge coordinate; returns (pipe::Union{PipeBehavior, Nothing}, ship::Union{Symbol, Nothing})"
function get_pipe_any_ship(gamemap::GameMap, coord::EdgeCoord)
    for (ship_name, ship) in gamemap.ships
        p = get_pipe(ship, coord)
        if !isnothing(p)
            return (p, ship_name)
        end
    end
    return (nothing, nothing)
end

"Check whether the coordinate is part of any ship surface; returns (found::Bool, ship::Union{Symbol, Nothing})"
function is_on_surface_tile_any_ship(coord::TileCoord, gamemap::GameMap)::Tuple{Bool, Union{Symbol, Nothing}}
    for (ship_name, ship) in gamemap.ships
        if is_on_surface_tile(coord, ship)
            return (true, ship_name)
        end
    end
    return (false, nothing)
end

# Count functions
"Get the number of components in the ship"
count_components(gamemap::GameMap; ship_name::Symbol = :primary)::Int = count_components(_get_ship(gamemap, ship_name))

"Get the number of pipes in the ship"
count_pipes(gamemap::GameMap; ship_name::Symbol = :primary)::Int = count_pipes(_get_ship(gamemap, ship_name))

"Get the number of ship surface tiles for the ship"
count_surface_tiles(gamemap::GameMap; ship_name::Symbol = :primary)::Int = count_surface_tiles(_get_ship(gamemap, ship_name))

# Batch operations
"Delete all components from a ship"
function delete_all_components!(gamemap::GameMap; ship_name::Symbol = :primary)
    return delete_all_components!(_get_ship(gamemap, ship_name))
end

"Delete all pipes from a ship"
function delete_all_pipes!(gamemap::GameMap; ship_name::Symbol = :primary)
    return delete_all_pipes!(_get_ship(gamemap, ship_name))
end

"Delete all surface tiles (remove all surface tiles) from a ship"
function delete_all_surface_tiles!(gamemap::GameMap; ship_name::Symbol = :primary)
    return delete_all_surface_tiles!(_get_ship(gamemap, ship_name))
end

# Ship surface access
"Check if a coordinate is on the ship surface"
is_on_surface_tile(coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Bool = is_on_surface_tile(coord, _get_ship(gamemap, ship_name))

"Default implimentation for placement_valid on a gamemap"
function placement_valid(behav::T, coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary, kwargs...) where {T <: ComponentBehavior}
    if is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return (true, "")
    else
        return (false, "Not on ship surface")
    end
end

"Add a tile coordinate to the ship surface"
function set_surface_tile!(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)
    return set_surface_tile!(_get_ship(gamemap, ship_name), coord)
end

"Add multiple tile coordinates to the ship surface"
function set_surface_tile!(gamemap::GameMap, surface::AbstractSet{TileCoord}; ship_name::Symbol = :primary)
    set_surface_tile!(_get_ship(gamemap, ship_name), surface)
    return nothing
end

"Remove a tile coordinate from the ship surface. Returns true if removed, false if didn't exist"
function delete_surface_tile!(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)::Bool
    return delete_surface_tile!(_get_ship(gamemap, ship_name), coord)
end

"Get all ship surface coordinates (for rendering or iteration)"
get_all_surface_tiles(gamemap::GameMap; ship_name::Symbol = :primary)::Set{TileCoord} = get_all_surface_tiles(_get_ship(gamemap, ship_name))

"Get the combined ship surface coordinates across all ships in the GameMap"
function get_all_surfaces_combined(gamemap::GameMap)::Set{TileCoord}
    combined = Set{TileCoord}()
    for (_, ship) in gamemap.ships
        union!(combined, get_all_surface_tiles(ship))
    end
    return combined
end

"""
Calculate the axial coordinate extremes for a set of surface tiles.
Accepts an `AbstractSet{TileCoord}` and returns a `HexFrame.AxialBounds` tuple containing the tile
coordinate furthest along each `HexAxis` direction. This operates on the provided tile set and
is used by `ShipMap` and `GameMap` overloads.
"""
function get_axial_bounds(tiles::AbstractSet{TileCoord})::HexFrame.AxialBounds
    # Handle empty set case - return origin for all directions
    if isempty(tiles)
        origin = TileCoord(0, 0)
        return (Q_POS = origin, R_NEG = origin, S_POS = origin, Q_NEG = origin, R_POS = origin, S_NEG = origin)
    end

    # Initialise tracking for each HexAxis direction
    extremes = Dict{HexFrame.HexAxis, Tuple{Float64, TileCoord}}()
    for axis in instances(HexFrame.HexAxis)
        extremes[axis] = (-Inf, TileCoord(0, 0))
    end

    # Single iteration through all surface tiles
    for tile in tiles
        tile_axial = AxialCoord(Float64(tile.q), Float64(tile.r))

        for axis in instances(HexFrame.HexAxis)
            axis_vec = HexFrame.hex_vert_vecs[axis]
            projection = tile_axial.q * axis_vec.q + tile_axial.r * axis_vec.r

            if projection > extremes[axis][1]
                extremes[axis] = (projection, tile)
            end
        end
    end

    return (
        Q_POS = extremes[HexFrame.Q_POS][2],
        R_NEG = extremes[HexFrame.R_NEG][2],
        S_POS = extremes[HexFrame.S_POS][2],
        Q_NEG = extremes[HexFrame.Q_NEG][2],
        R_POS = extremes[HexFrame.R_POS][2],
        S_NEG = extremes[HexFrame.S_NEG][2],
    )
end

# Convenience overloads that operate on ShipMap / GameMap by delegating
get_axial_bounds(ship::ShipMap)::HexFrame.AxialBounds = get_axial_bounds(get_all_surface_tiles(ship))
get_axial_bounds(gamemap::GameMap)::HexFrame.AxialBounds = get_axial_bounds(get_all_surfaces_combined(gamemap))

"""
Calculate the cartesian coordinate extremes for a set of surface tiles.
Accepts an `AbstractSet{TileCoord}` and returns a `HexFrame.CartesianBounds` tuple with the cartesian
x/y values furthest from the origin in each direction. This operates on the provided tile set and
is used by `ShipMap` and `GameMap` overloads.

Note: Y_POS is the maximum y value (top of screen), Y_NEG is minimum (bottom).
X_POS is maximum x (right), X_NEG is minimum (left).
"""
function get_cartesian_bounds(tiles::AbstractSet{TileCoord})::HexFrame.CartesianBounds
    # Handle empty set case - return zeros
    if isempty(tiles)
        return (X_POS = 0.0, X_NEG = 0.0, Y_POS = 0.0, Y_NEG = 0.0)
    end

    # Initialise with first tile
    first_tile = first(tiles)
    first_cart = HexFrame.to_cartesian(first_tile)
    x_max, x_min = first_cart.x, first_cart.x
    y_max, y_min = first_cart.y, first_cart.y

    # Single iteration through tiles
    for tile in tiles
        cart = HexFrame.to_cartesian(tile)
        x_max = max(x_max, cart.x)
        x_min = min(x_min, cart.x)
        y_max = max(y_max, cart.y)
        y_min = min(y_min, cart.y)
    end

    return (X_POS = x_max, X_NEG = x_min, Y_POS = y_max, Y_NEG = y_min)
end
get_cartesian_bounds(ship::ShipMap)::HexFrame.CartesianBounds = get_cartesian_bounds(get_all_surface_tiles(ship))
get_cartesian_bounds(gamemap::GameMap)::HexFrame.CartesianBounds = get_cartesian_bounds(get_all_surfaces_combined(gamemap))

"Get the centroid of a set of surface tiles in axial coordinates. Returns nothing for an empty set."
function get_surface_centroid(tiles::AbstractSet{TileCoord})::Union{AxialCoord, Nothing}
    if isempty(tiles)
        return nothing
    end

    q_sum = 0.0
    r_sum = 0.0
    count = 0
    for tile in tiles
        q_sum += tile.q
        r_sum += tile.r
        count += 1
    end

    return AxialCoord(q_sum / count, r_sum / count)
end
get_surface_centroid(ship::ShipMap)::Union{AxialCoord, Nothing} = get_surface_centroid(get_all_surface_tiles(ship))
get_surface_centroid(gamemap::GameMap, ship_name::Symbol)::Union{AxialCoord, Nothing} = get_surface_centroid(_get_ship(gamemap, ship_name))


"Count how many of a tile's 6 adjacent neighbors are present in the surface set."
@inline function count_surfacetile_adjacencies(surface_set::Set{TileCoord}, tile::TileCoord)::Int
    adjacent_tiles = HexFrame.get_adjacent_tiles_for_tile(tile)
    return count(adj_tile -> adj_tile in surface_set, adjacent_tiles)
end

"Update a set with tiles that are on the boundary of a single ShipMap"
function find_ship_surface_edgetiles!(edgesurface::Set{TileCoord}, ship::ShipMap)
    empty!(edgesurface)
    for tile in ship.ship_tiles
        if count_surfacetile_adjacencies(ship.ship_tiles, tile) != 6
            push!(edgesurface, tile)
        end
    end
    return nothing
end

"Update a set with tiles that are on the boundary of all ships (combined). Aggregates ship-level results."
function find_ship_surface_edgetiles!(edgesurface::Set{TileCoord}, gamemap::GameMap)
    empty!(edgesurface)
    tmp = Set{TileCoord}()
    for (_, ship) in gamemap.ships
        empty!(tmp)
        find_ship_surface_edgetiles!(tmp, ship)
        union!(edgesurface, tmp)
    end
    return nothing
end

# ===============================================================
# Placement Validation Functions
# ===============================================================

"Check if a node is connected to the ship surface by verifying that at least one of the tiles adjacent to the node is on the ship surface."
function is_node_on_ship_surface(node_abs::NodeCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Tuple{Bool, String}
    # Get the tiles adjacent to this node
    adjacent_tiles = get_adjacent_tiles_for_node(node_abs)

    # Check if any adjacent tile is on the specified ship surface
    for (tile, _) in adjacent_tiles
        if is_on_surface_tile(tile, gamemap; ship_name = ship_name)
            return (true, "")
        end
    end

    # No adjacent tiles on surface
    return (false, "Node is not connected to ship surface")
end

"Check if a component can be placed at a coordinate"
function can_place_component_at(coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Tuple{Bool, String}
    if !is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return (false, "Not on ship surface")
    end
    return (true, "")
end

"Check if a pipe can be placed at an edge coordinate (both endpoint nodes must be on ship surface)"
function can_place_pipe_at(coord::EdgeCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Tuple{Bool, String}
    # Get the two node coordinates for this edge
    v1_node = to_nodecoord(coord.v1)
    v2_node = to_nodecoord(coord.v2)

    # Check that the first node is connected to ship surface
    v1_valid, v1_reason = is_node_on_ship_surface(v1_node, gamemap; ship_name = ship_name)
    if !v1_valid
        return (false, "Pipe endpoint node at $(coord.v1.tile) is not connected to ship surface")
    end

    # Check that the second node is connected to ship surface
    v2_valid, v2_reason = is_node_on_ship_surface(v2_node, gamemap; ship_name = ship_name)
    if !v2_valid
        return (false, "Pipe endpoint node at $(coord.v2.tile) is not connected to ship surface")
    end

    return (true, "")
end

"Check if a surface tile can be removed (must not have a component on it)"
function can_remove_surface_at(coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Tuple{Bool, String}
    if has_component(gamemap, coord; ship_name = ship_name)
        return (false, "Surface cannot be deleted under a component, delete component first")
    end
    # TODO: This validation doesn't prevent nozzles from being left floating when their input node's
    # surface tile is removed. Consider adding a check that iterates through all components and validates
    # their placement after surface removal, or implement a separate validation pass that can be triggered
    # when editing surface tiles. For now, users can create invalid states by removing surface under
    # nozzle input nodes, but this won't cause crashes - just invalid placement that can be fixed.
    return (true, "")
end

# ===============================================================
# Helper Functions
# ===============================================================

"Find which ship (if any) owns the surface tile at a coordinate"
function find_ship_for_surface(gamemap::GameMap, coord::TileCoord)::Union{Symbol, Nothing}
    for (name, ship) in gamemap.ships
        if coord in ship.ship_tiles
            return name
        end
    end
    return nothing
end

"Find which ship(s) have surfaces adjacent to a coordinate"
function find_ships_adjacent_to_coord(gamemap::GameMap, coord::TileCoord)::Vector{Symbol}
    adjacent_tiles = HexFrame.get_adjacent_tiles_for_tile(coord)
    adjacent_ships = Symbol[]
    for adj_tile in adjacent_tiles
        ship_name = find_ship_for_surface(gamemap, adj_tile)
        if !isnothing(ship_name) && !(ship_name in adjacent_ships)
            push!(adjacent_ships, ship_name)
        end
    end
    return adjacent_ships
end

"Check if placing a surface at coord would connect multiple ships (invalid)"
function would_bridge_ships(gamemap::GameMap, coord::TileCoord)::Bool
    adjacent_ships = find_ships_adjacent_to_coord(gamemap, coord)
    return length(adjacent_ships) > 1
end

"Find which ship a component/pipe should belong to by testing placement_valid on all ships"
function find_valid_ship_for_placement(
        component::ComponentBehavior,
        coord::TileCoord,
        gamemap::GameMap;
        rotation::HexAxis
    )::Union{Symbol, Nothing}
    for (ship_name, _) in gamemap.ships
        is_valid, _ = placement_valid(component, coord, gamemap; rotation = rotation, ship_name = ship_name)
        if is_valid
            return ship_name
        end
    end
    return nothing
end

"Find which ship owns a component at a given coordinate (searches all ships)"
function find_ship_with_component(gamemap::GameMap, coord::TileCoord)::Union{Symbol, Nothing}
    for (ship_name, ship) in gamemap.ships
        if haskey(ship.components, coord)
            return ship_name
        end
    end
    return nothing
end

"Find which ship owns a pipe at a given edge coordinate (searches all ships)"
function find_ship_with_pipe(gamemap::GameMap, coord::EdgeCoord)::Union{Symbol, Nothing}
    for (ship_name, ship) in gamemap.ships
        if haskey(ship.pipe_behaviors, coord)
            return ship_name
        end
    end
    return nothing
end

# ===============================================================
# Ship Docking & Render Offset Functions
# ===============================================================

"Offset all coordinates in a ShipMap in-place by a TileCoord offset."
function offset_ship!(shipmap::ShipMap, offset::TileCoord)
    # Offset components
    new_components = Dict{TileCoord, ComponentOnTile}()
    sizehint!(new_components, length(shipmap.components))
    for (coord, comp) in shipmap.components
        new_coord = TileCoord(coord.q + offset.q, coord.r + offset.r)
        new_components[new_coord] = comp
    end
    empty!(shipmap.components)
    merge!(shipmap.components, new_components)

    # Offset pipes
    new_pipes = Dict{EdgeCoord, PipeBehavior}()
    sizehint!(new_pipes, length(shipmap.pipe_behaviors))
    for (edge, pipe) in shipmap.pipe_behaviors
        v1_offset = VertexCoord(
            TileCoord(edge.v1.tile.q + offset.q, edge.v1.tile.r + offset.r),
            edge.v1.dir
        )
        v2_offset = VertexCoord(
            TileCoord(edge.v2.tile.q + offset.q, edge.v2.tile.r + offset.r),
            edge.v2.dir
        )
        new_edge = EdgeCoord(v1_offset, v2_offset)
        new_pipes[new_edge] = pipe
    end
    empty!(shipmap.pipe_behaviors)
    merge!(shipmap.pipe_behaviors, new_pipes)

    # Offset surface tiles
    new_surface = Set{TileCoord}()
    sizehint!(new_surface, length(shipmap.ship_tiles))
    for coord in shipmap.ship_tiles
        new_coord = TileCoord(coord.q + offset.q, coord.r + offset.r)
        push!(new_surface, new_coord)
    end
    empty!(shipmap.ship_tiles)
    union!(shipmap.ship_tiles, new_surface)

    return nothing
end

"Get the render position offset for a ship (cosmetic offset for visual effects)"
function get_ship_render_offset(gamemap::GameMap, ship_name::Symbol)::AxialCoord
    return get_render_offset(_get_ship(gamemap, ship_name))
end

"Get the render offset for a ShipMap; returns AxialCoord(0,0) if no offset (e.g., ConnectedDockStat)"
function get_render_offset(ship::ShipMap)::AxialCoord
    offset = get_render_offset(ship.docking_status)
    return isnothing(offset) ? AxialCoord(0.0, 0.0) : offset
end

"Update render offset motion for a ship, returns true if motion is complete"
update_render_offset!(ship::ShipMap)::Bool = update_render_offset!(ship.docking_status)

"Get the docking status of a ship (ShipMap-level)"
get_docking_status(ship::ShipMap)::DockingStatus = ship.docking_status

"Set the docking status of a ship (ShipMap-level)"
function set_docking_status!(ship::ShipMap, status::DockingStatus)
    ship.docking_status = status
    return nothing
end

"Get the docking status of a ship by name. Returns nothing if ship not found."
function get_docking_status(gamemap::GameMap, ship_name::Symbol)::Union{DockingStatus, Nothing}
    if !haskey(gamemap.ships, ship_name)
        return nothing
    end
    return get_docking_status(gamemap.ships[ship_name])
end

"Set the docking status of a ship by name. Errors if ship not found."
function set_docking_status!(gamemap::GameMap, ship_name::Symbol, status::DockingStatus)
    if !haskey(gamemap.ships, ship_name)
        error("Ship '$ship_name' not found. Available ships: $(collect(keys(gamemap.ships)))")
    end
    set_docking_status!(gamemap.ships[ship_name], status)
    return nothing
end

"""
Update docking state machine for ships.

If `ship_name` keyword is provided, only update that ship.
If omitted (default `nothing`), loop through all ships in the `GameMap` and update each one.

Transitions:
- `ConnectedDockStat`: no motion
- `ApproachingDockStat`: update motion, transition to `ConnectedDockStat` when complete
- `DepartingDockStat`: update motion, remove ship when complete
"""
function update_docking!(gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)
    if isnothing(ship_name)
        for shipn in collect(keys(gamemap.ships))
            update_docking!(gamemap; ship_name = shipn)
        end
        return nothing
    end

    # Single-ship update path
    if !haskey(gamemap.ships, ship_name)
        return nothing
    end

    status = get_docking_status(gamemap.ships[ship_name])

    # Connected: no motion
    if status isa ConnectedDockStat
        return nothing
    end

    # Approaching: update motion and transition to connected when finished
    if status isa ApproachingDockStat
        if update_render_offset!(status)
            set_docking_status!(gamemap.ships[ship_name], ConnectedDockStat(get_approach_axis(status)))
        end
        return nothing
    end

    # Departing: update motion and remove ship when finished
    if status isa DepartingDockStat
        if update_render_offset!(status)
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

"Find which ship a node belongs to based on adjacent surface tiles. Returns :primary as fallback."
function find_ship_for_node(node::NodeCoord, gamemap::GameMap)::Symbol
    adjacent_tiles = get_adjacent_tiles_for_node(node)
    for (tile, _) in adjacent_tiles
        ship_name = find_ship_for_surface(gamemap, tile)
        if !isnothing(ship_name)
            return ship_name
        end
    end
    return :primary  # Fallback for ambiguous/unassociated nodes
end

# ===============================================================
# GameMap Space Map Delegation
# ===============================================================

"Get the space map from the game map."
get_spacemap(gamemap::GameMap)::AbstractSpaceMap = gamemap.space_map

"Get the ship's current velocity from the game map."
get_velocity(gamemap::GameMap)::SVector{2, Float64} = get_velocity(gamemap.space_map)

"Set the ship's velocity on the game map."
set_velocity!(gamemap::GameMap, v::SVector{2, Float64}) = set_velocity!(gamemap.space_map, v)

"Get the space map seed from the game map."
get_space_map_seed(gamemap::GameMap) = get_space_map_seed(gamemap.space_map)

"Get the current time in years from the game map."
get_time_years(gamemap::GameMap) = get_time_years(gamemap.space_map)

"Set the current time in years on the game map."
set_time_years!(gamemap::GameMap, t::Float64) = set_time_years!(gamemap.space_map, t)

"Get the active manoeuvre from the game map."
get_active_manoeuvre(gamemap::GameMap) = get_active_manoeuvre(gamemap.space_map)

"Check whether a manoeuvre is active on the game map."
has_active_manoeuvre(gamemap::GameMap)::Bool = has_active_manoeuvre(gamemap.space_map)

"Set an active manoeuvre on the game map."
set_active_manoeuvre!(gamemap::GameMap, m::ManoeuvreData) = set_active_manoeuvre!(gamemap.space_map, m)

"Clear any active manoeuvre on the game map."
clear_active_manoeuvre!(gamemap::GameMap) = clear_active_manoeuvre!(gamemap.space_map)

"Get the ship's current position from the game map."
get_position(gamemap::GameMap) = get_position(gamemap.space_map)

"Set the ship's position on the game map."
set_position!(gamemap::GameMap, p::SVector{2, Float64}) = set_position!(gamemap.space_map, p)

"Get the target time from the game map."
get_target_time(gamemap::GameMap) = get_target_time(gamemap.space_map)

"Set the target time on the game map."
set_target_time!(gamemap::GameMap, t::Float64) = set_target_time!(gamemap.space_map, t)

"Check whether time is progressing on the game map."
is_time_progressing(gamemap::GameMap)::Bool = is_time_progressing(gamemap.space_map)

"Get encounter points from the game map."
get_encounter_points(gamemap::GameMap) = get_encounter_points(gamemap.space_map)

"Overwrite the game map's space map with a new SpaceMapState using the given seed and velocity."
function initialise_spacemap!(gamemap::GameMap, seed::UInt32, velocity::SVector{2, Float64} = SVector{2, Float64}(100.0, 0.0))
    gamemap.space_map = SpaceMapState(seed = seed, velocity = velocity, time_years = 0.0)
    return nothing
end

"Calculate the total mass of all ships in the game map based on surface tile count."
function get_mass(gamemap::GameMap; mass_per_tile::Float64 = 1000.0)::Float64
    total_tiles = 0
    for (_, ship) in gamemap.ships
        total_tiles += count_surface_tiles(ship)
    end
    return total_tiles * mass_per_tile
end

end # module FlowMap
