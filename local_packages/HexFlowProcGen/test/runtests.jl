using Test
using SquirrelNoise
using GeometryBasics
using LinearAlgebra
using Statistics

# Include the local module source (keeps tests runnable without Pkg install)
include(joinpath(@__DIR__, "..", "src", "HexFlowProcGen.jl"))
using .HexFlowProcGen

using FlowMap, HexFrame, HexComponentsAPI, HexElements, FlowEngine
include(joinpath(@__DIR__, "manoeuvre_tests.jl"))

# ===============================================================
# Mock components and pipes for testing
# ===============================================================

"Minimal mock ComponentBehavior for testing placement logic."
struct MockCompBehav <: ComponentBehavior
    value::Float64
end

HexComponentsAPI.produce_rel_elements(::MockCompBehav) = (
    RelativeElement(
        connections = RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG),
        value = 1.0,
        type = HexElements.CONST_RESISTOR
    ),
)

HexComponentsAPI.get_tunables(::MockCompBehav) = ()
HexComponentsAPI.set_tunables(b::MockCompBehav, ::NTuple{0, Real}) = b
HexComponentsAPI.render_base_elem!(::AbstractVector, ::MockCompBehav; kwargs...) = nothing

"Minimal mock PipeBehavior for testing pipe placement logic."
struct MockPipeBehav <: PipeBehavior
    conductance::Float64
end

MockPipeBehav() = MockPipeBehav(1.0)

HexComponentsAPI.get_conductance(b::MockPipeBehav) = b.conductance
HexComponentsAPI.get_pipe_tunables(::MockPipeBehav) = ()
HexComponentsAPI.set_pipe_tunables(b::MockPipeBehav, ::NTuple{0, Real}) = b
HexComponentsAPI.render_pipe_base!(::AbstractVector, ::MockPipeBehav; kwargs...) = nothing

# Register mock roll_component / roll_pipe dispatches
HexFlowProcGen.roll_component(::Val{:MockComp}, point, seed) = MockCompBehav(1.0)
HexFlowProcGen.roll_pipe(::Val{:MockPipe}, point, seed) = MockPipeBehav()

# ===============================================================
# Utility helpers
# ===============================================================

"Creates a GameMap with a single ship having the given surface tiles."
function make_test_gamemap(tiles::Set{TileCoord})
    sm = ShipMap()
    empty!(sm.ship_tiles)
    union!(sm.ship_tiles, tiles)
    return GameMap(sm)
end

"Creates a small hex blob surface for testing (7 tiles: centre + 6 neighbours)."
function make_small_surface()
    origin = TileCoord(0, 0)
    tiles = Set{TileCoord}([origin])
    for n in get_adjacent_tiles_for_tile(origin)
        push!(tiles, n)
    end
    return tiles
end


# ===============================================================
# Utility function tests
# ===============================================================

@testset "Utilities" begin

    @testset "pick_from_range" begin
        seed = UInt32(0xABCD1234)

        # Float range: result within bounds
        for pt in 1:20
            val = pick_from_range(0.0, 10.0, pt, seed)
            @test 0.0 <= val <= 10.0
        end

        # Integer range: result within bounds and is integer-typed
        for pt in 1:20
            val = pick_from_range(Int32(1), Int32(6), pt, seed)
            @test val isa Int32
            @test 1 <= val <= 6
        end

        # Deterministic: same inputs yield same outputs
        @test pick_from_range(0.0, 1.0, 42, seed) == pick_from_range(0.0, 1.0, 42, seed)

        # Different points give different results (statistically)
        vals = Set(pick_from_range(0.0, 100.0, pt, seed) for pt in 1:50)
        @test length(vals) > 1
    end

    @testset "pick_from_options" begin
        options = [:a, :b, :c, :d]
        seed = UInt32(0x12345678)

        for pt in 1:20
            val = pick_from_options(options, pt, seed)
            @test val in options
        end

        # Deterministic
        @test pick_from_options(options, 7, seed) == pick_from_options(options, 7, seed)
    end

    @testset "weighted_roll_rng" begin
        using Random
        rng = MersenneTwister(42)
        weights = [(1, 0.5), (2, 0.3), (3, 0.2)]

        counts = Dict(1 => 0, 2 => 0, 3 => 0)
        N = 10_000
        for _ in 1:N
            val = HexFlowProcGen.weighted_roll_rng(rng, weights)
            counts[val] += 1
        end

        # All items selected at least once
        @test all(c > 0 for c in values(counts))
        # Rough distribution check (10% tolerance)
        @test abs(counts[1] / N - 0.5) < 0.1
    end

    @testset "weighted_roll_noise distribution" begin
        frequency = [
            (1, 0.5),
            (2, 0.25),
            (3, 0.125),
            (4, 0.0625),
            (5, 0.03125)
        ]

        seeds = UInt32[0x12345678, 0x87654321, 0xDEADBEEF]
        N = 200_000

        counts = Dict{Int, Int}(k => 0 for (k, _) in frequency)

        for seed in seeds, idx in 1:N
            val = HexFlowProcGen.weighted_roll_noise(frequency, idx, seed)
            counts[val] += 1
        end

        total = length(seeds) * N
        tol = 0.02

        for (item, expected) in frequency
            empirical = counts[item] / total
            @test abs(empirical - expected) <= tol
        end
    end
end

# ===============================================================
# Surface generation tests
# ===============================================================

@testset "Surface generation" begin

    @testset "random_tile_walk!" begin
        tiles = Set{TileCoord}()
        start = TileCoord(0, 0)
        seed = UInt32(0xDEAD)

        random_tile_walk!(tiles, start, 10, seed)

        # Produces at least the start tile and some walked tiles
        @test !isempty(tiles)
        @test start in tiles

        # Deterministic
        tiles2 = Set{TileCoord}()
        random_tile_walk!(tiles2, start, 10, seed)
        @test tiles == tiles2

        # Appends to existing set (doesn't clear)
        extra = TileCoord(100, 100)
        tiles3 = Set{TileCoord}([extra])
        random_tile_walk!(tiles3, start, 5, seed)
        @test extra in tiles3
    end

    @testset "random_tile_walk (non-mutating)" begin
        start = TileCoord(0, 0)
        seed = UInt32(0xBEEF)

        tiles = random_tile_walk(start, 10, seed)
        @test tiles isa Set{TileCoord}
        @test !isempty(tiles)

        # Matches mutating variant
        tiles2 = Set{TileCoord}()
        random_tile_walk!(tiles2, start, 10, seed)
        @test tiles == tiles2
    end

    @testset "stacked_random_tile_walk!" begin
        tiles = Set{TileCoord}()
        start = TileCoord(0, 0)
        seed = UInt32(0xCAFE)

        stacked_random_tile_walk!(tiles, start, 5, 4, seed)
        @test !isempty(tiles)
        @test start in tiles

        # More stacks should generally produce more tiles
        tiles_few = Set{TileCoord}()
        stacked_random_tile_walk!(tiles_few, start, 5, 1, seed)
        @test length(tiles) >= length(tiles_few)

        # Deterministic
        tiles2 = Set{TileCoord}()
        stacked_random_tile_walk!(tiles2, start, 5, 4, seed)
        @test tiles == tiles2
    end
end

# ===============================================================
# Component placement tests
# ===============================================================

@testset "Component placement" begin

    @testset "clear_tiles_around_component!" begin
        origin = TileCoord(0, 0)
        tiles = Set{TileCoord}([origin])
        for n in get_adjacent_tiles_for_tile(origin)
            push!(tiles, n)
        end

        HexFlowProcGen.clear_tiles_around_component!(tiles, origin)

        # Centre and all 6 neighbours should be removed
        @test !(origin in tiles)
        for n in get_adjacent_tiles_for_tile(origin)
            @test !(n in tiles)
        end
    end

    @testset "get_all_edgecoords_of_tiles" begin
        tiles = Set{TileCoord}([TileCoord(0, 0)])
        edges = HexFlowProcGen.get_all_edgecoords_of_tiles(tiles)

        @test edges isa Set{EdgeCoord}
        @test length(edges) == 6  # single hex has 6 edges

        # Two adjacent tiles share an edge → fewer total edges than 12
        tiles2 = Set{TileCoord}([TileCoord(0, 0), TileCoord(1, -1)])
        edges2 = HexFlowProcGen.get_all_edgecoords_of_tiles(tiles2)
        @test length(edges2) < 12
    end

    @testset "roll_component dispatches correctly" begin
        comp = HexFlowProcGen.roll_component(:MockComp, 42, UInt32(0))
        @test comp isa MockCompBehav
    end

    @testset "roll_component unknown kind throws" begin
        @test_throws ErrorException HexFlowProcGen.roll_component(:NonExistent, 1, UInt32(0))
    end

    @testset "place_shipset! with RANDOM_PLACE" begin
        surface = make_small_surface()
        gm = make_test_gamemap(surface)

        shipset = ShipComponentSet("test_set", [
            CompSpawnOptions(:MockComp, [(1, 1.0)], HexFlowProcGen.RANDOM_PLACE),
        ])

        success, msg = place_shipset!(gm, shipset, UInt32(0x1234))
        @test success == true

        comps = get_all_components(gm)
        @test length(comps) >= 1
        @test all(cot.component isa MockCompBehav for (_, cot) in comps)
    end

    @testset "place_shipset! with CLUSTERED_PLACE" begin
        surface = make_small_surface()
        gm = make_test_gamemap(surface)

        shipset = ShipComponentSet("cluster_test", [
            CompSpawnOptions(:MockComp, [(2, 1.0)], HexFlowProcGen.CLUSTERED_PLACE),
        ])

        success, msg = place_shipset!(gm, shipset, UInt32(0x5678))
        @test success == true
        @test length(get_all_components(gm)) >= 1
    end
end

# ===============================================================
# Pipe placement tests
# ===============================================================

@testset "Pipe placement" begin

    @testset "roll_pipe dispatches correctly" begin
        pipe = HexFlowProcGen.roll_pipe(:MockPipe, 1, UInt32(0))
        @test pipe isa MockPipeBehav
    end

    @testset "roll_pipe unknown kind throws" begin
        @test_throws ErrorException HexFlowProcGen.roll_pipe(:NonExistent, 1, UInt32(0))
    end

    @testset "place_random_pipes!" begin
        surface = make_small_surface()
        gm = make_test_gamemap(surface)
        set_component!(gm, TileCoord(0, 0), ComponentOnTile(MockCompBehav(1.0), HexFrame.Q_POS))

        place_random_pipes!(gm, :MockPipe, UInt32(0xAAAA); pipe_density = 1.0)

        pipes = get_ship(gm, :primary).pipe_behaviors
        @test !isempty(pipes)
        @test all(p isa MockPipeBehav for (_, p) in pipes)
    end

    @testset "place_connected_pipes!" begin
        surface = make_small_surface()
        gm = make_test_gamemap(surface)
        set_component!(gm, TileCoord(0, 0), ComponentOnTile(MockCompBehav(1.0), HexFrame.Q_POS))

        place_connected_pipes!(gm, :MockPipe, UInt32(0xBBBB); pipe_density = 1.0)

        pipes = get_ship(gm, :primary).pipe_behaviors
        @test !isempty(pipes)
    end

    @testset "place_pipeset! single" begin
        surface = make_small_surface()
        gm = make_test_gamemap(surface)
        set_component!(gm, TileCoord(0, 0), ComponentOnTile(MockCompBehav(1.0), HexFrame.Q_POS))

        opts = PipeSpawnOptions(:MockPipe, HexFlowProcGen.RANDOM_PIPES, 1.0)
        place_pipeset!(gm, opts, UInt32(0xCCCC))
        @test !isempty(get_ship(gm, :primary).pipe_behaviors)
    end

    @testset "place_pipeset! vector" begin
        surface = make_small_surface()
        gm = make_test_gamemap(surface)
        set_component!(gm, TileCoord(0, 0), ComponentOnTile(MockCompBehav(1.0), HexFrame.Q_POS))

        opts_vec = [
            PipeSpawnOptions(:MockPipe, HexFlowProcGen.RANDOM_PIPES, 0.5),
            PipeSpawnOptions(:MockPipe, HexFlowProcGen.ONE_CONNECT_PIPES, 0.5),
        ]
        place_pipeset!(gm, opts_vec, UInt32(0xDDDD))
        @test !isempty(get_ship(gm, :primary).pipe_behaviors)
    end

    @testset "zero density places no pipes" begin
        surface = make_small_surface()
        gm = make_test_gamemap(surface)
        set_component!(gm, TileCoord(0, 0), ComponentOnTile(MockCompBehav(1.0), HexFrame.Q_POS))

        place_random_pipes!(gm, :MockPipe, UInt32(0xEEEE); pipe_density = 0.0)
        @test isempty(get_ship(gm, :primary).pipe_behaviors)
    end
end

# ===============================================================
# Ship generation tests
# ===============================================================

@testset "Ship generation" begin

    @testset "generate_ship (empty components/pipes)" begin
        opts = ShipGenOptions(
            name = "bare_ship",
            surface_gen_steps = 3,
            surface_gen_stacks = 5,
            component_sets = ShipComponentSet[],
            pipe_sets = PipeSpawnOptions[]
        )

        ship = generate_ship(opts, UInt32(0x1111))
        @test ship isa ShipMap
        @test !isempty(ship.ship_tiles)
        @test isempty(ship.components)
        @test isempty(ship.pipe_behaviors)
    end

    @testset "generate_ship with mock components and pipes" begin
        shipset = ShipComponentSet("mock_set", [
            CompSpawnOptions(:MockComp, [(1, 1.0)], HexFlowProcGen.RANDOM_PLACE),
        ])
        pipeset = PipeSpawnOptions(:MockPipe, HexFlowProcGen.RANDOM_PIPES, 0.5)

        opts = ShipGenOptions(
            name = "equipped_ship",
            surface_gen_steps = 4,
            surface_gen_stacks = 10,
            component_sets = [shipset],
            pipe_sets = [pipeset]
        )

        ship = generate_ship(opts, UInt32(0x2222))
        @test !isempty(ship.ship_tiles)
        @test !isempty(ship.components)
    end

    @testset "generate_ship is deterministic" begin
        opts = ShipGenOptions(
            name = "det_test",
            surface_gen_steps = 3,
            surface_gen_stacks = 5,
            component_sets = ShipComponentSet[],
            pipe_sets = PipeSpawnOptions[]
        )

        ship1 = generate_ship(opts, UInt32(0x3333))
        ship2 = generate_ship(opts, UInt32(0x3333))
        @test ship1.ship_tiles == ship2.ship_tiles
    end

    @testset "_is_surface_overlap" begin
        tiles = make_small_surface()
        gm = make_test_gamemap(tiles)

        # Overlapping ship
        overlap_ship = ShipMap()
        empty!(overlap_ship.ship_tiles)
        push!(overlap_ship.ship_tiles, TileCoord(0, 0))
        @test HexFlowProcGen._is_surface_overlap(gm, overlap_ship) == true

        # Non-overlapping ship
        remote_ship = ShipMap()
        empty!(remote_ship.ship_tiles)
        push!(remote_ship.ship_tiles, TileCoord(100, 100))
        @test HexFlowProcGen._is_surface_overlap(gm, remote_ship) == false
    end

    @testset "_rects_overlap" begin
        a = (X_POS = 5.0, X_NEG = 0.0, Y_POS = 5.0, Y_NEG = 0.0)
        b = (X_POS = 3.0, X_NEG = 1.0, Y_POS = 3.0, Y_NEG = 1.0)
        @test HexFlowProcGen._rects_overlap(a, b) == true

        c = (X_POS = 20.0, X_NEG = 10.0, Y_POS = 20.0, Y_NEG = 10.0)
        @test HexFlowProcGen._rects_overlap(a, c) == false

        # Edge-touching rects (not overlapping with strict inequality)
        d = (X_POS = 5.0, X_NEG = 0.0, Y_POS = 5.0, Y_NEG = 0.0)
        e = (X_POS = 10.0, X_NEG = 5.0, Y_POS = 10.0, Y_NEG = 5.0)
        @test HexFlowProcGen._rects_overlap(d, e) == false
    end
end

# ===============================================================
# Encounter / Depart tests
# ===============================================================

@testset "encounter_ship! and depart_ship!" begin

    @testset "encounter_ship! adds a ship with ApproachingDockStat" begin
        gm = GameMap()
        opts = ShipGenOptions(
            name = "encounter_test",
            surface_gen_steps = 2,
            surface_gen_stacks = 2,
            component_sets = ShipComponentSet[],
            pipe_sets = PipeSpawnOptions[]
        )

        before = Set(keys(gm.ships))
        encounter_ship!(gm, opts, UInt32(0x12345678), HexFrame.Q_POS)
        after = Set(keys(gm.ships))

        new_ships = collect(setdiff(after, before))
        @test length(new_ships) == 1

        status = FlowMap.get_docking_status(gm, new_ships[1])
        @test status isa FlowMap.ApproachingDockStat
        @test FlowMap.get_approach_axis(status) == HexFrame.Q_POS
    end

    @testset "encounter_ship! works with all hex axes" begin
        for axis in instances(HexFrame.HexAxis)
            gm = GameMap()
            opts = ShipGenOptions(
                name = "axis_$(axis)",
                surface_gen_steps = 2,
                surface_gen_stacks = 2,
                component_sets = ShipComponentSet[],
                pipe_sets = PipeSpawnOptions[]
            )

            encounter_ship!(gm, opts, UInt32(0xAAAA), axis)
            @test length(gm.ships) == 2  # :primary + new ship
        end
    end

    @testset "encounter -> connect -> depart end-to-end" begin
        gm = GameMap()
        opts = ShipGenOptions(
            name = "e2e_test",
            surface_gen_steps = 2,
            surface_gen_stacks = 2,
            component_sets = ShipComponentSet[],
            pipe_sets = PipeSpawnOptions[]
        )

        before = Set(keys(gm.ships))
        encounter_ship!(gm, opts, UInt32(0x12345678), HexFrame.R_POS)
        after = Set(keys(gm.ships))
        newship = only(setdiff(after, before))

        # Run docking updates until connected or timeout
        connected = false
        for _ in 1:500
            FlowMap.update_docking!(gm; ship_name = newship)
            status = FlowMap.get_docking_status(gm, newship)
            if status isa FlowMap.ConnectedDockStat
                connected = true
                break
            end
        end
        @test connected == true

        # Depart
        success, reason = depart_ship!(gm, newship)
        @test success == true

        dstatus = FlowMap.get_docking_status(gm, newship)
        @test dstatus isa FlowMap.DepartingDockStat

        # Depart axis matches approach axis
        @test FlowMap.get_approach_axis(dstatus) == HexFrame.R_POS

        # Target offset is along the approach axis direction
        expected_dir = HexFrame.hex_vert_vecs[HexFrame.R_POS]
        expected_target = HexFrame.AxialCoord(expected_dir.q * 20, expected_dir.r * 20)
        @test dstatus.motion.target_offset == expected_target
    end

    @testset "depart_ship! error cases" begin
        gm = GameMap()
        opts = ShipGenOptions(
            name = "depart_errs",
            surface_gen_steps = 2,
            surface_gen_stacks = 2,
            component_sets = ShipComponentSet[],
            pipe_sets = PipeSpawnOptions[]
        )

        # Can't depart a ship that doesn't exist
        success, _ = depart_ship!(gm, :nonexistent)
        @test success == false

        # Can't depart a ship that is still approaching
        encounter_ship!(gm, opts, UInt32(0x9999), HexFrame.Q_POS)
        newship = only(setdiff(keys(gm.ships), [:primary]))
        success2, _ = depart_ship!(gm, newship)
        @test success2 == false

        # Connect it, depart, then try double-depart
        for _ in 1:500
            FlowMap.update_docking!(gm; ship_name = newship)
            if FlowMap.get_docking_status(gm, newship) isa FlowMap.ConnectedDockStat
                break
            end
        end
        s1, _ = depart_ship!(gm, newship)
        @test s1 == true
        s2, _ = depart_ship!(gm, newship)
        @test s2 == false  # already departing
    end
end

# ===============================================================
# Off-Ship Pipes and Departure Tests
# ===============================================================

@testset "Off-ship pipes and departure" begin
    #= ---------- Geometry ----------- =#
    # Four vertex-connected vertices forming a chain from primary to secondary.
    # V1 is adjacent to primary's tile (0,0); V4 is adjacent to secondary's tile (3,-1).
    # V2 and V3 are not adjacent to either ship's surface (they float in the gap).
    ISP_V1 = to_proper(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS))   # tiles: (1,-1), (0,0), (1,0) → primary
    ISP_V2 = to_proper(VertexCoord(TileCoord(2, -1), HexFrame.Q_NEG))  # tiles: (2,-1), (1,-1), (1,0) → neither
    ISP_V3 = to_proper(VertexCoord(TileCoord(1, 0), HexFrame.Q_POS))   # tiles: (2,-1), (1,0), (2,0) → neither
    ISP_V4 = to_proper(VertexCoord(TileCoord(3, -1), HexFrame.Q_NEG))  # tiles: (3,-1), (2,-1), (2,0) → secondary

    ISP_E1 = to_proper(EdgeCoord(ISP_V1, ISP_V2))  # attached to primary via V1
    ISP_E2 = to_proper(EdgeCoord(ISP_V2, ISP_V3))  # floating (no ship surface)
    ISP_E3 = to_proper(EdgeCoord(ISP_V3, ISP_V4))  # attached to secondary via V4

    """
    Create a GameMap with primary at tile (0,0) and secondary at tile (3,-1).
    Secondary has a ConnectedDockStat so it can depart.
    """
    function make_two_ship_gamemap()
        gm = GameMap()

        # Primary ship: single tile at origin
        empty!(gm.ships[:primary].ship_tiles)
        push!(gm.ships[:primary].ship_tiles, TileCoord(0, 0))

        # Secondary ship: single tile at (3,-1), separated from primary
        sm = ShipMap()
        empty!(sm.ship_tiles)
        push!(sm.ship_tiles, TileCoord(3, -1))
        sm.docking_status = FlowMap.ConnectedDockStat(HexFrame.Q_POS)
        add_ship!(gm, :secondary, sm)

        return gm
    end

    @testset "can_place_pipe_offship — connected to ship surface" begin
        gm = make_two_ship_gamemap()
        # E1 has V1 on primary's surface → should be valid, placed on :primary
        valid, target, _ = can_place_pipe_offship(ISP_E1, gm)
        @test valid == true
        @test target == :primary
    end

    @testset "can_place_pipe_offship — connected via existing pipe" begin
        gm = make_two_ship_gamemap()
        # Place E1 on primary, then E2 should connect through E1
        set_pipe!(gm, ISP_E1, MockPipeBehav(); ship_name = :primary)
        valid, target, _ = can_place_pipe_offship(ISP_E2, gm)
        @test valid == true
        @test target == :primary
    end

    @testset "can_place_pipe_offship — neither endpoint connected" begin
        gm = make_two_ship_gamemap()
        # E2 floats in the gap with no connections
        valid, _, reason = can_place_pipe_offship(ISP_E2, gm)
        @test valid == false
        @test occursin("Neither endpoint", reason)
    end

    @testset "validate_offship_pipe_deletion — middle of chain" begin
        gm = make_two_ship_gamemap()
        # Full bridge chain stored on their respective ships
        set_pipe!(gm, ISP_E1, MockPipeBehav(); ship_name = :primary)
        set_pipe!(gm, ISP_E2, MockPipeBehav(); ship_name = :primary)
        set_pipe!(gm, ISP_E3, MockPipeBehav(); ship_name = :secondary)

        # Deleting E2 (middle) splits into E1 (reaches primary via V1) and E3 (reaches secondary
        # via V4). Both components still connect to a ship → valid deletion.
        @test validate_offship_pipe_deletion(ISP_E2, gm) == true
    end

    @testset "validate_offship_pipe_deletion — would orphan" begin
        gm = make_two_ship_gamemap()
        # E1 (on primary) → E2 (floating, stored on primary)
        set_pipe!(gm, ISP_E1, MockPipeBehav(); ship_name = :primary)
        set_pipe!(gm, ISP_E2, MockPipeBehav(); ship_name = :primary)

        # Deleting E1 would orphan E2 (E2's vertices touch no ship surface)
        @test validate_offship_pipe_deletion(ISP_E1, gm) == false
        # Deleting E2 is fine (E1 still reaches primary)
        @test validate_offship_pipe_deletion(ISP_E2, gm) == true
    end

    @testset "reassign_pipe_ownership! — chain split" begin
        gm = make_two_ship_gamemap()
        # Full chain all stored on primary
        set_pipe!(gm, ISP_E1, MockPipeBehav(); ship_name = :primary)
        set_pipe!(gm, ISP_E2, MockPipeBehav(); ship_name = :primary)
        set_pipe!(gm, ISP_E3, MockPipeBehav(2.0); ship_name = :primary)

        # Delete E2 to split the chain
        delete_pipe!(gm, ISP_E2; ship_name = :primary)
        reassign_pipe_ownership!(ISP_E2, gm)

        # E1 should stay on primary (V1 is on primary's surface)
        @test has_pipe(gm.ships[:primary], ISP_E1)
        # E3 should have moved to secondary (V4 is on secondary's surface)
        @test has_pipe(gm.ships[:secondary], ISP_E3)
        @test !has_pipe(gm.ships[:primary], ISP_E3)
        @test get_conductance(get_pipe(gm.ships[:secondary], ISP_E3)) ≈ 2.0
    end

    @testset "check_departure_pipe_connections — no off-surface pipes" begin
        gm = make_two_ship_gamemap()
        can_depart, _ = check_departure_pipe_connections(gm, :secondary)
        @test can_depart == true
    end

    @testset "check_departure_pipe_connections — pipe bridge blocks departure" begin
        gm = make_two_ship_gamemap()
        # Full chain bridging primary ↔ secondary
        set_pipe!(gm, ISP_E1, MockPipeBehav(); ship_name = :primary)
        set_pipe!(gm, ISP_E2, MockPipeBehav(); ship_name = :primary)
        set_pipe!(gm, ISP_E3, MockPipeBehav(); ship_name = :secondary)

        can_depart, reason = check_departure_pipe_connections(gm, :secondary)
        @test can_depart == false
        @test occursin("pipes still connect", reason)
    end

    @testset "check_departure_pipe_connections — pipe only on departing ship" begin
        gm = make_two_ship_gamemap()
        # E3 only touches secondary, stored on secondary
        set_pipe!(gm, ISP_E3, MockPipeBehav(); ship_name = :secondary)

        can_depart, _ = check_departure_pipe_connections(gm, :secondary)
        @test can_depart == true
    end

    @testset "depart_ship! blocked by pipe bridge" begin
        gm = make_two_ship_gamemap()
        set_pipe!(gm, ISP_E1, MockPipeBehav(); ship_name = :primary)
        set_pipe!(gm, ISP_E2, MockPipeBehav(); ship_name = :primary)
        set_pipe!(gm, ISP_E3, MockPipeBehav(); ship_name = :secondary)

        success, reason = depart_ship!(gm, :secondary)
        @test success == false
        @test occursin("pipes still connect", reason)

        # All pipes should still be present
        @test has_pipe(gm.ships[:primary], ISP_E1)
        @test has_pipe(gm.ships[:primary], ISP_E2)
        @test has_pipe(gm.ships[:secondary], ISP_E3)
    end

    @testset "depart_ship! succeeds without pipe bridge" begin
        gm = make_two_ship_gamemap()
        # Pipe only on secondary, no bridge
        set_pipe!(gm, ISP_E3, MockPipeBehav(); ship_name = :secondary)

        success, _ = depart_ship!(gm, :secondary)
        @test success == true
        @test FlowMap.get_docking_status(gm, :secondary) isa FlowMap.DepartingDockStat
        # Pipe stays with secondary
        @test has_pipe(gm.ships[:secondary], ISP_E3)
    end

    @testset "depart_ship! with no pipes works as before" begin
        gm = make_two_ship_gamemap()
        success, reason = depart_ship!(gm, :secondary)
        @test success == true
        @test FlowMap.get_docking_status(gm, :secondary) isa FlowMap.DepartingDockStat
    end

    @testset "flood_search_pipes_from_node! basic traversal" begin
        # Full chain E1→E2→E3, all vertex-connected
        all_edges = Set([ISP_E1, ISP_E2, ISP_E3])

        # Flood from V1 — should reach all 3
        start_node = to_nodecoord(ISP_V1)
        reachable = Set{EdgeCoord}()
        flood_search_pipes_from_node!(reachable, all_edges, start_node)
        @test length(reachable) == 3

        # Flood from an unconnected node — should reach nothing
        far_node = to_nodecoord(to_proper(VertexCoord(TileCoord(10, 10), HexFrame.Q_POS)))
        reachable2 = Set{EdgeCoord}()
        flood_search_pipes_from_node!(reachable2, all_edges, far_node)
        @test isempty(reachable2)
    end
end

# ===============================================================
# Encounter point system tests
# ===============================================================

"Construct a minimal SpaceMapState with the encounter system fully initialised."
function make_encounter_sm(; n_points = 10,
                             player_vel = SVector(0.0, 0.0),
                             player_pos = SVector(0.0, 0.0))
    sm = SpaceMapState(seed = UInt32(0x1234ABCD), velocity = player_vel, position = player_pos)
    config = EncounterSystemConfig(n_points = n_points)
    initialise_encounter_system!(sm, config)
    return sm, config
end

@testset "Encounter point system" begin

    @testset "predict_crossing_time" begin
        # Point moving rightward at 100 units/yr, spawned at x = -100
        ep = EncounterPoint(index=1, base_velocity=100.0,
                            position=SVector(-100.0, 0.0),
                            velocity=SVector(100.0, 0.0),
                            spawn_time=0.0)

        ct = predict_crossing_time(ep, 0.0)
        @test !isnothing(ct)
        @test ct ≈ 1.0  # 100 units at 100/yr = 1 yr

        # Already past the line
        ct_past = predict_crossing_time(ep, -200.0)
        @test isnothing(ct_past)

        # Moving leftward — already past the right line
        ep_left = EncounterPoint(index=2, base_velocity=100.0,
                                  position=SVector(0.0, 0.0),
                                  velocity=SVector(-100.0, 0.0),
                                  spawn_time=0.0)
        @test isnothing(predict_crossing_time(ep_left, 100.0))

        # Zero x-velocity — never crosses
        ep_vert = EncounterPoint(index=3, base_velocity=100.0,
                                  position=SVector(0.0, 0.0),
                                  velocity=SVector(0.0, 100.0),
                                  spawn_time=0.0)
        @test isnothing(predict_crossing_time(ep_vert, 100.0))
    end

    @testset "spawn_encounter_point! at neg_spawn line" begin
        sm, config = make_encounter_sm()
        ep = sm.encounter_points[1]
        old_iter = ep.iteration

        spawn_encounter_point!(ep, sm, config, 5.0, sm.neg_spawn_line_x)

        @test ep.iteration == old_iter + 1
        @test ep.spawn_time ≈ 5.0
        @test ep.position[1] ≈ sm.neg_spawn_line_x
        # Y within expected range
        @test abs(ep.position[2]) <= sm.viewport_half_height + config.spawn_margin
        # Velocity has a rightward component (positive X, since relative speed > 0)
        @test ep.velocity[1] > 0.0
    end

    @testset "spawn_encounter_point! at pos_spawn line (backfill)" begin
        sm, config = make_encounter_sm()
        ep = sm.encounter_points[2]

        spawn_encounter_point!(ep, sm, config, 0.0, sm.pos_spawn_line_x)

        @test ep.position[1] ≈ sm.pos_spawn_line_x
        # Still has positive relative X velocity (ship drifts toward pos_disappear)
        @test ep.velocity[1] > 0.0
    end

    @testset "spawn_encounter_point! default uses neg_spawn_line_x" begin
        sm, config = make_encounter_sm()
        ep = sm.encounter_points[3]

        spawn_encounter_point!(ep, sm, config, 0.0)

        @test ep.position[1] ≈ sm.neg_spawn_line_x
    end

    @testset "spawn_encounter_point! is deterministic for same iteration" begin
        sm, config = make_encounter_sm()
        ep1 = sm.encounter_points[1]
        ep2 = deepcopy(ep1)

        spawn_encounter_point!(ep1, sm, config, 0.0)
        spawn_encounter_point!(ep2, sm, config, 0.0)

        @test ep1.position == ep2.position
        @test ep1.velocity == ep2.velocity
        @test ep1.ship_type_seed == ep2.ship_type_seed
    end

    @testset "initialise_encounter_system! sets four boundary lines" begin
        sm, config = make_encounter_sm()

        expected_neg_spawn    = -config.viewport_half_width - config.spawn_margin
        expected_neg_disappear = expected_neg_spawn - config.recycle_margin
        expected_pos_spawn    =  config.viewport_half_width + config.spawn_margin
        expected_pos_disappear = expected_pos_spawn + config.recycle_margin

        @test sm.neg_spawn_line_x    ≈ expected_neg_spawn
        @test sm.neg_disappear_line_x ≈ expected_neg_disappear
        @test sm.pos_spawn_line_x    ≈ expected_pos_spawn
        @test sm.pos_disappear_line_x ≈ expected_pos_disappear

        # All encounter points populated
        @test length(sm.encounter_points) == 10

        # All positions within the outer boundaries
        for ep in sm.encounter_points
            @test ep.position[1] >= sm.neg_disappear_line_x
            @test ep.position[1] <= sm.pos_disappear_line_x
        end
    end

    @testset "process_encounter_events! recycles forward-crossing points" begin
        sm, config = make_encounter_sm(n_points=5)

        # Manually place one point just before pos_disappear and set velocity so it crosses quickly
        ep = sm.encounter_points[1]
        ep.position = SVector(sm.pos_disappear_line_x - 1.0, 0.0)
        ep.velocity = SVector(10.0, 0.0)
        ep.spawn_time = 0.0

        # Predict crossing and rebuild queue so this point is in it
        crossing = predict_crossing_time(ep, sm.pos_disappear_line_x)
        @test !isnothing(crossing)
        rebuild_event_queue!(sm, config)

        old_iter = ep.iteration
        process_encounter_events!(sm, config, crossing + 1.0)

        # Point should have been respawned at neg_spawn_line_x
        @test ep.iteration == old_iter + 1
        @test ep.position[1] ≈ sm.neg_spawn_line_x
    end

    @testset "rebuild_event_queue! recycles points behind neg_disappear_line_x" begin
        sm, config = make_encounter_sm(n_points=5)

        # Move one point well behind neg_disappear_line_x
        ep = sm.encounter_points[1]
        ep.position = SVector(sm.neg_disappear_line_x - 500.0, 0.0)
        ep.velocity = SVector(1.0, 0.0)    # still moving right, just far behind
        ep.spawn_time = sm.time_years

        old_iter = ep.iteration
        rebuild_event_queue!(sm, config)

        # Point should have been recycled to pos_spawn_line_x
        @test ep.iteration == old_iter + 1
        @test ep.position[1] ≈ sm.pos_spawn_line_x
    end

    @testset "rebuild_event_queue! recycles points past pos_disappear_line_x" begin
        sm, config = make_encounter_sm(n_points=5)

        # Move one point well past pos_disappear_line_x
        ep = sm.encounter_points[2]
        ep.position = SVector(sm.pos_disappear_line_x + 500.0, 0.0)
        ep.velocity = SVector(1.0, 0.0)
        ep.spawn_time = sm.time_years

        old_iter = ep.iteration
        rebuild_event_queue!(sm, config)

        # Point should have been recycled to neg_spawn_line_x
        @test ep.iteration == old_iter + 1
        @test ep.position[1] ≈ sm.neg_spawn_line_x
    end

    @testset "check_line_shift! shifts all four lines by the same amount" begin
        sm, config = make_encounter_sm()

        neg_d0 = sm.neg_disappear_line_x
        neg_s0 = sm.neg_spawn_line_x
        pos_s0 = sm.pos_spawn_line_x
        pos_d0 = sm.pos_disappear_line_x

        # Move player forward by more than one line_step_size
        shift = config.line_step_size * 2
        sm.position = SVector(sm.position[1] + shift, 0.0)
        check_line_shift!(sm, config)

        @test sm.neg_disappear_line_x ≈ neg_d0 + shift
        @test sm.neg_spawn_line_x    ≈ neg_s0 + shift
        @test sm.pos_spawn_line_x    ≈ pos_s0 + shift
        @test sm.pos_disappear_line_x ≈ pos_d0 + shift
    end

    @testset "check_line_shift! does not shift for small movement" begin
        sm, config = make_encounter_sm()

        neg_s0 = sm.neg_spawn_line_x
        sm.position = SVector(sm.position[1] + config.line_step_size * 0.1, 0.0)
        check_line_shift!(sm, config)

        @test sm.neg_spawn_line_x ≈ neg_s0
    end

    @testset "check_line_shift! handles negative player movement (moving backward)" begin
        sm, config = make_encounter_sm()

        neg_d0 = sm.neg_disappear_line_x
        neg_s0 = sm.neg_spawn_line_x
        pos_s0 = sm.pos_spawn_line_x
        pos_d0 = sm.pos_disappear_line_x

        shift = -(config.line_step_size * 2)
        sm.position = SVector(sm.position[1] + shift, 0.0)
        check_line_shift!(sm, config)

        @test sm.neg_disappear_line_x  ≈ neg_d0 + shift
        @test sm.neg_spawn_line_x     ≈ neg_s0 + shift
        @test sm.pos_spawn_line_x     ≈ pos_s0 + shift
        @test sm.pos_disappear_line_x ≈ pos_d0 + shift
    end

    @testset "density is maintained after player acceleration (backfill scenario)" begin
        # Simulate the player outrunning ships: advance position significantly
        # then confirm no points are left behind neg_disappear_line_x
        sm, config = make_encounter_sm(n_points = 50)

        # Move player forward enormously
        sm.position = SVector(5000.0, 0.0)
        check_line_shift!(sm, config)

        current_time = sm.time_years
        for ep in sm.encounter_points
            current_x = get_encounter_position(ep, current_time)[1]
            @test current_x >= sm.neg_disappear_line_x - 1.0  # 1-unit tolerance for float rounding
            @test current_x <= sm.pos_disappear_line_x + 1.0
        end
    end

    @testset "step_space_map_time! advances time and updates position" begin
        sm, config = make_encounter_sm()
        sm.velocity = SVector(100.0, 0.0)
        sm.target_time_years = 1.0

        advanced = step_space_map_time!(sm; config=config, max_step=1.0)
        @test advanced == true
        @test sm.time_years ≈ 1.0
        @test sm.position[1] ≈ 100.0

        # At target — no further advance
        sm.target_time_years = 1.0
        advanced2 = step_space_map_time!(sm; config=config, max_step=1.0)
        @test advanced2 == false
    end
end
