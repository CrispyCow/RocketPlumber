module HexFlowProcGen

using Random, LinearAlgebra, GeometryBasics, StaticArrays
using HexFrame, FlowMap, SquirrelNoise, HexComponentsAPI, FlowEngine
using DataStructures: BinaryMinHeap

export random_tile_walk!, random_tile_walk, stacked_random_tile_walk!
export weighted_roll_noise, pick_from_range, pick_from_options
export CompPlacementStrategy, ShipComponentSet, CompSpawnOptions, roll_component
export PipePlacementStrategy, PipeSpawnOptions, roll_pipe
export place_shipset!, place_random_pipes!, place_connected_pipes!, place_pipeset!
export ShipGenOptions, generate_ship, encounter_ship!, depart_ship!
export check_departure_pipe_connections
export EncounterSystemConfig, initialise_encounter_system!
export spawn_encounter_point!, get_encounter_position, predict_crossing_time
export rebuild_event_queue!, check_line_shift!, process_encounter_events!
export step_space_map_time!
export calculate_minimum_intercept_dv, plan_intercept_manoeuvre
export compute_closest_approach
export get_encounter_ship_options, get_encounter_ship_seed
export generate_base_velocities


# =============================================================== #
# Utilities
# =============================================================== #

function pick_from_range(min::T, max::T, point, seed::UInt32) where {T <: Real}
    noise = get_noise_zero_to_one(point, seed)
    raw = min + noise * (max - min)

    return T <: Integer ? round(T, raw) : T(raw) # ensures uniform sampling for integer types
end

function pick_from_options(options::Vector{T}, point, seed::UInt32) where {T}
    return pick_element_from_noise(options, point, seed)
end

"Selects a weighted random item from `weights` based on and RNG instance"
function weighted_roll_rng(rng::AbstractRNG, weights::Vector{Tuple{T, Float64}}) where {T}
    total_weight = sum(w[2] for w in weights)
    roll = rand(rng) * total_weight

    cumulative = 0.0
    for (item, weight) in weights
        cumulative += weight
        if roll <= cumulative
            return item
        end
    end

    return weights[end][1]  # fallback
end

"Selects a weighted random item from `weights` based on SquirrelNoise with the given `point` and `seed`."
function weighted_roll_noise(weights::Vector{Tuple{T, Float64}}, point, seed::UInt32) where {T}
    total_weight = sum(w[2] for w in weights)
    roll = get_noise_zero_to_one(point, seed) * total_weight

    cumulative = 0.0
    for (item, weight) in weights
        cumulative += weight
        if roll <= cumulative
            return item
        end
    end

    return weights[end][1]  # Fallback in case of rounding errors
end

# =============================================================== #
# Surface Generation
# =============================================================== #

"Adds to the set `tiles` by performing a random walk starting at `start` for `steps` steps.
 The tile chosen at each step is determined by SquirrelNoise with the given `seed`."
function random_tile_walk!(tiles::Set{TileCoord}, start::TileCoord, steps::Int, seed::UInt32)
    current = start

    for step in 1:steps
        push!(tiles, current)
        neighbours = get_adjacent_tiles_for_tile(current)
        current = pick_element_from_noise(neighbours, step, seed)
    end
    push!(tiles, current)

    return nothing
end

"Return a set of `tiles` by performing a random walk starting at `start` for `steps` steps.
 The tile chosen at each step is determined by SquirrelNoise with the given `seed`."
function random_tile_walk(start::TileCoord, steps::Int, seed::UInt32)
    new_tiles = Set{TileCoord}()
    random_tile_walk!(new_tiles, start, steps, seed)
    return new_tiles
end


"Adds to the set `tiles` by performing `stacks` of overlaping random walks to bias the surface towards the center.
 Each stack uses a different seed derived from the original `seed`."
function stacked_random_tile_walk!(tiles::Set{TileCoord}, start::TileCoord, steps::Int, stacks::Int, seed::UInt32)
    for stack in 1:stacks
        stack_seed = get_noise(stack, seed)
        random_tile_walk!(tiles, start, steps, stack_seed)
    end

    return nothing
end

# =============================================================== #
# component placement
# =============================================================== #

@enum CompPlacementStrategy begin
    RANDOM_PLACE
    CLUSTERED_PLACE
    NOZZLE_EDGE_PLACE
end

struct CompSpawnOptions
    kind::Symbol
    spawn_count_weights::Vector{Tuple{Int, Float64}}
    placement::CompPlacementStrategy
end

struct ShipComponentSet
    name::String
    components::Vector{CompSpawnOptions}
end

"Rolls a component of the given kind symbol, using Val disptached functions"
roll_component(kind::Symbol, point, seed) =
    roll_component(Val(kind), point, seed)

"Default fallback — triggers for unknown kind"
roll_component(::Val{K}, point, seed) where {K} =
    error("Unknown component kind: $K")

"Clears the given tile coordinate and all adjacent tiles from the provided set of tiles."
function clear_tiles_around_component!(tiles::Set{TileCoord}, coord::TileCoord)
    delete!(tiles, coord)
    for neighbor in get_adjacent_tiles_for_tile(coord)
        delete!(tiles, neighbor)
    end

    return nothing
end

"Places all components from the given shipset onto the map using the provided seed.
 Returns a tuple indicating success and a message."
function place_shipset!(map::GameMap, shipset::ShipComponentSet, seed::UInt32)::Tuple{Bool, String}
    existing_components::Set{TileCoord} = Set(keys(get_all_components(map)))

    ship_surface_edge::Set{TileCoord} = Set{TileCoord}()
    find_ship_surface_edgetiles!(ship_surface_edge, map)
    all_tiles_adjacent_to_edgetiles::Set{TileCoord} = Set{TileCoord}()
    for edge_tile in ship_surface_edge
        union!(all_tiles_adjacent_to_edgetiles, get_adjacent_tiles_for_tile(edge_tile))
    end
    # tiles adjecent to the edge of the ship but not part of the ship surface are valid for nozzles
    available_nozzle_tiles = setdiff(all_tiles_adjacent_to_edgetiles, get_all_surface_tiles(map))
    # all surface tiles are valid for everything else
    available_ship_surface::Set{TileCoord} = Set(get_all_surface_tiles(map))
    # clear all tiles adjacent to existing components
    for coord in existing_components
        clear_tiles_around_component!(available_nozzle_tiles, coord)
        clear_tiles_around_component!(available_ship_surface, coord)
    end

    # preallocated buffers
    prng = MersenneTwister(seed)
    component_location_list = Vector{TileCoord}()
    canidate_tiles = Set{TileCoord}()
    possible_rotations = Vector{HexFrame.HexAxis}(collect(instances(HexFrame.HexAxis)))

    for spawn_option in shipset.components
        empty!(component_location_list)
        count = weighted_roll_rng(prng, spawn_option.spawn_count_weights)

        # build list of positions to place components
        if spawn_option.placement == CLUSTERED_PLACE
            for index in 1:count
                if isempty(available_ship_surface)
                    return (false, "Failed to cluster place component $(spawn_option.kind): no available ship surface tiles")
                end

                if isempty(component_location_list)
                    # first component, pick randomly
                    selected_coord = pick_element_from_rng(available_ship_surface, prng)
                else
                    # pick from canidates if any, otherwise fall back to full available surface
                    empty!(canidate_tiles)
                    union!(canidate_tiles, get_adjacent_tiles_for_tile(component_location_list[end]))
                    intersect!(canidate_tiles, available_ship_surface)
                    selected_coord = isempty(canidate_tiles) ? pick_element_from_rng(available_ship_surface, prng) : pick_element_from_rng(canidate_tiles, prng)
                end

                delete!(available_ship_surface, selected_coord) # only delete actual coordinate for now
                push!(component_location_list, selected_coord)
            end

            # clean up adjacent tiles after placing all components in the cluster
            for selected_coord in component_location_list
                clear_tiles_around_component!(available_nozzle_tiles, selected_coord)
                clear_tiles_around_component!(available_ship_surface, selected_coord)
            end

        elseif spawn_option.placement == NOZZLE_EDGE_PLACE
            for index in 1:count
                if isempty(available_nozzle_tiles)
                    return (false, "Failed to place component $(spawn_option.kind): no available nozzle edge tiles")
                end

                selected_coord = pick_element_from_rng(available_nozzle_tiles, prng)
                clear_tiles_around_component!(available_nozzle_tiles, selected_coord)
                clear_tiles_around_component!(available_ship_surface, selected_coord)

                push!(component_location_list, selected_coord)
            end

        elseif spawn_option.placement == RANDOM_PLACE
            for index in 1:count
                if isempty(available_ship_surface)
                    return (false, "Failed to place component $(spawn_option.kind): no available ship surface tiles")
                end

                selected_coord = pick_element_from_rng(available_ship_surface, prng)
                clear_tiles_around_component!(available_nozzle_tiles, selected_coord)
                clear_tiles_around_component!(available_ship_surface, selected_coord)

                push!(component_location_list, selected_coord)
            end

        else
            return (false, "Unknown placement strategy for component $(spawn_option.kind)")
        end

        # skip if no components to place
        if isempty(component_location_list)
            continue
        end

        # place components from list according to strategy
        if spawn_option.placement == CLUSTERED_PLACE
            # clustered place uses identical components, and assumes all rotations can be mapped to a valid one
            comp_behav = roll_component(spawn_option.kind, first(component_location_list), seed)
            comp_rotation = map_rotation(comp_behav, pick_element_from_rng(instances(HexFrame.HexAxis), prng))
            tilecomp = ComponentOnTile(comp_behav, comp_rotation)

            for selected_coord in component_location_list
                set_component!(map, selected_coord, deepcopy(tilecomp))
            end

        elseif spawn_option.placement == RANDOM_PLACE
            # random place rolls each component individually, assuming all rotations can be mapped to a valid one
            for selected_coord in component_location_list
                comp_behav = roll_component(spawn_option.kind, selected_coord, seed)
                comp_rotation = map_rotation(comp_behav, pick_element_from_rng(instances(HexFrame.HexAxis), prng))
                tilecomp = ComponentOnTile(comp_behav, comp_rotation)

                set_component!(map, selected_coord, deepcopy(tilecomp))
            end

        elseif spawn_option.placement == NOZZLE_EDGE_PLACE
            # nozzle edge place rolls each component individually, validating each rotation
            for selected_coord in component_location_list
                # generate component based on coordinate noise
                comp_behav = roll_component(spawn_option.kind, selected_coord, seed)

                # find valid orientation then place on the map
                shuffle!(prng, possible_rotations)
                for random_axis in possible_rotations
                    chosen_axis = map_rotation(comp_behav, random_axis)

                    # check if placement is valid
                    valid_pick, reason = placement_valid(comp_behav, selected_coord, map; rotation = chosen_axis)
                    if valid_pick
                        set_component!(map, selected_coord, ComponentOnTile(comp_behav, chosen_axis))
                        break
                    end
                end
            end

        else
            return (false, "Unknown placement strategy for component $(spawn_option.kind)")
        end

    end

    return (true, "Successfully placed all components")
end

# =============================================================== #
# pipe placement
# =============================================================== #

@enum PipePlacementStrategy begin
    RANDOM_PIPES
    ONE_CONNECT_PIPES
end

struct PipeSpawnOptions
    kind::Symbol
    placement::PipePlacementStrategy
    density::Float64
end

"Rolls a pipe of the given kind symbol, using Val disptached functions"
roll_pipe(kind::Symbol, point, seed) =
    roll_pipe(Val(kind), point, seed)

"Default fallback — triggers for unknown kind"
roll_pipe(::Val{K}, point, seed) where {K} =
    error("Unknown pipe kind: $K")

"allocated set of all edgecoords for the given set of tiles"
function get_all_edgecoords_of_tiles(tiles::Set{TileCoord})
    edgecoords = Set{EdgeCoord}()

    for tile in tiles
        union!(edgecoords, get_edges(tile))
    end

    return edgecoords
end

"randomly chooses to place a pipe at the given edge based on noise and pipe density"

function noise_pipe_place_helper!(map::GameMap, edge::EdgeCoord, pipe_kind::Symbol, seed::UInt32; pipe_density)
    used_pipe_density = clamp(pipe_density, 0.0, 1.0)
    hashed_edge = UInt32(hash(edge, hash(pipe_kind)) & typemax(UInt32)) # mix in pipe kind to vary placement
    roll = get_noise_zero_to_one(hashed_edge, seed)
    if roll <= used_pipe_density
        pipe_behav = roll_pipe(pipe_kind, hashed_edge, seed)
        set_pipe!(map, edge, pipe_behav)
    end

    return nothing
end

"randomly chooses to place pipes at the given edges based on noise and pipe density"
function noise_pipe_place_helper!(map::GameMap, edges, pipe_kind::Symbol, seed::UInt32; pipe_density)
    for edgecoord in edges
        noise_pipe_place_helper!(map, edgecoord, pipe_kind, seed; pipe_density = pipe_density)
    end

    return nothing
end

"places pipes randomly on canidate edges that connect to 1 and only 1 existing node on the map based on pipe density"
function place_connected_pipes!(map::GameMap, pipe_kind::Symbol, seed::UInt32; pipe_density)
    ship_tiles = deepcopy(get_all_surface_tiles(map))
    available_edgecoords = get_all_edgecoords_of_tiles(ship_tiles)
    all_nodes = Set(keys(list_nodes(list_elements(map))))

    # keep only edgecoords that would connect to one existing node
    for edgecoord in available_edgecoords
        v1_is_connected = to_nodecoord(edgecoord.v1) in all_nodes
        v2_is_connected = to_nodecoord(edgecoord.v2) in all_nodes

        if v1_is_connected && !v2_is_connected
            # keep this edgecoord
        elseif !v1_is_connected && v2_is_connected
            # keep this edgecoord
        else
            delete!(available_edgecoords, edgecoord)
        end
    end

    # place pipes based on density
    noise_pipe_place_helper!(map, available_edgecoords, pipe_kind, seed; pipe_density = pipe_density)

    return nothing
end

"places pipes randomly on on canidate edges that do not connect 2 nodes based on pipe density"
function place_random_pipes!(map::GameMap, pipe_kind::Symbol, seed::UInt32; pipe_density)
    ship_tiles = deepcopy(get_all_surface_tiles(map))
    available_edgecoords = get_all_edgecoords_of_tiles(ship_tiles)
    all_nodes = Set(keys(list_nodes(list_elements(map))))

    # remove any edgecoords that would actually connect 2 existing nodes
    for edgecoord in available_edgecoords
        v1_is_connected = to_nodecoord(edgecoord.v1) in all_nodes
        v2_is_connected = to_nodecoord(edgecoord.v2) in all_nodes

        if v1_is_connected && v2_is_connected
            delete!(available_edgecoords, edgecoord)
        end
    end

    # place pipes based on density
    noise_pipe_place_helper!(map, available_edgecoords, pipe_kind, seed; pipe_density = pipe_density)

    return nothing
end

function place_pipeset!(map::GameMap, pipe_options::PipeSpawnOptions, seed::UInt32)
    if pipe_options.placement == RANDOM_PIPES
        place_random_pipes!(map, pipe_options.kind, seed; pipe_density = pipe_options.density)
    elseif pipe_options.placement == ONE_CONNECT_PIPES
        place_connected_pipes!(map, pipe_options.kind, seed; pipe_density = pipe_options.density)
    else
        error("Unknown pipe placement strategy for pipe $(pipe_options.kind)")
    end

    return nothing
end

function place_pipeset!(map::GameMap, pipe_options::AbstractArray{PipeSpawnOptions}, seed::UInt32)
    for pipe_option in pipe_options
        place_pipeset!(map, pipe_option, seed)
    end

    return nothing
end

# =============================================================== #
# Ship Generation
# =============================================================== #

@kwdef struct ShipGenOptions
    name::String
    surface_gen_steps::Int
    surface_gen_stacks::Int
    component_sets::Vector{ShipComponentSet}
    pipe_sets::Vector{PipeSpawnOptions}
end

function generate_ship(ship::ShipGenOptions, seed::UInt32)::ShipMap
    shipmap = ShipMap()

    # generate ship surface
    stacked_random_tile_walk!(get_all_surface_tiles(shipmap), TileCoord(0, 0), ship.surface_gen_steps, ship.surface_gen_stacks, seed)

    # place components into a temporary GameMap wrapper for reuse of existing placement logic
    for shipset in ship.component_sets
        success, message = place_shipset!(GameMap(shipmap), shipset, seed)
        if !success
            @warn "Ship generation did not complete component placement:\n$message"
        end
    end

    # place pipes (operate via GameMap wrapper)
    for pipeset in ship.pipe_sets
        place_pipeset!(GameMap(shipmap), pipeset, seed)
    end

    return shipmap
end

"Checks if the surface tiles of the given shipmap overlap with any existing surfaces in the gamemap."
function _is_surface_overlap(gamemap::GameMap, shipmap::ShipMap)::Bool
    all_tiles = get_all_surfaces_combined(gamemap)
    ship_tiles = get_all_surface_tiles(shipmap)

    # Iterate the (assumed-smaller) ship tiles and test membership in the larger set without allocating
    for t in ship_tiles
        if t in all_tiles
            return true
        end
    end
    return false
end

function _rects_overlap(a::HexFrame.CartesianBounds, b::HexFrame.CartesianBounds)::Bool
    return a.X_NEG < b.X_POS && a.X_POS > b.X_NEG &&
           a.Y_NEG < b.Y_POS && a.Y_POS > b.Y_NEG
end

function encounter_ship!(gamemap::GameMap, shipoptions::ShipGenOptions, seed::UInt32, dir::HexFrame.HexAxis; max_view_bounds::Union{HexFrame.CartesianBounds, Nothing} = nothing)
    newship = generate_ship(shipoptions, seed)
    newship_name = gensym(shipoptions.name)

    # offset ship until no surface overlap, starting from primary centroid to handle the case the ship is not centered around (0,0)
    ship_centroid = get_surface_centroid(gamemap, :primary)
    offset_newship = deepcopy(newship)
    offset_ship!(offset_newship, round_to_tile(ship_centroid))
    while _is_surface_overlap(gamemap, offset_newship)
        offset = HexFrame.hex_neighbour_tiles[dir]
        offset_ship!(offset_newship, offset)
    end

    # add final gap
    MIN_SPACING = 3
    hnt = HexFrame.hex_neighbour_tiles[dir]
    final_offset = TileCoord(hnt.q * MIN_SPACING, hnt.r * MIN_SPACING)
    offset_ship!(offset_newship, final_offset)
    
    # Calculate approach animation parameters
    # Start 20 tiles away in the approach direction and animate to zero offset
    APPROACH_DISTANCE_TILES = 20.0
    
    # Direction vector
    direction_vec = HexFrame.hex_vert_vecs[dir]

    # If bounds provided, ensure start point is off-screen
    if !isnothing(max_view_bounds)
        ship_bounds = get_cartesian_bounds(offset_newship)
        
        # Increase distance until out of view
        is_overlapping = true
        while is_overlapping
             start_offset_test = HexFrame.AxialCoord(
                direction_vec.q * APPROACH_DISTANCE_TILES,
                direction_vec.r * APPROACH_DISTANCE_TILES
            )
            
            # Shift the ship bounds by this offset
            shift_cart = HexFrame.to_cartesian(start_offset_test)
            shifted_bounds = (
                X_POS = ship_bounds.X_POS + shift_cart.x,
                X_NEG = ship_bounds.X_NEG + shift_cart.x,
                Y_POS = ship_bounds.Y_POS + shift_cart.y,
                Y_NEG = ship_bounds.Y_NEG + shift_cart.y
            )
            
            if _rects_overlap(shifted_bounds, max_view_bounds)
                APPROACH_DISTANCE_TILES += 10.0
                if APPROACH_DISTANCE_TILES > 2000.0 # Safety break
                    @warn "Could not find safe spawn distance, capping at 2000"
                    break
                end
            else
                is_overlapping = false
            end
        end
    end

    TARGET_APPROACH_DURATION_SECS = 5.0
    TARGET_UPS = 60.0  # updates per second
    
    # Convert tile distance to axial offset (using hex_vert_vecs for direction)
    start_offset = HexFrame.AxialCoord(
        direction_vec.q * APPROACH_DISTANCE_TILES,
        direction_vec.r * APPROACH_DISTANCE_TILES
    )
    target_offset = HexFrame.AxialCoord(0.0, 0.0)
    
    # Calculate step size: total_distance / (duration * ups)
    total_distance = sqrt(start_offset.q^2 + start_offset.r^2)
    total_updates = TARGET_APPROACH_DURATION_SECS * TARGET_UPS
    offset_step = total_distance / total_updates
    
    # Set docking status to approaching on the new ship
    set_docking_status!(offset_newship, ApproachingDockStat(start_offset, target_offset, offset_step, dir))

    # add to gamemap
    add_ship!(gamemap, newship_name, offset_newship)

    return nothing
end

"""
    check_departure_pipe_connections(gamemap, ship_name) → (can_depart, reason)

Check whether a ship can depart by verifying no pipe chain still bridges it to another ship.
Collects all off-surface pipe edges (relative to the departing ship), flood-fills outward
from the departing ship's surface boundary, and checks whether any component reaches another
ship's surface.

Returns `(can_depart::Bool, reason::String)`.
"""
function check_departure_pipe_connections(gamemap::GameMap, ship_name::Symbol)::Tuple{Bool, String}
    # Collect off-surface pipe edges relative to the departing ship (from all ships)
    offship_edges = Set{EdgeCoord}()
    for (_, ship) in gamemap.ships
        for (edge, _) in ship.pipe_behaviors
            v1_on = is_node_on_ship_surface(to_nodecoord(edge.v1), gamemap; ship_name = ship_name)
            v2_on = is_node_on_ship_surface(to_nodecoord(edge.v2), gamemap; ship_name = ship_name)
            if !(v1_on && v2_on)
                push!(offship_edges, edge)
            end
        end
    end

    isempty(offship_edges) && return (true, "")

    # Starting nodes: endpoints of off-surface pipes that sit on the departing ship's surface
    starting_nodes = Set{NodeCoord}()
    for edge in offship_edges
        for vertex in (edge.v1, edge.v2)
            node = to_nodecoord(vertex)
            if is_node_on_ship_surface(node, gamemap; ship_name = ship_name)
                push!(starting_nodes, node)
            end
        end
    end

    isempty(starting_nodes) && return (true, "")

    # Flood from each starting node, checking if any component reaches another ship
    visited_edges = Set{EdgeCoord}()
    for start_node in starting_nodes
        # Skip if this node's component was already explored
        any(e -> to_nodecoord(e.v1) == start_node || to_nodecoord(e.v2) == start_node, visited_edges) && continue

        reachable = Set{EdgeCoord}()
        flood_search_pipes_from_node!(reachable, offship_edges, start_node)
        union!(visited_edges, reachable)

        for edge in reachable
            for vertex in (edge.v1, edge.v2)
                node = to_nodecoord(vertex)
                for (sname, _) in gamemap.ships
                    sname == ship_name && continue
                    if is_node_on_ship_surface(node, gamemap; ship_name = sname)
                        return (false, "Can't depart: pipes still connect $(ship_name) to $(sname)")
                    end
                end
            end
        end
    end

    return (true, "")
end


"Attempt to depart a ship using its saved approach axis. Returns (success, reason)."
function depart_ship!(gamemap::GameMap, ship_name::Symbol; max_view_bounds::Union{HexFrame.CartesianBounds, Nothing} = nothing)::Tuple{Bool, String}
    status = get_docking_status(gamemap, ship_name)
    if isnothing(status)
        return false, "Can't depart: ship $(ship_name) not found."
    end

    if status isa FlowMap.ApproachingDockStat
        return false, "Can't depart: ship $(ship_name) not connected yet."
    end

    if status isa FlowMap.DepartingDockStat
        return false, "Can't depart: ship $(ship_name) already departing."
    end

    if !(status isa FlowMap.ConnectedDockStat)
        return false, "Can't depart: ship $(ship_name) has unknown docking state."
    end

    approach_axis = get_approach_axis(status)
    if isnothing(approach_axis)
        return false, "Can't depart: no saved departure axis."
    end

    # Check pipe connections — block departure if pipes still bridge to another ship
    can_depart, reason = check_departure_pipe_connections(gamemap, ship_name)
    if !can_depart
        return false, reason
    end

    # Depart by backtracking along the original approach axis (return to where the ship came from)
    depart_axis = approach_axis

    # Calculate departure animation parameters
    DEPART_DISTANCE_TILES = 20.0
    
    # Direction vector
    direction_vec = HexFrame.hex_vert_vecs[depart_axis]

    # If bounds provided, ensure target point is off-screen
    if !isnothing(max_view_bounds)
        ship_bounds = get_cartesian_bounds(gamemap.ships[ship_name])
        
        # Increase distance until out of view
        is_overlapping = true
        while is_overlapping
             target_offset_test = HexFrame.AxialCoord(
                direction_vec.q * DEPART_DISTANCE_TILES,
                direction_vec.r * DEPART_DISTANCE_TILES
            )
            
            # Shift the ship bounds by this offset
            shift_cart = HexFrame.to_cartesian(target_offset_test)
            shifted_bounds = (
                X_POS = ship_bounds.X_POS + shift_cart.x,
                X_NEG = ship_bounds.X_NEG + shift_cart.x,
                Y_POS = ship_bounds.Y_POS + shift_cart.y,
                Y_NEG = ship_bounds.Y_NEG + shift_cart.y
            )
            
            if _rects_overlap(shifted_bounds, max_view_bounds)
                DEPART_DISTANCE_TILES += 10.0
                if DEPART_DISTANCE_TILES > 2000.0 # Safety break
                    @warn "Could not find safe depart distance, capping at 2000"
                    break
                end
            else
                is_overlapping = false
            end
        end
    end

    TARGET_DEPART_DURATION_SECS = 5.0
    TARGET_UPS = 60.0

    # Convert tile distance to axial offset
    direction_vec = HexFrame.hex_vert_vecs[depart_axis]
    target_offset = HexFrame.AxialCoord(
        direction_vec.q * DEPART_DISTANCE_TILES,
        direction_vec.r * DEPART_DISTANCE_TILES
    )
    start_offset = HexFrame.AxialCoord(0.0, 0.0)

    # Calculate step size
    total_distance = sqrt(target_offset.q^2 + target_offset.r^2)
    total_updates = TARGET_DEPART_DURATION_SECS * TARGET_UPS
    offset_step = total_distance / total_updates

    set_docking_status!(gamemap, ship_name, DepartingDockStat(start_offset, target_offset, offset_step, approach_axis))
    reason = "Ship $(ship_name) departing (axis=$(depart_axis))"
    return true, reason
end

# =============================================================== #
# Encounter Point System
# =============================================================== #

"Configuration for the encounter point system."
@kwdef struct EncounterSystemConfig
    n_points::Int = 100
    min_base_velocity::Float64 = 10.0
    max_base_velocity::Float64 = 1000.0
    velocity_variance::Float64 = 0.1          # ±10% of base velocity
    max_angle_rad::Float64 = π/8              # 22.5 degrees from horizontal
    viewport_half_width::Float64 = 400.0
    viewport_half_height::Float64 = 200.0
    spawn_margin::Float64 = 100.0             # Distance from viewport edge to spawn lines
    recycle_margin::Float64 = 50.0          # Extra distance from spawn lines to disappear lines
    line_step_size::Float64 = 50.0           # Discrete step for shifting lines
end

"Generate base velocities with a logarithmic distribution (equal density per octave)."
function generate_base_velocities(n_points::Int, min_velocity::Float64,
                                   max_velocity::Float64, seed::UInt32)::Vector{Float64}
    velocities = Vector{Float64}(undef, n_points)
    ratio = max_velocity / min_velocity
    for i in 1:n_points
        u = get_noise_zero_to_one(i, seed)
        velocities[i] = min_velocity * ratio^u
    end
    sort!(velocities)
    return velocities
end

"Calculate the position of an encounter point at a given time."
function get_encounter_position(ep::EncounterPoint, time::Float64)::SVector{2, Float64}
    dt = time - ep.spawn_time
    return ep.position + ep.velocity * dt
end

"Predict when an encounter point will cross a vertical line at x_line. Returns nothing if it never will."
function predict_crossing_time(ep::EncounterPoint, x_line::Float64)::Union{Nothing, Float64}
    vx = ep.velocity[1]
    if abs(vx) < 1e-12
        return nothing  # Moving purely vertically, never crosses
    end
    dt = (x_line - ep.position[1]) / vx
    if dt < 0.0
        return nothing  # Already past the line
    end
    return ep.spawn_time + dt
end

"""
Spawn (or respawn) an encounter point at `spawn_line_x` with a new random trajectory.

The `spawn_line_x` argument selects which boundary the point spawns on:
- Pass `sm.neg_spawn_line_x` for a normal left-side spawn (ship moves rightward).
- Pass `sm.pos_spawn_line_x` for a backfill spawn (ship overtaken by the player, placed
  at the right-side spawn line still moving rightward, so it disappears quickly if
  the player stops accelerating).

In both cases the point's velocity is `sm.velocity + relative_vel` so the relative speed
distribution is preserved regardless of which line is used.
"""
function spawn_encounter_point!(ep::EncounterPoint, sm::SpaceMapState,
                                 config::EncounterSystemConfig, current_time::Float64,
                                 spawn_line_x::Float64 = sm.neg_spawn_line_x; 
                                 velocity_override::Union{Nothing, SVector{2, Float64}} = nothing)
    ep.iteration += 1
    ep.spawn_time = current_time

    # Derive unique seeds from the map seed, index, and iteration
    point_seed = get_noise(UInt32(ep.index), get_noise(UInt32(ep.iteration), sm.seed))
    ep.ship_type_seed = get_noise(UInt32(ep.index + 1000), get_noise(UInt32(ep.iteration), sm.seed))

    # Random Y position along the spawn line
    spawn_y_range = sm.viewport_half_height + config.spawn_margin
    player_y_position = get_position(sm)[2]
    y_pos = pick_from_range(player_y_position - spawn_y_range, player_y_position + spawn_y_range, ep.index * 1000 + ep.iteration, point_seed)
    ep.position = SVector(spawn_line_x, y_pos)

    # Random speed: base_velocity ± variance
    speed_noise = get_noise_zero_to_one(ep.index * 2000 + ep.iteration, point_seed)
    speed = ep.base_velocity * (1.0 - config.velocity_variance +
                                 2.0 * config.velocity_variance * speed_noise)

    # Random angle within ±max_angle of horizontal
    angle_noise = get_noise_zero_to_one(ep.index * 3000 + ep.iteration, point_seed)
    angle = config.max_angle_rad * (2.0 * angle_noise - 1.0)

    # Velocity is relative to the player's velocity
    relative_vel = SVector(speed * cos(angle), speed * sin(angle))
    ep.velocity = velocity_override === nothing ? sm.velocity + relative_vel : velocity_override

    return nothing
end

"Spawn an encounter point at a random position across the full visible area (used for initial distribution)."
function spawn_encounter_point_distributed!(ep::EncounterPoint, sm::SpaceMapState,
                                             config::EncounterSystemConfig, current_time::Float64)
    ep.iteration += 1
    ep.spawn_time = current_time

    point_seed = get_noise(UInt32(ep.index), get_noise(UInt32(ep.iteration), sm.seed))
    ep.ship_type_seed = get_noise(UInt32(ep.index + 1000), get_noise(UInt32(ep.iteration), sm.seed))

    # Distribute across the full x range between the outermost boundary lines
    x_pos = pick_from_range(sm.neg_disappear_line_x, sm.pos_disappear_line_x, ep.index * 4000 + ep.iteration, point_seed)
    y_range = sm.viewport_half_height + config.spawn_margin
    y_pos = pick_from_range(-y_range, y_range, ep.index * 5000 + ep.iteration, point_seed)
    ep.position = SVector(x_pos, y_pos)

    # Speed and angle (same logic as normal spawn)
    speed_noise = get_noise_zero_to_one(ep.index * 2000 + ep.iteration, point_seed)
    speed = ep.base_velocity * (1.0 - config.velocity_variance +
                                 2.0 * config.velocity_variance * speed_noise)

    angle_noise = get_noise_zero_to_one(ep.index * 3000 + ep.iteration, point_seed)
    angle = config.max_angle_rad * (2.0 * angle_noise - 1.0)

    relative_vel = SVector(speed * cos(angle), speed * sin(angle))
    ep.velocity = sm.velocity + relative_vel

    return nothing
end

"""
Rebuild the event queue from scratch and recycle any points already outside the boundary lines.

For each encounter point:
- If its current position is already past `pos_disappear_line_x` (drifted too far forward)
  it is respawned at `neg_spawn_line_x` (normal left-side spawn).
- If its current position is already behind `neg_disappear_line_x` (player has outrun it)
  it is respawned at `pos_spawn_line_x` (right-side backfill spawn).
- Otherwise a crossing-time event is predicted and pushed to the queue as normal.

Called after every discrete line shift in `check_line_shift!`.
"""
function rebuild_event_queue!(sm::SpaceMapState, config::EncounterSystemConfig = EncounterSystemConfig())
    sm.event_queue = BinaryMinHeap{EncounterEvent}()
    current_time = sm.time_years
    for ep in sm.encounter_points
        current_x = get_encounter_position(ep, current_time)[1]

        if current_x > sm.pos_disappear_line_x
            # Point has drifted past the positive disappear line — recycle to left spawn
            spawn_encounter_point!(ep, sm, config, current_time, sm.neg_spawn_line_x)
        elseif current_x < sm.neg_disappear_line_x
            # Player has outrun this point — backfill by spawning at the right spawn line
            spawn_encounter_point!(ep, sm, config, current_time, sm.pos_spawn_line_x)
        end

        # Predict crossing time for points still within the boundaries and add to the event queue
        crossing_time = predict_crossing_time(ep, sm.pos_disappear_line_x)
        if !isnothing(crossing_time) && crossing_time > current_time
            push!(sm.event_queue, EncounterEvent(crossing_time, ep.index))
        end
    end
    return nothing
end

"""
Shift all four boundary lines if the player has moved far enough, then rebuild the event queue.

Lines shift in discrete steps of `line_step_size` so the spawn/disappear boundaries always
stay just outside the viewport regardless of accumulated player travel.
"""
function check_line_shift!(sm::SpaceMapState, config::EncounterSystemConfig)
    player_x = sm.position[1]
    step = sm.line_step_size
    moved = player_x - sm.last_line_step_x

    if abs(moved) >= step
        n_steps = floor(Int, moved / step)
        shift = n_steps * step
        sm.last_line_step_x += shift
        sm.neg_disappear_line_x += shift
        sm.neg_spawn_line_x += shift
        sm.pos_spawn_line_x += shift
        sm.pos_disappear_line_x += shift
        rebuild_event_queue!(sm, config)
    end

    return nothing
end

"Process encounter point recycling events up to the given time."
function process_encounter_events!(sm::SpaceMapState, config::EncounterSystemConfig,
                                    up_to_time::Float64)
    while !isempty(sm.event_queue)
        next_event = first(sm.event_queue)
        if next_event.time > up_to_time
            break
        end
        pop!(sm.event_queue)

        ep = sm.encounter_points[next_event.index]
        # Normal recycle: point has crossed pos_disappear_line_x, respawn at neg_spawn_line_x
        spawn_encounter_point!(ep, sm, config, up_to_time, sm.neg_spawn_line_x)

        crossing_time = predict_crossing_time(ep, sm.pos_disappear_line_x)
        if !isnothing(crossing_time) && crossing_time > up_to_time
            push!(sm.event_queue, EncounterEvent(crossing_time, ep.index))
        end
    end
    return nothing
end

"Initialise the encounter point system on a SpaceMapState."
function initialise_encounter_system!(sm::SpaceMapState, config::EncounterSystemConfig = EncounterSystemConfig())
    current_time = sm.time_years

    sm.viewport_half_width = config.viewport_half_width
    sm.viewport_half_height = config.viewport_half_height
    sm.line_step_size = config.line_step_size

    player_x = sm.position[1]
    sm.neg_spawn_line_x    = player_x - config.viewport_half_width - config.spawn_margin
    sm.neg_disappear_line_x = player_x - config.viewport_half_width - config.spawn_margin - config.recycle_margin
    sm.pos_spawn_line_x    = player_x + config.viewport_half_width + config.spawn_margin
    sm.pos_disappear_line_x = player_x + config.viewport_half_width + config.spawn_margin + config.recycle_margin
    sm.last_line_step_x = player_x

    base_velocities = generate_base_velocities(config.n_points,
                                                config.min_base_velocity,
                                                config.max_base_velocity, sm.seed)

    sm.encounter_points = Vector{EncounterPoint}(undef, config.n_points)
    sm.event_queue = BinaryMinHeap{EncounterEvent}()

    for i in 1:config.n_points
        ep = EncounterPoint(index=i, base_velocity=base_velocities[i])
        spawn_encounter_point_distributed!(ep, sm, config, current_time)
        sm.encounter_points[i] = ep

        crossing_time = predict_crossing_time(ep, sm.pos_disappear_line_x)
        if !isnothing(crossing_time) && crossing_time > current_time
            push!(sm.event_queue, EncounterEvent(crossing_time, ep.index))
        end
    end

    return nothing
end

"Advance the space map time by one tick. No-op for SpaceMapEmpty."
function step_space_map_time!(::SpaceMapEmpty;
                               config::EncounterSystemConfig = EncounterSystemConfig(),
                               max_step::Float64 = 1.0/60.0)
    return false
end

"Advance the space map time by one tick. Returns true if time was advanced."
function step_space_map_time!(sm::SpaceMapState;
                               config::EncounterSystemConfig = EncounterSystemConfig(),
                               max_step::Float64 = 1.0/60.0)::Bool
    if sm.time_years >= sm.target_time_years
        return false
    end

    old_time = sm.time_years
    new_time = min(old_time + max_step, sm.target_time_years)
    dt = new_time - old_time

    # Update player position (velocity is constant between manoeuvres)
    sm.position = sm.position + sm.velocity * dt

    # Process encounter recycling events up to the new time
    process_encounter_events!(sm, config, new_time)

    # Commit the new time
    sm.time_years = new_time

    # Check if lines need to shift
    check_line_shift!(sm, config)

    return true
end

# =============================================================== #
# Manoeuvre Planning
# =============================================================== #

"""
Compute the time, distance, and positions of closest approach between the player and an
encounter point, assuming both travel in straight lines at constant velocity.

Uses the quadratic minimisation approach: the squared distance
f(t) = A*t² + B*t + C is minimised at t_min = -B / (2A).
If the minimum lies in the past (diverging or parallel paths), returns the current
time and current separation.
"""
function compute_closest_approach(
        player_pos::SVector{2, Float64},
        player_vel::SVector{2, Float64},
        ep::EncounterPoint,
        current_time::Float64
    )
    target_pos = get_encounter_position(ep, current_time)

    # Relative position and velocity (target frame)
    a = target_pos - player_pos
    b = ep.velocity - player_vel

    A = dot(b, b)
    B = 2.0 * dot(a, b)

    # No relative motion — distance is constant
    if A < 1e-12
        return (time = current_time, distance = norm(a),
                player_position = player_pos, target_position = target_pos)
    end

    t_min = -B / (2.0 * A)

    # Closest approach in the past or right now — act immediately
    if t_min <= 0.0
        return (time = current_time, distance = norm(a),
                player_position = player_pos, target_position = target_pos)
    end

    closest_time = current_time + t_min
    closest_distance = norm(a + b * t_min)
    player_at_ca = player_pos + player_vel * t_min
    target_at_ca = get_encounter_position(ep, closest_time)
    return (time = closest_time, distance = closest_distance,
            player_position = player_at_ca, target_position = target_at_ca)
end

"""
Calculate the minimum delta‑V needed to intercept an encounter point.

Returns the velocity‑match ΔV plus a minimum surplus for closing the gap.
"""
function calculate_minimum_intercept_dv(
        player_vel::SVector{2, Float64},
        target_vel::SVector{2, Float64};
        min_surplus::Float64 = 5.0
    )::Float64
    return norm(target_vel - player_vel) + min_surplus
end

"""
Plan an intercept manoeuvre at the given total ΔV budget.

Manoeuvre model:
1. Determine whether to burn immediately or wait for closest approach.
   - Burn immediately if ships are diverging, or if convergence rate < close velocity.
   - Wait for closest approach if ships are already converging faster than close velocity.
2. Main burn: velocity match + surplus/2 toward the intercept position.
3. Coast the remaining gap at close velocity (surplus/2).
4. Deceleration burn: surplus/2 to re‑match velocities.

Returns `ManoeuvreData` or `nothing` if the total ΔV is insufficient.
"""
function plan_intercept_manoeuvre(
        player_pos::SVector{2, Float64},
        player_vel::SVector{2, Float64},
        ep::EncounterPoint,
        current_time::Float64,
        total_dv::Float64,
    )::Union{Nothing, ManoeuvreData}
    # Check minimum ΔV feasibility
    min_dv = calculate_minimum_intercept_dv(player_vel, ep.velocity)
    total_dv < min_dv && return nothing

    relative_vel = ep.velocity - player_vel
    velocity_match = norm(relative_vel)
    surplus = total_dv - velocity_match
    close_velocity = surplus / 2.0

    ca = compute_closest_approach(player_pos, player_vel, ep, current_time)

    # Decide whether to burn immediately or wait for closest approach.
    # Convergence rate: how fast the separation is shrinking right now.
    # Positive = converging, negative = diverging.
    separation = get_encounter_position(ep, current_time) - player_pos
    sep_dist = norm(separation)
    sep_unit = sep_dist > 1e-6 ? separation / sep_dist : SVector(1.0, 0.0)
    convergence_rate = -dot(relative_vel, sep_unit)  # positive when closing

    # Burn immediately if diverging or converging slower than our planned close velocity
    burn_immediately = convergence_rate < close_velocity

    if burn_immediately
        # First burn at the current position/time
        burn_time = current_time
        burn_player_pos = player_pos
        burn_distance = sep_dist
    else
        # Wait for closest approach
        burn_time = ca.time
        burn_player_pos = ca.player_position
        burn_distance = ca.distance
    end

    # Coast time: distance / close_velocity (close_velocity = surplus/2)
    coast_time = if burn_distance > 1e-6 && close_velocity > 1e-6
        burn_distance / close_velocity
    else
        0.0
    end

    intercept_time = burn_time + coast_time

    #= Direction from player at burn toward target at burn time.
       After the main burn the player velocity-matches the target, so both
       drift at ep.velocity.  The only relative closing happens via
       dir_unit * close_velocity in the target's reference frame.  Therefore
       the closing direction must point at wherever the target is when the
       burn fires — NOT at the future intercept position. =#
    target_pos_at_burn = get_encounter_position(ep, burn_time)
    direction = target_pos_at_burn - burn_player_pos
    dir_norm = norm(direction)
    dir_unit = if dir_norm > 1e-6
        direction / dir_norm
    elseif velocity_match > 1e-6
        relative_vel / velocity_match
    else
        SVector(1.0, 0.0)
    end

    # Main burn: velocity match + surplus/2 closing component (space-map frame)
    main_burn_dv = relative_vel + dir_unit * close_velocity

    # Deceleration burn: surplus/2 opposite to closing direction (space-map frame)
    decel_burn_dv = -dir_unit * close_velocity

    # Intercept position for rendering / ManoeuvreData (where encounter happens in spacemap coords)
    target_pos_at_intercept = get_encounter_position(ep, intercept_time)

    return ManoeuvreData(
        phase                 = PHASE_WAIT_APPROACH,
        main_burn_dv          = main_burn_dv,
        decel_burn_dv         = decel_burn_dv,
        closest_approach_time = burn_time,
        intercept_time        = intercept_time,
        target_encounter_index = ep.index,
        trajectory_start_pos  = player_pos,
        trajectory_start_time = current_time,
        surplus_dv            = surplus,
        main_burn_position    = burn_player_pos,
        decel_burn_position   = target_pos_at_intercept,
    )
end

"Determine the ShipGenOptions for an encounter point using its composite seed."
function get_encounter_ship_options(ep::EncounterPoint,
                                     ship_weights::Vector{Tuple{ShipGenOptions, Float64}})::ShipGenOptions
    return weighted_roll_noise(ship_weights, ep.index, ep.ship_type_seed)
end

"Get the seed for procedural ship generation for this encounter point."
function get_encounter_ship_seed(ep::EncounterPoint, map_seed::UInt32)::UInt32
    return get_noise(UInt32(ep.index), get_noise(UInt32(ep.iteration), map_seed))
end


end # module HexFlowProcGen
