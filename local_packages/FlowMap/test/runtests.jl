#=
Scope: FlowMap test suite covering map domain model, validation, docking state, and ship operations
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test, StaticArrays

using FlowMap, TypeGroupedDicts, HexFrame, HexComponentsAPI, HexFluids
using HexFrame: Q_POS, Q_NEG, R_POS, R_NEG, S_POS, S_NEG, GROUND

# ===============================================================
# Mock Implementations
# ===============================================================

"Minimal mock component for testing. Implements all mandatory ComponentBehavior methods."
struct MockCompBehav <: ComponentBehavior end
HexComponentsAPI.produce_rel_elements(::MockCompBehav) = ()
HexComponentsAPI.get_tunables(::MockCompBehav) = ()
HexComponentsAPI.set_tunables(::MockCompBehav, ::NTuple{0, Real}) = MockCompBehav()
HexComponentsAPI.render_base_elem!(queue, ::MockCompBehav; kwargs...) = nothing

"Component with explicit structural and single-fluid masses for reduction tests."
struct MassCompBehav{T <: Real} <: ComponentBehavior
    dry_mass::T
    wet_mass::T
    fluid::FluidType
end
HexComponentsAPI.get_component_dry_mass(comp::MassCompBehav) = Float64(comp.dry_mass)
HexComponentsAPI.get_component_wet_mass(comp::MassCompBehav; fluid = nothing) = isnothing(fluid) || fluid == comp.fluid ? Float64(comp.wet_mass) : 0.0

"Mock component whose placement rule deliberately permits one off-surface tile."
struct OffSurfaceCompBehav <: ComponentBehavior
    valid_coord::TileCoord
end
HexComponentsAPI.produce_rel_elements(::OffSurfaceCompBehav) = ()
HexComponentsAPI.get_tunables(::OffSurfaceCompBehav) = ()
HexComponentsAPI.set_tunables(comp::OffSurfaceCompBehav, ::NTuple{0, Real}) = comp
HexComponentsAPI.render_base_elem!(queue, ::OffSurfaceCompBehav; kwargs...) = nothing
function HexComponentsAPI.placement_valid(comp::OffSurfaceCompBehav, coord::TileCoord, ::GameMap; kwargs...)
    return coord == comp.valid_coord ? ValidRequest() : InvalidRequest("Wrong destination")
end

"Minimal mock pipe for testing."
struct MockPipeBehav <: PipeBehavior end
HexComponentsAPI.get_conductance(::MockPipeBehav) = 1.0
HexComponentsAPI.get_pipe_tunables(::MockPipeBehav) = ()
HexComponentsAPI.set_pipe_tunables(::MockPipeBehav, ::NTuple{0, Real}) = MockPipeBehav()
HexComponentsAPI.render_pipe_base!(queue, ::MockPipeBehav; kwargs...) = nothing
HexComponentsAPI.get_pipe_click_radius(::MockPipeBehav) = 0.1

"Mock pipe intentionally missing mandatory click-radius implementation."
struct MissingClickRadiusPipe <: PipeBehavior end

#= ---------- Test Helpers ----------- =#

"Create a basic single-ship GameMap with a surface tile at (0,0)."
function make_gamemap()
    return GameMap()
end

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
    gm = make_gamemap()
    add_ship!(gm, :second, ShipState())
    set_surface_tile!(gm, TileCoord(20, 0); ship_name = :second)
    return gm
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

"Return the indexed side-span pipe bordering a tile."
side_pipe(tile::TileCoord, index::Integer = 1) = get_side_pipes(tile)[index]

# ===============================================================
# Tests — direct map operations
# ===============================================================

@testset "FlowMap" begin

    @testset "Grouped live stores preserve map operations" begin
        gm = make_two_ship_map()
        @test gm.components isa TypeGroupedDict{TileCoord, PlacedComponent}
        @test gm.pipe_behaviors isa TypeGroupedDict{PipeCoord, PlacedPipe}
        @test ShipBlueprint().components isa Dict
        @test ShipBlueprint().pipe_behaviors isa Dict

        # Interleave owners within each concrete behaviour bucket
        for i in 0:7
            coord = TileCoord(i, 0)
            ship = iseven(i) ? :primary : :second
            behaviour = i < 4 ? MockCompBehav() : OffSurfaceCompBehav(coord)
            pipe = i < 4 ? MockPipeBehav() : MissingClickRadiusPipe()
            set_component!(gm, coord, PlacedComponent(behaviour, R_NEG, true, ship))
            set_pipe!(gm, side_pipe(coord), pipe; ship_name = ship)
        end
        components = Dict(pairs(get_components(gm)))
        pipes = Dict(pairs(get_pipes(gm)))
        @test Set(keys(gm.components)) == Set(keys(components))
        @test Set(values(gm.pipe_behaviors)) == Set(values(pipes))
        @test count(_ -> true, each_component_of_ship(gm, :second)) == 4
        @test count(_ -> true, each_pipe_of_type(gm, MockPipeBehav)) == 4

        # Replacements can change concrete behaviour type without changing count
        coord = TileCoord(0, 0)
        replacement = PlacedComponent(OffSurfaceCompBehav(coord), Q_POS, :primary)
        set_component!(gm, coord, replacement)
        @test get_component(gm, coord) === replacement
        @test length(gm.components) == 8
        set_pipe!(gm, side_pipe(coord), MissingClickRadiusPipe())
        @test get_pipe(gm, side_pipe(coord)).pipe isa MissingClickRadiusPipe
        @test length(gm.pipe_behaviors) == 8
        set_component!(gm, coord, components[coord])
        set_pipe!(gm, side_pipe(coord), pipes[side_pipe(coord)])

        # Map identity ignores bucket and insertion history
        reordered = deepcopy(gm)
        delete_all_components!(reordered)
        delete_all_pipes!(reordered)
        for (key, value) in reverse(collect(components))
            set_component!(reordered, key, value)
        end
        for (key, value) in reverse(collect(pipes))
            set_pipe!(reordered, key, value)
        end
        @test gm == reordered
        @test isequal(gm, reordered)
        @test hash(gm) == hash(reordered)

        offset = TileCoord(20, 0)
        offset_ship!(gm, :second, offset)
        for (key, value) in components
            moved_key = value.ship === :second ? offset_by_tile(key, offset) : key
            @test get_component(gm, moved_key) === value
        end
        for (key, value) in pipes
            moved_key = value.ship === :second ? offset_by_tile(key, offset) : key
            @test get_pipe(gm, moved_key) === value
        end
        swap_primary!(gm, :second)
        @test count(_ -> true, each_component_of_ship(gm, :primary)) == 4
        @test all(c -> c.rotation == R_NEG && c.mirrored, values(gm.components))
        @test all(get_pipe(gm, side_pipe(TileCoord(i + 20, 0))).ship === :primary for i in 1:2:7)
        retired_name = only(name for name in get_all_ship_names(gm) if name !== :primary)
        remove_ship!(gm, retired_name)
        @test length(gm.components) == length(gm.pipe_behaviors) == 4
        @test all(c -> c.ship === :primary, values(gm.components))
        @test all(p -> p.ship === :primary, values(gm.pipe_behaviors))

        # Selective deletion must not skip entries moved by bucket compaction
        delete_all_components!(reordered; ship_name = :second)
        delete_all_pipes!(reordered; ship_name = :second)
        @test Dict(reordered.components) == Dict(k => v for (k, v) in components if v.ship === :primary)
        @test Dict(reordered.pipe_behaviors) == Dict(k => v for (k, v) in pipes if v.ship === :primary)
        delete_all_components!(gm; ship_name = :primary)
        delete_all_pipes!(gm; ship_name = :primary)
        @test isempty(gm.components) && isempty(gm.pipe_behaviors)
    end

    @testset "GameMap — Component Operations" begin
        gm = GameMap()
        coord = TileCoord(0, 0)
        comp = PlacedComponent(MockCompBehav(), Q_POS, :primary)

        # Initially empty
        @test count_components(gm; ship_name = :primary) == 0
        @test !has_component(gm, coord)
        @test isnothing(get_component(gm, coord))

        # Set a component
        set_component!(gm, coord, comp)
        @test has_component(gm, coord)
        @test count_components(gm; ship_name = :primary) == 1
        @test get_component(gm, coord) === comp

        # Overwrite
        comp2 = PlacedComponent(MockCompBehav(), R_NEG, :primary)
        set_component!(gm, coord, comp2)
        @test count_components(gm; ship_name = :primary) == 1
        @test get_component(gm, coord) === comp2

        # Set multiple
        batch = Dict(
            TileCoord(1, 0) => PlacedComponent(MockCompBehav(), Q_POS, :primary),
            TileCoord(0, 1) => PlacedComponent(MockCompBehav(), Q_POS, :primary),
        )
        set_component!(gm, batch)
        @test count_components(gm; ship_name = :primary) == 3

        # Bulk import the grouped collection, including mixed concrete behaviours
        grouped_batch = TypeGroupedDict{TileCoord, PlacedComponent}(batch)
        grouped_batch[coord] = PlacedComponent(OffSurfaceCompBehav(coord), Q_POS, :visitor)
        @test set_component!(gm, grouped_batch) === nothing
        @test gm.components == grouped_batch
        @test get_component(gm, coord).ship === :visitor
        @test set_component!(gm, gm.components) === nothing
        @test gm.components == grouped_batch
        set_component!(gm, coord, comp2)

        # Delete
        delete_component!(gm, coord)
        @test !has_component(gm, coord)
        @test count_components(gm; ship_name = :primary) == 2

        # Delete all
        delete_all_components!(gm; ship_name = :primary)
        @test count_components(gm; ship_name = :primary) == 0
    end

    @testset "GameMap — Pipe Operations" begin
        gm = GameMap()
        pipe_coord_1 = side_pipe(TileCoord(0, 0), 1)
        pipe_behaviour = MockPipeBehav()

        # Initially empty
        @test count_pipes(gm; ship_name = :primary) == 0
        @test !has_pipe(gm, pipe_coord_1)
        @test isnothing(get_pipe(gm, pipe_coord_1))

        # Set a pipe
        set_pipe!(gm, pipe_coord_1, PlacedPipe(pipe_behaviour, :primary))
        @test has_pipe(gm, pipe_coord_1)
        @test count_pipes(gm; ship_name = :primary) == 1
        @test get_pipe(gm, pipe_coord_1) isa PlacedPipe
        @test get_pipe(gm, pipe_coord_1).pipe isa MockPipeBehav

        # Delete
        delete_pipe!(gm, pipe_coord_1)
        @test !has_pipe(gm, pipe_coord_1)
        @test count_pipes(gm; ship_name = :primary) == 0

        # Set multiple
        pipe_coord_2 = side_pipe(TileCoord(0, 0), 2)
        batch = Dict{PipeCoord, PipeBehavior}(pipe_coord_1 => MockPipeBehav(), pipe_coord_2 => MockPipeBehav())
        set_pipe!(gm, pipe_coord_1, PlacedPipe(batch[pipe_coord_1], :primary))
        set_pipe!(gm, pipe_coord_2, PlacedPipe(batch[pipe_coord_2], :primary))
        @test count_pipes(gm; ship_name = :primary) == 2

        # Delete all
        delete_all_pipes!(gm; ship_name = :primary)
        @test count_pipes(gm; ship_name = :primary) == 0
    end

    @testset "GameMap — Surface Tile Operations" begin
        gm = make_gamemap()

        # Default helper surface has (0,0)
        @test count_surface_tiles(gm; ship_name = :primary) == 1
        @test count_surface_tiles(gm) == 1
        @test is_on_surface_tile(TileCoord(0, 0), gm; ship_name = :primary)
        @test get_surface_shiptag(gm, TileCoord(0, 0)) == :primary

        # Add tile
        set_surface_tile!(gm, TileCoord(1, 0); ship_name = :primary)
        @test count_surface_tiles(gm; ship_name = :primary) == 2
        @test count_surface_tiles(gm) == 2
        @test is_on_surface_tile(TileCoord(1, 0), gm; ship_name = :primary)

        # Add set of tiles
        set_surface_tile!(gm, Set([TileCoord(2, 0), TileCoord(0, 1)]); ship_name = :primary)
        @test count_surface_tiles(gm; ship_name = :primary) == 4

        # Adding duplicate doesn't increase count
        set_surface_tile!(gm, TileCoord(0, 0); ship_name = :primary)
        @test count_surface_tiles(gm; ship_name = :primary) == 4

        # Delete tile
        @test delete_surface_tile!(gm, TileCoord(2, 0); ship_name = :primary) == true
        @test count_surface_tiles(gm; ship_name = :primary) == 3
        @test !is_on_surface_tile(TileCoord(2, 0), gm; ship_name = :primary)

        # Deleting non-existent returns false
        @test delete_surface_tile!(gm, TileCoord(99, 99); ship_name = :primary) == false

        # Collect all
        tiles = collect_surface_tiles!(Set{TileCoord}(), gm; ship_name = :primary)
        @test tiles isa Set{TileCoord}
        @test length(tiles) == 3

        all_tiles = collect_surface_tiles!(Set{TileCoord}(), gm)
        @test all_tiles == tiles

        # Before delete_all, we have 3 tiles: (0,0), (1,0), (0,1)
        @test count_surface_tiles(gm; ship_name = :primary) == 3
        delete_all_surface_tiles!(gm; ship_name = :primary)
        @test count_surface_tiles(gm; ship_name = :primary) == 0
        @test count_surface_tiles(gm) == 0
    end

    @testset "GameMap — Iteration" begin
        gm = GameMap()
        set_component!(gm, TileCoord(0, 0), PlacedComponent(MockCompBehav(), Q_POS, :primary))
        set_component!(gm, TileCoord(1, 0), PlacedComponent(MockCompBehav(), Q_POS, :primary))

        @test count_components(gm; ship_name = :primary) == 2
        @test has_component(gm, TileCoord(0, 0))
        @test get_components(gm) === gm.components
        @test count(_ -> true, each_component_of_ship(gm, :primary)) == 2
        @test count(_ -> true, each_component_of_type(gm, MockCompBehav)) == 2
        @test count_surface_tiles(gm; ship_name = :primary) == 1  # Default origin tile

        pipe_coord_1 = side_pipe(TileCoord(0, 0), 1)
        set_pipe!(gm, pipe_coord_1, PlacedPipe(MockPipeBehav(), :primary))
        @test count_pipes(gm; ship_name = :primary) == 1
        @test get_pipes(gm) === gm.pipe_behaviors
        @test count(_ -> true, each_pipe_of_ship(gm, :primary)) == 1
        @test count(_ -> true, each_pipe_of_type(gm, MockPipeBehav)) == 1
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
        add_ship!(gm, :asteroid, ShipState())
        @test has_ship(gm, :asteroid)
        @test length(get_all_ship_names(gm)) == 2

        # Cannot add duplicate
        @test_throws ErrorException add_ship!(gm, :asteroid, ShipState())

        # Get ship
        ship = get_ship_state(gm, :asteroid)
        @test ship isa ShipState

        # Get nonexistent ship errors
        @test_throws ErrorException get_ship_state(gm, :nonexistent)

        # Remove ship
        remove_ship!(gm, :asteroid)
        @test !has_ship(gm, :asteroid)
        @test length(get_all_ship_names(gm)) == 1

        # Cannot remove :primary
        @test_throws ErrorException remove_ship!(gm, :primary)
    end

    @testset "GameMap — Constructor from ShipState" begin
        ship = ShipState(docking_status = ApproachingDockStat(AxialCoord(1.0, 0.0), AxialCoord(0.0, 0.0), 0.5))
        gm = GameMap(ship)
        @test has_ship(gm, :primary)
        @test count_surface_tiles(gm) == 1  # Default tile at origin
        @test get_docking_status(gm, :primary) isa ApproachingDockStat
    end

    @testset "GameMap — Constructor from ShipBlueprint" begin
        blueprint = ShipBlueprint(ship_tiles = Set([TileCoord(0, 0), TileCoord(1, 0)]))
        blueprint.components[TileCoord(0, 0)] = PlacedComponent(MockCompBehav(), Q_POS, :_blueprint)
        blueprint.pipe_behaviors[PipeCoord(VertexCoord(TileCoord(0, 0), Q_POS), VertexCoord(TileCoord(1, 0), Q_NEG))] = MockPipeBehav()

        gm = GameMap(blueprint)

        @test has_ship(gm, :primary)
        @test is_on_surface_tile(TileCoord(1, 0), gm; ship_name = :primary)
        @test count_surface_tiles(gm; ship_name = :primary) == 2  # Blueprint tiles + default gets deduplicated
        @test count_components(gm; ship_name = :primary) == 1
        @test count_pipes(gm; ship_name = :primary) == 1
        @test only(each_component_of_ship(gm, :primary)).ship == :primary
        @test only(each_pipe_of_ship(gm, :primary)).ship == :primary
        @test only(values(blueprint.components)).ship == :_blueprint
    end

    # ===============================================================
    # Tests — GameMap Component/Pipe Routed Access
    # ===============================================================

    @testset "GameMap — Component Access (routed)" begin
        gm = make_two_ship_map()
        coord = TileCoord(0, 0)
        comp = PlacedComponent(MockCompBehav(), Q_POS, :primary)

        # Set on primary
        set_component!(gm, coord, comp)
        @test has_component(gm, coord)

        # Get
        got = get_component(gm, coord)
        @test !isnothing(got)
        @test got.ship === :primary
        @test got.ship !== :second

        # Count
        @test count_components(gm; ship_name = :primary) == 1
        @test count_components(gm; ship_name = :second) == 0

        # Delete
        delete_component!(gm, coord)
        @test !has_component(gm, coord)
    end

    @testset "GameMap — Pipe Access (routed)" begin
        gm = make_gamemap()
        pipe_coord_1 = side_pipe(TileCoord(0, 0), 1)

        set_pipe!(gm, pipe_coord_1, PlacedPipe(MockPipeBehav(), :primary))
        @test has_pipe(gm, pipe_coord_1)
        @test count_pipes(gm; ship_name = :primary) == 1

        delete_pipe!(gm, pipe_coord_1)
        @test !has_pipe(gm, pipe_coord_1)
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
        set_component!(gm, TileCoord(0, 0), PlacedComponent(MockCompBehav(), Q_POS, :primary))
        set_pipe!(gm, side_pipe(TileCoord(0, 0), 1), PlacedPipe(MockPipeBehav(), :primary))

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
            TileCoord(0, 0) => PlacedComponent(MockCompBehav(), Q_POS, :primary),
        )
        set_component!(gm, comps)
        @test has_component(gm, TileCoord(0, 0))

        pipe_coord_1 = side_pipe(TileCoord(0, 0), 1)
        set_pipe!(gm, pipe_coord_1, PlacedPipe(MockPipeBehav(), :primary))
        @test has_pipe(gm, pipe_coord_1)
    end

    # ===============================================================
    # Tests — Cross-Ship Queries
    # ===============================================================

    @testset "Cross-Ship Queries — Components" begin
        gm = make_two_ship_map()
        coord_primary = TileCoord(0, 0)
        coord_second = TileCoord(20, 0)
        comp_primary = PlacedComponent(MockCompBehav(), Q_POS, :primary)
        comp_second = PlacedComponent(MockCompBehav(), Q_POS, :second)

        set_component!(gm, coord_primary, comp_primary)
        set_component!(gm, coord_second, comp_second)

        # get_component_shiptag returns the stored wrapper owner, or nothing
        @test get_component_shiptag(gm, coord_primary) == :primary
        @test get_component_shiptag(gm, coord_second) == :second
        @test isnothing(get_component_shiptag(gm, TileCoord(99, 99)))

        # get_component (no ship_name) returns the wrapper regardless of owner
        @test !isnothing(get_component(gm, coord_primary))
        @test get_component(gm, coord_primary).ship == :primary
        @test isnothing(get_component(gm, TileCoord(99, 99)))
    end

    @testset "Cross-Ship Queries — Pipes" begin
        gm = make_two_ship_map()
        pipe_coord_1 = side_pipe(TileCoord(0, 0), 1)
        set_pipe!(gm, pipe_coord_1, PlacedPipe(MockPipeBehav(), :primary))

        @test get_pipe_shiptag(gm, pipe_coord_1) == :primary
        @test !isnothing(get_pipe(gm, pipe_coord_1))
        @test get_pipe(gm, pipe_coord_1).ship == :primary

        pipe_coord_2 = side_pipe(TileCoord(99, 99), 1)
        @test isnothing(get_pipe_shiptag(gm, pipe_coord_2))
        @test isnothing(get_pipe(gm, pipe_coord_2))
    end

    @testset "Cross-Ship Queries — Surface Tiles" begin
        gm = make_two_ship_map()

        found1, ship1 = is_on_surface_tile_any_ship(TileCoord(0, 0), gm)
        @test found1
        @test ship1 == :primary

        found2, ship2 = is_on_surface_tile_any_ship(TileCoord(20, 0), gm)
        @test found2
        @test ship2 == :second

        found3, ship3 = is_on_surface_tile_any_ship(TileCoord(99, 99), gm)
        @test !found3
        @test isnothing(ship3)
    end

    @testset "find_ship_containing" begin
        gm = make_two_ship_map()

        @test find_ship_containing(gm, side_pipe(TileCoord(0, 0), 1)) == :primary
        @test find_ship_containing(gm, side_pipe(TileCoord(20, 0), 1)) == :second
        @test isnothing(find_ship_containing(gm, side_pipe(TileCoord(99, 99), 1)))
    end

    @testset "collect_surface_tiles!" begin
        gm = make_two_ship_map()

        primary_tiles = collect_surface_tiles!(Set{TileCoord}(), gm; ship_name = :primary)
        @test primary_tiles == Set([TileCoord(0, 0)])

        non_primary_tiles = collect_surface_tiles!(Set{TileCoord}(), gm; exclude_ship = :primary)
        @test non_primary_tiles == Set([TileCoord(20, 0)])
    end

    @testset "each_surface_owner" begin
        gm = make_two_ship_map()
        owners = Dict(each_surface_owner(gm))

        @test owners[TileCoord(0, 0)] == :primary
        @test owners[TileCoord(20, 0)] == :second
    end

    # ===============================================================
    # Tests — Ship-Finding Helpers
    # ===============================================================

    @testset "get_surface_shiptag" begin
        gm = make_two_ship_map()
        @test get_surface_shiptag(gm, TileCoord(0, 0)) == :primary
        @test get_surface_shiptag(gm, TileCoord(20, 0)) == :second
        @test isnothing(get_surface_shiptag(gm, TileCoord(99, 99)))
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

    @testset "would_bridge_ships (via find_ships_adjacent_to_coord)" begin
        # Two ships physically adjacent — a tile between them bridges
        gm = GameMap(ships = Dict(:ship_a => ShipState(), :ship_b => ShipState()))
        set_surface_tile!(gm, TileCoord(0, 0); ship_name = :ship_a)
        set_surface_tile!(gm, TileCoord(2, 0); ship_name = :ship_b)
        @test length(find_ships_adjacent_to_coord(gm, TileCoord(1, 0))) > 1

        # Single ship — never bridges
        gm2 = make_gamemap()
        @test length(find_ships_adjacent_to_coord(gm2, TileCoord(1, 0))) <= 1
    end

    @testset "find_ship_for_placement" begin
        gm = make_two_ship_map()
        comp = MockCompBehav()

        # On primary surface
        result = find_ship_for_placement(comp, TileCoord(0, 0), gm; rotation = Q_POS)
        @test isvalidrequest(result)
        @test unwrap(result) === :primary

        # On second surface
        result2 = find_ship_for_placement(comp, TileCoord(20, 0), gm; rotation = Q_POS)
        @test isvalidrequest(result2)
        @test unwrap(result2) === :second

        # Off all surfaces
        result3 = find_ship_for_placement(comp, TileCoord(99, 99), gm; rotation = Q_POS)
        @test !isvalidrequest(result3)
        @test reason(result3) == "Place components on a ship surface"

        specialised = find_ship_for_placement(OffSurfaceCompBehav(TileCoord(10, 10)), TileCoord(99, 99), gm; rotation = Q_POS)
        @test !isvalidrequest(specialised)
        @test reason(specialised) == "Wrong destination"
    end

    @testset "get_component_shiptag" begin
        gm = make_two_ship_map()
        set_component!(gm, TileCoord(0, 0), PlacedComponent(MockCompBehav(), Q_POS, :primary))
        set_component!(gm, TileCoord(20, 0), PlacedComponent(MockCompBehav(), Q_POS, :second))

        @test get_component_shiptag(gm, TileCoord(0, 0)) == :primary
        @test get_component_shiptag(gm, TileCoord(20, 0)) == :second
        @test isnothing(get_component_shiptag(gm, TileCoord(99, 99)))
    end

    @testset "get_pipe_shiptag" begin
        gm = make_two_ship_map()
        pipe_coord_1 = side_pipe(TileCoord(0, 0), 1)
        set_pipe!(gm, pipe_coord_1, PlacedPipe(MockPipeBehav(), :primary))

        @test get_pipe_shiptag(gm, pipe_coord_1) == :primary

        pipe_coord_2 = side_pipe(TileCoord(99, 99), 1)
        @test isnothing(get_pipe_shiptag(gm, pipe_coord_2))
    end

    @testset "find_ship_containing" begin
        gm = make_two_ship_map()

        @test find_ship_containing(gm, side_pipe(TileCoord(0, 0), 1)) == :primary
        @test find_ship_containing(gm, side_pipe(TileCoord(20, 0), 1)) == :second
        @test isnothing(find_ship_containing(gm, side_pipe(TileCoord(99, 99), 1)))
    end

    # ===============================================================
    # Tests — Placement Validation
    # ===============================================================

    @testset "placement_valid" begin
        gm = make_gamemap()
        comp = PlacedComponent(MockCompBehav(), Q_POS, :primary)

        # On surface — valid
        valid = placement_valid(comp, TileCoord(0, 0), gm)
        @test isvalidrequest(valid)

        # Off surface — invalid
        invalid = placement_valid(comp, TileCoord(99, 99), gm)
        @test !isvalidrequest(invalid)
        @test !isempty(reason(invalid))
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

        valid = can_place_component_at(TileCoord(0, 0), gm; ship_name = :primary)
        @test isvalidrequest(valid)

        invalid = can_place_component_at(TileCoord(99, 99), gm; ship_name = :primary)
        @test !isvalidrequest(invalid)
        @test !isempty(reason(invalid))
    end

    @testset "validate_component_destination" begin
        origin = TileCoord(0, 0)
        destination = TileCoord(1, 0)
        gm = make_gamemap_with_surface([origin, destination])
        component = PlacedComponent(MockCompBehav(), R_NEG, true, :primary)

        valid = validate_component_destination(component, destination, gm)
        @test isvalidrequest(valid)
        @test unwrap(valid) === :primary

        set_component!(gm, destination, PlacedComponent(MockCompBehav(), Q_POS, :primary))
        existing_component = get_component(gm, destination)
        invalid = validate_component_destination(component, destination, gm)
        @test !isvalidrequest(invalid)
        @test reason(invalid) == "a component already occupies the destination tile"
        @test get_component(gm, destination) === existing_component

        valid = validate_component_destination(
            component,
            destination,
            gm;
            vacating_coords = Set([destination]),
        )
        @test isvalidrequest(valid)
        @test unwrap(valid) === :primary

        delete_component!(gm, destination)
        crossing_pipe = get_pipe_segments(destination)[7]
        set_pipe!(gm, crossing_pipe, PlacedPipe(MockPipeBehav(), :primary))
        invalid = validate_component_destination(component, destination, gm; vacating_coords = Set([destination]))
        @test !isvalidrequest(invalid)
        @test reason(invalid) == "a pipe segment crosses the destination tile"

        delete_pipe!(gm, crossing_pipe)
        set_pipe!(gm, side_pipe(destination), PlacedPipe(MockPipeBehav(), :primary))
        @test isvalidrequest(validate_component_destination(component, destination, gm))

        off_surface = TileCoord(10, 10)
        specialised = PlacedComponent(OffSurfaceCompBehav(off_surface), Q_POS, :primary)
        valid = validate_component_destination(specialised, off_surface, gm)
        @test isvalidrequest(valid)
        @test unwrap(valid) === :primary

        invalid = validate_component_destination(component, TileCoord(20, 20), gm)
        @test !isvalidrequest(invalid)
        @test reason(invalid) == "Place components on a ship surface"

        second_ship_map = make_two_ship_map()
        valid = validate_component_destination(component, TileCoord(20, 0), second_ship_map)
        @test isvalidrequest(valid)
        @test unwrap(valid) === :second
    end

    @testset "can_place_pipe_at" begin
        gm = make_gamemap_with_surface(origin_neighbourhood())
        pipe_coord_1 = side_pipe(TileCoord(0, 0), 1)

        valid = can_place_pipe_at(pipe_coord_1, gm; ship_name = :primary)
        @test isvalidrequest(valid)

        # Pipe far off surface
        far_pipe = side_pipe(TileCoord(99, 99), 1)
        invalid = can_place_pipe_at(far_pipe, gm; ship_name = :primary)
        @test !isvalidrequest(invalid)
        @test !isempty(reason(invalid))
    end

    @testset "PipeCoord placement and component conflicts" begin
        gm = make_gamemap_with_surface(origin_neighbourhood())
        tile = TileCoord(0, 0)
        side = get_pipe_segments(tile)[1]
        short_diag = get_pipe_segments(tile)[7]
        long_diag = get_pipe_segments(tile)[13]

        @test isvalidrequest(can_place_pipe_at(side, gm; ship_name = :primary))
        @test isvalidrequest(can_place_pipe_at(short_diag, gm; ship_name = :primary))
        @test isvalidrequest(can_place_pipe_at(long_diag, gm; ship_name = :primary))

        set_component!(gm, tile, PlacedComponent(MockCompBehav(), Q_POS, :primary))
        @test isvalidrequest(can_place_pipe_at(side, gm; ship_name = :primary))
        invalid_short = can_place_pipe_at(short_diag, gm; ship_name = :primary)
        invalid_long = can_place_pipe_at(long_diag, gm; ship_name = :primary)
        @test !isvalidrequest(invalid_short)
        @test reason(invalid_short) == "Pipe segment crosses an occupied tile"
        @test !isvalidrequest(invalid_long)
        @test reason(invalid_long) == "Pipe segment crosses an occupied tile"

        gm2 = make_gamemap_with_surface(origin_neighbourhood())
        set_pipe!(gm2, short_diag, PlacedPipe(MockPipeBehav(), :primary))
        invalid_component = can_place_component_at(tile, gm2; ship_name = :primary)
        @test !isvalidrequest(invalid_component)
        @test reason(invalid_component) == "Tile contains a pipe segment"

        gm3 = make_gamemap_with_surface(origin_neighbourhood())
        set_pipe!(gm3, side, PlacedPipe(MockPipeBehav(), :primary))
        @test isvalidrequest(can_place_component_at(tile, gm3; ship_name = :primary))
    end

    @testset "Pipe click hit-testing" begin
        tile = TileCoord(0, 0)
        side = get_pipe_segments(tile)[1]
        long_diag = get_pipe_segments(tile)[13]
        higher_long_diag = get_pipe_segments(tile)[15]
        pipe = PlacedPipe(MockPipeBehav(), :primary)

        centre = to_cartesian(side)
        a = to_cartesian(side.v1)
        b = to_cartesian(side.v2)
        segment_vec = b - a
        segment_len = sqrt(segment_vec.x^2 + segment_vec.y^2)
        normal = CartesianCoord(-segment_vec.y / segment_len, segment_vec.x / segment_len)

        @test is_click_on_pipe(centre, side, pipe)
        @test is_click_on_pipe(CartesianCoord(centre.x + normal.x * 0.1, centre.y + normal.y * 0.1), side, pipe)
        @test is_click_on_pipe(CartesianCoord(centre.x - normal.x * 0.1, centre.y - normal.y * 0.1), side, pipe)
        @test !is_click_on_pipe(CartesianCoord(centre.x + normal.x * 0.1001, centre.y + normal.y * 0.1001), side, pipe)
        @test !is_click_on_pipe(CartesianCoord(centre.x - normal.x * 0.1001, centre.y - normal.y * 0.1001), side, pipe)

        gm_empty = GameMap()
        @test isnothing(get_clicked_pipe(centre, gm_empty))

        gm = GameMap()
        set_pipe!(gm, long_diag, pipe)
        @test get_clicked_pipe(to_cartesian(long_diag), gm) == long_diag

        set_pipe!(gm, higher_long_diag, pipe)
        @test get_clicked_pipe(to_cartesian(tile), gm) == higher_long_diag

        short_rank_4 = get_pipe_segments(tile)[7]
        long_rank_2 = get_pipe_segments(tile)[14]
        gm_short_over_long = GameMap()
        set_pipe!(gm_short_over_long, long_rank_2, pipe)
        set_pipe!(gm_short_over_long, short_rank_4, pipe)
        @test get_clicked_pipe(to_cartesian(short_rank_4), gm_short_over_long) == short_rank_4

        short_rank_5 = get_pipe_segments(tile)[8]
        short_rank_6 = get_pipe_segments(tile)[9]
        gm_short_over_short = GameMap()
        set_pipe!(gm_short_over_short, short_rank_5, pipe)
        set_pipe!(gm_short_over_short, short_rank_6, pipe)
        @test get_clicked_pipe(CartesianCoord(-0.5, sqrt(3) / 6), gm_short_over_short) == short_rank_6
    end

    @testset "Pipe click radius API" begin
        @test_throws ErrorException get_pipe_click_radius(MissingClickRadiusPipe())

        pipe = PlacedPipe(MockPipeBehav(), :primary)
        @test get_pipe_click_radius(pipe) == 0.1
    end

    @testset "can_remove_surface_at" begin
        gm = make_gamemap()

        # Can remove empty surface tile
        set_surface_tile!(gm, TileCoord(1, 0))
        valid = can_remove_surface_at(TileCoord(1, 0), gm; ship_name = :primary)
        @test isvalidrequest(valid)

        # Cannot remove surface under a component
        set_component!(gm, TileCoord(0, 0), PlacedComponent(MockCompBehav(), Q_POS, :primary))
        invalid = can_remove_surface_at(TileCoord(0, 0), gm; ship_name = :primary)
        @test !isvalidrequest(invalid)
        @test contains(lowercase(reason(invalid)), "component")
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

        # GameMap overload — default :primary surface at origin
        gm = make_gamemap()
        centroid_gm = get_surface_centroid(gm, :primary)
        @test centroid_gm ≈ AxialCoord(0.0, 0.0)

        # Empty surface returns nothing
        gm_empty = GameMap()
        delete_all_surface_tiles!(gm_empty; ship_name = :primary)
        @test isnothing(get_surface_centroid(gm_empty, :primary))

        @test get_surface_centroid(TileCoord(t.q, t.r) for t in origin_neighbourhood()) == AxialCoord(0.0, 0.0)
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

        # GameMap overload matches combined set
        gm = make_gamemap()
        set_surface_tile!(gm, TileCoord(2, 0))
        collected = collect_surface_tiles!(Set{TileCoord}(), gm)
        @test get_axial_bounds(gm) == get_axial_bounds(collected)
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

        # GameMap overload — single ship matches set overload of its tiles
        gm_single = make_gamemap()
        set_surface_tile!(gm_single, TileCoord(3, 0))
        collected_single = collect_surface_tiles!(Set{TileCoord}(), gm_single)
        @test get_cartesian_bounds(gm_single) == get_cartesian_bounds(collected_single)

        # Multi-ship bounds spans both ships
        gm = GameMap()
        set_surface_tile!(gm, TileCoord(10, 0))
        add_ship!(gm, :second, ShipState())
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

    @testset "collect_surface_edge_tiles!" begin
        # Single tile is its own edge tile
        gm = make_gamemap()
        edgeset = Set{TileCoord}()
        collect_surface_edge_tiles!(edgeset, gm)
        @test TileCoord(0, 0) in edgeset
        @test length(edgeset) == 1

        # A full hex ring: the centre tile is NOT an edge tile
        gm2 = GameMap()
        for t in origin_neighbourhood()
            set_surface_tile!(gm2, t; ship_name = :primary)
        end
        edgeset2 = Set{TileCoord}()
        collect_surface_edge_tiles!(edgeset2, gm2)
        @test !(TileCoord(0, 0) in edgeset2)  # centre has 6 neighbours, not an edge
        @test length(edgeset2) == 6            # only the ring tiles are edges

        # GameMap overload (multi-ship)
        gm3 = make_two_ship_map()
        edgeset3 = Set{TileCoord}()
        collect_surface_edge_tiles!(edgeset3, gm3)
        @test length(edgeset3) == 2  # each ship has 1 tile, both are edge tiles
    end

    # ===============================================================
    # Tests — Off-Ship Pipe Functions
    # ===============================================================

    @testset "can_place_pipe_offship" begin
        gm = make_gamemap()
        # Completely disconnected pipe — neither endpoint connected
        far_pipe = side_pipe(TileCoord(50, 50), 1)
        invalid = can_place_pipe_offship(far_pipe, gm)
        @test !isvalidrequest(invalid)
        @test !isempty(reason(invalid))

        gm = make_gamemap_with_surface(origin_neighbourhood())
        valid = can_place_pipe_offship(side_pipe(TileCoord(0, 0), 1), gm)
        @test isvalidrequest(valid)
        @test unwrap(valid) === :primary
    end

    @testset "flood_search_pipes_from_node!" begin
        # Build a simple chain of pipes and verify flood fill finds them all
        gm = make_gamemap_with_surface(origin_neighbourhood())

        # Place two connected side-span pipes on (0,0)
        pipe_coord_1 = side_pipe(TileCoord(0, 0), 1)
        pipe_coord_2 = side_pipe(TileCoord(0, 0), 2)
        set_pipe!(gm, pipe_coord_1, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, pipe_coord_2, PlacedPipe(MockPipeBehav(), :primary))

        all_pipe_coords = Set([pipe_coord_1, pipe_coord_2])
        start_node = to_nodecoord(pipe_coord_1.v1)

        reachable = Set{PipeCoord}()
        flood_search_pipes_from_node!(reachable, all_pipe_coords, start_node)

        # Should find at least the pipe we started from
        @test pipe_coord_1 in reachable

        # Empty pipe set should yield empty reachable
        empty_reachable = Set{PipeCoord}()
        flood_search_pipes_from_node!(empty_reachable, Set{PipeCoord}(), start_node)
        @test isempty(empty_reachable)
    end

    @testset "resolve_pipe_ownerships" begin
        gm = make_gamemap()
        on_surface = side_pipe(TileCoord(0, 0), 1)
        valid = resolve_pipe_ownerships(gm, Set{PipeCoord}())
        @test isvalidrequest(valid)
        @test isempty(unwrap(valid))

        valid = resolve_pipe_ownerships(gm, Set([on_surface]))
        @test isvalidrequest(valid)
        @test unwrap(valid)[on_surface] === :primary

        detached = side_pipe(TileCoord(50, 50), 1)
        invalid = resolve_pipe_ownerships(gm, Set([detached]))
        @test !isvalidrequest(invalid)
        @test reason(invalid) == "Pipe network is not connected to a ship surface"

        set_pipe!(gm, on_surface, PlacedPipe(MockPipeBehav(), :stale))
        @test isvalidrequest(normalise_pipe_ownership!(gm))
        @test get_pipe(gm, on_surface).ship === :primary
        @test get_pipe(gm, on_surface).pipe isa MockPipeBehav
    end

    @testset "PipeCoord flood fill and off-ship deletion" begin
        source = VertexCoord(TileCoord(0, 0), Q_POS)
        anchor = get_pipe_segments(source)[1]
        anchor_end = anchor.v1 == to_proper(source) ? anchor.v2 : anchor.v1
        branch = first(pipe for pipe in get_pipe_segments(anchor_end) if pipe != anchor && !is_side_span(pipe))

        gm = make_gamemap()
        set_pipe!(gm, anchor, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, branch, PlacedPipe(MockPipeBehav(), :primary))

        reachable = Set{PipeCoord}()
        flood_search_pipes_from_node!(reachable, Set([anchor, branch]), to_nodecoord(source))
        @test reachable == Set([anchor, branch])
        @test find_ship_pipes_containing_node(to_nodecoord(anchor_end), gm; default = nothing) == :primary
        @test !validate_offship_pipe_deletion(anchor, gm)
    end

    @testset "validate_offship_pipe_deletion" begin
        gm = make_gamemap()
        # No off-ship pipes — deletion always valid
        pipe_coord_1 = side_pipe(TileCoord(0, 0), 1)
        @test validate_offship_pipe_deletion(pipe_coord_1, gm) == true
    end

    # ===============================================================
    # Tests — Offset Ship
    # ===============================================================

    @testset "offset_ship!" begin
        gm = make_gamemap()
        set_component!(gm, TileCoord(0, 0), PlacedComponent(MockCompBehav(), Q_POS, :primary))
        pipe_coord_1 = side_pipe(TileCoord(0, 0), 1)
        set_pipe!(gm, pipe_coord_1, PlacedPipe(MockPipeBehav(), :primary))

        offset = TileCoord(5, 3)
        offset_ship!(gm, :primary, offset)

        # Surface tile should be offset
        @test !is_on_surface_tile(TileCoord(0, 0), gm; ship_name = :primary)
        @test is_on_surface_tile(TileCoord(5, 3), gm; ship_name = :primary)

        # Component should be at offset location
        @test !has_component(gm, TileCoord(0, 0))
        @test has_component(gm, TileCoord(5, 3))

        # Pipe should no longer be at original edge
        @test !has_pipe(gm, pipe_coord_1)
        @test count_pipes(gm; ship_name = :primary) == 1  # still has the pipe, just at new edge
    end

    @testset "offset_ship! — preserves counts" begin
        gm = GameMap()
        set_component!(gm, TileCoord(0, 0), PlacedComponent(MockCompBehav(), Q_POS, :primary))
        set_surface_tile!(gm, TileCoord(1, 0); ship_name = :primary)
        pipe_coord_1 = side_pipe(TileCoord(0, 0), 1)
        pipe_coord_2 = side_pipe(TileCoord(0, 0), 2)
        set_pipe!(gm, pipe_coord_1, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, pipe_coord_2, PlacedPipe(MockPipeBehav(), :primary))

        comps_before = count_components(gm; ship_name = :primary)
        pipes_before = count_pipes(gm; ship_name = :primary)
        tiles_before = count_surface_tiles(gm; ship_name = :primary)

        offset_ship!(gm, :primary, TileCoord(10, 10))

        @test count_components(gm; ship_name = :primary) == comps_before
        @test count_pipes(gm; ship_name = :primary) == pipes_before
        @test count_surface_tiles(gm; ship_name = :primary) == tiles_before
    end

    @testset "offset_ship! translates blueprint coordinates" begin
        blueprint = ShipBlueprint()
        component_coord = TileCoord(1, -2)
        surface_tile = TileCoord(2, -3)
        pipe_coord_1 = side_pipe(component_coord, 1)
        offset = TileCoord(-4, 7)

        blueprint.components[component_coord] = PlacedComponent(MockCompBehav(), Q_POS, :primary)
        blueprint.pipe_behaviors[pipe_coord_1] = MockPipeBehav()
        push!(blueprint.ship_tiles, surface_tile)

        offset_ship!(blueprint, offset)

        @test haskey(blueprint.components, offset_by_tile(component_coord, offset))
        @test offset_by_tile(surface_tile, offset) in blueprint.ship_tiles
        @test haskey(blueprint.pipe_behaviors, offset_by_tile(pipe_coord_1, offset))
    end

    @testset "offset_ship! preserves diagonal pipe keys" begin
        gm = GameMap()
        short_diag = get_pipe_segments(TileCoord(0, 0))[7]
        long_diag = get_pipe_segments(TileCoord(0, 0))[13]
        set_pipe!(gm, short_diag, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, long_diag, PlacedPipe(MockPipeBehav(), :primary))

        offset = TileCoord(3, -2)
        offset_ship!(gm, :primary, offset)

        moved_short = PipeCoord(
            VertexCoord(short_diag.v1.tile + offset, short_diag.v1.dir),
            VertexCoord(short_diag.v2.tile + offset, short_diag.v2.dir),
        )
        moved_long = PipeCoord(
            VertexCoord(long_diag.v1.tile + offset, long_diag.v1.dir),
            VertexCoord(long_diag.v2.tile + offset, long_diag.v2.dir),
        )

        @test !has_pipe(gm, short_diag)
        @test !has_pipe(gm, long_diag)
        @test has_pipe(gm, moved_short)
        @test has_pipe(gm, moved_long)
    end

    # ===============================================================
    # Tests — Docking Status Types
    # ===============================================================

    @testset "DockingStatus — ConnectedDockStat" begin
        status = ConnectedDockStat()
        @test get_render_offset(status) === nothing
        @test update_render_offset!(status) == false
    end

    @testset "DockingStatus — ApproachingDockStat" begin
        start_pos = AxialCoord(10.0, 0.0)
        target_pos = AxialCoord(0.0, 0.0)
        step = 1.0

        status = ApproachingDockStat(start_pos, target_pos, step)

        @test get_render_offset(status) isa AxialCoord

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

        status = DepartingDockStat(start_pos, target_pos, step)

        @test get_render_offset(status) isa AxialCoord

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
        add_ship!(gm, :visitor, ShipState())
        set_docking_status!(
            gm, :visitor, ApproachingDockStat(
                AxialCoord(3.0, 0.0), AxialCoord(0.0, 0.0), 1.0
            )
        )
        for _ in 1:10000
            update_docking!(gm; ship_name = :visitor)
            get_docking_status(gm, :visitor) isa ConnectedDockStat && break
        end
        @test get_docking_status(gm, :visitor) isa ConnectedDockStat
    end

    @testset "update_docking! — Departing → removed" begin
        gm = GameMap()
        add_ship!(gm, :visitor, ShipState())
        set_docking_status!(
            gm, :visitor, DepartingDockStat(
                AxialCoord(0.0, 0.0), AxialCoord(4.0, 0.0), 1.0
            )
        )
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
        add_ship!(gm, :v1, ShipState())
        add_ship!(gm, :v2, ShipState())

        set_docking_status!(
            gm, :v1, ApproachingDockStat(
                AxialCoord(2.0, 0.0), AxialCoord(0.0, 0.0), 1.0
            )
        )
        set_docking_status!(
            gm, :v2, ApproachingDockStat(
                AxialCoord(2.0, 0.0), AxialCoord(0.0, 0.0), 1.0
            )
        )

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
        add_ship!(gm, :visitor, ShipState())
        set_docking_status!(
            gm, :visitor, ApproachingDockStat(
                AxialCoord(5.0, 0.0), AxialCoord(0.0, 0.0), 0.01
            )
        )

        clear_all_docking_statuses!(gm)
        @test get_docking_status(gm, :visitor) isa ConnectedDockStat
        @test get_docking_status(gm, :primary) isa ConnectedDockStat
    end

    @testset "is_ship_moving" begin
        @test !is_ship_moving(ShipState())
        @test is_ship_moving(ShipState(docking_status = ApproachingDockStat(AxialCoord(1.0, 0.0), AxialCoord(0.0, 0.0), 0.5)))
        @test is_ship_moving(ShipState(docking_status = DepartingDockStat(AxialCoord(0.0, 0.0), AxialCoord(1.0, 0.0), 0.5)))

        gm = GameMap()
        add_ship!(gm, :visitor, ShipState(docking_status = ApproachingDockStat(AxialCoord(1.0, 0.0), AxialCoord(0.0, 0.0), 0.5)))
        @test is_ship_moving(gm, :visitor)
        @test !is_ship_moving(gm, :primary)
    end

    @testset "get/set docking_status" begin
        gm = make_gamemap()
        @test get_docking_status(gm, :primary) isa ConnectedDockStat
        @test isnothing(get_docking_status(gm, :nonexistent))

        set_docking_status!(gm, :primary, ConnectedDockStat())
        @test get_docking_status(gm, :primary) isa ConnectedDockStat

        @test_throws ErrorException set_docking_status!(gm, :nonexistent, ConnectedDockStat())

        # ShipState-level
        ship = get_ship_state(gm, :primary)
        @test get_docking_status(ship) isa ConnectedDockStat
        set_docking_status!(ship, ConnectedDockStat())
        @test get_docking_status(ship) isa ConnectedDockStat
    end

    @testset "get_ship_render_offset" begin
        gm = make_gamemap()
        offset = get_ship_render_offset(gm, :primary)
        @test offset ≈ AxialCoord(0.0, 0.0)

        ship = get_ship_state(gm, :primary)
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
        add_ship!(gm, :visitor, ShipState())

        success, _ = swap_primary!(gm, :visitor)
        @test success

        # Both new primary and retired ship should be ConnectedDockStat
        @test get_docking_status(get_ship_state(gm, :primary)) isa ConnectedDockStat
        retired_names = filter(n -> n != :primary, get_all_ship_names(gm))
        @test length(retired_names) == 1
        @test get_docking_status(get_ship_state(gm, retired_names[1])) isa ConnectedDockStat
    end

    @testset "swap_primary! — round-trip" begin
        gm = GameMap()
        set_component!(gm, TileCoord(0, 0), PlacedComponent(MockCompBehav(), Q_POS, :primary))
        add_ship!(gm, :visitor, ShipState())
        set_surface_tile!(gm, TileCoord(10, 0); ship_name = :visitor)
        set_component!(gm, TileCoord(10, 0), PlacedComponent(MockCompBehav(), R_NEG, :visitor))

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
    # Tests — Node ship queries
    # ===============================================================

    @testset "find_ship_surface_containing_node" begin
        gm = make_two_ship_map()

        node_primary = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
        @test find_ship_surface_containing_node(node_primary, gm; default = nothing) == :primary

        node_second = NodeCoord(TileCoord(20, 0), HexFrame.NODE_Q_POS)
        @test find_ship_surface_containing_node(node_second, gm; default = nothing) == :second

        node_nowhere = NodeCoord(TileCoord(99, 99), HexFrame.NODE_Q_POS)
        @test isnothing(find_ship_surface_containing_node(node_nowhere, gm; default = nothing))
    end

    @testset "find_ship_pipes_containing_node" begin
        gm = make_two_ship_map()
        offsurface_pipe = side_pipe(TileCoord(99, 99), 1)
        set_pipe!(gm, offsurface_pipe, PlacedPipe(MockPipeBehav(), :second))

        axis_node = to_nodecoord(offsurface_pipe.v1)
        @test find_ship_pipes_containing_node(axis_node, gm; default = nothing) == :second

        non_axis_node = NodeCoord(TileCoord(99, 99), HexFrame.NODE_INTERNAL_1)
        @test isnothing(find_ship_pipes_containing_node(non_axis_node, gm; default = nothing))
    end

    @testset "find_ship_for_node" begin
        gm = make_two_ship_map()

        node_primary = NodeCoord(TileCoord(0, 0), HexFrame.NODE_Q_POS)
        node_second = NodeCoord(TileCoord(20, 0), HexFrame.NODE_Q_POS)
        node_nowhere = NodeCoord(TileCoord(150, 150), HexFrame.NODE_Q_POS)
        non_axis_surface_node = NodeCoord(TileCoord(0, 0), HexFrame.NODE_INTERNAL_1)

        @test find_ship_for_node(node_primary, gm) == :primary
        @test find_ship_for_node(node_second, gm) == :second
        @test find_ship_for_node(non_axis_surface_node, gm; default = nothing) == :primary

        precedence_pipe = side_pipe(TileCoord(0, 0), 1)
        set_pipe!(gm, precedence_pipe, PlacedPipe(MockPipeBehav(), :second))
        @test find_ship_for_node(to_nodecoord(precedence_pipe.v1), gm; default = nothing) == :primary

        offsurface_pipe = side_pipe(TileCoord(99, 99), 1)
        set_pipe!(gm, offsurface_pipe, PlacedPipe(MockPipeBehav(), :second))
        @test find_ship_for_node(to_nodecoord(offsurface_pipe.v1), gm; default = nothing) == :second

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
        set_active_manoeuvre!(sm, ManoeuvreData(approach_burn_dv = SVector(0.0, 0.0), capture_burn_dv = SVector(0.0, 0.0)))
        clear_active_manoeuvre!(sm)
    end

    @testset "GalaxyEscapeSpaceMap — validation, accessors, and progress" begin
        initial_velocity = SVector(25.0, -4.0)
        pre_escape_map = GameMap()
        sm = GalaxyEscapeSpaceMap(
            velocity = initial_velocity,
            starting_velocity_x = 25.0,
            departure_time_years = 12.5,
            pre_escape_map = pre_escape_map,
        )

        @test sm == GalaxyEscapeSpaceMap(
            velocity = initial_velocity,
            starting_velocity_x = 25.0,
            departure_time_years = 12.5,
            pre_escape_map = deepcopy(pre_escape_map),
        )
        @test deepcopy(sm) == sm
        @test deepcopy(sm) !== sm
        @test get_pre_escape_map(sm) === pre_escape_map
        @test_throws ArgumentError GalaxyEscapeSpaceMap(
            velocity = SVector(Inf, 0.0), starting_velocity_x = 0.0, departure_time_years = 0.0,
            pre_escape_map = pre_escape_map,
        )
        @test_throws ArgumentError GalaxyEscapeSpaceMap(
            velocity = SVector(0.0, NaN), starting_velocity_x = 0.0, departure_time_years = 0.0,
            pre_escape_map = pre_escape_map,
        )
        @test_throws ArgumentError GalaxyEscapeSpaceMap(
            velocity = SVector(0.0, 0.0), starting_velocity_x = Inf, departure_time_years = 0.0,
            pre_escape_map = pre_escape_map,
        )
        @test_throws ArgumentError GalaxyEscapeSpaceMap(
            velocity = SVector(0.0, 0.0), starting_velocity_x = 0.0, departure_time_years = -1.0,
            pre_escape_map = pre_escape_map,
        )
        @test_throws ArgumentError GalaxyEscapeSpaceMap(
            velocity = SVector(0.0, 0.0), starting_velocity_x = 0.0, departure_time_years = NaN,
            pre_escape_map = pre_escape_map,
        )
        nested_backup = GameMap(space_map = sm)
        @test_throws ArgumentError GalaxyEscapeSpaceMap(
            velocity = initial_velocity, starting_velocity_x = 25.0,
            departure_time_years = 12.5, pre_escape_map = nested_backup,
        )

        @test get_velocity(sm) == initial_velocity
        @test isnothing(get_space_map_seed(sm))
        @test get_time_years(sm) == 12.5
        @test get_position(sm) == SVector(0.0, 0.0)
        @test get_target_time(sm) == 12.5
        @test get_last_stop_time(sm) == 12.5
        @test !is_time_progressing(sm)
        @test !has_active_manoeuvre(sm)
        @test isnothing(get_active_manoeuvre(sm))
        @test get_encounter_points(sm) isa Vector{EncounterPoint}
        @test isempty(get_encounter_points(sm))

        set_time_years!(sm, 100.0)
        set_position!(sm, SVector(8.0, 9.0))
        set_target_time!(sm, 100.0)
        set_last_stop_time!(sm, 100.0)
        set_active_manoeuvre!(
            sm, ManoeuvreData(
                approach_burn_dv = SVector(1.0, 0.0), capture_burn_dv = SVector(-1.0, 0.0),
            )
        )
        clear_active_manoeuvre!(sm)
        @test get_time_years(sm) == 12.5
        @test get_position(sm) == SVector(0.0, 0.0)
        @test get_target_time(sm) == 12.5
        @test get_last_stop_time(sm) == 12.5
        @test !has_active_manoeuvre(sm)

        @test galaxy_escape_progress(sm) == 0.0
        set_velocity!(sm, SVector(30.0, -4.0))
        @test galaxy_escape_progress(sm) == 5.0
        set_velocity!(sm, SVector(27.0, -4.0))
        @test galaxy_escape_progress(sm) == 2.0
        set_velocity!(sm, SVector(20.0, -4.0))
        @test galaxy_escape_progress(sm) == 0.0
        set_velocity!(sm, SVector(25.0, 40.0))
        @test galaxy_escape_progress(sm) == 0.0
    end

    @testset "Galaxy escape mode lookup" begin
        empty_map = GameMap()
        @test !is_galaxy_escape_active(empty_map.space_map)
        @test !is_galaxy_escape_active(empty_map)
        @test isnothing(get_galaxy_escape_space_map(empty_map))
        @test isnothing(get_pre_escape_map(empty_map))
        @test isnothing(get_galaxy_escape_progress(empty_map))

        escape_map = GalaxyEscapeSpaceMap(
            velocity = SVector(12.0, 3.0), starting_velocity_x = 10.0, departure_time_years = 4.0,
            pre_escape_map = GameMap(),
        )
        gamemap = GameMap(space_map = escape_map)
        @test is_galaxy_escape_active(escape_map)
        @test is_galaxy_escape_active(gamemap)
        @test get_galaxy_escape_space_map(gamemap) === escape_map
        @test get_pre_escape_map(gamemap) === escape_map.pre_escape_map
        @test get_galaxy_escape_progress(gamemap) == 2.0
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
        gm = make_gamemap()
        # One surface tile at get_tile_mass() per tile, no components
        @test get_mass(gm) == get_tile_mass()

        # Custom mass per tile
        @test get_mass(gm; mass_per_tile = 500.0) == 500.0

        # Multiple surface tiles
        set_surface_tile!(gm, TileCoord(1, 0))
        @test get_mass(gm) == 2 * get_tile_mass()

        # Multi-ship
        add_ship!(gm, :other, ShipState())
        set_surface_tile!(gm, TileCoord(20, 0); ship_name = :other)
        @test get_mass(gm) == 3 * get_tile_mass()  # 2 + 1 tiles

        # Mixed concrete component types and ship tags contribute to global totals
        set_component!(gm, TileCoord(0, 0), PlacedComponent(MassCompBehav(3, 7, HexFluids.COLD_GAS), Q_POS, :primary))
        set_component!(gm, TileCoord(1, 0), PlacedComponent(MassCompBehav(5, 11, HexFluids.COLD_GAS), Q_POS, :primary))
        set_component!(gm, TileCoord(20, 0), PlacedComponent(MassCompBehav(2.5, 4.5, HexFluids.MONOPROP_LIQUID), Q_POS, :other))
        @test get_dry_mass(gm; mass_per_tile = 100.0) == 310.5
        @test get_wet_mass(gm) == 22.5
        @test get_wet_mass(gm; fluid = HexFluids.COLD_GAS) == 18.0
        @test get_wet_mass(gm; fluid = HexFluids.MONOPROP_LIQUID) == 4.5
        @test get_wet_mass(gm; fluid = HexFluids.FUEL_LIQUID) == 0.0
        @test get_mass(gm; mass_per_tile = 100.0) == 333.0
        delete_all_components!(gm; ship_name = :primary)
        delete_all_components!(gm; ship_name = :other)
        @test get_dry_mass(gm; mass_per_tile = 100.0) == 300.0
        @test get_wet_mass(gm) == 0.0
    end

    # ===============================================================
    # Tests — Space Map Types
    # ===============================================================

    @testset "ManoeuvreData" begin
        man = ManoeuvreData(
            approach_burn_dv = SVector(10.0, 0.0),
            capture_burn_dv = SVector(-5.0, 0.0),
            approach_burn_time = 1.0,
            intercept_time = 2.0,
            target_encounter_index = 1,
        )

        @test man.phase == PHASE_APPROACH_BURN
        @test man.approach_burn_dv ≈ SVector(10.0, 0.0)
        @test man.capture_burn_dv ≈ SVector(-5.0, 0.0)
        @test man.approach_burn_time == 1.0
        @test man.intercept_time == 2.0
        @test man.target_encounter_index == 1

        # Mutable fields can be updated
        man.phase = PHASE_APPROACH_BURN
        @test man.phase == PHASE_APPROACH_BURN

        man.burn_remaining_dv = SVector(5.0, 0.0)
        @test man.burn_remaining_dv ≈ SVector(5.0, 0.0)
    end

    @testset "ManoeuvrePhase enum" begin
        @test PHASE_APPROACH_BURN isa ManoeuvrePhase
        @test PHASE_COAST isa ManoeuvrePhase
        @test PHASE_CAPTURE_BURN isa ManoeuvrePhase
        @test PHASE_ENCOUNTER_READY isa ManoeuvrePhase

        @test phase_description(PHASE_APPROACH_BURN) == "Performing Approach Burn"
        @test phase_description(PHASE_COAST) == "Waiting for Target Intercept"
        @test phase_description(PHASE_CAPTURE_BURN) == "Performing Capture Burn"
        @test phase_description(PHASE_ENCOUNTER_READY) == "Target Reached"
        @test Int(PHASE_APPROACH_BURN) == 1
        @test Int(PHASE_COAST) == 2
        @test Int(PHASE_CAPTURE_BURN) == 3
        @test Int(PHASE_ENCOUNTER_READY) == 4
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
        @test ep.fuel_tag === nothing
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

    @testset "PlaythroughStatistics" begin
        statistics = PlaythroughStatistics()
        @test get_recorded_play_time_seconds(statistics) == 0.0
        @test get_simulated_ticks(statistics) == 0
        @test get_simulated_seconds(statistics) == 0.0
        @test get_total_delta_v(statistics) == 0.0
        @test get_peak_thrust(statistics) == 0.0
        @test get_peak_estimated_delta_v(statistics) == 0.0
        @test get_total_encounter_count(statistics) == 0
        @test isempty(statistics.completed_encounters)

        first_map = GameMap()
        second_map = GameMap()
        record_completed_encounter!(first_map, ENCOUNTER_SHIP)
        @test get_encounter_count(first_map, ENCOUNTER_SHIP) == 1
        @test get_encounter_count(second_map, ENCOUNTER_SHIP) == 0
        @test first_map.statistics.completed_encounters !== second_map.statistics.completed_encounters

        set_recorded_play_time_seconds!(statistics, 12.5)
        @test get_recorded_play_time_seconds(statistics) == 12.5
        for invalid_value in (-1.0, Inf, NaN)
            @test_throws ArgumentError set_recorded_play_time_seconds!(statistics, invalid_value)
        end

        increment_simulated_ticks!(statistics)
        increment_simulated_ticks!(statistics)
        @test get_simulated_ticks(statistics) == 2
        @test get_simulated_seconds(statistics) == 2 / BASE_UPS

        record_delta_v!(statistics, 1.25)
        record_delta_v!(statistics, 0.75)
        @test get_total_delta_v(statistics) == 2.0
        for invalid_value in (-1.0, Inf, NaN)
            @test_throws ArgumentError record_delta_v!(statistics, invalid_value)
        end

        record_peak_thrust!(statistics, 5.0)
        record_peak_thrust!(statistics, 3.0)
        @test get_peak_thrust(statistics) == 5.0
        for invalid_value in (-1.0, Inf, NaN)
            @test_throws ArgumentError record_peak_thrust!(statistics, invalid_value)
        end

        @test record_peak_estimated_delta_v!(statistics, 1200.0)
        @test get_peak_estimated_delta_v(statistics) == 1200.0
        @test !record_peak_estimated_delta_v!(statistics, 1200.0)
        @test !record_peak_estimated_delta_v!(statistics, 900.0)
        @test get_peak_estimated_delta_v(statistics) == 1200.0
        for invalid_value in (-1.0, Inf, NaN)
            @test_throws ArgumentError record_peak_estimated_delta_v!(statistics, invalid_value)
        end

        peak_map = GameMap()
        @test record_peak_estimated_delta_v!(peak_map, 1500)
        @test get_peak_estimated_delta_v(peak_map) == 1500.0
        copied_statistics = deepcopy(peak_map.statistics)
        @test copied_statistics == peak_map.statistics
        @test copied_statistics !== peak_map.statistics

        @test get_encounter_count(statistics, ENCOUNTER_FUEL_CACHE) == 0
        record_completed_encounter!(statistics, ENCOUNTER_SHIP)
        record_completed_encounter!(statistics, ENCOUNTER_SHIP)
        record_completed_encounter!(statistics, ENCOUNTER_FUEL_CACHE)
        @test get_encounter_count(statistics, ENCOUNTER_SHIP) == 2
        @test get_encounter_count(statistics, ENCOUNTER_FUEL_CACHE) == 1
        @test get_total_encounter_count(statistics) == 3

        @test get_simulated_ticks(GameMap(ShipState())) == 0
        @test get_recorded_play_time_seconds(GameMap(ShipBlueprint())) == 0.0
    end

    @testset "initialise_spacemap! (moved to HexFlowProcGen)" begin
        # initialise_spacemap! implementation has moved to HexFlowProcGen.
        # These tests are now in HexFlowProcGen tests.
        @test true
    end

    # ===============================================================
    # LearningProgress Tests
    # ===============================================================

    @testset "LearningProgress" begin
        @testset "default construction" begin
            lp = LearningProgress()
            @test isempty(lp.tutorials)
        end

        @testset "TutorialState default" begin
            ts = TutorialState()
            @test ts.status == TUTORIAL_WAITING
            @test ts.unlocked_step == 1
        end

        @testset "GameMap includes learning_system" begin
            gm = GameMap()
            @test gm.learning_system isa NoLearningSystem
            @test !has_learning_system(gm)

            set_learning_system!(gm, LearningProgress())
            @test gm.learning_system isa LearningProgress
            @test has_learning_system(gm)
            @test isempty(gm.learning_system.tutorials)

            set_learning_system!(gm, SandboxLearningState(tutorial_id = :sandbox))
            @test is_sandbox_learning(gm)
        end

        @testset "tutorial state mutation" begin
            lp = LearningProgress()
            lp.tutorials[:test] = TutorialState(status = TUTORIAL_IN_PROGRESS, unlocked_step = 3)
            @test lp.tutorials[:test].status == TUTORIAL_IN_PROGRESS
            @test lp.tutorials[:test].unlocked_step == 3
        end
    end

    # ===============================================================
    # expand_tileset
    # ===============================================================

    @testset "expand_tileset" begin
        @testset "single tile expands to 7" begin
            tiles = Set([TileCoord(0, 0)])
            expanded = expand_tileset(tiles)
            @test TileCoord(0, 0) in expanded
            # All 6 neighbours of (0,0) should be present
            for axis in instances(HexFrame.HexAxis)
                @test HexFrame.hex_neighbour_tiles[axis] in expanded
            end
            @test length(expanded) == 7
        end

        @testset "does not modify original set" begin
            tiles = Set([TileCoord(0, 0)])
            expanded = expand_tileset(tiles)
            @test length(tiles) == 1
            @test length(expanded) == 7
        end

        @testset "multi-step expansion" begin
            tiles = Set([TileCoord(0, 0)])
            ring2 = expand_tileset(tiles, 2)
            # 2-ring expansion of single tile: 1 + 6 + 12 = 19
            @test length(ring2) == 19
        end

        @testset "zero-step returns copy" begin
            tiles = Set([TileCoord(3, -1)])
            result = expand_tileset(tiles, 0)
            @test result == tiles
            @test result !== tiles  # different object
        end
    end

    @testset "ship docking footprints" begin
        pipe_coord = side_pipe(TileCoord(10, 0))
        pipe_tiles = Set(
            tile for vertex in (pipe_coord.v1, pipe_coord.v2)
                for (tile, _) in get_adjacent_tiles_for_node(to_nodecoord(vertex))
        )
        blueprint = ShipBlueprint(
            ship_tiles = Set([TileCoord(20, 0)]),
            pipe_behaviors = Dict(pipe_coord => MockPipeBehav()),
        )

        footprint = docking_footprint(blueprint)
        @test TileCoord(20, 0) in footprint
        @test pipe_tiles ⊆ footprint
        @test docking_footprint(Set([TileCoord(20, 0)]), (pipe_coord,)) == footprint
        @test ship_footprints_overlap(Set([TileCoord(0, 0)]), Set([TileCoord(0, 0)]))
        @test !ship_footprints_overlap(Set([TileCoord(0, 0)]), Set([TileCoord(0, 0)]), TileCoord(3, 0))

        gm = GameMap()
        set_pipe!(gm, pipe_coord, MockPipeBehav())
        add_ship!(gm, :visitor, ShipState())
        set_surface_tile!(gm, TileCoord(30, 0); ship_name = :visitor)
        set_pipe!(gm, side_pipe(TileCoord(30, 0)), MockPipeBehav(); ship_name = :visitor)

        exclusion = docking_footprint_excluding(gm, :visitor; surface_clearance = DOCKING_SURFACE_CLEARANCE)
        @test expand_tileset(Set([TileCoord(0, 0)]), DOCKING_SURFACE_CLEARANCE) ⊆ exclusion
        @test pipe_tiles ⊆ exclusion
        @test docking_footprint(gm) == docking_footprint_excluding(gm)
        @test docking_footprint(gm) == docking_footprint_including(gm, :primary, :visitor)
        @test docking_footprint_including(gm, :visitor) == docking_footprint_excluding(gm, :primary)
        @test isempty(docking_footprint_excluding(gm, :primary, :visitor))
        @test !ship_footprints_overlap(exclusion, docking_footprint_including(gm, :visitor), TileCoord(30, 0))
        @test ship_footprints_overlap(exclusion, Set([first(pipe_tiles)]))
    end

end # @testset "FlowMap"
