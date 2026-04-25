using Test
using HexFluids
using Base.Threads: @spawn

@testset "HexFluids" begin

@testset "Fluid property defaults" begin
    @test lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS) == 500.0
    @test lookup_fluid_exhaust_velocity(HexFluids.MONOPROP_GAS) == 1500.0

    @test lookup_fluid_density(HexFluids.COLD_GAS) == 1.0
    @test lookup_fluid_density(HexFluids.MONOPROP_LIQUID) == 5.0
    @test lookup_fluid_density(HexFluids.MONOPROP_GAS) == 1.0

    @test lookup_fluid_reference_temperature(HexFluids.COLD_GAS) == 300.0
    @test lookup_fluid_reference_temperature(HexFluids.MONOPROP_GAS) == 800.0
end

@testset "Temperature-scaled exhaust velocity" begin
    cold_gas_reference_velocity = HexFluids.lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS)::Float64
    cold_gas_reference_temperature = HexFluids.lookup_fluid_reference_temperature(HexFluids.COLD_GAS)::Float64

    @test HexFluids.lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS, cold_gas_reference_temperature) == cold_gas_reference_velocity
    @test HexFluids.lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS, cold_gas_reference_temperature / 4) ≈ cold_gas_reference_velocity / 2
    @test HexFluids.lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS, cold_gas_reference_temperature * 4) == cold_gas_reference_velocity

    @test HexFluids.lookup_fluid_exhaust_velocity(HexFluids.MONOPROP_LIQUID, 300.0) === nothing
end

@testset "Runtime tuning setters" begin
    old_exhaust = something(lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS))
    old_density = something(lookup_fluid_density(HexFluids.COLD_GAS))

    try
        @test set_fluid_exhaust_velocity!(HexFluids.COLD_GAS, old_exhaust + 42.0) === nothing
        @test lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS) == old_exhaust + 42.0

        @test set_fluid_density!(HexFluids.COLD_GAS, old_density + 0.25) === nothing
        @test lookup_fluid_density(HexFluids.COLD_GAS) == old_density + 0.25
    finally
        set_fluid_exhaust_velocity!(HexFluids.COLD_GAS, old_exhaust)
        set_fluid_density!(HexFluids.COLD_GAS, old_density)
    end
end

@testset "Snapshot dictionary getters" begin
    exhaust_snapshot = get_fluid_exhaust_velocities()
    density_snapshot = get_fluid_densities()

    @test exhaust_snapshot isa Dict{FluidType, Float64}
    @test density_snapshot isa Dict{FluidType, Float64}

    @test exhaust_snapshot[HexFluids.COLD_GAS] == something(lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS))
    @test density_snapshot[HexFluids.MONOPROP_LIQUID] == something(lookup_fluid_density(HexFluids.MONOPROP_LIQUID))

    baseline = something(lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS))
    exhaust_snapshot[HexFluids.COLD_GAS] = -1.0
    @test lookup_fluid_exhaust_velocity(HexFluids.COLD_GAS) == baseline
end

@testset "Setter validation for unknown fluid types" begin
    # FluidType values without configured properties should throw
    unknown_fluid = reinterpret(HexFluids.FluidType, UInt32(0xFF))
    @test_throws ErrorException set_fluid_exhaust_velocity!(unknown_fluid, 100.0)
    @test_throws ErrorException set_fluid_density!(unknown_fluid, 1.0)
end

@testset "Fluid labels" begin
    @test fluid_type_label(HexFluids.COLD_GAS) == "Cold Gas"
    @test fluid_type_label(nothing) === nothing
end

@testset "Concurrent tuning smoke test" begin
    original_density = something(lookup_fluid_density(HexFluids.COLD_GAS))
    candidate_values = (101.0, 202.0, 303.0, 404.0)

    try
        tasks = map(candidate_values) do value
            @spawn begin
                for _ in 1:1000
                    set_fluid_density!(HexFluids.COLD_GAS, value)
                    lookup_fluid_density(HexFluids.COLD_GAS)
                end
                return nothing
            end
        end

        wait.(tasks)
        final_density = something(lookup_fluid_density(HexFluids.COLD_GAS))
        @test final_density in candidate_values
    finally
        set_fluid_density!(HexFluids.COLD_GAS, original_density)
    end
end

end
