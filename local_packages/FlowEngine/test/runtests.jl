using Test
using LinearAlgebra: SingularException
using SparseArrays: sparse, nonzeros, rowvals, nnz
using KLU: klu, klu!
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
struct MultiElementPipe <: PipeBehavior end
struct InactiveElementPipe <: PipeBehavior end
import HexComponentsAPI: get_conductance, get_pipe_tunables, set_pipe_tunables, render_pipe_base!, get_pipe_click_radius, produce_abs_elements
get_conductance(::TestPipe) = 1.0
get_pipe_tunables(::TestPipe) = ()
set_pipe_tunables(::TestPipe, tunables) = TestPipe()
get_pipe_click_radius(::TestPipe) = 0.1
function render_pipe_base!(queue::AbstractVector, behav::TestPipe; kwargs...)
    return nothing
end

get_conductance(::MultiElementPipe) = 1.0
get_pipe_tunables(::MultiElementPipe) = ()
set_pipe_tunables(::MultiElementPipe, tunables) = MultiElementPipe()
get_pipe_click_radius(::MultiElementPipe) = 0.1
render_pipe_base!(queue::AbstractVector, behav::MultiElementPipe; kwargs...) = nothing

get_conductance(::InactiveElementPipe) = 1.0
get_pipe_tunables(::InactiveElementPipe) = ()
set_pipe_tunables(::InactiveElementPipe, tunables) = InactiveElementPipe()
get_pipe_click_radius(::InactiveElementPipe) = 0.1
render_pipe_base!(queue::AbstractVector, behav::InactiveElementPipe; kwargs...) = nothing

struct DummyCompUpdate <: ComponentBehavior end
import HexComponentsAPI: update_flowbehav!
function update_flowbehav!(::DummyCompUpdate; tile::TileCoord, mna_state::MNA_State, derivedmapstate::DerivedMapState, kwargs...)
    derived_value = get(derivedmapstate.nodeactualfluids, NodeCoord(tile, HexFrame.NODE_INTERNAL_1), nothing)
    mna_state.node_voltages[NodeCoord(tile, HexFrame.NODE_INTERNAL_1)] = derived_value === HexFluids.COLD_GAS ? 3.21 : -1.0
    return nothing
end

struct DummyFluidComp <: ComponentBehavior end
import HexComponentsAPI: produce_rel_fluid_declarations
function produce_rel_fluid_declarations(::DummyFluidComp)
    return (FlowEngine.RelativeFluidDeclaration(HexFrame.NODE_INTERNAL_1, HexFluids.FluidSource(HexFluids.COLD_GAS, 300.0)),)
end

function expect_fluid_compatibility_error(action::Function, expected_message::AbstractString)
    error = try
        action()
        nothing
    catch exception
        exception
    end

    @test error isa FluidCompatibilityError
    @test error isa ExpectedMapValidationError
    @test sprint(showerror, error) == expected_message
    return nothing
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

function produce_abs_elements(::MultiElementPipe, coord::PipeCoord)
    n1 = to_nodecoord(coord.v1)
    n2 = to_nodecoord(coord.v2)
    return (
        make_element(TileCoord(90, 0), 1, n1, n2, 1.0, CONST_RESISTOR),
        make_element(TileCoord(90, 0), 2, n1, n2, 2.0, CONST_RESISTOR),
    )
end

function produce_abs_elements(::InactiveElementPipe, coord::PipeCoord)
    n1 = to_nodecoord(coord.v1)
    n2 = to_nodecoord(coord.v2)
    return (
        make_element(TileCoord(91, 0), 1, n1, n2, 1.0, CONST_RESISTOR; active = false),
        make_element(TileCoord(91, 0), 2, n1, n2, 2.0, CONST_RESISTOR),
    )
end

"Shorthand to make a grounded node (GROUND on a dummy tile)"
ground_node() = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

"Shorthand: make a NodeCoord"
nc(q, r, dir) = NodeCoord(TileCoord(q, r), dir)

"Return the indexed side-span pipe bordering a tile."
side_pipe(tile::TileCoord, index::Integer = 1) = get_side_pipes(tile)[index]


# ===============================================================
# Phase 1: Existing Infrastructure Tests (list_elements, etc.)
# ===============================================================

@testset "list_elements" begin
    # Multi-ship element collection
    gm = GameMap()
    pipe1 = side_pipe(TileCoord(1, 0), 1)
    set_pipe!(gm, pipe1, PlacedPipe(TestPipe(), :primary))
    sec = ShipState()
    add_ship!(gm, :sec, sec)
    pipe2 = side_pipe(TileCoord(5, 0), 1)
    set_pipe!(gm, pipe2, PlacedPipe(TestPipe(), :sec))
    els = list_elements(gm)
    ids = Set(e.id for e in els)
    @test HexElements.ElementID(pipe1) in ids
    @test HexElements.ElementID(pipe2) in ids

    # Per-ship should only include that ship's elements
    els_sec = list_elements(gm; ship_name = :sec)
    ids_sec = Set(e.id for e in els_sec)
    @test HexElements.ElementID(pipe2) in ids_sec
    @test !(HexElements.ElementID(pipe1) in ids_sec)

    @testset "default pipe elements cover all span classes" begin
        gm_spans = GameMap()
        side = get_pipe_segments(TileCoord(0, 0))[1]
        short_diag = get_pipe_segments(TileCoord(0, 0))[7]
        long_diag = get_pipe_segments(TileCoord(0, 0))[13]
        for coord in (side, short_diag, long_diag)
            set_pipe!(gm_spans, coord, PlacedPipe(TestPipe(), :primary))
        end

        elements = list_elements(gm_spans)
        ids = Set(element.id for element in elements)
        @test length(elements) == 3
        @test all(coord -> ElementID(coord) in ids, (side, short_diag, long_diag))
        @test all(element -> element.type === CONST_RESISTOR, elements)
    end

    @testset "pipe produce_abs_elements hook is honoured" begin
        gm_multi = GameMap()
        coord = get_pipe_segments(TileCoord(0, 0))[7]
        set_pipe!(gm_multi, coord, PlacedPipe(MultiElementPipe(), :primary))
        elements = list_elements(gm_multi)
        @test length(elements) == 2
        @test sort([element.value for element in elements]) == [1.0, 2.0]

        gm_inactive = GameMap()
        set_pipe!(gm_inactive, coord, PlacedPipe(InactiveElementPipe(), :primary))
        active_elements = list_elements(gm_inactive)
        @test length(active_elements) == 1
        @test only(active_elements).value == 2.0
    end
end

@testset "update_components!" begin
    # Per-GameMap: calls update_flowbehav! on all ships
    gm = GameMap()
    set_component!(gm, TileCoord(0,0), PlacedComponent(DummyCompUpdate(), HexFrame.Q_POS, :primary))
    sec = ShipState()
    add_ship!(gm, :two, sec)
    set_component!(gm, TileCoord(5,5), PlacedComponent(DummyCompUpdate(), HexFrame.Q_POS, :two))
    ms = MNA_State()
    derived = DerivedMapState(
        nodeactualfluids = Dict(
            NodeCoord(TileCoord(0,0), HexFrame.NODE_INTERNAL_1) => HexFluids.COLD_GAS,
            NodeCoord(TileCoord(5,5), HexFrame.NODE_INTERNAL_1) => HexFluids.COLD_GAS,
        )
    )
    update_components!(gm, ms, derived)
    @test NodeCoord(TileCoord(0,0), HexFrame.NODE_INTERNAL_1) in keys(ms.node_voltages)
    @test NodeCoord(TileCoord(5,5), HexFrame.NODE_INTERNAL_1) in keys(ms.node_voltages)
    @test ms.node_voltages[NodeCoord(TileCoord(0,0), HexFrame.NODE_INTERNAL_1)] ≈ 3.21
    @test ms.node_voltages[NodeCoord(TileCoord(5,5), HexFrame.NODE_INTERNAL_1)] ≈ 3.21
end

@testset "fluid declarations" begin
    gm = GameMap()
    sec = ShipState()
    add_ship!(gm, :two, sec)
    set_component!(gm, TileCoord(10,10), PlacedComponent(DummyFluidComp(), HexFrame.Q_POS, :two))
    derived = DerivedMapState()
    list_fluid_declarations!(derived.primary_fluid_declarations, gm)
    @test length(derived.primary_fluid_declarations) == 1
    decl = derived.primary_fluid_declarations[1]
    @test decl.declaration isa HexFluids.FluidSource
    @test decl.declaration.fluid_type === HexFluids.COLD_GAS
end

@testset "propagate_fluid_types! rejects incompatible traversed declarations" begin
    source_node = nc(0, 0, HexFrame.NODE_Q_POS)
    constrained_node = nc(1, 0, HexFrame.NODE_Q_NEG)

    derived = DerivedMapState(
        node_declarations = Dict(
            source_node => HexFluids.FluidSource(HexFluids.MONOPROP_GAS, 800.0),
            constrained_node => HexFluids.FluidConstraintRule(HexFluids.IS_LIQUID),
        ),
        source_nodes = Set((source_node,)),
    )
    scratchpad = FlowEngine.CalculatorScratchpad(
        final_nodeconnections = Dict(
            source_node => FlowEngine.ConnectionVect((constrained_node,)),
            constrained_node => FlowEngine.ConnectionVect((source_node,)),
        ),
    )

    err = try
        propagate_fluid_types!(derived, scratchpad)
        nothing
    catch exc
        exc
    end

    @test err isa FluidCompatibilityError
    @test err isa ExpectedMapValidationError
    @test sprint(showerror, err) == "Fluid MONOPROP_GAS incompatible with constraint IS_LIQUID"
    @test !haskey(derived.nodeactualfluids, constrained_node)
end

@testset "fluid compatibility errors preserve their messages" begin
    expect_fluid_compatibility_error(
        () -> FlowEngine.prioritise_declarations(
            HexFluids.FluidConstraintRule(HexFluids.IS_GAS),
            HexFluids.FluidConstraintRule(HexFluids.IS_LIQUID),
        ),
        "Conflicting fluid constraints: IS_GAS vs IS_LIQUID",
    )
    expect_fluid_compatibility_error(
        () -> FlowEngine.prioritise_declarations(
            HexFluids.FluidSource(HexFluids.MONOPROP_GAS, 800.0),
            HexFluids.FluidSource(HexFluids.COLD_GAS, 300.0),
        ),
        "Conflicting fluid sources: MONOPROP_GAS vs COLD_GAS",
    )
    expect_fluid_compatibility_error(
        () -> FlowEngine.prioritise_declarations(
            HexFluids.FluidTypeRule(HexFluids.COLD_GAS),
            HexFluids.FluidSource(HexFluids.MONOPROP_GAS, 800.0),
        ),
        "FluidTypeRule COLD_GAS incompatible with MONOPROP_GAS",
    )
    expect_fluid_compatibility_error(
        () -> FlowEngine.prioritise_declarations(
            HexFluids.FluidConstraintRule(HexFluids.IS_LIQUID),
            HexFluids.FluidSource(HexFluids.MONOPROP_GAS, 800.0),
        ),
        "Fluid MONOPROP_GAS does not satisfy constraint IS_LIQUID",
    )
    expect_fluid_compatibility_error(
        () -> FlowEngine._check_declaration_compatible(
            HexFluids.FluidConstraintRule(HexFluids.IS_LIQUID), HexFluids.MONOPROP_GAS,
        ),
        "Fluid MONOPROP_GAS incompatible with constraint IS_LIQUID",
    )
    expect_fluid_compatibility_error(
        () -> FlowEngine._check_declaration_compatible(
            HexFluids.FluidTypeRule(HexFluids.COLD_GAS), HexFluids.MONOPROP_GAS,
        ),
        "FluidTypeRule COLD_GAS conflicts with region fluid MONOPROP_GAS",
    )
    expect_fluid_compatibility_error(
        () -> FlowEngine._check_declaration_compatible(
            HexFluids.FluidSource(HexFluids.COLD_GAS, 300.0), HexFluids.MONOPROP_GAS,
        ),
        "FluidSource COLD_GAS conflicts with region fluid MONOPROP_GAS",
    )

    @test FlowEngine.prioritise_declarations(
        HexFluids.FluidConstraintRule(HexFluids.IS_GAS),
        HexFluids.FluidConstraintRule(HexFluids.IS_GAS),
    ) == HexFluids.FluidConstraintRule(HexFluids.IS_GAS)
    @test FlowEngine._check_declaration_compatible(
        HexFluids.FluidConstraintRule(HexFluids.IS_GAS), HexFluids.COLD_GAS,
    ) === nothing
end

@testset "prioritise_declarations rejects conflicting constraint rules" begin
    matching_constraint = FlowEngine.prioritise_declarations(
        HexFluids.FluidConstraintRule(HexFluids.IS_GAS),
        HexFluids.FluidConstraintRule(HexFluids.IS_GAS),
    )

    @test matching_constraint == HexFluids.FluidConstraintRule(HexFluids.IS_GAS)

    err = try
        FlowEngine.prioritise_declarations(
            HexFluids.FluidConstraintRule(HexFluids.IS_GAS),
            HexFluids.FluidConstraintRule(HexFluids.IS_LIQUID),
        )
        nothing
    catch exc
        exc
    end

    @test err isa FluidCompatibilityError
    @test err isa ExpectedMapValidationError
    @test sprint(showerror, err) == "Conflicting fluid constraints: IS_GAS vs IS_LIQUID"
end

@testset "propagate_fluid_types! visits whole region with stack traversal" begin
    source_node = nc(0, 0, HexFrame.NODE_Q_POS)
    middle_node = nc(1, 0, HexFrame.NODE_Q_NEG)
    end_node = nc(2, 0, HexFrame.NODE_R_POS)

    derived = DerivedMapState(
        node_declarations = Dict(
            source_node => HexFluids.FluidSource(HexFluids.COLD_GAS, 300.0),
        ),
        source_nodes = Set((source_node,)),
    )
    scratchpad = FlowEngine.CalculatorScratchpad(
        final_nodeconnections = Dict(
            source_node => FlowEngine.ConnectionVect((middle_node,)),
            middle_node => FlowEngine.ConnectionVect((source_node, end_node)),
            end_node => FlowEngine.ConnectionVect((middle_node,)),
        ),
    )

    propagate_fluid_types!(derived, scratchpad)

    @test derived.nodeactualfluids[source_node] === HexFluids.COLD_GAS
    @test derived.nodeactualfluids[middle_node] === HexFluids.COLD_GAS
    @test derived.nodeactualfluids[end_node] === HexFluids.COLD_GAS
    @test derived.node_to_region[source_node] == derived.node_to_region[end_node]
end

@testset "compute_region_temperatures! uses grounded source index for reversed elements" begin
    source_node = nc(0, 0, HexFrame.NODE_Q_POS)
    ground = ground_node()
    grounded_resistor = make_element(TileCoord(0, 0), 1, ground, source_node, 2.0, CONST_RESISTOR)

    derived = DerivedMapState(
        filteredelements = [grounded_resistor],
        primary_fluid_declarations = [
            FlowEngine.AbsoluteFluidDeclaration(source_node, HexFluids.FluidSource(HexFluids.COLD_GAS, 450.0)),
        ],
        node_to_region = Dict(source_node => 1),
    )
    scratchpad = FlowEngine.CalculatorScratchpad()
    FlowEngine.index_grounded_source_elements!(scratchpad.filtered_source_element_index, derived.filteredelements)

    mna_state = MNA_State(
        node_voltages = Dict(source_node => 5.0),
    )

    compute_region_temperatures!(derived, scratchpad, mna_state)

    @test derived.region_temperatures[1] ≈ 450.0
    @test derived.node_temperatures[source_node] ≈ 450.0
end


"Run ground search on a copy of elements via the new in-place API; returns the mutated survivor vector."
function run_ground_search(elements::Vector{AbsoluteElement})
    elems = copy(elements)
    scratchpad = FlowEngine.CalculatorScratchpad()
    ground_search!(elems, scratchpad)
    return elems
end

"Run prune on a copy of elements via the new in-place API; returns the mutated survivor vector."
function run_prune(elements::Vector{AbsoluteElement})
    elems = copy(elements)
    scratchpad = FlowEngine.CalculatorScratchpad()
    prune!(elems, scratchpad)
    return elems
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
        result = run_prune(elems)
        @test length(result) == 3
    end

    @testset "removes dead-end chain" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_c, 1.0, CONST_RESISTOR),
        ]
        result = run_prune(elems)
        @test isempty(result)
    end

    @testset "keeps grounded ring" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_a, 2.0, CONST_RESISTOR),
        ]
        result = run_prune(elems)
        @test length(result) == 3
    end

    @testset "counts parallel edges during prune" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_a, n_b, 2.0, CONST_VOLTAGE),
        ]

        result = run_prune(elems)
        @test length(result) == 3
    end

    @testset "single grounded element pruned" begin
        elems = [make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE)]
        result = run_prune(elems)
        @test isempty(result)
    end

    @testset "keeps diamond topology" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(0,0), 2, n_a, n_c, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_d, 1.0, CONST_RESISTOR),
            make_element(TileCoord(2,0), 1, n_c, n_d, 1.0, CONST_RESISTOR),
        ]
        result = run_prune(elems)
        @test length(result) == 4
    end

    @testset "empty input" begin
        @test isempty(run_prune(AbsoluteElement[]))
    end

    @testset "prune! leaves scratch buffer clean after call" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_a, 2.0, CONST_RESISTOR),
        ]
        scratchpad = FlowEngine.CalculatorScratchpad()
        prune!(elems, scratchpad)
        @test length(elems) == 3
        @test isempty(scratchpad.pruning_nodeconnections)
    end

    @testset "prune! result matches old prunedelements output" begin
        # In-place prune: call on a copy, assert same survivor count as run_prune
        elems_copy = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_a, 2.0, CONST_RESISTOR),
        ]
        result = run_prune(elems_copy)
        nodes = list_nodes(result)
        @test length(result) == 3
        @test nodes[n_a] == 3
        @test nodes[n_b] == 2
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
        result = run_ground_search(elems)
        @test length(result) == 2
    end

    @testset "disconnected island removed" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(2,0), 1, n_c, n_d, 1.0, CONST_RESISTOR),
        ]
        result = run_ground_search(elems)
        @test length(result) == 2
        result_ids = Set(e.id for e in result)
        @test !(ElementID(TileCoord(2,0), UInt8(1)) in result_ids)
    end

    @testset "zero-conductance resistor treated as disconnected" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 0.0, CONST_RESISTOR),
        ]
        result = run_ground_search(elems)
        @test length(result) == 1
        @test result[1].type == CONST_VOLTAGE
    end

    @testset "grounded zero-conductance resistor does not anchor traversal" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 0.0, CONST_RESISTOR),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
        ]
        result = run_ground_search(elems)
        @test isempty(result)
    end

    @testset "non-ground zero-conductance resistor is kept when its nodes are grounded" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(1,0), 1, n_b, gnd, 3.0, CONST_RESISTOR),
            make_element(TileCoord(2,0), 1, n_a, n_b, 0.0, CONST_RESISTOR),
        ]
        result = run_ground_search(elems)
        @test length(result) == 3
        @test any(element -> element.value == 0.0 && element.type == CONST_RESISTOR, result)
    end

    @testset "grounded zero-conductance resistor is kept when its node is grounded by other paths" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(1,0), 1, n_a, gnd, 0.0, CONST_RESISTOR),
        ]
        result = run_ground_search(elems)
        @test length(result) == 2
        @test any(element -> element.value == 0.0 && element.type == CONST_RESISTOR, result)
    end

    @testset "current sources excluded from traversal" begin
        # Current sources are NOT traversable — they don't provide voltage references.
        # Element 2 (current source to n_b) is excluded because n_b is only reachable through it.
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(1,0), 1, n_a, n_b, 0.5, CONST_CURRENT),
        ]
        result = run_ground_search(elems)
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
        result = run_ground_search(elems)
        @test length(result) == 3
    end

    @testset "voltage source chain provides ground path" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(1,0), 1, n_a, n_b, 3.0, CONST_VOLTAGE),
        ]
        result = run_ground_search(elems)
        @test length(result) == 2
    end

    @testset "traversal through mixed resistors and voltage sources" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 2.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_c, 3.0, CONST_VOLTAGE),
            make_element(TileCoord(2,0), 1, n_c, n_d, 1.0, CONST_RESISTOR),
        ]
        result = run_ground_search(elems)
        @test length(result) == 4
    end

    @testset "multiple grounded anchors" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(2,0), 1, n_c, gnd, 3.0, CONST_VOLTAGE),
            make_element(TileCoord(2,0), 2, n_c, n_d, 1.0, CONST_RESISTOR),
        ]
        result = run_ground_search(elems)
        @test length(result) == 4
    end

    @testset "empty input" begin
        @test isempty(run_ground_search(AbsoluteElement[]))
    end

    @testset "ground_search! leaves scratch buffers clean after call" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, gnd, 2.0, CONST_RESISTOR),
        ]
        scratchpad = FlowEngine.CalculatorScratchpad()
        ground_search!(elems, scratchpad)
        @test length(elems) == 3
        @test isempty(scratchpad.groundsearch_nodeconnections)
        @test isempty(scratchpad.groundsearch_root_index)
        @test isempty(scratchpad.groundsearch_grounded_nodes)
        @test isempty(scratchpad.groundsearch_pending_nodes)
    end

    @testset "ground_search! preserves the legacy grounded traversal result" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, gnd, 2.0, CONST_RESISTOR),
        ]
        result = run_ground_search(elems)
        nodes = list_nodes(result)
        @test length(result) == 3
        @test nodes[n_a] == 2
        @test nodes[n_b] == 2
    end
end


# ===============================================================
# Phase 5: clear_dangling_dependants! Tests
# ===============================================================

@testset "clear_dangling_dependants!" begin
    n_a = nc(0, 0, HexFrame.NODE_Q_POS)
    n_b = nc(1, 0, HexFrame.NODE_Q_POS)
    n_c = nc(0, 0, HexFrame.NODE_INTERNAL_1)
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

    # Local convenience wrapper so individual tests read as simple in/out checks.
    scratch = Set{ElementID}()
    function call_clear!(elems)
        clear_dangling_dependants!(elems, scratch)
        return elems
    end

    @testset "independent elements unaffected" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
        ]
        call_clear!(elems)
        @test length(elems) == 2
    end

    @testset "dependent with controller present stays" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 1.0, V_DEP_VOLTAGE; dependent_index=2),
            make_element(TileCoord(0,0), 2, n_c, n_b, 1.0, CONST_RESISTOR),
        ]
        call_clear!(elems)
        @test length(elems) == 2
    end

    @testset "dependent with missing controller removed" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 1.0, V_DEP_VOLTAGE; dependent_index=3),
            make_element(TileCoord(0,0), 2, n_c, n_b, 1.0, CONST_RESISTOR),
        ]
        call_clear!(elems)
        @test length(elems) == 1
        @test elems[1].type == CONST_RESISTOR
    end

    @testset "mutual dependants both present stay" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 1.0, V_DEP_VOLTAGE; dependent_index=2),
            make_element(TileCoord(0,0), 2, n_b, gnd, -2.0, C_DEP_CURRENT; dependent_index=1),
        ]
        call_clear!(elems)
        @test length(elems) == 2
    end

    @testset "cascading removal" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_b, gnd, 1.0, C_DEP_CURRENT; dependent_index=3),
        ]
        call_clear!(elems)
        @test length(elems) == 1
        @test elems[1].type == CONST_VOLTAGE
    end

    @testset "empty input" begin
        elems = AbsoluteElement[]
        call_clear!(elems)
        @test isempty(elems)
    end

    @testset "original order preserved" begin
        # Three elements: first and third survive, second is removed.
        # Original index positions of survivors must be maintained.
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_b, gnd, 1.0, C_DEP_CURRENT; dependent_index=9),
            make_element(TileCoord(0,0), 3, n_c, n_b, 1.0, CONST_RESISTOR),
        ]
        ids_before = [elems[1].id, elems[3].id]
        call_clear!(elems)
        @test length(elems) == 2
        @test elems[1].id == ids_before[1]
        @test elems[2].id == ids_before[2]
    end

    @testset "scratch set is empty after call" begin
        elems = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
        ]
        call_clear!(elems)
        @test isempty(scratch)
    end

    @testset "scratch set reusable across consecutive calls" begin
        # First call: removes a dependant
        elems1 = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 1.0, V_DEP_VOLTAGE; dependent_index=9),
            make_element(TileCoord(0,0), 2, n_b, n_c, 1.0, CONST_RESISTOR),
        ]
        call_clear!(elems1)
        @test length(elems1) == 1  # dependant removed

        # Second call with different input: stale IDs from call 1 must not affect call 2
        elems2 = [
            make_element(TileCoord(1,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(1,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
        ]
        call_clear!(elems2)
        @test length(elems2) == 2  # no removals — stale IDs from call 1 must not affect this
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
    n_int = nc(0, 0, HexFrame.NODE_INTERNAL_1)
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

    "Run the same iterative pruning pipeline as update_map! in HexFlowCalculator"
    function run_prune_pipeline(elements::Vector{AbsoluteElement})
        pruned = elements
        scratch = Set{ElementID}()
        last_hash::UInt64 = 0
        while last_hash != hash(pruned)
            pruned = run_prune(pruned)
            pruned = run_ground_search(pruned)
            last_hash = hash(pruned)
            clear_dangling_dependants!(pruned, scratch)
        end
        return pruned
    end

    @testset "simple grounded circuit survives" begin
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
        n_int2 = nc(3, 0, HexFrame.NODE_INTERNAL_1)
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
        n_pump_int = nc(5, 0, HexFrame.NODE_INTERNAL_1)
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
            make_element(TileCoord(4,0), 1, nc(4,0, HexFrame.NODE_INTERNAL_1), gnd, 3.0, CONST_VOLTAGE),
            make_element(TileCoord(4,0), 2, nc(4,0, HexFrame.NODE_INTERNAL_1), n_qpos, 2.0, CONST_RESISTOR),
            # Pipe + nozzle
            make_element(TileCoord(6,0), 1, n_qneg, n_pipe_out, 1.0, CONST_RESISTOR),
            make_element(TileCoord(7,0), 1, n_pipe_out, gnd, 0.5, CONST_RESISTOR),
            # Gas tank feeding turbine S_POS
            make_element(TileCoord(8,0), 1, nc(8,0, HexFrame.NODE_INTERNAL_1), gnd, 2.0, CONST_VOLTAGE),
            make_element(TileCoord(8,0), 2, nc(8,0, HexFrame.NODE_INTERNAL_1), n_spos, 2.0, CONST_RESISTOR),
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
            make_element(TileCoord(9,0), 1, nc(9,0, HexFrame.NODE_INTERNAL_1), gnd, 8.0, CONST_VOLTAGE),
            make_element(TileCoord(9,0), 2, nc(9,0, HexFrame.NODE_INTERNAL_1), n_dq_pos, 4.0, CONST_RESISTOR),
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
        derived.filteredelements = elements
        derived.filterednodes = list_nodes(elements)
        MNA_indexnodes!(mna, derived)
        MNA_splitelements!(mna, derived)
        MNA_updateA!(mna)
        mna.mat_Z = MNA_getZ(mna)
        MNA_solve!(mna)
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
        n_int = nc(0, 0, HexFrame.NODE_INTERNAL_1)
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
        derived.filteredelements = elements
        derived.filterednodes = list_nodes(elements)
        MNA_indexnodes!(mna, derived)
        MNA_splitelements!(mna, derived)
        MNA_updateA!(mna)
        mna.mat_Z = MNA_getZ(mna)
        MNA_solve!(mna)
        return (mna, derived)
    end

    @testset "CCCS (turbopump-like)" begin
        n_pump_int = nc(5, 0, HexFrame.NODE_INTERNAL_1)
        n_qpos = nc(5, 0, HexFrame.NODE_Q_POS)
        n_qneg = nc(5, 0, HexFrame.NODE_Q_NEG)
        n_spos = nc(5, 0, HexFrame.NODE_S_POS)
        n_tank_int = nc(4, 0, HexFrame.NODE_INTERNAL_1)
        n_load = nc(7, 0, HexFrame.NODE_Q_POS)
        n_gas_int = nc(8, 0, HexFrame.NODE_INTERNAL_1)

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
        n_liq_int = nc(9, 0, HexFrame.NODE_INTERNAL_1)
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
# Phase 8.5: In-Place A Matrix and Z Vector Tests
# ===============================================================

@testset "in-place A matrix construction" begin
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)
    n_a = nc(0, 0, HexFrame.NODE_Q_POS)
    n_b = nc(1, 0, HexFrame.NODE_Q_POS)
    n_c = nc(2, 0, HexFrame.NODE_Q_POS)

    "Build an MNA state suitable for in-place A matrix tests"
    function build_mna(elements::Vector{AbsoluteElement})
        derived = DerivedMapState()
        mna = MNA_State()
        derived.filteredelements = elements
        derived.filterednodes = list_nodes(elements)
        MNA_indexnodes!(mna, derived)
        MNA_splitelements!(mna, derived)
        return mna
    end

    base_elements = [
        make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
        make_element(TileCoord(0,0), 2, n_a, n_b, 2.0, CONST_RESISTOR),
        make_element(TileCoord(1,0), 1, n_b, gnd, 1.0, CONST_CURRENT),
    ]

    @testset "MNA_buildA_sparse matches MNA_getA numerically" begin
        mna = build_mna(base_elements)
        A_sparse = MNA_buildA_sparse(mna)
        A_lu = MNA_getA(mna)
        # Solve same Z with both to verify equivalence
        mna.mat_Z = MNA_getZ(mna)
        x_sparse = A_sparse \ vec(mna.mat_Z)
        x_lu = A_lu \ vec(mna.mat_Z)
        @test x_sparse ≈ x_lu
    end

    @testset "MNA_updateA! produces correct LU factorisation" begin
        mna = build_mna(base_elements)
        # First call triggers cold path (rebuild)
        MNA_updateA!(mna)
        mna.mat_Z = MNA_getZ(mna)
        x_update = mna.a_cache.mat_A_lu \ vec(mna.mat_Z)
        # Compare to fresh MNA_getA
        mna2 = build_mna(base_elements)
        mna2.a_cache.mat_A_lu = MNA_getA(mna2)
        mna2.mat_Z = MNA_getZ(mna2)
        x_fresh = mna2.a_cache.mat_A_lu \ vec(mna2.mat_Z)
        @test x_update ≈ x_fresh
    end

    @testset "MNA_updateA! skips LU when values unchanged" begin
        mna = build_mna(base_elements)
        MNA_updateA!(mna) # cold path
        old_hash = mna.a_cache.value_hash
        MNA_updateA!(mna) # hot path — same values
        @test mna.a_cache.value_hash == old_hash # hash unchanged means LU was skipped
    end

    @testset "MNA_updateA! detects value changes" begin
        mna = build_mna(base_elements)
        MNA_updateA!(mna)
        old_hash = mna.a_cache.value_hash

        # Change a resistor value (simulates valve conductance changing)
        resistor_id = ElementID(TileCoord(0, 0), UInt8(2))
        resistor = mna.resistors[resistor_id]
        mna.resistors[resistor_id] = AbsoluteElement(
            connections = resistor.connections,
            value = 3.0,
            type = resistor.type,
            id = resistor.id,
            dependent_id = resistor.dependent_id,
            active = resistor.active,
        )
        MNA_updateA!(mna)
        @test mna.a_cache.value_hash != old_hash # value changed → LU was redone
    end

    @testset "sparse CSC storage is canonical across equivalent raw stamp orderings" begin
        I1 = [3, 1, 2, 1, 3, 2]
        J1 = [2, 1, 1, 1, 2, 1]
        V1 = [5.0, 1.0, 2.0, -1.0, -5.0, 4.0]

        I2 = reverse(I1)
        J2 = reverse(J1)
        V2 = reverse(V1)

        A1 = sparse(I1, J1, V1, 3, 3, +)
        A2 = sparse(I2, J2, V2, 3, 3, +)

        @test A1.colptr == A2.colptr
        @test rowvals(A1) == rowvals(A2)
        @test nonzeros(A1) == nonzeros(A2)
    end

    @testset "MNA_buildA_sparse canonicalises equivalent element ordering" begin
        mna1 = build_mna(base_elements)
        mna2 = build_mna(reverse(base_elements))

        A1 = MNA_buildA_sparse(mna1)
        A2 = MNA_buildA_sparse(mna2)

        @test A1.colptr == A2.colptr
        @test rowvals(A1) == rowvals(A2)
        @test nonzeros(A1) == nonzeros(A2)
    end

    @testset "sparse combine can produce stored explicit zeros" begin
        A = sparse([1, 1], [1, 1], [1.0, -1.0], 1, 1, +)

        @test nnz(A) == 1
        @test count(!iszero, A) == 0
        @test nonzeros(A) == [0.0]
    end

    @testset "KLU numeric refactor throws on stored-zero warm transition" begin
        matrix1 = sparse([1, 2, 1, 2], [1, 1, 2, 2], [-1.0, -0.1, 1.0, -0.5], 2, 2)
        matrix2 = sparse([1, 2, 1, 2], [1, 1, 2, 2], [0.0, -0.1, 2.0, -0.5], 2, 2)

        factor = klu(matrix1)
        @test_throws SingularException klu!(factor, nonzeros(matrix2))
    end

    @testset "real stamped MNA can change CSC zero-state without changing CSC structure" begin
        resistor_id = ElementID(TileCoord(0, 0), UInt8(2))

        elems_nonzero = copy(base_elements)
        elems_zero = [
            base_elements[1],
            make_element(TileCoord(0,0), 2, n_a, n_b, 0.0, CONST_RESISTOR),
            base_elements[3],
        ]

        mna_nonzero = build_mna(elems_nonzero)
        mna_zero = build_mna(elems_zero)

        A_nonzero = MNA_buildA_sparse(mna_nonzero)
        A_zero = MNA_buildA_sparse(mna_zero)

        @test A_nonzero.colptr == A_zero.colptr
        @test rowvals(A_nonzero) == rowvals(A_zero)
        @test map(iszero, nonzeros(A_nonzero)) != map(iszero, nonzeros(A_zero))
        @test !any(iszero, nonzeros(A_nonzero))
        @test any(iszero, nonzeros(A_zero))
    end

    @testset "real stamped zero-toggle witness becomes singular on cold rebuild" begin
        elems_zero = [
            base_elements[1],
            make_element(TileCoord(0,0), 2, n_a, n_b, 0.0, CONST_RESISTOR),
            base_elements[3],
        ]

        mna_zero = build_mna(elems_zero)
        @test_throws SingularException MNA_updateA!(mna_zero)
    end

    @testset "MNA_updateA! detects topology changes" begin
        mna = build_mna(base_elements)
        MNA_updateA!(mna)
        old_structure_hash = mna.a_cache.structure_hash

        # Add an extra element → topology changes
        extended_elements = [
            base_elements...,
            make_element(TileCoord(2,0), 1, n_b, n_c, 4.0, CONST_RESISTOR),
        ]
        derived = DerivedMapState()
        derived.filteredelements = extended_elements
        derived.filterednodes = list_nodes(extended_elements)
        MNA_indexnodes!(mna, derived)
        MNA_splitelements!(mna, derived)
        MNA_updateA!(mna)
        @test mna.a_cache.structure_hash != old_structure_hash
    end

    @testset "MNA_stamp_A_ijv! produces correct IJV entries" begin
        mna = build_mna(base_elements)
        MNA_stamp_A_ijv!(mna)
        cache = mna.a_cache
        # IJV vectors should be non-empty and consistent lengths
        @test length(cache.ijv_I) > 0
        @test length(cache.ijv_I) == length(cache.ijv_J) == length(cache.ijv_V)
        # Build sparse from IJV and compare to the reference build path
        MNA_construct_A_sparse!(mna)
        A_ijv = Matrix(cache.mat_A_sparse)
        # Compare against a fresh solve via MNA_getA
        mna2 = build_mna(base_elements)
        A_ref = Matrix(MNA_buildA_sparse(mna2))
        @test A_ijv ≈ A_ref
    end

    @testset "compute_A_hashes detects structure vs value changes" begin
        mna = build_mna(base_elements)
        MNA_stamp_A_ijv!(mna)
        MNA_construct_A_sparse!(mna)
        sh1, vh1 = compute_A_hashes(mna.a_cache)

        # Same elements → same hashes
        MNA_stamp_A_ijv!(mna)
        MNA_construct_A_sparse!(mna)
        sh2, vh2 = compute_A_hashes(mna.a_cache)
        @test sh1 == sh2
        @test vh1 == vh2

        # Change a value → value hash changes, structure hash unchanged
        resistor_id = ElementID(TileCoord(0, 0), UInt8(2))
        resistor = mna.resistors[resistor_id]
        mna.resistors[resistor_id] = AbsoluteElement(
            connections = resistor.connections,
            value = 9.0,
            type = resistor.type,
            id = resistor.id,
            dependent_id = resistor.dependent_id,
            active = resistor.active,
        )
        MNA_stamp_A_ijv!(mna)
        MNA_construct_A_sparse!(mna)
        sh3, vh3 = compute_A_hashes(mna.a_cache)
        @test sh3 == sh1  # structure unchanged
        @test vh3 != vh1  # value changed
    end
end

@testset "in-place Z vector" begin
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)
    n_a = nc(0, 0, HexFrame.NODE_Q_POS)
    n_b = nc(1, 0, HexFrame.NODE_Q_POS)

    elements = [
        make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
        make_element(TileCoord(0,0), 2, n_a, n_b, 2.0, CONST_RESISTOR),
        make_element(TileCoord(1,0), 1, n_b, gnd, 1.0, CONST_CURRENT),
    ]

    derived = DerivedMapState()
    mna = MNA_State()
    derived.filteredelements = elements
    derived.filterednodes = list_nodes(elements)
    MNA_indexnodes!(mna, derived)
    MNA_splitelements!(mna, derived)

    @testset "MNA_getZ! matches MNA_getZ" begin
        z_alloc = MNA_getZ(mna)
        MNA_getZ!(mna)
        @test mna.mat_Z ≈ z_alloc
    end

    @testset "MNA_getZ! reuses buffer on repeated calls" begin
        MNA_getZ!(mna)
        buffer_ptr = pointer(mna.mat_Z)
        MNA_getZ!(mna)
        @test pointer(mna.mat_Z) == buffer_ptr # same array, no reallocation
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
        scratch = Set{ElementID}()
        last_hash::UInt64 = 0
        while last_hash != hash(pruned)
            pruned = run_prune(pruned)
            pruned = run_ground_search(pruned)
            last_hash = hash(pruned)
            clear_dangling_dependants!(pruned, scratch)
        end
        return pruned
    end

    "Run full MNA pipeline on pre-pruned elements"
    function solve_circuit(elements::Vector{AbsoluteElement})
        derived = DerivedMapState()
        mna = MNA_State()
        derived.filteredelements = elements
        derived.filterednodes = list_nodes(elements)
        if isempty(derived.filterednodes)
            return (mna, derived)
        end
        MNA_indexnodes!(mna, derived)
        MNA_splitelements!(mna, derived)
        MNA_updateA!(mna)
        mna.mat_Z = MNA_getZ(mna)
        MNA_solve!(mna)
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

        n_tp_int  = nc(17, -16, HexFrame.NODE_INTERNAL_1)
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

        n_tp_int  = nc(17, -16, HexFrame.NODE_INTERNAL_1)
        n_tp_qpos = nc(17, -16, HexFrame.NODE_Q_POS)
        n_tp_qneg = nc(17, -16, HexFrame.NODE_Q_NEG)
        n_tp_spos = nc(17, -16, HexFrame.NODE_S_POS)
        n_dc_qpos = nc(16, -16, HexFrame.NODE_Q_POS)
        n_dc_qneg = nc(15, -16, HexFrame.NODE_Q_POS)
        n_liq_int = nc(14, -16, HexFrame.NODE_INTERNAL_1)
        n_gas_int = nc(18, -16, HexFrame.NODE_INTERNAL_1)
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
        nodeconnections = Dict{NodeCoord, FlowEngine.ConnectionVect}()
        elements = [
            make_element(TileCoord(0,0), 1, n_a, n_b, 1.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_c, 1.0, CONST_RESISTOR),
        ]
        build_node_connection_map!(nodeconnections, elements)
        @test n_b in nodeconnections[n_a]
        @test n_a in nodeconnections[n_b]
        @test n_c in nodeconnections[n_b]
        @test n_b in nodeconnections[n_c]
    end

    @testset "grounded elements excluded from connections" begin
        nodeconnections = Dict{NodeCoord, FlowEngine.ConnectionVect}()
        elements = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
        ]
        build_node_connection_map!(nodeconnections, elements)
        @test !haskey(nodeconnections, n_a) || isempty(nodeconnections[n_a])
    end

    @testset "default builder keeps zero-conductance links" begin
        nodeconnections = Dict{NodeCoord, FlowEngine.ConnectionVect}()
        elements = [
            make_element(TileCoord(0,0), 1, n_a, n_b, 0.0, CONST_RESISTOR),
        ]
        build_node_connection_map!(nodeconnections, elements)
        @test n_b in nodeconnections[n_a]
        @test n_a in nodeconnections[n_b]
    end

    @testset "filtered builder excludes current and zero-conductance edges" begin
        nodeconnections = Dict{NodeCoord, FlowEngine.ConnectionVect}()
        elements = [
            make_element(TileCoord(0,0), 1, n_a, n_b, 0.0, CONST_RESISTOR),
            make_element(TileCoord(1,0), 1, n_b, n_c, 1.0, CONST_RESISTOR),
            make_element(TileCoord(2,0), 1, n_c, gnd, 1.0, CONST_CURRENT),
        ]
        build_node_connection_map!(
            nodeconnections,
            elements;
            element_filter_function = FlowEngine._include_ground_search_connection_element,
        )
        @test !haskey(nodeconnections, n_a)
        @test n_c in nodeconnections[n_b]
        @test !haskey(nodeconnections, gnd)
    end

    @testset "ground neighbour mode keeps grounded degree without ground key" begin
        nodeconnections = Dict{NodeCoord, FlowEngine.ConnectionVect}()
        elements = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(0,0), 2, n_a, n_b, 1.0, CONST_RESISTOR),
        ]

        build_node_connection_map!(
            nodeconnections,
            elements;
            include_ground_neighbour = true,
            deduplicate_neighbours = false,
        )

        @test FlowEngine.GROUND_NODE in nodeconnections[n_a]
        @test !haskey(nodeconnections, FlowEngine.GROUND_NODE)
        @test n_b in nodeconnections[n_a]
    end
end

@testset "index_grounded_source_elements!" begin
    n_a = nc(0, 0, HexFrame.NODE_Q_POS)
    n_b = nc(1, 0, HexFrame.NODE_Q_POS)
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)

    @testset "indexes reversed grounded elements by default" begin
        source_index = Dict{NodeCoord, Int}()
        elements = [
            make_element(TileCoord(0,0), 1, gnd, n_a, 2.0, CONST_RESISTOR),
        ]
        index_grounded_source_elements!(source_index, elements)
        @test source_index[n_a] == 1
    end

    @testset "filter can exclude current sources" begin
        source_index = Dict{NodeCoord, Int}()
        elements = [
            make_element(TileCoord(0,0), 1, n_a, gnd, 5.0, CONST_VOLTAGE),
            make_element(TileCoord(1,0), 1, n_b, gnd, 1.0, CONST_CURRENT),
        ]
        index_grounded_source_elements!(
            source_index,
            elements;
            element_filter_function = element -> element.type != CONST_CURRENT,
        )
        @test source_index[n_a] == 1
        @test !haskey(source_index, n_b)
    end
end

@testset "Multi-internal-node infrastructure" begin
    gnd = NodeCoord(TileCoord(0, 0), HexFrame.GROUND)
    T = TileCoord(0, 0)
    n_qpos = nc(0, 0, HexFrame.NODE_Q_POS)

    function solve_circuit_mi(elements::Vector{AbsoluteElement})
        derived = DerivedMapState()
        mna = MNA_State()
        derived.filteredelements = elements
        derived.filterednodes = list_nodes(elements)
        MNA_indexnodes!(mna, derived)
        MNA_splitelements!(mna, derived)
        MNA_updateA!(mna)
        mna.mat_Z = MNA_getZ(mna)
        MNA_solve!(mna)
        return (mna, derived)
    end

    @testset "Two internal nodes wired in series resolve correctly" begin
        # Vsource: Q_POS → GROUND, V = 10.0
        # R1 = 1.0: Q_POS → INTERNAL_1
        # R2 = 1.0: INTERNAL_1 → INTERNAL_2
        # R3 = 1.0: INTERNAL_2 → GROUND
        n_int1 = nc(0, 0, HexFrame.NODE_INTERNAL_1)
        n_int2 = nc(0, 0, HexFrame.NODE_INTERNAL_2)

        elems = [
            make_element(T, 1, n_qpos, gnd, 10.0, CONST_VOLTAGE),
            make_element(T, 2, n_qpos, n_int1, 1.0, CONST_RESISTOR),
            make_element(T, 3, n_int1, n_int2, 1.0, CONST_RESISTOR),
            make_element(T, 4, n_int2, gnd, 1.0, CONST_RESISTOR),
        ]
        mna, _ = solve_circuit_mi(elems)
        
        # With three equal resistors in series, voltage divider gives:
        # V_int1 = 10 * (2/3), V_int2 = 10 * (1/3)
        @test mna.node_voltages[n_int1] ≈ 10.0 * (2.0/3.0)
        @test mna.node_voltages[n_int2] ≈ 10.0 * (1.0/3.0)
        @test length(mna.node_voltages) >= 3  # At least Q_POS, INTERNAL_1, INTERNAL_2
    end

    @testset "Three internal nodes are all distinct" begin
        # Extend with four resistors in series spanning Q_POS → INT_1 → INT_2 → INT_3 → GROUND
        n_int1 = nc(0, 0, HexFrame.NODE_INTERNAL_1)
        n_int2 = nc(0, 0, HexFrame.NODE_INTERNAL_2)
        n_int3 = nc(0, 0, HexFrame.NODE_INTERNAL_3)

        elems = [
            make_element(T, 1, n_qpos, gnd, 10.0, CONST_VOLTAGE),
            make_element(T, 2, n_qpos, n_int1, 1.0, CONST_RESISTOR),
            make_element(T, 3, n_int1, n_int2, 1.0, CONST_RESISTOR),
            make_element(T, 4, n_int2, n_int3, 1.0, CONST_RESISTOR),
            make_element(T, 5, n_int3, gnd, 1.0, CONST_RESISTOR),
        ]
        mna, _ = solve_circuit_mi(elems)
        
        # With four equal resistors in series, voltage divider gives:
        @test mna.node_voltages[n_int1] ≈ 10.0 * (3.0/4.0)
        @test mna.node_voltages[n_int2] ≈ 10.0 * (2.0/4.0)
        @test mna.node_voltages[n_int3] ≈ 10.0 * (1.0/4.0)
    end

    @testset "Internal nodes on different tiles do not alias" begin
        # Build the same series divider on two adjacent tiles T1 and T2,
        # both using NODE_INTERNAL_2, drive with different voltages
        T1 = TileCoord(0, 0)
        T2 = TileCoord(1, 0)
        n_int2_T1 = nc(0, 0, HexFrame.NODE_INTERNAL_2)
        n_int2_T2 = nc(1, 0, HexFrame.NODE_INTERNAL_2)
        n_qpos_T1 = nc(0, 0, HexFrame.NODE_Q_POS)
        n_qpos_T2 = nc(1, 0, HexFrame.NODE_Q_POS)
        gnd_T1 = nc(0, 0, HexFrame.GROUND)

        elems = [
            # T1: 10V source
            make_element(T1, 1, n_qpos_T1, gnd_T1, 10.0, CONST_VOLTAGE),
            make_element(T1, 2, n_qpos_T1, n_int2_T1, 1.0, CONST_RESISTOR),
            make_element(T1, 3, n_int2_T1, gnd_T1, 1.0, CONST_RESISTOR),
            # T2: 4V source
            make_element(T2, 1, n_qpos_T2, gnd_T1, 4.0, CONST_VOLTAGE),
            make_element(T2, 2, n_qpos_T2, n_int2_T2, 1.0, CONST_RESISTOR),
            make_element(T2, 3, n_int2_T2, gnd_T1, 1.0, CONST_RESISTOR),
        ]
        mna, _ = solve_circuit_mi(elems)
        
        # Each divider should give half its source voltage
        @test mna.node_voltages[n_int2_T1] ≈ 5.0
        @test mna.node_voltages[n_int2_T2] ≈ 2.0
        @test mna.node_voltages[n_int2_T1] !== mna.node_voltages[n_int2_T2]
    end

    @testset "is_proper returns true for all three internal node variants" begin
        @test HexFrame.is_proper(HexFrame.NODE_INTERNAL_1)
        @test HexFrame.is_proper(HexFrame.NODE_INTERNAL_2)
        @test HexFrame.is_proper(HexFrame.NODE_INTERNAL_3)
    end

    @testset "get_adjacent_tiles_for_node returns the correct variant" begin
        for dir in (HexFrame.NODE_INTERNAL_1, HexFrame.NODE_INTERNAL_2, HexFrame.NODE_INTERNAL_3)
            result = HexFrame.get_adjacent_tiles_for_node(NodeCoord(TileCoord(0, 0), dir))
            @test result == ((TileCoord(0, 0), dir),)
        end
    end
end

println("All FlowEngine tests complete")
