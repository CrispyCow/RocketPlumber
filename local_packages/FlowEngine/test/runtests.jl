using Test
using HexFrame
using HexElements
using HexFluids
using HexComponentsAPI
using FlowEngine
using FlowMap

# Import element type constants (not exported by FlowEngine, defined in HexElements)
using HexElements: CONST_RESISTOR, CONST_VOLTAGE, CONST_CURRENT, C_DEP_CURRENT, V_DEP_VOLTAGE

# ===============================================================
# Test Stub Types
# ===============================================================

# Minimal pipe implementation for producing elements
struct TestPipe <: PipeBehavior end
import HexComponentsAPI: get_conductance, get_pipe_tunables, set_pipe_tunables, render_pipe_base!
get_conductance(::TestPipe) = 1.0
get_pipe_tunables(::TestPipe) = ()
set_pipe_tunables(::TestPipe, tunables) = TestPipe()
function render_pipe_base!(queue::AbstractVector, behav::TestPipe; kwargs...)
    return nothing
end

struct DummyCompUpdate <: ComponentBehavior end
import HexComponentsAPI: update_flowbehav!
function update_flowbehav!(::DummyCompUpdate; tile::TileCoord, mna_state::MNA_State, kwargs...)
    mna_state.node_voltages[NodeCoord(tile, HexFrame.NODE_INTERNAL)] = 3.21
    return nothing
end

struct DummyFluidComp <: ComponentBehavior end
import HexComponentsAPI: get_fluidtags
function get_fluidtags(::DummyFluidComp)
    return NodeFluidTags(NODE_INTERNAL = HexFluids.COLD_GAS)
end


# ===============================================================
# Helper: construct absolute elements directly from node coords
# ===============================================================

"Shorthand to create an AbsoluteElement from node positions on a tile"
function make_element(tile::TileCoord, index::Integer, v1::NodeCoord, v2::NodeCoord,
                      value::Float64, type::ElementTypes;
                      dependent_index::Integer = 0, active::Bool = true)
    conns = AbsoluteElementConnections(v1, v2)
    id = ElementID(tile, UInt8(index))
    dep_id = ElementID(tile, UInt8(dependent_index))
    return AbsoluteElement(connections=conns, value=value, type=type,
                           id=id, dependent_id=dep_id, active=active)
end

"Shorthand to make a grounded node (GROUND on a dummy tile)"
ground_node() = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

"Shorthand: make a NodeCoord"
nc(q, r, dir) = NodeCoord(TileCoord(q, r), dir)


# ===============================================================
# Phase 1: Existing Infrastructure Tests (list_elements, etc.)
# ===============================================================

@testset "list_elements" begin
    # Multi-ship element collection
    gm = GameMap()
    edge1 = EdgeCoord(VertexCoord(TileCoord(1,0), HexFrame.Q_POS), VertexCoord(TileCoord(2,0), HexFrame.Q_POS))
    set_pipe!(gm, edge1, TestPipe())
    sec = ShipMap()
    add_ship!(gm, :sec, sec)
    edge2 = EdgeCoord(VertexCoord(TileCoord(5,0), HexFrame.Q_POS), VertexCoord(TileCoord(6,0), HexFrame.Q_POS))
    set_pipe!(gm, edge2, TestPipe(); ship_name = :sec)
    els = list_elements(gm)
    ids = Set(e.id for e in els)
    @test HexElements.ElementID(edge1) in ids
    @test HexElements.ElementID(edge2) in ids

    # Per-ship should only include that ship's elements
    els_sec = list_elements(get_ship(gm, :sec))
    ids_sec = Set(e.id for e in els_sec)
    @test HexElements.ElementID(edge2) in ids_sec
    @test !(HexElements.ElementID(edge1) in ids_sec)
end

@testset "update_components!" begin
    # Per-GameMap: calls update_flowbehav! on all ships
    gm = GameMap()
    set_component!(gm, TileCoord(0,0), ComponentOnTile(DummyCompUpdate(), HexFrame.Q_POS))
    sec = ShipMap()
    add_ship!(gm, :two, sec)
    set_component!(gm, TileCoord(5,5), ComponentOnTile(DummyCompUpdate(), HexFrame.Q_POS); ship_name = :two)
    ms = MNA_State()
    update_components!(gm, ms)
    @test NodeCoord(TileCoord(0,0), HexFrame.NODE_INTERNAL) in keys(ms.node_voltages)
    @test NodeCoord(TileCoord(5,5), HexFrame.NODE_INTERNAL) in keys(ms.node_voltages)
    @test ms.node_voltages[NodeCoord(TileCoord(0,0), HexFrame.NODE_INTERNAL)] ≈ 3.21
    @test ms.node_voltages[NodeCoord(TileCoord(5,5), HexFrame.NODE_INTERNAL)] ≈ 3.21

    # Per-Ship
    ship_single = ShipMap()
    set_component!(ship_single, TileCoord(7,7), ComponentOnTile(DummyCompUpdate(), HexFrame.Q_POS))
    ms2 = MNA_State()
    update_components!(ship_single, ms2)
    @test NodeCoord(TileCoord(7,7), HexFrame.NODE_INTERNAL) in keys(ms2.node_voltages)
    @test ms2.node_voltages[NodeCoord(TileCoord(7,7), HexFrame.NODE_INTERNAL)] ≈ 3.21
end

@testset "get_node_fluid_tags" begin
    gm = GameMap()
    sec = ShipMap()
    add_ship!(gm, :two, sec)
    set_component!(gm, TileCoord(10,10), ComponentOnTile(DummyFluidComp(), HexFrame.Q_POS); ship_name = :two)
    ctag = get_node_fluid_tags(NodeCoord(TileCoord(10,10), HexFrame.NODE_INTERNAL), gm)
    @test ctag[1] === HexFluids.COLD_GAS

    # Per-ship
    ship_fluid = ShipMap()
    set_component!(ship_fluid, TileCoord(20,20), ComponentOnTile(DummyFluidComp(), HexFrame.Q_POS))
    ptag = get_node_fluid_tags(NodeCoord(TileCoord(20,20), HexFrame.NODE_INTERNAL), ship_fluid)
    @test ptag[1] === HexFluids.COLD_GAS
end


# ===============================================================
# Phase 2: list_nodes Tests
# ===============================================================

@testset "list_nodes" begin
    n_a = nc(0, 0, HexFrame.NODE_Q_POS)
    n_b = nc(1, 0, HexFrame.NODE_Q_POS)
    n_c = nc(2, 0, HexFrame.NODE_Q_POS)
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

    @testset "single element - two nodes" begin
        elems = [make_element(TileCoord(0,0), 1, n_a, n_b, 1.0, CONST_RESISTOR)]
        nodes = list_nodes(elems)
        @test length(nodes) == 2
        @test nodes[n_a] == 1
        @test nodes[n_b] == 1
    end

    @testset "shared node count increments" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_c, 1.0, CONST_RESISTOR),
        ]
        nodes = list_nodes(elems)
        @test nodes[n_b] == 2
        @test nodes[n_a] == 1
        @test nodes[n_c] == 1
    end

    @testset "grounded node excluded" begin
        elems = [make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE)]
        nodes = list_nodes(elems)
        @test length(nodes) == 1
        @test haskey(nodes, n_a)
        @test !haskey(nodes, gnd)
    end

    @testset "empty input" begin
        @test isempty(list_nodes(AbsoluteElement[]))
    end
end


# ===============================================================
# Phase 3: prune Tests
# ===============================================================

@testset "prune" begin
    n_a = nc(0, 0, HexFrame.NODE_Q_POS)
    n_b = nc(1, 0, HexFrame.NODE_Q_POS)
    n_c = nc(2, 0, HexFrame.NODE_Q_POS)
    n_d = nc(3, 0, HexFrame.NODE_Q_POS)
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

    @testset "keeps well-connected triangle" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_c, 1.0, CONST_RESISTOR),
            make_element(TileCoord(2,0), 1, n_c, n_a, 1.0, CONST_RESISTOR),
        ]
        result = prune(elems)
        @test length(result) == 3
    end

    @testset "removes dead-end chain" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_c, 1.0, CONST_RESISTOR),
        ]
        result = prune(elems)
        @test isempty(result)
    end

    @testset "keeps grounded ring" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_a, 2.0, CONST_RESISTOR),
        ]
        result = prune(elems)
        @test length(result) == 3
    end

    @testset "single grounded element pruned" begin
        elems = [make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE)]
        result = prune(elems)
        @test isempty(result)
    end

    @testset "keeps diamond topology" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(0,0), 2, n_a, n_c, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_d, 1.0, CONST_RESISTOR),
            make_element(TileCoord(2,0), 1, n_c, n_d, 1.0, CONST_RESISTOR),
        ]
        result = prune(elems)
        @test length(result) == 4
    end

    @testset "empty input" begin
        @test isempty(prune(AbsoluteElement[]))
    end
end


# ===============================================================
# Phase 4: ground_search Tests
# ===============================================================

@testset "ground_search" begin
    n_a = nc(0, 0, HexFrame.NODE_Q_POS)
    n_b = nc(1, 0, HexFrame.NODE_Q_POS)
    n_c = nc(2, 0, HexFrame.NODE_Q_POS)
    n_d = nc(3, 0, HexFrame.NODE_Q_POS)
    n_e = nc(4, 0, HexFrame.NODE_Q_POS)
    n_f = nc(5, 0, HexFrame.NODE_Q_POS)
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

    @testset "simple grounded circuit" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
        ]
        result = ground_search(elems)
        @test length(result) == 2
    end

    @testset "disconnected island removed" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(2,0), 1, n_c, n_d, 1.0, CONST_RESISTOR),
        ]
        result = ground_search(elems)
        @test length(result) == 2
        result_ids = Set(e.id for e in result)
        @test !(ElementID(TileCoord(2,0), UInt8(1)) in result_ids)
    end

    @testset "zero-conductance resistor treated as disconnected" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 0.0, CONST_RESISTOR),
        ]
        result = ground_search(elems)
        @test length(result) == 1
        @test result[1].type == CONST_VOLTAGE
    end

    @testset "current sources excluded from traversal" begin
        # Current sources are NOT traversable — they don't provide voltage references.
        # Element 2 (current source to n_b) is excluded because n_b is only reachable through it.
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(1,0), 1, n_a, n_b, 0.5, CONST_CURRENT),
        ]
        result = ground_search(elems)
        @test length(result) == 1
        @test result[1].type == CONST_VOLTAGE
    end

    @testset "current sources included when nodes reachable via other paths" begin
        # Current source is kept if both its non-ground nodes are reachable from other elements
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(1,0), 1, n_a, n_b, 0.5, CONST_CURRENT),
            make_element(TileCoord(2,0), 1, n_b, gnd, 1.0, CONST_RESISTOR),
        ]
        result = ground_search(elems)
        @test length(result) == 3
    end

    @testset "voltage source chain provides ground path" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(1,0), 1, n_a, n_b, 3.0, CONST_VOLTAGE),
        ]
        result = ground_search(elems)
        @test length(result) == 2
    end

    @testset "traversal through mixed resistors and voltage sources" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 2.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_c, 3.0, CONST_VOLTAGE),
            make_element(TileCoord(2,0), 1, n_c, n_d, 1.0, CONST_RESISTOR),
        ]
        result = ground_search(elems)
        @test length(result) == 4
    end

    @testset "multiple grounded anchors" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(2,0), 1, n_c, gnd, 3.0, CONST_VOLTAGE),
            make_element(TileCoord(2,0), 2, n_c, n_d, 1.0, CONST_RESISTOR),
        ]
        result = ground_search(elems)
        @test length(result) == 4
    end

    @testset "empty input" begin
        @test isempty(ground_search(AbsoluteElement[]))
    end
end


# ===============================================================
# Phase 5: clear_dangling_dependants Tests
# ===============================================================

@testset "clear_dangling_dependants" begin
    n_a = nc(0, 0, HexFrame.NODE_Q_POS)
    n_b = nc(1, 0, HexFrame.NODE_Q_POS)
    n_c = nc(0, 0, HexFrame.NODE_INTERNAL)
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

    @testset "independent elements unaffected" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
        ]
        result = clear_dangling_dependants(elems)
        @test length(result) == 2
    end

    @testset "dependent with controller present stays" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 1.0, V_DEP_VOLTAGE; dependent_index=2),
            make_element(TileCoord(0,0), 2, n_c, n_b, 1.0, CONST_RESISTOR),
        ]
        result = clear_dangling_dependants(elems)
        @test length(result) == 2
    end

    @testset "dependent with missing controller removed" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 1.0, V_DEP_VOLTAGE; dependent_index=3),
            make_element(TileCoord(0,0), 2, n_c, n_b, 1.0, CONST_RESISTOR),
        ]
        result = clear_dangling_dependants(elems)
        @test length(result) == 1
        @test result[1].type == CONST_RESISTOR
    end

    @testset "mutual dependants both present stay" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 1.0, V_DEP_VOLTAGE; dependent_index=2),
            make_element(TileCoord(0,0), 2, n_b, gnd, -2.0, C_DEP_CURRENT; dependent_index=1),
        ]
        result = clear_dangling_dependants(elems)
        @test length(result) == 2
    end

    @testset "cascading removal" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_b, gnd, 1.0, C_DEP_CURRENT; dependent_index=3),
        ]
        result = clear_dangling_dependants(elems)
        @test length(result) == 1
        @test result[1].type == CONST_VOLTAGE
    end

    @testset "empty input" begin
        @test isempty(clear_dangling_dependants(AbsoluteElement[]))
    end
end


# ===============================================================
# Phase 6: Full Pruning Pipeline Tests
# ===============================================================

@testset "pruning pipeline convergence" begin
    n_a = nc(0, 0, HexFrame.NODE_Q_POS)
    n_b = nc(1, 0, HexFrame.NODE_Q_POS)
    n_c = nc(2, 0, HexFrame.NODE_Q_POS)
    n_d = nc(3, 0, HexFrame.NODE_Q_POS)
    n_e = nc(4, 0, HexFrame.NODE_Q_POS)
    n_int = nc(0, 0, HexFrame.NODE_INTERNAL)
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

    "Run the same iterative pruning pipeline as update_map! in HexFlowCalculator"
    function run_prune_pipeline(elements::Vector{AbsoluteElement})
        pruned = elements
        last_hash::UInt64 = 0
        while last_hash != hash(pruned)
            pruned = prune(pruned)
            pruned = ground_search(pruned)
            last_hash = hash(pruned)
            pruned = clear_dangling_dependants(pruned)
        end
        return pruned
    end

    @testset "simple grounded circuit survives" begin
        # Tank pattern: Vsrc(int→GND), R(int→a), R(int→b) + pipe R(a→c)
        elems = [
            make_element(TileCoord(0,0), 1, n_int, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_int, n_a, 2.0, CONST_RESISTOR),
            make_element(TileCoord(0,0), 3, n_int, n_b, 2.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_a, n_c, 1.0, CONST_RESISTOR),
        ]
        result = run_prune_pipeline(elems)
        # Dead ends cascade: n_c dead→pipe removed, n_a dead→R2 removed, n_b dead→R3 removed
        # n_int left with only vsrc (count=1)→pruned
        @test isempty(result)
    end

    @testset "tank-pipe-nozzle circuit survives" begin
        #=
        Tank: Vsrc(int→GND, 5V), R(int→a, 2S)
        Pipe: R(a→b, 1S)
        Nozzle: R(b→GND, 0.5S)
        =#
        elems = [
            make_element(TileCoord(0,0), 1, n_int, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_int, n_a, 2.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(2,0), 1, n_b, gnd, 0.5, CONST_RESISTOR),
        ]
        result = run_prune_pipeline(elems)
        @test length(result) == 4
    end

    @testset "two tanks feeding a nozzle" begin
        n_int2 = nc(3, 0, HexFrame.NODE_INTERNAL)
        elems = [
            make_element(TileCoord(0,0), 1, n_int, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_int, n_a, 2.0, CONST_RESISTOR),
            make_element(TileCoord(3,0), 1, n_int2, gnd, 3.0, CONST_VOLTAGE),
            make_element(TileCoord(3,0), 2, n_int2, n_b, 2.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_a, n_c, 1.0, CONST_RESISTOR),
            make_element(TileCoord(2,0), 1, n_b, n_c, 1.0, CONST_RESISTOR),
            make_element(TileCoord(4,0), 1, n_c, gnd, 0.5, CONST_RESISTOR),
        ]
        result = run_prune_pipeline(elems)
        @test length(result) == 7
    end

    @testset "CCCS with controller (turbopump pattern)" begin
        n_pump_int = nc(5, 0, HexFrame.NODE_INTERNAL)
        n_qpos = nc(5, 0, HexFrame.NODE_Q_POS)
        n_qneg = nc(5, 0, HexFrame.NODE_Q_NEG)
        n_spos = nc(5, 0, HexFrame.NODE_S_POS)
        n_pipe_out = nc(6, 0, HexFrame.NODE_Q_POS)

        elems = [
            # Turbopump
            make_element(TileCoord(5,0), 1, n_pump_int, n_qpos, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(5,0), 2, n_pump_int, n_qneg, 2.0, CONST_RESISTOR),
            make_element(TileCoord(5,0), 3, n_spos, gnd, 0.5, C_DEP_CURRENT; dependent_index=1),
            # Gas tank on Q_POS
            make_element(TileCoord(4,0), 1, nc(4,0, HexFrame.NODE_INTERNAL), gnd, 3.0, CONST_VOLTAGE),
            make_element(TileCoord(4,0), 2, nc(4,0, HexFrame.NODE_INTERNAL), n_qpos, 2.0, CONST_RESISTOR),
            # Pipe + nozzle
            make_element(TileCoord(6,0), 1, n_qneg, n_pipe_out, 1.0, CONST_RESISTOR),
            make_element(TileCoord(7,0), 1, n_pipe_out, gnd, 0.5, CONST_RESISTOR),
            # Gas tank feeding turbine S_POS
            make_element(TileCoord(8,0), 1, nc(8,0, HexFrame.NODE_INTERNAL), gnd, 2.0, CONST_VOLTAGE),
            make_element(TileCoord(8,0), 2, nc(8,0, HexFrame.NODE_INTERNAL), n_spos, 2.0, CONST_RESISTOR),
        ]
        result = run_prune_pipeline(elems)
        @test length(result) == 9
    end

    @testset "VCVS with controller (decomp chamber pattern)" begin
        n_dq_pos = nc(10, 0, HexFrame.NODE_Q_POS)
        n_dq_neg = nc(10, 0, HexFrame.NODE_Q_NEG)

        elems = [
            # Decomp chamber
            make_element(TileCoord(10,0), 1, n_dq_pos, gnd, 1.0, V_DEP_VOLTAGE; dependent_index=2),
            make_element(TileCoord(10,0), 2, n_dq_neg, gnd, -2.0, C_DEP_CURRENT; dependent_index=1),
            # Liquid tank
            make_element(TileCoord(9,0), 1, nc(9,0, HexFrame.NODE_INTERNAL), gnd, 8.0, CONST_VOLTAGE),
            make_element(TileCoord(9,0), 2, nc(9,0, HexFrame.NODE_INTERNAL), n_dq_pos, 4.0, CONST_RESISTOR),
            # Gas nozzle
            make_element(TileCoord(11,0), 1, n_dq_neg, nc(11,0, HexFrame.NODE_Q_POS), 1.0, CONST_RESISTOR),
            make_element(TileCoord(12,0), 1, nc(11,0, HexFrame.NODE_Q_POS), gnd, 0.5, CONST_RESISTOR),
        ]
        result = run_prune_pipeline(elems)
        @test length(result) == 6
    end
end


# ===============================================================
# Phase 7: MNA Solve Tests (full pipeline)
# ===============================================================

@testset "MNA solve - simple circuits" begin
    n_a = nc(0, 0, HexFrame.NODE_Q_POS)
    n_b = nc(1, 0, HexFrame.NODE_Q_POS)
    n_c = nc(2, 0, HexFrame.NODE_Q_POS)
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

    "Run full MNA pipeline on a set of elements, returns (mna_state, derived)"
    function solve_circuit(elements::Vector{AbsoluteElement})
        derived = DerivedMapState()
        mna = MNA_State()
        derived.prunedelements = elements
        derived.prunednodes = list_nodes(elements)
        mna.node_to_index, mna.index_to_node = MNA_indexnodes(derived)
        MNA_splitelements!(mna, derived)
        mna.mat_A = MNA_getA(mna)
        mna.mat_Z = MNA_getZ(mna)
        mna.node_voltages, mna.vsource_currents = MNA_solve(mna)
        return (mna, derived)
    end

    @testset "single voltage source with resistor" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, gnd, 1.0, CONST_RESISTOR),
        ]
        mna, _ = solve_circuit(elems)
        @test mna.node_voltages[n_a] ≈ 5.0
    end

    @testset "voltage divider" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 10.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 2.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, gnd, 2.0, CONST_RESISTOR),
        ]
        mna, _ = solve_circuit(elems)
        @test mna.node_voltages[n_a] ≈ 10.0
        @test mna.node_voltages[n_b] ≈ 5.0
    end

    @testset "current source into resistor" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 2.0, CONST_CURRENT),
            make_element(TileCoord(0,0), 2, n_a, gnd, 0.5, CONST_RESISTOR),
        ]
        mna, _ = solve_circuit(elems)
        @test mna.node_voltages[n_a] ≈ 4.0
    end

    @testset "two voltage sources in series" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(1,0), 1, n_b, n_a, 3.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_b, gnd, 1.0, CONST_RESISTOR),
        ]
        mna, _ = solve_circuit(elems)
        @test mna.node_voltages[n_a] ≈ 5.0
        @test mna.node_voltages[n_b] ≈ 8.0
    end

    @testset "tank-pipe-nozzle circuit" begin
        n_int = nc(0, 0, HexFrame.NODE_INTERNAL)
        elems = [
            make_element(TileCoord(0,0), 1, n_int, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_int, n_a, 2.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_a, n_b, 10.0, CONST_RESISTOR),
            make_element(TileCoord(2,0), 1, n_b, gnd, 0.3, CONST_RESISTOR),
        ]
        mna, _ = solve_circuit(elems)
        @test mna.node_voltages[n_int] ≈ 5.0
        R_total = 1/2.0 + 1/10.0 + 1/0.3
        I_expected = 5.0 / R_total
        @test mna.node_voltages[n_a] ≈ 5.0 - I_expected * (1/2.0)
        @test mna.node_voltages[n_b] ≈ I_expected * (1/0.3)
    end
end


# ===============================================================
# Phase 8: MNA Solve with Dependent Sources
# ===============================================================

@testset "MNA solve - dependent sources" begin
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

    "Run full MNA pipeline on a set of elements"
    function solve_circuit(elements::Vector{AbsoluteElement})
        derived = DerivedMapState()
        mna = MNA_State()
        derived.prunedelements = elements
        derived.prunednodes = list_nodes(elements)
        mna.node_to_index, mna.index_to_node = MNA_indexnodes(derived)
        MNA_splitelements!(mna, derived)
        mna.mat_A = MNA_getA(mna)
        mna.mat_Z = MNA_getZ(mna)
        mna.node_voltages, mna.vsource_currents = MNA_solve(mna)
        return (mna, derived)
    end

    @testset "CCCS (turbopump-like)" begin
        n_pump_int = nc(5, 0, HexFrame.NODE_INTERNAL)
        n_qpos = nc(5, 0, HexFrame.NODE_Q_POS)
        n_qneg = nc(5, 0, HexFrame.NODE_Q_NEG)
        n_spos = nc(5, 0, HexFrame.NODE_S_POS)
        n_tank_int = nc(4, 0, HexFrame.NODE_INTERNAL)
        n_load = nc(7, 0, HexFrame.NODE_Q_POS)
        n_gas_int = nc(8, 0, HexFrame.NODE_INTERNAL)

        elems = [
            # Pump
            make_element(TileCoord(5,0), 1, n_pump_int, n_qpos, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(5,0), 2, n_pump_int, n_qneg, 2.0, CONST_RESISTOR),
            make_element(TileCoord(5,0), 3, n_spos, gnd, 0.5, C_DEP_CURRENT; dependent_index=1),
            # Gas tank
            make_element(TileCoord(4,0), 1, n_tank_int, gnd, 3.0, CONST_VOLTAGE),
            make_element(TileCoord(4,0), 2, n_tank_int, n_qpos, 2.0, CONST_RESISTOR),
            # Gas tank feeding turbine
            make_element(TileCoord(8,0), 1, n_gas_int, gnd, 2.0, CONST_VOLTAGE),
            make_element(TileCoord(8,0), 2, n_gas_int, n_spos, 2.0, CONST_RESISTOR),
            # Pipe + nozzle
            make_element(TileCoord(6,0), 1, n_qneg, n_load, 1.0, CONST_RESISTOR),
            make_element(TileCoord(7,0), 1, n_load, gnd, 0.5, CONST_RESISTOR),
        ]
        mna, _ = solve_circuit(elems)
        @test haskey(mna.node_voltages, n_pump_int)
        @test haskey(mna.node_voltages, n_qpos)
        @test haskey(mna.node_voltages, n_spos)
        @test (mna.node_voltages[n_pump_int] - mna.node_voltages[n_qpos]) ≈ 5.0
    end

    @testset "VCVS (decomp chamber-like)" begin
        n_dq_pos = nc(10, 0, HexFrame.NODE_Q_POS)
        n_dq_neg = nc(10, 0, HexFrame.NODE_Q_NEG)
        n_liq_int = nc(9, 0, HexFrame.NODE_INTERNAL)
        n_gas_out = nc(11, 0, HexFrame.NODE_Q_POS)

        elems = [
            # Decomp chamber
            make_element(TileCoord(10,0), 1, n_dq_pos, gnd, 1.0, V_DEP_VOLTAGE; dependent_index=2),
            make_element(TileCoord(10,0), 2, n_dq_neg, gnd, -2.0, C_DEP_CURRENT; dependent_index=1),
            # Liquid tank
            make_element(TileCoord(9,0), 1, n_liq_int, gnd, 8.0, CONST_VOLTAGE),
            make_element(TileCoord(9,0), 2, n_liq_int, n_dq_pos, 4.0, CONST_RESISTOR),
            # Pipe + nozzle
            make_element(TileCoord(11,0), 1, n_dq_neg, n_gas_out, 1.0, CONST_RESISTOR),
            make_element(TileCoord(12,0), 1, n_gas_out, gnd, 0.5, CONST_RESISTOR),
        ]
        mna, _ = solve_circuit(elems)
        @test haskey(mna.node_voltages, n_dq_pos)
        @test haskey(mna.node_voltages, n_dq_neg)
    end
end


# ===============================================================
# Phase 9: Known Failure Cases (singularity-inducing topologies)
# ===============================================================

@testset "singularity cases" begin
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

    "Run the iterative pruning pipeline (mirrors HexFlowCalculator.update_map!)"
    function run_prune_pipeline(elements::Vector{AbsoluteElement})
        pruned = elements
        last_hash::UInt64 = 0
        while last_hash != hash(pruned)
            pruned = prune(pruned)
            pruned = ground_search(pruned)
            last_hash = hash(pruned)
            pruned = clear_dangling_dependants(pruned)
        end
        return pruned
    end

    "Run full MNA pipeline on pre-pruned elements"
    function solve_circuit(elements::Vector{AbsoluteElement})
        derived = DerivedMapState()
        mna = MNA_State()
        derived.prunedelements = elements
        derived.prunednodes = list_nodes(elements)
        if isempty(derived.prunednodes)
            return (mna, derived)
        end
        mna.node_to_index, mna.index_to_node = MNA_indexnodes(derived)
        MNA_splitelements!(mna, derived)
        mna.mat_A = MNA_getA(mna)
        mna.mat_Z = MNA_getZ(mna)
        mna.node_voltages, mna.vsource_currents = MNA_solve(mna)
        return (mna, derived)
    end

    @testset "current source island in grounded circuit" begin
        #=
        Small island connected to ground ONLY via current sources.
        Internal R gives all non-ground nodes count ≥2, surviving basic prune.
        Current ground_search traverses current sources, keeping the island alive.
        After fix: current sources excluded from traversal → island pruned.
        =#
        n_a = nc(0, 0, HexFrame.NODE_Q_POS)
        n_b = nc(1, 0, HexFrame.NODE_Q_POS)

        elems = [
            make_element(TileCoord(0,0), 1, n_a, n_b, 2.0, CONST_RESISTOR),
            make_element(TileCoord(0,0), 2, n_a, gnd, 1.0, CONST_CURRENT),
            make_element(TileCoord(1,0), 1, n_b, gnd, 1.0, CONST_CURRENT),
        ]

        # All non-ground nodes have count ≥2 (prune-proof)
        nodes = list_nodes(elems)
        @test all(v >= 2 for (_, v) in nodes)

        pruned = run_prune_pipeline(elems)
        # Current sources excluded from traversal → island has no voltage anchor → pruned
        @test isempty(pruned)
    end

    @testset "turbopump/decomp floating island (playtest2-crash pattern)" begin
        #=
        From mna_singularity_report.md:
        TurboPump + DecompChamber form floating island when all adjacent tanks stall.
        All ground connections are through dependent sources (CCCS) and VCVS —
        no independent voltage source to ground exists in the island.

        Pipes between the components ensure all non-ground nodes have ≥2 element
        connections, making the island immune to basic prune.
        =#
        tp_tile = TileCoord(17, -16)
        dc_tile = TileCoord(16, -16)

        n_tp_int  = nc(17, -16, HexFrame.NODE_INTERNAL)
        n_tp_qpos = nc(17, -16, HexFrame.NODE_Q_POS)
        n_tp_qneg = nc(17, -16, HexFrame.NODE_Q_NEG)
        n_tp_spos = nc(17, -16, HexFrame.NODE_S_POS)
        n_dc_qpos = nc(16, -16, HexFrame.NODE_Q_POS)
        n_dc_qneg = nc(15, -16, HexFrame.NODE_Q_POS) # mapped to adjacent tile vertex

        elems = [
            # TurboPump (stalled: Vsrc at 0V but still active element)
            make_element(tp_tile, 1, n_tp_int, n_tp_qpos, 0.0, CONST_VOLTAGE),
            make_element(tp_tile, 2, n_tp_int, n_tp_qneg, 2.0, CONST_RESISTOR),
            make_element(tp_tile, 3, n_tp_spos, gnd, 0.5, C_DEP_CURRENT; dependent_index=1),
            # DecompChamber (mutual VCVS ↔ CCCS dependency)
            make_element(dc_tile, 1, n_dc_qpos, gnd, 1.0, V_DEP_VOLTAGE; dependent_index=2),
            make_element(dc_tile, 2, n_dc_qneg, gnd, -2.0, C_DEP_CURRENT; dependent_index=1),
            # Pipes connecting TurboPump ports to DecompChamber ports
            make_element(TileCoord(18, -16), 1, n_tp_qpos, n_dc_qpos, 1.0, CONST_RESISTOR),
            make_element(TileCoord(19, -16), 1, n_tp_qneg, n_dc_qpos, 1.0, CONST_RESISTOR),
            make_element(TileCoord(20, -16), 1, n_tp_spos, n_dc_qneg, 1.0, CONST_RESISTOR),
        ]

        # All non-ground nodes have count ≥2 (prune-proof)
        nodes = list_nodes(elems)
        @test all(v >= 2 for (_, v) in nodes)

        pruned = run_prune_pipeline(elems)
        # Current sources excluded from traversal → island has no voltage anchor → pruned
        @test isempty(pruned)
    end

    @testset "VCVS-coupled circuit with proper grounding survives" begin
        #=
        Same TurboPump + DecompChamber topology as above, but WITH active tanks
        providing independent grounded voltage sources. This represents a working
        circuit that should survive pruning completely.

        Key difference: liquid and gas tanks provide CONST_VOLTAGE to GND, giving
        the circuit proper voltage references. All non-ground nodes have ≥2 connections.
        =#
        tp_tile = TileCoord(17, -16)
        dc_tile = TileCoord(16, -16)

        n_tp_int  = nc(17, -16, HexFrame.NODE_INTERNAL)
        n_tp_qpos = nc(17, -16, HexFrame.NODE_Q_POS)
        n_tp_qneg = nc(17, -16, HexFrame.NODE_Q_NEG)
        n_tp_spos = nc(17, -16, HexFrame.NODE_S_POS)
        n_dc_qpos = nc(16, -16, HexFrame.NODE_Q_POS)
        n_dc_qneg = nc(15, -16, HexFrame.NODE_Q_POS)
        n_liq_int = nc(14, -16, HexFrame.NODE_INTERNAL)
        n_gas_int = nc(18, -16, HexFrame.NODE_INTERNAL)
        n_nozzle  = nc(19, -16, HexFrame.NODE_Q_POS)

        elems = [
            # TurboPump (active: Vsrc at 5V)
            make_element(tp_tile, 1, n_tp_int, n_tp_qpos, 5.0, CONST_VOLTAGE),
            make_element(tp_tile, 2, n_tp_int, n_tp_qneg, 2.0, CONST_RESISTOR),
            make_element(tp_tile, 3, n_tp_spos, gnd, 0.5, C_DEP_CURRENT; dependent_index=1),
            # DecompChamber
            make_element(dc_tile, 1, n_dc_qpos, gnd, 1.0, V_DEP_VOLTAGE; dependent_index=2),
            make_element(dc_tile, 2, n_dc_qneg, gnd, -2.0, C_DEP_CURRENT; dependent_index=1),
            # Liquid tank (grounded via CONST_VOLTAGE → GND, series R to tp_qpos)
            make_element(TileCoord(14, -16), 1, n_liq_int, gnd, 8.0, CONST_VOLTAGE),
            make_element(TileCoord(14, -16), 2, n_liq_int, n_tp_qpos, 4.0, CONST_RESISTOR),
            # Gas tank (grounded via CONST_VOLTAGE → GND, series R to tp_spos)
            make_element(TileCoord(18, -16), 1, n_gas_int, gnd, 3.0, CONST_VOLTAGE),
            make_element(TileCoord(18, -16), 2, n_gas_int, n_tp_spos, 2.0, CONST_RESISTOR),
            # Pipes connecting TurboPump ↔ DecompChamber
            make_element(TileCoord(20, -16), 1, n_tp_qneg, n_dc_qpos, 1.0, CONST_RESISTOR),
            make_element(TileCoord(21, -16), 1, n_tp_spos, n_dc_qneg, 1.0, CONST_RESISTOR),
            # Nozzle (resistive path to ground)
            make_element(TileCoord(22, -16), 1, n_tp_qneg, n_nozzle, 1.0, CONST_RESISTOR),
            make_element(TileCoord(23, -16), 1, n_nozzle, gnd, 0.5, CONST_RESISTOR),
        ]

        # All non-ground nodes have count ≥2
        nodes = list_nodes(elems)
        @test all(v >= 2 for (_, v) in nodes)

        pruned = run_prune_pipeline(elems)
        @test length(pruned) == length(elems)

        # Circuit should also be solvable without singularity
        mna, _ = solve_circuit(pruned)
        @test !isempty(mna.node_voltages)
    end
end


# ===============================================================
# Phase 10: Build Node Connection Map Tests
# ===============================================================

@testset "build_node_connection_map!" begin
    n_a = nc(0, 0, HexFrame.NODE_Q_POS)
    n_b = nc(1, 0, HexFrame.NODE_Q_POS)
    n_c = nc(2, 0, HexFrame.NODE_Q_POS)
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

    @testset "basic connections" begin
        derived = DerivedMapState()
        derived.prunedelements = [
            make_element(TileCoord(0,0), 1, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_c, 1.0, CONST_RESISTOR),
        ]
        build_node_connection_map!(derived)
        @test n_b in derived.nodeconnections[n_a]
        @test n_a in derived.nodeconnections[n_b]
        @test n_c in derived.nodeconnections[n_b]
        @test n_b in derived.nodeconnections[n_c]
    end

    @testset "grounded elements excluded from connections" begin
        derived = DerivedMapState()
        derived.prunedelements = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
        ]
        build_node_connection_map!(derived)
        @test !haskey(derived.nodeconnections, n_a) || isempty(derived.nodeconnections[n_a])
    end
end

println("All FlowEngine tests complete")
