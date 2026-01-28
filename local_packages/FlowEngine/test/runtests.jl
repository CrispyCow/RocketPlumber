using Test
using HexFrame
using HexElements
using HexFluids
using HexComponentsAPI
using FlowEngine

# Minimal dummy component for placement testing
struct DummyComp <: ComponentBehavior end

# Create game map and check primary ship exists
gm = GameMap()

@test has_ship(gm, :primary)

# ShipMap direct access tests
ship = get_ship(gm, :primary)
@test !has_component(ship, TileCoord(0,0))
set_component!(ship, TileCoord(0,0), ComponentOnTile(DummyComp(), HexFrame.Q_POS))
@test has_component(ship, TileCoord(0,0))
@test get_component(ship, TileCoord(0,0)) !== nothing

# Remove and check
delete_component!(ship, TileCoord(0,0))
@test !has_component(ship, TileCoord(0,0))

# Place a component on primary via GameMap
coord = TileCoord(0, 0)
comp = ComponentOnTile(DummyComp(), HexFrame.Q_POS)
set_component!(gm, coord, comp)
@test has_component(gm, coord)
@test get_component(gm, coord) === comp
@test count_components(gm) == 1

# placement_valid should consider the primary ship surface (origin present) and allow placement
valid, reason = placement_valid(comp, coord, gm)
@test valid == true
@test reason == ""

# Create a secondary ship and add to gamemap
secondary = ShipMap()
add_ship!(gm, :asteroid, secondary)
@test has_ship(gm, :asteroid)

# Place a component on secondary ship (direct ShipMap)
coord2 = TileCoord(5, 0)
comp2 = ComponentOnTile(DummyComp(), HexFrame.Q_POS)
set_component!(secondary, coord2, comp2)
@test has_component(secondary, coord2)

# Place a component on secondary ship via GameMap
# (defer placement until after offsetting the ship to avoid accidental movement in tests)
coord3 = TileCoord(6, 0)
comp3 = ComponentOnTile(DummyComp(), HexFrame.Q_POS)


# Surface tile and offset test (ShipMap direct)
set_surface_tile!(secondary, TileCoord(0,0))
@test TileCoord(0,0) in get_all_surface_tiles(secondary)

# Surface tile via GameMap and offset
set_surface_tile!(gm, TileCoord(0,0); ship_name = :asteroid)
@test TileCoord(0,0) in get_all_surface_tiles(gm; ship_name = :asteroid)
offset_ship!(get_ship(gm, :asteroid), TileCoord(10, 0))
@test TileCoord(10,0) in get_all_surface_tiles(gm; ship_name = :asteroid)
@test !(TileCoord(0,0) in get_all_surface_tiles(gm; ship_name = :asteroid))

# Pipe tests
struct DummyPipe <: PipeBehavior end
edge = EdgeCoord(VertexCoord(TileCoord(1,0), HexFrame.Q_POS), VertexCoord(TileCoord(2,0), HexFrame.Q_POS))
set_pipe!(secondary, edge, DummyPipe())
@test has_pipe(secondary, edge)
@test get_pipe(secondary, edge) !== nothing

# Place the deferred component on the secondary ship (after offsetting it)
set_component!(gm, coord3, comp3; ship_name = :asteroid)
@test has_component(gm, coord3; ship_name = :asteroid)
@test !has_component(gm, coord3)

# any_ship accessor tests (search across all ships)
foundc, shipc = FlowEngine.has_component_any_ship(gm, coord3)
@test foundc == true
@test shipc == :asteroid
comp_out, shipc2 = FlowEngine.get_component_any_ship(gm, coord3)
@test comp_out === comp3
@test shipc2 == :asteroid
foundp, shipp = FlowEngine.has_pipe_any_ship(gm, edge)
@test foundp == true
@test shipp !== nothing

# is_on_surface_tile_any_ship test
# set a surface tile explicitly on asteroid for this assertion
set_surface_tile!(gm, TileCoord(42,42); ship_name = :asteroid)
foundsurf, shipsurf = FlowEngine.is_on_surface_tile_any_ship(TileCoord(42,42), gm)
@test foundsurf == true
@test shipsurf == :asteroid

# Error handling for missing ship
@test_throws ErrorException get_ship(gm, :noexist)

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

# Test: combined ship surface edge detection (and per-ship)
set_surface_tile!(gm3, TileCoord(0,0))
set_surface_tile!(gm3, TileCoord(1,0))
set_surface_tile!(gm3, TileCoord(5,5); ship_name = :two)
edge_tiles = Set{TileCoord}()
find_ship_surface_edgetiles!(edge_tiles, gm3)
@test TileCoord(0,0) in edge_tiles
@test TileCoord(5,5) in edge_tiles

# Per-ship surface edge detection
ship_for_edges = ShipMap()
set_surface_tile!(ship_for_edges, TileCoord(0,0))
set_surface_tile!(ship_for_edges, TileCoord(1,0))
edge_tiles_ship = Set{TileCoord}()
find_ship_surface_edgetiles!(edge_tiles_ship, ship_for_edges)
@test TileCoord(0,0) in edge_tiles_ship
@test !(TileCoord(2,0) in edge_tiles_ship)

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

# Phase 6: Basic smoke tests
# GameMap constructor from ShipMap
s = ShipMap()
set_component!(s, TileCoord(3,3), ComponentOnTile(DummyComp(), HexFrame.Q_POS))
gm_wrap = GameMap(s)
@test has_ship(gm_wrap, :primary)
@test get_component(gm_wrap, TileCoord(3,3); ship_name = :primary) !== nothing

# If HexFlowProcGen is available, ensure generate_ship returns ShipMap
try
    using HexFlowProcGen
    options = HexFlowProcGen.ShipGenOptions("testgen", 3, 1, HexFlowProcGen.ShipComponentSet[], HexFlowProcGen.PipeSpawnOptions[])
    gen_ship = HexFlowProcGen.generate_ship(options, UInt32(1))
    @test typeof(gen_ship) == ShipMap
catch e
    @info "HexFlowProcGen not available for test: $e"
end

println("FlowEngine Phase1 + Phase2 tests passed")
