module FlowEngine

using HexFrame, HexElements, HexFluids, HexComponentsAPI
import HexComponentsAPI: placement_valid

using SparseArrays, LinearAlgebra, SmallCollections, StructEquality

# Type Exports
export ShipMap, GameMap, DerivedMapState, MNA_State
# Function Exports
export add_ship!, remove_ship!, get_all_ship_names, has_ship, get_ship, offset_ship!
export add_pipes_abs_element!, abs_element_get_current, update_components!
export list_elements, list_nodes, prune, ground_search, clear_dangling_dependants
export fluidtag_nodes, get_node_fluid_tags, build_node_connection_map!, connect_fluidtags!
export MNA_indexnodes, MNA_splitelements!, MNA_getA, MNA_getZ, MNA_solve
# GameMap Abstraction Functions
export get_component, has_component, set_component!, delete_component!, delete_all_components!
export get_pipe, has_pipe, set_pipe!, delete_pipe!
export get_all_components, get_all_pipes
export count_components, count_pipes, count_surface_tiles
export delete_all_components!, delete_all_pipes!, delete_all_surface_tiles!
export is_on_surface_tile, set_surface_tile!, delete_surface_tile!, get_all_surface_tiles
export has_component_any_ship, get_component_any_ship, has_pipe_any_ship, get_pipe_any_ship, is_on_surface_tile_any_ship
# Convenience helpers that search all ships (useful for UI and queries where ship is not known)
export can_place_component_at, can_place_pipe_at, can_remove_surface_at, is_node_on_ship_surface
export get_all_ship_edge_coords, get_all_surface_tiles, get_all_surfaces_combined, count_edge_tiles, find_ship_surface_edgetiles!
export find_ship_for_surface, find_ships_adjacent_to_coord, would_bridge_ships, find_valid_ship_for_placement, find_ship_with_component, find_ship_with_pipe

const CONST_RESISTOR = HexElements.CONST_RESISTOR
const CONST_CURRENT = HexElements.CONST_CURRENT
const CONST_VOLTAGE = HexElements.CONST_VOLTAGE
const C_DEP_CURRENT = HexElements.C_DEP_CURRENT
const V_DEP_VOLTAGE = HexElements.V_DEP_VOLTAGE

# ===============================================================
# Game State Struct Types
# ===============================================================

"""
Holds the tiles and pipes that make up a single ship's map.
Also includes the ship surface which defines where components can be placed.
"""
@kwdef mutable struct ShipMap
    components::Dict{TileCoord, ComponentOnTile} = Dict{TileCoord, ComponentOnTile}()
    pipe_behaviors::Dict{EdgeCoord, PipeBehavior} = Dict{EdgeCoord, PipeBehavior}()
    ship_tiles::Set{TileCoord} = Set{TileCoord}([TileCoord(0, 0)])
end
@struct_hash_equal ShipMap


"Top-level game map containing multiple named ships.  Always contains at least :primary."
@kwdef mutable struct GameMap
    ships::Dict{Symbol, ShipMap} = Dict(:primary => ShipMap())
end
@struct_hash_equal GameMap

"Construct a `GameMap` from a single `ShipMap`, using it as `:primary`"
function GameMap(ship::ShipMap)
    return GameMap(ships = Dict(:primary => ship))
end

const ConnectionVect = SmallVector{12, NodeCoord}

"Holds characteristics which can be deterministically derived from the GameMap"
@kwdef mutable struct DerivedMapState
    ship_surface_edge::Set{TileCoord} = Set{TileCoord}()
    allelements::Vector{AbsoluteElement} = Vector{AbsoluteElement}()
    allnodes::Dict{NodeCoord, UInt16} = Dict{NodeCoord, UInt16}()
    prunedelements::Vector{AbsoluteElement} = Vector{AbsoluteElement}()
    prunednodes::Dict{NodeCoord, UInt16} = Dict{NodeCoord, UInt16}()
    nodeconnections::Dict{NodeCoord, ConnectionVect} = Dict{NodeCoord, ConnectionVect}()
    nodeprimefluidtags::Dict{NodeCoord, FluidTags} = Dict{NodeCoord, FluidTags}()
    nodeactualfluids::Dict{NodeCoord, FluidTags} = Dict{NodeCoord, FluidTags}()
end
@struct_hash_equal DerivedMapState


"Holds intermediates and outputs for the Modified Nodal Analysis"
@kwdef mutable struct MNA_State
    # matrix index lookups
    node_to_index::Dict{NodeCoord, Int64} = Dict{NodeCoord, Int64}()
    index_to_node::Dict{Int64, NodeCoord} = Dict{Int64, NodeCoord}()
    # intermediates
    resistors::Dict{ElementID, AbsoluteElement} = Dict{ElementID, AbsoluteElement}()
    csources::Dict{ElementID, AbsoluteElement} = Dict{ElementID, AbsoluteElement}()
    vsources::Dict{ElementID, AbsoluteElement} = Dict{ElementID, AbsoluteElement}()
    vsource_lookup::Dict{ElementID, Int64} = Dict{ElementID, Int64}()
    mat_A::SparseArrays.UMFPACK.UmfpackLU{Float64, Int64} = lu(sparse(I, 1, 1))
    mat_Z::Matrix{Float64} = Matrix{Float64}(undef, 0, 0)
    # outputs
    node_voltages::Dict{NodeCoord, Float64} = Dict{NodeCoord, Float64}()
    vsource_currents::Dict{ElementID, Float64} = Dict{ElementID, Float64}()
    node_voltages_scaled::Dict{NodeCoord, Float64} = Dict{NodeCoord, Float64}()
end
@struct_hash_equal MNA_State

# ===============================================================
# ShipMap Abstraction Functions
# ===============================================================

# Tile access for ShipMap
"Get the component at a tile coordinate on a ShipMap, or nothing if no component exists"
get_component(ship::ShipMap, coord::TileCoord) = get(ship.components, coord, nothing)

"Check if a component exists at a tile coordinate on a ShipMap"
has_component(ship::ShipMap, coord::TileCoord)::Bool = haskey(ship.components, coord)

"Set the component at a tile coordinate on a ShipMap"
function set_component!(ship::ShipMap, coord::TileCoord, component::ComponentOnTile)
    ship.components[coord] = component
    return nothing
end

"Set multiple components at tile coordinates on a ShipMap"
function set_component!(ship::ShipMap, components::AbstractDict{TileCoord, ComponentOnTile})
    for (coord, component) in components
        ship.components[coord] = component
    end
    return nothing
end

"Delete the component at a tile coordinate on a ShipMap"
function delete_component!(ship::ShipMap, coord::TileCoord)
    delete!(ship.components, coord)
    return nothing
end

"Iterate over all components in a ShipMap (returns pairs of TileCoord => ComponentOnTile)"
get_all_components(ship::ShipMap) = ship.components

# Pipe access for ShipMap
"Get the pipe behavior at an edge coordinate in a ShipMap, or nothing if no pipe exists"
get_pipe(ship::ShipMap, coord::EdgeCoord) = get(ship.pipe_behaviors, coord, nothing)

"Check if a pipe exists at an edge coordinate on a ShipMap"
has_pipe(ship::ShipMap, coord::EdgeCoord)::Bool = haskey(ship.pipe_behaviors, coord)

"Set the pipe behavior at an edge coordinate on a ShipMap"
function set_pipe!(ship::ShipMap, coord::EdgeCoord, pipe_behavior::PipeBehavior)
    ship.pipe_behaviors[coord] = pipe_behavior
    return nothing
end

"Set multiple pipe behaviors at edge coordinates on a ShipMap"
function set_pipe!(ship::ShipMap, pipes::AbstractDict{EdgeCoord, PipeBehavior})
    for (coord, pipe_behavior) in pipes
        ship.pipe_behaviors[coord] = pipe_behavior
    end
    return nothing
end

"Delete the pipe at an edge coordinate in a ShipMap"
function delete_pipe!(ship::ShipMap, coord::EdgeCoord)
    delete!(ship.pipe_behaviors, coord)
    return nothing
end

"Iterate over all pipes in a ShipMap (returns pairs of EdgeCoord => PipeBehavior)"
get_all_pipes(ship::ShipMap) = ship.pipe_behaviors

# Count functions for ShipMap
"Get the number of components in a ShipMap"
count_components(ship::ShipMap)::Int = length(ship.components)

"Get the number of pipes in a ShipMap"
count_pipes(ship::ShipMap)::Int = length(ship.pipe_behaviors)

"Get the number of ship surface tiles in a ShipMap"
count_surface_tiles(ship::ShipMap)::Int = length(ship.ship_tiles)

# Ship surface access for ShipMap
"Check if a coordinate is on the ship surface of a ShipMap"
is_on_surface_tile(coord::TileCoord, ship::ShipMap)::Bool = coord in ship.ship_tiles

"Add a tile coordinate to the ship surface on a ShipMap"
function set_surface_tile!(ship::ShipMap, coord::TileCoord)
    return push!(ship.ship_tiles, coord)
end

"Add multiple tile coordinates to the ship surface on a ShipMap"
function set_surface_tile!(ship::ShipMap, surface::AbstractSet{TileCoord})
    for coord in surface
        set_surface_tile!(ship, coord)
    end
    return nothing
end

"Remove a tile coordinate from the ship surface on a ShipMap. Returns true if removed, false if didn't exist"
function delete_surface_tile!(ship::ShipMap, coord::TileCoord)::Bool
    if coord in ship.ship_tiles
        delete!(ship.ship_tiles, coord)
        return true
    end
    return false
end

"Get all ship surface coordinates in a ShipMap (for rendering or iteration)"
get_all_surface_tiles(ship::ShipMap)::Set{TileCoord} = ship.ship_tiles

# Batch operations for ShipMap
"Delete all components from a ShipMap"
function delete_all_components!(ship::ShipMap)
    return empty!(ship.components)
end

"Delete all pipes from a ShipMap"
function delete_all_pipes!(ship::ShipMap)
    return empty!(ship.pipe_behaviors)
end

"Delete all surface tiles from a ShipMap"
function delete_all_surface_tiles!(ship::ShipMap)
    return empty!(ship.ship_tiles)
end

# ===============================================================
# GameMap Abstraction Functions
# ===============================================================
# These functions provide a clean, ship-routed interface to map internals.
# By default operations route to the `:primary` ship unless `ship_name` is supplied.

# Ship management
"Get a ShipMap by name or throw a descriptive error if it does not exist"
function _get_ship(gamemap::GameMap, ship_name::Symbol = :primary)::ShipMap
    if !haskey(gamemap.ships, ship_name)
        error("Ship '$ship_name' not found. Available ships: $(collect(keys(gamemap.ships)))")
    end
    return gamemap.ships[ship_name]
end

"Add a ShipMap to the GameMap under the provided symbol name; errors if the name already exists"
function add_ship!(gamemap::GameMap, name::Symbol, shipmap::ShipMap)
    if haskey(gamemap.ships, name)
        error("Ship '$name' already exists")
    end
    gamemap.ships[name] = shipmap
    return nothing
end

"Remove a ship from the GameMap by name (error if attempting to remove :primary)"
function remove_ship!(gamemap::GameMap, name::Symbol)
    if name == :primary
        error("Cannot remove primary ship")
    end
    delete!(gamemap.ships, name)
    return nothing
end

"Return a vector containing the Symbol names of all ships in the GameMap"
function get_all_ship_names(gamemap::GameMap)::Vector{Symbol}
    return collect(keys(gamemap.ships))
end

"Return true if a ship with the given name exists in the GameMap, false otherwise"
function has_ship(gamemap::GameMap, name::Symbol)::Bool
    return haskey(gamemap.ships, name)
end

"Get the ShipMap associated with `name` or throw if not found"
function get_ship(gamemap::GameMap, name::Symbol)::ShipMap
    return _get_ship(gamemap, name)
end

# Tile access
"Get the component at a tile coordinate on a specific ship, or nothing if no component exists"
get_component(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary) = get_component(_get_ship(gamemap, ship_name), coord)

"Check if a component exists at a tile coordinate on a specific ship"
has_component(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)::Bool = has_component(_get_ship(gamemap, ship_name), coord)

"Set the component at a tile coordinate on a specific ship"
function set_component!(gamemap::GameMap, coord::TileCoord, component::ComponentOnTile; ship_name::Symbol = :primary)
    set_component!(_get_ship(gamemap, ship_name), coord, component)
    return nothing
end

"Set multiple components at tile coordinates on a specific ship"
function set_component!(gamemap::GameMap, components::AbstractDict{TileCoord, ComponentOnTile}; ship_name::Symbol = :primary)
    set_component!(_get_ship(gamemap, ship_name), components)
    return nothing
end

"Delete the component at a tile coordinate on a specific ship"
function delete_component!(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)
    delete_component!(_get_ship(gamemap, ship_name), coord)
    return nothing
end

"Iterate over all components for a specific ship (returns pairs of TileCoord => ComponentOnTile)"
get_all_components(gamemap::GameMap; ship_name::Symbol = :primary) = get_all_components(_get_ship(gamemap, ship_name))


# Pipe access
"Get the pipe behavior at an edge coordinate on a specific ship, or nothing if no pipe exists"
get_pipe(gamemap::GameMap, coord::EdgeCoord; ship_name::Symbol = :primary) = get_pipe(_get_ship(gamemap, ship_name), coord)

"Check if a pipe exists at an edge coordinate on a specific ship"
has_pipe(gamemap::GameMap, coord::EdgeCoord; ship_name::Symbol = :primary)::Bool = has_pipe(_get_ship(gamemap, ship_name), coord)

"Set the pipe behavior at an edge coordinate on a specific ship"
function set_pipe!(gamemap::GameMap, coord::EdgeCoord, pipe_behavior::PipeBehavior; ship_name::Symbol = :primary)
    set_pipe!(_get_ship(gamemap, ship_name), coord, pipe_behavior)
    return nothing
end

"Set multiple pipe behaviors at edge coordinates on a specific ship"
function set_pipe!(gamemap::GameMap, pipes::AbstractDict{EdgeCoord, PipeBehavior}; ship_name::Symbol = :primary)
    set_pipe!(_get_ship(gamemap, ship_name), pipes)
    return nothing
end

"Delete the pipe at an edge coordinate on a specific ship"
function delete_pipe!(gamemap::GameMap, coord::EdgeCoord; ship_name::Symbol = :primary)
    delete_pipe!(_get_ship(gamemap, ship_name), coord)
    return nothing
end

"Iterate over all pipes for a specific ship (returns pairs of EdgeCoord => PipeBehavior)"
get_all_pipes(gamemap::GameMap; ship_name::Symbol = :primary) = get_all_pipes(_get_ship(gamemap, ship_name))

# Convenience helpers that search across all ships
"Check if any ship contains a component at the given tile coordinate; returns (found::Bool, ship::Union{Symbol, Nothing})"
function has_component_any_ship(gamemap::GameMap, coord::TileCoord)::Tuple{Bool, Union{Symbol, Nothing}}
    for (ship_name, ship) in gamemap.ships
        if has_component(ship, coord)
            return (true, ship_name)
        end
    end
    return (false, nothing)
end

"Get the first component found on any ship at the given tile coordinate; returns (component::Union{ComponentOnTile, Nothing}, ship::Union{Symbol, Nothing})"
function get_component_any_ship(gamemap::GameMap, coord::TileCoord)
    for (ship_name, ship) in gamemap.ships
        comp = get_component(ship, coord)
        if !isnothing(comp)
            return (comp, ship_name)
        end
    end
    return (nothing, nothing)
end

"Check if any ship contains a pipe at the given edge coordinate; returns (found::Bool, ship::Union{Symbol, Nothing})"
function has_pipe_any_ship(gamemap::GameMap, coord::EdgeCoord)::Tuple{Bool, Union{Symbol, Nothing}}
    for (ship_name, ship) in gamemap.ships
        if has_pipe(ship, coord)
            return (true, ship_name)
        end
    end
    return (false, nothing)
end

"Get the first pipe found on any ship at the given edge coordinate; returns (pipe::Union{PipeBehavior, Nothing}, ship::Union{Symbol, Nothing})"
function get_pipe_any_ship(gamemap::GameMap, coord::EdgeCoord)
    for (ship_name, ship) in gamemap.ships
        p = get_pipe(ship, coord)
        if !isnothing(p)
            return (p, ship_name)
        end
    end
    return (nothing, nothing)
end

"Check whether the coordinate is part of any ship surface; returns (found::Bool, ship::Union{Symbol, Nothing})"
function is_on_surface_tile_any_ship(coord::TileCoord, gamemap::GameMap)::Tuple{Bool, Union{Symbol, Nothing}}
    for (ship_name, ship) in gamemap.ships
        if is_on_surface_tile(coord, ship)
            return (true, ship_name)
        end
    end
    return (false, nothing)
end

# Count functions
"Get the number of components in the ship"
count_components(gamemap::GameMap; ship_name::Symbol = :primary)::Int = count_components(_get_ship(gamemap, ship_name))

"Get the number of pipes in the ship"
count_pipes(gamemap::GameMap; ship_name::Symbol = :primary)::Int = count_pipes(_get_ship(gamemap, ship_name))

"Get the number of ship surface tiles for the ship"
count_surface_tiles(gamemap::GameMap; ship_name::Symbol = :primary)::Int = count_surface_tiles(_get_ship(gamemap, ship_name))

# Batch operations
"Delete all components from a ship"
function delete_all_components!(gamemap::GameMap; ship_name::Symbol = :primary)
    return delete_all_components!(_get_ship(gamemap, ship_name))
end

"Delete all pipes from a ship"
function delete_all_pipes!(gamemap::GameMap; ship_name::Symbol = :primary)
    return delete_all_pipes!(_get_ship(gamemap, ship_name))
end

"Delete all surface tiles (remove all surface tiles) from a ship"
function delete_all_surface_tiles!(gamemap::GameMap; ship_name::Symbol = :primary)
    return delete_all_surface_tiles!(_get_ship(gamemap, ship_name))
end

# Ship surface access
"Check if a coordinate is on the ship surface"
is_on_surface_tile(coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Bool = is_on_surface_tile(coord, _get_ship(gamemap, ship_name))

"Default implimentation for placement_valid on a gamemap"
function placement_valid(behav::T, coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary, kwargs...) where {T <: ComponentBehavior}
    if is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return (true, "")
    else
        return (false, "Not on ship surface")
    end
end

"Add a tile coordinate to the ship surface"
function set_surface_tile!(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)
    return set_surface_tile!(_get_ship(gamemap, ship_name), coord)
end

"Add multiple tile coordinates to the ship surface"
function set_surface_tile!(gamemap::GameMap, surface::AbstractSet{TileCoord}; ship_name::Symbol = :primary)
    set_surface_tile!(_get_ship(gamemap, ship_name), surface)
    return nothing
end

"Remove a tile coordinate from the ship surface. Returns true if removed, false if didn't exist"
function delete_surface_tile!(gamemap::GameMap, coord::TileCoord; ship_name::Symbol = :primary)::Bool
    return delete_surface_tile!(_get_ship(gamemap, ship_name), coord)
end

"Get all ship surface coordinates (for rendering or iteration)"
get_all_surface_tiles(gamemap::GameMap; ship_name::Symbol = :primary)::Set{TileCoord} = get_all_surface_tiles(_get_ship(gamemap, ship_name))

"Get the combined ship surface coordinates across all ships in the GameMap"
function get_all_surfaces_combined(gamemap::GameMap)::Set{TileCoord}
    combined = Set{TileCoord}()
    for (_, ship) in gamemap.ships
        union!(combined, get_all_surface_tiles(ship))
    end
    return combined
end

# DerivedMapState ship surface edge access
"Get all ship surface edge tile coordinates (tiles on the boundary of the ship)"
get_all_ship_edge_coords(derivedmapstate::DerivedMapState)::Set{TileCoord} = derivedmapstate.ship_surface_edge

"Get the number of ship surface edge tiles"
count_edge_tiles(derivedmapstate::DerivedMapState)::Int = length(derivedmapstate.ship_surface_edge)

"Count how many of a tile's 6 adjacent neighbors are present in the surface set."
@inline function count_surfacetile_adjacencies(surface_set::Set{TileCoord}, tile::TileCoord)::Int
    adjacent_tiles = HexFrame.get_adjacent_tiles_for_tile(tile)
    return count(adj_tile -> adj_tile in surface_set, adjacent_tiles)
end

"Update a set with tiles that are on the boundary of a single ShipMap"
function find_ship_surface_edgetiles!(edgesurface::Set{TileCoord}, ship::ShipMap)
    empty!(edgesurface)
    for tile in ship.ship_tiles
        if count_surfacetile_adjacencies(ship.ship_tiles, tile) != 6
            push!(edgesurface, tile)
        end
    end
    return nothing
end

"Update a set with tiles that are on the boundary of all ships (combined). Aggregates ship-level results."
function find_ship_surface_edgetiles!(edgesurface::Set{TileCoord}, gamemap::GameMap)
    empty!(edgesurface)
    tmp = Set{TileCoord}()
    for (_, ship) in gamemap.ships
        empty!(tmp)
        find_ship_surface_edgetiles!(tmp, ship)
        union!(edgesurface, tmp)
    end
    return nothing
end

"Update the ship_surface_edge set in DerivedMapState with tiles that are on the boundary of the ship."
function find_ship_surface_edgetiles!(derivedmapstate::DerivedMapState, gamemap::GameMap)
    find_ship_surface_edgetiles!(derivedmapstate.ship_surface_edge, gamemap)
    return nothing
end

# Placement validation
"Check if a node is connected to the ship surface by verifying that at least one of the tiles adjacent to the node is on the ship surface."
function is_node_on_ship_surface(node_abs::NodeCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Tuple{Bool, String}
    # Get the tiles adjacent to this node
    adjacent_tiles = get_adjacent_tiles_for_node(node_abs)

    # Check if any adjacent tile is on the specified ship surface
    for (tile, _) in adjacent_tiles
        if is_on_surface_tile(tile, gamemap; ship_name = ship_name)
            return (true, "")
        end
    end

    # No adjacent tiles on surface
    return (false, "Node is not connected to ship surface")
end

"Check if a component can be placed at a coordinate"
function can_place_component_at(coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Tuple{Bool, String}
    if !is_on_surface_tile(coord, gamemap; ship_name = ship_name)
        return (false, "Not on ship surface")
    end
    return (true, "")
end

"Check if a pipe can be placed at an edge coordinate (both endpoint nodes must be on ship surface)"
function can_place_pipe_at(coord::EdgeCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Tuple{Bool, String}
    # Get the two node coordinates for this edge
    v1_node = to_nodecoord(coord.v1)
    v2_node = to_nodecoord(coord.v2)

    # Check that the first node is connected to ship surface
    v1_valid, v1_reason = is_node_on_ship_surface(v1_node, gamemap; ship_name = ship_name)
    if !v1_valid
        return (false, "Pipe endpoint node at $(coord.v1.tile) is not connected to ship surface")
    end

    # Check that the second node is connected to ship surface
    v2_valid, v2_reason = is_node_on_ship_surface(v2_node, gamemap; ship_name = ship_name)
    if !v2_valid
        return (false, "Pipe endpoint node at $(coord.v2.tile) is not connected to ship surface")
    end

    return (true, "")
end

"Check if a surface tile can be removed (must not have a component on it)"
function can_remove_surface_at(coord::TileCoord, gamemap::GameMap; ship_name::Symbol = :primary)::Tuple{Bool, String}
    if has_component(gamemap, coord; ship_name = ship_name)
        return (false, "Surface cannot be deleted under a component, delete component first")
    end
    # TODO: This validation doesn't prevent nozzles from being left floating when their input node's
    # surface tile is removed. Consider adding a check that iterates through all components and validates
    # their placement after surface removal, or implement a separate validation pass that can be triggered
    # when editing surface tiles. For now, users can create invalid states by removing surface under
    # nozzle input nodes, but this won't cause crashes - just invalid placement that can be fixed.
    return (true, "")
end

# ===============================================================
# Helper Functions
# ===============================================================

"Find which ship (if any) owns the surface tile at a coordinate"
function find_ship_for_surface(gamemap::GameMap, coord::TileCoord)::Union{Symbol, Nothing}
    for (name, ship) in gamemap.ships
        if coord in ship.ship_tiles
            return name
        end
    end
    return nothing
end

"Find which ship(s) have surfaces adjacent to a coordinate"
function find_ships_adjacent_to_coord(gamemap::GameMap, coord::TileCoord)::Vector{Symbol}
    adjacent_tiles = HexFrame.get_adjacent_tiles_for_tile(coord)
    adjacent_ships = Symbol[]
    for adj_tile in adjacent_tiles
        ship_name = find_ship_for_surface(gamemap, adj_tile)
        if !isnothing(ship_name) && !(ship_name in adjacent_ships)
            push!(adjacent_ships, ship_name)
        end
    end
    return adjacent_ships
end

"Check if placing a surface at coord would connect multiple ships (invalid)"
function would_bridge_ships(gamemap::GameMap, coord::TileCoord)::Bool
    adjacent_ships = find_ships_adjacent_to_coord(gamemap, coord)
    return length(adjacent_ships) > 1
end

"Find which ship a component/pipe should belong to by testing placement_valid on all ships"
function find_valid_ship_for_placement(
        component::ComponentBehavior,
        coord::TileCoord,
        gamemap::GameMap;
        rotation::HexAxis
    )::Union{Symbol, Nothing}
    for (ship_name, _) in gamemap.ships
        is_valid, _ = placement_valid(component, coord, gamemap; rotation = rotation, ship_name = ship_name)
        if is_valid
            return ship_name
        end
    end
    return nothing
end

"Find which ship owns a component at a given coordinate (searches all ships)"
function find_ship_with_component(gamemap::GameMap, coord::TileCoord)::Union{Symbol, Nothing}
    for (ship_name, ship) in gamemap.ships
        if haskey(ship.components, coord)
            return ship_name
        end
    end
    return nothing
end

"Find which ship owns a pipe at a given edge coordinate (searches all ships)"
function find_ship_with_pipe(gamemap::GameMap, coord::EdgeCoord)::Union{Symbol, Nothing}
    for (ship_name, ship) in gamemap.ships
        if haskey(ship.pipe_behaviors, coord)
            return ship_name
        end
    end
    return nothing
end

"Offset all coordinates in a ShipMap in-place by a TileCoord offset."
function offset_ship!(shipmap::ShipMap, offset::TileCoord)
    # Offset components
    new_components = Dict{TileCoord, ComponentOnTile}()
    sizehint!(new_components, length(shipmap.components))
    for (coord, comp) in shipmap.components
        new_coord = TileCoord(coord.q + offset.q, coord.r + offset.r)
        new_components[new_coord] = comp
    end
    empty!(shipmap.components)
    merge!(shipmap.components, new_components)

    # Offset pipes
    new_pipes = Dict{EdgeCoord, PipeBehavior}()
    sizehint!(new_pipes, length(shipmap.pipe_behaviors))
    for (edge, pipe) in shipmap.pipe_behaviors
        v1_offset = VertexCoord(
            TileCoord(edge.v1.tile.q + offset.q, edge.v1.tile.r + offset.r),
            edge.v1.dir
        )
        v2_offset = VertexCoord(
            TileCoord(edge.v2.tile.q + offset.q, edge.v2.tile.r + offset.r),
            edge.v2.dir
        )
        new_edge = EdgeCoord(v1_offset, v2_offset)
        new_pipes[new_edge] = pipe
    end
    empty!(shipmap.pipe_behaviors)
    merge!(shipmap.pipe_behaviors, new_pipes)

    # Offset surface tiles
    new_surface = Set{TileCoord}()
    sizehint!(new_surface, length(shipmap.ship_tiles))
    for coord in shipmap.ship_tiles
        new_coord = TileCoord(coord.q + offset.q, coord.r + offset.r)
        push!(new_surface, new_coord)
    end
    empty!(shipmap.ship_tiles)
    union!(shipmap.ship_tiles, new_surface)

    return nothing
end

"Used to update a Dict holding the count of instances of the key in another set. Call this function once for each occurrence of the key"
function add_or_increment!(dict::Dict{K, V}, key::K) where {K, V <: Integer}
    if haskey(dict, key)
        dict[key] += one(V)
    else
        dict[key] = one(V)
    end
    return nothing
end

"Returns true if the input node is one of the connections of the element"
function element_has_node(element::AbsoluteElement, node::NodeCoord)::Bool
    return (element.connections.v1 == node) || (element.connections.v2 == node)
end

"""
Elements have two connections, this function returns the connection that's not the input node.
Raises an error if the input node is not a connection of the input element.
"""
function element_other_node(element::AbsoluteElement, node::NodeCoord)
    if element.connections.v1 == node
        return element.connections.v2
    elseif element.connections.v2 == node
        return element.connections.v1
    else
        error("element_other_node called when node not in element")
    end
end

function add_pipes_abs_element!(abs_vector::Vector{AbsoluteElement}, edge::EdgeCoord, conductance::Float64)
    connections = AbsoluteElementConnections(to_nodecoord(edge.v1), to_nodecoord(edge.v2))
    absolute_element = AbsoluteElement(connections, conductance, CONST_RESISTOR, ElementID(edge))
    return push!(abs_vector, absolute_element)
end

"Updates behaviors of all components on a single ShipMap"
function update_components!(ship::ShipMap, mna_state::MNA_State)
    for (coord, data) in ship.components
        update_flowbehav!(data; tile = coord, mna_state = mna_state)
    end
    return nothing
end

"Updates behaviors of all components on the GameMap by delegating to each ShipMap"
function update_components!(gamemap::GameMap, mna_state::MNA_State)
    for (_, ship) in gamemap.ships
        update_components!(ship, mna_state)
    end
    return nothing
end

"List all electrical elements for a single ship (returns AbsoluteElement vector)."
function list_elements(ship::ShipMap)
    tiles = ship.components
    pipe_behaviors = ship.pipe_behaviors

    size = length(tiles) + length(pipe_behaviors)
    elements_present = Vector{AbsoluteElement}()
    sizehint!(elements_present, size * 2)

    for (coord, data) in tiles # collects elements from each tile on the ship
        produced = produce_abs_elements(data, coord)
        if length(produced) > 0
            push!(elements_present, produced...)
        end
    end

    for (edge, pipe_behav) in pipe_behaviors # collects elements from pipes on the ship
        produced = produce_abs_elements(pipe_behav, edge)
        if length(produced) > 0
            push!(elements_present, produced...)
        end
    end

    # remove any inactive elements (produced by stalled components)
    filter!(e -> getfield(e, :active), elements_present)
    return elements_present
end

"List all electrical elements in the GameMap (aggregates across ships)"
function list_elements(gamemap::GameMap)
    all_elements = Vector{AbsoluteElement}()
    sizehint!(all_elements, 16)

    for (_, ship) in gamemap.ships
        append!(all_elements, list_elements(ship))
    end

    # remove any inactive elements (produced by stalled components)
    filter!(e -> getfield(e, :active), all_elements)
    return all_elements
end

"List all nodes connected to an element"
function list_nodes(elements::Vector{AbsoluteElement})
    node_count = Dict{NodeCoord, UInt16}()
    sizehint!(node_count, length(elements))

    for element in elements
        # adds the nodes connected to each element if they aren't grounded
        node1 = element.connections.v1
        if !is_grounded(node1)
            add_or_increment!(node_count, node1)
        end
        node2 = element.connections.v2
        if !is_grounded(node2)
            add_or_increment!(node_count, node2)
        end
    end

    return node_count
end

"Prune dead branches that will break the MNA, by iteratively removing nodes with a single element connection"
function prune(elements::Vector{AbsoluteElement})::Vector{AbsoluteElement}
    final_nodes::Dict{NodeCoord, UInt16} = list_nodes(elements)
    final_elements::Vector{AbsoluteElement} = copy(elements)

    bad_nodes = [k for (k, v) in final_nodes if v <= 1] # nodes with 0 or 1 connections are bad

    while !isempty(bad_nodes)
        node = pop!(bad_nodes)

        i = 1
        for element in final_elements
            if element_has_node(element, node)
                other_node = element_other_node(element, node)
                if !is_grounded(other_node)
                    if final_nodes[other_node] != 0 # prevent underflow
                        final_nodes[other_node] -= 1
                    end
                    if final_nodes[other_node] <= 1 # push newly unconnected nodes
                        push!(bad_nodes, other_node)
                    end
                end
            else # element doesn't have bad node, should be kept
                final_elements[i] = element
                i += 1
            end
        end

        resize!(final_elements, i - 1)
    end

    return final_elements
end

"""
Returns a Dict of connections between nodes, where the keys are the nodes and the values are sets of connected nodes.

NOTE: This function uses small vectors in the hot loop to avoid allocation for each node.
There is actually a finite set of nodes that could be connected to each node (12) so this
can be significantly optimized by using a SmallBitSet indexing those 12 possibilities. This
could drop the size in memory of a ConnectionVect from 74 bytes to 2 bytes, which will reduce the
copy overhead on the pushes to immutable types, and would reduce memory usage of nodeconnections.
"""
function build_node_connection_map!(derivedmapstate::DerivedMapState)
    elements = derivedmapstate.prunedelements
    nodeconnections = derivedmapstate.nodeconnections
    empty!(nodeconnections)

    for element in elements
        v1 = element.connections.v1
        v2 = element.connections.v2

        if is_grounded(v2) # grounded nodes contribute no connections
            continue
        end

        oldset = get(nodeconnections, v1, ConnectionVect())
        if !(v2 in oldset)
            nodeconnections[v1] = push(oldset, v2)
        end

        oldset = get(nodeconnections, v2, ConnectionVect())
        if !(v1 in oldset)
            nodeconnections[v2] = push(oldset, v1)
        end
    end
    return nothing
end

"Set derivedmapstate.actualfluids based by propagating the concrete fluids from primefluidtags through the nodeconnections"
function connect_fluidtags!(derivedmapstate::DerivedMapState)
    nodeconnections = derivedmapstate.nodeconnections
    derivedmapstate.nodeactualfluids = copy(derivedmapstate.nodeprimefluidtags)
    actualfluids = derivedmapstate.nodeactualfluids

    concrete_fluidnodes::Set{NodeCoord} = Set(
        node for (node, tag) in derivedmapstate.nodeprimefluidtags if is_gas(tag) || is_liquid(tag)
    )
    to_visit = Set{NodeCoord}() # set of nodes to visit, reused each loop
    visited = Set{NodeCoord}() # set of nodes that have been visited, reused each loop

    # Traverse from all tags with a concrete fluid type and check for collisions.
    # Once all concrete tagged nodes have been traversed or visited, the algorithm will end.
    # This will visit all nodes connected to a concrete fluid tag, and update their fluid tags.
    while !isempty(concrete_fluidnodes)
        # grab a node with concrete fluid tag
        start_node = pop!(concrete_fluidnodes)
        start_fluidtag = derivedmapstate.nodeprimefluidtags[start_node]
        push!(to_visit, start_node)

        # traverse the graph of nodes, starting from the start node
        # uses some random combination of BFS and DFS as sets are unordered
        while true
            current_node = pop!(to_visit)
            connections = get(nodeconnections, current_node, ConnectionVect())
            for node in connections
                # add unvisited connected nodes to visit set
                if !(node in visited)
                    push!(to_visit, node)
                end
            end
            tag = prioritise_fluidtag(actualfluids[current_node], start_fluidtag)
            actualfluids[current_node] = tag
            delete!(concrete_fluidnodes, current_node) # node reached so can be removed from concrete set
            push!(visited, current_node)

            isempty(to_visit) && break # exit if to_visit is empty
        end
    end
    return nothing
end


"""
Performs graph traversal across all elements, starting from grounded elements to exclude elements not connected to ground.
Uses some random combination of breadth and depth first search, as pushes and pops from sets are not ordered.
Returns elements that were visited, and thus reachable from a ground node
"""
function ground_search(elements::Vector{AbsoluteElement})
    node_elements = Dict{NodeCoord, Vector{UInt16}}()
    sizehint!(node_elements, length(elements))

    for (index, element) in enumerate(elements)
        # adds the nodes connected to each element
        for i in 1:2
            node = getfield(element.connections, i)
            # if the node is not grounded, then it can be used to find other elements
            if !is_grounded(node)
                if !haskey(node_elements, node)
                    node_elements[node] = Vector{UInt16}()
                end
                push!(node_elements[node], index)
            end
        end
    end

    # elements are represented by their index in the input vector
    grounded_elements::Set{UInt16} = Set(UInt16(index) for (index, elem) in enumerate(elements) if is_grounded(elem.connections.v2))
    to_visit::Set{UInt16} = Set{UInt16}()
    visited::Set{UInt16} = Set{UInt16}()
    sizehint!(visited, length(elements))

    while !isempty(grounded_elements)
        # start at grounded element that hasn't been visited yet
        grounded_element = pop!(grounded_elements)
        if grounded_element ∈ visited
            continue
        end
        push!(to_visit, grounded_element)

        while !isempty(to_visit)
            current = pop!(to_visit)
            push!(visited, current)

            for i in 1:2
                node = getfield(elements[current].connections, i)
                if !is_grounded(node)
                    # add connected elements to to_visit if they haven't been visited already
                    connected_elements = node_elements[node]
                    for element in connected_elements
                        if element ∉ visited
                            push!(to_visit, element)
                        end
                    end
                end
            end
        end
    end

    return elements[collect(visited)]
end

"""
Removes dependant elements that depend on an element that has been pruned.
This can leave other elements in a state where they should also now be pruned,
if this function modifies the vector you should call prune and ground_search again.
"""
function clear_dangling_dependants(elements::Vector{AbsoluteElement})::Vector{AbsoluteElement}
    # exit early for empty vector
    if isempty(elements)
        return Vector{AbsoluteElement}()
    end

    # create set of element IDs for fast membership tests
    element_IDs = Set{ElementID}()
    sizehint!(element_IDs, length(elements))
    for element in elements
        push!(element_IDs, element.id)
    end

    final_elements::Vector{AbsoluteElement} = Vector{AbsoluteElement}()
    sizehint!(final_elements, length(elements))
    last_hash::UInt64 = 0

    # Check dependent elements repeatedly until no change is made.
    # This is required as depending on element order it is possible for an element to pass its dependent check,
    # but then have the element it depended on pruned later on.
    while last_hash != hash(final_elements)
        last_hash = hash(final_elements)
        empty!(final_elements)

        for element in elements
            # element added by default
            push!(final_elements, element)

            # elements with no dependent can always stay
            if element.dependent_id.index == 0
                continue
            end

            # dependent element must have its dependency present
            if !(element.dependent_id in element_IDs)
                pop!(final_elements)
                delete!(element_IDs, element.dependent_id)
            end
        end
    end

    return final_elements
end

"Returns the current through an absolute element, or nothing if element was pruned"
function abs_element_get_current(element::AbsoluteElement, derivedmapstate::DerivedMapState, mna_state::MNA_State)
    if !(element in derivedmapstate.prunedelements)
        return nothing
    end

    # for csource, current is their value
    if element.type == CONST_CURRENT
        return element.value
    end

    # for vsource, current is looked up directly from MNA results
    if element.type == CONST_VOLTAGE || element.type == V_DEP_VOLTAGE
        return mna_state.vsource_currents[element.id]
    end

    # for resistors, current calculated from voltage difference and resistance
    if element.type == CONST_RESISTOR
        volt1 = mna_state.node_voltages[element.connections.v1]
        volt2 = is_grounded(element.connections.v2) ? 0.0 : mna_state.node_voltages[element.connections.v2]
        return (volt1 - volt2) * element.value
    end

    # for dependant current sources, current is dependant on another vsource current
    if element.type == C_DEP_CURRENT
        dep_element_id = element.dependent_id
        if haskey(mna_state.vsource_lookup, dep_element_id)
            return mna_state.vsource_currents[dep_element_id] * element.value
        else
            error("Dependent current source depends on a source that is not in the MNA vsource lookup")
        end
    end

    error("Tried to get current for unimplemented element type")
end

"Get the fluid tag contributed by a single tile on a ShipMap for the specified node axis"
function get_tile_fluid_tag(ship::ShipMap, tile::TileCoord, hex_axis::HexAxis)
    if haskey(ship.components, tile)
        tile_comp = ship.components[tile]
        tile_tags = get_fluidtags(tile_comp)
        local_dir = rotate(to_hexaxis(hex_axis), HexFrame.rotate_reverse(tile_comp.rotation))
        return getfield(tile_tags, Symbol(to_nodepos(local_dir)))
    end
    return HexFluids.NONE
end

"Get the fluid tags from tiles adjacent to a node for a single ShipMap"
function get_node_fluid_tags(node::NodeCoord, ship::ShipMap)
    if node.dir === HexFrame.NODE_INTERNAL
        tile_comp = get_component(ship, node.tile)
        if tile_comp === nothing
            return (HexFluids.NONE,)
        end
        fluidtags = get_fluidtags(tile_comp)
        tag = getfield(fluidtags, Symbol(HexFrame.NODE_INTERNAL))
        return (tag,)
    end

    proper_node = to_proper(node)
    adjacent_tiles_info = get_adjacent_tiles_for_node(proper_node)

    tags = map(adjacent_tiles_info) do (tile, hex_axis)
        get_tile_fluid_tag(ship, tile, to_hexaxis(hex_axis))
    end

    return (tags[1], tags[2], tags[3])
end

"Get the fluid tags from tiles adjacent to a node, checking all ships (aggregates ship lookups)."
function get_node_fluid_tags(node::NodeCoord, gamemap::GameMap)
    if node.dir === HexFrame.NODE_INTERNAL
        for (_, ship) in gamemap.ships
            tagtuple = get_node_fluid_tags(node, ship)
            if tagtuple[1] !== HexFluids.NONE
                return tagtuple
            end
        end
        return (HexFluids.NONE,)
    end

    proper_node = to_proper(node)
    adjacent_tiles_info = get_adjacent_tiles_for_node(proper_node)

    tags = Vector{HexFluids.FluidTags}(undef, 3)
    for (i, (tile, hex_axis)) in enumerate(adjacent_tiles_info)
        # For each adjacent tile, check all ships until a non-NONE tag is found
        found = HexFluids.NONE
        for (_, ship) in gamemap.ships
            candidate = get_tile_fluid_tag(ship, tile, to_hexaxis(hex_axis))
            if candidate !== HexFluids.NONE
                found = candidate
                break
            end
        end
        tags[i] = found
    end

    return (tags[1], tags[2], tags[3])
end

"Assigns the highest priority fluid tag to each node in the map, from the tags of connected tiles"
function fluidtag_nodes(derivedmapstate::DerivedMapState, gamemap::GameMap)::Dict{NodeCoord, FluidTags}
    node_prime_fluidtags = Dict{NodeCoord, FluidTags}()
    for (node, _) in derivedmapstate.prunednodes
        tags = get_node_fluid_tags(node, gamemap)
        primetag = prioritise_fluidtag(tags...)
        node_prime_fluidtags[node] = primetag
    end

    return node_prime_fluidtags
end

"Assigns nodes indexes to use in the MNA matrices. Returns 2 Dicts for lookups in either direction"
function MNA_indexnodes(derivedmapstate::DerivedMapState)
    nodes = derivedmapstate.prunednodes

    num_nodes = length(nodes)
    node_to_index = Dict{NodeCoord, Int64}()
    index_to_node = Dict{Int64, NodeCoord}()
    sizehint!(node_to_index, num_nodes)
    sizehint!(index_to_node, num_nodes)
    i = 1
    for (node, _) in nodes
        node_to_index[node] = i
        index_to_node[i] = node
        i += 1
    end

    return (node_to_index, index_to_node)
end

"Checks if element is a resistor (CONST_RESISTOR type)"
is_resistor(element::Element)::Bool = element.type in (CONST_RESISTOR,)

"Checks if element is a current source (CONST_CURRENT or C_DEP_CURRENT types)"
is_csource(element::Element)::Bool = element.type in (CONST_CURRENT, C_DEP_CURRENT)

"Checks if element is a voltage source (CONST_VOLTAGE or V_DEP_VOLTAGE types)"
is_vsource(element::Element)::Bool = element.type in (CONST_VOLTAGE, V_DEP_VOLTAGE)

"Sort elements into separate vectors based on their type and populate index lookups. Result mutates mna_state"
function MNA_splitelements!(mna_state::MNA_State, derivedmapstate::DerivedMapState)
    empty!(mna_state.resistors)
    empty!(mna_state.csources)
    empty!(mna_state.vsources)
    empty!(mna_state.vsource_lookup)

    # sort elements into their respective dicts
    for element::AbsoluteElement in derivedmapstate.prunedelements
        if is_resistor(element)
            mna_state.resistors[element.id] = element
        elseif is_csource(element)
            mna_state.csources[element.id] = element
        elseif is_vsource(element)
            mna_state.vsources[element.id] = element
        end
    end

    # assign indexes to vsources, used to locate them in the B and E Matrixes
    for (index, (id, _element)) in enumerate(mna_state.vsources)
        mna_state.vsource_lookup[id] = index
    end

    return nothing
end

"""
Gets the A matrix to be used in MNA. Returns it in an LU decomposed form.
Uses matrix names and algorithms from https://qucs.sourceforge.net/tech/node14.html
"""
function MNA_getA(mna_state::MNA_State)
    resistors = mna_state.resistors
    vsources = mna_state.vsources
    csources = mna_state.csources
    node_to_index = mna_state.node_to_index
    vsource_lookup = mna_state.vsource_lookup

    num_vsource = length(vsources) # M number of independent voltage sources
    num_nodes = length(node_to_index) # N number of nodes

    # A MATRIX
    #=
    The G matrix is an N×N matrix formed in two steps.

    Each element in the diagonal matrix is equal to the sum of the conductance (one over the resistance)
    of each element connected to the corresponding node. So the first diagonal element is the sum of 
    conductances connected to node 1, the second diagonal element is the sum of conductances connected 
    to node 2, and so on.

    The off diagonal elements are the negative conductance of the element connected to the pair of 
    corresponding node. Therefore a resistor between nodes 1 and 2 goes into the G matrix at location 
    (1,2) and locations (2,1).

    If an element is grounded, it will only have contribute to one entry in the G matrix - at the 
    appropriate location on the diagonal. If it is ungrounded it will contribute to four entries 
    in the matrix - two diagonal entries (corresponding to the two nodes) and two off-diagonal entries.
    =#
    G = let
        G = zeros(num_nodes, num_nodes)
        for element in values(resistors)
            conductance = element.value
            v1_index = node_to_index[element.connections.v1]

            # v1 will always show up on the diagonal
            G[v1_index, v1_index] += conductance

            # v2 contributes to diagonal and off-diagonal if not grounded
            if !is_grounded(element.connections.v2)
                v2_index = node_to_index[element.connections.v2]
                G[v2_index, v2_index] += conductance
                G[v1_index, v2_index] -= conductance
                G[v2_index, v1_index] -= conductance
            end
        end

        # return sparse G from let scope
        sparse(G)
    end

    #=
    The pure B matrix (not considering dependent sources) is an N$ \times$M 
    matrix with only 0, 1, and -1 elements. Each location in the matrix corresponds 
    to a particular voltage source (first dimension) or a node (second dimension). 
    If the positive terminal of the ith voltage source is connected to node k, then 
    the element (k,i) in the B matrix is a 1. If the negative terminal of the ith 
    voltage source is connected to node k, then the element (k,i) in the B matrix 
    is a -1. Otherwise, elements of the B matrix are zero.

    If a voltage source is ungrounded, it will have two elements in the B matrix 
    (a 1 and a -1 in the same column). If it is grounded, it will only have one 
    element in the matrix.
    =#
    pure_B = let
        B = zeros(num_nodes, num_vsource)
        for (vsource_index, (id, element)) in enumerate(vsources)
            vsource_index = vsource_lookup[id]

            # v1 contributes +1
            v1_index = node_to_index[element.connections.v1]
            B[v1_index, vsource_index] = 1.0

            # v2 contributes -1 if not grounded
            if !is_grounded(element.connections.v2)
                v2_index = node_to_index[element.connections.v2]
                B[v2_index, vsource_index] = -1.0
            end
        end

        # return pure B from let scope (is not yet made sparse, will be made sparse an B and C)
        B
    end

    #=
    The B matrix is based on the pure B matrix, but it is modified to include dependent sources.
    The standard +1 and -1 entries for the dependent source have already been added during the
    creation of the pure B matrix.

    VCVS (V_DEP_VOLTAGE) have no additional effects on the B matrix

    CCCS (C_DEP_CURRENT) are current sources dependent on the current through a voltage source.
    They modify the column corresponding to the voltage source they depend on, adding a
    value of +gain to the node connected to the positive terminal of the voltage source,
    and a value of -gain to the node connected to the negative terminal of the voltage source.
    =#
    B = let
        B = copy(pure_B)

        for (id, element) in csources
            if element.type == C_DEP_CURRENT
                dep_element_id = element.dependent_id

                if !haskey(vsource_lookup, dep_element_id)
                    error("Dependent current source depends on a source that is not in the MNA vsource lookup")
                    # TODO: this should be handled by pruning, but currently is not
                end

                dep_element_index = vsource_lookup[dep_element_id]

                pos_dep_node = element.connections.v1
                neg_dep_node = element.connections.v2

                # set vsource positive node to +gain (never grounded, can assume not pruned)
                pos_node_index = node_to_index[pos_dep_node]
                B[pos_node_index, dep_element_index] += element.value

                # set the vsource negative node to -gain if it is not grounded
                if !is_grounded(neg_dep_node)
                    neg_node_index = node_to_index[neg_dep_node]
                    B[neg_node_index, dep_element_index] += -(element.value)
                end
            end
        end

        # return sparse B from let scope
        sparse(B)
    end

    #=
    C matrix is the transpose of the B matrix, if there are no dependent sources.

    VCVS (V_DEP_VOLTAGE) are voltage sources dependent on the voltage across an element. The standard
    +1 and -1 entries of a vsource are brought over from the transposed pure B matrix. In the row
    corresponding to the voltage source, the C matrix has a +gain in the column corresponding to the
    dependent element's negative terminal node, and a -gain in the column corresponding to the dependent
    element's positive terminal node.
    =#
    C = let
        C = copy(transpose(pure_B)) # C is based on the transposed pure B matrix

        for (id, element) in vsources
            if element.type == V_DEP_VOLTAGE
                dep_element_id = element.dependent_id # get the element this VCVS depends on

                # VCVS can depend on any element type
                if haskey(resistors, dep_element_id)
                    dep_element = resistors[dep_element_id]
                elseif haskey(csources, dep_element_id)
                    dep_element = csources[dep_element_id]
                elseif haskey(vsources, dep_element_id)
                    dep_element = vsources[dep_element_id]
                else
                    error("VCVS depends on element that is not in the MNA")
                end

                vsource_index = vsource_lookup[id]

                # set positive node v1 to -gain (never grounded, can assume not pruned)
                pos_dep_node = dep_element.connections.v1
                pos_node_index = node_to_index[pos_dep_node]
                C[vsource_index, pos_node_index] += -(element.value)

                # set the negative node v2 to +gain if it is not grounded
                neg_dep_node = dep_element.connections.v2
                if !is_grounded(neg_dep_node)
                    neg_node_index = node_to_index[neg_dep_node]
                    C[vsource_index, neg_node_index] += element.value
                end
            end
        end

        # return sparse C from let scope
        sparse(C)
    end

    #=
    The D matrix is an M×M matrix that is composed entirely of zeros. It can be non-zero if dependent
    sources are considered, however no implemented sources currently modify the D matrix.
    =#
    D = spzeros(num_vsource, num_vsource)

    A = hvcat((2, 2), G, B, C, D) # A matrix build from submatrices

    return lu(A) # return LU decomposed A matrix
end


function MNA_getZ(mna_state::MNA_State)
    vsources = mna_state.vsources
    vsource_lookup = mna_state.vsource_lookup
    csources = mna_state.csources
    node_to_index = mna_state.node_to_index

    num_vsource = length(vsources) # M number of independent voltage sources
    num_nodes = length(node_to_index) # N number of nodes

    #=
    The i matrix is an N×1 matrix with each element of the matrix corresponding to a particular node.
    The value of each element of i is determined by the sum of current sources into the corresponding node.
    If there are no current sources connected to the node, the value is zero.
    =#
    I = let
        I = zeros(num_nodes, 1)
        for element in values(csources)
            if element.type != CONST_CURRENT # only independent current sources contribute to the i matrix
                continue
            end

            current = element.value
            v1_index = node_to_index[element.connections.v1]

            # v1 contributes +current (positive terminal)
            I[v1_index] += current

            # v2 contributes -current if not grounded (negative terminal)
            if !is_grounded(element.connections.v2)
                v2_index = node_to_index[element.connections.v2]
                I[v2_index] -= current
            end
        end

        # return I from let scope (can't be sparse to allow solving)
        I
    end

    #=
    The e matrix is an M×1 matrix with each element of the matrix equal in value to the corresponding
    independent voltage source.

    If the voltage source is dependent, then a value of 0 is added to the e matrix
    =#
    E = let
        E = zeros(num_vsource, 1)
        for (id, element) in vsources
            vsource_index = vsource_lookup[id]

            if is_dependant(element.type)
                E[vsource_index] = 0.0 # dependent sources have voltage of 0
            else
                E[vsource_index] = element.value # independent sources have voltage of value set
            end
        end

        # return E from let scope (can't be sparse to allow solving)
        E
    end

    # Combine to form z
    return Z = vcat(I, E)
end

function MNA_solve(mna_state::MNA_State)
    Z = mna_state.mat_Z
    A = mna_state.mat_A
    vsources = mna_state.vsources
    vsource_lookup = mna_state.vsource_lookup
    index_to_node = mna_state.index_to_node

    num_vsource = length(vsources) # M number of independent voltage sources
    num_nodes = length(index_to_node) # N number of nodes

    # X MATRIX (solution)
    X = similar(Z)
    try
        X = A \ Z
    catch e
        println("Solve Exception: ", e)
        println("\n\n A Matrix:")
        display(A)
        println("\n\n Z Matrix:")
        display(Z)
        X .= 0.0 # solve failed, just return zeroes
    end

    #=
    The V matrix is an N×1 matrix formed of the node voltages. Each element in v corresponds to the voltage
    at the equivalent node in the circuit (there is no entry for ground - node 0).
    =#
    V = @view X[1:num_nodes, 1]
    node_voltages = Dict{NodeCoord, Float64}()
    sizehint!(node_voltages, num_nodes)
    for (index, node) in index_to_node
        node_voltages[node] = V[index]
    end

    #=
    The J matrix is an M×1 matrix, with one entry for the current through each voltage source
    =#
    J = @view X[(num_nodes + 1):end, 1]
    vsource_currents = Dict{ElementID, Float64}()
    sizehint!(vsource_currents, num_vsource)
    for (id, index) in vsource_lookup
        vsource_currents[id] = J[index]
    end

    return (node_voltages, vsource_currents)
end

end # module FlowEngine
