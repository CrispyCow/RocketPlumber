module HexFlowCalculator

# Packages
using Base.Threads, Dates, LinearAlgebra, StructEquality
using TimerOutputs, StaticArrays
# Custom Packages
using HexFrame, HexElements, HexFluids, HexFlowTelemetry
using FlowEngine, FlowMap, HexComponentsAPI, HexFlowControl
using HexFlowProcGen

# Type exports - Data Structures
export FlowCalculatorSnapshot, FlowCalculatorSharedState, FlowCalculatorIPC, TimingState

# Type exports - Commands
export CommandStatus, APPLIED, REJECTED, QUEUED_FAILED
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
export update_map!, update_mna!, handle_thrusters!, scale_voltage_dict

# Constant exports - Manoeuvre thresholds
export MANOEUVRE_THRUST_THRESHOLD, MANOEUVRE_COMPLETION_THRESHOLD

# ===============================================================
# Data Structures
# ===============================================================

"Snapshot of complete game state for rendering. Deep-copied to ensure thread safety."
@kwdef struct FlowCalculatorSnapshot
    gamemap::GameMap = GameMap()
    derived::DerivedMapState = DerivedMapState()
    mna::MNA_State = MNA_State()
    gamestate::GameState = GameState()
    timestamp::Float64
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
@enum CommandStatus APPLIED REJECTED QUEUED_FAILED

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
    set_snapshot::Function
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
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal SetTileCommand

"Place a pipe behaviour at an edge coordinate."
@kwdef struct SetPipeBehaviorCommand <: MapEditCommand
    id::UInt64
    coord::EdgeCoord
    pipe_behavior::PipeBehavior
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal SetPipeBehaviorCommand

"Move a component or pipe across the map."
@kwdef struct MoveCommand{T <: Union{TileCoord, EdgeCoord}} <: MapEditCommand
    id::UInt64
    source_coord::T
    dest_coord::T
    delta_rotation::HexAxis
    response_channel::Union{Nothing, Channel{CommandStatus}}
end
@struct_hash_equal MoveCommand

"Delete element at coordinate. Type parameter selects tile vs edge dispatch."
@kwdef struct DeleteAtCommand{T <: Union{TileCoord, EdgeCoord}} <: MapEditCommand
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
    new_shipmap::ShipMap
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
# Thread-Safe Snapshot Storage
# ===============================================================

"""
Thread-safe snapshot storage using closure pattern.
Returns `(set_function, get_function)` for snapshot access.
"""
function create_snapshot_storage(initial_snapshot::FlowCalculatorSnapshot)
    local snapshot_ref = Ref{FlowCalculatorSnapshot}(initial_snapshot)
    local snapshot_lock = ReentrantLock()

    "Set the latest snapshot (producer side)."
    function set_flowcalc_snapshot(new_snapshot::FlowCalculatorSnapshot)
        return lock(snapshot_lock) do
            snapshot_ref[] = new_snapshot
        end
    end

    "Get the latest snapshot (consumer side)."
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

"Find which ship (if any) has both edge endpoints on its surface. Returns `nothing` if none."
function find_ship_for_pipe_endpoints(coord::EdgeCoord, gamemap::GameMap)::Union{Symbol, Nothing}
    v1_node = to_nodecoord(coord.v1)
    v2_node = to_nodecoord(coord.v2)
    for (ship_name, _) in gamemap.ships
        if is_node_on_ship_surface(v1_node, gamemap; ship_name = ship_name) &&
                is_node_on_ship_surface(v2_node, gamemap; ship_name = ship_name)
            return ship_name
        end
    end
    return nothing
end

"""
Apply a map edit command directly to the `gamemap` without sandbox validation.
Dispatches on concrete command type.
"""
function apply_mapedit_command!(
        gamemap::GameMap,
        command::SetTileCommand,
        threadsafe_console_push::Function
    )
    # Determine which ship this component belongs to via placement_valid on each ship
    mapped_rotation = map_rotation(command.component, command.rotation)
    target_ship = find_valid_ship_for_placement(
        command.component, command.coord, gamemap;
        rotation = mapped_rotation
    )

    if isnothing(target_ship)
        threadsafe_console_push("Cannot place component: Not a valid placement on any ship")
        return nothing
    end

    # Check if tile already occupied on that ship
    existing_comptile = get_component(gamemap, command.coord; ship_name = target_ship)
    if !isnothing(existing_comptile)
        threadsafe_console_push("Cannot place component: Tile is already occupied on $(target_ship)")
        return nothing
    end

    set_component!(gamemap, command.coord, ComponentOnTile(deepcopy(command.component), mapped_rotation); ship_name = target_ship)
    threadsafe_console_push("Component placed at $(command.coord) on $(target_ship)")
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::SetPipeBehaviorCommand,
        threadsafe_console_push::Function
    )
    # Check if edge is already occupied anywhere
    found_existing, existing_loc = has_pipe_any_ship(gamemap, command.coord)
    if found_existing
        threadsafe_console_push("Cannot place pipe: Edge already occupied on $(existing_loc)")
        return nothing
    end

    # Try on-surface placement first, then off-ship fallback
    target_ship = find_ship_for_pipe_endpoints(command.coord, gamemap)

    if !isnothing(target_ship)
        set_pipe!(gamemap, command.coord, deepcopy(command.pipe_behavior); ship_name = target_ship)
        threadsafe_console_push("Pipe placed at $(command.coord) on $(target_ship)")
        return nothing
    end

    # Not on any single ship — try off-ship pipe placement (extending from a ship into space)
    can_place, offship_target, reason = can_place_pipe_offship(command.coord, gamemap)
    if can_place
        set_pipe!(gamemap, command.coord, deepcopy(command.pipe_behavior); ship_name = offship_target)
        threadsafe_console_push("Off-ship pipe placed at $(command.coord) on $(offship_target)")
        return nothing
    else
        threadsafe_console_push("Cannot place pipe: $(reason)")
    end

    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::MoveCommand{TileCoord},
        threadsafe_console_push::Function
    )
    # Find source ship
    source_ship = find_ship_with_component(gamemap, command.source_coord)
    if isnothing(source_ship)
        threadsafe_console_push("Cannot move: No component at source $(command.source_coord)")
        return nothing
    end

    source_comptile = get_component(gamemap, command.source_coord; ship_name = source_ship)

    # Check if the component can be moved
    can_move, reason = can_be_moved(source_comptile)
    if !can_move
        threadsafe_console_push("Component cannot be moved: $reason")
        return nothing
    end

    # Calculate new rotation
    new_rotation = map_rotation(source_comptile.component, rotate(source_comptile.rotation, command.delta_rotation))

    # Same-coord move: rotate component in place
    if command.source_coord == command.dest_coord
        rotated_comptile = ComponentOnTile(source_comptile.component, new_rotation)
        is_valid, reason = placement_valid(rotated_comptile, command.source_coord, gamemap; ship_name = source_ship)
        if !is_valid
            threadsafe_console_push("Cannot rotate in place: $reason")
            return nothing
        end

        set_component!(gamemap, command.source_coord, rotated_comptile; ship_name = source_ship)
        threadsafe_console_push("Component rotated in place at $(command.source_coord)")
        return nothing
    end

    # Determine destination ship via placement_valid
    dest_ship = find_valid_ship_for_placement(
        source_comptile.component, command.dest_coord, gamemap;
        rotation = new_rotation
    )

    if isnothing(dest_ship)
        threadsafe_console_push("Cannot move: Destination $(command.dest_coord) not valid for any ship")
        return nothing
    end

    # Check destination not already occupied
    existing_dest = get_component(gamemap, command.dest_coord; ship_name = dest_ship)
    if !isnothing(existing_dest)
        threadsafe_console_push("Cannot move: Destination tile already occupied on $(dest_ship)")
        return nothing
    end

    # Perform move (potentially cross-ship)
    dest_comptile = ComponentOnTile(source_comptile.component, new_rotation)
    set_component!(gamemap, command.dest_coord, dest_comptile; ship_name = dest_ship)
    delete_component!(gamemap, command.source_coord; ship_name = source_ship)

    if source_ship == dest_ship
        threadsafe_console_push("Component moved on $(source_ship) from $(command.source_coord) to $(command.dest_coord)")
    else
        threadsafe_console_push("Component moved from $(source_ship) to $(dest_ship)")
    end
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::MoveCommand{EdgeCoord},
        threadsafe_console_push::Function
    )
    # Find source ship
    source_ship = find_ship_with_pipe(gamemap, command.source_coord)
    if isnothing(source_ship)
        threadsafe_console_push("Cannot move: No pipe at source $(command.source_coord)")
        return nothing
    end

    source_pipe = get_pipe(gamemap, command.source_coord; ship_name = source_ship)

    # Check if source pipe is off-surface — validate that removing it won't orphan connected pipes
    src_v1_on = is_node_on_any_ship_surface(to_nodecoord(command.source_coord.v1), gamemap)
    src_v2_on = is_node_on_any_ship_surface(to_nodecoord(command.source_coord.v2), gamemap)
    source_is_offship = !(src_v1_on && src_v2_on)

    if source_is_offship
        if !validate_offship_pipe_deletion(command.source_coord, gamemap)
            threadsafe_console_push("Cannot move pipe: would orphan connected off-surface pipes")
            return nothing
        end
    end

    # Determine destination ship — try on-surface first, then off-ship fallback
    dest_ship = find_ship_for_pipe_endpoints(command.dest_coord, gamemap)

    if isnothing(dest_ship)
        # Try off-ship placement
        can_place, offship_target, reason = can_place_pipe_offship(command.dest_coord, gamemap)
        if can_place
            dest_ship = offship_target
        else
            threadsafe_console_push("Cannot move pipe: $(reason)")
            return nothing
        end
    end

    # Check destination not already occupied (across all ships)
    found_existing, _ = has_pipe_any_ship(gamemap, command.dest_coord)
    if found_existing
        threadsafe_console_push("Cannot move pipe: Destination edge already occupied")
        return nothing
    end

    # Perform move
    delete_pipe!(gamemap, command.source_coord; ship_name = source_ship)
    set_pipe!(gamemap, command.dest_coord, source_pipe; ship_name = dest_ship)

    # Reassign ownership if source was off-surface (removing it may have split a chain)
    if source_is_offship
        reassign_pipe_ownership!(command.source_coord, gamemap)
    end

    threadsafe_console_push("Pipe moved from $(command.source_coord) to $(command.dest_coord)")
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::DeleteAtCommand{TileCoord},
        threadsafe_console_push::Function
    )
    ship_with_comp = find_ship_with_component(gamemap, command.coord)
    if !isnothing(ship_with_comp)
        delete_component!(gamemap, command.coord; ship_name = ship_with_comp)
        threadsafe_console_push("Component deleted at $(command.coord) from $(ship_with_comp)")
    else
        threadsafe_console_push("No component found at $(command.coord)")
    end
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::DeleteAtCommand{EdgeCoord},
        threadsafe_console_push::Function
    )
    ship_with_pipe = find_ship_with_pipe(gamemap, command.coord)
    if !isnothing(ship_with_pipe)
        # Check if pipe is off-surface — validate deletion won't orphan connected pipes
        v1_on = is_node_on_any_ship_surface(to_nodecoord(command.coord.v1), gamemap)
        v2_on = is_node_on_any_ship_surface(to_nodecoord(command.coord.v2), gamemap)
        is_offship = !(v1_on && v2_on)

        if is_offship && !validate_offship_pipe_deletion(command.coord, gamemap)
            threadsafe_console_push("Cannot delete: would orphan connected off-surface pipes")
            return nothing
        end

        delete_pipe!(gamemap, command.coord; ship_name = ship_with_pipe)
        threadsafe_console_push("Pipe deleted at $(command.coord) from $(ship_with_pipe)")

        # Reassign ownership if the deleted pipe was off-surface (may have split a chain)
        if is_offship
            reassign_pipe_ownership!(command.coord, gamemap)
        end
    else
        threadsafe_console_push("No pipe found at $(command.coord)")
    end
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::ClickTileCommand,
        threadsafe_console_push::Function
    )
    ship_with_comp = find_ship_with_component(gamemap, command.coord)
    if isnothing(ship_with_comp)
        threadsafe_console_push("No component at $(command.coord)")
        return nothing
    end

    tilecomp = get_component(gamemap, command.coord; ship_name = ship_with_comp)
    on_click!(tilecomp; unrotated_clicksite = command.unrotated_clicksite)
    threadsafe_console_push("Clicked component at $(command.coord) on $(ship_with_comp)")
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::DoActionCommand,
        threadsafe_console_push::Function
    )
    ship_with_comp = find_ship_with_component(gamemap, command.coord)
    if isnothing(ship_with_comp)
        threadsafe_console_push("No component at $(command.coord)")
        return nothing
    end

    tilecomp = get_component(gamemap, command.coord; ship_name = ship_with_comp)
    success, message = do_action!(tilecomp, command.action_id)
    threadsafe_console_push(message)
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::AddShipSurfaceCommand,
        threadsafe_console_push::Function
    )
    coord = command.coord

    # Find which ships have adjacent surfaces
    adjacent_ships = find_ships_adjacent_to_coord(gamemap, coord)

    if isempty(adjacent_ships)
        threadsafe_console_push("Cannot add surface: Must be adjacent to existing surface")
        return nothing
    end

    if length(adjacent_ships) > 1
        threadsafe_console_push("Cannot add surface: Would connect multiple ships ($(adjacent_ships))")
        return nothing
    end

    target_ship = adjacent_ships[1]

    # Check not already on surface
    if is_on_surface_tile(coord, gamemap; ship_name = target_ship)
        threadsafe_console_push("Surface already exists at $(coord) on $(target_ship)")
        return nothing
    end

    set_surface_tile!(gamemap, coord; ship_name = target_ship)
    threadsafe_console_push("Surface added at $(coord) on $(target_ship)")
    return nothing
end

function apply_mapedit_command!(
        gamemap::GameMap,
        command::RemoveShipSurfaceCommand,
        threadsafe_console_push::Function
    )
    coord = command.coord

    # Find which ship owns this surface tile
    ship_with_surface = find_ship_for_surface(gamemap, coord)
    if isnothing(ship_with_surface)
        threadsafe_console_push("No surface at $(coord)")
        return nothing
    end

    # Check if removing would leave a component without surface
    if has_component(gamemap, coord; ship_name = ship_with_surface)
        threadsafe_console_push("Cannot remove surface: Component present (delete component first)")
        return nothing
    end

    # Check if this is the last surface tile on this ship
    ship = get_ship(gamemap, ship_with_surface)
    if count_surface_tiles(ship) <= 1
        threadsafe_console_push("Cannot remove surface: Cannot delete last surface tile on $(ship_with_surface)")
        return nothing
    end

    delete_surface_tile!(gamemap, coord; ship_name = ship_with_surface)
    threadsafe_console_push("Surface removed at $(coord) from $(ship_with_surface)")
    return nothing
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
    )
    # Deepcopy the provided map to avoid sharing mutable state
    newmap = deepcopy(command.new_map)

    replace_by_mutation!(gamemap, newmap)

    numtiles = count_surface_tiles(newmap)
    numcomps = count_components(newmap)
    numpipes = count_pipes(newmap)
    threadsafe_console_push("Map override applied with $numtiles surfaces, $numcomps tiles, and $numpipes pipes")

    return nothing
end

"Add an encounter ship, with optional encounter point recycling for live encounters."
function apply_mapedit_command!(
        gamemap::GameMap,
        command::AddEncounterShipCommand,
        threadsafe_console_push::Function
    )
    if command.dir === nothing
        encounter_ship_optimal_dir!(gamemap, command.new_shipmap, command.ship_name_base,
            command.seed; max_view_bounds = command.max_view_bounds)
    else
        encounter_ship!(gamemap, command.new_shipmap, command.ship_name_base,
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

    return nothing
end

"""
Relocate a non-primary ship by a tile offset. Validates that the new position
does not overlap any other ship's surface (including a 2-tile exclusion gap
enforced by the render-side check) and does not bridge circuit nodes. Sets up
an `ApproachingDockStat` so the ship animates to its new position.
"""
function apply_mapedit_command!(
        gamemap::GameMap,
        command::RedockShipCommand,
        threadsafe_console_push::Function
    )
    if command.ship_name === :primary
        threadsafe_console_push("Cannot redock the primary ship")
        return nothing
    end

    ship = get_ship(gamemap, command.ship_name)

    if !(ship.docking_status isa ConnectedDockStat)
        threadsafe_console_push("Ship $(command.ship_name) is not in a connected state")
        return nothing
    end

    # Pre-compute offset tiles without modifying the ship
    trial_tiles = Set(tile + command.offset for tile in ship.ship_tiles)

    # Enforce a 2-tile gap between the relocated ship and all other ships
    other_tiles = Set{TileCoord}()
    for (name, other) in gamemap.ships
        name === command.ship_name && continue
        union!(other_tiles, other.ship_tiles)
    end
    exclusion_zone = expand_tileset(other_tiles, 2)

    if !isempty(intersect(trial_tiles, exclusion_zone))
        threadsafe_console_push("Redock position too close to another ship")
        return nothing
    end

    # Validation passed, perform the move on the real map
    offset_ship!(ship, command.offset)

    # Set up approach animation: render offset starts at old position, animates to zero
    anim_offset = AxialCoord(Float64(-command.offset.q), Float64(-command.offset.r))
    target_offset = AxialCoord(0.0, 0.0)
    distance = sqrt(anim_offset.q^2 + anim_offset.r^2)
    duration_secs = clamp(distance / 3.0, 0.5, 5.0)
    step = distance > 0.0 ? distance / (duration_secs * BASE_UPS) : 0.01

    ship.docking_status = ApproachingDockStat(anim_offset, target_offset, step)
    threadsafe_console_push("Ship $(command.ship_name) relocated")

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

    # Try to apply the command to the sandbox first
    try
        apply_mapedit_command!(sandbox, command, (msg) -> nothing)  # Silent for sandbox
        new_hash = hash(sandbox)

        # If map changed, validate it won't cause errors
        if new_hash != original_hash
            test_derivedmapstate = DerivedMapState()
            test_mna_state = MNA_State()

            # Test the sandbox with full validation (use tick 0 for validation)
            update_components!(sandbox, test_mna_state, test_derivedmapstate)
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

"Create a `SetTileCommand` for placing a component."
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

"Create a `SetPipeBehaviorCommand` for placing a pipe."
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

"Create a `MoveCommand` for moving an element."
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

"Create a `DeleteAtCommand` for deleting a component or pipe."
function create_delete_command(
        cq::CommandQueue,
        coord::T;
        response_channel::Union{Nothing, Channel} = nothing
    ) where {T <: Union{TileCoord, EdgeCoord}}
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
        cq::CommandQueue, new_shipmap::ShipMap, ship_name_base::String, seed::UInt32;
        dir::Union{Nothing, HexFrame.HexAxis} = nothing,
        target_encounter_index::Union{Nothing, Int} = nothing,
        max_view_bounds::Union{Nothing, HexFrame.CartesianBounds} = nothing,
        response_channel::Union{Nothing, Channel} = nothing
    )::AddEncounterShipCommand
    return AddEncounterShipCommand(
        id = cq.next_command_id(),
        new_shipmap = deepcopy(new_shipmap),
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
# Map Update Functions
# ===============================================================

"""
Rebuild derived map state and MNA matrix from the current `gamemap`.
Called every tick (fast enough for now; may need revisiting if it becomes a bottleneck).
"""
function update_map!(gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State, current_tick::Int64)
    # (updating map every tick as it is quite quick. This might need to be revisited if it becomes a bottleneck)
    @timeit flowcalc_loop_timer "Map Updates" begin
        # Derive basic map state
        @timeit flowcalc_loop_timer "find ship edge" find_ship_surface_edgetiles!(derivedmapstate, gamemap)
        @timeit flowcalc_loop_timer "list elements" derivedmapstate.allelements = list_elements(gamemap)
        @timeit flowcalc_loop_timer "list nodes" derivedmapstate.allnodes = list_nodes(derivedmapstate.allelements) # diagnostic only

        # Iteratively prune until clear_dangling_dependants reaches a fixed point
        # This is a simple but inefficient approach, should consider optimising if it becomes a bottleneck
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
            # Clear stale outputs so they don't continue to be rendered
            empty!(mna_state.node_voltages)
            empty!(mna_state.vsource_currents)
            empty!(mna_state.node_voltages_scaled)
            empty!(derivedmapstate.nodeactualfluids)
        end
    end
    return nothing
end

# TODO: This closure hides mutable state (max_voltage_ever) with no way to reset on map reload.
# Consider replacing with a proper struct + reset! method in a future cleanup pass.
let max_voltage_ever::Float64 = -Inf
    "Normalise node voltages to [0, 1] for colour rendering. Tracks the historical maximum."
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

"Re-solve the MNA system (Z vector rebuild + linear solve). Called once per tick."
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

"Sum thrust from all components, integrate velocity, and track burn progress during manoeuvres."
function handle_thrusters!(gamestate::GameState, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State; base_ups::Float64 = BASE_UPS)
    # Compute total thrust vector from all nozzle components (ship space)
    thrust = SVector{2, Float64}(0.0, 0.0)
    for (_, ship) in gamemap.ships
        for (tile, comp) in get_all_components(ship)
            thrust += get_thrust(comp; tile = tile, mna_state = mna_state, derivedmapstate = derivedmapstate)
        end
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
    target_index = man.target_encounter_index
    if !(1 <= target_index <= length(sm.encounter_points))
        clear_active_manoeuvre!(gamemap)
        console_push("Manoeuvre cancelled: target encounter is no longer available.")
        return false
    end

    ep = sm.encounter_points[target_index]
    enc_seed = get_encounter_ship_seed(ep, sm.seed)

    enc_config = get_encounter_config(sm)
    class_config = enc_config.encounter_class_configs[ep.encounter_class]
    new_shipmap = generate_encounter(ep.encounter_class, ep.fuel_tag, ep.richness, enc_seed, class_config)

    cmd = create_add_encounter_ship_command(
        ipc.command_queue, new_shipmap, ep.display_name, enc_seed;
        target_encounter_index = target_index,
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
that remains is the capture burn transition at intercept time.

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

    if man.phase == FlowMap.PHASE_WAIT_APPROACH
        clear_active_manoeuvre!(gamemap)
        console_push("Manoeuvre cancelled: encountered deprecated wait phase after load migration.")
        return nothing

    elseif man.phase == PHASE_APPROACH_BURN
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
        # Guards: thrust between burns, or time warp that skips the capture burn
        cancel_if_thrust!(gamemap, gamestate; console_push) && return nothing
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

"Deep-copy all game state and publish a new snapshot."
function _publish_snapshot!(set_snapshot::Function, gamemap, derivedmapstate, mna_state, gamestate, timestamp)
    @timeit flowcalc_loop_timer "Snapshot Publishing" begin
        snapshot = FlowCalculatorSnapshot(
            gamemap = deepcopy(gamemap),
            derived = deepcopy(derivedmapstate),
            mna = deepcopy(mna_state),
            gamestate = deepcopy(gamestate),
            timestamp = timestamp
        )
        set_snapshot(snapshot)
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
                    update_map!(gamemap, derivedmapstate, mna_state, gamestate.ticks)
                    update_mna!(derivedmapstate, mna_state, gamestate.ticks)
                    @timeit flowcalc_loop_timer "Thruster Handling" handle_thrusters!(gamestate, gamemap, derivedmapstate, mna_state)
                    target_time = @atomic shared_state.target_spacemap_time
                    step_space_map_time!(gamemap.space_map, target_time)

                    _publish_snapshot!(set_snapshot, gamemap, derivedmapstate, mna_state, gamestate, timing.current_time)

                elseif commands_processed
                    # Paused with pending commands: rebuild derived state without advancing time
                    update_map!(gamemap, derivedmapstate, mna_state, gamestate.ticks)
                    update_mna!(derivedmapstate, mna_state, gamestate.ticks)

                    _publish_snapshot!(set_snapshot, gamemap, derivedmapstate, mna_state, gamestate, timing.current_time)
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

            # Request orderly shutdown so the error is visible and the main thread can react
            @atomic shared_state.should_exit = true
            break
        end
    end
    return nothing
end

end # module HexFlowCalculator
