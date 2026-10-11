#=
Scope: Nozzle and combustion-chamber component behaviour tests
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"

using Test
using Accessors
using HexFrame
using HexElements
using HexFluids
using FlowEngine
using FlowMap
using HexComponentsAPI
using HexFlowBasicComponents
using HexFlowNozzleComponents
using HexFlowSwitchComponents
using HexFlowRendering, RenderEngine, StaticArrays

const TEST_TILE = TileCoord(3, -2)
const TEST_ROTATION = HexFrame.Q_POS

"Set a node voltage in the mock MNA state."
function set_node_voltage!(
        mna_state::MNA_State, tile::TileCoord, node, voltage::Float64;
        rotation::HexAxis = TEST_ROTATION, mirrored::Bool = false
    )
    mna_state.node_voltages[map_element(node, tile, rotation, mirrored)] = voltage
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
        sprite_variant = TINY_NOZZLE_SPRITE,
        limit_temperature_k = limit_temperature_k
    )
end

@testset "Nozzle placement guidance" begin
    gamemap = GameMap()
    set_surface_tile!(gamemap, TileCoord(0, 0))
    expected = "Nozzles must be placed on a ship edge with their input connected to the surface"

    for nozzle in (make_basic_nozzle(), make_switched_nozzle())
        on_surface = placement_valid(nozzle, TileCoord(0, 0), gamemap; rotation = HexFrame.Q_POS)
        @test !isvalidrequest(on_surface)
        @test reason(on_surface) == expected

        disconnected = placement_valid(nozzle, TileCoord(10, 10), gamemap; rotation = HexFrame.Q_POS)
        @test !isvalidrequest(disconnected)
        @test reason(disconnected) == expected
    end
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

@testset "Biprop chamber mirroring" begin
    comp = BipropChamberCompBehav()
    @test map_mirroring(comp, true)

    mirrored = PlacedComponent(comp, TEST_ROTATION, true, :primary)
    abs_elements = produce_abs_elements(mirrored, TEST_TILE)
    @test abs_elements[5].connections.v1 == map_element(HexFrame.NODE_S_NEG, TEST_TILE, TEST_ROTATION)
    @test abs_elements[6].connections.v1 == map_element(HexFrame.NODE_R_NEG, TEST_TILE, TEST_ROTATION)
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
    nozzle = update_flowbehav(nozzle; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = mna_state, derivedmapstate = derivedmapstate)

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

    nozzle, result = do_action(nozzle, :repair_component)
    @test isvalidrequest(result)
    @test !is_damaged(nozzle)
end

@testset "Nozzle auto-deactivation" begin
    nozzle = NozzleBehavFrag(HexFrame.NODE_Q_POS, 0.2)

    # Nozzle is initially active.
    @test !is_inactive(nozzle)
    @test produce_rel_elements(nozzle)[1].active == true

    # deactivate disables the nozzle element.
    nozzle = deactivate(nozzle)
    @test is_inactive(nozzle)
    @test produce_rel_elements(nozzle)[1].active == false

    # reactivate restores the element.
    nozzle = reactivate(nozzle)
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
    nozzle = update_flowbehav(nozzle; tile = tile, rotation = rotation, mna_state = mna_fwd, derivedmapstate = derivedmapstate)
    @test !is_inactive(nozzle)

    # Negative pressure beyond tolerance: nozzle deactivates.
    mna_rev = MNA_State()
    set_node_voltage!(mna_rev, tile, nozzle.connected_node, -1.0; rotation = rotation)
    nozzle = update_flowbehav(nozzle; tile = tile, rotation = rotation, mna_state = mna_rev, derivedmapstate = derivedmapstate)
    @test is_inactive(nozzle)
end

@testset "Nozzle reactivation probe" begin
    nozzle = NozzleBehavFrag(HexFrame.NODE_Q_POS, 0.2)
    tile = TEST_TILE
    rotation = TEST_ROTATION

    # Active nozzle returns no probe.
    @test isnothing(get_reactivation_probe(nozzle; tile = tile, rotation = rotation))

    # Deactivated (not damaged) nozzle returns a one-element probe.
    nozzle = deactivate(nozzle)
    probe = get_reactivation_probe(nozzle; tile = tile, rotation = rotation)
    @test probe isa ReactivationProbe
    @test length(probe.rel_elements) == 1
    @test probe.rel_elements[1].active == true

    # Damaged nozzle returns no probe even when deactivated.
    nozzle = damage(nozzle)
    @test isnothing(get_reactivation_probe(nozzle; tile = tile, rotation = rotation))
end

@testset "Nozzle classify_reactivation_probe and commit_reactivation_probe" begin
    tile = TEST_TILE
    rotation = TEST_ROTATION

    active = NozzleBehavFrag(HexFrame.NODE_Q_POS, 0.2)
    inactive = deactivate(active)
    for (pressure, expected) in ((5.0, PROBE_USEFUL), (-5.0, PROBE_HARMFUL), (0.0, PROBE_NEUTRAL))
        @testset "Probe pressure $pressure" begin
            # The speculative solve includes the active element while the live nozzle remains inactive
            mna, derived = make_nozzle_state(active; pressure = pressure)
            @test classify_reactivation_probe(inactive; tile = tile, rotation = rotation, derivedmapstate = derived, mna_state = mna) === expected
            @test is_inactive(inactive)
            if expected === PROBE_USEFUL
                committed = commit_reactivation_probe(inactive; tile = tile, rotation = rotation, derivedmapstate = derived, mna_state = mna)
                @test !is_inactive(committed)
            end
        end
    end

    # Pruned element (not in filteredelements) → neutral.
    @test classify_reactivation_probe(inactive; tile = tile, rotation = rotation, derivedmapstate = DerivedMapState(), mna_state = MNA_State()) === PROBE_NEUTRAL
    @test is_inactive(inactive)
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
    basic = update_flowbehav(basic; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = basic_mna_state, derivedmapstate = basic_derivedmapstate)

    @test get_component_temperature(basic) === get_component_temperature(basic.nozzle)

    tile_component = PlacedComponent(basic, TEST_ROTATION, :primary)
    @test get_component_temperature(tile_component) === get_component_temperature(basic)

    switched = make_switched_nozzle()
    switched_mna_state, switched_derivedmapstate = make_nozzle_state(switched.nozzle; temperature_k = 925.0)
    switched = update_flowbehav(switched; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = switched_mna_state, derivedmapstate = switched_derivedmapstate)

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
    @test tunables[4].type_desc == "Heat Loss Factor"
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
    @test tuned.nozzle.overheat.heat_loss_factor ≈ 7.0
    @test tuned.switch.switch.max_conductance ≈ 3.0
    @test tuned.switch.switch.min_conductance ≈ 0.1

    # Clicking an auto-deactivated switched nozzle always toggles the switch.
    comp = @set comp.nozzle = deactivate(comp.nozzle)
    comp = on_click(comp)
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
    basic = on_click(basic)  # should be a no-op, not error
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

@testset "Bipropellant combustion chamber structure and tunables" begin
    comp = BipropChamberCompBehav()
    @test comp.fuel_conductance == 0.4
    @test comp.oxid_conductance == 1.0
    @test comp.r_optimal == 2.5
    @test comp.state.output_temperature_k == HexFlowNozzleComponents.BIPROP_NONCOMBUSTION_MIN_TEMPERATURE_K
    @test !is_inactive(comp.state.auto_deactivation)
end

@testset "Bipropellant combustion chamber produces 6 elements" begin
    comp = BipropChamberCompBehav()
    elements = produce_rel_elements(comp)
    @test length(elements) == 6

    # Element 1 & 2: VCVS sources (one per propellant)
    @test elements[1].value == 1.0 && elements[1].type == HexElements.V_DEP_VOLTAGE
    @test elements[2].value == 1.0 && elements[2].type == HexElements.V_DEP_VOLTAGE

    # Element 3 & 4: CCCS sinks (one per propellant)
    @test elements[3].type == HexElements.C_DEP_CURRENT
    @test elements[4].type == HexElements.C_DEP_CURRENT

    # Element 5 & 6: Orifice resistors (one per propellant)
    @test elements[5].value == 0.4 && elements[5].type == HexElements.CONST_RESISTOR
    @test elements[6].value == 1.0 && elements[6].type == HexElements.CONST_RESISTOR
end

@testset "Bipropellant combustion chamber fluid declarations" begin
    comp = BipropChamberCompBehav()
    decls = produce_rel_fluid_declarations(comp)

    @test length(decls) == 3
    @test decls[1] === RelativeFluidDeclaration(HexFrame.NODE_R_NEG, FluidTypeRule(HexFluids.FUEL_LIQUID))
    @test decls[2] === RelativeFluidDeclaration(HexFrame.NODE_S_NEG, FluidTypeRule(HexFluids.OXIDISER_LIQUID))
    @test decls[3] === RelativeFluidDeclaration(HexFrame.NODE_Q_NEG, FluidSource(HexFluids.BIPROP_EXHAUST, HexFlowNozzleComponents.BIPROP_NONCOMBUSTION_MIN_TEMPERATURE_K))
end

@testset "Bipropellant combustion chamber tunables" begin
    comp = BipropChamberCompBehav(fuel_conductance = 0.5, oxid_conductance = 1.2, r_optimal = 3.0)

    tunables = get_tunables(comp)
    @test tunables isa NTuple{3, TunableProps}
    @test tunables[1].current_val ≈ 0.5
    @test tunables[2].current_val ≈ 1.2
    @test tunables[3].current_val ≈ 3.0

    tuned_comp = set_tunables(comp, (0.3, 0.9, 2.7))
    @test tuned_comp.fuel_conductance ≈ 0.3
    @test tuned_comp.oxid_conductance ≈ 0.9
    @test tuned_comp.r_optimal ≈ 2.7
end

@testset "Bipropellant combustion chamber flow ratio at equal pressures" begin
    # This is the critical correctness test: at equal input pressures, verify Q_o/Q_f ≈ 2.5
    comp = BipropChamberCompBehav(fuel_conductance = 0.4, oxid_conductance = 1.0)

    # Build a mock circuit state with equal pressures on both input nodes
    tile = TEST_TILE
    rotation = TEST_ROTATION

    # Set equal pressures on fuel and oxidiser input nodes (both at 100V)
    mna_state = MNA_State()
    set_node_voltage!(mna_state, tile, HexFrame.NODE_R_NEG, 100.0; rotation = rotation)   # fuel input
    set_node_voltage!(mna_state, tile, HexFrame.NODE_S_NEG, 100.0; rotation = rotation)   # oxid input
    set_node_voltage!(mna_state, tile, HexFrame.NODE_INTERNAL_1, 50.0; rotation = rotation)  # internal fuel node (voltage drop across orifice)
    set_node_voltage!(mna_state, tile, HexFrame.NODE_INTERNAL_2, 50.0; rotation = rotation)  # internal oxid node
    set_node_voltage!(mna_state, tile, HexFrame.NODE_Q_NEG, 0.0; rotation = rotation)   # output

    # Simulate current flow through both VCVS elements (fuel and oxid proportional to their conductances)
    # At equal internal pressures (50V), volumetric flow through orifice is proportional to conductance times pressure diff
    fuel_current = 0.4 * (100.0 - 50.0)  # G_f * ΔP_f = 0.4 * 50 = 20.0
    oxid_current = 1.0 * (100.0 - 50.0)  # G_o * ΔP_o = 1.0 * 50 = 50.0

    # Record in vsource_currents (indexed by element ID at indices 1 and 2)
    mna_state.vsource_currents[ElementID(tile, 1)] = fuel_current
    mna_state.vsource_currents[ElementID(tile, 2)] = oxid_current

    # Mock derivedmapstate with fluid assignments
    derivedmapstate = DerivedMapState()
    fuel_node = map_element(HexFrame.NODE_R_NEG, tile, rotation)
    oxid_node = map_element(HexFrame.NODE_S_NEG, tile, rotation)
    output_node = map_element(HexFrame.NODE_Q_NEG, tile, rotation)

    derivedmapstate.nodeactualfluids[fuel_node] = HexFluids.FUEL_LIQUID
    derivedmapstate.nodeactualfluids[oxid_node] = HexFluids.OXIDISER_LIQUID
    derivedmapstate.nodeactualfluids[output_node] = HexFluids.BIPROP_EXHAUST

    # Update flow behaviour and check temperature curve peak
    comp = update_flowbehav(comp; rotation = rotation, tile = tile, mna_state = mna_state, derivedmapstate = derivedmapstate)

    # At 2.5:1 flow ratio, the temperature should be at peak (2300K)
    @test comp.state.output_temperature_k ≈ 2300.0 atol = 1.0e-6
end

@testset "Bipropellant combustion chamber backflow deactivation" begin
    comp = BipropChamberCompBehav()
    tile = TEST_TILE
    rotation = TEST_ROTATION

    mna_state = MNA_State()
    derivedmapstate = DerivedMapState()

    # Test fuel backflow
    mna_state.vsource_currents[ElementID(tile, 1)] = -0.05  # Negative fuel current
    mna_state.vsource_currents[ElementID(tile, 2)] = 0.0

    comp = update_flowbehav(comp; rotation = rotation, tile = tile, mna_state = mna_state, derivedmapstate = derivedmapstate)
    @test is_inactive(comp.state.auto_deactivation)
    @test comp.state.output_temperature_k == HexFlowNozzleComponents.BIPROP_NONCOMBUSTION_MIN_TEMPERATURE_K

    # Reset and test oxidiser backflow
    comp = BipropChamberCompBehav()
    mna_state.vsource_currents[ElementID(tile, 1)] = 0.0
    mna_state.vsource_currents[ElementID(tile, 2)] = -0.05  # Negative oxid current

    comp = update_flowbehav(comp; rotation = rotation, tile = tile, mna_state = mna_state, derivedmapstate = derivedmapstate)
    @test is_inactive(comp.state.auto_deactivation)
    @test comp.state.output_temperature_k == HexFlowNozzleComponents.BIPROP_NONCOMBUSTION_MIN_TEMPERATURE_K
end

@testset "Bipropellant combustion chamber non-combustion floor" begin
    tile = TEST_TILE
    rotation = TEST_ROTATION
    derivedmapstate = DerivedMapState()
    expected_temperature = HexFlowNozzleComponents.BIPROP_NONCOMBUSTION_MIN_TEMPERATURE_K

    fuel_only = BipropChamberCompBehav()
    fuel_only_mna_state = MNA_State()
    fuel_only_mna_state.vsource_currents[ElementID(tile, 1)] = 10.0
    fuel_only_mna_state.vsource_currents[ElementID(tile, 2)] = 0.0
    fuel_only = update_flowbehav(fuel_only; rotation = rotation, tile = tile, mna_state = fuel_only_mna_state, derivedmapstate = derivedmapstate)
    @test fuel_only.state.output_temperature_k == expected_temperature

    oxid_only = BipropChamberCompBehav()
    oxid_only_mna_state = MNA_State()
    oxid_only_mna_state.vsource_currents[ElementID(tile, 1)] = 0.0
    oxid_only_mna_state.vsource_currents[ElementID(tile, 2)] = 10.0
    oxid_only = update_flowbehav(oxid_only; rotation = rotation, tile = tile, mna_state = oxid_only_mna_state, derivedmapstate = derivedmapstate)
    @test oxid_only.state.output_temperature_k == expected_temperature

    zero_flow = BipropChamberCompBehav()
    zero_flow_mna_state = MNA_State()
    zero_flow = update_flowbehav(zero_flow; rotation = rotation, tile = tile, mna_state = zero_flow_mna_state, derivedmapstate = derivedmapstate)
    @test zero_flow.state.output_temperature_k == expected_temperature
end

@testset "Bipropellant combustion chamber temperature curve" begin
    comp = BipropChamberCompBehav()
    tile = TEST_TILE
    rotation = TEST_ROTATION

    mna_state = MNA_State()
    derivedmapstate = DerivedMapState()

    # Test temperature at different flow ratios
    # Perfect ratio (2.5:1)
    mna_state.vsource_currents[ElementID(tile, 1)] = 10.0
    mna_state.vsource_currents[ElementID(tile, 2)] = 25.0  # 2.5x flow

    comp = update_flowbehav(comp; rotation = rotation, tile = tile, mna_state = mna_state, derivedmapstate = derivedmapstate)
    temp_at_optimal = comp.state.output_temperature_k

    # Lean mixture (1.25:1)
    comp = BipropChamberCompBehav()
    mna_state.vsource_currents[ElementID(tile, 1)] = 20.0
    mna_state.vsource_currents[ElementID(tile, 2)] = 25.0  # Only 1.25x flow

    comp = update_flowbehav(comp; rotation = rotation, tile = tile, mna_state = mna_state, derivedmapstate = derivedmapstate)
    temp_lean = comp.state.output_temperature_k

    # Rich mixture (5.0:1)
    comp = BipropChamberCompBehav()
    mna_state.vsource_currents[ElementID(tile, 1)] = 10.0
    mna_state.vsource_currents[ElementID(tile, 2)] = 50.0  # 5x flow

    comp = update_flowbehav(comp; rotation = rotation, tile = tile, mna_state = mna_state, derivedmapstate = derivedmapstate)
    temp_rich = comp.state.output_temperature_k

    # Peak should be at optimal, with falloff on either side
    @test temp_at_optimal > temp_lean
    @test temp_at_optimal > temp_rich
end

@testset "Bipropellant combustion chamber off-design temperature falloff" begin
    comp_lean = BipropChamberCompBehav()
    comp_rich = BipropChamberCompBehav()

    tile = TEST_TILE
    rotation = TEST_ROTATION

    mna_state_lean = MNA_State()
    mna_state_rich = MNA_State()
    derivedmapstate = DerivedMapState()

    # Lean: ratio = 1.25 (deficit of oxidiser)
    mna_state_lean.vsource_currents[ElementID(tile, 1)] = 20.0
    mna_state_lean.vsource_currents[ElementID(tile, 2)] = 25.0

    # Rich: ratio = 5.0 (excess oxidiser)
    mna_state_rich.vsource_currents[ElementID(tile, 1)] = 10.0
    mna_state_rich.vsource_currents[ElementID(tile, 2)] = 50.0

    comp_lean = update_flowbehav(comp_lean; rotation = rotation, tile = tile, mna_state = mna_state_lean, derivedmapstate = derivedmapstate)
    comp_rich = update_flowbehav(comp_rich; rotation = rotation, tile = tile, mna_state = mna_state_rich, derivedmapstate = derivedmapstate)

    # Both off-design conditions should produce lower temperature than optimal
    @test comp_lean.state.output_temperature_k < 2200.0
    @test comp_rich.state.output_temperature_k < 2200.0
    # Rich should be lower than lean (exponential falloff is steeper on high-ratio side)
    @test comp_rich.state.output_temperature_k < comp_lean.state.output_temperature_k
end

@testset "Nozzle fragment replacements preserve originals" begin
    original = NozzleBehavFrag(HexFrame.NODE_Q_POS, 0.2)
    inactive = deactivate(original)
    damaged = damage(inactive)
    repaired = undamage(damaged)
    active = reactivate(repaired)

    @test !is_inactive(original)
    @test !is_damaged(original)
    @test is_inactive(inactive)
    @test !is_damaged(inactive)
    @test is_inactive(damaged)
    @test is_damaged(damaged)
    @test is_inactive(repaired)
    @test !is_damaged(repaired)
    @test !is_inactive(active)
    @test !is_damaged(active)
    for replacement in (inactive, damaged, repaired, active)
        @test replacement.connected_node == original.connected_node
        @test replacement.throat_area == original.throat_area
        @test get_component_temperature(replacement) == get_component_temperature(original)
        @test get_tunables(replacement) == get_tunables(original)
    end
end

@testset "Nozzle component replacement composition and actions" begin
    for original in (make_basic_nozzle(; limit_temperature_k = 301.0), make_switched_nozzle(; limit_temperature_k = 301.0))
        temperature_before = get_component_temperature(original)
        mna, derived = make_nozzle_state(original.nozzle)
        updated = update_flowbehav(original; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = mna, derivedmapstate = derived)
        @test is_damaged(updated.nozzle)
        @test get_component_temperature(updated) > temperature_before
        @test !is_damaged(original.nozzle)
        @test get_component_temperature(original) == temperature_before
        @test updated.nozzle.connected_node == original.nozzle.connected_node
        @test get_tunables(updated) == get_tunables(original)

        repaired, result = do_action(updated, :repair_component)
        @test isvalidrequest(result)
        @test unwrap(result) == "Component repaired"
        @test !is_damaged(repaired.nozzle)
        @test is_damaged(updated.nozzle)
        @test get_component_temperature(repaired) == get_component_temperature(updated)

        unchanged, rejected = do_action(original, :repair_component)
        @test !isvalidrequest(rejected)
        @test reason(rejected) == "Component is not currently damaged"
        @test !is_damaged(unchanged.nozzle)
        @test get_component_temperature(unchanged) == temperature_before
        @test get_tunables(unchanged) == get_tunables(original)
        @test_throws ArgumentError do_action(original, :unsupported_action)
    end

    original = make_switched_nozzle()
    clicked = on_click(original)
    @test original.switch.switch.state.target_conductance == original.switch.switch.min_conductance
    @test clicked.switch.switch.state.target_conductance == clicked.switch.switch.max_conductance
    @test get_component_temperature(clicked) == get_component_temperature(original)
    @test !is_inactive(clicked.nozzle)

    opened, result = do_action(original, :open_valve)
    @test isvalidrequest(result)
    @test opened.switch.switch.state.target_conductance == opened.switch.switch.max_conductance
    @test original.switch.switch.state.target_conductance == original.switch.switch.min_conductance
    closed, result = do_action(opened, :close_valve)
    @test isvalidrequest(result)
    @test closed.switch.switch.state.target_conductance == closed.switch.switch.min_conductance
    @test opened.switch.switch.state.target_conductance == opened.switch.switch.max_conductance

    mna, derived = make_nozzle_state(clicked.nozzle)
    stepped = update_flowbehav(clicked; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = mna, derivedmapstate = derived)
    @test stepped.switch.switch.state.current_conductance > clicked.switch.switch.state.current_conductance
    @test get_component_temperature(stepped) > get_component_temperature(clicked)
    @test original.switch.switch.state.current_conductance == original.switch.switch.min_conductance
end

@testset "Nozzle placed replacements preserve placement" begin
    original = PlacedComponent(make_switched_nozzle(; limit_temperature_k = 301.0), HexFrame.R_POS, true, :test_ship)
    mna, derived = make_nozzle_state(original.component.nozzle; rotation = original.rotation)
    clicked = on_click(original)
    updated = update_flowbehav(clicked; tile = TEST_TILE, mna_state = mna, derivedmapstate = derived)
    repaired, accepted = do_action(updated, :repair_component)
    unchanged, rejected = do_action(original, :repair_component)
    inactive = @set original.component.nozzle = deactivate(original.component.nozzle)
    reactivated = commit_reactivation_probe(inactive)

    @test isvalidrequest(accepted)
    @test !isvalidrequest(rejected)
    @test is_damaged(updated.component.nozzle)
    @test !is_damaged(repaired.component.nozzle)
    @test !is_damaged(original.component.nozzle)
    @test !is_damaged(unchanged.component.nozzle)
    @test is_inactive(inactive.component.nozzle)
    @test !is_inactive(reactivated.component.nozzle)
    @test original.component.switch.switch.state.target_conductance == original.component.switch.switch.min_conductance
    @test clicked.component.switch.switch.state.target_conductance == clicked.component.switch.switch.max_conductance
    for replacement in (clicked, updated, repaired, unchanged, inactive, reactivated)
        @test replacement.rotation == original.rotation
        @test replacement.mirrored == original.mirrored
        @test replacement.ship == original.ship
        @test get_tunables(replacement) == get_tunables(original)
    end
end

@testset "Biprop chamber state replacements and probes" begin
    original = BipropChamberCompBehav()
    @test !ismutabletype(typeof(original.state))
    mna = MNA_State()
    derived = DerivedMapState()
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = 10.0
    mna.vsource_currents[ElementID(TEST_TILE, 2)] = 25.0
    hot = update_flowbehav(original; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = mna, derivedmapstate = derived)
    @test hot.state.output_temperature_k ≈ 2300.0
    @test original.state.output_temperature_k == HexFlowNozzleComponents.BIPROP_NONCOMBUSTION_MIN_TEMPERATURE_K
    @test !is_inactive(original.state.auto_deactivation)

    mna.vsource_currents[ElementID(TEST_TILE, 1)] = -0.05
    inactive = update_flowbehav(hot; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = mna, derivedmapstate = derived)
    @test is_inactive(inactive.state.auto_deactivation)
    @test inactive.state.output_temperature_k == HexFlowNozzleComponents.BIPROP_NONCOMBUSTION_MIN_TEMPERATURE_K
    @test !is_inactive(hot.state.auto_deactivation)
    @test hot.state.output_temperature_k ≈ 2300.0
    @test all(!elem.active for elem in produce_rel_elements(inactive))
    probe = get_reactivation_probe(inactive)
    @test probe isa ReactivationProbe
    @test all(elem.active for elem in probe.rel_elements)
    @test classify_reactivation_probe(inactive; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = mna, derivedmapstate = derived) == PROBE_HARMFUL
    @test classify_reactivation_probe(inactive; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = MNA_State(), derivedmapstate = derived) == PROBE_NEUTRAL
    mna.vsource_currents[ElementID(TEST_TILE, 1)] = 10.0
    @test classify_reactivation_probe(inactive; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = mna, derivedmapstate = derived) == PROBE_USEFUL
    @test is_inactive(inactive.state.auto_deactivation)

    placed = PlacedComponent(inactive, HexFrame.S_POS, true, :test_ship)
    reactivated = commit_reactivation_probe(placed)
    @test is_inactive(placed.component.state.auto_deactivation)
    @test !is_inactive(reactivated.component.state.auto_deactivation)
    @test reactivated.component.state.output_temperature_k == inactive.state.output_temperature_k
    @test get_tunables(reactivated) == get_tunables(original)
    @test reactivated.rotation == placed.rotation
    @test reactivated.mirrored == placed.mirrored
    @test reactivated.ship == placed.ship

    # An inactive hot state is cooled without changing the input value
    inactive_hot = @set hot.state = deactivate(hot.state)
    cooled = update_flowbehav(inactive_hot; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = mna, derivedmapstate = derived)
    @test cooled.state.output_temperature_k == HexFlowNozzleComponents.BIPROP_NONCOMBUSTION_MIN_TEMPERATURE_K
    @test inactive_hot.state.output_temperature_k ≈ 2300.0
    @test is_inactive(cooled.state.auto_deactivation)
end

@testset "Chamber tunables preserve deactivation and temperature state" begin
    biprop = BipropChamberCompBehav(fuel_conductance = 0.4, oxid_conductance = 1.0, r_optimal = 2.5)
    biprop = @set biprop.state.output_temperature_k = 2300.0
    biprop = @set biprop.state.auto_deactivation = deactivate(biprop.state.auto_deactivation)
    tuned_biprop = set_tunables(biprop, (0.3, 0.9, 2.7))
    @test tuned_biprop.state == biprop.state
    @test tuned_biprop.fuel_conductance == 0.3
    @test biprop.fuel_conductance == 0.4
end

@testset "Basic nozzle sprite variants are independent of throat area" begin
    glmap = GLObjectMap()
    glmap.textures[:TestAtlas] = RenderEngine.GLtexData(GLtexID(0), UInt32(0), UInt(256), UInt(256))
    variants = (
        (TINY_NOZZLE_SPRITE, :AllNozzles_TinyNozzle),
        (SMALL_NOZZLE_SPRITE, :AllNozzles_SmallNozzle),
        (MEDIUM_NOZZLE_SPRITE, :AllNozzles_MediumNozzle),
    )
    for (index, (variant, sprite)) in enumerate(variants)
        glmap.sprites[sprite] = GLspriteData(:TestAtlas, SVector(0.1f0, 0.1f0), SVector(0.1f0 * index, 0.0f0), SVector(256.0f0, 256.0f0), SVector(256.0f0, 256.0f0), SVector(0.0f0, 0.0f0))
        for area in (0.13, 2.7)
            component = BasicNozzleCompBehav(connected_node = HexFrame.NODE_Q_POS, throat_area = area, sprite_variant = variant)
            @test typeof(component) === BasicNozzleCompBehav
            @test isbitstype(typeof(component))
            @test HexFlowNozzleComponents.nozzle_sprite(component) === sprite
            @test component.nozzle.throat_area == area
            tuned = set_tunables(component, (0.73, 3000.0, 2.0, 5.0))
            @test tuned.sprite_variant === variant
            @test tuned.nozzle.throat_area == 0.73
            @test HexFlowNozzleComponents.nozzle_sprite(tuned) === sprite

            queue = SpriteRenderCommand[]
            offset = AxialCoord(0.2, 0.3)
            expected = render_basic_tile(glmap, sprite, TEST_ROTATION, TEST_TILE; pos_offset = offset, scale = 0.5, transparency = 0.7, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + 200))
            render_base_elem!(queue, component; glmap = glmap, position = TEST_TILE, rotation = TEST_ROTATION, pos_offset = offset, scale = 0.5, transparency = 0.7, render_height_offset = 200)
            @test only(queue) == expected
            empty!(queue)
            render_map_elem!(queue, component; glmap = glmap, position = TEST_TILE, rotation = TEST_ROTATION, pos_offset = offset, scale = 0.5, transparency = 0.7, render_height_offset = 200)
            @test first(queue) == expected
        end
    end
end

@testset "Basic nozzle rejects unhandled sprite variants" begin
    # Simulate a future enum member without extending the production enum.
    unknown = reinterpret(NozzleSpriteVariant, typemax(UInt8))
    component = BasicNozzleCompBehav(make_basic_nozzle().nozzle, unknown)
    @test_throws ArgumentError HexFlowNozzleComponents.nozzle_sprite(component)
end
