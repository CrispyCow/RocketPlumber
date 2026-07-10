# ===============================================================
# Test Harness
# ===============================================================

using HexFlowCalculator: MapEditCommand, SetTileCommand, DeleteAtCommand,
    SetPipeBehaviorCommand, MoveCommand, ClickTileCommand, DoActionCommand,
    AddShipSurfaceCommand, RemoveShipSurfaceCommand, RedockShipCommand,
    AddEncounterShipCommand, MapOverrideCommand, CommandQueue, try_enqueue_command!,
    CommandStatus, APPLIED, REJECTED, QUEUED_FAILED, INVALID
using Accessors
using HexFlowControl: EXIT_QUIT, InputState
using HexFrame: TileCoord, PipeCoord, HexAxis, CartesianCoord
using HexComponentsAPI: ComponentBehavior
using FlowMap: PipeBehavior, ShipBlueprint, GameMap, get_ship_blueprint

"Single scheduled test-harness step consumed by `test_system_tick!`."
Base.@kwdef struct TestCommandStep
    tick::Int
    command::Union{Nothing, MapEditCommand} = nothing
    description::String = ""
end

"Schedule of `TestCommandStep`s consumed by `test_system_tick!`."
const TestCommandSchedule = Vector{TestCommandStep}

const TEST_HARNESS_TOTAL = Ref{Int}(0)
const TEST_HARNESS_PASSED = Threads.Atomic{Int}(0)
const TEST_HARNESS_FAILED = Threads.Atomic{Int}(0)
const TEST_HARNESS_CALCULATOR_DOWN = Threads.Atomic{Bool}(false)

"Reset the response-verification counters before building a fresh harness schedule."
function reset_test_harness_stats!()
    TEST_HARNESS_TOTAL[] = 0
    TEST_HARNESS_PASSED[] = 0
    TEST_HARNESS_FAILED[] = 0
    TEST_HARNESS_CALCULATOR_DOWN[] = false
    return nothing
end

#= ---------- Queue-free command builders ----------- =#

# These intentionally mirror the create_*_command helpers in HexFlowCalculator
# so the harness can build commands without depending on a live `CommandQueue`.

"Build a `SetTileCommand` for harness use."
make_test_set_tile(coord::TileCoord, component::ComponentBehavior, rotation::HexAxis, mirrored::Bool = false) =
    SetTileCommand(id = UInt64(0), coord = coord, component = component,
        rotation = rotation, mirrored = mirrored, response_channel = nothing)

"Build a `DeleteAtCommand` for harness use."
make_test_delete(coord::T) where {T <: Union{TileCoord, PipeCoord}} =
    create_delete_command(create_command_queue(1), coord; response_channel = nothing)

"Build a `SetPipeBehaviorCommand` for harness use."
make_test_set_pipe(coord::PipeCoord, pipe::PipeBehavior) =
    create_set_pipe_behavior_command(create_command_queue(1), coord, pipe; response_channel = nothing)

"Build a `MoveCommand` for harness use."
make_test_move(src::T, dst::T, delta_rotation::HexAxis, delta_mirror::Bool = false) where {T <: Union{TileCoord, PipeCoord}} =
    create_move_command(create_command_queue(1), src, dst, delta_rotation, delta_mirror; response_channel = nothing)

"Build a `ClickTileCommand` for harness use."
make_test_click(coord::TileCoord, clicksite::CartesianCoord = CartesianCoord(0.0, 0.0)) =
    ClickTileCommand(id = UInt64(0), coord = coord, unrotated_clicksite = clicksite, response_channel = nothing)

"Build a `DoActionCommand` for harness use."
make_test_action(coord::TileCoord, action_id::Symbol) =
    DoActionCommand(id = UInt64(0), coord = coord, action_id = action_id, response_channel = nothing)

"Build an `AddShipSurfaceCommand` for harness use."
make_test_add_ship_surface(coord::TileCoord) =
    AddShipSurfaceCommand(id = UInt64(0), coord = coord, response_channel = nothing)

"Build a `RemoveShipSurfaceCommand` for harness use."
make_test_remove_ship_surface(coord::TileCoord) =
    RemoveShipSurfaceCommand(id = UInt64(0), coord = coord, response_channel = nothing)

"Build a `RedockShipCommand` for harness use."
make_test_redock_ship(ship_name::Symbol, offset::TileCoord) =
    RedockShipCommand(id = UInt64(0), ship_name = ship_name, offset = offset, response_channel = nothing)

"Build an `AddEncounterShipCommand` for harness use. Defaults to dev-mode placement
(no space_map mutation) so the test can run repeatedly without exhausting encounter slots."
make_test_add_encounter_ship(blueprint::ShipBlueprint, name_base::AbstractString, seed::UInt32;
        dir::Union{Nothing, HexAxis} = nothing) =
    AddEncounterShipCommand(id = UInt64(0), blueprint = blueprint, ship_name_base = String(name_base),
        seed = seed, dir = dir, target_encounter_index = nothing,
        max_view_bounds = nothing, response_channel = nothing)

"Build a `MapOverrideCommand` for harness use."
make_test_map_override(new_map::GameMap) =
    MapOverrideCommand(id = UInt64(0), new_map = new_map, response_channel = nothing)

#= ---------- Response verification ----------- =#

"Drain `ch` and atomically tally a pass/fail against `expected`. Run as a `@spawn`ed watcher."

function _watch_test_response(
        ch::Channel{CommandStatus},
        expected::CommandStatus,
        description::AbstractString,
    )
    actual = take!(ch)
    if actual == expected
        Threads.atomic_add!(TEST_HARNESS_PASSED, 1)
    else
        Threads.atomic_add!(TEST_HARNESS_FAILED, 1)
        @warn "Test harness mismatch" expected actual description
    end
    return nothing
end

"Return a copy of `c` with its response channel set to `ch`."
with_response_channel(c::MapEditCommand, ch::Channel{CommandStatus}) = @set c.response_channel = ch

"Create a scheduled test step, optionally wiring an expected calculator response."
function make_test_step(
        tick::Int,
        command::Union{Nothing, MapEditCommand} = nothing;
        expected_status::Union{Nothing, CommandStatus} = nothing,
        description::AbstractString = "",
    )::TestCommandStep
    if isnothing(command) || isnothing(expected_status)
        return TestCommandStep(tick = tick, command = command, description = description)
    end

    ch = Channel{CommandStatus}(1)
    TEST_HARNESS_TOTAL[] += 1
    command_with_channel = with_response_channel(command, ch)
    Threads.@spawn _watch_test_response(ch, expected_status, description)

    return TestCommandStep(
        tick = tick,
        command = command_with_channel,
        description = description,
    )
end

"Wait briefly for in-flight watcher @spawn tasks to settle so the harness counters are accurate. Returns as soon as all expected outcomes resolve or after `timeout_s` seconds elapse."
function wait_for_test_harness_resolution(timeout_s::Float64 = 0.5)
    deadline = time() + timeout_s
    while time() < deadline
        TEST_HARNESS_PASSED[] + TEST_HARNESS_FAILED[] >= TEST_HARNESS_TOTAL[] && return nothing
        sleep(0.01)
    end
    return nothing
end

"Return true if any expected command outcome failed or never resolved."
function test_harness_failed()
    failed = TEST_HARNESS_FAILED[]
    pending = TEST_HARNESS_TOTAL[] - TEST_HARNESS_PASSED[] - failed
    return failed > 0 || pending > 0 || TEST_HARNESS_CALCULATOR_DOWN[]
end

"Print a compact end-of-run summary for expected command outcomes."
function print_test_harness_summary()
    # Watcher tasks update the counters asynchronously, so an immediate caller can
    # briefly observe a small unresolved count at shutdown.
    total = TEST_HARNESS_TOTAL[]
    passed = TEST_HARNESS_PASSED[]
    failed = TEST_HARNESS_FAILED[]
    pending = total - passed - failed
    calculator_down = TEST_HARNESS_CALCULATOR_DOWN[]

    if failed == 0 && pending == 0
        @info "Test harness: $passed/$total expected outcomes matched."
    else
        @warn "Test harness: $passed/$total matched, $failed failed, $pending unresolved."
    end

    if calculator_down
        @error "Test harness detected that the FlowCalculator task exited before the scripted schedule completed."
    end

    return nothing
end

#= ---------- Tick driver ----------- =#

"Drive the scripted smoke-test schedule and request a clean exit once it is exhausted."
function test_system_tick!(
        schedule::Union{Nothing, TestCommandSchedule},
        snapshot,
        inputstate::InputState,
        command_queue::CommandQueue,
        console_push::Function,
        flowcalc_task::Union{Nothing, Task} = nothing,
    )
    isnothing(schedule) && return nothing

    if !isnothing(flowcalc_task) && istaskdone(flowcalc_task)
        if !TEST_HARNESS_CALCULATOR_DOWN[]
            TEST_HARNESS_CALCULATOR_DOWN[] = true
            @warn "FlowCalculator task exited before the smoke-test schedule completed" current_tick = snapshot.gamestate.ticks remaining_steps = length(schedule)
        end
        inputstate.exit_reason = EXIT_QUIT
        return nothing
    end

    if isempty(schedule)
        inputstate.exit_reason = EXIT_QUIT
        return nothing
    end

    step = last(schedule)
    step.tick > snapshot.gamestate.ticks && return nothing

    if !isnothing(step.command)
        success, _ = try_enqueue_command!(command_queue, step.command, console_push)
        if !success && step.command.response_channel !== nothing
            put!(step.command.response_channel, QUEUED_FAILED)
        end
    end
    pop!(schedule)

    if isempty(schedule)
        inputstate.exit_reason = EXIT_QUIT
    end

    return nothing
end