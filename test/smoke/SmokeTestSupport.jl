#=
Scope: Graphical smoke-test support loaded only by the smoke-test launcher
Formatter: Runic
=#

module SmokeTestSupport

using GLFW, HexFluids
using FlowMap: SandboxLearningState, set_learning_system!, ShipBlueprint, ENCOUNTER_SHIP
using HexFrame: TileCoord
using HexFlowProcGen: generate_encounter, generate_encounter_name
using RocketPlumber: configure_threads, start_window, enter_gameloop, ui_teardown
using RocketPlumber: mapgen_teasership, get_encounter_system_config

# ===============================================================
# Test Harness
# ===============================================================

using HexFlowCalculator: MapEditCommand, DoActionCommand, RedockShipCommand, AddEncounterShipCommand
using HexFlowCalculator: CommandQueue, try_enqueue_command!, CommandStatus, APPLIED, QUEUED_FAILED
using Accessors
using HexFlowControl: EXIT_QUIT, InputState

#= ---------- Harness State ---------- =#

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

# Build commands before the live calculator queue exists.

"Build a `DoActionCommand` for harness use."
function make_test_action(coord::TileCoord, action_id::Symbol)
    return DoActionCommand(id = UInt64(0), component_coords = [coord], action_id = action_id, response_channel = nothing)
end

"Build a `RedockShipCommand` for harness use."
function make_test_redock_ship(ship_name::Symbol, offset::TileCoord)
    return RedockShipCommand(id = UInt64(0), ship_name = ship_name, offset = offset, response_channel = nothing)
end

"Build an `AddEncounterShipCommand` with automatic docking and no space-map bookkeeping."
function make_test_add_encounter_ship(blueprint::ShipBlueprint, name_base::String, seed::UInt32)
    return AddEncounterShipCommand(
        id = UInt64(0),
        blueprint = blueprint,
        ship_name_base = name_base,
        seed = seed,
        dir = nothing,
        target_encounter_index = nothing,
        max_view_bounds = nothing,
        response_channel = nothing,
    )
end

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
        success = try_enqueue_command!(command_queue, step.command)
        if !success && !isnothing(step.command.response_channel)
            put!(step.command.response_channel, QUEUED_FAILED)
        end
    end
    pop!(schedule)

    if isempty(schedule)
        inputstate.exit_reason = EXIT_QUIT
    end

    return nothing
end
include("fixture.jl")

"Run the graphical smoke test against the application's teaser map."
function run_smoke_test()::Bool
    GLFW.GetPlatform() == GLFW.PLATFORM_NULL && throw(ArgumentError("Graphical startup requires a display"))
    configure_threads()
    window = start_window()
    return run_smoke_test_fixture(window)
end

end # module SmokeTestSupport
