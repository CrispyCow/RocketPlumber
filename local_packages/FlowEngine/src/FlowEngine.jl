module FlowEngine

using HexFrame, HexElements, HexFluids, HexComponentsAPI
using FlowMap
import FlowMap: find_ship_surface_edgetiles!

using SparseArrays, LinearAlgebra, SmallCollections, StructEquality

# Type Exports
export DerivedMapState, MNA_State
# Function Exports
export add_pipes_abs_element!, abs_element_get_current, update_components!
export list_elements, list_nodes, prune, ground_search, clear_dangling_dependants
export fluidtag_nodes, get_node_fluid_tags, build_node_connection_map!, connect_fluidtags!
export MNA_indexnodes, MNA_splitelements!, MNA_getA, MNA_getZ, MNA_solve
# DerivedMapState ship surface edge access
export get_all_ship_edge_coords, count_edge_tiles

const CONST_RESISTOR = HexElements.CONST_RESISTOR
const CONST_CURRENT = HexElements.CONST_CURRENT
const CONST_VOLTAGE = HexElements.CONST_VOLTAGE
const C_DEP_CURRENT = HexElements.C_DEP_CURRENT
const V_DEP_VOLTAGE = HexElements.V_DEP_VOLTAGE

# ===============================================================
# Game State Struct Types
# ===============================================================

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

# DerivedMapState ship surface edge access
"Get all ship surface edge tile coordinates (tiles on the boundary of the ship)"
get_all_ship_edge_coords(derivedmapstate::DerivedMapState)::Set{TileCoord} = derivedmapstate.ship_surface_edge

"Get the number of ship surface edge tiles"
count_edge_tiles(derivedmapstate::DerivedMapState)::Int = length(derivedmapstate.ship_surface_edge)

"Update the ship_surface_edge set in DerivedMapState with tiles that are on the boundary of the ship."
function find_ship_surface_edgetiles!(derivedmapstate::DerivedMapState, gamemap::GameMap)
    find_ship_surface_edgetiles!(derivedmapstate.ship_surface_edge, gamemap)
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
