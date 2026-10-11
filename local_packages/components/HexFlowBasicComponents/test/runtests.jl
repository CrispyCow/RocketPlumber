#=
Scope: Tests for basic component behaviour fragments
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using HexComponentsAPI
using HexFlowBasicComponents
using HexFluids
using HexElements, HexFrame
using HexFlowRendering, RenderEngine, StaticArrays

@testset "Damage fragment" begin
    damage_state = DamageStateBehavFrag()
    @test !is_damaged(damage_state)

    actions = get_actions(damage_state)
    @test length(actions) == 1
    @test actions[1].id === :repair_component
    @test !actions[1].enabled

    original = damage_state
    damage_state = damage(damage_state)
    @test !is_damaged(original)
    @test is_damaged(damage_state)

    damaged_original = damage_state
    damage_state, result = do_action(damage_state, :repair_component)
    @test isvalidrequest(result)
    @test !is_damaged(damage_state)

    @test is_damaged(damaged_original)
    unchanged, stale_result = do_action(damage_state, :repair_component)
    @test !is_damaged(unchanged)
    @test !isvalidrequest(stale_result)
    @test reason(stale_result) == "Component is not currently damaged"
    @test_throws ArgumentError do_action(damage_state, :unknown_action)
end

@testset "Component temperature state" begin
    temperature = ComponentTemperatureState()
    @test get_component_temperature(temperature) == 300.0

    original = temperature
    temperature = set_component_temperature(temperature, 412.5)
    @test get_component_temperature(original) == 300.0
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

    calibrated = overheat
    nominal_mass_flow = 30.0 / (1 / 2.0 + 1 / 0.04)
    for _ in 1:(5 * BASE_UPS)
        calibrated = update_overheat_state(calibrated; fluid_temperature_k = 800.0, mass_flow_rate = nominal_mass_flow)
    end
    @test 394.5 <= get_component_temperature(calibrated) <= 396.0
    @test !is_damaged(calibrated)
    @test 0.94 <= get_overheat_percentage(calibrated) < 1.0

    hot_tint = get_overheat_tint(calibrated)
    @test hot_tint[1] == 1.0
    @test 0.03 < hot_tint[2] < 0.06
    @test 0.03 < hot_tint[3] < 0.06

    damaging = overheat
    for _ in 1:(20 * BASE_UPS)
        damaging = update_overheat_state(damaging; fluid_temperature_k = 900.0, mass_flow_rate = nominal_mass_flow)
        is_damaged(damaging) && break
    end
    @test is_damaged(damaging)
    @test get_overheat_percentage(damaging) == 1.0

    start_temperature = get_component_temperature(damaging)
    for _ in 1:(5 * BASE_UPS)
        damaging = update_overheat_state(damaging; fluid_temperature_k = 300.0, mass_flow_rate = 0.0)
    end
    @test get_component_temperature(damaging) <= 301.5
    @test get_component_temperature(damaging) < start_temperature
    @test is_damaged(damaging)

    original = damaging
    damaging, result = do_action(damaging, :repair_component)
    @test isvalidrequest(result)
    @test !is_damaged(damaging)
    @test is_damaged(original)
end

@testset "Semantic value transitions" begin
    active = AutoDeactivationState()
    inactive = deactivate(active)
    @test !is_inactive(active)
    @test is_inactive(inactive)
    @test !is_inactive(reactivate(inactive))
    @test is_inactive(inactive)

    running = StallStateBehavFrag()
    stalled = stall(running)
    @test !is_stalled(running)
    @test is_stalled(stalled)
    resumed, result = do_action(stalled, :unstall)
    @test isvalidrequest(result)
    @test !is_stalled(resumed)
    @test is_stalled(stalled)
    unchanged, rejected = do_action(running, :unstall)
    @test !isvalidrequest(rejected)
    @test !is_stalled(unchanged)
    @test_throws ArgumentError do_action(running, :unsupported)

    cool = OverheatLimitBehavFrag(400.0, 1.0, 0.0)
    hot = update_overheat_state(cool; fluid_temperature_k = 900.0, mass_flow_rate = 1.0, dt = 1.0)
    @test get_component_temperature(cool) == 300.0
    @test !is_damaged(cool)
    @test get_component_temperature(hot) == 900.0
    @test is_damaged(hot)
    @test hot.limit_temperature_k == cool.limit_temperature_k
    @test hot.thermal_mass == cool.thermal_mass
end

@testset "Concrete runtime state representation" begin
    @test fieldtypes(DamageStateBehavFrag) == (Bool,)
    @test fieldtypes(StallStateBehavFrag) == (Bool,)
    @test fieldtypes(AutoDeactivationState) == (Bool,)
    @test fieldtypes(ComponentTemperatureState) == (Float64,)
    for type in (DamageStateBehavFrag, StallStateBehavFrag, AutoDeactivationState, ComponentTemperatureState)
        @test isbitstype(type)
    end
end

@testset "Basic component sprite identity is stored in its type" begin
    element = RelativeElement(RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG), 2.0, HexElements.CONST_RESISTOR)
    component = BasicCompBehav(elems = BasicElemBehavFrag(element), sprite = :TestBasic)
    @test typeof(component) === BasicCompBehav{1, :TestBasic}
    @test isbitstype(typeof(component))
    @test fieldnames(typeof(component)) == (:elems,)
    @test HexFlowBasicComponents.basic_sprite(component) === :TestBasic
    tuned = set_tunables(component, (3.0,))
    @test typeof(tuned) === typeof(component)
    @test only(produce_rel_elements(tuned)).value == 3.0
    @test only(produce_rel_elements(component)).value == 2.0

    glmap = GLObjectMap()
    glmap.textures[:TestAtlas] = RenderEngine.GLtexData(GLtexID(0), UInt32(0), UInt(256), UInt(256))
    glmap.sprites[:TestBasic] = GLspriteData(:TestAtlas, SVector(0.1f0, 0.1f0), SVector(0.2f0, 0.3f0), SVector(256.0f0, 256.0f0), SVector(256.0f0, 256.0f0), SVector(0.0f0, 0.0f0))
    queue = SpriteRenderCommand[]
    offset = AxialCoord(0.2, 0.3)
    render_base_elem!(queue, component; glmap = glmap, position = TileCoord(2, -1), rotation = HexFrame.R_NEG, pos_offset = offset, scale = 0.5, transparency = 0.7, render_height_offset = 200)
    expected = render_basic_tile(glmap, :TestBasic, HexFrame.R_NEG, TileCoord(2, -1); pos_offset = offset, scale = 0.5, transparency = 0.7, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + 200))
    @test only(queue) == expected
end
