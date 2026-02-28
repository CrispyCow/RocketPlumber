module HexFlowProcGen

using Random, LinearAlgebra, GeometryBasics, StaticArrays, Printf
using HexFrame, FlowMap, SquirrelNoise, HexComponentsAPI, FlowEngine, HexFluids
using DataStructures: BinaryMinHeap
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
export encounter_ship!, depart_ship!
export check_departure_pipe_connections
export EncounterSystemConfig, initialise_encounter_system!
export spawn_encounter_point!, get_encounter_position, predict_crossing_time
export rebuild_event_queue!, check_line_shift!, process_encounter_events!
export step_space_map_time!
export calculate_minimum_intercept_dv, plan_intercept_manoeuvre
export compute_closest_approach
export get_encounter_ship_seed
export generate_base_velocities
export HullSizeConfig, FuelTagConfig, EncounterClassConfig
export compute_hull_size, compute_target_components, evaluate_component_pool, calculate_richness
export SpaceMapState, get_encounter_config


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

"Probabilistically place a pipe at `edge` based on noise and `pipe_density`."
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

"Probabilistically place pipes at multiple edges based on noise and `pipe_density`."
function noise_pipe_place_helper!(map::GameMap, edges, pipe_kind::Symbol, seed::UInt32; pipe_density)
    for edgecoord in edges
        noise_pipe_place_helper!(map, edgecoord, pipe_kind, seed; pipe_density = pipe_density)
    end

    return nothing
end

"Place pipes on candidate edges connecting to exactly one existing node, filtered by `pipe_density`."
function place_connected_pipes!(map::GameMap, pipe_kind::Symbol, seed::UInt32; pipe_density)
    ship_tiles = deepcopy(get_all_surface_tiles(map))
    available_edgecoords = get_all_edgecoords_of_tiles(ship_tiles)
    all_nodes = Set(keys(list_nodes(list_elements(map))))

    # Keep only edges that would connect to exactly one existing node
    for edgecoord in available_edgecoords
        v1_is_connected = to_nodecoord(edgecoord.v1) in all_nodes
        v2_is_connected = to_nodecoord(edgecoord.v2) in all_nodes
        if v1_is_connected == v2_is_connected  # both or neither connected — remove
            delete!(available_edgecoords, edgecoord)
        end
    end

    # Place pipes based on density
    noise_pipe_place_helper!(map, available_edgecoords, pipe_kind, seed; pipe_density = pipe_density)

    return nothing
end

"Place pipes on candidate edges that do not bridge two existing nodes, filtered by `pipe_density`."
function place_random_pipes!(map::GameMap, pipe_kind::Symbol, seed::UInt32; pipe_density)
    ship_tiles = deepcopy(get_all_surface_tiles(map))
    available_edgecoords = get_all_edgecoords_of_tiles(ship_tiles)
    all_nodes = Set(keys(list_nodes(list_elements(map))))

    # Remove any edges that would bridge two existing nodes
    for edgecoord in available_edgecoords
        v1_is_connected = to_nodecoord(edgecoord.v1) in all_nodes
        v2_is_connected = to_nodecoord(edgecoord.v2) in all_nodes

        if v1_is_connected && v2_is_connected
            delete!(available_edgecoords, edgecoord)
        end
    end

    # Place pipes based on density
    noise_pipe_place_helper!(map, available_edgecoords, pipe_kind, seed; pipe_density = pipe_density)

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
    fuel_configs::Dict{FluidTags, FuelTagConfig}
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
    spawn_margin::Float64 = 100.0             # Distance from viewport edge to spawn lines
    recycle_margin::Float64 = 50.0            # Extra distance from spawn lines to disappear lines
    line_step_size::Float64 = 50.0            # Discrete step for shifting lines
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
        fuel_configs::Dict{FluidTags, FuelTagConfig},
        richness::Float64, point, seed::UInt32
    )::FluidTags
    sorted_tags = sort!(collect(keys(fuel_configs)))
    evaluated = Tuple{FluidTags, Float64}[
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
        encounter_class::EncounterClass, fuel_tag::FluidTags,
        richness::Float64, seed::UInt32, class_config::EncounterClassConfig
    )::ShipMap
    steps, stacks = compute_hull_size(class_config.hull_size, richness)
    shipmap = ShipMap()
    stacked_random_tile_walk!(get_all_surface_tiles(shipmap), TileCoord(0, 0), steps, stacks, seed)

    target_count = compute_target_components(class_config.target_components, richness)
    gamemap = GameMap(shipmap)
    draw_seed = seed
    max_iterations = target_count + 10

    fuel_config = class_config.fuel_configs[fuel_tag]
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

    place_pipeset!(gamemap, class_config.pipe_options, seed)
    return shipmap
end

"Check whether `shipmap`'s surface tiles overlap any existing surfaces in `gamemap`."
function _is_surface_overlap(gamemap::GameMap, shipmap::ShipMap)::Bool
    all_tiles = get_all_surfaces_combined(gamemap)
    return any(t -> t in all_tiles, get_all_surface_tiles(shipmap))
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
function _compute_docking_offsets(direction_vec, distance::Float64; duration_secs::Float64 = 5.0, ups::Float64 = 60.0)
    far_offset = HexFrame.AxialCoord(direction_vec.q * distance, direction_vec.r * distance)
    zero_offset = HexFrame.AxialCoord(0.0, 0.0)
    total_distance = sqrt(far_offset.q^2 + far_offset.r^2)
    step = total_distance / (duration_secs * ups)
    return (far_offset, zero_offset, step)
end

"""
Dock a pre-generated ship into the game map with approach animation.
The ship is offset from the primary ship and approaches from direction `dir`.
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
    while _is_surface_overlap(gamemap, offset_newship)
        offset = HexFrame.hex_neighbour_tiles[dir]
        offset_ship!(offset_newship, offset)
    end

    # Add final gap
    MIN_SPACING = 3
    hnt = HexFrame.hex_neighbour_tiles[dir]
    final_offset = TileCoord(hnt.q * MIN_SPACING, hnt.r * MIN_SPACING)
    offset_ship!(offset_newship, final_offset)

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
    set_docking_status!(offset_newship, ApproachingDockStat(start_offset, target_offset, offset_step, dir))

    # Add to gamemap
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


"Attempt to depart a ship using its saved approach axis. Returns `(success, reason)`."
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

    # block departure if pipes still bridge to another ship
    can_depart, reason = check_departure_pipe_connections(gamemap, ship_name)
    if !can_depart
        return false, reason
    end

    # Depart by backtracking along the original approach axis
    depart_axis = approach_axis
    DEPART_DISTANCE_TILES = 20.0
    direction_vec = HexFrame.hex_vert_vecs[depart_axis]

    # If bounds provided, ensure target point is off-screen
    if !isnothing(max_view_bounds)
        DEPART_DISTANCE_TILES = _ensure_offscreen_distance(
            get_cartesian_bounds(gamemap.ships[ship_name]), direction_vec, DEPART_DISTANCE_TILES, max_view_bounds
        )
    end

    far_offset, zero_offset, offset_step = _compute_docking_offsets(direction_vec, DEPART_DISTANCE_TILES)

    set_docking_status!(gamemap, ship_name, DepartingDockStat(zero_offset, far_offset, offset_step, approach_axis))
    reason = "Ship $(ship_name) departing (axis=$(depart_axis))"
    return true, reason
end

# ===============================================================
# Encounter Point System — SpaceMapState
# ===============================================================

"Full space map state with seed, velocity, position, encounter points, and event queue."
@kwdef mutable struct SpaceMapState <: AbstractSpaceMap
    seed::UInt32 = UInt32(0)
    velocity::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    position::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    time_years::Float64 = 0.0
    target_time_years::Float64 = 0.0
    active_manoeuvre::Union{Nothing, ManoeuvreData} = nothing
    # Encounter system
    encounter_points::Vector{EncounterPoint} = EncounterPoint[]
    event_queue::BinaryMinHeap{EncounterEvent} = BinaryMinHeap{EncounterEvent}()
    neg_disappear_line_x::Float64 = -1600.0
    neg_spawn_line_x::Float64 = -1500.0
    pos_spawn_line_x::Float64 = 1500.0
    pos_disappear_line_x::Float64 = 1600.0
    last_line_step_x::Float64 = 0.0
    line_step_size::Float64 = 200.0
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
set_target_time!(sm::SpaceMapState, t::Float64) = (sm.target_time_years = t)
is_time_progressing(sm::SpaceMapState)::Bool = sm.time_years < sm.target_time_years
get_encounter_points(sm::SpaceMapState) = sm.encounter_points

"Get the encounter system config from a space map."
get_encounter_config(sm::SpaceMapState)::EncounterSystemConfig = sm.encounter_config
get_encounter_config(::SpaceMapEmpty)::Nothing = nothing

"Overwrite the game map's space map with a new `SpaceMapState`."
function initialise_spacemap!(
        gamemap::GameMap, seed::UInt32, config::EncounterSystemConfig,
        velocity::SVector{2, Float64} = SVector{2, Float64}(1.0, 0.0)
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

"Predict when an encounter point will cross a vertical line at `x_line`. Returns `nothing` if it never will."
function predict_crossing_time(ep::EncounterPoint, x_line::Float64)::Union{Nothing, Float64}
    vx = ep.velocity[1]
    if abs(vx) < 1.0e-12
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
function spawn_encounter_point!(
        ep::EncounterPoint, sm::SpaceMapState,
        current_time::Float64, spawn_line_x::Float64 = sm.neg_spawn_line_x;
        velocity_override::Union{Nothing, SVector{2, Float64}} = nothing
    )
    config = get_encounter_config(sm)
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
    ep.fuel_tag = select_fuel_tag(class_config.fuel_configs, ep.richness, ep.index, fuel_seed)

    ep.display_name = generate_encounter_name(ep.ship_type_seed, ep.encounter_class)

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
function rebuild_event_queue!(sm::SpaceMapState)
    sm.event_queue = BinaryMinHeap{EncounterEvent}()
    current_time = sm.time_years
    for ep in sm.encounter_points
        current_x = get_encounter_position(ep, current_time)[1]

        if current_x > sm.pos_disappear_line_x
            # Point has drifted past the positive disappear line — recycle to left spawn
            spawn_encounter_point!(ep, sm, current_time, sm.neg_spawn_line_x)
        elseif current_x < sm.neg_disappear_line_x
            # Player has outrun this point — backfill by spawning at the right spawn line
            spawn_encounter_point!(ep, sm, current_time, sm.pos_spawn_line_x)
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
function check_line_shift!(sm::SpaceMapState)
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
        rebuild_event_queue!(sm)
    end

    return nothing
end

"Process encounter point recycling events up to the given time."
function process_encounter_events!(sm::SpaceMapState, up_to_time::Float64)
    while !isempty(sm.event_queue)
        next_event = first(sm.event_queue)
        if next_event.time > up_to_time
            break
        end
        pop!(sm.event_queue)

        ep = sm.encounter_points[next_event.index]
        # Normal recycle: point has crossed pos_disappear_line_x, respawn at neg_spawn_line_x
        spawn_encounter_point!(ep, sm, up_to_time, sm.neg_spawn_line_x)

        crossing_time = predict_crossing_time(ep, sm.pos_disappear_line_x)
        if !isnothing(crossing_time) && crossing_time > up_to_time
            push!(sm.event_queue, EncounterEvent(crossing_time, ep.index))
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
    sm.line_step_size = config.line_step_size

    player_x = sm.position[1]
    sm.neg_spawn_line_x = player_x - config.viewport_half_width - config.spawn_margin
    sm.neg_disappear_line_x = player_x - config.viewport_half_width - config.spawn_margin - config.recycle_margin
    sm.pos_spawn_line_x = player_x + config.viewport_half_width + config.spawn_margin
    sm.pos_disappear_line_x = player_x + config.viewport_half_width + config.spawn_margin + config.recycle_margin
    sm.last_line_step_x = player_x

    base_velocities = generate_base_velocities(
        config.n_points, config.min_base_velocity,
        config.max_base_velocity, sm.seed
    )

    sm.encounter_points = Vector{EncounterPoint}(undef, config.n_points)
    sm.event_queue = BinaryMinHeap{EncounterEvent}()

    for i in 1:config.n_points
        ep = EncounterPoint(index = i, base_velocity = base_velocities[i])
        spawn_encounter_point!(ep, sm, current_time, sm.neg_spawn_line_x)

        point_seed = get_noise(UInt32(ep.index), get_noise(UInt32(ep.iteration), sm.seed))
        x_pos = pick_from_range(
            sm.neg_disappear_line_x, sm.pos_disappear_line_x,
            ep.index * 4000 + ep.iteration, point_seed
        )
        y_range = sm.viewport_half_height + config.spawn_margin
        y_pos = pick_from_range(-y_range, y_range, ep.index * 5000 + ep.iteration, point_seed)
        ep.position = SVector(x_pos, y_pos)

        sm.encounter_points[i] = ep

        crossing_time = predict_crossing_time(ep, sm.pos_disappear_line_x)
        if !isnothing(crossing_time) && crossing_time > current_time
            push!(sm.event_queue, EncounterEvent(crossing_time, ep.index))
        end
    end

    return nothing
end

"Advance the space map time by one tick. No-op for `SpaceMapEmpty`."
function step_space_map_time!(::SpaceMapEmpty; max_step::Float64 = 1.0 / 60.0)
    return false
end

"Advance the space map time by one tick. Returns true if time was advanced."
function step_space_map_time!(sm::SpaceMapState; max_step::Float64 = 1.0 / 60.0)::Bool
    if sm.time_years >= sm.target_time_years
        return false
    end

    old_time = sm.time_years
    new_time = min(old_time + max_step, sm.target_time_years)
    dt = new_time - old_time

    # Update player position (velocity is constant between manoeuvres)
    sm.position = sm.position + sm.velocity * dt

    # Process encounter recycling events up to the new time
    process_encounter_events!(sm, new_time)

    # Commit the new time
    sm.time_years = new_time

    # Check if lines need to shift
    check_line_shift!(sm)

    return true
end

# ===============================================================
# Manoeuvre Planning
# ===============================================================

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
    if A < 1.0e-12
        return (
            time = current_time, distance = norm(a),
            player_position = player_pos, target_position = target_pos,
        )
    end

    t_min = -B / (2.0 * A)

    # Closest approach in the past or right now — act immediately
    if t_min <= 0.0
        return (
            time = current_time, distance = norm(a),
            player_position = player_pos, target_position = target_pos,
        )
    end

    closest_time = current_time + t_min
    closest_distance = norm(a + b * t_min)
    player_at_ca = player_pos + player_vel * t_min
    target_at_ca = get_encounter_position(ep, closest_time)
    return (
        time = closest_time, distance = closest_distance,
        player_position = player_at_ca, target_position = target_at_ca,
    )
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
    sep_unit = sep_dist > 1.0e-6 ? separation / sep_dist : SVector(1.0, 0.0)
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
    coast_time = if burn_distance > 1.0e-6 && close_velocity > 1.0e-6
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
    dir_unit = if dir_norm > 1.0e-6
        direction / dir_norm
    elseif velocity_match > 1.0e-6
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
        phase = PHASE_WAIT_APPROACH,
        main_burn_dv = main_burn_dv,
        decel_burn_dv = decel_burn_dv,
        closest_approach_time = burn_time,
        intercept_time = intercept_time,
        target_encounter_index = ep.index,
        trajectory_start_pos = player_pos,
        trajectory_start_time = current_time,
        surplus_dv = surplus,
        main_burn_position = burn_player_pos,
        decel_burn_position = target_pos_at_intercept,
    )
end

"Get the seed for procedural ship generation for this encounter point."
function get_encounter_ship_seed(ep::EncounterPoint, map_seed::UInt32)::UInt32
    return get_noise(UInt32(ep.index), get_noise(UInt32(ep.iteration), map_seed))
end


end # module HexFlowProcGen
