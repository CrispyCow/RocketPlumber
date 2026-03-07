using Test
using FlowMap
using HexFrame
using HexFrame: Q_POS, Q_NEG, R_POS, R_NEG, S_POS, S_NEG, NODE_INTERNAL, GROUND
using HexComponentsAPI
using HexFluids
using StaticArrays

# ===============================================================
# Mock Implementations
# ===============================================================

"Minimal mock component for testing. Implements all mandatory ComponentBehavior methods."
struct MockCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::MockCompBehav) = ()
HexComponentsAPI.get_tunables(::MockCompBehav) = ()
HexComponentsAPI.set_tunables(::MockCompBehav, ::NTuple{0, Real}) = MockCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::MockCompBehav; kwargs...) = nothing

"Minimal mock pipe for testing."
struct MockPipeBehav <: PipeBehavior end
HexComponentsAPI.get_conductance(::MockPipeBehav) = 1.0
HexComponentsAPI.get_pipe_tunables(::MockPipeBehav) = ()
HexComponentsAPI.set_pipe_tunables(::MockPipeBehav, ::NTuple{0, Real}) = MockPipeBehav()
HexComponentsAPI.render_pipe_base!(queue, ::MockPipeBehav; kwargs...) = nothing

#= ---------- Test Helpers ----------- =#

"Create a basic single-ship GameMap with default surface at (0,0)"
make_gamemap() = GameMap()

"Create a GameMap with a larger surface area around the origin"
function make_gamemap_with_surface(tiles::Vector{TileCoord})
    gm = GameMap()
    for t in tiles
        set_surface_tile!(gm, t; ship_name = :primary)
    end
    return gm
end

"Create a two-ship GameMap. :primary at origin, :second offset to (20,0)"
function make_two_ship_map()
    primary = ShipMap()
    second = ShipMap()
    offset_ship!(second, TileCoord(20, 0))
    return GameMap(ships = Dict(:primary => primary, :second => second))
end

"Get a convenient set of neighbouring surface tiles around origin"
function origin_neighbourhood()
    origin = TileCoord(0, 0)
    tiles = TileCoord[origin]
    for t in get_adjacent_tiles_for_tile(origin)
        push!(tiles, t)
    end
    return tiles
end

# ===============================================================
# Tests — ShipMap Direct Operations
# ===============================================================

@testset "FlowMap" begin

@testset "ShipMap — Component Operations" begin
    ship = ShipMap()
    coord = TileCoord(0, 0)
    comp = ComponentOnTile(MockCompBehav(), Q_POS)

    # Initially empty
    @test count_components(ship) == 0
    @test !has_component(ship, coord)
    @test isnothing(get_component(ship, coord))

    # Set a component
    set_component!(ship, coord, comp)
    @test has_component(ship, coord)
    @test count_components(ship) == 1
    @test get_component(ship, coord) === comp

    # Overwrite
    comp2 = ComponentOnTile(MockCompBehav(), R_NEG)
    set_component!(ship, coord, comp2)
    @test count_components(ship) == 1
    @test get_component(ship, coord) === comp2

    # Set multiple
    batch = Dict(
        TileCoord(1, 0) => ComponentOnTile(MockCompBehav(), Q_POS),
        TileCoord(0, 1) => ComponentOnTile(MockCompBehav(), Q_POS),
    )
    set_component!(ship, batch)
    @test count_components(ship) == 3

    # Delete
    delete_component!(ship, coord)
    @test !has_component(ship, coord)
    @test count_components(ship) == 2

    # Delete all
    delete_all_components!(ship)
    @test count_components(ship) == 0
end

@testset "ShipMap — Pipe Operations" begin
    ship = ShipMap()
    edge = get_edges(TileCoord(0, 0))[1]
    pipe = MockPipeBehav()

    # Initially empty
    @test count_pipes(ship) == 0
    @test !has_pipe(ship, edge)
    @test isnothing(get_pipe(ship, edge))

    # Set a pipe
    set_pipe!(ship, edge, pipe)
    @test has_pipe(ship, edge)
    @test count_pipes(ship) == 1
    @test get_pipe(ship, edge) isa MockPipeBehav

    # Delete
    delete_pipe!(ship, edge)
    @test !has_pipe(ship, edge)
    @test count_pipes(ship) == 0

    # Set multiple
    edge2 = get_edges(TileCoord(0, 0))[2]
    batch = Dict{EdgeCoord, PipeBehavior}(edge => MockPipeBehav(), edge2 => MockPipeBehav())
    set_pipe!(ship, batch)
    @test count_pipes(ship) == 2

    # Delete all
    delete_all_pipes!(ship)
    @test count_pipes(ship) == 0
end

@testset "ShipMap — Surface Tile Operations" begin
    ship = ShipMap()

    # Default surface has (0,0)
    @test count_surface_tiles(ship) == 1
    @test is_on_surface_tile(TileCoord(0, 0), ship)

    # Add tile
    set_surface_tile!(ship, TileCoord(1, 0))
    @test count_surface_tiles(ship) == 2
    @test is_on_surface_tile(TileCoord(1, 0), ship)

    # Add set of tiles
    set_surface_tile!(ship, Set([TileCoord(2, 0), TileCoord(0, 1)]))
    @test count_surface_tiles(ship) == 4

    # Adding duplicate doesn't increase count
    set_surface_tile!(ship, TileCoord(0, 0))
    @test count_surface_tiles(ship) == 4

    # Delete tile
    @test delete_surface_tile!(ship, TileCoord(2, 0)) == true
    @test count_surface_tiles(ship) == 3
    @test !is_on_surface_tile(TileCoord(2, 0), ship)

    # Deleting non-existent returns false
    @test delete_surface_tile!(ship, TileCoord(99, 99)) == false

    # Get all
    tiles = get_all_surface_tiles(ship)
    @test tiles isa Set{TileCoord}
    @test length(tiles) == 3

    # Delete all
    delete_all_surface_tiles!(ship)
    @test count_surface_tiles(ship) == 0
end

@testset "ShipMap — Iteration" begin
    ship = ShipMap()
    set_component!(ship, TileCoord(0, 0), ComponentOnTile(MockCompBehav(), Q_POS))
    set_component!(ship, TileCoord(1, 0), ComponentOnTile(MockCompBehav(), Q_POS))

    all_comps = get_all_components(ship)
    @test length(all_comps) == 2
    @test haskey(all_comps, TileCoord(0, 0))

    edge = get_edges(TileCoord(0, 0))[1]
    set_pipe!(ship, edge, MockPipeBehav())
    all_pipes = get_all_pipes(ship)
    @test length(all_pipes) == 1
end

# ===============================================================
# Tests — GameMap Ship Management
# ===============================================================

@testset "GameMap — Ship Management" begin
    gm = GameMap()

    # Default has :primary
    @test has_ship(gm, :primary)
    @test length(get_all_ship_names(gm)) == 1

    # Add a ship
    add_ship!(gm, :asteroid, ShipMap())
    @test has_ship(gm, :asteroid)
    @test length(get_all_ship_names(gm)) == 2

    # Cannot add duplicate
    @test_throws ErrorException add_ship!(gm, :asteroid, ShipMap())

    # Get ship
    ship = get_ship(gm, :asteroid)
    @test ship isa ShipMap

    # Get nonexistent ship errors
    @test_throws ErrorException get_ship(gm, :nonexistent)

    # Remove ship
    remove_ship!(gm, :asteroid)
    @test !has_ship(gm, :asteroid)
    @test length(get_all_ship_names(gm)) == 1

    # Cannot remove :primary
    @test_throws ErrorException remove_ship!(gm, :primary)
end

@testset "GameMap — Constructor from ShipMap" begin
    ship = ShipMap()
    set_surface_tile!(ship, TileCoord(5, 5))
    gm = GameMap(ship)
    @test has_ship(gm, :primary)
    @test is_on_surface_tile(TileCoord(5, 5), gm; ship_name = :primary)
end

# ===============================================================
# Tests — GameMap Component/Pipe Routed Access
# ===============================================================

@testset "GameMap — Component Access (routed)" begin
    gm = make_two_ship_map()
    coord = TileCoord(0, 0)
    comp = ComponentOnTile(MockCompBehav(), Q_POS)

    # Set on primary
    set_component!(gm, coord, comp; ship_name = :primary)
    @test has_component(gm, coord; ship_name = :primary)
    @test !has_component(gm, coord; ship_name = :second)

    # Get
    @test !isnothing(get_component(gm, coord; ship_name = :primary))
    @test isnothing(get_component(gm, coord; ship_name = :second))

    # Count
    @test count_components(gm; ship_name = :primary) == 1
    @test count_components(gm; ship_name = :second) == 0

    # Delete
    delete_component!(gm, coord; ship_name = :primary)
    @test !has_component(gm, coord; ship_name = :primary)
end

@testset "GameMap — Pipe Access (routed)" begin
    gm = make_gamemap()
    edge = get_edges(TileCoord(0, 0))[1]

    set_pipe!(gm, edge, MockPipeBehav(); ship_name = :primary)
    @test has_pipe(gm, edge; ship_name = :primary)
    @test count_pipes(gm; ship_name = :primary) == 1

    delete_pipe!(gm, edge; ship_name = :primary)
    @test !has_pipe(gm, edge; ship_name = :primary)
end

@testset "GameMap — Surface Tile Access (routed)" begin
    gm = make_gamemap()

    @test is_on_surface_tile(TileCoord(0, 0), gm; ship_name = :primary)
    @test !is_on_surface_tile(TileCoord(5, 5), gm; ship_name = :primary)

    set_surface_tile!(gm, TileCoord(1, 0); ship_name = :primary)
    @test is_on_surface_tile(TileCoord(1, 0), gm; ship_name = :primary)

    delete_surface_tile!(gm, TileCoord(1, 0); ship_name = :primary)
    @test !is_on_surface_tile(TileCoord(1, 0), gm; ship_name = :primary)

    # Batch surface set
    set_surface_tile!(gm, Set([TileCoord(3, 0), TileCoord(4, 0)]); ship_name = :primary)
    @test is_on_surface_tile(TileCoord(3, 0), gm; ship_name = :primary)
    @test is_on_surface_tile(TileCoord(4, 0), gm; ship_name = :primary)

    # Batch delete
    delete_all_surface_tiles!(gm; ship_name = :primary)
    @test count_surface_tiles(gm; ship_name = :primary) == 0
end

@testset "GameMap — Batch Operations" begin
    gm = make_gamemap()
    set_component!(gm, TileCoord(0, 0), ComponentOnTile(MockCompBehav(), Q_POS))
    set_pipe!(gm, get_edges(TileCoord(0, 0))[1], MockPipeBehav())

    @test count_components(gm) == 1
    @test count_pipes(gm) == 1

    delete_all_components!(gm)
    @test count_components(gm) == 0
    @test count_pipes(gm) == 1  # pipes unaffected

    delete_all_pipes!(gm)
    @test count_pipes(gm) == 0
end

@testset "GameMap — Multiple component/pipe set" begin
    gm = make_gamemap()
    comps = Dict(
        TileCoord(0, 0) => ComponentOnTile(MockCompBehav(), Q_POS),
    )
    set_component!(gm, comps; ship_name = :primary)
    @test has_component(gm, TileCoord(0, 0))

    edge = get_edges(TileCoord(0, 0))[1]
    pipes = Dict{EdgeCoord, PipeBehavior}(edge => MockPipeBehav())
    set_pipe!(gm, pipes; ship_name = :primary)
    @test has_pipe(gm, edge)
end

# ===============================================================
# Tests — Cross-Ship Queries
# ===============================================================

@testset "Cross-Ship Queries — Components" begin
    gm = make_two_ship_map()
    coord_primary = TileCoord(0, 0)
    coord_second = TileCoord(20, 0)
    comp = ComponentOnTile(MockCompBehav(), Q_POS)

    set_component!(gm, coord_primary, comp; ship_name = :primary)
    set_component!(gm, coord_second, comp; ship_name = :second)

    # has_component_any_ship
    found, ship_name = has_component_any_ship(gm, coord_primary)
    @test found == true
    @test ship_name == :primary

    found2, ship_name2 = has_component_any_ship(gm, coord_second)
    @test found2 == true
    @test ship_name2 == :second

    found3, ship_name3 = has_component_any_ship(gm, TileCoord(99, 99))
    @test found3 == false
    @test isnothing(ship_name3)

    # get_component_any_ship
    comp_result, ship_result = get_component_any_ship(gm, coord_primary)
    @test !isnothing(comp_result)
    @test ship_result == :primary

    comp_none, ship_none = get_component_any_ship(gm, TileCoord(99, 99))
    @test isnothing(comp_none)
    @test isnothing(ship_none)
end

@testset "Cross-Ship Queries — Pipes" begin
    gm = make_two_ship_map()
    edge = get_edges(TileCoord(0, 0))[1]
    set_pipe!(gm, edge, MockPipeBehav(); ship_name = :primary)

    found, ship = has_pipe_any_ship(gm, edge)
    @test found == true
    @test ship == :primary

    pipe, ship2 = get_pipe_any_ship(gm, edge)
    @test !isnothing(pipe)
    @test ship2 == :primary

    # Non-existent
    edge2 = get_edges(TileCoord(99, 99))[1]
    found2, _ = has_pipe_any_ship(gm, edge2)
    @test found2 == false
end

@testset "Cross-Ship Queries — Surface Tiles" begin
    gm = make_two_ship_map()

    found, ship = is_on_surface_tile_any_ship(TileCoord(0, 0), gm)
    @test found == true
    @test ship == :primary

    found2, ship2 = is_on_surface_tile_any_ship(TileCoord(20, 0), gm)
    @test found2 == true
    @test ship2 == :second

    found3, ship3 = is_on_surface_tile_any_ship(TileCoord(99, 99), gm)
    @test found3 == false
    @test isnothing(ship3)
end

@testset "get_all_surfaces_combined" begin
    gm = make_two_ship_map()
    combined = get_all_surfaces_combined(gm)
    @test TileCoord(0, 0) in combined
    @test TileCoord(20, 0) in combined
    @test length(combined) == 2
end

# ===============================================================
# Tests — Ship-Finding Helpers
# ===============================================================

@testset "find_ship_for_surface" begin
    gm = make_two_ship_map()
    @test find_ship_for_surface(gm, TileCoord(0, 0)) == :primary
    @test find_ship_for_surface(gm, TileCoord(20, 0)) == :second
    @test isnothing(find_ship_for_surface(gm, TileCoord(99, 99)))
end

@testset "find_ships_adjacent_to_coord" begin
    gm = make_gamemap()
    # TileCoord(1, 0) is adjacent to (0,0) which is on :primary's surface
    adj = find_ships_adjacent_to_coord(gm, TileCoord(1, 0))
    @test :primary in adj

    # Far-away tile shouldn't be adjacent to any ship
    adj2 = find_ships_adjacent_to_coord(gm, TileCoord(50, 50))
    @test isempty(adj2)
end

@testset "would_bridge_ships" begin
    # Two ships physically adjacent — a tile between them bridges
    gm = GameMap(ships = Dict(
        :ship_a => ShipMap(ship_tiles = Set([TileCoord(0, 0)])),
        :ship_b => ShipMap(ship_tiles = Set([TileCoord(2, 0)])),
    ))
    @test would_bridge_ships(gm, TileCoord(1, 0))

    # Single ship — never bridges
    gm2 = make_gamemap()
    @test !would_bridge_ships(gm2, TileCoord(1, 0))
end

@testset "find_valid_ship_for_placement" begin
    gm = make_two_ship_map()
    comp = MockCompBehav()

    # On primary surface
    result = find_valid_ship_for_placement(comp, TileCoord(0, 0), gm; rotation = Q_POS)
    @test result == :primary

    # On second surface
    result2 = find_valid_ship_for_placement(comp, TileCoord(20, 0), gm; rotation = Q_POS)
    @test result2 == :second

    # Off all surfaces
    result3 = find_valid_ship_for_placement(comp, TileCoord(99, 99), gm; rotation = Q_POS)
    @test isnothing(result3)
end

@testset "find_ship_with_component" begin
    gm = make_two_ship_map()
    set_component!(gm, TileCoord(0, 0), ComponentOnTile(MockCompBehav(), Q_POS); ship_name = :primary)
    set_component!(gm, TileCoord(20, 0), ComponentOnTile(MockCompBehav(), Q_POS); ship_name = :second)

    @test find_ship_with_component(gm, TileCoord(0, 0)) == :primary
    @test find_ship_with_component(gm, TileCoord(20, 0)) == :second
    @test isnothing(find_ship_with_component(gm, TileCoord(99, 99)))
end

@testset "find_ship_with_pipe" begin
    gm = make_two_ship_map()
    edge = get_edges(TileCoord(0, 0))[1]
    set_pipe!(gm, edge, MockPipeBehav(); ship_name = :primary)

    @test find_ship_with_pipe(gm, edge) == :primary

    edge2 = get_edges(TileCoord(99, 99))[1]
    @test isnothing(find_ship_with_pipe(gm, edge2))
end

# ===============================================================
# Tests — Placement Validation
# ===============================================================

@testset "placement_valid" begin
    gm = make_gamemap()
    comp = ComponentOnTile(MockCompBehav(), Q_POS)

    # On surface — valid
    valid, reason = placement_valid(comp, TileCoord(0, 0), gm)
    @test valid == true
    @test reason == ""

    # Off surface — invalid
    invalid, reason2 = placement_valid(comp, TileCoord(99, 99), gm)
    @test !invalid
    @test !isempty(reason2)
end

@testset "is_node_on_ship_surface" begin
    gm = make_gamemap()
    # A node adjacent to the surface tile (0,0) should be on the surface
    node_on = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    @test is_node_on_ship_surface(node_on, gm; ship_name = :primary)

    # A node far away should not be on the surface
    node_off = NodeCoord(TileCoord(50, 50), HexFrame.NODE_Q_POS)
    @test !is_node_on_ship_surface(node_off, gm; ship_name = :primary)
end

@testset "is_node_on_any_ship_surface" begin
    gm = make_two_ship_map()
    node_primary = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    node_second = NodeCoord(TileCoord(20, 0), HexFrame.NODE_Q_POS)
    node_nowhere = NodeCoord(TileCoord(99, 99), HexFrame.NODE_Q_POS)

    @test is_node_on_any_ship_surface(node_primary, gm)
    @test is_node_on_any_ship_surface(node_second, gm)
    @test !is_node_on_any_ship_surface(node_nowhere, gm)
end

@testset "can_place_component_at" begin
    gm = make_gamemap()

    valid, _ = can_place_component_at(TileCoord(0, 0), gm; ship_name = :primary)
    @test valid

    invalid, reason = can_place_component_at(TileCoord(99, 99), gm; ship_name = :primary)
    @test !invalid
    @test !isempty(reason)
end

@testset "can_place_pipe_at" begin
    gm = make_gamemap_with_surface(origin_neighbourhood())
    edge = get_edges(TileCoord(0, 0))[1]

    valid, _ = can_place_pipe_at(edge, gm; ship_name = :primary)
    @test valid

    # Edge far off surface
    far_edge = get_edges(TileCoord(99, 99))[1]
    invalid, reason = can_place_pipe_at(far_edge, gm; ship_name = :primary)
    @test !invalid
    @test !isempty(reason)
end

@testset "can_remove_surface_at" begin
    gm = make_gamemap()

    # Can remove empty surface tile
    set_surface_tile!(gm, TileCoord(1, 0))
    valid, _ = can_remove_surface_at(TileCoord(1, 0), gm; ship_name = :primary)
    @test valid

    # Cannot remove surface under a component
    set_component!(gm, TileCoord(0, 0), ComponentOnTile(MockCompBehav(), Q_POS); ship_name = :primary)
    invalid, reason = can_remove_surface_at(TileCoord(0, 0), gm; ship_name = :primary)
    @test !invalid
    @test contains(lowercase(reason), "component")
end

# ===============================================================
# Tests — Bounds & Geometry
# ===============================================================

@testset "get_surface_centroid" begin
    # Empty set
    @test isnothing(get_surface_centroid(Set{TileCoord}()))

    # Single tile
    centroid = get_surface_centroid(Set([TileCoord(0, 0)]))
    @test centroid ≈ AxialCoord(0.0, 0.0)

    # Two tiles
    centroid2 = get_surface_centroid(Set([TileCoord(0, 0), TileCoord(2, 0)]))
    @test centroid2 ≈ AxialCoord(1.0, 0.0)

    # Three tiles (from original tests)
    centroid3 = get_surface_centroid(Set([TileCoord(0, 0), TileCoord(2, 0), TileCoord(0, 2)]))
    @test centroid3.q ≈ (2 / 3)
    @test centroid3.r ≈ (2 / 3)

    # ShipMap overload
    ship = ShipMap()
    @test get_surface_centroid(ship) ≈ AxialCoord(0.0, 0.0)

    # Empty ShipMap
    empty_ship = ShipMap()
    delete_all_surface_tiles!(empty_ship)
    @test isnothing(get_surface_centroid(empty_ship))

    # GameMap overload
    gm = make_gamemap()
    centroid_gm = get_surface_centroid(gm, :primary)
    @test centroid_gm ≈ AxialCoord(0.0, 0.0)
end

@testset "get_axial_bounds" begin
    # Empty set returns origin for all directions
    bounds_empty = get_axial_bounds(Set{TileCoord}())
    @test bounds_empty.Q_POS == TileCoord(0, 0)
    @test bounds_empty.Q_NEG == TileCoord(0, 0)

    # Single tile
    bounds_single = get_axial_bounds(Set([TileCoord(0, 0)]))
    @test bounds_single.Q_POS == TileCoord(0, 0)

    # Multiple tiles — each extreme should be one of the input tiles
    tiles = Set([TileCoord(-2, 0), TileCoord(0, 0), TileCoord(2, 0)])
    bounds = get_axial_bounds(tiles)
    @test bounds.Q_POS in tiles
    @test bounds.Q_NEG in tiles

    # Directional correctness
    tiles2 = Set([TileCoord(5, 0), TileCoord(-3, 0), TileCoord(0, 5), TileCoord(0, -3), TileCoord(0, 0)])
    bounds2 = get_axial_bounds(tiles2)
    @test bounds2.Q_POS.q >= 0
    @test bounds2.Q_NEG.q <= 0

    # ShipMap overload matches set overload
    ship = ShipMap()
    set_surface_tile!(ship, TileCoord(3, 0))
    @test get_axial_bounds(ship) == get_axial_bounds(get_all_surface_tiles(ship))

    # GameMap overload matches combined set
    gm = GameMap()
    set_surface_tile!(gm, TileCoord(2, 0))
    @test get_axial_bounds(gm) == get_axial_bounds(get_all_surfaces_combined(gm))
end

@testset "get_cartesian_bounds" begin
    # Empty set returns zeros
    bounds_empty = get_cartesian_bounds(Set{TileCoord}())
    @test bounds_empty.X_POS == 0.0
    @test bounds_empty.X_NEG == 0.0
    @test bounds_empty.Y_POS == 0.0
    @test bounds_empty.Y_NEG == 0.0

    # Single tile — same point for all bounds
    bounds_single = get_cartesian_bounds(Set([TileCoord(0, 0)]))
    @test bounds_single.X_POS == bounds_single.X_NEG

    # Multiple tiles — bounds should be consistent (max >= min)
    tiles = Set([TileCoord(-2, 0), TileCoord(0, 0), TileCoord(2, 0)])
    bounds = get_cartesian_bounds(tiles)
    @test bounds.X_POS >= bounds.X_NEG
    @test bounds.Y_POS >= bounds.Y_NEG

    # Tiles along q axis spread in x
    bounds_q = get_cartesian_bounds(Set([TileCoord(3, 0), TileCoord(-2, 0), TileCoord(0, 0)]))
    @test bounds_q.X_POS > 0.0
    @test bounds_q.X_NEG < 0.0

    # ShipMap and GameMap overloads
    ship = ShipMap()
    @test get_cartesian_bounds(ship) == get_cartesian_bounds(get_all_surface_tiles(ship))

    # Multi-ship bounds spans both ships
    gm = GameMap()
    set_surface_tile!(gm, TileCoord(10, 0))
    add_ship!(gm, :second, ShipMap())
    set_surface_tile!(gm, TileCoord(-10, 0); ship_name = :second)
    bounds_multi = get_cartesian_bounds(gm)
    @test bounds_multi.X_POS > 10.0
    @test bounds_multi.X_NEG < -10.0
end

@testset "count_surfacetile_adjacencies" begin
    # A single tile has 0 adjacent tiles on surface
    tiles = Set([TileCoord(0, 0)])
    @test FlowMap.count_surfacetile_adjacencies(tiles, TileCoord(0, 0)) == 0

    # Centre of a hex ring of 7 tiles has 6 neighbours
    all_tiles = Set(origin_neighbourhood())
    @test FlowMap.count_surfacetile_adjacencies(all_tiles, TileCoord(0, 0)) == 6
end

@testset "find_ship_surface_edgetiles!" begin
    # Single tile is its own edge tile
    ship = ShipMap()
    edgeset = Set{TileCoord}()
    find_ship_surface_edgetiles!(edgeset, ship)
    @test TileCoord(0, 0) in edgeset
    @test length(edgeset) == 1

    # A full hex ring: the centre tile is NOT an edge tile
    ship2 = ShipMap()
    for t in origin_neighbourhood()
        set_surface_tile!(ship2, t)
    end
    edgeset2 = Set{TileCoord}()
    find_ship_surface_edgetiles!(edgeset2, ship2)
    @test !(TileCoord(0, 0) in edgeset2)  # centre has 6 neighbours, not an edge
    @test length(edgeset2) == 6            # only the ring tiles are edges

    # GameMap overload (multi-ship)
    gm = make_two_ship_map()
    edgeset3 = Set{TileCoord}()
    find_ship_surface_edgetiles!(edgeset3, gm)
    @test length(edgeset3) == 2  # each ship has 1 tile, both are edge tiles
end

# ===============================================================
# Tests — Off-Ship Pipe Functions
# ===============================================================

@testset "can_place_pipe_offship" begin
    gm = make_gamemap()
    # Completely disconnected edge — neither endpoint connected
    far_edge = get_edges(TileCoord(50, 50))[1]
    valid, _, reason = can_place_pipe_offship(far_edge, gm)
    @test !valid
    @test !isempty(reason)
end

@testset "flood_search_pipes_from_node!" begin
    # Build a simple chain of pipes and verify flood fill finds them all
    gm = make_gamemap_with_surface(origin_neighbourhood())

    # Place two connected pipes on edges of (0,0)
    edges = get_edges(TileCoord(0, 0))
    e1 = edges[1]
    e2 = edges[2]
    set_pipe!(gm, e1, MockPipeBehav())
    set_pipe!(gm, e2, MockPipeBehav())

    all_pipe_edges = Set([e1, e2])
    start_node = to_nodecoord(e1.v1)

    reachable = Set{EdgeCoord}()
    flood_search_pipes_from_node!(reachable, all_pipe_edges, start_node)

    # Should find at least the edge we started from
    @test e1 in reachable

    # Empty pipe set should yield empty reachable
    empty_reachable = Set{EdgeCoord}()
    flood_search_pipes_from_node!(empty_reachable, Set{EdgeCoord}(), start_node)
    @test isempty(empty_reachable)
end

@testset "validate_offship_pipe_deletion" begin
    gm = make_gamemap()
    # No off-ship pipes — deletion always valid
    edge = get_edges(TileCoord(0, 0))[1]
    @test validate_offship_pipe_deletion(edge, gm) == true
end

# ===============================================================
# Tests — Offset Ship
# ===============================================================

@testset "offset_ship!" begin
    ship = ShipMap()
    set_component!(ship, TileCoord(0, 0), ComponentOnTile(MockCompBehav(), Q_POS))
    edge = get_edges(TileCoord(0, 0))[1]
    set_pipe!(ship, edge, MockPipeBehav())

    offset = TileCoord(5, 3)
    offset_ship!(ship, offset)

    # Surface tile should be offset
    @test !is_on_surface_tile(TileCoord(0, 0), ship)
    @test is_on_surface_tile(TileCoord(5, 3), ship)

    # Component should be at offset location
    @test !has_component(ship, TileCoord(0, 0))
    @test has_component(ship, TileCoord(5, 3))

    # Pipe should no longer be at original edge
    @test !has_pipe(ship, edge)
    @test count_pipes(ship) == 1  # still has the pipe, just at new edge
end

@testset "offset_ship! — preserves counts" begin
    ship = ShipMap()
    set_component!(ship, TileCoord(0, 0), ComponentOnTile(MockCompBehav(), Q_POS))
    set_surface_tile!(ship, TileCoord(1, 0))
    e1 = get_edges(TileCoord(0, 0))[1]
    e2 = get_edges(TileCoord(0, 0))[2]
    set_pipe!(ship, e1, MockPipeBehav())
    set_pipe!(ship, e2, MockPipeBehav())

    comps_before = count_components(ship)
    pipes_before = count_pipes(ship)
    tiles_before = count_surface_tiles(ship)

    offset_ship!(ship, TileCoord(10, 10))

    @test count_components(ship) == comps_before
    @test count_pipes(ship) == pipes_before
    @test count_surface_tiles(ship) == tiles_before
end

# ===============================================================
# Tests — Docking Status Types
# ===============================================================

@testset "DockingStatus — ConnectedDockStat" begin
    status = ConnectedDockStat()
    @test get_render_offset(status) === nothing
    @test update_render_offset!(status) == false
    @test get_approach_axis(status) === nothing

    # With saved axis
    status_axis = ConnectedDockStat(Q_POS)
    @test get_approach_axis(status_axis) == Q_POS
end

@testset "DockingStatus — ApproachingDockStat" begin
    start_pos = AxialCoord(10.0, 0.0)
    target_pos = AxialCoord(0.0, 0.0)
    step = 1.0

    status = ApproachingDockStat(start_pos, target_pos, step, R_NEG)

    @test get_render_offset(status) isa AxialCoord
    @test get_approach_axis(status) == R_NEG

    # Proximity-eased stepping — iterate until target reached
    reached = false
    for _ in 1:10000
        reached = update_render_offset!(status)
        reached && break
    end
    @test reached == true
    @test get_render_offset(status) ≈ target_pos
end

@testset "DockingStatus — DepartingDockStat" begin
    start_pos = AxialCoord(0.0, 0.0)
    target_pos = AxialCoord(10.0, 0.0)
    step = 1.0

    status = DepartingDockStat(start_pos, target_pos, step, S_POS)

    @test get_render_offset(status) isa AxialCoord
    @test get_approach_axis(status) == S_POS

    # Proximity-eased stepping — iterate until target reached
    reached = false
    for _ in 1:10000
        reached = update_render_offset!(status)
        reached && break
    end
    @test reached == true
end

@testset "RenderPosOffsetState" begin
    state = RenderPosOffsetState(
        current_offset = AxialCoord(5.0, 0.0),
        target_offset = AxialCoord(0.0, 0.0),
        offset_step = 0.01
    )

    @test get_render_offset(state) ≈ AxialCoord(5.0, 0.0)

    # Stepping doesn't overshoot
    update_render_offset!(state)
    offset = get_render_offset(state)
    @test offset.q < 5.0  # moved closer
    @test offset.q >= 0.0  # didn't overshoot

    # Reaching target returns true
    state2 = RenderPosOffsetState(
        current_offset = AxialCoord(0.001, 0.0),
        target_offset = AxialCoord(0.0, 0.0),
        offset_step = 1.0
    )
    @test update_render_offset!(state2) == true
    @test get_render_offset(state2) ≈ AxialCoord(0.0, 0.0)
end

# ===============================================================
# Tests — Docking State Machine
# ===============================================================

@testset "update_docking! — Approaching → Connected" begin
    gm = GameMap()
    add_ship!(gm, :visitor, ShipMap())
    set_docking_status!(gm, :visitor, ApproachingDockStat(
        AxialCoord(3.0, 0.0), AxialCoord(0.0, 0.0), 1.0, Q_POS
    ))
    for _ in 1:10000
        update_docking!(gm; ship_name = :visitor)
        get_docking_status(gm, :visitor) isa ConnectedDockStat && break
    end
    @test get_docking_status(gm, :visitor) isa ConnectedDockStat
    @test get_approach_axis(get_docking_status(gm, :visitor)) == Q_POS
end

@testset "update_docking! — Departing → removed" begin
    gm = GameMap()
    add_ship!(gm, :visitor, ShipMap())
    set_docking_status!(gm, :visitor, DepartingDockStat(
        AxialCoord(0.0, 0.0), AxialCoord(4.0, 0.0), 1.0, R_NEG
    ))
    for _ in 1:10000
        has_ship(gm, :visitor) || break
        update_docking!(gm; ship_name = :visitor)
    end
    @test !has_ship(gm, :visitor)
end

@testset "update_docking! — Connected is no-op" begin
    gm = GameMap()
    update_docking!(gm; ship_name = :primary)
    @test get_docking_status(gm, :primary) isa ConnectedDockStat
end

@testset "update_docking! — all ships" begin
    gm = GameMap()
    add_ship!(gm, :v1, ShipMap())
    add_ship!(gm, :v2, ShipMap())

    set_docking_status!(gm, :v1, ApproachingDockStat(
        AxialCoord(2.0, 0.0), AxialCoord(0.0, 0.0), 1.0, nothing
    ))
    set_docking_status!(gm, :v2, ApproachingDockStat(
        AxialCoord(2.0, 0.0), AxialCoord(0.0, 0.0), 1.0, nothing
    ))

    for _ in 1:10000
        update_docking!(gm)  # no ship_name — updates all
        both_done = get_docking_status(gm, :v1) isa ConnectedDockStat &&
                    get_docking_status(gm, :v2) isa ConnectedDockStat
        both_done && break
    end
    @test get_docking_status(gm, :v1) isa ConnectedDockStat
    @test get_docking_status(gm, :v2) isa ConnectedDockStat
end

@testset "update_docking! — nonexistent ship is no-op" begin
    gm = GameMap()
    update_docking!(gm; ship_name = :nonexistent)  # should not error
end

@testset "clear_all_docking_statuses!" begin
    gm = GameMap()
    add_ship!(gm, :visitor, ShipMap())
    set_docking_status!(gm, :visitor, ApproachingDockStat(
        AxialCoord(5.0, 0.0), AxialCoord(0.0, 0.0), 0.01, Q_POS
    ))

    clear_all_docking_statuses!(gm)
    @test get_docking_status(gm, :visitor) isa ConnectedDockStat
    @test get_docking_status(gm, :primary) isa ConnectedDockStat
end

@testset "get/set docking_status" begin
    gm = make_gamemap()
    @test get_docking_status(gm, :primary) isa ConnectedDockStat
    @test isnothing(get_docking_status(gm, :nonexistent))

    set_docking_status!(gm, :primary, ConnectedDockStat(Q_NEG))
    @test get_approach_axis(get_docking_status(gm, :primary)) == Q_NEG

    @test_throws ErrorException set_docking_status!(gm, :nonexistent, ConnectedDockStat())

    # ShipMap-level
    ship = get_ship(gm, :primary)
    @test get_docking_status(ship) isa ConnectedDockStat
    set_docking_status!(ship, ConnectedDockStat(R_POS))
    @test get_approach_axis(get_docking_status(ship)) == R_POS
end

@testset "get_ship_render_offset" begin
    gm = make_gamemap()
    offset = get_ship_render_offset(gm, :primary)
    @test offset ≈ AxialCoord(0.0, 0.0)

    ship = get_ship(gm, :primary)
    @test get_render_offset(ship) ≈ AxialCoord(0.0, 0.0)
end

# ===============================================================
# Tests — Swap Primary
# ===============================================================

@testset "swap_primary! — basic" begin
    gm = make_two_ship_map()

    success, msg = swap_primary!(gm, :second)
    @test success
    @test !isempty(msg)

    # After swap, :primary should have second's surface (20,0)
    @test is_on_surface_tile(TileCoord(20, 0), gm; ship_name = :primary)

    # The old primary is retired under a gensym'd name
    @test length(get_all_ship_names(gm)) == 2
end

@testset "swap_primary! — error cases" begin
    gm = make_gamemap()

    # Cannot swap with self
    fail1, _ = swap_primary!(gm, :primary)
    @test !fail1

    # Cannot swap with nonexistent
    fail2, _ = swap_primary!(gm, :nonexistent)
    @test !fail2
end

@testset "swap_primary! — axis propagation" begin
    gm = GameMap()
    add_ship!(gm, :visitor, ShipMap())
    set_docking_status!(gm, :visitor, ConnectedDockStat(Q_POS))

    success, _ = swap_primary!(gm, :visitor)
    @test success

    # The new primary should have no approach axis
    @test get_approach_axis(get_docking_status(get_ship(gm, :primary))) === nothing

    # The retired ship should have rotate(Q_POS, Q_NEG) = Q_NEG
    retired_names = filter(n -> n != :primary, get_all_ship_names(gm))
    @test length(retired_names) == 1
    retired_axis = get_approach_axis(get_docking_status(get_ship(gm, retired_names[1])))
    @test retired_axis == Q_NEG
end

@testset "swap_primary! — round-trip" begin
    gm = GameMap()
    set_component!(gm, TileCoord(0, 0), ComponentOnTile(MockCompBehav(), Q_POS))
    add_ship!(gm, :visitor, ShipMap())
    set_surface_tile!(gm, TileCoord(10, 0); ship_name = :visitor)
    set_component!(gm, TileCoord(10, 0), ComponentOnTile(MockCompBehav(), R_NEG); ship_name = :visitor)

    # Swap to visitor
    success1, _ = swap_primary!(gm, :visitor)
    @test success1
    @test has_component(gm, TileCoord(10, 0))  # visitor's component is now primary

    # Swap back
    retired_name = filter(n -> n != :primary, get_all_ship_names(gm))[1]
    success2, _ = swap_primary!(gm, retired_name)
    @test success2
    @test has_component(gm, TileCoord(0, 0))  # original primary component
end

# ===============================================================
# Tests — find_ship_for_node
# ===============================================================

@testset "find_ship_for_node" begin
    gm = make_two_ship_map()

    node_primary = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
    @test find_ship_for_node(node_primary, gm) == :primary

    node_second = NodeCoord(TileCoord(20, 0), HexFrame.NODE_Q_POS)
    @test find_ship_for_node(node_second, gm) == :second

    # Node not adjacent to any surface falls back to :primary
    node_nowhere = NodeCoord(TileCoord(99, 99), HexFrame.NODE_Q_POS)
    @test find_ship_for_node(node_nowhere, gm) == :primary
end

# ===============================================================
# Tests — Space Map Accessors
# ===============================================================

@testset "SpaceMapEmpty — accessors" begin
    sm = SpaceMapEmpty()

    @test get_velocity(sm) ≈ SVector(0.0, 0.0)
    set_velocity!(sm, SVector(1.0, 2.0))
    @test get_velocity(sm) ≈ SVector(1.0, 2.0)

    @test isnothing(get_space_map_seed(sm))
    @test isnothing(get_time_years(sm))
    @test !has_active_manoeuvre(sm)
    @test isnothing(get_active_manoeuvre(sm))
    @test get_position(sm) ≈ SVector(0.0, 0.0)
    @test get_target_time(sm) == 0.0
    @test !is_time_progressing(sm)
    @test isempty(get_encounter_points(sm))

    # No-op setters don't error
    set_time_years!(sm, 1.0)
    set_position!(sm, SVector(1.0, 1.0))
    set_target_time!(sm, 1.0)
    set_active_manoeuvre!(sm, ManoeuvreData(main_burn_dv = SVector(0.0, 0.0), decel_burn_dv = SVector(0.0, 0.0)))
    clear_active_manoeuvre!(sm)
end

@testset "SpaceMapState — accessors (moved to HexFlowProcGen)" begin
    # SpaceMapState has been moved to HexFlowProcGen. These tests are now in HexFlowProcGen.
    @test true
end

@testset "GameMap — space map delegation (SpaceMapEmpty only)" begin
    gm = GameMap()

    # Default space map is SpaceMapEmpty
    @test get_spacemap(gm) isa SpaceMapEmpty
    @test get_velocity(gm) ≈ SVector(0.0, 0.0)

    set_velocity!(gm, SVector(10.0, 0.0))
    @test get_velocity(gm) ≈ SVector(10.0, 0.0)

    # SpaceMapState-specific tests moved to HexFlowProcGen
end

@testset "get_mass" begin
    gm = GameMap()
    # Default: 1 surface tile at 100.0 per tile, no components
    @test get_mass(gm) == 100.0

    # Custom mass per tile
    @test get_mass(gm; mass_per_tile = 500.0) == 500.0

    # Multiple surface tiles
    set_surface_tile!(gm, TileCoord(1, 0))
    @test get_mass(gm) == 200.0

    # Multi-ship
    add_ship!(gm, :other, ShipMap())
    @test get_mass(gm) == 300.0  # 2 + 1 tiles
end

# ===============================================================
# Tests — Space Map Types
# ===============================================================

@testset "ManoeuvreData" begin
    man = ManoeuvreData(
        main_burn_dv = SVector(10.0, 0.0),
        decel_burn_dv = SVector(-5.0, 0.0),
        closest_approach_time = 1.0,
        intercept_time = 2.0,
        target_encounter_index = 1,
    )

    @test man.phase == PHASE_WAIT_APPROACH
    @test man.main_burn_dv ≈ SVector(10.0, 0.0)
    @test man.decel_burn_dv ≈ SVector(-5.0, 0.0)
    @test man.closest_approach_time == 1.0
    @test man.intercept_time == 2.0
    @test man.target_encounter_index == 1

    # Mutable fields can be updated
    man.phase = PHASE_MAIN_BURN
    @test man.phase == PHASE_MAIN_BURN

    man.burn_remaining_dv = SVector(5.0, 0.0)
    @test man.burn_remaining_dv ≈ SVector(5.0, 0.0)
end

@testset "ManoeuvrePhase enum" begin
    @test PHASE_WAIT_APPROACH isa ManoeuvrePhase
    @test PHASE_MAIN_BURN isa ManoeuvrePhase
    @test PHASE_COAST isa ManoeuvrePhase
    @test PHASE_DECEL_BURN isa ManoeuvrePhase
    @test PHASE_ENCOUNTER_READY isa ManoeuvrePhase
end

@testset "EncounterPoint" begin
    ep = EncounterPoint(index = 1, base_velocity = 50.0)
    @test ep.index == 1
    @test ep.base_velocity == 50.0
    @test ep.iteration == 0
    @test ep.position ≈ SVector(0.0, 0.0)
    @test ep.velocity ≈ SVector(0.0, 0.0)
    @test ep.spawn_time == 0.0
    @test ep.encounter_class == ENCOUNTER_SCRAP
    @test ep.fuel_tag == HexFluids.NONE
    @test ep.display_name == ""
    @test ep.richness == 0.0
end

@testset "EncounterClass" begin
    @test ENCOUNTER_SHIP isa EncounterClass
    @test ENCOUNTER_FUEL_CACHE isa EncounterClass
    @test ENCOUNTER_SCRAP isa EncounterClass
    @test Int(ENCOUNTER_SHIP) != Int(ENCOUNTER_FUEL_CACHE)
    @test Int(ENCOUNTER_FUEL_CACHE) != Int(ENCOUNTER_SCRAP)
    @test Int(ENCOUNTER_SHIP) != Int(ENCOUNTER_SCRAP)
end

@testset "EncounterEvent ordering" begin
    e1 = EncounterEvent(1.0, 1)
    e2 = EncounterEvent(2.0, 2)
    e3 = EncounterEvent(0.5, 3)

    @test isless(e3, e1)
    @test isless(e1, e2)
    @test !isless(e2, e1)
end

@testset "initialise_spacemap! (moved to HexFlowProcGen)" begin
    # initialise_spacemap! implementation has moved to HexFlowProcGen.
    # These tests are now in HexFlowProcGen tests.
    @test true
end

end # @testset "FlowMap"
