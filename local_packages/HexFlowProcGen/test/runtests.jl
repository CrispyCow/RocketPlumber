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
end
