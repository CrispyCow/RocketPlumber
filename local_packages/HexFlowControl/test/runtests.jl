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
        ship_nodes = Set{NodeCoord}(),
        other_ship_tiles = Set{TileCoord}(),
        other_ship_nodes = Set{NodeCoord}(),
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

    @testset "world-selection helpers" begin
        is = make_test_inputstate()
        is.rightclick_selectedcoord = TileCoord(1, 1)
        is.rightclick_selectedship = :test_ship

        clear_world_selection!(is)
        @test isnothing(is.rightclick_selectedcoord)
        @test isnothing(is.rightclick_selectedship)
        @test isnothing(is.action_popup)

        set_placement_state!(is, make_pressed_state())
        clear_placement_state!(is)
        @test placement_state(is) isa PlacementReadyState
    end

    @testset "editor transition helpers" begin
        is = make_test_inputstate()
        tile_state = make_tile_state()

        enter_editor_placement_state!(is, tile_state)
        @test placement_state(is) === tile_state

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

        enter_redock_placement_state!(is, redock_state)
        @test placement_state(is) === redock_state
        @test placement_state(is) isa PlacementRedockState

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

        set_placement_state!(is, PlacementMoveState(move_target = TilePipeMoveTarget(TileCoord(1, 2), HexFrame.Q_POS)))
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