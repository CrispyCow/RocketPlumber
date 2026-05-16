# ===============================================================
# Map Loading and Saving
# ===============================================================
#
# JLD2 serialisation for GameMap persistence.
#
# This file is intentionally lean — it only imports what is needed
# for loading and saving, with no rendering or UI dependencies.
# That allows it to be included in both the full game and in
# headless diagnostic / tooling scripts.
# ===============================================================

using JLD2
using FlowMap
using HexComponentsAPI
using HexFlowProcGen
using HexFrame
import JLD2: rconvert

#= ---------- JLD2 Upgrade Helpers ----------- =#

"Normalise stored manoeuvre phase values to the current enum."
function _load_manoeuvre_phase(value)::FlowMap.ManoeuvrePhase
    value isa FlowMap.ManoeuvrePhase && return value
    value isa Integer && return FlowMap.ManoeuvrePhase(value)
    return FlowMap.PHASE_APPROACH_BURN
end

#= ---------- JLD2 Upgrade Converters ----------- =#

function rconvert(::Type{HexComponentsAPI.ComponentOnTile}, nt::NamedTuple)
    component = get(nt, :component, nothing)
    isnothing(component) && error("Stored ComponentOnTile is missing :component")
    rotation = get(nt, :rotation, HexFrame.Q_POS)
    mirrored = get(nt, :mirrored, false)
    ship = get(nt, :ship, :primary)
    return HexComponentsAPI.ComponentOnTile(component, rotation, mirrored, ship)
end

function rconvert(::Type{HexComponentsAPI.PipeOnEdge}, nt::NamedTuple)
    pipe = get(nt, :pipe, nothing)
    isnothing(pipe) && error("Stored PipeOnEdge is missing :pipe")
    ship = get(nt, :ship, :primary)
    return HexComponentsAPI.PipeOnEdge(pipe, ship)
end

function rconvert(::Type{FlowMap.ShipState}, nt::NamedTuple)
    docking_status = get(nt, :docking_status, FlowMap.ConnectedDockStat())
    return FlowMap.ShipState(docking_status = docking_status)
end

function rconvert(::Type{FlowMap.GameMap}, nt::NamedTuple)
    default_map = FlowMap.GameMap()
    components = get(nt, :components, default_map.components)
    pipe_behaviors = get(nt, :pipe_behaviors, default_map.pipe_behaviors)
    surface_shiptags = get(nt, :surface_shiptags, default_map.surface_shiptags)
    ships = get(nt, :ships, default_map.ships)
    space_map = get(nt, :space_map, default_map.space_map)
    learning_system = get(nt, :learning_system, default_map.learning_system)
    return FlowMap.GameMap(; components, pipe_behaviors, surface_shiptags, ships, space_map, learning_system)
end

function rconvert(::Type{FlowMap.LearningProgress}, nt::NamedTuple)
    default_progress = FlowMap.LearningProgress()
    tutorials = get(nt, :tutorials, default_progress.tutorials)
    return FlowMap.LearningProgress(tutorials = tutorials)
end

function rconvert(::Type{FlowMap.SandboxLearningState}, nt::NamedTuple)
    default_state = FlowMap.SandboxLearningState(tutorial_id = Symbol())
    tutorial_id = get(nt, :tutorial_id, default_state.tutorial_id)
    level_index = get(nt, :level_index, default_state.level_index)
    tutorial_state = get(nt, :tutorial_state, default_state.tutorial_state)
    return FlowMap.SandboxLearningState(; tutorial_id, level_index, tutorial_state)
end

function rconvert(::Type{FlowMap.TutorialState}, nt::NamedTuple)
    default_state = FlowMap.TutorialState()
    status = get(nt, :status, default_state.status)
    unlocked_step = get(nt, :unlocked_step, default_state.unlocked_step)
    step_blocker = get(nt, :step_blocker, default_state.step_blocker)
    return FlowMap.TutorialState(; status, unlocked_step, step_blocker)
end

function rconvert(::Type{FlowMap.SpaceMapEmpty}, nt::NamedTuple)
    default_space_map = FlowMap.SpaceMapEmpty()
    velocity = get(nt, :velocity, default_space_map.velocity)
    return FlowMap.SpaceMapEmpty(velocity = velocity)
end

function rconvert(::Type{FlowMap.ManoeuvreData}, nt::NamedTuple)
    default_manoeuvre = FlowMap.ManoeuvreData(
        approach_burn_dv = FlowMap.SpaceMapEmpty().velocity,
        capture_burn_dv = FlowMap.SpaceMapEmpty().velocity,
    )
    phase = _load_manoeuvre_phase(get(nt, :phase, default_manoeuvre.phase))
    burn_target_dv = get(nt, :burn_target_dv, default_manoeuvre.burn_target_dv)
    burn_remaining_dv = get(nt, :burn_remaining_dv, default_manoeuvre.burn_remaining_dv)
    approach_burn_dv = get(nt, :approach_burn_dv, default_manoeuvre.approach_burn_dv)
    capture_burn_dv = get(nt, :capture_burn_dv, default_manoeuvre.capture_burn_dv)
    approach_burn_time = get(nt, :approach_burn_time, default_manoeuvre.approach_burn_time)
    intercept_time = get(nt, :intercept_time, default_manoeuvre.intercept_time)
    target_encounter_index = get(nt, :target_encounter_index, default_manoeuvre.target_encounter_index)
    capture_burn_position = get(nt, :capture_burn_position, default_manoeuvre.capture_burn_position)
    return FlowMap.ManoeuvreData(
        ;
        phase,
        burn_target_dv,
        burn_remaining_dv,
        approach_burn_dv,
        capture_burn_dv,
        approach_burn_time,
        intercept_time,
        target_encounter_index,
        capture_burn_position,
    )
end

function rconvert(::Type{FlowMap.EncounterPoint}, nt::NamedTuple)
    default_point = FlowMap.EncounterPoint(index = 0, base_velocity = 0.0)
    index = get(nt, :index, default_point.index)
    iteration = get(nt, :iteration, default_point.iteration)
    base_velocity = get(nt, :base_velocity, default_point.base_velocity)
    position = get(nt, :position, default_point.position)
    velocity = get(nt, :velocity, default_point.velocity)
    spawn_time = get(nt, :spawn_time, default_point.spawn_time)
    ship_type_seed = get(nt, :ship_type_seed, default_point.ship_type_seed)
    encounter_class = get(nt, :encounter_class, default_point.encounter_class)
    fuel_tag = get(nt, :fuel_tag, default_point.fuel_tag)
    display_name = get(nt, :display_name, default_point.display_name)
    richness = get(nt, :richness, default_point.richness)
    return FlowMap.EncounterPoint(
        ;
        index,
        iteration,
        base_velocity,
        position,
        velocity,
        spawn_time,
        ship_type_seed,
        encounter_class,
        fuel_tag,
        display_name,
        richness,
    )
end

function rconvert(::Type{HexFlowProcGen.SpaceMapState}, nt::NamedTuple)
    default_space_map = HexFlowProcGen.SpaceMapState(encounter_config = HexFlowProcGen.EncounterSystemConfig())
    seed = get(nt, :seed, default_space_map.seed)
    velocity = get(nt, :velocity, default_space_map.velocity)
    position = get(nt, :position, default_space_map.position)
    time_years = get(nt, :time_years, default_space_map.time_years)
    target_time_years = get(nt, :target_time_years, default_space_map.target_time_years)
    last_stop_time = get(nt, :last_stop_time, default_space_map.last_stop_time)
    is_time_progressing = get(nt, :is_time_progressing, default_space_map.is_time_progressing)
    active_manoeuvre = get(nt, :active_manoeuvre, default_space_map.active_manoeuvre)
    encounter_points = get(nt, :encounter_points, default_space_map.encounter_points)
    viewport_half_width = get(nt, :viewport_half_width, default_space_map.viewport_half_width)
    viewport_half_height = get(nt, :viewport_half_height, default_space_map.viewport_half_height)
    encounter_config = get(nt, :encounter_config, default_space_map.encounter_config)
    return HexFlowProcGen.SpaceMapState(
        ;
        seed,
        velocity,
        position,
        time_years,
        target_time_years,
        last_stop_time,
        is_time_progressing,
        active_manoeuvre,
        encounter_points,
        viewport_half_width,
        viewport_half_height,
        encounter_config,
    )
end

function rconvert(::Type{HexFlowProcGen.EncounterSystemConfig}, nt::NamedTuple)
    default_config = HexFlowProcGen.EncounterSystemConfig()
    n_points = get(nt, :n_points, default_config.n_points)
    min_base_velocity = get(nt, :min_base_velocity, default_config.min_base_velocity)
    max_base_velocity = get(nt, :max_base_velocity, default_config.max_base_velocity)
    velocity_variance = get(nt, :velocity_variance, default_config.velocity_variance)
    max_angle_rad = get(nt, :max_angle_rad, default_config.max_angle_rad)
    viewport_half_width = get(nt, :viewport_half_width, default_config.viewport_half_width)
    viewport_half_height = get(nt, :viewport_half_height, default_config.viewport_half_height)
    spawn_box_offset = get(nt, :spawn_box_offset, default_config.spawn_box_offset)
    disappear_box_offset = get(nt, :disappear_box_offset, default_config.disappear_box_offset)
    encounter_class_configs = get(nt, :encounter_class_configs, default_config.encounter_class_configs)
    return HexFlowProcGen.EncounterSystemConfig(
        ;
        n_points,
        min_base_velocity,
        max_base_velocity,
        velocity_variance,
        max_angle_rad,
        viewport_half_width,
        viewport_half_height,
        spawn_box_offset,
        disappear_box_offset,
        encounter_class_configs,
    )
end

"Build the JLD2 typemap used for save migrations when persisted types change shape."
function _build_map_typemap()::Dict{String, Any}
    typemap = Dict{String, Any}()

    # Add `JLD2.Upgrade(...)` entries here when a persisted type changes package path or layout.
    # typemap["HexComponentsAPI.ComponentOnTile"] = JLD2.Upgrade(HexComponentsAPI.ComponentOnTile)
    # typemap["HexComponentsAPI.PipeOnEdge"] = JLD2.Upgrade(HexComponentsAPI.PipeOnEdge)
    # typemap["FlowMap.ShipState"] = JLD2.Upgrade(FlowMap.ShipState)
    # typemap["FlowMap.GameMap"] = JLD2.Upgrade(FlowMap.GameMap)
    # typemap["FlowMap.LearningProgress"] = JLD2.Upgrade(FlowMap.LearningProgress)
    # typemap["FlowMap.SandboxLearningState"] = JLD2.Upgrade(FlowMap.SandboxLearningState)
    # typemap["FlowMap.TutorialState"] = JLD2.Upgrade(FlowMap.TutorialState)
    # typemap["FlowMap.SpaceMapEmpty"] = JLD2.Upgrade(FlowMap.SpaceMapEmpty)
    # typemap["FlowMap.ManoeuvreData"] = JLD2.Upgrade(FlowMap.ManoeuvreData)
    # typemap["FlowMap.EncounterPoint"] = JLD2.Upgrade(FlowMap.EncounterPoint)
    # typemap["HexFlowProcGen.SpaceMapState"] = JLD2.Upgrade(HexFlowProcGen.SpaceMapState)
    # typemap["HexFlowProcGen.EncounterSystemConfig"] = JLD2.Upgrade(HexFlowProcGen.EncounterSystemConfig)

    return typemap
end

"""
Load a `GameMap` from the given path, or return an empty map on failure.
"""
function loadmap(mappath::Union{Nothing, String})::GameMap
    isnothing(mappath) && (@info "No map path provided; starting empty."; return GameMap())
    try
        typemap = _build_map_typemap()
        result = JLD2.load(mappath, "stored_gamemap"; typemap = typemap)
        result isa GameMap && return result
        @warn "Loaded object was not a GameMap; returning empty." loaded_type = typeof(result)
    catch e
        @warn "Map load failed; returning empty." exception = (e, catch_backtrace())
    end
    return GameMap()
end

"""
Dispatch map loading from multiple source types.
"""
function loadmap_from_source(map_source::Union{Nothing, String, GameMap, ShipState})::GameMap
    map_source isa GameMap && (@info "Using pre-generated GameMap"; return map_source)
    map_source isa ShipState && (@info "Wrapping ShipState as primary ship"; return GameMap(map_source))
    return loadmap(map_source)
end

"""
Save a `GameMap` to disk via JLD2.
"""
function savemap(gamemap::GameMap, mappath::String)
    try
        JLD2.jldsave(mappath; stored_gamemap = gamemap)
    catch e
        @warn "Map save failed." path = mappath exception = (e, catch_backtrace())
    end
    return nothing
end
