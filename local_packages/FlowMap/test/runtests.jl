using Test
using HexFrame
using HexElements
using HexFluids
using HexComponentsAPI
using FlowMap

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
foundc, shipc = has_component_any_ship(gm, coord3)
@test foundc == true
@test shipc == :asteroid
comp_out, shipc2 = get_component_any_ship(gm, coord3)
@test comp_out === comp3
@test shipc2 == :asteroid
foundp, shipp = has_pipe_any_ship(gm, edge)
@test foundp == true
@test shipp !== nothing

# is_on_surface_tile_any_ship test
# set a surface tile explicitly on asteroid for this assertion
set_surface_tile!(gm, TileCoord(42,42); ship_name = :asteroid)
foundsurf, shipsurf = is_on_surface_tile_any_ship(TileCoord(42,42), gm)
@test foundsurf == true
@test shipsurf == :asteroid

# Error handling for missing ship
@test_throws ErrorException get_ship(gm, :noexist)

# Test: combined ship surface edge detection (and per-ship)
set_surface_tile!(gm, TileCoord(0,0))
set_surface_tile!(gm, TileCoord(1,0))
set_surface_tile!(gm, TileCoord(5,5); ship_name = :asteroid)
edge_tiles = Set{TileCoord}()
find_ship_surface_edgetiles!(edge_tiles, gm)
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

println("FlowMap Phase1 tests passed")

# -----------------------------
# Docking status tests
# -----------------------------

# Default docking status on new gamemap/ship
gm4 = GameMap()
@test typeof(get_docking_status(get_ship(gm4, :primary))) == ConnectedDockStat
@test get_ship_render_offset(gm4, :primary) == AxialCoord(0.0, 0.0)

# Approaching transition -> Connected
s = ShipMap()
add_ship!(gm4, :a, s)
set_docking_status!(s, ApproachingDockStat(HexFrame.AxialCoord(3.0, 0.0), HexFrame.AxialCoord(0.0, 0.0), 2.0, HexFrame.Q_POS))
for i in 1:10
    update_docking!(gm4; ship_name = :a)
end
@test typeof(get_docking_status(get_ship(gm4, :a))) == ConnectedDockStat

# Departing removal
s2 = ShipMap()
add_ship!(gm4, :b, s2)
set_docking_status!(s2, DepartingDockStat(HexFrame.AxialCoord(0.0, 0.0), HexFrame.AxialCoord(4.0, 0.0), 2.0, HexFrame.Q_POS))
for i in 1:10
    update_docking!(gm4; ship_name = :b)
end
@test !has_ship(gm4, :b)

# update_docking! without ship_name updates all ships
s3 = ShipMap()
add_ship!(gm4, :c, s3)
set_docking_status!(s3, ApproachingDockStat(HexFrame.AxialCoord(2.0, 0.0), HexFrame.AxialCoord(0.0, 0.0), 1.0, HexFrame.Q_POS))
# call update_docking! repeatedly without ship_name
for i in 1:5
    update_docking!(gm4)
end
@test typeof(get_docking_status(get_ship(gm4, :c))) == ConnectedDockStat

println("FlowMap docking tests passed")

# -----------------------------
# Bounds Calculation Tests
# -----------------------------

@testset "get_surface_centroid" begin
    # ShipMap overload
    empty_ship = ShipMap()
    delete_all_surface_tiles!(empty_ship)
    centroid_empty = get_surface_centroid(empty_ship)
    @test centroid_empty === nothing

    ship = ShipMap()
    delete_all_surface_tiles!(ship)
    set_surface_tile!(ship, TileCoord(0, 0))
    set_surface_tile!(ship, TileCoord(2, 0))
    set_surface_tile!(ship, TileCoord(0, 2))
    centroid = get_surface_centroid(ship)
    @test centroid.q ≈ (2 / 3)
    @test centroid.r ≈ (2 / 3)

    # AbstractSet{TileCoord} implementation
    tileset = Set([TileCoord(0,0), TileCoord(2,0), TileCoord(0,2)])
    centroid_set = get_surface_centroid(tileset)
    @test centroid_set !== nothing
    @test centroid_set.q ≈ (2 / 3)
    @test centroid_set.r ≈ (2 / 3)

    # GameMap accessor (requires ship name)
    gm = GameMap()
    delete_all_surface_tiles!(get_ship(gm, :primary))
    set_surface_tile!(gm, TileCoord(0, 0); ship_name = :primary)
    set_surface_tile!(gm, TileCoord(2, 0); ship_name = :primary)
    set_surface_tile!(gm, TileCoord(0, 2); ship_name = :primary)
    centroid_g = get_surface_centroid(gm, :primary)
    @test centroid_g !== nothing
    @test centroid_g.q ≈ (2 / 3)
    @test centroid_g.r ≈ (2 / 3)
end

@testset "get_axial_bounds" begin
    # Test empty map returns origin for all directions
    empty_map = GameMap()
    delete_surface_tile!(empty_map, TileCoord(0, 0))  # Remove default origin tile
    bounds = get_axial_bounds(empty_map)
    @test bounds.Q_POS == TileCoord(0, 0)
    @test bounds.Q_NEG == TileCoord(0, 0)

    # Test single tile at origin
    single_map = GameMap()  # Has origin tile by default
    bounds_single = get_axial_bounds(single_map)
    @test bounds_single.Q_POS == TileCoord(0, 0)

    # Test multiple tiles - Q_POS direction should find tile with max q
    multi_map = GameMap()
    set_surface_tile!(multi_map, TileCoord(5, 0))   # Far in Q_POS direction
    set_surface_tile!(multi_map, TileCoord(-3, 0))  # Far in Q_NEG direction
    set_surface_tile!(multi_map, TileCoord(0, 5))   # Far in R_POS direction
    set_surface_tile!(multi_map, TileCoord(0, -3))  # Far in R_NEG direction
    bounds_multi = get_axial_bounds(multi_map)

    # Verify directions work (exact tile may vary based on projection math)
    @test bounds_multi.Q_POS.q >= 0  # Should be positive q
    @test bounds_multi.Q_NEG.q <= 0  # Should be negative q
end

@testset "get_cartesian_bounds" begin
    # Test empty map returns zeros
    empty_map = GameMap()
    delete_surface_tile!(empty_map, TileCoord(0, 0))
    bounds = get_cartesian_bounds(empty_map)
    @test bounds.X_POS == 0.0
    @test bounds.X_NEG == 0.0
    @test bounds.Y_POS == 0.0
    @test bounds.Y_NEG == 0.0

    # Test single tile at origin
    single_map = GameMap()
    bounds_single = get_cartesian_bounds(single_map)
    @test bounds_single.X_POS == 0.0
    @test bounds_single.X_NEG == 0.0

    # Test tiles along q axis (positive q = positive x in cartesian)
    q_map = GameMap()
    set_surface_tile!(q_map, TileCoord(3, 0))
    set_surface_tile!(q_map, TileCoord(-2, 0))
    bounds_q = get_cartesian_bounds(q_map)

    # TileCoord(3, 0) -> CartesianCoord(4.5, -sqrt(3)*1.5) approximately
    # TileCoord(-2, 0) -> CartesianCoord(-3.0, sqrt(3)) approximately
    @test bounds_q.X_POS > 0.0
    @test bounds_q.X_NEG < 0.0

    # Test multi-ship bounds includes all ships
    multi_ship_map = GameMap()
    set_surface_tile!(multi_ship_map, TileCoord(10, 0))
    add_ship!(multi_ship_map, :second, ShipMap())
    set_surface_tile!(multi_ship_map, TileCoord(-10, 0); ship_name=:second)
    bounds_multi = get_cartesian_bounds(multi_ship_map)

    # Bounds should span both ships
    @test bounds_multi.X_POS > 10.0  # Far positive from primary
    @test bounds_multi.X_NEG < -10.0  # Far negative from secondary
end

# Additional tests for Set and ShipMap overloads
@testset "bounds overloads and set variants" begin
    # ShipMap axial vs set
    s = ShipMap()
    delete_all_surface_tiles!(s)
    set_surface_tile!(s, TileCoord(2, 1))
    set_surface_tile!(s, TileCoord(-1, -2))
    @test get_axial_bounds(s) == get_axial_bounds(get_all_surface_tiles(s))

    # GameMap combined vs set
    gm = GameMap()
    delete_all_surface_tiles!(gm)
    set_surface_tile!(gm, TileCoord(4, 0))
    add_ship!(gm, :s2, ShipMap())
    set_surface_tile!(gm, TileCoord(-4, 0); ship_name=:s2)
    @test get_axial_bounds(gm) == get_axial_bounds(get_all_surfaces_combined(gm))

    # ShipMap cartesian vs set
    s2 = ShipMap()
    delete_all_surface_tiles!(s2)
    set_surface_tile!(s2, TileCoord(3, 0))
    @test get_cartesian_bounds(s2) == get_cartesian_bounds(get_all_surface_tiles(s2))

    # Direct set cartesian
    tileset = Set([TileCoord(0, 0), TileCoord(2, 0)])
    b = get_cartesian_bounds(tileset)
    @test b.X_POS > 0.0
end

println("FlowMap bounds tests added")
