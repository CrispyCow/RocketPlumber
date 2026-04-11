module FlowMap

using HexFrame, HexComponentsAPI, HexFluids
import HexComponentsAPI: placement_valid

using StructEquality
using StaticArrays
using DataStructures: Deque

#= ---------- Type Exports ----------- =#
export ShipMap, GameMap, RenderPosOffsetState
export DockingStatus, ConnectedDockStat, ApproachingDockStat, DepartingDockStat
export AbstractSpaceMap, SpaceMapEmpty, ManoeuvreData
export EncounterClass, ENCOUNTER_SHIP, ENCOUNTER_FUEL_CACHE, ENCOUNTER_SCRAP
export ManoeuvrePhase, PHASE_APPROACH_BURN, PHASE_COAST, PHASE_CAPTURE_BURN, PHASE_ENCOUNTER_READY
export EncounterPoint

#= ---------- Learning Progress Exports ----------- =#
export TutorialStatus, TUTORIAL_WAITING, TUTORIAL_IN_PROGRESS, TUTORIAL_COMPLETED
export AbstractLearningSystem, NoLearningSystem, TutorialState, LearningProgress, SandboxLearningState

#= ---------- Function Exports ----------- =#
export add_ship!, remove_ship!, get_all_ship_names, has_ship, get_ship, offset_ship!, swap_primary!

#= ---------- GameMap Abstraction Functions ----------- =#
export get_component, has_component, set_component!, delete_component!, delete_all_components!
export get_pipe, has_pipe, set_pipe!, delete_pipe!, delete_all_pipes!
export get_all_components, get_all_pipes
export count_components, count_pipes, count_surface_tiles
export delete_all_surface_tiles!
export is_on_surface_tile, set_surface_tile!, delete_surface_tile!, get_all_surface_tiles
export has_component_any_ship, get_component_any_ship, has_pipe_any_ship, get_pipe_any_ship, is_on_surface_tile_any_ship
export can_place_component_at, can_place_pipe_at, can_remove_surface_at, is_node_on_ship_surface
export get_all_surfaces_combined, find_ship_surface_edgetiles!, expand_tileset
export get_axial_bounds, get_cartesian_bounds, get_surface_centroid
export find_ship_for_surface, find_ships_adjacent_to_coord, would_bridge_ships, find_valid_ship_for_placement, find_ship_with_component, find_ship_with_pipe
export find_ship_for_node

#= ---------- Learning System Exports ----------- =#
export get_learning_system, set_learning_system!, has_learning_system, is_sandbox_learning

#= ---------- Off-Ship Pipe Exports ----------- =#
export can_place_pipe_offship, validate_offship_pipe_deletion, reassign_pipe_ownership!
export is_node_on_any_ship_surface, flood_search_pipes_from_node!

#= ---------- Ship Render and Docking Exports ----------- =#
export get_ship_render_offset, get_render_offset, update_render_offset!, compute_departure_axis
export get_docking_status, set_docking_status!, update_docking!, clear_all_docking_statuses!

#= ---------- Space Map and Velocity Exports ----------- =#
export get_velocity, set_velocity!, get_space_map_seed, get_time_years, set_time_years!
export get_active_manoeuvre, set_active_manoeuvre!, clear_active_manoeuvre!, has_active_manoeuvre, phase_description
export initialise_spacemap!, get_spacemap, get_mass, get_tile_mass, set_tile_mass!, get_dry_mass, get_wet_mass
export get_position, set_position!, get_target_time, set_target_time!
export is_time_progressing, get_encounter_points, get_last_stop_time, set_last_stop_time!

# ===============================================================
# Game State Struct Types
# ===============================================================

"Encapsulates state for a linear manoeuvre in render offset space, animating ships between positions."
@kwdef mutable struct RenderPosOffsetState
    current_offset::AxialCoord
    target_offset::AxialCoord
    offset_step::Float64  # Distance to move per update
end
@struct_hash_equal RenderPosOffsetState

"Returns the current render offset position"
get_render_offset(state::RenderPosOffsetState)::AxialCoord = state.current_offset

"Step `current_offset` towards `target_offset` with proximity easing. Returns `true` when target is reached."
function update_render_offset!(state::RenderPosOffsetState)::Bool
    diff = state.target_offset - state.current_offset
    distance_to_target = sqrt(diff.q^2 + diff.r^2)

    # Step size proportional to distance from dock (zero offset), clamped to max speed
    proximity_factor = 0.015
    min_speed = 0.005    # Ensure we actually finish moving

    current_offset_mag = sqrt(state.current_offset.q^2 + state.current_offset.r^2)
    step_size = clamp(current_offset_mag * proximity_factor, min_speed, state.offset_step)

    # Snap to target if close enough or at zero distance
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

#= ---------- Docking Status Types ----------- =#
abstract type DockingStatus end

"Ship is connected/docked with no render offset. Default/resting state."
struct ConnectedDockStat <: DockingStatus end
@struct_hash_equal ConnectedDockStat

get_render_offset(::ConnectedDockStat)::Union{AxialCoord, Nothing} = nothing
update_render_offset!(::ConnectedDockStat)::Bool = false

"Ship is approaching dock. Transitions to `ConnectedDockStat` when motion completes."
struct ApproachingDockStat <: DockingStatus
    motion::RenderPosOffsetState
end
@struct_hash_equal ApproachingDockStat

"Transparent constructor matching RenderPosOffsetState arguments."
function ApproachingDockStat(current_offset::AxialCoord, target_offset::AxialCoord, offset_step::Float64)
    return ApproachingDockStat(RenderPosOffsetState(current_offset, target_offset, offset_step))
end
get_render_offset(status::ApproachingDockStat)::AxialCoord = get_render_offset(status.motion)
update_render_offset!(status::ApproachingDockStat)::Bool = update_render_offset!(status.motion)

"Ship is departing. Removed from `GameMap` when motion completes."
struct DepartingDockStat <: DockingStatus
    motion::RenderPosOffsetState
end
@struct_hash_equal DepartingDockStat
function DepartingDockStat(current_offset::AxialCoord, target_offset::AxialCoord, offset_step::Float64)
    return DepartingDockStat(RenderPosOffsetState(current_offset, target_offset, offset_step))
end
get_render_offset(status::DepartingDockStat)::AxialCoord = get_render_offset(status.motion)
update_render_offset!(status::DepartingDockStat)::Bool = update_render_offset!(status.motion)

# ===============================================================
# Space Map Types
# ===============================================================

"Classifies what type of encounter an encounter point represents."
@enum EncounterClass::UInt8 begin
    ENCOUNTER_SHIP          # Jumbled ship with propulsion components
    ENCOUNTER_FUEL_CACHE    # Heavy platform with fuel tanks, no engines
    ENCOUNTER_SCRAP         # Random assortment of individual components
end

"A single encounter point — a ship moving through space on a linear trajectory."
@kwdef mutable struct EncounterPoint
    index::Int                                          # Unique, permanent index (1-based)
    iteration::Int = 0                                  # Incremented each time this point is recycled
    base_velocity::Float64                              # Immutable speed magnitude (relative to player)
    position::SVector{2, Float64} = SVector(0.0, 0.0)   # Position at spawn_time
    velocity::SVector{2, Float64} = SVector(0.0, 0.0)   # Actual velocity vector (absolute)
    spawn_time::Float64 = 0.0                           # Time (years) when the current trajectory started
    ship_type_seed::UInt32 = UInt32(0)                  # Seed for proc-gen
    encounter_class::EncounterClass = ENCOUNTER_SCRAP   # What kind of encounter this is
    fuel_tag::FluidTags = HexFluids.NONE                # Primary fuel type (NONE for scrap)
    display_name::String = ""                           # Human-readable name (generated at spawn time)
    richness::Float64 = 0.0                             # Richness at spawn time (cached for UI display)
end

"Manoeuvre phase for an intercept plan. New manoeuvres use APPROACH_BURN → COAST → CAPTURE_BURN → ENCOUNTER_READY."
@enum ManoeuvrePhase begin
    PHASE_APPROACH_BURN = 1     # Initial burn onto the planned approach trajectory
    PHASE_COAST = 2             # Coasting toward intercept
    PHASE_CAPTURE_BURN = 3      # Velocity-match / capture burn at intercept
    PHASE_ENCOUNTER_READY = 4   # Burns complete — encounter triggers automatically
end

"Return a player-facing description of the given manoeuvre phase."
function phase_description(phase::ManoeuvrePhase)::String
    phase == PHASE_APPROACH_BURN && return "Performing Approach Burn"
    phase == PHASE_COAST && return "Waiting for Target Intercept"
    phase == PHASE_CAPTURE_BURN && return "Performing Capture Burn"
    phase == PHASE_ENCOUNTER_READY && return "Target Reached"
    return "Unknown manoeuvre phase"
end

"""
Tracks an in-progress intercept manoeuvre via an explicit phase state machine.

Reference frames:
- `approach_burn_dv`, `capture_burn_dv`:  **space-map space** — planned ΔV as full vectors.
  Direction is embedded in the vector (no separate direction field needed).
- `burn_target_dv`, `burn_remaining_dv`:  **ship space** — the current active burn budget,
    where ship +X aligns with the burn direction. New manoeuvres pre-populate these fields
    for the approach burn at planning time; the capture burn values are filled when the
    intercept phase begins.
"""
@kwdef mutable struct ManoeuvreData
    # ── Mutable state (updated during flight) ──
    phase::ManoeuvrePhase = PHASE_APPROACH_BURN
    burn_target_dv::SVector{2, Float64} = SVector(0.0, 0.0)      # Ship-space: total ΔV the current burn aims to achieve
    burn_remaining_dv::SVector{2, Float64} = SVector(0.0, 0.0)   # Ship-space: ΔV still to apply in the current burn

    # ── Planned constants (set at planning time, immutable after construction) ──
    const approach_burn_dv::SVector{2, Float64}                            # Space-map-space ΔV for the first burn
    const capture_burn_dv::SVector{2, Float64}                             # Space-map-space ΔV for the intercept burn
    const approach_burn_time::Float64 = 0.0                                # Time (years) when the first burn begins
    const intercept_time::Float64 = 0.0                                    # Time (years) when the capture burn begins
    const target_encounter_index::Int = 0                                  # Index into encounter_points vector
    const capture_burn_position::SVector{2, Float64} = SVector(0.0, 0.0)   # Position where intercept / capture burn occurs
end
@struct_hash_equal ManoeuvreData

"Abstract base for all space map representations."
abstract type AbstractSpaceMap end

"Minimal space map placeholder that only stores ship velocity. Used for tutorials and maps without encounter state."
@kwdef mutable struct SpaceMapEmpty <: AbstractSpaceMap
    velocity::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
end
@struct_hash_equal SpaceMapEmpty

# ===============================================================
# AbstractSpaceMap Accessor Functions
# ===============================================================
# SpaceMapEmpty implementations here; SpaceMapState implementations in HexFlowProcGen

"Get the ship's current velocity vector."
get_velocity(sm::AbstractSpaceMap)::SVector{2, Float64} = sm.velocity

"Set the ship's velocity vector."
set_velocity!(sm::AbstractSpaceMap, v::SVector{2, Float64}) = (sm.velocity = v)

"Get the space map seed. Returns nothing for SpaceMapEmpty."
get_space_map_seed(::SpaceMapEmpty)::Nothing = nothing

"Get the current time in years. Returns nothing for SpaceMapEmpty."
get_time_years(::SpaceMapEmpty)::Nothing = nothing

"Set the current time in years. No-op for SpaceMapEmpty."
set_time_years!(::SpaceMapEmpty, ::Float64) = nothing

"Get the active manoeuvre data, or nothing if none is active."
get_active_manoeuvre(::SpaceMapEmpty)::Nothing = nothing

"Check whether a manoeuvre is currently active."
has_active_manoeuvre(::SpaceMapEmpty)::Bool = false

"Set an active manoeuvre on the space map. No-op for SpaceMapEmpty."
set_active_manoeuvre!(::SpaceMapEmpty, ::ManoeuvreData) = nothing

"Clear any active manoeuvre. No-op for SpaceMapEmpty."
clear_active_manoeuvre!(::SpaceMapEmpty) = nothing

# ===============================================================
# Position, Target Time, and Encounter Accessors
# ===============================================================

"Get the ship's current position vector."
get_position(::SpaceMapEmpty)::SVector{2, Float64} = SVector(0.0, 0.0)

"Set the ship's position vector. No-op for SpaceMapEmpty."
set_position!(::SpaceMapEmpty, ::SVector{2, Float64}) = nothing

"Get the target time for time progression."
get_target_time(::SpaceMapEmpty)::Float64 = 0.0

"Set the target time for time progression. No-op for SpaceMapEmpty."
set_target_time!(::SpaceMapEmpty, ::Float64) = nothing

"Check whether time is currently being progressed (current < target)."
is_time_progressing(::SpaceMapEmpty)::Bool = false

"Get the last time a warp stopped (for easing). Always 0.0 for SpaceMapEmpty."
get_last_stop_time(::SpaceMapEmpty)::Float64 = 0.0

"Set the last stop time. No-op for SpaceMapEmpty."
set_last_stop_time!(::SpaceMapEmpty, ::Float64) = nothing

"Get the encounter points vector. Empty for SpaceMapEmpty."
get_encounter_points(::SpaceMapEmpty) = EncounterPoint[]

"Overwrite the game map's space map. Implementation provided by HexFlowProcGen."
function initialise_spacemap! end

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

# ===============================================================
# Learning System Types
# ===============================================================

abstract type AbstractLearningSystem end

"Learning is disabled for this map."
struct NoLearningSystem <: AbstractLearningSystem end
@struct_hash_equal NoLearningSystem

@enum TutorialStatus::UInt8 begin
    TUTORIAL_WAITING = 0
    TUTORIAL_IN_PROGRESS = 1
    TUTORIAL_COMPLETED = 2
end

"Per-tutorial persistent state combining status and step progress."
@kwdef mutable struct TutorialState
    status::TutorialStatus = TUTORIAL_WAITING
    "1-based index of the furthest unlocked step (for in-game tutorials). Defaults to 1."
    unlocked_step::Int = 1
    "Cached blocker message for the current frontier step. `nothing` means the step is unblocked or informational."
    step_blocker::Union{Nothing, String} = nothing
end

"Persistent learning progress, saved with the map. Only tutorials with an entry in `tutorials` are considered active."
@kwdef mutable struct LearningProgress <: AbstractLearningSystem
    tutorials::Dict{Symbol, TutorialState} = Dict{Symbol, TutorialState}()
end

"Construct a `LearningProgress` pre-populated with `TUTORIAL_WAITING` entries for each ID."
function LearningProgress(active_ids::Vector{Symbol})
    tutorials = Dict{Symbol, TutorialState}(id => TutorialState() for id in active_ids)
    return LearningProgress(tutorials = tutorials)
end

"Single sandbox tutorial state stored directly on a sandbox map."
@kwdef mutable struct SandboxLearningState <: AbstractLearningSystem
    tutorial_id::Symbol
    level_index::Int = 1
    tutorial_state::TutorialState = TutorialState(status = TUTORIAL_IN_PROGRESS)
end


"Top-level game map containing multiple named ships.  Always contains at least :primary."
@kwdef mutable struct GameMap
    ships::Dict{Symbol, ShipMap} = Dict(:primary => ShipMap())
    space_map::AbstractSpaceMap = SpaceMapEmpty()
    learning_system::AbstractLearningSystem = NoLearningSystem()
end
@struct_hash_equal GameMap

"Construct a `GameMap` from a single `ShipMap`, using it as `:primary`"
function GameMap(ship::ShipMap)
    return GameMap(ships = Dict(:primary => ship))
end

"Get the learning system attached to a game map."
get_learning_system(gamemap::GameMap)::AbstractLearningSystem = gamemap.learning_system

"Set the learning system attached to a game map."
function set_learning_system!(gamemap::GameMap, learning_system::AbstractLearningSystem)
    gamemap.learning_system = learning_system
    return nothing
end

"Check whether a game map has any learning system enabled."
has_learning_system(gamemap::GameMap)::Bool = !(get_learning_system(gamemap) isa NoLearningSystem)

"Check whether a game map is a sandbox tutorial session."
is_sandbox_learning(gamemap::GameMap)::Bool = get_learning_system(gamemap) isa SandboxLearningState

# ===============================================================
# ShipMap Abstraction Functions
# ===============================================================

#= ---------- ShipMap: Component Access ----------- =#
"Get the component at a tile coordinate, or `nothing` if absent."
get_component(ship::ShipMap, coord::TileCoord) = get(ship.components, coord, nothing)

has_component(ship::ShipMap, coord::TileCoord)::Bool = haskey(ship.components, coord)

"Set a component (or multiple) at tile coordinate(s)."
function set_component!(ship::ShipMap, coord::TileCoord, component::ComponentOnTile)
    ship.components[coord] = component
    return nothing
end

function set_component!(ship::ShipMap, components::AbstractDict{TileCoord, ComponentOnTile})
    for (coord, component) in components
        ship.components[coord] = component
    end
    return nothing
end

function delete_component!(ship::ShipMap, coord::TileCoord)
    delete!(ship.components, coord)
    return nothing
end

get_all_components(ship::ShipMap) = ship.components

#= ---------- ShipMap: Pipe Access ----------- =#
"Get the pipe behaviour at an edge coordinate, or `nothing` if absent."
get_pipe(ship::ShipMap, coord::EdgeCoord) = get(ship.pipe_behaviors, coord, nothing)

has_pipe(ship::ShipMap, coord::EdgeCoord)::Bool = haskey(ship.pipe_behaviors, coord)

"Set a pipe behaviour (or multiple) at edge coordinate(s)."
function set_pipe!(ship::ShipMap, coord::EdgeCoord, pipe_behavior::PipeBehavior)
    ship.pipe_behaviors[coord] = pipe_behavior
    return nothing
end

function set_pipe!(ship::ShipMap, pipes::AbstractDict{EdgeCoord, PipeBehavior})
    for (coord, pipe_behavior) in pipes
        ship.pipe_behaviors[coord] = pipe_behavior
    end
    return nothing
end

function delete_pipe!(ship::ShipMap, coord::EdgeCoord)
    delete!(ship.pipe_behaviors, coord)
    return nothing
end

get_all_pipes(ship::ShipMap) = ship.pipe_behaviors

#= ---------- ShipMap: Counts ----------- =#
count_components(ship::ShipMap)::Int = length(ship.components)
count_pipes(ship::ShipMap)::Int = length(ship.pipe_behaviors)
count_surface_tiles(ship::ShipMap)::Int = length(ship.ship_tiles)

#= ---------- ShipMap: Surface Access ----------- =#
"Check if a coordinate is on the ship surface."
is_on_surface_tile(coord::TileCoord, ship::ShipMap)::Bool = coord in ship.ship_tiles

"Add tile coordinate(s) to the ship surface."
function set_surface_tile!(ship::ShipMap, coord::TileCoord)
    return push!(ship.ship_tiles, coord)
end

function set_surface_tile!(ship::ShipMap, surface::AbstractSet{TileCoord})
    for coord in surface
        set_surface_tile!(ship, coord)
    end
    return nothing
end

"Remove a tile from the ship surface. Returns `true` if removed, `false` if absent."
function delete_surface_tile!(ship::ShipMap, coord::TileCoord)::Bool
    if coord in ship.ship_tiles
        delete!(ship.ship_tiles, coord)
        return true
    end
    return false
end

get_all_surface_tiles(ship::ShipMap)::Set{TileCoord} = ship.ship_tiles

#= ---------- ShipMap: Batch Operations ----------- =#
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

#= ---------- Ship Management ----------- =#
"Get a `ShipMap` by name or throw if it does not exist."
function _get_ship(gamemap::GameMap, ship_name::Symbol = :primary)::ShipMap
    if !haskey(gamemap.ships, ship_name)
        error("Ship '$ship_name' not found. Available ships: $(collect(keys(gamemap.ships)))")
    end
    return gamemap.ships[ship_name]
end

"Add a `ShipMap` under the provided name; errors if it already exists."
function add_ship!(gamemap::GameMap, name::Symbol, shipmap::ShipMap)
    if haskey(gamemap.ships, name)
        error("Ship '$name' already exists")
    end
    gamemap.ships[name] = shipmap
    return nothing
end

"Remove a ship by name (cannot remove `:primary`)."
function remove_ship!(gamemap::GameMap, name::Symbol)
    if name == :primary
        error("Cannot remove primary ship")
    end
    delete!(gamemap.ships, name)
    return nothing
end

get_all_ship_names(gamemap::GameMap)::Vector{Symbol} = collect(keys(gamemap.ships))
has_ship(gamemap::GameMap, name::Symbol)::Bool = haskey(gamemap.ships, name)
get_ship(gamemap::GameMap, name::Symbol)::ShipMap = _get_ship(gamemap, name)

#= ---------- GameMap: Component Access ----------- =#
get_component(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary) = get_component(_get_ship(gamemap, ship_name), coord)
has_component(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)::Bool = has_component(_get_ship(gamemap, ship_name), coord)

"Set a component (or multiple) at tile coordinate(s) on a specific ship."
function set_component!(gamemap::GameMap, coord::TileCoord, component::ComponentOnTile; ship_name::Symbol = :primary)
    set_component!(_get_ship(gamemap, ship_name), coord, component)
    return nothing
end

function set_component!(gamemap::GameMap, components::AbstractDict{TileCoord, ComponentOnTile}; ship_name::Symbol = :primary)
    set_component!(_get_ship(gamemap, ship_name), components)
    return nothing
end

function delete_component!(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)
    delete_component!(_get_ship(gamemap, ship_name), coord)
    return nothing
end

get_all_components(gamemap::GameMap; ship_name::Symbol = :primary) = get_all_components(_get_ship(gamemap, ship_name))

#= ---------- GameMap: Pipe Access ----------- =#
get_pipe(gamemap::GameMap, coord::EdgeCoord; ship_name::Symbol = :primary) = get_pipe(_get_ship(gamemap, ship_name), coord)
has_pipe(gamemap::GameMap, coord::EdgeCoord; ship_name::Symbol = :primary)::Bool = has_pipe(_get_ship(gamemap, ship_name), coord)

"Set a pipe behaviour (or multiple) at edge coordinate(s) on a specific ship."
function set_pipe!(gamemap::GameMap, coord::EdgeCoord, pipe_behavior::PipeBehavior; ship_name::Symbol = :primary)
    set_pipe!(_get_ship(gamemap, ship_name), coord, pipe_behavior)
    return nothing
end

function set_pipe!(gamemap::GameMap, pipes::AbstractDict{EdgeCoord, PipeBehavior}; ship_name::Symbol = :primary)
    set_pipe!(_get_ship(gamemap, ship_name), pipes)
    return nothing
end

function delete_pipe!(gamemap::GameMap, coord::EdgeCoord; ship_name::Symbol = :primary)
    delete_pipe!(_get_ship(gamemap, ship_name), coord)
    return nothing
end

get_all_pipes(gamemap::GameMap; ship_name::Symbol = :primary) = get_all_pipes(_get_ship(gamemap, ship_name))

#= ---------- GameMap: Cross-Ship Queries ----------- =#
"Check if any ship contains a component at the given tile coordinate."
function has_component_any_ship(gamemap::GameMap, coord::TileCoord)::Tuple{Bool, Union{Symbol, Nothing}}
    for (ship_name, ship) in gamemap.ships
        if has_component(ship, coord)
            return (true, ship_name)
        end
    end
    return (false, nothing)
end

"Get the first component found on any ship at the given tile coordinate."
function get_component_any_ship(gamemap::GameMap, coord::TileCoord)
    for (ship_name, ship) in gamemap.ships
        comp = get_component(ship, coord)
        if !isnothing(comp)
            return (comp, ship_name)
        end
    end
    return (nothing, nothing)
end

"Check if any ship contains a pipe at the given edge coordinate."
function has_pipe_any_ship(gamemap::GameMap, coord::EdgeCoord)::Tuple{Bool, Union{Symbol, Nothing}}
    for (ship_name, ship) in gamemap.ships
        if has_pipe(ship, coord)
            return (true, ship_name)
        end
    end
    return (false, nothing)
end

"Get the first pipe found on any ship at the given edge coordinate."
function get_pipe_any_ship(gamemap::GameMap, coord::EdgeCoord)
    for (ship_name, ship) in gamemap.ships
        p = get_pipe(ship, coord)
        if !isnothing(p)
            return (p, ship_name)
        end
    end
    return (nothing, nothing)
end

"Check whether the coordinate is part of any ship's surface."
function is_on_surface_tile_any_ship(coord::TileCoord, gamemap::GameMap)::Tuple{Bool, Union{Symbol, Nothing}}
    for (ship_name, ship) in gamemap.ships
        if is_on_surface_tile(coord, ship)
            return (true, ship_name)
        end
    end
    return (false, nothing)
end

#= ---------- GameMap: Counts ----------- =#
count_components(gamemap::GameMap; ship_name::Symbol = :primary)::Int = count_components(_get_ship(gamemap, ship_name))
count_pipes(gamemap::GameMap; ship_name::Symbol = :primary)::Int = count_pipes(_get_ship(gamemap, ship_name))
count_surface_tiles(gamemap::GameMap; ship_name::Symbol = :primary)::Int = count_surface_tiles(_get_ship(gamemap, ship_name))

#= ---------- GameMap: Batch Operations ----------- =#
delete_all_components!(gamemap::GameMap; ship_name::Symbol = :primary) = delete_all_components!(_get_ship(gamemap, ship_name))
delete_all_pipes!(gamemap::GameMap; ship_name::Symbol = :primary) = delete_all_pipes!(_get_ship(gamemap, ship_name))
delete_all_surface_tiles!(gamemap::GameMap; ship_name::Symbol = :primary) = delete_all_surface_tiles!(_get_ship(gamemap, ship_name))

#= ---------- GameMap: Surface Access ----------- =#
"Check if a coordinate is on the ship surface."
is_on_surface_tile(coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Bool = is_on_surface_tile(coord, _get_ship(gamemap, ship_name))

"Default implementation for `placement_valid` on a `GameMap`."
function placement_valid(behav::T, coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary, kwargs...) where {T <: ComponentBehavior}
    if is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return (true, "")
    else
        return (false, "Not on ship surface")
    end
end

"Add tile coordinate(s) to the ship surface."
function set_surface_tile!(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)
    return set_surface_tile!(_get_ship(gamemap, ship_name), coord)
end
function set_surface_tile!(gamemap::GameMap, surface::AbstractSet{TileCoord}; ship_name::Symbol = :primary)
    set_surface_tile!(_get_ship(gamemap, ship_name), surface)
    return nothing
end

"Remove a tile from the ship surface. Returns `true` if removed, `false` if absent."
function delete_surface_tile!(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)::Bool
    return delete_surface_tile!(_get_ship(gamemap, ship_name), coord)
end

get_all_surface_tiles(gamemap::GameMap; ship_name::Symbol = :primary)::Set{TileCoord} = get_all_surface_tiles(_get_ship(gamemap, ship_name))

"Get the combined ship surface coordinates across all ships."
function get_all_surfaces_combined(gamemap::GameMap)::Set{TileCoord}
    combined = Set{TileCoord}()
    for (_, ship) in gamemap.ships
        union!(combined, get_all_surface_tiles(ship))
    end
    return combined
end

"Find the tile with the largest projection along each `HexAxis` direction."
function get_axial_bounds(tiles::AbstractSet{TileCoord})::HexFrame.AxialBounds
    if isempty(tiles)
        origin = TileCoord(0, 0)
        return (Q_POS = origin, R_NEG = origin, S_POS = origin, Q_NEG = origin, R_POS = origin, S_NEG = origin)
    end

    # Track (max_projection, best_tile) per axis using local variables to avoid Dict allocation
    origin = TileCoord(0, 0)
    best_proj = MVector{6, Float64}(-Inf, -Inf, -Inf, -Inf, -Inf, -Inf)
    best_tile = MVector{6, TileCoord}(origin, origin, origin, origin, origin, origin)

    for tile in tiles
        tile_q = Float64(tile.q)
        tile_r = Float64(tile.r)
        for axis in instances(HexFrame.HexAxis)
            axis_vec = HexFrame.hex_vert_vecs[axis]
            projection = tile_q * axis_vec.q + tile_r * axis_vec.r
            idx = Int(axis) + 1
            if projection > best_proj[idx]
                best_proj[idx] = projection
                best_tile[idx] = tile
            end
        end
    end

    return (
        Q_POS = best_tile[Int(HexFrame.Q_POS) + 1],
        R_NEG = best_tile[Int(HexFrame.R_NEG) + 1],
        S_POS = best_tile[Int(HexFrame.S_POS) + 1],
        Q_NEG = best_tile[Int(HexFrame.Q_NEG) + 1],
        R_POS = best_tile[Int(HexFrame.R_POS) + 1],
        S_NEG = best_tile[Int(HexFrame.S_NEG) + 1],
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

"""
Compute a departure direction for `ship_name` based on the relative position of ship centroids.
Returns the `HexAxis` pointing from the centroid of all other ships towards the departing ship.
Falls back to `Q_POS` when centroids coincide or the departing ship is the only one.
"""
function compute_departure_axis(gamemap::GameMap, ship_name::Symbol)::HexFrame.HexAxis
    departing_centroid = get_surface_centroid(gamemap, ship_name)
    isnothing(departing_centroid) && return HexFrame.Q_POS

    # Combined centroid of all other ships
    other_tiles = Set{TileCoord}()
    for (name, ship) in gamemap.ships
        name === ship_name && continue
        union!(other_tiles, get_all_surface_tiles(ship))
    end
    other_centroid = get_surface_centroid(other_tiles)
    isnothing(other_centroid) && return HexFrame.Q_POS  # departing ship is the only one

    direction = AxialCoord(departing_centroid.q - other_centroid.q, departing_centroid.r - other_centroid.r)
    return HexFrame.nearest_hex_axis(direction)
end


"Count how many of a tile's 6 adjacent neighbours are present in the surface set."
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

"Update a set with boundary tiles aggregated across all ships."
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

"Expand a tile set by one ring — returns a new set containing the original tiles plus all neighbours."
function expand_tileset(tiles::Set{TileCoord})::Set{TileCoord}
    expanded = copy(tiles)
    sizehint!(expanded, length(tiles) * 4)
    for tile in tiles
        for nb in HexFrame.get_adjacent_tiles_for_tile(tile)
            push!(expanded, nb)
        end
    end
    return expanded
end

"Expand a tile set by `n` rings by applying `expand_tileset` iteratively."
function expand_tileset(tiles::Set{TileCoord}, n::Integer)::Set{TileCoord}
    result = copy(tiles)
    for _ in 1:n
        result = expand_tileset(result)
    end
    return result
end

# ===============================================================
# Placement Validation Functions
# ===============================================================

"Return `true` if any tile adjacent to the node lies on the given ship's surface."
function is_node_on_ship_surface(node_abs::NodeCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Bool
    for (tile, _) in get_adjacent_tiles_for_node(node_abs)
        if is_on_surface_tile(tile, gamemap; ship_name = ship_name)
            return true
        end
    end
    return false
end

"Check if a component can be placed at a coordinate"
function can_place_component_at(coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Tuple{Bool, String}
    if !is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return (false, "Not on ship surface")
    end
    return (true, "")
end

"Check if a pipe can be placed at an edge coordinate (both endpoint nodes must be on ship surface)."
function can_place_pipe_at(coord::EdgeCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Tuple{Bool, String}
    v1_node = to_nodecoord(coord.v1)
    v2_node = to_nodecoord(coord.v2)
    if !is_node_on_ship_surface(v1_node, gamemap; ship_name = ship_name)
        return (false, "Pipe endpoint node at $(coord.v1.tile) is not connected to ship surface")
    end
    if !is_node_on_ship_surface(v2_node, gamemap; ship_name = ship_name)
        return (false, "Pipe endpoint node at $(coord.v2.tile) is not connected to ship surface")
    end
    return (true, "")
end

"Check if a surface tile can be removed (must not have a component on it)."
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
# Off-Ship Pipe Functions
# ===============================================================

#= ---------- Node Queries ----------- =#

"Check if a node is on any ship's surface (searches all ships)."
function is_node_on_any_ship_surface(node::NodeCoord, gamemap::GameMap)::Bool
    for (ship_name, _) in gamemap.ships
        if is_node_on_ship_surface(node, gamemap; ship_name = ship_name)
            return true
        end
    end
    return false
end

"""
Find which ship a node connects to, by surface-tile adjacency or pipe-edge ownership.
Returns `nothing` if unconnected. Unlike `find_ship_for_node`, has no fallback.
"""
function _find_connected_ship(node::NodeCoord, gamemap::GameMap)::Union{Symbol, Nothing}
    for (tile, _) in get_adjacent_tiles_for_node(node)
        ship_name = find_ship_for_surface(gamemap, tile)
        if !isnothing(ship_name)
            return ship_name
        end
    end

    # Slow path: check pipe edges radiating from this node's vertex
    if is_axis(node.dir)
        vertex = to_vertex(node)
        for edge in get_edges(vertex)
            for (ship_name, ship) in gamemap.ships
                if haskey(ship.pipe_behaviors, edge)
                    return ship_name
                end
            end
        end
    end

    return nothing
end

#= ---------- Placement & Deletion Validation ----------- =#

"""
    flood_search_pipes_from_node!(reachable, all_pipe_edges, start_node)

Flood-fill through pipe edges starting from `start_node`, collecting all reachable edges into
`reachable`. Only traverses edges present in `all_pipe_edges`. Uses BFS over the hex vertex
graph, following edges from vertex to vertex via shared pipe endpoints.

Placed in FlowMap (rather than FlowEngine) because it depends only on HexFrame primitives and
is needed by FlowMap's own validation logic.
"""
function flood_search_pipes_from_node!(reachable::Set{EdgeCoord}, all_pipe_edges, start_node::NodeCoord)
    visited_nodes = Set{NodeCoord}()
    queue = Deque{NodeCoord}()
    push!(queue, start_node)

    while !isempty(queue)
        node = popfirst!(queue)
        node in visited_nodes && continue
        push!(visited_nodes, node)

        vertex = to_vertex(node)
        for edge in get_edges(vertex) # 3 edges radiating from this vertex
            if edge in all_pipe_edges && edge ∉ reachable
                push!(reachable, edge)
                other_vertex = edge.v1 == vertex ? edge.v2 : edge.v1
                other_node = to_nodecoord(other_vertex)
                if other_node ∉ visited_nodes
                    push!(queue, other_node)
                end
            end
        end
    end
    return nothing
end

"""
    can_place_pipe_offship(coord, gamemap) → (valid, target_ship, reason)

Check if a pipe can be placed at `coord` when it doesn't fit entirely on a single ship's
surface. Requires at least one endpoint to be connected to a ship (via surface adjacency
or an existing pipe). Returns the target ship to store the pipe on.
"""
function can_place_pipe_offship(coord::EdgeCoord, gamemap::GameMap)::Tuple{Bool, Union{Symbol, Nothing}, String}
    v1_node = to_nodecoord(coord.v1)
    v2_node = to_nodecoord(coord.v2)

    v1_ship = _find_connected_ship(v1_node, gamemap)
    v2_ship = _find_connected_ship(v2_node, gamemap)

    if isnothing(v1_ship) && isnothing(v2_ship)
        return (false, nothing, "Neither endpoint is connected to a ship or existing pipe")
    end

    target = !isnothing(v1_ship) ? v1_ship : v2_ship
    return (true, target, "")
end

"""
    validate_offship_pipe_deletion(coord, gamemap) → valid

Validate that deleting an off-surface pipe won't orphan any remaining off-surface pipes.
Collects all off-surface pipe edges from all ships (excluding the pipe being deleted),
then flood-fills from each endpoint of the deleted pipe to verify every connected component
still reaches a ship surface.
"""
function validate_offship_pipe_deletion(coord::EdgeCoord, gamemap::GameMap)::Bool
    # Collect all off-surface pipe edges from all ships, excluding the target
    remaining_offship = Set{EdgeCoord}()
    for (_, ship) in gamemap.ships
        for (edge, _) in ship.pipe_behaviors
            edge == coord && continue
            v1_on = is_node_on_any_ship_surface(to_nodecoord(edge.v1), gamemap)
            v2_on = is_node_on_any_ship_surface(to_nodecoord(edge.v2), gamemap)
            if !(v1_on && v2_on)
                push!(remaining_offship, edge)
            end
        end
    end

    isempty(remaining_offship) && return true

    v1_node = to_nodecoord(coord.v1)
    v2_node = to_nodecoord(coord.v2)

    for start_node in (v1_node, v2_node)
        reachable = Set{EdgeCoord}()
        flood_search_pipes_from_node!(reachable, remaining_offship, start_node)

        isempty(reachable) && continue # No remaining off-surface pipes connected to this endpoint

        # Check if any vertex in the reachable component is on a ship surface
        has_ship_connection = false
        for edge in reachable
            for vertex in (edge.v1, edge.v2)
                if is_node_on_any_ship_surface(to_nodecoord(vertex), gamemap)
                    has_ship_connection = true
                    break
                end
            end
            has_ship_connection && break
        end

        if !has_ship_connection
            return false # This component would be orphaned
        end
    end

    return true
end

"""
    reassign_pipe_ownership!(deleted_coord, gamemap)

After deleting an off-surface pipe at `deleted_coord`, flood-fill from each endpoint through
remaining off-surface pipes to determine which ship each connected component physically
reaches. Moves any pipes that are stored on the wrong ship to the correct one.
"""
function reassign_pipe_ownership!(deleted_coord::EdgeCoord, gamemap::GameMap)
    # Build lookup of off-surface edges → owning ship
    offship_edges = Set{EdgeCoord}()
    edge_to_ship = Dict{EdgeCoord, Symbol}()
    for (ship_name, ship) in gamemap.ships
        for (edge, _) in ship.pipe_behaviors
            v1_on = is_node_on_any_ship_surface(to_nodecoord(edge.v1), gamemap)
            v2_on = is_node_on_any_ship_surface(to_nodecoord(edge.v2), gamemap)
            if !(v1_on && v2_on)
                push!(offship_edges, edge)
                edge_to_ship[edge] = ship_name
            end
        end
    end

    isempty(offship_edges) && return nothing

    v1_node = to_nodecoord(deleted_coord.v1)
    v2_node = to_nodecoord(deleted_coord.v2)

    visited_all = Set{EdgeCoord}()
    for start_node in (v1_node, v2_node)
        reachable = Set{EdgeCoord}()
        flood_search_pipes_from_node!(reachable, offship_edges, start_node)

        isempty(reachable) && continue
        any(e -> e ∈ visited_all, reachable) && continue # Already processed this component
        union!(visited_all, reachable)

        # Find which ship this component physically connects to
        target_ship = nothing
        for edge in reachable
            for vertex in (edge.v1, edge.v2)
                node = to_nodecoord(vertex)
                for (sname, _) in gamemap.ships
                    if is_node_on_ship_surface(node, gamemap; ship_name = sname)
                        target_ship = sname
                        break
                    end
                end
                !isnothing(target_ship) && break
            end
            !isnothing(target_ship) && break
        end

        isnothing(target_ship) && continue # Shouldn't happen if deletion was validated

        # Move any pipes that are stored on the wrong ship
        for edge in reachable
            current_ship = get(edge_to_ship, edge, nothing)
            isnothing(current_ship) && continue
            if current_ship != target_ship
                pipe_behav = get_pipe(gamemap, edge; ship_name = current_ship)
                delete_pipe!(gamemap, edge; ship_name = current_ship)
                set_pipe!(gamemap, edge, pipe_behav; ship_name = target_ship)
            end
        end
    end

    return nothing
end

# ===============================================================
# Ship Search Helpers
# ===============================================================

"Find which ship (if any) owns the surface tile at a coordinate."
function find_ship_for_surface(gamemap::GameMap, coord::TileCoord)::Union{Symbol, Nothing}
    for (name, ship) in gamemap.ships
        if coord in ship.ship_tiles
            return name
        end
    end
    return nothing
end

"Find which ship(s) have surfaces adjacent to a coordinate."
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

"Check if placing a surface at coord would connect multiple ships (invalid)."
function would_bridge_ships(gamemap::GameMap, coord::TileCoord)::Bool
    return length(find_ships_adjacent_to_coord(gamemap, coord)) > 1
end

"Find which ship a component should belong to by testing `placement_valid` on all ships."
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

"Find which ship owns a component at a given coordinate (searches all ships)."
function find_ship_with_component(gamemap::GameMap, coord::TileCoord)::Union{Symbol, Nothing}
    for (ship_name, ship) in gamemap.ships
        if haskey(ship.components, coord)
            return ship_name
        end
    end
    return nothing
end

"Find which ship owns a pipe at a given edge coordinate (searches all ships)."
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

"Offset all coordinates in a `ShipMap` in-place by a `TileCoord` offset."
function offset_ship!(shipmap::ShipMap, offset::TileCoord)
    # Offset components
    new_components = Dict{TileCoord, ComponentOnTile}()
    sizehint!(new_components, length(shipmap.components))
    for (coord, comp) in shipmap.components
        new_components[TileCoord(coord.q + offset.q, coord.r + offset.r)] = comp
    end
    empty!(shipmap.components)
    merge!(shipmap.components, new_components)

    # Offset pipes
    new_pipes = Dict{EdgeCoord, PipeBehavior}()
    sizehint!(new_pipes, length(shipmap.pipe_behaviors))
    for (edge, pipe) in shipmap.pipe_behaviors
        v1_offset = VertexCoord(TileCoord(edge.v1.tile.q + offset.q, edge.v1.tile.r + offset.r), edge.v1.dir)
        v2_offset = VertexCoord(TileCoord(edge.v2.tile.q + offset.q, edge.v2.tile.r + offset.r), edge.v2.dir)
        new_pipes[EdgeCoord(v1_offset, v2_offset)] = pipe
    end
    empty!(shipmap.pipe_behaviors)
    merge!(shipmap.pipe_behaviors, new_pipes)

    # Offset surface tiles
    new_surface = Set{TileCoord}()
    sizehint!(new_surface, length(shipmap.ship_tiles))
    for coord in shipmap.ship_tiles
        push!(new_surface, TileCoord(coord.q + offset.q, coord.r + offset.r))
    end
    empty!(shipmap.ship_tiles)
    union!(shipmap.ship_tiles, new_surface)

    return nothing
end

"Get the render position offset for a ship."
function get_ship_render_offset(gamemap::GameMap, ship_name::Symbol)::AxialCoord
    return get_render_offset(_get_ship(gamemap, ship_name))
end

"Get the render offset for a `ShipMap`; returns `AxialCoord(0,0)` if no offset."
function get_render_offset(ship::ShipMap)::AxialCoord
    offset = get_render_offset(ship.docking_status)
    return isnothing(offset) ? AxialCoord(0.0, 0.0) : offset
end

"Update render offset motion; returns `true` if motion is complete."
update_render_offset!(ship::ShipMap)::Bool = update_render_offset!(ship.docking_status)

"Get the docking status of a ship (ShipMap-level)"
get_docking_status(ship::ShipMap)::DockingStatus = ship.docking_status

"Set the docking status of a ship (ShipMap-level)"
function set_docking_status!(ship::ShipMap, status::DockingStatus)
    ship.docking_status = status
    return nothing
end

"Get the docking status of a ship by name. Returns `nothing` if ship not found."
function get_docking_status(gamemap::GameMap, ship_name::Symbol)::Union{DockingStatus, Nothing}
    haskey(gamemap.ships, ship_name) || return nothing
    return get_docking_status(gamemap.ships[ship_name])
end

"Set the docking status of a ship by name."
function set_docking_status!(gamemap::GameMap, ship_name::Symbol, status::DockingStatus)
    set_docking_status!(_get_ship(gamemap, ship_name), status)
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
            set_docking_status!(gamemap.ships[ship_name], ConnectedDockStat())
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

"Reset all ships to `ConnectedDockStat` (used before saving maps)."
function clear_all_docking_statuses!(gamemap::GameMap)
    for (_, ship) in gamemap.ships
        set_docking_status!(ship, ConnectedDockStat())
    end
    return nothing
end

"""
Swap the primary ship with another ship in the GameMap.
The current primary is retired under a `gensym`'d name, and the target becomes `:primary`.
Both ships are reset to `ConnectedDockStat()` — departure direction will be computed
from ship centroids at departure time via `compute_departure_axis`.
"""
function swap_primary!(gamemap::GameMap, new_primary_name::Symbol)::Tuple{Bool, String}
    if new_primary_name == :primary
        return (false, "Ship is already the primary")
    end
    if !has_ship(gamemap, new_primary_name)
        return (false, "Ship '$(new_primary_name)' not found")
    end

    # Pop both ships from the dict before re-inserting under swapped keys
    old_primary_ship = pop!(gamemap.ships, :primary)
    new_primary_ship = pop!(gamemap.ships, new_primary_name)

    set_docking_status!(old_primary_ship, ConnectedDockStat())
    set_docking_status!(new_primary_ship, ConnectedDockStat())

    retired_name = gensym(:old_primary)
    gamemap.ships[:primary] = new_primary_ship
    gamemap.ships[retired_name] = old_primary_ship

    return (true, "Swapped primary: '$(new_primary_name)' is now the primary ship (old primary retired as '$(retired_name)')")
end

"""
Find which ship a node belongs to. Checks surface-tile adjacency first,
then pipe-edge ownership. Falls back to `:primary`.
"""
function find_ship_for_node(node::NodeCoord, gamemap::GameMap)::Symbol
    # Fast path: check adjacent surface tiles
    for (tile, _) in get_adjacent_tiles_for_node(node)
        ship_name = find_ship_for_surface(gamemap, tile)
        if !isnothing(ship_name)
            return ship_name
        end
    end

    # Slow path: check pipe edges for off-surface nodes
    if is_axis(node.dir)
        vertex = to_vertex(node)
        for edge in get_edges(vertex)
            for (ship_name, ship) in gamemap.ships
                if haskey(ship.pipe_behaviors, edge)
                    return ship_name
                end
            end
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

"Get the last stop time from the game map (for warp easing)."
get_last_stop_time(gamemap::GameMap)::Float64 = get_last_stop_time(gamemap.space_map)

"Set the last stop time on the game map."
set_last_stop_time!(gamemap::GameMap, t::Float64) = set_last_stop_time!(gamemap.space_map, t)

"Get encounter points from the game map."
get_encounter_points(gamemap::GameMap) = get_encounter_points(gamemap.space_map)

"Dry mass of all ships: surface tile mass + structural component mass (no fuel)."
function get_dry_mass(gamemap::GameMap; mass_per_tile::Float64 = get_tile_mass())::Float64
    tile_mass = sum(count_surface_tiles(ship) for (_, ship) in gamemap.ships) * mass_per_tile

    component_dry_mass = 0.0
    for (_, ship) in gamemap.ships
        for (_, comp) in get_all_components(ship)
            component_dry_mass += get_component_dry_mass(comp)
        end
    end

    return tile_mass + component_dry_mass
end

"Wet mass (stored fluid) across all ships. If `fluid` is `nothing`, returns total fluid mass; if a specific FluidTags, returns mass of only that fluid."
function get_wet_mass(gamemap::GameMap; fluid::Union{FluidTags, Nothing} = nothing)::Float64
    wet_mass = 0.0
    for (_, ship) in gamemap.ships
        for (_, comp) in get_all_components(ship)
            wet_mass += get_component_wet_mass(comp; fluid = fluid)
        end
    end
    return wet_mass
end

"Total mass of all ships: dry mass (tiles + structure) + wet mass (stored fluid)."
function get_mass(gamemap::GameMap; mass_per_tile::Float64 = get_tile_mass())::Float64
    return get_dry_mass(gamemap; mass_per_tile = mass_per_tile) + get_wet_mass(gamemap)
end

#= ---------- Tile Mass Tuning ----------- =#

const _tile_mass = Threads.Atomic{Float64}(20.0)

"Get the mass assigned to each ship surface tile."
get_tile_mass()::Float64 = _tile_mass[]

"Set the mass assigned to each ship surface tile."
function set_tile_mass!(value::Float64)
    _tile_mass[] = value
    return nothing
end

end # module FlowMap
