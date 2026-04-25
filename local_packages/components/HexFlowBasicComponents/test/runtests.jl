using Test
using HexComponentsAPI
using HexFlowBasicComponents

@testset "Damage fragment" begin
    damage = DamageStateBehavFrag()
    @test !is_damaged(damage)

    actions = get_actions(damage)
    @test length(actions) == 1
    @test actions[1].id === :repair_component
    @test !actions[1].enabled

    damage!(damage)
    @test is_damaged(damage)

    success, _ = do_action!(damage, :repair_component)
    @test success
    @test !is_damaged(damage)
end

@testset "Component temperature fragment" begin
    temperature = ComponentTemperatureBehavFrag()
    @test get_component_temperature(temperature) == 300.0

    set_component_temperature!(temperature, 412.5)
    @test get_component_temperature(temperature) == 412.5
end

@testset "Overheat fragment" begin
    @test_throws ErrorException OverheatLimitBehavFrag(300.0, 5.0, 1.0)
    @test_throws ErrorException OverheatLimitBehavFrag(400.0, 0.0, 1.0)
    @test_throws ErrorException OverheatLimitBehavFrag(400.0, 5.0, -1.0)

    overheat = OverheatLimitBehavFrag(400.0, 5.3, 5.0)
    @test get_overheat_limit_temperature(overheat) == 400.0
    @test get_component_temperature(overheat) == 300.0
    @test get_overheat_percentage(overheat) == 0.0

    tuned = set_tunables(overheat, (450.0, 6.0, 8.0))
    @test tuned.temperature === overheat.temperature
    @test tuned.damage === overheat.damage

    calibrated = OverheatLimitBehavFrag(400.0, 5.3, 5.0)
    nominal_mass_flow = 30.0 / (1 / 2.0 + 1 / 0.04)
    for _ in 1:BASE_UPS
        update_overheat_state!(calibrated; fluid_temperature_k = 800.0, mass_flow_rate = nominal_mass_flow)
    end
    @test 398.0 <= get_component_temperature(calibrated) <= 400.5
    @test !is_damaged(calibrated)
    @test 0.98 <= get_overheat_percentage(calibrated) < 1.0

    hot_tint = get_overheat_tint(calibrated)
    @test hot_tint[1] == 1.0
    @test 0.0 < hot_tint[2] < 0.02
    @test 0.0 < hot_tint[3] < 0.02

    while !is_damaged(calibrated)
        update_overheat_state!(calibrated; fluid_temperature_k = 800.0, mass_flow_rate = nominal_mass_flow)
    end
    @test get_overheat_percentage(calibrated) == 1.0

    start_temperature = get_component_temperature(calibrated)
    for _ in 1:(5 * BASE_UPS)
        update_overheat_state!(calibrated; fluid_temperature_k = 300.0, mass_flow_rate = 0.0)
    end
    @test get_component_temperature(calibrated) < start_temperature
    @test is_damaged(calibrated)

    repaired, _ = do_action!(calibrated, :repair_component)
    @test repaired
    @test !is_damaged(calibrated)
end