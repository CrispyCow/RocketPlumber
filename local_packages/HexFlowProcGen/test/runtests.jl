using Test
using SquirrelNoise

# Include the local module source (keeps tests runnable without Pkg install)
include(joinpath(@__DIR__, "..", "src", "HexFlowProcGen.jl"))
using .HexFlowProcGen

@testset "weighted_roll_noise distribution (SquirrelNoise)" begin
    frequency = [
        (1, 0.5),
        (2, 0.25),
        (3, 0.125),
        (4, 0.0625),
        (5, 0.03125)
    ]

    seeds = UInt32[0x12345678, 0x87654321, 0xDEADBEEF]
    N = 200_000

    counts = Dict{Int, Int}()
    for (k, _) in frequency
        counts[k] = 0
    end

    for seed in seeds
        for idx in 1:N
            val = HexFlowProcGen.weighted_roll_noise(frequency, idx, seed)
            counts[val] += 1
        end
    end

    total = length(seeds) * N
    tol = 0.02 # 2% absolute tolerance

    @info "Sampled total" sampled=total
    for (item, expected) in frequency
        empirical = counts[item] / total
        @info "Item stats" item=item expected=expected empirical=empirical
        @test abs(empirical - expected) <= tol
    end

@testset "encounter_ship! smoke test" begin
    using FlowMap, HexFrame
    gm = GameMap()
    opts = HexFlowProcGen.ShipGenOptions(name="test", surface_gen_steps=2, surface_gen_stacks=2, component_sets=HexFlowProcGen.ShipComponentSet[], pipe_sets=HexFlowProcGen.PipeSpawnOptions[])
    @test try
        encounter_ship!(gm, opts, 0x12345678, HexFrame.Q_POS)
        true
    catch e
        @warn "encounter_ship! raised" exception = e
        false
    end
end


@testset "encounter -> connect -> depart end-to-end" begin
    using FlowMap

    gm3 = GameMap()
    opts = HexFlowProcGen.ShipGenOptions(name="test2", surface_gen_steps=2, surface_gen_stacks=2, component_sets=HexFlowProcGen.ShipComponentSet[], pipe_sets=HexFlowProcGen.PipeSpawnOptions[])
    before = Set(keys(gm3.ships))
    encounter_ship!(gm3, opts, 0x12345678, HexFrame.R_POS)
    after = Set(keys(gm3.ships))
    new_ships = collect(setdiff(after, before))
    @test length(new_ships) == 1
    newship = new_ships[1]

    # run docking updates until Connected or timeout
    connected = false
    for i in 1:500
        FlowMap.update_docking!(gm3; ship_name = newship)
        status = FlowMap.get_docking_status(gm3, newship)
        if status isa FlowMap.ConnectedDockStat
            connected = true
            break
        end
    end
    @test connected == true

    # Now attempt depart
    success, reason = depart_ship!(gm3, newship)
    @test success == true
    dstatus = FlowMap.get_docking_status(gm3, newship)
    @test dstatus isa FlowMap.DepartingDockStat

    # Ensure the depart axis backtracks to the same approach axis (R_POS)
    approach_axis = FlowMap.get_approach_axis(FlowMap.get_docking_status(gm3, newship))
    @test approach_axis == HexFrame.R_POS
    expected_dir = HexFrame.hex_vert_vecs[HexFrame.R_POS]
    expected_target = HexFrame.AxialCoord(expected_dir.q * 20, expected_dir.r * 20)
    @test (dstatus::FlowMap.DepartingDockStat).motion.target_offset == expected_target
end
end
