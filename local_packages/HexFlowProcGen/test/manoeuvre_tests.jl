using Test
using StaticArrays

# Simple manoeuvre-planning unit tests (headless, deterministic)
@testset "Manoeuvre planning (unit)" begin

    function simulate_plan(player_pos::SVector{2, Float64}, player_vel::SVector{2, Float64}, ep::EncounterPoint, current_time::Float64, total_dv::Float64)
        m = plan_intercept_manoeuvre(player_pos, player_vel, ep, current_time, total_dv)
        @test !isnothing(m)
        m = m::ManoeuvreData

        burn_time = m.closest_approach_time
        intercept_time = m.intercept_time

        # Coast to burn time
        pos = player_pos + player_vel * (burn_time - current_time)
        # Apply main burn (instant)
        vel = player_vel + m.main_burn_dv
        # Coast to intercept
        pos = pos + vel * (intercept_time - burn_time)

        target_at_intercept = get_encounter_position(ep, intercept_time)
        separation = norm(pos - target_at_intercept)

        # After decel burn, velocities should match
        vel_after_decel = vel + m.decel_burn_dv
        vel_diff = norm(vel_after_decel - ep.velocity)

        return separation, vel_diff
    end

    @testset "standard manoeuvre scenarios" begin
        ep1 = EncounterPoint(index=1, base_velocity=50.0, position=SVector(500.0,100.0), velocity=SVector(130.0,10.0), spawn_time=0.0)
        sep1, vdiff1 = simulate_plan(SVector(0.0,0.0), SVector(100.0,0.0), ep1, 0.0, 60.0)
        @test isapprox(sep1, 0.0; atol=1e-6)
        @test isapprox(vdiff1, 0.0; atol=1e-6)

        ep2 = EncounterPoint(index=2, base_velocity=80.0, position=SVector(1000.0,200.0), velocity=SVector(50.0,-5.0), spawn_time=0.0)
        sep2, vdiff2 = simulate_plan(SVector(0.0,0.0), SVector(100.0,0.0), ep2, 0.0, 100.0)
        @test isapprox(sep2, 0.0; atol=1e-6)
        @test isapprox(vdiff2, 0.0; atol=1e-6)

        ep3 = EncounterPoint(index=3, base_velocity=200.0, position=SVector(2000.0,0.0), velocity=SVector(-100.0,0.0), spawn_time=0.0)
        sep3, vdiff3 = simulate_plan(SVector(0.0,0.0), SVector(100.0,0.0), ep3, 0.0, 250.0)
        @test isapprox(sep3, 0.0; atol=1e-6)
        @test isapprox(vdiff3, 0.0; atol=1e-6)

        ep4 = EncounterPoint(index=4, base_velocity=100.0, position=SVector(200.0,300.0), velocity=SVector(100.0,0.0), spawn_time=0.0)
        sep4, vdiff4 = simulate_plan(SVector(0.0,0.0), SVector(100.0,0.0), ep4, 0.0, 40.0)
        @test isapprox(sep4, 0.0; atol=1e-6)
        @test isapprox(vdiff4, 0.0; atol=1e-6)
    end
end
