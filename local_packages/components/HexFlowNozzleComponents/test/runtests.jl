using Test
using HexFrame
using HexElements
using HexFluids
using FlowEngine
using HexComponentsAPI
using HexFlowBasicComponents
using HexFlowNozzleComponents
using HexFlowSwitchComponents

const TEST_TILE = TileCoord(3, -2)
const TEST_ROTATION = HexFrame.Q_POS

"Set a node voltage in the mock MNA state."
function set_node_voltage!(mna_state::MNA_State, tile::TileCoord, node, voltage::Float64; rotation::HexAxis = TEST_ROTATION)
    mna_state.node_voltages[map_element(node, tile, rotation)] = voltage
    return mna_state
end

"Build a representative switched nozzle for regression tests."
function make_switched_nozzle(; limit_temperature_k::Float64 = 400.0)
    return SwitchedNozzleCompBehav(
        throat_area = 0.2,
        connected_node = HexFrame.NODE_Q_POS,
        max_conductance = 2.0,
        min_conductance = 0.0,
        growth_factor = calculate_growth_factor(2.0, 0.0, 6.0 / BASE_UPS),
        limit_temperature_k = limit_temperature_k
    )
end

"Build a representative basic nozzle for regression tests."
function make_basic_nozzle(; limit_temperature_k::Float64 = 3000.0)
    return BasicNozzleCompBehav(
        connected_node = HexFrame.NODE_Q_POS,
        throat_area = 0.2,
        sprite = :TestSprite,
        limit_temperature_k = limit_temperature_k
    )
end

"Create the solved-state inputs needed for nozzle current and temperature updates."
function make_nozzle_state(nozzle::NozzleBehavFrag; tile::TileCoord = TEST_TILE, rotation::HexAxis = TEST_ROTATION, fluid = HexFluids.MONOPROP_GAS, pressure::Float64 = 100.0, temperature_k::Float64 = 800.0)
    nozzle_input_node = map_element(nozzle.connected_node, tile, rotation)
    mna_state = MNA_State()
    set_node_voltage!(mna_state, tile, nozzle.connected_node, pressure; rotation = rotation)

    nozzle_rel_element = produce_rel_elements(nozzle)[1]
    nozzle_abs_element = map_element(nozzle_rel_element, tile, 1, rotation)
    filteredelements = [nozzle_abs_element]
    derivedmapstate = DerivedMapState(
        filteredelements = filteredelements,
        filterednodes = list_nodes(filteredelements),
        nodeactualfluids = Dict(nozzle_input_node => fluid),
        node_temperatures = Dict(nozzle_input_node => temperature_k)
    )

    return mna_state, derivedmapstate
end

@testset "Nozzle fragment overheat" begin
    nozzle = NozzleBehavFrag(
        HexFrame.NODE_Q_POS,
        0.2,
        StallBehavFrag(),
        OverheatLimitBehavFrag(301.0, 5.3, 5.0)
    )

    tunables = get_tunables(nozzle)
    @test tunables isa NTuple{4, TunableProps}
    @test tunables[1].type_desc == "Nozzle Throat Area"
    @test tunables[2].type_desc == "Temperature Limit"

    mna_state, derivedmapstate = make_nozzle_state(nozzle)
    update_flowbehav!(nozzle; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = mna_state, derivedmapstate = derivedmapstate)

    @test is_damaged(nozzle)
    @test produce_rel_elements(nozzle)[1].active == false
    @test get_overheat_percentage(nozzle) == 1.0
    thrust = get_thrust(nozzle; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = mna_state, derivedmapstate = derivedmapstate)
    @test thrust[1] == 0.0
    @test thrust[2] == 0.0

    actions = get_actions(nozzle)
    @test length(actions) == 2
    @test actions[1].id === :unstall
    @test actions[2].id === :repair_component

    repaired, _ = do_action!(nozzle, :repair_component)
    @test repaired
    @test !is_damaged(nozzle)
end

@testset "Nozzle thrust temperature scaling" begin
    nozzle = NozzleBehavFrag(
        HexFrame.NODE_Q_POS,
        0.2,
        StallBehavFrag(),
    )

    cold_mna_state, cold_derivedmapstate = make_nozzle_state(nozzle; pressure = 50.0, temperature_k = 200.0)
    cold_thrust = get_thrust(nozzle; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = cold_mna_state, derivedmapstate = cold_derivedmapstate)

    reference_mna_state, reference_derivedmapstate = make_nozzle_state(nozzle; pressure = 50.0, temperature_k = 800.0)
    reference_thrust = get_thrust(nozzle; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = reference_mna_state, derivedmapstate = reference_derivedmapstate)

    hot_mna_state, hot_derivedmapstate = make_nozzle_state(nozzle; pressure = 50.0, temperature_k = 1600.0)
    hot_thrust = get_thrust(nozzle; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = hot_mna_state, derivedmapstate = hot_derivedmapstate)

    nozzle_flow = 50.0 * first(produce_rel_elements(nozzle)).value
    density = HexFluids.lookup_fluid_density(HexFluids.MONOPROP_GAS)::Float64
    cold_exhaust_velocity = HexFluids.lookup_fluid_exhaust_velocity(HexFluids.MONOPROP_GAS, 200.0)::Float64
    reference_exhaust_velocity = HexFluids.lookup_fluid_exhaust_velocity(HexFluids.MONOPROP_GAS, 800.0)::Float64
    pressure_component = nozzle.throat_area * 50.0

    @test cold_thrust[1] ≈ density * nozzle_flow * cold_exhaust_velocity + pressure_component
    @test reference_thrust[1] ≈ density * nozzle_flow * reference_exhaust_velocity + pressure_component
    @test hot_thrust[1] ≈ reference_thrust[1]
    @test cold_thrust[2] == 0.0
    @test reference_thrust[2] == 0.0
    @test hot_thrust[2] == 0.0
end

@testset "Component temperature API delegation" begin
    basic = make_basic_nozzle()
    basic_mna_state, basic_derivedmapstate = make_nozzle_state(basic.nozzle; temperature_k = 975.0)
    update_flowbehav!(basic; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = basic_mna_state, derivedmapstate = basic_derivedmapstate)

    @test get_component_temperature(basic) === get_component_temperature(basic.nozzle)

    tile_component = ComponentOnTile(basic, TEST_ROTATION)
    @test get_component_temperature(tile_component) === get_component_temperature(basic)

    switched = make_switched_nozzle()
    switched_mna_state, switched_derivedmapstate = make_nozzle_state(switched.nozzle; temperature_k = 925.0)
    update_flowbehav!(switched; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = switched_mna_state, derivedmapstate = switched_derivedmapstate)

    @test get_component_temperature(switched) === get_component_temperature(switched.nozzle)
    @test get_component_temperature(DecompChamberCompBehav()) === nothing
end

@testset "Switched nozzle tunables and click behaviour" begin
    comp = make_switched_nozzle()
    tunables = get_tunables(comp)

    @test tunables isa NTuple{7, TunableProps}
    @test tunables[1].type_desc == "Nozzle Throat Area"
    @test tunables[2].type_desc == "Temperature Limit"
    @test tunables[3].type_desc == "Thermal Mass"
    @test tunables[4].type_desc == "Radiative Surface Area"
    @test tunables[5].type_desc == "Max Conductance (Fully ON)"
    @test tunables[7].type_desc == "Growth Factor"

    original_temperature_state = comp.nozzle.overheat.temperature
    original_damage_state = comp.nozzle.overheat.damage
    tuned = set_tunables(comp, (0.25, 450.0, 6.5, 7.0, 3.0, 0.1, calculate_growth_factor(3.0, 0.1, 8.0 / BASE_UPS)))
    @test tuned.nozzle.overheat.temperature === original_temperature_state
    @test tuned.nozzle.overheat.damage === original_damage_state
    @test tuned.nozzle.throat_area ≈ 0.25
    @test tuned.nozzle.overheat.limit_temperature_k ≈ 450.0
    @test tuned.nozzle.overheat.thermal_mass ≈ 6.5
    @test tuned.nozzle.overheat.radiative_surface_area ≈ 7.0
    @test tuned.switch.switch.max_conductance ≈ 3.0
    @test tuned.switch.switch.min_conductance ≈ 0.1

    damage!(comp.nozzle)
    on_click!(comp)
    @test comp.switch.switch.state.target_conductance ≈ comp.switch.switch.max_conductance
    @test is_damaged(comp.nozzle)
end

@testset "Decomposition chamber tunables" begin
    comp = DecompChamberCompBehav()

    tunables = get_tunables(comp)
    @test tunables isa NTuple{1, TunableProps}
    @test tunables[1].current_val == 800.0
    @test tunables[1].type_desc == "Output Temperature"
    @test tunables[1].unit_desc == "K"

    tuned_comp = set_tunables(comp, (975.0,))
    @test tuned_comp.output_temperature == 975.0

    decls = produce_rel_fluid_declarations(tuned_comp)
    @test length(decls) == 2
    @test decls[1] === RelativeFluidDeclaration(HexFrame.NODE_Q_POS, FluidTypeRule(HexFluids.MONOPROP_LIQUID))
    @test decls[2] === RelativeFluidDeclaration(HexFrame.NODE_Q_NEG, FluidSource(HexFluids.MONOPROP_GAS, 975.0))
end