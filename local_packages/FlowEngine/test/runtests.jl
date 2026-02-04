using Test
using HexFrame
using HexElements
using HexFluids
using HexComponentsAPI
using FlowEngine
using FlowMap

# -----------------------------
# Phase 2: MNA & Derived State tests
# -----------------------------

# Minimal pipe implementation for producing elements
struct TestPipe <: PipeBehavior end
import HexComponentsAPI: get_conductance, get_pipe_tunables, set_pipe_tunables, render_pipe_base!
get_conductance(::TestPipe) = 1.0
get_pipe_tunables(::TestPipe) = ()
set_pipe_tunables(::TestPipe, tunables) = TestPipe()
function render_pipe_base!(queue::AbstractVector, behav::TestPipe; kwargs...)
    return nothing
end

# Test: list_elements collects from all ships (and per-ship)
gm2 = GameMap()
edge1 = EdgeCoord(VertexCoord(TileCoord(1,0), HexFrame.Q_POS), VertexCoord(TileCoord(2,0), HexFrame.Q_POS))
set_pipe!(gm2, edge1, TestPipe())
sec = ShipMap()
add_ship!(gm2, :sec, sec)
edge2 = EdgeCoord(VertexCoord(TileCoord(5,0), HexFrame.Q_POS), VertexCoord(TileCoord(6,0), HexFrame.Q_POS))
set_pipe!(gm2, edge2, TestPipe(); ship_name = :sec)
els = list_elements(gm2)
ids = Set(e.id for e in els)
@test HexElements.ElementID(edge1) in ids
@test HexElements.ElementID(edge2) in ids

# Per-ship list_elements: should only include elements from that ship
els_sec = list_elements(get_ship(gm2, :sec))
ids_sec = Set(e.id for e in els_sec)
@test HexElements.ElementID(edge2) in ids_sec
@test !(HexElements.ElementID(edge1) in ids_sec)

# Test: update_components! calls update_flowbehav! for all ships (and per-ship)
struct DummyCompUpdate <: ComponentBehavior end
import HexComponentsAPI: update_flowbehav!
function update_flowbehav!(::DummyCompUpdate; tile::TileCoord, mna_state::MNA_State, kwargs...)
    mna_state.node_voltages[NodeCoord(tile, HexFrame.NODE_INTERNAL)] = 3.21
    return nothing
end

# Per-GameMap update_components!
gm3 = GameMap()
set_component!(gm3, TileCoord(0,0), ComponentOnTile(DummyCompUpdate(), HexFrame.Q_POS))
sec2 = ShipMap()
add_ship!(gm3, :two, sec2)
set_component!(gm3, TileCoord(5,5), ComponentOnTile(DummyCompUpdate(), HexFrame.Q_POS); ship_name = :two)
ms = MNA_State()
update_components!(gm3, ms)
@test NodeCoord(TileCoord(0,0), HexFrame.NODE_INTERNAL) in keys(ms.node_voltages)
@test NodeCoord(TileCoord(5,5), HexFrame.NODE_INTERNAL) in keys(ms.node_voltages)
@test ms.node_voltages[NodeCoord(TileCoord(0,0), HexFrame.NODE_INTERNAL)] ≈ 3.21
@test ms.node_voltages[NodeCoord(TileCoord(5,5), HexFrame.NODE_INTERNAL)] ≈ 3.21

# Per-Ship update_components!
ship_single = ShipMap()
set_component!(ship_single, TileCoord(7,7), ComponentOnTile(DummyCompUpdate(), HexFrame.Q_POS))
ms2 = MNA_State()
update_components!(ship_single, ms2)
@test NodeCoord(TileCoord(7,7), HexFrame.NODE_INTERNAL) in keys(ms2.node_voltages)
@test ms2.node_voltages[NodeCoord(TileCoord(7,7), HexFrame.NODE_INTERNAL)] ≈ 3.21

# Test: get_node_fluid_tags checks all ships (and per-ship)
struct DummyFluidComp <: ComponentBehavior end
import HexComponentsAPI: get_fluidtags
function get_fluidtags(::DummyFluidComp)
    return NodeFluidTags(NODE_INTERNAL = HexFluids.COLD_GAS)
end
set_component!(gm3, TileCoord(10,10), ComponentOnTile(DummyFluidComp(), HexFrame.Q_POS); ship_name = :two)
ctag = get_node_fluid_tags(NodeCoord(TileCoord(10,10), HexFrame.NODE_INTERNAL), gm3)
@test ctag[1] === HexFluids.COLD_GAS

# Per-ship node fluid tags
ship_fluid = ShipMap()
set_component!(ship_fluid, TileCoord(20,20), ComponentOnTile(DummyFluidComp(), HexFrame.Q_POS))
ptag = get_node_fluid_tags(NodeCoord(TileCoord(20,20), HexFrame.NODE_INTERNAL), ship_fluid)
@test ptag[1] === HexFluids.COLD_GAS

println("FlowEngine Phase2 tests passed")
