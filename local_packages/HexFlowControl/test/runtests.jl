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

make_tile_state(; mirrored = false) = PlacementTileState(pendingcomponent = MockCompBehav(), toolmirrored = mirrored)

function make_test_inputstate()
    return InputState(
        pendingpipebehavior = MockPipeBehav(),
        tile_tool_state = make_tile_state(),
    )
end

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
        move_target_valid = !isnothing(move_target),
    )
end

# ===============================================================
# Tests
# ===============================================================

@testset "HexFlowControl" begin

    @testset "InputState defaults" begin
        is = make_test_inputstate()
        @test placement_state(is) isa PlacementReadyState
        @test selection_state(is) isa SelectionEmptyState
        @test isempty(selected_component_coords(is))
        @test isnothing(primary_selected_component(is))
        @test !hasproperty(is, :rightclick_selectedcoord)
        @test !editor_capabilities_enabled(is)
        @test is.tile_tool_state isa PlacementTileState
        @test is.tile_tool_state.pendingcomponent isa MockCompBehav
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

    @testset "editor capability gate" begin
        is = make_test_inputstate()
        @test !editor_capabilities_enabled(is)
        is.editor_mode = true
        @test editor_capabilities_enabled(is)
    end

    @testset "component-selection helpers" begin
        is = make_test_inputstate()
        first_coord = TileCoord(1, 1)
        second_coord = TileCoord(2, 3)

        select_single_component!(is, first_coord)
        @test selection_state(is) isa ComponentSelectionState
        @test selected_component_coords(is) == Set((first_coord,))
        @test primary_selected_component(is) == first_coord
        @test has_selected_component(is, first_coord)
        @test !has_selected_component(is, second_coord)

        select_single_component!(is, second_coord)
        @test selected_component_coords(is) == Set((second_coord,))
        @test primary_selected_component(is) == second_coord
        @test !has_selected_component(is, first_coord)

        toggle_selected_component!(is, first_coord)
        @test selected_component_coords(is) == Set((first_coord, second_coord))
        @test primary_selected_component(is) == first_coord
        @test selected_component_count(is) == 2

        toggle_selected_component!(is, first_coord)
        @test selected_component_coords(is) == Set((second_coord,))
        @test primary_selected_component(is) == second_coord

        toggle_selected_component!(is, first_coord)
        prune_selected_components!(coord -> coord == first_coord, is)
        @test selected_component_coords(is) == Set((first_coord,))
        @test primary_selected_component(is) == first_coord

        clear_selection!(is)
        @test selection_state(is) isa SelectionEmptyState
        @test isempty(selected_component_coords(is))
        @test isnothing(primary_selected_component(is))
    end

    @testset "world-selection helpers" begin
        is = make_test_inputstate()
        select_single_component!(is, TileCoord(1, 1))
        is.rightclick_selectedship = :test_ship

        clear_world_selection!(is)
        @test selection_state(is) isa SelectionEmptyState
        @test isnothing(is.rightclick_selectedship)
        @test isnothing(is.action_popup)

        set_placement_state!(is, make_pressed_state())
        clear_placement_state!(is)
        @test placement_state(is) isa PlacementReadyState
    end

    @testset "shared component actions" begin
        first_actions = (
            ActionInfo(:first, "First", true, "Ready"),
            ActionInfo(:shared, "Shared", true, "Ready", "Confirm?"),
        )
        second_actions = (
            ActionInfo(:shared, "Shared", false, "Blocked", "Confirm?"),
            ActionInfo(:other, "Other", true, "Ready"),
        )

        actions = shared_component_actions((first_actions, second_actions))
        @test length(actions) == 1
        @test actions[1].id === :shared
        @test !actions[1].enabled
        @test actions[1].tooltip == "Unavailable for 1 of 2 selected components."
        @test actions[1].confirmation_message == "Confirm?"
    end

    @testset "editor transition helpers" begin
        is = make_test_inputstate()
        tile_state = make_tile_state()

        select_single_component!(is, TileCoord(1, 1))
        enter_editor_placement_state!(is, tile_state)
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
        enter_redock_placement_state!(is, redock_state)
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

        set_placement_state!(is, PlacementMoveState(move_target = PipeMoveTarget(
            PipeCoord(VertexCoord(TileCoord(1, 2), HexFrame.Q_POS), VertexCoord(TileCoord(1, 2), HexFrame.Q_NEG)),
        )))
        state = placement_state(is)
        @test state isa PlacementMoveState

        set_placement_state!(is, PlacementPipeChainState(source_node = VertexCoord(TileCoord(0, 0), HexFrame.Q_POS)))
        state = placement_state(is)
        @test state isa PlacementPipeChainState
        @test is_active_standard_interaction_state(state)

        clear_placement_state!(is)
        @test !(placement_state(is) isa PlacementMoveState)
        @test !(placement_state(is) isa PlacementPipeChainState)
    end

    @testset "toolbar and tile tool cache survive state clearing" begin
        is = make_test_inputstate()
        is.toolbar = 7
        cached_tile_state = is.tile_tool_state

        enter_editor_placement_state!(is, cached_tile_state)
        clear_placement_state!(is)

        @test is.toolbar == 7
        @test is.tile_tool_state === cached_tile_state
        @test placement_state(is) isa PlacementReadyState
    end

end
