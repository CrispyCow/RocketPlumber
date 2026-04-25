module FlowEngine

using HexFrame, HexElements, HexFluids, HexComponentsAPI
using FlowMap
import FlowMap: find_ship_surface_edgetiles!

using SparseArrays, LinearAlgebra, KLU, SmallCollections, StructEquality

# Type Exports
export DerivedMapState, MNA_State, MNA_StateSnapshot, AMatrixCache
export RelativeFluidDeclaration, AbsoluteFluidDeclaration, RelFluidDecl, AbsFluidDecl
# Function Exports
export add_pipes_abs_element!, abs_element_get_current, update_components!, index_grounded_source_elements!
export list_elements, list_elements!, list_nodes, list_nodes!, prune, ground_search, clear_dangling_dependants
export list_fluid_declarations!, push_mapped_declarations!, map_declaration
export index_fluid_declarations!, propagate_fluid_types!, compute_region_temperatures!
export prioritise_declarations, build_node_connection_map!
export MNA_indexnodes!, MNA_splitelements!, MNA_getA, MNA_getZ, MNA_getZ!, MNA_solve!
export MNA_updateA!, MNA_buildA_sparse
export MNA_stamp_A_ijv!, MNA_construct_A_sparse!, compute_A_hashes
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

# ===============================================================
# Fluid Declaration Wrapper Types
# ===============================================================

"A fluid declaration at a tile-local node position (parametric over declaration type)"
struct RelativeFluidDeclaration{T <: FluidDeclaration}
    node_pos::NodePos
    declaration::T
end

"A fluid declaration at a map-global node coordinate (parametric over declaration type)"
struct AbsoluteFluidDeclaration{T <: FluidDeclaration}
    node_coord::NodeCoord
    declaration::T
end

"isbitsunion alias for relative declarations (Vector storage without boxing)"
const RelFluidDecl = Union{
    RelativeFluidDeclaration{FluidSource},
    RelativeFluidDeclaration{FluidTypeRule},
    RelativeFluidDeclaration{FluidConstraintRule},
}

"isbitsunion alias for absolute declarations (Vector storage without boxing)"
const AbsFluidDecl = Union{
    AbsoluteFluidDeclaration{FluidSource},
    AbsoluteFluidDeclaration{FluidTypeRule},
    AbsoluteFluidDeclaration{FluidConstraintRule},
}

"Map a relative fluid declaration to absolute using tile position and rotation"
function map_declaration(decl::RelativeFluidDeclaration, tile::TileCoord, rotation::HexAxis)
    node_coord = map_element(decl.node_pos, tile, rotation)
    return AbsoluteFluidDeclaration(node_coord, decl.declaration)
end

"Holds characteristics which can be deterministically derived from the GameMap"
@kwdef mutable struct DerivedMapState
    ship_surface_edge::Set{TileCoord} = Set{TileCoord}()
    allelements::Vector{AbsoluteElement} = Vector{AbsoluteElement}()
    allnodes::Dict{NodeCoord, UInt16} = Dict{NodeCoord, UInt16}()
    prunedelements::Vector{AbsoluteElement} = Vector{AbsoluteElement}()
    grounded_source_element_index::Dict{NodeCoord, Int} = Dict{NodeCoord, Int}()
    prunednodes::Dict{NodeCoord, UInt16} = Dict{NodeCoord, UInt16}()
    nodeconnections::Dict{NodeCoord, ConnectionVect} = Dict{NodeCoord, ConnectionVect}()
    # Fluid declarations (collected from components)
    all_fluid_declarations::Vector{AbsFluidDecl} = Vector{AbsFluidDecl}()
    node_declarations::Dict{NodeCoord, FluidDeclaration} = Dict{NodeCoord, FluidDeclaration}()
    source_nodes::Set{NodeCoord} = Set{NodeCoord}()
    # Propagated fluid state
    nodeactualfluids::Dict{NodeCoord, FluidType} = Dict{NodeCoord, FluidType}()
    # Temperature and regions
    node_to_region::Dict{NodeCoord, Int} = Dict{NodeCoord, Int}()
    region_temperatures::Dict{Int, Float64} = Dict{Int, Float64}()
    node_temperatures::Dict{NodeCoord, Float64} = Dict{NodeCoord, Float64}()
end
@struct_hash_equal DerivedMapState

"""
Pre-allocated buffers and cached state for zero-allocation A matrix construction.

The A matrix is built each tick by stamping circuit elements into IJV vectors (I = row indices,
J = column indices, V = values), then converting to CSC sparse format via `SparseArrays.sparse!`
with fully pre-allocated work buffers. The `combine = +` argument handles multiple contributions
to the same matrix position (e.g., resistors sharing a node sum their conductances).

Structure and value change detection uses hashes computed from the IJV vectors:
- `structure_hash`: XOR of hash((I[k], J[k])) — detects topology changes (new/removed non-zeros)
- `value_hash`: hash of V vector — detects conductance/gain magnitude changes
"""
@kwdef mutable struct AMatrixCache
    # IJV stamp vectors (refilled each tick via empty! + push!)
    ijv_I::Vector{Int} = sizehint!(Int[], 256)
    ijv_J::Vector{Int} = sizehint!(Int[], 256)
    ijv_V::Vector{Float64} = sizehint!(Float64[], 256)
    # sparse! intermediate CSR buffers (pre-allocated, grown to high-water mark)
    klasttouch::Vector{Int} = Vector{Int}(undef, 1)      # length ≥ n
    csrrowptr::Vector{Int} = Vector{Int}(undef, 2)        # length ≥ m+1
    csrcolval::Vector{Int} = Vector{Int}(undef, 1)        # length ≥ max IJV entries
    csrnzval::Vector{Float64} = Vector{Float64}(undef, 1) # length ≥ max IJV entries
    # sparse! output CSC buffers — these ARE the sparse matrix's storage
    csccolptr::Vector{Int} = Vector{Int}(undef, 2)        # length = n+1
    cscrowval::Vector{Int} = Vector{Int}(undef, 1)        # length = nnz
    cscnzval::Vector{Float64} = Vector{Float64}(undef, 1) # length = nnz
    # The sparse A matrix (wraps the csc* vectors above — NOT independently allocated)
    mat_A_sparse::SparseMatrixCSC{Float64, Int64} = spzeros(1, 1)
    # KLU factorisation — circuit-simulation specialist from SuiteSparse.
    # WARNING: deepcopy of KLUFactorization shares C pointers (_symbolic, _numeric) and will double-free on GC, Do not copy!
    mat_A_lu::KLU.KLUFactorization{Float64, Int64} = klu(sparse([1], [1], [1.0]))
    # Two-tier cache hashes
    structure_hash::UInt64 = UInt64(0) # hash of IJV positions (I, J) — topology
    value_hash::UInt64 = UInt64(0)     # hash of IJV magnitudes (V) — conductances/gains
end
@struct_hash_equal AMatrixCache


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
    # A matrix construction cache (IJV + sparse! buffers + LU factorisation)
    a_cache::AMatrixCache = AMatrixCache()
    mat_Z::Matrix{Float64} = Matrix{Float64}(undef, 0, 0)
    mat_X::Matrix{Float64} = Matrix{Float64}(undef, 0, 0) # pre-allocated solve buffer for ldiv!
    # outputs
    node_voltages::Dict{NodeCoord, Float64} = Dict{NodeCoord, Float64}()
    vsource_currents::Dict{ElementID, Float64} = Dict{ElementID, Float64}()
    node_voltages_scaled::Dict{NodeCoord, Float64} = Dict{NodeCoord, Float64}()
end
@struct_hash_equal MNA_State

"Read-only subset of MNA_State for snapshot publishing. Excludes A-matrix cache, solve buffers, and index mappings."
@kwdef mutable struct MNA_StateSnapshot
    # Element lookups (included for logical completeness even if not all currently read on render thread)
    resistors::Dict{ElementID, AbsoluteElement} = Dict{ElementID, AbsoluteElement}()
    csources::Dict{ElementID, AbsoluteElement} = Dict{ElementID, AbsoluteElement}()
    vsources::Dict{ElementID, AbsoluteElement} = Dict{ElementID, AbsoluteElement}()
    vsource_lookup::Dict{ElementID, Int64} = Dict{ElementID, Int64}()
    # Outputs
    node_voltages::Dict{NodeCoord, Float64} = Dict{NodeCoord, Float64}()
    vsource_currents::Dict{ElementID, Float64} = Dict{ElementID, Float64}()
    node_voltages_scaled::Dict{NodeCoord, Float64} = Dict{NodeCoord, Float64}()
end

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

"Return the non-ground endpoint of a singly grounded element, or `nothing` otherwise."
function grounded_element_node(element::AbsoluteElement)::Union{NodeCoord, Nothing}
    v1 = element.connections.v1
    v2 = element.connections.v2

    if is_grounded(v1)
        return is_grounded(v2) ? nothing : v2
    end

    return is_grounded(v2) ? v1 : nothing
end

function add_pipes_abs_element!(abs_vector::Vector{AbsoluteElement}, edge::EdgeCoord, conductance::Float64)
    connections = AbsoluteElementConnections(to_nodecoord(edge.v1), to_nodecoord(edge.v2))
    absolute_element = AbsoluteElement(connections, conductance, CONST_RESISTOR, ElementID(edge))
    return push!(abs_vector, absolute_element)
end

"Updates behaviors of all components on a single ShipMap"
function update_components!(ship::ShipMap, mna_state::MNA_State, derivedmapstate::DerivedMapState)
    for (coord, data) in ship.components
        update_flowbehav!(data; tile = coord, mna_state = mna_state, derivedmapstate = derivedmapstate)
    end
    return nothing
end

"Updates behaviors of all components on the GameMap by delegating to each ShipMap"
function update_components!(gamemap::GameMap, mna_state::MNA_State, derivedmapstate::DerivedMapState)
    for (_, ship) in gamemap.ships
        update_components!(ship, mna_state, derivedmapstate)
    end
    return nothing
end

"Push mapped absolute elements from a ComponentOnTile directly into the output vector, bypassing ntuple allocation."
function push_mapped_elements!(out::Vector{AbsoluteElement}, tilecomp::ComponentOnTile, tile::TileCoord)
    rel_elements = produce_rel_elements(tilecomp.component)
    rot = tilecomp.rotation
    i = 1
    for rel in rel_elements
        abs_elem = map_element(rel, tile, i, rot)
        abs_elem.active && push!(out, abs_elem)
        i += 1
    end
    return nothing
end

"Push the single pipe resistor element directly into the output vector."
function push_pipe_element!(out::Vector{AbsoluteElement}, pipe_behav::PipeBehavior, edge::EdgeCoord)
    connections = AbsoluteElementConnections(to_nodecoord(edge.v1), to_nodecoord(edge.v2))
    conductance = get_conductance(pipe_behav)
    push!(out, AbsoluteElement(connections, conductance, CONST_RESISTOR, ElementID(edge)))
    return nothing
end

"Collect all electrical elements for a single ship into `out` (appends, caller should empty! first)."
function list_elements!(out::Vector{AbsoluteElement}, ship::ShipMap)
    for (coord, data) in ship.components
        push_mapped_elements!(out, data, coord)
    end
    for (edge, pipe_behav) in ship.pipe_behaviors
        push_pipe_element!(out, pipe_behav, edge)
    end
    return nothing
end

"Collect all electrical elements in the GameMap into `out` (empties first, then fills)."
function list_elements!(out::Vector{AbsoluteElement}, gamemap::GameMap)
    empty!(out)
    sizehint!(out, 16)

    for (_, ship) in gamemap.ships
        list_elements!(out, ship)
    end

    return nothing
end

"List all electrical elements for a single ship (allocating convenience wrapper)."
function list_elements(ship::ShipMap)
    elements_present = Vector{AbsoluteElement}()
    tiles = ship.components
    pipe_behaviors = ship.pipe_behaviors
    sizehint!(elements_present, (length(tiles) + length(pipe_behaviors)) * 2)
    list_elements!(elements_present, ship)
    return elements_present
end

"List all electrical elements in the GameMap (allocating convenience wrapper)."
function list_elements(gamemap::GameMap)
    all_elements = Vector{AbsoluteElement}()
    list_elements!(all_elements, gamemap)
    return all_elements
end

"Populate `node_count` with connection counts per non-ground node (empties first)."
function list_nodes!(node_count::Dict{NodeCoord, UInt16}, elements::Vector{AbsoluteElement})
    empty!(node_count)
    sizehint!(node_count, length(elements))

    for element in elements
        node1 = element.connections.v1
        if !is_grounded(node1)
            add_or_increment!(node_count, node1)
        end
        node2 = element.connections.v2
        if !is_grounded(node2)
            add_or_increment!(node_count, node2)
        end
    end

    return nothing
end

"List all nodes connected to an element (allocating convenience wrapper)."
function list_nodes(elements::Vector{AbsoluteElement})
    node_count = Dict{NodeCoord, UInt16}()
    list_nodes!(node_count, elements)
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

"""
Performs graph traversal across all elements, starting from grounded elements to
exclude elements not connected to ground. Current sources (CONST_CURRENT,
C_DEP_CURRENT) are excluded from the traversal graph because they do not provide
voltage references — a node connected to ground solely through current sources has
undetermined voltage, causing MNA singularity.

Current sources whose non-ground nodes are reachable through other elements are
still included in the output (they are valid circuit elements when their nodes
have determined voltages from other paths).

Returns elements that are reachable from ground through voltage-reference-capable
paths, plus current sources whose nodes are coincidentally reachable.
"""
function ground_search(elements::Vector{AbsoluteElement})
    node_elements = Dict{NodeCoord, MutableSmallVector{10, UInt16}}()
    sizehint!(node_elements, length(elements))

    for (index, element) in enumerate(elements)
        # skip zero-conductance resistors (no voltage/current contribution)
        if element.type == CONST_RESISTOR && element.value == 0.0
            continue
        end

        # skip current sources — they don't provide voltage references
        if element.type == CONST_CURRENT || element.type == C_DEP_CURRENT
            continue
        end

        # register non-ground nodes for traversal
        for i in 1:2
            node = getfield(element.connections, i)
            # if the node is not grounded, then it can be used to find other elements
            if !is_grounded(node)
                if !haskey(node_elements, node)
                    node_elements[node] = MutableSmallVector{10, UInt16}()
                end
                push!(node_elements[node], UInt16(index))
            end
        end
    end

    #= ---------- BFS from grounded non-current elements ---------- =#
    grounded_elements = Set{UInt16}(
        UInt16(index) for (index, elem) in enumerate(elements)
        if is_grounded(elem.connections.v2)
           && elem.type != CONST_CURRENT
           && elem.type != C_DEP_CURRENT
    )
    to_visit = Set{UInt16}()
    visited = Set{UInt16}()
    sizehint!(visited, length(elements))

    while !isempty(grounded_elements)
        # start at grounded element that hasn't been visited yet
        grounded_element = pop!(grounded_elements)
        grounded_element ∈ visited && continue
        push!(to_visit, grounded_element)

        while !isempty(to_visit)
            current = pop!(to_visit)
            push!(visited, current)

            for i in 1:2
                node = getfield(elements[current].connections, i)
                if !is_grounded(node)
                    connected_elements = get(node_elements, node, nothing)
                    connected_elements === nothing && continue
                    for element in connected_elements
                        element ∉ visited && push!(to_visit, element)
                    end
                end
            end
        end
    end

    #= ---------- Collect visited nodes ---------- =#
    visited_nodes = Set{NodeCoord}()
    sizehint!(visited_nodes, length(visited) * 2)
    for idx in visited
        for i in 1:2
            node = getfield(elements[idx].connections, i)
            is_grounded(node) || push!(visited_nodes, node)
        end
    end

    #= ---------- Include current sources whose nodes are all reachable ---------- =#
    for (index, element) in enumerate(elements)
        uidx = UInt16(index)
        uidx ∈ visited && continue # already included
        (element.type == CONST_CURRENT || element.type == C_DEP_CURRENT) || continue

        all_visited = true
        for i in 1:2
            node = getfield(element.connections, i)
            if !is_grounded(node) && node ∉ visited_nodes
                all_visited = false
                break
            end
        end
        all_visited && push!(visited, uidx)
    end

    return elements[sort!(collect(visited))]
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

    # Check dependent elements repeatedly until no change is made (fixed-point).
    # We iterate over the original `elements` each pass, skipping any whose ID was
    # already removed from element_IDs in a prior pass.
    changed = true
    while changed
        changed = false
        empty!(final_elements)

        for element in elements
            # skip elements already removed in a prior pass
            element.id in element_IDs || continue

            push!(final_elements, element)

            # elements with no dependent can always stay
            if element.dependent_id.index == 0
                continue
            end

            # dependent element must have its dependency present
            if !(element.dependent_id in element_IDs)
                pop!(final_elements)
                delete!(element_IDs, element.id) # remove our own ID so dependants of us are also cleared
                changed = true
            end
        end
    end

    return final_elements
end

"Returns the current through an absolute element, or nothing if element was pruned"
function abs_element_get_current(element::AbsoluteElement, derivedmapstate::DerivedMapState, mna_state::Union{MNA_State, MNA_StateSnapshot})
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
        volt1 = is_grounded(element.connections.v1) ? 0.0 : mna_state.node_voltages[element.connections.v1]
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

# ===============================================================
# Fluid Declaration Collection and Propagation
# ===============================================================

"Push mapped declarations from a single component"
function push_mapped_declarations!(out::Vector{AbsFluidDecl}, tilecomp::ComponentOnTile, tile::TileCoord)
    rel_decls = produce_rel_fluid_declarations(tilecomp.component)
    rot = tilecomp.rotation
    for rel in rel_decls
        push!(out, map_declaration(rel, tile, rot))
    end
    return nothing
end

"Collect all fluid declarations from a single ship"
function list_fluid_declarations!(out::Vector{AbsFluidDecl}, ship::ShipMap)
    for (coord, data) in ship.components
        push_mapped_declarations!(out, data, coord)
    end
end

"Collect all fluid declarations from all ships"
function list_fluid_declarations!(out::Vector{AbsFluidDecl}, gamemap::GameMap)
    empty!(out)
    sizehint!(out, 16)
    for ship_name in get_all_ship_names(gamemap)
        list_fluid_declarations!(out, get_ship(gamemap, ship_name))
    end
end

"""
Resolve two declarations on the same node. Priority: FluidSource > FluidTypeRule > FluidConstraintRule.
Throws on incompatible declarations.
"""
function prioritise_declarations(existing::FluidDeclaration, incoming::FluidDeclaration)
    # FluidSource wins over everything
    if incoming isa FluidSource
        _check_compatible(existing, incoming.fluid_type)
        return incoming
    elseif existing isa FluidSource
        _check_compatible(incoming, existing.fluid_type)
        return existing
    end
    # FluidTypeRule wins over FluidConstraintRule
    if incoming isa FluidTypeRule
        _check_compatible(existing, incoming.fluid_type)
        return incoming
    elseif existing isa FluidTypeRule
        _check_compatible(incoming, existing.fluid_type)
        return existing
    end

    # Current constraints are mutually exclusive one-hot enums. If future work adds
    # overlapping constraints, this branch may need intersection semantics instead.
    existing.constraint === incoming.constraint ||
        error("Conflicting fluid constraints: $(existing.constraint) vs $(incoming.constraint)")

    return incoming
end

"Check that a declaration is compatible with a concrete fluid type"
function _check_compatible(decl::FluidDeclaration, fluid::FluidType)
    if decl isa FluidSource
        decl.fluid_type === fluid || error("Conflicting fluid sources: $(decl.fluid_type) vs $(fluid)")
    elseif decl isa FluidTypeRule
        decl.fluid_type === fluid || error("FluidTypeRule $(decl.fluid_type) incompatible with $(fluid)")
    elseif decl isa FluidConstraintRule
        check_constraint(fluid, decl.constraint) || error("Fluid $(fluid) does not satisfy constraint $(decl.constraint)")
    end
    return nothing
end

"Build per-node declaration index and source node set from collected declarations"
function index_fluid_declarations!(derivedmapstate::DerivedMapState)
    node_decls = derivedmapstate.node_declarations
    source_nodes = derivedmapstate.source_nodes
    empty!(node_decls)
    empty!(source_nodes)

    for abs_decl in derivedmapstate.all_fluid_declarations
        node = abs_decl.node_coord
        # Only index nodes that survived pruning
        haskey(derivedmapstate.prunednodes, node) || continue

        decl = abs_decl.declaration
        existing = get(node_decls, node, nothing)
        if existing === nothing
            node_decls[node] = decl
        else
            node_decls[node] = prioritise_declarations(existing, decl)
        end

        if decl isa FluidSource
            push!(source_nodes, node)
        end
    end
end

"Check that a declaration at a traversed node is compatible with the region's fluid type"
function _check_declaration_compatible(decl::FluidDeclaration, fluid_type::FluidType)
    if decl isa FluidConstraintRule
        check_constraint(fluid_type, decl.constraint) || error("Fluid $(fluid_type) incompatible with constraint $(decl.constraint)")
    elseif decl isa FluidTypeRule
        decl.fluid_type === fluid_type || error("FluidTypeRule $(decl.fluid_type) conflicts with region fluid $(fluid_type)")
    elseif decl isa FluidSource
        decl.fluid_type === fluid_type || error("FluidSource $(decl.fluid_type) conflicts with region fluid $(fluid_type)")
    end
    return nothing
end

"Fallback temperature when a region has no active flow"
function _fallback_temperature(fluid::FluidType)::Float64
    temp = get_default_temperature(Val(fluid))
    return temp !== nothing ? temp : 300.0
end

"Index singly grounded pruned elements by their non-ground node for O(1) source lookup."
function index_grounded_source_elements!(derivedmapstate::DerivedMapState)
    source_index = derivedmapstate.grounded_source_element_index
    empty!(source_index)

    for (index, element) in pairs(derivedmapstate.prunedelements)
        node = grounded_element_node(element)
        node === nothing && continue
        get!(source_index, node, index)
    end

    return nothing
end

"Traverse from source nodes to assign fluid types and build regions. No MNA needed."
function propagate_fluid_types!(derivedmapstate::DerivedMapState)
    nodeconnections = derivedmapstate.nodeconnections
    actualfluids    = derivedmapstate.nodeactualfluids
    node_to_region  = derivedmapstate.node_to_region
    node_decls      = derivedmapstate.node_declarations
    source_nodes    = derivedmapstate.source_nodes

    empty!(actualfluids)
    empty!(node_to_region)

    visited = Set{NodeCoord}()
    region_id = 0

    for start_node in source_nodes
        start_node in visited && continue
        start_decl = node_decls[start_node]::FluidSource
        fluid_type = start_decl.fluid_type

        region_id += 1
        pending_nodes = NodeCoord[start_node]

        while !isempty(pending_nodes)
            current = pop!(pending_nodes)
            current in visited && continue
            push!(visited, current)

            # Check declaration compatibility at this node
            decl = get(node_decls, current, nothing)
            if decl !== nothing
                _check_declaration_compatible(decl, fluid_type)
            end

            actualfluids[current] = fluid_type
            node_to_region[current] = region_id

            for neighbour in get(nodeconnections, current, ConnectionVect())
                neighbour in visited || push!(pending_nodes, neighbour)
            end
        end
    end
    return nothing
end

"Get the MNA current magnitude through the grounded element at a source node"
function _get_source_flow_rate(node::NodeCoord, derivedmapstate::DerivedMapState, mna_state)
    element_index = get(derivedmapstate.grounded_source_element_index, node, 0)
    element_index == 0 && return 0.0

    element = derivedmapstate.prunedelements[element_index]
    current = abs_element_get_current(element, derivedmapstate, mna_state)
    return current === nothing ? 0.0 : abs(current)
end

"Compute per-region temperatures using flow-weighted averages. Requires solved MNA state."
function compute_region_temperatures!(derivedmapstate::DerivedMapState, mna_state)
    region_temps = derivedmapstate.region_temperatures
    node_temps   = derivedmapstate.node_temperatures
    node_to_region = derivedmapstate.node_to_region

    empty!(region_temps)
    empty!(node_temps)

    # Collect per-region flow-weighted temperature sums
    region_weighted_temp = Dict{Int, Float64}()
    region_total_flow    = Dict{Int, Float64}()
    region_fluid_type    = Dict{Int, FluidType}()

    for abs_decl in derivedmapstate.all_fluid_declarations
        abs_decl.declaration isa FluidSource || continue
        node = abs_decl.node_coord
        rid = get(node_to_region, node, 0)
        rid == 0 && continue

        source = abs_decl.declaration::FluidSource
        region_fluid_type[rid] = source.fluid_type

        flow = _get_source_flow_rate(node, derivedmapstate, mna_state)
        if flow > 0.0
            region_weighted_temp[rid] = get(region_weighted_temp, rid, 0.0) + flow * source.temperature
            region_total_flow[rid]    = get(region_total_flow, rid, 0.0) + flow
        end
    end

    # Compute final temperatures and assign to nodes
    for (rid, fluid) in region_fluid_type
        total_flow = get(region_total_flow, rid, 0.0)
        if total_flow > 0.0
            region_temps[rid] = region_weighted_temp[rid] / total_flow
        else
            region_temps[rid] = _fallback_temperature(fluid)
        end
    end

    for (node, rid) in node_to_region
        node_temps[node] = region_temps[rid]
    end
    return nothing
end

"Populate `mna_state` node index lookups from pruned nodes (empties and refills existing dicts)."
function MNA_indexnodes!(mna_state::MNA_State, derivedmapstate::DerivedMapState)
    nodes = derivedmapstate.prunednodes

    num_nodes = length(nodes)
    node_to_index = mna_state.node_to_index
    index_to_node = mna_state.index_to_node
    empty!(node_to_index)
    empty!(index_to_node)
    sizehint!(node_to_index, num_nodes)
    sizehint!(index_to_node, num_nodes)

    i = 1
    for (node, _) in nodes
        node_to_index[node] = i
        index_to_node[i] = node
        i += 1
    end

    return nothing
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

#= ---------- IJV-Based A Matrix Construction ----------- =#

"""
Stamp all circuit element contributions into the A matrix's IJV vectors.

Clears the IJV vectors and re-stamps all elements from the current MNA state. The resulting
I, J, V vectors represent the full A = [G B; C D] matrix in coordinate (COO) format, ready
for conversion to CSC via `sparse!`. Uses matrix names and algorithms from
https://qucs.sourceforge.net/tech/node14.html

Duplicate (i,j) entries are expected and intentional — `sparse!` combines them via `+`.
For example, multiple resistors connected to the same node each stamp their conductance
at the diagonal, and the addition happens during CSC construction.
"""
function MNA_stamp_A_ijv!(mna_state::MNA_State)
    cache = mna_state.a_cache
    I = cache.ijv_I; J = cache.ijv_J; V = cache.ijv_V
    empty!(I); empty!(J); empty!(V)

    node_to_index = mna_state.node_to_index
    vsource_lookup = mna_state.vsource_lookup
    num_nodes = length(node_to_index)

    # Inline stamp helper — pushes one (row, col, value) triple to the IJV vectors
    stamp!(i, j, v) = (push!(I, i); push!(J, j); push!(V, v))

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
    for element in values(mna_state.resistors)
        conductance = element.value
        v1_index = node_to_index[element.connections.v1]

        # v1 will always show up on the diagonal
        stamp!(v1_index, v1_index, conductance)

        # v2 contributes to diagonal and off-diagonal if not grounded
        if !is_grounded(element.connections.v2)
            v2_index = node_to_index[element.connections.v2]
            stamp!(v2_index, v2_index, conductance)
            stamp!(v1_index, v2_index, -conductance)
            stamp!(v2_index, v1_index, -conductance)
        end
    end

    #=
    The pure B matrix (not considering dependent sources) is an N×M 
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
    for (id, element) in mna_state.vsources
        vs_col = num_nodes + vsource_lookup[id] # B columns offset past G

        # v1 contributes +1
        v1_index = node_to_index[element.connections.v1]
        stamp!(v1_index, vs_col, 1.0)

        # v2 contributes -1 if not grounded
        if !is_grounded(element.connections.v2)
            v2_index = node_to_index[element.connections.v2]
            stamp!(v2_index, vs_col, -1.0)
        end
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
    for (_id, element) in mna_state.csources
        if element.type == C_DEP_CURRENT
            dep_element_id = element.dependent_id

            if !haskey(vsource_lookup, dep_element_id)
                error("Dependent current source depends on a source that is not in the MNA vsource lookup")
            end

            dep_col = num_nodes + vsource_lookup[dep_element_id]

            pos_dep_node = element.connections.v1
            neg_dep_node = element.connections.v2

            # set vsource positive node to +gain (never grounded, can assume not pruned)
            pos_node_index = node_to_index[pos_dep_node]
            stamp!(pos_node_index, dep_col, element.value)

            # set the vsource negative node to -gain if it is not grounded
            if !is_grounded(neg_dep_node)
                neg_node_index = node_to_index[neg_dep_node]
                stamp!(neg_node_index, dep_col, -(element.value))
            end
        end
    end

    #=
    C matrix is the transpose of the B matrix, if there are no dependent sources.

    VCVS (V_DEP_VOLTAGE) are voltage sources dependent on the voltage across an element. The standard
    +1 and -1 entries of a vsource are brought over from the transposed pure B matrix. In the row
    corresponding to the voltage source, the C matrix has a +gain in the column corresponding to the
    dependent element's negative terminal node, and a -gain in the column corresponding to the dependent
    element's positive terminal node.
    =#
    # Pure C entries (transpose of pure B): +1/−1 mirroring the B block with rows and columns swapped.
    for (id, element) in mna_state.vsources
        vs_row = num_nodes + vsource_lookup[id] # C rows offset past G
        v1_index = node_to_index[element.connections.v1]
        stamp!(vs_row, v1_index, 1.0)
        if !is_grounded(element.connections.v2)
            v2_index = node_to_index[element.connections.v2]
            stamp!(vs_row, v2_index, -1.0)
        end
    end

    # VCVS contributions to C block
    for (id, element) in mna_state.vsources
        if element.type == V_DEP_VOLTAGE
            dep_element_id = element.dependent_id # get the element this VCVS depends on

            # VCVS can depend on any element type
            if haskey(mna_state.resistors, dep_element_id)
                dep_element = mna_state.resistors[dep_element_id]
            elseif haskey(mna_state.csources, dep_element_id)
                dep_element = mna_state.csources[dep_element_id]
            elseif haskey(mna_state.vsources, dep_element_id)
                dep_element = mna_state.vsources[dep_element_id]
            else
                error("VCVS depends on element that is not in the MNA")
            end

            vs_row = num_nodes + vsource_lookup[id]

            # set positive node v1 to -gain (never grounded, can assume not pruned)
            pos_dep_node = dep_element.connections.v1
            pos_node_index = node_to_index[pos_dep_node]
            stamp!(vs_row, pos_node_index, -(element.value))

            # set the negative node v2 to +gain if it is not grounded
            neg_dep_node = dep_element.connections.v2
            if !is_grounded(neg_dep_node)
                neg_node_index = node_to_index[neg_dep_node]
                stamp!(vs_row, neg_node_index, element.value)
            end
        end
    end

    #=
    The D matrix is an M×M matrix that is composed entirely of zeros. It can be non-zero if dependent
    sources are considered, however no implemented sources currently modify the D matrix.
    =#
    # D block: nothing to stamp (all zeros)

    return nothing
end

"""
Construct the sparse A matrix from the IJV vectors using `SparseArrays.sparse!`.

Uses fully pre-allocated work buffers from `AMatrixCache` to achieve zero allocations
when the matrix dimensions and nnz are stable. Work buffers are grown to their high-water
mark and never shrunk.

Must be called after `MNA_stamp_A_ijv!` has populated the IJV vectors.
"""
function MNA_construct_A_sparse!(mna_state::MNA_State)
    cache = mna_state.a_cache
    num_nodes = length(mna_state.node_to_index)
    num_vsources = length(mna_state.vsources)
    n = num_nodes + num_vsources  # A is n×n

    num_entries = length(cache.ijv_I)

    # Grow work buffers to high-water mark (amortised, rare after first few ticks)
    (length(cache.klasttouch) < n) && resize!(cache.klasttouch, n)
    (length(cache.csrrowptr) < n + 1) && resize!(cache.csrrowptr, n + 1)
    (length(cache.csrcolval) < num_entries) && resize!(cache.csrcolval, num_entries)
    (length(cache.csrnzval) < num_entries) && resize!(cache.csrnzval, num_entries)
    (length(cache.csccolptr) < n + 1) && resize!(cache.csccolptr, n + 1)
    # cscrowval/cscnzval sized to nnz (after combine) ≤ num_entries. sparse! will resize!
    # them to exact nnz — if nnz is stable across ticks, resize! is a no-op (zero-alloc).

    cache.mat_A_sparse = SparseArrays.sparse!(
        cache.ijv_I, cache.ijv_J, cache.ijv_V, n, n, +,
        cache.klasttouch,
        cache.csrrowptr, cache.csrcolval, cache.csrnzval,
        cache.csccolptr, cache.cscrowval, cache.cscnzval
    )

    return nothing
end

"""
Compute structure and value hashes from the IJV vectors.

Structure hash: XOR-combined hash of (I[k], J[k]) pairs. Detects topology changes (which matrix
positions have non-zero entries). Uses XOR for Dict iteration order independence.

Value hash: standard `hash()` over the V vector. Detects magnitude changes in conductances, gains,
and connectivity values.

Returns `(structure_hash, value_hash)`.
"""
function compute_A_hashes(cache::AMatrixCache)::Tuple{UInt64, UInt64}
    I = cache.ijv_I; J = cache.ijv_J; V = cache.ijv_V

    sh = UInt64(0)
    for k in eachindex(I, J)
        sh ⊻= hash((I[k], J[k]))
    end
    sh = hash(length(I), sh) # include entry count for extra safety

    vh = hash(V)

    return (sh, vh)
end

"""
Build the raw sparse A matrix from the current MNA state (without LU decomposition).
Convenience wrapper used by tests — stamps IJV and constructs sparse.
"""
function MNA_buildA_sparse(mna_state::MNA_State)::SparseMatrixCSC{Float64, Int64}
    MNA_stamp_A_ijv!(mna_state)
    MNA_construct_A_sparse!(mna_state)
    return mna_state.a_cache.mat_A_sparse
end

"Gets the A matrix in KLU-factorised form. Used by tests and diagnostics."
function MNA_getA(mna_state::MNA_State)
    return klu(MNA_buildA_sparse(mna_state))
end

"""
Update the A matrix and its KLU factorisation using the unified IJV → sparse! pipeline.

Each call stamps all elements into IJV vectors (zero-allocation), then applies three-tier caching:

1. **Structure changed** (different non-zero positions): full sparse construction + `klu()`
   factorisation — needs new symbolic analysis. This is the cold path.
2. **Values changed** (same positions, different magnitudes): sparse construction (zero-alloc) +
   `klu!()` in-place numeric refactorisation — reuses symbolic analysis, near-zero allocation.
3. **Nothing changed**: skip entirely — previous KLU factorisation is still valid.
"""
function MNA_updateA!(mna_state::MNA_State)
    # Stamp elements into IJV (zero-alloc after warmup)
    MNA_stamp_A_ijv!(mna_state)

    cache = mna_state.a_cache
    new_structure_hash, new_value_hash = compute_A_hashes(cache)

    if new_structure_hash != cache.structure_hash
        # Cold path: topology changed — full sparse rebuild + new KLU factorisation
        MNA_construct_A_sparse!(mna_state)
        cache.mat_A_lu = klu(cache.mat_A_sparse)
        cache.structure_hash = new_structure_hash
        cache.value_hash = new_value_hash

    elseif new_value_hash != cache.value_hash
        # Warm path: values changed — rebuild sparse (zero-alloc) + in-place numeric refactor
        MNA_construct_A_sparse!(mna_state)
        klu!(cache.mat_A_lu, nonzeros(cache.mat_A_sparse))
        cache.value_hash = new_value_hash

    end
    # else: nothing changed — skip entirely

    return nothing
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
    return vcat(I, E)
end

"""
In-place version of `MNA_getZ`. Stamps current and voltage source values directly into the
existing `mat_Z` vector, resizing only when the circuit dimension changes.

The Z vector is [I; E] where:
- I (rows 1:N): net current injected at each node from independent current sources
- E (rows N+1:N+M): independent voltage source set-points (zero for dependent sources)
"""
function MNA_getZ!(mna_state::MNA_State)
    num_nodes = length(mna_state.node_to_index)
    num_vsources = length(mna_state.vsources)
    required_length = num_nodes + num_vsources

    # Resize Z if circuit dimension changed (rare, only on topology change)
    if length(mna_state.mat_Z) != required_length
        mna_state.mat_Z = zeros(required_length, 1)
    else
        fill!(mna_state.mat_Z, 0.0)
    end

    Z = mna_state.mat_Z
    node_to_index = mna_state.node_to_index
    vsource_lookup = mna_state.vsource_lookup

    # I block (rows 1:N): sum of independent current sources at each node
    for element in values(mna_state.csources)
        element.type == CONST_CURRENT || continue
        current = element.value
        v1_index = node_to_index[element.connections.v1]
        Z[v1_index] += current
        if !is_grounded(element.connections.v2)
            v2_index = node_to_index[element.connections.v2]
            Z[v2_index] -= current
        end
    end

    # E block (rows N+1:N+M): voltage source set-points
    for (id, element) in mna_state.vsources
        vsource_index = num_nodes + vsource_lookup[id]
        Z[vsource_index] = is_dependant(element.type) ? 0.0 : element.value
    end

    return nothing
end

"Solve the MNA system in-place using `ldiv!`. Fills `mna_state` output dicts."
function MNA_solve!(mna_state::MNA_State)
    Z = mna_state.mat_Z
    A = mna_state.a_cache.mat_A_lu
    vsources = mna_state.vsources
    vsource_lookup = mna_state.vsource_lookup
    index_to_node = mna_state.index_to_node

    num_vsource = length(vsources)
    num_nodes = length(index_to_node)

    # Resize solve buffer if dimensions changed (topology change)
    X = mna_state.mat_X
    if size(X) != size(Z)
        mna_state.mat_X = similar(Z)
        X = mna_state.mat_X
    end

    #= The X matrix is the solution =#
    try
        ldiv!(X, A, Z)
    catch e
        @warn "MNA solve failed, returning zero solution" exception = e
        X .= 0.0
    end

    #=
    The V matrix is an N×1 matrix formed of the node voltages. Each element in v corresponds to the voltage
    at the equivalent node in the circuit (there is no entry for ground - node 0).
    =#
    V = @view X[1:num_nodes, 1]
    node_voltages = mna_state.node_voltages
    empty!(node_voltages)
    sizehint!(node_voltages, num_nodes)
    for (index, node) in index_to_node
        node_voltages[node] = V[index]
    end

    #=
    The J matrix is an M×1 matrix, with one entry for the current through each voltage source
    =#
    J = @view X[(num_nodes + 1):end, 1]
    vsource_currents = mna_state.vsource_currents
    empty!(vsource_currents)
    sizehint!(vsource_currents, num_vsource)
    for (id, index) in vsource_lookup
        vsource_currents[id] = J[index]
    end

    return nothing
end

end # module FlowEngine
