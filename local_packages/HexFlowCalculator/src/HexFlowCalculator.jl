module HexFlowCalculator

# Packages
using Base.Threads, Dates, JLD2, LinearAlgebra, StructEquality
using TimerOutputs, StaticArrays
# Custom Packages
using HexFrame, HexElements, HexFluids, HexFlowTelemetry
using FlowEngine, FlowMap, HexComponentsAPI, HexFlowControl
using HexFlowProcGen

# Type exports - Data Structures
export FlowCalculatorSnapshot, FlowCalculatorSharedState, FlowCalculatorIPC, TimingState

# Type exports - Commands
export CommandStatus, APPLIED, REJECTED, QUEUED_FAILED, INVALID
export MapEditCommand, SetTileCommand, SetPipeBehaviorCommand, MoveCommand
export DeleteAtCommand, ClickTileCommand, DoActionCommand, AddShipSurfaceCommand, RemoveShipSurfaceCommand
export MapOverrideCommand, AddEncounterShipCommand, RedockShipCommand
export CommandQueue

# Function exports - Setup
export create_snapshot_storage, create_threadsafe_consolebuffer
export create_command_queue
export set_max_reachable_bounds!, get_max_reachable_bounds

# Function exports - Commands
export create_set_tile_command, create_set_pipe_behavior_command, create_move_command
export create_delete_command, create_click_tile_command, create_do_action_command
export create_add_ship_surface_command, create_remove_ship_surface_command
export create_map_override_command, create_add_encounter_ship_command, create_redock_ship_command
export try_enqueue_command!

# Function exports - Main loop
export flowcalculator_loop!

# Function exports - Map updates
export update_map!, update_mna!, handle_thrusters!, scale_voltage_dict!
export collect_primary_map_inputs!, update_map_from_inputs!, solve_from_inputs!

# Constant exports - Manoeuvre thresholds
export MANOEUVRE_THRUST_THRESHOLD, MANOEUVRE_COMPLETION_THRESHOLD

const DELTA_V_CACHE_TICK_DIVISOR::Int64 = 30

# ===============================================================
# Data Structures
# ===============================================================

"Snapshot of complete game state for rendering. Triple-buffered and filled in-place to reduce allocations."
@kwdef mutable struct FlowCalculatorSnapshot
    gamemap::GameMap = GameMap()
    derived::DerivedMapState = DerivedMapState()
    mna::MNA_StateSnapshot = MNA_StateSnapshot()
    gamestate::GameState = GameState()
    timestamp::Float64 = 0.0
end

"Shared control state between render and logic threads. All fields must be accessed atomically."
mutable struct FlowCalculatorSharedState
    @atomic should_exit::Bool
    @atomic is_paused::Bool
    @atomic target_ups::Float64
    @atomic actual_ups::Float64
    @atomic target_spacemap_time::Float64
    @atomic view_bounds_x_pos::Float64
    @atomic view_bounds_x_neg::Float64
    @atomic view_bounds_y_pos::Float64
    @atomic view_bounds_y_neg::Float64
end

"Keyword constructor for FlowCalculatorSharedState with defaults"
function FlowCalculatorSharedState(;
        should_exit::Bool = false,
        is_paused::Bool = false,
        target_ups::Float64 = BASE_UPS,
        actual_ups::Float64 = 0.0,
        target_spacemap_time::Float64 = 0.0,
        view_bounds_x_pos::Float64 = 5.0,
        view_bounds_x_neg::Float64 = -5.0,
        view_bounds_y_pos::Float64 = 5.0,
        view_bounds_y_neg::Float64 = -5.0
    )
    return FlowCalculatorSharedState(
        should_exit,
        is_paused,
        target_ups,
        actual_ups,
        target_spacemap_time,
        view_bounds_x_pos,
        view_bounds_x_neg,
        view_bounds_y_pos,
        view_bounds_y_neg,
    )
end

"Push the render thread's computed max reachable bounds into shared state."
function set_max_reachable_bounds!(shared_state::FlowCalculatorSharedState, bounds::HexFrame.CartesianBounds)
    @atomic :monotonic shared_state.view_bounds_x_pos = bounds.X_POS
    @atomic :monotonic shared_state.view_bounds_x_neg = bounds.X_NEG
    @atomic :monotonic shared_state.view_bounds_y_pos = bounds.Y_POS
    @atomic :monotonic shared_state.view_bounds_y_neg = bounds.Y_NEG
    return nothing
end

"Read the current max reachable bounds from shared state."
function get_max_reachable_bounds(shared_state::FlowCalculatorSharedState)::HexFrame.CartesianBounds
    return (
        X_POS = @atomic(:monotonic, shared_state.view_bounds_x_pos),
        X_NEG = @atomic(:monotonic, shared_state.view_bounds_x_neg),
        Y_POS = @atomic(:monotonic, shared_state.view_bounds_y_pos),
        Y_NEG = @atomic(:monotonic, shared_state.view_bounds_y_neg),
    )
end

"Timing state for the FlowCalculator fixed-timestep accumulator."
mutable struct TimingState
    current_time::Float64
    last_loop_time::Float64
    delta_time::Float64
    accumulator::Float64
    should_update::Bool
    last_update_time::Float64
end

"Initialise `TimingState` with the current wall-clock time."
function TimingState()
    t = time()
    return TimingState(t, t, 0.0, 0.0, false, t)
end

# ===============================================================
# Map Edit Commands (needed before CommandQueue)
# ===============================================================

# Command result status
@enum CommandStatus APPLIED REJECTED QUEUED_FAILED INVALID

"Abstract base type for all map edit commands."
abstract type MapEditCommand end

"Command queue with encapsulated channel and ID generation."
mutable struct CommandQueue
    command_channel::Channel{MapEditCommand}
    next_command_id::Function
    last_command::Union{MapEditCommand, Nothing}
end

"Bundles all inter-thread communication handles for the FlowCalculator."
@kwdef struct FlowCalculatorIPC
    shared_state::FlowCalculatorSharedState
    command_queue::CommandQueue
    publish_snapshot::Function
    get_snapshot::Function
    console_push::Function
    console_see::Function
end

# ===============================================================
# FlowCalculator Command Types and Processing
# ===============================================================

"Place a component at a tile coordinate."
@kwdef struct SetTileCommand <: MapEditCommand
    id::UInt64
    coord::TileCoord
    component::ComponentBehavior
    rotation::HexAxis
    mirrored::Bool
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal SetTileCommand

"Place a pipe behaviour at a pipe coordinate."
@kwdef struct SetPipeBehaviorCommand <: MapEditCommand
    id::UInt64
    coord::PipeCoord
    pipe_behavior::PipeBehavior
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal SetPipeBehaviorCommand

"Move a component or pipe across the map."
@kwdef struct MoveCommand{T <: Union{TileCoord, PipeCoord}} <: MapEditCommand
    id::UInt64
    source_coord::T
    dest_coord::T
    delta_rotation::HexAxis
    delta_mirror::Bool
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal MoveCommand

"Delete element at coordinate. Type parameter selects tile vs edge dispatch."
@kwdef struct DeleteAtCommand{T <: Union{TileCoord, PipeCoord}} <: MapEditCommand
    id::UInt64
    coord::T
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal DeleteAtCommand

"Invoke `on_click!` semantics for a tile component."
@kwdef struct ClickTileCommand <: MapEditCommand
    id::UInt64
    coord::TileCoord
    unrotated_clicksite::CartesianCoord
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal ClickTileCommand

"Execute a named action on a tile component."
@kwdef struct DoActionCommand <: MapEditCommand
    id::UInt64
    coord::TileCoord
    action_id::Symbol
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal DoActionCommand

"Add a ship surface tile at coordinate."
@kwdef struct AddShipSurfaceCommand <: MapEditCommand
    id::UInt64
    coord::TileCoord
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal AddShipSurfaceCommand

"Remove a ship surface tile at coordinate."
@kwdef struct RemoveShipSurfaceCommand <: MapEditCommand
    id::UInt64
    coord::TileCoord
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal RemoveShipSurfaceCommand

"Replace the entire `GameMap` with a provided map."
@kwdef struct MapOverrideCommand <: MapEditCommand
    id::UInt64
    new_map::GameMap
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal MapOverrideCommand

"Add an encounter ship to the map with optional space_map bookkeeping."
@kwdef struct AddEncounterShipCommand <: MapEditCommand
    id::UInt64
    blueprint::ShipBlueprint
    ship_name_base::String
    seed::UInt32
    dir::Union{Nothing, HexFrame.HexAxis}       # nothing = auto-optimal, HexAxis = explicit
    target_encounter_index::Union{Nothing, Int}  # nothing = dev utils (no space_map mutation)
    max_view_bounds::Union{Nothing, HexFrame.CartesianBounds}
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal AddEncounterShipCommand

"Relocate a ship by a tile offset, with approach animation and explicit overlap validation."
@kwdef struct RedockShipCommand <: MapEditCommand
    id::UInt64
    ship_name::Symbol
    offset::TileCoord              # delta to apply via offset_ship!
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal RedockShipCommand

# ===============================================================
# Snapshot Refill Methods
# ===============================================================

"Refill `dest` with data from `src`, reusing existing container allocations."
function snapshot!(dest::DerivedMapState, src::DerivedMapState)
    # Sets: empty and refill
    empty!(dest.ship_surface_edge)
    union!(dest.ship_surface_edge, src.ship_surface_edge)

    # Vectors: resize and copy
    resize!(dest.primaryelements, length(src.primaryelements))
    copyto!(dest.primaryelements, src.primaryelements)

    resize!(dest.filteredelements, length(src.filteredelements))
    copyto!(dest.filteredelements, src.filteredelements)

    resize!(dest.primary_fluid_declarations, length(src.primary_fluid_declarations))
    copyto!(dest.primary_fluid_declarations, src.primary_fluid_declarations)

    # Dicts: empty and merge
    empty!(dest.primarynodes)
    merge!(dest.primarynodes, src.primarynodes)

    empty!(dest.filterednodes)
    merge!(dest.filterednodes, src.filterednodes)

    empty!(dest.node_declarations)
    merge!(dest.node_declarations, src.node_declarations)

    empty!(dest.source_nodes)
    union!(dest.source_nodes, src.source_nodes)

    empty!(dest.nodeactualfluids)
    merge!(dest.nodeactualfluids, src.nodeactualfluids)

    empty!(dest.node_to_region)
    merge!(dest.node_to_region, src.node_to_region)

    empty!(dest.region_temperatures)
    merge!(dest.region_temperatures, src.region_temperatures)

    empty!(dest.node_temperatures)
    merge!(dest.node_temperatures, src.node_temperatures)

    return nothing
end

"Refill snapshot `dest` with the render-relevant subset of `src`."
function snapshot!(dest::MNA_StateSnapshot, src::MNA_State)
    empty!(dest.resistors)
    merge!(dest.resistors, src.resistors)

    empty!(dest.csources)
    merge!(dest.csources, src.csources)

    empty!(dest.vsources)
    merge!(dest.vsources, src.vsources)

    empty!(dest.vsource_lookup)
    merge!(dest.vsource_lookup, src.vsource_lookup)

    empty!(dest.node_voltages)
    merge!(dest.node_voltages, src.node_voltages)

    empty!(dest.vsource_currents)
    merge!(dest.vsource_currents, src.vsource_currents)

    empty!(dest.node_voltages_scaled)
    merge!(dest.node_voltages_scaled, src.node_voltages_scaled)

    return nothing
end

"Refill snapshot `dest` with values from `src`."
function snapshot!(dest::GameState, src::GameState)
    dest.thrust = src.thrust
    dest.acceleration_ship_frame = src.acceleration_ship_frame
    dest.acceleration_space_map_frame = src.acceleration_space_map_frame
    dest.ticks = src.ticks
    dest.estimated_min_delta_v = src.estimated_min_delta_v
    return nothing
end

"Refresh the cached conservative delta-V estimate when the cadence or caller requires it."
function refresh_estimated_min_delta_v!(gamestate::GameState, gamemap::GameMap; force::Bool = false)
    if force || gamestate.ticks == 0 || gamestate.ticks % DELTA_V_CACHE_TICK_DIVISOR == 0
        @timeit flowcalc_loop_timer "Update Delta-V Cache" gamestate.estimated_min_delta_v = estimate_min_delta_v(gamemap)
    end
    return nothing
end

# ===============================================================
# Triple-Buffered Snapshot Storage
# ===============================================================

"""
Create triple-buffered snapshot storage for thread-safe IPC.

Returns `(publish_snapshot!, get_snapshot)` closures. The publish closure fills
the writer buffer in-place and swaps it into the ready slot. The get closure swaps
the ready slot into the reader slot and returns it. The lock is held only during
the index swaps (two integer writes), never during data copying.

Three buffers are needed (not two) because at >1x sim speed the background thread
may complete multiple ticks per render frame. With only two buffers, the second tick
would overwrite the buffer the render thread is still reading. Triple buffering
guarantees the writer, ready, and reader slots are always distinct, so neither thread
ever touches the other's active buffer.
"""
function create_snapshot_storage(initial_snapshot::FlowCalculatorSnapshot)
    # All three buffers seeded so the render thread has valid data before the first BG tick
    buffers = (
        deepcopy(initial_snapshot),
        deepcopy(initial_snapshot),
        deepcopy(initial_snapshot),
    )
    writer_idx = Threads.Atomic{Int}(1)
    ready_idx  = Threads.Atomic{Int}(2)
    reader_idx = Threads.Atomic{Int}(3)
    has_new_data = Threads.Atomic{Int}(0)  # 1 when writer has published but reader hasn't consumed
    snapshot_lock = ReentrantLock()

    "Fill the writer buffer from live state and swap it into the ready slot."
    function publish_flowcalc_snapshot!(gamemap::GameMap, derived::DerivedMapState, mna_state::MNA_State, gamestate::GameState, timestamp::Float64)
        buf = buffers[writer_idx[]]

        # GameMap: deepcopy (contains mutable component leaf state)
        buf.gamemap = deepcopy(gamemap)
        # DerivedMapState: in-place refill (all containers hold immutable values)
        snapshot!(buf.derived, derived)
        # MNA_State → MNA_StateSnapshot: in-place refill of the render-relevant subset
        snapshot!(buf.mna, mna_state)
        # GameState: field copy (4 isbits fields)
        snapshot!(buf.gamestate, gamestate)
        buf.timestamp = timestamp

        # Swap writer and ready under lock, signal new data available
        Base.@lock snapshot_lock begin
            old_ready = ready_idx[]
            ready_idx[] = writer_idx[]
            writer_idx[] = old_ready
            has_new_data[] = 1
        end
        return nothing
    end

    "Swap the ready buffer into the reader slot and return it. Only swaps when new data is available."
    function get_flowcalc_snapshot()::FlowCalculatorSnapshot
        Base.@lock snapshot_lock begin
            if has_new_data[] == 1
                old_ready = ready_idx[]
                ready_idx[] = reader_idx[]
                reader_idx[] = old_ready
                has_new_data[] = 0
            end
        end

        return buffers[reader_idx[]]
    end

    return publish_flowcalc_snapshot!, get_flowcalc_snapshot
end

# ===============================================================
# Thread-Safe Console Buffer
# ===============================================================

"""
Thread-safe console message buffer using closure pattern.
Returns `(push_function, see_function)` for console access.
"""
function create_threadsafe_consolebuffer(capacity::Int)
    if capacity < 1
        error("Invalid console buffer capacity (must be at least 1)")
    end

    local msg_buffer = String[]
    local console_lock = ReentrantLock()

    "Thread-safe push: appends a timestamped message, evicting the oldest if over capacity."
    function push_message(msg::String)
        lock(console_lock) do
            timestamp = Dates.format(now(), "HH:MM:SS")
            stamped_msg = "[$timestamp]: $msg"
            push!(msg_buffer, stamped_msg)
            if length(msg_buffer) > capacity
                popfirst!(msg_buffer)
            end
        end
        return nothing
    end

    "Thread-safe read: returns a shallow copy of the message buffer."
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
Create a command queue with bounded capacity.
Returns a `CommandQueue` with encapsulated channel and atomic ID counter.
"""
function create_command_queue(capacity::Int = 32)
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
Apply a map edit command directly to the `gamemap` without sandbox validation.
Returns `true` if the mutation was applied, `false` if an internal check refused it.
Dispatches on concrete command type.
"""
function apply_mapedit_command!(
        gamemap::GameMap,
        command::SetTileCommand,
        threadsafe_console_push::Function
    )::Bool
    # Determine which ship this component belongs to via placement_valid on each ship
    mapped_rotation = map_rotation(command.component, command.rotation)
    mapped_mirror = map_mirroring(command.component, command.mirrored)
    target_ship = find_ship_for_placement(
        command.component, command.coord, gamemap;
        rotation = mapped_rotation, mirrored = mapped_mirror
    )

    if isnothing(target_ship)
        threadsafe_console_push("Cannot place component: Not a valid placement on any ship")
        return false
    end

    # Check if tile already occupied anywhere
    existing_comptile = get_component(gamemap, command.coord)
    if !isnothing(existing_comptile)
        threadsafe_console_push("Cannot place component: Tile is already occupied on $(existing_comptile.ship)")
        return false
    end

    set_component!(gamemap, command.coord, PlacedComponent(deepcopy(command.component), mapped_rotation, mapped_mirror, target_ship))
    threadsafe_console_push("Component placed at $(command.coord) on $(target_ship)")
    return true
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::SetPipeBehaviorCommand,
        threadsafe_console_push::Function
    )::Bool
    # Check if edge is already occupied anywhere
    existing_pipe = get_pipe(gamemap, command.coord)
    if !isnothing(existing_pipe)
        threadsafe_console_push("Cannot place pipe: Edge already occupied on $(existing_pipe.ship)")
        return false
    end

    # Try on-surface placement first, then off-ship fallback
    target_ship = find_ship_containing(gamemap, command.coord)

    if !isnothing(target_ship)
        can_place, reason = can_place_pipe_at(command.coord, gamemap; ship_name = target_ship)
        if !can_place
            threadsafe_console_push("Cannot place pipe: $(reason)")
            return false
        end

        set_pipe!(gamemap, command.coord, PlacedPipe(deepcopy(command.pipe_behavior), target_ship))
        threadsafe_console_push("Pipe placed at $(command.coord) on $(target_ship)")
        return true
    end

    # Not on any single ship — try off-ship pipe placement (extending from a ship into space)
    can_place, offship_target, reason = can_place_pipe_offship(command.coord, gamemap)
    if can_place
        set_pipe!(gamemap, command.coord, PlacedPipe(deepcopy(command.pipe_behavior), offship_target))
        threadsafe_console_push("Off-ship pipe placed at $(command.coord) on $(offship_target)")
        return true
    end
    threadsafe_console_push("Cannot place pipe: $(reason)")
    return false
    
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::MoveCommand{TileCoord},
        threadsafe_console_push::Function
    )::Bool
    source_comptile = get_component(gamemap, command.source_coord)
    if isnothing(source_comptile)
        threadsafe_console_push("Cannot move: No component at source $(command.source_coord)")
        return false
    end
    source_ship = source_comptile.ship

    # Check if the component can be moved
    can_move, reason = can_be_moved(source_comptile)
    if !can_move
        threadsafe_console_push("Component cannot be moved: $reason")
        return false
    end

    # Calculate new rotation
    new_rotation = map_rotation(source_comptile.component, rotate(source_comptile.rotation, command.delta_rotation))
    requested_mirror = xor(source_comptile.mirrored, command.delta_mirror)
    new_mirrored = map_mirroring(source_comptile, requested_mirror)

    # Same-coord move: rotate component in place
    if command.source_coord == command.dest_coord
        rotated_comptile = PlacedComponent(source_comptile.component, new_rotation, new_mirrored, source_ship)
        is_valid, reason = placement_valid(rotated_comptile, command.source_coord, gamemap; ship_name = source_ship)
        if !is_valid
            threadsafe_console_push("Cannot rotate in place: $reason")
            return false
        end

        set_component!(gamemap, command.source_coord, rotated_comptile)
        threadsafe_console_push("Component rotated in place at $(command.source_coord)")
        return true
    end

    # Determine destination ship via placement_valid
    dest_ship = find_ship_for_placement(
        source_comptile.component, command.dest_coord, gamemap;
        rotation = new_rotation, mirrored = new_mirrored
    )

    if isnothing(dest_ship)
        threadsafe_console_push("Cannot move: Destination $(command.dest_coord) not valid for any ship")
        return false
    end

    # Check destination not already occupied
    existing_dest = get_component(gamemap, command.dest_coord)
    if !isnothing(existing_dest)
        threadsafe_console_push("Cannot move: Destination tile already occupied on $(existing_dest.ship)")
        return false
    end

    # Perform move (potentially cross-ship)
    dest_comptile = PlacedComponent(source_comptile.component, new_rotation, new_mirrored, dest_ship)
    set_component!(gamemap, command.dest_coord, dest_comptile)
    delete_component!(gamemap, command.source_coord)

    if source_ship == dest_ship
        threadsafe_console_push("Component moved on $(source_ship) from $(command.source_coord) to $(command.dest_coord)")
    else
        threadsafe_console_push("Component moved from $(source_ship) to $(dest_ship)")
    end
    return true
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::MoveCommand{PipeCoord},
        threadsafe_console_push::Function
    )::Bool
    source_pipe = get_pipe(gamemap, command.source_coord)
    if isnothing(source_pipe)
        threadsafe_console_push("Cannot move: No pipe at source $(command.source_coord)")
        return false
    end

    # Check if source pipe is off-surface — validate that removing it won't orphan connected pipes
    src_v1_on = is_node_on_any_ship_surface(to_nodecoord(command.source_coord.v1), gamemap)
    src_v2_on = is_node_on_any_ship_surface(to_nodecoord(command.source_coord.v2), gamemap)
    source_is_offship = !(src_v1_on && src_v2_on)

    if source_is_offship
        if !validate_offship_pipe_deletion(command.source_coord, gamemap)
            threadsafe_console_push("Cannot move pipe: would orphan connected off-surface pipes")
            return false
        end
    end

    # Determine destination ship — try on-surface first, then off-ship fallback
    dest_ship = find_ship_containing(gamemap, command.dest_coord)

    if !isnothing(dest_ship)
        can_place, reason = can_place_pipe_at(command.dest_coord, gamemap; ship_name = dest_ship)
        if !can_place
            threadsafe_console_push("Cannot move pipe: $(reason)")
            return false
        end
    else
        # Try off-ship placement
        can_place, offship_target, reason = can_place_pipe_offship(command.dest_coord, gamemap)
        if can_place
            dest_ship = offship_target
        else
            threadsafe_console_push("Cannot move pipe: $(reason)")
            return false
        end
    end

    # Check destination not already occupied (across all ships)
    if has_pipe(gamemap, command.dest_coord)
        threadsafe_console_push("Cannot move pipe: destination coordinate already occupied")
        return false
    end

    # Perform move
    delete_pipe!(gamemap, command.source_coord)
    set_pipe!(gamemap, command.dest_coord, PlacedPipe(source_pipe.pipe, dest_ship))

    # Reassign ownership if source was off-surface (removing it may have split a chain)
    if source_is_offship
        reassign_pipe_ownership!(command.source_coord, gamemap)
    end

    threadsafe_console_push("Pipe moved from $(command.source_coord) to $(command.dest_coord)")
    return true
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::DeleteAtCommand{TileCoord},
        threadsafe_console_push::Function
    )::Bool
    existing_comp = get_component(gamemap, command.coord)
    if !isnothing(existing_comp)
        delete_component!(gamemap, command.coord)
        threadsafe_console_push("Component deleted at $(command.coord) from $(existing_comp.ship)")
        return true
    end
    threadsafe_console_push("No component found at $(command.coord)")
    return false
    
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::DeleteAtCommand{PipeCoord},
        threadsafe_console_push::Function
    )::Bool
    existing_pipe = get_pipe(gamemap, command.coord)
    if isnothing(existing_pipe)
        threadsafe_console_push("No pipe found at $(command.coord)")
        return false
    end

    # Check if pipe is off-surface — validate deletion won't orphan connected pipes
    v1_on = is_node_on_any_ship_surface(to_nodecoord(command.coord.v1), gamemap)
    v2_on = is_node_on_any_ship_surface(to_nodecoord(command.coord.v2), gamemap)
    is_offship = !(v1_on && v2_on)

    if is_offship && !validate_offship_pipe_deletion(command.coord, gamemap)
        threadsafe_console_push("Cannot delete: would orphan connected off-surface pipes")
        return false
    end

    delete_pipe!(gamemap, command.coord)
    threadsafe_console_push("Pipe deleted at $(command.coord) from $(existing_pipe.ship)")

    # Reassign ownership if the deleted pipe was off-surface (may have split a chain)
    if is_offship
        reassign_pipe_ownership!(command.coord, gamemap)
    end

    return true
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::ClickTileCommand,
        threadsafe_console_push::Function
    )::Bool
    tilecomp = get_component(gamemap, command.coord)
    if isnothing(tilecomp)
        threadsafe_console_push("No component at $(command.coord)")
        return false
    end

    on_click!(tilecomp; unrotated_clicksite = command.unrotated_clicksite)
    threadsafe_console_push("Clicked component at $(command.coord) on $(tilecomp.ship)")
    return true
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::DoActionCommand,
        threadsafe_console_push::Function
    )::Bool
    tilecomp = get_component(gamemap, command.coord)
    if isnothing(tilecomp)
        threadsafe_console_push("No component at $(command.coord)")
        return false
    end

    success, message = do_action!(tilecomp, command.action_id)
    threadsafe_console_push(message)
    return success
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::AddShipSurfaceCommand,
        threadsafe_console_push::Function
    )::Bool
    coord = command.coord

    # Find which ships have adjacent surfaces
    adjacent_ships = find_ships_adjacent_to_coord(gamemap, coord)

    if isempty(adjacent_ships)
        threadsafe_console_push("Cannot add surface: Must be adjacent to existing surface")
        return false
    end

    if length(adjacent_ships) > 1
        threadsafe_console_push("Cannot add surface: Would connect multiple ships ($(adjacent_ships))")
        return false
    end

    target_ship = adjacent_ships[1]

    # Check not already on surface
    if is_on_surface_tile(coord, gamemap; ship_name = target_ship)
        threadsafe_console_push("Surface already exists at $(coord) on $(target_ship)")
        return false
    end

    set_surface_tile!(gamemap, coord; ship_name = target_ship)
    threadsafe_console_push("Surface added at $(coord) on $(target_ship)")
    return true
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::RemoveShipSurfaceCommand,
        threadsafe_console_push::Function
    )::Bool
    coord = command.coord

    # Find which ship owns this surface tile
    ship_with_surface = get_surface_shiptag(gamemap, coord)
    if isnothing(ship_with_surface)
        threadsafe_console_push("No surface at $(coord)")
        return false
    end

    # Check if removing would leave a component without surface
    if has_component(gamemap, coord)
        threadsafe_console_push("Cannot remove surface: Component present (delete component first)")
        return false
    end

    # Check if this is the last surface tile on this ship
    if count_surface_tiles(gamemap; ship_name = ship_with_surface) <= 1
        threadsafe_console_push("Cannot remove surface: Cannot delete last surface tile on $(ship_with_surface)")
        return false
    end

    delete_surface_tile!(gamemap, coord; ship_name = ship_with_surface)
    threadsafe_console_push("Surface removed at $(coord) from $(ship_with_surface)")
    return true
end

"Replace all fields of `dest` with values from `src` (same concrete type). Keeps the original object reference."
function replace_by_mutation!(dest::T, src::T) where {T}
    @assert typeof(dest) === typeof(src)
    for f in fieldnames(T)
        setfield!(dest, f, getfield(src, f))
    end
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::MapOverrideCommand,
        threadsafe_console_push::Function
    )::Bool
    # Deepcopy the provided map to avoid sharing mutable state
    newmap = deepcopy(command.new_map)

    replace_by_mutation!(gamemap, newmap)

    numtiles = count_surface_tiles(newmap)
    numcomps = count_components(newmap)
    numpipes = count_pipes(newmap)
    threadsafe_console_push("Map override applied with $numtiles surfaces, $numcomps tiles, and $numpipes pipes")

    return true
end

"Add an encounter ship, with optional encounter point recycling for live encounters."
function apply_mapedit_command!(
        gamemap::GameMap,
        command::AddEncounterShipCommand,
        threadsafe_console_push::Function
    )::Bool
    if command.dir === nothing
        encounter_ship_optimal_dir!(gamemap, command.blueprint, command.ship_name_base,
            command.seed; max_view_bounds = command.max_view_bounds)
    else
        encounter_ship!(gamemap, command.blueprint, command.ship_name_base,
            command.seed, command.dir; max_view_bounds = command.max_view_bounds)
    end

    # Recycle encounter point and clear manoeuvre if this is a live encounter
    if command.target_encounter_index !== nothing
        sm = gamemap.space_map
        ep = sm.encounter_points[command.target_encounter_index]
        spawn_encounter_point!(ep, sm, sm.time_years)
        clear_active_manoeuvre!(gamemap)
        threadsafe_console_push("Encounter triggered: $(command.ship_name_base)")
    end

    return true
end

"""
Relocate a non-primary ship by a tile offset. Validates the shared docking
footprints before setting up an `ApproachingDockStat` to animate the move.
"""
function apply_mapedit_command!(
        gamemap::GameMap,
        command::RedockShipCommand,
        threadsafe_console_push::Function
    )::Bool
    if command.ship_name === :primary
        threadsafe_console_push("Cannot redock the primary ship")
        return false
    end

    ship = get_ship_state(gamemap, command.ship_name)

    if !(ship.docking_status isa ConnectedDockStat)
        threadsafe_console_push("Ship $(command.ship_name) is not in a connected state")
        return false
    end

    other_exclusion = docking_footprint_excluding(
        gamemap, command.ship_name; surface_clearance = DOCKING_SURFACE_CLEARANCE
    )
    ship_footprint = docking_footprint_including(gamemap, command.ship_name)
    if ship_footprints_overlap(other_exclusion, ship_footprint, command.offset)
        threadsafe_console_push("Redock position conflicts with another ship's docking clearance")
        return false
    end

    # Validation passed, perform the move on the real map
    offset_ship!(gamemap, command.ship_name, command.offset)

    # Set up approach animation: render offset starts at old position, animates to zero
    anim_offset = AxialCoord(Float64(-command.offset.q), Float64(-command.offset.r))
    target_offset = AxialCoord(0.0, 0.0)
    distance = sqrt(anim_offset.q^2 + anim_offset.r^2)
    duration_secs = clamp(distance / 3.0, 0.5, 5.0)
    step = distance > 0.0 ? distance / (duration_secs * BASE_UPS) : 0.01

    ship.docking_status = ApproachingDockStat(anim_offset, target_offset, step)
    threadsafe_console_push("Ship $(command.ship_name) relocated")

    return true
end

"Write `status` to a command's response channel if one is attached.\nSwallows put! errors so a closed channel cannot crash the calculator loop."
function _try_put_status!(command::MapEditCommand, status::CommandStatus)
    command.response_channel === nothing && return nothing
    try
        put!(command.response_channel, status)
    catch
        # Channel may be closed; ignore — same policy as before.
    end
    return nothing
end

"""
Validate and apply a map edit command using sandbox-first execution.
Applies the command to a deep copy first; only mutates the real `gamemap` if the
sandbox survives a full `update_map!` / `update_mna!` cycle.
"""
function process_command!(
        command::MapEditCommand,
        gamemap::GameMap,
        threadsafe_console_push::Function;
        throw_errors::Bool = true
    )
    # Create sandbox copy for validation
    sandbox = deepcopy(gamemap)
    original_hash = hash(sandbox)

    try
        # Dry-run on the sandbox with a silent console. The return value is
        # discarded here — the real-map call below decides the final status.
        apply_mapedit_command!(sandbox, command, (msg) -> nothing)
        new_hash = hash(sandbox)

        # If map changed, validate it won't cause errors
        if new_hash != original_hash
            test_derivedmapstate = DerivedMapState()
            test_mna_state = MNA_State()
            test_scratchpad = CalculatorScratchpad()

            # Validate using the non-speculative path (no reactivation probes during sandbox)
            update_components!(sandbox, test_mna_state, test_derivedmapstate)
            collect_primary_map_inputs!(sandbox, test_derivedmapstate)
            update_map_from_inputs!(test_derivedmapstate, test_mna_state, test_scratchpad, Int64(0))
            update_mna!(test_derivedmapstate, test_mna_state, Int64(0))
            compute_region_temperatures!(test_derivedmapstate, test_scratchpad, test_mna_state)
        end

        applied = apply_mapedit_command!(gamemap, command, threadsafe_console_push)
        _try_put_status!(command, applied ? APPLIED : INVALID)

    catch sandbox_error
        threadsafe_console_push("Invalid map edit: $(sandbox_error)")
        _try_put_status!(command, REJECTED)

        if throw_errors
            @warn "Rethrowing sandbox error" exception = sandbox_error
            rethrow(sandbox_error)
        end
    end
    return nothing
end

# ===============================================================
# Command Generation Helpers
# ===============================================================

"Create a `SetTileCommand` for placing a component."
function create_set_tile_command(
        cq::CommandQueue,
        coord::TileCoord,
        component::ComponentBehavior,
        rotation::HexAxis,
        mirrored::Bool = false;
        response_channel::Union{Nothing, Channel} = nothing
    )::SetTileCommand
    return SetTileCommand(
        id = cq.next_command_id(),
        coord = coord,
        component = component,
        rotation = rotation,
        mirrored = mirrored,
        response_channel = response_channel
    )
end

"Create a `SetPipeBehaviorCommand` for placing a pipe."
function create_set_pipe_behavior_command(
        cq::CommandQueue,
    coord::PipeCoord,
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

"Create a `MoveCommand` for moving an element."
function create_move_command(
        cq::CommandQueue,
        source_coord::T,
        dest_coord::T,
        delta_rotation::HexAxis,
        delta_mirror::Bool = false;
        response_channel::Union{Nothing, Channel} = nothing
    ) where {T <: Union{TileCoord, PipeCoord}}
    return MoveCommand{T}(
        id = cq.next_command_id(),
        source_coord = source_coord,
        dest_coord = dest_coord,
        delta_rotation = delta_rotation,
        delta_mirror = delta_mirror,
        response_channel = response_channel
    )
end

"Create a `DeleteAtCommand` for deleting a component or pipe."
function create_delete_command(
        cq::CommandQueue,
        coord::T;
        response_channel::Union{Nothing, Channel} = nothing
    ) where {T <: Union{TileCoord, PipeCoord}}
    return DeleteAtCommand{T}(
        id = cq.next_command_id(),
        coord = coord,
        response_channel = response_channel
    )
end

"Create a `ClickTileCommand` for tile interaction."
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

"Create a `DoActionCommand` for executing a named action on a tile component."
function create_do_action_command(
        cq::CommandQueue,
        coord::TileCoord,
        action_id::Symbol;
        response_channel::Union{Nothing, Channel} = nothing
    )::DoActionCommand
    return DoActionCommand(
        id = cq.next_command_id(),
        coord = coord,
        action_id = action_id,
        response_channel = response_channel
    )
end

"Create an `AddShipSurfaceCommand`."
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

"Create a `RemoveShipSurfaceCommand`."
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

"Create a `MapOverrideCommand` to replace the current map."
function create_map_override_command(
        cq::CommandQueue,
        new_map::GameMap;
        response_channel::Union{Nothing, Channel} = nothing
    )::MapOverrideCommand
    return MapOverrideCommand(
        id = cq.next_command_id(),
        new_map = deepcopy(new_map),
        response_channel = response_channel
    )
end

"Create an `AddEncounterShipCommand` to add a generated encounter ship."
function create_add_encounter_ship_command(
        cq::CommandQueue, blueprint::ShipBlueprint, ship_name_base::String, seed::UInt32;
        dir::Union{Nothing, HexFrame.HexAxis} = nothing,
        target_encounter_index::Union{Nothing, Int} = nothing,
        max_view_bounds::Union{Nothing, HexFrame.CartesianBounds} = nothing,
        response_channel::Union{Nothing, Channel} = nothing
    )::AddEncounterShipCommand
    return AddEncounterShipCommand(
        id = cq.next_command_id(),
        blueprint = deepcopy(blueprint),
        ship_name_base = ship_name_base,
        seed = seed,
        dir = dir,
        target_encounter_index = target_encounter_index,
        max_view_bounds = max_view_bounds,
        response_channel = response_channel
    )
end

"Create a `RedockShipCommand` to relocate a ship by a tile offset."
function create_redock_ship_command(
        cq::CommandQueue,
        ship_name::Symbol,
        offset::TileCoord;
        response_channel::Union{Nothing, Channel} = nothing
    )::RedockShipCommand
    return RedockShipCommand(
        id = cq.next_command_id(),
        ship_name = ship_name,
        offset = offset,
        response_channel = response_channel
    )
end

"""
Enqueue a command onto the command channel (currently blocking).
Returns `(success::Bool, status::CommandStatus)`.
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
# Reactivation Scheduler
# ===============================================================

"""
Calculator-thread-only state for the speculative reactivation system.

Each tick the scheduler scans all components for pending reactivation requests.
At most one probe is executed per tick (FIFO fairness). Stale queue entries are
silently discarded at execution time by re-resolving the component from the map.

The `probe_elements` and `probe_declarations` vectors are reusable scratch space
for the probe-specific circuit additions. Before each trial they are loaded with
only the new elements from the probe; the normal primary collections are extended
with these and then restored after the trial solve completes.

"""
@kwdef mutable struct ReactivationScheduler
    pending::Vector{TileCoord} = Vector{TileCoord}()       # FIFO queue of tile coords awaiting a probe
    pending_set::Set{TileCoord} = Set{TileCoord}()         # duplicate-guard for O(1) membership test
    neutral_registry::Set{TileCoord} = Set{TileCoord}()    # solo-neutral candidates eligible for grouped retry
    grouped_coords::Vector{TileCoord} = Vector{TileCoord}()    # scratch coord list for grouped retries
    probe_elements::Vector{AbsoluteElement} = Vector{AbsoluteElement}()       # probe-only elements (not a copy of primary)
    probe_declarations::Vector{AbsFluidDecl} = Vector{AbsFluidDecl}()         # probe-only declarations
    trial_derivedmapstate::DerivedMapState = DerivedMapState()
    trial_mna_state::MNA_State = MNA_State()
    trial_scratchpad::CalculatorScratchpad = CalculatorScratchpad()
end

"Reinitialise the scheduler's isolated trial solve state after a failed speculative solve."
function reset_reactivation_trial_state!(scheduler::ReactivationScheduler)
    scheduler.trial_derivedmapstate = DerivedMapState()
    scheduler.trial_mna_state = MNA_State()
    scheduler.trial_scratchpad = CalculatorScratchpad()
    return nothing
end

"Add a coord to the neutral registry. Set.push! is idempotent, so duplicates are naturally handled."
function push_neutral_registry!(scheduler::ReactivationScheduler, coord::TileCoord)
    push!(scheduler.neutral_registry, coord)
    return nothing
end

"Remove a coord from the neutral registry if present. Set.delete! is idempotent."
function drop_neutral_registry!(scheduler::ReactivationScheduler, coord::TileCoord)
    delete!(scheduler.neutral_registry, coord)
    return nothing
end

"Remove a coord from the pending FIFO and duplicate guard if present."
function drop_pending_coord!(scheduler::ReactivationScheduler, coord::TileCoord)
    coord in scheduler.pending_set || return nothing
    delete!(scheduler.pending_set, coord)
    filter!(pending_coord -> pending_coord != coord, scheduler.pending)
    return nothing
end

"Drop neutral-registry entries whose component disappeared or no longer requests a probe."
function prune_neutral_registry!(scheduler::ReactivationScheduler, gamemap::GameMap)
    filter!(scheduler.neutral_registry) do coord
        comp = get_component(gamemap, coord)
        !isnothing(comp) && !isnothing(get_reactivation_probe(comp))
    end
    return nothing
end

"""
Scan all components for pending reactivation probe requests and enqueue new ones.

Components already in the queue are skipped (deduplication via `pending_set`).
"""
function scan_reactivation_requests!(scheduler::ReactivationScheduler, gamemap::GameMap)
    for (coord, comp) in gamemap.components
        coord in scheduler.pending_set && continue
        isnothing(get_reactivation_probe(comp)) && continue
        push!(scheduler.pending, coord)
        push!(scheduler.pending_set, coord)
    end
    return nothing
end


"""
Map the currently requested probe into the provided output vectors.

Only active probe elements are carried through, matching the normal map-input
collector. Element IDs still use the original tuple indices so dependent probes
can preserve their component-local numbering.
"""
function append_reactivation_probe!(
        probe_elements::Vector{AbsoluteElement},
        probe_declarations::Vector{AbsFluidDecl},
        comp::PlacedComponent,
        coord::TileCoord
    )
    probe = get_reactivation_probe(comp)
    isnothing(probe) && throw(ArgumentError("Component at $coord does not currently request a reactivation probe"))

    for (i, rel_elem) in pairs(probe.rel_elements)
        rel_elem.active || continue
        push!(probe_elements, map_element(rel_elem, coord, i, comp.rotation, comp.mirrored))
    end

    for rel_decl in probe.rel_fluid_declarations
        push!(probe_declarations, map_declaration(rel_decl, coord, comp.rotation, comp.mirrored))
    end

    return nothing
end


"Map the currently requested probe into the provided output vectors, replacing any previous contents."
function load_reactivation_probe!(
        probe_elements::Vector{AbsoluteElement},
        probe_declarations::Vector{AbsFluidDecl},
        comp::PlacedComponent,
        coord::TileCoord
    )
    empty!(probe_elements)
    empty!(probe_declarations)
    append_reactivation_probe!(probe_elements, probe_declarations, comp, coord)
    return nothing
end


"""
Load the probe's mapped elements and declarations into the scheduler's scratch buffers.

Only stores elements/declarations contributed by the probe itself — not copies of the
primary collections. The caller is responsible for appending these to
`derivedmapstate.primaryelements`/`primary_fluid_declarations` before the trial solve
and restoring the original lengths afterwards.
"""
function load_reactivation_probe!(
        scheduler::ReactivationScheduler,
        comp::PlacedComponent,
        coord::TileCoord
    )
    load_reactivation_probe!(scheduler.probe_elements, scheduler.probe_declarations, comp, coord)
    return nothing
end

"Load mapped probes for all supplied coords into the scheduler scratch buffers."
function load_reactivation_probes!(scheduler::ReactivationScheduler, gamemap::GameMap, coords::AbstractVector{TileCoord})
    empty!(scheduler.probe_elements)
    empty!(scheduler.probe_declarations)

    for coord in coords
        comp = get_component(gamemap, coord)
        isnothing(comp) && throw(ArgumentError("Component at $coord no longer exists"))
        append_reactivation_probe!(scheduler.probe_elements, scheduler.probe_declarations, comp, coord)
    end

    return nothing
end

"Copy the live primary inputs into the isolated trial state, then append the current probe inputs."
function seed_reactivation_trial_inputs!(scheduler::ReactivationScheduler, derivedmapstate::DerivedMapState)
    trial_derivedmapstate = scheduler.trial_derivedmapstate

    resize!(trial_derivedmapstate.primaryelements, length(derivedmapstate.primaryelements))
    copyto!(trial_derivedmapstate.primaryelements, derivedmapstate.primaryelements)
    append!(trial_derivedmapstate.primaryelements, scheduler.probe_elements)

    resize!(trial_derivedmapstate.primary_fluid_declarations, length(derivedmapstate.primary_fluid_declarations))
    copyto!(trial_derivedmapstate.primary_fluid_declarations, derivedmapstate.primary_fluid_declarations)
    append!(trial_derivedmapstate.primary_fluid_declarations, scheduler.probe_declarations)

    return trial_derivedmapstate
end

"Solve the currently loaded speculative trial inputs into the scheduler-owned trial state."
function solve_reactivation_trial!(scheduler::ReactivationScheduler, derivedmapstate::DerivedMapState, current_tick::Int64)::Bool
    trial_derivedmapstate = seed_reactivation_trial_inputs!(scheduler, derivedmapstate)

    try
        solve_from_inputs!(trial_derivedmapstate, scheduler.trial_mna_state, scheduler.trial_scratchpad, current_tick)
        return true
    catch
        reset_reactivation_trial_state!(scheduler)
        return false
    end
end

"Classify one component against the scheduler's current speculative trial state." 
function classify_trial_outcome(comp::PlacedComponent, coord::TileCoord, gamemap::GameMap, scheduler::ReactivationScheduler)::ReactivationProbeOutcome
    return classify_reactivation_probe(comp;
        tile = coord,
        ship_name = comp.ship,
        gamemap = gamemap,
        derivedmapstate = scheduler.trial_derivedmapstate,
        mna_state = scheduler.trial_mna_state,
    )
end

"Commit one useful component against the scheduler's current speculative trial state." 
function commit_trial_outcome!(comp::PlacedComponent, coord::TileCoord, gamemap::GameMap, scheduler::ReactivationScheduler)
    commit_reactivation_probe!(comp;
        tile = coord,
        ship_name = comp.ship,
        gamemap = gamemap,
        derivedmapstate = scheduler.trial_derivedmapstate,
        mna_state = scheduler.trial_mna_state,
    )
    return nothing
end

"Attempt one grouped retry using the current neutral registry."
function attempt_grouped_neutral_retry!(
        scheduler::ReactivationScheduler,
        gamemap::GameMap,
        derivedmapstate::DerivedMapState,
        current_tick::Int64
    )
    prune_neutral_registry!(scheduler, gamemap)
    length(scheduler.neutral_registry) > 1 || return nothing

    empty!(scheduler.grouped_coords)
    append!(scheduler.grouped_coords, scheduler.neutral_registry)

    try
        load_reactivation_probes!(scheduler, gamemap, scheduler.grouped_coords)
    catch
        reset_reactivation_trial_state!(scheduler)
        prune_neutral_registry!(scheduler, gamemap)
        return nothing
    end

    solve_reactivation_trial!(scheduler, derivedmapstate, current_tick) || return nothing

    useful_coords = TileCoord[]
    harmful_coords = TileCoord[]

    for coord in scheduler.grouped_coords
        comp = get_component(gamemap, coord)
        isnothing(comp) && continue

        outcome = try
            classify_trial_outcome(comp, coord, gamemap, scheduler)
        catch
            drop_neutral_registry!(scheduler, coord)
            return nothing
        end

        if outcome === HexComponentsAPI.PROBE_USEFUL
            push!(useful_coords, coord)
        elseif outcome === HexComponentsAPI.PROBE_HARMFUL
            push!(harmful_coords, coord)
        end
    end

    if !isempty(harmful_coords)
        for coord in harmful_coords
            drop_neutral_registry!(scheduler, coord)
        end
        return nothing
    end

    for coord in useful_coords
        comp = get_component(gamemap, coord)
        isnothing(comp) && continue
        commit_trial_outcome!(comp, coord, gamemap, scheduler)
        drop_neutral_registry!(scheduler, coord)
        drop_pending_coord!(scheduler, coord)
    end

    return nothing
end

"""
Attempt one speculative reactivation probe from the scheduler queue.

Pops candidate coords from the front of the queue, discarding stale entries, until a valid
target is found or the queue is exhausted. Returns `true` if a speculative attempt was made,
or `false` if the queue was empty.

Speculative trials run on scheduler-owned trial state so a singular or otherwise invalid probe
cannot poison the live MNA cache. After any attempted trial, the live primary inputs are
recollected and the committed solve is rerun on the live state.
"""
function run_reactivation_trial!(
        scheduler::ReactivationScheduler,
        gamemap::GameMap,
        derivedmapstate::DerivedMapState,
        mna_state::MNA_State,
        scratchpad::CalculatorScratchpad,
        current_tick::Int64
    )::Bool
    while !isempty(scheduler.pending)
        # Pop the next candidate (FIFO: remove from front)
        coord = popfirst!(scheduler.pending)
        delete!(scheduler.pending_set, coord)

        # Re-resolve: verify component still exists and still requests a probe (drops stale entries after map edits)
        comp = get_component(gamemap, coord)
        if isnothing(comp)
            drop_neutral_registry!(scheduler, coord)
            continue  # stale, try next
        end
        if isnothing(get_reactivation_probe(comp))
            drop_neutral_registry!(scheduler, coord)
            continue  # no longer requesting, skip
        end

        # Load probe-only elements/declarations into scheduler scratch buffers
        load_reactivation_probe!(scheduler, comp, coord)

        # Speculative solo solve — isolated by try/catch so a failure does not crash the loop.
        if solve_reactivation_trial!(scheduler, derivedmapstate, current_tick)
            trial_outcome = try
                classify_trial_outcome(comp, coord, gamemap, scheduler)
            catch
                drop_neutral_registry!(scheduler, coord)
                HexComponentsAPI.PROBE_HARMFUL
            end

            if trial_outcome === HexComponentsAPI.PROBE_USEFUL
                commit_trial_outcome!(comp, coord, gamemap, scheduler)
                drop_neutral_registry!(scheduler, coord)
            elseif trial_outcome === HexComponentsAPI.PROBE_HARMFUL
                drop_neutral_registry!(scheduler, coord)
            else
                push_neutral_registry!(scheduler, coord)
                attempt_grouped_neutral_retry!(scheduler, gamemap, derivedmapstate, current_tick)
            end
        else
            drop_neutral_registry!(scheduler, coord)
        end

        # Always rebuild the live solve from committed map state. Useful probes may mutate the
        # component, so the primary input collections must be refreshed before solving.
        collect_primary_map_inputs!(gamemap, derivedmapstate)
        solve_from_inputs!(derivedmapstate, mna_state, scratchpad, current_tick)

        return true  # one speculative attempt was processed this tick
    end

    return false  # queue was empty
end

#= ---------- Crash Dump Persistence ----------- =#

"""
Persist a crash dump for the FlowCalculator loop. Returns the file path written.

Drains the pending `MapEditCommand` channel into a Vector so the queue contents are
captured (subsequent ticks would not see them, but the loop is exiting anyway).
"""
function _write_crash_dump(gamemap::GameMap, mna_state::MNA_State,
        command_queue::CommandQueue, exception, trace_str::String)::String
    pending_commands = MapEditCommand[]
    while isready(command_queue.command_channel)
        push!(pending_commands, take!(command_queue.command_channel))
    end

    timestamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    crashpath = joinpath("maps", "crash_$(timestamp).jld2")
    mkpath(dirname(crashpath))

    jldsave(crashpath;
        stored_gamemap     = gamemap,
        pending_commands   = pending_commands,
        node_voltages      = mna_state.node_voltages,
        vsource_currents   = mna_state.vsource_currents,
        exception_message  = sprint(showerror, exception),
        exception_backtrace = trace_str,
    )

    return crashpath
end

# ===============================================================
# Map Update Functions
# ===============================================================

"""
Collect all primary map inputs from `gamemap` into `derivedmapstate`.

Fills `ship_surface_edge`, `primaryelements`, `primarynodes`, and
`primary_fluid_declarations`. Does not filter or solve — call
`update_map_from_inputs!` or `solve_from_inputs!` afterwards.
"""
function collect_primary_map_inputs!(gamemap::GameMap, derivedmapstate::DerivedMapState)
    @timeit flowcalc_loop_timer "find ship edge" collect_surface_edge_tiles!(derivedmapstate, gamemap)
    @timeit flowcalc_loop_timer "list elements" list_elements!(derivedmapstate.primaryelements, gamemap)
    @timeit flowcalc_loop_timer "list nodes" list_nodes!(derivedmapstate.primarynodes, derivedmapstate.primaryelements) # diagnostic only
    @timeit flowcalc_loop_timer "fluid declarations" list_fluid_declarations!(derivedmapstate.primary_fluid_declarations, gamemap)
    return nothing
end

"""
Run the graph-filter, fluid-type propagation, and MNA setup from `derivedmapstate.primaryelements`
and `derivedmapstate.primary_fluid_declarations`.
"""
function update_map_from_inputs!(
        derivedmapstate::DerivedMapState,
        mna_state::MNA_State,
        scratchpad::CalculatorScratchpad,
        current_tick::Int64
    )
    @timeit flowcalc_loop_timer "Map Updates" begin
        # Refill the working survivor vector from the primary elements, reusing storage.
        resize!(derivedmapstate.filteredelements, length(derivedmapstate.primaryelements))
        copyto!(derivedmapstate.filteredelements, derivedmapstate.primaryelements)

        # Iteratively prune until clear_dangling_dependants reaches a fixed point.
        # All three passes operate in-place on filteredelements through a single fixed-point loop.
        last_hash::UInt64 = 0
        while last_hash != hash(derivedmapstate.filteredelements)
            @timeit flowcalc_loop_timer "prune" prune!(derivedmapstate.filteredelements, scratchpad)
            @timeit flowcalc_loop_timer "grounding search" ground_search!(derivedmapstate.filteredelements, scratchpad)
            last_hash = hash(derivedmapstate.filteredelements)
            @timeit flowcalc_loop_timer "dangling dependants" clear_dangling_dependants!(derivedmapstate.filteredelements, scratchpad.dangling_dependant_element_id_set)
        end

        @timeit flowcalc_loop_timer "list filtered nodes" list_nodes!(derivedmapstate.filterednodes, derivedmapstate.filteredelements)
        @timeit flowcalc_loop_timer "index sources" index_grounded_source_elements!(scratchpad.filtered_source_element_index, derivedmapstate.filteredelements)

        if !isempty(derivedmapstate.filterednodes)
            @timeit flowcalc_loop_timer "index fluid declarations" index_fluid_declarations!(derivedmapstate, derivedmapstate.primary_fluid_declarations)
            @timeit flowcalc_loop_timer "node connections" build_node_connection_map!(scratchpad.final_nodeconnections, derivedmapstate.filteredelements)
            @timeit flowcalc_loop_timer "propagate fluid types" propagate_fluid_types!(derivedmapstate, scratchpad)
            @timeit flowcalc_loop_timer "MNA index nodes" MNA_indexnodes!(mna_state, derivedmapstate)
            @timeit flowcalc_loop_timer "MNA split elements" MNA_splitelements!(mna_state, derivedmapstate)

            # In-place A matrix construction + conditional LU refactorisation.
            # Structure changes (topology) trigger a full rebuild; value-only changes use
            # zero-alloc stamping into the existing sparse matrix + lu! refactorisation.
            @timeit flowcalc_loop_timer "MNA update A" MNA_updateA!(mna_state)
        else
            # Clear stale outputs so they don't continue to be rendered
            empty!(mna_state.node_voltages)
            empty!(mna_state.vsource_currents)
            empty!(mna_state.node_voltages_scaled)
            empty!(derivedmapstate.nodeactualfluids)
            empty!(derivedmapstate.node_declarations)
            empty!(derivedmapstate.source_nodes)
            empty!(derivedmapstate.node_to_region)
            empty!(derivedmapstate.region_temperatures)
            empty!(derivedmapstate.node_temperatures)
            mna_state.a_cache.structure_hash = UInt64(0) # reset structure cache
            mna_state.a_cache.value_hash = UInt64(0)     # reset value cache
            clear_calculator_scratchpad!(scratchpad)
        end
    end
    return nothing
end

"""
Run the full non-thruster solve pipeline from `derivedmapstate.primaryelements` and
`derivedmapstate.primary_fluid_declarations`.

Equivalent to `update_map_from_inputs!` + `update_mna!` + `compute_region_temperatures!`.
Used for both the normal tick path and speculative reactivation trials (which temporarily
extend the primary collections with probe elements before calling this).
"""
function solve_from_inputs!(
        derivedmapstate::DerivedMapState,
        mna_state::MNA_State,
        scratchpad::CalculatorScratchpad,
        current_tick::Int64
    )
    update_map_from_inputs!(derivedmapstate, mna_state, scratchpad, current_tick)
    update_mna!(derivedmapstate, mna_state, current_tick)
    compute_region_temperatures!(derivedmapstate, scratchpad, mna_state)
    return nothing
end

"""
Rebuild derived map state and MNA matrix from the current `gamemap`.
Called every tick (fast enough for now; may need revisiting if it becomes a bottleneck).
"""
function update_map!(gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State, scratchpad::CalculatorScratchpad, current_tick::Int64)
    collect_primary_map_inputs!(gamemap, derivedmapstate)
    update_map_from_inputs!(derivedmapstate, mna_state, scratchpad, current_tick)
    return nothing
end

# TODO: This closure hides mutable state (max_voltage_ever) with no way to reset on map reload.
# Consider replacing with a proper struct + reset! method in a future cleanup pass.
let max_voltage_ever::Float64 = -Inf
    "Normalise node voltages to [0, 1] for colour rendering. Tracks the historical maximum. Mutates `out` in-place."
    global function scale_voltage_dict!(out::Dict{NodeCoord, Float64}, dict::Dict{NodeCoord, Float64})
        if isempty(dict)
            empty!(out)
            return nothing
        end

        # Get the maximum value
        max_voltage_current = maximum(values(dict))
        max_voltage_ever = max(max_voltage_current, max_voltage_ever)

        # Scale so that the largest value is 1
        empty!(out)
        sizehint!(out, length(dict))
        for (key, value) in dict
            out[key] = value / max_voltage_ever
        end
        return nothing
    end
end

"Re-solve the MNA system (Z vector rebuild + linear solve). Called once per tick."
function update_mna!(derivedmapstate::DerivedMapState, mna_state::MNA_State, current_tick::Int64)
    if !isempty(derivedmapstate.filterednodes)
        @timeit flowcalc_loop_timer "MNA Solve" begin
            @timeit flowcalc_loop_timer "get Z" MNA_getZ!(mna_state)
            @timeit flowcalc_loop_timer "MNA solve" MNA_solve!(mna_state)
            @timeit flowcalc_loop_timer "MNA scale" scale_voltage_dict!(mna_state.node_voltages_scaled, mna_state.node_voltages)
        end
    end
    return nothing
end

"Sum thrust from all components, integrate velocity, and track burn progress during manoeuvres."
function handle_thrusters!(gamestate::GameState, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State; base_ups::Float64 = BASE_UPS)
    # Sum thrust from all components globally
    thrust = SVector{2, Float64}(0.0, 0.0)
    for (tile, comp) in gamemap.components
        thrust += get_thrust(comp; tile = tile, mna_state = mna_state, derivedmapstate = derivedmapstate)
    end
    gamestate.thrust = thrust

    # Acceleration in per-second units (thrust is a continuous force, F/m gives accel/s²)
    mass = get_mass(gamemap)
    accel_per_second = mass > 0.0 ? thrust / mass : SVector{2, Float64}(0.0, 0.0)

    # Default: ship space = space map space (no rotation)
    applied_accel_per_second = accel_per_second

    #= During a burn phase the ship conceptually rotates so that its +X axis
       aligns with the burn direction in space-map space.  We rotate the ship-
       space acceleration into space-map space for velocity integration, and
       subtract the raw ship-space acceleration from the ship-space remaining ΔV. =#
    if has_active_manoeuvre(gamemap)
        manoeuvre = get_active_manoeuvre(gamemap)
        phase = manoeuvre.phase
        if phase == PHASE_APPROACH_BURN || phase == PHASE_CAPTURE_BURN
            # Burn direction comes from the planned space-map ΔV vector
            burn_dv = phase == PHASE_APPROACH_BURN ? manoeuvre.approach_burn_dv : manoeuvre.capture_burn_dv
            burn_dir_mag = norm(burn_dv)
            burn_dir = burn_dir_mag > 1.0e-10 ? burn_dv / burn_dir_mag : SVector(1.0, 0.0)
            burn_angle = atan(burn_dir[2], burn_dir[1])
            c = cos(burn_angle)
            s = sin(burn_angle)

            # Rotate ship-space acceleration into space-map space
            applied_accel_per_second = SVector(
                c * accel_per_second[1] - s * accel_per_second[2],
                s * accel_per_second[1] + c * accel_per_second[2],
            )

            # Track burn progress in ship space: subtract ΔV gained this tick
            manoeuvre.burn_remaining_dv -= accel_per_second / base_ups
        end
    end

    # Store both frames for downstream consumers
    gamestate.acceleration_ship_frame = accel_per_second
    gamestate.acceleration_space_map_frame = applied_accel_per_second

    # Integrate velocity: one tick's worth of acceleration (space-map space)
    accel_per_tick = applied_accel_per_second / base_ups
    current_velocity = get_velocity(gamemap)
    new_velocity = current_velocity + accel_per_tick
    set_velocity!(gamemap, new_velocity)

    return nothing
end

const MANOEUVRE_COMPLETION_THRESHOLD = 0.05  # Absolute velocity units
const MANOEUVRE_THRUST_THRESHOLD = 0.1       # Thrust magnitude to count as "engines off"

#= ---------- Manoeuvre guard helpers ----------- =#

"""
Cancel the active manoeuvre if the ship is producing thrust above the detection
threshold. Returns `true` if the manoeuvre was cancelled.

Thrust during a non-burn phase (e.g. coasting or waiting) invalidates the planned
trajectory, so the manoeuvre must be abandoned.
"""
function cancel_if_thrust!(gamemap::GameMap, gamestate::GameState; console_push::Function = identity)::Bool
    norm(gamestate.thrust) <= MANOEUVRE_THRUST_THRESHOLD && return false
    clear_active_manoeuvre!(gamemap)
    console_push("Manoeuvre cancelled: thrust applied outside a burn phase.")
    return true
end

"""
Cancel the active manoeuvre if time is currently progressing (i.e. the target time
is ahead of the current time). Returns `true` if the manoeuvre was cancelled.

Time-warping during an active burn would skip thrust integration steps and corrupt
the ΔV budget.
"""
function cancel_if_time_progressing!(gamemap::GameMap; console_push::Function = identity)::Bool
    sm = gamemap.space_map
    !(sm isa SpaceMapState) && return false
    sm.target_time_years <= sm.time_years && return false
    clear_active_manoeuvre!(gamemap)
    console_push("Manoeuvre cancelled: time stepped during an active burn phase.")
    return true
end

"""
Cancel if the current time deviates from `expected_time` by more than `tolerance`
years. Returns `true` if the manoeuvre was cancelled.

A large time discrepancy means the ship is not at the planned position for the
upcoming waypoint, so continuing the manoeuvre would produce incorrect burns.
"""
function cancel_if_time_wrong!(
        gamemap::GameMap, expected_time::Float64;
        tolerance::Float64 = 0.01,
        console_push::Function = identity
    )::Bool
    sm = gamemap.space_map
    !(sm isa SpaceMapState) && return false
    abs(sm.time_years - expected_time) <= tolerance && return false
    clear_active_manoeuvre!(gamemap)
    console_push("Manoeuvre cancelled: current time is too far from the planned waypoint time.")
    return true
end

"""
Cancel if the target time (set by the player for time-warping) would skip past
`waypoint_time` by more than `tolerance` years. Returns `true` if cancelled.

Skipping past a waypoint time while coasting (or waiting for a burn) means the
ship would arrive at the wrong position and the planned burn could never execute
correctly.
"""
function cancel_if_target_time_past!(
        gamemap::GameMap, waypoint_time::Float64;
        tolerance::Float64 = 0.01,
        console_push::Function = identity
    )::Bool
    sm = gamemap.space_map
    !(sm isa SpaceMapState) && return false
    sm.target_time_years <= waypoint_time + tolerance && return false
    clear_active_manoeuvre!(gamemap)
    console_push("Manoeuvre cancelled: time warp would skip past the planned burn waypoint.")
    return true
end

"Return the targeted encounter point or `nothing` when the manoeuvre target is stale."
function _get_target_encounter(sm::SpaceMapState, target_index::Int)
    1 <= target_index <= length(sm.encounter_points) || return nothing
    return sm.encounter_points[target_index]
end

"Replan the active manoeuvre when thrust is detected during `PHASE_COAST`."
function recover_if_coast_thrust!(gamemap::GameMap, gamestate::GameState, man::ManoeuvreData, sm::SpaceMapState, ipc::FlowCalculatorIPC)::Bool
    norm(gamestate.thrust) <= MANOEUVRE_THRUST_THRESHOLD && return false

    console_push = ipc.console_push
    current_time = sm.time_years
    set_target_time!(gamemap, current_time)
    @atomic :monotonic ipc.shared_state.target_spacemap_time = current_time

    ep = _get_target_encounter(sm, man.target_encounter_index)
    if isnothing(ep)
        clear_active_manoeuvre!(gamemap)
        console_push("Manoeuvre cancelled: target encounter is no longer available.")
        return true
    end
    ep = ep::EncounterPoint

    new_manoeuvre = plan_intercept_manoeuvre_at_time(
        get_position(gamemap),
        get_velocity(gamemap),
        ep,
        current_time,
        man.intercept_time,
    )

    if isnothing(new_manoeuvre)
        clear_active_manoeuvre!(gamemap)
        console_push("Manoeuvre cancelled: unable to recover the planned intercept window after off-course thrust.")
        return true
    end

    set_active_manoeuvre!(gamemap, new_manoeuvre)
    console_push("Manoeuvre recalculated: thrust during coast restored the planned intercept window.")
    return true
end

# ===============================================================
# Manoeuvre phase state machine
# ===============================================================

"Enqueue an encounter ship command for the active manoeuvre's target."
function trigger_ready_encounter!(
        gamemap::GameMap,
        man::ManoeuvreData,
        sm::SpaceMapState,
        ipc::FlowCalculatorIPC
    )::Bool
    console_push = ipc.console_push
    max_view_bounds = get_max_reachable_bounds(ipc.shared_state)
    ep = _get_target_encounter(sm, man.target_encounter_index)
    if isnothing(ep)
        clear_active_manoeuvre!(gamemap)
        console_push("Manoeuvre cancelled: target encounter is no longer available.")
        return false
    end
    ep = ep::EncounterPoint

    enc_seed = get_encounter_ship_seed(ep, sm.seed)

    enc_config = get_encounter_config(sm)
    class_config = enc_config.encounter_class_configs[ep.encounter_class]
    encounter_blueprint = generate_encounter(ep.encounter_class, ep.fuel_tag, ep.richness, enc_seed, class_config)

    cmd = create_add_encounter_ship_command(
        ipc.command_queue, encounter_blueprint, ep.display_name, enc_seed;
        target_encounter_index = man.target_encounter_index,
        max_view_bounds = max_view_bounds
    )
    try_enqueue_command!(ipc.command_queue, cmd, console_push)

    @info "Encounter enqueued" name = ep.display_name class = ep.encounter_class

    # Clear manoeuvre immediately to prevent re-enqueuing on subsequent ticks
    clear_active_manoeuvre!(gamemap)
    return true
end

"""
Advance the manoeuvre state machine one step.

New manoeuvres enter `PHASE_APPROACH_BURN` with the approach burn already loaded
into `burn_target_dv` and `burn_remaining_dv`. The only runtime burn initialisation
that remains is the capture burn transition at intercept time. Coast-phase thrust
can also replace the active manoeuvre with a freshly replanned approach burn for
the same target.

All phase transitions are centralised here so the UI is purely a display layer.
Must be called once per tick near the start of the simulation pipeline, before
component/MNA updates and spacemap time stepping.
"""
function update_manoeuvre_phase!(gamestate::GameState, gamemap::GameMap, ipc::FlowCalculatorIPC)
    !has_active_manoeuvre(gamemap) && return nothing
    sm = gamemap.space_map
    !(sm isa SpaceMapState) && return nothing

    man = get_active_manoeuvre(gamemap)
    rem_mag = norm(man.burn_remaining_dv)
    thrust_mag = norm(gamestate.thrust)
    console_push = ipc.console_push

    if man.phase == PHASE_APPROACH_BURN
        # Guards: time-warp during a burn invalidates ΔV integration
        cancel_if_time_progressing!(gamemap; console_push) && return nothing

        if rem_mag < MANOEUVRE_COMPLETION_THRESHOLD && thrust_mag < MANOEUVRE_THRUST_THRESHOLD
            man.burn_target_dv = SVector(0.0, 0.0)
            man.burn_remaining_dv = SVector(0.0, 0.0)
            man.phase = PHASE_COAST

            current_velocity = get_velocity(gamemap)
            @info "Approach Burn completed:" current_velocity = current_velocity
        end

    elseif man.phase == PHASE_COAST
        # Recovery: thrust between burns restarts the manoeuvre from a replanned approach burn
        recover_if_coast_thrust!(gamemap, gamestate, man, sm, ipc) && return nothing
        cancel_if_target_time_past!(gamemap, man.intercept_time; console_push) && return nothing

        # Transition: rotate the capture burn ΔV into ship space when intercept time is reached
        if sm.time_years >= man.intercept_time
            cancel_if_time_wrong!(gamemap, man.intercept_time; console_push) && return nothing

            ship_dv = _spacemap_to_ship(man.capture_burn_dv)
            man.burn_target_dv = ship_dv
            man.burn_remaining_dv = ship_dv
            man.phase = PHASE_CAPTURE_BURN

            current_position = get_position(gamemap)
            expected_velocity = man.capture_burn_dv + get_velocity(gamemap)
            @info "Capture Burn started:" current_position = current_position expected_velocity = expected_velocity
        end

    elseif man.phase == PHASE_CAPTURE_BURN
        # Guards: time-warp during a burn invalidates ΔV integration
        cancel_if_time_progressing!(gamemap; console_push) && return nothing

        if rem_mag < MANOEUVRE_COMPLETION_THRESHOLD && thrust_mag < MANOEUVRE_THRUST_THRESHOLD
            man.burn_target_dv = SVector(0.0, 0.0)
            man.burn_remaining_dv = SVector(0.0, 0.0)
            man.phase = PHASE_ENCOUNTER_READY

            current_velocity = get_velocity(gamemap)
            @info "Capture Burn completed:" current_velocity = current_velocity

            trigger_ready_encounter!(gamemap, man, sm, ipc)
            return nothing
        end

    elseif man.phase == PHASE_ENCOUNTER_READY
        # Guard: thrust after burns complete invalidates the final approach
        cancel_if_thrust!(gamemap, gamestate; console_push) && return nothing
        trigger_ready_encounter!(gamemap, man, sm, ipc)
        return nothing
    end

    return nothing
end

"""
Rotate a space-map-space ΔV vector into ship space.
The ship's +X axis aligns with the burn direction, so the result is `SVector(‖dv‖, 0)`.
"""
function _spacemap_to_ship(dv::SVector{2, Float64})::SVector{2, Float64}
    mag = norm(dv)
    mag < 1.0e-10 && return SVector(0.0, 0.0)

    return SVector(mag, 0.0)
end

# ===============================================================
# FlowCalculator Main Loop
# ===============================================================

"Time the snapshot publish and delegate to the triple-buffer closure."
function _publish_snapshot!(publish_fn::Function, gamemap::GameMap, derived::DerivedMapState,
        mna_state::MNA_State, gamestate::GameState, timestamp::Float64)
    @timeit flowcalc_loop_timer "Snapshot Publishing" begin
        publish_fn(gamemap, derived, mna_state, gamestate, timestamp)
    end
    return nothing
end

"Update timing state: compute delta, advance accumulator (with saturation), and set the `should_update` flag."
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
Update UPS metrics and warn if the accumulator is saturating.
Returns the (possibly reset) update count.
"""
function update_ups_metrics!(
        shared_state::FlowCalculatorSharedState,
        timing::TimingState,
        update_count::Int,
        target_ups::Float64,
        threadsafe_console_push::Function
    )::Int
    # Calculate actual UPS based on updates performed
    time_since_last_update = timing.current_time - timing.last_update_time
    new_update_count = update_count

    if time_since_last_update >= 0.1  # Update every 100ms
        if time_since_last_update > 0.0 && update_count > 0
            measured_ups = update_count / time_since_last_update
            prev_ups = @atomic shared_state.actual_ups
            new_ups = prev_ups * 0.5 + measured_ups * 0.5  # EMA smoothing
            @atomic shared_state.actual_ups = new_ups

            timing.last_update_time = timing.current_time
            new_update_count = 0
        end
    end

    # Warn if accumulator is saturating
    max_accumulator = (1.0 / target_ups) * 10.0
    if timing.accumulator >= max_accumulator * 0.99
        threadsafe_console_push("FlowCalculator saturating time accumulator (running behind)")
    end

    return new_update_count
end

"Main FlowCalculator loop: runs deterministic game simulation on a fixed timestep."
function flowcalculator_loop!(
        ipc::FlowCalculatorIPC,
        initial_snapshot::FlowCalculatorSnapshot
    )
    # Unpack IPC elements
    shared_state = ipc.shared_state
    command_queue = ipc.command_queue
    publish_snapshot = ipc.publish_snapshot
    threadsafe_console_push = ipc.console_push

    @info "FlowCalculator loop started on thread $(Threads.threadid())"
    threadsafe_console_push("FlowCalculator loop started")

    # Timing state and UPS tracking
    timing = TimingState()
    update_count = 0

    # Unpack initial state from snapshot
    gamemap = initial_snapshot.gamemap
    derivedmapstate = initial_snapshot.derived
    mna_state = MNA_State()  # fresh full state; first solve populates it
    gamestate = initial_snapshot.gamestate
    scratchpad = CalculatorScratchpad()  # reused across ticks; fields emptied by each phase
    reactivation_scheduler = ReactivationScheduler()

    # Initialise the shared target spacemap time from the loaded map
    @atomic shared_state.target_spacemap_time = get_target_time(gamemap.space_map)

    # Main loop
    while true
        try
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
                # Drain command queue
                commands_processed = false
                @timeit flowcalc_loop_timer "Command Processing" begin
                    while isready(command_queue.command_channel)
                        command = take!(command_queue.command_channel)
                        process_command!(command, gamemap, threadsafe_console_push, throw_errors = false)
                        commands_processed = true
                    end
                end

                # Consume accumulated time
                timing.accumulator -= target_update_time
                update_count += 1

                if !is_paused
                    # Full update: advance game state
                    gamestate.ticks += 1

                    # Simulation pipeline
                    update_docking!(gamemap)
                    update_manoeuvre_phase!(gamestate, gamemap, ipc)
                    @timeit flowcalc_loop_timer "Component Updates" update_components!(gamemap, mna_state, derivedmapstate)
                    @timeit flowcalc_loop_timer "Reactivation Scan" scan_reactivation_requests!(reactivation_scheduler, gamemap)
                    @timeit flowcalc_loop_timer "Primary Inputs" collect_primary_map_inputs!(gamemap, derivedmapstate)

                    # Attempt one speculative reactivation probe; if none pending, run the base solve
                    @timeit flowcalc_loop_timer "Reactivation Trial" begin
                        if !run_reactivation_trial!(reactivation_scheduler, gamemap, derivedmapstate, mna_state, scratchpad, gamestate.ticks)
                            solve_from_inputs!(derivedmapstate, mna_state, scratchpad, gamestate.ticks)
                        end
                    end

                    @timeit flowcalc_loop_timer "Thruster Handling" handle_thrusters!(gamestate, gamemap, derivedmapstate, mna_state)
                    target_time = @atomic shared_state.target_spacemap_time
                    step_space_map_time!(gamemap.space_map, target_time)
                    refresh_estimated_min_delta_v!(gamestate, gamemap)

                    _publish_snapshot!(publish_snapshot, gamemap, derivedmapstate, mna_state, gamestate, timing.current_time)

                elseif commands_processed
                    # Paused with pending commands: rebuild derived state without advancing time
                    collect_primary_map_inputs!(gamemap, derivedmapstate)
                    solve_from_inputs!(derivedmapstate, mna_state, scratchpad, gamestate.ticks)
                    refresh_estimated_min_delta_v!(gamestate, gamemap; force = true)

                    _publish_snapshot!(publish_snapshot, gamemap, derivedmapstate, mna_state, gamestate, timing.current_time)
                end
            end

            # UPS metrics and diagnostics
            @timeit flowcalc_loop_timer "UPS Metrics" begin
                update_count = update_ups_metrics!(
                    shared_state, timing, update_count,
                    target_ups, threadsafe_console_push
                )
            end

            handle_diagnostics(flowcalc_loop_diagnostic_config, gamestate.ticks)
        catch e
            bt = catch_backtrace()
            @error "FlowCalculator loop exception" exception = (e, bt)
            threadsafe_console_push("FlowCalculator loop crashed; see terminal log for details")

            # Print full backtrace to stderr for terminal visibility
            ios = IOBuffer()
            showerror(ios, e, bt)
            trace_str = String(take!(ios))
            println(stderr, trace_str)

            # Persist a crash dump for post-mortem replay. Wrapped in its own try/catch so a
            # write failure cannot mask the underlying exception.
            try
                crashpath = _write_crash_dump(gamemap, mna_state, command_queue, e, trace_str)
                @info "Crash dump written to $crashpath"
                threadsafe_console_push("Crash dump: $crashpath")
            catch dump_err
                @error "Failed to write crash dump" exception = (dump_err, catch_backtrace())
            end

            # Request orderly shutdown so the error is visible and the main thread can react
            @atomic shared_state.should_exit = true
            break
        end
    end
    return nothing
end

end # module HexFlowCalculator
