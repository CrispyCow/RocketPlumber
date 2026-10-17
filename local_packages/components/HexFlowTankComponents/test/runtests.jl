#=
Scope: Tank component behaviour tests
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using Accessors
using HexFrame
using HexElements
using HexFluids
using HexComponentsAPI
using FlowEngine
using HexFlowBasicComponents
using HexFlowTankComponents

const TEST_TILE = TileCoord(3, -2)

"Construct a dummy absolute voltage source entry for MNA_State tests."
function make_vsource(tile::TileCoord, index::Integer)
    connections = AbsoluteElementConnections(
        NodeCoord(tile, HexFrame.NODE_Q_POS),
        NodeCoord(tile, HexFrame.GROUND)
    )
    return AbsoluteElement(connections, 0.0, HexElements.CONST_VOLTAGE, ElementID(tile, index))
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
function make_pressurefed_tank(; liquid_charge::Float64 = 20.0, gas_charge::Float64 = 4.0, max_liquid_charge::Float64 = 40.0, max_gas_pressure::Float64 = 50.0, series_conductance::Float64 = 5.0, liquid_fluid::FluidType = HexFluids.MONOPROP_LIQUID)
    tank = PressureFedTankBehavFrag(
        initial_liquid_charge = liquid_charge,
        initial_gas_charge = gas_charge,
        max_liquid_charge = max_liquid_charge,
        max_gas_pressure = max_gas_pressure,
        gas_node = HexFrame.NODE_Q_POS,
        initial_liquid_fluid = liquid_fluid
    )
    return PressureFedTankCompBehav(
        tank,
        (HexFrame.NODE_Q_NEG,),
        series_conductance,
        HexFluids.COLD_GAS,
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
function make_liquid_tank(; initial_charge::Float64 = 20.0, fluid::FluidType = HexFluids.MONOPROP_LIQUID)
    return ThevininTankCompBehav(
        LiquidTankBehavFrag,
        3;
        fluid = fluid,
        max_charge = 40.0,
        max_voltage = 1.0,
        initial_charge = initial_charge,
        series_conductance = 5.0
    )
end

@testset "Pressure-fed tank fragment: constructor and defaults" begin
    tank = make_pressurefed_tank().tank

    @test get_tunables(tank) isa NTuple{4, TunableProps}
    @test HexFlowTankComponents.compute_gas_pressure(tank) ≈ 16.666666666666668

    # Default: both seal states are unsealed
    @test !liquid_is_sealed(tank)
    @test !gas_is_sealed(tank)

    # Stored liquid is seeded from initial_liquid_fluid when charge is positive
    @test get_stored_fluid(tank.stored_liquid) === HexFluids.MONOPROP_LIQUID

    # Full liquid initial charge: NOT pre-sealed, state is derived from charge
    full_tank = PressureFedTankBehavFrag(
        initial_liquid_charge = 40.0,
        initial_gas_charge = 2.0,
        max_liquid_charge = 40.0,
        max_gas_pressure = 50.0,
        gas_node = HexFrame.NODE_Q_POS,
        initial_liquid_fluid = HexFluids.MONOPROP_LIQUID
    )
    @test !liquid_is_sealed(full_tank)
    @test !gas_is_sealed(full_tank)
    @test pressurefed_liquid_is_auto_full(full_tank)
    @test !pressurefed_liquid_is_auto_empty(full_tank)
    @test HexFlowTankComponents.compute_gas_pressure(full_tank) ≈ 50.0
    @test get_stored_fluid(full_tank.stored_liquid) === HexFluids.MONOPROP_LIQUID

    # Zero liquid charge: stored_liquid is nothing even when initial_liquid_fluid is supplied
    empty_tank = PressureFedTankBehavFrag(
        initial_liquid_charge = 0.0,
        initial_gas_charge = 2.0,
        max_liquid_charge = 40.0,
        max_gas_pressure = 50.0,
        gas_node = HexFrame.NODE_Q_POS,
        initial_liquid_fluid = HexFluids.MONOPROP_LIQUID
    )
    @test isnothing(get_stored_fluid(empty_tank.stored_liquid))
end

@testset "Pressure-fed tank fragment: gas pressure formula" begin
    zero_gas = PressureFedTankBehavFrag(
        initial_liquid_charge = 20.0, initial_gas_charge = 0.0,
        max_liquid_charge = 40.0, max_gas_pressure = 50.0, gas_node = HexFrame.NODE_Q_POS
    )
    @test HexFlowTankComponents.compute_gas_pressure(zero_gas) == 0.0

    empty_tank = PressureFedTankBehavFrag(
        initial_liquid_charge = 0.0, initial_gas_charge = 10.0,
        max_liquid_charge = 40.0, max_gas_pressure = 80.0, gas_node = HexFrame.NODE_Q_POS
    )
    @test HexFlowTankComponents.compute_gas_pressure(empty_tank) ≈ 36.36363636363637

    # One unit of gas charge supports two units of liquid displacement after the fixed 5% starting headspace.
    full_tank = make_pressurefed_tank(liquid_charge = 40.0, gas_charge = 2.0).tank
    half_full_tank = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 12.0).tank
    drained_tank = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 22.0).tank
    @test HexFlowTankComponents.compute_gas_pressure(full_tank) ≈ 50.0
    @test HexFlowTankComponents.compute_gas_pressure(half_full_tank) ≈ 50.0
    @test HexFlowTankComponents.compute_gas_pressure(drained_tank) ≈ 50.0

    negative_gas = PressureFedTankBehavFrag(
        initial_liquid_charge = 20.0, initial_gas_charge = -1.0,
        max_liquid_charge = 40.0, max_gas_pressure = 50.0, gas_node = HexFrame.NODE_Q_POS
    )
    @test HexFlowTankComponents.compute_gas_pressure(negative_gas) ≈ -41.666666666666664
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
    # At liquid_charge = 0, effective headspace = 5% * 40 + 40 / 2 = 22, so charge 22 reaches max pressure.
    overpressure = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 22.0).tank
    @test pressurefed_gas_is_auto_full_pressure(overpressure)
    @test !pressurefed_gas_source_active(overpressure)
    @test !pressurefed_liquid_source_active(overpressure)  # cross-side coupling
    @test !pressurefed_liquid_path_active(overpressure)

    # Manual seals override auto-state helpers
    mid2 = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 4.0).tank
    mid2 = @set mid2.liquid_sealstate = seal(mid2.liquid_sealstate)
    @test liquid_is_sealed(mid2)
    @test !pressurefed_liquid_is_auto_empty(mid2)  # sealed → not auto
    @test !pressurefed_liquid_source_active(mid2)

    mid2 = @set mid2.gas_sealstate = seal(mid2.gas_sealstate)
    @test gas_is_sealed(mid2)
    @test !pressurefed_gas_is_auto_empty(mid2)
    @test !pressurefed_gas_source_active(mid2)
end

@testset "Pressure-fed tank fragment: set_tunables preserves seal state" begin
    tank = make_pressurefed_tank().tank
    tank = @set tank.liquid_sealstate = seal(tank.liquid_sealstate)

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
    tank = update_flowbehav(tank; tile = TEST_TILE, mna_state = mna)
    @test tank.liquid_state.charge ≈ 19.9
    @test tank.gas_state.charge ≈ 4.2

    # Liquid underflow: clamped to 0.0, no seal mutation
    emptying_tank = make_pressurefed_tank(liquid_charge = 0.05, gas_charge = 2.0).tank
    emptying_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    emptying_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    emptying_mna.vsource_currents[ElementID(TEST_TILE, 2)] = 60.0
    emptying_tank = update_flowbehav(emptying_tank; tile = TEST_TILE, mna_state = emptying_mna)
    @test emptying_tank.liquid_state.charge == 0.0
    @test emptying_tank.gas_state.charge ≈ 3.0
    @test !liquid_is_sealed(emptying_tank)  # auto-empty, not sealed
    @test pressurefed_liquid_is_auto_empty(emptying_tank)

    # Liquid overflow: clamped to max_liquid_charge, no seal mutation
    filling_tank = make_pressurefed_tank(liquid_charge = 39.95, gas_charge = 2.0).tank
    filling_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    filling_mna.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0
    filling_mna.vsource_currents[ElementID(TEST_TILE, 2)] = -60.0
    filling_tank = update_flowbehav(filling_tank; tile = TEST_TILE, mna_state = filling_mna)
    @test filling_tank.liquid_state.charge == 40.0
    @test filling_tank.gas_state.charge ≈ 1.0
    @test !liquid_is_sealed(filling_tank)  # auto-full, not sealed
    @test pressurefed_liquid_is_auto_full(filling_tank)

    # Gas underflow: clamped to 0.0, liquid side unaffected
    gas_underflow = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 0.05).tank
    gas_uf_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    gas_uf_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    gas_uf_mna.vsource_currents[ElementID(TEST_TILE, 2)] = -6.0
    gas_underflow = update_flowbehav(gas_underflow; tile = TEST_TILE, mna_state = gas_uf_mna)
    @test gas_underflow.liquid_state.charge ≈ 14.9
    @test gas_underflow.gas_state.charge == 0.0
    @test !liquid_is_sealed(gas_underflow)
    @test !gas_is_sealed(gas_underflow)
    @test pressurefed_gas_is_auto_empty(gas_underflow)

    # Gas-only source present: liquid charge unchanged
    gas_only = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 1.0).tank
    gas_only_mna = register_vsources!(MNA_State(), TEST_TILE, 2)
    gas_only_mna.vsource_currents[ElementID(TEST_TILE, 2)] = 6.0
    gas_only = update_flowbehav(gas_only; tile = TEST_TILE, mna_state = gas_only_mna)
    @test gas_only.liquid_state.charge ≈ 15.0
    @test gas_only.gas_state.charge ≈ 1.1

    # Liquid-only source present: gas charge unchanged
    liq_only = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 1.0).tank
    liq_only_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    liq_only_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    liq_only = update_flowbehav(liq_only; tile = TEST_TILE, mna_state = liq_only_mna)
    @test liq_only.liquid_state.charge ≈ 14.9
    @test liq_only.gas_state.charge ≈ 1.0

    # Pruned sources: no update
    pruned = make_pressurefed_tank(liquid_charge = 12.0, gas_charge = 3.0).tank
    pruned = update_flowbehav(pruned; tile = TEST_TILE, mna_state = MNA_State())
    @test pruned.liquid_state.charge ≈ 12.0
    @test pruned.gas_state.charge ≈ 3.0

    # Manually sealed liquid side ignores stale current
    liq_sealed = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 2.0).tank
    liq_sealed = @set liq_sealed.liquid_sealstate = seal(liq_sealed.liquid_sealstate)
    sealed_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    sealed_mna.vsource_currents[ElementID(TEST_TILE, 1)] = 60.0   # large inflow, should be ignored
    sealed_mna.vsource_currents[ElementID(TEST_TILE, 2)] = 6.0
    liq_sealed = update_flowbehav(liq_sealed; tile = TEST_TILE, mna_state = sealed_mna)
    @test liq_sealed.liquid_state.charge == 15.0  # unchanged
    @test liq_sealed.gas_state.charge ≈ 2.1  # gas still updated

    # Manually sealed gas side ignores stale current
    gas_sealed_tank = make_pressurefed_tank(liquid_charge = 15.0, gas_charge = 2.0).tank
    gas_sealed_tank = @set gas_sealed_tank.gas_sealstate = seal(gas_sealed_tank.gas_sealstate)
    gas_sealed_mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    gas_sealed_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    gas_sealed_mna.vsource_currents[ElementID(TEST_TILE, 2)] = 60.0  # large inflow, should be ignored
    gas_sealed_tank = update_flowbehav(gas_sealed_tank; tile = TEST_TILE, mna_state = gas_sealed_mna)
    @test gas_sealed_tank.liquid_state.charge ≈ 14.9
    @test gas_sealed_tank.gas_state.charge == 2.0  # unchanged
end

@testset "Pressure-fed tank component: elements and tunables" begin
    comp = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 4.0)
    elements = produce_rel_elements(comp)

    @test length(elements) == 3
    @test elements[1].type === HexElements.CONST_VOLTAGE
    @test elements[1].connections == RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND)
    @test elements[2].type === HexElements.CONST_VOLTAGE
    @test elements[2].connections == RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.GROUND)
    @test elements[3].type === HexElements.CONST_RESISTOR
    @test elements[3].connections == RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.NODE_Q_NEG)

    expected_gas_pressure = HexFlowTankComponents.compute_gas_pressure(comp.tank)
    expected_liquid_pressure = 0.01 * (comp.tank.liquid_state.charge / comp.tank.max_liquid_charge * comp.tank.max_gas_pressure)
    @test elements[1].value ≈ (expected_gas_pressure + expected_liquid_pressure)
    @test elements[2].value ≈ expected_gas_pressure
    @test all(elem.active for elem in elements)

    # Gas auto-full-pressure: both sources and resistor inactive
    overpressure_comp = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 22.0)
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
    @test length(tunables) == 6
    @test all(tunables[1:5]) do t
        t isa TunableProps
    end
    @test tunables[6] isa EnumTunableProps{HexFluids.FluidType}
    @test tunables[3].type_desc == "Liquid Charge"
    @test tunables[3].current_val == comp.tank.liquid_state.charge
    @test tunables[4].type_desc == "Gas Charge"
    @test tunables[4].current_val == comp.tank.gas_state.charge
    @test tunables[6].current_val == HexFluids.MONOPROP_LIQUID  # seeded from initial_liquid_fluid

    tuned_comp = set_tunables(comp, (50.0, 70.0, 15.0, 5.0, 8.0, HexFluids.FUEL_LIQUID))
    @test tuned_comp.tank.max_liquid_charge == 50.0
    @test tuned_comp.tank.max_gas_pressure == 70.0
    @test tuned_comp.tank.liquid_state.charge == 15.0
    @test tuned_comp.tank.gas_state.charge == 5.0
    @test tuned_comp.series_conductance == 8.0
    @test get_stored_fluid(tuned_comp.tank.stored_liquid) === HexFluids.FUEL_LIQUID

    # Filled tank emits concrete FluidSource for stored liquid
    decls = produce_rel_fluid_declarations(comp)
    @test length(decls) == 2
    @test decls[1] === RelativeFluidDeclaration(HexFrame.NODE_Q_POS, FluidSource(HexFluids.COLD_GAS, 300.0))
    @test decls[2] === RelativeFluidDeclaration(HexFrame.NODE_INTERNAL_1, FluidSource(HexFluids.MONOPROP_LIQUID, 300.0))

    # Empty tank emits FluidConstraintRule(IS_LIQUID) to accept any liquid
    empty_comp = make_pressurefed_tank(liquid_charge = 0.0)
    empty_decls = produce_rel_fluid_declarations(empty_comp)
    @test length(empty_decls) == 2
    @test empty_decls[1] === RelativeFluidDeclaration(HexFrame.NODE_Q_POS, FluidSource(HexFluids.COLD_GAS, 300.0))
    @test empty_decls[2].declaration isa FluidConstraintRule
    @test empty_decls[2].declaration.constraint === HexFluids.IS_LIQUID

    @test map_rotation(comp, HexFrame.R_POS) === HexFrame.Q_POS

    liquid_density = HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64
    gas_density = HexFluids.lookup_fluid_density(HexFluids.COLD_GAS)::Float64
    # Wet mass uses runtime stored_liquid identity, not a fixed wrapper field
    @test get_component_wet_mass(comp) ≈ (20.0 * liquid_density + 4.0 * gas_density)
    @test get_component_wet_mass(comp; fluid = HexFluids.MONOPROP_LIQUID) ≈ 20.0 * liquid_density
    @test get_component_wet_mass(comp; fluid = HexFluids.COLD_GAS) ≈ 4.0 * gas_density
    @test get_component_wet_mass(comp; fluid = HexFluids.FUEL_LIQUID) == 0.0  # wrong fluid returns 0
    comp = @set comp.tank.gas_state.charge = -2.0
    @test get_component_wet_mass(comp; fluid = HexFluids.COLD_GAS) == 0.0

    # Empty liquid side: liquid contribution is zero regardless of query fluid
    @test get_component_wet_mass(make_pressurefed_tank(liquid_charge = 0.0); fluid = HexFluids.MONOPROP_LIQUID) == 0.0
    @test get_component_wet_mass(make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 0.0)) == 0.0

    # Movement: only when both charges are zero
    liquid_charged = can_be_moved(make_pressurefed_tank(liquid_charge = 10.0, gas_charge = 0.0))
    gas_charged = can_be_moved(make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 1.0))
    @test !isvalidrequest(liquid_charged)
    @test !isvalidrequest(gas_charged)
    @test reason(liquid_charged) == "empty or vent the tank first"
    @test isvalidrequest(can_be_moved(make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 0.0)))
    # Manually sealed still not movable if charge present
    sealed_movable = make_pressurefed_tank(liquid_charge = 39.0, gas_charge = 0.0)
    sealed_movable = @set sealed_movable.tank.liquid_sealstate = seal(sealed_movable.tank.liquid_sealstate)
    @test !isvalidrequest(can_be_moved(sealed_movable))
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
    @test all(action -> action.group_enabled == action.enabled, actions[3:end])

    @testset "vent metadata follows gas state" begin
        for (charge, sealed, expected_enabled, expected_group_enabled) in (
                (3.0, false, true, true),
                (0.0, false, false, true),
                (0.0, true, false, true),
                (3.0, true, false, false),
            )
            state = make_pressurefed_tank(liquid_charge = 12.0, gas_charge = charge).tank
            sealed && (state = @set state.gas_sealstate = seal(state.gas_sealstate))
            action = only(item for item in get_actions(state) if item.id === :vent_and_seal_gas)

            @test action.enabled == expected_enabled
            @test action.group_enabled == expected_group_enabled
            @test action.confirmation_message == "Are you sure? This will vent all stored pressurising gas."
            if charge == 0.0
                @test occursin("already empty", action.tooltip)
            end
        end
    end

    @testset "vent metadata follows liquid state" begin
        for (charge, sealed, expected_enabled, expected_group_enabled) in (
                (12.0, false, true, true),
                (0.0, false, false, true),
                (0.0, true, false, true),
                (12.0, true, false, false),
            )
            state = make_pressurefed_tank(liquid_charge = charge, gas_charge = 3.0).tank
            sealed && (state = @set state.liquid_sealstate = seal(state.liquid_sealstate))
            action = only(item for item in get_actions(state) if item.id === :vent_and_seal_liquid)

            @test action.enabled == expected_enabled
            @test action.group_enabled == expected_group_enabled
            @test action.confirmation_message == "Are you sure? This will vent all stored liquid fuel."
            if charge == 0.0
                @test occursin("already empty", action.tooltip)
            end
        end
    end

    # Vent and Seal Gas: zeroes gas charge and seals gas side only
    tank, result = do_action(tank, :vent_and_seal_gas)
    @test isvalidrequest(result)
    @test tank.gas_state.charge == 0.0
    @test gas_is_sealed(tank)
    @test !liquid_is_sealed(tank)  # liquid side unaffected
    @test unwrap(result) == "Gas vented and sealed"

    # Unseal Gas: clears gas seal
    tank, result = do_action(tank, :unseal_gas)
    @test isvalidrequest(result)
    @test !gas_is_sealed(tank)

    # Vent and Seal Liquid: zeroes liquid charge and seals liquid side only
    tank, result = do_action(tank, :vent_and_seal_liquid)
    @test isvalidrequest(result)
    @test tank.liquid_state.charge == 0.0
    @test liquid_is_sealed(tank)
    @test !gas_is_sealed(tank)  # gas side unaffected
    @test unwrap(result) == "Liquid vented and sealed"

    # Unseal Liquid: clears liquid seal
    tank, result = do_action(tank, :unseal_liquid)
    @test isvalidrequest(result)
    @test !liquid_is_sealed(tank)

    # Seal Both: seals both without changing charge
    tank2 = make_pressurefed_tank(liquid_charge = 12.0, gas_charge = 3.0).tank
    tank2, result = do_action(tank2, :seal_both)
    @test isvalidrequest(result)
    @test liquid_is_sealed(tank2)
    @test gas_is_sealed(tank2)
    @test tank2.liquid_state.charge == 12.0  # charge preserved
    @test tank2.gas_state.charge == 3.0

    # Unseal both sides independently
    tank2, result = do_action(tank2, :unseal_liquid)
    @test !liquid_is_sealed(tank2)
    @test gas_is_sealed(tank2)
    tank2, result = do_action(tank2, :unseal_gas)
    @test !gas_is_sealed(tank2)

    # Unrecognised action
    @test_throws ArgumentError do_action(tank, :nonexistent)
end

@testset "Pressure-fed tank: empty vent actions are safe" begin
    for initially_sealed in (false, true)
        empty_gas = make_pressurefed_tank(liquid_charge = 12.0, gas_charge = 0.0).tank
        initially_sealed && (empty_gas = @set empty_gas.gas_sealstate = seal(empty_gas.gas_sealstate))
        empty_gas, result = do_action(empty_gas, :vent_and_seal_gas)
        @test isvalidrequest(result)
        @test empty_gas.gas_state.charge == 0.0
        @test gas_is_sealed(empty_gas)
        @test empty_gas.liquid_state.charge == 12.0

        empty_liquid = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 3.0).tank
        initially_sealed && (empty_liquid = @set empty_liquid.liquid_sealstate = seal(empty_liquid.liquid_sealstate))
        empty_liquid, result = do_action(empty_liquid, :vent_and_seal_liquid)
        @test isvalidrequest(result)
        @test empty_liquid.liquid_state.charge == 0.0
        @test liquid_is_sealed(empty_liquid)
        @test empty_liquid.gas_state.charge == 3.0
    end
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
    overpressure = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 12.0)
    probe_op = get_reactivation_probe(overpressure)
    @test probe_op isa ReactivationProbe
    @test probe_op.rel_elements[1].active   # liquid probed
    @test probe_op.rel_elements[2].active   # gas probed
    @test probe_op.rel_elements[3].active   # resistor follows liquid

    # Empty liquid cannot flow in either direction while gas pressure is at its limit
    empty_overpressure = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 22.0)
    probe_empty_op = get_reactivation_probe(empty_overpressure)
    @test map(e -> e.active, probe_empty_op.rel_elements) == (false, true, false)

    # Manually sealed sides: no probe for sealed side
    liq_empty_gas_sealed = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0)
    liq_empty_gas_sealed = @set liq_empty_gas_sealed.tank.gas_sealstate = seal(liq_empty_gas_sealed.tank.gas_sealstate)  # gas sealed (not auto-disconnected)
    probe_partial = get_reactivation_probe(liq_empty_gas_sealed)
    @test probe_partial isa ReactivationProbe
    @test probe_partial.rel_elements[1].active  # liquid probed
    @test !probe_partial.rel_elements[2].active  # gas sealed → not probed

    # Both sides manually sealed: no probe
    both_sealed = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 4.0)
    both_sealed = @set both_sealed.tank.liquid_sealstate = seal(both_sealed.tank.liquid_sealstate)
    both_sealed = @set both_sealed.tank.gas_sealstate = seal(both_sealed.tank.gas_sealstate)
    @test isnothing(get_reactivation_probe(both_sealed))
end

@testset "Pressure-fed tank: reactivation probe classify and commit" begin
    "Build speculative state with currents for the supplied pressure-fed source indices."
    function setup_pf_probe(comp::PressureFedTankCompBehav, tile::TileCoord, currents::Pair{Int, Float64}...; rotation::HexAxis = HexFrame.Q_POS)
        elements = produce_rel_elements(comp.tank)
        dm = DerivedMapState()
        mna = MNA_State()
        for (index, current) in currents
            frag = elements[index]
            active_frag = @set frag.active = true
            abs_elem = map_element(active_frag, tile, index, rotation)
            push!(dm.filteredelements, abs_elem)
            mna.vsource_currents[abs_elem.id] = current
        end
        return dm, mna
    end

    # Liquid auto-empty: useful on positive inflow, harmful on outflow
    liq_empty = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0)
    dm_pos, mna_pos = setup_pf_probe(liq_empty, TEST_TILE, 1 => 5.0)
    @test classify_reactivation_probe(liq_empty; tile = TEST_TILE, derivedmapstate = dm_pos, mna_state = mna_pos) === PROBE_USEFUL
    @test liq_empty.tank.liquid_state.charge == 0.0
    @test !liquid_is_force_reactivated(liq_empty.tank)
    liq_empty = commit_reactivation_probe(liq_empty; tile = TEST_TILE, derivedmapstate = dm_pos, mna_state = mna_pos)
    @test liquid_is_force_reactivated(liq_empty.tank)
    @test !gas_is_force_reactivated(liq_empty.tank)

    liq_empty2 = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0)
    dm_neg, mna_neg = setup_pf_probe(liq_empty2, TEST_TILE, 1 => -5.0)
    @test classify_reactivation_probe(liq_empty2; tile = TEST_TILE, derivedmapstate = dm_neg, mna_state = mna_neg) === PROBE_HARMFUL
    @test !liquid_is_force_reactivated(liq_empty2.tank)

    # Liquid auto-full: useful on negative outflow, harmful on inflow (low gas charge to avoid overpressure)
    liq_full = make_pressurefed_tank(liquid_charge = 40.0, gas_charge = 0.5)
    dm_full_neg, mna_full_neg = setup_pf_probe(liq_full, TEST_TILE, 1 => -5.0)
    @test classify_reactivation_probe(liq_full; tile = TEST_TILE, derivedmapstate = dm_full_neg, mna_state = mna_full_neg) === PROBE_USEFUL
    @test liq_full.tank.liquid_state.charge == 40.0
    liq_full = commit_reactivation_probe(liq_full; tile = TEST_TILE, derivedmapstate = dm_full_neg, mna_state = mna_full_neg)
    @test liquid_is_force_reactivated(liq_full.tank)

    liq_full2 = make_pressurefed_tank(liquid_charge = 40.0, gas_charge = 0.5)
    dm_full_pos, mna_full_pos = setup_pf_probe(liq_full2, TEST_TILE, 1 => 5.0)
    @test classify_reactivation_probe(liq_full2; tile = TEST_TILE, derivedmapstate = dm_full_pos, mna_state = mna_full_pos) === PROBE_HARMFUL
    @test !liquid_is_force_reactivated(liq_full2.tank)

    # Gas auto-empty: useful on positive inflow
    gas_empty = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 0.0)
    dm_ge_pos, mna_ge_pos = setup_pf_probe(gas_empty, TEST_TILE, 2 => 5.0)
    @test classify_reactivation_probe(gas_empty; tile = TEST_TILE, derivedmapstate = dm_ge_pos, mna_state = mna_ge_pos) === PROBE_USEFUL
    @test gas_empty.tank.gas_state.charge == 0.0
    gas_empty = commit_reactivation_probe(gas_empty; tile = TEST_TILE, derivedmapstate = dm_ge_pos, mna_state = mna_ge_pos)
    @test gas_is_force_reactivated(gas_empty.tank)
    @test !liquid_is_force_reactivated(gas_empty.tank)

    # Pruned element: neutral
    liq_empty_pruned = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0)
    @test classify_reactivation_probe(liq_empty_pruned; tile = TEST_TILE, derivedmapstate = DerivedMapState(), mna_state = MNA_State()) === PROBE_NEUTRAL

    # Pruned companion side: still useful when the remaining side can reactivate independently
    liq_empty_gas_pruned = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 0.0)
    dm_liq_only, mna_liq_only = setup_pf_probe(liq_empty_gas_pruned, TEST_TILE, 1 => 5.0)
    @test classify_reactivation_probe(liq_empty_gas_pruned; tile = TEST_TILE, derivedmapstate = dm_liq_only, mna_state = mna_liq_only) === PROBE_USEFUL
    liq_empty_gas_pruned = commit_reactivation_probe(liq_empty_gas_pruned; tile = TEST_TILE, derivedmapstate = dm_liq_only, mna_state = mna_liq_only)
    @test liquid_is_force_reactivated(liq_empty_gas_pruned.tank)
    @test !gas_is_force_reactivated(liq_empty_gas_pruned.tank)

    # Gas overpressure: useful when gas outflow is useful and liquid side stays neutral
    overpressure = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 22.0)
    dm_op_gas, mna_op_gas = setup_pf_probe(overpressure, TEST_TILE, 1 => 0.0, 2 => -5.0)  # liquid neutral, gas outflow useful
    @test classify_reactivation_probe(overpressure; tile = TEST_TILE, derivedmapstate = dm_op_gas, mna_state = mna_op_gas) === PROBE_USEFUL
    overpressure = commit_reactivation_probe(overpressure; tile = TEST_TILE, derivedmapstate = dm_op_gas, mna_state = mna_op_gas)
    @test !liquid_is_force_reactivated(overpressure.tank)
    @test gas_is_force_reactivated(overpressure.tank)

    # Both sides probe independently; useful flow wins for the component, and only useful sides commit
    for (label, liquid_current, gas_current, expected_class, force_liquid, force_gas) in (
            ("useful gas, harmful liquid", 5.0, -5.0, PROBE_USEFUL, false, true),
            ("useful liquid, harmful gas", -5.0, 5.0, PROBE_USEFUL, true, false),
            ("both harmful", 5.0, 5.0, PROBE_HARMFUL, false, false),
            ("both neutral", 0.0, 0.0, PROBE_NEUTRAL, false, false),
        )
        @testset "$label" begin
            comp = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = 12.0)
            probe = get_reactivation_probe(comp)
            @test probe.rel_elements[1].active
            @test probe.rel_elements[2].active

            dm, mna = setup_pf_probe(comp, TEST_TILE, 1 => liquid_current, 2 => gas_current)

            @test classify_reactivation_probe(comp; tile = TEST_TILE, derivedmapstate = dm, mna_state = mna) === expected_class
            @test !liquid_is_force_reactivated(comp.tank)
            @test !gas_is_force_reactivated(comp.tank)

            comp = commit_reactivation_probe(comp; tile = TEST_TILE, derivedmapstate = dm, mna_state = mna)
            @test liquid_is_force_reactivated(comp.tank) === force_liquid
            @test gas_is_force_reactivated(comp.tank) === force_gas
            @test map(e -> e.active, produce_rel_elements(comp)) == (force_liquid, force_gas, force_liquid)
        end
    end
end

@testset "Pressure-fed tank: empty liquid stays disconnected during pressure relief" begin
    for liquid_current in (-5.0, 5.0)
        comp = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 22.0)
        derived = DerivedMapState()
        mna = MNA_State()
        for (index, current) in (1 => liquid_current, 2 => -5.0)
            source = produce_rel_elements(comp.tank)[index]
            source = @set source.active = true
            element = map_element(source, TEST_TILE, index, HexFrame.Q_POS)
            push!(derived.filteredelements, element)
            mna.vsource_currents[element.id] = current
        end
        @test classify_reactivation_probe(comp; tile = TEST_TILE, derivedmapstate = derived, mna_state = mna) === PROBE_USEFUL
        committed = commit_reactivation_probe(comp; tile = TEST_TILE, derivedmapstate = derived, mna_state = mna)
        @test !liquid_is_force_reactivated(committed.tank)
        @test gas_is_force_reactivated(committed.tank)
        @test map(e -> e.active, produce_rel_elements(committed)) == (false, true, false)
    end
end

@testset "Pressure-fed tank: approved pressure relief reaches the live solve" begin
    for gas_charge in (2.0, 2.1), relief_side in (:liquid, :gas, :both)
        @testset "gas charge $gas_charge, relief $relief_side" begin
            comp = make_pressurefed_tank(liquid_charge = 40.0, gas_charge = gas_charge)
            placed = PlacedComponent(comp, HexFrame.Q_POS, :primary)
            @test !any(e -> e.active, produce_rel_elements(comp))

            # Grounded outlets let the real solver measure useful relief on either side
            outlets = AbsoluteElement[]
            if relief_side in (:liquid, :both)
                push!(
                    outlets, map_element(
                        RelativeElement(
                            RelativeElementConnections(HexFrame.NODE_Q_NEG, HexFrame.GROUND),
                            1.0, HexElements.CONST_RESISTOR
                        ), TEST_TILE, 4, HexFrame.Q_POS
                    )
                )
            end
            if relief_side in (:gas, :both)
                push!(
                    outlets, map_element(
                        RelativeElement(
                            RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.GROUND),
                            1.0, HexElements.CONST_RESISTOR
                        ), TEST_TILE, 5, HexFrame.Q_POS
                    )
                )
            end

            probe = get_reactivation_probe(placed)
            derived = DerivedMapState()
            append!(derived.filteredelements, [map_element(e, TEST_TILE, i, HexFrame.Q_POS) for (i, e) in pairs(probe.rel_elements) if e.active])
            append!(derived.filteredelements, outlets)
            scratchpad = CalculatorScratchpad()
            prune!(derived.filteredelements, scratchpad)
            ground_search!(derived.filteredelements, scratchpad)
            list_nodes!(derived.filterednodes, derived.filteredelements)
            mna = MNA_State()
            MNA_indexnodes!(mna, derived)
            MNA_splitelements!(mna, derived)
            MNA_updateA!(mna)
            MNA_getZ!(mna)
            MNA_solve!(mna)

            @test classify_reactivation_probe(placed; tile = TEST_TILE, derivedmapstate = derived, mna_state = mna) === PROBE_USEFUL
            committed = commit_reactivation_probe(placed; tile = TEST_TILE, derivedmapstate = derived, mna_state = mna)
            liquid_relief = relief_side in (:liquid, :both)
            gas_relief = relief_side in (:gas, :both)
            @test map(e -> e.active, produce_rel_elements(committed)) == (liquid_relief, gas_relief, liquid_relief)

            # Rebuild from committed behaviour, rather than retaining the speculative sources
            empty!(derived.filteredelements)
            append!(derived.filteredelements, filter(e -> e.active, produce_abs_elements(committed, TEST_TILE)))
            append!(derived.filteredelements, outlets)
            list_nodes!(derived.filterednodes, derived.filteredelements)
            MNA_indexnodes!(mna, derived)
            MNA_splitelements!(mna, derived)
            MNA_updateA!(mna)
            MNA_getZ!(mna)
            MNA_solve!(mna)
            if liquid_relief
                @test mna.vsource_currents[ElementID(TEST_TILE, 1)] ≈ -(25.0 * gas_charge + 0.5) * 5.0 / 6.0
            end
            if gas_relief
                @test mna.vsource_currents[ElementID(TEST_TILE, 2)] ≈ -25.0 * gas_charge
            end

            updated = update_flowbehav(committed; tile = TEST_TILE, derivedmapstate = derived, mna_state = mna)
            @test (updated.component.tank.liquid_state.charge < 40.0) === liquid_relief
            @test (updated.component.tank.gas_state.charge < gas_charge) === gas_relief
            @test !liquid_is_force_reactivated(updated.component.tank)
            @test !gas_is_force_reactivated(updated.component.tank)

            # Even an approved side remains disconnected if the player seals it
            sealed_liquid = @set committed.component.tank.liquid_sealstate = seal(committed.component.tank.liquid_sealstate)
            sealed_gas = @set committed.component.tank.gas_sealstate = seal(committed.component.tank.gas_sealstate)
            @test !produce_rel_elements(sealed_liquid)[1].active
            @test !produce_rel_elements(sealed_liquid)[3].active
            @test !produce_rel_elements(sealed_gas)[2].active
        end
    end
end

# ===============================================================
# Pressure-Fed Liquid Switching: StoredFluidState and Fluid Adoption
# ===============================================================

@testset "Pressure-fed liquid switching: construction seeding" begin
    # Non-empty tank is seeded with the supplied initial fluid
    comp = make_pressurefed_tank(liquid_charge = 20.0)
    @test get_stored_fluid(comp) === HexFluids.MONOPROP_LIQUID

    # Empty tank starts with nothing regardless of initial_liquid_fluid
    comp_empty = make_pressurefed_tank(liquid_charge = 0.0)
    @test isnothing(get_stored_fluid(comp_empty))

    # Fuel and oxidiser tanks seed their respective fluid when non-empty
    fuel_tank = make_pressurefed_tank(gas_charge = 2.0, liquid_fluid = HexFluids.FUEL_LIQUID)
    @test get_stored_fluid(fuel_tank) === HexFluids.FUEL_LIQUID
end

@testset "Pressure-fed liquid switching: state-dependent declarations" begin
    # Filled tank emits a concrete FluidSource for stored liquid
    comp = make_pressurefed_tank(liquid_charge = 20.0)
    decls = produce_rel_fluid_declarations(comp)
    liq_decl = decls[2]
    @test liq_decl.declaration isa FluidSource
    @test liq_decl.declaration.fluid_type === HexFluids.MONOPROP_LIQUID

    # Empty tank emits FluidConstraintRule(IS_LIQUID) to accept any compatible liquid
    comp_empty = make_pressurefed_tank(liquid_charge = 0.0)
    empty_decls = produce_rel_fluid_declarations(comp_empty)
    @test empty_decls[2].declaration isa FluidConstraintRule
    @test empty_decls[2].declaration.constraint === HexFluids.IS_LIQUID

    # Gas declaration is always a concrete FluidSource, unaffected by liquid state
    @test empty_decls[1] === RelativeFluidDeclaration(HexFrame.NODE_Q_POS, FluidSource(HexFluids.COLD_GAS, 300.0))

    # Fuel-filled tank emits its stored fuel fluid
    fuel_tank = make_pressurefed_tank(gas_charge = 2.0, liquid_fluid = HexFluids.FUEL_LIQUID)
    fuel_decls = produce_rel_fluid_declarations(fuel_tank)
    @test fuel_decls[2].declaration.fluid_type === HexFluids.FUEL_LIQUID
end

@testset "Pressure-fed liquid switching: set_tunables stored fluid independence" begin
    comp = make_pressurefed_tank(liquid_charge = 20.0)
    tuned = set_tunables(comp, (50.0, 60.0, 10.0, 3.0, 8.0, HexFluids.FUEL_LIQUID))

    @test tuned.tank.max_liquid_charge == 50.0
    @test tuned.tank.liquid_state.charge == 10.0
    @test tuned.series_conductance == 8.0
    @test get_stored_fluid(tuned.tank.stored_liquid) === HexFluids.FUEL_LIQUID

    # Original component is not affected
    @test get_stored_fluid(comp.tank.stored_liquid) === HexFluids.MONOPROP_LIQUID

end

@testset "Pressure-fed liquid switching: update_flowbehav clears fluid on empty" begin
    comp = make_pressurefed_tank(liquid_charge = 0.1, gas_charge = 2.0)
    @test get_stored_fluid(comp) === HexFluids.MONOPROP_LIQUID

    # Large outflow drains liquid to zero in one tick
    mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = -1000.0
    mna.vsource_currents[ElementID(TEST_TILE, 2)] = 0.0
    comp = update_flowbehav(comp; tile = TEST_TILE, mna_state = mna)

    @test comp.tank.liquid_state.charge == 0.0
    @test isnothing(get_stored_fluid(comp))  # cleared on empty
end

@testset "Pressure-fed liquid switching: update_flowbehav adopts fluid on refill" begin
    comp = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0)
    @test isnothing(get_stored_fluid(comp))

    # Provide derivedmapstate with FUEL_LIQUID on NODE_INTERNAL_1
    dm = DerivedMapState()
    internal_node = NodeCoord(TEST_TILE, HexFrame.NODE_INTERNAL_1)
    dm.nodeactualfluids[internal_node] = HexFluids.FUEL_LIQUID

    mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0  # inflow raises liquid charge
    mna.vsource_currents[ElementID(TEST_TILE, 2)] = 0.0
    comp = update_flowbehav(comp; tile = TEST_TILE, mna_state = mna, derivedmapstate = dm)

    @test comp.tank.liquid_state.charge > 0.0
    @test get_stored_fluid(comp) === HexFluids.FUEL_LIQUID  # adopted from NODE_INTERNAL_1
end

@testset "Pressure-fed liquid switching: no adoption without derivedmapstate" begin
    comp = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 4.0)
    @test isnothing(get_stored_fluid(comp))

    mna = register_vsources!(MNA_State(), TEST_TILE, 1, 2)
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0
    mna.vsource_currents[ElementID(TEST_TILE, 2)] = 0.0
    comp = update_flowbehav(comp; tile = TEST_TILE, mna_state = mna)  # no derivedmapstate

    @test comp.tank.liquid_state.charge > 0.0
    @test isnothing(get_stored_fluid(comp))  # no adoption without derived state
end

@testset "Pressure-fed liquid switching: fragment set_tunables preserves stored liquid" begin
    tank = make_pressurefed_tank().tank
    @test get_stored_fluid(tank.stored_liquid) === HexFluids.MONOPROP_LIQUID

    # Updated tunables preserve the stored fluid value
    tuned = set_tunables(tank, (50.0, 60.0, 25.0, 3.0))
    @test get_stored_fluid(tuned.stored_liquid) === HexFluids.MONOPROP_LIQUID
    @test get_stored_fluid(tank.stored_liquid) === HexFluids.MONOPROP_LIQUID

    # Tuning charge to zero clears stored_liquid (consistent with empty semantics)
    tuned_empty = set_tunables(tank, (40.0, 50.0, 0.0, 0.0))
    @test isnothing(get_stored_fluid(tuned_empty.stored_liquid))

    overfilled = set_tunables(tank, (10.0, 50.0, 25.0, -3.0))
    @test overfilled.liquid_state === TankState(10.0)
    @test overfilled.gas_state === TankState(-3.0)
    underfilled = set_tunables(tank, (40.0, 50.0, -5.0, 3.0))
    @test underfilled.liquid_state === TankState(0.0)
    @test isnothing(get_stored_fluid(underfilled.stored_liquid))
end

@testset "Existing tank regression coverage" begin
    gas_comp = make_gas_tank(initial_charge = 20.0)
    gas_elements = produce_rel_elements(gas_comp)
    @test length(gas_elements) == 4
    @test gas_elements[1].type === HexElements.CONST_VOLTAGE
    @test gas_elements[1].value ≈ 25.0  # bounded linear: 20/40 * 50
    @test gas_elements[2].type === HexElements.CONST_RESISTOR
    gas_decls = produce_rel_fluid_declarations(gas_comp)
    @test length(gas_decls) == 1
    @test gas_decls[1] === RelativeFluidDeclaration(HexFrame.NODE_INTERNAL_1, FluidSource(HexFluids.COLD_GAS, 300.0))
    @test get_component_wet_mass(gas_comp) ≈ 20.0

    gas_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    gas_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    gas_comp = update_flowbehav(gas_comp; tile = TEST_TILE, mna_state = gas_mna)
    @test gas_comp.tank.tank.state.charge ≈ 19.9

    # Near-empty: clamps to zero and becomes auto-disconnected (not stalled)
    gas_near_empty = make_gas_tank(initial_charge = 0.05)
    gas_near_empty_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    gas_near_empty_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    gas_near_empty = update_flowbehav(gas_near_empty; tile = TEST_TILE, mna_state = gas_near_empty_mna)
    @test gas_near_empty.tank.tank.state.charge == 0.0
    @test isvalidrequest(can_be_moved(gas_near_empty))  # movable when empty

    # Vent and Seal action empties and seals
    gas_comp, result = do_action(gas_comp, :vent_and_seal)
    @test isvalidrequest(result)
    @test gas_comp.tank.tank.state.charge == 0.0
    @test is_sealed(gas_comp.tank.tank.sealstate)

    liquid_comp = make_liquid_tank(initial_charge = 20.0)
    liquid_elements = produce_rel_elements(liquid_comp)
    @test length(liquid_elements) == 4
    @test liquid_elements[1].type === HexElements.CONST_VOLTAGE
    @test liquid_elements[1].value > 0.0
    liq_decls = produce_rel_fluid_declarations(liquid_comp)
    @test length(liq_decls) == 1
    @test liq_decls[1] === RelativeFluidDeclaration(HexFrame.NODE_INTERNAL_1, FluidSource(HexFluids.MONOPROP_LIQUID, 300.0))
    @test get_component_wet_mass(liquid_comp) ≈ 100.0
    @test map_rotation(liquid_comp, HexFrame.S_POS) === HexFrame.Q_POS
    @test map_rotation(liquid_comp, HexFrame.R_NEG) === HexFrame.Q_NEG

    liquid_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    liquid_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    liquid_comp = update_flowbehav(liquid_comp; tile = TEST_TILE, mna_state = liquid_mna)
    @test liquid_comp.tank.tank.state.charge ≈ 19.9
end

# ===============================================================
# Thevinin Tank (SealState + New Semantics)
# ===============================================================

@testset "SealState" begin
    s = SealState()
    @test !is_sealed(s)

    s = seal(s)
    @test is_sealed(s)

    s = unseal(s)
    @test !is_sealed(s)
end

@testset "TankBehavFrag derived state helpers" begin
    connection = RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND)

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
    empty_tank = @set empty_tank.sealstate = seal(empty_tank.sealstate)
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
    @test gas_elems[1].type === HexElements.CONST_VOLTAGE

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
    sealed_gas = @set sealed_gas.tank.tank.sealstate = seal(sealed_gas.tank.tank.sealstate)
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

@testset "ThevininTankCompBehav: update_flowbehav charge clamping" begin
    # Normal mid-range update
    gas = make_gas_tank(initial_charge = 20.0)
    mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0  # outflow
    gas = update_flowbehav(gas; tile = TEST_TILE, mna_state = mna)
    @test gas.tank.tank.state.charge ≈ 19.9

    # Underflow clamps to zero
    gas_near_empty = make_gas_tank(initial_charge = 0.05)
    mna_empty = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna_empty.vsource_currents[ElementID(TEST_TILE, 1)] = -6.0
    gas_near_empty = update_flowbehav(gas_near_empty; tile = TEST_TILE, mna_state = mna_empty)
    @test gas_near_empty.tank.tank.state.charge == 0.0

    # Overflow clamps to max_charge
    gas_near_full = make_gas_tank(initial_charge = 39.95)
    mna_full = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna_full.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0  # inflow
    gas_near_full = update_flowbehav(gas_near_full; tile = TEST_TILE, mna_state = mna_full)
    @test gas_near_full.tank.tank.state.charge == 40.0

    # Sealed tanks ignore stale current even when source is present
    gas_sealed = make_gas_tank(initial_charge = 20.0)
    gas_sealed = @set gas_sealed.tank.tank.sealstate = seal(gas_sealed.tank.tank.sealstate)
    mna_sealed = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna_sealed.vsource_currents[ElementID(TEST_TILE, 1)] = -60.0
    gas_sealed = update_flowbehav(gas_sealed; tile = TEST_TILE, mna_state = mna_sealed)
    @test gas_sealed.tank.tank.state.charge == 20.0  # unchanged

    # Pruned source: no update
    gas_pruned = make_gas_tank(initial_charge = 20.0)
    gas_pruned = update_flowbehav(gas_pruned; tile = TEST_TILE, mna_state = MNA_State())
    @test gas_pruned.tank.tank.state.charge == 20.0

    # Auto-empty (charge == 0): accepts probe current when vsource is present
    gas_boundary = make_gas_tank(initial_charge = 0.0)
    mna_boundary = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna_boundary.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0  # inflow from accepted probe
    gas_boundary = update_flowbehav(gas_boundary; tile = TEST_TILE, mna_state = mna_boundary)
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
    @test all(action -> action.group_enabled == action.enabled, actions[2:end])

    @testset "vent metadata follows tank state" begin
        for make_tank in (make_gas_tank, make_liquid_tank)
            for (charge, sealed, expected_enabled, expected_group_enabled) in (
                    (20.0, false, true, true),
                    (0.0, false, false, true),
                    (0.0, true, false, true),
                    (20.0, true, false, false),
                )
                state = make_tank(initial_charge = charge)
                sealed && (state = @set state.tank.tank.sealstate = seal(state.tank.tank.sealstate))
                action = only(item for item in get_actions(state) if item.id === :vent_and_seal)

                @test action.enabled == expected_enabled
                @test action.group_enabled == expected_group_enabled
                @test action.confirmation_message == "Are you sure? This will vent all stored fuel."
                if charge == 0.0
                    @test occursin("already empty", action.tooltip)
                end
            end
        end
    end

    # Vent and Seal: empties tank and seals it
    gas, result = do_action(gas, :vent_and_seal)
    @test isvalidrequest(result)
    @test gas.tank.tank.state.charge == 0.0
    @test is_sealed(gas.tank.tank.sealstate)
    @test unwrap(result) == "Tank vented and sealed"

    # Unseal: clears seal
    gas, result = do_action(gas, :unseal_tank)
    @test isvalidrequest(result)
    @test !is_sealed(gas.tank.tank.sealstate)

    # Seal Tank: seals without venting
    gas2 = make_gas_tank(initial_charge = 25.0)
    gas2, result = do_action(gas2, :seal_tank)
    @test isvalidrequest(result)
    @test is_sealed(gas2.tank.tank.sealstate)
    @test gas2.tank.tank.state.charge == 25.0  # charge unchanged

    # Unseal via action
    gas2, result = do_action(gas2, :unseal_tank)
    @test isvalidrequest(result)
    @test !is_sealed(gas2.tank.tank.sealstate)

    # can_be_moved: based on charge only
    gas2_status = can_be_moved(gas2)
    @test !isvalidrequest(gas2_status)  # has charge
    @test reason(gas2_status) == "empty or vent the tank first"
    gas3 = make_gas_tank(initial_charge = 0.0)
    @test isvalidrequest(can_be_moved(gas3))

    # Sealed tank with charge: still not movable
    gas2 = @set gas2.tank.tank.sealstate = seal(gas2.tank.tank.sealstate)
    @test !isvalidrequest(can_be_moved(gas2))
end

@testset "ThevininTankCompBehav: empty vent actions are safe" begin
    empty_unsealed = make_gas_tank(initial_charge = 0.0)
    empty_unsealed, result = do_action(empty_unsealed, :vent_and_seal)
    @test isvalidrequest(result)
    @test empty_unsealed.tank.tank.state.charge == 0.0
    @test is_sealed(empty_unsealed.tank.tank.sealstate)

    empty_sealed = make_gas_tank(initial_charge = 0.0)
    empty_sealed = @set empty_sealed.tank.tank.sealstate = seal(empty_sealed.tank.tank.sealstate)
    empty_sealed, result = do_action(empty_sealed, :vent_and_seal)
    @test isvalidrequest(result)
    @test empty_sealed.tank.tank.state.charge == 0.0
    @test is_sealed(empty_sealed.tank.tank.sealstate)
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
    gas_sealed_empty = @set gas_sealed_empty.tank.tank.sealstate = seal(gas_sealed_empty.tank.tank.sealstate)
    @test isnothing(get_reactivation_probe(gas_sealed_empty))

    gas_sealed_full = make_gas_tank(initial_charge = 40.0)
    gas_sealed_full = @set gas_sealed_full.tank.tank.sealstate = seal(gas_sealed_full.tank.tank.sealstate)
    @test isnothing(get_reactivation_probe(gas_sealed_full))

    # Liquid tank same behaviour
    liq_empty = make_liquid_tank(initial_charge = 0.0)
    @test get_reactivation_probe(liq_empty) isa ReactivationProbe

    liq_full = make_liquid_tank(initial_charge = 40.0)
    @test get_reactivation_probe(liq_full) isa ReactivationProbe

    liq_mid = make_liquid_tank(initial_charge = 20.0)
    @test isnothing(get_reactivation_probe(liq_mid))
end

@testset "ThevininTankCompBehav: reactivation probe classify and commit" begin
    "Build DerivedMapState and MNA_State for classify_reactivation_probe tests."
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

    probe_tol = 1.0e-9

    # --- Empty tank ---
    gas_empty = make_gas_tank(initial_charge = 0.0)

    # Pruned element: neutral
    pruned_dm = DerivedMapState()
    pruned_mna = MNA_State()
    @test classify_reactivation_probe(gas_empty; tile = TEST_TILE, derivedmapstate = pruned_dm, mna_state = pruned_mna) === PROBE_NEUTRAL

    # Positive inflow: useful
    dm_pos, mna_pos = setup_probe_accept(gas_empty.tank, TEST_TILE, 5.0)
    @test classify_reactivation_probe(gas_empty; tile = TEST_TILE, derivedmapstate = dm_pos, mna_state = mna_pos) === PROBE_USEFUL
    @test gas_empty.tank.tank.state.charge == 0.0
    @test !is_force_reactivated(gas_empty.tank.tank)
    gas_empty = commit_reactivation_probe(gas_empty; tile = TEST_TILE, derivedmapstate = dm_pos, mna_state = mna_pos)
    @test is_force_reactivated(gas_empty.tank.tank)

    # Negative current (outflow): harmful
    dm_neg, mna_neg = setup_probe_accept(gas_empty.tank, TEST_TILE, -5.0)
    @test classify_reactivation_probe(gas_empty; tile = TEST_TILE, derivedmapstate = dm_neg, mna_state = mna_neg) === PROBE_HARMFUL

    # Neutral current (below tolerance): neutral
    dm_neut, mna_neut = setup_probe_accept(gas_empty.tank, TEST_TILE, probe_tol / 2)
    @test classify_reactivation_probe(gas_empty; tile = TEST_TILE, derivedmapstate = dm_neut, mna_state = mna_neut) === PROBE_NEUTRAL

    # --- Full tank ---
    gas_full = make_gas_tank(initial_charge = 40.0)

    # Negative outflow: useful
    dm_neg_full, mna_neg_full = setup_probe_accept(gas_full.tank, TEST_TILE, -5.0)
    @test classify_reactivation_probe(gas_full; tile = TEST_TILE, derivedmapstate = dm_neg_full, mna_state = mna_neg_full) === PROBE_USEFUL
    @test gas_full.tank.tank.state.charge == 40.0
    gas_full = commit_reactivation_probe(gas_full; tile = TEST_TILE, derivedmapstate = dm_neg_full, mna_state = mna_neg_full)
    @test is_force_reactivated(gas_full.tank.tank)

    # Positive inflow: harmful
    dm_pos_full, mna_pos_full = setup_probe_accept(gas_full.tank, TEST_TILE, 5.0)
    @test classify_reactivation_probe(gas_full; tile = TEST_TILE, derivedmapstate = dm_pos_full, mna_state = mna_pos_full) === PROBE_HARMFUL

    # Neutral current: neutral
    dm_neut_full, mna_neut_full = setup_probe_accept(gas_full.tank, TEST_TILE, -(probe_tol / 2))
    @test classify_reactivation_probe(gas_full; tile = TEST_TILE, derivedmapstate = dm_neut_full, mna_state = mna_neut_full) === PROBE_NEUTRAL
end

@testset "Tank force reactivation flags are one-shot" begin
    gas = make_gas_tank(initial_charge = 0.0)
    gas = @set gas.tank.tank = force_reactivate(gas.tank.tank)
    @test tank_is_active(gas.tank.tank)

    mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0
    gas = @set gas.tank.tank = update_flowbehav(gas.tank.tank; tile = TEST_TILE, mna_state = mna)
    @test !is_force_reactivated(gas.tank.tank)

    pf = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 0.0)
    pf = @set pf.tank = force_liquid_reactivate(pf.tank)
    pf = @set pf.tank = force_gas_reactivate(pf.tank)
    @test pressurefed_liquid_source_active(pf.tank)
    @test pressurefed_gas_source_active(pf.tank)

    mna_pf = register_vsources!(MNA_State(), TEST_TILE, 2)
    mna_pf.vsource_currents[ElementID(TEST_TILE, 1)] = 5.0
    mna_pf.vsource_currents[ElementID(TEST_TILE, 2)] = 4.0
    pf = @set pf.tank = update_flowbehav(pf.tank; tile = TEST_TILE, mna_state = mna_pf)
    @test !liquid_is_force_reactivated(pf.tank)
    @test !gas_is_force_reactivated(pf.tank)
end

@testset "ThevininTankCompBehav: component tunables and declarations" begin
    gas = make_gas_tank(initial_charge = 20.0)
    tunables = get_tunables(gas)
    @test tunables isa NTuple{4, TunableProps}
    @test tunables[3].type_desc == "Current Charge State"
    @test tunables[3].current_val == 20.0

    tuned = set_tunables(gas, (45.0, 60.0, 15.0, 8.0))
    @test tuned.tank.tank.max_charge == 45.0
    @test tuned.tank.tank.max_voltage == 60.0
    @test tuned.tank.tank.state.charge == 15.0
    @test tuned.series_conductance == 8.0

    gas_decls = produce_rel_fluid_declarations(gas)
    @test length(gas_decls) == 1
    @test gas_decls[1] === RelativeFluidDeclaration(HexFrame.NODE_INTERNAL_1, FluidSource(HexFluids.COLD_GAS, 300.0))

    # Liquid tank tunables: 5-element tuple, last one is EnumTunableProps{FluidType}
    liq = make_liquid_tank(initial_charge = 20.0)
    liq_tunables = get_tunables(liq)
    @test length(liq_tunables) == 5
    @test all(liq_tunables[1:4]) do t
        t isa TunableProps
    end
    @test liq_tunables[5] isa EnumTunableProps{HexFluids.FluidType}
    @test liq_tunables[5].current_val == HexFluids.MONOPROP_LIQUID

    liq_decls = produce_rel_fluid_declarations(liq)
    @test length(liq_decls) == 1
    @test liq_decls[1] === RelativeFluidDeclaration(HexFrame.NODE_INTERNAL_1, FluidSource(HexFluids.MONOPROP_LIQUID, 300.0))

    # Wet mass
    @test get_component_wet_mass(gas) ≈ 20.0  # COLD_GAS density 1.0 kg/L
    liq_density = HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64
    @test get_component_wet_mass(liq) ≈ 20.0 * liq_density

    # map_rotation: liquid flips, gas does not restrict
    @test map_rotation(liq, HexFrame.S_POS) === HexFrame.Q_POS
    @test map_rotation(liq, HexFrame.R_NEG) === HexFrame.Q_NEG
end

# ===============================================================
# Refillable Liquid Tank: StoredFluidState and Fluid Adoption
# ===============================================================

@testset "Refillable liquid tank: StoredFluidState basics" begin
    # Non-empty tank is initialised with stored fluid from construction-time fluid
    liq = make_liquid_tank(initial_charge = 20.0)
    @test get_stored_fluid(liq.tank.stored_fluid) === HexFluids.MONOPROP_LIQUID

    # Empty tank at construction has stored_fluid = nothing
    liq_empty = make_liquid_tank(initial_charge = 0.0)
    @test isnothing(get_stored_fluid(liq_empty.tank.stored_fluid))

    # Fuel and oxidiser tanks initialise with their respective fluids when non-empty
    fuel_tank = make_liquid_tank(fluid = HexFluids.FUEL_LIQUID)
    @test get_stored_fluid(fuel_tank.tank.stored_fluid) === HexFluids.FUEL_LIQUID

    ox_tank = make_liquid_tank(fluid = HexFluids.OXIDISER_LIQUID)
    @test get_stored_fluid(ox_tank.tank.stored_fluid) === HexFluids.OXIDISER_LIQUID
end

@testset "Refillable liquid tank: state-dependent declarations" begin
    # Filled tank emits a concrete FluidSource
    liq = make_liquid_tank(initial_charge = 20.0)
    decls = produce_rel_fluid_declarations(liq)
    @test length(decls) == 1
    decl = decls[1]
    @test decl isa RelativeFluidDeclaration
    @test decl.declaration isa FluidSource
    @test decl.declaration.fluid_type === HexFluids.MONOPROP_LIQUID

    # Empty tank emits FluidConstraintRule(IS_LIQUID) to accept any liquid
    liq_empty = make_liquid_tank(initial_charge = 0.0)
    empty_decls = produce_rel_fluid_declarations(liq_empty)
    @test length(empty_decls) == 1
    @test empty_decls[1].declaration isa FluidConstraintRule
    @test empty_decls[1].declaration.constraint === HexFluids.IS_LIQUID

    # Fuel and oxidiser tanks emit their respective fluid when filled
    fuel_tank = make_liquid_tank(fluid = HexFluids.FUEL_LIQUID)
    fuel_decls = produce_rel_fluid_declarations(fuel_tank)
    @test fuel_decls[1].declaration.fluid_type === HexFluids.FUEL_LIQUID
end

@testset "Refillable liquid tank: set_tunables preserves stored fluid independence" begin
    liq = make_liquid_tank(initial_charge = 20.0)
    # set_tunables with 5-tuple: last element is the new fluid
    tuned = set_tunables(liq, (50.0, 1.0, 10.0, 6.0, HexFluids.FUEL_LIQUID))
    @test tuned.tank.tank.max_charge == 50.0
    @test tuned.tank.tank.state.charge == 10.0
    @test tuned.series_conductance == 6.0
    @test get_stored_fluid(tuned.tank.stored_fluid) === HexFluids.FUEL_LIQUID

    # The original tank is not affected (set_tunables is non-mutating at component level)
    @test get_stored_fluid(liq.tank.stored_fluid) === HexFluids.MONOPROP_LIQUID

end

@testset "Refillable liquid tank: wet mass uses stored fluid" begin
    liq_density = HexFluids.lookup_fluid_density(HexFluids.MONOPROP_LIQUID)::Float64
    fuel_density = HexFluids.lookup_fluid_density(HexFluids.FUEL_LIQUID)::Float64

    # Filled monoprop tank
    liq = make_liquid_tank(initial_charge = 20.0)
    @test get_component_wet_mass(liq) ≈ 20.0 * liq_density
    @test get_component_wet_mass(liq; fluid = HexFluids.MONOPROP_LIQUID) ≈ 20.0 * liq_density
    @test get_component_wet_mass(liq; fluid = HexFluids.FUEL_LIQUID) == 0.0  # wrong fluid

    # Empty tank: no wet mass regardless of query fluid
    liq_empty = make_liquid_tank(initial_charge = 0.0)
    @test get_component_wet_mass(liq_empty) == 0.0
    @test get_component_wet_mass(liq_empty; fluid = HexFluids.MONOPROP_LIQUID) == 0.0

    # Fuel-filled tank
    fuel_tank = make_liquid_tank(fluid = HexFluids.FUEL_LIQUID)
    @test get_component_wet_mass(fuel_tank) ≈ 20.0 * fuel_density
    @test get_component_wet_mass(fuel_tank; fluid = HexFluids.MONOPROP_LIQUID) == 0.0
end

@testset "Refillable liquid tank: update_flowbehav clears fluid on empty" begin
    liq = make_liquid_tank(initial_charge = 0.1)
    @test get_stored_fluid(liq.tank.stored_fluid) === HexFluids.MONOPROP_LIQUID

    # Large outflow drains tank to zero in one tick
    mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = -1000.0
    liq = update_flowbehav(liq; tile = TEST_TILE, mna_state = mna)

    @test liq.tank.tank.state.charge == 0.0
    @test isnothing(get_stored_fluid(liq.tank.stored_fluid))  # cleared on empty
end

@testset "Refillable liquid tank: update_flowbehav adopts fluid on refill" begin
    liq_empty = make_liquid_tank(initial_charge = 0.0)
    @test isnothing(get_stored_fluid(liq_empty.tank.stored_fluid))

    # Provide derivedmapstate with FUEL_LIQUID on the internal node
    dm = DerivedMapState()
    internal_node = NodeCoord(TEST_TILE, HexFrame.NODE_INTERNAL_1)
    dm.nodeactualfluids[internal_node] = HexFluids.FUEL_LIQUID

    # Inflow: charge rises above zero
    mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0
    liq_empty = update_flowbehav(liq_empty; tile = TEST_TILE, mna_state = mna, derivedmapstate = dm)

    @test liq_empty.tank.tank.state.charge > 0.0
    @test get_stored_fluid(liq_empty.tank.stored_fluid) === HexFluids.FUEL_LIQUID  # adopted
end

@testset "Refillable liquid tank: no adoption without derivedmapstate" begin
    # Without derivedmapstate, filling a tank leaves stored_fluid as nothing (adoption deferred)
    liq_empty = make_liquid_tank(initial_charge = 0.0)
    mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0
    liq_empty = update_flowbehav(liq_empty; tile = TEST_TILE, mna_state = mna)  # no derivedmapstate

    @test liq_empty.tank.tank.state.charge > 0.0
    @test isnothing(get_stored_fluid(liq_empty.tank.stored_fluid))  # no adoption without derived state
end

# ===============================================================
# Value Semantics
# ===============================================================

@testset "Tank state transitions preserve original fragments" begin
    @test !ismutabletype(SealState)
    @test !ismutabletype(TankState)
    @test !ismutabletype(StoredFluidState)

    original_seal = SealState()
    sealed = seal(original_seal)
    reopened = unseal(sealed)
    @test !is_sealed(original_seal)
    @test is_sealed(sealed)
    @test !is_sealed(reopened)

    original_fluid = StoredFluidState(nothing)
    filled = set_stored_fluid(original_fluid, HexFluids.FUEL_LIQUID)
    cleared = clear_stored_fluid(filled)
    @test isnothing(get_stored_fluid(original_fluid))
    @test get_stored_fluid(filled) === HexFluids.FUEL_LIQUID
    @test isnothing(get_stored_fluid(cleared))

    original_tank = make_gas_tank(initial_charge = 0.0).tank.tank
    forced = force_reactivate(original_tank)
    cleared_force = clear_force_reactivate(forced)
    @test !is_force_reactivated(original_tank)
    @test is_force_reactivated(forced)
    @test !is_force_reactivated(cleared_force)
    @test forced.connection == original_tank.connection
    @test forced.max_charge == original_tank.max_charge
    @test forced.max_voltage == original_tank.max_voltage
    @test forced.state.charge == original_tank.state.charge

    # Flags still clear when the solver has pruned the source
    pruned = update_flowbehav(forced; tile = TEST_TILE, mna_state = MNA_State())
    @test is_force_reactivated(forced)
    @test !is_force_reactivated(pruned)
    @test pruned.state.charge == forced.state.charge

    original_pf = make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 0.0).tank
    liquid_forced = force_liquid_reactivate(original_pf)
    both_forced = force_gas_reactivate(liquid_forced)
    @test !liquid_is_force_reactivated(original_pf)
    @test !gas_is_force_reactivated(original_pf)
    @test liquid_is_force_reactivated(liquid_forced)
    @test !gas_is_force_reactivated(liquid_forced)
    @test liquid_is_force_reactivated(both_forced)
    @test gas_is_force_reactivated(both_forced)
    @test !liquid_is_force_reactivated(clear_force_liquid_reactivate(both_forced))
    @test gas_is_force_reactivated(clear_force_liquid_reactivate(both_forced))
    @test liquid_is_force_reactivated(clear_force_gas_reactivate(both_forced))
    @test !gas_is_force_reactivated(clear_force_gas_reactivate(both_forced))
    pf_pruned = update_flowbehav(both_forced; tile = TEST_TILE, mna_state = MNA_State())
    @test liquid_is_force_reactivated(both_forced)
    @test gas_is_force_reactivated(both_forced)
    @test !liquid_is_force_reactivated(pf_pruned)
    @test !gas_is_force_reactivated(pf_pruned)
end

@testset "Tank updates propagate through fragments and placement" begin
    mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0
    original = make_gas_tank()
    core = original.tank.tank
    updated_core = update_flowbehav(core; tile = TEST_TILE, mna_state = mna)
    updated_frag = update_flowbehav(original.tank; tile = TEST_TILE, mna_state = mna)
    updated_comp = update_flowbehav(original; tile = TEST_TILE, mna_state = mna)
    @test core.state.charge == 20.0
    @test updated_core.state.charge ≈ 20.1
    @test updated_frag.tank.state.charge ≈ 20.1
    @test updated_comp.tank.tank.state.charge ≈ 20.1
    @test original.tank.tank.state.charge == 20.0
    @test updated_comp.out_nodes == original.out_nodes
    @test updated_comp.series_conductance == original.series_conductance
    @test updated_comp.fluid == original.fluid

    for comp in (original, make_liquid_tank(), make_pressurefed_tank())
        placed = PlacedComponent(comp, HexFrame.S_NEG, true, :ValueSemanticsShip)
        updated = update_flowbehav(placed; tile = TEST_TILE, mna_state = mna)
        @test updated.rotation == placed.rotation
        @test updated.mirrored == placed.mirrored
        @test updated.ship == placed.ship
        @test updated.component.series_conductance == comp.series_conductance
        if comp isa PressureFedTankCompBehav
            @test comp.tank.liquid_state.charge == 20.0
            @test updated.component.tank.liquid_state.charge ≈ 20.1
            @test updated.component.tank.gas_state.charge == comp.tank.gas_state.charge
            @test updated.component.liquid_nodes == comp.liquid_nodes
            @test updated.component.gas_fluid == comp.gas_fluid
        else
            @test comp.tank.tank.state.charge == 20.0
            @test updated.component.tank.tank.state.charge ≈ 20.1
            @test updated.component.out_nodes == comp.out_nodes
            @test updated.component.fluid == comp.fluid
        end
    end
end

@testset "Liquid identity updates preserve original components" begin
    dm = DerivedMapState()
    dm.nodeactualfluids[NodeCoord(TEST_TILE, HexFrame.NODE_INTERNAL_1)] = HexFluids.FUEL_LIQUID
    mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0
    for original in (make_liquid_tank(initial_charge = 0.0), make_pressurefed_tank(liquid_charge = 0.0))
        filled = update_flowbehav(original; tile = TEST_TILE, mna_state = mna, derivedmapstate = dm)
        @test isnothing(get_stored_fluid(original))
        @test get_stored_fluid(filled) === HexFluids.FUEL_LIQUID
        mna.vsource_currents[ElementID(TEST_TILE, 1)] = -1000.0
        drained = update_flowbehav(filled; tile = TEST_TILE, mna_state = mna, derivedmapstate = dm)
        @test get_stored_fluid(filled) === HexFluids.FUEL_LIQUID
        @test isnothing(get_stored_fluid(drained))
        @test drained.series_conductance == original.series_conductance
        mna.vsource_currents[ElementID(TEST_TILE, 1)] = 6.0
    end
end

@testset "Tank action tuples preserve original values and placement" begin
    for comp in (make_gas_tank(), make_liquid_tank(), make_pressurefed_tank())
        placed = PlacedComponent(comp, HexFrame.R_NEG, true, :ValueSemanticsShip)
        action = comp isa PressureFedTankCompBehav ? :vent_and_seal_liquid : :vent_and_seal
        updated, result = do_action(placed, action)
        @test result isa ValidRequestResult
        @test updated.rotation == placed.rotation
        @test updated.mirrored == placed.mirrored
        @test updated.ship == placed.ship
        @test updated.component.series_conductance == comp.series_conductance
        if comp isa PressureFedTankCompBehav
            @test comp.tank.liquid_state.charge == 20.0
            @test !liquid_is_sealed(comp.tank)
            @test updated.component.tank.liquid_state.charge == 0.0
            @test liquid_is_sealed(updated.component.tank)
            @test updated.component.tank.gas_state.charge == comp.tank.gas_state.charge
            @test !gas_is_sealed(updated.component.tank)
        else
            @test comp.tank.tank.state.charge == 20.0
            @test !is_sealed(comp.tank.tank)
            @test updated.component.tank.tank.state.charge == 0.0
            @test is_sealed(updated.component.tank.tank)
            @test updated.component.out_nodes == comp.out_nodes
        end
        repeated, repeated_result = do_action(updated, action)
        @test repeated_result isa ValidRequestResult  # Already-empty vents remain safe
        @test map(prop -> prop.current_val, get_tunables(repeated)) == map(prop -> prop.current_val, get_tunables(updated))
        @test_throws ArgumentError do_action(placed, :unsupported)
        @test map(prop -> prop.current_val, get_tunables(placed)) == map(prop -> prop.current_val, get_tunables(comp))
    end
end

@testset "Tank reactivation commits preserve original values" begin
    for comp in (make_gas_tank(initial_charge = 0.0), make_liquid_tank(initial_charge = 0.0), make_pressurefed_tank(liquid_charge = 0.0, gas_charge = 0.0))
        placed = PlacedComponent(comp, HexFrame.S_NEG, true, :ValueSemanticsShip)
        probe = get_reactivation_probe(placed)
        dm = DerivedMapState()
        mna = MNA_State()
        source_count = comp isa PressureFedTankCompBehav ? 2 : 1
        for index in 1:source_count
            element = map_element(probe.rel_elements[index], TEST_TILE, index, placed.rotation, placed.mirrored)
            push!(dm.filteredelements, element)
            mna.vsource_currents[element.id] = 6.0
        end
        @test classify_reactivation_probe(placed; tile = TEST_TILE, derivedmapstate = dm, mna_state = mna) === PROBE_USEFUL
        committed = commit_reactivation_probe(placed; tile = TEST_TILE, derivedmapstate = dm, mna_state = mna)
        @test committed.rotation == placed.rotation
        @test committed.mirrored == placed.mirrored
        @test committed.ship == placed.ship
        @test committed.component.series_conductance == comp.series_conductance
        if comp isa PressureFedTankCompBehav
            @test !liquid_is_force_reactivated(comp.tank)
            @test !gas_is_force_reactivated(comp.tank)
            @test liquid_is_force_reactivated(committed.component.tank)
            @test gas_is_force_reactivated(committed.component.tank)
            @test committed.component.tank.liquid_state.charge == comp.tank.liquid_state.charge
            @test committed.component.tank.gas_state.charge == comp.tank.gas_state.charge
        else
            @test !is_force_reactivated(comp.tank.tank)
            @test is_force_reactivated(committed.component.tank.tank)
            @test committed.component.tank.tank.state.charge == comp.tank.tank.state.charge
        end
    end
end

@testset "Tank editor values replace state and preserve placement" begin
    gas = make_gas_tank(initial_charge = 20.0)
    gas = @set gas.tank.tank.sealstate = seal(gas.tank.tank.sealstate)
    gas = @set gas.tank.tank = force_reactivate(gas.tank.tank)
    liquid = make_liquid_tank(initial_charge = 20.0)
    liquid = @set liquid.tank.stored_fluid = set_stored_fluid(liquid.tank.stored_fluid, HexFluids.FUEL_LIQUID)
    pressurefed = make_pressurefed_tank(liquid_charge = 20.0, gas_charge = -3.0)
    pressurefed = @set pressurefed.tank.liquid_sealstate = seal(pressurefed.tank.liquid_sealstate)
    pressurefed = @set pressurefed.tank.gas_sealstate = seal(pressurefed.tank.gas_sealstate)
    pressurefed = @set pressurefed.tank = force_liquid_reactivate(force_gas_reactivate(pressurefed.tank))

    for comp in (gas, liquid, pressurefed)
        placed = PlacedComponent(comp, HexFrame.S_NEG, true, :Owner)
        values = if comp isa PressureFedTankCompBehav
            (10.0, 60.0, 7.0, -2.0, 8.0, HexFluids.OXIDISER_LIQUID)
        elseif comp.tank isa LiquidTankBehavFrag
            (10.0, 60.0, 7.0, 8.0, HexFluids.OXIDISER_LIQUID)
        else
            (10.0, 60.0, 7.0, 8.0)
        end
        tuned = set_tunables(placed, values)
        @test tuned isa PlacedComponent
        @test (tuned.rotation, tuned.mirrored, tuned.ship) == (placed.rotation, true, :Owner)
        @test tuned.component.series_conductance == 8.0
        @test placed.component == comp
        if comp isa PressureFedTankCompBehav
            @test tuned.component.tank.liquid_state === TankState(7.0)
            @test comp.tank.liquid_state.charge == 20.0
            @test tuned.component.tank.gas_state === TankState(-2.0)
            @test comp.tank.gas_state.charge == -3.0
            @test tuned.component.tank.stored_liquid === StoredFluidState(HexFluids.OXIDISER_LIQUID)
            @test get_stored_fluid(comp.tank.stored_liquid) === HexFluids.MONOPROP_LIQUID
            @test tuned.component.tank.liquid_sealstate == comp.tank.liquid_sealstate
            @test tuned.component.tank.gas_sealstate == comp.tank.gas_sealstate
            @test liquid_is_force_reactivated(tuned.component.tank)
            @test gas_is_force_reactivated(tuned.component.tank)
        else
            @test tuned.component.tank.tank.state === TankState(7.0)
            @test comp.tank.tank.state.charge == 20.0
            @test tuned.component.tank.tank.sealstate == comp.tank.tank.sealstate
            @test is_force_reactivated(tuned.component.tank.tank) == is_force_reactivated(comp.tank.tank)
            if comp.tank isa LiquidTankBehavFrag
                @test tuned.component.tank.stored_fluid === StoredFluidState(HexFluids.OXIDISER_LIQUID)
                @test get_stored_fluid(comp.tank.stored_fluid) === HexFluids.FUEL_LIQUID
            end
        end
    end
end

@testset "Optional stored-fluid identity uses concrete value storage" begin
    empty = StoredFluidState(nothing)
    filled = set_stored_fluid(empty, HexFluids.FUEL_LIQUID)
    @test isbitstype(typeof(empty))
    @test typeof(empty) === typeof(filled)
    @test isnothing(get_stored_fluid(empty))
    @test get_stored_fluid(filled) === HexFluids.FUEL_LIQUID
    @test clear_stored_fluid(filled) === empty
    @test get_stored_fluid(filled) === HexFluids.FUEL_LIQUID
end
