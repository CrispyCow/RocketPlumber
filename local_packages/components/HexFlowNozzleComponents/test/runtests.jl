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

    # Only the repair action remains; no manual unstall action is exposed.
    actions = get_actions(nozzle)
    @test length(actions) == 1
    @test actions[1].id === :repair_component

    repaired, _ = do_action!(nozzle, :repair_component)
    @test repaired
    @test !is_damaged(nozzle)
end

@testset "Nozzle auto-deactivation" begin
    nozzle = NozzleBehavFrag(HexFrame.NODE_Q_POS, 0.2)

    # Nozzle is initially active.
    @test !is_inactive(nozzle)
    @test produce_rel_elements(nozzle)[1].active == true

    # deactivate! disables the nozzle element.
    deactivate!(nozzle)
    @test is_inactive(nozzle)
    @test produce_rel_elements(nozzle)[1].active == false

    # reactivate! restores the element.
    reactivate!(nozzle)
    @test !is_inactive(nozzle)
    @test produce_rel_elements(nozzle)[1].active == true
end

@testset "Nozzle deactivates on reverse pressure" begin
    nozzle = NozzleBehavFrag(HexFrame.NODE_Q_POS, 0.2)
    tile = TEST_TILE
    rotation = TEST_ROTATION

    # Positive pressure: nozzle stays active.
    mna_fwd = MNA_State()
    set_node_voltage!(mna_fwd, tile, nozzle.connected_node, 10.0; rotation = rotation)
    derivedmapstate = DerivedMapState()
    update_flowbehav!(nozzle; tile = tile, rotation = rotation, mna_state = mna_fwd, derivedmapstate = derivedmapstate)
    @test !is_inactive(nozzle)

    # Negative pressure beyond tolerance: nozzle deactivates.
    mna_rev = MNA_State()
    set_node_voltage!(mna_rev, tile, nozzle.connected_node, -1.0; rotation = rotation)
    update_flowbehav!(nozzle; tile = tile, rotation = rotation, mna_state = mna_rev, derivedmapstate = derivedmapstate)
    @test is_inactive(nozzle)
end

@testset "Nozzle reactivation probe" begin
    nozzle = NozzleBehavFrag(HexFrame.NODE_Q_POS, 0.2)
    tile = TEST_TILE
    rotation = TEST_ROTATION

    # Active nozzle returns no probe.
    @test isnothing(get_reactivation_probe(nozzle; tile = tile, rotation = rotation))

    # Deactivated (not damaged) nozzle returns a one-element probe.
    deactivate!(nozzle)
    probe = get_reactivation_probe(nozzle; tile = tile, rotation = rotation)
    @test probe isa ReactivationProbe
    @test length(probe.rel_elements) == 1
    @test probe.rel_elements[1].active == true

    # Damaged nozzle returns no probe even when deactivated.
    damage!(nozzle)
    @test isnothing(get_reactivation_probe(nozzle; tile = tile, rotation = rotation))
end

@testset "Nozzle accept_reactivation_probe!" begin
    tile = TEST_TILE
    rotation = TEST_ROTATION

    # Build absolute probe element and inject a positive current via a mock derived state.
    function make_probe_state(nozzle::NozzleBehavFrag; pressure::Float64)
        probe_rel_elem = RelativeElement(
            RelativeElementConnections(nozzle.connected_node, HexFrame.GROUND),
            nozzle.throat_area^2,
            HexElements.CONST_RESISTOR;
            active = true
        )
        probe_abs_elem = map_element(probe_rel_elem, tile, 1, rotation)
        input_node = map_element(nozzle.connected_node, tile, rotation)
        mna_state = MNA_State()
        mna_state.node_voltages[input_node] = pressure
        derivedmapstate = DerivedMapState(
            filteredelements = [probe_abs_elem],
            filterednodes = list_nodes([probe_abs_elem])
        )
        return mna_state, derivedmapstate
    end

    # Positive probe current → accept and reactivate.
    nozzle_accept = NozzleBehavFrag(HexFrame.NODE_Q_POS, 0.2)
    deactivate!(nozzle_accept)
    mna_pos, dm_pos = make_probe_state(nozzle_accept; pressure = 5.0)
    @test accept_reactivation_probe!(nozzle_accept; tile = tile, rotation = rotation, derivedmapstate = dm_pos, mna_state = mna_pos)
    @test !is_inactive(nozzle_accept)

    # Negative probe current → reject; state unchanged.
    nozzle_reject = NozzleBehavFrag(HexFrame.NODE_Q_POS, 0.2)
    deactivate!(nozzle_reject)
    mna_neg, dm_neg = make_probe_state(nozzle_reject; pressure = -5.0)
    @test !accept_reactivation_probe!(nozzle_reject; tile = tile, rotation = rotation, derivedmapstate = dm_neg, mna_state = mna_neg)
    @test is_inactive(nozzle_reject)

    # Zero (neutral) probe current → reject (not > probe_tol).
    nozzle_neutral = NozzleBehavFrag(HexFrame.NODE_Q_POS, 0.2)
    deactivate!(nozzle_neutral)
    mna_zero, dm_zero = make_probe_state(nozzle_neutral; pressure = 0.0)
    @test !accept_reactivation_probe!(nozzle_neutral; tile = tile, rotation = rotation, derivedmapstate = dm_zero, mna_state = mna_zero)
    @test is_inactive(nozzle_neutral)

    # Pruned element (not in filteredelements) → reject.
    nozzle_pruned = NozzleBehavFrag(HexFrame.NODE_Q_POS, 0.2)
    deactivate!(nozzle_pruned)
    @test !accept_reactivation_probe!(nozzle_pruned; tile = tile, rotation = rotation, derivedmapstate = DerivedMapState(), mna_state = MNA_State())
    @test is_inactive(nozzle_pruned)
end

@testset "Nozzle thrust temperature scaling" begin
    nozzle = NozzleBehavFrag(HexFrame.NODE_Q_POS, 0.2)

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

    # Clicking an auto-deactivated switched nozzle always toggles the switch.
    deactivate!(comp.nozzle)
    on_click!(comp)
    @test comp.switch.switch.state.target_conductance ≈ comp.switch.switch.max_conductance
    @test is_inactive(comp.nozzle)  # deactivation state unchanged by click

    # No :unstall action is exposed on a switched nozzle.
    action_ids = Set(action.id for action in get_actions(comp))
    @test :unstall ∉ action_ids
    @test :open_valve ∈ action_ids || :close_valve ∈ action_ids
end

@testset "Basic nozzle has no :unstall action" begin
    basic = make_basic_nozzle()
    action_ids = Set(action.id for action in get_actions(basic))
    @test :unstall ∉ action_ids
    # No click action expected either.
    on_click!(basic)  # should be a no-op, not error
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
