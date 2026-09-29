#=
Scope: Tests for basic component behaviour fragments
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using HexComponentsAPI
using HexFlowBasicComponents
using HexFluids

@testset "Damage fragment" begin
    damage = DamageStateBehavFrag()
    @test !is_damaged(damage)

    actions = get_actions(damage)
    @test length(actions) == 1
    @test actions[1].id === :repair_component
    @test !actions[1].enabled

    damage!(damage)
    @test is_damaged(damage)

    result = do_action!(damage, :repair_component)
    @test isvalidrequest(result)
    @test !is_damaged(damage)

    stale_result = do_action!(damage, :repair_component)
    @test !isvalidrequest(stale_result)
    @test reason(stale_result) == "Component is not currently damaged"
    @test_throws ArgumentError do_action!(damage, :unknown_action)
end

@testset "Component temperature fragment" begin
    temperature = ComponentTemperatureBehavFrag()
    @test get_component_temperature(temperature) == 300.0

    set_component_temperature!(temperature, 412.5)
    @test get_component_temperature(temperature) == 412.5
end

@testset "Overheat fragment" begin
    clamped = OverheatLimitBehavFrag(300.0, 0.0, -1.0)
    @test clamped.limit_temperature_k == THERMAL_AMBIENT_TEMPERATURE_K + 1.0
    @test clamped.thermal_mass == 1.0e-6
    @test clamped.heat_loss_factor == 0.0

    overheat = OverheatLimitBehavFrag(400.0, 5.3, 5.0)
    @test get_overheat_limit_temperature(overheat) == 400.0
    @test get_component_temperature(overheat) == 300.0
    @test get_overheat_percentage(overheat) == 0.0

    tuned = set_tunables(overheat, (450.0, 6.0, 8.0))
    @test tuned.temperature === overheat.temperature
    @test tuned.damage === overheat.damage

    invalid = set_tunables(overheat, (250.0, 0.0, -1.0))
    @test invalid.limit_temperature_k == THERMAL_AMBIENT_TEMPERATURE_K + 1.0
    @test invalid.thermal_mass == 1.0e-6
    @test invalid.heat_loss_factor == 0.0

    calibrated = OverheatLimitBehavFrag(400.0, 5.3, 5.0)
    nominal_mass_flow = 30.0 / (1 / 2.0 + 1 / 0.04)
    for _ in 1:(5 * BASE_UPS)
        update_overheat_state!(calibrated; fluid_temperature_k = 800.0, mass_flow_rate = nominal_mass_flow)
    end
    @test 394.5 <= get_component_temperature(calibrated) <= 396.0
    @test !is_damaged(calibrated)
    @test 0.94 <= get_overheat_percentage(calibrated) < 1.0

    hot_tint = get_overheat_tint(calibrated)
    @test hot_tint[1] == 1.0
    @test 0.03 < hot_tint[2] < 0.06
    @test 0.03 < hot_tint[3] < 0.06

    damaging = OverheatLimitBehavFrag(400.0, 5.3, 5.0)
    for _ in 1:(20 * BASE_UPS)
        update_overheat_state!(damaging; fluid_temperature_k = 900.0, mass_flow_rate = nominal_mass_flow)
        is_damaged(damaging) && break
    end
    @test is_damaged(damaging)
    @test get_overheat_percentage(damaging) == 1.0

    start_temperature = get_component_temperature(damaging)
    for _ in 1:(5 * BASE_UPS)
        update_overheat_state!(damaging; fluid_temperature_k = 300.0, mass_flow_rate = 0.0)
    end
    @test get_component_temperature(damaging) <= 301.5
    @test get_component_temperature(damaging) < start_temperature
    @test is_damaged(damaging)

    result = do_action!(damaging, :repair_component)
    @test isvalidrequest(result)
    @test !is_damaged(damaging)
end
