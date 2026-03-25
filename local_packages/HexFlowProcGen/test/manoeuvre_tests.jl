using Test
using StaticArrays

# Simple manoeuvre-planning unit tests (headless, deterministic)
@testset "Manoeuvre planning (unit)" begin

    function simulate_plan(player_pos::SVector{2, Float64}, player_vel::SVector{2, Float64}, ep::EncounterPoint, current_time::Float64, total_dv::Float64)
        m = plan_intercept_manoeuvre(player_pos, player_vel, ep, current_time, total_dv)
        @test !isnothing(m)
        m = m::ManoeuvreData

        burn_time = m.approach_burn_time
        intercept_time = m.intercept_time

        # Coast to burn time
        pos = player_pos + player_vel * (burn_time - current_time)
        # Apply approach burn (instant)
        vel = player_vel + m.approach_burn_dv
        # Coast to intercept
        pos = pos + vel * (intercept_time - burn_time)

        target_at_intercept = get_encounter_position(ep, intercept_time)
        separation = norm(pos - target_at_intercept)

        # After capture burn, velocities should match
        vel_after_capture = vel + m.capture_burn_dv
        vel_diff = norm(vel_after_capture - ep.velocity)

        return separation, vel_diff
    end

    @testset "direct intercept helpers" begin
        separation = SVector(100.0, 0.0)
        relative_vel = SVector(10.0, 0.0)

        total_dv = HexFlowProcGen.compute_direct_intercept_dv(separation, relative_vel, 10.0)
        @test isapprox(total_dv, 30.0; atol = 1.0e-9)

        tau = HexFlowProcGen.find_direct_intercept_time(separation, relative_vel, 30.0, 20.0)
        @test !isnothing(tau)
        @test isapprox(tau, 10.0; atol = 1.0e-6)

        infeasible_tau = HexFlowProcGen.find_direct_intercept_time(separation, relative_vel, 29.0, 10.0)
        @test isnothing(infeasible_tau)
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

    @testset "planner initialises immediate burn state" begin
        ep = EncounterPoint(
            index = 5,
            base_velocity = 80.0,
            position = SVector(1000.0, 0.0),
            velocity = SVector(80.0, 0.0),
            spawn_time = 0.0,
        )
        plan = plan_intercept_manoeuvre(SVector(0.0, 0.0), SVector(100.0, 0.0), ep, 0.0, 30.0)
        @test !isnothing(plan)

        plan = plan::ManoeuvreData
        @test plan.phase == PHASE_APPROACH_BURN
        @test plan.approach_burn_time == 0.0
        @test plan.intercept_time > 0.0
        @test plan.burn_target_dv ≈ plan.burn_remaining_dv
        @test plan.burn_target_dv ≈ SVector(norm(plan.approach_burn_dv), 0.0)
        @test norm(plan.capture_burn_position - get_encounter_position(ep, plan.intercept_time)) ≤ 1.0e-6
    end

    @testset "zero-separation degenerate case" begin
        ep = EncounterPoint(
            index = 6,
            base_velocity = 100.0,
            position = SVector(0.0, 0.0),
            velocity = SVector(110.0, -5.0),
            spawn_time = 0.0,
        )
        plan = plan_intercept_manoeuvre(SVector(0.0, 0.0), SVector(100.0, 10.0), ep, 0.0, 30.0)
        @test !isnothing(plan)

        plan = plan::ManoeuvreData
        @test plan.phase == PHASE_APPROACH_BURN
        @test plan.intercept_time == 0.0
        @test plan.capture_burn_dv ≈ SVector(0.0, 0.0)
        @test plan.approach_burn_dv ≈ ep.velocity - SVector(100.0, 10.0)
        @test plan.burn_target_dv ≈ SVector(norm(plan.approach_burn_dv), 0.0)
    end
end
