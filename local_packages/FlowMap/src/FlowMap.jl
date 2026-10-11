#=
Scope: FlowMap's persistent game-map model, ownership helpers, docking, and map-level validation
Formatter: Runic
=#

module FlowMap

using HexFrame, HexComponentsAPI, HexFluids, TypeGroupedDicts
import HexComponentsAPI: placement_valid

using StructEquality
using StaticArrays
using DataStructures: Deque

#= ---------- Type Exports ----------- =#
export ShipState, ShipBlueprint, GameMap, RenderPosOffsetState
export DockingStatus, ConnectedDockStat, ApproachingDockStat, DepartingDockStat
export AbstractSpaceMap, SpaceMapEmpty, GalaxyEscapeSpaceMap, ManoeuvreData
export EncounterClass, ENCOUNTER_SHIP, ENCOUNTER_FUEL_CACHE, ENCOUNTER_SCRAP
export ManoeuvrePhase, PHASE_APPROACH_BURN, PHASE_COAST, PHASE_CAPTURE_BURN, PHASE_ENCOUNTER_READY
export EncounterPoint, PlaythroughStatistics

#= ---------- Learning Progress Exports ----------- =#
export TutorialStatus, TUTORIAL_WAITING, TUTORIAL_IN_PROGRESS, TUTORIAL_COMPLETED
export AbstractLearningSystem, NoLearningSystem, TutorialState, LearningProgress, SandboxLearningState

#= ---------- Function Exports ----------- =#
export add_ship!, remove_ship!, get_all_ship_names, has_ship, get_ship_state, offset_ship!, swap_primary!, merge_ship!, get_ship_blueprint

#= ---------- GameMap Abstraction Functions ----------- =#
export get_component, has_component, set_component!, delete_component!, delete_all_components!
export get_pipe, has_pipe, set_pipe!, delete_pipe!, delete_all_pipes!
export is_click_on_pipe, get_clicked_pipe
export get_components, get_pipes, each_component_of_ship, each_component_of_type, each_pipe_of_ship, each_pipe_of_type
export count_components, count_pipes, count_surface_tiles
export delete_all_surface_tiles!
export is_on_surface_tile, set_surface_tile!, delete_surface_tile!
export is_on_surface_tile_any_ship
export can_place_component_at, validate_component_destination, can_place_pipe_at, can_remove_surface_at, is_node_on_ship_surface
export each_surface_owner, collect_surface_tiles!, collect_surface_edge_tiles!, expand_tileset!, expand_tileset
export get_axial_bounds, get_cartesian_bounds, get_surface_centroid
export get_surface_shiptag, get_component_shiptag, get_pipe_shiptag
export find_ships_adjacent_to_coord, find_ship_for_placement, find_ship_containing
export find_ship_surface_containing_node, find_ship_pipes_containing_node, find_ship_for_node
export DOCKING_SURFACE_CLEARANCE, docking_footprint, docking_footprint_including, docking_footprint_excluding
export ship_footprints_overlap

#= ---------- Learning System Exports ----------- =#
export get_learning_system, set_learning_system!, has_learning_system, is_sandbox_learning

#= ---------- Off-Ship Pipe Exports ----------- =#
export can_place_pipe_offship, validate_offship_pipe_deletion, reassign_pipe_ownership!
export resolve_pipe_ownerships, normalise_pipe_ownership!
export is_node_on_any_ship_surface, flood_search_pipes_from_node!
export has_pipe_component_conflict

#= ---------- Ship Render and Docking Exports ----------- =#
export get_ship_render_offset, get_render_offset, update_render_offset!, compute_departure_axis
export get_docking_status, set_docking_status!, update_docking!, clear_all_docking_statuses!, is_ship_moving

#= ---------- Space Map and Velocity Exports ----------- =#
export get_velocity, set_velocity!, get_space_map_seed, get_time_years, set_time_years!
export get_active_manoeuvre, set_active_manoeuvre!, clear_active_manoeuvre!, has_active_manoeuvre, phase_description
export initialise_spacemap!, get_spacemap, get_mass, get_tile_mass, set_tile_mass!, get_dry_mass, get_wet_mass
export get_position, set_position!, get_target_time, set_target_time!
export is_time_progressing, get_encounter_points, get_last_stop_time, set_last_stop_time!
export is_galaxy_escape_active, get_galaxy_escape_space_map, get_pre_escape_map
export galaxy_escape_progress, get_galaxy_escape_progress

#= ---------- Playthrough Statistics Exports ----------- =#
export get_playthrough_statistics
export get_recorded_play_time_seconds, set_recorded_play_time_seconds!
export get_simulated_ticks, get_simulated_seconds, increment_simulated_ticks!
export get_total_delta_v, record_delta_v!
export get_peak_thrust, record_peak_thrust!
export get_peak_estimated_delta_v, record_peak_estimated_delta_v!
export get_encounter_count, get_total_encounter_count, record_completed_encounter!

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

"Persistent aggregate facts for a map, with play time stored as an as-of-checkpoint value."
@kwdef mutable struct PlaythroughStatistics
    recorded_play_time_seconds::Float64 = 0.0
    simulated_ticks::Int64 = 0
    total_delta_v::Float64 = 0.0
    peak_thrust::Float64 = 0.0
    completed_encounters::Dict{EncounterClass, Int64} = Dict{EncounterClass, Int64}()
    peak_estimated_delta_v::Float64 = 0.0
end
@struct_hash_equal PlaythroughStatistics

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

"Return whether a space map represents an active galaxy-escape attempt."
is_galaxy_escape_active(::AbstractSpaceMap)::Bool = false

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
    components::Dict{TileCoord, PlacedComponent} = Dict{TileCoord, PlacedComponent}()
    pipe_behaviors::Dict{PipeCoord, PipeBehavior} = Dict{PipeCoord, PipeBehavior}()
    ship_tiles::Set{TileCoord} = Set{TileCoord}()
end

"Offset all coordinates in a blueprint by a `TileCoord` step — mutates in-place."
function offset_ship!(blueprint::ShipBlueprint, offset::TileCoord)
    # Components
    moved_c = [(coord, comp) for (coord, comp) in blueprint.components]
    empty!(blueprint.components)
    for (coord, comp) in moved_c
        blueprint.components[offset_by_tile(coord, offset)] = comp
    end
    # Pipes
    moved_p = [(pipe_coord, pipe) for (pipe_coord, pipe) in blueprint.pipe_behaviors]
    empty!(blueprint.pipe_behaviors)
    for (coord, pipe) in moved_p
        blueprint.pipe_behaviors[offset_by_tile(coord, offset)] = pipe
    end
    # Tiles
    new_tiles = Set(offset_by_tile(t, offset) for t in blueprint.ship_tiles)
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


"Top-level game map. Global type-grouped component/pipe stores tagged by ship; per-ship metadata in `ships`. Initialises with a single surface tile at (0,0) for the primary ship to enable tile placement."
@kwdef mutable struct GameMap
    components::TypeGroupedDict{TileCoord, PlacedComponent} = TypeGroupedDict{TileCoord, PlacedComponent}()
    pipe_behaviors::TypeGroupedDict{PipeCoord, PlacedPipe} = TypeGroupedDict{PipeCoord, PlacedPipe}()
    surface_shiptags::Dict{TileCoord, Symbol} = Dict{TileCoord, Symbol}(TileCoord(0, 0) => :primary)
    ships::Dict{Symbol, ShipState} = Dict(:primary => ShipState())
    space_map::AbstractSpaceMap = SpaceMapEmpty()
    learning_system::AbstractLearningSystem = NoLearningSystem()
    statistics::PlaythroughStatistics = PlaythroughStatistics()
end
@struct_hash_equal GameMap

"Terminal galaxy-escape map with authoritative flight state and the required pre-departure map."
@kwdef mutable struct GalaxyEscapeSpaceMap <: AbstractSpaceMap
    velocity::SVector{2, Float64}
    starting_velocity_x::Float64
    departure_time_years::Float64
    pre_escape_map::GameMap

    function GalaxyEscapeSpaceMap(
            velocity::SVector{2, T}, starting_velocity_x::Real, departure_time_years::Real,
            pre_escape_map::GameMap,
        ) where {T <: Real}
        velocity = SVector{2, Float64}(velocity)
        starting_velocity_x = Float64(starting_velocity_x)
        departure_time_years = Float64(departure_time_years)

        all(isfinite, velocity) || throw(ArgumentError("velocity must be finite"))
        isfinite(starting_velocity_x) || throw(ArgumentError("starting velocity must be finite"))
        (isfinite(departure_time_years) && departure_time_years >= 0.0) ||
            throw(ArgumentError("departure time must be finite and non-negative"))
        pre_escape_map.space_map isa GalaxyEscapeSpaceMap &&
            throw(ArgumentError("pre-escape map cannot contain a galaxy-escape attempt"))

        return new(velocity, starting_velocity_x, departure_time_years, pre_escape_map)
    end
end
@struct_hash_equal GalaxyEscapeSpaceMap

is_galaxy_escape_active(::GalaxyEscapeSpaceMap)::Bool = true

"Return net positive X velocity gained since galaxy departure."
galaxy_escape_progress(space_map::GalaxyEscapeSpaceMap)::Float64 =
    max(0.0, space_map.velocity[1] - space_map.starting_velocity_x)

#= ---------- GalaxyEscapeSpaceMap accessor implementations ----------- =#
get_space_map_seed(::GalaxyEscapeSpaceMap)::Nothing = nothing
get_time_years(sm::GalaxyEscapeSpaceMap)::Float64 = sm.departure_time_years
set_time_years!(::GalaxyEscapeSpaceMap, ::Float64) = nothing
get_active_manoeuvre(::GalaxyEscapeSpaceMap)::Nothing = nothing
has_active_manoeuvre(::GalaxyEscapeSpaceMap)::Bool = false
set_active_manoeuvre!(::GalaxyEscapeSpaceMap, ::ManoeuvreData) = nothing
clear_active_manoeuvre!(::GalaxyEscapeSpaceMap) = nothing
get_position(::GalaxyEscapeSpaceMap)::SVector{2, Float64} = SVector(0.0, 0.0)
set_position!(::GalaxyEscapeSpaceMap, ::SVector{2, Float64}) = nothing
get_target_time(sm::GalaxyEscapeSpaceMap)::Float64 = sm.departure_time_years
set_target_time!(::GalaxyEscapeSpaceMap, ::Float64) = nothing
is_time_progressing(::GalaxyEscapeSpaceMap)::Bool = false
get_last_stop_time(sm::GalaxyEscapeSpaceMap)::Float64 = sm.departure_time_years
set_last_stop_time!(::GalaxyEscapeSpaceMap, ::Float64) = nothing
get_encounter_points(::GalaxyEscapeSpaceMap)::Vector{EncounterPoint} = EncounterPoint[]

"Return the complete map captured immediately before galaxy departure."
get_pre_escape_map(space_map::GalaxyEscapeSpaceMap)::GameMap = space_map.pre_escape_map

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
# Playthrough Statistics
# ===============================================================

"Return the persistent playthrough statistics owned by a game map."
get_playthrough_statistics(gamemap::GameMap)::PlaythroughStatistics = gamemap.statistics

"Return real-world play time in seconds as of the last checkpoint."
get_recorded_play_time_seconds(statistics::PlaythroughStatistics)::Float64 = statistics.recorded_play_time_seconds
get_recorded_play_time_seconds(gamemap::GameMap)::Float64 = get_recorded_play_time_seconds(get_playthrough_statistics(gamemap))

"Set real-world play time in seconds as a validated checkpoint value."
function set_recorded_play_time_seconds!(statistics::PlaythroughStatistics, seconds::Real)
    value = _validate_nonnegative_finite(seconds, "recorded play time")
    statistics.recorded_play_time_seconds = value
    return nothing
end
set_recorded_play_time_seconds!(gamemap::GameMap, seconds::Real) =
    set_recorded_play_time_seconds!(get_playthrough_statistics(gamemap), seconds)

"Return the number of completed fixed-step simulation ticks."
get_simulated_ticks(statistics::PlaythroughStatistics)::Int64 = statistics.simulated_ticks
get_simulated_ticks(gamemap::GameMap)::Int64 = get_simulated_ticks(get_playthrough_statistics(gamemap))

"Return detailed simulated time in seconds derived from completed ticks."
get_simulated_seconds(statistics::PlaythroughStatistics)::Float64 = statistics.simulated_ticks / BASE_UPS
get_simulated_seconds(gamemap::GameMap)::Float64 = get_simulated_seconds(get_playthrough_statistics(gamemap))

"Increment the count of completed fixed-step simulation ticks once."
function increment_simulated_ticks!(statistics::PlaythroughStatistics)
    statistics.simulated_ticks += 1
    return nothing
end
increment_simulated_ticks!(gamemap::GameMap) = increment_simulated_ticks!(get_playthrough_statistics(gamemap))

"Return the accumulated scalar path length through velocity space in delta-V units."
get_total_delta_v(statistics::PlaythroughStatistics)::Float64 = statistics.total_delta_v
get_total_delta_v(gamemap::GameMap)::Float64 = get_total_delta_v(get_playthrough_statistics(gamemap))

"Add a non-negative delta-V increment to the playthrough total."
function record_delta_v!(statistics::PlaythroughStatistics, delta_v::Real)
    value = _validate_nonnegative_finite(delta_v, "delta-V increment")
    statistics.total_delta_v += value
    return nothing
end
record_delta_v!(gamemap::GameMap, delta_v::Real) = record_delta_v!(get_playthrough_statistics(gamemap), delta_v)

"Return the greatest combined thrust magnitude recorded during a simulation tick."
get_peak_thrust(statistics::PlaythroughStatistics)::Float64 = statistics.peak_thrust
get_peak_thrust(gamemap::GameMap)::Float64 = get_peak_thrust(get_playthrough_statistics(gamemap))

"Record a non-negative combined thrust magnitude, retaining the historical peak."
function record_peak_thrust!(statistics::PlaythroughStatistics, thrust::Real)
    value = _validate_nonnegative_finite(thrust, "thrust magnitude")
    statistics.peak_thrust = max(statistics.peak_thrust, value)
    return nothing
end
record_peak_thrust!(gamemap::GameMap, thrust::Real) = record_peak_thrust!(get_playthrough_statistics(gamemap), thrust)

"Return the greatest conservative remaining delta-V estimate recorded for the playthrough."
get_peak_estimated_delta_v(statistics::PlaythroughStatistics)::Float64 = statistics.peak_estimated_delta_v
get_peak_estimated_delta_v(gamemap::GameMap)::Float64 = get_peak_estimated_delta_v(get_playthrough_statistics(gamemap))

"Record a conservative remaining delta-V estimate, returning whether the historical peak increased."
function record_peak_estimated_delta_v!(statistics::PlaythroughStatistics, estimate::Real)::Bool
    value = _validate_nonnegative_finite(estimate, "estimated delta-V")
    value <= statistics.peak_estimated_delta_v && return false

    statistics.peak_estimated_delta_v = value
    return true
end
record_peak_estimated_delta_v!(gamemap::GameMap, estimate::Real)::Bool =
    record_peak_estimated_delta_v!(get_playthrough_statistics(gamemap), estimate)

"Return the number of completed encounters for one class, or zero when absent."
get_encounter_count(statistics::PlaythroughStatistics, encounter_class::EncounterClass)::Int64 =
    get(statistics.completed_encounters, encounter_class, Int64(0))
get_encounter_count(gamemap::GameMap, encounter_class::EncounterClass)::Int64 =
    get_encounter_count(get_playthrough_statistics(gamemap), encounter_class)

"Return the derived total of all completed encounter-class buckets."
get_total_encounter_count(statistics::PlaythroughStatistics)::Int64 =
    sum(values(statistics.completed_encounters); init = Int64(0))
get_total_encounter_count(gamemap::GameMap)::Int64 =
    get_total_encounter_count(get_playthrough_statistics(gamemap))

"Increment the completed encounter bucket for a class."
function record_completed_encounter!(statistics::PlaythroughStatistics, encounter_class::EncounterClass)
    statistics.completed_encounters[encounter_class] = get_encounter_count(statistics, encounter_class) + Int64(1)
    return nothing
end
record_completed_encounter!(gamemap::GameMap, encounter_class::EncounterClass) =
    record_completed_encounter!(get_playthrough_statistics(gamemap), encounter_class)

function _validate_nonnegative_finite(value::Real, name::AbstractString)::Float64
    converted = Float64(value)
    (isfinite(converted) && converted >= 0.0) || throw(ArgumentError("$name must be finite and non-negative"))
    return converted
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
- any coordinate in `blueprint.pipe_behaviors` is already occupied (collision guard)
"""
function merge_ship!(
        gamemap::GameMap, ship_name::Symbol, blueprint::ShipBlueprint;
        docking_status::DockingStatus = ConnectedDockStat()
    )
    has_ship(gamemap, ship_name) && error("Ship '$ship_name' already exists in gamemap")

    # Validate no coordinate collisions before mutation
    for coord in keys(blueprint.components)
        haskey(gamemap.components, coord) && error(
            "Cannot merge ship '$ship_name': component already exists at $coord (from ship '$(gamemap.components[coord].ship)')"
        )
    end
    for coord in keys(blueprint.pipe_behaviors)
        haskey(gamemap.pipe_behaviors, coord) && error(
            "Cannot merge ship '$ship_name': pipe already exists at $coord (from ship '$(gamemap.pipe_behaviors[coord].ship)')"
        )
    end
    for tile in blueprint.ship_tiles
        haskey(gamemap.surface_shiptags, tile) && error(
            "Cannot merge ship '$ship_name': surface tile already exists at $tile (from ship '$(gamemap.surface_shiptags[tile])')"
        )
    end

    # Safe to merge after validation passes
    for (coord, comp) in blueprint.components
        gamemap.components[coord] = PlacedComponent(comp.component, comp.rotation, comp.mirrored, ship_name)
    end
    for (coord, pipe) in blueprint.pipe_behaviors
        gamemap.pipe_behaviors[coord] = PlacedPipe(pipe, ship_name)
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
    delete_all_components!(gamemap; ship_name = name)
    delete_all_pipes!(gamemap; ship_name = name)
    filter!(((_, ship_name),) -> ship_name !== name, gamemap.surface_shiptags)
    return nothing
end

get_all_ship_names(gamemap::GameMap)::Vector{Symbol} = collect(keys(gamemap.ships))
has_ship(gamemap::GameMap, name::Symbol)::Bool = haskey(gamemap.ships, name)
get_ship_state(gamemap::GameMap, name::Symbol)::ShipState = _get_ship_state(gamemap, name)

#= ---------- GameMap: Component Access ----------- =#
"Get the `PlacedComponent` at `coord`, or `nothing`. Read `.ship` on the result to determine ownership."
function get_component(gamemap::GameMap, coord::TileCoord)
    return get(gamemap.components, coord, nothing)
end

"Whether any component exists at `coord`. To check ownership, fetch with `get_component` and compare `.ship`."
function has_component(gamemap::GameMap, coord::TileCoord)::Bool
    return haskey(gamemap.components, coord)
end

"Place `component` at `coord`. Ownership is taken from `component.ship` — construct the wrapper with the desired ship tag."
function set_component!(gamemap::GameMap, coord::TileCoord, component::PlacedComponent)
    gamemap.components[coord] = component
    return nothing
end

"Bulk-place a dictionary or `TypeGroupedDict` of components, preserving ship tags. Passing the map's own collection is a no-op."
function set_component!(gamemap::GameMap, components::Union{AbstractDict{TileCoord, <:PlacedComponent}, TypeGroupedDict{TileCoord, <:PlacedComponent}})
    components === gamemap.components && return nothing
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

"Return the component collection shared with the gamemap. Do not mutate; use `set_component!` / `delete_component!`, `each_component_of_ship`, or `each_component_of_type`."
get_components(gamemap::GameMap) = gamemap.components

"Lazy iterator over `PlacedComponent` values belonging to `ship_name`."
each_component_of_ship(gamemap::GameMap, ship_name::Symbol) =
    Iterators.filter(c -> c.ship === ship_name, values(get_components(gamemap)))

"Lazy iterator over `PlacedComponent` values whose component behaviour is of type `T`."
each_component_of_type(gamemap::GameMap, ::Type{T}) where {T} =
    Iterators.filter(c -> c.component isa T, values(get_components(gamemap)))

#= ---------- GameMap: Pipe Access ----------- =#
"Get the `PlacedPipe` at `coord`, or `nothing`. Read `.ship` on the result to determine ownership."
function get_pipe(gamemap::GameMap, coord::PipeCoord)
    return get(gamemap.pipe_behaviors, coord, nothing)
end

"Whether any pipe exists at `coord`. To check ownership, fetch with `get_pipe` and compare `.ship`."
function has_pipe(gamemap::GameMap, coord::PipeCoord)::Bool
    return haskey(gamemap.pipe_behaviors, coord)
end

"Place `pipe` at `coord`. Ownership is taken from `pipe.ship` — construct the `PlacedPipe` with the desired ship tag."
function set_pipe!(gamemap::GameMap, coord::PipeCoord, pipe::PlacedPipe)
    gamemap.pipe_behaviors[coord] = pipe
    return nothing
end

"Place raw `pipe` at `coord`, tagging it with `ship_name` before insertion."
function set_pipe!(gamemap::GameMap, coord::PipeCoord, pipe::PipeBehavior; ship_name::Symbol = :primary)
    return set_pipe!(gamemap, coord, PlacedPipe(pipe, ship_name))
end

"Delete the pipe at `coord` if present. To delete only when owned by a particular ship, gate the call externally."
function delete_pipe!(gamemap::GameMap, coord::PipeCoord)
    delete!(gamemap.pipe_behaviors, coord)
    return nothing
end

"Return the pipe collection shared with the gamemap. Do not mutate; use `set_pipe!` / `delete_pipe!`, `each_pipe_of_ship`, or `each_pipe_of_type`."
get_pipes(gamemap::GameMap) = gamemap.pipe_behaviors

"Shortest distance from a point to a line segment defined by endpoints `a` and `b`."
function _point_to_segment_distance(p::CartesianCoord, a::CartesianCoord, b::CartesianCoord)::Float64
    ab = b - a
    ap = p - a
    len_sq = ab.x^2 + ab.y^2
    len_sq == 0.0 && return sqrt(ap.x^2 + ap.y^2)

    t = clamp((ap.x * ab.x + ap.y * ab.y) / len_sq, 0.0, 1.0)
    closest = CartesianCoord(a.x + t * ab.x, a.y + t * ab.y)
    delta = p - closest
    return sqrt(delta.x^2 + delta.y^2)
end

"Return whether a click lies inside the rendered width of a placed pipe."
function is_click_on_pipe(click::CartesianCoord, coord::PipeCoord, pipe)::Bool
    radius = get_pipe_click_radius(pipe)
    distance = _point_to_segment_distance(click, to_cartesian(coord.v1), to_cartesian(coord.v2))
    return distance <= radius + 1.0e-12
end

"Return the highest rendered real pipe under a click, or `nothing` if no pipe was hit."
function get_clicked_pipe(click::CartesianCoord, gamemap::GameMap)::Union{Nothing, PipeCoord}
    clicked_tile = round_to_tile(click)
    candidate_tiles = (clicked_tile, get_adjacent_tiles_for_tile(clicked_tile)...)
    selected::Union{Nothing, PipeCoord} = nothing
    selected_rank = typemin(Int)

    for tile in candidate_tiles
        for coord in get_pipe_segments(tile)
            pipe = get_pipe(gamemap, coord)
            isnothing(pipe) && continue

            rank = get_stacking_rank(coord)
            rank <= selected_rank && continue

            is_click_on_pipe(click, coord, pipe) || continue

            selected = coord
            selected_rank = rank
        end
    end

    return selected
end

"Lazy iterator over `PlacedPipe` values belonging to `ship_name`."
each_pipe_of_ship(gamemap::GameMap, ship_name::Symbol) =
    Iterators.filter(p -> p.ship === ship_name, values(get_pipes(gamemap)))

"Lazy iterator over `PlacedPipe` values whose pipe behaviour is of type `T`."
each_pipe_of_type(gamemap::GameMap, ::Type{T}) where {T} =
    Iterators.filter(p -> p.pipe isa T, values(get_pipes(gamemap)))

#= ---------- Cross-Ship Surface Queries ----------- =#
"Check whether the coordinate is part of any ship's surface."
function is_on_surface_tile_any_ship(coord::TileCoord, gamemap::GameMap)::Tuple{Bool, Union{Symbol, Nothing}}
    ship_name = get_surface_shiptag(gamemap, coord)
    return (!isnothing(ship_name), ship_name)
end

#= ---------- Counts and Batch Operations ----------- =#
"Count components in the map, optionally restricting the total to one ship."
function count_components(gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)::Int
    if isnothing(ship_name)
        return length(gamemap.components)
    else
        return count(c -> c.ship === ship_name, values(gamemap.components))
    end
end

"Count pipes in the map, optionally restricting the total to one ship."
function count_pipes(gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)::Int
    if isnothing(ship_name)
        return length(gamemap.pipe_behaviors)
    else
        return count(p -> p.ship === ship_name, values(gamemap.pipe_behaviors))
    end
end

"Count surface tiles in the map, optionally restricting the total to one ship."
function count_surface_tiles(gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)::Int
    if isnothing(ship_name)
        return length(gamemap.surface_shiptags)
    end

    _get_ship_state(gamemap, ship_name)
    return count(owner -> owner === ship_name, values(gamemap.surface_shiptags))
end

"Delete all components from the map, optionally restricting removal to one ship."
function delete_all_components!(gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)
    if isnothing(ship_name)
        empty!(gamemap.components)
    else
        coords = [coord for (coord, c) in gamemap.components if c.ship === ship_name]
        for coord in coords
            delete!(gamemap.components, coord)
        end
    end
    return nothing
end

"Delete all pipes from the map, optionally restricting removal to one ship."
function delete_all_pipes!(gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)
    if isnothing(ship_name)
        empty!(gamemap.pipe_behaviors)
    else
        coords = [coord for (coord, p) in gamemap.pipe_behaviors if p.ship === ship_name]
        for coord in coords
            delete!(gamemap.pipe_behaviors, coord)
        end
    end
    return nothing
end

"Delete every surface tile owned by `ship_name`."
function delete_all_surface_tiles!(gamemap::GameMap; ship_name::Symbol = :primary)
    _get_ship_state(gamemap, ship_name)
    filter!(((_, owner),) -> owner !== ship_name, gamemap.surface_shiptags)
    return nothing
end

#= ---------- Surface Access ----------- =#
"Read the owning ship tag for a surface tile, if present."
get_surface_shiptag(gamemap::GameMap, coord::TileCoord)::Union{Symbol, Nothing} = get(gamemap.surface_shiptags, coord, nothing)

"Return whether `coord` belongs to `ship_name`'s surface."
is_on_surface_tile(coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Bool =
    get_surface_shiptag(gamemap, coord) === ship_name

"Tag `coord` as a surface tile owned by `ship_name`."
function set_surface_tile!(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)
    _get_ship_state(gamemap, ship_name)
    gamemap.surface_shiptags[coord] = ship_name
    return nothing
end

"Tag every tile in `surface` as owned by `ship_name`."
function set_surface_tile!(gamemap::GameMap, surface; ship_name::Symbol = :primary)
    _get_ship_state(gamemap, ship_name)
    for coord in surface
        gamemap.surface_shiptags[coord] = ship_name
    end
    return nothing
end

"Delete `coord` from `ship_name`'s surface if present, returning whether a tile was removed."
function delete_surface_tile!(
        gamemap::GameMap, coord::TileCoord;
        ship_name::Symbol = :primary
    )::Bool
    _get_ship_state(gamemap, ship_name)
    get_surface_shiptag(gamemap, coord) === ship_name || return false
    delete!(gamemap.surface_shiptags, coord)
    return true
end

"Iterate `(tile, ship_name)` pairs for every surface tile in the map."
each_surface_owner(gamemap::GameMap) = pairs(gamemap.surface_shiptags)

"Collect surface tiles into `dest`, optionally filtering by owner."
function collect_surface_tiles!(
        dest, gamemap::GameMap;
        ship_name::Union{Symbol, Nothing} = nothing,
        exclude_ship::Union{Symbol, Nothing} = nothing
    )
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
function placement_valid(behav::T, coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary, kwargs...)::RequestStatus where {T <: ComponentBehavior}
    return is_on_surface_tile(coord, gamemap; ship_name) ? ValidRequest() : InvalidRequest("Place components on a ship surface")
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

#= ---------- Ship Docking Footprints ----------- =#

"Minimum surface-to-surface clearance maintained while ships are docked."
const DOCKING_SURFACE_CLEARANCE::Int = 2

"Add every tile touching an endpoint node of `pipe_coords` to `dest`."
function _add_docking_pipe_clearance_tiles!(dest::Set{TileCoord}, pipe_coords)
    for pipe_coord in pipe_coords
        for vertex in (pipe_coord.v1, pipe_coord.v2)
            for (tile, _) in HexFrame.get_adjacent_tiles_for_node(to_nodecoord(vertex))
                push!(dest, tile)
            end
        end
    end
    return dest
end

"Build a docking footprint from surface tiles and pipe endpoint clearance."
function docking_footprint(surface_tiles, pipe_coords; surface_clearance::Integer = 0)::Set{TileCoord}
    surface_clearance < 0 && throw(ArgumentError("surface_clearance must be non-negative"))
    footprint = surface_clearance == 0 ? Set{TileCoord}(surface_tiles) : expand_tileset(Set{TileCoord}(surface_tiles), surface_clearance)
    _add_docking_pipe_clearance_tiles!(footprint, pipe_coords)
    return footprint
end

"Build the surface and pipe-clearance footprint for a detached ship blueprint."
function docking_footprint(blueprint::ShipBlueprint; surface_clearance::Integer = 0)::Set{TileCoord}
    return docking_footprint(blueprint.ship_tiles, keys(blueprint.pipe_behaviors); surface_clearance)
end

"Build the surface and pipe-clearance footprint for every ship in `gamemap`."
function docking_footprint(gamemap::GameMap; surface_clearance::Integer = 0)::Set{TileCoord}
    return docking_footprint_excluding(gamemap; surface_clearance)
end

"Build a docking footprint containing only `included_ships`."
function docking_footprint_including(
        gamemap::GameMap, included_ships::Vararg{Symbol}; surface_clearance::Integer = 0
    )::Set{TileCoord}
    surface_tiles = Set{TileCoord}()
    pipe_coords = PipeCoord[]

    for (tile, ship_name) in each_surface_owner(gamemap)
        ship_name in included_ships || continue
        push!(surface_tiles, tile)
    end
    for (coord, pipe) in get_pipes(gamemap)
        pipe.ship in included_ships || continue
        push!(pipe_coords, coord)
    end

    return docking_footprint(surface_tiles, pipe_coords; surface_clearance)
end

"Build a docking footprint containing every ship except `excluded_ships`."
function docking_footprint_excluding(
        gamemap::GameMap, excluded_ships::Vararg{Symbol}; surface_clearance::Integer = 0
    )::Set{TileCoord}
    surface_tiles = Set{TileCoord}()
    pipe_coords = PipeCoord[]

    for (tile, ship_name) in each_surface_owner(gamemap)
        ship_name in excluded_ships && continue
        push!(surface_tiles, tile)
    end
    for (coord, pipe) in get_pipes(gamemap)
        pipe.ship in excluded_ships && continue
        push!(pipe_coords, coord)
    end

    return docking_footprint(surface_tiles, pipe_coords; surface_clearance)
end

"Return whether `incoming_footprint` overlaps `existing_footprint` after `offset` translation."
function ship_footprints_overlap(
        existing_footprint::Set{TileCoord}, incoming_footprint::Set{TileCoord}, offset::TileCoord = TileCoord(0, 0)
    )::Bool
    for tile in incoming_footprint
        tile + offset in existing_footprint && return true
    end
    return false
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

"Check whether a component can be placed at a coordinate."
function can_place_component_at(coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary)::RequestStatus
    if !is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return InvalidRequest("Not on ship surface")
    end
    if has_pipe_component_conflict(coord, gamemap)
        return InvalidRequest("Tile contains a pipe segment")
    end
    return ValidRequest()
end

"""
Validate a candidate placed component at `destination` and return a request result containing its destination ship.

The candidate's existing `ship` field is not used to resolve destination ownership.

Coordinates in `vacating_coords` relax component occupancy only. Pipe conflicts and
component-specific placement rules are always checked.
"""
function validate_component_destination(
        component::PlacedComponent,
        destination::TileCoord,
        gamemap::GameMap;
        vacating_coords::Union{Nothing, AbstractSet{TileCoord}} = nothing,
    )::RequestResult{Symbol}
    occupant = get_component(gamemap, destination)
    destination_vacated = !isnothing(vacating_coords) && destination in vacating_coords
    if !isnothing(occupant) && !destination_vacated
        return InvalidRequest("a component already occupies the destination tile")
    end

    if has_pipe_component_conflict(destination, gamemap)
        return InvalidRequest("a pipe segment crosses the destination tile")
    end

    return find_ship_for_placement(
        component.component,
        destination,
        gamemap;
        rotation = component.rotation,
        mirrored = component.mirrored,
    )
end

"Check if a pipe can be placed at a pipe coordinate (both endpoint nodes must be on ship surface)."
function can_place_pipe_at(coord::PipeCoord, gamemap::GameMap; ship_name::Symbol = :primary)::RequestStatus
    if has_pipe_component_conflict(coord, gamemap)
        return InvalidRequest("Pipe segment crosses an occupied tile")
    end

    v1_node = to_nodecoord(coord.v1)
    v2_node = to_nodecoord(coord.v2)
    if !is_node_on_ship_surface(v1_node, gamemap; ship_name = ship_name)
        return InvalidRequest("Pipe endpoint node at $(coord.v1.tile) is not connected to ship surface")
    end
    if !is_node_on_ship_surface(v2_node, gamemap; ship_name = ship_name)
        return InvalidRequest("Pipe endpoint node at $(coord.v2.tile) is not connected to ship surface")
    end
    return ValidRequest()
end

"Return true when a pipe segment would cross an occupied component tile."
function has_pipe_component_conflict(subject::PipeCoord, gamemap::GameMap)::Bool
    tile = get_tile_containing_pipe(subject)
    isnothing(tile) && return false
    return !isnothing(get_component(gamemap, tile))
end

"Return true when an existing non-side pipe segment crosses `subject`."
function has_pipe_component_conflict(subject::TileCoord, gamemap::GameMap)::Bool
    for pipe in get_pipe_segments(subject)
        get_tile_containing_pipe(pipe) == subject || continue
        has_pipe(gamemap, pipe) && return true
    end
    return false
end

"Check if a surface tile can be removed (must not have a component on it)."
function can_remove_surface_at(coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary)::RequestStatus
    component = get_component(gamemap, coord)
    if !isnothing(component) && component.ship === ship_name
        return InvalidRequest("Surface cannot be deleted under a component, delete component first")
    end
    # TODO: This validation doesn't prevent nozzles from being left floating when their input node's
    # surface tile is removed. Consider adding a check that iterates through all components and validates
    # their placement after surface removal, or implement a separate validation pass that can be triggered
    # when editing surface tiles. For now, users can create invalid states by removing surface under
    # nozzle input nodes, but this won't cause crashes - just invalid placement that can be fixed.
    return ValidRequest()
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

"Find a ship accepting a component placement, or return the most specific placement rejection reason."
function find_ship_for_placement(
        component::ComponentBehavior, coord::TileCoord, gamemap::GameMap;
        rotation::HexAxis, mirrored::Bool = false,
    )::RequestResult{Symbol}
    first_reason = "Place components on a ship surface"
    for (ship_name, _) in gamemap.ships
        status = placement_valid(component, coord, gamemap; rotation, mirrored, ship_name)
        isvalidrequest(status) && return ValidRequestResult(ship_name)
        status_reason = reason(status)
        if first_reason == "Place components on a ship surface" && status_reason != first_reason
            first_reason = status_reason
        end
    end
    return InvalidRequest(first_reason)
end

"Read the stored ship tag from the component wrapper at `coord`, if present."
function get_component_shiptag(gamemap::GameMap, coord::TileCoord)::Union{Symbol, Nothing}
    c = get(gamemap.components, coord, nothing)
    return isnothing(c) ? nothing : c.ship
end

"Read the stored ship tag from the pipe wrapper at `coord`, if present."
function get_pipe_shiptag(gamemap::GameMap, coord::PipeCoord)::Union{Symbol, Nothing}
    p = get(gamemap.pipe_behaviors, coord, nothing)
    return isnothing(p) ? nothing : p.ship
end

"Find which ship surface contains both endpoints of `coord`. Returns `nothing` when no single ship contains both nodes."
function find_ship_containing(coord::PipeCoord, gamemap::GameMap)::Union{Symbol, Nothing}
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

find_ship_containing(gamemap::GameMap, coord::PipeCoord)::Union{Symbol, Nothing} = find_ship_containing(coord, gamemap)

"Find a ship by adjacent surface ownership only. Returns `default` if no adjacent surface is found."
function find_ship_surface_containing_node(
        node::NodeCoord, gamemap::GameMap;
        default::Union{Symbol, Nothing} = nothing
    )::Union{Symbol, Nothing}
    for (tile, _) in get_adjacent_tiles_for_node(node)
        sn = get_surface_shiptag(gamemap, tile)
        !isnothing(sn) && return sn
    end
    return default
end

"Find a ship by adjacent pipe ownership only. Non-axis nodes return `default` immediately."
function find_ship_pipes_containing_node(
        node::NodeCoord, gamemap::GameMap;
        default::Union{Symbol, Nothing} = nothing
    )::Union{Symbol, Nothing}
    is_axis(node.dir) || return default

    vertex = to_vertex(node)
    for pipe in get_pipe_segments(vertex)
        sn = get_pipe_shiptag(gamemap, pipe)
        !isnothing(sn) && return sn
    end
    return default
end

"Find a ship for `node` by checking surface ownership first, then pipe ownership. Returns `default` if no ship is found."
function find_ship_for_node(
        node::NodeCoord, gamemap::GameMap;
        default::Union{Symbol, Nothing} = :primary
    )::Union{Symbol, Nothing}
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
    for (coord, pipe) in gamemap.pipe_behaviors
        pipe.ship === ship_name || continue
        blueprint.pipe_behaviors[coord] = pipe.pipe  # unwrap PlacedPipe to raw PipeBehavior
    end
    collect_surface_tiles!(blueprint.ship_tiles, gamemap; ship_name = ship_name)
    return blueprint
end

# ===============================================================
# Placement Validation Functions
# ===============================================================

#= ---------- Placement & Deletion Validation ----------- =#

"""
    flood_search_pipes_from_node!(reachable, all_pipe_coords, start_node)

Flood-fill through pipe segments starting from `start_node`, collecting all reachable coordinates into
`reachable`. Only traverses coordinates present in `all_pipe_coords`. Uses BFS over the hex vertex
graph, following pipe segments from vertex to vertex via shared endpoints.

Placed in FlowMap (rather than FlowEngine) because it depends only on HexFrame primitives and
is needed by FlowMap's own validation logic.
"""
function flood_search_pipes_from_node!(reachable::Set{PipeCoord}, all_pipe_coords, start_node::NodeCoord)
    visited_nodes = Set{NodeCoord}()
    queue = Deque{NodeCoord}()
    push!(queue, start_node)

    while !isempty(queue)
        node = popfirst!(queue)
        node in visited_nodes && continue
        push!(visited_nodes, node)

        vertex = to_proper(to_vertex(node))
        for coord in get_pipe_segments(vertex)
            if coord in all_pipe_coords && !(coord in reachable)
                push!(reachable, coord)
                other_vertex = coord.v1 == vertex ? coord.v2 : coord.v1
                other_node = to_nodecoord(other_vertex)
                if !(other_node in visited_nodes)
                    push!(queue, other_node)
                end
            end
        end
    end
    return nothing
end

"""
Resolve ownership for a complete candidate pipe topology without mutating `gamemap`.

Off-surface networks touching multiple ships are assigned to the ship whose name sorts first,
making ownership independent of dictionary and set iteration order.
"""
function resolve_pipe_ownerships(gamemap::GameMap, pipe_coords)::RequestResult{Dict{PipeCoord, Symbol}}
    ownerships = Dict{PipeCoord, Symbol}()
    off_surface = Set{PipeCoord}()

    for coord in pipe_coords
        ship = find_ship_containing(gamemap, coord)
        if isnothing(ship)
            push!(off_surface, coord)
        else
            ownerships[coord] = ship
        end
    end

    unvisited = copy(off_surface)
    while !isempty(unvisited)
        first_coord = first(unvisited)
        connected = Set{PipeCoord}()
        flood_search_pipes_from_node!(connected, off_surface, to_nodecoord(first_coord.v1))
        setdiff!(unvisited, connected)

        target_ship::Union{Symbol, Nothing} = nothing
        for coord in connected, vertex in (coord.v1, coord.v2)
            ship = find_ship_surface_containing_node(to_nodecoord(vertex), gamemap; default = nothing)
            isnothing(ship) && continue
            target_ship = isnothing(target_ship) ? ship : min(target_ship, ship)
        end
        isnothing(target_ship) &&
            return InvalidRequest("Pipe network is not connected to a ship surface")

        for coord in connected
            ownerships[coord] = target_ship
        end
    end
    return ValidRequestResult(ownerships)
end

"Normalise every placed pipe's owner from the map's complete final topology."
function normalise_pipe_ownership!(gamemap::GameMap)::RequestStatus
    ownership_result = resolve_pipe_ownerships(gamemap, keys(gamemap.pipe_behaviors))
    isvalidrequest(ownership_result) || return ownership_result
    ownerships = unwrap(ownership_result)

    for (coord, ship) in ownerships
        placed = gamemap.pipe_behaviors[coord]
        placed.ship === ship || (gamemap.pipe_behaviors[coord] = PlacedPipe(placed.pipe, ship))
    end
    return ValidRequest()
end

"""
    can_place_pipe_offship(coord, gamemap) → RequestResult{Symbol}

Perform the minimum local check needed to preview placing an off-surface pipe at `coord`.
Requires an endpoint to touch a ship surface or an existing, authoritatively normalised pipe
network. Committed map edits must subsequently resolve the complete pipe topology.
"""
function can_place_pipe_offship(coord::PipeCoord, gamemap::GameMap)::RequestResult{Symbol}
    if has_pipe_component_conflict(coord, gamemap)
        return InvalidRequest("Pipe segment crosses an occupied tile")
    end

    v1_ship = find_ship_for_node(to_nodecoord(coord.v1), gamemap; default = nothing)
    v2_ship = find_ship_for_node(to_nodecoord(coord.v2), gamemap; default = nothing)

    if isnothing(v1_ship) && isnothing(v2_ship)
        return InvalidRequest("Neither endpoint is connected to a ship or existing pipe")
    end

    return ValidRequestResult(!isnothing(v1_ship) ? v1_ship : v2_ship)
end

"""
    validate_offship_pipe_deletion(coord, gamemap) → valid

Perform the minimum local check needed to preview deleting the off-surface pipe at `coord`.
Only networks connected through its endpoints can be affected. Committed map edits must
subsequently resolve the complete pipe topology.
"""
function validate_offship_pipe_deletion(coord::PipeCoord, gamemap::GameMap)::Bool
    remaining_offship = Set{PipeCoord}()
    for (pipe_coord, _) in gamemap.pipe_behaviors
        pipe_coord == coord && continue
        v1_on = is_node_on_any_ship_surface(to_nodecoord(pipe_coord.v1), gamemap)
        v2_on = is_node_on_any_ship_surface(to_nodecoord(pipe_coord.v2), gamemap)
        !(v1_on && v2_on) && push!(remaining_offship, pipe_coord)
    end
    isempty(remaining_offship) && return true

    for start_node in (to_nodecoord(coord.v1), to_nodecoord(coord.v2))
        reachable = Set{PipeCoord}()
        flood_search_pipes_from_node!(reachable, remaining_offship, start_node)
        isempty(reachable) && continue
        has_ship_connection = any(
            is_node_on_any_ship_surface(to_nodecoord(vertex), gamemap)
                for pipe_coord in reachable
                for vertex in (pipe_coord.v1, pipe_coord.v2)
        )
        has_ship_connection || return false
    end
    return true
end

"""
    reassign_pipe_ownership!(deleted_coord, gamemap)

Compatibility wrapper that normalises ownership after deleting an off-surface pipe.
The normalisation status is intentionally discarded because this compatibility API returns `nothing`.
"""
function reassign_pipe_ownership!(::PipeCoord, gamemap::GameMap)
    normalisation_status = normalise_pipe_ownership!(gamemap)
    isvalidrequest(normalisation_status) || return nothing
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
        gamemap.components[coord] = PlacedComponent(c.component, c.rotation, c.mirrored, rename_to[c.ship])
    end
    for coord in collect(keys(gamemap.pipe_behaviors))
        p = gamemap.pipe_behaviors[coord]
        haskey(rename_to, p.ship) || continue
        gamemap.pipe_behaviors[coord] = PlacedPipe(p.pipe, rename_to[p.ship])
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
Rewrites component keys, pipe coordinate keys, and surface tiles for the given ship.
"""
function offset_ship!(gamemap::GameMap, ship_name::Symbol, offset::TileCoord)
    # Components — collect, clear, reinsert
    moved_c = [(coord, comp) for (coord, comp) in gamemap.components if comp.ship === ship_name]
    for (old_coord, _) in moved_c
        delete!(gamemap.components, old_coord)
    end
    for (coord, comp) in moved_c
        gamemap.components[offset_by_tile(coord, offset)] = comp
    end

    # Pipes
    moved_p = [(coord, pipe) for (coord, pipe) in gamemap.pipe_behaviors if pipe.ship === ship_name]
    for (old_coord, _) in moved_p
        delete!(gamemap.pipe_behaviors, old_coord)
    end
    for (coord, pipe) in moved_p
        gamemap.pipe_behaviors[offset_by_tile(coord, offset)] = pipe
    end

    # Surface tiles
    _get_ship_state(gamemap, ship_name)
    moved_tiles = [tile for (tile, owner) in each_surface_owner(gamemap) if owner === ship_name]
    for tile in moved_tiles
        delete!(gamemap.surface_shiptags, tile)
    end
    for tile in moved_tiles
        gamemap.surface_shiptags[offset_by_tile(tile, offset)] = ship_name
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

"Return whether a game map contains an active galaxy-escape attempt."
is_galaxy_escape_active(gamemap::GameMap)::Bool = is_galaxy_escape_active(gamemap.space_map)

"Return the active galaxy-escape map, or `nothing` for other space-map modes."
function get_galaxy_escape_space_map(gamemap::GameMap)::Union{Nothing, GalaxyEscapeSpaceMap}
    space_map = gamemap.space_map
    return space_map isa GalaxyEscapeSpaceMap ? space_map : nothing
end

"Return the pre-departure map, or `nothing` outside a galaxy-escape attempt."
function get_pre_escape_map(gamemap::GameMap)::Union{Nothing, GameMap}
    space_map = get_galaxy_escape_space_map(gamemap)
    return isnothing(space_map) ? nothing : get_pre_escape_map(space_map)
end

"Return current galaxy-escape progress, or `nothing` outside an escape attempt."
function get_galaxy_escape_progress(gamemap::GameMap)::Union{Nothing, Float64}
    space_map = get_galaxy_escape_space_map(gamemap)
    return isnothing(space_map) ? nothing : galaxy_escape_progress(space_map)
end

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

    component_dry_mass = mapreducevalues(get_component_dry_mass, +, gamemap.components; init = 0.0)
    return tile_mass + component_dry_mass
end

"Wet mass (stored fluid) across all ships. If `fluid` is `nothing`, returns total fluid mass; if a specific FluidType, returns mass of only that fluid."
function get_wet_mass(gamemap::GameMap; fluid::Union{FluidType, Nothing} = nothing)::Float64
    return mapreducevalues(+, gamemap.components; init = 0.0) do comp
        return get_component_wet_mass(comp; fluid = fluid)
    end
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
