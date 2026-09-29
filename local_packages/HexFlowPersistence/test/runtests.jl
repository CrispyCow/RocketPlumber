#=
Scope: Save-file round trips and historical JLD2 migration tests
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using HexFlowPersistence
using FlowMap
using HexFrame
using HexComponentsAPI
using HexFlowBasicComponents: BasicCompBehav, BasicElemBehavFrag, PlainSpriteBehavFrag
using HexFlowBasicPipes: ScrapPipeBehav
using HexFlowProcGen
using StaticArrays
using JLD2
import JLD2: rconvert

struct PersistenceTestComponent <: ComponentBehavior end

"Build a galaxy map with position and velocity for persistence tests."
function make_galaxy_escape_ready_map(; velocity::SVector{2, Float64} = SVector(10.0, 0.0), time_years::Float64 = 0.0)::GameMap
    gamemap = GameMap()
    set_surface_tile!(gamemap, TileCoord(0, 0); ship_name = :primary)
    initialise_spacemap!(gamemap, UInt32(0x1234), EncounterSystemConfig(), velocity)
    set_time_years!(gamemap, time_years)
    return gamemap
end

@testset "historical structure upgrades" begin
    component = PersistenceTestComponent()
    placed_component = rconvert(PlacedComponent, (component = component,))
    @test placed_component.component === component
    @test placed_component.rotation == HexFrame.Q_POS
    @test placed_component.ship == :primary
    @test_throws ErrorException rconvert(PlacedComponent, NamedTuple())

    pipe = ScrapPipeBehav()
    placed_pipe = rconvert(PlacedPipe, (pipe = pipe,))
    @test placed_pipe.pipe === pipe
    @test placed_pipe.ship == :primary
    @test_throws ErrorException rconvert(PlacedPipe, NamedTuple())

    @test rconvert(ShipState, NamedTuple()) isa ShipState
    @test rconvert(SpaceMapEmpty, NamedTuple()) isa SpaceMapEmpty
    @test rconvert(LearningProgress, NamedTuple()) isa LearningProgress
    @test rconvert(SandboxLearningState, NamedTuple()) isa SandboxLearningState
    @test rconvert(TutorialState, NamedTuple()) isa TutorialState
    @test rconvert(ManoeuvreData, NamedTuple()) isa ManoeuvreData
    @test rconvert(EncounterPoint, (index = 1, base_velocity = 2.0)) isa EncounterPoint
    @test rconvert(SpaceMapState, NamedTuple()) isa SpaceMapState
    @test rconvert(EncounterSystemConfig, NamedTuple()) isa EncounterSystemConfig
end

@testset "built-in pipe reconstruction" begin
    gamemap = GameMap()
    pipe_coord = first(get_side_pipes(TileCoord(0, 0)))
    gamemap.pipe_behaviors[pipe_coord] = PlacedPipe(ScrapPipeBehav(), :primary)

    mktempdir() do directory
        path = joinpath(directory, "built_in_pipe.jld2")
        savemap(gamemap, path)
        loaded_map = loadmap_strict(path)
        @test loaded_map.pipe_behaviors[pipe_coord].pipe isa ScrapPipeBehav
    end
end

@testset "built-in behaviours load in a fresh process" begin
    gamemap = GameMap()
    component_coord = TileCoord(2, -1)
    pipe_coord = first(get_side_pipes(component_coord))
    set_surface_tile!(gamemap, component_coord; ship_name = :primary)
    component = BasicCompBehav(
        elems = BasicElemBehavFrag(),
        sprite = PlainSpriteBehavFrag(:test_persistence),
    )
    gamemap.components[component_coord] = PlacedComponent(component, HexFrame.R_NEG, true, :primary)
    gamemap.pipe_behaviors[pipe_coord] = PlacedPipe(ScrapPipeBehav(7.5), :primary)
    increment_simulated_ticks!(gamemap)

    mktempdir() do directory
        path = joinpath(directory, "built_in_behaviours.jld2")
        savemap(gamemap, path)
        @test isfile(path)

        child_script = joinpath(@__DIR__, "fresh_process_load.jl")
        package_dir = dirname(@__DIR__)
        command = `$(Base.julia_cmd()) --startup-file=no --history-file=no --project=$(package_dir) $(child_script) $(path)`
        @test success(command)
    end
end

@testset "PlaythroughStatistics persistence" begin
    old_layout = (
        components = Dict{TileCoord, PlacedComponent}(),
        pipe_behaviors = Dict{PipeCoord, PlacedPipe}(),
        surface_shiptags = Dict{TileCoord, Symbol}(),
        ships = Dict{Symbol, ShipState}(),
        space_map = SpaceMapEmpty(),
        learning_system = NoLearningSystem(),
    )
    old_map = rconvert(FlowMap.GameMap, old_layout)
    @test get_recorded_play_time_seconds(old_map) == 0.0
    @test get_simulated_ticks(old_map) == 0
    @test get_total_delta_v(old_map) == 0.0
    @test get_peak_thrust(old_map) == 0.0
    @test get_peak_estimated_delta_v(old_map) == 0.0
    @test isempty(get_playthrough_statistics(old_map).completed_encounters)

    partial_statistics = rconvert(FlowMap.PlaythroughStatistics, (total_delta_v = 2.5, peak_estimated_delta_v = 1700.0))
    @test get_recorded_play_time_seconds(partial_statistics) == 0.0
    @test get_total_delta_v(partial_statistics) == 2.5
    @test get_peak_estimated_delta_v(partial_statistics) == 1700.0
    @test get_simulated_ticks(partial_statistics) == 0
    @test typeof(partial_statistics.completed_encounters) == Dict{EncounterClass, Int64}
    for invalid_peak in (-1.0, Inf, NaN)
        @test_throws ArgumentError rconvert(
            FlowMap.PlaythroughStatistics,
            (peak_estimated_delta_v = invalid_peak,),
        )
    end

    typemap = HexFlowPersistence._build_map_typemap()
    @test haskey(typemap, "FlowMap.PlaythroughStatistics")
    @test haskey(typemap, "FlowMap.GalaxyEscapeSpaceMap")

    gamemap = GameMap()
    set_recorded_play_time_seconds!(gamemap, 12.0)
    for _ in 1:4
        increment_simulated_ticks!(gamemap)
    end
    record_delta_v!(gamemap, 3.5)
    record_peak_thrust!(gamemap, 8.0)
    record_peak_estimated_delta_v!(gamemap, 1900.0)
    record_completed_encounter!(gamemap, ENCOUNTER_SHIP)
    record_completed_encounter!(gamemap, ENCOUNTER_FUEL_CACHE)

    mktempdir() do directory
        path = joinpath(directory, "statistics.jld2")
        savemap(gamemap, path)
        loaded_map = loadmap(path)

        @test get_recorded_play_time_seconds(loaded_map) == 12.0
        @test get_simulated_ticks(loaded_map) == 4
        @test get_total_delta_v(loaded_map) == 3.5
        @test get_peak_thrust(loaded_map) == 8.0
        @test get_peak_estimated_delta_v(loaded_map) == 1900.0
        @test get_encounter_count(loaded_map, ENCOUNTER_SHIP) == 1
        @test get_encounter_count(loaded_map, ENCOUNTER_FUEL_CACHE) == 1
        @test get_total_encounter_count(loaded_map) == 2
        @test typeof(loaded_map.statistics.completed_encounters) == Dict{EncounterClass, Int64}
    end
end


@testset "GalaxyEscapeSpaceMap persistence" begin
    pre_escape_map = make_galaxy_escape_ready_map(velocity = SVector(100.0, -8.0), time_years = 42.0)
    escape_map = GalaxyEscapeSpaceMap(
        velocity = SVector(175.0, -8.0),
        starting_velocity_x = 100.0,
        departure_time_years = 42.0,
        pre_escape_map = pre_escape_map,
    )
    gamemap = GameMap(space_map = escape_map)
    record_peak_estimated_delta_v!(gamemap, 2100.0)

    reconstructed = rconvert(
        FlowMap.GalaxyEscapeSpaceMap, (
            velocity = SVector(130.0, 2.0),
            starting_velocity_x = 100.0,
            departure_time_years = 7.0,
        )
    )
    @test reconstructed == GalaxyEscapeSpaceMap(
        velocity = SVector(130.0, 2.0), starting_velocity_x = 100.0, departure_time_years = 7.0,
        pre_escape_map = GameMap(),
    )
    @test !can_abort_galaxy_escape(reconstructed)
    @test_throws ErrorException rconvert(
        FlowMap.GalaxyEscapeSpaceMap, (
            starting_velocity_x = 100.0, departure_time_years = 7.0,
        )
    )
    @test_throws ArgumentError rconvert(
        FlowMap.GalaxyEscapeSpaceMap, (
            velocity = SVector(Inf, 0.0), starting_velocity_x = 100.0, departure_time_years = 7.0,
        )
    )
    @test_throws ArgumentError rconvert(
        FlowMap.GalaxyEscapeSpaceMap, (
            velocity = SVector(130.0, 0.0), starting_velocity_x = 100.0, departure_time_years = -1.0,
        )
    )

    mktempdir() do directory
        path = joinpath(directory, "galaxy_escape.jld2")
        savemap(gamemap, path)
        loaded_map = loadmap(path)

        @test loaded_map.space_map isa GalaxyEscapeSpaceMap
        loaded_escape = loaded_map.space_map::GalaxyEscapeSpaceMap
        @test loaded_escape.velocity == escape_map.velocity
        @test loaded_escape.starting_velocity_x == escape_map.starting_velocity_x
        @test loaded_escape.departure_time_years == escape_map.departure_time_years
        @test loaded_escape.pre_escape_map !== pre_escape_map
        loaded_pre_escape_space_map = loaded_escape.pre_escape_map.space_map::SpaceMapState
        original_pre_escape_space_map = pre_escape_map.space_map::SpaceMapState
        @test loaded_pre_escape_space_map.seed == original_pre_escape_space_map.seed
        @test loaded_pre_escape_space_map.velocity == original_pre_escape_space_map.velocity
        @test loaded_pre_escape_space_map.time_years == original_pre_escape_space_map.time_years
        @test loaded_escape.pre_escape_map.statistics == pre_escape_map.statistics
        @test can_abort_galaxy_escape(loaded_map)
        @test galaxy_escape_progress(loaded_escape) == 75.0
        @test get_peak_estimated_delta_v(loaded_map) == 2100.0
        @test isempty(get_encounter_points(loaded_escape))
        @test !has_active_manoeuvre(loaded_escape)
    end
end

@testset "render-thread time-lapse persistence" begin
    gamemap = GameMap()
    first_frame = GameMap()
    second_frame = GameMap()
    increment_simulated_ticks!(first_frame)
    for _ in 1:2
        increment_simulated_ticks!(second_frame)
    end
    history = TimelapseHistory(frames = [first_frame, second_frame])

    mktempdir() do directory
        map_only_path = joinpath(directory, "map_only.jld2")
        savemap(gamemap, map_only_path)
        map_only = loadmap_bundle(map_only_path)
        @test map_only.gamemap isa GameMap
        @test isnothing(map_only.timelapse)
        @test !JLD2.jldopen(map_only_path, "r") do file
            haskey(file, "stored_timelapse")
        end
        @test loadmap(map_only_path) isa GameMap

        bundled_path = joinpath(directory, "bundled.jld2")
        savemap(GameMapBundle(gamemap, history), bundled_path)
        bundled = loadmap_bundle(bundled_path)
        @test bundled.gamemap isa GameMap
        @test bundled.timelapse isa TimelapseHistory
        loaded_history = bundled.timelapse::TimelapseHistory
        @test loaded_history.format_version == TIMELAPSE_FORMAT_VERSION
        @test length(loaded_history.frames) == 2
        @test get_simulated_ticks(loaded_history.frames[1]) == 1
        @test get_simulated_ticks(loaded_history.frames[2]) == 2

        empty_path = joinpath(directory, "empty_history.jld2")
        savemap(GameMapBundle(gamemap, TimelapseHistory()), empty_path)
        empty_bundle = loadmap_bundle(empty_path)
        @test empty_bundle.timelapse isa TimelapseHistory
        @test isempty(empty_bundle.timelapse.frames)

        malformed_path = joinpath(directory, "malformed_history.jld2")
        JLD2.jldsave(malformed_path; stored_gamemap = gamemap, stored_timelapse = "invalid")
        malformed_bundle = @test_logs (:warn, r"invalid type") loadmap_bundle(malformed_path)
        @test malformed_bundle.gamemap isa GameMap
        @test isnothing(malformed_bundle.timelapse)

        unsupported_path = joinpath(directory, "unsupported_history.jld2")
        unsupported = TimelapseHistory(format_version = UInt16(1))
        JLD2.jldsave(unsupported_path; stored_gamemap = gamemap, stored_timelapse = unsupported)
        unsupported_bundle = @test_logs (:warn, r"unsupported.*format version") loadmap_bundle(unsupported_path)
        @test unsupported_bundle.gamemap isa GameMap
        @test isnothing(unsupported_bundle.timelapse)

        @test_throws ArgumentError savemap(GameMapBundle(gamemap, unsupported), joinpath(directory, "unsupported_save.jld2"))
    end
end

@testset "historical Main time-lapse migration" begin
    # This fixture records Main.TimelapseHistory and must not be regenerated with current types.
    legacy_path = joinpath(@__DIR__, "fixtures", "pre_migration_bundle.jld2")
    legacy_bundle = loadmap_bundle_strict(legacy_path)

    @test legacy_bundle.gamemap isa GameMap
    @test legacy_bundle.timelapse isa TimelapseHistory
    @test length(legacy_bundle.timelapse.frames) == 1
    @test only(legacy_bundle.timelapse.frames) isa GameMap

    typemap = HexFlowPersistence._build_map_typemap()
    @test haskey(typemap, "Main.TimelapseHistory")
    @test !haskey(typemap, "RocketPlumber.TimelapseHistory")
end

@testset "strict and forgiving loading" begin
    mktempdir() do directory
        missing_path = joinpath(directory, "missing.jld2")
        @test_throws Exception loadmap_strict(missing_path)
        @test_throws Exception loadmap_bundle_strict(missing_path)
        @test get_simulated_ticks(loadmap(missing_path)) == 0
        @test get_simulated_ticks(loadmap_bundle(missing_path).gamemap) == 0

        absent_map_path = joinpath(directory, "absent_map.jld2")
        JLD2.jldsave(absent_map_path; other_key = 1)
        @test_throws Exception loadmap_strict(absent_map_path)
        @test_throws Exception loadmap_bundle_strict(absent_map_path)

        invalid_map_path = joinpath(directory, "invalid_map.jld2")
        JLD2.jldsave(invalid_map_path; stored_gamemap = "invalid")
        @test_throws Exception loadmap_strict(invalid_map_path)
        @test_throws Exception loadmap_bundle_strict(invalid_map_path)
        @test get_simulated_ticks(loadmap(invalid_map_path)) == 0
        @test get_simulated_ticks(loadmap_bundle(invalid_map_path).gamemap) == 0

        gamemap = GameMap()
        increment_simulated_ticks!(gamemap)
        map_only_path = joinpath(directory, "map_only.jld2")
        savemap(gamemap, map_only_path)
        @test loadmap_strict(map_only_path) isa GameMap
        @test isnothing(loadmap_bundle_strict(map_only_path).timelapse)
        JLD2.jldopen(map_only_path, "r") do file
            @test haskey(file, "stored_gamemap")
            @test !haskey(file, "stored_timelapse")
        end

        history = TimelapseHistory(frames = [gamemap])
        bundle_path = joinpath(directory, "bundle.jld2")
        savemap(GameMapBundle(gamemap, history), bundle_path)
        @test loadmap_bundle_strict(bundle_path).timelapse isa TimelapseHistory
        JLD2.jldopen(bundle_path, "r") do file
            @test haskey(file, "stored_gamemap")
            @test haskey(file, "stored_timelapse")
        end

        malformed_path = joinpath(directory, "malformed_history.jld2")
        JLD2.jldsave(malformed_path; stored_gamemap = gamemap, stored_timelapse = "invalid")
        @test get_simulated_ticks(loadmap_strict(malformed_path)) == 1
        @test_throws Exception loadmap_bundle_strict(malformed_path)
        malformed_bundle = @test_logs (:warn, r"invalid type") loadmap_bundle(malformed_path)
        @test get_simulated_ticks(malformed_bundle.gamemap) == 1
        @test isnothing(malformed_bundle.timelapse)

        null_history_path = joinpath(directory, "null_history.jld2")
        JLD2.jldsave(null_history_path; stored_gamemap = gamemap, stored_timelapse = nothing)
        @test get_simulated_ticks(loadmap_strict(null_history_path)) == 1
        @test_throws Exception loadmap_bundle_strict(null_history_path)
        null_history_bundle = loadmap_bundle(null_history_path)
        @test get_simulated_ticks(null_history_bundle.gamemap) == 1
        @test isnothing(null_history_bundle.timelapse)

        unsupported_path = joinpath(directory, "unsupported_history.jld2")
        unsupported = TimelapseHistory(format_version = UInt16(1))
        JLD2.jldsave(unsupported_path; stored_gamemap = gamemap, stored_timelapse = unsupported)
        @test get_simulated_ticks(loadmap_strict(unsupported_path)) == 1
        @test_throws Exception loadmap_bundle_strict(unsupported_path)
        unsupported_bundle = @test_logs (:warn, r"unsupported.*format version") loadmap_bundle(unsupported_path)
        @test get_simulated_ticks(unsupported_bundle.gamemap) == 1
        @test isnothing(unsupported_bundle.timelapse)
    end
end
