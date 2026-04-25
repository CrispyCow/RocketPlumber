using Test
using HexFrame
using HexElements
using HexFluids
using HexComponentsAPI
using FlowEngine
using HexFlowBasicComponents
using HexFlowPumpComponents
using HexFlowSwitchComponents

using HexElements: CONST_RESISTOR, CONST_VOLTAGE
using HexFlowPumpComponents: EnergyStoreBehavFrag, RotorStateBehavFrag, get_current_energy, get_max_energy, update_energy!, get_current_rpm, get_rpm_fraction, update_rpm!, effective_turbine_conductance

const TEST_TILE = TileCoord(3, -2)
const TEST_ROTATION = HexFrame.Q_POS

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

"Write a node voltage into the mock MNA state."
function set_node_voltage!(mna_state::MNA_State, tile::TileCoord, node, voltage::Float64; rotation::HexAxis = TEST_ROTATION)
    mna_state.node_voltages[map_element(node, tile, rotation)] = voltage
    return mna_state
end

"Populate a minimal derived map state with the turbine-side fluid tag and temperature."
function make_derived_state(
        tile::TileCoord = TEST_TILE;
        rotation::HexAxis = TEST_ROTATION,
        fluid::HexFluids.FluidType = HexFluids.COLD_GAS,
        temperature_k::Float64 = HexFluids.THERMAL_AMBIENT_TEMPERATURE_K
    )
    turbine_input_node = map_element(HexFrame.NODE_S_POS, tile, rotation)
    nodeactualfluids = Dict{NodeCoord, HexFluids.FluidType}(turbine_input_node => fluid)
    node_temperatures = Dict{NodeCoord, Float64}(turbine_input_node => temperature_k)
    return DerivedMapState(nodeactualfluids = nodeactualfluids, node_temperatures = node_temperatures)
end

const TURBOPUMP_STATIC_FRICTION_BIAS = 200.0

"Compute the turbopump's per-tick friction power using the same static bias as the implementation."
turbopump_friction_power(comp::TurboPumpCompBehav, rpm::Float64)::Float64 = comp.rotor.friction_coefficient * (rpm + TURBOPUMP_STATIC_FRICTION_BIAS)

"Construct a representative variable-conductance turbopump for tests."
function make_turbopump(
        ;
        max_pump_voltage::Float64 = 50.0,
        series_conductance::Float64 = 1.0,
    max_turbine_conductance::Float64 = 0.3,
    cycle_efficiency::Float64 = 0.6,
        current_rpm::Float64 = 0.0,
        max_rpm::Float64 = 3000.0,
    rotor_inertia::Float64 = 1000.0,
    friction_coefficient::Float64 = 0.005,
        stall_state::StallBehavFrag = StallBehavFrag()
    )
    return TurboPumpCompBehav(
        max_pump_voltage = max_pump_voltage,
        series_conductance = series_conductance,
        max_turbine_conductance = max_turbine_conductance,
        cycle_efficiency = cycle_efficiency,
        current_rpm = current_rpm,
        max_rpm = max_rpm,
        rotor_inertia = rotor_inertia,
        friction_coefficient = friction_coefficient,
        stall_state = stall_state
    )
end

"Construct an electric pump variant for regression coverage."
function make_electric_pump(
        ::Type{T};
        pump_voltage::Float64 = 50.0,
        max_energy::Float64 = 200.0,
        initial_energy::Float64 = 200.0,
        max_conductance::Float64 = 1.0,
        min_conductance::Float64 = 0.0,
        growth_factor::Float64 = calculate_growth_factor(1.0, 0.0, 1.0 / BASE_UPS)
    ) where {T}
    return ElectricPumpCompBehav(
        T;
        pump_voltage = pump_voltage,
        max_energy = max_energy,
        initial_energy = initial_energy,
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        growth_factor = growth_factor
    )
end

@testset "Pump fragment" begin
    pump = PumpBehavFrag(50.0)
    powered = produce_rel_elements(pump, true)
    unpowered = produce_rel_elements(pump, false)

    @test powered[1].type === CONST_VOLTAGE
    @test powered[1].connections == RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.NODE_Q_POS)
    @test powered[1].value ≈ 50.0
    @test unpowered[1].value == 0.0
    @test HexFlowPumpComponents.get_scaled_pump_voltage(pump, 0.5) ≈ 25.0

    tuned = set_tunables(pump, (35.0,))
    @test tuned.pump_voltage ≈ 35.0
end

@testset "Energy and rotor fragments" begin
    energy = EnergyStoreBehavFrag(FloatStateBehavFrag(20.0), 50.0)
    update_energy!(energy, 10.0)
    @test get_current_energy(energy) ≈ 30.0
    update_energy!(energy, 50.0)
    @test get_current_energy(energy) ≈ get_max_energy(energy)
    update_energy!(energy, -100.0)
    @test get_current_energy(energy) == 0.0

    rotor = RotorStateBehavFrag(current_rpm = 7000.0, max_rpm = 3000.0, rotor_inertia = 0.1, friction_coefficient = 0.001)
    @test get_current_rpm(rotor) == 3000.0  # keyword constructor clamps to [0, max_rpm]
    @test get_rpm_fraction(rotor) == 1.0
    update_rpm!(rotor, -1500.0)
    @test get_current_rpm(rotor) == 1500.0
    update_rpm!(rotor, -10_000.0)
    @test get_current_rpm(rotor) == 0.0

    # RPM can exceed max_rpm via update_rpm! (no upper clamp — conductance limiting handles ceiling)
    update_rpm!(rotor, 5000.0)
    @test get_current_rpm(rotor) == 5000.0
    @test get_rpm_fraction(rotor) == 1.0  # rpm_fraction is clamped to [0, 1]

    applied_rotor_inertia = rotor.rotor_inertia * HexFlowPumpComponents.TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    @test applied_rotor_inertia ≈ 1.0e-4

    clamped_rotor = RotorStateBehavFrag(current_rpm = 5.0, max_rpm = 0.0, rotor_inertia = 0.0, friction_coefficient = -1.0)
    @test clamped_rotor.max_rpm == 1.0e-6
    @test clamped_rotor.rotor_inertia == 1.0e-6
    @test clamped_rotor.friction_coefficient == 1.0e-6
    @test get_current_rpm(clamped_rotor) == 0.0
end

@testset "Turbo pump component" begin
    comp = make_turbopump(current_rpm = 1500.0)
    elements = produce_rel_elements(comp)

    # At 1500/3000 RPM: pump voltage = 50 × 0.5 = 25, turbine G follows the non-linear rpm_frac^0.7 curve.
    @test length(elements) == 3
    @test elements[1].type === CONST_VOLTAGE
    @test elements[1].connections == RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.NODE_Q_POS)
    @test elements[1].value ≈ 25.0
    @test elements[2].type === CONST_RESISTOR
    @test elements[2].connections == RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.NODE_Q_NEG)
    @test elements[2].value ≈ 1.0
    @test elements[3].type === CONST_RESISTOR
    @test elements[3].connections == RelativeElementConnections(HexFrame.NODE_S_POS, HexFrame.GROUND)
    @test elements[3].value ≈ effective_turbine_conductance(comp)
    @test all(elem.active for elem in elements)

    stall!(comp.stall_state)
    stalled_elements = produce_rel_elements(comp)
    @test all(!elem.active for elem in stalled_elements)
    unstall!(comp.stall_state)

    tunables = get_tunables(comp)
    @test tunables isa NTuple{8, TunableProps}
    original_rpm_state = comp.rotor.rpm
    tuned = set_tunables(comp, (60.0, 2.0, 0.6, 3500.0, 3500.0, 400.0, 0.5, 0.90))
    @test tuned.rotor.rpm === original_rpm_state
    @test tuned.max_pump_voltage ≈ 60.0
    @test tuned.series_conductance ≈ 2.0
    @test tuned.max_turbine_conductance ≈ 0.6
    @test get_current_rpm(tuned.rotor) ≈ 3500.0
    @test tuned.rotor.max_rpm ≈ 3500.0
    @test tuned.rotor.rotor_inertia ≈ 400.0
    @test tuned.rotor.friction_coefficient ≈ 0.5
    @test tuned.cycle_efficiency ≈ 0.90

    decls = produce_rel_fluid_declarations(comp)
    @test length(decls) == 3
    @test decls[1] === RelativeFluidDeclaration(HexFrame.NODE_Q_POS, FluidConstraintRule(HexFluids.IS_LIQUID))
    @test decls[2] === RelativeFluidDeclaration(HexFrame.NODE_Q_NEG, FluidConstraintRule(HexFluids.IS_LIQUID))
    @test decls[3] === RelativeFluidDeclaration(HexFrame.NODE_S_POS, FluidConstraintRule(HexFluids.IS_GAS))

    stall!(comp.stall_state)
    actions = get_actions(comp)
    @test length(actions) == 1
    @test actions[1].id === :unstall
    success, _ = do_action!(comp, :unstall)
    @test success
    @test !is_stalled(comp.stall_state)

    stall!(comp.stall_state)
    on_click!(comp)
    @test !is_stalled(comp.stall_state)
end

@testset "Turbo pump RPM updates" begin
    # Friction-only decay (no gas, no pump load)
    # Use high inertia / low friction so single-tick delta stays within positive RPM range
    friction_only = make_turbopump(current_rpm = 1200.0, rotor_inertia = 6000.0, friction_coefficient = 0.1)
    update_flowbehav!(friction_only; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = MNA_State(), derivedmapstate = make_derived_state())
    applied_inertia = friction_only.rotor.rotor_inertia * HexFlowPumpComponents.TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    friction_power = turbopump_friction_power(friction_only, 1200.0)
    friction_expected = 1200.0 - friction_power / (applied_inertia * BASE_UPS)
    @test get_current_rpm(friction_only.rotor) ≈ friction_expected

    # Spin-up from rest with gas at S_POS (max turbine conductance at 0 RPM)
    spun_up = make_turbopump(current_rpm = 0.0)
    spinup_mna = MNA_State()
    set_node_voltage!(spinup_mna, TEST_TILE, HexFrame.NODE_S_POS, 5.0)
    spinup_derived = make_derived_state(fluid = HexFluids.MONOPROP_GAS, temperature_k = 800.0)
    update_flowbehav!(spun_up; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = spinup_mna, derivedmapstate = spinup_derived)
    turbine_g = spun_up.max_turbine_conductance  # at 0 RPM, G = max
    turbine_current = 5.0 * turbine_g
    density = HexFluids.lookup_fluid_density(HexFluids.COLD_GAS)::Float64
    temperature_change_k = 800.0 - HexFluids.THERMAL_AMBIENT_TEMPERATURE_K
    turbine_power = density * turbine_current * temperature_change_k * HexFlowPumpComponents.TURBOPUMP_TURBINE_TEMPERATURE_POWER_SCALING
    spinup_applied_inertia = spun_up.rotor.rotor_inertia * HexFlowPumpComponents.TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    spinup_friction = turbopump_friction_power(spun_up, 0.0)
    spinup_expected = (spun_up.cycle_efficiency * turbine_power - spinup_friction) / (spinup_applied_inertia * BASE_UPS)
    @test get_current_rpm(spun_up.rotor) ≈ spinup_expected

    # Ambient-temperature gas should not add turbine power.
    ambient_gas = make_turbopump(current_rpm = 1200.0, rotor_inertia = 6000.0, friction_coefficient = 0.1)
    ambient_gas_mna = MNA_State()
    set_node_voltage!(ambient_gas_mna, TEST_TILE, HexFrame.NODE_S_POS, 40.0)
    ambient_gas_derived = make_derived_state(temperature_k = HexFluids.THERMAL_AMBIENT_TEMPERATURE_K)
    update_flowbehav!(ambient_gas; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = ambient_gas_mna, derivedmapstate = ambient_gas_derived)
    ambient_applied_inertia = ambient_gas.rotor.rotor_inertia * HexFlowPumpComponents.TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    ambient_friction = turbopump_friction_power(ambient_gas, 1200.0)
    ambient_expected = 1200.0 - ambient_friction / (ambient_applied_inertia * BASE_UPS)
    @test get_current_rpm(ambient_gas.rotor) ≈ ambient_expected

    # Loaded pump (50% RPM, pump current, no gas input)
    loaded = make_turbopump(current_rpm = 1500.0, rotor_inertia = 6000.0, friction_coefficient = 0.1)
    loaded_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    loaded_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -5.0
    update_flowbehav!(loaded; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = loaded_mna, derivedmapstate = make_derived_state())
    load_applied_inertia = loaded.rotor.rotor_inertia * HexFlowPumpComponents.TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    pump_voltage = loaded.max_pump_voltage * 0.5  # rpm_fraction = 0.5
    pump_power = pump_voltage * 5.0
    load_friction = turbopump_friction_power(loaded, 1500.0)
    load_expected = 1500.0 + (-pump_power - load_friction) / (load_applied_inertia * BASE_UPS)
    @test get_current_rpm(loaded.rotor) ≈ load_expected

    # Back-drive stalls the pump; RPM decays via friction only
    reversed = make_turbopump(current_rpm = 1200.0, rotor_inertia = 6000.0, friction_coefficient = 0.1)
    reversed_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    reversed_mna.vsource_currents[ElementID(TEST_TILE, 1)] = 0.5
    update_flowbehav!(reversed; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = reversed_mna, derivedmapstate = make_derived_state())
    reversed_applied_inertia = reversed.rotor.rotor_inertia * HexFlowPumpComponents.TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    reversed_friction = turbopump_friction_power(reversed, 1200.0)
    reversed_expected = 1200.0 - reversed_friction / (reversed_applied_inertia * BASE_UPS)
    @test is_stalled(reversed.stall_state)
    @test get_current_rpm(reversed.rotor) ≈ reversed_expected

    # Normal startup: negative pump current + gas pressure = spin-up
    startup = make_turbopump(current_rpm = 0.0)
    startup_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    startup_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -0.3
    set_node_voltage!(startup_mna, TEST_TILE, HexFrame.NODE_S_POS, 40.0)
    update_flowbehav!(startup; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = startup_mna, derivedmapstate = make_derived_state(fluid = HexFluids.MONOPROP_GAS, temperature_k = 800.0))
    @test !is_stalled(startup.stall_state)
    @test get_current_rpm(startup.rotor) > 0.0

    # Post-tick element contract: pump voltage tracks RPM fraction
    contract_comp = make_turbopump(current_rpm = 0.0)
    contract_mna = MNA_State()
    set_node_voltage!(contract_mna, TEST_TILE, HexFrame.NODE_S_POS, 50.0)
    update_flowbehav!(contract_comp; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = contract_mna, derivedmapstate = make_derived_state(fluid = HexFluids.MONOPROP_GAS, temperature_k = 800.0))
    contract_elements = produce_rel_elements(contract_comp)
    @test get_current_rpm(contract_comp.rotor) > 0.0
    @test contract_elements[1].value ≈ contract_comp.max_pump_voltage * get_rpm_fraction(contract_comp.rotor)

    # Missing previous-tick fluid data should behave like no turbine drive, not crash.
    missing_fluid = make_turbopump(current_rpm = 1200.0, rotor_inertia = 6000.0, friction_coefficient = 0.1)
    missing_fluid_mna = MNA_State()
    set_node_voltage!(missing_fluid_mna, TEST_TILE, HexFrame.NODE_S_POS, 40.0)
    update_flowbehav!(missing_fluid; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = missing_fluid_mna, derivedmapstate = DerivedMapState())
    missing_expected = 1200.0 - reversed_friction / (reversed_applied_inertia * BASE_UPS)
    @test get_current_rpm(missing_fluid.rotor) ≈ missing_expected
end

@testset "Variable conductance" begin
    # At 0 RPM: full max_turbine_conductance
    comp_zero = make_turbopump(current_rpm = 0.0)
    @test effective_turbine_conductance(comp_zero) ≈ comp_zero.max_turbine_conductance

    # At half RPM, conductance follows the non-linear exponent curve.
    comp_half = make_turbopump(current_rpm = 1500.0, max_rpm = 3000.0)
    @test effective_turbine_conductance(comp_half) ≈ comp_half.max_turbine_conductance * (1.0 - 0.5^0.7)

    # At max RPM: zero conductance
    comp_max = make_turbopump(current_rpm = 3000.0, max_rpm = 3000.0)
    @test effective_turbine_conductance(comp_max) ≈ 0.0

    # Elements at max RPM have zero turbine conductance
    elems_max = produce_rel_elements(comp_max)
    @test elems_max[3].value ≈ 0.0

    # Transient overshoot: rpm_fraction clamped to 1.0 so pump voltage ≤ max
    overshoot = make_turbopump(current_rpm = 2900.0, max_rpm = 3000.0)
    update_rpm!(overshoot.rotor, 200.0)  # push above max_rpm
    @test get_current_rpm(overshoot.rotor) ≈ 3100.0
    @test get_rpm_fraction(overshoot.rotor) == 1.0
    elems_overshoot = produce_rel_elements(overshoot)
    @test elems_overshoot[1].value ≈ overshoot.max_pump_voltage  # capped at max
    @test elems_overshoot[3].value ≈ 0.0  # conductance zero above max_rpm
end

@testset "Electric pump regression coverage" begin
    turbo_electric = make_electric_pump(ElectricTurboPump)
    transfer_electric = make_electric_pump(ElectricTransferPump; pump_voltage = 5.0, max_conductance = 0.5, growth_factor = calculate_growth_factor(0.5, 0.0, 0.4 / BASE_UPS))

    turbo_elements = produce_rel_elements(turbo_electric)
    @test length(turbo_elements) == 2
    @test turbo_elements[1].type === CONST_VOLTAGE
    @test turbo_elements[2].type === CONST_RESISTOR
    turbo_decls = produce_rel_fluid_declarations(turbo_electric)
    @test length(turbo_decls) == 2
    @test turbo_decls[1] === RelativeFluidDeclaration(HexFrame.NODE_Q_POS, FluidConstraintRule(HexFluids.IS_LIQUID))
    @test turbo_decls[2] === RelativeFluidDeclaration(HexFrame.NODE_Q_NEG, FluidConstraintRule(HexFluids.IS_LIQUID))
    transfer_decls = produce_rel_fluid_declarations(transfer_electric)
    @test length(transfer_decls) == 2
    @test transfer_decls[1] === RelativeFluidDeclaration(HexFrame.NODE_Q_POS, FluidConstraintRule(HexFluids.IS_LIQUID))
    @test transfer_decls[2] === RelativeFluidDeclaration(HexFrame.NODE_Q_NEG, FluidConstraintRule(HexFluids.IS_LIQUID))

    turbo_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    turbo_mna.vsource_currents[ElementID(TEST_TILE, 1)] = 2.0
    update_flowbehav!(turbo_electric; tile = TEST_TILE, mna_state = turbo_mna)
    @test get_current_energy(turbo_electric.energy) ≈ 100.0

    tuned_electric = set_tunables(turbo_electric, (40.0, 50.0, 100.0, 0.8, 0.0))
    @test tuned_electric.pump.pump_voltage ≈ 40.0
    @test get_current_energy(tuned_electric.energy) ≈ 50.0
    @test get_max_energy(tuned_electric.energy) ≈ 100.0

    action_ids = Set(action.id for action in get_actions(turbo_electric))
    @test action_ids == Set((:pump_on, :pump_off))

    empty_electric = make_electric_pump(ElectricTransferPump; pump_voltage = 5.0, max_energy = 10.0, initial_energy = 0.0, max_conductance = 0.5, growth_factor = calculate_growth_factor(0.5, 0.0, 0.4 / BASE_UPS))
    on_click!(empty_electric)
    @test get_current_energy(empty_electric.energy) == 0.0
end