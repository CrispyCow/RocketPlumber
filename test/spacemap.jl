#=
Scope: Space Map selection, encounter identity, and manoeuvre planning
Formatter: Runic
=#

import ImPlot
using CImGui: ImVec2

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

@testset "Space Map pixel hit radius" begin
    nearest = RocketPlumber.nearest_spacemap_encounter
    mouse = ImVec2(100, 200)
    radius = RocketPlumber.ui_px(RocketPlumber.SPACEMAP_CLICK_RADIUS_MODULES, RocketPlumber.UIScale100)
    @test nearest([(1, ImVec2(110, 210))], mouse, radius) == 1
    @test nearest([(1, ImVec2(114, 214))], mouse, radius) == 0  # Circular, not square
    @test nearest([(1, ImVec2(119, 200))], mouse, radius) == 0
    @test nearest([(1, ImVec2(112, 200)), (2, ImVec2(105, 200))], mouse, radius) == 2
    @test nearest([(2, ImVec2(105, 200)), (1, ImVec2(112, 200))], mouse, radius) == 2
    @test nearest(Tuple{Int, ImVec2}[], mouse, radius) == 0

    for scale in instances(RocketPlumber.UIScale)
        scaled_radius = RocketPlumber.ui_px(RocketPlumber.SPACEMAP_CLICK_RADIUS_MODULES, scale)
        @test nearest([(1, ImVec2(mouse.x + scaled_radius - 1, mouse.y))], mouse, scaled_radius) == 1
        @test nearest([(1, ImVec2(mouse.x + scaled_radius + 1, mouse.y))], mouse, scaled_radius) == 0
        @test nearest([(1, ImVec2(130, 200))], mouse, scaled_radius) == (scaled_radius > 30 ? 1 : 0)
    end
end
