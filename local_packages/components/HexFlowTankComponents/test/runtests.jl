using Test
using HexFrame
using HexElements
using HexFluids
using HexComponentsAPI
using FlowEngine
using HexFlowBasicComponents
using HexFlowTankComponents

using HexElements: CONST_RESISTOR, CONST_VOLTAGE
using HexFlowTankComponents: compute_gas_pressure

const TEST_TILE = TileCoord(3, -2)

"Construct a dummy absolute voltage source entry for MNA_State tests."
function make_vsource(tile::TileCoord, index::Integer)
    connections = AbsoluteElementConnections(
        NodeCoord(tile, HexFrame.NODE_Q_POS),
        NodeCoord(tile, HexFrame.GROUND)
    )
    return AbsoluteElement(connections, 0.0, CONST_VOLTAGE, ElementID(tile, index))
end

"Register one or more voltage source ids in the MNA state."
function register_vsources!(mna_state::MNA_State, tile::TileCoord, indices::Vararg{Int, N}) where {N}
    for index in indices
        element_id = ElementID(tile, index)
        mna_state.vsources[element_id] = make_vsource(tile, index)
    end
    return mna_state
end

"Construct a representative pressure-fed monoprop tank for tests."
function make_pressurefed_tank(; liquid_charge::Float64 = 20.0, gas_charge::Float64 = 4.0, max_liquid_charge::Float64 = 40.0, max_gas_pressure::Float64 = 50.0, series_conductance::Float64 = 5.0)
    tank = PressureFedTankBehavFrag(
        initial_liquid_charge = liquid_charge,
        initial_gas_charge = gas_charge,
        max_liquid_charge = max_liquid_charge,
        max_gas_pressure = max_gas_pressure,
        gas_node = HexFrame.NODE_Q_POS
    )
    return PressureFedTankCompBehav(
        tank,
        (HexFrame.NODE_Q_NEG,),
        series_conductance,
        HexFluids.COLD_GAS,
        HexFluids.MONOPROP_LIQUID,
        NoRotationBehavFrag()
    )
end

"Construct an existing three-port gas tank for regression tests."
function make_gas_tank(; initial_charge::Float64 = 20.0)
    return ThevininTankCompBehav(
        GasTankBehavFrag,
        3;
        fluid = HexFluids.COLD_GAS,
        max_charge = 40.0,
        max_voltage = 50.0,
        initial_charge = initial_charge,
        series_conductance = 5.0
    )
end

"Construct an existing three-port liquid tank for regression tests."
function make_liquid_tank(; initial_charge::Float64 = 20.0)
    return ThevininTankCompBehav(
        LiquidTankBehavFrag,
        3;
        fluid = HexFluids.MONOPROP_LIQUID,
        max_charge = 40.0,
        max_voltage = 1.0,
        initial_charge = initial_charge,
        series_conductance = 5.0
    )
end

@testset "Pressure-fed tank fragment" begin
    tank = make_pressurefed_tank().tank

    @test get_tunables(tank) isa NTuple{4, TunableProps}
    @test compute_gas_pressure(tank) ≈ 9.090909090909092

    zero_gas_tank = PressureFedTankBehavFrag(
        initial_liquid_charge = 20.0,
        initial_gas_charge = 0.0,
        max_liquid_charge = 40.0,
        max_gas_pressure = 50.0,
        gas_node = HexFrame.NODE_Q_POS
    )
    @test compute_gas_pressure(zero_gas_tank) == 0.0

    half_pressure_tank = PressureFedTankBehavFrag(
        initial_liquid_charge = 0.0,
        initial_gas_charge = 10.0,
        max_liquid_charge = 40.0,
        max_gas_pressure = 80.0,
        gas_node = HexFrame.NODE_Q_POS
    )
    @test compute_gas_pressure(half_pressure_tank) ≈ 19.047619047619047

    negative_gas_tank = PressureFedTankBehavFrag(
        initial_liquid_charge = 20.0,
        initial_gas_charge = -1.0,
        max_liquid_charge = 40.0,
        max_gas_pressure = 50.0,
        gas_node = HexFrame.NODE_Q_POS
    )
    @test compute_gas_pressure(negative_gas_tank) ≈ -22.727272727272727

    full_tank = PressureFedTankBehavFrag(
        initial_liquid_charge = 40.0,
        initial_gas_charge = 2.0,
        max_liquid_charge = 40.0,
        max_gas_pressure = 50.0,
        gas_node = HexFrame.NODE_Q_POS
    )
    @test is_stalled(full_tank)
    @test is_stalled(full_tank.liquid_stallstate)
    @test !is_stalled(full_tank.gas_stallstate)
    @test compute_gas_pressure(full_tank) ≈ 50.0

    full_elements = produce_rel_elements(full_tank)
    @test !full_elements[1].active
    @test full_elements[2].active

    tuned_tank = set_tunables(tank, (45.0, 60.0, 25.0, 3.0))
    @test tuned_tank.max_liquid_charge == 45.0
    @test tuned_tank.max_gas_pressure == 60.0
    @test tuned_tank.liquid_state.charge == 25.0
    @test tuned_tank.gas_state.charge == 3.0
end

@testset "Pressure-fed tank charge tracking" begin
    comp = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 4.0)
    tank = comp.tank

    mna_state = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    mna_state.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    mna_state.vsource_currents[ElementID(TEST_TILE, 2)] = 12.0
    update_flowbehav!(tank; tile = TEST_TILE, mna_state = mna_state)
    @test tank.liquid_state.charge ≈ 19.9
    @test tank.gas_state.charge ≈ 4.2
    @test !is_stalled(tank)

    emptying_tank = make_pressurefed_tank(liquid_charge = 0.05, gas_charge = 2.0).tank
    emptying_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    emptying_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    emptying_mna.vsource_currents[ElementID(TEST_TILE, 2)] = 60.0
    update_flowbehav!(emptying_tank; tile = TEST_TILE, mna_state = emptying_mna)
    @test is_stalled(emptying_tank)
    @test emptying_tank.liquid_state.charge ≈ 0.05
    @test emptying_tank.gas_state.charge ≈ 2.0

    filling_tank = make_pressurefed_tank(liquid_charge = 39.95, gas_charge = 2.0).tank
    filling_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    filling_mna.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0
    filling_mna.vsource_currents[ElementID(TEST_TILE, 2)] = -60.0
    update_flowbehav!(filling_tank; tile = TEST_TILE, mna_state = filling_mna)
    @test is_stalled(filling_tank)
    @test is_stalled(filling_tank.liquid_stallstate)
    @test !is_stalled(filling_tank.gas_stallstate)
    @test filling_tank.liquid_state.charge ≈ 39.95
    @test filling_tank.gas_state.charge ≈ 2.0

    gas_only_tank = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 1.0).tank
    gas_only_mna = register_vsources!(MNA_State(), TEST_TILE, 2)
    gas_only_mna.vsource_currents[ElementID(TEST_TILE, 2)] = 6.0
    update_flowbehav!(gas_only_tank; tile = TEST_TILE, mna_state = gas_only_mna)
    @test gas_only_tank.liquid_state.charge ≈ 15.0
    @test gas_only_tank.gas_state.charge ≈ 1.1

    gas_underflow_tank = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 0.05).tank
    gas_underflow_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    gas_underflow_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    gas_underflow_mna.vsource_currents[ElementID(TEST_TILE, 2)] = -6.0
    update_flowbehav!(gas_underflow_tank; tile = TEST_TILE, mna_state = gas_underflow_mna)
    @test gas_underflow_tank.liquid_state.charge ≈ 14.9
    @test gas_underflow_tank.gas_state.charge == 0.0
    @test !is_stalled(gas_underflow_tank.liquid_stallstate)
    @test is_stalled(gas_underflow_tank.gas_stallstate)

    liquid_only_tank = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 1.0).tank
    liquid_only_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    liquid_only_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    update_flowbehav!(liquid_only_tank; tile = TEST_TILE, mna_state = liquid_only_mna)
    @test liquid_only_tank.liquid_state.charge ≈ 14.9
    @test liquid_only_tank.gas_state.charge ≈ 1.0

    pruned_tank = make_pressurefed_tank(liquid_charge = 12.0, gas_charge = 3.0).tank
    update_flowbehav!(pruned_tank; tile = TEST_TILE, mna_state = MNA_State())
    @test pruned_tank.liquid_state.charge ≈ 12.0
    @test pruned_tank.gas_state.charge ≈ 3.0

    vent_gas_tank = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 2.0).tank
    @test do_action!(vent_gas_tank, :vent_gas) == (true, "Pressurising gas vented")
    @test vent_gas_tank.gas_state.charge == 0.0
    @test is_stalled(vent_gas_tank.liquid_stallstate)
    @test is_stalled(vent_gas_tank.gas_stallstate)

    vent_gas_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    vent_gas_mna.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0
    vent_gas_mna.vsource_currents[ElementID(TEST_TILE, 2)] = -6.0
    update_flowbehav!(vent_gas_tank; tile = TEST_TILE, mna_state = vent_gas_mna)
    @test vent_gas_tank.liquid_state.charge == 15.0
    @test vent_gas_tank.gas_state.charge == 0.0

    on_click!(vent_gas_tank)
    @test !is_stalled(vent_gas_tank.liquid_stallstate)
    @test !is_stalled(vent_gas_tank.gas_stallstate)

    vent_liquid_tank = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 2.0).tank
    @test do_action!(vent_liquid_tank, :vent_liquid) == (true, "Liquid fuel vented")
    @test vent_liquid_tank.liquid_state.charge == 0.0
    @test is_stalled(vent_liquid_tank.liquid_stallstate)
    @test is_stalled(vent_liquid_tank.gas_stallstate)
end

@testset "Pressure-fed tank component" begin
    comp = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 4.0)
    elements = produce_rel_elements(comp)

    @test length(elements) == 3
    @test elements[1].type === CONST_VOLTAGE
    @test elements[1].connections == RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.GROUND)
    @test elements[2].type === CONST_VOLTAGE
    @test elements[2].connections == RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.GROUND)
    @test elements[3].type === CONST_RESISTOR
    @test elements[3].connections == RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.NODE_Q_NEG)
    @test elements[1].value ≈ elements[2].value
    @test all(elem.active for elem in elements)

    stall!(comp.tank)
    stalled_elements = produce_rel_elements(comp)
    @test all(!elem.active for elem in stalled_elements)
    unstall!(comp.tank)

    tunables = get_tunables(comp)
    @test tunables isa NTuple{5, TunableProps}
    tuned_comp = set_tunables(comp, (50.0, 70.0, 15.0, 5.0, 8.0))
    @test tuned_comp.tank.max_liquid_charge == 50.0
    @test tuned_comp.tank.max_gas_pressure == 70.0
    @test tuned_comp.tank.liquid_state.charge == 15.0
    @test tuned_comp.tank.gas_state.charge == 5.0
    @test tuned_comp.series_conductance == 8.0

    tags = get_fluidtags(comp)
    @test tags.NODE_Q_POS === HexFluids.COLD_GAS
    @test tags.NODE_Q_NEG === HexFluids.MONOPROP_LIQUID
    @test tags.NODE_R_POS === HexFluids.NONE

    @test map_rotation(comp, HexFrame.R_POS) === HexFrame.Q_POS

    liquid_density = HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64
    gas_density = HexFluids.lookup_fluid_density(HexFluids.COLD_GAS)::Float64
    @test get_component_wet_mass(comp) ≈ (20.0 * liquid_density + 4.0 * gas_density)
    @test get_component_wet_mass(comp; fluid = HexFluids.MONOPROP_LIQUID) ≈ 20.0 * liquid_density
    @test get_component_wet_mass(comp; fluid = HexFluids.COLD_GAS) ≈ 4.0 * gas_density

    comp.tank.gas_state.charge = -2.0
    @test get_component_wet_mass(comp; fluid = HexFluids.COLD_GAS) == 0.0

    gas_stalled_comp = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 4.0)
    HexFlowTankComponents.stall_gas!(gas_stalled_comp.tank)
    gas_stalled_elements = produce_rel_elements(gas_stalled_comp)
    @test gas_stalled_elements[1].active
    @test !gas_stalled_elements[2].active
    @test gas_stalled_elements[3].active

    @test !can_be_moved(make_pressurefed_tank(liquid_charge = 10.0, gas_charge = 0.0))[1]
    @test !can_be_moved(make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 1.0))[1]
    @test can_be_moved(make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 0.0))[1]

    movable_stalled = make_pressurefed_tank(liquid_charge = 39.0, gas_charge = 0.0)
    stall!(movable_stalled.tank)
    @test !can_be_moved(movable_stalled)[1]
end

@testset "Pressure-fed tank actions" begin
    tank = make_pressurefed_tank(liquid_charge = 12.0, gas_charge = 3.0).tank
    actions = get_actions(tank)
    @test length(actions) == 3
    @test all(action isa ActionInfo for action in actions)

    success, _ = do_action!(tank, :vent_gas)
    @test success
    @test tank.gas_state.charge == 0.0
    @test is_stalled(tank)
    @test is_stalled(tank.liquid_stallstate)
    @test is_stalled(tank.gas_stallstate)

    success, _ = do_action!(tank, :vent_gas)
    @test !success

    success, _ = do_action!(tank, :vent_liquid)
    @test success
    @test tank.liquid_state.charge == 0.0
    @test is_stalled(tank)

    success, _ = do_action!(tank, :unstall)
    @test success
    @test !is_stalled(tank)

    empty_tank = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 0.0).tank
    success, _ = do_action!(empty_tank, :vent_liquid)
    @test !success
end

@testset "Existing tank regression coverage" begin
    gas_comp = make_gas_tank(initial_charge = 20.0)
    gas_elements = produce_rel_elements(gas_comp)
    @test length(gas_elements) == 4
    @test gas_elements[1].type === CONST_VOLTAGE
    @test gas_elements[1].value ≈ 25.0
    @test gas_elements[2].type === CONST_RESISTOR
    @test get_fluidtags(gas_comp).NODE_Q_POS === HexFluids.COLD_GAS
    @test get_component_wet_mass(gas_comp) ≈ 20.0

    gas_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    gas_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    update_flowbehav!(gas_comp; tile = TEST_TILE, mna_state = gas_mna)
    @test gas_comp.tank.tank.state.charge ≈ 19.9

    gas_empty = make_gas_tank(initial_charge = 0.05)
    gas_empty_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    gas_empty_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    update_flowbehav!(gas_empty; tile = TEST_TILE, mna_state = gas_empty_mna)
    @test is_stalled(gas_empty.tank)
    @test can_be_moved(gas_empty)[1]

    success, _ = do_action!(gas_comp, :vent_tank)
    @test success
    @test gas_comp.tank.tank.state.charge == 0.0
    @test is_stalled(gas_comp.tank)

    liquid_comp = make_liquid_tank(initial_charge = 20.0)
    liquid_elements = produce_rel_elements(liquid_comp)
    @test length(liquid_elements) == 4
    @test liquid_elements[1].type === CONST_VOLTAGE
    @test liquid_elements[1].value > 0.0
    @test get_fluidtags(liquid_comp).NODE_Q_POS === HexFluids.MONOPROP_LIQUID
    @test get_component_wet_mass(liquid_comp) ≈ 100.0
    @test map_rotation(liquid_comp, HexFrame.S_POS) === HexFrame.Q_POS
    @test map_rotation(liquid_comp, HexFrame.R_NEG) === HexFrame.Q_NEG

    liquid_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    liquid_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    update_flowbehav!(liquid_comp; tile = TEST_TILE, mna_state = liquid_mna)
    @test liquid_comp.tank.tank.state.charge ≈ 19.9
end
