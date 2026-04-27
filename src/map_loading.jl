# ===============================================================
# Map Loading and Saving
# ===============================================================
#
# JLD2 serialisation helpers for GameMap persistence.
#
# This file is intentionally lean — it only imports what is needed
# for loading and saving, with no rendering or UI dependencies.
# That allows it to be included in both the full game and in
# headless diagnostic / tooling scripts.
#
# See: https://juliaio.github.io/JLD2.jl/stable/advanced/#Upgrading-old-structures-on-load
#
# We rely on `JLD2.Upgrade` plus `rconvert` to reconstruct current save types
# from on-disk NamedTuple representations when explicit control is needed.
# Transient fields (such as runtime-only caches inside learning or space-map
# state) are rebuilt on load rather than trusted from disk. The `get()` calls
# below keep the loader ready for future field additions without retaining
# one-off migrations for historical save formats.
# ===============================================================

using JLD2
using StaticArrays
using HexFrame, FlowMap, HexFlowProcGen, HexFluids
using HexComponentsAPI

import JLD2: rconvert

#= ---------- Core Map Types ----------- =#

"Rebuild legacy non-parametric `ComponentOnTile` values from a NamedTuple."
JLD2.rconvert(::Type{HexComponentsAPI.ComponentOnTile}, nt::NamedTuple) = HexComponentsAPI.ComponentOnTile(
    nt.component,
    get(nt, :rotation, HexFrame.Q_POS),
)

"Rebuild `ShipMap` from a NamedTuple."
JLD2.rconvert(::Type{FlowMap.ShipMap}, nt::NamedTuple) = FlowMap.ShipMap(
    components = get(nt, :components, Dict{TileCoord, ComponentOnTile}()),
    pipe_behaviors = get(nt, :pipe_behaviors, Dict{EdgeCoord, PipeBehavior}()),
    ship_tiles = get(nt, :ship_tiles, Set{TileCoord}([TileCoord(0, 0)])),
    docking_status = get(nt, :docking_status, FlowMap.ConnectedDockStat())
)

"Rebuild `GameMap` from a NamedTuple."
JLD2.rconvert(::Type{FlowMap.GameMap}, nt::NamedTuple) = FlowMap.GameMap(
    ships = get(nt, :ships, Dict(:primary => FlowMap.ShipMap())),
    space_map = get(nt, :space_map, FlowMap.SpaceMapEmpty()),
    learning_system = get(nt, :learning_system, FlowMap.NoLearningSystem()),
)

#= ---------- Learning System ----------- =#

"Rebuild `LearningProgress` from a NamedTuple."
JLD2.rconvert(::Type{FlowMap.LearningProgress}, nt::NamedTuple) = FlowMap.LearningProgress(
    tutorials = get(nt, :tutorials, Dict{Symbol, FlowMap.TutorialState}()),
)

"Rebuild `SandboxLearningState` from a NamedTuple; `tutorial_state` falls back to a fresh in-progress state."
JLD2.rconvert(::Type{FlowMap.SandboxLearningState}, nt::NamedTuple) = FlowMap.SandboxLearningState(
    tutorial_id = nt.tutorial_id,
    level_index = get(nt, :level_index, 1),
    tutorial_state = get(nt, :tutorial_state, FlowMap.TutorialState(status = FlowMap.TUTORIAL_IN_PROGRESS)),
)

"Rebuild `TutorialState` from a NamedTuple; `step_blocker` is runtime-only and re-evaluated after load."
JLD2.rconvert(::Type{FlowMap.TutorialState}, nt::NamedTuple) = FlowMap.TutorialState(
    status = get(nt, :status, FlowMap.TUTORIAL_WAITING),
    unlocked_step = get(nt, :unlocked_step, 1),
    step_blocker = nothing,
)

#= ---------- SpaceMapEmpty ----------- =#

"Rebuild `SpaceMapEmpty` from a NamedTuple."
JLD2.rconvert(::Type{SpaceMapEmpty}, nt::NamedTuple) = SpaceMapEmpty(
    velocity = get(nt, :velocity, SVector{2,Float64}(0.0, 0.0)),
)

#= ---------- ManoeuvreData ----------- =#

"Normalise a loaded phase value into the current `ManoeuvrePhase` enum."
function _load_manoeuvre_phase(raw_phase)::ManoeuvrePhase
    raw_phase isa ManoeuvrePhase && return raw_phase
    return ManoeuvrePhase(raw_phase)
end

"Rebuild `ManoeuvreData` from a NamedTuple using the current field layout."
function JLD2.rconvert(::Type{ManoeuvreData}, nt::NamedTuple)
    return ManoeuvreData(
        phase              = _load_manoeuvre_phase(get(nt, :phase, PHASE_APPROACH_BURN)),
        approach_burn_dv   = get(nt, :approach_burn_dv, SVector(0.0, 0.0)),
        capture_burn_dv    = get(nt, :capture_burn_dv, SVector(0.0, 0.0)),
        burn_target_dv     = get(nt, :burn_target_dv, SVector(0.0, 0.0)),
        burn_remaining_dv  = get(nt, :burn_remaining_dv, SVector(0.0, 0.0)),
        approach_burn_time = get(nt, :approach_burn_time, 0.0),
        intercept_time     = get(nt, :intercept_time, 0.0),
        target_encounter_index = get(nt, :target_encounter_index, 0),
        capture_burn_position = get(nt, :capture_burn_position, SVector(0.0, 0.0)),
    )
end

#= ---------- SpaceMapState ----------- =#

"Rebuild `SpaceMapState` from a NamedTuple using the current encounter config defaults."
function JLD2.rconvert(::Type{SpaceMapState}, nt::NamedTuple)
    return SpaceMapState(
        seed               = get(nt, :seed, UInt32(0)),
        velocity           = get(nt, :velocity, SVector{2,Float64}(0.0, 0.0)),
        position           = get(nt, :position, SVector{2,Float64}(0.0, 0.0)),
        time_years         = get(nt, :time_years, 0.0),
        target_time_years  = get(nt, :target_time_years, 0.0),
        last_stop_time     = get(nt, :last_stop_time, 0.0),
        is_time_progressing = get(nt, :is_time_progressing, false),
        active_manoeuvre    = get(nt, :active_manoeuvre, nothing),
        encounter_points   = get(nt, :encounter_points, EncounterPoint[]),
        viewport_half_width  = get(nt, :viewport_half_width, 1000.0),
        viewport_half_height = get(nt, :viewport_half_height, 500.0),
        encounter_config   = encounter_system_config,
    )
end

"Rebuild `EncounterPoint` from a NamedTuple."
function JLD2.rconvert(::Type{EncounterPoint}, nt::NamedTuple)
    EncounterPoint(
        index = nt.index,
        iteration = get(nt, :iteration, 0),
        base_velocity = nt.base_velocity,
        position = get(nt, :position, SVector(0.0, 0.0)),
        velocity = get(nt, :velocity, SVector(0.0, 0.0)),
        spawn_time = get(nt, :spawn_time, 0.0),
        ship_type_seed = get(nt, :ship_type_seed, UInt32(0)),
        encounter_class = get(nt, :encounter_class, ENCOUNTER_SCRAP),
        fuel_tag = get(nt, :fuel_tag, nothing),
        display_name = get(nt, :display_name, ""),
        richness = get(nt, :richness, 0.0),
    )
end

#= ---------- EncounterSystemConfig ----------- =#

"Rebuild `EncounterSystemConfig` from a NamedTuple."
function JLD2.rconvert(::Type{EncounterSystemConfig}, nt::NamedTuple)
    EncounterSystemConfig(
        n_points             = get(nt, :n_points, 100),
        min_base_velocity    = get(nt, :min_base_velocity, 10.0),
        max_base_velocity    = get(nt, :max_base_velocity, 1000.0),
        velocity_variance    = get(nt, :velocity_variance, 0.1),
        max_angle_rad        = get(nt, :max_angle_rad, π / 8),
        viewport_half_width  = get(nt, :viewport_half_width, 400.0),
        viewport_half_height = get(nt, :viewport_half_height, 200.0),
        spawn_box_offset     = get(nt, :spawn_box_offset, 50.0),
        disappear_box_offset = get(nt, :disappear_box_offset, 100.0),
        encounter_class_configs = get(nt, :encounter_class_configs, Dict{EncounterClass, EncounterClassConfig}()),
    )
end

"Build the JLD2 typemap used to route current save types through reconstruction hooks."
function _build_map_typemap()::Dict{String, Any}
    return Dict(
        "HexComponentsAPI.ComponentOnTile" => JLD2.Upgrade(HexComponentsAPI.ComponentOnTile),
        "FlowMap.ShipMap" => JLD2.Upgrade(FlowMap.ShipMap),
        "FlowMap.GameMap" => JLD2.Upgrade(FlowMap.GameMap),
        "FlowMap.LearningProgress" => JLD2.Upgrade(FlowMap.LearningProgress),
        "FlowMap.SandboxLearningState" => JLD2.Upgrade(FlowMap.SandboxLearningState),
        "FlowMap.TutorialState" => JLD2.Upgrade(FlowMap.TutorialState),
        "FlowMap.SpaceMapEmpty" => JLD2.Upgrade(FlowMap.SpaceMapEmpty),
        "FlowMap.ManoeuvreData" => JLD2.Upgrade(FlowMap.ManoeuvreData),
        "FlowMap.EncounterPoint" => JLD2.Upgrade(FlowMap.EncounterPoint),
        "HexFlowProcGen.SpaceMapState" => JLD2.Upgrade(HexFlowProcGen.SpaceMapState),
        "HexFlowProcGen.EncounterSystemConfig" => JLD2.Upgrade(HexFlowProcGen.EncounterSystemConfig),
    )
end

"Load a `GameMap` from a JLD2 file at `mappath`. Returns an empty map if `mappath` is `nothing`."
function loadmap(mappath::Union{Nothing, String})::GameMap
    if isnothing(mappath)
        @info "No map loaded..."
        return GameMap()
    end

    typemap = _build_map_typemap()

    try
        stored_gamemap = JLD2.load(mappath, "stored_gamemap"; typemap=typemap)
        stored_gamemap isa GameMap && return stored_gamemap

        @warn "Loaded object was not a GameMap. Returning empty map." loaded_type = typeof(stored_gamemap)
    catch e
        @warn "Map load failed. Returning empty map." exception = (e, catch_backtrace())
    end

    return GameMap()
end

"""
Load a GameMap from various sources:
- `nothing`: Return an empty map
- `String`: Load from JLD2 file path
- `GameMap`: Return the GameMap directly (pass-through)
- `ShipMap`: Wrap as the primary ship in a new GameMap
"""
function loadmap_from_source(map_source::Union{Nothing, String, GameMap, ShipMap})::GameMap
    if map_source isa GameMap
        @info "Using pre-generated GameMap"
        return map_source
    elseif map_source isa ShipMap
        @info "Wrapping pre-generated ShipMap as primary ship"
        return GameMap(map_source)
    else
        return loadmap(map_source)
    end
end

"Save `gamemap` to the JLD2 file at `mappath`. No-op if `mappath` is `nothing`."
function savemap(gamemap::GameMap, mappath::Union{Nothing, String})
    if isnothing(mappath)
        @info "Map not saved..."
        return
    end

    try
        jldsave(mappath; stored_gamemap = gamemap)
        @info "Map saved as $mappath"
    catch e
        @error "An error occurred while saving map: $e"
    end

    return nothing
end
