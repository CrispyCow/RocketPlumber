#=
Scope: HexFlowControl state and control helpers
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using HexComponentsAPI
using HexFlowControl
using HexFrame

# ===============================================================
# Mock Types
# ===============================================================

struct MockCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::MockCompBehav) = ()
HexComponentsAPI.get_tunables(::MockCompBehav) = ()
HexComponentsAPI.set_tunables(behaviour::MockCompBehav, ::Any) = behaviour
HexComponentsAPI.render_base_elem!(::Any, ::MockCompBehav; kwargs...) = nothing

struct MockPipeBehav <: PipeBehavior end
HexComponentsAPI.get_conductance(::MockPipeBehav) = 1.0
HexComponentsAPI.get_pipe_tunables(::MockPipeBehav) = ()
HexComponentsAPI.set_pipe_tunables(behaviour::MockPipeBehav, ::Any) = behaviour
HexComponentsAPI.render_pipe_base!(::Any, ::MockPipeBehav; kwargs...) = nothing
HexComponentsAPI.get_pipe_click_radius(::MockPipeBehav) = 0.1

# ===============================================================
# Test Helpers
# ===============================================================

make_tile_state(; component_index = 1, mirrored = false) = PlacementTileState(
    component_index = component_index, pendingcomponent = MockCompBehav(), toolmirrored = mirrored,
)

make_pipe_state() = PlacementPipeChainState(
    source_node = VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), pipe_behavior = MockPipeBehav(),
)

make_popup(target) = ActionPopupState(
    target = target, world_position = CartesianCoord(0.0, 0.0), actions = (), window_title = "Actions",
)

make_test_inputstate() = InputState()

function make_test_redock_state()
    return PlacementRedockState(
        ship_name = :test_ship,
        ship_tiles = Set{TileCoord}(),
        exclusion_ring = Set{TileCoord}(),
        ship_footprint = Set{TileCoord}(),
        other_exclusion = Set{TileCoord}(),
        original_centre = TileCoord(0, 0),
    )
end

function make_pressed_state(; move_target = nothing, click_tile = TileCoord(1, 2))
    return PlacementPressedState(
        press_started_at = 3.5,
        press_cursor_cart = CartesianCoord(1.5, 2.5),
        click_tile = click_tile,
        move_target = move_target,
    )
end

# ===============================================================
# Tests
# ===============================================================

@testset "HexFlowControl" begin

    @testset "Galaxy escape rules" begin
        @test GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V == 600.0
        @test isfinite(GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V)
        @test GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V > 0.0
        @test all(isfinite, GALAXY_ESCAPE_TIER_DELTA_V)
        @test all(>(0.0), GALAXY_ESCAPE_TIER_DELTA_V)
        @test issorted(GALAXY_ESCAPE_TIER_DELTA_V)
        @test GALAXY_ESCAPE_TIER_DELTA_V[1] < GALAXY_ESCAPE_TIER_DELTA_V[2] < GALAXY_ESCAPE_TIER_DELTA_V[3]
        @test GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V < first(GALAXY_ESCAPE_TIER_DELTA_V)

        @test !is_galaxy_escape_unlocked(prevfloat(GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V))
        @test is_galaxy_escape_unlocked(GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V)
        @test is_galaxy_escape_unlocked(nextfloat(GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V))
        @test !is_galaxy_escape_unlocked(-1.0)

        first_tier, second_tier, third_tier = GALAXY_ESCAPE_TIER_DELTA_V
        @test galaxy_escape_tier(-1.0) == 0x00
        @test galaxy_escape_tier(0.0) == 0x00
        @test galaxy_escape_tier(prevfloat(first_tier)) == 0x00
        @test galaxy_escape_tier(first_tier) == 0x01
        @test galaxy_escape_tier(nextfloat(first_tier)) == 0x01
        @test galaxy_escape_tier(prevfloat(second_tier)) == 0x01
        @test galaxy_escape_tier(second_tier) == 0x02
        @test galaxy_escape_tier(nextfloat(second_tier)) == 0x02
        @test galaxy_escape_tier(prevfloat(third_tier)) == 0x02
        @test galaxy_escape_tier(third_tier) == 0x03
        @test galaxy_escape_tier(nextfloat(third_tier)) == 0x03
        @test !can_complete_galaxy_escape(prevfloat(first_tier))
        @test can_complete_galaxy_escape(first_tier)

        for invalid_value in (NaN, Inf, -Inf)
            @test_throws ArgumentError is_galaxy_escape_unlocked(invalid_value)
            @test_throws ArgumentError galaxy_escape_tier(invalid_value)
            @test_throws ArgumentError can_complete_galaxy_escape(invalid_value)
        end
    end

    @testset "PlaySessionTiming" begin
        timing = PlaySessionTiming(120.0; started_at_ns = UInt64(1_000_000_000))
        @test get_current_play_time_seconds(timing; current_time_ns = UInt64(31_000_000_000)) == 150.0
        @test get_current_play_time_seconds(timing; current_time_ns = UInt64(1_000_000_000)) == 120.0

        @test get_current_play_time_seconds(timing; current_time_ns = UInt64(41_000_000_000)) == 160.0
        @test timing.recorded_play_time_at_start_seconds == 120.0
        @test timing.started_at_ns == UInt64(1_000_000_000)

        @test_throws ArgumentError get_current_play_time_seconds(timing; current_time_ns = UInt64(999_999_999))
        @test_throws ArgumentError PlaySessionTiming(-1.0; started_at_ns = UInt64(1))
        @test_throws ArgumentError PlaySessionTiming(Inf; started_at_ns = UInt64(1))
        @test_throws ArgumentError PlaySessionTiming(NaN; started_at_ns = UInt64(1))
    end

    @testset "InputState defaults" begin
        is = make_test_inputstate()
        @test placement_state(is) isa PlacementReadyState
        @test selection_state(is) isa SelectionEmptyState
        @test isempty(selected_component_coords(is))
        @test isempty(selected_pipe_coords(is))
        @test !hasproperty(is, :pending_move_completion)
        @test !hasproperty(is, :rightclick_selectedcoord)
        @test isnothing(is.action_popup)
        for field in (:toolbar, :last_toolbar, :tile_tool_state, :pendingpipebehavior, :rightclick_selectedship, :last_command_time)
            @test !hasproperty(is, field)
        end
        @test !editor_capabilities_enabled(is)
        @test !is.galaxy_escape_completion_requested
    end

    @testset "active placement tool state owns its configuration" begin
        tile_state = make_tile_state(component_index = 3, mirrored = true)
        @test tile_state.component_index == 3
        @test tile_state.pendingcomponent isa MockCompBehav
        tile_state.toolrotation = HexFrame.R_POS
        tile_state.toolmirrored = false
        @test tile_state.toolrotation == HexFrame.R_POS
        @test !tile_state.toolmirrored

        pipe_state = make_pipe_state()
        @test pipe_state.pipe_behavior isa MockPipeBehav
        next_state = PlacementPipeChainState(
            source_node = pipe_state.source_node, pipe_behavior = pipe_state.pipe_behavior,
        )
        @test next_state.pipe_behavior === pipe_state.pipe_behavior
    end

    @testset "state classification helpers" begin
        is = make_test_inputstate()
        state = placement_state(is)
        @test state isa PlacementReadyState
        @test is_standard_family_state(state)
        @test !is_active_standard_interaction_state(state)

        set_placement_state!(is, make_pressed_state())
        state = placement_state(is)
        @test state isa PlacementPressedState
        @test is_standard_family_state(state)
        @test is_active_standard_interaction_state(state)

        pending_state = PlacementMovePendingState(
            response_channel = Channel{Any}(1),
            original_selection = SelectionEmptyState(),
            translated_selection = SelectionEmptyState(),
            expected_component_sources = Set{TileCoord}(),
            expected_component_destinations = Set{TileCoord}(),
            expected_pipe_sources = Set{PipeCoord}(),
            expected_pipe_destinations = Set{PipeCoord}(),
        )
        set_placement_state!(is, pending_state)
        @test is_standard_family_state(placement_state(is))
        @test !is_active_standard_interaction_state(placement_state(is))

        set_placement_state!(is, PlacementDeleteState())
        state = placement_state(is)
        @test state isa PlacementDeleteState
        @test state isa AbstractEditorPlacementState
        @test !is_active_standard_interaction_state(state)

        set_placement_state!(is, make_test_redock_state())
        state = placement_state(is)
        @test state isa PlacementRedockState
        @test !(state isa AbstractEditorPlacementState)
        @test !is_standard_family_state(state)
    end

    @testset "pressed state stores click and optional move target" begin
        no_target = make_pressed_state()
        @test no_target.press_started_at == 3.5
        @test no_target.press_cursor_cart == CartesianCoord(1.5, 2.5)
        @test no_target.click_tile == TileCoord(1, 2)
        @test isnothing(no_target.move_target)

        move_target = TileComponentMoveTarget(TileCoord(2, 3))
        with_target = make_pressed_state(move_target = move_target)
        @test with_target.press_started_at == 3.5
        @test with_target.press_cursor_cart == CartesianCoord(1.5, 2.5)
        @test with_target.click_tile == TileCoord(1, 2)
        @test with_target.move_target === move_target
    end

    @testset "editor capability gate" begin
        is = make_test_inputstate()
        @test !editor_capabilities_enabled(is)
        is.editor_mode = true
        @test editor_capabilities_enabled(is)
    end

    @testset "mixed selection helpers" begin
        is = make_test_inputstate()
        first_coord = TileCoord(1, 1)
        second_coord = TileCoord(2, 3)
        pipe = PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG))

        select_single_component!(is, first_coord)
        @test selection_state(is) isa WorldSelectionState
        @test selected_component_coords(is) == Set((first_coord,))
        @test has_selected_component(is, first_coord)
        @test !has_selected_component(is, second_coord)

        select_single_component!(is, second_coord)
        @test selected_component_coords(is) == Set((second_coord,))
        @test !has_selected_component(is, first_coord)

        toggle_selected_component!(is, first_coord)
        @test selected_component_coords(is) == Set((first_coord, second_coord))
        @test selected_element_count(is) == 2

        toggle_selected_component!(is, first_coord)
        @test selected_component_coords(is) == Set((second_coord,))

        toggle_selected_component!(is, first_coord)
        toggle_selected_pipe!(is, pipe)
        @test selected_pipe_coords(is) == Set((pipe,))
        prune_selection!(coord -> coord == first_coord, _ -> true, is)
        @test selected_component_coords(is) == Set((first_coord,))
        @test selected_pipe_coords(is) == Set((pipe,))
        prune_selection!(_ -> true, _ -> false, is)
        @test selected_component_coords(is) == Set((first_coord,))
        @test isempty(selected_pipe_coords(is))

        select_elements!(is, Set((second_coord, first_coord)), Set{PipeCoord}())
        @test selected_component_coords(is) == Set((first_coord, second_coord))

        selection = WorldSelectionState(Set((first_coord,)), Set((pipe,)))
        translated = translate_selection(selection, TileCoord(2, -1))
        @test translated.component_coords == Set((TileCoord(3, 0),))
        @test translated.pipe_coords == Set((offset_by_tile(pipe, TileCoord(2, -1)),))

        @test_throws ArgumentError WorldSelectionState(Set{TileCoord}(), Set{PipeCoord}())

        popup = ElementGroupPopupTarget(Set((first_coord,)), Set((pipe,)))
        @test popup.component_coords == [first_coord]
        @test popup.pipe_coords == [pipe]
        @test_throws ArgumentError ElementGroupPopupTarget(Set((first_coord,)), Set{PipeCoord}())

        clear_selection!(is)
        @test selection_state(is) isa SelectionEmptyState
        @test isempty(selected_component_coords(is))
    end

    @testset "world-selection helpers" begin
        is = make_test_inputstate()
        first_coord = TileCoord(1, 1)
        select_single_component!(is, first_coord)
        is.action_popup = make_popup(ComponentPopupTarget(first_coord))

        dismiss_action_popup!(is)
        @test selected_component_coords(is) == Set((first_coord,))
        @test isnothing(is.action_popup)

        is.action_popup = make_popup(ShipPopupTarget(:test_ship))
        @test highlighted_ship(is) === :test_ship
        dismiss_action_popup!(is)
        @test isnothing(highlighted_ship(is))

        is.action_popup = make_popup(ComponentPopupTarget(first_coord))

        clear_world_selection!(is)
        @test selection_state(is) isa SelectionEmptyState
        @test isnothing(is.action_popup)

        pipe = PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG))
        select_elements!(is, Set((first_coord,)), Set((pipe,)))
        is.action_popup = make_popup(ElementGroupPopupTarget(Set((first_coord,)), Set((pipe,))))
        dismiss_action_popup!(is)
        @test isnothing(highlighted_ship(is))
        @test selected_element_count(is) == 2

        set_placement_state!(is, make_pressed_state())
        select_single_component!(is, TileCoord(2, 2))
        @test enter_ready_placement_state!(is)
        @test placement_state(is) isa PlacementReadyState
        @test selected_component_coords(is) == Set((TileCoord(2, 2),))

        pending_state = PlacementMovePendingState(
            response_channel = Channel{Any}(1),
            original_selection = WorldSelectionState(Set((TileCoord(1, 1),)), Set{PipeCoord}()),
            translated_selection = WorldSelectionState(Set((TileCoord(2, 1),)), Set{PipeCoord}()),
            expected_component_sources = Set((TileCoord(1, 1),)),
            expected_component_destinations = Set((TileCoord(2, 1),)),
            expected_pipe_sources = Set{PipeCoord}(),
            expected_pipe_destinations = Set{PipeCoord}(),
        )
        select_single_component!(is, TileCoord(1, 1))
        set_placement_state!(is, pending_state)
        @test !enter_ready_placement_state!(is)
        @test selected_component_coords(is) == Set((TileCoord(1, 1),))
        @test placement_state(is) === pending_state

        clear_world_selection!(is)
        @test selection_state(is) isa SelectionEmptyState
        @test placement_state(is) === pending_state
    end

    @testset "Escape world-interaction precedence" begin
        is = make_test_inputstate()
        coord = TileCoord(1, 1)
        select_single_component!(is, coord)
        is.action_popup = make_popup(ComponentPopupTarget(coord))

        @test handle_world_escape!(is)
        @test isnothing(is.action_popup)
        @test selected_component_coords(is) == Set((coord,))

        @test handle_world_escape!(is)
        @test selection_state(is) isa SelectionEmptyState
        @test !handle_world_escape!(is)

        select_single_component!(is, coord)
        move_state = PlacementMoveState(move_target = TileComponentMoveTarget(coord))
        set_placement_state!(is, move_state)

        @test handle_world_escape!(is)
        @test placement_state(is) isa PlacementReadyState
        @test selected_component_coords(is) == Set((coord,))

        @test handle_world_escape!(is)
        @test selection_state(is) isa SelectionEmptyState

        set_placement_state!(is, make_tile_state())
        @test handle_world_escape!(is)
        @test placement_state(is) isa PlacementReadyState

        set_placement_state!(is, make_test_redock_state())
        @test handle_world_escape!(is)
        @test placement_state(is) isa PlacementReadyState

        pending_state = PlacementMovePendingState(
            response_channel = Channel{Any}(1),
            original_selection = WorldSelectionState(Set((coord,)), Set{PipeCoord}()),
            translated_selection = WorldSelectionState(Set((TileCoord(2, 1),)), Set{PipeCoord}()),
            expected_component_sources = Set((coord,)),
            expected_component_destinations = Set((TileCoord(2, 1),)),
            expected_pipe_sources = Set{PipeCoord}(),
            expected_pipe_destinations = Set{PipeCoord}(),
        )
        select_single_component!(is, coord)
        set_placement_state!(is, pending_state)

        @test handle_world_escape!(is)
        @test placement_state(is) === pending_state
        @test selected_component_coords(is) == Set((coord,))
    end

    @testset "shared component actions" begin
        make_shared_action(; enabled, group_enabled = enabled, tooltip = "Ready", confirmation_message = nothing) =
            ActionInfo(
            id = :shared,
            label = "Shared",
            enabled = enabled,
            group_enabled = group_enabled,
            tooltip = tooltip,
            confirmation_message = confirmation_message,
        )

        @testset "all components enabled" begin
            actions = shared_component_actions(
                (
                    (make_shared_action(enabled = true),),
                    (make_shared_action(enabled = true),),
                )
            )
            @test length(actions) == 1
            @test actions[1].enabled
            @test actions[1].group_enabled
            @test actions[1].tooltip == "Ready"
        end

        @testset "group-disabled component blocks action" begin
            actions = shared_component_actions(
                (
                    (make_shared_action(enabled = true),),
                    (make_shared_action(enabled = false, group_enabled = false, tooltip = "Blocked"),),
                )
            )
            @test !actions[1].enabled
            @test !actions[1].group_enabled
            @test actions[1].tooltip == "Unavailable for 1 of 2 selected components."
        end

        @testset "group-enabled disabled component permits action" begin
            actions = shared_component_actions(
                (
                    (make_shared_action(enabled = true),),
                    (make_shared_action(enabled = false, group_enabled = true, tooltip = "Already empty"),),
                )
            )
            @test actions[1].enabled
            @test actions[1].group_enabled
            @test actions[1].tooltip ==
                "Available as a group; enabled individually for 1 of 2 selected components."
        end

        @testset "no selected component currently needs action" begin
            actions = shared_component_actions(
                (
                    (make_shared_action(enabled = false, group_enabled = true),),
                    (make_shared_action(enabled = false, group_enabled = true),),
                )
            )
            @test !actions[1].enabled
            @test !actions[1].group_enabled
            @test actions[1].tooltip ==
                "None of the 2 selected components can currently perform this action."
        end

        @testset "only blocking components count as unavailable" begin
            actions = shared_component_actions(
                (
                    (make_shared_action(enabled = true),),
                    (make_shared_action(enabled = false, group_enabled = true),),
                    (make_shared_action(enabled = false, group_enabled = false),),
                )
            )
            @test !actions[1].enabled
            @test actions[1].tooltip == "Unavailable for 1 of 3 selected components."
        end

        @testset "missing actions remain absent from intersection" begin
            actions = shared_component_actions(
                (
                    (make_shared_action(enabled = true),),
                    (ActionInfo(id = :other, label = "Other", enabled = true, tooltip = "Ready"),),
                )
            )
            @test isempty(actions)
        end

        @testset "confirmation is retained when a later component requires it" begin
            actions = @test_logs (:warn, r"Inconsistent metadata for shared component action") begin
                shared_component_actions(
                    (
                        (make_shared_action(enabled = true),),
                        (make_shared_action(enabled = true, confirmation_message = "Confirm?"),),
                    )
                )
            end
            @test actions[1].confirmation_message == "Confirm?"
        end

        @testset "conflicting confirmations warn and use a deterministic message" begin
            action_sets = (
                (make_shared_action(enabled = true, confirmation_message = "Confirm later"),),
                (make_shared_action(enabled = true, confirmation_message = "Confirm earlier"),),
            )
            actions = @test_logs (:warn, r"Inconsistent metadata for shared component action") begin
                shared_component_actions(action_sets)
            end
            reversed_actions = @test_logs (:warn, r"Inconsistent metadata for shared component action") begin
                shared_component_actions(reverse(action_sets))
            end
            @test actions[1].confirmation_message == "Confirm earlier"
            @test reversed_actions[1].confirmation_message == actions[1].confirmation_message
        end
    end

    @testset "editor transition helpers" begin
        is = make_test_inputstate()
        tile_state = make_tile_state()

        select_single_component!(is, TileCoord(1, 1))
        @test enter_editor_placement_state!(is, tile_state)
        @test placement_state(is) === tile_state
        @test selection_state(is) isa SelectionEmptyState

        toggle_editor_placement_state!(is, make_tile_state())
        @test placement_state(is) isa PlacementReadyState

        toggle_editor_placement_state!(is, PlacementDeleteState())
        @test placement_state(is) isa PlacementDeleteState

        toggle_editor_placement_state!(is, PlacementSurfaceEditState())
        @test placement_state(is) isa PlacementSurfaceEditState

        enter_ready_placement_state!(is)
        @test placement_state(is) isa PlacementReadyState
    end

    @testset "redock transition helper" begin
        is = make_test_inputstate()
        redock_state = make_test_redock_state()

        select_single_component!(is, TileCoord(1, 1))
        @test enter_redock_placement_state!(is, redock_state)
        @test placement_state(is) === redock_state
        @test placement_state(is) isa PlacementRedockState
        @test selection_state(is) isa SelectionEmptyState

        enter_ready_placement_state!(is)
        @test placement_state(is) isa PlacementReadyState
    end

    @testset "pressed-state helper only clears pressed state" begin
        is = make_test_inputstate()
        set_placement_state!(is, make_pressed_state())
        clear_placement_pressed_state!(is)
        @test placement_state(is) isa PlacementReadyState

        move_state = PlacementMoveState(move_target = TileComponentMoveTarget(TileCoord(2, 3)))
        set_placement_state!(is, move_state)
        clear_placement_pressed_state!(is)
        @test placement_state(is) == move_state
    end

    @testset "move and pipe helper predicates" begin
        is = make_test_inputstate()
        @test !(placement_state(is) isa PlacementMoveState)
        @test !(placement_state(is) isa PlacementPipeChainState)

        set_placement_state!(
            is, PlacementMoveState(
                move_target = PipeMoveTarget(
                    PipeCoord(VertexCoord(TileCoord(1, 2), HexFrame.Q_POS), VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG)),
                )
            )
        )
        state = placement_state(is)
        @test state isa PlacementMoveState

        set_placement_state!(is, make_pipe_state())
        state = placement_state(is)
        @test state isa PlacementPipeChainState
        @test is_active_standard_interaction_state(state)

        clear_placement_state!(is)
        @test !(placement_state(is) isa PlacementMoveState)
        @test !(placement_state(is) isa PlacementPipeChainState)

        sources = Set((TileCoord(0, 0), TileCoord(1, 0)))
        target = SelectionMoveTarget(sources, Set{PipeCoord}(), TileCoord(1, 0), TileCoord(1, 0))
        empty!(sources)
        @test target.component_coords == Set((TileCoord(0, 0), TileCoord(1, 0)))
        @test_throws ArgumentError SelectionMoveTarget(
            target.component_coords, Set{PipeCoord}(),
            TileCoord(2, 0), TileCoord(2, 0)
        )

        pipe = PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG))
        pipe_target = SelectionMoveTarget(Set((TileCoord(0, 0),)), Set((pipe,)), pipe, TileCoord(0, 0))
        @test pipe_target.anchor == pipe
        @test_throws ArgumentError SelectionMoveTarget(
            Set((TileCoord(0, 0),)), Set((pipe,)),
            PipeCoord(VertexCoord(TileCoord(1, 0), HexFrame.Q_POS), VertexCoord(TileCoord(1, 0), HexFrame.Q_NEG)),
            TileCoord(1, 0)
        )
    end

end
