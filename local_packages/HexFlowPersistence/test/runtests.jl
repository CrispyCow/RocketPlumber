#=
Scope: Save-file round trips and authoritative-map validation
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using HexFlowPersistence
using FlowMap
using FlowMap.TypeGroupedDicts: TypeGroupedDict
using HexFrame
using HexComponentsAPI
using HexFlowBasicComponents: BasicCompBehav, BasicElemBehavFrag
using HexFlowBasicPipes: ScrapPipeBehav, BigPipeBehav
using HexFlowPersistence.HexFlowNozzleComponents: BipropChamberCompBehav, BipropChamberState
using HexFlowBasicComponents: AutoDeactivationState, deactivate
using HexFlowProcGen
using StaticArrays
using JLD2

"Build a galaxy map with position and velocity for persistence tests."
function make_galaxy_escape_ready_map(; velocity::SVector{2, Float64} = SVector(10.0, 0.0), time_years::Float64 = 0.0)::GameMap
    gamemap = GameMap()
    set_surface_tile!(gamemap, TileCoord(0, 0); ship_name = :primary)
    initialise_spacemap!(gamemap, UInt32(0x1234), EncounterSystemConfig(), velocity)
    set_time_years!(gamemap, time_years)
    return gamemap
end

@testset "built-in pipe reconstruction" begin
    gamemap = GameMap()
    pipe_coord = first(get_side_pipes(TileCoord(0, 0)))
    gamemap.pipe_behaviors[pipe_coord] = PlacedPipe(ScrapPipeBehav(), :primary)

    mktempdir() do directory
        path = joinpath(directory, "built_in_pipe.jld2")
        savemap(gamemap, path; game_version = v"0.1.0")
        loaded_map = loadmap(path)
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
        sprite = :test_persistence,
    )
    gamemap.components[component_coord] = PlacedComponent(component, HexFrame.R_NEG, true, :primary)
    gamemap.pipe_behaviors[pipe_coord] = PlacedPipe(ScrapPipeBehav(7.5), :primary)
    second_pipe_coord = get_side_pipes(component_coord)[2]
    gamemap.pipe_behaviors[second_pipe_coord] = PlacedPipe(BigPipeBehav(12.5), :primary)
    chamber_coord = TileCoord(3, -1)
    set_surface_tile!(gamemap, chamber_coord; ship_name = :primary)
    chamber_state = BipropChamberState(750.0, deactivate(AutoDeactivationState()))
    chamber = BipropChamberCompBehav(0.4, 1.0, 2.5, chamber_state)
    set_component!(gamemap, chamber_coord, PlacedComponent(chamber, HexFrame.S_POS, :primary))
    increment_simulated_ticks!(gamemap)

    mktempdir() do directory
        path = joinpath(directory, "built_in_behaviours.jld2")
        savemap(gamemap, path; game_version = v"0.1.0")
        @test isfile(path)

        child_script = joinpath(@__DIR__, "fresh_process_load.jl")
        package_dir = dirname(@__DIR__)
        command = `$(Base.julia_cmd()) --startup-file=no --history-file=no --project=$(package_dir) $(child_script) $(path)`
        @test success(command)
    end
end

@testset "crash-dump payload persistence" begin
    gamemap = GameMap()
    increment_simulated_ticks!(gamemap)
    payload = (
        stored_gamemap = gamemap,
        pending_command_diagnostics = NamedTuple[(type = :AddShipSurfaceCommand, id = UInt64(1), coord = TileCoord(1, 0))],
        node_voltages = Dict(NodeCoord(TileCoord(0, 0), HexFrame.NODE_INTERNAL_1) => 12.0),
        vsource_currents = Dict(HexComponentsAPI.HexElements.ElementID(TileCoord(0, 0), 1) => 0.5),
        exception_message = "calculator test failure",
        exception_backtrace = "calculator test failure\nStacktrace:\n [1] test crash site",
    )

    mktempdir() do directory
        dump_directory = joinpath(directory, "maps")
        path = HexFlowPersistence.write_crash_dump(payload; game_version = v"0.1.0-dev", directory = dump_directory)
        @test dirname(path) == dump_directory
        @test occursin(r"^crash_\d{8}_\d{6}\.jld2$", basename(path))
        @test isfile(path)
        dump = JLD2.load(path)
        @test dump["game_version"] == "0.1.0-dev"
        @test HexFlowPersistence.load_game_version(path) == "0.1.0-dev"
        @test only(dump["pending_command_diagnostics"]) == only(payload.pending_command_diagnostics)
        @test dump["exception_message"] == "calculator test failure"
        @test occursin("test crash site", dump["exception_backtrace"])
        @test get_simulated_ticks(loadmap(path)) == 1

        blocked_directory = joinpath(directory, "file")
        write(blocked_directory, "blocks directory creation")
        @test_throws Exception HexFlowPersistence.write_crash_dump(payload; game_version = v"0.1.0-dev", directory = blocked_directory)
    end
end

@testset "PlaythroughStatistics persistence" begin
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
        savemap(gamemap, path; game_version = v"0.1.0")
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

    mktempdir() do directory
        path = joinpath(directory, "galaxy_escape.jld2")
        savemap(gamemap, path; game_version = v"0.1.0")
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
        savemap(gamemap, map_only_path; game_version = v"0.1.0")
        map_only = loadmap_bundle(map_only_path)
        @test map_only.gamemap isa GameMap
        @test isnothing(map_only.timelapse)
        @test !JLD2.jldopen(map_only_path, "r") do file
            haskey(file, "stored_timelapse")
        end
        @test loadmap(map_only_path) isa GameMap
        @test HexFlowPersistence.load_game_version(map_only_path) == "0.1.0"

        bundled_path = joinpath(directory, "bundled.jld2")
        savemap(GameMapBundle(gamemap, history), bundled_path; game_version = v"0.1.0")
        @test HexFlowPersistence.load_game_version(bundled_path) == "0.1.0"
        bundled = loadmap_bundle(bundled_path)
        @test bundled.gamemap isa GameMap
        @test bundled.timelapse isa TimelapseHistory
        loaded_history = bundled.timelapse::TimelapseHistory
        @test length(loaded_history.frames) == 2
        @test get_simulated_ticks(loaded_history.frames[1]) == 1
        @test get_simulated_ticks(loaded_history.frames[2]) == 2

        empty_path = joinpath(directory, "empty_history.jld2")
        savemap(GameMapBundle(gamemap, TimelapseHistory()), empty_path; game_version = v"0.1.0")
        empty_bundle = loadmap_bundle(empty_path)
        @test empty_bundle.timelapse isa TimelapseHistory
        @test isempty(empty_bundle.timelapse.frames)

        malformed_path = joinpath(directory, "malformed_history.jld2")
        JLD2.jldsave(malformed_path; stored_gamemap = gamemap, stored_timelapse = "invalid")
        malformed_bundle = @test_logs (:warn, r"invalid type") loadmap_bundle(malformed_path)
        @test malformed_bundle.gamemap isa GameMap
        @test isnothing(malformed_bundle.timelapse)
    end
end

@testset "informational game version metadata" begin
    gamemap = GameMap()
    increment_simulated_ticks!(gamemap)

    mktempdir() do directory
        path = joinpath(directory, "versioned.jld2")
        savemap(gamemap, path; game_version = v"0.1.0-dev")
        @test HexFlowPersistence.load_game_version(path) == "0.1.0-dev"

        legacy_path = joinpath(directory, "unversioned.jld2")
        JLD2.jldsave(legacy_path; stored_gamemap = gamemap)
        @test isnothing(HexFlowPersistence.load_game_version(legacy_path))
        @test get_simulated_ticks(loadmap(legacy_path)) == 1
    end
end

@testset "optional history interruptions propagate" begin
    mktempdir() do directory
        path = joinpath(directory, "interrupted_history.jld2")
        savemap(GameMapBundle(GameMap(), TimelapseHistory()), path; game_version = v"0.1.0")

        # Inject cancellation in a separate process so other load tests keep the real reader.
        child_code = """
        using Test, HexFlowPersistence, JLD2
        @eval HexFlowPersistence _stored_timelapse(::JLD2.JLDFile) = throw(InterruptException())
        @test_throws InterruptException loadmap_bundle(only(ARGS))
        """
        package_dir = dirname(@__DIR__)
        command = `$(Base.julia_cmd()) --startup-file=no --history-file=no --project=$(package_dir) -e $(child_code) $(path)`
        @test success(command)
    end
end

@testset "authoritative map validation" begin
    mktempdir() do directory
        missing_path = joinpath(directory, "missing.jld2")
        absent_map_path = joinpath(directory, "absent_map.jld2")
        JLD2.jldsave(absent_map_path; other_key = 1)
        invalid_map_path = joinpath(directory, "invalid_map.jld2")
        JLD2.jldsave(invalid_map_path; stored_gamemap = "invalid")
        corrupt_path = joinpath(directory, "corrupt.jld2")
        write(corrupt_path, "not JLD2 data")

        for path in (missing_path, absent_map_path, invalid_map_path, corrupt_path)
            @test_throws Exception loadmap(path)
            @test_throws Exception loadmap_bundle(path)
        end

        gamemap = GameMap()
        increment_simulated_ticks!(gamemap)
        malformed_path = joinpath(directory, "malformed_history.jld2")
        JLD2.jldsave(malformed_path; stored_gamemap = gamemap, stored_timelapse = "invalid")
        @test get_simulated_ticks(loadmap(malformed_path)) == 1
        malformed_bundle = @test_logs (:warn, r"invalid type") loadmap_bundle(malformed_path)
        @test get_simulated_ticks(malformed_bundle.gamemap) == 1
        @test isnothing(malformed_bundle.timelapse)

        null_history_path = joinpath(directory, "null_history.jld2")
        JLD2.jldsave(null_history_path; stored_gamemap = gamemap, stored_timelapse = nothing)
        null_history_bundle = loadmap_bundle(null_history_path)
        @test get_simulated_ticks(null_history_bundle.gamemap) == 1
        @test isnothing(null_history_bundle.timelapse)
    end
end

@testset "save failures propagate" begin
    mktempdir() do directory
        path = joinpath(directory, "missing_directory", "map.jld2")
        @test_throws Exception savemap(GameMap(), path; game_version = v"0.1.0")
        @test_throws Exception savemap(GameMapBundle(GameMap(), TimelapseHistory()), path; game_version = v"0.1.0")
    end
end

@testset "current component state round trips" begin
    basic = HexFlowPersistence.HexFlowBasicComponents
    tanks = HexFlowPersistence.HexFlowTankComponents
    pumps = HexFlowPersistence.HexFlowPumpComponents
    fuel = tanks.HexFluids.FUEL_LIQUID
    states = (
        tank = tanks.TankBehavFrag(
            HexComponentsAPI.HexElements.RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.GROUND),
            50.0, 10.0, tanks.TankState(23.0), tanks.SealState(true), true,
        ),
        pressurefed = tanks.PressureFedTankBehavFrag(
            tanks.TankState(21.0), tanks.TankState(4.0), tanks.SealState(true), tanks.SealState(false),
            false, true, 50.0, 10.0, HexFrame.NODE_Q_POS, tanks.StoredFluidState(fuel),
        ),
        overheat = basic.OverheatLimitBehavFrag(
            1500.0, 2.0, 0.05, basic.ComponentTemperatureState(725.0), basic.DamageStateBehavFrag(true),
        ),
        rotor = pumps.Rotor(pumps.RotorState(4200.0), 3000.0, 50.0, 0.002),
        drive = pumps.DelayedDrive(current_power = 12.5, time_constant = 1.25),
        energy = pumps.EnergyStore(pumps.EnergyStoreState(37.0), 100.0),
        chamber = BipropChamberCompBehav(0.4, 1.0, 2.5, BipropChamberState(750.0, deactivate(AutoDeactivationState()))),
        stall = basic.StallStateBehavFrag(true),
        deactivation = deactivate(AutoDeactivationState()),
        fixed_fluid = tanks.FixedFluid(fuel),
        stored_fluid = tanks.StoredFluidState(fuel),
        empty_fluid = tanks.StoredFluidState(nothing),
    )

    mktempdir() do directory
        path = joinpath(directory, "current_states.jld2")
        JLD2.jldsave(path; states...)
        JLD2.jldopen(path, "r"; typemap = HexFlowPersistence._build_map_typemap()) do file
            for (key, expected) in pairs(states)
                loaded = file[string(key)]
                @test typeof(loaded) === typeof(expected)
                @test loaded === expected
            end
        end

        # Heterogeneous grouped stores with non-default runtime state
        turbo = pumps.TurboPumpCompBehav(50.0, 1.0, 0.3, 0.6, states.drive, states.rotor, states.deactivation, states.overheat)
        gamemap = GameMap()
        for (index, component) in enumerate((BasicCompBehav(elems = BasicElemBehavFrag(), sprite = :current_persistence), turbo, states.chamber))
            coord = TileCoord(index, 0)
            set_surface_tile!(gamemap, coord)
            set_component!(gamemap, coord, PlacedComponent(component, HexFrame.R_NEG, true, :primary))
        end
        for (coord, pipe) in zip(get_side_pipes(TileCoord(0, 0)), (ScrapPipeBehav(7.5), BigPipeBehav(12.5)))
            set_pipe!(gamemap, coord, PlacedPipe(pipe, :primary))
        end
        map_path = joinpath(directory, "current_map.jld2")
        savemap(GameMapBundle(gamemap, TimelapseHistory(frames = [deepcopy(gamemap)])), map_path; game_version = v"0.1.0-dev")
        loaded = loadmap_bundle(map_path)
        for map in (loadmap(map_path), loaded.gamemap, only(loaded.timelapse.frames))
            @test map.components isa TypeGroupedDict{TileCoord, PlacedComponent}
            @test map.pipe_behaviors isa TypeGroupedDict{PipeCoord, PlacedPipe}
            @test map.components == gamemap.components
            @test map.pipe_behaviors == gamemap.pipe_behaviors
            for (coord, expected) in gamemap.components
                @test typeof(map.components[coord]) === typeof(expected)
                @test map.components[coord] === expected
            end
            for (coord, expected) in gamemap.pipe_behaviors
                @test typeof(map.pipe_behaviors[coord]) === typeof(expected)
                @test map.pipe_behaviors[coord] === expected
            end
        end
    end
end
