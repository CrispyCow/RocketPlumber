using Test
using Accessors
using HexFrame
using HexElements
using HexFluids
using HexComponentsAPI
using FlowEngine
using HexFlowBasicComponents
using HexFlowTankComponents

using HexElements: CONST_RESISTOR, CONST_VOLTAGE
using HexFlowTankComponents: compute_gas_pressure, tank_is_active, tank_is_auto_empty, tank_is_auto_full,
    liquid_is_sealed, gas_is_sealed,
    pressurefed_liquid_is_auto_empty, pressurefed_liquid_is_auto_full,
    pressurefed_gas_is_auto_empty, pressurefed_gas_is_auto_full_pressure,
    pressurefed_liquid_source_active, pressurefed_gas_source_active, pressurefed_liquid_path_active

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

@testset "Pressure-fed tank fragment: constructor and defaults" begin
    tank = make_pressurefed_tank().tank

    @test get_tunables(tank) isa NTuple{4, TunableProps}
    @test compute_gas_pressure(tank) ≈ 9.090909090909092

    # Default: both seal states are unsealed
    @test !liquid_is_sealed(tank)
    @test !gas_is_sealed(tank)

    # Full liquid initial charge: NOT pre-sealed, state is derived from charge
    full_tank = PressureFedTankBehavFrag(
        initial_liquid_charge = 40.0,
        initial_gas_charge = 2.0,
        max_liquid_charge = 40.0,
        max_gas_pressure = 50.0,
        gas_node = HexFrame.NODE_Q_POS
    )
    @test !liquid_is_sealed(full_tank)
    @test !gas_is_sealed(full_tank)
    @test pressurefed_liquid_is_auto_full(full_tank)
    @test !pressurefed_liquid_is_auto_empty(full_tank)
    @test compute_gas_pressure(full_tank) ≈ 50.0
end

@testset "Pressure-fed tank fragment: gas pressure formula" begin
    zero_gas = PressureFedTankBehavFrag(
        initial_liquid_charge = 20.0, initial_gas_charge = 0.0,
        max_liquid_charge = 40.0, max_gas_pressure = 50.0, gas_node = HexFrame.NODE_Q_POS
    )
    @test compute_gas_pressure(zero_gas) == 0.0

    half_pressure = PressureFedTankBehavFrag(
        initial_liquid_charge = 0.0, initial_gas_charge = 10.0,
        max_liquid_charge = 40.0, max_gas_pressure = 80.0, gas_node = HexFrame.NODE_Q_POS
    )
    @test compute_gas_pressure(half_pressure) ≈ 19.047619047619047

    negative_gas = PressureFedTankBehavFrag(
        initial_liquid_charge = 20.0, initial_gas_charge = -1.0,
        max_liquid_charge = 40.0, max_gas_pressure = 50.0, gas_node = HexFrame.NODE_Q_POS
    )
    @test compute_gas_pressure(negative_gas) ≈ -22.727272727272727
end

@testset "Pressure-fed tank fragment: derived state helpers" begin
    # Active mid-range tank
    mid = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 4.0).tank
    @test pressurefed_liquid_source_active(mid)
    @test pressurefed_gas_source_active(mid)
    @test !pressurefed_liquid_is_auto_empty(mid)
    @test !pressurefed_liquid_is_auto_full(mid)
    @test !pressurefed_gas_is_auto_empty(mid)
    @test !pressurefed_gas_is_auto_full_pressure(mid)

    # Liquid auto-empty: charge <= 0
    liq_empty = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0).tank
    @test pressurefed_liquid_is_auto_empty(liq_empty)
    @test !pressurefed_liquid_source_active(liq_empty)
    @test !pressurefed_liquid_path_active(liq_empty)
    @test pressurefed_gas_source_active(liq_empty)  # gas unaffected by liquid empty

    # Liquid auto-full: liquid source and resistor inactive; gas may or may not be overpressure
    # Use low gas charge so headspace pressure stays below max (0.5 * 50 / 2.0 = 12.5 < 50)
    liq_full = make_pressurefed_tank(liquid_charge = 40.0, gas_charge = 0.5).tank
    @test pressurefed_liquid_is_auto_full(liq_full)
    @test !pressurefed_liquid_source_active(liq_full)
    @test pressurefed_gas_source_active(liq_full)  # gas unaffected by liquid full when pressure stays low

    # Gas auto-empty: charge <= 0
    gas_empty = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 0.0).tank
    @test pressurefed_gas_is_auto_empty(gas_empty)
    @test !pressurefed_gas_source_active(gas_empty)
    @test pressurefed_liquid_source_active(gas_empty)  # liquid unaffected by gas empty

    # Gas overpressure disables both sides
    # max_gas_pressure = 50.0; at liquid_charge = 0 headspace = 1.05*40 = 42, charge = 42 => pressure = 50.0
    overpressure = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 42.0).tank
    @test pressurefed_gas_is_auto_full_pressure(overpressure)
    @test !pressurefed_gas_source_active(overpressure)
    @test !pressurefed_liquid_source_active(overpressure)  # cross-side coupling
    @test !pressurefed_liquid_path_active(overpressure)

    # Manual seals override auto-state helpers
    mid2 = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 4.0).tank
    seal!(mid2.liquid_sealstate)
    @test liquid_is_sealed(mid2)
    @test !pressurefed_liquid_is_auto_empty(mid2)  # sealed → not auto
    @test !pressurefed_liquid_source_active(mid2)

    seal!(mid2.gas_sealstate)
    @test gas_is_sealed(mid2)
    @test !pressurefed_gas_is_auto_empty(mid2)
    @test !pressurefed_gas_source_active(mid2)
end

@testset "Pressure-fed tank fragment: set_tunables preserves seal state" begin
    tank = make_pressurefed_tank().tank
    seal!(tank.liquid_sealstate)

    tuned = set_tunables(tank, (45.0, 60.0, 25.0, 3.0))
    @test tuned.max_liquid_charge == 45.0
    @test tuned.max_gas_pressure == 60.0
    @test tuned.liquid_state.charge == 25.0
    @test tuned.gas_state.charge == 3.0
    @test liquid_is_sealed(tuned)  # seal preserved
    @test !gas_is_sealed(tuned)
end

@testset "Pressure-fed tank: charge tracking" begin
    comp = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 4.0)
    tank = comp.tank

    # Normal mid-range update
    mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    mna.vsource_currents[ElementID(TEST_TILE, 2)] = 12.0
    update_flowbehav!(tank; tile = TEST_TILE, mna_state = mna)
    @test tank.liquid_state.charge ≈ 19.9
    @test tank.gas_state.charge ≈ 4.2

    # Liquid underflow: clamped to 0.0, no seal mutation
    emptying_tank = make_pressurefed_tank(liquid_charge = 0.05, gas_charge = 2.0).tank
    emptying_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    emptying_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    emptying_mna.vsource_currents[ElementID(TEST_TILE, 2)] = 60.0
    update_flowbehav!(emptying_tank; tile = TEST_TILE, mna_state = emptying_mna)
    @test emptying_tank.liquid_state.charge == 0.0
    @test emptying_tank.gas_state.charge ≈ 3.0
    @test !liquid_is_sealed(emptying_tank)  # auto-empty, not sealed
    @test pressurefed_liquid_is_auto_empty(emptying_tank)

    # Liquid overflow: clamped to max_liquid_charge, no seal mutation
    filling_tank = make_pressurefed_tank(liquid_charge = 39.95, gas_charge = 2.0).tank
    filling_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    filling_mna.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0
    filling_mna.vsource_currents[ElementID(TEST_TILE, 2)] = -60.0
    update_flowbehav!(filling_tank; tile = TEST_TILE, mna_state = filling_mna)
    @test filling_tank.liquid_state.charge == 40.0
    @test filling_tank.gas_state.charge ≈ 1.0
    @test !liquid_is_sealed(filling_tank)  # auto-full, not sealed
    @test pressurefed_liquid_is_auto_full(filling_tank)

    # Gas underflow: clamped to 0.0, liquid side unaffected
    gas_underflow = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 0.05).tank
    gas_uf_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    gas_uf_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    gas_uf_mna.vsource_currents[ElementID(TEST_TILE, 2)] = -6.0
    update_flowbehav!(gas_underflow; tile = TEST_TILE, mna_state = gas_uf_mna)
    @test gas_underflow.liquid_state.charge ≈ 14.9
    @test gas_underflow.gas_state.charge == 0.0
    @test !liquid_is_sealed(gas_underflow)
    @test !gas_is_sealed(gas_underflow)
    @test pressurefed_gas_is_auto_empty(gas_underflow)

    # Gas-only source present: liquid charge unchanged
    gas_only = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 1.0).tank
    gas_only_mna = register_vsources!(MNA_State(), TEST_TILE, 2)
    gas_only_mna.vsource_currents[ElementID(TEST_TILE, 2)] = 6.0
    update_flowbehav!(gas_only; tile = TEST_TILE, mna_state = gas_only_mna)
    @test gas_only.liquid_state.charge ≈ 15.0
    @test gas_only.gas_state.charge ≈ 1.1

    # Liquid-only source present: gas charge unchanged
    liq_only = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 1.0).tank
    liq_only_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    liq_only_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    update_flowbehav!(liq_only; tile = TEST_TILE, mna_state = liq_only_mna)
    @test liq_only.liquid_state.charge ≈ 14.9
    @test liq_only.gas_state.charge ≈ 1.0

    # Pruned sources: no update
    pruned = make_pressurefed_tank(liquid_charge = 12.0, gas_charge = 3.0).tank
    update_flowbehav!(pruned; tile = TEST_TILE, mna_state = MNA_State())
    @test pruned.liquid_state.charge ≈ 12.0
    @test pruned.gas_state.charge ≈ 3.0

    # Manually sealed liquid side ignores stale current
    liq_sealed = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 2.0).tank
    seal!(liq_sealed.liquid_sealstate)
    sealed_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    sealed_mna.vsource_currents[ElementID(TEST_TILE, 1)] = 60.0   # large inflow, should be ignored
    sealed_mna.vsource_currents[ElementID(TEST_TILE, 2)] = 6.0
    update_flowbehav!(liq_sealed; tile = TEST_TILE, mna_state = sealed_mna)
    @test liq_sealed.liquid_state.charge == 15.0  # unchanged
    @test liq_sealed.gas_state.charge ≈ 2.1  # gas still updated

    # Manually sealed gas side ignores stale current
    gas_sealed_tank = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 2.0).tank
    seal!(gas_sealed_tank.gas_sealstate)
    gas_sealed_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    gas_sealed_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    gas_sealed_mna.vsource_currents[ElementID(TEST_TILE, 2)] = 60.0  # large inflow, should be ignored
    update_flowbehav!(gas_sealed_tank; tile = TEST_TILE, mna_state = gas_sealed_mna)
    @test gas_sealed_tank.liquid_state.charge ≈ 14.9
    @test gas_sealed_tank.gas_state.charge == 2.0  # unchanged
end

@testset "Pressure-fed tank component: elements and tunables" begin
    comp = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 4.0)
    elements = produce_rel_elements(comp)

    @test length(elements) == 3
    @test elements[1].type === CONST_VOLTAGE
    @test elements[1].connections == RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.GROUND)
    @test elements[2].type === CONST_VOLTAGE
    @test elements[2].connections == RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.GROUND)
    @test elements[3].type === CONST_RESISTOR
    @test elements[3].connections == RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.NODE_Q_NEG)

    expected_gas_pressure = compute_gas_pressure(comp.tank)
    expected_liquid_pressure = 0.01 * (comp.tank.liquid_state.charge / comp.tank.max_liquid_charge * comp.tank.max_gas_pressure)
    @test elements[1].value ≈ (expected_gas_pressure + expected_liquid_pressure)
    @test elements[2].value ≈ expected_gas_pressure
    @test all(elem.active for elem in elements)

    # Gas auto-full-pressure: both sources and resistor inactive
    overpressure_comp = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 42.0)
    op_elements = produce_rel_elements(overpressure_comp)
    @test all(!elem.active for elem in op_elements)

    # Gas auto-empty: only gas source inactive; liquid side still active
    gas_empty_comp = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 0.0)
    ge_elements = produce_rel_elements(gas_empty_comp)
    @test ge_elements[1].active   # liquid vsource active
    @test !ge_elements[2].active  # gas vsource inactive
    @test ge_elements[3].active   # liquid resistor active

    # Liquid auto-empty: liquid source and resistor inactive, gas active
    liq_empty_comp = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0)
    le_elements = produce_rel_elements(liq_empty_comp)
    @test !le_elements[1].active  # liquid vsource inactive
    @test le_elements[2].active   # gas vsource active
    @test !le_elements[3].active  # liquid resistor inactive

    # Liquid auto-full: liquid source and resistor inactive, gas active (low gas charge to avoid overpressure)
    liq_full_comp = make_pressurefed_tank(liquid_charge = 40.0, gas_charge = 0.5)
    lf_elements = produce_rel_elements(liq_full_comp)
    @test !lf_elements[1].active
    @test lf_elements[2].active
    @test !lf_elements[3].active

    tunables = get_tunables(comp)
    @test tunables isa NTuple{5, TunableProps}
    tuned_comp = set_tunables(comp, (50.0, 70.0, 15.0, 5.0, 8.0))
    @test tuned_comp.tank.max_liquid_charge == 50.0
    @test tuned_comp.tank.max_gas_pressure == 70.0
    @test tuned_comp.tank.liquid_state.charge == 15.0
    @test tuned_comp.tank.gas_state.charge == 5.0
    @test tuned_comp.series_conductance == 8.0

    decls = produce_rel_fluid_declarations(comp)
    @test length(decls) == 2
    @test decls[1] === RelativeFluidDeclaration(HexFrame.NODE_Q_POS, FluidSource(HexFluids.COLD_GAS, 300.0))
    @test decls[2] === RelativeFluidDeclaration(HexFrame.NODE_INTERNAL, FluidSource(HexFluids.MONOPROP_LIQUID, 300.0))

    @test map_rotation(comp, HexFrame.R_POS) === HexFrame.Q_POS

    liquid_density = HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64
    gas_density = HexFluids.lookup_fluid_density(HexFluids.COLD_GAS)::Float64
    @test get_component_wet_mass(comp) ≈ (20.0 * liquid_density + 4.0 * gas_density)
    @test get_component_wet_mass(comp; fluid = HexFluids.MONOPROP_LIQUID) ≈ 20.0 * liquid_density
    @test get_component_wet_mass(comp; fluid = HexFluids.COLD_GAS) ≈ 4.0 * gas_density
    comp.tank.gas_state.charge = -2.0
    @test get_component_wet_mass(comp; fluid = HexFluids.COLD_GAS) == 0.0

    # Movement: only when both charges are zero
    @test !can_be_moved(make_pressurefed_tank(liquid_charge = 10.0, gas_charge = 0.0))[1]
    @test !can_be_moved(make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 1.0))[1]
    @test can_be_moved(make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 0.0))[1]
    # Manually sealed still not movable if charge present
    sealed_movable = make_pressurefed_tank(liquid_charge = 39.0, gas_charge = 0.0)
    seal!(sealed_movable.tank.liquid_sealstate)
    @test !can_be_moved(sealed_movable)[1]
end

@testset "Pressure-fed tank: actions" begin
    tank = make_pressurefed_tank(liquid_charge = 12.0, gas_charge = 3.0).tank
    actions = get_actions(tank)
    @test length(actions) == 5
    @test all(action isa ActionInfo for action in actions)
    ids = [a.id for a in actions]
    @test :vent_and_seal_gas in ids
    @test :vent_and_seal_liquid in ids
    @test :seal_both in ids
    @test :unseal_gas in ids
    @test :unseal_liquid in ids

    # Vent and Seal Gas: zeroes gas charge and seals gas side only
    success, msg = do_action!(tank, :vent_and_seal_gas)
    @test success
    @test tank.gas_state.charge == 0.0
    @test gas_is_sealed(tank)
    @test !liquid_is_sealed(tank)  # liquid side unaffected
    @test msg == "Gas vented and sealed"

    # Unseal Gas: clears gas seal
    success2, _ = do_action!(tank, :unseal_gas)
    @test success2
    @test !gas_is_sealed(tank)

    # Vent and Seal Liquid: zeroes liquid charge and seals liquid side only
    success3, msg3 = do_action!(tank, :vent_and_seal_liquid)
    @test success3
    @test tank.liquid_state.charge == 0.0
    @test liquid_is_sealed(tank)
    @test !gas_is_sealed(tank)  # gas side unaffected
    @test msg3 == "Liquid vented and sealed"

    # Unseal Liquid: clears liquid seal
    success4, _ = do_action!(tank, :unseal_liquid)
    @test success4
    @test !liquid_is_sealed(tank)

    # Seal Both: seals both without changing charge
    tank2 = make_pressurefed_tank(liquid_charge = 12.0, gas_charge = 3.0).tank
    success5, _ = do_action!(tank2, :seal_both)
    @test success5
    @test liquid_is_sealed(tank2)
    @test gas_is_sealed(tank2)
    @test tank2.liquid_state.charge == 12.0  # charge preserved
    @test tank2.gas_state.charge == 3.0

    # Unseal both sides independently
    do_action!(tank2, :unseal_liquid)
    @test !liquid_is_sealed(tank2)
    @test gas_is_sealed(tank2)
    do_action!(tank2, :unseal_gas)
    @test !gas_is_sealed(tank2)

    # Unrecognised action
    result, _ = do_action!(tank, :nonexistent)
    @test !result
end

@testset "Pressure-fed tank: reactivation probe get" begin
    # Both sides active: no probe
    mid = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 4.0)
    @test isnothing(get_reactivation_probe(mid))

    # Liquid auto-empty: probe with liquid active, gas inactive
    liq_empty = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0)
    probe_le = get_reactivation_probe(liq_empty)
    @test probe_le isa ReactivationProbe
    @test length(probe_le.rel_elements) == 3
    @test probe_le.rel_elements[1].active   # liquid vsource
    @test !probe_le.rel_elements[2].active  # gas vsource inactive
    @test probe_le.rel_elements[3].active   # resistor follows liquid

    # Liquid auto-full: probe with liquid active, gas inactive (low gas charge to avoid overpressure)
    liq_full = make_pressurefed_tank(liquid_charge = 40.0, gas_charge = 0.5)
    probe_lf = get_reactivation_probe(liq_full)
    @test probe_lf isa ReactivationProbe
    @test probe_lf.rel_elements[1].active
    @test !probe_lf.rel_elements[2].active
    @test probe_lf.rel_elements[3].active

    # Gas auto-empty: probe with gas active, liquid inactive
    gas_empty = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 0.0)
    probe_ge = get_reactivation_probe(gas_empty)
    @test probe_ge isa ReactivationProbe
    @test !probe_ge.rel_elements[1].active  # liquid vsource inactive
    @test probe_ge.rel_elements[2].active   # gas vsource
    @test !probe_ge.rel_elements[3].active  # resistor inactive when liquid not probed

    # Gas overpressure: both sides probed
    overpressure = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 42.0)
    probe_op = get_reactivation_probe(overpressure)
    @test probe_op isa ReactivationProbe
    @test probe_op.rel_elements[1].active   # liquid probed
    @test probe_op.rel_elements[2].active   # gas probed
    @test probe_op.rel_elements[3].active   # resistor follows liquid

    # Manually sealed sides: no probe for sealed side
    liq_empty_gas_sealed = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0)
    seal!(liq_empty_gas_sealed.tank.gas_sealstate)  # gas sealed (not auto-disconnected)
    probe_partial = get_reactivation_probe(liq_empty_gas_sealed)
    @test probe_partial isa ReactivationProbe
    @test probe_partial.rel_elements[1].active  # liquid probed
    @test !probe_partial.rel_elements[2].active  # gas sealed → not probed

    # Both sides manually sealed: no probe
    both_sealed = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 4.0)
    seal!(both_sealed.tank.liquid_sealstate)
    seal!(both_sealed.tank.gas_sealstate)
    @test isnothing(get_reactivation_probe(both_sealed))
end

@testset "Pressure-fed tank: reactivation probe accept" begin
    "Build a DerivedMapState and MNA_State with a registered vsource for accept tests."
    function setup_pf_probe(comp, tile::TileCoord, index::Int, current::Float64; rotation = HexFrame.Q_POS)
        (frag_liq, frag_gas) = produce_rel_elements(comp.tank)
        frag = index == 1 ? frag_liq : frag_gas
        active_frag = @set frag.active = true
        abs_elem = map_element(active_frag, tile, index, rotation)
        dm = DerivedMapState()
        push!(dm.filteredelements, abs_elem)
        mna = MNA_State()
        mna.vsource_currents[abs_elem.id] = current
        return dm, mna
    end

    # Liquid auto-empty: accept positive inflow, reject outflow
    liq_empty = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0)
    dm_pos, mna_pos = setup_pf_probe(liq_empty, TEST_TILE, 1, 5.0)
    @test accept_reactivation_probe!(liq_empty; tile = TEST_TILE, derivedmapstate = dm_pos, mna_state = mna_pos)
    @test liq_empty.tank.liquid_state.charge == 0.0  # no mutation on accept

    liq_empty2 = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0)
    dm_neg, mna_neg = setup_pf_probe(liq_empty2, TEST_TILE, 1, -5.0)
    @test !accept_reactivation_probe!(liq_empty2; tile = TEST_TILE, derivedmapstate = dm_neg, mna_state = mna_neg)

    # Liquid auto-full: accept negative outflow, reject inflow (low gas charge to avoid overpressure)
    liq_full = make_pressurefed_tank(liquid_charge = 40.0, gas_charge = 0.5)
    dm_full_neg, mna_full_neg = setup_pf_probe(liq_full, TEST_TILE, 1, -5.0)
    @test accept_reactivation_probe!(liq_full; tile = TEST_TILE, derivedmapstate = dm_full_neg, mna_state = mna_full_neg)
    @test liq_full.tank.liquid_state.charge == 40.0  # no mutation

    liq_full2 = make_pressurefed_tank(liquid_charge = 40.0, gas_charge = 0.5)
    dm_full_pos, mna_full_pos = setup_pf_probe(liq_full2, TEST_TILE, 1, 5.0)
    @test !accept_reactivation_probe!(liq_full2; tile = TEST_TILE, derivedmapstate = dm_full_pos, mna_state = mna_full_pos)

    # Gas auto-empty: accept positive inflow
    gas_empty = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 0.0)
    dm_ge_pos, mna_ge_pos = setup_pf_probe(gas_empty, TEST_TILE, 2, 5.0)
    @test accept_reactivation_probe!(gas_empty; tile = TEST_TILE, derivedmapstate = dm_ge_pos, mna_state = mna_ge_pos)
    @test gas_empty.tank.gas_state.charge == 0.0  # no mutation

    # Pruned element: reject
    liq_empty_pruned = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0)
    @test !accept_reactivation_probe!(liq_empty_pruned; tile = TEST_TILE, derivedmapstate = DerivedMapState(), mna_state = MNA_State())

    # Gas overpressure: accept when gas outflow is useful; reject if harmful
    overpressure = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 42.0)
    dm_op_gas, mna_op_gas = setup_pf_probe(overpressure, TEST_TILE, 2, -5.0)  # gas outflow: useful
    # Must also register the liquid vsource since both sides are probed
    (frag_liq, _) = produce_rel_elements(overpressure.tank)
    active_liq = @set frag_liq.active = true
    abs_liq = map_element(active_liq, TEST_TILE, 1, HexFrame.Q_POS)
    push!(dm_op_gas.filteredelements, abs_liq)
    mna_op_gas.vsource_currents[abs_liq.id] = 0.0  # liquid neutral
    @test accept_reactivation_probe!(overpressure; tile = TEST_TILE, derivedmapstate = dm_op_gas, mna_state = mna_op_gas)
end

@testset "Existing tank regression coverage" begin
    gas_comp = make_gas_tank(initial_charge = 20.0)
    gas_elements = produce_rel_elements(gas_comp)
    @test length(gas_elements) == 4
    @test gas_elements[1].type === CONST_VOLTAGE
    @test gas_elements[1].value ≈ 25.0  # bounded linear: 20/40 * 50
    @test gas_elements[2].type === CONST_RESISTOR
    gas_decls = produce_rel_fluid_declarations(gas_comp)
    @test length(gas_decls) == 1
    @test gas_decls[1] === RelativeFluidDeclaration(HexFrame.NODE_INTERNAL, FluidSource(HexFluids.COLD_GAS, 300.0))
    @test get_component_wet_mass(gas_comp) ≈ 20.0

    gas_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    gas_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    update_flowbehav!(gas_comp; tile = TEST_TILE, mna_state = gas_mna)
    @test gas_comp.tank.tank.state.charge ≈ 19.9

    # Near-empty: clamps to zero and becomes auto-disconnected (not stalled)
    gas_near_empty = make_gas_tank(initial_charge = 0.05)
    gas_near_empty_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    gas_near_empty_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    update_flowbehav!(gas_near_empty; tile = TEST_TILE, mna_state = gas_near_empty_mna)
    @test gas_near_empty.tank.tank.state.charge == 0.0
    @test can_be_moved(gas_near_empty)[1]  # movable when empty

    # Vent and Seal action empties and seals
    success, _ = do_action!(gas_comp, :vent_and_seal)
    @test success
    @test gas_comp.tank.tank.state.charge == 0.0
    @test is_sealed(gas_comp.tank.tank.sealstate)

    liquid_comp = make_liquid_tank(initial_charge = 20.0)
    liquid_elements = produce_rel_elements(liquid_comp)
    @test length(liquid_elements) == 4
    @test liquid_elements[1].type === CONST_VOLTAGE
    @test liquid_elements[1].value > 0.0
    liq_decls = produce_rel_fluid_declarations(liquid_comp)
    @test length(liq_decls) == 1
    @test liq_decls[1] === RelativeFluidDeclaration(HexFrame.NODE_INTERNAL, FluidSource(HexFluids.MONOPROP_LIQUID, 300.0))
    @test get_component_wet_mass(liquid_comp) ≈ 100.0
    @test map_rotation(liquid_comp, HexFrame.S_POS) === HexFrame.Q_POS
    @test map_rotation(liquid_comp, HexFrame.R_NEG) === HexFrame.Q_NEG

    liquid_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    liquid_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    update_flowbehav!(liquid_comp; tile = TEST_TILE, mna_state = liquid_mna)
    @test liquid_comp.tank.tank.state.charge ≈ 19.9
end

# ===============================================================
# Thevinin Tank (SealState + New Semantics)
# ===============================================================

@testset "SealStateBehavFrag" begin
    s = SealStateBehavFrag()
    @test !is_sealed(s)

    seal!(s)
    @test is_sealed(s)

    unseal!(s)
    @test !is_sealed(s)
end

@testset "TankBehavFrag derived state helpers" begin
    connection = RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.GROUND)

    mid_tank = TankBehavFrag(connection = connection, max_charge = 40.0, max_voltage = 50.0, initial_charge = 20.0)
    @test tank_is_active(mid_tank)
    @test !tank_is_auto_empty(mid_tank)
    @test !tank_is_auto_full(mid_tank)

    empty_tank = TankBehavFrag(connection = connection, max_charge = 40.0, max_voltage = 50.0, initial_charge = 0.0)
    @test !tank_is_active(empty_tank)
    @test tank_is_auto_empty(empty_tank)
    @test !tank_is_auto_full(empty_tank)

    full_tank = TankBehavFrag(connection = connection, max_charge = 40.0, max_voltage = 50.0, initial_charge = 40.0)
    @test !tank_is_active(full_tank)
    @test !tank_is_auto_empty(full_tank)
    @test tank_is_auto_full(full_tank)

    # Sealed tanks are never auto-empty or auto-full — they are manually sealed
    seal!(empty_tank.sealstate)
    @test !tank_is_active(empty_tank)
    @test !tank_is_auto_empty(empty_tank)
    @test !tank_is_auto_full(empty_tank)
end

@testset "ThevininTankCompBehav: constructor defaults and active/inactive elements" begin
    # Default sealstate is unsealed
    gas = make_gas_tank(initial_charge = 20.0)
    @test !is_sealed(gas.tank.tank.sealstate)

    # Mid-range: active voltage source
    gas_elems = produce_rel_elements(gas)
    @test gas_elems[1].active
    @test gas_elems[1].type === CONST_VOLTAGE

    # Zero charge (auto-empty): inactive voltage source
    gas_empty = make_gas_tank(initial_charge = 0.0)
    empty_elems = produce_rel_elements(gas_empty)
    @test !empty_elems[1].active

    # Full charge (auto-full): inactive voltage source
    gas_full = make_gas_tank(initial_charge = 40.0)
    full_elems = produce_rel_elements(gas_full)
    @test !full_elems[1].active

    # Manually sealed: inactive regardless of charge
    sealed_gas = make_gas_tank(initial_charge = 20.0)
    seal!(sealed_gas.tank.tank.sealstate)
    sealed_elems = produce_rel_elements(sealed_gas)
    @test !sealed_elems[1].active
end

@testset "GasTankBehavFrag voltage curve (bounded linear)" begin
    gas = make_gas_tank(initial_charge = 20.0)  # max_charge=40, max_voltage=50
    (vsource,) = produce_rel_elements(gas.tank)
    @test vsource.value ≈ 25.0  # 20/40 * 50 = 25
    @test vsource.active

    gas_full = make_gas_tank(initial_charge = 40.0)
    (vsource_full,) = produce_rel_elements(gas_full.tank)
    @test vsource_full.value ≈ 50.0  # 40/40 * 50 = 50

    gas_zero = make_gas_tank(initial_charge = 0.0)
    (vsource_zero,) = produce_rel_elements(gas_zero.tank)
    @test vsource_zero.value ≈ 0.0  # 0/40 * 50 = 0
end

@testset "LiquidTankBehavFrag voltage curve (bounded nonlinear)" begin
    liq = make_liquid_tank(initial_charge = 40.0)  # max_charge=40, max_voltage=1.0
    (vsource_full,) = produce_rel_elements(liq.tank)
    f(x; steepness = 9.0) = 1 - (1 - x)^steepness
    expected_full = 1.0 * f(1.0)
    @test vsource_full.value ≈ expected_full

    liq_half = make_liquid_tank(initial_charge = 20.0)
    (vsource_half,) = produce_rel_elements(liq_half.tank)
    expected_half = 1.0 * f(0.5)
    @test vsource_half.value ≈ expected_half

    liq_zero = make_liquid_tank(initial_charge = 0.0)
    (vsource_zero,) = produce_rel_elements(liq_zero.tank)
    @test vsource_zero.value ≈ 0.0

    # Voltage must stay in [0, max_voltage]
    @test 0.0 ≤ vsource_full.value ≤ 1.0
    @test 0.0 ≤ vsource_half.value ≤ 1.0
end

@testset "ThevininTankCompBehav: update_flowbehav! charge clamping" begin
    # Normal mid-range update
    gas = make_gas_tank(initial_charge = 20.0)
    mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0  # outflow
    update_flowbehav!(gas; tile = TEST_TILE, mna_state = mna)
    @test gas.tank.tank.state.charge ≈ 19.9

    # Underflow clamps to zero
    gas_near_empty = make_gas_tank(initial_charge = 0.05)
    mna_empty = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna_empty.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    update_flowbehav!(gas_near_empty; tile = TEST_TILE, mna_state = mna_empty)
    @test gas_near_empty.tank.tank.state.charge == 0.0

    # Overflow clamps to max_charge
    gas_near_full = make_gas_tank(initial_charge = 39.95)
    mna_full = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna_full.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0  # inflow
    update_flowbehav!(gas_near_full; tile = TEST_TILE, mna_state = mna_full)
    @test gas_near_full.tank.tank.state.charge == 40.0

    # Sealed tanks ignore stale current even when source is present
    gas_sealed = make_gas_tank(initial_charge = 20.0)
    seal!(gas_sealed.tank.tank.sealstate)
    mna_sealed = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna_sealed.vsource_currents[ElementID(TEST_TILE, 1)] = -60.0
    update_flowbehav!(gas_sealed; tile = TEST_TILE, mna_state = mna_sealed)
    @test gas_sealed.tank.tank.state.charge == 20.0  # unchanged

    # Pruned source: no update
    gas_pruned = make_gas_tank(initial_charge = 20.0)
    update_flowbehav!(gas_pruned; tile = TEST_TILE, mna_state = MNA_State())
    @test gas_pruned.tank.tank.state.charge == 20.0

    # Auto-empty (charge == 0): accepts probe current when vsource is present
    gas_boundary = make_gas_tank(initial_charge = 0.0)
    mna_boundary = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna_boundary.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0  # inflow from accepted probe
    update_flowbehav!(gas_boundary; tile = TEST_TILE, mna_state = mna_boundary)
    @test gas_boundary.tank.tank.state.charge > 0.0  # moved off boundary
end

@testset "ThevininTankCompBehav: actions" begin
    gas = make_gas_tank(initial_charge = 20.0)
    actions = get_actions(gas)
    @test length(actions) == 3
    @test all(a isa ActionInfo for a in actions)
    ids = [a.id for a in actions]
    @test :vent_and_seal in ids
    @test :seal_tank in ids
    @test :unseal_tank in ids

    # Vent and Seal: empties tank and seals it
    success, msg = do_action!(gas, :vent_and_seal)
    @test success
    @test gas.tank.tank.state.charge == 0.0
    @test is_sealed(gas.tank.tank.sealstate)
    @test msg == "Tank vented and sealed"

    # Unseal: clears seal
    success2, _ = do_action!(gas, :unseal_tank)
    @test success2
    @test !is_sealed(gas.tank.tank.sealstate)

    # Seal Tank: seals without venting
    gas2 = make_gas_tank(initial_charge = 25.0)
    success3, _ = do_action!(gas2, :seal_tank)
    @test success3
    @test is_sealed(gas2.tank.tank.sealstate)
    @test gas2.tank.tank.state.charge == 25.0  # charge unchanged

    # Unseal via action
    success4, _ = do_action!(gas2, :unseal_tank)
    @test success4
    @test !is_sealed(gas2.tank.tank.sealstate)

    # can_be_moved: based on charge only
    @test !can_be_moved(gas2)[1]  # has charge
    gas3 = make_gas_tank(initial_charge = 0.0)
    @test can_be_moved(gas3)[1]

    # Sealed tank with charge: still not movable
    seal!(gas2.tank.tank.sealstate)
    @test !can_be_moved(gas2)[1]
end

@testset "ThevininTankCompBehav: reactivation probe (get)" begin
    # Active mid-range: no probe
    gas_mid = make_gas_tank(initial_charge = 20.0)
    @test isnothing(get_reactivation_probe(gas_mid))

    # Auto-empty: probe requested
    gas_empty = make_gas_tank(initial_charge = 0.0)
    probe = get_reactivation_probe(gas_empty)
    @test probe isa ReactivationProbe
    @test length(probe.rel_elements) == 1
    @test probe.rel_elements[1].active

    # Auto-full: probe requested
    gas_full = make_gas_tank(initial_charge = 40.0)
    probe_full = get_reactivation_probe(gas_full)
    @test probe_full isa ReactivationProbe

    # Manually sealed: no probe regardless of charge
    gas_sealed_empty = make_gas_tank(initial_charge = 0.0)
    seal!(gas_sealed_empty.tank.tank.sealstate)
    @test isnothing(get_reactivation_probe(gas_sealed_empty))

    gas_sealed_full = make_gas_tank(initial_charge = 40.0)
    seal!(gas_sealed_full.tank.tank.sealstate)
    @test isnothing(get_reactivation_probe(gas_sealed_full))

    # Liquid tank same behaviour
    liq_empty = make_liquid_tank(initial_charge = 0.0)
    @test get_reactivation_probe(liq_empty) isa ReactivationProbe

    liq_full = make_liquid_tank(initial_charge = 40.0)
    @test get_reactivation_probe(liq_full) isa ReactivationProbe

    liq_mid = make_liquid_tank(initial_charge = 20.0)
    @test isnothing(get_reactivation_probe(liq_mid))
end

@testset "ThevininTankCompBehav: reactivation probe (accept)" begin
    "Build DerivedMapState and MNA_State for accept_reactivation_probe! tests."
    function setup_probe_accept(behav, tile::TileCoord, current::Float64; rotation::HexAxis = HexFrame.Q_POS)
        (rel_vsource,) = produce_rel_elements(behav)
        active_vsource = @set rel_vsource.active = true
        abs_vsource = map_element(active_vsource, tile, 1, rotation)

        derivedmapstate = DerivedMapState()
        push!(derivedmapstate.filteredelements, abs_vsource)

        mna_state = MNA_State()
        mna_state.vsource_currents[abs_vsource.id] = current
        return derivedmapstate, mna_state
    end

    probe_tol = 1e-9

    # --- Empty tank ---
    gas_empty = make_gas_tank(initial_charge = 0.0)

    # Pruned element: reject
    pruned_dm = DerivedMapState()
    pruned_mna = MNA_State()
    @test !accept_reactivation_probe!(gas_empty; tile = TEST_TILE, derivedmapstate = pruned_dm, mna_state = pruned_mna)

    # Positive inflow: accept
    dm_pos, mna_pos = setup_probe_accept(gas_empty.tank, TEST_TILE, 5.0)
    @test accept_reactivation_probe!(gas_empty; tile = TEST_TILE, derivedmapstate = dm_pos, mna_state = mna_pos)
    @test gas_empty.tank.tank.state.charge == 0.0  # no mutation on accept

    # Negative current (outflow): reject
    dm_neg, mna_neg = setup_probe_accept(gas_empty.tank, TEST_TILE, -5.0)
    @test !accept_reactivation_probe!(gas_empty; tile = TEST_TILE, derivedmapstate = dm_neg, mna_state = mna_neg)

    # Neutral current (below tolerance): reject
    dm_neut, mna_neut = setup_probe_accept(gas_empty.tank, TEST_TILE, probe_tol / 2)
    @test !accept_reactivation_probe!(gas_empty; tile = TEST_TILE, derivedmapstate = dm_neut, mna_state = mna_neut)

    # --- Full tank ---
    gas_full = make_gas_tank(initial_charge = 40.0)

    # Negative outflow: accept
    dm_neg_full, mna_neg_full = setup_probe_accept(gas_full.tank, TEST_TILE, -5.0)
    @test accept_reactivation_probe!(gas_full; tile = TEST_TILE, derivedmapstate = dm_neg_full, mna_state = mna_neg_full)
    @test gas_full.tank.tank.state.charge == 40.0  # no mutation on accept

    # Positive inflow: reject
    dm_pos_full, mna_pos_full = setup_probe_accept(gas_full.tank, TEST_TILE, 5.0)
    @test !accept_reactivation_probe!(gas_full; tile = TEST_TILE, derivedmapstate = dm_pos_full, mna_state = mna_pos_full)

    # Neutral current: reject
    dm_neut_full, mna_neut_full = setup_probe_accept(gas_full.tank, TEST_TILE, -(probe_tol / 2))
    @test !accept_reactivation_probe!(gas_full; tile = TEST_TILE, derivedmapstate = dm_neut_full, mna_state = mna_neut_full)
end

@testset "ThevininTankCompBehav: component tunables and declarations" begin
    gas = make_gas_tank(initial_charge = 20.0)
    tunables = get_tunables(gas)
    @test tunables isa NTuple{4, TunableProps}

    tuned = set_tunables(gas, (45.0, 60.0, 15.0, 8.0))
    @test tuned.tank.tank.max_charge == 45.0
    @test tuned.tank.tank.max_voltage == 60.0
    @test tuned.tank.tank.state.charge == 15.0
    @test tuned.series_conductance == 8.0

    gas_decls = produce_rel_fluid_declarations(gas)
    @test length(gas_decls) == 1
    @test gas_decls[1] === RelativeFluidDeclaration(HexFrame.NODE_INTERNAL, FluidSource(HexFluids.COLD_GAS, 300.0))

    liq = make_liquid_tank(initial_charge = 20.0)
    liq_decls = produce_rel_fluid_declarations(liq)
    @test length(liq_decls) == 1
    @test liq_decls[1] === RelativeFluidDeclaration(HexFrame.NODE_INTERNAL, FluidSource(HexFluids.MONOPROP_LIQUID, 300.0))

    # Wet mass
    @test get_component_wet_mass(gas) ≈ 20.0  # COLD_GAS density 1.0 kg/L
    liq_density = HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64
    @test get_component_wet_mass(liq) ≈ 20.0 * liq_density

    # map_rotation: liquid flips, gas does not restrict
    @test map_rotation(liq, HexFrame.S_POS) === HexFrame.Q_POS
    @test map_rotation(liq, HexFrame.R_NEG) === HexFrame.Q_NEG
end
