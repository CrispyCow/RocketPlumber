module HexFlowProcGen

using Random
using HexFrame, FlowEngine, SquirrelNoise, HexComponentsAPI

export random_tile_walk!, random_tile_walk, stacked_random_tile_walk!
export weighted_roll_noise, pick_from_range, pick_from_options
export PlacementStrategy, ShipComponentSet, SpawnOptions, roll_component
export place_shipset!, place_random_pipes!

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


function pick_from_range(min::T, max::T, point, seed::UInt32) where {T <: Real}
    noise = get_noise_zero_to_one(point, seed)
    raw = min + noise * (max - min)

    return T <: Integer ? round(T, raw) : T(raw) # ensures uniform sampling for integer types
end

function pick_from_options(options::Vector{T}, point, seed::UInt32) where {T}
    return pick_element_from_noise(options, point, seed)
end


# =============================================================== #
# component placement
# =============================================================== #

@enum PlacementStrategy begin
    RANDOM_PLACE
    CLUSTERED_PLACE
    NOZZLE_EDGE_PLACE
end

struct SpawnOptions
    kind::Symbol
    spawn_count_weights::Vector{Tuple{Int, Float64}}
    placement::PlacementStrategy
end

struct ShipComponentSet
    name::String
    components::Vector{SpawnOptions}
end

#const POSSIBLE_HEXAXIS

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
    existing_components::Set{TileCoord} = Set(keys(get_all_tiles(map)))

    ship_surface_edge::Set{TileCoord} = Set{TileCoord}()
    find_ship_surface_edgetiles!(ship_surface_edge, map)
    all_tiles_adjacent_to_edgetiles::Set{TileCoord} = Set{TileCoord}()
    for edge_tile in ship_surface_edge
        union!(all_tiles_adjacent_to_edgetiles, get_adjacent_tiles_for_tile(edge_tile))
    end
    # tiles adjecent to the edge of the ship but not part of the ship surface are valid for nozzles
    available_nozzle_tiles = setdiff(all_tiles_adjacent_to_edgetiles, get_ship_surface(map))
    # all surface tiles are valid for everything else
    available_ship_surface::Set{TileCoord} = Set(get_ship_surface(map))
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
                set_tile!(map, selected_coord, deepcopy(tilecomp))
            end

        elseif spawn_option.placement == RANDOM_PLACE
            # random place rolls each component individually, assuming all rotations can be mapped to a valid one
            for selected_coord in component_location_list
                comp_behav = roll_component(spawn_option.kind, selected_coord, seed)
                comp_rotation = map_rotation(comp_behav, pick_element_from_rng(instances(HexFrame.HexAxis), prng))
                tilecomp = ComponentOnTile(comp_behav, comp_rotation)

                set_tile!(map, selected_coord, deepcopy(tilecomp))
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
                    valid_pick, reason = placement_valid(comp_behav, coord = selected_coord, gamemap = map, rotation = chosen_axis)
                    if valid_pick
                        set_tile!(map, selected_coord, ComponentOnTile(comp_behav, chosen_axis))
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

"allocated set of all edgecoords for the given set of tiles"
function get_all_edgecoords_of_tiles(tiles::Set{TileCoord})
    edgecoords = Set{EdgeCoord}()

    for tile in tiles
        union!(edgecoords, get_edges(tile))
    end

    return edgecoords
end

"randomly chooses to place a pipe at the given edge based on noise and pipe density"
function noise_pipe_place_helper!(map::GameMap, edge::EdgeCoord, pipe_behav::PipeBehavior, seed::UInt32; pipe_density)
    used_pipe_density = clamp(pipe_density, 0.0, 1.0)
    hashed_edge = UInt32(hash(edge, hash(pipe_behav)) & typemax(UInt32)) # mix in pipe behavior to vary placement
    roll = get_noise_zero_to_one(hashed_edge, seed)
    if roll <= used_pipe_density
        set_pipe!(map, edge, pipe_behav)
    end

    return nothing
end

"randomly chooses to place pipes at the given edges based on noise and pipe density"
function noise_pipe_place_helper!(map::GameMap, edges, pipe_behav::PipeBehavior, seed::UInt32; pipe_density)
    for edgecoord in edges
        noise_pipe_place_helper!(map, edgecoord, pipe_behav, seed; pipe_density = pipe_density)
    end

    return nothing
end

"places pipes randomly on canidate edges that connect to 1 and only 1 existing node on the map based on pipe density"
function place_connected_pipes!(map::GameMap, pipe_behav::PipeBehavior, seed::UInt32; pipe_density)
    ship_surface = deepcopy(get_ship_surface(map))
    available_edgecoords = get_all_edgecoords_of_tiles(ship_surface)
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
    noise_pipe_place_helper!(map, available_edgecoords, pipe_behav, seed; pipe_density = pipe_density)

    return nothing
end

"places pipes randomly on on canidate edges that do not connect 2 nodes based on pipe density"
function place_random_pipes!(map::GameMap, pipe_behav::PipeBehavior, seed::UInt32; pipe_density)
    ship_surface = deepcopy(get_ship_surface(map))
    available_edgecoords = get_all_edgecoords_of_tiles(ship_surface)
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
    noise_pipe_place_helper!(map, available_edgecoords, pipe_behav, seed; pipe_density = pipe_density)

    return nothing
end

end # module HexFlowProcGen
