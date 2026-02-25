using Test
using HexFlowCalculator
using FlowMap
using HexFrame
using HexFrame: Q_POS
using HexComponentsAPI
using HexFlowControl
using FlowEngine
using StaticArrays
using LinearAlgebra

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

"""Minimal mock pipe for command-processing tests."""
struct MockPipeBehav <: PipeBehavior end
HexComponentsAPI.get_conductance(::MockPipeBehav) = 1.0
HexComponentsAPI.get_pipe_tunables(::MockPipeBehav) = ()
HexComponentsAPI.set_pipe_tunables(::MockPipeBehav, ::NTuple{0, Real}) = MockPipeBehav()
HexComponentsAPI.render_pipe_base!(queue, ::MockPipeBehav; kwargs...) = nothing

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
    result4 = HexFlowCalculator._spacemap_to_ship(SVector(1e-12, 0.0))
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

@testset "create_snapshot_storage" begin
    snap = FlowCalculatorSnapshot(timestamp = 1.0)
    set_snap, get_snap = create_snapshot_storage(snap)

    # Get returns initial snapshot
    result = get_snap()
    @test result.timestamp == 1.0
    @test result.gamemap isa GameMap
    @test result.gamestate isa GameState

    # Set overwrites
    snap2 = FlowCalculatorSnapshot(timestamp = 42.0)
    set_snap(snap2)
    result2 = get_snap()
    @test result2.timestamp == 42.0

    # Multiple sets — last write wins
    set_snap(FlowCalculatorSnapshot(timestamp = 100.0))
    set_snap(FlowCalculatorSnapshot(timestamp = 200.0))
    @test get_snap().timestamp == 200.0
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
    @test (@atomic ss.target_ups) == 60.0
    @test (@atomic ss.actual_ups) == 0.0
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
end

@testset "FlowCalculatorSharedState — keyword constructor" begin
    ss = FlowCalculatorSharedState(target_ups = 30.0, is_paused = true)
    @test (@atomic ss.target_ups) == 30.0
    @test (@atomic ss.is_paused) == true
    @test (@atomic ss.should_exit) == false  # default
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

    target_update_time = 1.0 / 60.0  # ~16.67ms
    HexFlowCalculator.accumulate_time!(t, target_update_time)

    @test t.delta_time >= 0.05            # at least ~50ms with tolerance
    @test t.accumulator >= 0.05
    @test t.should_update == true         # 100ms >> 16.67ms target
end

@testset "accumulate_time! — immediate call" begin
    t = TimingState()
    target_update_time = 1.0 / 60.0

    # Called immediately — delta_time should be tiny
    HexFlowCalculator.accumulate_time!(t, target_update_time)
    @test t.delta_time < 0.01             # practically zero
end

@testset "accumulate_time! — accumulator saturation" begin
    t = TimingState()
    target_update_time = 1.0 / 60.0

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
# Tests — scale_voltage_dict
# ===============================================================

@testset "scale_voltage_dict — empty" begin
    @test isempty(scale_voltage_dict(Dict{NodeCoord, Float64}()))
end

@testset "scale_voltage_dict — single entry" begin
    nc = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    result = scale_voltage_dict(Dict(nc => 10.0))
    @test haskey(result, nc)
    @test result[nc] <= 1.0 + 1e-10  # scaled to at most 1.0
    @test result[nc] > 0.0
end

@testset "scale_voltage_dict — relative ordering preserved" begin
    nc1 = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    nc2 = NodeCoord(TileCoord(1, 0), HexFrame.NODE_Q_POS)

    result = scale_voltage_dict(Dict(nc1 => 100.0, nc2 => 50.0))
    @test result[nc1] > result[nc2]  # higher voltage → higher scaled value
end

# ===============================================================
# Tests — handle_thrusters!
# ===============================================================

@testset "handle_thrusters! — empty map" begin
    gs = GameState()
    gm = GameMap()
    mna = MNA_State()

    handle_thrusters!(gs, gm, mna)

    # No components → no thrust
    @test gs.thrust ≈ SVector(0.0, 0.0)
    @test gs.acceleration ≈ SVector(0.0, 0.0)
end

@testset "handle_thrusters! — velocity unchanged with no thrust" begin
    gs = GameState()
    gm = GameMap()
    mna = MNA_State()

    set_velocity!(gm, SVector(100.0, 50.0))
    initial_vel = get_velocity(gm)

    handle_thrusters!(gs, gm, mna)

    # With no thrust, velocity should remain unchanged
    @test get_velocity(gm) ≈ initial_vel
end

@testset "handle_thrusters! — sets acceleration per-second" begin
    gs = GameState()
    gm = GameMap()
    mna = MNA_State()

    # base_ups defaults to 60 — acceleration should be per-second (× 60)
    handle_thrusters!(gs, gm, mna; base_ups = 60.0)
    @test gs.acceleration ≈ SVector(0.0, 0.0)  # zero thrust → zero accel
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
    initialise_spacemap!(gm, UInt32(1))
    man = ManoeuvreData(main_burn_dv = SVector(1.0, 0.0), decel_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    gs = GameState()
    gs.thrust = SVector(10.0, 0.0)  # well above MANOEUVRE_THRUST_THRESHOLD (0.1)

    @test HexFlowCalculator.cancel_if_thrust!(gm, gs) == true
    @test !has_active_manoeuvre(gm)
end

@testset "cancel_if_thrust! — at threshold" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1))
    man = ManoeuvreData(main_burn_dv = SVector(1.0, 0.0), decel_burn_dv = SVector(-1.0, 0.0))
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
    initialise_spacemap!(gm, UInt32(1))
    set_time_years!(gm, 5.0)
    set_target_time!(gm, 3.0)  # target behind current → not progressing

    man = ManoeuvreData(main_burn_dv = SVector(1.0, 0.0), decel_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.cancel_if_time_progressing!(gm) == false
    @test has_active_manoeuvre(gm)  # NOT cancelled
end

@testset "cancel_if_time_progressing! — time progressing cancels" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1))
    set_time_years!(gm, 5.0)
    set_target_time!(gm, 10.0)  # target ahead → progressing

    man = ManoeuvreData(main_burn_dv = SVector(1.0, 0.0), decel_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.cancel_if_time_progressing!(gm) == true
    @test !has_active_manoeuvre(gm)
end

@testset "cancel_if_time_wrong! — time matches" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1))
    set_time_years!(gm, 5.0)

    man = ManoeuvreData(main_burn_dv = SVector(1.0, 0.0), decel_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.cancel_if_time_wrong!(gm, 5.0) == false
    @test has_active_manoeuvre(gm)
end

@testset "cancel_if_time_wrong! — time mismatch cancels" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1))
    set_time_years!(gm, 5.0)

    man = ManoeuvreData(main_burn_dv = SVector(1.0, 0.0), decel_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    @test HexFlowCalculator.cancel_if_time_wrong!(gm, 10.0) == true
    @test !has_active_manoeuvre(gm)
end

@testset "cancel_if_time_wrong! — within tolerance" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1))
    set_time_years!(gm, 5.0)

    man = ManoeuvreData(main_burn_dv = SVector(1.0, 0.0), decel_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    # 5.005 is within default tolerance of 0.01
    @test HexFlowCalculator.cancel_if_time_wrong!(gm, 5.005) == false
    @test has_active_manoeuvre(gm)
end

@testset "cancel_if_target_time_past! — waypoint ahead" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1))
    set_target_time!(gm, 5.0)

    man = ManoeuvreData(main_burn_dv = SVector(1.0, 0.0), decel_burn_dv = SVector(-1.0, 0.0))
    set_active_manoeuvre!(gm, man)

    # Waypoint at 10.0, target time at 5.0 → target not past waypoint
    @test HexFlowCalculator.cancel_if_target_time_past!(gm, 10.0) == false
    @test has_active_manoeuvre(gm)
end

@testset "cancel_if_target_time_past! — waypoint behind cancels" begin
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1))
    set_target_time!(gm, 5.0)

    man = ManoeuvreData(main_burn_dv = SVector(1.0, 0.0), decel_burn_dv = SVector(-1.0, 0.0))
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

    # Should not error when no manoeuvre is active
    HexFlowCalculator.update_manoeuvre_phase!(gs, gm)
end

@testset "update_manoeuvre_phase! — SpaceMapEmpty is no-op" begin
    gs = GameState()
    gm = GameMap()  # SpaceMapEmpty

    HexFlowCalculator.update_manoeuvre_phase!(gs, gm)
end

@testset "update_manoeuvre_phase! — WAIT_APPROACH with thrust cancels" begin
    gs = GameState()
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1))
    set_time_years!(gm, 0.0)

    man = ManoeuvreData(
        main_burn_dv = SVector(1.0, 0.0),
        decel_burn_dv = SVector(-1.0, 0.0),
        closest_approach_time = 5.0,
        intercept_time = 10.0,
    )
    set_active_manoeuvre!(gm, man)

    # Apply thrust above threshold — should cancel during WAIT_APPROACH
    gs.thrust = SVector(10.0, 0.0)
    HexFlowCalculator.update_manoeuvre_phase!(gs, gm)

    @test !has_active_manoeuvre(gm)
end

@testset "update_manoeuvre_phase! — WAIT_APPROACH transitions to MAIN_BURN" begin
    gs = GameState()
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1))

    # Add a dummy encounter point so the encounter index lookup succeeds
    ep = EncounterPoint(index = 1, base_velocity = 100.0,
        position = SVector(500.0, 0.0), velocity = SVector(-100.0, 0.0), spawn_time = 0.0)
    push!(get_encounter_points(gm), ep)

    man = ManoeuvreData(
        main_burn_dv = SVector(10.0, 0.0),
        decel_burn_dv = SVector(-10.0, 0.0),
        closest_approach_time = 5.0,
        intercept_time = 10.0,
        target_encounter_index = 1,
    )
    set_active_manoeuvre!(gm, man)
    @test man.phase == PHASE_WAIT_APPROACH

    # Set time at closest_approach_time — should trigger transition
    set_time_years!(gm, 5.0)
    set_target_time!(gm, 0.0)  # target behind current → not progressing
    gs.thrust = SVector(0.0, 0.0)  # no thrust

    HexFlowCalculator.update_manoeuvre_phase!(gs, gm)

    @test has_active_manoeuvre(gm)
    updated_man = get_active_manoeuvre(gm)
    @test updated_man.phase == PHASE_MAIN_BURN
    @test updated_man.burn_remaining_dv ≈ SVector(10.0, 0.0)  # _spacemap_to_ship(main_burn_dv)
end

@testset "update_manoeuvre_phase! — ENCOUNTER_READY with thrust cancels" begin
    gs = GameState()
    gm = GameMap()
    initialise_spacemap!(gm, UInt32(1))

    man = ManoeuvreData(
        main_burn_dv = SVector(1.0, 0.0),
        decel_burn_dv = SVector(-1.0, 0.0),
    )
    man.phase = PHASE_ENCOUNTER_READY
    set_active_manoeuvre!(gm, man)

    # Thrust above threshold → cancel
    gs.thrust = SVector(5.0, 0.0)
    HexFlowCalculator.update_manoeuvre_phase!(gs, gm)

    @test !has_active_manoeuvre(gm)
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
