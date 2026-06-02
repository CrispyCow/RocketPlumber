module FlowMap

using HexFrame, HexComponentsAPI, HexFluids
import HexComponentsAPI: placement_valid

using StructEquality
using StaticArrays
using DataStructures: Deque

#= ---------- Type Exports ----------- =#
export ShipState, ShipBlueprint, GameMap, RenderPosOffsetState
export DockingStatus, ConnectedDockStat, ApproachingDockStat, DepartingDockStat
export AbstractSpaceMap, SpaceMapEmpty, ManoeuvreData
export EncounterClass, ENCOUNTER_SHIP, ENCOUNTER_FUEL_CACHE, ENCOUNTER_SCRAP
export ManoeuvrePhase, PHASE_APPROACH_BURN, PHASE_COAST, PHASE_CAPTURE_BURN, PHASE_ENCOUNTER_READY
export EncounterPoint

#= ---------- Learning Progress Exports ----------- =#
export TutorialStatus, TUTORIAL_WAITING, TUTORIAL_IN_PROGRESS, TUTORIAL_COMPLETED
export AbstractLearningSystem, NoLearningSystem, TutorialState, LearningProgress, SandboxLearningState

#= ---------- Function Exports ----------- =#
export add_ship!, remove_ship!, get_all_ship_names, has_ship, get_ship_state, offset_ship!, swap_primary!, merge_ship!, get_ship_blueprint

#= ---------- GameMap Abstraction Functions ----------- =#
export get_component, has_component, set_component!, delete_component!, delete_all_components!
export get_pipe, has_pipe, set_pipe!, delete_pipe!, delete_all_pipes!
export get_components, get_pipes, each_component_of_ship, each_component_of_type, each_pipe_of_ship, each_pipe_of_type
export count_components, count_pipes, count_surface_tiles
export delete_all_surface_tiles!
export is_on_surface_tile, set_surface_tile!, delete_surface_tile!
export is_on_surface_tile_any_ship
export can_place_component_at, can_place_pipe_at, can_remove_surface_at, is_node_on_ship_surface
export each_surface_owner, collect_surface_tiles!, collect_surface_edge_tiles!, expand_tileset!, expand_tileset
export get_axial_bounds, get_cartesian_bounds, get_surface_centroid
export get_surface_shiptag, get_component_shiptag, get_pipe_shiptag
export find_ships_adjacent_to_coord, find_ship_for_placement, find_ship_containing_edge, find_tile_pipe_host_ship
export find_ship_surface_containing_node, find_ship_pipes_containing_node, find_ship_for_node

#= ---------- Learning System Exports ----------- =#
export get_learning_system, set_learning_system!, has_learning_system, is_sandbox_learning

#= ---------- Off-Ship Pipe Exports ----------- =#
export can_place_pipe_offship, validate_offship_pipe_deletion, reassign_pipe_ownership!
export is_node_on_any_ship_surface, flood_search_pipes_from_node!

#= ---------- Ship Render and Docking Exports ----------- =#
export get_ship_render_offset, get_render_offset, update_render_offset!, compute_departure_axis
export get_docking_status, set_docking_status!, update_docking!, clear_all_docking_statuses!, is_ship_moving

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
    fuel_tag::Union{FluidType, Nothing} = nothing        # Primary fuel type (nothing for scrap)
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

"""Per-ship metadata and docking animation state."""
@kwdef mutable struct ShipState
    docking_status::DockingStatus = ConnectedDockStat()
end
@struct_hash_equal ShipState

# ===============================================================
# Ship Blueprint (Transient Builder)
# ===============================================================

"""
Transient container for a ship under construction by procgen or demo-map generators.
Not stored to disk. Use `merge_ship!` to insert into a live `GameMap`.
"""
@kwdef mutable struct ShipBlueprint
    components::Dict{TileCoord, ComponentOnTile} = Dict{TileCoord, ComponentOnTile}()
    pipe_behaviors::Dict{EdgeCoord, PipeBehavior} = Dict{EdgeCoord, PipeBehavior}()
    ship_tiles::Set{TileCoord} = Set{TileCoord}()
end

"Offset all coordinates in a blueprint by a `TileCoord` step — mutates in-place."
function offset_ship!(blueprint::ShipBlueprint, offset::TileCoord)
    # Components
    moved_c = [(coord, comp) for (coord, comp) in blueprint.components]
    empty!(blueprint.components)
    for (coord, comp) in moved_c
        new_coord = TileCoord(coord.q + offset.q, coord.r + offset.r)
        blueprint.components[new_coord] = comp
    end
    # Pipes
    moved_p = [(edge, pipe) for (edge, pipe) in blueprint.pipe_behaviors]
    empty!(blueprint.pipe_behaviors)
    for (edge, pipe) in moved_p
        v1n = VertexCoord(TileCoord(edge.v1.tile.q + offset.q, edge.v1.tile.r + offset.r), edge.v1.dir)
        v2n = VertexCoord(TileCoord(edge.v2.tile.q + offset.q, edge.v2.tile.r + offset.r), edge.v2.dir)
        blueprint.pipe_behaviors[EdgeCoord(v1n, v2n)] = pipe
    end
    # Tiles
    new_tiles = Set(TileCoord(t.q + offset.q, t.r + offset.r) for t in blueprint.ship_tiles)
    empty!(blueprint.ship_tiles)
    union!(blueprint.ship_tiles, new_tiles)
    return nothing
end

get_cartesian_bounds(bp::ShipBlueprint) = get_cartesian_bounds(bp.ship_tiles)
get_all_surface_tiles(bp::ShipBlueprint) = bp.ship_tiles

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


"Top-level game map. Global component/pipe dicts tagged by ship; per-ship metadata in `ships`. Initialises with a single surface tile at (0,0) for the primary ship to enable tile placement."
@kwdef mutable struct GameMap
    components::Dict{TileCoord, ComponentOnTile} = Dict{TileCoord, ComponentOnTile}()
    pipe_behaviors::Dict{EdgeCoord, PipeOnEdge} = Dict{EdgeCoord, PipeOnEdge}()
    surface_shiptags::Dict{TileCoord, Symbol} = Dict{TileCoord, Symbol}(TileCoord(0, 0) => :primary)
    ships::Dict{Symbol, ShipState} = Dict(:primary => ShipState())
    space_map::AbstractSpaceMap = SpaceMapEmpty()
    learning_system::AbstractLearningSystem = NoLearningSystem()
end
@struct_hash_equal GameMap

"Wrap a single `ShipState` as the primary ship (no components or pipes)."
function GameMap(state::ShipState)
    return GameMap(ships = Dict(:primary => state))
end

"Construct a game map whose primary ship is populated from `blueprint`. Skips default surface tile initialization since blueprint will provide its own tiles."
function GameMap(blueprint::ShipBlueprint)
    gamemap = GameMap(ships = Dict{Symbol, ShipState}(), surface_shiptags = Dict{TileCoord, Symbol}())
    merge_ship!(gamemap, :primary, blueprint)
    return gamemap
end

# ===============================================================
# Ship Merge Function
# ===============================================================

"""
    merge_ship!(gamemap, ship_name, blueprint; docking_status)

Insert all components, pipes, and surface tiles from `blueprint` into `gamemap` under
`ship_name`. Each component and pipe is re-tagged with `ship_name`. A new `ShipState` entry
is created.

Errors if:
- `ship_name` already exists in the gamemap (checked at start)
- any coordinate in `blueprint.components` is already occupied (collision guard)
- any edge in `blueprint.pipe_behaviors` is already occupied (collision guard)
"""
function merge_ship!(gamemap::GameMap, ship_name::Symbol, blueprint::ShipBlueprint;
        docking_status::DockingStatus = ConnectedDockStat())
    has_ship(gamemap, ship_name) && error("Ship '$ship_name' already exists in gamemap")

    # Validate no coordinate/edge collisions before mutation
    for coord in keys(blueprint.components)
        haskey(gamemap.components, coord) && error(
            "Cannot merge ship '$ship_name': component already exists at $coord (from ship '$(gamemap.components[coord].ship)')"
        )
    end
    for edge in keys(blueprint.pipe_behaviors)
        haskey(gamemap.pipe_behaviors, edge) && error(
            "Cannot merge ship '$ship_name': pipe already exists on edge $edge (from ship '$(gamemap.pipe_behaviors[edge].ship)')"
        )
    end
    for tile in blueprint.ship_tiles
        haskey(gamemap.surface_shiptags, tile) && error(
            "Cannot merge ship '$ship_name': surface tile already exists at $tile (from ship '$(gamemap.surface_shiptags[tile])')"
        )
    end

    # Safe to merge after validation passes
    for (coord, comp) in blueprint.components
        gamemap.components[coord] = ComponentOnTile(comp.component, comp.rotation, comp.mirrored, ship_name)
    end
    for (edge, pipe) in blueprint.pipe_behaviors
        gamemap.pipe_behaviors[edge] = PipeOnEdge(pipe, ship_name)
    end
    for tile in blueprint.ship_tiles
        gamemap.surface_shiptags[tile] = ship_name
    end
    gamemap.ships[ship_name] = ShipState(docking_status = docking_status)
    return nothing
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
# GameMap Abstraction Functions
# ===============================================================
# These functions provide a clean, ship-routed interface to map internals.
# By default operations route to the `:primary` ship unless `ship_name` is supplied.

#= ---------- Ship Management ----------- =#
"Get a `ShipState` by name or throw if it does not exist."
function _get_ship_state(gamemap::GameMap, ship_name::Symbol = :primary)::ShipState
    if !haskey(gamemap.ships, ship_name)
        error("Ship '$ship_name' not found. Available ships: $(collect(keys(gamemap.ships)))")
    end
    return gamemap.ships[ship_name]
end

"Add a `ShipState` under the provided name; errors if it already exists."
function add_ship!(gamemap::GameMap, name::Symbol, state::ShipState)
    if haskey(gamemap.ships, name)
        error("Ship '$name' already exists")
    end
    gamemap.ships[name] = state
    return nothing
end

"Remove a ship by name (cannot remove `:primary`). Deletes all components and pipes tagged with that ship from global stores."
function remove_ship!(gamemap::GameMap, name::Symbol)
    if name == :primary
        error("Cannot remove primary ship")
    end
    delete!(gamemap.ships, name)
    filter!(((_, c),) -> c.ship !== name, gamemap.components)
    filter!(((_, p),) -> p.ship !== name, gamemap.pipe_behaviors)
    filter!(((_, ship_name),) -> ship_name !== name, gamemap.surface_shiptags)
    return nothing
end

get_all_ship_names(gamemap::GameMap)::Vector{Symbol} = collect(keys(gamemap.ships))
has_ship(gamemap::GameMap, name::Symbol)::Bool = haskey(gamemap.ships, name)
get_ship_state(gamemap::GameMap, name::Symbol)::ShipState = _get_ship_state(gamemap, name)

#= ---------- GameMap: Component Access ----------- =#
"Get the `ComponentOnTile` at `coord`, or `nothing`. Read `.ship` on the result to determine ownership."
function get_component(gamemap::GameMap, coord::TileCoord)
    return get(gamemap.components, coord, nothing)
end

"Whether any component exists at `coord`. To check ownership, fetch with `get_component` and compare `.ship`."
function has_component(gamemap::GameMap, coord::TileCoord)::Bool
    return haskey(gamemap.components, coord)
end

"Place `component` at `coord`. Ownership is taken from `component.ship` — construct the wrapper with the desired ship tag."
function set_component!(gamemap::GameMap, coord::TileCoord, component::ComponentOnTile)
    gamemap.components[coord] = component
    return nothing
end

"Bulk-place components. Each entry's ship tag is taken from its `ComponentOnTile.ship`."
function set_component!(gamemap::GameMap, components::AbstractDict{TileCoord, <:ComponentOnTile})
    for (coord, comp) in components
        set_component!(gamemap, coord, comp)
    end
    return nothing
end

"Delete the component at `coord` if present. To delete only when owned by a particular ship, gate the call externally."
function delete_component!(gamemap::GameMap, coord::TileCoord)
    delete!(gamemap.components, coord)
    return nothing
end

"Return the components dict shared with the gamemap. Do not mutate; use `set_component!` / `delete_component!`, `each_component_of_ship`, or `each_component_of_type`."
get_components(gamemap::GameMap) = gamemap.components

"Lazy iterator over `ComponentOnTile` values belonging to `ship_name`."
each_component_of_ship(gamemap::GameMap, ship_name::Symbol) =
    Iterators.filter(c -> c.ship === ship_name, values(get_components(gamemap)))

"Lazy iterator over `ComponentOnTile` values whose component behaviour is of type `T`."
each_component_of_type(gamemap::GameMap, ::Type{T}) where {T} =
    Iterators.filter(c -> c.component isa T, values(get_components(gamemap)))

#= ---------- GameMap: Pipe Access ----------- =#
"Get the `PipeOnEdge` at `coord`, or `nothing`. Read `.ship` on the result to determine ownership."
function get_pipe(gamemap::GameMap, coord::EdgeCoord)
    return get(gamemap.pipe_behaviors, coord, nothing)
end

"Whether any pipe exists at `coord`. To check ownership, fetch with `get_pipe` and compare `.ship`."
function has_pipe(gamemap::GameMap, coord::EdgeCoord)::Bool
    return haskey(gamemap.pipe_behaviors, coord)
end

"Place `pipe` at `coord`. Ownership is taken from `pipe.ship` — construct the `PipeOnEdge` with the desired ship tag."
function set_pipe!(gamemap::GameMap, coord::EdgeCoord, pipe::PipeOnEdge)
    gamemap.pipe_behaviors[coord] = pipe
    return nothing
end

"Place raw `pipe` at `coord`, tagging it with `ship_name` before insertion."
function set_pipe!(gamemap::GameMap, coord::EdgeCoord, pipe::PipeBehavior; ship_name::Symbol = :primary)
    return set_pipe!(gamemap, coord, PipeOnEdge(pipe, ship_name))
end

"Delete the pipe at `coord` if present. To delete only when owned by a particular ship, gate the call externally."
function delete_pipe!(gamemap::GameMap, coord::EdgeCoord)
    delete!(gamemap.pipe_behaviors, coord)
    return nothing
end

"Return the pipe-behaviors dict shared with the gamemap. Do not mutate; use `set_pipe!` / `delete_pipe!`, `each_pipe_of_ship`, or `each_pipe_of_type`."
get_pipes(gamemap::GameMap) = gamemap.pipe_behaviors

"Lazy iterator over `PipeOnEdge` values belonging to `ship_name`."
each_pipe_of_ship(gamemap::GameMap, ship_name::Symbol) =
    Iterators.filter(p -> p.ship === ship_name, values(get_pipes(gamemap)))

"Lazy iterator over `PipeOnEdge` values whose pipe behaviour is of type `T`."
each_pipe_of_type(gamemap::GameMap, ::Type{T}) where {T} =
    Iterators.filter(p -> p.pipe isa T, values(get_pipes(gamemap)))

#= ---------- Cross-Ship Surface Queries ----------- =#
"Check whether the coordinate is part of any ship's surface."
function is_on_surface_tile_any_ship(coord::TileCoord, gamemap::GameMap)::Tuple{Bool, Union{Symbol, Nothing}}
    ship_name = get_surface_shiptag(gamemap, coord)
    return (!isnothing(ship_name), ship_name)
end

#= ---------- Counts and Batch Operations ----------- =#
function count_components(gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)::Int
    if isnothing(ship_name)
        return length(gamemap.components)
    else
        return count(c -> c.ship === ship_name, values(gamemap.components))
    end
end

function count_pipes(gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)::Int
    if isnothing(ship_name)
        return length(gamemap.pipe_behaviors)
    else
        return count(p -> p.ship === ship_name, values(gamemap.pipe_behaviors))
    end
end

function count_surface_tiles(gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)::Int
    if isnothing(ship_name)
        return length(gamemap.surface_shiptags)
    end

    _get_ship_state(gamemap, ship_name)
    return count(owner -> owner === ship_name, values(gamemap.surface_shiptags))
end

function delete_all_components!(gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)
    if isnothing(ship_name)
        empty!(gamemap.components)
    else
        filter!(((_, c),) -> c.ship !== ship_name, gamemap.components)
    end
    return nothing
end

function delete_all_pipes!(gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)
    if isnothing(ship_name)
        empty!(gamemap.pipe_behaviors)
    else
        filter!(((_, p),) -> p.ship !== ship_name, gamemap.pipe_behaviors)
    end
    return nothing
end

function delete_all_surface_tiles!(gamemap::GameMap; ship_name::Symbol = :primary)
    _get_ship_state(gamemap, ship_name)
    filter!(((_, owner),) -> owner !== ship_name, gamemap.surface_shiptags)
    return nothing
end

#= ---------- Surface Access ----------- =#
"Read the owning ship tag for a surface tile, if present."
get_surface_shiptag(gamemap::GameMap, coord::TileCoord)::Union{Symbol, Nothing} = get(gamemap.surface_shiptags, coord, nothing)

is_on_surface_tile(coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Bool =
    get_surface_shiptag(gamemap, coord) === ship_name

function set_surface_tile!(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)
    _get_ship_state(gamemap, ship_name)
    gamemap.surface_shiptags[coord] = ship_name
    return nothing
end
function set_surface_tile!(gamemap::GameMap, surface; ship_name::Symbol = :primary)
    _get_ship_state(gamemap, ship_name)
    for coord in surface
        gamemap.surface_shiptags[coord] = ship_name
    end
    return nothing
end

function delete_surface_tile!(gamemap::GameMap, coord::TileCoord;
        ship_name::Symbol = :primary)::Bool
    _get_ship_state(gamemap, ship_name)
    get_surface_shiptag(gamemap, coord) === ship_name || return false
    delete!(gamemap.surface_shiptags, coord)
    return true
end

"Iterate `(tile, ship_name)` pairs for every surface tile in the map."
each_surface_owner(gamemap::GameMap) = pairs(gamemap.surface_shiptags)

"Collect surface tiles into `dest`, optionally filtering by owner." 
function collect_surface_tiles!(dest, gamemap::GameMap;
        ship_name::Union{Symbol, Nothing} = nothing,
        exclude_ship::Union{Symbol, Nothing} = nothing)
    if !isnothing(ship_name)
        _get_ship_state(gamemap, ship_name)
    end
    if !isnothing(exclude_ship)
        _get_ship_state(gamemap, exclude_ship)
    end

    empty!(dest)
    for (tile, owner) in each_surface_owner(gamemap)
        !isnothing(ship_name) && owner !== ship_name && continue
        !isnothing(exclude_ship) && owner === exclude_ship && continue
        push!(dest, tile)
    end
    return dest
end

"Default: tile must be on the named ship's surface."
function placement_valid(behav::T, coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary, kwargs...) where {T <: ComponentBehavior}
    return is_on_surface_tile(coord, gamemap; ship_name) ? (true, "") : (false, "Not on ship surface")
end

"Find the tile with the largest projection along each `HexAxis` direction."
function get_axial_bounds(tiles)::HexFrame.AxialBounds
    origin = TileCoord(0, 0)
    best_proj = MVector{6, Float64}(-Inf, -Inf, -Inf, -Inf, -Inf, -Inf)
    best_tile = MVector{6, TileCoord}(origin, origin, origin, origin, origin, origin)
    found_any = false

    for tile in tiles
        found_any = true
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

    if !found_any
        return (Q_POS = origin, R_NEG = origin, S_POS = origin, Q_NEG = origin, R_POS = origin, S_NEG = origin)
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

get_axial_bounds(gamemap::GameMap)::HexFrame.AxialBounds = get_axial_bounds(keys(gamemap.surface_shiptags))

"""
Calculate the cartesian coordinate extremes for a set of surface tiles.
Accepts an iterable of `TileCoord` and returns a `HexFrame.CartesianBounds` tuple with the cartesian
x/y values furthest from the origin in each direction. This operates on the provided tile set and
is used by the `ShipBlueprint`, `GameMap`, and `(GameMap, ship_name)` overloads.

Note: Y_POS is the maximum y value (top of screen), Y_NEG is minimum (bottom).
X_POS is maximum x (right), X_NEG is minimum (left).
"""
function get_cartesian_bounds(tiles)::HexFrame.CartesianBounds
    x_max = 0.0
    x_min = 0.0
    y_max = 0.0
    y_min = 0.0
    found_any = false

    for tile in tiles
        cart = HexFrame.to_cartesian(tile)
        if !found_any
            x_max, x_min = cart.x, cart.x
            y_max, y_min = cart.y, cart.y
            found_any = true
            continue
        end

        x_max = max(x_max, cart.x)
        x_min = min(x_min, cart.x)
        y_max = max(y_max, cart.y)
        y_min = min(y_min, cart.y)
    end

    if !found_any
        return (X_POS = 0.0, X_NEG = 0.0, Y_POS = 0.0, Y_NEG = 0.0)
    end

    return (X_POS = x_max, X_NEG = x_min, Y_POS = y_max, Y_NEG = y_min)
end
get_cartesian_bounds(gamemap::GameMap)::HexFrame.CartesianBounds = get_cartesian_bounds(keys(gamemap.surface_shiptags))

"Cartesian bounds for one ship's surface tiles, selected by `ship_name`."
function get_cartesian_bounds(gamemap::GameMap, ship_name::Symbol)::HexFrame.CartesianBounds
    _get_ship_state(gamemap, ship_name)
    return get_cartesian_bounds(tile for (tile, owner) in each_surface_owner(gamemap) if owner === ship_name)
end

"Get the centroid of an iterable of surface tiles in axial coordinates. Returns nothing for an empty set."
function get_surface_centroid(tiles)::Union{AxialCoord, Nothing}
    q_sum = 0.0
    r_sum = 0.0
    count = 0
    for tile in tiles
        q_sum += tile.q
        r_sum += tile.r
        count += 1
    end

    count == 0 && return nothing

    return AxialCoord(q_sum / count, r_sum / count)
end
function get_surface_centroid(gamemap::GameMap, ship_name::Symbol)::Union{AxialCoord, Nothing}
    _get_ship_state(gamemap, ship_name)
    return get_surface_centroid(tile for (tile, owner) in each_surface_owner(gamemap) if owner === ship_name)
end

"""
Compute a departure direction for `ship_name` based on the relative position of ship centroids.
Returns the `HexAxis` pointing from the centroid of all other ships towards the departing ship.
Falls back to `Q_POS` when centroids coincide or the departing ship is the only one.
"""
function compute_departure_axis(gamemap::GameMap, ship_name::Symbol)::HexFrame.HexAxis
    _get_ship_state(gamemap, ship_name)

    departing_q = 0.0
    departing_r = 0.0
    departing_count = 0
    other_q = 0.0
    other_r = 0.0
    other_count = 0
    for (tile, owner) in each_surface_owner(gamemap)
        if owner === ship_name
            departing_q += tile.q
            departing_r += tile.r
            departing_count += 1
        else
            other_q += tile.q
            other_r += tile.r
            other_count += 1
        end
    end

    departing_count == 0 && return HexFrame.Q_POS
    other_count == 0 && return HexFrame.Q_POS

    departing_centroid = AxialCoord(departing_q / departing_count, departing_r / departing_count)
    other_centroid = AxialCoord(other_q / other_count, other_r / other_count)
    direction = AxialCoord(departing_centroid.q - other_centroid.q, departing_centroid.r - other_centroid.r)
    return HexFrame.nearest_hex_axis(direction)
end


"Count how many of a tile's 6 adjacent neighbours are present in the surface set."
@inline function count_surfacetile_adjacencies(surface_set::Set{TileCoord}, tile::TileCoord)::Int
    adjacent_tiles = HexFrame.get_adjacent_tiles_for_tile(tile)
    return count(adj_tile -> adj_tile in surface_set, adjacent_tiles)
end

"Collect boundary tiles, optionally restricted to one ship." 
function collect_surface_edge_tiles!(dest, gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)
    if !isnothing(ship_name)
        _get_ship_state(gamemap, ship_name)
    end

    empty!(dest)
    for (tile, owner) in each_surface_owner(gamemap)
        !isnothing(ship_name) && owner !== ship_name && continue

        is_edge_tile = false
        for adj_tile in HexFrame.get_adjacent_tiles_for_tile(tile)
            if get_surface_shiptag(gamemap, adj_tile) !== owner
                is_edge_tile = true
                break
            end
        end

        is_edge_tile && push!(dest, tile)
    end
    return dest
end

"Expand a tile set by one ring into `dest`."
function expand_tileset!(dest::Set{TileCoord}, tiles)::Set{TileCoord}
    empty!(dest)
    for tile in tiles
        push!(dest, tile)
        for nb in HexFrame.get_adjacent_tiles_for_tile(tile)
            push!(dest, nb)
        end
    end
    return dest
end

"Expand a tile set by `n` rings into `dest`."
function expand_tileset!(dest::Set{TileCoord}, tiles, n::Integer)::Set{TileCoord}
    n <= 0 && return (empty!(dest); union!(dest, tiles); dest)

    expand_tileset!(dest, tiles)
    for _ in 2:n
        current = copy(dest)
        expand_tileset!(dest, current)
    end
    return dest
end

"Expand a tile set by one ring — returns a new set containing the original tiles plus all neighbours."
function expand_tileset(tiles::Set{TileCoord})::Set{TileCoord}
    expanded = Set{TileCoord}()
    sizehint!(expanded, length(tiles) * 4)
    return expand_tileset!(expanded, tiles)
end

"Expand a tile set by `n` rings by applying `expand_tileset` iteratively."
function expand_tileset(tiles::Set{TileCoord}, n::Integer)::Set{TileCoord}
    expanded = Set{TileCoord}()
    sizehint!(expanded, max(length(tiles) * 4, length(tiles)))
    return expand_tileset!(expanded, tiles, n)
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
    component = get_component(gamemap, coord)
    if !isnothing(component) && component.ship === ship_name
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
    for (tile, _) in get_adjacent_tiles_for_node(node)
        if !isnothing(get_surface_shiptag(gamemap, tile))
            return true
        end
    end
    return false
end

#= ---------- Ship Search Helpers ----------- =#

"Find which ship(s) have surfaces adjacent to a coordinate."
function find_ships_adjacent_to_coord(gamemap::GameMap, coord::TileCoord)::Vector{Symbol}
    adjacent = Symbol[]
    for adj in HexFrame.get_adjacent_tiles_for_tile(coord)
        sn = get_surface_shiptag(gamemap, adj)
        !isnothing(sn) && sn ∉ adjacent && push!(adjacent, sn)
    end
    return adjacent
end

"Find the first ship whose `placement_valid` accepts `(component, coord)`. Current placement rules are expected to make the match unique."
function find_ship_for_placement(component::ComponentBehavior, coord::TileCoord, gamemap::GameMap; rotation::HexAxis, mirrored::Bool = false)::Union{Symbol, Nothing}
    for (ship_name, _) in gamemap.ships
        is_valid, _ = placement_valid(component, coord, gamemap; rotation, mirrored, ship_name)
        is_valid && return ship_name
    end
    return nothing
end

"Read the stored ship tag from the component wrapper at `coord`, if present."
function get_component_shiptag(gamemap::GameMap, coord::TileCoord)::Union{Symbol, Nothing}
    c = get(gamemap.components, coord, nothing)
    return isnothing(c) ? nothing : c.ship
end

"Read the stored ship tag from the pipe wrapper at `coord`, if present."
function get_pipe_shiptag(gamemap::GameMap, coord::EdgeCoord)::Union{Symbol, Nothing}
    p = get(gamemap.pipe_behaviors, coord, nothing)
    return isnothing(p) ? nothing : p.ship
end

"Find which ship surface contains both endpoints of `coord`. Returns `nothing` when no single ship contains both nodes."
function find_ship_containing_edge(gamemap::GameMap, coord::EdgeCoord)::Union{Symbol, Nothing}
    v1_node = to_nodecoord(coord.v1)
    v2_node = to_nodecoord(coord.v2)
    for (ship_name, _) in gamemap.ships
        if is_node_on_ship_surface(v1_node, gamemap; ship_name = ship_name) &&
                is_node_on_ship_surface(v2_node, gamemap; ship_name = ship_name)
            return ship_name
        end
    end
    return nothing
end

"Component owner first, then surface owner."
function find_tile_pipe_host_ship(gamemap::GameMap, coord::TileCoord)::Union{Symbol, Nothing}
    sn = get_component_shiptag(gamemap, coord)
    isnothing(sn) || return sn
    return get_surface_shiptag(gamemap, coord)
end

"Find a ship by adjacent surface ownership only. Returns `default` if no adjacent surface is found."
function find_ship_surface_containing_node(node::NodeCoord, gamemap::GameMap;
        default::Union{Symbol, Nothing} = nothing)::Union{Symbol, Nothing}
    for (tile, _) in get_adjacent_tiles_for_node(node)
        sn = get_surface_shiptag(gamemap, tile)
        !isnothing(sn) && return sn
    end
    return default
end

"Find a ship by adjacent pipe ownership only. Non-axis nodes return `default` immediately."
function find_ship_pipes_containing_node(node::NodeCoord, gamemap::GameMap;
        default::Union{Symbol, Nothing} = nothing)::Union{Symbol, Nothing}
    is_axis(node.dir) || return default

    vertex = to_vertex(node)
    for edge in get_edges(vertex)
        sn = get_pipe_shiptag(gamemap, edge)
        !isnothing(sn) && return sn
    end
    return default
end

"Find a ship for `node` by checking surface ownership first, then pipe ownership. Returns `default` if no ship is found."
function find_ship_for_node(node::NodeCoord, gamemap::GameMap;
        default::Union{Symbol, Nothing} = :primary)::Union{Symbol, Nothing}
    surface_ship = find_ship_surface_containing_node(node, gamemap; default = nothing)
    isnothing(surface_ship) || return surface_ship

    pipe_ship = find_ship_pipes_containing_node(node, gamemap; default = nothing)
    isnothing(pipe_ship) || return pipe_ship

    return default
end

"""
Extract a `ShipBlueprint` from a `GameMap` containing only the components, pipes, and tiles
of a specific ship. The blueprint is suitable for export or further manipulation.
"""
function get_ship_blueprint(gamemap::GameMap, ship_name::Symbol)::ShipBlueprint
    blueprint = ShipBlueprint()
    for (coord, comp) in gamemap.components
        comp.ship === ship_name || continue
        blueprint.components[coord] = comp
    end
    for (edge, pipe) in gamemap.pipe_behaviors
        pipe.ship === ship_name || continue
        blueprint.pipe_behaviors[edge] = pipe.pipe  # unwrap PipeOnEdge to raw PipeBehavior
    end
    collect_surface_tiles!(blueprint.ship_tiles, gamemap; ship_name = ship_name)
    return blueprint
end

# ===============================================================
# Placement Validation Functions
# ===============================================================

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

    v1_ship = find_ship_for_node(v1_node, gamemap; default = nothing)
    v2_ship = find_ship_for_node(v2_node, gamemap; default = nothing)

    if isnothing(v1_ship) && isnothing(v2_ship)
        return (false, nothing, "Neither endpoint is connected to a ship or existing pipe")
    end

    target = !isnothing(v1_ship) ? v1_ship : v2_ship
    return (true, target, "")
end

"""
    validate_offship_pipe_deletion(coord, gamemap) → valid

Validate that deleting an off-surface pipe won't orphan any remaining off-surface pipes.
"""
function validate_offship_pipe_deletion(coord::EdgeCoord, gamemap::GameMap)::Bool
    remaining_offship = Set{EdgeCoord}()
    for (edge, _) in gamemap.pipe_behaviors
        edge == coord && continue
        v1_on = is_node_on_any_ship_surface(to_nodecoord(edge.v1), gamemap)
        v2_on = is_node_on_any_ship_surface(to_nodecoord(edge.v2), gamemap)
        !(v1_on && v2_on) && push!(remaining_offship, edge)
    end
    isempty(remaining_offship) && return true

    for start_node in (to_nodecoord(coord.v1), to_nodecoord(coord.v2))
        reachable = Set{EdgeCoord}()
        flood_search_pipes_from_node!(reachable, remaining_offship, start_node)
        isempty(reachable) && continue
        has_ship_connection = any(
            is_node_on_any_ship_surface(to_nodecoord(v), gamemap)
            for e in reachable
            for v in (e.v1, e.v2)
        )
        !has_ship_connection && return false
    end
    return true
end

"""
    reassign_pipe_ownership!(deleted_coord, gamemap)

After deleting an off-surface pipe, flood-fill through remaining off-surface pipes
and rewrite each connected component's ship tag to the ship its touching endpoint belongs to.
"""
function reassign_pipe_ownership!(deleted_coord::EdgeCoord, gamemap::GameMap)
    offship_edges = Set{EdgeCoord}()
    for (edge, _) in gamemap.pipe_behaviors
        v1_on = is_node_on_any_ship_surface(to_nodecoord(edge.v1), gamemap)
        v2_on = is_node_on_any_ship_surface(to_nodecoord(edge.v2), gamemap)
        !(v1_on && v2_on) && push!(offship_edges, edge)
    end
    isempty(offship_edges) && return nothing

    visited_all = Set{EdgeCoord}()
    for start_node in (to_nodecoord(deleted_coord.v1), to_nodecoord(deleted_coord.v2))
        reachable = Set{EdgeCoord}()
        flood_search_pipes_from_node!(reachable, offship_edges, start_node)
        isempty(reachable) && continue
        any(e -> e ∈ visited_all, reachable) && continue
        union!(visited_all, reachable)

        # Pipe-fallback disabled: the chain we're about to retag is itself the source
        # of stale tags, so we must anchor only on actual surface ownership.
        target_ship = nothing
        for edge in reachable
            for v in (edge.v1, edge.v2)
                target_ship = find_ship_surface_containing_node(to_nodecoord(v), gamemap;
                    default = nothing)
                !isnothing(target_ship) && break
            end
            !isnothing(target_ship) && break
        end
        isnothing(target_ship) && continue

        for edge in reachable
            p = gamemap.pipe_behaviors[edge]
            if p.ship !== target_ship
                gamemap.pipe_behaviors[edge] = PipeOnEdge(p.pipe, target_ship)
            end
        end
    end
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

    # Rewrite ship tags on every component and pipe so they follow the swap:
    #   old `:primary` entries → `retired_name` (the demoted ship's new identity)
    #   old `new_primary_name` entries → `:primary`
    rename_to = Dict{Symbol, Symbol}(:primary => retired_name, new_primary_name => :primary)
    for coord in collect(keys(gamemap.components))
        c = gamemap.components[coord]
        haskey(rename_to, c.ship) || continue
        gamemap.components[coord] = ComponentOnTile(c.component, c.rotation, c.mirrored, rename_to[c.ship])
    end
    for edge in collect(keys(gamemap.pipe_behaviors))
        p = gamemap.pipe_behaviors[edge]
        haskey(rename_to, p.ship) || continue
        gamemap.pipe_behaviors[edge] = PipeOnEdge(p.pipe, rename_to[p.ship])
    end
    for tile in collect(keys(gamemap.surface_shiptags))
        owner = gamemap.surface_shiptags[tile]
        haskey(rename_to, owner) || continue
        gamemap.surface_shiptags[tile] = rename_to[owner]
    end

    return (true, "Swapped primary: '$(new_primary_name)' is now the primary ship (old primary retired as '$(retired_name)')")
end

"""
Offset all coordinates belonging to `ship_name` in `gamemap` by a `TileCoord` offset, in-place.
Rewrites component keys, pipe edge keys, and surface tiles for the given ship.
"""
function offset_ship!(gamemap::GameMap, ship_name::Symbol, offset::TileCoord)
    # Components — collect, clear, reinsert
    moved_c = [(coord, comp) for (coord, comp) in gamemap.components if comp.ship === ship_name]
    for (old_coord, _) in moved_c
        delete!(gamemap.components, old_coord)
    end
    for (coord, comp) in moved_c
        gamemap.components[TileCoord(coord.q + offset.q, coord.r + offset.r)] = comp
    end

    # Pipes
    moved_p = [(edge, pipe) for (edge, pipe) in gamemap.pipe_behaviors if pipe.ship === ship_name]
    for (old_edge, _) in moved_p
        delete!(gamemap.pipe_behaviors, old_edge)
    end
    for (edge, pipe) in moved_p
        v1n = VertexCoord(TileCoord(edge.v1.tile.q + offset.q, edge.v1.tile.r + offset.r), edge.v1.dir)
        v2n = VertexCoord(TileCoord(edge.v2.tile.q + offset.q, edge.v2.tile.r + offset.r), edge.v2.dir)
        gamemap.pipe_behaviors[EdgeCoord(v1n, v2n)] = pipe
    end

    # Surface tiles
    _get_ship_state(gamemap, ship_name)
    moved_tiles = [tile for (tile, owner) in each_surface_owner(gamemap) if owner === ship_name]
    for tile in moved_tiles
        delete!(gamemap.surface_shiptags, tile)
    end
    for tile in moved_tiles
        moved_tile = TileCoord(tile.q + offset.q, tile.r + offset.r)
        gamemap.surface_shiptags[moved_tile] = ship_name
    end

    return nothing
end

# ===============================================================
# Docking and Render Offset Functions
# ===============================================================

"Get the render position offset for a ship."
function get_ship_render_offset(gamemap::GameMap, ship_name::Symbol)::AxialCoord
    return get_render_offset(_get_ship_state(gamemap, ship_name))
end

"Get the render offset for a `ShipState`; returns `AxialCoord(0,0)` if no offset."
function get_render_offset(state::ShipState)::AxialCoord
    offset = get_render_offset(state.docking_status)
    return isnothing(offset) ? AxialCoord(0.0, 0.0) : offset
end

"Update render offset motion; returns `true` if motion is complete."
update_render_offset!(state::ShipState)::Bool = update_render_offset!(state.docking_status)

"Get the docking status of a ship (ShipState-level)"
get_docking_status(state::ShipState)::DockingStatus = state.docking_status

"Set the docking status of a ship (ShipState-level)"
function set_docking_status!(state::ShipState, status::DockingStatus)
    state.docking_status = status
    return nothing
end

"Get the docking status of a ship by name. Returns `nothing` if ship not found."
function get_docking_status(gamemap::GameMap, ship_name::Symbol)::Union{DockingStatus, Nothing}
    haskey(gamemap.ships, ship_name) || return nothing
    return get_docking_status(gamemap.ships[ship_name])
end

"Set the docking status of a ship by name."
function set_docking_status!(gamemap::GameMap, ship_name::Symbol, status::DockingStatus)
    set_docking_status!(_get_ship_state(gamemap, ship_name), status)
    return nothing
end

is_ship_moving(::ConnectedDockStat)::Bool = false
is_ship_moving(::ApproachingDockStat)::Bool = true
is_ship_moving(::DepartingDockStat)::Bool = true
is_ship_moving(ship::ShipState)::Bool = is_ship_moving(ship.docking_status)
is_ship_moving(gamemap::GameMap, ship_name::Symbol)::Bool = is_ship_moving(_get_ship_state(gamemap, ship_name))

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
    tile_count = length(gamemap.surface_shiptags)
    tile_mass = tile_count * mass_per_tile

    component_dry_mass = 0.0
    for (_, comp) in gamemap.components
        component_dry_mass += get_component_dry_mass(comp)
    end

    return tile_mass + component_dry_mass
end

"Wet mass (stored fluid) across all ships. If `fluid` is `nothing`, returns total fluid mass; if a specific FluidType, returns mass of only that fluid."
function get_wet_mass(gamemap::GameMap; fluid::Union{FluidType, Nothing} = nothing)::Float64
    wet_mass = 0.0
    for (_, comp) in gamemap.components
        wet_mass += get_component_wet_mass(comp; fluid = fluid)
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
