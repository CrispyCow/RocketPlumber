module HexFlowCalculator

# Packages
using Base.Threads, Dates, Printf, LinearAlgebra, StructEquality
using TimerOutputs, SparseArrays, StaticArrays 
# Custom Packages
using HexFrame, HexElements, HexFluids, HexFlowTelemetry
using FlowEngine, HexComponentsAPI, HexFlowControl

# Type exports - Data Structures
export FlowCalculatorSnapshot, FlowCalculatorSharedState, FlowCalculatorIPC, TimingState

# Type exports - Commands
export CommandStatus, APPLIED, REJECTED, QUEUED_FAILED
export MapEditCommand, SetTileCommand, SetPipeBehaviorCommand, MoveCommand
export DeleteAtCommand, ClickTileCommand, AddShipSurfaceCommand, RemoveShipSurfaceCommand
export CommandQueue

# Function exports - Setup
export create_snapshot_storage, create_threadsafe_consolebuffer
export create_command_queue

# Function exports - Commands
export create_set_tile_command, create_set_pipe_behavior_command, create_move_command
export create_delete_command, create_click_tile_command
export create_add_ship_surface_command, create_remove_ship_surface_command
export try_enqueue_command!

# Function exports - Main loop
export flowcalculator_loop!

# Function exports - Map updates
export update_map!, update_mna!, handle_thrusters!, scale_voltage_dict

# ===============================================================
# Data Structures
# ===============================================================

"""Snapshot of complete game state for rendering. Deep copied to ensure thread safety."""
@kwdef struct FlowCalculatorSnapshot
    gamemap::GameMap = GameMap()
    derived::DerivedMapState = DerivedMapState()
    mna::MNA_State = MNA_State()
    gamestate::GameState = GameState()
    timestamp::Float64
end

"""Shared control state between render and logic threads. All fields must be accessed atomically."""
mutable struct FlowCalculatorSharedState
    @atomic should_exit::Bool
    @atomic is_paused::Bool
    @atomic target_ups::Float64
    @atomic actual_ups::Float64
end

"Keyword constructor for FlowCalculatorSharedState with defaults"
function FlowCalculatorSharedState(;
        should_exit::Bool = false,
        is_paused::Bool = false,
        target_ups::Float64 = 60.0,
        actual_ups::Float64 = 0.0
    )
    return FlowCalculatorSharedState(should_exit, is_paused, target_ups, actual_ups)
end

"""Mutable timing state for FlowCalculator main loop."""
mutable struct TimingState
    current_time::Float64
    last_loop_time::Float64
    delta_time::Float64
    accumulator::Float64
    should_update::Bool
    last_update_time::Float64
end

"""Initialize TimingState with current time"""
function TimingState()
    t = time()
    return TimingState(t, t, 0.0, 0.0, false, t)
end

# ===============================================================
# Map Edit Commands (needed before CommandQueue)
# ===============================================================

# Command result status
@enum CommandStatus APPLIED REJECTED QUEUED_FAILED

"""Abstract base type for all map edit commands"""
abstract type MapEditCommand end

"""Command queue with encapsulated channel and ID generation."""
mutable struct CommandQueue
    command_channel::Channel{MapEditCommand}
    next_command_id::Function
    last_command::Union{MapEditCommand, Nothing}
end

"""Combines all IPC elements for FlowCalculator task"""
@kwdef struct FlowCalculatorIPC
    shared_state::FlowCalculatorSharedState
    command_queue::CommandQueue
    set_snapshot::Function
    get_snapshot::Function
    console_push::Function
    console_see::Function
end

# ===============================================================
# FlowCalculator Command Types and Processing
# ===============================================================

"""Place or replace component at a tile coordinate"""
@kwdef struct SetTileCommand <: MapEditCommand
    id::UInt64
    coord::TileCoord
    component::ComponentBehavior
    rotation::HexAxis
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal SetTileCommand

"""Create/replace pipe behavior at an edge coordinate"""
@kwdef struct SetPipeBehaviorCommand <: MapEditCommand
    id::UInt64
    coord::EdgeCoord
    pipe_behavior::PipeBehavior
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal SetPipeBehaviorCommand

"""Moves a pipe or tile across the map"""
@kwdef struct MoveCommand{T <: Union{TileCoord, EdgeCoord}} <: MapEditCommand
    id::UInt64
    source_coord::T
    dest_coord::T
    delta_rotation::HexAxis
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal MoveCommand

"""Delete element at coordinate"""
@kwdef struct DeleteAtCommand <: MapEditCommand
    id::UInt64
    coord::Union{TileCoord, EdgeCoord, VertexCoord}
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal DeleteAtCommand

"""Invoke on_click! semantics for a tile"""
@kwdef struct ClickTileCommand <: MapEditCommand
    id::UInt64
    coord::TileCoord
    unrotated_clicksite::CartesianCoord
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal ClickTileCommand

"""Add a ship surface tile at coordinate"""
@kwdef struct AddShipSurfaceCommand <: MapEditCommand
    id::UInt64
    coord::TileCoord
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal AddShipSurfaceCommand

"""Remove a ship surface tile at coordinate"""
@kwdef struct RemoveShipSurfaceCommand <: MapEditCommand
    id::UInt64
    coord::TileCoord
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal RemoveShipSurfaceCommand

# ===============================================================
# Thread-Safe Snapshot Storage
# ===============================================================

"""
Thread-safe snapshot storage using closure pattern.
Accepts an initial FlowCalculatorSnapshot.
Returns (set_function, get_function) for snapshot access.
"""
function create_snapshot_storage(initial_snapshot::FlowCalculatorSnapshot)
    local snapshot_ref = Ref{FlowCalculatorSnapshot}(initial_snapshot)
    local snapshot_lock = ReentrantLock()

    """Set the latest snapshot (producer side)"""
    function set_flowcalc_snapshot(new_snapshot::FlowCalculatorSnapshot)
        return lock(snapshot_lock) do
            snapshot_ref[] = new_snapshot
        end
    end

    """Get the latest snapshot (consumer side)"""
    function get_flowcalc_snapshot()::FlowCalculatorSnapshot
        return lock(snapshot_lock) do
            return snapshot_ref[]
        end
    end

    return set_flowcalc_snapshot, get_flowcalc_snapshot
end

# ===============================================================
# Thread-Safe Console Buffer
# ===============================================================

"""
Thread-safe console message buffer using closure pattern.
Returns (push_function, see_function) for console access.
"""
function create_threadsafe_consolebuffer(Length::Int)
    if Length < 1
        error("Invalid Length of Console Buffer (must be more than 1)")
    end

    local msg_buffer = String[]
    local console_lock = ReentrantLock()

    """Thread-safe function to add a message string to the internal message buffer"""
    function push_message(msg::String)
        lock(console_lock) do
            timestamp = Dates.format(now(), "HH:MM:SS")
            stamped_msg = "[$timestamp]: $msg"
            push!(msg_buffer, stamped_msg)
            if length(msg_buffer) > Length
                popfirst!(msg_buffer)
            end
        end
        return nothing
    end

    """Thread-safe function which returns a shallow copy of the internal message buffer"""
    function see_messages()
        return lock(console_lock) do
            return copy(msg_buffer)
        end
    end

    return push_message, see_messages
end

# ===============================================================
# Command Queue Management
# ===============================================================

"""
Create command queue with bounded capacity.
Returns a CommandQueue with encapsulated channel and ID counter.
"""
function create_command_queue(capacity::Int = 32)
    # Create per-queue atomic counter
    local id_counter = Threads.Atomic{UInt64}(0)

    # Create closure for thread-safe ID generation
    function next_id_fn()::UInt64
        return Threads.atomic_add!(id_counter, UInt64(1))
    end

    return CommandQueue(
        Channel{MapEditCommand}(capacity),
        next_id_fn,
        nothing
    )
end

# ===============================================================
# Command Processing
# ===============================================================

"""
Apply a map edit command directly to the gamemap without validation.
Dispatches on command type and performs the actual mutation.
"""
function apply_mapedit_command!(
        gamemap::GameMap,
        command::SetTileCommand,
        threadsafe_console_push::Function
    )
    # Check if theres already a component at this tile
    existing_comptile = get_tile(gamemap, command.coord)
    if !isnothing(existing_comptile)
        threadsafe_console_push("Cannot place component: Tile is already occupied")
        return nothing
    end

    # Use component-specific placement validation
    mapped_rotation = map_rotation(command.component, command.rotation)
    can_place, reason = placement_valid(
        command.component;
        coord = command.coord,
        gamemap = gamemap,
        rotation = mapped_rotation
    )
    if !can_place
        threadsafe_console_push("Cannot place component: $reason")
        return nothing
    end

    set_tile!(
        gamemap, command.coord, ComponentOnTile(
            deepcopy(command.component),
            mapped_rotation
        )
    )
    threadsafe_console_push("Tile placed at $(command.coord)")
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::SetPipeBehaviorCommand,
        threadsafe_console_push::Function
    )
    # Check if there's already a pipe behavior at this edge
    existing_pipe = get_pipe(gamemap, command.coord)
    if !isnothing(existing_pipe)
        threadsafe_console_push("Cannot place pipe: Edge is already occupied")
        return nothing
    end

    # Validate both pipe endpoints are on ship surface
    can_place, reason = can_place_pipe_at(command.coord, gamemap)
    if !can_place
        threadsafe_console_push("Cannot place pipe: $reason")
        return nothing
    end

    set_pipe!(gamemap, command.coord, deepcopy(command.pipe_behavior))
    threadsafe_console_push("Pipe behavior placed at $(command.coord)")
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::MoveCommand{TileCoord},
        threadsafe_console_push::Function
    )

    # Check if theres already a component at the destination tile
    existing_comptile = get_tile(gamemap, command.dest_coord)
    if !isnothing(existing_comptile)
        threadsafe_console_push("Cannot place component: Tile is already occupied")
        return nothing
    end
    
    source_comptile = get_tile(gamemap, command.source_coord)

    # Check if the component can be moved
    can_move, reason = can_be_moved(source_comptile)
    if !can_move
        threadsafe_console_push("Component at $(command.source_coord) cannot be moved: $reason")
        return nothing
    end

    # Calculate new rotation
    new_rotation = map_rotation(source_comptile.component, rotate(source_comptile.rotation, command.delta_rotation))

    # Use component-specific placement validation
    can_place, reason = placement_valid(
        source_comptile.component;
        coord = command.dest_coord,
        gamemap = gamemap,
        rotation = new_rotation
    )
    if !can_place
        threadsafe_console_push("Cannot move to $(command.dest_coord): $reason")
        return nothing
    end

    dest_comptile = ComponentOnTile(source_comptile.component, new_rotation)
    set_tile!(gamemap, command.dest_coord, dest_comptile)
    delete_tile!(gamemap, command.source_coord)
    threadsafe_console_push("Tile moved from $(command.source_coord) to $(command.dest_coord)")
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::MoveCommand{EdgeCoord},
        threadsafe_console_push::Function
    )
    # Check if theres already a pipe behavior at the destination edge
    existing_pipe = get_pipe(gamemap, command.dest_coord)
    if !isnothing(existing_pipe)
        threadsafe_console_push("Cannot move pipe: Edge is already occupied")
        return nothing
    end

    # Check if destination pipe endpoints are on ship surface
    can_place, reason = can_place_pipe_at(command.dest_coord, gamemap)
    if !can_place
        threadsafe_console_push("Cannot move pipe to $(command.dest_coord): $reason")
        return nothing
    end

    # Handle pipe behaviors
    if has_pipe(gamemap, command.source_coord)
        source_pipe = get_pipe(gamemap, command.source_coord)
        set_pipe!(gamemap, command.dest_coord, source_pipe)
        delete_pipe!(gamemap, command.source_coord)
        threadsafe_console_push("Pipe behavior moved from $(command.source_coord) to $(command.dest_coord)")
    end
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::DeleteAtCommand,
        threadsafe_console_push::Function
    )
    if command.coord isa VertexCoord
        threadsafe_console_push("Can't delete a node!")
        return nothing# No-op for vertex deletion
    elseif command.coord isa EdgeCoord
        # Delete pipe behaviors
        if has_pipe(gamemap, command.coord)
            delete_pipe!(gamemap, command.coord)
            threadsafe_console_push("Pipe behavior deleted at $(command.coord)")
        end
    elseif command.coord isa TileCoord
        delete_tile!(gamemap, command.coord)
        threadsafe_console_push("Tile deleted at $(command.coord)")
    end
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::ClickTileCommand,
        threadsafe_console_push::Function
    )
    tilecomp = get_tile(gamemap, command.coord)
    if !isnothing(tilecomp)
        on_click!(tilecomp; unrotated_clicksite = command.unrotated_clicksite)
        threadsafe_console_push("Clicked tile at $(command.coord)")
    else
        threadsafe_console_push("No tile found at $(command.coord)")
    end
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::AddShipSurfaceCommand,
        threadsafe_console_push::Function
    )
    add_ship_surface_tile!(gamemap, command.coord)
    threadsafe_console_push("Ship surface added at $(command.coord)")
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::RemoveShipSurfaceCommand,
        threadsafe_console_push::Function
    )
    can_remove, reason = can_remove_surface_at(command.coord, gamemap)
    if !can_remove
        threadsafe_console_push("Cannot remove surface: $reason")
        return nothing
    end

    remove_ship_surface_tile!(gamemap, command.coord)
    threadsafe_console_push("Ship surface removed at $(command.coord)")
    return nothing
end

"""
Process a single map edit command using sandbox validation.
Validates changes on a copy before applying to the real gamemap.
"""
function process_command!(
        command::MapEditCommand,
        gamemap::GameMap,
        threadsafe_console_push::Function;
        throw_errors::Bool = true
    )
    # Create sandbox copy for validation
    sandbox = deepcopy(gamemap)

    # Helper function to check if map changed
    map_hash(gmap::GameMap) = hash(gmap.tiles, hash(gmap.pipe_behaviors))
    original_hash = map_hash(sandbox)

    # Try to apply the command to the sandbox first
    try
        apply_mapedit_command!(sandbox, command, (msg) -> nothing)  # Silent for sandbox
        new_hash = map_hash(sandbox)

        # If map changed, validate it won't cause errors
        if new_hash != original_hash
            test_derivedmapstate = DerivedMapState()
            test_mna_state = MNA_State()

            # Test the sandbox with full validation (use tick 0 for validation)
            update_map!(sandbox, test_derivedmapstate, test_mna_state, Int64(0))
            update_mna!(test_derivedmapstate, test_mna_state, Int64(0))
        end

        # If we get here, validation succeeded - apply to real gamemap
        apply_mapedit_command!(gamemap, command, threadsafe_console_push)

        # Send success response if channel provided
        if command.response_channel !== nothing
            try
                put!(command.response_channel, APPLIED)
            catch
                # Ignore response channel failures
            end
        end

    catch sandbox_error
        # Sandbox validation failed
        error_msg = "Invalid map edit: $(sandbox_error)"
        threadsafe_console_push(error_msg)

        # Send failure response if channel provided
        if command.response_channel !== nothing
            try
                put!(command.response_channel, REJECTED)
            catch
                # Ignore response channel failures
            end
        end

        # rethrow if requested
        if throw_errors
            println("Rethrowing sandbox error as requested: $sandbox_error")
            rethrow(sandbox_error)
        end
    end
    return nothing
end

# ===============================================================
# Command Generation Helpers
# ===============================================================

"""Create a SetTileCommand for placing a component"""
function create_set_tile_command(
        cq::CommandQueue,
        coord::TileCoord,
        component::ComponentBehavior,
        rotation::HexAxis;
        response_channel::Union{Nothing, Channel} = nothing
    )::SetTileCommand
    return SetTileCommand(
        id = cq.next_command_id(),
        coord = coord,
        component = component,
        rotation = rotation,
        response_channel = response_channel
    )
end

"""Create a SetPipeBehaviorCommand for placing a pipe behavior"""
function create_set_pipe_behavior_command(
        cq::CommandQueue,
        coord::EdgeCoord,
        pipe_behavior::PipeBehavior;
        response_channel::Union{Nothing, Channel} = nothing
    )::SetPipeBehaviorCommand
    return SetPipeBehaviorCommand(
        id = cq.next_command_id(),
        coord = coord,
        pipe_behavior = pipe_behavior,
        response_channel = response_channel
    )
end

"""Create a MoveCommand for moving an element"""
function create_move_command(
        cq::CommandQueue,
        source_coord::T,
        dest_coord::T,
        delta_rotation::HexAxis;
        response_channel::Union{Nothing, Channel} = nothing
    ) where {T <: Union{TileCoord, EdgeCoord}}
    return MoveCommand{T}(
        id = cq.next_command_id(),
        source_coord = source_coord,
        dest_coord = dest_coord,
        delta_rotation = delta_rotation,
        response_channel = response_channel
    )
end

"""Create a DeleteAtCommand for deleting an element"""
function create_delete_command(
        cq::CommandQueue,
        coord::Union{TileCoord, EdgeCoord, VertexCoord};
        response_channel::Union{Nothing, Channel} = nothing
    )::DeleteAtCommand
    return DeleteAtCommand(
        id = cq.next_command_id(),
        coord = coord,
        response_channel = response_channel
    )
end

"""Create a ClickTileCommand for tile interaction"""
function create_click_tile_command(
        cq::CommandQueue,
        coord::TileCoord,
        unrotated_clicksite::CartesianCoord;
        response_channel::Union{Nothing, Channel} = nothing
    )::ClickTileCommand
    return ClickTileCommand(
        id = cq.next_command_id(),
        coord = coord,
        unrotated_clicksite = unrotated_clicksite,
        response_channel = response_channel
    )
end

"""Create an AddShipSurfaceCommand"""
function create_add_ship_surface_command(
        cq::CommandQueue,
        coord::TileCoord;
        response_channel::Union{Nothing, Channel} = nothing
    )::AddShipSurfaceCommand
    return AddShipSurfaceCommand(
        id = cq.next_command_id(),
        coord = coord,
        response_channel = response_channel
    )
end

"""Create a RemoveShipSurfaceCommand"""
function create_remove_ship_surface_command(
        cq::CommandQueue,
        coord::TileCoord;
        response_channel::Union{Nothing, Channel} = nothing
    )::RemoveShipSurfaceCommand
    return RemoveShipSurfaceCommand(
        id = cq.next_command_id(),
        coord = coord,
        response_channel = response_channel
    )
end

"""
Command enqueue function - currently blocking.
Returns (success::Bool, status::CommandStatus)
TODO: Implement proper non-blocking behavior with isfull check once available
"""
function try_enqueue_command!(
        command_queue::CommandQueue,
        command::MapEditCommand,
        threadsafe_console_push::Function
    )::Tuple{Bool, CommandStatus}

    try
        # Blocking put for now - TODO: replace with non-blocking when isfull is available
        put!(command_queue.command_channel, command)
        command_queue.last_command = command
        return (true, APPLIED)  # Command queued successfully
    catch e
        threadsafe_console_push("Failed to enqueue command: $(e)")
        return (false, QUEUED_FAILED)
    end
end

# ===============================================================
# Map Update Functions
# ===============================================================

"""
Checks for changes to the map, and recomputes derived state and MNA if necessary.
Will modify derivedmapstate and mna_state.
"""
function update_map!(gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State, current_tick::Int64)
    # (updating map every tick as it is quite quick. This might need to be revisited if it becomes a bottleneck)
    @timeit flowcalc_loop_timer "Map Updates" begin
        # derive basic map state
        @timeit flowcalc_loop_timer "find ship edge" find_ship_surface_edgetiles!(derivedmapstate, gamemap)
        @timeit flowcalc_loop_timer "list elements" derivedmapstate.allelements = list_elements(gamemap)
        @timeit flowcalc_loop_timer "list nodes" derivedmapstate.allnodes = list_nodes(derivedmapstate.allelements) # not actually used, just for diagnostics
        @timeit flowcalc_loop_timer "prune" derivedmapstate.prunedelements = prune(derivedmapstate.allelements)
        @timeit flowcalc_loop_timer "grounding search" derivedmapstate.prunedelements = ground_search(derivedmapstate.prunedelements)

        # repeatedly clean/prune until clear_dangling_dependants no longer changes the elements
        # this part of the code is not great, ripe for optimization
        derivedmapstate.prunedelements = derivedmapstate.allelements
        last_hash::UInt64 = 0
        while last_hash != hash(derivedmapstate.prunedelements)
            # call cleanup functions
            @timeit flowcalc_loop_timer "prune" derivedmapstate.prunedelements = prune(derivedmapstate.prunedelements)
            @timeit flowcalc_loop_timer "grounding search" derivedmapstate.prunedelements = ground_search(derivedmapstate.prunedelements)
            last_hash = hash(derivedmapstate.prunedelements)
            @timeit flowcalc_loop_timer "dangling dependants" derivedmapstate.prunedelements = clear_dangling_dependants(derivedmapstate.prunedelements)
        end
        @timeit flowcalc_loop_timer "list pruned nodes" derivedmapstate.prunednodes = list_nodes(derivedmapstate.prunedelements)

        # derive MNA, if there are any nodes. MNA on empty arrays crashes
        if !isempty(derivedmapstate.prunednodes)
            derivedmapstate.nodeprimefluidtags = fluidtag_nodes(derivedmapstate, gamemap)
            build_node_connection_map!(derivedmapstate)
            connect_fluidtags!(derivedmapstate)
            @timeit flowcalc_loop_timer "MNA index nodes" mna_state.node_to_index, mna_state.index_to_node = MNA_indexnodes(derivedmapstate)
            @timeit flowcalc_loop_timer "MNA split elements" MNA_splitelements!(mna_state, derivedmapstate)
            @timeit flowcalc_loop_timer "MNA get A" mna_state.mat_A = MNA_getA(mna_state)
        else
            # clear old outputs so they dont continue to be rendered
            empty!(mna_state.node_voltages)
            empty!(mna_state.vsource_currents)
            empty!(mna_state.node_voltages_scaled)
            empty!(derivedmapstate.nodeactualfluids)
        end
    end
    return nothing
end

# Closure to remember maximum voltage seen so far
let max_voltage_ever::Float64 = -Inf
    """
    Normalise the node voltage between 0 and 1 for colour rendering.
    Remembers maximum voltage it has seen.
    """
    global function scale_voltage_dict(dict::Dict{NodeCoord, Float64})::Dict{NodeCoord, Float64}
        # Skip if input Dict is empty
        if isempty(dict)
            return Dict{NodeCoord, Float64}()
        end

        # Get the maximum value
        max_voltage_current = maximum(values(dict))
        max_voltage_ever = maximum([max_voltage_current, max_voltage_ever])

        # Scale the values so that the largest is 1
        scaled_dict = Dict(key => value / max_voltage_ever for (key, value) in dict)
        return scaled_dict
    end
end

"""
Updates Z matrix and re-solves MNA. Run once every tick.
"""
function update_mna!(derivedmapstate::DerivedMapState, mna_state::MNA_State, current_tick::Int64)
    if !isempty(derivedmapstate.prunednodes)
        @timeit flowcalc_loop_timer "MNA Solve" begin
            @timeit flowcalc_loop_timer "get Z" mna_state.mat_Z = MNA_getZ(mna_state)
            @timeit flowcalc_loop_timer "MNA solve" mna_state.node_voltages, mna_state.vsource_currents = MNA_solve(mna_state)
            @timeit flowcalc_loop_timer "MNA scale" mna_state.node_voltages_scaled = scale_voltage_dict(mna_state.node_voltages)
        end
    end
    return nothing
end

"Updates thrust related gamestate based on calls to get_thrust for all components"
function handle_thrusters!(gamestate::GameState, gamemap::GameMap, mna_state::MNA_State)
    # compute thrust vector
    thrust = SVector{2, Float64}(0.0, 0.0)
    for (tile, comp) in get_all_tiles(gamemap)
        thrust += get_thrust(comp; tile = tile, mna_state = mna_state)
    end

    # mutate gamestate
    gamestate.thrust = thrust
    return gamestate.impulse += thrust
end

# ===============================================================
# FlowCalculator Main Loop
# ===============================================================

"""
Update timing state for the next loop iteration.
Calculates delta time, updates accumulator with saturation, and sets should_update flag.
"""
function accumulate_time!(
        timing::TimingState,
        target_update_time::Float64
    )
    # Calculate elapsed time
    timing.current_time = time()
    timing.delta_time = timing.current_time - timing.last_loop_time
    timing.last_loop_time = timing.current_time

    # Update accumulator with saturation
    max_accumulator = target_update_time * 10.0
    timing.accumulator += timing.delta_time
    timing.accumulator = min(timing.accumulator, max_accumulator)

    # Check if we have enough time for an update
    timing.should_update = timing.accumulator >= target_update_time

    return nothing
end

"""
Update UPS metrics, check saturation, and log diagnostics.
Returns new update_count (0 if reset, otherwise unchanged).
"""
function update_ups_metrics!(
        shared_state::FlowCalculatorSharedState,
        timing::TimingState,
        update_count::Int,
        target_ups::Float64,
        threadsafe_console_push::Function;
        diagnostic_interval::Float64 = 10.0
    )::Int
    # Calculate actual UPS based on updates performed
    time_since_last_update = timing.current_time - timing.last_update_time
    new_update_count = update_count

    if time_since_last_update >= 0.1  # Update every 100ms
        if time_since_last_update > 0.0 && update_count > 0
            measured_ups = update_count / time_since_last_update
            prev_ups = @atomic shared_state.actual_ups
            new_ups = prev_ups * 0.5 + measured_ups * 0.5
            @atomic shared_state.actual_ups = new_ups

            # Reset counters
            timing.last_update_time = timing.current_time
            new_update_count = 0
        end
    end

    # Warn if accumulator is saturated
    max_accumulator = (1.0 / target_ups) * 10.0
    if timing.accumulator >= max_accumulator * 0.99
        threadsafe_console_push("FlowCalculator saturating time accumulator (running behind)")
    end

    return new_update_count
end

"""
Main FlowCalculator loop - runs deterministic game simulation on fixed timestep.
"""
function flowcalculator_loop!(
        ipc::FlowCalculatorIPC,
        initial_snapshot::FlowCalculatorSnapshot
    )
    # Unpack IPC elements
    shared_state = ipc.shared_state
    command_queue = ipc.command_queue
    set_snapshot = ipc.set_snapshot
    threadsafe_console_push = ipc.console_push

    @info "FlowCalculator loop started on thread $(Threads.threadid())"
    threadsafe_console_push("FlowCalculator loop started")

    # Timing state and UPS tracking
    timing = TimingState()
    diagnostic_interval = 10.0  # seconds
    update_count = 0

    # Unpack initial state from snapshot
    gamemap = initial_snapshot.gamemap
    derivedmapstate = initial_snapshot.derived
    mna_state = initial_snapshot.mna
    gamestate = initial_snapshot.gamestate

    # Main loop
    while true
        # Update timing state
        target_ups = @atomic shared_state.target_ups
        target_update_time = 1.0 / target_ups
        accumulate_time!(timing, target_update_time)

        # Exit loop if requested
        if (@atomic shared_state.should_exit)
            @info "FlowCalculator loop exiting as requested"
            threadsafe_console_push("FlowCalculator loop exiting")
            break
        end

        # Check if paused
        is_paused = @atomic shared_state.is_paused

        # Main update logic
        if !timing.should_update
            # Not enough time accumulated, sleep briefly
            sleep(0.001)  # 1ms
        else
            # Process commands (only when updating)
            commands_processed = false
            @timeit flowcalc_loop_timer "Command Processing" begin
                while isready(command_queue.command_channel)
                    command = take!(command_queue.command_channel)
                    process_command!(command, gamemap, threadsafe_console_push, throw_errors = false)
                    commands_processed = true
                end
            end

            # Consume accumulated time and track update
            timing.accumulator -= target_update_time
            update_count += 1

            if !is_paused
                # Full update: advance game state
                gamestate.ticks += 1

                # Update state
                @timeit flowcalc_loop_timer "Component Updates" update_components!(gamemap, mna_state)
                update_map!(gamemap, derivedmapstate, mna_state, gamestate.ticks)
                update_mna!(derivedmapstate, mna_state, gamestate.ticks)
                @timeit flowcalc_loop_timer "Thruster Handling" handle_thrusters!(gamestate, gamemap, mna_state)

                # Publish snapshot
                @timeit flowcalc_loop_timer "Snapshot Publishing" begin
                    snapshot = FlowCalculatorSnapshot(
                        gamemap = deepcopy(gamemap),
                        derived = deepcopy(derivedmapstate),
                        mna = deepcopy(mna_state),
                        gamestate = deepcopy(gamestate),
                        timestamp = timing.current_time
                    )
                    set_snapshot(snapshot)
                end

            elseif commands_processed
                # Paused with commands: update derived state only
                update_map!(gamemap, derivedmapstate, mna_state, gamestate.ticks)
                update_mna!(derivedmapstate, mna_state, gamestate.ticks)

                # Publish snapshot without advancing game time
                @timeit flowcalc_loop_timer "Snapshot Publishing" begin
                    snapshot = FlowCalculatorSnapshot(
                        gamemap = deepcopy(gamemap),
                        derived = deepcopy(derivedmapstate),
                        mna = deepcopy(mna_state),
                        gamestate = deepcopy(gamestate),
                        timestamp = timing.current_time
                    )
                    set_snapshot(snapshot)
                end
            end
        end

        # Update UPS metrics, warnings, and diagnostics
        @timeit flowcalc_loop_timer "UPS Metrics" begin
            update_count = update_ups_metrics!(
                shared_state, timing, update_count,
                target_ups, threadsafe_console_push,
                diagnostic_interval = diagnostic_interval
            )
        end

        # Handle FlowCalculator diagnostics (called from background thread)
        # Uses gamestate.ticks as counter for tick-based diagnostic printing
        handle_diagnostics(flowcalc_loop_diagnostic_config, gamestate.ticks)
    end
    return nothing
end

end # module HexFlowCalculator
