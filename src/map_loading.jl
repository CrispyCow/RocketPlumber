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
# We rely on `rconvert` to upgrade old on-disk NamedTuple representations
# into the current struct types when loading saves.
# Transient fields (such as event queues inside space-map state) are not
# expected to be valid on disk and are always rebuilt when constructing
# fresh runtime state after load. The use of `get()` with defaults below
# ensures that future field additions do not break loading of older saves.
# ===============================================================

using JLD2
using StaticArrays
using LinearAlgebra
using HexFrame, FlowMap, HexFlowProcGen, HexFluids
using HexComponentsAPI, HexFlowNozzleComponents

import JLD2: rconvert

#= ---------- ShipMap (legacy FlowEngine upgrades) ----------- =#

"Conversion for old `ShipMap` saved representations"
JLD2.rconvert(::Type{FlowMap.ShipMap}, nt::NamedTuple) = FlowMap.ShipMap(
    components = get(nt, :components, Dict{TileCoord, ComponentOnTile}()),
    pipe_behaviors = get(nt, :pipe_behaviors, Dict{EdgeCoord, PipeBehavior}()),
    ship_tiles = get(nt, :ship_tiles, Set{TileCoord}([TileCoord(0, 0)])),
    docking_status = get(nt, :docking_status, FlowMap.ConnectedDockStat())
)

"Conversion for old `GameMap` saved representations that may lack `space_map` or use the legacy `learning_progress` field."
JLD2.rconvert(::Type{FlowMap.GameMap}, nt::NamedTuple) = FlowMap.GameMap(
    ships = get(nt, :ships, Dict(:primary => FlowMap.ShipMap())),
    space_map = get(nt, :space_map, FlowMap.SpaceMapEmpty()),
    learning_system = haskey(nt, :learning_system) ?
        get(nt, :learning_system, FlowMap.NoLearningSystem()) :
        get(nt, :learning_progress, FlowMap.LearningProgress()),
)

#= ---------- Learning System ----------- =#

"Rebuild `TutorialState` from a NamedTuple; `step_blocker` is runtime-only and re-evaluated after load."
JLD2.rconvert(::Type{FlowMap.TutorialState}, nt::NamedTuple) = FlowMap.TutorialState(
    status = get(nt, :status, FlowMap.TUTORIAL_WAITING),
    unlocked_step = get(nt, :unlocked_step, 1),
    step_blocker = nothing,
)

#= ---------- SpaceMapEmpty ----------- =#

"Rebuild `SpaceMapEmpty` from a NamedTuple (JLD2 Upgrade path)."
JLD2.rconvert(::Type{SpaceMapEmpty}, nt::NamedTuple) = SpaceMapEmpty(
    velocity = get(nt, :velocity, SVector{2,Float64}(0.0, 0.0)),
)

#= ---------- ManoeuvreData ----------- =#

"Normalise a loaded phase value into the current `ManoeuvrePhase` enum."
function _loaded_manoeuvre_phase(raw_phase)::ManoeuvrePhase
    raw_phase isa ManoeuvrePhase && return raw_phase
    raw_phase == 0 && return FlowMap.PHASE_WAIT_APPROACH
    raw_phase == 1 && return PHASE_APPROACH_BURN
    raw_phase == 2 && return PHASE_COAST
    raw_phase == 3 && return PHASE_CAPTURE_BURN
    raw_phase == 4 && return PHASE_ENCOUNTER_READY
    return PHASE_APPROACH_BURN
end

"Repair loaded manoeuvre burn buffers or migrate deprecated wait-phase plans."
function _migrate_loaded_active_manoeuvre!(sm::SpaceMapState)
    manoeuvre = sm.active_manoeuvre
    isnothing(manoeuvre) && return nothing

    if manoeuvre.phase == FlowMap.PHASE_WAIT_APPROACH
        target_index = manoeuvre.target_encounter_index
        if !(1 <= target_index <= length(sm.encounter_points))
            sm.active_manoeuvre = nothing
            return nothing
        end

        total_dv_budget = norm(manoeuvre.approach_burn_dv) + norm(manoeuvre.capture_burn_dv)
        replanned_manoeuvre = plan_intercept_manoeuvre(
            sm.position,
            sm.velocity,
            sm.encounter_points[target_index],
            sm.time_years,
            total_dv_budget,
        )
        sm.active_manoeuvre = replanned_manoeuvre

        if !isnothing(replanned_manoeuvre)
            set_target_time!(sm, sm.time_years)
            sm.is_time_progressing = false
        end
        return nothing
    end

    if manoeuvre.phase == PHASE_APPROACH_BURN &&
        norm(manoeuvre.burn_target_dv) < 1.0e-9 &&
        norm(manoeuvre.burn_remaining_dv) < 1.0e-9
        ship_space_approach_dv = SVector(norm(manoeuvre.approach_burn_dv), 0.0)
        manoeuvre.burn_target_dv = ship_space_approach_dv
        manoeuvre.burn_remaining_dv = ship_space_approach_dv
    end

    return nothing
end

"""Rebuild `ManoeuvreData` from a NamedTuple (JLD2 Upgrade path).

Handles three legacy formats:
1. **Very old**: has `target_delta_v`/`intercept_delta_v` (no `main_burn_dv`). Uses vectors as-is.
2. **Legacy**: has `main_burn_dv` (ship-local) + `main_burn_direction` unit vector. Reconstructs
   space-map ΔV via `direction × magnitude`.
3. **Current**: has `main_burn_dv`/`decel_burn_dv` as full space-map vectors (no `main_burn_direction`).
4. **Renamed**: has `approach_burn_dv`/`capture_burn_dv` with the same semantics as current.
"""
function JLD2.rconvert(::Type{ManoeuvreData}, nt::NamedTuple)
    if haskey(nt, :target_delta_v) && !haskey(nt, :main_burn_dv) && !haskey(nt, :approach_burn_dv)
        # Very old format: target_delta_v → main_burn_dv, intercept_delta_v → decel_burn_dv
        main_dv  = get(nt, :target_delta_v,    SVector(0.0, 0.0))
        decel_dv = get(nt, :intercept_delta_v, SVector(0.0, 0.0))
    elseif haskey(nt, :main_burn_direction)
        # Legacy: reconstruct space-map ΔV from direction × magnitude
        dir_main  = get(nt, :main_burn_direction,  SVector(1.0, 0.0))
        dir_decel = get(nt, :decel_burn_direction, SVector(1.0, 0.0))
        main_dv   = dir_main  * norm(nt.main_burn_dv)
        decel_dv  = dir_decel * norm(nt.decel_burn_dv)
    else
        # Current or renamed format: prefer new names, fall back to old ones.
        main_dv  = get(nt, :approach_burn_dv, get(nt, :main_burn_dv, SVector(0.0, 0.0)))
        decel_dv = get(nt, :capture_burn_dv, get(nt, :decel_burn_dv, SVector(0.0, 0.0)))
    end

    ManoeuvreData(
        phase              = _loaded_manoeuvre_phase(get(nt, :phase, PHASE_APPROACH_BURN)),
        approach_burn_dv   = main_dv,
        capture_burn_dv    = decel_dv,
        burn_target_dv     = get(nt, :burn_target_dv, SVector(0.0, 0.0)),
        burn_remaining_dv  = get(nt, :burn_remaining_dv, SVector(0.0, 0.0)),
        approach_burn_time = get(nt, :approach_burn_time, get(nt, :closest_approach_time, 0.0)),
        intercept_time     = get(nt, :intercept_time, 0.0),
        target_encounter_index = get(nt, :target_encounter_index, 0),
        capture_burn_position = get(nt, :capture_burn_position, get(nt, :decel_burn_position, SVector(0.0, 0.0))),
    )
end

#= ---------- SpaceMapState ----------- =#

"Rebuild `SpaceMapState` from a NamedTuple using the current encounter config defaults."
function JLD2.rconvert(::Type{SpaceMapState}, nt::NamedTuple)
    sm = SpaceMapState(
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
        encounter_config   = encounter_system_config,  # Old saves get current encounter rules
    )
    _migrate_loaded_active_manoeuvre!(sm)
    return sm
end

"Rebuild `EncounterPoint` from a NamedTuple (JLD2 Upgrade path)."
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
        fuel_tag = get(nt, :fuel_tag, HexFluids.NONE),
        display_name = get(nt, :display_name, ""),
        richness = get(nt, :richness, 0.0),
    )
end

#= ---------- DecompChamberCompBehav ----------- =#

"Legacy DecompChamberCompBehav had an expansion_factor field; new version derives it from fluid densities."
JLD2.rconvert(::Type{DecompChamberCompBehav}, nt::NamedTuple) = DecompChamberCompBehav()

#= ---------- EncounterSystemConfig ----------- =#

"Rebuild EncounterSystemConfig from old saves that may lack newer box-offset fields."
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

"Build the JLD2 typemap used to upgrade legacy save data into current runtime types."
function _build_map_typemap()::Dict{String, Any}
    return Dict(
        "FlowEngine.ShipMap" => JLD2.Upgrade(FlowMap.ShipMap),
        "FlowEngine.GameMap" => JLD2.Upgrade(FlowMap.GameMap),
        "FlowMap.ShipMap" => JLD2.Upgrade(FlowMap.ShipMap),
        "FlowMap.GameMap" => JLD2.Upgrade(FlowMap.GameMap),
        "Main.ShipMap" => JLD2.Upgrade(FlowMap.ShipMap),
        "Main.GameMap" => JLD2.Upgrade(FlowMap.GameMap),
        "Main.FlowMap.ShipMap" => JLD2.Upgrade(FlowMap.ShipMap),
        "Main.FlowMap.GameMap" => JLD2.Upgrade(FlowMap.GameMap),
        "FlowEngine.DockingStatus" => JLD2.Upgrade(FlowMap.DockingStatus),
        "FlowEngine.ConnectedDockStat" => JLD2.Upgrade(FlowMap.ConnectedDockStat),
        "FlowEngine.ApproachingDockStat" => JLD2.Upgrade(FlowMap.ApproachingDockStat),
        "FlowEngine.DepartingDockStat" => JLD2.Upgrade(FlowMap.DepartingDockStat),
        "FlowEngine.RenderPosOffsetState" => JLD2.Upgrade(FlowMap.RenderPosOffsetState),
        "FlowMap.SpaceMapEmpty" => JLD2.Upgrade(FlowMap.SpaceMapEmpty),
        "FlowMap.SpaceMapState" => JLD2.Upgrade(HexFlowProcGen.SpaceMapState),
        "FlowMap.ManoeuvreData" => JLD2.Upgrade(FlowMap.ManoeuvreData),
        "FlowMap.EncounterPoint" => JLD2.Upgrade(FlowMap.EncounterPoint),
        "HexFlowProcGen.SpaceMapState" => JLD2.Upgrade(HexFlowProcGen.SpaceMapState),
        "HexFlowProcGen.EncounterSystemConfig" => JLD2.Upgrade(HexFlowProcGen.EncounterSystemConfig),
        "HexFlowNozzleComponents.DecompChamberCompBehav" => JLD2.Upgrade(HexFlowNozzleComponents.DecompChamberCompBehav),
        "Main.DecompChamberCompBehav" => JLD2.Upgrade(HexFlowNozzleComponents.DecompChamberCompBehav),
        "Main.HexFlowNozzleComponents.DecompChamberCompBehav" => JLD2.Upgrade(HexFlowNozzleComponents.DecompChamberCompBehav),
    )
end

"Load a `GameMap` from a JLD2 file at `mappath`. Returns an empty map if `mappath` is `nothing`."
function loadmap(mappath::Union{Nothing, String})::GameMap
    # Guard clause for empty path
    if isnothing(mappath)
        @info "No map loaded..."
        return GameMap()
    end

    stored_gamemap::Union{GameMap, ShipMap, Nothing} = nothing
    typemap = _build_map_typemap()

    if isnothing(stored_gamemap)
        try
            stored_gamemap = JLD2.load(mappath, "stored_gamemap"; typemap=typemap)
        catch e
            @info "Standard map load failed:\n$e"
        end
    end

    # If a ShipMap was saved directly (legacy single-ship save), wrap it
    if stored_gamemap isa ShipMap
        @info "Loaded ShipMap directly from file; wrapping as GameMap"
        stored_gamemap = GameMap(stored_gamemap)
    end

    if isnothing(stored_gamemap)
        @info "Attempting legacy map load 1..."
        try
            loaded = JLD2.load(mappath; typemap=typemap)
            tile_dict = loaded["TileDict"]
            pipe_behavior_dict = loaded["PipeBehaviorDict"]
            ship_surface = loaded["ShipSurface"]

            ship = ShipMap(components = tile_dict, pipe_behaviors = pipe_behavior_dict, ship_tiles = ship_surface)
            stored_gamemap = GameMap(ship)
        catch e
            @info "Legacy map load 1 failed:\n$e"
        end
    end

    if isnothing(stored_gamemap)
        @info "Attempting legacy map load 2..."
        try
            loaded = JLD2.load(mappath; typemap=typemap)
            tile_dict = loaded["TileDict"]
            pipe_behavior_dict = loaded["PipeBehaviorDict"]

            ship = ShipMap(components = tile_dict, pipe_behaviors = pipe_behavior_dict)
            stored_gamemap = GameMap(ship)
        catch e
            @info "Legacy map load 2 failed:\n$e"
        end
    end

    if isnothing(stored_gamemap)
        @warn "All map loading attempts failed. Returning empty map."
        stored_gamemap = GameMap()
    end

    return stored_gamemap
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
        @info "Map saved as  $mappath"
    catch e
        @error "An error occurred while saving map: $e"
    end

    return nothing
end
