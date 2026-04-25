module HexFlowProcGen

using Random, LinearAlgebra, StaticArrays, Printf
using HexFrame, FlowMap, SquirrelNoise, HexComponentsAPI, FlowEngine, HexFluids
using StructEquality: @struct_hash_equal

# Import FlowMap functions to extend with SpaceMapState methods
import FlowMap: AbstractSpaceMap, get_velocity, set_velocity!, get_space_map_seed
import FlowMap: get_time_years, set_time_years!, get_active_manoeuvre, has_active_manoeuvre
import FlowMap: set_active_manoeuvre!, clear_active_manoeuvre!, get_position, set_position!
import FlowMap: get_target_time, set_target_time!, is_time_progressing, get_encounter_points
import FlowMap: initialise_spacemap!

export random_tile_walk!, random_tile_walk, stacked_random_tile_walk!
export weighted_roll_noise, weighted_roll_rng, pick_from_range, pick_from_options
export CompPlacementStrategy, ShipComponentSet, CompSpawnOptions, roll_component
export PipePlacementStrategy, PipeSpawnOptions, roll_pipe
export place_shipset!, place_random_pipes!, place_connected_pipes!, place_pipeset!
export ScalingRule, NoScaling, LinearScaling, GatedLinearScaling, evaluate_scaling
export WeightedComponentSet
export select_encounter_class, select_fuel_tag
export generate_encounter, generate_encounter_name
export encounter_ship!, encounter_ship_optimal_dir!, depart_ship!
export check_departure_pipe_connections
export EncounterSystemConfig, initialise_encounter_system!
export spawn_encounter_point!, get_encounter_position, check_encounter_bounds!
export step_space_map_time!
export calculate_minimum_intercept_dv, plan_intercept_manoeuvre
export get_encounter_ship_seed
export generate_base_velocities
export HullSizeConfig, FuelTagConfig, EncounterClassConfig
export compute_hull_size, compute_target_components, evaluate_component_pool, calculate_richness
export SpaceMapState, get_encounter_config
export estimate_min_delta_v


"Minimum gap (in tile-steps) added between ships after clearing overlap."
const MIN_SPACING::Int = 2

# ===============================================================
# Utilities
# ===============================================================

"Pick a deterministic random value in `[min, max]` from SquirrelNoise."
function pick_from_range(min::T, max::T, point, seed::UInt32) where {T <: Real}
    noise = get_noise_zero_to_one(point, seed)
    raw = min + noise * (max - min)
    return T <: Integer ? round(T, raw) : T(raw) # round for uniform integer sampling
end

"Pick a deterministic random element from `options` using SquirrelNoise."
function pick_from_options(options::Vector{T}, point, seed::UInt32) where {T}
    return pick_element_from_noise(options, point, seed)
end

"Select a weighted random item from `weights` using an RNG instance."
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

"Select a weighted random item from `weights` using SquirrelNoise."
function weighted_roll_noise(weights::Vector{Tuple{T, Float64}}, point, seed::UInt32) where {T}
    isempty(weights) && error("weighted_roll_noise called with empty weights vector")
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

# ===============================================================
# Surface Generation
# ===============================================================

"Grow `tiles` via a deterministic random walk from `start` for `steps` steps."
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

"Return a new tile set from a deterministic random walk starting at `start`."
function random_tile_walk(start::TileCoord, steps::Int, seed::UInt32)
    new_tiles = Set{TileCoord}()
    random_tile_walk!(new_tiles, start, steps, seed)
    return new_tiles
end

"Grow `tiles` via `stacks` overlapping random walks, biasing the surface towards the centre."
function stacked_random_tile_walk!(tiles::Set{TileCoord}, start::TileCoord, steps::Int, stacks::Int, seed::UInt32)
    for stack in 1:stacks
        stack_seed = get_noise(stack, seed)
        random_tile_walk!(tiles, start, steps, stack_seed)
    end

    return nothing
end

# ===============================================================
# Component Placement
# ===============================================================

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

"Roll a component of the given kind symbol via Val dispatch."
roll_component(kind::Symbol, point, seed) =
    roll_component(Val(kind), point, seed)

"Default fallback — error for unknown component kind."
roll_component(::Val{K}, point, seed) where {K} =
    error("Unknown component kind: $K")

"Remove `coord` and all its neighbours from `tiles`."
function clear_tiles_around_component!(tiles::Set{TileCoord}, coord::TileCoord)
    delete!(tiles, coord)
    for neighbor in get_adjacent_tiles_for_tile(coord)
        delete!(tiles, neighbor)
    end

    return nothing
end

"Place all components from `shipset` onto the map. Returns `(success, message)`."
function place_shipset!(map::GameMap, shipset::ShipComponentSet, seed::UInt32)::Tuple{Bool, String}
    existing_components::Set{TileCoord} = Set(keys(get_all_components(map)))

    ship_surface_edge::Set{TileCoord} = Set{TileCoord}()
    find_ship_surface_edgetiles!(ship_surface_edge, map)
    all_tiles_adjacent_to_edgetiles::Set{TileCoord} = Set{TileCoord}()
    for edge_tile in ship_surface_edge
        union!(all_tiles_adjacent_to_edgetiles, get_adjacent_tiles_for_tile(edge_tile))
    end
    # Tiles adjacent to the edge but not on the ship surface are valid for nozzles
    available_nozzle_tiles = setdiff(all_tiles_adjacent_to_edgetiles, get_all_surface_tiles(map))
    # All surface tiles are valid for everything else
    available_ship_surface::Set{TileCoord} = Set(get_all_surface_tiles(map))
    # Clear all tiles adjacent to existing components
    for coord in existing_components
        clear_tiles_around_component!(available_nozzle_tiles, coord)
        clear_tiles_around_component!(available_ship_surface, coord)
    end

    # Preallocated buffers
    prng = MersenneTwister(seed)
    component_location_list = Vector{TileCoord}()
    candidate_tiles = Set{TileCoord}()
    possible_rotations = Vector{HexFrame.HexAxis}(collect(instances(HexFrame.HexAxis)))

    for spawn_option in shipset.components
        empty!(component_location_list)
        count = weighted_roll_rng(prng, spawn_option.spawn_count_weights)

        # Build list of positions to place components
        if spawn_option.placement == CLUSTERED_PLACE
            for index in 1:count
                if isempty(available_ship_surface)
                    return (false, "Failed to cluster place component $(spawn_option.kind): no available ship surface tiles")
                end

                if isempty(component_location_list)
                    # First component, pick randomly
                    selected_coord = pick_element_from_rng(available_ship_surface, prng)
                else
                    # Pick from candidates if any, otherwise fall back to full surface
                    empty!(candidate_tiles)
                    union!(candidate_tiles, get_adjacent_tiles_for_tile(component_location_list[end]))
                    intersect!(candidate_tiles, available_ship_surface)
                    selected_coord = isempty(candidate_tiles) ? pick_element_from_rng(available_ship_surface, prng) : pick_element_from_rng(candidate_tiles, prng)
                end

                delete!(available_ship_surface, selected_coord) # only delete actual coordinate for now
                push!(component_location_list, selected_coord)
            end

            # Clean up adjacent tiles after placing all components in the cluster
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

        # Skip if no components to place
        if isempty(component_location_list)
            continue
        end

        # Place components from list according to strategy
        if spawn_option.placement == CLUSTERED_PLACE
            # Clustered: identical components, assumes all rotations can be mapped to a valid one
            comp_behav = roll_component(spawn_option.kind, first(component_location_list), seed)
            comp_rotation = map_rotation(comp_behav, pick_element_from_rng(instances(HexFrame.HexAxis), prng))
            tilecomp = ComponentOnTile(comp_behav, comp_rotation)

            for selected_coord in component_location_list
                set_component!(map, selected_coord, deepcopy(tilecomp))
            end

        elseif spawn_option.placement == RANDOM_PLACE
            # Random: rolls each component individually, assumes all rotations are valid
            for selected_coord in component_location_list
                comp_behav = roll_component(spawn_option.kind, selected_coord, seed)
                comp_rotation = map_rotation(comp_behav, pick_element_from_rng(instances(HexFrame.HexAxis), prng))
                tilecomp = ComponentOnTile(comp_behav, comp_rotation)

                set_component!(map, selected_coord, deepcopy(tilecomp))
            end

        elseif spawn_option.placement == NOZZLE_EDGE_PLACE
            # Nozzle edge: rolls each individually, validating orientation
            for selected_coord in component_location_list
                # Generate component based on coordinate noise
                comp_behav = roll_component(spawn_option.kind, selected_coord, seed)

                # Find valid orientation then place on the map
                shuffle!(prng, possible_rotations)
                for random_axis in possible_rotations
                    chosen_axis = map_rotation(comp_behav, random_axis)

                    # Check if placement is valid
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

# ===============================================================
# Pipe Placement
# ===============================================================

@enum PipePlacementStrategy begin
    RANDOM_PIPES
    ONE_CONNECT_PIPES
end

struct PipeSpawnOptions
    kind::Symbol
    placement::PipePlacementStrategy
    density::Float64
end

"Roll a pipe of the given kind symbol via Val dispatch."
roll_pipe(kind::Symbol, point, seed) =
    roll_pipe(Val(kind), point, seed)

"Default fallback — error for unknown pipe kind."
roll_pipe(::Val{K}, point, seed) where {K} =
    error("Unknown pipe kind: $K")

"Return the set of all `EdgeCoord`s belonging to the given tiles."
function get_all_edgecoords_of_tiles(tiles::Set{TileCoord})
    edgecoords = Set{EdgeCoord}()

    for tile in tiles
        union!(edgecoords, get_edges(tile))
    end

    return edgecoords
end

"Hash an edge with a pipe kind to produce a deterministic UInt32 noise key."
hash_pipe_edge(edge::EdgeCoord, pipe_kind::Symbol) = UInt32(hash(edge, hash(pipe_kind)) & typemax(UInt32))

"Remove edges that fail the noise density check for `pipe_kind`. Mutates `edges` in-place."
function noise_filter_pipe_edges!(edges::Set{EdgeCoord}, pipe_kind::Symbol, seed::UInt32; pipe_density)
    used_pipe_density = clamp(pipe_density, 0.0, 1.0)
    filter!(edges) do edge
        roll = get_noise_zero_to_one(hash_pipe_edge(edge, pipe_kind), seed)
        roll <= used_pipe_density
    end
    return edges
end

"Remove edges that share a vertex with any other edge in the set."
function filter_mutually_connected_edges!(edges::Set{EdgeCoord})
    to_remove = EdgeCoord[]
    for edge in edges
        is_connected = false
        for adj in get_edges(edge.v1)
            if adj != edge && adj in edges
                is_connected = true
                break
            end
        end
        if !is_connected
            for adj in get_edges(edge.v2)
                if adj != edge && adj in edges
                    is_connected = true
                    break
                end
            end
        end
        is_connected && push!(to_remove, edge)
    end
    for edge in to_remove
        delete!(edges, edge)
    end
    return edges
end

"Place pipes on candidate edges connecting to exactly one existing node, filtered by `pipe_density`."
function place_connected_pipes!(map::GameMap, pipe_kind::Symbol, seed::UInt32; pipe_density)
    ship_tiles = deepcopy(get_all_surface_tiles(map))
    available_edgecoords = get_all_edgecoords_of_tiles(ship_tiles)
    # all_nodes covers component AND pipe-endpoint nodes (via list_elements), preventing a
    # second pipe-placement call from bridging through an existing-pipe vertex.
    all_nodes = Set(keys(list_nodes(list_elements(map))))

    # Keep only edges that would connect to exactly one existing node
    for edgecoord in available_edgecoords
        v1_is_connected = to_nodecoord(edgecoord.v1) in all_nodes
        v2_is_connected = to_nodecoord(edgecoord.v2) in all_nodes
        if v1_is_connected == v2_is_connected  # both or neither connected — remove
            delete!(available_edgecoords, edgecoord)
        end
    end

    # Filter by noise density, then remove edges that would interconnect
    noise_filter_pipe_edges!(available_edgecoords, pipe_kind, seed; pipe_density)
    filter_mutually_connected_edges!(available_edgecoords)

    # Place surviving edges
    for edgecoord in available_edgecoords
        pipe_behav = roll_pipe(pipe_kind, hash_pipe_edge(edgecoord, pipe_kind), seed)
        set_pipe!(map, edgecoord, pipe_behav)
    end

    return nothing
end

"Place pipes on candidate edges that do not bridge two existing nodes, filtered by `pipe_density`."
function place_random_pipes!(map::GameMap, pipe_kind::Symbol, seed::UInt32; pipe_density)
    ship_tiles = deepcopy(get_all_surface_tiles(map))
    available_edgecoords = get_all_edgecoords_of_tiles(ship_tiles)
    # all_nodes covers component AND pipe-endpoint nodes (via list_elements), preventing a
    # second pipe-placement call from bridging through an existing-pipe vertex.
    all_nodes = Set(keys(list_nodes(list_elements(map))))

    # Remove any edges that would bridge two existing nodes
    for edgecoord in available_edgecoords
        v1_is_connected = to_nodecoord(edgecoord.v1) in all_nodes
        v2_is_connected = to_nodecoord(edgecoord.v2) in all_nodes

        if v1_is_connected && v2_is_connected
            delete!(available_edgecoords, edgecoord)
        end
    end

    # Filter by noise density, then remove edges that would interconnect
    noise_filter_pipe_edges!(available_edgecoords, pipe_kind, seed; pipe_density)
    filter_mutually_connected_edges!(available_edgecoords)

    # Place surviving edges
    for edgecoord in available_edgecoords
        pipe_behav = roll_pipe(pipe_kind, hash_pipe_edge(edgecoord, pipe_kind), seed)
        set_pipe!(map, edgecoord, pipe_behav)
    end

    return nothing
end

"Place pipes according to the given `PipeSpawnOptions`."
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

"Place all pipes from an array of `PipeSpawnOptions`."
function place_pipeset!(map::GameMap, pipe_options::AbstractArray{PipeSpawnOptions}, seed::UInt32)
    for pipe_option in pipe_options
        place_pipeset!(map, pipe_option, seed)
    end

    return nothing
end

# ===============================================================
# Scaling Rule Type Hierarchy
# ===============================================================

"Abstract supertype for all richness-dependent scaling rules."
abstract type ScalingRule end

"Evaluate a scaling rule at a given richness value."
function evaluate_scaling end

"Constant scaling rule: always returns the same value regardless of richness."
struct NoScaling <: ScalingRule
    value::Float64
end

evaluate_scaling(ns::NoScaling, richness::Float64)::Float64 = ns.value

"Linear scaling: evaluates as `initial + slope * richness`."
struct LinearScaling <: ScalingRule
    initial::Float64
    slope::Float64
end

evaluate_scaling(ls::LinearScaling, richness::Float64)::Float64 = ls.initial + ls.slope * richness

"""
Gated linear scaling: zero below threshold, then linear from initial value.
`evaluate(richness) = richness < threshold ? 0.0 : initial + slope * (richness - threshold)`
"""
struct GatedLinearScaling <: ScalingRule
    initial::Float64
    slope::Float64
    threshold::Float64
end

function evaluate_scaling(gls::GatedLinearScaling, richness::Float64)::Float64
    richness < gls.threshold && return 0.0
    return gls.initial + gls.slope * (richness - gls.threshold)
end

"A component set paired with its richness-dependent scaling rule."
struct WeightedComponentSet
    component_set::ShipComponentSet
    weight::ScalingRule
end

# ===============================================================
# Encounter Config Data Structures
# ===============================================================

"Hull generation parameters: linear scaling for both walk steps and stacks."
struct HullSizeConfig
    steps::LinearScaling
    stacks::LinearScaling
end

"Configuration for one fluid type within an encounter class: selection weight and component pool."
struct FuelTagConfig
    weight::ScalingRule
    component_pool::Vector{WeightedComponentSet}
end

"Complete generation configuration for one encounter class."
struct EncounterClassConfig
    class_weight::ScalingRule
    hull_size::HullSizeConfig
    target_components::LinearScaling
    fuel_configs::Dict{FluidType, FuelTagConfig}
    pipe_options::Vector{PipeSpawnOptions}
end

"Configuration for the encounter point system."
@kwdef struct EncounterSystemConfig
    n_points::Int = 100
    min_base_velocity::Float64 = 10.0
    max_base_velocity::Float64 = 1000.0
    velocity_variance::Float64 = 0.1          # ±10% of base velocity
    max_angle_rad::Float64 = π / 8            # 22.5 degrees from horizontal
    viewport_half_width::Float64 = 400.0
    viewport_half_height::Float64 = 200.0
    spawn_box_offset::Float64 = 50.0          # Distance beyond the viewport to the spawn perimeter
    disappear_box_offset::Float64 = 100.0     # Distance beyond the viewport to the recycle boundary
    encounter_class_configs::Dict{EncounterClass, EncounterClassConfig} = Dict()
end

"Compute hull size (steps, stacks) from config and richness."
function compute_hull_size(config::HullSizeConfig, richness::Float64)::Tuple{Int, Int}
    steps = max(1, round(Int, evaluate_scaling(config.steps, richness)))
    stacks = max(1, round(Int, evaluate_scaling(config.stacks, richness)))
    return (steps, stacks)
end

"Compute target component count from scaling rule and richness."
function compute_target_components(scaling::ScalingRule, richness::Float64)::Int
    return max(0, round(Int, evaluate_scaling(scaling, richness)))
end

"Evaluate a component pool, returning (component_set, weight) pairs with nonzero weights."
function evaluate_component_pool(
        pool::Vector{WeightedComponentSet},
        richness::Float64
    )::Vector{Tuple{ShipComponentSet, Float64}}
    result = Tuple{ShipComponentSet, Float64}[]
    for wcs in pool
        w = evaluate_scaling(wcs.weight, richness)
        if w > 0.0
            push!(result, (wcs.component_set, w))
        end
    end
    return result
end

"Compute richness from player speed and encounter base velocity."
function calculate_richness(
        config::EncounterSystemConfig, player_speed::Float64,
        base_velocity::Float64
    )::Float64
    minimum_richness = 1.0
    richness_log_scale = 0.7
    richness_velocity_bonus_scale = 2.0

    base = player_speed > 1.0 ? log(player_speed) * richness_log_scale : 0.0
    percentile = clamp(base_velocity / config.max_base_velocity, 0.0, 1.0)
    bonus = richness_velocity_bonus_scale * percentile
    return max(base + bonus, minimum_richness)
end

"Select an encounter class from dict-based configs with deterministic ordering."
function select_encounter_class(
        configs::Dict{EncounterClass, EncounterClassConfig},
        richness::Float64, point, seed::UInt32
    )::EncounterClass
    sorted_classes = sort!(collect(keys(configs)))
    evaluated = Tuple{EncounterClass, Float64}[
        (cls, evaluate_scaling(configs[cls].class_weight, richness)) for cls in sorted_classes
    ]
    return weighted_roll_noise(evaluated, point, seed)
end

"Select a fuel tag from dict-based fuel configs with deterministic ordering."
function select_fuel_tag(
        fuel_configs::Dict{FluidType, FuelTagConfig},
        richness::Float64, point, seed::UInt32
    )::FluidType
    sorted_tags = sort!(collect(keys(fuel_configs)))
    evaluated = Tuple{FluidType, Float64}[
        (tag, evaluate_scaling(fuel_configs[tag].weight, richness)) for tag in sorted_tags
    ]
    return weighted_roll_noise(evaluated, point, seed)
end

"""
Generate a random encounter name from a seed and encounter class.
Produces names like 'Vessel KR-447', 'Wreck AX-082'.
Each class has a distinct set of prefixes.
"""
function generate_encounter_name(seed::UInt32, encounter_class::EncounterClass)::String
    ship_prefixes = ("Vessel", "Ship", "Craft")
    cache_prefixes = ("Station", "Hull", "Platform")
    scrap_prefixes = ("Wreck", "Debris", "Hulk")

    prefixes = if encounter_class == ENCOUNTER_SHIP
        ship_prefixes
    elseif encounter_class == ENCOUNTER_FUEL_CACHE
        cache_prefixes
    elseif encounter_class == ENCOUNTER_SCRAP
        scrap_prefixes
    else
        error("Unknown encounter class: $encounter_class")
    end

    letters = "ABCDEFGHJKLMNPQRSTUVWXYZ"

    prefix = pick_element_from_noise(prefixes, UInt32(1), seed)
    l1 = pick_element_from_noise(letters, UInt32(2), seed)
    l2 = pick_element_from_noise(letters, UInt32(3), seed)
    num = Int(get_noise(UInt32(4), seed) % 1000)

    return @sprintf("%s %c%c-%03d", prefix, l1, l2, num)
end

"Generate an encounter's ShipMap from config data."
function generate_encounter(
        encounter_class::EncounterClass, fuel_tag::Union{FluidType, Nothing},
        richness::Float64, seed::UInt32, class_config::EncounterClassConfig
    )::ShipMap
    steps, stacks = compute_hull_size(class_config.hull_size, richness)
    shipmap = ShipMap()
    stacked_random_tile_walk!(get_all_surface_tiles(shipmap), TileCoord(0, 0), steps, stacks, seed)

    target_count = compute_target_components(class_config.target_components, richness)
    gamemap = GameMap(shipmap)
    draw_seed = seed
    max_iterations = target_count + 10

    fuel_config = !isnothing(fuel_tag) ? get(class_config.fuel_configs, fuel_tag, nothing) : nothing
    if !isnothing(fuel_config)
        for iteration in 1:max_iterations
            current_count = count_components(gamemap)
            current_count >= target_count && break

            pool = evaluate_component_pool(fuel_config.component_pool, richness)
            isempty(pool) && break

            draw_seed = get_noise(UInt32(iteration), draw_seed)
            chosen_set = weighted_roll_noise(pool, iteration, draw_seed)

            success, _ = place_shipset!(gamemap, chosen_set, draw_seed)
            !success && break
        end
    end

    place_pipeset!(gamemap, class_config.pipe_options, seed)
    return shipmap
end

"Check whether `shipmap`'s tiles are too close to any existing surfaces in `gamemap` (within MIN_SPACING)."
function _is_ship_too_close(ship::ShipMap, expanded_other_tiles::Set{TileCoord})::Bool
    return any(t -> t in expanded_other_tiles, get_all_surface_tiles(ship))
end

"Check whether two axis-aligned bounding rectangles overlap."
function _rects_overlap(a::HexFrame.CartesianBounds, b::HexFrame.CartesianBounds)::Bool
    return a.X_NEG < b.X_POS && a.X_POS > b.X_NEG &&
        a.Y_NEG < b.Y_POS && a.Y_POS > b.Y_NEG
end

"Increase `distance` along `direction_vec` until the shifted `ship_bounds` no longer overlap `view_bounds`."
function _ensure_offscreen_distance(
        ship_bounds::HexFrame.CartesianBounds, direction_vec, initial_distance::Float64,
        view_bounds::HexFrame.CartesianBounds
    )::Float64

    distance = initial_distance
    while true
        offset = HexFrame.AxialCoord(direction_vec.q * distance, direction_vec.r * distance)
        shift_cart = HexFrame.to_cartesian(offset)
        shifted = (
            X_POS = ship_bounds.X_POS + shift_cart.x, X_NEG = ship_bounds.X_NEG + shift_cart.x,
            Y_POS = ship_bounds.Y_POS + shift_cart.y, Y_NEG = ship_bounds.Y_NEG + shift_cart.y,
        )
        _rects_overlap(shifted, view_bounds) || return distance
        distance += 10.0
        if distance > 2000.0
            @warn "Could not find safe offscreen distance, capping at 2000"
            return distance
        end
    end
end

"Compute docking animation offsets: `(far_offset, zero_offset, step_size)` for approach/departure."
function _compute_docking_offsets(direction_vec, distance::Float64; duration_secs::Float64 = 5.0, ups::Float64 = BASE_UPS)
    far_offset = HexFrame.AxialCoord(direction_vec.q * distance, direction_vec.r * distance)
    zero_offset = HexFrame.AxialCoord(0.0, 0.0)
    total_distance = sqrt(far_offset.q^2 + far_offset.r^2)
    step = total_distance / (duration_secs * ups)
    return (far_offset, zero_offset, step)
end

"""
Offset `ship` along `dir` until it clears all existing surfaces by at least `MIN_SPACING`
tiles in every direction. Uses tile-set expansion to enforce a true isotropic gap.
Mutates `ship` in place. Returns the total number of tile-steps moved.
"""
function _offset_ship_until_clear!(gamemap::GameMap, ship::ShipMap, dir::HexFrame.HexAxis)::Int
    step = HexFrame.hex_neighbour_tiles[dir]
    steps = 0
    max_steps = 500

    # Pre-expand other ships' tiles by MIN_SPACING once (they don't move during the loop)
    all_other_tiles = get_all_surfaces_combined(gamemap)
    expanded_others = expand_tileset(all_other_tiles, MIN_SPACING)

    while _is_ship_too_close(ship, expanded_others) && steps < max_steps
        offset_ship!(ship, step)
        steps += 1
    end
    if steps >= max_steps
        @warn "Hit safety limit in _offset_ship_until_clear!" dir steps
    end
    return steps
end

"""
Dock a pre-generated ship into the game map with approach animation.
The ship is offset from the primary ship along direction `dir` until clear,
then approaches from that direction.
"""
function encounter_ship!(
        gamemap::GameMap, newship::ShipMap, ship_name_base::String, seed::UInt32, dir::HexFrame.HexAxis;
        max_view_bounds::Union{HexFrame.CartesianBounds, Nothing} = nothing
    )

    newship_name = gensym(ship_name_base)

    # Offset ship until no surface overlap, starting from primary centroid
    ship_centroid = get_surface_centroid(gamemap, :primary)
    offset_newship = deepcopy(newship)
    offset_ship!(offset_newship, round_to_tile(ship_centroid))
    _offset_ship_until_clear!(gamemap, offset_newship, dir)

    # Calculate approach animation parameters
    APPROACH_DISTANCE_TILES = 20.0
    direction_vec = HexFrame.hex_vert_vecs[dir]

    # If bounds provided, ensure start point is off-screen
    if !isnothing(max_view_bounds)
        APPROACH_DISTANCE_TILES = _ensure_offscreen_distance(
            get_cartesian_bounds(offset_newship), direction_vec, APPROACH_DISTANCE_TILES, max_view_bounds
        )
    end

    start_offset, target_offset, offset_step = _compute_docking_offsets(direction_vec, APPROACH_DISTANCE_TILES)

    # Set docking status to approaching on the new ship
    set_docking_status!(offset_newship, ApproachingDockStat(start_offset, target_offset, offset_step))

    # Add to gamemap
    add_ship!(gamemap, newship_name, offset_newship)

    return nothing
end

"""
Dock a pre-generated ship into the game map, automatically choosing the approach
direction that requires the fewest tile-steps to avoid overlap with existing ships.

Tries all six hex axis directions, measures the offset distance each would require,
and picks the direction with the shortest distance. Ties are broken deterministically
using the encounter seed. Delegates to `encounter_ship!` for the actual placement.
"""
function encounter_ship_optimal_dir!(
        gamemap::GameMap, newship::ShipMap, ship_name_base::String, seed::UInt32;
        max_view_bounds::Union{HexFrame.CartesianBounds, Nothing} = nothing
    )

    ship_centroid = get_surface_centroid(gamemap, :primary)
    if isnothing(ship_centroid)
        # Fallback: pick randomly if primary has no surface
        dir = pick_element_from_noise(collect(instances(HexFrame.HexAxis)), 42, seed)
        encounter_ship!(gamemap, newship, ship_name_base, seed, dir; max_view_bounds)
        return nothing
    end
    centroid_tile = round_to_tile(ship_centroid)

    # Measure offset distance required for each direction
    best_dist = typemax(Int)
    best_dirs = HexFrame.HexAxis[]

    for dir in instances(HexFrame.HexAxis)
        trial_ship = deepcopy(newship)
        offset_ship!(trial_ship, centroid_tile)
        dist = _offset_ship_until_clear!(gamemap, trial_ship, dir)

        if dist < best_dist
            best_dist = dist
            best_dirs = HexFrame.HexAxis[dir]
        elseif dist == best_dist
            push!(best_dirs, dir)
        end
    end

    # Pick among tied directions — deterministic from seed
    chosen_dir = if length(best_dirs) == 1
        best_dirs[1]
    else
        pick_from_options(best_dirs, 42, seed)
    end

    encounter_ship!(gamemap, newship, ship_name_base, seed, chosen_dir; max_view_bounds)
    return nothing
end

"""
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


"Depart a ship by computing a direction away from other ships. Returns `(success, reason)`."
function depart_ship!(gamemap::GameMap, ship_name::Symbol; max_view_bounds::Union{HexFrame.CartesianBounds, Nothing} = nothing)::Tuple{Bool, String}
    if ship_name === :primary
        return false, "Can't depart: primary ship cannot be departed."
    end

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

    # Block departure if pipes still bridge to another ship
    can_depart, reason = check_departure_pipe_connections(gamemap, ship_name)
    if !can_depart
        return false, reason
    end

    # Compute departure direction from ship centroids
    depart_axis = compute_departure_axis(gamemap, ship_name)
    DEPART_DISTANCE_TILES = 20.0
    direction_vec = HexFrame.hex_vert_vecs[depart_axis]

    # If bounds provided, ensure target point is off-screen
    if !isnothing(max_view_bounds)
        DEPART_DISTANCE_TILES = _ensure_offscreen_distance(
            get_cartesian_bounds(gamemap.ships[ship_name]), direction_vec, DEPART_DISTANCE_TILES, max_view_bounds
        )
    end

    far_offset, zero_offset, offset_step = _compute_docking_offsets(direction_vec, DEPART_DISTANCE_TILES)

    set_docking_status!(gamemap, ship_name, DepartingDockStat(zero_offset, far_offset, offset_step))
    return true, "Ship $(ship_name) departing (axis=$(depart_axis))"
end



# ===============================================================
# Encounter Point System — SpaceMapState
# ===============================================================

"Full space map state with seed, velocity, position, and encounter points."
@kwdef mutable struct SpaceMapState <: AbstractSpaceMap
    seed::UInt32 = UInt32(0)
    velocity::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    position::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    time_years::Float64 = 0.0
    target_time_years::Float64 = 0.0
    last_stop_time::Float64 = 0.0
    is_time_progressing::Bool = false
    active_manoeuvre::Union{Nothing, ManoeuvreData} = nothing
    # Encounter system
    encounter_points::Vector{EncounterPoint} = EncounterPoint[]
    viewport_half_width::Float64 = 1000.0
    viewport_half_height::Float64 = 500.0
    encounter_config::EncounterSystemConfig
end
@struct_hash_equal SpaceMapState

#= ---------- SpaceMapState accessor implementations (extending FlowMap) ----------- =#
get_velocity(sm::SpaceMapState)::SVector{2, Float64} = sm.velocity
set_velocity!(sm::SpaceMapState, v::SVector{2, Float64}) = (sm.velocity = v)
get_space_map_seed(sm::SpaceMapState)::UInt32 = sm.seed
get_time_years(sm::SpaceMapState)::Float64 = sm.time_years
set_time_years!(sm::SpaceMapState, t::Float64) = (sm.time_years = t)
get_active_manoeuvre(sm::SpaceMapState)::Union{Nothing, ManoeuvreData} = sm.active_manoeuvre
has_active_manoeuvre(sm::SpaceMapState)::Bool = !isnothing(sm.active_manoeuvre)
set_active_manoeuvre!(sm::SpaceMapState, m::ManoeuvreData) = (sm.active_manoeuvre = m)
clear_active_manoeuvre!(sm::SpaceMapState) = (sm.active_manoeuvre = nothing)
get_position(sm::SpaceMapState)::SVector{2, Float64} = sm.position
set_position!(sm::SpaceMapState, p::SVector{2, Float64}) = (sm.position = p)
get_target_time(sm::SpaceMapState)::Float64 = sm.target_time_years

"Set the target time. If the new target is at or before the current time, records a stop for easing."
function set_target_time!(sm::SpaceMapState, t::Float64)
    sm.target_time_years = t
    if t <= sm.time_years
        sm.last_stop_time = sm.time_years
    end
end

is_time_progressing(sm::SpaceMapState)::Bool = sm.is_time_progressing
get_last_stop_time(sm::SpaceMapState)::Float64 = sm.last_stop_time
set_last_stop_time!(sm::SpaceMapState, t::Float64) = (sm.last_stop_time = t)
get_encounter_points(sm::SpaceMapState) = sm.encounter_points

"Get the encounter system config from a space map."
get_encounter_config(sm::SpaceMapState)::EncounterSystemConfig = sm.encounter_config
get_encounter_config(::SpaceMapEmpty)::Nothing = nothing

"Overwrite the game map's space map with a new `SpaceMapState`."
function initialise_spacemap!(
        gamemap::GameMap, seed::UInt32, config::EncounterSystemConfig,
        velocity::SVector{2, Float64} = SVector{2, Float64}(10.0, 0.0)
    )
    gamemap.space_map = SpaceMapState(
        seed = seed, velocity = velocity, time_years = 0.0,
        encounter_config = config
    )
    return nothing
end

"Generate base velocities with a logarithmic distribution (equal density per octave)."
function generate_base_velocities(
        n_points::Int, min_velocity::Float64,
        max_velocity::Float64, seed::UInt32
    )::Vector{Float64}
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

"Spawn (or respawn) an encounter point on the perimeter of the spawn box with a new random trajectory."
function spawn_encounter_point!(ep::EncounterPoint, sm::SpaceMapState, current_time::Float64;
        velocity_override::Union{Nothing, SVector{2, Float64}} = nothing
    )
    config = get_encounter_config(sm)
    ep.iteration += 1
    ep.spawn_time = current_time

    # Derive unique seeds from the map seed, index, and iteration
    point_seed = get_noise(UInt32(ep.index), get_noise(UInt32(ep.iteration), sm.seed))
    ep.ship_type_seed = get_noise(UInt32(ep.index + 1000), get_noise(UInt32(ep.iteration), sm.seed))

    # Spawn on one of the four box edges so encounters can arrive from any direction.
    player_pos = get_position(sm)
    spawn_x = sm.viewport_half_width + config.spawn_box_offset
    spawn_y = sm.viewport_half_height + config.spawn_box_offset
    edge = pick_element_from_noise((0, 1, 2, 3), ep.index * 6000 + ep.iteration, point_seed)

    if edge == 0
        y_pos = pick_from_range(player_pos[2] - spawn_y, player_pos[2] + spawn_y, ep.index * 1000 + ep.iteration, point_seed)
        ep.position = SVector(player_pos[1] - spawn_x, y_pos)
    elseif edge == 1
        y_pos = pick_from_range(player_pos[2] - spawn_y, player_pos[2] + spawn_y, ep.index * 1000 + ep.iteration, point_seed)
        ep.position = SVector(player_pos[1] + spawn_x, y_pos)
    elseif edge == 2
        x_pos = pick_from_range(player_pos[1] - spawn_x, player_pos[1] + spawn_x, ep.index * 1000 + ep.iteration, point_seed)
        ep.position = SVector(x_pos, player_pos[2] + spawn_y)
    else
        x_pos = pick_from_range(player_pos[1] - spawn_x, player_pos[1] + spawn_x, ep.index * 1000 + ep.iteration, point_seed)
        ep.position = SVector(x_pos, player_pos[2] - spawn_y)
    end

    # Random speed: base_velocity ± variance
    speed_noise = get_noise_zero_to_one(ep.index * 2000 + ep.iteration, point_seed)
    speed = ep.base_velocity * (1.0 - config.velocity_variance + 2.0 * config.velocity_variance * speed_noise)

    # Random angle within ±max_angle of horizontal
    angle_noise = get_noise_zero_to_one(ep.index * 3000 + ep.iteration, point_seed)
    angle = config.max_angle_rad * (2.0 * angle_noise - 1.0)

    # Velocity is relative to the player's velocity
    relative_vel = SVector(speed * cos(angle), speed * sin(angle))
    ep.velocity = velocity_override === nothing ? sm.velocity + relative_vel : velocity_override

    player_speed = norm(sm.velocity)
    ep.richness = calculate_richness(config, player_speed, ep.base_velocity)

    class_seed = get_noise(UInt32(100), ep.ship_type_seed)
    ep.encounter_class = select_encounter_class(config.encounter_class_configs, ep.richness, ep.index, class_seed)

    class_config = config.encounter_class_configs[ep.encounter_class]
    fuel_seed = get_noise(UInt32(200), ep.ship_type_seed)
    ep.fuel_tag = isempty(class_config.fuel_configs) ? nothing : select_fuel_tag(class_config.fuel_configs, ep.richness, ep.index, fuel_seed)

    ep.display_name = generate_encounter_name(ep.ship_type_seed, ep.encounter_class)

    return nothing
end

"Check all encounter points against the disappear box and recycle any that have left it."
function check_encounter_bounds!(sm::SpaceMapState)
    config = get_encounter_config(sm)
    disappear_x = sm.viewport_half_width + config.disappear_box_offset
    disappear_y = sm.viewport_half_height + config.disappear_box_offset
    current_time = sm.time_years

    for ep in sm.encounter_points
        pos = get_encounter_position(ep, current_time)
        rel = pos - sm.position

        if abs(rel[1]) > disappear_x || abs(rel[2]) > disappear_y
            if sm.active_manoeuvre !== nothing && sm.active_manoeuvre.target_encounter_index == ep.index
                sm.active_manoeuvre = nothing
            end
            spawn_encounter_point!(ep, sm, current_time)
        end
    end

    return nothing
end

"Initialise the encounter point system on a `SpaceMapState`."
function initialise_encounter_system!(sm::SpaceMapState)
    config = get_encounter_config(sm)
    current_time = sm.time_years

    sm.viewport_half_width = config.viewport_half_width
    sm.viewport_half_height = config.viewport_half_height
    player_pos = sm.position
    disappear_x = sm.viewport_half_width + config.disappear_box_offset
    disappear_y = sm.viewport_half_height + config.disappear_box_offset

    base_velocities = generate_base_velocities(
        config.n_points, config.min_base_velocity,
        config.max_base_velocity, sm.seed
    )

    sm.encounter_points = Vector{EncounterPoint}(undef, config.n_points)

    for i in 1:config.n_points
        ep = EncounterPoint(index = i, base_velocity = base_velocities[i])
        spawn_encounter_point!(ep, sm, current_time)

        point_seed = get_noise(UInt32(ep.index), get_noise(UInt32(ep.iteration), sm.seed))
        x_pos = pick_from_range(
            player_pos[1] - disappear_x, player_pos[1] + disappear_x,
            ep.index * 4000 + ep.iteration, point_seed
        )
        y_pos = pick_from_range(player_pos[2] - disappear_y, player_pos[2] + disappear_y, ep.index * 5000 + ep.iteration, point_seed)
        ep.position = SVector(x_pos, y_pos)

        sm.encounter_points[i] = ep
    end

    return nothing
end

"Advance the space map time by one tick. No-op for `SpaceMapEmpty`."
function step_space_map_time!(::SpaceMapEmpty, target_time::Float64; max_step::Float64 = 2.5 / BASE_UPS, ease_distance::Float64 = 1.0)
    return false
end

"""
Advance the space map time by one tick. Returns `true` if time was advanced.

Time stepping uses linear ease-in/ease-out: within `ease_distance` years of the warp start
(`last_stop_time`) or the warp end (`target_time_years`), the step size is scaled down linearly.
A minimum step of `0.2/BASE_UPS` years/tick ensures the warp always makes progress.
"""
function step_space_map_time!(sm::SpaceMapState, target_time::Float64; max_step::Float64 = 2.5 / BASE_UPS, ease_distance::Float64 = 1.0)::Bool
    # Sync target from IPC shared state (only calls set_target_time! when the value has actually changed,
    # preserving the last_stop_time update logic on cancel)
    if target_time != sm.target_time_years
        set_target_time!(sm, target_time)
    end

    sm.is_time_progressing = sm.time_years < sm.target_time_years
    if !sm.is_time_progressing
        return false
    end

    min_step = 0.2 / BASE_UPS

    # Ease‑in/ease‑out: use the smaller of start/end distances for a single smooth ramp
    dist_from_start = sm.time_years - sm.last_stop_time
    dist_to_end = sm.target_time_years - sm.time_years
    ease_dist = min(dist_from_start, dist_to_end)

    if ease_dist < ease_distance
        fraction = ease_dist / ease_distance
        step = max(min_step, max_step * fraction)
    else
        step = max_step
    end

    old_time = sm.time_years
    new_time = min(old_time + step, sm.target_time_years)
    dt = new_time - old_time

    # Update player position (velocity is constant between manoeuvres)
    sm.position = sm.position + sm.velocity * dt

    # Commit the new time
    sm.time_years = new_time

    check_encounter_bounds!(sm)

    # Record stop for future ease-in when warp completes
    if sm.time_years >= sm.target_time_years
        sm.last_stop_time = sm.time_years
    end

    return true
end

# ===============================================================
# Manoeuvre Planning
# ===============================================================

"""
Returns the velocity-match ΔV plus a minimum surplus fraction for closing the gap.
"""
function calculate_minimum_intercept_dv(
        player_vel::SVector{2, Float64},
        target_vel::SVector{2, Float64};
        min_surplus_fraction::Float64 = 0.05
    )::Float64
    return norm(target_vel - player_vel) * (1.0 + min_surplus_fraction)
end

"""
Compute the total ΔV for a direct intercept with coast duration `coast_time`.

This models an immediate approach burn that puts the player on a collision course,
followed by a capture burn at intercept to match velocities.
"""
function compute_direct_intercept_dv(
        separation::SVector{2, Float64},
        relative_vel::SVector{2, Float64},
        coast_time::Float64
    )::Float64
    coast_time <= 1.0e-12 && return Inf

    capture_dv = norm(separation) / coast_time
    approach_dv = norm(separation / coast_time + relative_vel)
    return approach_dv + capture_dv
end

"""
Find the minimum direct-intercept coast time that fits within `total_dv`.

The direct-intercept cost is continuous and non-increasing in `coast_time`, so bisection on
the feasible interval is robust. Returns `nothing` when the supplied upper bound is
already infeasible, in which case the caller should fall back to the existing plan.
"""
function find_direct_intercept_time(
        separation::SVector{2, Float64},
        relative_vel::SVector{2, Float64},
        total_dv::Float64,
        coast_time_upper::Float64;
        max_iterations::Int = 60,
        tolerance::Float64 = 1.0e-9
    )::Union{Nothing, Float64}
    coast_time_upper <= 1.0e-6 && return nothing

    feasibility_tolerance = sqrt(eps(Float64)) * max(total_dv, 1.0)
    dv_upper = compute_direct_intercept_dv(separation, relative_vel, coast_time_upper)
    dv_upper > total_dv + feasibility_tolerance && return nothing

    coast_time_lo = 1.0e-6
    coast_time_hi = coast_time_upper

    for _ in 1:max_iterations
        coast_time_mid = (coast_time_lo + coast_time_hi) / 2.0
        dv_mid = compute_direct_intercept_dv(separation, relative_vel, coast_time_mid)

        if dv_mid > total_dv
            coast_time_lo = coast_time_mid
        else
            coast_time_hi = coast_time_mid
        end

        (coast_time_hi - coast_time_lo) < tolerance && break
    end

    return coast_time_hi
end

"""
Plan an intercept manoeuvre at the given total ΔV budget.

The approach burn sets the ship on a trajectory to reach the target's future position after `coast_time` years:
    approach_burn_dv = relative_vel + separation / coast_time

 The capture burn then removes the closing component so the ship arrives velocity-matched with the encounter point:
    capture_burn_dv = -separation / coast_time

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

    target_pos = get_encounter_position(ep, current_time)
    separation = target_pos - player_pos
    relative_vel = ep.velocity - player_vel
    separation_magnitude = norm(separation)

    if separation_magnitude < 1.0e-9
        approach_burn_dv = relative_vel
        ship_space_approach_dv = SVector(norm(approach_burn_dv), 0.0)
        return ManoeuvreData(
            phase = PHASE_APPROACH_BURN,
            burn_target_dv = ship_space_approach_dv,
            burn_remaining_dv = ship_space_approach_dv,
            approach_burn_dv = approach_burn_dv,
            capture_burn_dv = SVector(0.0, 0.0),
            approach_burn_time = current_time,
            intercept_time = current_time,
            target_encounter_index = ep.index,
            capture_burn_position = target_pos,
        )
    end

    velocity_match_dv = norm(relative_vel)
    closing_dv_budget = total_dv - velocity_match_dv
    closing_dv_budget <= 1.0e-9 && return nothing

    #= By the triangle inequality `coast_time_upper = 2 * norm(separation) / closing_dv_budget` 
       is guaranteed to be feasible whenever the manoeuvre has any closing ΔV available. =#
    coast_time_upper = 2.0 * separation_magnitude / closing_dv_budget
    intercept_coast_time = find_direct_intercept_time(separation, relative_vel, total_dv, coast_time_upper)
    isnothing(intercept_coast_time) && return nothing

    #= The immediate approach burn adds the exact closing velocity needed to meet the
       target at `intercept_coast_time`, while the capture burn removes that closing component
       at intercept so the post-burn relative velocity is zero. =#
    closing_velocity = separation / intercept_coast_time
    approach_burn_dv = relative_vel + closing_velocity
    capture_burn_dv = -closing_velocity

    ship_space_approach_dv = SVector(norm(approach_burn_dv), 0.0)
    intercept_time = current_time + intercept_coast_time
    capture_burn_position = get_encounter_position(ep, intercept_time)

    return ManoeuvreData(
        phase = PHASE_APPROACH_BURN,
        burn_target_dv = ship_space_approach_dv,
        burn_remaining_dv = ship_space_approach_dv,
        approach_burn_dv = approach_burn_dv,
        capture_burn_dv = capture_burn_dv,
        approach_burn_time = current_time,
        intercept_time = intercept_time,
        target_encounter_index = ep.index,
        capture_burn_position = capture_burn_position,
    )
end

"Get the seed for procedural ship generation for this encounter point."
function get_encounter_ship_seed(ep::EncounterPoint, map_seed::UInt32)::UInt32
    return get_noise(UInt32(ep.index), get_noise(UInt32(ep.iteration), map_seed))
end

# ===============================================================
# Delta V Estimation
# ===============================================================

"""
Estimate the minimum remaining delta V for a ship using the Tsiolkovsky rocket equation.

Computes a lower bound by staging fuels in decreasing exhaust velocity order (burning
more efficient fuel first, when the ship is heaviest). Two fuel paths are modelled:
- Cold gas: direct use (`COLD_GAS` tanks, `COLD_GAS` exhaust velocity)
- Monopropellant: liquid decomposed to gas (`MONOPROP_LIQUID` tanks, `MONOPROP_GAS` exhaust velocity)

Returns 0.0 if the ship has no fuel or no dry mass.
"""
function estimate_min_delta_v(gamemap::GameMap)::Float64
    dry_mass = get_dry_mass(gamemap)
    dry_mass <= 0.0 && return 0.0

    # Define fuel paths: (wet mass of fuel, effective exhaust velocity)
    cold_gas_mass = get_wet_mass(gamemap; fluid = HexFluids.COLD_GAS)
    cold_gas_ve = something(lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS), 0.0)

    monoprop_mass = get_wet_mass(gamemap; fluid = HexFluids.MONOPROP_LIQUID)
    monoprop_ve = something(lookup_fluid_exhaust_velocity(HexFluids.MONOPROP_GAS), 0.0)

    # Collect non-empty fuel stages and sort by DECREASING exhaust velocity (minimum delta V order)
    fuels = Tuple{Float64, Float64}[]
    cold_gas_mass > 0.0 && cold_gas_ve > 0.0 && push!(fuels, (cold_gas_mass, cold_gas_ve))
    monoprop_mass > 0.0 && monoprop_ve > 0.0 && push!(fuels, (monoprop_mass, monoprop_ve))
    sort!(fuels; by = last, rev = true)

    # Sequential Tsiolkovsky rocket equation: for each fuel stage, the remaining
    # unburnt fuels act as additional dry mass
    remaining_mass = dry_mass + sum(first, fuels; init = 0.0)
    total_dv = 0.0

    for (fuel_mass, ve) in fuels
        m_final = remaining_mass - fuel_mass
        m_final <= 0.0 && continue

        total_dv += ve * log(remaining_mass / m_final)
        remaining_mass = m_final
    end

    return total_dv
end


end # module HexFlowProcGen
