#=
Scope: Application UI, saved-map compatibility, map-source dispatch, and time-lapse recording tests
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test, LinearAlgebra, StaticArrays
import ImPlot, RocketPlumber
using FlowEngine: DerivedMapState
using HexFlowLearningSystem: LearningInputs
using RocketPlumber: TimelapseRecorder, timelapse_frame_count, capture_timelapse_frame!,
    set_timelapse_enabled!, maybe_capture_timelapse!, snapshot_timelapse_history

using FlowMap, HexFrame
using HexFrame: Q_POS
using HexFlowBasicPipes
using HexFlowCalculator, HexFlowControl
using HexFlowPersistence, HexFlowProcGen
using HexFlowRendering, RenderEngine
using JLD2

include(joinpath(@__DIR__, "smoke", "SmokeTestSupport.jl"))

@testset "Background video recording" begin
    script = joinpath(@__DIR__, "recording_writer.jl")
    command = `$(Base.julia_cmd()) --project=$(dirname(Base.active_project())) --threads=2,1 $script`
    @test success(pipeline(command; stdout, stderr))
end

# ===============================================================
# Space-map manoeuvre planning
# ===============================================================

@testset "Space-map planning selection" begin
    config = EncounterSystemConfig(
        viewport_half_width = 100.0, viewport_half_height = 50.0,
        encounter_class_configs = RocketPlumber.get_encounter_system_config().encounter_class_configs,
    )
    ep = EncounterPoint(index = 1, iteration = 2, base_velocity = 10.0, velocity = SVector(10.0, -5.0), spawn_time = 2.0)
    sm = SpaceMapState(
        encounter_config = config, encounter_points = [ep],
        position = SVector(100.0, -50.0), time_years = 5.0,
        viewport_half_width = 100.0, viewport_half_height = 50.0,
    )
    gamemap = GameMap(space_map = sm)
    inputstate = InputState()
    viewport = ImPlot.ImPlotRect(0.0, 200.0, -100.0, 0.0)

    function select_encounter!()
        RocketPlumber.set_spacemap_selection!(inputstate, ep.index, ep.iteration)
        return nothing
    end

    @testset "Visible edges retain uncommitted selections" begin
        for position in (SVector(0.0, -50.0), SVector(200.0, -50.0), SVector(100.0, -100.0), SVector(100.0, 0.0))
            ep.position = position - ep.velocity * (sm.time_years - ep.spawn_time)
            select_encounter!()
            @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 1
        end
    end

    @testset "Leaving the visible viewport clears previews before recycling" begin
        for position in (SVector(-1.0, -50.0), SVector(201.0, -50.0), SVector(100.0, -101.0), SVector(100.0, 1.0))
            ep.position = position - ep.velocity * (sm.time_years - ep.spawn_time)
            select_encounter!()
            inputstate.gui_inputs[:spacemap_delta_v] = Cfloat(500.0)
            @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 0
            @test inputstate.gui_inputs[:spacemap_selected_idx] == 0
            @test inputstate.gui_inputs[:spacemap_selected_iteration] == 0
            @test !haskey(inputstate.gui_inputs, :spacemap_delta_v)
            HexFlowProcGen.check_encounter_bounds!(sm)
            @test ep.iteration == 2
        end

        # Equal axes can make the visible limits differ from the configured viewport
        ep.position = SVector(205.0, -50.0) - ep.velocity * (sm.time_years - ep.spawn_time)
        select_encounter!()
        wider_viewport = ImPlot.ImPlotRect(-10.0, 210.0, -100.0, 0.0)
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, wider_viewport) == 1
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 0

        # Reset the cached slider when a new preview is selected after clearing
        ep.position = SVector(150.0, -50.0) - ep.velocity * (sm.time_years - ep.spawn_time)
        select_encounter!()
        inputstate.gui_inputs[:spacemap_delta_v] = Cfloat(500.0)
        RocketPlumber.clear_spacemap_selection!(inputstate)
        select_encounter!()
        selected_idx = RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport)
        preview = RocketPlumber.resolve_spacemap_manoeuvre!(inputstate, gamemap, selected_idx)::ManoeuvreData
        min_dv = calculate_minimum_intercept_dv(get_velocity(gamemap), ep.velocity)
        @test inputstate.gui_inputs[:spacemap_delta_v] == Cfloat(min_dv)
        @test norm(preview.approach_burn_dv) + norm(preview.capture_burn_dv) ≈ min_dv
    end

    @testset "Committed manoeuvres survive leaving the viewport" begin
        manoeuvre = ManoeuvreData(target_encounter_index = ep.index, approach_burn_dv = SVector(10.0, 0.0), capture_burn_dv = SVector(-5.0, 0.0))
        set_active_manoeuvre!(gamemap, manoeuvre)
        for position in (SVector(-1.0, -50.0), SVector(201.0, -50.0), SVector(100.0, -101.0), SVector(100.0, 1.0))
            ep.position = position - ep.velocity * (sm.time_years - ep.spawn_time)
            select_encounter!()
            @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 1
            @test get_active_manoeuvre(gamemap) === manoeuvre
            HexFlowProcGen.check_encounter_bounds!(sm)
            @test has_active_manoeuvre(gamemap)
        end

        # Existing recycling still cancels a committed manoeuvre and invalidates selection
        ep.position = SVector(301.0, -50.0) - ep.velocity * (sm.time_years - ep.spawn_time)
        HexFlowProcGen.check_encounter_bounds!(sm)
        @test !has_active_manoeuvre(gamemap)
        @test ep.iteration == 3
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 0
    end

    @testset "Cancel visible target and immediately replan from current ship state" begin
        sm.time_years = 0.0
        sm.velocity = SVector(100.0, 0.0)
        ep.spawn_time = 0.0
        ep.position = SVector(150.0, -50.0)
        ep.velocity = SVector(110.0, 0.0)
        select_encounter!()
        initial_plan = plan_intercept_manoeuvre(sm.position, sm.velocity, ep, sm.time_years, 14.0)::ManoeuvreData
        set_active_manoeuvre!(gamemap, initial_plan)

        sm.position = SVector(120.0, -45.0)
        sm.velocity = SVector(105.0, 0.0)
        sm.time_years = 0.1
        clear_active_manoeuvre!(gamemap)
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 1

        min_dv = calculate_minimum_intercept_dv(sm.velocity, ep.velocity)
        @test min_dv == 9.0
        replan = plan_intercept_manoeuvre(sm.position, sm.velocity, ep, sm.time_years, min_dv)::ManoeuvreData
        @test replan.target_encounter_index == ep.index
        @test replan.approach_burn_time == sm.time_years
        @test replan.approach_burn_dv != initial_plan.approach_burn_dv
        @test replan.intercept_time != initial_plan.intercept_time
        intercept_position = sm.position + (sm.velocity + replan.approach_burn_dv) * (replan.intercept_time - sm.time_years)
        @test intercept_position ≈ get_encounter_position(ep, replan.intercept_time)
        @test sm.velocity + replan.approach_burn_dv + replan.capture_burn_dv ≈ ep.velocity
        set_active_manoeuvre!(gamemap, replan)
        @test get_active_manoeuvre(gamemap) === replan

        # Cancelling while offscreen returns to an uncommitted selection, which is cleared
        ep.position = SVector(201.0, -50.0) - ep.velocity * sm.time_years
        clear_active_manoeuvre!(gamemap)
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 0
    end

    @testset "Invalid selections are still cleared" begin
        for index in (-1, 2)
            select_encounter!()
            inputstate.gui_inputs[:spacemap_selected_idx] = index
            @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 0
        end
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 0
    end
end

@testset "Space-map active target selection" begin
    target = EncounterPoint(index = 1, iteration = 2, base_velocity = 10.0, position = SVector(150.0, -50.0))
    other = EncounterPoint(index = 2, iteration = 4, base_velocity = 20.0, position = SVector(50.0, -50.0), velocity = SVector(20.0, 0.0))
    sm = SpaceMapState(
        encounter_config = RocketPlumber.get_encounter_system_config(),
        encounter_points = [target, other], position = SVector(100.0, -50.0),
        viewport_half_width = 100.0, viewport_half_height = 50.0,
    )
    gamemap = GameMap(space_map = sm)
    viewport = ImPlot.ImPlotRect(0.0, 200.0, -100.0, 0.0)
    manoeuvre = ManoeuvreData(
        target_encounter_index = target.index,
        approach_burn_dv = SVector(10.0, 0.0), capture_burn_dv = SVector(-5.0, 0.0),
    )

    @testset "Opening with an active manoeuvre adopts its target" begin
        # Missing UI state, a different selection, and a stale target iteration
        for initial_selection in (nothing, (other.index, other.iteration), (target.index, target.iteration - 1))
            inputstate = InputState()
            if !isnothing(initial_selection)
                RocketPlumber.set_spacemap_selection!(inputstate, initial_selection...)
            end
            inputstate.gui_inputs[:spacemap_delta_v] = Cfloat(500.0)
            set_active_manoeuvre!(gamemap, manoeuvre)

            @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap) == target.index
            @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == target.index
            @test inputstate.gui_inputs[:spacemap_selected_iteration] == target.iteration
            @test !haskey(inputstate.gui_inputs, :spacemap_delta_v)
            @test RocketPlumber.resolve_spacemap_manoeuvre!(inputstate, gamemap, target.index) === manoeuvre
            inputstate.gui_inputs[:spacemap_delta_v] = Cfloat(500.0)

            # Both encounter and blank-space clicks preserve the committed selection
            for clicked_idx in (other.index, 0)
                RocketPlumber.select_spacemap_encounter!(inputstate, gamemap, clicked_idx)
                @test inputstate.gui_inputs[:spacemap_selected_idx] == target.index
                @test inputstate.gui_inputs[:spacemap_selected_iteration] == target.iteration
                @test get_active_manoeuvre(gamemap) === manoeuvre
                @test inputstate.gui_inputs[:spacemap_delta_v] == Cfloat(500.0)
            end

            clear_active_manoeuvre!(gamemap)
            @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == target.index
            @test inputstate.gui_inputs[:spacemap_selected_iteration] == target.iteration
            preview = RocketPlumber.resolve_spacemap_manoeuvre!(inputstate, gamemap, target.index)::ManoeuvreData
            @test preview.target_encounter_index == target.index
            @test norm(preview.approach_burn_dv) + norm(preview.capture_burn_dv) ≈ 500.0
        end
    end

    @testset "Cancellation restores normal visibility and identity validation" begin
        inputstate = InputState()
        set_active_manoeuvre!(gamemap, manoeuvre)
        target.position = SVector(201.0, -50.0)
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == target.index
        clear_active_manoeuvre!(gamemap)
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 0

        target.position = SVector(150.0, -50.0)
        set_active_manoeuvre!(gamemap, manoeuvre)
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == target.index
        clear_active_manoeuvre!(gamemap)
        target.iteration += 1
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 0
        @test inputstate.gui_inputs[:spacemap_selected_iteration] == 0
    end

    @testset "Preview budgets follow encounter identity" begin
        inputstate = InputState()
        RocketPlumber.select_spacemap_encounter!(inputstate, gamemap, target.index)
        preview = RocketPlumber.resolve_spacemap_manoeuvre!(inputstate, gamemap, target.index)::ManoeuvreData
        @test norm(preview.approach_burn_dv) + norm(preview.capture_burn_dv) ≈ 4.0
        inputstate.gui_inputs[:spacemap_delta_v] = Cfloat(500.0)

        # Repeated clicks and validation preserve the budget for the same encounter
        RocketPlumber.select_spacemap_encounter!(inputstate, gamemap, target.index)
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == target.index
        preview = RocketPlumber.resolve_spacemap_manoeuvre!(inputstate, gamemap, target.index)::ManoeuvreData
        @test norm(preview.approach_burn_dv) + norm(preview.capture_burn_dv) ≈ 500.0

        RocketPlumber.select_spacemap_encounter!(inputstate, gamemap, other.index)
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == other.index
        @test !haskey(inputstate.gui_inputs, :spacemap_delta_v)
        preview = RocketPlumber.resolve_spacemap_manoeuvre!(inputstate, gamemap, other.index)::ManoeuvreData
        @test preview.target_encounter_index == other.index
        @test inputstate.gui_inputs[:spacemap_delta_v] == Cfloat(24.0)
        @test norm(preview.approach_burn_dv) + norm(preview.capture_burn_dv) ≈ 24.0

        # Reusing the same index with a new iteration also resets the preview
        inputstate.gui_inputs[:spacemap_delta_v] = Cfloat(500.0)
        other.iteration += 1
        other.velocity = SVector(30.0, 0.0)
        RocketPlumber.select_spacemap_encounter!(inputstate, gamemap, other.index)
        @test !haskey(inputstate.gui_inputs, :spacemap_delta_v)
        preview = RocketPlumber.resolve_spacemap_manoeuvre!(inputstate, gamemap, other.index)::ManoeuvreData
        @test inputstate.gui_inputs[:spacemap_delta_v] == Cfloat(34.0)
        @test norm(preview.approach_burn_dv) + norm(preview.capture_burn_dv) ≈ 34.0

        other.iteration += 1
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 0
        @test !haskey(inputstate.gui_inputs, :spacemap_delta_v)
        @test isnothing(RocketPlumber.resolve_spacemap_manoeuvre!(inputstate, gamemap, 0))

        RocketPlumber.select_spacemap_encounter!(inputstate, gamemap, other.index)
        RocketPlumber.resolve_spacemap_manoeuvre!(inputstate, gamemap, other.index)
        RocketPlumber.select_spacemap_encounter!(inputstate, gamemap, 0)
        @test RocketPlumber.validate_spacemap_selection!(inputstate, gamemap, viewport) == 0
        @test !haskey(inputstate.gui_inputs, :spacemap_delta_v)
    end
end

@testset "Space Map tutorial manoeuvre planning" begin
    steps = RocketPlumber.get_entry_space_map_intro().definition.steps
    objects_step = only(filter(step -> step.heading == "OBJECTS IN SPACE", steps))
    planning_step = only(filter(step -> step.heading == "PLANNING A MANOEUVRE", steps))
    blocker = planning_step.step_blocker
    gamemap = GameMap(
        space_map = SpaceMapState(
            encounter_config = EncounterSystemConfig(),
            encounter_points = [
                EncounterPoint(index = index, base_velocity = 0.0, encounter_class = encounter_class)
                    for (index, encounter_class) in enumerate((ENCOUNTER_SHIP, ENCOUNTER_FUEL_CACHE, ENCOUNTER_SCRAP))
            ],
        )
    )
    inputs = LearningInputs(
        gamemap = gamemap,
        derivedmapstate = DerivedMapState(),
        gamestate = GameState(estimated_min_delta_v = 100.0),
        inputstate = InputState(),
        viewstate = ViewState(),
        flowcalc_shared_state = FlowCalculatorSharedState(),
    )
    gui_inputs = inputs.inputstate.gui_inputs

    @test occursin("Select a fuel cache", planning_step.text)
    @test !occursin("75%", planning_step.text)
    no_target = blocker(inputs)
    @test occursin("Select a fuel cache", no_target)
    for selected_idx in (0, -1, 4, "invalid")
        gui_inputs[:spacemap_selected_idx] = selected_idx
        @test blocker(inputs) == no_target
    end

    for selected_idx in (1, 3)
        gui_inputs[:spacemap_selected_idx] = selected_idx
        @test isnothing(objects_step.step_blocker(inputs))
        @test blocker(inputs) == "Select a fuel cache as your manoeuvre target."
    end

    gui_inputs[:spacemap_selected_idx] = 2
    @test blocker(inputs) == "Plan a manoeuvre to the selected fuel cache by pressing 'Plan Manoeuvre'."
    for delta_v in (74.0f0, 75.0f0)
        gui_inputs[:spacemap_delta_v] = delta_v
        @test blocker(inputs) == "Plan a manoeuvre to the selected fuel cache by pressing 'Plan Manoeuvre'."
    end
    gui_inputs[:spacemap_delta_v] = 76.0f0
    excessive_preview = blocker(inputs)
    @test occursin("no more than 75% of your estimated ship delta-V", excessive_preview)

    # Validate committed targets and both planned burns, regardless of the preview
    gui_inputs[:spacemap_delta_v] = 1.0f0
    for target_idx in (0, 4, 1, 3, 2)
        set_active_manoeuvre!(
            gamemap, ManoeuvreData(
                target_encounter_index = target_idx,
                approach_burn_dv = SVector(30.0, 40.0),
                capture_burn_dv = SVector(-15.0, -20.0),
            )
        )
        message = blocker(inputs)
        if target_idx == 2
            @test isnothing(message) # Exactly 75% is allowed
        else
            @test occursin("Cancel this manoeuvre", message)
            @test occursin("fuel cache", message)
        end
    end

    gui_inputs[:spacemap_selected_idx] = 0
    gui_inputs[:spacemap_delta_v] = 1000.0f0
    @test isnothing(blocker(inputs))
    inputs.gamestate.estimated_min_delta_v = 99.0
    excessive_plan = blocker(inputs)
    @test occursin("no more than 75% of your estimated ship delta-V", excessive_plan)
    @test occursin("Cancel this manoeuvre", excessive_plan)
    @test occursin("plan a new one", excessive_plan)

    clear_active_manoeuvre!(gamemap)
    @test blocker(inputs) == no_target
end

@testset "Console notifications" begin
    ipc = RocketPlumber.setup_flowcalc_ipc(FlowCalculatorSnapshot())
    winsize = (width = Int32(800), height = Int32(600))
    @test isnothing(ipc.console_see())
    @test isnothing(RocketPlumber.ui_notifications_render!(winsize, ipc.console_see))

    # Existing IPC producers need only supply the message text
    ipc.console_push("hello")
    @test ipc.console_see().text == "hello"
    ipc.console_push("latest")
    @test ipc.console_see().text == "latest"

    # Expired notifications return before any CImGui calls, even without a UI context
    expired = ConsoleMessage("expired", Float64(time_ns()) / 1.0e9 - RocketPlumber.NOTIFICATION_DURATION)
    @test isnothing(RocketPlumber.ui_notifications_render!(winsize, () -> expired))
end

@testset "Launch and smoke arguments" begin
    for (args, options) in (
            (String[], (telemetry = false, gc_log = false)),
            (["--telemetry"], (telemetry = true, gc_log = false)),
            (["--gc-log"], (telemetry = false, gc_log = true)),
            (["--telemetry", "--gc-log"], (telemetry = true, gc_log = true)),
            (["--gc-log", "--telemetry"], (telemetry = true, gc_log = true)),
        )
        @test RocketPlumber.parse_launch_args(args) == options
        @test SmokeTestSupport.parse_smoke_args(args) == (; options..., duration = 20.0)
    end

    for args in (["--unknown"], ["--gc-log", "--unknown"], ["--duration", "60"])
        @test_throws ArgumentError RocketPlumber.parse_launch_args(args)
    end

    for (args, options) in (
            (["--telemetry", "--duration", "60"], (telemetry = true, gc_log = false, duration = 60.0)),
            (["--duration", "21.5", "--telemetry"], (telemetry = true, gc_log = false, duration = 21.5)),
            (["--gc-log", "--duration", "60"], (telemetry = false, gc_log = true, duration = 60.0)),
            (["--telemetry", "--duration", "21.5", "--gc-log"], (telemetry = true, gc_log = true, duration = 21.5)),
            (["--gc-log", "--duration", "60", "--telemetry"], (telemetry = true, gc_log = true, duration = 60.0)),
        )
        @test SmokeTestSupport.parse_smoke_args(args) == options
    end

    @test SmokeTestSupport.smoke_exit_tick(20.0) == 1200
    @test SmokeTestSupport.smoke_exit_tick(60.0) == 3600
    @test SmokeTestSupport.smoke_exit_tick(20.01) == 1201
    for args in (["--duration"], ["--duration", "bad"], ["--duration", "19.9"], ["--duration", "NaN"], ["--duration", "Inf"], ["--unknown"])
        @test_throws ArgumentError SmokeTestSupport.parse_smoke_args(args)
        @test_throws ArgumentError SmokeTestSupport.parse_smoke_args(vcat(["--gc-log"], args))
    end
end

@testset "Editor Mode transitions" begin
    inputstate = InputState()
    @test !editor_capabilities_enabled(inputstate)

    # Exercise the same state changes used by the shortcut and checkbox.
    RocketPlumber.set_editor_mode!(inputstate, !inputstate.editor_mode)
    @test editor_capabilities_enabled(inputstate)
    RocketPlumber.set_editor_mode!(inputstate, false)
    @test !editor_capabilities_enabled(inputstate)

    RocketPlumber.set_editor_mode!(inputstate, true)
    @test editor_capabilities_enabled(inputstate)
    RocketPlumber.set_editor_mode!(inputstate, !inputstate.editor_mode)
    @test !editor_capabilities_enabled(inputstate)

    for editor_state in (PlacementDeleteState(), RocketPlumber.new_tile_placement_state(), PlacementSurfaceEditState())
        RocketPlumber.set_editor_mode!(inputstate, true)
        set_placement_state!(inputstate, editor_state)
        RocketPlumber.set_editor_mode!(inputstate, false)
        @test placement_state(inputstate) isa PlacementReadyState
    end

    pipe_state = PlacementPipeChainState(
        source_node = VertexCoord(TileCoord(0, 0), Q_POS),
        pipe_behavior = BigPipeBehav(),
    )
    RocketPlumber.set_editor_mode!(inputstate, true)
    set_placement_state!(inputstate, pipe_state)
    RocketPlumber.set_editor_mode!(inputstate, false)
    @test placement_state(inputstate) === pipe_state
    @test pipe_state.pipe_behavior isa ScrapPipeBehav
end

@testset "application map-source dispatch" begin
    gamemap = GameMap()
    @test RocketPlumber.loadmap_from_source(gamemap) === gamemap
    @test RocketPlumber.loadmap_bundle_from_source(gamemap).gamemap === gamemap
    @test isnothing(RocketPlumber.loadmap_bundle_from_source(gamemap).timelapse)

    ship_map = RocketPlumber.loadmap_from_source(ShipState())
    @test ship_map isa GameMap
    @test RocketPlumber.loadmap_bundle_from_source(ShipState()).gamemap isa GameMap
    @test RocketPlumber.loadmap_from_source(nothing) isa GameMap
    @test RocketPlumber.loadmap_bundle_from_source(nothing).gamemap isa GameMap

    mktempdir() do directory
        path = joinpath(directory, "source_bundle.jld2")
        history = TimelapseHistory(frames = [gamemap])
        RocketPlumber.save_game(GameMapBundle(gamemap, history), path)

        @test RocketPlumber.loadmap_from_source(path) isa GameMap
        bundle = RocketPlumber.loadmap_bundle_from_source(path)
        @test bundle.gamemap isa GameMap
        @test bundle.timelapse isa TimelapseHistory
        @test length(bundle.timelapse.frames) == 1
    end
end

@testset "frozen teaser save compatibility" begin
    # Immutable historical test data: the sole provisional pre-release baseline.
    # At the final 0.1.0 release, replace it with a save generated by that release
    # as teaser_0.1.0.jld2, rather than retaining both fixtures.
    path = joinpath(@__DIR__, "fixtures", "teaser_0.1.0-dev.jld2")
    @test HexFlowPersistence.load_game_version(path) == "0.1.0-dev"
    gamemap = loadmap(path)
    @test length(gamemap.ships) == 5
    @test !isempty(gamemap.pipe_behaviors)
end

@testset "application saves record the root package version" begin
    mktempdir() do directory
        path = joinpath(directory, "map.jld2")
        RocketPlumber.save_game(GameMap(), path)
        @test HexFlowPersistence.load_game_version(path) == string(Base.pkgversion(RocketPlumber))
        @test loadmap(path) isa GameMap
        @test_throws Exception RocketPlumber.save_game(GameMap(), joinpath(directory, "missing_directory", "map.jld2"))
    end
end

@testset "Isolated application output paths" begin
    mktempdir() do directory
        documents = joinpath(directory, "Custom Documents")
        config = mkpath(joinpath(directory, "config"))
        workdir = mkpath(joinpath(directory, "work"))
        write(joinpath(config, "user-dirs.dirs"), "XDG_DOCUMENTS_DIR=\"$documents\"\n")
        script = joinpath(@__DIR__, "output_paths.jl")
        command = `$(Base.julia_cmd()) --project=$(dirname(Base.active_project())) $script $documents $workdir`
        # A fresh process resolves BaseDirs during runtime initialisation, before application import
        command = addenv(command, "XDG_CONFIG_HOME" => config, "XDG_DOCUMENTS_DIR" => nothing, "JULIA_GLFW_PLATFORM" => "null")
        @test success(pipeline(command; stdout, stderr))
    end
end

@testset "start-menu selected-save loading" begin
    state = RocketPlumber.StartMenuState()
    gamemap = GameMap()
    increment_simulated_ticks!(gamemap)

    mktempdir() do directory
        invalid_path = joinpath(directory, "invalid_map.jld2")
        JLD2.jldsave(invalid_path; stored_gamemap = "invalid")
        session = @test_logs (:warn, r"Selected save could not be loaded") RocketPlumber._load_map_session!(state, invalid_path)
        @test isnothing(session)
        @test !isempty(state.load_error)

        # A new action clears the error even when it produces no session.
        window = RocketPlumber.GLFW.Window(C_NULL)
        RocketPlumber.handle_start_menu_action!(state, window)
        @test !isempty(state.load_error)
        state.action = RocketPlumber.ACTION_LAUNCH_SANDBOX
        RocketPlumber.handle_start_menu_action!(state, window)
        @test isempty(state.load_error)

        valid_path = joinpath(directory, "valid.jld2")
        RocketPlumber.save_game(gamemap, valid_path)
        legacy_path = joinpath(directory, "legacy.jld2")
        JLD2.jldsave(legacy_path; stored_gamemap = gamemap)

        for path in (valid_path, legacy_path)
            session = RocketPlumber._load_map_session!(state, path)
            @test session isa RocketPlumber.MapSession
            @test get_simulated_ticks(session.bundle.gamemap) == 1
            @test isempty(state.load_error)
        end

        invalid_history_path = joinpath(directory, "invalid_history.jld2")
        JLD2.jldsave(invalid_history_path; stored_gamemap = gamemap, stored_timelapse = "invalid")
        session = @test_logs (:warn, r"Time-lapse load failed") RocketPlumber._load_map_session!(state, invalid_history_path)
        @test session isa RocketPlumber.MapSession
        @test get_simulated_ticks(session.bundle.gamemap) == 1
        @test isnothing(session.bundle.timelapse)
    end
end

@testset "world render queue population" begin
    gamemap = GameMap()
    set_surface_tile!(gamemap, TileCoord(0, 0))
    snapshot = FlowCalculatorSnapshot(gamemap = gamemap)
    inputstate = InputState()
    renderqueue = SpriteRenderCommand[]

    glmap = GLObjectMap()
    glmap.textures[:TestAtlas] = RenderEngine.GLtexData(RenderEngine.GLtexID(0), UInt32(0), UInt(256), UInt(256))
    glmap.sprites[:ShipSurface_basic] = GLspriteData(
        :TestAtlas,
        SVector{2, Float32}(0.1f0, 0.1f0),
        SVector{2, Float32}(0.0f0, 0.0f0),
        SVector{2, Float32}(256.0f0, 256.0f0),
        SVector{2, Float32}(256.0f0, 256.0f0),
        SVector{2, Float32}(0.0f0, 0.0f0),
    )

    RocketPlumber.populate_renderqueue!(renderqueue, glmap, snapshot, inputstate)
    @test !isempty(renderqueue)
end

@testset "render-thread time-lapse recorder" begin
    gamemap = GameMap()
    snapshot = (gamemap = gamemap, timestamp = 1.0)

    recorder = TimelapseRecorder(nothing; now = 0.0)
    @test !recorder.enabled
    @test isnothing(recorder.history)
    @test timelapse_frame_count(recorder) == 0
    @test !capture_timelapse_frame!(recorder, GameMap(); snapshot_timestamp = 0.5)
    @test isnothing(recorder.history)

    loaded_recorder = TimelapseRecorder(TimelapseHistory(); now = 10.0)
    @test loaded_recorder.enabled
    @test loaded_recorder.next_capture_time_seconds == 40.0

    set_timelapse_enabled!(recorder, true; now = 0.0)
    @test recorder.enabled
    @test maybe_capture_timelapse!(recorder, snapshot; now = 0.0)
    @test timelapse_frame_count(recorder) == 1
    @test only(recorder.history.frames) === gamemap
    @test !maybe_capture_timelapse!(recorder, snapshot; now = 30.0)

    changed_snapshot = (gamemap = GameMap(), timestamp = 2.0)
    @test maybe_capture_timelapse!(recorder, changed_snapshot; now = 31.0)
    @test timelapse_frame_count(recorder) == 2
    @test recorder.next_capture_time_seconds == 61.0

    suppressed_snapshot = (gamemap = GameMap(), timestamp = 3.0)
    @test !maybe_capture_timelapse!(recorder, suppressed_snapshot; capture_suppressed = true, now = 100.0)
    @test recorder.next_capture_time_seconds == 61.0
    @test maybe_capture_timelapse!(recorder, suppressed_snapshot; now = 101.0)
    @test timelapse_frame_count(recorder) == 3

    before_disable = snapshot_timelapse_history(recorder)::TimelapseHistory
    @test before_disable.frames !== recorder.history.frames
    @test before_disable.frames[1] === gamemap
    @test capture_timelapse_frame!(recorder, GameMap(); snapshot_timestamp = 4.0)
    set_timelapse_enabled!(recorder, false; now = 110.0)
    @test !recorder.enabled
    @test !maybe_capture_timelapse!(recorder, (gamemap = GameMap(), timestamp = 5.0); now = 200.0)
    @test timelapse_frame_count(recorder) == 4

    set_timelapse_enabled!(recorder, true; now = 200.0)
    reenabled_snapshot = (gamemap = GameMap(), timestamp = 6.0)
    @test maybe_capture_timelapse!(recorder, reenabled_snapshot; now = 200.0)
    @test timelapse_frame_count(recorder) == 5

    prepared = snapshot_timelapse_history(recorder)::TimelapseHistory
    @test capture_timelapse_frame!(recorder, GameMap(); snapshot_timestamp = 7.0)
    @test length(prepared.frames) == 5

    timestamped_map = GameMap()
    @test capture_timelapse_frame!(recorder, timestamped_map; snapshot_timestamp = 8.0)
    @test !capture_timelapse_frame!(recorder, timestamped_map; snapshot_timestamp = 8.0)
    timestampless_map = GameMap()
    @test capture_timelapse_frame!(recorder, timestampless_map)
    @test recorder.last_captured_snapshot_timestamp === nothing
    @test maybe_capture_timelapse!(recorder, (gamemap = GameMap(), timestamp = 8.0); now = 300.0)
end
