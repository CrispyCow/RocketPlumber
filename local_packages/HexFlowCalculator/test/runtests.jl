using Test
using HexFlowCalculator
using FlowMap
using HexFrame
using HexFrame: Q_POS
using HexComponentsAPI
using HexFlowControl
using FlowEngine
using HexElements
using HexFlowProcGen
using HexFluids
using StaticArrays
using LinearAlgebra

"Minimal encounter config for tests that only need a SpaceMapState."
const _test_enc_config = EncounterSystemConfig()

"Minimal encounter config for tests that need a valid generated encounter ship."
function make_trigger_test_encounter_config()
    class_config = EncounterClassConfig(
        NoScaling(1.0),
        HullSizeConfig(LinearScaling(2.0, 0.0), LinearScaling(2.0, 0.0)),
        LinearScaling(0.0, 0.0),
        Dict{FluidTags, FuelTagConfig}(
            HexFluids.COLD_GAS => FuelTagConfig(NoScaling(1.0), WeightedComponentSet[]),
        ),
        PipeSpawnOptions[],
    )

    return EncounterSystemConfig(
        n_points = 1,
        encounter_class_configs = Dict(ENCOUNTER_SHIP => class_config),
    )
end

"Minimal encounter point for calculator-thread trigger tests."
function make_trigger_test_encounter_point()
    return EncounterPoint(
        index = 1,
        base_velocity = 100.0,
        position = SVector(500.0, 0.0),
        velocity = SVector(-100.0, 0.0),
        spawn_time = 0.0,
        ship_type_seed = UInt32(0x1234),
        encounter_class = ENCOUNTER_SHIP,
        fuel_tag = HexFluids.COLD_GAS,
        display_name = "Test Vessel",
        richness = 1.0,
    )
end

# ===============================================================
# Mock Implementations
# ===============================================================

"""Minimal mock component for command-processing tests. Implements all mandatory
ComponentBehavior methods so sandbox validation (update_map!/update_mna!) succeeds."""
struct MockCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::MockCompBehav) = ()
HexComponentsAPI.get_tunables(::MockCompBehav) = ()
HexComponentsAPI.set_tunables(::MockCompBehav, ::NTuple{0, Real}) = MockCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::MockCompBehav; kwargs...) = nothing

struct DerivedStateCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::DerivedStateCompBehav) = ()
HexComponentsAPI.get_tunables(::DerivedStateCompBehav) = ()
HexComponentsAPI.set_tunables(::DerivedStateCompBehav, ::NTuple{0, Real}) = DerivedStateCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::DerivedStateCompBehav; kwargs...) = nothing
function HexComponentsAPI.update_flowbehav!(::DerivedStateCompBehav; tile::TileCoord, derivedmapstate::DerivedMapState, kwargs...)
    derivedmapstate.nodeactualfluids[NodeCoord(tile, HexFrame.NODE_INTERNAL)] = HexFluids.COLD_GAS
    return nothing
end

"""Minimal mock pipe for command-processing tests."""
struct MockPipeBehav <: PipeBehavior end
HexComponentsAPI.get_conductance(::MockPipeBehav) = 1.0
HexComponentsAPI.get_pipe_tunables(::MockPipeBehav) = ()
HexComponentsAPI.set_pipe_tunables(::MockPipeBehav, ::NTuple{0, Real}) = MockPipeBehav()
HexComponentsAPI.render_pipe_base!(queue, ::MockPipeBehav; kwargs...) = nothing

#= ---------- Additional Mock for DoActionCommand ----------- =#

# external counter for action execution
const action_count = Ref(0)

mutable struct ActionCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::ActionCompBehav) = ()
HexComponentsAPI.get_tunables(::ActionCompBehav) = ()
HexComponentsAPI.set_tunables(::ActionCompBehav, ::NTuple{0, Real}) = ActionCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::ActionCompBehav; kwargs...) = nothing
import HexComponentsAPI: get_actions, do_action!, placement_valid
function get_actions(comp::ActionCompBehav; kwargs...)
    return (ActionInfo(:flip, "Flip", true, "Flip state"),)
end
function do_action!(comp::ActionCompBehav, action_id::Symbol; kwargs...)
    if action_id === :flip
        action_count[] += 1
        return (true, "Flipped")
    end
    return (false, "Unknown action")
end
function placement_valid(comp::ActionCompBehav, coord::TileCoord, gamemap::GameMap; kwargs...)
    return (true, "")
end

struct RotationSensitiveCompBehav{N} <: ComponentBehavior
    valid_rotations::NTuple{N, HexAxis}
end
HexComponentsAPI.produce_rel_elements(::RotationSensitiveCompBehav) = ()
HexComponentsAPI.get_tunables(::RotationSensitiveCompBehav) = ()
HexComponentsAPI.set_tunables(comp::RotationSensitiveCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::RotationSensitiveCompBehav; kwargs...) = nothing
function placement_valid(comp::RotationSensitiveCompBehav, coord::TileCoord, gamemap::GameMap; rotation::HexAxis, ship_name::Symbol = :primary, kwargs...)
    if !is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return (false, "Not on ship surface")
    end
    if rotation ∉ comp.valid_rotations
        return (false, "Rotation invalid")
    end
    return (true, "")
end

#= ---------- Test Helpers ----------- =#

"No-op console sink — captures nothing"
silent_console(::String) = nothing

"Console sink that captures all messages"
function make_log_console()
    logs = String[]
    push_fn = (msg::String) -> push!(logs, msg)
    return logs, push_fn
end

"Shorthand: process a command and return the log messages"
function process_and_log!(cmd, gamemap)
    logs, console = make_log_console()
    HexFlowCalculator.process_command!(cmd, gamemap, console)
    return logs
end

"Minimal FlowCalculatorIPC for unit tests that call update_manoeuvre_phase! directly."
function make_test_ipc(; shared_state::FlowCalculatorSharedState = FlowCalculatorSharedState())
    return FlowCalculatorIPC(
        shared_state = shared_state,
        command_queue = create_command_queue(),
        publish_snapshot = (args...) -> nothing,
        get_snapshot = () -> FlowCalculatorSnapshot(),
        console_push = silent_console,
        console_see = () -> String[],
    )
end

"Create a two-ship GameMap for multi-ship routing tests.
:primary has surface at (0,0); :asteroid has surface at (20,0)."
function make_two_ship_map()
    primary = ShipMap()
    asteroid = ShipMap()
    offset_ship!(asteroid, TileCoord(20, 0))
    return GameMap(ships = Dict(:primary => primary, :asteroid => asteroid))
end

# ===============================================================
# Tests
# ===============================================================

@testset "HexFlowCalculator Map Edit Commands" begin
    cq = create_command_queue(16)

    #= ---------- SetTileCommand ----------- =#
    @testset "SetTileCommand" begin
        gamemap = GameMap()
        coord = TileCoord(0, 0)  # on :primary surface by default

        cmd = create_set_tile_command(cq, coord, MockCompBehav(), Q_POS)
        logs = process_and_log!(cmd, gamemap)

        @test !isnothing(get_component(gamemap, coord; ship_name = :primary))
    end

    @testset "SetTileCommand — supports derived-state-aware updates" begin
        gamemap = GameMap()
        coord = TileCoord(0, 0)

        logs = process_and_log!(
            create_set_tile_command(cq, coord, DerivedStateCompBehav(), Q_POS),
            gamemap
        )

        @test !isnothing(get_component(gamemap, coord; ship_name = :primary))
        @test !any(contains(log, "Invalid map edit") for log in logs)
    end

    @testset "SetTileCommand — rejects off-surface" begin
        gamemap = GameMap()
        off_surface = TileCoord(10, 10)  # not on any ship surface

        logs = process_and_log!(
            create_set_tile_command(cq, off_surface, MockCompBehav(), Q_POS),
            gamemap
        )

        @test isnothing(get_component(gamemap, off_surface; ship_name = :primary))
    end

    @testset "SetTileCommand — routes to correct ship" begin
        gamemap = make_two_ship_map()
        set_surface_tile!(gamemap, TileCoord(1, 0); ship_name = :asteroid)

        process_and_log!(
            create_set_tile_command(cq, TileCoord(1, 0), MockCompBehav(), Q_POS),
            gamemap
        )

        # Should land on :asteroid (the only ship with that surface tile)
        @test isnothing(get_component(gamemap, TileCoord(1, 0); ship_name = :primary))
        @test !isnothing(get_component(gamemap, TileCoord(1, 0); ship_name = :asteroid))
    end

    #= ---------- SetPipeBehaviorCommand ----------- =#
    @testset "SetPipeBehaviorCommand" begin
        gamemap = GameMap()
        edge = get_edges(TileCoord(0, 0))[1]

        cmd = create_set_pipe_behavior_command(cq, edge, MockPipeBehav())
        process_and_log!(cmd, gamemap)

        @test !isnothing(get_pipe(gamemap, edge; ship_name = :primary))
    end

    #= ---------- MoveCommand{TileCoord} ----------- =#
    @testset "MoveCommand{TileCoord}" begin
        gamemap = GameMap()
        src = TileCoord(0, 0)
        dst = TileCoord(0, 1)
        set_surface_tile!(gamemap, dst; ship_name = :primary)

        # Place a component first
        process_and_log!(
            create_set_tile_command(cq, src, MockCompBehav(), Q_POS),
            gamemap
        )
        @test !isnothing(get_component(gamemap, src; ship_name = :primary))

        # Move it
        cmd = create_move_command(cq, src, dst, Q_POS)
        process_and_log!(cmd, gamemap)

        @test isnothing(get_component(gamemap, src; ship_name = :primary))
        @test !isnothing(get_component(gamemap, dst; ship_name = :primary))
    end

    @testset "MoveCommand{TileCoord} — rejects missing source" begin
        gamemap = GameMap()
        set_surface_tile!(gamemap, TileCoord(0, 1); ship_name = :primary)

        logs = process_and_log!(
            create_move_command(cq, TileCoord(0, 0), TileCoord(0, 1), Q_POS),
            gamemap
        )

        # No component at source — destination should remain empty
        @test isnothing(get_component(gamemap, TileCoord(0, 1); ship_name = :primary))
    end

    @testset "MoveCommand{TileCoord} — rejects invalid in-place rotation" begin
        gamemap = GameMap()
        coord = TileCoord(0, 0)

        process_and_log!(
            create_set_tile_command(cq, coord, RotationSensitiveCompBehav((Q_POS,)), Q_POS),
            gamemap
        )

        logs = process_and_log!(
            create_move_command(cq, coord, coord, HexFrame.R_POS),
            gamemap
        )

        placed = get_component(gamemap, coord; ship_name = :primary)
        @test !isnothing(placed)
        @test placed.rotation == Q_POS
        @test any(contains(l, "Cannot rotate in place") || contains(l, "Rotation invalid") for l in logs)
    end

    @testset "MoveCommand{TileCoord} — allows valid in-place rotation" begin
        gamemap = GameMap()
        coord = TileCoord(0, 0)

        process_and_log!(
            create_set_tile_command(cq, coord, RotationSensitiveCompBehav((Q_POS, HexFrame.R_POS)), Q_POS),
            gamemap
        )

        logs = process_and_log!(
            create_move_command(cq, coord, coord, HexFrame.R_POS),
            gamemap
        )

        placed = get_component(gamemap, coord; ship_name = :primary)
        @test !isnothing(placed)
        @test placed.rotation == HexFrame.R_POS
        @test any(contains(l, "rotated in place") for l in logs)
    end

    #= ---------- MoveCommand{EdgeCoord} ----------- =#
    @testset "MoveCommand{EdgeCoord}" begin
        gamemap = GameMap()
        set_surface_tile!(gamemap, TileCoord(0, 1); ship_name = :primary)

        src_edge = get_edges(TileCoord(0, 0))[1]
        dst_edge = get_edges(TileCoord(0, 1))[1]

        # Place a pipe first
        process_and_log!(
            create_set_pipe_behavior_command(cq, src_edge, MockPipeBehav()),
            gamemap
        )
        @test !isnothing(get_pipe(gamemap, src_edge; ship_name = :primary))

        # Move it
        cmd = create_move_command(cq, src_edge, dst_edge, Q_POS)
        process_and_log!(cmd, gamemap)

        @test isnothing(get_pipe(gamemap, src_edge; ship_name = :primary))
        @test !isnothing(get_pipe(gamemap, dst_edge; ship_name = :primary))
    end

    #= ---------- DeleteAtCommand{TileCoord} ----------- =#
    @testset "DeleteAtCommand{TileCoord}" begin
        gamemap = GameMap()
        coord = TileCoord(0, 0)

        # Place then delete
        process_and_log!(
            create_set_tile_command(cq, coord, MockCompBehav(), Q_POS),
            gamemap
        )
        @test !isnothing(get_component(gamemap, coord; ship_name = :primary))

        cmd = create_delete_command(cq, coord)
        @test cmd isa DeleteAtCommand{TileCoord}

        logs = process_and_log!(cmd, gamemap)
        @test isnothing(get_component(gamemap, coord; ship_name = :primary))
        @test any(contains(l, "deleted") || contains(l, "Deleted") for l in logs)
    end

    #= ---------- DoActionCommand tests ----------- =#

    @testset "DoActionCommand" begin
        gamemap = GameMap()
        coord = TileCoord(0, 0)

        # place the action component
        process_and_log!(create_set_tile_command(cq, coord, ActionCompBehav(), Q_POS), gamemap)
        @test !isnothing(get_component(gamemap, coord; ship_name = :primary))  # ensure placement succeeded
        @test action_count[] == 0

        # sanity check: manual invocation should work
        wrapped = get_component(gamemap, coord; ship_name = :primary)
        do_action!(wrapped, :flip)
        @test action_count[] == 1
        # reset for command test
        action_count[] = 0

        # perform action (sanbox validation + real apply will call the action twice)
        cmd = create_do_action_command(cq, coord, :flip)
        logs = process_and_log!(cmd, gamemap)
        @test action_count[] == 2
        @test !isempty(logs)  # at least some message logged

        # action on nonexistent component should log error and do nothing
        gamemap2 = GameMap()
        logs2 = process_and_log!(create_do_action_command(cq, TileCoord(5, 5), :flip), gamemap2)
        @test any(contains(l, "No component") for l in logs2)
    end

    @testset "DeleteAtCommand{TileCoord} — missing component" begin
        gamemap = GameMap()
        logs = process_and_log!(
            create_delete_command(cq, TileCoord(0, 0)),
            gamemap
        )

        @test any(contains(l, "No component") for l in logs)
    end

    #= ---------- DeleteAtCommand{EdgeCoord} ----------- =#
    @testset "DeleteAtCommand{EdgeCoord}" begin
        gamemap = GameMap()
        edge = get_edges(TileCoord(0, 0))[1]

        # Place then delete
        process_and_log!(
            create_set_pipe_behavior_command(cq, edge, MockPipeBehav()),
            gamemap
        )
        @test !isnothing(get_pipe(gamemap, edge; ship_name = :primary))

        cmd = create_delete_command(cq, edge)
        @test cmd isa DeleteAtCommand{EdgeCoord}

        logs = process_and_log!(cmd, gamemap)
        @test isnothing(get_pipe(gamemap, edge; ship_name = :primary))
        @test any(contains(l, "deleted") || contains(l, "Deleted") for l in logs)
    end

    @testset "DeleteAtCommand{EdgeCoord} — missing pipe" begin
        gamemap = GameMap()
        edge = get_edges(TileCoord(0, 0))[1]

        logs = process_and_log!(
            create_delete_command(cq, edge),
            gamemap
        )

        @test any(contains(l, "No pipe") for l in logs)
    end

    #= ---------- DeleteAtCommand — type parameter correctness ----------- =#
    @testset "DeleteAtCommand type parameter" begin
        cmd_tile = create_delete_command(cq, TileCoord(0, 0))
        cmd_edge = create_delete_command(cq, get_edges(TileCoord(0, 0))[1])

        @test cmd_tile isa DeleteAtCommand{TileCoord}
        @test cmd_edge isa DeleteAtCommand{EdgeCoord}

        # Both are subtypes of MapEditCommand
        @test cmd_tile isa MapEditCommand
        @test cmd_edge isa MapEditCommand
    end

    #= ---------- ClickTileCommand ----------- =#
    @testset "ClickTileCommand" begin
        gamemap = GameMap()
        coord = TileCoord(0, 0)

        # Place a component to click on
        process_and_log!(
            create_set_tile_command(cq, coord, MockCompBehav(), Q_POS),
            gamemap
        )

        cmd = create_click_tile_command(cq, coord, CartesianCoord(0.0, 0.0))
        logs = process_and_log!(cmd, gamemap)

        # MockCompBehav.on_click! does nothing, so no error expected
        @test !any(contains(l, "error") || contains(l, "Error") for l in logs)
    end

    @testset "ClickTileCommand — missing component" begin
        gamemap = GameMap()

        logs = process_and_log!(
            create_click_tile_command(cq, TileCoord(5, 5), CartesianCoord(0.0, 0.0)),
            gamemap
        )

        @test any(contains(l, "No component") || contains(l, "no") for l in logs)
    end

    #= ---------- AddShipSurfaceCommand ----------- =#
    @testset "AddShipSurfaceCommand" begin
        gamemap = GameMap()
        coord = TileCoord(0, 1)  # adjacent to default (0,0) surface

        cmd = create_add_ship_surface_command(cq, coord)
        logs = process_and_log!(cmd, gamemap)

        @test is_on_surface_tile(coord, gamemap; ship_name = :primary)
    end

    #= ---------- RemoveShipSurfaceCommand ----------- =#
    @testset "RemoveShipSurfaceCommand" begin
        gamemap = GameMap()
        coord = TileCoord(0, 1)

        # Add then remove
        process_and_log!(create_add_ship_surface_command(cq, coord), gamemap)
        @test is_on_surface_tile(coord, gamemap; ship_name = :primary)

        logs = process_and_log!(
            create_remove_ship_surface_command(cq, coord),
            gamemap
        )

        @test !is_on_surface_tile(coord, gamemap; ship_name = :primary)
    end

    #= ---------- MapOverrideCommand ----------- =#
    @testset "MapOverrideCommand" begin
        gamemap = GameMap()
        new_map = make_two_ship_map()

        cmd = create_map_override_command(cq, new_map)
        process_and_log!(cmd, gamemap)

        # After override, gamemap should have the :asteroid ship
        @test haskey(gamemap.ships, :asteroid)
    end

    #= ---------- Multi-Ship Routing ----------- =#
    @testset "Multi-ship command routing" begin
        gamemap = make_two_ship_map()

        # Place component on :asteroid's surface tile
        set_surface_tile!(gamemap, TileCoord(1, 0); ship_name = :asteroid)
        process_and_log!(
            create_set_tile_command(cq, TileCoord(1, 0), MockCompBehav(), Q_POS),
            gamemap
        )

        @test isnothing(get_component(gamemap, TileCoord(1, 0); ship_name = :primary))
        @test !isnothing(get_component(gamemap, TileCoord(1, 0); ship_name = :asteroid))

        # Move within :asteroid
        set_surface_tile!(gamemap, TileCoord(2, 0); ship_name = :asteroid)
        process_and_log!(
            create_move_command(cq, TileCoord(1, 0), TileCoord(2, 0), Q_POS),
            gamemap
        )

        @test isnothing(get_component(gamemap, TileCoord(1, 0); ship_name = :asteroid))
        @test !isnothing(get_component(gamemap, TileCoord(2, 0); ship_name = :asteroid))

        # Delete from :asteroid
        process_and_log!(
            create_delete_command(cq, TileCoord(2, 0)),
            gamemap
        )

        @test isnothing(get_component(gamemap, TileCoord(2, 0); ship_name = :asteroid))
    end

    #= ---------- Command ID Generation ----------- =#
    @testset "Command IDs are sequential" begin
        c1 = create_delete_command(cq, TileCoord(0, 0))
        c2 = create_delete_command(cq, TileCoord(0, 0))
        c3 = create_set_tile_command(cq, TileCoord(0, 0), MockCompBehav(), Q_POS)

        @test c2.id == c1.id + 1
        @test c3.id == c2.id + 1
    end
end

# ===============================================================
# Tests — _spacemap_to_ship
# ===============================================================

@testset "_spacemap_to_ship" begin
    # +X stays as +X
    result = HexFlowCalculator._spacemap_to_ship(SVector(10.0, 0.0))
    @test result ≈ SVector(10.0, 0.0)

    # +Y: magnitude preserved, rotated to +X
    result2 = HexFlowCalculator._spacemap_to_ship(SVector(0.0, 5.0))
    @test result2 ≈ SVector(5.0, 0.0)

    # Diagonal: magnitude = 5
    result3 = HexFlowCalculator._spacemap_to_ship(SVector(3.0, 4.0))
    @test result3 ≈ SVector(5.0, 0.0)

    # Near-zero → zero
    result4 = HexFlowCalculator._spacemap_to_ship(SVector(1.0e-12, 0.0))
    @test result4 ≈ SVector(0.0, 0.0)

    # Negative dv — magnitude still positive
    result5 = HexFlowCalculator._spacemap_to_ship(SVector(-10.0, 0.0))
    @test result5 ≈ SVector(10.0, 0.0)

    # Exact zero
    result6 = HexFlowCalculator._spacemap_to_ship(SVector(0.0, 0.0))
    @test result6 ≈ SVector(0.0, 0.0)
end

# ===============================================================
# Tests — Snapshot Storage
# ===============================================================

@testset "create_snapshot_storage — triple buffer" begin
    snap = FlowCalculatorSnapshot(timestamp = 1.0)
    publish_snap, get_snap = create_snapshot_storage(snap)

    # Get returns seeded snapshot
    result = get_snap()
    @test result.timestamp == 1.0
    @test result.gamemap isa GameMap
    @test result.gamestate isa GameState
    @test result.mna isa MNA_StateSnapshot

    # Publish overwrites via raw state objects
    publish_snap(GameMap(), DerivedMapState(), MNA_State(), GameState(), 42.0)
    result2 = get_snap()
    @test result2.timestamp == 42.0

    # Multiple publishes — last write wins
    publish_snap(GameMap(), DerivedMapState(), MNA_State(), GameState(), 100.0)
    publish_snap(GameMap(), DerivedMapState(), MNA_State(), GameState(), 200.0)
    @test get_snap().timestamp == 200.0
end

@testset "snapshot! methods" begin
    # DerivedMapState refill
    src_derived = DerivedMapState()
    push!(src_derived.allelements, AbsoluteElement(
        connections = AbsoluteElementConnections(NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS), NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_NEG)),
        value = 1.0,
        type = HexElements.CONST_RESISTOR,
        id = ElementID(TileCoord(0, 0), 1),
    ))
    src_derived.nodeactualfluids[NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)] = HexFluids.COLD_GAS

    dest_derived = DerivedMapState()
    HexFlowCalculator.snapshot!(dest_derived, src_derived)
    @test length(dest_derived.allelements) == 1
    @test length(dest_derived.nodeactualfluids) == 1

    # Refill again with empty — should clear
    HexFlowCalculator.snapshot!(dest_derived, DerivedMapState())
    @test isempty(dest_derived.allelements)
    @test isempty(dest_derived.nodeactualfluids)

    # MNA_StateSnapshot refill from MNA_State
    src_mna = MNA_State()
    src_mna.node_voltages[NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)] = 5.0
    src_mna.vsource_currents[ElementID(TileCoord(0, 0), 1)] = 0.1

    dest_mna = MNA_StateSnapshot()
    HexFlowCalculator.snapshot!(dest_mna, src_mna)
    @test dest_mna.node_voltages[NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)] == 5.0
    @test dest_mna.vsource_currents[ElementID(TileCoord(0, 0), 1)] == 0.1

    # GameState refill
    src_gs = GameState(ticks = 42)
    dest_gs = GameState()
    HexFlowCalculator.snapshot!(dest_gs, src_gs)
    @test dest_gs.ticks == 42
end

# ===============================================================
# Tests — Console Buffer
# ===============================================================

@testset "create_threadsafe_consolebuffer" begin
    push_msg, see_msgs = create_threadsafe_consolebuffer(5)

    # Initially empty
    @test isempty(see_msgs())

    # Push and see
    push_msg("hello")
    msgs = see_msgs()
    @test length(msgs) == 1
    @test contains(msgs[1], "hello")

    # Messages get timestamped
    @test contains(msgs[1], ":")  # timestamp format HH:MM:SS contains colons

    # Ring buffer wraps at capacity
    for i in 1:10
        push_msg("msg $i")
    end
    msgs2 = see_msgs()
    @test length(msgs2) == 5  # buffer capacity is 5

    # see_messages returns a copy — mutating it doesn't affect buffer
    msgs3 = see_msgs()
    empty!(msgs3)
    @test length(see_msgs()) == 5
end

@testset "create_threadsafe_consolebuffer — invalid length" begin
    @test_throws Exception create_threadsafe_consolebuffer(0)
end

# ===============================================================
# Tests — FlowCalculatorSharedState
# ===============================================================

@testset "FlowCalculatorSharedState — defaults" begin
    ss = FlowCalculatorSharedState()

    @test (@atomic ss.should_exit) == false
    @test (@atomic ss.is_paused) == false
    @test (@atomic ss.target_ups) == BASE_UPS
    @test (@atomic ss.actual_ups) == 0.0
    @test (@atomic ss.target_spacemap_time) == 0.0
    @test get_max_reachable_bounds(ss) == (X_POS = 5.0, X_NEG = -5.0, Y_POS = 5.0, Y_NEG = -5.0)
end

@testset "FlowCalculatorSharedState — atomic operations" begin
    ss = FlowCalculatorSharedState()

    @atomic ss.should_exit = true
    @test (@atomic ss.should_exit) == true

    @atomic ss.is_paused = true
    @test (@atomic ss.is_paused) == true

    @atomic ss.target_ups = 120.0
    @test (@atomic ss.target_ups) == 120.0

    @atomic ss.actual_ups = 59.5
    @test (@atomic ss.actual_ups) == 59.5

    @atomic ss.target_spacemap_time = 42.0
    @test (@atomic ss.target_spacemap_time) == 42.0
end

@testset "FlowCalculatorSharedState — bounds accessors" begin
    ss = FlowCalculatorSharedState()
    bounds = (X_POS = 12.0, X_NEG = -8.0, Y_POS = 7.5, Y_NEG = -3.5)

    set_max_reachable_bounds!(ss, bounds)

    @test get_max_reachable_bounds(ss) == bounds
end

@testset "FlowCalculatorSharedState — keyword constructor" begin
    ss = FlowCalculatorSharedState(target_ups = 30.0, is_paused = true, view_bounds_x_pos = 12.0)
    @test (@atomic ss.target_ups) == 30.0
    @test (@atomic ss.is_paused) == true
    @test (@atomic ss.should_exit) == false  # default
    @test (@atomic ss.target_spacemap_time) == 0.0  # default
    @test (@atomic ss.view_bounds_x_pos) == 12.0
end

# ===============================================================
# Tests — TimingState
# ===============================================================

@testset "TimingState — defaults" begin
    t = TimingState()

    @test t.current_time > 0.0        # initialised to time()
    @test t.last_loop_time > 0.0
    @test t.delta_time == 0.0
    @test t.accumulator == 0.0
    @test t.should_update == false
    @test t.last_update_time > 0.0
end

@testset "accumulate_time! — basic" begin
    t = TimingState()
    # Simulate 100ms elapsed by backdating last_loop_time
    t.last_loop_time = time() - 0.1

    target_update_time = 1.0 / BASE_UPS  # ~16.67ms
    HexFlowCalculator.accumulate_time!(t, target_update_time)

    @test t.delta_time >= 0.05            # at least ~50ms with tolerance
    @test t.accumulator >= 0.05
    @test t.should_update == true         # 100ms >> 16.67ms target
end

@testset "accumulate_time! — immediate call" begin
    t = TimingState()
    target_update_time = 1.0 / BASE_UPS

    # Called immediately — delta_time should be tiny
    HexFlowCalculator.accumulate_time!(t, target_update_time)
    @test t.delta_time < 0.01             # practically zero
end

@testset "accumulate_time! — accumulator saturation" begin
    t = TimingState()
    target_update_time = 1.0 / BASE_UPS

    # Simulate a very large elapsed time (1 second)
    t.last_loop_time = time() - 1.0
    HexFlowCalculator.accumulate_time!(t, target_update_time)

    # Accumulator should be clamped to target_update_time * 10
    max_accumulator = target_update_time * 10.0
    @test t.accumulator <= max_accumulator + 0.001  # small tolerance
end

# ===============================================================
# Tests — Command Queue
# ===============================================================

@testset "try_enqueue_command!" begin
    cq = create_command_queue(4)
    cmd = create_delete_command(cq, TileCoord(0, 0))

    success, status = try_enqueue_command!(cq, cmd, silent_console)
    @test success == true
    @test status == APPLIED
end

@testset "CommandQueue — last_command tracking" begin
    cq = create_command_queue(4)
    cmd1 = create_delete_command(cq, TileCoord(0, 0))
    cmd2 = create_set_tile_command(cq, TileCoord(0, 0), MockCompBehav(), Q_POS)

    try_enqueue_command!(cq, cmd1, silent_console)
    @test cq.last_command === cmd1

    try_enqueue_command!(cq, cmd2, silent_console)
    @test cq.last_command === cmd2
end

# ===============================================================
# Tests — scale_voltage_dict!
# ===============================================================

@testset "scale_voltage_dict! — empty" begin
    out = Dict{NodeCoord, Float64}()
    scale_voltage_dict!(out, Dict{NodeCoord, Float64}())
    @test isempty(out)
end

@testset "scale_voltage_dict! — single entry" begin
    nc = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    out = Dict{NodeCoord, Float64}()
    scale_voltage_dict!(out, Dict(nc => 10.0))
    @test haskey(out, nc)
    @test out[nc] <= 1.0 + 1.0e-10  # scaled to at most 1.0
    @test out[nc] > 0.0
end

@testset "scale_voltage_dict! — relative ordering preserved" begin
    nc1 = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    nc2 = NodeCoord(TileCoord(1, 0), HexFrame.NODE_Q_POS)

    out = Dict{NodeCoord, Float64}()
    scale_voltage_dict!(out, Dict(nc1 => 100.0, nc2 => 50.0))
    @test out[nc1] > out[nc2]  # higher voltage → higher scaled value
end

# ===============================================================
# Tests — handle_thrusters!
# ===============================================================

@testset "handle_thrusters! — empty map" begin
    gs = GameState()
    gm = GameMap()
    derived = DerivedMapState()
    mna = MNA_State()

    handle_thrusters!(gs, gm, derived, mna)

    # No components → no thrust
    @test gs.thrust ≈ SVector(0.0, 0.0)
    @test gs.acceleration_ship_frame ≈ SVector(0.0, 0.0)
    @test gs.acceleration_space_map_frame ≈ SVector(0.0, 0.0)
end

@testset "handle_thrusters! — velocity unchanged with no thrust" begin
    gs = GameState()
    gm = GameMap()
    derived = DerivedMapState()
    mna = MNA_State()

    set_velocity!(gm, SVector(100.0, 50.0))
    initial_vel = get_velocity(gm)

    handle_thrusters!(gs, gm, derived, mna)

    # With no thrust, velocity should remain unchanged
    @test get_velocity(gm) ≈ initial_vel
end

@testset "handle_thrusters! — sets acceleration per-second" begin
    gs = GameState()
    gm = GameMap()
    derived = DerivedMapState()
    mna = MNA_State()

    # base_ups defaults to BASE_UPS, acceleration is stored in per-second units (F/m)
    handle_thrusters!(gs, gm, derived, mna; base_ups = BASE_UPS)
    @test gs.acceleration_ship_frame ≈ SVector(0.0, 0.0)  # zero thrust → zero accel
    @test gs.acceleration_space_map_frame ≈ SVector(0.0, 0.0)
end

# ===============================================================
# Tests — Manoeuvre Guard Helpers
# ===============================================================

@testset "cancel_if_thrust! — zero thrust" begin
    gm = GameMap()
    gs = GameState()
    gs.thrust = SVector(0.0, 0.0)

    # Below threshold → no cancellation
    @test HexFlowCalculator.cancel_if_thrust!(gm, gs) == false
end

@testset "cancel_if_thrust! — above threshold cancels" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    gs = GameState()
    gs.thrust = SVector(10.0, 0.0)  # well above MANOEUVRE_THRUST_THRESHOLD (0.1)

    @test HexFlowCalculator.cancel_if_thrust!(gm, gs) == true
    @test !has_active_manoeuvre(gm)
end

@testset "cancel_if_thrust! — at threshold" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    gs = GameState()
    gs.thrust = SVector(MANOEUVRE_THRUST_THRESHOLD, 0.0)  # exactly at threshold

    @test HexFlowCalculator.cancel_if_thrust!(gm, gs) == false  # <= threshold → no cancel
    @test has_active_manoeuvre(gm)
end

@testset "cancel_if_time_progressing! — SpaceMapEmpty" begin
    gm = GameMap()  # default SpaceMapEmpty

    # SpaceMapEmpty → not a SpaceMapState → returns false
    @test HexFlowCalculator.cancel_if_time_progressing!(gm) == false
end

@testset "cancel_if_time_progressing! — time not progressing" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_time_years!(gm, 5.0)
    set_target_time!(gm, 3.0)  # target behind current → not progressing

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.cancel_if_time_progressing!(gm) == false
    @test has_active_manoeuvre(gm)  # NOT cancelled
end

@testset "cancel_if_time_progressing! — time progressing cancels" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_time_years!(gm, 5.0)
    set_target_time!(gm, 10.0)  # target ahead → progressing

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.cancel_if_time_progressing!(gm) == true
    @test !has_active_manoeuvre(gm)
end

@testset "cancel_if_time_wrong! — time matches" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_time_years!(gm, 5.0)

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.cancel_if_time_wrong!(gm, 5.0) == false
    @test has_active_manoeuvre(gm)
end

# ===============================================================
# Tests — RedockShipCommand
# ===============================================================

@testset "RedockShipCommand" begin
    cq = create_command_queue(16)

    @testset "valid redock moves ship and starts animation" begin
        gm = GameMap()
        sec = ShipMap()
        offset_ship!(sec, TileCoord(10, 0))
        sec.docking_status = FlowMap.ConnectedDockStat()
        add_ship!(gm, :asteroid, sec)

        delta = TileCoord(-3, 0)
        cmd = create_redock_ship_command(cq, :asteroid, delta)
        logs = process_and_log!(cmd, gm)

        # Ship should now be offset by delta (originally at 10,0 → 7,0)
        new_tiles = get_all_surface_tiles(get_ship(gm, :asteroid))
        @test TileCoord(7, 0) in new_tiles

        # Should be in approaching state (animating)
        status = FlowMap.get_docking_status(gm, :asteroid)
        @test status isa FlowMap.ApproachingDockStat
    end

    @testset "rejects placement too close to another ship" begin
        gm = GameMap()
        sec = ShipMap()
        offset_ship!(sec, TileCoord(5, 0))
        sec.docking_status = FlowMap.ConnectedDockStat()
        add_ship!(gm, :asteroid, sec)

        # Try to move directly on top of primary ship at (0,0)
        delta = TileCoord(-5, 0)
        cmd = create_redock_ship_command(cq, :asteroid, delta)

        # Should not mutate the map (rejected via console message)
        original_tiles = copy(get_all_surface_tiles(get_ship(gm, :asteroid)))
        process_and_log!(cmd, gm)
        @test get_all_surface_tiles(get_ship(gm, :asteroid)) == original_tiles
    end

    @testset "rejects redock of nonexistent ship" begin
        gm = GameMap()
        delta = TileCoord(1, 0)
        cmd = create_redock_ship_command(cq, :nonexistent, delta)
        @test_throws Exception process_and_log!(cmd, gm)
    end

    @testset "animation completes after redock" begin
        gm = GameMap()
        sec = ShipMap()
        offset_ship!(sec, TileCoord(10, 0))
        sec.docking_status = FlowMap.ConnectedDockStat()
        add_ship!(gm, :asteroid, sec)

        delta = TileCoord(-3, 0)
        cmd = create_redock_ship_command(cq, :asteroid, delta)
        process_and_log!(cmd, gm)

        # Animate to completion
        for _ in 1:5000
            FlowMap.update_docking!(gm; ship_name = :asteroid)
            s = FlowMap.get_docking_status(gm, :asteroid)
            s isa FlowMap.ConnectedDockStat && break
        end

        final_status = FlowMap.get_docking_status(gm, :asteroid)
        @test final_status isa FlowMap.ConnectedDockStat
    end
end

@testset "cancel_if_time_wrong! — time mismatch cancels" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_time_years!(gm, 5.0)

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.cancel_if_time_wrong!(gm, 10.0) == true
    @test !has_active_manoeuvre(gm)
end

@testset "cancel_if_time_wrong! — within tolerance" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_time_years!(gm, 5.0)

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    # 5.005 is within default tolerance of 0.01
    @test HexFlowCalculator.cancel_if_time_wrong!(gm, 5.005) == false
    @test has_active_manoeuvre(gm)
end

@testset "cancel_if_target_time_past! — waypoint ahead" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_target_time!(gm, 5.0)

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    # Waypoint at 10.0, target time at 5.0 → target not past waypoint
    @test HexFlowCalculator.cancel_if_target_time_past!(gm, 10.0) == false
    @test has_active_manoeuvre(gm)
end

@testset "cancel_if_target_time_past! — waypoint behind cancels" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)
    set_target_time!(gm, 5.0)

    man = ManoeuvreData(approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    # Waypoint at 3.0, target time at 5.0 → target has passed waypoint
    @test HexFlowCalculator.cancel_if_target_time_past!(gm, 3.0) == true
    @test !has_active_manoeuvre(gm)
end

@testset "cancel_if_target_time_past! — SpaceMapEmpty" begin
    gm = GameMap()  # default SpaceMapEmpty
    @test HexFlowCalculator.cancel_if_target_time_past!(gm, 5.0) == false
end

# ===============================================================
# Tests — update_manoeuvre_phase! (smoke tests)
# ===============================================================

@testset "update_manoeuvre_phase! — no manoeuvre is no-op" begin
    gs = GameState()
    gm = GameMap()
    ipc = make_test_ipc()

    # Should not error when no manoeuvre is active
    @test HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc) === nothing
end

@testset "update_manoeuvre_phase! — SpaceMapEmpty is no-op" begin
    gs = GameState()
    gm = GameMap()  # SpaceMapEmpty
    ipc = make_test_ipc()

    @test HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc) === nothing
end

@testset "update_manoeuvre_phase! — APPROACH_BURN respects preloaded burn state" begin
    gs = GameState()
    gm = GameMap()
    ipc = make_test_ipc()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)

    # Add a dummy encounter point so the encounter index lookup succeeds
    ep = EncounterPoint(
        index = 1, base_velocity = 100.0,
        position = SVector(500.0, 0.0), velocity = SVector(-100.0, 0.0), spawn_time = 0.0
    )
    push!(get_encounter_points(gm), ep)

    man = ManoeuvreData(
        approach_burn_dv = SVector(10.0, 0.0),
        capture_burn_dv = SVector(-10.0, 0.0),
        burn_target_dv = SVector(10.0, 0.0),
        burn_remaining_dv = SVector(10.0, 0.0),
        approach_burn_time = 0.0,
        intercept_time = 10.0,
        target_encounter_index = 1,
    )
    set_active_manoeuvre!(gm, man)

    set_time_years!(gm, 0.0)
    set_target_time!(gm, 0.0)  # target behind current → not progressing
    gs.thrust = SVector(0.0, 0.0)  # no thrust

    HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc)

    @test has_active_manoeuvre(gm)
    updated_man = get_active_manoeuvre(gm)
    @test updated_man.phase == PHASE_APPROACH_BURN
    @test updated_man.burn_remaining_dv ≈ SVector(10.0, 0.0)
    @test updated_man.burn_target_dv ≈ SVector(10.0, 0.0)
end

@testset "update_manoeuvre_phase! — ENCOUNTER_READY with thrust cancels" begin
    gs = GameState()
    gm = GameMap()
    ipc = make_test_ipc()
    initialise_spacemap!(gm, UInt32(1), _test_enc_config)

    man = ManoeuvreData(
        approach_burn_dv = SVector(1.0, 0.0),
        capture_burn_dv = SVector(-1.0, 0.0),
    )
    man.phase = PHASE_ENCOUNTER_READY
    set_active_manoeuvre!(gm, man)

    # Thrust above threshold → cancel
    gs.thrust = SVector(5.0, 0.0)
    HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc)

    @test !has_active_manoeuvre(gm)
end

@testset "update_manoeuvre_phase! — CAPTURE_BURN completion triggers encounter" begin
    gs = GameState()
    gm = GameMap()
    ipc = make_test_ipc()
    initialise_spacemap!(gm, UInt32(42), make_trigger_test_encounter_config())
    set_surface_tile!(gm, TileCoord(0, 0))
    push!(get_encounter_points(gm), make_trigger_test_encounter_point())
    set_time_years!(gm, 5.0)
    set_target_time!(gm, 5.0)

    man = ManoeuvreData(
        approach_burn_dv = SVector(1.0, 0.0),
        capture_burn_dv = SVector(-1.0, 0.0),
        target_encounter_index = 1,
    )
    man.phase = PHASE_CAPTURE_BURN
    man.burn_target_dv = SVector(0.0, 0.0)
    man.burn_remaining_dv = SVector(0.0, 0.0)
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc) === nothing

    @test !has_active_manoeuvre(gm)

    # Encounter is now enqueued — drain the command queue to apply it
    while isready(ipc.command_queue.command_channel)
        cmd = take!(ipc.command_queue.command_channel)
        HexFlowCalculator.process_command!(cmd, gm, silent_console, throw_errors = true)
    end
    @test any(ship_name -> ship_name != :primary, get_all_ship_names(gm))
end

@testset "update_manoeuvre_phase! — ENCOUNTER_READY triggers encounter even with future target time" begin
    gs = GameState()
    gm = GameMap()
    ipc = make_test_ipc()
    initialise_spacemap!(gm, UInt32(42), make_trigger_test_encounter_config())
    set_surface_tile!(gm, TileCoord(0, 0))
    push!(get_encounter_points(gm), make_trigger_test_encounter_point())
    set_time_years!(gm, 5.0)
    set_target_time!(gm, 10.0)

    man = ManoeuvreData(
        approach_burn_dv = SVector(1.0, 0.0),
        capture_burn_dv = SVector(-1.0, 0.0),
        target_encounter_index = 1,
    )
    man.phase = PHASE_ENCOUNTER_READY
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.update_manoeuvre_phase!(gs, gm, ipc) === nothing

    @test !has_active_manoeuvre(gm)

    # Encounter is now enqueued — drain the command queue to apply it
    while isready(ipc.command_queue.command_channel)
        cmd = take!(ipc.command_queue.command_channel)
        HexFlowCalculator.process_command!(cmd, gm, silent_console, throw_errors = true)
    end
    @test any(ship_name -> ship_name != :primary, get_all_ship_names(gm))
end

# ===============================================================
# Tests — replace_by_mutation!
# ===============================================================

@testset "replace_by_mutation!" begin
    src = GameMap()
    set_surface_tile!(src, TileCoord(5, 5))
    set_component!(src, TileCoord(0, 0), ComponentOnTile(MockCompBehav(), Q_POS))

    dest = GameMap()
    @test !is_on_surface_tile(TileCoord(5, 5), dest)

    HexFlowCalculator.replace_by_mutation!(dest, src)

    # dest should now have src's data
    @test is_on_surface_tile(TileCoord(5, 5), dest)
    @test has_component(dest, TileCoord(0, 0))
end

# ===============================================================
# Tests — CommandStatus enum
# ===============================================================

@testset "CommandStatus enum" begin
    @test APPLIED isa CommandStatus
    @test REJECTED isa CommandStatus
    @test QUEUED_FAILED isa CommandStatus
end

# ===============================================================
# Tests — Manoeuvre constants
# ===============================================================

@testset "Manoeuvre constants" begin
    @test MANOEUVRE_THRUST_THRESHOLD > 0.0
    @test MANOEUVRE_COMPLETION_THRESHOLD > 0.0
    @test MANOEUVRE_THRUST_THRESHOLD == 0.1
    @test MANOEUVRE_COMPLETION_THRESHOLD == 0.05
end
