#=
Scope: Application UI, current-format persistence, map-source dispatch, and time-lapse recording tests
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test, LinearAlgebra, StaticArrays
import ImPlot, RocketPlumber
using FlowEngine: DerivedMapState, MNA_State
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

"Read the values shown by the component editor and inspector."
tunable_values(component) = map(prop -> prop.current_val, RocketPlumber.HexComponentsAPI.get_tunables(component))

@testset "Pending component editor and inspector values" begin
    api = RocketPlumber.HexComponentsAPI
    for (original, count, edits) in (
            (RocketPlumber.TriGasTank, 4, (3 => 7.0,)),
            (RocketPlumber.TriLiquidTank, 5, (3 => 7.0, 5 => RocketPlumber.HexFluids.FUEL_LIQUID)),
            (RocketPlumber.PressureFedLiquidTank, 6, (3 => 7.0, 4 => 3.0, 6 => RocketPlumber.HexFluids.FUEL_LIQUID)),
            (RocketPlumber.ElecTurboPump, 5, (2 => 15.0,)),
            (RocketPlumber.TurboPump, 13, (4 => 1500.0, 9 => 12.5)),
        )
        component_index = findfirst(component -> component === original, RocketPlumber.component_list)
        state = RocketPlumber.new_tile_placement_state(component_index)
        @test state.pendingcomponent === original
        state.toolrotation = Q_POS
        state.toolmirrored = true
        original_values = tunable_values(original)
        @test length(original_values) == count
        values = original_values
        for (index, value) in edits
            values = Base.setindex(values, value, index)
        end
        state.pendingcomponent = api.set_tunables(state.pendingcomponent, values)
        @test tunable_values(state.pendingcomponent) == values
        @test tunable_values(original) == original_values
        @test tunable_values(RocketPlumber.component_list[component_index]) == original_values
        @test state.toolrotation == Q_POS
        @test state.toolmirrored

        placed = api.PlacedComponent(state.pendingcomponent, state.toolrotation, state.toolmirrored, :Owner)
        @test tunable_values(placed) == values

        # Cycling restores the prototype; subsequent tuning also replaces it
        RocketPlumber.cycle_tile_component!(state, length(RocketPlumber.component_list))
        @test state.pendingcomponent === original
        state.pendingcomponent = api.set_tunables(state.pendingcomponent, values)
        @test tunable_values(state.pendingcomponent) == values
        @test tunable_values(RocketPlumber.component_list[component_index]) == original_values
        @test (state.toolrotation, state.toolmirrored) == (Q_POS, true)

        # Two map entries can share the original immutable placed value
        gamemap = GameMap()
        first_coord, second_coord = TileCoord(0, 0), TileCoord(1, 0)
        set_surface_tile!(gamemap, second_coord)
        shared = api.PlacedComponent(original, HexFrame.R_NEG, true, :primary)
        set_component!(gamemap, first_coord, shared)
        set_component!(gamemap, second_coord, shared)
        updated = api.set_tunables(get_component(gamemap, first_coord), values)
        set_component!(gamemap, first_coord, updated)
        @test tunable_values(get_component(gamemap, first_coord)) == values
        @test tunable_values(get_component(gamemap, second_coord)) == original_values
        @test tunable_values(shared) == original_values
        @test (updated.rotation, updated.mirrored, updated.ship) == (HexFrame.R_NEG, true, :primary)
    end
end

@testset "Shared pipe values have independent placed tuning" begin
    api = RocketPlumber.HexComponentsAPI
    for pipe in (ScrapPipeBehav(), BigPipeBehav())
        gamemap = GameMap()
        first_coord, second_coord = get_side_pipes(TileCoord(0, 0))[1:2]
        original_conductance = api.get_conductance(pipe)
        shared = api.PlacedPipe(pipe, :primary)
        set_pipe!(gamemap, first_coord, shared)
        set_pipe!(gamemap, second_coord, shared)
        updated = api.set_pipe_tunables(get_pipe(gamemap, first_coord), (7.5,))
        set_pipe!(gamemap, first_coord, updated)
        @test api.get_conductance(get_pipe(gamemap, first_coord)) == 7.5
        @test api.get_conductance(get_pipe(gamemap, second_coord)) == original_conductance
        @test api.get_conductance(shared) == original_conductance
        @test updated.ship === :primary
        @test get_pipe(gamemap, second_coord).ship === :primary
    end
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

"Capture component type and field values for save/load comparison."
function component_value_tree(value)
    value isa Union{Symbol, AbstractString} && return value
    fieldcount(typeof(value)) == 0 && return value
    return (typeof(value), map(name -> component_value_tree(getfield(value, name)), fieldnames(typeof(value))))
end

@testset "shipped component and pipe behaviours are isbits" begin
    # isbits also guarantees immutable nested state; keep representation checks here.
    behaviours = (RocketPlumber.component_list..., RocketPlumber.ScrapPipe, RocketPlumber.BigPipe)
    for behaviour_type in unique(typeof.(behaviours))
        @testset "$behaviour_type" begin
            @test isbitstype(behaviour_type)
        end
    end
end

@testset "shipped component values survive save/load" begin
    gamemap = GameMap()
    originals = map(component_value_tree, RocketPlumber.component_list)
    for (index, component) in enumerate(RocketPlumber.component_list)
        coord = TileCoord(index, 0)
        set_surface_tile!(gamemap, coord)
        set_component!(gamemap, coord, RocketPlumber.PlacedComponent(component, HexFrame.R_NEG, true, :primary))
    end
    mktempdir() do directory
        path = joinpath(directory, "component_values.jld2")
        savemap(gamemap, path; game_version = v"0.1.0")
        loaded = loadmap(path)
        for (index, expected) in enumerate(originals)
            placed = get_component(loaded, TileCoord(index, 0))
            @test isequal(component_value_tree(placed.component), expected)
            @test (placed.rotation, placed.mirrored, placed.ship) == (HexFrame.R_NEG, true, :primary)
        end
    end
end

@testset "freshly generated map save/load" begin
    gamemap = RocketPlumber.mapgen_teasership()
    mktempdir() do directory
        path = joinpath(directory, "current_teaser.jld2")
        RocketPlumber.save_game(gamemap, path)
        loaded = loadmap(path)
        @test typeof(loaded.components) === typeof(gamemap.components)
        @test typeof(loaded.pipe_behaviors) === typeof(gamemap.pipe_behaviors)
        @test loaded.components == gamemap.components
        @test loaded.pipe_behaviors == gamemap.pipe_behaviors
        @test length(loaded.ships) == length(gamemap.ships)
        @test HexFlowPersistence.load_game_version(path) == string(Base.pkgversion(RocketPlumber))
    end
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

@testset "Ship popup actions use the current frame map" begin
    initial_map = GameMap()
    set_surface_tile!(initial_map, TileCoord(0, 0))
    add_ship!(initial_map, :visitor, ShipState())
    set_surface_tile!(initial_map, Set(TileCoord(10, r) for r in -1:1); ship_name = :visitor)
    actions = RocketPlumber.get_ship_actions(initial_map, :visitor)

    for action in actions
        @test action.enabled
        inputstate = InputState()
        viewstate = ViewState()
        command_queue = create_command_queue(1)
        popup = ActionPopupState(
            target = ShipPopupTarget(:visitor), world_position = CartesianCoord(0.0, 0.0),
            actions = actions, window_title = "Ship: visitor",
            pending_confirmation = isnothing(action.confirmation_message) ? nothing : action,
        )
        inputstate.action_popup = popup

        # The ship has moved since the popup was opened; confirmation uses this frame's map
        snapshot = FlowCalculatorSnapshot(gamemap = deepcopy(initial_map))
        offset_ship!(snapshot.gamemap, :visitor, TileCoord(4, 0))
        set_surface_tile!(snapshot.gamemap, TileCoord(1, 0))
        source_map = deepcopy(snapshot.gamemap)
        RocketPlumber._execute_action!(inputstate, popup, action, command_queue, snapshot.gamemap, viewstate)

        @test isnothing(inputstate.action_popup)
        @test snapshot.gamemap == source_map
        visitor_tiles = Set(TileCoord(14, r) for r in -1:1)

        if action.id === :redock
            state = placement_state(inputstate)::PlacementRedockState
            @test !isready(command_queue.command_channel)
            @test state.ship_tiles == visitor_tiles
            @test state.ship_footprint == visitor_tiles
            @test state.original_centre == TileCoord(14, 0)
            @test TileCoord(1, 0) in state.other_exclusion
            @test !RocketPlumber.is_redock_preview_valid(state, TileCoord(-14, 0))
            @test RocketPlumber.is_redock_preview_valid(state, TileCoord(0, 0))

            # Cached preview geometry survives subsequent changes to the source map
            offset_ship!(snapshot.gamemap, :visitor, TileCoord(4, 0))
            @test state.ship_tiles == visitor_tiles
            @test state.ship_footprint == visitor_tiles
        else
            command = take!(command_queue.command_channel)::MapOverrideCommand
            @test command.new_map !== snapshot.gamemap
            if action.id === :make_primary
                @test !has_ship(command.new_map, :visitor)
                @test collect_surface_tiles!(Set{TileCoord}(), command.new_map; ship_name = :primary) == visitor_tiles
            else
                @test get_docking_status(command.new_map, :visitor) isa DepartingDockStat
                @test collect_surface_tiles!(Set{TileCoord}(), command.new_map; ship_name = :visitor) == visitor_tiles
            end
            command_tiles = copy(command.new_map.surface_shiptags)
            offset_ship!(snapshot.gamemap, :visitor, TileCoord(4, 0))
            @test command.new_map.surface_shiptags == command_tiles
        end
    end

    # A closed queue leaves confirmation open and the frame map untouched
    command_queue = create_command_queue(1)
    close(command_queue.command_channel)
    action = only(filter(action -> action.id === :undock, actions))
    popup = ActionPopupState(
        target = ShipPopupTarget(:visitor), world_position = CartesianCoord(0.0, 0.0),
        actions = actions, window_title = "Ship: visitor", pending_confirmation = action,
    )
    inputstate = InputState(action_popup = popup)
    source_map = deepcopy(initial_map)
    @test_logs (:warn, r"Failed to enqueue map edit command") RocketPlumber._execute_action!(
        inputstate, popup, action, command_queue, initial_map, ViewState(),
    )
    @test inputstate.action_popup === popup
    @test popup.pending_confirmation === action
    @test initial_map == source_map
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
    @test only(recorder.history.frames) !== gamemap
    @test only(recorder.history.frames) == gamemap
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
    @test before_disable.frames[1] === recorder.history.frames[1]
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
    @test !capture_timelapse_frame!(recorder, timestampless_map)
    @test recorder.last_captured_snapshot_timestamp === nothing
    @test maybe_capture_timelapse!(recorder, (gamemap = GameMap(), timestamp = 8.0); now = 300.0)
end

@testset "time-lapse frames own nested mutable state" begin
    gamemap = GameMap(learning_system = LearningProgress([:test]))
    set_surface_tile!(gamemap, TileCoord(1, 0))
    record_completed_encounter!(gamemap, ENCOUNTER_SHIP)
    recorder = TimelapseRecorder(TimelapseHistory(); now = 0.0)
    publish_snap, get_snap = create_snapshot_storage(FlowCalculatorSnapshot())

    publish_snap(gamemap, DerivedMapState(), MNA_State(), GameState(), 1.0)
    snapshot = get_snap()
    @test capture_timelapse_frame!(recorder, snapshot.gamemap; snapshot_timestamp = snapshot.timestamp)
    first_frame = only(recorder.history.frames)
    @test first_frame.surface_shiptags == gamemap.surface_shiptags
    @test first_frame.statistics == gamemap.statistics
    @test first_frame !== snapshot.gamemap
    @test first_frame.learning_system.tutorials[:test] !== snapshot.gamemap.learning_system.tutorials[:test]
    @test first_frame.statistics.completed_encounters !== snapshot.gamemap.statistics.completed_encounters

    # Capture another published buffer, then cycle through every slot repeatedly
    gamemap.learning_system.tutorials[:test].unlocked_step = 3
    record_completed_encounter!(gamemap, ENCOUNTER_SHIP)
    delete_surface_tile!(gamemap, TileCoord(1, 0))
    publish_snap(gamemap, DerivedMapState(), MNA_State(), GameState(), 2.0)
    snapshot = get_snap()
    @test capture_timelapse_frame!(recorder, snapshot.gamemap; snapshot_timestamp = snapshot.timestamp)
    second_frame = last(recorder.history.frames)
    @test second_frame.surface_shiptags == gamemap.surface_shiptags
    @test second_frame.statistics == gamemap.statistics
    @test second_frame !== snapshot.gamemap

    empty!(gamemap.learning_system.tutorials)
    empty!(gamemap.statistics.completed_encounters)
    for timestamp in 3.0:8.0
        publish_snap(gamemap, DerivedMapState(), MNA_State(), GameState(), timestamp)
        get_snap()
    end
    @test first_frame.learning_system.tutorials[:test].unlocked_step == 1
    @test get_encounter_count(first_frame, ENCOUNTER_SHIP) == 1
    @test is_on_surface_tile(TileCoord(1, 0), first_frame)
    @test second_frame.learning_system.tutorials[:test].unlocked_step == 3
    @test get_encounter_count(second_frame, ENCOUNTER_SHIP) == 2
    @test !is_on_surface_tile(TileCoord(1, 0), second_frame)
end

# A skipped capture must never attempt to copy the source map
mutable struct UncopyableTimelapseLearningState <: AbstractLearningSystem end
Base.deepcopy_internal(::UncopyableTimelapseLearningState, ::IdDict) = error("Unexpected time-lapse copy")

@testset "skipped time-lapse captures avoid copying" begin
    gamemap = GameMap(learning_system = UncopyableTimelapseLearningState())
    @test_throws ErrorException deepcopy(gamemap)
    snapshot = (gamemap = gamemap, timestamp = 1.0)
    recorder = TimelapseRecorder(nothing; now = 0.0)
    @test !capture_timelapse_frame!(recorder, gamemap)
    @test !maybe_capture_timelapse!(recorder, snapshot; now = 0.0)
    @test isnothing(recorder.history)

    set_timelapse_enabled!(recorder, true; now = 0.0)
    @test !maybe_capture_timelapse!(recorder, snapshot; capture_suppressed = true, now = 0.0)
    @test timelapse_frame_count(recorder) == 0

    gamemap.learning_system = NoLearningSystem()
    @test maybe_capture_timelapse!(recorder, snapshot; now = 0.0)
    gamemap.learning_system = UncopyableTimelapseLearningState()
    @test !maybe_capture_timelapse!(recorder, (gamemap = gamemap, timestamp = 2.0); now = 29.0)
    @test !capture_timelapse_frame!(recorder, gamemap; snapshot_timestamp = 1.0)
    @test !capture_timelapse_frame!(recorder, GameMap(learning_system = UncopyableTimelapseLearningState()); snapshot_timestamp = 1.0)
    @test !capture_timelapse_frame!(recorder, gamemap)
    @test timelapse_frame_count(recorder) == 1
    @test recorder.next_capture_time_seconds == 30.0
end

@testset "time-lapse source identity without timestamps" begin
    gamemap = GameMap()
    history = TimelapseHistory(frames = [gamemap])
    recorder = TimelapseRecorder(history; now = 0.0)
    @test !capture_timelapse_frame!(recorder, gamemap)

    other_map = deepcopy(gamemap)
    @test capture_timelapse_frame!(recorder, other_map)
    increment_simulated_ticks!(other_map)
    @test !capture_timelapse_frame!(recorder, other_map)
    @test get_simulated_ticks(last(history.frames)) == 0
    @test capture_timelapse_frame!(recorder, gamemap)
    @test timelapse_frame_count(recorder) == 3
end

@testset "manual and pre-escape saves retain owned time-lapse frames" begin
    mktempdir() do directory
        gamemap = GameMap()
        recorder = TimelapseRecorder(TimelapseHistory(); now = 0.0)
        snapshot = FlowCalculatorSnapshot(gamemap = gamemap, timestamp = 1.0)
        save_path = joinpath(directory, "manual.jld2")
        timing = PlaySessionTiming(0.0)
        RocketPlumber.save_current_map(recorder, snapshot, timing, nothing, save_path)
        @test only(recorder.history.frames) !== gamemap
        increment_simulated_ticks!(gamemap)
        @test get_simulated_ticks(only(recorder.history.frames)) == 0
        @test get_simulated_ticks(only(loadmap_bundle(save_path).timelapse.frames)) == 0

        pre_escape_map = deepcopy(gamemap)
        escape_map = GameMap(
            space_map = GalaxyEscapeSpaceMap(
                velocity = SVector(10.0, 0.0), starting_velocity_x = 10.0,
                departure_time_years = 0.0, pre_escape_map = pre_escape_map,
            )
        )
        escape_save_path = joinpath(directory, "pre_escape.jld2")
        RocketPlumber.save_pre_escape_map(recorder, escape_map, escape_save_path)
        RocketPlumber.save_pre_escape_map(recorder, escape_map, escape_save_path)
        @test timelapse_frame_count(recorder) == 2
        @test last(recorder.history.frames) !== pre_escape_map
        increment_simulated_ticks!(escape_map)
        @test get_simulated_ticks(pre_escape_map) == 1
        @test get_simulated_ticks(last(recorder.history.frames)) == 1
        saved_bundle = loadmap_bundle(escape_save_path)
        @test get_simulated_ticks(saved_bundle.gamemap) == 1
        @test get_simulated_ticks.(saved_bundle.timelapse.frames) == [0, 1]
    end
end

@testset "paired escape saves" begin
    mktempdir() do directory
        checkpoint = GameMap()
        increment_simulated_ticks!(checkpoint)
        escape_map = GameMap(space_map = GalaxyEscapeSpaceMap(SVector(10.0, 0.0), 10.0, 0.0, checkpoint))
        recorder = TimelapseRecorder(TimelapseHistory(); now = 0.0)
        state = RocketPlumber.EscapeSaveState()
        messages = String[]
        console_push = message -> push!(messages, message)
        selected_path = nothing
        dialog = (directory; filterlist) -> selected_path
        captures = String[]
        capture = path -> (push!(captures, path); write(path, "complete PNG"))

        # Cancellation neither persists nor queues a capture
        RocketPlumber.request_escape_save!(state, recorder, escape_map, console_push; dialog)
        RocketPlumber.finish_escape_save!(state, capture, console_push)
        @test isempty(readdir(directory))
        @test isempty(captures)
        @test isempty(messages)

        selected_path = joinpath(directory, "My Galactic Escape")
        RocketPlumber.request_escape_save!(state, recorder, escape_map, console_push; dialog)
        ship_path = selected_path * ".jld2"
        png_path = selected_path * ".png"
        @test state.pending_path == ship_path
        bundle = loadmap_bundle(ship_path)
        @test get_simulated_ticks(bundle.gamemap) == 1
        @test !is_galaxy_escape_active(bundle.gamemap)
        @test get_simulated_ticks(only(bundle.timelapse.frames)) == 1
        @test isempty(captures)  # Capture is deferred until the render loop finishes the next frame
        @test !ispath(png_path)
        RocketPlumber.finish_escape_save!(state, capture, console_push)
        @test read(png_path, String) == "complete PNG"
        @test isnothing(state.pending_path)
        @test last(messages) == "Escape saved! Ship: $ship_path; Screenshot: $png_path"
        @test !ispath(only(captures))
        @test sort(readdir(directory)) == ["My Galactic Escape.jld2", "My Galactic Escape.png"]

        # Refuse the PNG collision before replacing even an authorised ship file
        selected_path = ship_path
        write(ship_path, "keep ship")
        RocketPlumber.request_escape_save!(state, recorder, escape_map, console_push; dialog)
        @test isnothing(state.pending_path)
        @test read(ship_path, String) == "keep ship"
        @test read(png_path, String) == "complete PNG"
        @test startswith(last(messages), "Nothing saved.")

        selected_path = joinpath(directory, "failed_capture.jld2")
        RocketPlumber.request_escape_save!(state, recorder, escape_map, console_push; dialog)
        failed_capture = path -> (write(path, "partial PNG"); error("capture failed"))
        @test_logs (:warn, "Escape screenshot save failed") RocketPlumber.finish_escape_save!(state, failed_capture, console_push)
        @test startswith(last(messages), "Ship saved: $selected_path; screenshot failed:")
        @test isnothing(state.pending_path)
        @test !is_galaxy_escape_active(loadmap_bundle(selected_path).gamemap)
        @test !ispath(first(splitext(selected_path)) * ".png")
        @test all(name -> endswith(name, ".jld2") || endswith(name, ".png"), readdir(directory))

        # Ship failure must not queue or attempt a screenshot
        selected_path = joinpath(directory, "blocked.jld2")
        mkdir(selected_path)
        capture_count = length(captures)
        @test_logs (:warn, "Pre-escape map save failed") RocketPlumber.request_escape_save!(state, recorder, escape_map, console_push; dialog)
        @test isnothing(state.pending_path)
        RocketPlumber.finish_escape_save!(state, capture, console_push)
        @test length(captures) == capture_count
        @test !ispath(first(splitext(selected_path)) * ".png")
        @test startswith(last(messages), "Ship save failed: $selected_path.")
    end
end

@testset "galaxy-escape restart owns a mutable checkpoint copy" begin
    checkpoint = GameMap(
        space_map = SpaceMapState(encounter_config = RocketPlumber.get_encounter_system_config()),
        learning_system = LearningProgress([:test]),
    )
    escape_map = GameMap(space_map = GalaxyEscapeSpaceMap(SVector(10.0, 0.0), 10.0, 0.0, checkpoint))
    _, get_snap = create_snapshot_storage(FlowCalculatorSnapshot(gamemap = escape_map))
    borrowed = get_snap().gamemap
    @test get_pre_escape_map(borrowed) === checkpoint

    restart = RocketPlumber.capture_galaxy_escape_restart_gamemap(borrowed, PlaySessionTiming(0.0), nothing)
    @test restart !== checkpoint
    @test restart.space_map isa SpaceMapState
    restart.learning_system.tutorials[:test].unlocked_step = 9
    increment_simulated_ticks!(restart)
    @test checkpoint.learning_system.tutorials[:test].unlocked_step == 1
    @test get_simulated_ticks(checkpoint) == 0
    @test get_recorded_play_time_seconds(checkpoint) == 0.0
end

@testset "Fluid-transfer tutorial requires the transfer pump variant" begin
    gamemap = GameMap()
    entry = RocketPlumber.get_entry_fluid_transfer()
    @test !entry.trigger((gamemap = gamemap,))
    pump_coord = TileCoord(1, 0)
    set_surface_tile!(gamemap, pump_coord)
    set_component!(gamemap, pump_coord, RocketPlumber.PlacedComponent(RocketPlumber.ElecTurboPump, Q_POS, :primary))
    @test !entry.trigger((gamemap = gamemap,))
    set_component!(gamemap, pump_coord, RocketPlumber.PlacedComponent(RocketPlumber.ElecTransferPump, Q_POS, :primary))
    @test entry.trigger((gamemap = gamemap,))

    add_ship!(gamemap, :tanker, ShipState())
    tank_coord = TileCoord(2, 0)
    set_surface_tile!(gamemap, tank_coord; ship_name = :tanker)
    set_component!(gamemap, tank_coord, RocketPlumber.PlacedComponent(RocketPlumber.TriLiquidTank, Q_POS, :tanker))
    inputs = LearningInputs(gamemap = gamemap, derivedmapstate = DerivedMapState(), gamestate = GameState(), inputstate = InputState(), viewstate = ViewState(), flowcalc_shared_state = FlowCalculatorSharedState())
    blocker = entry.definition.levels[1].steps[3].step_blocker
    @test !isnothing(blocker(inputs))
    for (pump, expected_ready) in ((RocketPlumber.ElecTurboPump, false), (RocketPlumber.ElecTransferPump, true))
        set_component!(gamemap, pump_coord, RocketPlumber.PlacedComponent(pump, Q_POS, :tanker))
        @test isnothing(blocker(inputs)) == expected_ready
    end
end
