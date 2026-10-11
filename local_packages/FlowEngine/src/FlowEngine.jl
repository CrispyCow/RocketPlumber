#=
Scope: Derived circuit and fluid state construction, sparse MNA solving, and region temperatures
Formatter: Runic
=#

module FlowEngine

using HexFrame, HexElements, HexFluids, HexComponentsAPI
using FlowMap
import FlowMap: collect_surface_edge_tiles!

using SparseArrays, LinearAlgebra, KLU, SmallCollections, StructEquality

# Type Exports
export DerivedMapState, CalculatorScratchpad, MNA_State, MNA_StateSnapshot, AMatrixCache
export RelativeFluidDeclaration, AbsoluteFluidDeclaration, RelFluidDecl, AbsFluidDecl
export FluidCompatibilityError
# Function Exports
export add_pipes_abs_element!, abs_element_get_current, update_components!, index_grounded_source_elements!
export list_elements, list_elements!, list_nodes, list_nodes!, prune!, ground_search!, clear_dangling_dependants!
export filter_no_shrink!, clear_calculator_scratchpad!
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
const GROUND_NODE = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

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

"An expected rejection caused by incompatible fluid declarations or connected fluid regions."
struct FluidCompatibilityError <: ExpectedMapValidationError
    message::String
end

"Construct a fluid compatibility error from string-like input."
FluidCompatibilityError(message::AbstractString) = FluidCompatibilityError(String(message))

"Render the player-facing fluid compatibility explanation."
Base.showerror(io::IO, error::FluidCompatibilityError) = print(io, error.message)

"Map a relative fluid declaration to absolute using tile position, rotation, and mirroring."
function map_declaration(decl::RelativeFluidDeclaration, tile::TileCoord, rotation::HexAxis, mirrored::Bool = false)
    node_coord = map_element(decl.node_pos, tile, rotation, mirrored)
    return AbsoluteFluidDeclaration(node_coord, decl.declaration)
end

"Holds characteristics which can be deterministically derived from the GameMap"
@kwdef mutable struct DerivedMapState
    # All ship parts
    ship_surface_edge::Set{TileCoord} = Set{TileCoord}()
    primaryelements::Vector{AbsoluteElement} = Vector{AbsoluteElement}()   # base collected elements before filtering
    primarynodes::Dict{NodeCoord, UInt16} = Dict{NodeCoord, UInt16}()      # diagnostic node count from primary elements
    # Survivors filtered by pruning/grounding/dangling checks
    filteredelements::Vector{AbsoluteElement} = Vector{AbsoluteElement}()
    filterednodes::Dict{NodeCoord, UInt16} = Dict{NodeCoord, UInt16}()
    # Fluid declarations (collected from components)
    primary_fluid_declarations::Vector{AbsFluidDecl} = Vector{AbsFluidDecl}()
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

"Calculator-thread-only scratch buffers used during update_map! and not published in snapshots."
@kwdef mutable struct CalculatorScratchpad
    pruning_nodeconnections::Dict{NodeCoord, ConnectionVect} = Dict{NodeCoord, ConnectionVect}()
    groundsearch_root_index::Dict{NodeCoord, Int} = Dict{NodeCoord, Int}()
    groundsearch_nodeconnections::Dict{NodeCoord, ConnectionVect} = Dict{NodeCoord, ConnectionVect}()
    groundsearch_grounded_nodes::Set{NodeCoord} = Set{NodeCoord}()
    groundsearch_pending_nodes::Vector{NodeCoord} = Vector{NodeCoord}()
    dangling_dependant_element_id_set::Set{ElementID} = Set{ElementID}()
    filtered_source_element_index::Dict{NodeCoord, Int} = Dict{NodeCoord, Int}()  # grounded sources indexed by non-ground node
    final_nodeconnections::Dict{NodeCoord, ConnectionVect} = Dict{NodeCoord, ConnectionVect}()  # adjacency for fluid propagation
    fluid_propagation_visited::Set{NodeCoord} = Set{NodeCoord}()  # reusable visited-node buffer for propagate_fluid_types!
    fluid_propagation_pending::Vector{NodeCoord} = Vector{NodeCoord}()  # reusable DFS stack for propagate_fluid_types!
end

"Empty all scratch buffers in one call. Use at early-exit paths to leave the scratchpad in a clean state."
function clear_calculator_scratchpad!(scratchpad::CalculatorScratchpad)
    empty!(scratchpad.pruning_nodeconnections)
    empty!(scratchpad.groundsearch_root_index)
    empty!(scratchpad.groundsearch_nodeconnections)
    empty!(scratchpad.groundsearch_grounded_nodes)
    empty!(scratchpad.groundsearch_pending_nodes)
    empty!(scratchpad.dangling_dependant_element_id_set)
    empty!(scratchpad.filtered_source_element_index)
    empty!(scratchpad.final_nodeconnections)
    empty!(scratchpad.fluid_propagation_visited)
    empty!(scratchpad.fluid_propagation_pending)
    return nothing
end

"""
Pre-allocated buffers and cached state for zero-allocation A matrix construction.

The A matrix is built each tick by stamping circuit elements into IJV vectors (I = row indices,
J = column indices, V = values), then converting to CSC sparse format via `SparseArrays.sparse!`
with fully pre-allocated work buffers. The `combine = +` argument handles multiple contributions
to the same matrix position (e.g., resistors sharing a node sum their conductances).

The authoritative cache hashes are computed from the constructed CSC matrix, not the raw stamps:
- `structure_hash`: hash of CSC `colptr` and `rowval` — detects changes in stored matrix structure
- `value_hash`: hash of CSC `nzval` — detects magnitude changes while structure is unchanged
- `zero_state_hash`: hash of which CSC stored values are exactly zero — catches warm-path hazards
    where exact-zero transitions preserve CSC storage but invalidate numeric reuse
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
    # WARNING: deepcopy of KLUFactorization shares C pointers (_symbolic, _numeric) and will double-free on GC. Do not copy!
    mat_A_lu::KLU.KLUFactorization{Float64, Int64} = klu(sparse([1], [1], [1.0]))
    # CSC-based cache hashes
    structure_hash::UInt64 = UInt64(0)  # hash of CSC colptr/rowval — stored structure
    value_hash::UInt64 = UInt64(0)      # hash of CSC nzval — stored magnitudes
    zero_state_hash::UInt64 = UInt64(0) # hash of CSC exact-zero participation
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
    node_voltage_scale_max::Float64 = eps(Float64)
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

# ===============================================================
# Element Collection and Graph Filtering
# ===============================================================

"""
Filter a reusable vector in place, preserving order and backing capacity.
Mirrors the `Vector` implementation of `Base.filter!`, with shrinking disabled in the final size hint.
"""
function filter_no_shrink!(predicate, elements::Vector)
    destination = firstindex(elements)
    for element in elements
        @inbounds elements[destination] = element
        destination = ifelse(predicate(element)::Bool, nextind(elements, destination), destination)
    end
    destination > lastindex(elements) && return elements

    resize!(elements, destination - 1)
    sizehint!(elements, destination - 1; shrink = false)
    return elements
end

# DerivedMapState ship surface edge access
"Get all ship surface edge tile coordinates (tiles on the boundary of the ship)"
get_all_ship_edge_coords(derivedmapstate::DerivedMapState)::Set{TileCoord} = derivedmapstate.ship_surface_edge

"Get the number of ship surface edge tiles"
count_edge_tiles(derivedmapstate::DerivedMapState)::Int = length(derivedmapstate.ship_surface_edge)

"Update the ship_surface_edge set in DerivedMapState with boundary tiles from the surface owner index."
function collect_surface_edge_tiles!(derivedmapstate::DerivedMapState, gamemap::GameMap)
    collect_surface_edge_tiles!(derivedmapstate.ship_surface_edge, gamemap)
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

"Append the absolute resistor representation of a pipe span to `abs_vector`."
function add_pipes_abs_element!(abs_vector::Vector{AbsoluteElement}, coord::PipeCoord, conductance::Float64)
    connections = AbsoluteElementConnections(to_nodecoord(coord.v1), to_nodecoord(coord.v2))
    absolute_element = AbsoluteElement(connections, conductance, CONST_RESISTOR, ElementID(coord))
    return push!(abs_vector, absolute_element)
end

"""
Update behaviours of all components on the GameMap.
"""
function update_components!(gamemap::GameMap, mna_state::MNA_State, derivedmapstate::DerivedMapState)
    for (coord, comp) in gamemap.components
        updated = update_flowbehav(comp; tile = coord, mna_state, derivedmapstate)
        set_component!(gamemap, coord, updated)
    end
    return nothing
end

"Push active absolute elements from a PlacedComponent directly into the output vector."
function push_mapped_elements!(out::Vector{AbsoluteElement}, tilecomp::PlacedComponent, tile::TileCoord)
    for abs_elem in produce_abs_elements(tilecomp, tile)
        abs_elem.active && push!(out, abs_elem)
    end
    return nothing
end

"Push active absolute elements from a PlacedPipe directly into the output vector."
function push_pipe_element!(out::Vector{AbsoluteElement}, pipe::PlacedPipe, coord::PipeCoord)
    for abs_elem in produce_abs_elements(pipe, coord)
        abs_elem.active && push!(out, abs_elem)
    end
    return nothing
end

"""
Collect electrical elements in the GameMap into `out` (empties first, then fills).
If `ship_name` is provided, only elements belonging to that ship are included.
"""
function list_elements!(
        out::Vector{AbsoluteElement}, gamemap::GameMap;
        ship_name::Union{Symbol, Nothing} = nothing
    )
    empty!(out)
    sizehint!(out, length(gamemap.components) * 2 + length(gamemap.pipe_behaviors))
    for (coord, comp) in gamemap.components
        (isnothing(ship_name) || comp.ship === ship_name) || continue
        push_mapped_elements!(out, comp, coord)
    end
    for (edge, pipe) in gamemap.pipe_behaviors
        (isnothing(ship_name) || pipe.ship === ship_name) || continue
        push_pipe_element!(out, pipe, edge)
    end
    return nothing
end

"""
List all electrical elements in the GameMap (allocating convenience wrapper).
If `ship_name` is provided, only elements belonging to that ship are returned.
"""
function list_elements(gamemap::GameMap; ship_name::Union{Symbol, Nothing} = nothing)
    out = Vector{AbsoluteElement}()
    list_elements!(out, gamemap; ship_name = ship_name)
    return out
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

"Return `true` for all elements. Used as the default filter hook for graph builders."
_include_all_elements(::AbsoluteElement)::Bool = true

"Return `true` when every non-ground endpoint of `element` remains present in `present_nodes`."
function _all_non_ground_nodes_present(element::AbsoluteElement, present_nodes::AbstractSet)::Bool
    for i in 1:2
        node = getfield(element.connections, i)
        if !is_grounded(node) && node ∉ present_nodes
            return false
        end
    end
    return true
end

"Recursively remove a leaf node and any newly exposed leaf from `nodeconnections`."
function _prune_leaf_cascade!(nodeconnections::Dict{NodeCoord, ConnectionVect}, node::NodeCoord)
    haskey(nodeconnections, node) || return nothing
    connected_nodes = nodeconnections[node]
    length(connected_nodes) == 1 || return nothing

    connected_node = first(connected_nodes)

    delete!(nodeconnections, node)

    haskey(nodeconnections, connected_node) || return nothing

    updated_connections = filter(!=(node), nodeconnections[connected_node])
    nodeconnections[connected_node] = updated_connections

    if length(updated_connections) <= 1
        _prune_leaf_cascade!(nodeconnections, connected_node)
    end

    return nothing
end

"Prune dead branches in-place on `elements` using the cascade leaf-removal algorithm."
function prune!(elements::Vector{AbsoluteElement}, scratchpad::CalculatorScratchpad)::Nothing
    pruning_nodeconnections = scratchpad.pruning_nodeconnections

    build_node_connection_map!(
        pruning_nodeconnections,
        elements;
        include_ground_neighbour = true,
        # Prune degree counts incident elements, so parallel edges must stay distinct.
        deduplicate_neighbours = false,
    )

    # Restart the dictionary scan after each local cascade, because the cascade mutates the iterator
    while true
        leaf_node = nothing
        for (node, connected_nodes) in pruning_nodeconnections
            if length(connected_nodes) <= 1
                leaf_node = node
                break
            end
        end

        isnothing(leaf_node) && break

        if isempty(pruning_nodeconnections[leaf_node])
            delete!(pruning_nodeconnections, leaf_node)
        else
            _prune_leaf_cascade!(pruning_nodeconnections, leaf_node)
        end
    end

    present_nodes = keys(pruning_nodeconnections)
    filter_no_shrink!(element -> _all_non_ground_nodes_present(element, present_nodes), elements)

    empty!(pruning_nodeconnections)

    return nothing
end

"""
Fill `nodeconnections` with node-to-node adjacency derived from `elements`.

By default this preserves the existing fluid-propagation behaviour by excluding
grounded elements entirely.

NOTE: This function uses small vectors in the hot loop to avoid allocation for each node.
There is actually a finite set of nodes that could be connected to each node (12) so this
can be significantly optimized by using a SmallBitSet indexing those 12 possibilities. This
could drop the size in memory of a ConnectionVect from 74 bytes to 2 bytes, which will reduce the
copy overhead on the pushes to immutable types, and would reduce memory usage of nodeconnections.
"""
function build_node_connection_map!(
        nodeconnections::Dict{NodeCoord, ConnectionVect},
        elements::Vector{AbsoluteElement};
        element_filter_function::Function = _include_all_elements,
        include_ground_neighbour::Bool = false,
        deduplicate_neighbours::Bool = true,
    )

    empty!(nodeconnections)

    for element in elements
        element_filter_function(element) || continue

        v1 = element.connections.v1
        v2 = element.connections.v2

        if !is_grounded(v1)
            neighbour = is_grounded(v2) ? GROUND_NODE : v2
            if include_ground_neighbour || neighbour != GROUND_NODE
                old_connections = get(nodeconnections, v1, ConnectionVect())
                if !deduplicate_neighbours || neighbour ∉ old_connections
                    nodeconnections[v1] = push(old_connections, neighbour)
                end
            end
        end

        if !is_grounded(v2)
            neighbour = is_grounded(v1) ? GROUND_NODE : v1
            if include_ground_neighbour || neighbour != GROUND_NODE
                old_connections = get(nodeconnections, v2, ConnectionVect())
                if !deduplicate_neighbours || neighbour ∉ old_connections
                    nodeconnections[v2] = push(old_connections, neighbour)
                end
            end
        end
    end
    return nothing
end

"Return `true` for elements that can propagate a ground reference through the graph search."
_include_ground_search_connection_element(element::AbsoluteElement)::Bool =
    element.type != CONST_CURRENT &&
    element.type != C_DEP_CURRENT &&
    !(element.type == CONST_RESISTOR && element.value == 0.0) &&
    !is_grounded(element.connections.v1) &&
    !is_grounded(element.connections.v2)

"Return `true` for grounded elements that can seed the ground reachability search."
_include_ground_search_root_element(element::AbsoluteElement)::Bool =
    !isnothing(grounded_element_node(element)) &&
    element.type != CONST_CURRENT &&
    element.type != C_DEP_CURRENT &&
    !(element.type == CONST_RESISTOR && element.value == 0.0)

"""
Mutate `elements` vector to keep only elements that are grounded-reachable.

Performs graph traversal across node connection map, starting from grounded elements to
exclude elements not connected to ground. Current sources (CONST_CURRENT,
C_DEP_CURRENT) are excluded from the connection map because they do not provide
voltage references. A node connected to ground solely through current sources has
undetermined voltage, causing MNA singularity. 

This behaviour is captured in _include_ground_search_connection_element

Current sources whose non-ground nodes are reachable through other elements are
still included in the output (they are valid circuit elements when their nodes
have determined voltages from other paths).

This behaviour is captured in _include_ground_search_root_element
"""
function ground_search!(elements::Vector{AbsoluteElement}, scratchpad::CalculatorScratchpad)::Nothing
    groundsearch_nodeconnections = scratchpad.groundsearch_nodeconnections
    root_index = scratchpad.groundsearch_root_index
    groundsearch_grounded_nodes = scratchpad.groundsearch_grounded_nodes
    pending_nodes = scratchpad.groundsearch_pending_nodes

    build_node_connection_map!(
        groundsearch_nodeconnections, elements;
        element_filter_function = _include_ground_search_connection_element,
    )
    index_grounded_source_elements!(
        root_index, elements;
        element_filter_function = _include_ground_search_root_element,
    )

    empty!(groundsearch_grounded_nodes)
    empty!(pending_nodes)

    for node in keys(root_index)
        node ∈ groundsearch_grounded_nodes && continue
        push!(pending_nodes, node)

        while !isempty(pending_nodes)
            current = pop!(pending_nodes)
            current ∈ groundsearch_grounded_nodes && continue
            push!(groundsearch_grounded_nodes, current)

            connected_nodes = get(groundsearch_nodeconnections, current, nothing)
            isnothing(connected_nodes) && continue
            for neighbour in connected_nodes
                neighbour ∈ groundsearch_grounded_nodes || push!(pending_nodes, neighbour)
            end
        end
    end

    filter_no_shrink!(element -> _all_non_ground_nodes_present(element, groundsearch_grounded_nodes), elements)

    empty!(groundsearch_nodeconnections)
    empty!(root_index)
    empty!(groundsearch_grounded_nodes)
    empty!(pending_nodes)

    return nothing
end

"""
Removes dependant elements whose controlling element has been pruned, mutating `elements` in place.

`element_id_set` is a caller-owned scratch buffer (typically
`scratchpad.dangling_dependant_element_id_set` from `CalculatorScratchpad`);
it is filled, used for fixed-point iteration, then emptied before this function returns.

If this function removes any elements, the caller should rerun prune and the ground-search pass.
"""
function clear_dangling_dependants!(elements::Vector{AbsoluteElement}, element_id_set::Set{ElementID})::Nothing
    # Refill the reusable ID set from the current survivor list.
    empty!(element_id_set)
    sizehint!(element_id_set, length(elements); shrink = false)  # grow-only: avoids shrink+regrow allocation cycles
    for element in elements
        push!(element_id_set, element.id)
    end

    # Repeatedly scan the vector, removing dependants whose controller ID has already been deleted from the set.
    changed = true
    while changed
        changed = false
        for element in elements
            element.id in element_id_set || continue  # already removed in a prior pass
            element.dependent_id.index == 0 && continue  # no controller needed

            if !(element.dependent_id in element_id_set)
                delete!(element_id_set, element.id)  # cascades to our own dependants
                changed = true
            end
        end
    end

    # Compact the vector in place, keep only elements still in the survivor set.
    filter_no_shrink!(element -> element.id in element_id_set, elements)

    empty!(element_id_set)  # leave the scratch buffer clean for the next call

    return nothing
end

"Returns the current through an absolute element, or nothing if element was pruned"
function abs_element_get_current(element::AbsoluteElement, derivedmapstate::DerivedMapState, mna_state::Union{MNA_State, MNA_StateSnapshot})
    if !(element in derivedmapstate.filteredelements)
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
function push_mapped_declarations!(out::Vector{AbsFluidDecl}, tilecomp::PlacedComponent, tile::TileCoord)
    rel_decls = produce_rel_fluid_declarations(tilecomp.component)
    rot = tilecomp.rotation
    mirrored = tilecomp.mirrored
    for rel in rel_decls
        push!(out, map_declaration(rel, tile, rot, mirrored))
    end
    return nothing
end

"""
Collect all fluid declarations from the GameMap.
"""
function list_fluid_declarations!(out::Vector{AbsFluidDecl}, gamemap::GameMap)
    empty!(out)
    sizehint!(out, 16)
    for (coord, comp) in gamemap.components
        push_mapped_declarations!(out, comp, coord)
    end
    return nothing
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
        throw(FluidCompatibilityError("Conflicting fluid constraints: $(existing.constraint) vs $(incoming.constraint)"))

    return incoming
end

"Check that a declaration is compatible with a concrete fluid type"
function _check_compatible(decl::FluidDeclaration, fluid::FluidType)
    if decl isa FluidSource
        decl.fluid_type === fluid || throw(FluidCompatibilityError("Conflicting fluid sources: $(decl.fluid_type) vs $(fluid)"))
    elseif decl isa FluidTypeRule
        decl.fluid_type === fluid || throw(FluidCompatibilityError("FluidTypeRule $(decl.fluid_type) incompatible with $(fluid)"))
    elseif decl isa FluidConstraintRule
        check_constraint(fluid, decl.constraint) || throw(
            FluidCompatibilityError("Fluid $(fluid) does not satisfy constraint $(decl.constraint)"),
        )
    end
    return nothing
end

"Build per-node declaration index and source node set."
function index_fluid_declarations!(derivedmapstate::DerivedMapState, declarations::AbstractVector{<:AbsFluidDecl})
    node_decls = derivedmapstate.node_declarations
    source_nodes = derivedmapstate.source_nodes
    empty!(node_decls)
    empty!(source_nodes)

    for abs_decl in declarations
        node = abs_decl.node_coord
        # Only index nodes that survived filtering
        haskey(derivedmapstate.filterednodes, node) || continue

        decl = abs_decl.declaration
        existing = get(node_decls, node, nothing)
        if isnothing(existing)
            node_decls[node] = decl
        else
            node_decls[node] = prioritise_declarations(existing, decl)
        end

        if decl isa FluidSource
            push!(source_nodes, node)
        end
    end
    return nothing
end

"Check that a declaration at a traversed node is compatible with the region's fluid type"
function _check_declaration_compatible(decl::FluidDeclaration, fluid_type::FluidType)
    if decl isa FluidConstraintRule
        check_constraint(fluid_type, decl.constraint) || throw(
            FluidCompatibilityError("Fluid $(fluid_type) incompatible with constraint $(decl.constraint)"),
        )
    elseif decl isa FluidTypeRule
        decl.fluid_type === fluid_type || throw(
            FluidCompatibilityError("FluidTypeRule $(decl.fluid_type) conflicts with region fluid $(fluid_type)"),
        )
    elseif decl isa FluidSource
        decl.fluid_type === fluid_type || throw(
            FluidCompatibilityError("FluidSource $(decl.fluid_type) conflicts with region fluid $(fluid_type)"),
        )
    end
    return nothing
end

"Fallback temperature when a region has no active flow"
function _fallback_temperature(fluid::FluidType)::Float64
    return get_default_temperature(fluid, THERMAL_AMBIENT_TEMPERATURE_K)
end

"Index singly grounded elements by their non-ground node for O(1) source lookup."
function index_grounded_source_elements!(
        source_index::Dict{NodeCoord, Int},
        elements::Vector{AbsoluteElement};
        element_filter_function::Function = _include_all_elements,
    )

    empty!(source_index)

    for (index, element) in pairs(elements)
        element_filter_function(element) || continue
        node = grounded_element_node(element)
        isnothing(node) && continue
        get!(source_index, node, index)
    end

    return nothing
end

"Traverse from source nodes to assign fluid types and build regions. No MNA needed."
function propagate_fluid_types!(derivedmapstate::DerivedMapState, scratchpad::CalculatorScratchpad)
    nodeconnections = scratchpad.final_nodeconnections
    actualfluids = derivedmapstate.nodeactualfluids
    node_to_region = derivedmapstate.node_to_region
    node_decls = derivedmapstate.node_declarations
    source_nodes = derivedmapstate.source_nodes
    visited = scratchpad.fluid_propagation_visited
    pending_nodes = scratchpad.fluid_propagation_pending

    empty!(actualfluids)
    empty!(node_to_region)
    empty!(visited)

    region_id = 0

    for start_node in source_nodes
        start_node in visited && continue
        start_decl = node_decls[start_node]::FluidSource
        fluid_type = start_decl.fluid_type

        region_id += 1
        push!(pending_nodes, start_node)

        while !isempty(pending_nodes)
            current = pop!(pending_nodes)
            current in visited && continue
            push!(visited, current)

            # Check declaration compatibility at this node
            decl = get(node_decls, current, nothing)
            if !isnothing(decl)
                _check_declaration_compatible(decl, fluid_type)
            end

            actualfluids[current] = fluid_type
            node_to_region[current] = region_id

            for neighbour in get(nodeconnections, current, ConnectionVect())
                neighbour in visited || push!(pending_nodes, neighbour)
            end
        end
        # pending_nodes is empty here (BFS ran to completion), ready for next region
    end
    empty!(visited)
    return nothing
end

"Get the MNA current magnitude through the filtered (grounded) source element at a node"
function _get_source_flow_rate(node::NodeCoord, derivedmapstate::DerivedMapState, scratchpad::CalculatorScratchpad, mna_state)
    element_index = get(scratchpad.filtered_source_element_index, node, 0)
    element_index == 0 && return 0.0

    element = derivedmapstate.filteredelements[element_index]
    current = abs_element_get_current(element, derivedmapstate, mna_state)
    return isnothing(current) ? 0.0 : abs(current)
end

"Compute per-region temperatures using flow-weighted averages. Requires solved MNA state."
function compute_region_temperatures!(derivedmapstate::DerivedMapState, scratchpad::CalculatorScratchpad, mna_state)
    region_temps = derivedmapstate.region_temperatures
    node_temps = derivedmapstate.node_temperatures
    node_to_region = derivedmapstate.node_to_region

    empty!(region_temps)
    empty!(node_temps)

    # Collect per-region flow-weighted temperature sums
    region_weighted_temp = Dict{Int, Float64}()
    region_total_flow = Dict{Int, Float64}()
    region_fluid_type = Dict{Int, FluidType}()

    for abs_decl in derivedmapstate.primary_fluid_declarations
        abs_decl.declaration isa FluidSource || continue
        node = abs_decl.node_coord
        rid = get(node_to_region, node, 0)
        rid == 0 && continue

        source = abs_decl.declaration::FluidSource
        region_fluid_type[rid] = source.fluid_type

        flow = _get_source_flow_rate(node, derivedmapstate, scratchpad, mna_state)
        if abs(flow) > 1.0e-9
            region_weighted_temp[rid] = get(region_weighted_temp, rid, 0.0) + flow * source.temperature
            region_total_flow[rid] = get(region_total_flow, rid, 0.0) + flow
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

# ===============================================================
# MNA State Preparation and Solve
# ===============================================================

"Populate `mna_state` node index lookups from filtered nodes (empties and refills existing dicts)."
function MNA_indexnodes!(mna_state::MNA_State, derivedmapstate::DerivedMapState)
    nodes = derivedmapstate.filterednodes

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
    for element::AbsoluteElement in derivedmapstate.filteredelements
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

"""Fold vector contents into a hash seed in order."""
function _fold_hash(values, h::UInt64)::UInt64
    for value in values
        h = hash(value, h)
    end
    return h
end

"""
Compute structure, value, and zero-state hashes from the constructed CSC A matrix.

Must be called after `MNA_construct_A_sparse!`. The CSC output of `SparseArrays.sparse!` is
canonical for equivalent matrices, so these order-sensitive hashes are stable across equivalent
raw stamp orderings.

Returns `(structure_hash, value_hash, zero_state_hash)`.
"""
function compute_A_hashes(cache::AMatrixCache)::Tuple{UInt64, UInt64, UInt64}
    colptr = cache.csccolptr
    rowval = cache.cscrowval
    nzval = cache.cscnzval

    # Hash CSC structure via canonical column pointers and row indices.
    structure_hash = hash(length(rowval))
    structure_hash = _fold_hash(colptr, structure_hash)
    structure_hash = _fold_hash(rowval, structure_hash)

    # Hash CSC stored values to detect magnitude changes under fixed structure.
    value_hash = hash(length(nzval))
    value_hash = _fold_hash(nzval, value_hash)

    # Hash CSC exact-zero participation to catch zero-toggle reuse hazards.
    zero_state_hash = hash(length(nzval))
    for value in nzval
        zero_state_hash = hash(iszero(value), zero_state_hash)
    end

    return (structure_hash, value_hash, zero_state_hash)
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

Each call stamps all elements into IJV vectors (zero-allocation), then applies two-tier caching:

1. **Structure or zero-state changed**: full sparse construction + `klu()` factorisation
   needs new symbolic analysis. This is the cold path.
2. **Values changed** (same positions and zero-state, different magnitudes): sparse construction
   (zero-alloc) + `klu!()` in-place numeric refactorisation — reuses symbolic analysis.

On the first tick, all hashes initialize to zero, so the new hashes always differ, triggering the
cold path naturally.
"""
function MNA_updateA!(mna_state::MNA_State)
    # Stamp elements into IJV (zero-alloc after warmup)
    MNA_stamp_A_ijv!(mna_state)

    # Build sparse matrix and compute authoritative hashes from the CSC structure
    MNA_construct_A_sparse!(mna_state)

    cache = mna_state.a_cache
    new_structure_hash, new_value_hash, new_zero_state_hash = compute_A_hashes(cache)

    if (new_structure_hash != cache.structure_hash) || (new_zero_state_hash != cache.zero_state_hash)
        # Cold path: topology or zero-state changed so do full sparse rebuild + new KLU factorisation
        cache.mat_A_lu = klu(cache.mat_A_sparse)
    elseif new_value_hash != cache.value_hash
        # Warm path: CSC structure and zero participation are stable so do numeric refactor only
        klu!(cache.mat_A_lu, nonzeros(cache.mat_A_sparse))
    end

    cache.structure_hash = new_structure_hash
    cache.value_hash = new_value_hash
    cache.zero_state_hash = new_zero_state_hash

    return nothing
end


"Construct the dense right-hand-side MNA vector `[I; E]` for the current circuit state."
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
