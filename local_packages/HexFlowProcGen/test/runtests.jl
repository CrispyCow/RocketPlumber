#=
Scope: Test suite for HexFlowProcGen procedural generation and encounter balance.
Formatter: Runic
=#

using Test
using SquirrelNoise
using GeometryBasics
using LinearAlgebra
using Statistics
using HexFluids

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

"Minimal ComponentBehavior with explicit dry and wet masses for delta-V tests."
struct MockMassCompBehav <: ComponentBehavior
    dry_mass::Float64
    cold_gas_mass::Float64
    monoprop_mass::Float64
    fuel_mass::Float64
    oxid_mass::Float64
    unmodelled_mass::Float64
end

HexComponentsAPI.produce_rel_elements(::MockMassCompBehav) = ()
HexComponentsAPI.get_tunables(::MockMassCompBehav) = ()
HexComponentsAPI.set_tunables(b::MockMassCompBehav, ::NTuple{0, Real}) = b
HexComponentsAPI.render_base_elem!(::AbstractVector, ::MockMassCompBehav; kwargs...) = nothing
HexComponentsAPI.get_component_dry_mass(b::MockMassCompBehav; kwargs...) = b.dry_mass

function HexComponentsAPI.get_component_wet_mass(
        b::MockMassCompBehav;
        fluid::Union{HexFluids.FluidType, Nothing} = nothing,
        kwargs...
    )::Float64
    isnothing(fluid) && return b.cold_gas_mass + b.monoprop_mass + b.fuel_mass + b.oxid_mass + b.unmodelled_mass
    fluid == HexFluids.COLD_GAS && return b.cold_gas_mass
    fluid == HexFluids.MONOPROP_LIQUID && return b.monoprop_mass
    fluid == HexFluids.FUEL_LIQUID && return b.fuel_mass
    fluid == HexFluids.OXIDISER_LIQUID && return b.oxid_mass
    fluid == HexFluids.BIPROP_EXHAUST && return b.unmodelled_mass
    return 0.0
end

"Minimal mock PipeBehavior for testing pipe placement logic."
struct MockPipeBehav <: PipeBehavior
    conductance::Float64
end

MockPipeBehav() = MockPipeBehav(1.0)

HexComponentsAPI.get_conductance(b::MockPipeBehav) = b.conductance
HexComponentsAPI.get_pipe_tunables(::MockPipeBehav) = ()
HexComponentsAPI.set_pipe_tunables(b::MockPipeBehav, ::NTuple{0, Real}) = b
HexComponentsAPI.render_pipe_base!(::AbstractVector, ::MockPipeBehav; kwargs...) = nothing
HexComponentsAPI.get_pipe_click_radius(::MockPipeBehav) = 0.1

# Register mock roll_component / roll_pipe dispatches
HexFlowProcGen.roll_component(::Val{:MockComp}, point, seed) = MockCompBehav(1.0)
HexFlowProcGen.roll_pipe(::Val{:MockPipe}, point, seed) = MockPipeBehav()

# ===============================================================
# Utility helpers
# ===============================================================

"Creates a GameMap with a single ship having the given surface tiles."
function make_test_gamemap(tiles::Set{TileCoord})
    gm = GameMap()
    set_surface_tile!(gm, tiles; ship_name = :primary)
    return gm
end

"Creates a GameMap with a single primary surface tile at the origin."
make_origin_gamemap() = make_test_gamemap(Set([TileCoord(0, 0)]))

"Creates a small hex blob surface for testing (7 tiles: centre + 6 neighbours)."
function make_small_surface()
    origin = TileCoord(0, 0)
    tiles = Set{TileCoord}([origin])
    for n in get_adjacent_tiles_for_tile(origin)
        push!(tiles, n)
    end
    return tiles
end

"A wider surface for pipe-placement tests — the mutual-connection filter needs room for isolated edges."
function make_pipe_test_surface()
    tiles = Set{TileCoord}()
    for q in -3:3
        push!(tiles, TileCoord(q, 0))
        push!(tiles, TileCoord(q, 1))
    end
    return tiles
end

"Creates a bare ShipBlueprint with a small random-walk surface for encounter testing."
function make_bare_blueprint(seed::UInt32)
    bp = ShipBlueprint()
    stacked_random_tile_walk!(bp.ship_tiles, TileCoord(0, 0), 2, 2, seed)
    return bp
end

"Create a side-span pipe on `tile` for docking-clearance tests."
function make_test_pipe_coord(tile::TileCoord = TileCoord(0, 0))
    return PipeCoord(VertexCoord(tile, HexFrame.Q_POS), VertexCoord(tile, HexFrame.R_NEG))
end

"Collect endpoint nodes from an iterable of pipe coordinates."
function collect_pipe_nodes(pipe_coords)
    nodes = Set{NodeCoord}()
    for pipe_coord in pipe_coords
        push!(nodes, to_nodecoord(pipe_coord.v1), to_nodecoord(pipe_coord.v2))
    end
    return nodes
end

"Return the hex-grid distance between two tile coordinates."
function tile_distance(a::TileCoord, b::TileCoord)::Int
    dq = Int(a.q) - Int(b.q)
    dr = Int(a.r) - Int(b.r)
    return max(abs(dq), abs(dr), abs(dq + dr))
end

"Add a mock mass-reporting component to `gm` for delta-V estimator tests."
function add_mock_mass_component!(
        gm::GameMap,
        coord::TileCoord;
        dry_mass::Float64 = 0.0,
        cold_gas_mass::Float64 = 0.0,
        monoprop_mass::Float64 = 0.0,
        fuel_mass::Float64 = 0.0,
        oxid_mass::Float64 = 0.0,
        unmodelled_mass::Float64 = 0.0,
    )
    set_component!(
        gm,
        coord,
        PlacedComponent(
            MockMassCompBehav(dry_mass, cold_gas_mass, monoprop_mass, fuel_mass, oxid_mass, unmodelled_mass),
            HexFrame.Q_POS,
            :primary,
        ),
    )
    return gm
end

"Split stored bipropellant into matched and leftover stages for estimator tests."
function expected_biprop_stage_masses(
        fuel_mass::Float64,
        oxid_mass::Float64;
        optimal_vol_ratio::Float64 = 2.5,
    )::Tuple{Float64, Float64}
    total_biprop_mass = fuel_mass + oxid_mass
    total_biprop_mass <= 0.0 && return (0.0, 0.0)
    fuel_mass <= 0.0 && return (0.0, oxid_mass)
    oxid_mass <= 0.0 && return (0.0, fuel_mass)

    fuel_density = something(HexFluids.lookup_fluid_density(HexFluids.FUEL_LIQUID), 0.0)
    oxid_density = something(HexFluids.lookup_fluid_density(HexFluids.OXIDISER_LIQUID), 0.0)
    (fuel_density <= 0.0 || oxid_density <= 0.0) && return (0.0, total_biprop_mass)

    mass_ratio = optimal_vol_ratio * oxid_density / fuel_density
    mass_ratio <= 0.0 && return (0.0, total_biprop_mass)

    matched_fuel_mass = min(fuel_mass, oxid_mass / mass_ratio)
    matched_total_mass = matched_fuel_mass * (1.0 + mass_ratio)
    leftover_mass = max(total_biprop_mass - matched_total_mass, 0.0)
    return (matched_total_mass, leftover_mass)
end

"Apply the estimator's staged Tsiolkovsky calculation to an explicit stage list."
function expected_staged_delta_v(initial_mass::Float64, fuels::Vector{Tuple{Float64, Float64}})::Float64
    remaining_mass = initial_mass
    total_dv = 0.0

    for (fuel_mass, ve) in sort(copy(fuels); by = last, rev = true)
        m_final = remaining_mass - fuel_mass
        m_final <= 0.0 && continue

        total_dv += ve * log(remaining_mass / m_final)
        remaining_mass = m_final
    end

    return total_dv
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
            (5, 0.03125),
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
# Delta-V estimator tests
# ===============================================================

@testset "Delta-V estimation" begin

    @testset "returns zero without usable propellant" begin
        gm = make_origin_gamemap()
        add_mock_mass_component!(gm, TileCoord(0, 0); dry_mass = 10.0, unmodelled_mass = 40.0)

        @test estimate_min_delta_v(gm) == 0.0
    end

    @testset "cold gas only matches staged Tsiolkovsky" begin
        gm = make_origin_gamemap()
        add_mock_mass_component!(gm, TileCoord(0, 0); dry_mass = 10.0, cold_gas_mass = 40.0)

        initial_mass = get_dry_mass(gm) + get_wet_mass(gm)
        cold_gas_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS), 0.0)
        expected = expected_staged_delta_v(initial_mass, [(40.0, cold_gas_ve)])

        @test estimate_min_delta_v(gm) ≈ expected
    end

    @testset "monopropellant only matches staged Tsiolkovsky" begin
        gm = make_origin_gamemap()
        add_mock_mass_component!(gm, TileCoord(0, 0); dry_mass = 10.0, monoprop_mass = 50.0)

        initial_mass = get_dry_mass(gm) + get_wet_mass(gm)
        monoprop_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.MONOPROP_GAS), 0.0)
        expected = expected_staged_delta_v(initial_mass, [(50.0, monoprop_ve)])

        @test estimate_min_delta_v(gm) ≈ expected
    end

    @testset "balanced bipropellant burns the full matched mass" begin
        gm = make_origin_gamemap()
        add_mock_mass_component!(gm, TileCoord(0, 0); dry_mass = 10.0, fuel_mass = 100.0, oxid_mass = 250.0)

        initial_mass = get_dry_mass(gm) + get_wet_mass(gm)
        hot_mass, cold_mass = expected_biprop_stage_masses(100.0, 250.0)
        hot_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.BIPROP_EXHAUST, 2000.0), 0.0)
        expected = expected_staged_delta_v(initial_mass, [(hot_mass, hot_ve)])

        @test hot_mass ≈ 350.0
        @test cold_mass == 0.0
        @test estimate_min_delta_v(gm) ≈ expected
    end

    @testset "fuel-limited bipropellant adds a low-temperature oxidiser stage" begin
        gm = make_origin_gamemap()
        add_mock_mass_component!(gm, TileCoord(0, 0); dry_mass = 10.0, fuel_mass = 100.0, oxid_mass = 400.0)

        initial_mass = get_dry_mass(gm) + get_wet_mass(gm)
        hot_mass, cold_mass = expected_biprop_stage_masses(100.0, 400.0)
        hot_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.BIPROP_EXHAUST, 2000.0), 0.0)
        cold_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.BIPROP_EXHAUST, 50.0), 0.0)
        expected = expected_staged_delta_v(initial_mass, [(hot_mass, hot_ve), (cold_mass, cold_ve)])
        stranded = expected_staged_delta_v(initial_mass, [(hot_mass, hot_ve)])

        @test hot_mass ≈ 350.0
        @test cold_mass ≈ 150.0
        @test estimate_min_delta_v(gm) ≈ expected
        @test estimate_min_delta_v(gm) > stranded
    end

    @testset "oxidiser-limited bipropellant adds a low-temperature fuel stage" begin
        gm = make_origin_gamemap()
        add_mock_mass_component!(gm, TileCoord(0, 0); dry_mass = 10.0, fuel_mass = 100.0, oxid_mass = 100.0)

        initial_mass = get_dry_mass(gm) + get_wet_mass(gm)
        hot_mass, cold_mass = expected_biprop_stage_masses(100.0, 100.0)
        hot_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.BIPROP_EXHAUST, 2000.0), 0.0)
        cold_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.BIPROP_EXHAUST, 50.0), 0.0)
        expected = expected_staged_delta_v(initial_mass, [(hot_mass, hot_ve), (cold_mass, cold_ve)])

        @test hot_mass ≈ 140.0
        @test cold_mass ≈ 60.0
        @test estimate_min_delta_v(gm) ≈ expected
    end

    @testset "single-reagent bipropellant still contributes a low-temperature stage" begin
        gm = make_origin_gamemap()
        add_mock_mass_component!(gm, TileCoord(0, 0); dry_mass = 10.0, fuel_mass = 80.0)

        initial_mass = get_dry_mass(gm) + get_wet_mass(gm)
        hot_mass, cold_mass = expected_biprop_stage_masses(80.0, 0.0)
        cold_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.BIPROP_EXHAUST, 50.0), 0.0)
        expected = expected_staged_delta_v(initial_mass, [(cold_mass, cold_ve)])

        @test hot_mass == 0.0
        @test cold_mass ≈ 80.0
        @test estimate_min_delta_v(gm) ≈ expected
    end

    @testset "unmodelled stored fluid still counts as carried mass" begin
        baseline_gm = make_origin_gamemap()
        add_mock_mass_component!(baseline_gm, TileCoord(0, 0); dry_mass = 10.0, cold_gas_mass = 40.0)

        cargo_gm = make_origin_gamemap()
        add_mock_mass_component!(cargo_gm, TileCoord(0, 0); dry_mass = 10.0, cold_gas_mass = 40.0, unmodelled_mass = 30.0)

        initial_mass = get_dry_mass(cargo_gm) + get_wet_mass(cargo_gm)
        cold_gas_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS), 0.0)
        cargo_expected = expected_staged_delta_v(initial_mass, [(40.0, cold_gas_ve)])

        @test estimate_min_delta_v(cargo_gm) ≈ cargo_expected
        @test estimate_min_delta_v(cargo_gm) < estimate_min_delta_v(baseline_gm)
    end

    @testset "mixed propellants burn in decreasing exhaust-velocity order" begin
        gm = make_origin_gamemap()
        add_mock_mass_component!(
            gm,
            TileCoord(0, 0);
            dry_mass = 10.0,
            cold_gas_mass = 40.0,
            monoprop_mass = 60.0,
            fuel_mass = 20.0,
            oxid_mass = 70.0,
            unmodelled_mass = 15.0,
        )

        cold_gas_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS), 0.0)
        monoprop_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.MONOPROP_GAS), 0.0)
        biprop_hot_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.BIPROP_EXHAUST, 2000.0), 0.0)
        biprop_cold_ve = something(HexFluids.lookup_fluid_exhaust_velocity(HexFluids.BIPROP_EXHAUST, 50.0), 0.0)
        biprop_hot_mass, biprop_cold_mass = expected_biprop_stage_masses(20.0, 70.0)
        initial_mass = get_dry_mass(gm) + get_wet_mass(gm)
        fuels = [(40.0, cold_gas_ve), (60.0, monoprop_ve), (biprop_hot_mass, biprop_hot_ve), (biprop_cold_mass, biprop_cold_ve)]

        expected = expected_staged_delta_v(initial_mass, fuels)
        wrong_order = begin
            remaining_mass = initial_mass
            total_dv = 0.0

            for (fuel_mass, ve) in sort(copy(fuels); by = last, rev = false)
                m_final = remaining_mass - fuel_mass
                m_final <= 0.0 && continue

                total_dv += ve * log(remaining_mass / m_final)
                remaining_mass = m_final
            end

            total_dv
        end

        @test estimate_min_delta_v(gm) ≈ expected
        @test abs(expected - wrong_order) > 1.0e-6
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

    @testset "scale_spawn_count" begin
        @test HexFlowProcGen.scale_spawn_count(2, HexFlowProcGen.CLUSTERED_PLACE, 1.0) == 2
        @test HexFlowProcGen.scale_spawn_count(0, HexFlowProcGen.CLUSTERED_PLACE, 100.0) == 0
        @test HexFlowProcGen.scale_spawn_count(2, HexFlowProcGen.RANDOM_PLACE, 3.0) == 2
        @test HexFlowProcGen.scale_spawn_count(2, HexFlowProcGen.CLUSTERED_PLACE, 1.25) == 3
        @test HexFlowProcGen.scale_spawn_count(1, HexFlowProcGen.CLUSTERED_PLACE, 0.01) == 1

        for invalid_scale in (0.0, -1.0, NaN, Inf)
            @test_throws ArgumentError HexFlowProcGen.scale_spawn_count(
                1, HexFlowProcGen.CLUSTERED_PLACE, invalid_scale
            )
        end
        @test_throws ArgumentError HexFlowProcGen.scale_spawn_count(1, HexFlowProcGen.CLUSTERED_PLACE, 1.0e300)
        @test_throws ArgumentError HexFlowProcGen.scale_spawn_count(
            typemax(Int), HexFlowProcGen.CLUSTERED_PLACE, 2.0
        )
    end

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

    @testset "get_all_pipes_of_tiles" begin
        tiles = Set{TileCoord}([TileCoord(0, 0)])
        pipes = HexFlowProcGen.get_all_pipes_of_tiles(tiles)

        @test pipes isa Set{PipeCoord}
        @test length(pipes) == 15
        @test count(is_side_span, pipes) == 6
        @test count(pipe -> !is_side_span(pipe), pipes) == 9

        # Two adjacent tiles share a side span, so the total is less than 30.
        tiles2 = Set{TileCoord}([TileCoord(0, 0), TileCoord(1, -1)])
        pipes2 = HexFlowProcGen.get_all_pipes_of_tiles(tiles2)
        @test pipes2 isa Set{PipeCoord}
        @test length(pipes2) < 30
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

        shipset = ShipComponentSet(
            "test_set", [
                CompSpawnOptions(:MockComp, [(1, 1.0)], HexFlowProcGen.RANDOM_PLACE),
            ]
        )

        success, msg = place_shipset!(gm, shipset, UInt32(0x1234))
        @test success == true

        comps = get_components(gm)
        @test length(comps) >= 1
        @test all(placed_component.component isa MockCompBehav for (_, placed_component) in comps)
    end

    @testset "place_shipset! with CLUSTERED_PLACE" begin
        surface = make_small_surface()
        gm = make_test_gamemap(surface)

        shipset = ShipComponentSet(
            "cluster_test", [
                CompSpawnOptions(:MockComp, [(2, 1.0)], HexFlowProcGen.CLUSTERED_PLACE),
            ]
        )

        success, msg = place_shipset!(gm, shipset, UInt32(0x5678))
        @test success == true
        @test length(get_components(gm)) >= 1
    end

    @testset "place_shipset! scales only clustered counts" begin
        surface = Set{TileCoord}()
        stacked_random_tile_walk!(surface, TileCoord(0, 0), 12, 12, UInt32(0xCAFE))
        clustered_set = ShipComponentSet(
            "scaled_cluster", [
                CompSpawnOptions(:MockComp, [(2, 1.0)], HexFlowProcGen.CLUSTERED_PLACE),
            ]
        )
        random_set = ShipComponentSet(
            "unscaled_random", [
                CompSpawnOptions(:MockComp, [(2, 1.0)], HexFlowProcGen.RANDOM_PLACE),
            ]
        )

        clustered_map = make_test_gamemap(surface)
        success, _ = place_shipset!(
            clustered_map, clustered_set, UInt32(0xCAFE); clustered_count_scale = 2.0
        )
        @test success
        @test length(get_components(clustered_map)) == 4

        random_map = make_test_gamemap(surface)
        success, _ = place_shipset!(
            random_map, random_set, UInt32(0xCAFE); clustered_count_scale = 2.0
        )
        @test success
        @test length(get_components(random_map)) == 2
    end

    @testset "separate clustered placements retain the exclusion gap" begin
        surface = Set{TileCoord}()
        stacked_random_tile_walk!(surface, TileCoord(0, 0), 12, 12, UInt32(0xBEEF))
        shipset = ShipComponentSet(
            "separated_clusters", [
                CompSpawnOptions(:MockComp, [(2, 1.0)], HexFlowProcGen.CLUSTERED_PLACE),
            ]
        )
        gm = make_test_gamemap(surface)

        place_shipset!(gm, shipset, UInt32(0x1000))
        first_cluster = Set(keys(get_components(gm)))
        place_shipset!(gm, shipset, UInt32(0x2000))
        second_cluster = setdiff(Set(keys(get_components(gm))), first_cluster)

        @test !isempty(second_cluster)
        @test all(
            neighbour ∉ first_cluster
                for coord in second_cluster for neighbour in get_adjacent_tiles_for_tile(coord)
        )
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

    @testset "noise_filter_pipes! applies non-side pipe probability factor" begin
        seed = UInt32(0xFACE)
        pipes = Set(get_pipe_segments(TileCoord(0, 0)))
        filtered = HexFlowProcGen.noise_filter_pipes!(copy(pipes), :MockPipe, seed; pipe_density = 1.0)

        expected = Set(
            filter(pipes) do pipe
                effective_density = is_side_span(pipe) ? 1.0 : HexFlowProcGen.NON_SIDE_PIPE_PROBABILITY_FACTOR
                get_noise_zero_to_one(HexFlowProcGen.hash_pipe(pipe, :MockPipe), seed) <= effective_density
            end
        )

        @test filtered == expected
        @test all(pipe -> pipe in filtered, filter(is_side_span, collect(pipes)))

        empty_filtered = HexFlowProcGen.noise_filter_pipes!(copy(pipes), :MockPipe, seed; pipe_density = 0.0)
        @test isempty(empty_filtered)
    end

    @testset "place_random_pipes!" begin
        surface = make_pipe_test_surface()
        gm = make_test_gamemap(surface)
        set_component!(gm, TileCoord(0, 0), PlacedComponent(MockCompBehav(1.0), HexFrame.Q_POS, :primary))

        place_random_pipes!(gm, :MockPipe, UInt32(0xAAAA); pipe_density = 0.3)

        pipes = gm.pipe_behaviors
        @test !isempty(pipes)
        @test all(p.pipe isa MockPipeBehav for (_, p) in pipes)

        # Verify no two placed pipes share a vertex
        placed_edges = collect(keys(pipes))
        for i in eachindex(placed_edges), j in (i + 1):length(placed_edges)
            a, b = placed_edges[i], placed_edges[j]
            @test a.v1 != b.v1 && a.v1 != b.v2 && a.v2 != b.v1 && a.v2 != b.v2
        end
    end

    @testset "place_connected_pipes!" begin
        surface = make_pipe_test_surface()
        gm = make_test_gamemap(surface)
        set_component!(gm, TileCoord(-2, 0), PlacedComponent(MockCompBehav(1.0), HexFrame.Q_POS, :primary))
        set_component!(gm, TileCoord(2, 0), PlacedComponent(MockCompBehav(1.0), HexFrame.Q_POS, :primary))

        place_connected_pipes!(gm, :MockPipe, UInt32(0xBBBB); pipe_density = 0.2)

        # Verify the mutual-connection invariant: no two placed pipes share a vertex
        pipes = gm.pipe_behaviors
        placed_edges = collect(keys(pipes))
        for i in eachindex(placed_edges), j in (i + 1):length(placed_edges)
            a, b = placed_edges[i], placed_edges[j]
            @test a.v1 != b.v1 && a.v1 != b.v2 && a.v2 != b.v1 && a.v2 != b.v2
        end
    end

    @testset "place_pipeset! single" begin
        surface = make_pipe_test_surface()
        gm = make_test_gamemap(surface)
        set_component!(gm, TileCoord(0, 0), PlacedComponent(MockCompBehav(1.0), HexFrame.Q_POS, :primary))

        opts = PipeSpawnOptions(:MockPipe, HexFlowProcGen.RANDOM_PIPES, 0.3)
        place_pipeset!(gm, opts, UInt32(0xCCCC))
        @test !isempty(gm.pipe_behaviors)
    end

    @testset "place_pipeset! vector" begin
        surface = make_small_surface()
        gm = make_test_gamemap(surface)
        set_component!(gm, TileCoord(0, 0), PlacedComponent(MockCompBehav(1.0), HexFrame.Q_POS, :primary))

        opts_vec = [
            PipeSpawnOptions(:MockPipe, HexFlowProcGen.RANDOM_PIPES, 0.5),
            PipeSpawnOptions(:MockPipe, HexFlowProcGen.ONE_CONNECT_PIPES, 0.5),
        ]
        place_pipeset!(gm, opts_vec, UInt32(0xDDDD))
        @test !isempty(gm.pipe_behaviors)
    end

    @testset "zero density places no pipes" begin
        surface = make_small_surface()
        gm = make_test_gamemap(surface)
        set_component!(gm, TileCoord(0, 0), PlacedComponent(MockCompBehav(1.0), HexFrame.Q_POS, :primary))

        place_random_pipes!(gm, :MockPipe, UInt32(0xEEEE); pipe_density = 0.0)
        @test isempty(gm.pipe_behaviors)
    end

    @testset "non-side pipes do not cross occupied component tiles" begin
        surface = make_small_surface()
        component_tile = TileCoord(0, 0)
        gm = make_test_gamemap(surface)
        set_component!(gm, component_tile, PlacedComponent(MockCompBehav(1.0), HexFrame.Q_POS, :primary))

        place_random_pipes!(gm, :MockPipe, UInt32(0xFFFF); pipe_density = 1.0)

        @test all(pipe -> get_tile_containing_pipe(pipe) != component_tile, keys(gm.pipe_behaviors))
    end
end

# ===============================================================
# Encounter generation tests
# ===============================================================

# Module-scope test data used by both inline testsets and helper functions
const mock_pipe_opts = [PipeSpawnOptions(:MockPipe, HexFlowProcGen.RANDOM_PIPES, 0.5)]

@testset "Encounter generation" begin

    mock_shipset = ShipComponentSet(
        "mock_set", [
            CompSpawnOptions(:MockComp, [(1, 1.0)], HexFlowProcGen.RANDOM_PLACE),
        ]
    )

    # Mock encounter class config for testing
    mock_class_config = EncounterClassConfig(
        NoScaling(1.0),                        # class_weight
        HullSizeConfig(
            LinearScaling(3.0, 0.0),           # Always 3 steps
            LinearScaling(5.0, 0.0),           # Always 5 stacks
        ),
        LinearScaling(2.0, 0.0),               # target_components: always 2
        FluidTaggedEncounterComponents(
            Dict{FluidType, FuelTagConfig}(
                HexFluids.COLD_GAS => FuelTagConfig(
                    NoScaling(1.0),
                    [WeightedComponentSet(mock_shipset, NoScaling(1.0))]
                ),
                HexFluids.MONOPROP_LIQUID => FuelTagConfig(
                    NoScaling(1.0),
                    [WeightedComponentSet(mock_shipset, NoScaling(1.0))]
                ),
            )
        ),
        mock_pipe_opts,
        NoScaling(1.0),
    )

    @testset "ScalingRule" begin
        @testset "NoScaling" begin
            ns = NoScaling(5.0)
            @test evaluate_scaling(ns, 0.0) == 5.0
            @test evaluate_scaling(ns, 100.0) == 5.0
        end

        @testset "LinearScaling" begin
            ls = LinearScaling(1.0, 2.0)
            @test evaluate_scaling(ls, 0.0) == 1.0
            @test evaluate_scaling(ls, 1.0) == 3.0
            @test evaluate_scaling(ls, 5.0) == 11.0
        end

        @testset "GatedLinearScaling" begin
            gls = GatedLinearScaling(0.25, 0.4, 2.0)
            @test evaluate_scaling(gls, 0.0) == 0.0
            @test evaluate_scaling(gls, 1.9) == 0.0
            @test evaluate_scaling(gls, 2.0) == 0.25
            @test evaluate_scaling(gls, 3.0) ≈ 0.65
            @test evaluate_scaling(gls, 7.0) ≈ 2.25
        end
    end

    @testset "clustered spawn-count scale" begin
        six_argument_config = EncounterClassConfig(
            mock_class_config.class_weight,
            mock_class_config.hull_size,
            mock_class_config.target_components,
            mock_class_config.component_source,
            mock_class_config.pipe_options,
            LinearScaling(0.5, 0.25),
        )
        @test six_argument_config.clustered_spawn_count_scale == LinearScaling(0.5, 0.25)
        @test HexFlowProcGen.compute_clustered_spawn_count_scale(
            six_argument_config, 4.0
        ) == 1.5

        for invalid_rule in (NoScaling(0.0), NoScaling(-1.0), NoScaling(NaN), NoScaling(Inf))
            invalid_config = EncounterClassConfig(
                mock_class_config.class_weight,
                mock_class_config.hull_size,
                mock_class_config.target_components,
                mock_class_config.component_source,
                mock_class_config.pipe_options,
                invalid_rule,
            )
            @test_throws ArgumentError HexFlowProcGen.compute_clustered_spawn_count_scale(
                invalid_config, 1.0
            )
        end
    end

    @testset "Encounter class selection" begin
        configs = Dict{EncounterClass, EncounterClassConfig}(
            ENCOUNTER_SHIP => mock_class_config,
        )
        @test select_encounter_class(configs, 1.0, 1, UInt32(42)) == ENCOUNTER_SHIP
    end

    @testset "Fuel tag selection" begin
        fuel_configs = Dict{FluidType, FuelTagConfig}(
            HexFluids.COLD_GAS => FuelTagConfig(
                NoScaling(1.0),
                [WeightedComponentSet(mock_shipset, NoScaling(1.0))]
            ),
        )
        @test select_fuel_tag(fuel_configs, 1.0, 1, UInt32(42)) == HexFluids.COLD_GAS
    end

    @testset "Encounter component sources" begin
        direct_source = DirectEncounterComponents(WeightedComponentSet[])
        fluid_source = FluidTaggedEncounterComponents(
            Dict{FluidType, FuelTagConfig}(
                HexFluids.COLD_GAS => FuelTagConfig(NoScaling(1.0), WeightedComponentSet[]),
            )
        )

        @test direct_source.component_pool == WeightedComponentSet[]
        @test fluid_source.fuel_configs[HexFluids.COLD_GAS].component_pool == WeightedComponentSet[]
        @test_throws ArgumentError FluidTaggedEncounterComponents(Dict{FluidType, FuelTagConfig}())

        @test select_encounter_fuel_tag(direct_source, 1.0, 1, UInt32(42)) === nothing
        @test select_encounter_fuel_tag(fluid_source, 1.0, 1, UInt32(42)) == HexFluids.COLD_GAS
        @test_throws ArgumentError select_encounter_fuel_tag(
            FluidTaggedEncounterComponents(
                Dict{FluidType, FuelTagConfig}(
                    HexFluids.COLD_GAS => FuelTagConfig(GatedLinearScaling(0.0, 0.0, 2.0), WeightedComponentSet[]),
                )
            ),
            1.0,
            1,
            UInt32(42),
        )
    end

    @testset "Encounter component pool resolution" begin
        direct_pool = WeightedComponentSet[]
        direct_source = DirectEncounterComponents(direct_pool)
        fluid_pool = [WeightedComponentSet(mock_shipset, NoScaling(1.0))]
        fluid_source = FluidTaggedEncounterComponents(
            Dict{FluidType, FuelTagConfig}(
                HexFluids.COLD_GAS => FuelTagConfig(NoScaling(1.0), fluid_pool),
            )
        )

        @test resolve_encounter_component_pool(direct_source, nothing) === direct_pool
        @test resolve_encounter_component_pool(fluid_source, HexFluids.COLD_GAS) === fluid_pool
        @test_throws ArgumentError resolve_encounter_component_pool(direct_source, HexFluids.COLD_GAS)
        @test_throws ArgumentError resolve_encounter_component_pool(fluid_source, nothing)
        @test_throws ArgumentError resolve_encounter_component_pool(fluid_source, HexFluids.MONOPROP_LIQUID)
    end

    @testset "Fuel tag selection honours richness gates" begin
        gated_fuel_configs = Dict{FluidType, FuelTagConfig}(
            HexFluids.COLD_GAS => FuelTagConfig(
                NoScaling(1.0),
                [WeightedComponentSet(mock_shipset, NoScaling(1.0))]
            ),
            HexFluids.MONOPROP_LIQUID => FuelTagConfig(
                GatedLinearScaling(0.25, 0.4, 2.5),
                [WeightedComponentSet(mock_shipset, NoScaling(1.0))]
            ),
            HexFluids.FUEL_LIQUID => FuelTagConfig(
                GatedLinearScaling(0.25, 0.4, 4.0),
                [WeightedComponentSet(mock_shipset, NoScaling(1.0))]
            ),
            HexFluids.OXIDISER_LIQUID => FuelTagConfig(
                GatedLinearScaling(0.25, 0.4, 4.0),
                [WeightedComponentSet(mock_shipset, NoScaling(1.0))]
            ),
        )

        sample_points = 1:4096
        seed = UInt32(0xB1F00001)

        @test any(point -> select_fuel_tag(gated_fuel_configs, 2.5, point, seed) == HexFluids.MONOPROP_LIQUID, sample_points)
        @test !any(point -> select_fuel_tag(gated_fuel_configs, 3.9, point, seed) == HexFluids.FUEL_LIQUID, sample_points)
        @test !any(point -> select_fuel_tag(gated_fuel_configs, 3.9, point, seed) == HexFluids.OXIDISER_LIQUID, sample_points)
        @test any(point -> select_fuel_tag(gated_fuel_configs, 4.0, point, seed) == HexFluids.FUEL_LIQUID, sample_points)
        @test any(point -> select_fuel_tag(gated_fuel_configs, 4.0, point, seed) == HexFluids.OXIDISER_LIQUID, sample_points)
    end

    @testset "Encounter name generation" begin
        name = generate_encounter_name(UInt32(12345), ENCOUNTER_SHIP)
        @test !isempty(name)
        @test contains(name, "-")
        @test generate_encounter_name(UInt32(12345), ENCOUNTER_SHIP) == name
        scrap_name = generate_encounter_name(UInt32(12345), ENCOUNTER_SCRAP)
        @test !isempty(scrap_name)
    end

    @testset "generate_encounter places surface and components" begin
        blueprint = generate_encounter(
            ENCOUNTER_SHIP, HexFluids.COLD_GAS, 2.0,
            UInt32(0x2222), mock_class_config
        )

        @test blueprint isa ShipBlueprint
        @test !isempty(blueprint.ship_tiles)
        @test !isempty(blueprint.components)
    end

    @testset "generate_encounter uses direct component sources" begin
        direct_class_config = EncounterClassConfig(
            NoScaling(1.0),
            HullSizeConfig(LinearScaling(3.0, 0.0), LinearScaling(5.0, 0.0)),
            LinearScaling(2.0, 0.0),
            DirectEncounterComponents(
                [
                    WeightedComponentSet(mock_shipset, NoScaling(1.0)),
                ]
            ),
            mock_pipe_opts,
            NoScaling(1.0),
        )
        blueprint = generate_encounter(
            ENCOUNTER_SCRAP,
            nothing,
            1.0,
            UInt32(0x2222),
            direct_class_config,
        )

        @test !isempty(blueprint.ship_tiles)
        @test length(blueprint.components) == 2
    end

    @testset "direct component source empty-pool validation" begin
        empty_direct_config = EncounterClassConfig(
            NoScaling(1.0),
            HullSizeConfig(LinearScaling(3.0, 0.0), LinearScaling(5.0, 0.0)),
            LinearScaling(1.0, 0.0),
            DirectEncounterComponents(WeightedComponentSet[]),
            PipeSpawnOptions[],
            NoScaling(1.0),
        )
        @test_throws ArgumentError generate_encounter(
            ENCOUNTER_SCRAP, nothing, 1.0, UInt32(0x2222), empty_direct_config
        )

        hull_only_config = EncounterClassConfig(
            NoScaling(1.0),
            HullSizeConfig(LinearScaling(3.0, 0.0), LinearScaling(5.0, 0.0)),
            LinearScaling(0.0, 0.0),
            DirectEncounterComponents(WeightedComponentSet[]),
            PipeSpawnOptions[],
            NoScaling(1.0),
        )
        blueprint = generate_encounter(
            ENCOUNTER_SCRAP, nothing, 1.0, UInt32(0x2222), hull_only_config
        )
        @test !isempty(blueprint.ship_tiles)
        @test isempty(blueprint.components)
    end

    @testset "generation retries based on component-count progress" begin
        impossible_set = ShipComponentSet(
            "impossible", [
                CompSpawnOptions(:MockComp, [(100, 1.0)], HexFlowProcGen.CLUSTERED_PLACE),
            ]
        )
        possible_set = ShipComponentSet(
            "possible", [
                CompSpawnOptions(:MockComp, [(1, 1.0)], HexFlowProcGen.RANDOM_PLACE),
            ]
        )
        retry_pipe_opts = [PipeSpawnOptions(:MockPipe, HexFlowProcGen.RANDOM_PIPES, 1.0)]
        retry_config = EncounterClassConfig(
            NoScaling(1.0),
            HullSizeConfig(LinearScaling(3.0, 0.0), LinearScaling(3.0, 0.0)),
            LinearScaling(1.0, 0.0),
            DirectEncounterComponents(
                [
                    WeightedComponentSet(impossible_set, NoScaling(1.0)),
                    WeightedComponentSet(possible_set, NoScaling(1.0)),
                ]
            ),
            retry_pipe_opts,
            NoScaling(1.0),
        )

        third_attempt_blueprint = generate_encounter(
            ENCOUNTER_SCRAP, nothing, 1.0, UInt32(8), retry_config
        )
        @test length(third_attempt_blueprint.components) == 1

        fourth_attempt_blueprint = generate_encounter(
            ENCOUNTER_SCRAP, nothing, 1.0, UInt32(16), retry_config
        )
        @test isempty(fourth_attempt_blueprint.components)

        zero_count_set = ShipComponentSet(
            "zero_count", [
                CompSpawnOptions(:NeverRolled, [(0, 1.0)], HexFlowProcGen.RANDOM_PLACE),
            ]
        )
        zero_count_config = EncounterClassConfig(
            NoScaling(1.0),
            retry_config.hull_size,
            retry_config.target_components,
            DirectEncounterComponents([WeightedComponentSet(zero_count_set, NoScaling(1.0))]),
            retry_pipe_opts,
            NoScaling(1.0),
        )
        zero_count_blueprint = generate_encounter(
            ENCOUNTER_SCRAP, nothing, 1.0, UInt32(8), zero_count_config
        )
        @test isempty(zero_count_blueprint.components)

        partial_set = ShipComponentSet(
            "partial", [
                CompSpawnOptions(:MockComp, [(1, 1.0)], HexFlowProcGen.RANDOM_PLACE),
                CompSpawnOptions(:MockComp, [(100, 1.0)], HexFlowProcGen.CLUSTERED_PLACE),
            ]
        )
        partial_config = EncounterClassConfig(
            NoScaling(1.0),
            HullSizeConfig(LinearScaling(12.0, 0.0), LinearScaling(12.0, 0.0)),
            LinearScaling(2.0, 0.0),
            DirectEncounterComponents(
                [
                    WeightedComponentSet(partial_set, NoScaling(1.0)),
                    WeightedComponentSet(possible_set, NoScaling(1.0)),
                ]
            ),
            PipeSpawnOptions[],
            NoScaling(1.0),
        )
        partial_blueprint = generate_encounter(
            ENCOUNTER_SCRAP, nothing, 1.0, UInt32(1), partial_config
        )
        @test length(partial_blueprint.components) == 2
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
        gm = make_origin_gamemap()
        bp = make_bare_blueprint(UInt32(0x12345678))

        before = Set(keys(gm.ships))
        encounter_ship!(gm, bp, "encounter_test", UInt32(0x12345678), HexFrame.Q_POS)
        after = Set(keys(gm.ships))

        new_ships = collect(setdiff(after, before))
        @test length(new_ships) == 1

        status = FlowMap.get_docking_status(gm, new_ships[1])
        @test status isa FlowMap.ApproachingDockStat
    end

    @testset "encounter_ship! works with all hex axes" begin
        for axis in instances(HexFrame.HexAxis)
            gm = make_origin_gamemap()
            bp = make_bare_blueprint(UInt32(0xAAAA))

            encounter_ship!(gm, bp, "axis_$(axis)", UInt32(0xAAAA), axis)
            @test length(gm.ships) == 2  # :primary + new ship
        end
    end

    @testset "avoids existing off-ship pipes" begin
        gm = make_origin_gamemap()
        old_surface_only_offset = TileCoord(3, -3)
        set_pipe!(gm, offset_by_tile(make_test_pipe_coord(), old_surface_only_offset), MockPipeBehav())

        encounter_ship!(
            gm, ShipBlueprint(ship_tiles = Set([TileCoord(0, 0)])), "pipe_obstruction",
            UInt32(0x5151), HexFrame.Q_POS
        )
        new_ship = only(setdiff(keys(gm.ships), [:primary]))
        @test round_to_tile(get_surface_centroid(gm, new_ship)) != old_surface_only_offset
    end

    @testset "keeps protruding incoming pipes disconnected" begin
        gm = make_origin_gamemap()
        old_surface_only_offset = TileCoord(3, -3)
        protruding_pipe = offset_by_tile(make_test_pipe_coord(), TileCoord(2, -2))
        existing_pipe = offset_by_tile(protruding_pipe, old_surface_only_offset)
        set_pipe!(gm, existing_pipe, MockPipeBehav())

        blueprint = ShipBlueprint(
            pipe_behaviors = Dict(protruding_pipe => MockPipeBehav()),
            ship_tiles = Set([TileCoord(0, 0)]),
        )
        encounter_ship!(gm, blueprint, "pipe_nodes", UInt32(0x5252), HexFrame.Q_POS)
        new_ship = only(setdiff(keys(gm.ships), [:primary]))

        existing_nodes = collect_pipe_nodes((existing_pipe,))
        incoming_coords = (coord for (coord, pipe) in get_pipes(gm) if pipe.ship === new_ship)
        @test isdisjoint(existing_nodes, collect_pipe_nodes(incoming_coords))
    end

    @testset "encounter -> connect -> depart end-to-end" begin
        gm = make_origin_gamemap()
        bp = make_bare_blueprint(UInt32(0x12345678))

        before = Set(keys(gm.ships))
        encounter_ship!(gm, bp, "e2e_test", UInt32(0x12345678), HexFrame.R_POS)
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

        # Target offset is along the computed departure direction
        @test dstatus.motion.target_offset != HexFrame.AxialCoord(0.0, 0.0)
    end

    @testset "depart_ship! error cases" begin
        gm = make_origin_gamemap()
        bp = make_bare_blueprint(UInt32(0x9999))

        # Can't depart a ship that doesn't exist
        success, _ = depart_ship!(gm, :nonexistent)
        @test success == false

        # Can't depart a ship that is still approaching
        encounter_ship!(gm, bp, "depart_errs", UInt32(0x9999), HexFrame.Q_POS)
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

    ISP_E1 = PipeCoord(ISP_V1, ISP_V2)  # attached to primary via V1
    ISP_E2 = PipeCoord(ISP_V2, ISP_V3)  # floating (no ship surface)
    ISP_E3 = PipeCoord(ISP_V3, ISP_V4)  # attached to secondary via V4

    """
    Create a GameMap with primary at tile (0,0) and secondary at tile (3,-1).
    Secondary has a ConnectedDockStat so it can depart.
    """
    function make_two_ship_gamemap()
        gm = make_origin_gamemap()

        # Secondary ship: single tile at (3,-1), separated from primary
        add_ship!(gm, :secondary, ShipState(docking_status = FlowMap.ConnectedDockStat()))
        set_surface_tile!(gm, Set([TileCoord(3, -1)]); ship_name = :secondary)

        return gm
    end

    @testset "can_place_pipe_offship — connected to ship surface" begin
        gm = make_two_ship_gamemap()
        # E1 has V1 on primary's surface → should be valid, placed on :primary
        valid = can_place_pipe_offship(ISP_E1, gm)
        @test isvalidrequest(valid)
        @test unwrap(valid) === :primary
    end

    @testset "can_place_pipe_offship — connected via existing pipe" begin
        gm = make_two_ship_gamemap()
        # Place E1 on primary, then E2 should connect through E1
        set_pipe!(gm, ISP_E1, PlacedPipe(MockPipeBehav(), :primary))
        valid = can_place_pipe_offship(ISP_E2, gm)
        @test isvalidrequest(valid)
        @test unwrap(valid) === :primary
    end

    @testset "can_place_pipe_offship — neither endpoint connected" begin
        gm = make_two_ship_gamemap()
        # E2 floats in the gap with no connections
        invalid = can_place_pipe_offship(ISP_E2, gm)
        @test !isvalidrequest(invalid)
        @test occursin("Neither endpoint", reason(invalid))
    end

    @testset "validate_offship_pipe_deletion — middle of chain" begin
        gm = make_two_ship_gamemap()
        # Full bridge chain stored on their respective ships
        set_pipe!(gm, ISP_E1, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, ISP_E2, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, ISP_E3, PlacedPipe(MockPipeBehav(), :secondary))

        # Deleting E2 (middle) splits into E1 (reaches primary via V1) and E3 (reaches secondary
        # via V4). Both components still connect to a ship → valid deletion.
        @test validate_offship_pipe_deletion(ISP_E2, gm) == true
    end

    @testset "validate_offship_pipe_deletion — would orphan" begin
        gm = make_two_ship_gamemap()
        # E1 (on primary) → E2 (floating, stored on primary)
        set_pipe!(gm, ISP_E1, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, ISP_E2, PlacedPipe(MockPipeBehav(), :primary))

        # Deleting E1 would orphan E2 (E2's vertices touch no ship surface)
        @test validate_offship_pipe_deletion(ISP_E1, gm) == false
        # Deleting E2 is fine (E1 still reaches primary)
        @test validate_offship_pipe_deletion(ISP_E2, gm) == true
    end

    @testset "reassign_pipe_ownership! — chain split" begin
        gm = make_two_ship_gamemap()
        # Full chain all stored on primary
        set_pipe!(gm, ISP_E1, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, ISP_E2, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, ISP_E3, PlacedPipe(MockPipeBehav(2.0), :primary))

        # Delete E2 to split the chain
        delete_pipe!(gm, ISP_E2)
        reassign_pipe_ownership!(ISP_E2, gm)

        # E1 should stay on primary (V1 is on primary's surface)
        e1 = get_pipe(gm, ISP_E1)
        @test !isnothing(e1) && e1.ship === :primary
        # E3 should have moved to secondary (V4 is on secondary's surface)
        e3 = get_pipe(gm, ISP_E3)
        @test !isnothing(e3) && e3.ship === :secondary
        placed_pipe = e3
        @test !isnothing(placed_pipe)
        @test get_conductance(placed_pipe.pipe) ≈ 2.0
    end

    @testset "check_departure_pipe_connections — no off-surface pipes" begin
        gm = make_two_ship_gamemap()
        status = check_departure_pipe_connections(gm, :secondary)
        @test isvalidrequest(status)
    end

    @testset "check_departure_pipe_connections — pipe bridge blocks departure" begin
        gm = make_two_ship_gamemap()
        # Full chain bridging primary ↔ secondary
        set_pipe!(gm, ISP_E1, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, ISP_E2, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, ISP_E3, PlacedPipe(MockPipeBehav(), :secondary))

        status = check_departure_pipe_connections(gm, :secondary)
        @test !isvalidrequest(status)
        @test occursin("pipes still connect", reason(status))
    end

    @testset "check_departure_pipe_connections — pipe only on departing ship" begin
        gm = make_two_ship_gamemap()
        # E3 only touches secondary, stored on secondary
        set_pipe!(gm, ISP_E3, PlacedPipe(MockPipeBehav(), :secondary))

        status = check_departure_pipe_connections(gm, :secondary)
        @test isvalidrequest(status)
    end

    @testset "depart_ship! blocked by pipe bridge" begin
        gm = make_two_ship_gamemap()
        set_pipe!(gm, ISP_E1, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, ISP_E2, PlacedPipe(MockPipeBehav(), :primary))
        set_pipe!(gm, ISP_E3, PlacedPipe(MockPipeBehav(), :secondary))

        success, reason = depart_ship!(gm, :secondary)
        @test success == false
        @test occursin("pipes still connect", reason)

        # All pipes should still be present
        e1 = get_pipe(gm, ISP_E1)
        e2 = get_pipe(gm, ISP_E2)
        e3 = get_pipe(gm, ISP_E3)
        @test !isnothing(e1) && e1.ship === :primary
        @test !isnothing(e2) && e2.ship === :primary
        @test !isnothing(e3) && e3.ship === :secondary
    end

    @testset "depart_ship! succeeds without pipe bridge" begin
        gm = make_two_ship_gamemap()
        # Pipe only on secondary, no bridge
        set_pipe!(gm, ISP_E3, PlacedPipe(MockPipeBehav(), :secondary))

        success, _ = depart_ship!(gm, :secondary)
        @test success == true
        @test FlowMap.get_docking_status(gm, :secondary) isa FlowMap.DepartingDockStat
        # Pipe stays with secondary
        e3 = get_pipe(gm, ISP_E3)
        @test !isnothing(e3) && e3.ship === :secondary
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
        reachable = Set{PipeCoord}()
        flood_search_pipes_from_node!(reachable, all_edges, start_node)
        @test length(reachable) == 3

        # Flood from an unconnected node — should reach nothing
        far_node = to_nodecoord(to_proper(VertexCoord(TileCoord(10, 10), HexFrame.Q_POS)))
        reachable2 = Set{PipeCoord}()
        flood_search_pipes_from_node!(reachable2, all_edges, far_node)
        @test isempty(reachable2)
    end
end

# ===============================================================
# Encounter point system tests
# ===============================================================

# ===============================================================
# Encounter system test setup
# ===============================================================

"Mock class configuration for tests — uses simple ship set with single mock component."
function make_test_class_config(pipe_opts = mock_pipe_opts)
    mock_shipset = ShipComponentSet(
        "mock_set", [
            CompSpawnOptions(:MockComp, [(1, 1.0)], HexFlowProcGen.RANDOM_PLACE),
        ]
    )
    return EncounterClassConfig(
        NoScaling(1.0),
        HullSizeConfig(LinearScaling(3.0, 0.0), LinearScaling(5.0, 0.0)),
        LinearScaling(2.0, 0.0),
        FluidTaggedEncounterComponents(
            Dict{FluidType, FuelTagConfig}(
                HexFluids.COLD_GAS => FuelTagConfig(
                    NoScaling(1.0),
                    [WeightedComponentSet(mock_shipset, NoScaling(1.0))]
                ),
                HexFluids.MONOPROP_LIQUID => FuelTagConfig(
                    NoScaling(1.0),
                    [WeightedComponentSet(mock_shipset, NoScaling(1.0))]
                ),
            )
        ),
        pipe_opts,
        NoScaling(1.0),
    )
end

"Mock encounter system config for tests."
function make_mock_encounter_config(; n_points::Int = 10)
    test_class_config = make_test_class_config()
    return EncounterSystemConfig(
        n_points = n_points,
        encounter_class_configs = Dict(
            ENCOUNTER_SHIP => test_class_config,
            ENCOUNTER_FUEL_CACHE => test_class_config,
            ENCOUNTER_SCRAP => test_class_config,
        ),
    )
end

"Construct a minimal SpaceMapState with the encounter system fully initialised."
function make_encounter_sm(;
        n_points = 10,
        player_vel = SVector(0.0, 0.0),
        player_pos = SVector(0.0, 0.0)
    )
    config = make_mock_encounter_config(n_points = n_points)
    sm = SpaceMapState(
        seed = UInt32(0x1234ABCD), velocity = player_vel, position = player_pos,
        encounter_config = config
    )
    initialise_encounter_system!(sm)
    return sm
end

"Return the spawn-box half-extents for `sm`."
function get_spawn_box_extents(sm::SpaceMapState)
    config = get_encounter_config(sm)
    return sm.viewport_half_width + config.spawn_box_offset, sm.viewport_half_height + config.spawn_box_offset
end

"Return the disappear-box half-extents for `sm`."
function get_disappear_box_extents(sm::SpaceMapState)
    config = get_encounter_config(sm)
    return sm.viewport_half_width + config.disappear_box_offset, sm.viewport_half_height + config.disappear_box_offset
end

"Return true when `pos` lies on the perimeter of the axis-aligned box centred at `centre`."
function is_on_box_edge(pos::SVector{2, Float64}, centre::SVector{2, Float64}, half_x::Float64, half_y::Float64)
    on_left = pos[1] ≈ centre[1] - half_x && centre[2] - half_y <= pos[2] <= centre[2] + half_y
    on_right = pos[1] ≈ centre[1] + half_x && centre[2] - half_y <= pos[2] <= centre[2] + half_y
    on_top = pos[2] ≈ centre[2] + half_y && centre[1] - half_x <= pos[1] <= centre[1] + half_x
    on_bottom = pos[2] ≈ centre[2] - half_y && centre[1] - half_x <= pos[1] <= centre[1] + half_x
    return on_left || on_right || on_top || on_bottom
end

@testset "Encounter point system" begin

    @testset "replace_encounter_config! updates the live config without reshuffling encounters" begin
        sm = make_encounter_sm(n_points = 3)
        original_points = sm.encounter_points
        original_manoeuvre = ManoeuvreData(
            approach_burn_dv = SVector(1.0, 0.0),
            capture_burn_dv = SVector(0.0, 1.0),
            target_encounter_index = 1,
        )
        sm.active_manoeuvre = original_manoeuvre
        replacement = make_mock_encounter_config(n_points = 7)
        replacement = EncounterSystemConfig(
            n_points = replacement.n_points,
            viewport_half_width = 123.0,
            viewport_half_height = 456.0,
            encounter_class_configs = replacement.encounter_class_configs,
        )

        replace_encounter_config!(sm, replacement)

        @test sm.encounter_points === original_points
        @test sm.active_manoeuvre === original_manoeuvre
        @test length(sm.encounter_points) == 3
        @test sm.encounter_config.n_points == 7
        @test sm.encounter_config.viewport_half_width == 123.0
        @test sm.encounter_config.viewport_half_height == 456.0
        @test sm.viewport_half_width == 123.0
        @test sm.viewport_half_height == 456.0
        @test sm.encounter_config !== replacement
        @test sm.encounter_config.encounter_class_configs !== replacement.encounter_class_configs
    end

    @testset "spawn_encounter_point! places encounters on the spawn perimeter" begin
        sm = make_encounter_sm(player_pos = SVector(10.0, -20.0))
        ep = sm.encounter_points[1]
        old_iter = ep.iteration
        spawn_x, spawn_y = get_spawn_box_extents(sm)

        spawn_encounter_point!(ep, sm, 5.0)

        @test ep.iteration == old_iter + 1
        @test ep.spawn_time ≈ 5.0
        @test is_on_box_edge(ep.position, sm.position, spawn_x, spawn_y)
        @test ep.velocity[1] > 0.0
        @test ep.encounter_class isa EncounterClass
        @test ep.fuel_tag isa HexFluids.FluidType
        @test !isempty(ep.display_name)
        @test ep.richness >= 1.0
    end

    @testset "spawn_encounter_point! preserves direct scrap fuel classification" begin
        scrap_config = EncounterClassConfig(
            NoScaling(1.0),
            HullSizeConfig(LinearScaling(2.0, 0.0), LinearScaling(2.0, 0.0)),
            LinearScaling(0.0, 0.0),
            DirectEncounterComponents(WeightedComponentSet[]),
            PipeSpawnOptions[],
            NoScaling(1.0),
        )
        config = EncounterSystemConfig(
            n_points = 1,
            encounter_class_configs = Dict(ENCOUNTER_SCRAP => scrap_config),
        )
        sm = SpaceMapState(seed = UInt32(0x1234ABCD), encounter_config = config)
        initialise_encounter_system!(sm)
        ep = only(sm.encounter_points)

        spawn_encounter_point!(ep, sm, 5.0)

        @test ep.encounter_class == ENCOUNTER_SCRAP
        @test ep.fuel_tag === nothing
    end

    @testset "spawn_encounter_point! can choose multiple spawn edges across recycles" begin
        sm = make_encounter_sm()
        ep = sm.encounter_points[1]
        spawn_x, spawn_y = get_spawn_box_extents(sm)
        seen_edges = Set{Symbol}()

        for current_time in 1.0:20.0
            spawn_encounter_point!(ep, sm, current_time)

            if ep.position[1] ≈ sm.position[1] - spawn_x
                push!(seen_edges, :left)
            elseif ep.position[1] ≈ sm.position[1] + spawn_x
                push!(seen_edges, :right)
            elseif ep.position[2] ≈ sm.position[2] + spawn_y
                push!(seen_edges, :top)
            elseif ep.position[2] ≈ sm.position[2] - spawn_y
                push!(seen_edges, :bottom)
            end
        end

        @test length(seen_edges) > 1
    end

    @testset "spawn_encounter_point! is deterministic for same iteration" begin
        sm = make_encounter_sm()
        ep1 = sm.encounter_points[1]
        ep2 = deepcopy(ep1)

        spawn_encounter_point!(ep1, sm, 0.0)
        spawn_encounter_point!(ep2, sm, 0.0)

        @test ep1.position == ep2.position
        @test ep1.velocity == ep2.velocity
        @test ep1.ship_type_seed == ep2.ship_type_seed
    end

    @testset "initialise_encounter_system! scatters points inside the disappear box" begin
        sm = make_encounter_sm()
        disappear_x, disappear_y = get_disappear_box_extents(sm)

        @test length(sm.encounter_points) == 10

        for ep in sm.encounter_points
            rel = ep.position - sm.position
            @test abs(rel[1]) <= disappear_x
            @test abs(rel[2]) <= disappear_y
        end
    end

    @testset "initialise_encounter_system! supports a separate reference velocity" begin
        config = make_mock_encounter_config(n_points = 5)
        player_velocity = SVector(4.0, -3.0)
        reference_velocity = SVector(30.0, 20.0)
        sm = SpaceMapState(
            seed = UInt32(0x1234ABCD),
            velocity = player_velocity,
            encounter_config = config,
        )
        reference_sm = SpaceMapState(
            seed = sm.seed,
            velocity = reference_velocity,
            encounter_config = config,
        )

        initialise_encounter_system!(sm; reference_velocity)
        initialise_encounter_system!(reference_sm)

        @test sm.velocity == player_velocity
        @test length(sm.encounter_points) == length(reference_sm.encounter_points)
        for (point, reference_point) in zip(sm.encounter_points, reference_sm.encounter_points)
            @test all(
                field -> isequal(getfield(point, field), getfield(reference_point, field)),
                fieldnames(EncounterPoint),
            )
        end
    end

    @testset "check_encounter_bounds! recycles only out-of-bounds points" begin
        cases = [
            (label = "inside", offset = SVector(0.0, 0.0), should_recycle = false),
            (label = "right", offset = nothing, should_recycle = true),
            (label = "left", offset = nothing, should_recycle = true),
            (label = "top", offset = nothing, should_recycle = true),
            (label = "bottom", offset = nothing, should_recycle = true),
            (label = "diagonal", offset = nothing, should_recycle = true),
            (label = "boundary", offset = nothing, should_recycle = false),
        ]

        for case in cases
            @testset "$(case.label)" begin
                sm = make_encounter_sm(n_points = 1)
                disappear_x, disappear_y = get_disappear_box_extents(sm)
                ep = sm.encounter_points[1]
                old_iter = ep.iteration

                offset = if case.label == "right"
                    SVector(disappear_x + 1.0, 0.0)
                elseif case.label == "left"
                    SVector(-disappear_x - 1.0, 0.0)
                elseif case.label == "top"
                    SVector(0.0, disappear_y + 1.0)
                elseif case.label == "bottom"
                    SVector(0.0, -disappear_y - 1.0)
                elseif case.label == "diagonal"
                    SVector(disappear_x + 1.0, disappear_y + 1.0)
                elseif case.label == "boundary"
                    SVector(disappear_x, 0.0)
                else
                    case.offset
                end

                ep.position = sm.position + offset
                ep.velocity = SVector(0.0, 0.0)
                ep.spawn_time = sm.time_years

                check_encounter_bounds!(sm)

                expected_iter = case.should_recycle ? old_iter + 1 : old_iter
                @test ep.iteration == expected_iter
            end
        end
    end

    @testset "check_encounter_bounds! clears a manoeuvre when its target is recycled" begin
        sm = make_encounter_sm(n_points = 1)
        disappear_x, _ = get_disappear_box_extents(sm)
        spawn_x, spawn_y = get_spawn_box_extents(sm)
        ep = sm.encounter_points[1]
        old_iter = ep.iteration

        sm.active_manoeuvre = ManoeuvreData(
            approach_burn_dv = SVector(0.0, 0.0),
            capture_burn_dv = SVector(0.0, 0.0),
            target_encounter_index = ep.index,
        )
        ep.position = sm.position + SVector(disappear_x + 1.0, 0.0)
        ep.velocity = SVector(0.0, 0.0)
        ep.spawn_time = sm.time_years

        check_encounter_bounds!(sm)

        @test sm.active_manoeuvre === nothing
        @test ep.iteration == old_iter + 1
        @test is_on_box_edge(ep.position, sm.position, spawn_x, spawn_y)
    end

    @testset "check_encounter_bounds! preserves other manoeuvre targets" begin
        sm = make_encounter_sm(n_points = 2)
        disappear_x, _ = get_disappear_box_extents(sm)
        recycled_ep = sm.encounter_points[1]
        target_ep = sm.encounter_points[2]

        sm.active_manoeuvre = ManoeuvreData(
            approach_burn_dv = SVector(0.0, 0.0),
            capture_burn_dv = SVector(0.0, 0.0),
            target_encounter_index = target_ep.index,
        )
        recycled_ep.position = sm.position + SVector(disappear_x + 1.0, 0.0)
        recycled_ep.velocity = SVector(0.0, 0.0)
        recycled_ep.spawn_time = sm.time_years

        check_encounter_bounds!(sm)

        @test sm.active_manoeuvre !== nothing
        @test sm.active_manoeuvre.target_encounter_index == target_ep.index
    end

    @testset "density is maintained after player acceleration (backfill scenario)" begin
        sm = make_encounter_sm(n_points = 50)
        disappear_x, disappear_y = get_disappear_box_extents(sm)

        sm.position = SVector(5000.0, 0.0)
        check_encounter_bounds!(sm)

        current_time = sm.time_years
        for ep in sm.encounter_points
            rel = get_encounter_position(ep, current_time) - sm.position
            @test abs(rel[1]) <= disappear_x
            @test abs(rel[2]) <= disappear_y
        end
    end

    @testset "step_space_map_time! advances time and updates position" begin
        sm = make_encounter_sm()
        sm.velocity = SVector(100.0, 0.0)
        sm.target_time_years = 1.0
        sm.last_stop_time = -1.0  # well before start so easing doesn't throttle the step

        advanced = step_space_map_time!(sm, sm.target_time_years; max_step = 1.0)
        @test advanced == true
        @test sm.time_years ≈ 1.0
        @test sm.position[1] ≈ 100.0

        # At target — no further advance
        sm.target_time_years = 1.0
        advanced2 = step_space_map_time!(sm, sm.target_time_years; max_step = 1.0)
        @test advanced2 == false
    end

    @testset "galaxy escape disables encounter navigation and time progression" begin
        pre_escape_map = GameMap(
            space_map = SpaceMapState(
                encounter_config = make_mock_encounter_config(n_points = 0),
            )
        )
        sm = GalaxyEscapeSpaceMap(
            velocity = SVector(40.0, -3.0),
            starting_velocity_x = 25.0,
            departure_time_years = 18.0,
            pre_escape_map = pre_escape_map,
        )
        initial_velocity = get_velocity(sm)

        @test !step_space_map_time!(sm, 1000.0; max_step = 100.0, ease_distance = 0.01)
        @test get_time_years(sm) == 18.0
        @test get_target_time(sm) == 18.0
        @test get_position(sm) == SVector(0.0, 0.0)
        @test get_velocity(sm) == initial_velocity
        @test isnothing(get_encounter_config(sm))
        @test isempty(get_encounter_points(sm))

        gamemap = GameMap(space_map = sm)
        @test is_galaxy_escape_active(gamemap)
        @test can_abort_galaxy_escape(sm)
        @test can_abort_galaxy_escape(gamemap)
        @test get_galaxy_escape_space_map(gamemap) === sm

        ordinary_space_map = SpaceMapState(encounter_config = make_mock_encounter_config(n_points = 0))
        ordinary_map = GameMap(space_map = ordinary_space_map)
        @test !is_galaxy_escape_active(ordinary_space_map)
        @test !is_galaxy_escape_active(ordinary_map)
        @test !can_abort_galaxy_escape(ordinary_map)
        @test isnothing(get_galaxy_escape_space_map(ordinary_map))
        @test isnothing(get_galaxy_escape_progress(ordinary_map))

        empty_space_map = SpaceMapEmpty(velocity = SVector(2.0, 1.0))
        @test !step_space_map_time!(empty_space_map, 1000.0)
        @test get_velocity(empty_space_map) == SVector(2.0, 1.0)
        @test isnothing(get_encounter_config(empty_space_map))

        compatibility_escape = GalaxyEscapeSpaceMap(
            velocity = SVector(1.0, 0.0), starting_velocity_x = 0.0,
            departure_time_years = 0.0, pre_escape_map = GameMap(),
        )
        @test !can_abort_galaxy_escape(compatibility_escape)
    end
end

# ===============================================================
# Encounter docking geometry tests
# ===============================================================

@testset "Encounter docking geometry" begin

    @testset "builds surface and pipe footprints in the intended order" begin
        gm = make_origin_gamemap()
        pipe_coord = offset_by_tile(make_test_pipe_coord(), TileCoord(20, 20))
        set_pipe!(gm, pipe_coord, MockPipeBehav())

        surface_only = expand_tileset(Set([TileCoord(0, 0)]), DOCKING_SURFACE_CLEARANCE)
        pipe_tiles = docking_footprint(ShipBlueprint(pipe_behaviors = Dict(pipe_coord => MockPipeBehav())))
        exclusion = docking_footprint(gm; surface_clearance = DOCKING_SURFACE_CLEARANCE)

        @test surface_only ⊆ exclusion
        @test pipe_tiles ⊆ exclusion

        outside_pipe_margin = first(
            tile for pipe_tile in pipe_tiles for tile in get_adjacent_tiles_for_tile(pipe_tile)
                if tile ∉ pipe_tiles && tile ∉ surface_only
        )
        @test outside_pipe_margin ∉ exclusion

        component_coord = TileCoord(30, 30)
        blueprint = ShipBlueprint(
            components = Dict(component_coord => PlacedComponent(MockCompBehav(1.0), HexFrame.Q_POS, :incoming)),
            pipe_behaviors = Dict(make_test_pipe_coord() => MockPipeBehav()),
            ship_tiles = Set([TileCoord(0, 0)]),
        )
        incoming = docking_footprint(blueprint)
        incoming_pipe_tiles = docking_footprint(ShipBlueprint(pipe_behaviors = blueprint.pipe_behaviors))

        @test TileCoord(0, 0) in incoming
        @test incoming_pipe_tiles ⊆ incoming
        @test component_coord ∉ incoming
        @test docking_footprint(ShipBlueprint(pipe_behaviors = Dict(pipe_coord => MockPipeBehav()))) == pipe_tiles
    end

    @testset "checks translated footprints without mutation" begin
        existing = Set([TileCoord(0, 0), TileCoord(2, -2)])
        incoming = Set([TileCoord(0, 0), TileCoord(1, 0)])
        existing_before = copy(existing)
        incoming_before = copy(incoming)

        @test ship_footprints_overlap(existing, incoming)
        @test ship_footprints_overlap(existing, incoming, TileCoord(1, -2))
        @test !ship_footprints_overlap(existing, incoming, TileCoord(10, 10))
        for dir in instances(HexFrame.HexAxis)
            translated = Set(tile + HexFrame.hex_neighbour_tiles[dir] for tile in incoming)
            expected = !isdisjoint(existing, translated)
            @test ship_footprints_overlap(
                existing, incoming, HexFrame.hex_neighbour_tiles[dir]
            ) == expected
        end

        @test existing == existing_before
        @test incoming == incoming_before
        offset = HexFlowProcGen._find_docking_offset(
            Set([TileCoord(typemax(Int16), 0)]), Set([TileCoord(0, 0)]),
            TileCoord(typemax(Int16), 0), HexFrame.Q_POS
        )
        @test offset == TileCoord(typemax(Int16) + 1, -1)
    end

    @testset "searches beyond the former 500-step cap" begin
        existing = Set(TileCoord(distance, -distance) for distance in 0:1200)
        incoming = Set([TileCoord(0, 0)])
        offset = HexFlowProcGen._find_docking_offset(
            existing, incoming, TileCoord(0, 0), HexFrame.Q_POS
        )

        @test tile_distance(offset, TileCoord(0, 0)) > 500
        @test !ship_footprints_overlap(existing, incoming, offset)
    end

    @testset "handles empty geometry from the origin" begin
        dir, offset = HexFlowProcGen._find_optimal_docking_offset(
            Set{TileCoord}(), Set([TileCoord(0, 0)]), TileCoord(0, 0), UInt32(0x1234)
        )
        @test dir in instances(HexFrame.HexAxis)
        @test offset == TileCoord(0, 0)

        gm = GameMap()
        delete_all_surface_tiles!(gm)
        encounter_ship_optimal_dir!(
            gm, ShipBlueprint(ship_tiles = Set([TileCoord(0, 0)])), "empty_primary", UInt32(0x1234)
        )
        new_ship = only(setdiff(keys(gm.ships), [:primary]))
        @test get_surface_centroid(gm, new_ship) == HexFrame.AxialCoord(0.0, 0.0)
    end
end

# ===============================================================
# encounter_ship_optimal_dir! tests
# ===============================================================

@testset "encounter_ship_optimal_dir!" begin

    @testset "adds a ship with ApproachingDockStat" begin
        gm = make_origin_gamemap()
        bp = make_bare_blueprint(UInt32(0xAAAA))

        before = Set(keys(gm.ships))
        encounter_ship_optimal_dir!(gm, bp, "opt_test", UInt32(0xAAAA))
        after = Set(keys(gm.ships))

        new_ships = collect(setdiff(after, before))
        @test length(new_ships) == 1

        status = FlowMap.get_docking_status(gm, new_ships[1])
        @test status isa FlowMap.ApproachingDockStat
    end

    @testset "picks direction requiring least offset" begin
        # Create a primary ship elongated along the S axis (q varies, r=0).
        # S_NEG/S_POS walk along the line and require many steps;
        # perpendicular directions (Q_POS, R_NEG, etc.) clear in one step.
        gm = GameMap()
        set_surface_tile!(gm, Set(TileCoord(q, 0) for q in -5:5); ship_name = :primary)

        newship = ShipBlueprint(ship_tiles = Set([TileCoord(0, 0)]))

        centroid_tile = HexFrame.round_to_tile(get_surface_centroid(gm, :primary))
        existing_exclusion = docking_footprint(gm; surface_clearance = DOCKING_SURFACE_CLEARANCE)
        incoming_footprint = docking_footprint(newship)
        dists = Dict{HexFrame.HexAxis, Int}()
        for dir in instances(HexFrame.HexAxis)
            offset = HexFlowProcGen._find_docking_offset(
                existing_exclusion, incoming_footprint, centroid_tile, dir
            )
            dists[dir] = tile_distance(offset, centroid_tile)
        end

        # Perpendicular directions should be much shorter than along-the-line directions
        @test dists[HexFrame.R_NEG] < dists[HexFrame.S_NEG]
        @test dists[HexFrame.R_POS] < dists[HexFrame.S_POS]
        @test dists[HexFrame.Q_POS] < dists[HexFrame.S_NEG]

        encounter_ship_optimal_dir!(gm, newship, "minimum_distance", UInt32(0x000A11CE))
        new_name = only(setdiff(keys(gm.ships), [:primary]))
        final_tile = round_to_tile(get_surface_centroid(gm, new_name))
        @test tile_distance(final_tile, centroid_tile) == minimum(values(dists))
    end

    @testset "deterministic for same seed" begin
        gm1 = make_origin_gamemap()
        gm2 = make_origin_gamemap()
        bp = make_bare_blueprint(UInt32(0xBBBB))

        encounter_ship_optimal_dir!(gm1, deepcopy(bp), "det_test", UInt32(0xBBBB))
        encounter_ship_optimal_dir!(gm2, deepcopy(bp), "det_test", UInt32(0xBBBB))

        key1 = only(setdiff(keys(gm1.ships), [:primary]))
        key2 = only(setdiff(keys(gm2.ships), [:primary]))

        s1 = FlowMap.get_docking_status(gm1, key1)
        s2 = FlowMap.get_docking_status(gm2, key2)
        @test s1.motion.current_offset == s2.motion.current_offset
    end

    @testset "seeded ties include every clear direction" begin
        gm = make_origin_gamemap()
        blueprint = ShipBlueprint(ship_tiles = Set([TileCoord(0, 0)]))
        exclusion = docking_footprint(gm; surface_clearance = DOCKING_SURFACE_CLEARANCE)
        footprint = docking_footprint(blueprint)
        anchor = TileCoord(0, 0)

        chosen_dirs = Set{HexFrame.HexAxis}()
        for seed in UInt32(1):UInt32(64)
            dir, offset = HexFlowProcGen._find_optimal_docking_offset(exclusion, footprint, anchor, seed)
            push!(chosen_dirs, dir)
            @test tile_distance(offset, anchor) == 3
        end
        @test chosen_dirs == Set(instances(HexFrame.HexAxis))
    end

    @testset "does not mutate the input blueprint" begin
        gm = make_origin_gamemap()
        pipe_coord = make_test_pipe_coord()
        component_coord = TileCoord(0, 0)
        blueprint = ShipBlueprint(
            components = Dict(component_coord => PlacedComponent(MockCompBehav(1.0), HexFrame.Q_POS, :incoming)),
            pipe_behaviors = Dict(pipe_coord => MockPipeBehav()),
            ship_tiles = Set([TileCoord(0, 0)]),
        )
        component_keys = Set(keys(blueprint.components))
        pipe_keys = Set(keys(blueprint.pipe_behaviors))
        ship_tiles = copy(blueprint.ship_tiles)

        encounter_ship_optimal_dir!(gm, blueprint, "unchanged", UInt32(0xC0DE))

        @test Set(keys(blueprint.components)) == component_keys
        @test Set(keys(blueprint.pipe_behaviors)) == pipe_keys
        @test blueprint.ship_tiles == ship_tiles
    end

    @testset "spreads ships around when multiple docked" begin
        gm = make_origin_gamemap()

        # Dock 3 ships in sequence — they should spread out rather than stack
        centroids = HexFrame.AxialCoord[]
        for i in 1:3
            bp = make_bare_blueprint(UInt32(0x1000 + i))
            before = Set(keys(gm.ships))
            encounter_ship_optimal_dir!(gm, bp, "spread_$(i)", UInt32(0x1000 + i))
            after = Set(keys(gm.ships))
            new_name = only(setdiff(after, before))

            # Connect the ship so it's part of the overlap check for subsequent encounters
            for _ in 1:500
                FlowMap.update_docking!(gm; ship_name = new_name)
                if FlowMap.get_docking_status(gm, new_name) isa FlowMap.ConnectedDockStat
                    break
                end
            end

            push!(centroids, FlowMap.get_surface_centroid(gm, new_name))
        end

        # With 3 ships, we should have at least 2 unique centroid positions
        @test length(unique(centroids)) >= 2
    end
end
