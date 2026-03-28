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

function make_test_inputstate()
    return InputState(
        pendingcomponent = MockCompBehav(),
        pendingpipebehavior = MockPipeBehav(),
    )
end

# ===============================================================
# Tests
# ===============================================================

@testset "HexFlowControl" begin

    @testset "PlacementModes enum" begin
        @test INSPECT isa PlacementModes
        @test MOVE isa PlacementModes
        @test PIPE isa PlacementModes
        @test DELETE isa PlacementModes
        @test TILE isa PlacementModes
        @test SURFACE_EDIT isa PlacementModes
        @test REDOCK isa PlacementModes
    end

    @testset "set_placementmode! basic transitions" begin
        is = make_test_inputstate()
        @test is.placementmode == INSPECT

        set_placementmode!(is, MOVE)
        @test is.placementmode == MOVE

        set_placementmode!(is, PIPE)
        @test is.placementmode == PIPE

        set_placementmode!(is, REDOCK)
        @test is.placementmode == REDOCK
    end

    @testset "set_placementmode! clears state on transition" begin
        is = make_test_inputstate()
        is.selectedcoord = TileCoord(1, 2)
        is.action_popup = nothing  # already nothing, just verifying the pattern

        set_placementmode!(is, MOVE)
        @test is.selectedcoord === nothing
        @test is.action_popup === nothing
        @test is.redock_state === nothing
    end

    @testset "set_placementmode! clears redock_state on mode change" begin
        is = make_test_inputstate()

        # Simulate entering redock mode
        set_placementmode!(is, REDOCK)
        is.redock_state = RedockModeState(
            ship_name = :test_ship,
            ship_tiles = Set{TileCoord}(),
            exclusion_ring = Set{TileCoord}(),
            ship_nodes = Set{NodeCoord}(),
            other_ship_tiles = Set{TileCoord}(),
            other_ship_nodes = Set{NodeCoord}(),
            original_centre = TileCoord(0, 0),
        )
        @test is.placementmode == REDOCK
        @test !isnothing(is.redock_state)

        # Switching to ANY mode should clear redock_state
        set_placementmode!(is, INSPECT)
        @test is.placementmode == INSPECT
        @test is.redock_state === nothing
    end

    @testset "set_placementmode! no-op when same mode" begin
        is = make_test_inputstate()
        is.selectedcoord = TileCoord(3, 4)

        # Same mode should be a no-op — selectedcoord preserved
        set_placementmode!(is, INSPECT)
        @test is.selectedcoord == TileCoord(3, 4)
    end

    @testset "set_placementmode! REDOCK to REDOCK is no-op" begin
        is = make_test_inputstate()
        set_placementmode!(is, REDOCK)
        is.redock_state = RedockModeState(
            ship_name = :ship_a,
            ship_tiles = Set{TileCoord}(),
            exclusion_ring = Set{TileCoord}(),
            ship_nodes = Set{NodeCoord}(),
            other_ship_tiles = Set{TileCoord}(),
            other_ship_nodes = Set{NodeCoord}(),
            original_centre = TileCoord(0, 0),
        )

        # Same mode (REDOCK → REDOCK) should be a no-op — redock_state preserved
        set_placementmode!(is, REDOCK)
        @test !isnothing(is.redock_state)
        @test is.redock_state.ship_name === :ship_a
    end

    @testset "REDOCK exits cleanly via number key path" begin
        # Simulates: user is in REDOCK, presses key 1 → set_placementmode!(is, INSPECT)
        is = make_test_inputstate()
        set_placementmode!(is, REDOCK)
        is.redock_state = RedockModeState(
            ship_name = :test_ship,
            ship_tiles = Set{TileCoord}(),
            exclusion_ring = Set{TileCoord}(),
            ship_nodes = Set{NodeCoord}(),
            other_ship_tiles = Set{TileCoord}(),
            other_ship_nodes = Set{NodeCoord}(),
            original_centre = TileCoord(0, 0),
        )

        # Pressing key 1 calls set_placementmode!(is, INSPECT)
        set_placementmode!(is, INSPECT)
        @test is.placementmode == INSPECT
        @test is.redock_state === nothing
    end

end
