#=
Scope: Deterministic manoeuvre-planning unit tests
Formatter: Runic
=#

using Test
using StaticArrays

@testset "Manoeuvre planning (unit)" begin

    function simulate_plan(
            player_pos::SVector{2, Float64},
            player_vel::SVector{2, Float64},
            ep::EncounterPoint,
            current_time::Float64,
            total_dv::Float64;
            kwargs...
        )
        m = plan_intercept_manoeuvre(player_pos, player_vel, ep, current_time, total_dv; kwargs...)
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

    "Build a deterministic encounter point for manoeuvre-planning tests."
    function make_test_encounter_point(
            index::Int;
            base_velocity::Float64,
            position::SVector{2, Float64},
            velocity::SVector{2, Float64},
            spawn_time::Float64 = 0.0,
        )::EncounterPoint
        return EncounterPoint(index = index, base_velocity = base_velocity, position = position, velocity = velocity, spawn_time = spawn_time)
    end


    @testset "minimum intercept ΔV" begin
        player_pos = SVector(100.0, -50.0)
        player_vel = SVector(100.0, 20.0)
        current_time = 3.0

        for (relative_vel, expected_minimum) in (
                (SVector(0.0, 0.0), 4.0),
                (SVector(3.0, 4.0), 9.0),
                (SVector(80.0, 0.0), 84.0),
                (SVector(0.0, -100.0), 105.0),
                (SVector(600.0, 800.0), 1050.0),
            )
            target_vel = player_vel + relative_vel
            @test calculate_minimum_intercept_dv(player_vel, target_vel) == expected_minimum

            # Distance changes coast time, not the minimum budget or feasibility
            for separation in (SVector(10.0, 20.0), SVector(1.0e6, -2.0e6))
                ep = make_test_encounter_point(
                    1;
                    base_velocity = norm(target_vel),
                    position = player_pos + separation,
                    velocity = target_vel,
                    spawn_time = current_time,
                )
                @test isnothing(plan_intercept_manoeuvre(player_pos, player_vel, ep, current_time, prevfloat(expected_minimum)))
                sep, vdiff = simulate_plan(player_pos, player_vel, ep, current_time, expected_minimum)
                @test isapprox(sep, 0.0; atol = 1.0e-6)
                @test isapprox(vdiff, 0.0; atol = 1.0e-6)
            end
        end
    end

    @testset "configurable closing ΔV surplus" begin
        player_pos = SVector(100.0, -50.0)
        player_vel = SVector(100.0, 20.0)
        current_time = 3.0

        for (relative_vel, surplus_options, expected_minimum) in (
                (SVector(3.0, 4.0), (min_close_delta_v = 1.0,), 6.0),
                (SVector(3.0, 4.0), (min_close_delta_v = 12.0,), 17.0),
                (SVector(100.0, 0.0), (min_close_delta_v = 1.0,), 105.0),
                (SVector(20.0, 0.0), (min_close_delta_v = 1.0, min_surplus_fraction = 0.1), 22.0),
                (SVector(3.0, 4.0), (min_close_delta_v = 0.25, min_surplus_fraction = 0.0), 5.25),
            )
            target_vel = player_vel + relative_vel
            ep = make_test_encounter_point(
                1;
                base_velocity = norm(target_vel),
                position = player_pos + SVector(10.0, 20.0),
                velocity = target_vel,
                spawn_time = current_time,
            )
            @test calculate_minimum_intercept_dv(player_vel, target_vel; surplus_options...) == expected_minimum
            @test isnothing(plan_intercept_manoeuvre(player_pos, player_vel, ep, current_time, prevfloat(expected_minimum); surplus_options...))
            sep, vdiff = simulate_plan(player_pos, player_vel, ep, current_time, expected_minimum; surplus_options...)
            @test isapprox(sep, 0.0; atol = 1.0e-6)
            @test isapprox(vdiff, 0.0; atol = 1.0e-6)
        end
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
        ep1 = EncounterPoint(index = 1, base_velocity = 50.0, position = SVector(500.0, 100.0), velocity = SVector(130.0, 10.0), spawn_time = 0.0)
        sep1, vdiff1 = simulate_plan(SVector(0.0, 0.0), SVector(100.0, 0.0), ep1, 0.0, 60.0)
        @test isapprox(sep1, 0.0; atol = 1.0e-6)
        @test isapprox(vdiff1, 0.0; atol = 1.0e-6)

        ep2 = EncounterPoint(index = 2, base_velocity = 80.0, position = SVector(1000.0, 200.0), velocity = SVector(50.0, -5.0), spawn_time = 0.0)
        sep2, vdiff2 = simulate_plan(SVector(0.0, 0.0), SVector(100.0, 0.0), ep2, 0.0, 100.0)
        @test isapprox(sep2, 0.0; atol = 1.0e-6)
        @test isapprox(vdiff2, 0.0; atol = 1.0e-6)

        ep3 = EncounterPoint(index = 3, base_velocity = 200.0, position = SVector(2000.0, 0.0), velocity = SVector(-100.0, 0.0), spawn_time = 0.0)
        sep3, vdiff3 = simulate_plan(SVector(0.0, 0.0), SVector(100.0, 0.0), ep3, 0.0, 250.0)
        @test isapprox(sep3, 0.0; atol = 1.0e-6)
        @test isapprox(vdiff3, 0.0; atol = 1.0e-6)

        ep4 = EncounterPoint(index = 4, base_velocity = 100.0, position = SVector(200.0, 300.0), velocity = SVector(100.0, 0.0), spawn_time = 0.0)
        sep4, vdiff4 = simulate_plan(SVector(0.0, 0.0), SVector(100.0, 0.0), ep4, 0.0, 40.0)
        @test isapprox(sep4, 0.0; atol = 1.0e-6)
        @test isapprox(vdiff4, 0.0; atol = 1.0e-6)
    end

    @testset "planner initialises immediate burn state" begin
        ep = make_test_encounter_point(
            5;
            base_velocity = 80.0,
            position = SVector(1000.0, 0.0),
            velocity = SVector(80.0, 0.0),
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
        ep = make_test_encounter_point(
            6;
            base_velocity = 100.0,
            position = SVector(0.0, 0.0),
            velocity = SVector(110.0, -5.0),
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

    @testset "relaxed surplus supports recovery-style replans" begin
        ep = make_test_encounter_point(
            7;
            base_velocity = 200.0,
            position = SVector(330.0, 0.0),
            velocity = SVector(200.0, 0.0),
        )

        player_pos = SVector(650.0, 0.0)
        player_vel = SVector(100.0, 0.0)
        current_time = 3.0
        total_dv = 104.5

        @test isnothing(plan_intercept_manoeuvre(player_pos, player_vel, ep, current_time, total_dv))

        relaxed_plan = plan_intercept_manoeuvre(
            player_pos,
            player_vel,
            ep,
            current_time,
            total_dv;
            min_surplus_fraction = 0.0,
        )
        @test !isnothing(relaxed_plan)

        relaxed_plan = relaxed_plan::ManoeuvreData
        @test relaxed_plan.phase == PHASE_APPROACH_BURN
        @test relaxed_plan.approach_burn_time == current_time
        @test relaxed_plan.intercept_time > current_time
        @test relaxed_plan.burn_target_dv ≈ relaxed_plan.burn_remaining_dv
        @test relaxed_plan.burn_target_dv ≈ SVector(norm(relaxed_plan.approach_burn_dv), 0.0)

        sep, vdiff = simulate_plan(
            player_pos,
            player_vel,
            ep,
            current_time,
            total_dv;
            min_surplus_fraction = 0.0,
        )
        @test isapprox(sep, 0.0; atol = 1.0e-6)
        @test isapprox(vdiff, 0.0; atol = 1.0e-6)
    end

    @testset "fixed-time replans minimise coast recovery burns" begin
        player_pos_0 = SVector(0.0, 0.0)
        player_vel_0 = SVector(100.0, 0.0)
        ep = make_test_encounter_point(
            8;
            base_velocity = 80.0,
            position = SVector(1000.0, 0.0),
            velocity = SVector(80.0, 0.0),
        )

        initial_plan = plan_intercept_manoeuvre(player_pos_0, player_vel_0, ep, 0.0, 30.0)
        @test !isnothing(initial_plan)

        initial_plan = initial_plan::ManoeuvreData
        coast_velocity = player_vel_0 + initial_plan.approach_burn_dv
        current_time = initial_plan.intercept_time / 2.0
        player_pos_mid = player_pos_0 + coast_velocity * current_time

        on_trajectory_plan = plan_intercept_manoeuvre_at_time(
            player_pos_mid,
            coast_velocity,
            ep,
            current_time,
            initial_plan.intercept_time,
        )
        @test !isnothing(on_trajectory_plan)

        on_trajectory_plan = on_trajectory_plan::ManoeuvreData
        @test norm(on_trajectory_plan.approach_burn_dv) ≤ 1.0e-9
        @test on_trajectory_plan.intercept_time == initial_plan.intercept_time

        corrected_velocity = coast_velocity + SVector(0.5, 0.0)
        recovery_plan = plan_intercept_manoeuvre_at_time(
            player_pos_mid,
            corrected_velocity,
            ep,
            current_time,
            initial_plan.intercept_time,
        )
        @test !isnothing(recovery_plan)

        recovery_plan = recovery_plan::ManoeuvreData
        @test recovery_plan.intercept_time == initial_plan.intercept_time
        @test recovery_plan.approach_burn_dv ≈ SVector(-0.5, 0.0)
        @test recovery_plan.burn_target_dv ≈ SVector(0.5, 0.0)
    end
end
