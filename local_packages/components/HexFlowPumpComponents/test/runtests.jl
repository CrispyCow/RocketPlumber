using Test
using HexFrame
using HexElements
using HexFluids
using HexComponentsAPI
using FlowEngine
using HexFlowBasicComponents
using HexFlowPumpComponents
using HexFlowSwitchComponents
using HexFlowRendering
using RenderEngine
using StaticArrays

using HexElements: CONST_RESISTOR, CONST_VOLTAGE
using HexFlowPumpComponents: EnergyStoreBehavFrag, RotorStateBehavFrag, DelayedDriveBehavFrag,
    get_current_energy, get_max_energy, update_energy!,
    get_current_rpm, get_rpm_fraction, update_rpm!,
    effective_turbine_conductance, turbopump_vibe_magnitude,
    get_delayed_drive_power, get_stored_drive_energy, update_delayed_drive!,
    get_rated_rpm, get_failure_rpm, get_turbine_runaway_rpm,
    get_overspeed_fraction, get_animation_rpm_fraction

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
function set_node_voltage!(mna_state::MNA_State, tile::TileCoord, node, voltage::Float64;
        rotation::HexAxis = TEST_ROTATION, mirrored::Bool = false)
    mna_state.node_voltages[map_element(node, tile, rotation, mirrored)] = voltage
    return mna_state
end

"Populate a minimal derived map state with the turbine-side fluid tag and temperature."
function make_derived_state(
        tile::TileCoord = TEST_TILE;
        rotation::HexAxis = TEST_ROTATION,
        mirrored::Bool = false,
        fluid::Union{HexFluids.FluidType, Nothing} = HexFluids.COLD_GAS,
        temperature_k::Float64 = HexFluids.THERMAL_AMBIENT_TEMPERATURE_K
    )
    turbine_input_node = map_element(HexFrame.NODE_S_POS, tile, rotation, mirrored)
    nodeactualfluids = isnothing(fluid) ? Dict{NodeCoord, HexFluids.FluidType}() : Dict{NodeCoord, HexFluids.FluidType}(turbine_input_node => fluid)
    node_temperatures = Dict{NodeCoord, Float64}(turbine_input_node => temperature_k)
    return DerivedMapState(nodeactualfluids = nodeactualfluids, node_temperatures = node_temperatures)
end

"Compute the turbopump's shaft drag power for a supplied RPM."
turbopump_friction_power(comp::TurboPumpCompBehav, rpm::Float64)::Float64 = HexFlowPumpComponents.turbopump_shaft_drag(comp.rotor.friction_coefficient, rpm)

"Construct a representative variable-conductance turbopump for tests."
function make_turbopump(
        ;
        max_pump_voltage::Float64 = 50.0,
        series_conductance::Float64 = 1.0,
        max_turbine_conductance::Float64 = 0.3,
        cycle_efficiency::Float64 = 0.6,
        current_rpm::Float64 = 0.0,
        max_rpm::Float64 = 3000.0,
        rotor_inertia::Float64 = 50.0,
        friction_coefficient::Float64 = 0.002,
        current_delayed_drive_power::Float64 = 0.0,
        drive_time_constant::Float64 = 1.25,
        deactivation::AutoDeactivationBehavFrag = AutoDeactivationBehavFrag(),
        limit_temperature_k::Float64 = 1500.0,
        thermal_mass::Float64 = 30.0,
        heat_loss_factor::Float64 = 0.7
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
        current_delayed_drive_power = current_delayed_drive_power,
        drive_time_constant = drive_time_constant,
        deactivation = deactivation,
        limit_temperature_k = limit_temperature_k,
        thermal_mass = thermal_mass,
        heat_loss_factor = heat_loss_factor
    )
end

"Construct a turbopump with a post-construction RPM value, including overspeed values."
function make_turbopump_at_rpm(rpm::Float64; kwargs...)
    comp = make_turbopump(; kwargs...)
    setstate!(comp.rotor.rpm, max(rpm, 0.0))
    return comp
end

"Build a high-flow, low-spinup turbopump fixture for thermal regression tests."
function make_hot_turbopump(; kwargs...)
    return make_turbopump(; max_rpm = 1.0e9, rotor_inertia = 1.0e9, kwargs...)
end

"Advance a turbopump under a fixed turbine-side condition until damage triggers or the limit expires."
function run_until_damage!(comp::TurboPumpCompBehav;
        tile::TileCoord = TEST_TILE,
        rotation::HexAxis = TEST_ROTATION,
        voltage::Float64 = 40.0,
        fluid::HexFluids.FluidType = HexFluids.BIPROP_EXHAUST,
        temperature_k::Float64 = 2300.0,
        max_ticks::Int = Int(30 * BASE_UPS)
    )
    mna_state = MNA_State()
    set_node_voltage!(mna_state, tile, HexFrame.NODE_S_POS, voltage; rotation = rotation)
    derivedmapstate = make_derived_state(tile; rotation = rotation, fluid = fluid, temperature_k = temperature_k)

    for tick in 1:max_ticks
        update_flowbehav!(comp; tile = tile, rotation = rotation, mna_state = mna_state, derivedmapstate = derivedmapstate)
        is_damaged(comp.overheat) && return tick
    end

    return max_ticks
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
    @test powered[1].connections == RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.NODE_Q_POS)
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
    @test turbopump_friction_power(make_turbopump(friction_coefficient = 0.001), 0.0) ≈ 1.2

    stopped = make_turbopump(current_rpm = 0.5)
    update_flowbehav!(stopped; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = MNA_State(), derivedmapstate = make_derived_state())
    @test get_current_rpm(stopped.rotor) == 0.0

    applied_rotor_inertia = rotor.rotor_inertia * HexFlowPumpComponents.TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    @test applied_rotor_inertia ≈ 1.0e-4

    clamped_rotor = RotorStateBehavFrag(current_rpm = 5.0, max_rpm = 0.0, rotor_inertia = 0.0, friction_coefficient = -1.0)
    @test clamped_rotor.max_rpm == 1.0e-6
    @test clamped_rotor.rotor_inertia == 1.0e-6
    @test clamped_rotor.friction_coefficient == 1.0e-6
    @test get_current_rpm(clamped_rotor) == 0.0
end

@testset "Turbopump shaft drag curve" begin
    friction_coefficient = 0.002
    threshold_rpm = HexFlowPumpComponents.TURBOPUMP_LOW_SPEED_DRAG_RPM
    threshold_drag = friction_coefficient * threshold_rpm

    @test HexFlowPumpComponents.turbopump_shaft_drag(friction_coefficient, 0.0) ≈ 2.4
    @test HexFlowPumpComponents.turbopump_shaft_drag(friction_coefficient, 150.0) ≈ 1.5
    @test HexFlowPumpComponents.turbopump_shaft_drag(friction_coefficient, threshold_rpm) ≈ threshold_drag
    @test HexFlowPumpComponents.turbopump_shaft_drag(friction_coefficient, 600.0) ≈ 1.2

    # Clamp and max keep the low-speed curve bounded and select normal drag above the threshold.
    @test HexFlowPumpComponents.turbopump_shaft_drag(friction_coefficient, -10.0) ≈ 2.4
    @test HexFlowPumpComponents.turbopump_shaft_drag(friction_coefficient, 600.0) == max(0.002 * 600.0, threshold_drag)
end

@testset "Delayed drive fragment" begin
    negative = DelayedDriveBehavFrag(current_power = -5.0, time_constant = 1.0)
    @test get_delayed_drive_power(negative) == 0.0

    minimum_time_constant = DelayedDriveBehavFrag(current_power = 2.0, time_constant = 0.0)
    @test minimum_time_constant.time_constant == 1.0 / BASE_UPS

    drive = DelayedDriveBehavFrag(current_power = 0.0, time_constant = 1.0)
    target = 12.0
    alpha = -expm1(-0.5 / drive.time_constant)
    update_delayed_drive!(drive, target; dt = 0.5)
    @test get_delayed_drive_power(drive) ≈ alpha * target
    for _ in 1:1000
        update_delayed_drive!(drive, target; dt = 1.0 / BASE_UPS)
    end
    @test 0.0 < get_delayed_drive_power(drive) < target
    @test get_delayed_drive_power(drive) ≈ target atol = 1.0e-6

    settled_power = get_delayed_drive_power(drive)
    update_delayed_drive!(drive, 0.0; dt = 0.25)
    @test get_delayed_drive_power(drive) ≈ settled_power * exp(-0.25 / drive.time_constant)
    update_delayed_drive!(drive, -10.0; dt = 1.0)
    @test get_delayed_drive_power(drive) ≥ 0.0
    @test get_stored_drive_energy(drive) ≈ drive.time_constant * get_delayed_drive_power(drive)

    power_state = FloatStateBehavFrag(4.0)
    reconstructed = DelayedDriveBehavFrag(power_state, 2.0)
    @test reconstructed.power === power_state
    @test get_stored_drive_energy(reconstructed) ≈ 8.0
end

@testset "Turbo pump component" begin
    comp = make_turbopump(current_rpm = 1500.0)
    elements = produce_rel_elements(comp)

    @test comp.rotor.rotor_inertia == 50.0
    @test comp.delayed_drive.time_constant == 1.25

    # At 1500/3000 RPM: pump voltage = 50 × 0.5 = 25, turbine G follows the non-linear rpm_frac^0.7 curve.
    @test length(elements) == 3
    @test elements[1].type === CONST_VOLTAGE
    @test elements[1].connections == RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.NODE_Q_POS)
    @test elements[1].value ≈ 25.0
    @test elements[2].type === CONST_RESISTOR
    @test elements[2].connections == RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.NODE_Q_NEG)
    @test elements[2].value ≈ 1.0
    @test elements[3].type === CONST_RESISTOR
    @test elements[3].connections == RelativeElementConnections(HexFrame.NODE_S_POS, HexFrame.GROUND)
    @test elements[3].value ≈ effective_turbine_conductance(comp)
    @test all(elem.active for elem in elements)

    # Auto-deactivation disables all three elements.
    deactivate!(comp.deactivation)
    deactivated_elements = produce_rel_elements(comp)
    @test all(!elem.active for elem in deactivated_elements)
    reactivate!(comp.deactivation)

    tunables = get_tunables(comp)
    @test tunables isa NTuple{13, TunableProps}
    original_rpm_state = comp.rotor.rpm
    original_drive_state = comp.delayed_drive.power
    original_temperature_state = comp.overheat.temperature
    original_damage_state = comp.overheat.damage
    tuned = set_tunables(comp, (60.0, 2.0, 0.6, 3500.0, 3500.0, 400.0, 0.5, 0.90, 25.0, 2.0, 1600.0, 12.0, 7.0))
    @test tuned.rotor.rpm === original_rpm_state
    @test tuned.delayed_drive.power === original_drive_state
    @test tuned.overheat.temperature === original_temperature_state
    @test tuned.overheat.damage === original_damage_state
    @test tuned.max_pump_voltage ≈ 60.0
    @test tuned.series_conductance ≈ 2.0
    @test tuned.max_turbine_conductance ≈ 0.6
    @test get_current_rpm(tuned.rotor) ≈ 3500.0
    @test tuned.rotor.max_rpm ≈ 3500.0
    @test tuned.rotor.rotor_inertia ≈ 400.0
    @test tuned.rotor.friction_coefficient ≈ 0.5
    @test tuned.cycle_efficiency ≈ 0.90
    @test get_delayed_drive_power(tuned.delayed_drive) ≈ 25.0
    @test tuned.delayed_drive.time_constant ≈ 2.0
    @test tuned.overheat.limit_temperature_k ≈ 1600.0
    @test tuned.overheat.thermal_mass ≈ 12.0
    @test tuned.overheat.heat_loss_factor ≈ 7.0

    decls = produce_rel_fluid_declarations(comp)
    @test length(decls) == 3
    @test decls[1] === RelativeFluidDeclaration(HexFrame.NODE_Q_POS, FluidConstraintRule(HexFluids.IS_LIQUID))
    @test decls[2] === RelativeFluidDeclaration(HexFrame.NODE_Q_NEG, FluidConstraintRule(HexFluids.IS_LIQUID))
    @test decls[3] === RelativeFluidDeclaration(HexFrame.NODE_S_POS, FluidConstraintRule(HexFluids.IS_GAS))

    # No click action; repair exists but is disabled while undamaged.
    actions = get_actions(comp)
    @test length(actions) == 1
    @test actions[1].id === :repair_component
    @test !actions[1].enabled
    on_click!(comp)
    @test !is_inactive(comp.deactivation)
end

@testset "Turbopump speed indicator" begin
    safe_colour = HexFlowPumpComponents.TURBOPUMP_SPEED_SAFE_COLOUR
    overspeed_colour = HexFlowPumpComponents.TURBOPUMP_SPEED_OVERSPEED_COLOUR
    damaged_colour = HexFlowPumpComponents.TURBOPUMP_SPEED_DAMAGED_COLOUR

    cases = (
        (name = "stopped", rpm = 0.0, damaged = false, fill_fraction = 0.0, colour = safe_colour),
        (name = "half rated", rpm = 1500.0, damaged = false, fill_fraction = 0.5, colour = safe_colour),
        (name = "rated", rpm = 3000.0, damaged = false, fill_fraction = 1.0, colour = safe_colour),
        (name = "overspeed", rpm = 3300.0, damaged = false, fill_fraction = 1.0, colour = overspeed_colour),
        (name = "damaged and stopped", rpm = 0.0, damaged = true, fill_fraction = 0.0, colour = damaged_colour),
        (name = "damaged at half rated", rpm = 1500.0, damaged = true, fill_fraction = 0.5, colour = damaged_colour),
        (name = "damaged and overspeed", rpm = 3300.0, damaged = true, fill_fraction = 1.0, colour = damaged_colour),
    )

    for case in cases
        @testset "$(case.name)" begin
            comp = make_turbopump_at_rpm(case.rpm)
            case.damaged && damage!(comp.overheat)
            indicator = HexFlowPumpComponents.turbopump_speed_indicator(comp)
            @test indicator.fill_fraction == case.fill_fraction
            @test indicator.colour == case.colour
        end
    end

    heated = make_turbopump_at_rpm(1500.0)
    set_component_temperature!(heated.overheat, 1400.0)
    heated_indicator = HexFlowPumpComponents.turbopump_speed_indicator(heated)
    @test !is_damaged(heated.overheat)
    @test heated_indicator.fill_fraction == 0.5
    @test heated_indicator.colour == safe_colour
end

function _mock_turbopump_glmap()
    glmap = GLObjectMap()
    glmap.textures[:TestAtlas] = RenderEngine.GLtexData(RenderEngine.GLtexID(0), UInt32(0), UInt(1024), UInt(1024))
    sprites = (
        :TurboPump1_fluidmask, :TurboPump1_speedmask, :TurboPump1_rotor,
        :TurboPump1_static, :TurboPump1_genturbine, :TurboPump1_vibepart,
    )
    for sprite in sprites
        uv_offset = sprite === :TurboPump1_speedmask ? SVector{2, Float32}(0.9f0, 0.9f0) : SVector{2, Float32}(0.0f0, 0.0f0)
        glmap.sprites[sprite] = GLspriteData(
            :TestAtlas,
            SVector{2, Float32}(0.1f0, 0.1f0),
            uv_offset,
            SVector{2, Float32}(256.0f0, 256.0f0),
            SVector{2, Float32}(256.0f0, 256.0f0),
            SVector{2, Float32}(0.0f0, 0.0f0),
        )
    end
    return glmap
end

@testset "Turbopump speed-mask render command" begin
    queue = HexFlowRendering.SpriteRenderCommand[]
    comp = make_turbopump_at_rpm(1500.0)
    render_base_elem!(queue, comp;
        glmap = _mock_turbopump_glmap(),
        rotation = TEST_ROTATION,
        position = TEST_TILE,
        render_height_offset = 200
    )

    speed_commands = filter(command -> command.uniforms.uv_offset == SVector{2, Float32}(0.9f0, 0.9f0), queue)
    @test length(speed_commands) == 1
    speed_command = only(speed_commands)
    @test speed_command.uniforms.unclipped_texcoord == SVector{2, Float32}(1.0f0, 0.5f0)
    @test speed_command.uniforms.colour_multiply == HexFlowPumpComponents.TURBOPUMP_SPEED_SAFE_COLOUR
    @test speed_command.draw_height == Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 10 + 200)
end

@testset "Turbopump overheat" begin
    fresh = make_turbopump()
    @test get_component_temperature(fresh) == THERMAL_AMBIENT_TEMPERATURE_K
    @test !is_damaged(fresh.overheat)

    tunables = get_tunables(fresh)
    @test length(tunables) == 13
    @test tunables[5].type_desc == "Rated RPM"
    @test tunables[7].type_desc == "Viscous drag coefficient"
    @test tunables[9].type_desc == "Current delayed drive power"
    @test tunables[10].type_desc == "Drive time constant"
    @test tunables[11].type_desc == "Temperature Limit"
    @test tunables[12].type_desc == "Thermal Mass"
    @test tunables[13].type_desc == "Heat Loss Factor"

    heated = make_turbopump()
    set_component_temperature!(heated.overheat, 975.0)
    damage!(heated.overheat)
    roundtrip_values = ntuple(index -> tunables[index].current_val, 13)
    roundtripped = set_tunables(heated, roundtrip_values)
    @test get_component_temperature(roundtripped) == 975.0
    @test is_damaged(roundtripped.overheat)

    monoprop_safe = make_hot_turbopump()
    monoprop_mna = MNA_State()
    set_node_voltage!(monoprop_mna, TEST_TILE, HexFrame.NODE_S_POS, 40.0)
    monoprop_derived = make_derived_state(fluid = HexFluids.MONOPROP_GAS, temperature_k = 800.0)
    for _ in 1:(5 * BASE_UPS)
        update_flowbehav!(monoprop_safe; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = monoprop_mna, derivedmapstate = monoprop_derived)
    end
    @test !is_damaged(monoprop_safe.overheat)
    @test get_component_temperature(monoprop_safe) < 1000.0

    off_mixture_safe = make_hot_turbopump()
    off_mixture_mna = MNA_State()
    set_node_voltage!(off_mixture_mna, TEST_TILE, HexFrame.NODE_S_POS, 40.0)
    off_mixture_derived = make_derived_state(fluid = HexFluids.BIPROP_EXHAUST, temperature_k = 1400.0)
    for _ in 1:(5 * BASE_UPS)
        update_flowbehav!(off_mixture_safe; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = off_mixture_mna, derivedmapstate = off_mixture_derived)
    end
    @test !is_damaged(off_mixture_safe.overheat)

    peak_biprop = make_hot_turbopump()
    damage_tick = run_until_damage!(peak_biprop)
    @test is_damaged(peak_biprop.overheat)
    @test damage_tick < 30 * BASE_UPS
    @test get_overheat_percentage(peak_biprop.overheat) == 1.0
    @test get_component_temperature(peak_biprop) >= peak_biprop.overheat.limit_temperature_k
    @test all(!elem.active for elem in produce_rel_elements(peak_biprop))

    damaged_probe = make_hot_turbopump(deactivation = AutoDeactivationBehavFrag())
    @test run_until_damage!(damaged_probe) < 30 * BASE_UPS
    deactivate!(damaged_probe.deactivation)
    @test isnothing(get_reactivation_probe(damaged_probe; tile = TEST_TILE, rotation = TEST_ROTATION))

    repaired_active = make_hot_turbopump()
    @test run_until_damage!(repaired_active) < 30 * BASE_UPS
    repair_actions = get_actions(repaired_active)
    @test length(repair_actions) == 1
    @test repair_actions[1].id === :repair_component
    @test repair_actions[1].enabled
    result = do_action!(repaired_active, :repair_component)
    @test isvalidrequest(result)
    @test !is_damaged(repaired_active.overheat)
    @test all(elem.active for elem in produce_rel_elements(repaired_active))
    @test isnothing(get_reactivation_probe(repaired_active; tile = TEST_TILE, rotation = TEST_ROTATION))

    result = do_action!(damaged_probe, :repair_component)
    @test isvalidrequest(result)
    @test !is_damaged(damaged_probe.overheat)
    @test get_reactivation_probe(damaged_probe; tile = TEST_TILE, rotation = TEST_ROTATION) isa ReactivationProbe

    cooling_probe = make_hot_turbopump()
    @test run_until_damage!(cooling_probe) < 30 * BASE_UPS
    start_temperature = get_component_temperature(cooling_probe)
    ambient_state = make_derived_state(fluid = HexFluids.BIPROP_EXHAUST, temperature_k = THERMAL_AMBIENT_TEMPERATURE_K)
    for _ in 1:(20 * BASE_UPS)
        update_flowbehav!(cooling_probe; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = MNA_State(), derivedmapstate = ambient_state)
    end
    @test get_component_temperature(cooling_probe) < start_temperature
    @test all(!elem.active for elem in produce_rel_elements(cooling_probe))
end

@testset "Turbo pump mirroring" begin
    comp = make_turbopump()
    @test map_mirroring(comp, true)

    mirrored = PlacedComponent(comp, TEST_ROTATION, true, :primary)
    abs_elements = produce_abs_elements(mirrored, TEST_TILE)
    @test abs_elements[3].connections.v1 == map_element(HexFrame.NODE_R_POS, TEST_TILE, TEST_ROTATION)

    mirrored_state = make_derived_state(; mirrored = true)
    mirrored_node = only(keys(mirrored_state.nodeactualfluids))
    @test mirrored_node == map_element(HexFrame.NODE_R_POS, TEST_TILE, TEST_ROTATION)
end

@testset "Turbo pump RPM updates" begin
    # Friction-only decay (no gas, no pump load)
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
    raw_drive_power = spun_up.cycle_efficiency * turbine_power
    drive_alpha = -expm1(-(1.0 / BASE_UPS) / spun_up.delayed_drive.time_constant)
    spinup_expected = (drive_alpha * raw_drive_power - spinup_friction) / (spinup_applied_inertia * BASE_UPS)
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

    # Normal startup: negative pump current + gas pressure = spin-up
    startup = make_turbopump(current_rpm = 0.0)
    startup_mna = register_vsources!(MNA_State(), TEST_TILE, 1)
    startup_mna.vsource_currents[ElementID(TEST_TILE, 1)] = -0.3
    set_node_voltage!(startup_mna, TEST_TILE, HexFrame.NODE_S_POS, 40.0)
    update_flowbehav!(startup; tile = TEST_TILE, rotation = TEST_ROTATION, mna_state = startup_mna, derivedmapstate = make_derived_state(fluid = HexFluids.MONOPROP_GAS, temperature_k = 800.0))
    @test !is_inactive(startup.deactivation)
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
    missing_applied_inertia = missing_fluid.rotor.rotor_inertia * HexFlowPumpComponents.TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    missing_friction = turbopump_friction_power(missing_fluid, 1200.0)
    missing_expected = 1200.0 - missing_friction / (missing_applied_inertia * BASE_UPS)
    @test get_current_rpm(missing_fluid.rotor) ≈ missing_expected
end

@testset "Turbopump transient dynamics" begin
    tile = TEST_TILE
    rotation = TEST_ROTATION
    loaded_mna = register_vsources!(MNA_State(), tile, 1)
    # The 6.0-unit liquid load keeps the inertia-50 pump loaded but below failure speed.
    loaded_mna.vsource_currents[ElementID(tile, 1)] = -6.0
    set_node_voltage!(loaded_mna, tile, HexFrame.NODE_S_POS, 40.0; rotation = rotation)
    loaded_derived = make_derived_state(tile; rotation = rotation, fluid = HexFluids.MONOPROP_GAS, temperature_k = 800.0)

    loaded = make_turbopump()
    for _ in 1:600
        update_flowbehav!(loaded; tile = tile, rotation = rotation, mna_state = loaded_mna, derivedmapstate = loaded_derived)
    end
    loaded_rpm = get_current_rpm(loaded.rotor)
    @test !is_damaged(loaded.overheat)
    @test loaded_rpm < get_failure_rpm(loaded)
    @test get_delayed_drive_power(loaded.delayed_drive) > 0.0
    steady_current = 40.0 * effective_turbine_conductance(loaded)
    steady_density = something(lookup_fluid_density(HexFluids.MONOPROP_GAS), 0.0)
    steady_temperature_change = 800.0 - THERMAL_AMBIENT_TEMPERATURE_K
    steady_raw_drive = loaded.cycle_efficiency * steady_density * steady_current * steady_temperature_change * HexFlowPumpComponents.TURBOPUMP_TURBINE_TEMPERATURE_POWER_SCALING
    # The agreed longer time constant leaves a small intentional transient after 10 seconds.
    @test get_delayed_drive_power(loaded.delayed_drive) ≈ steady_raw_drive rtol = 0.04

    cold_derived = make_derived_state(tile; rotation = rotation, fluid = nothing, temperature_k = THERMAL_AMBIENT_TEMPERATURE_K)

    # Removing turbine drive and pump load together leaves stored drive to accelerate the shaft.
    common_shutdown = deepcopy(loaded)
    common_cut_mna = MNA_State()
    first_cut_drive = nothing
    shutdown_damage_tick = nothing
    for tick in 1:180
        update_flowbehav!(common_shutdown; tile = tile, rotation = rotation, mna_state = common_cut_mna, derivedmapstate = cold_derived)
        tick == 1 && (first_cut_drive = get_delayed_drive_power(common_shutdown.delayed_drive))
        if is_damaged(common_shutdown.overheat)
            shutdown_damage_tick = tick
            break
        end
    end
    @test first_cut_drive > 0.0
    @test shutdown_damage_tick !== nothing
    # Inertia is a gameplay tuning value; require prompt failure without pinning an exact time.
    @test 1 ≤ shutdown_damage_tick ≤ 2 * BASE_UPS
    @test get_component_temperature(common_shutdown) < common_shutdown.overheat.limit_temperature_k

    # Removing turbine drive while retaining liquid load winds the pump down safely.
    safe_shutdown = deepcopy(loaded)
    safe_cut_mna = register_vsources!(MNA_State(), tile, 1)
    safe_cut_mna.vsource_currents[ElementID(tile, 1)] = -6.0
    maximum_safe_rpm = loaded_rpm
    for _ in 1:180
        update_flowbehav!(safe_shutdown; tile = tile, rotation = rotation, mna_state = safe_cut_mna, derivedmapstate = cold_derived)
        maximum_safe_rpm = max(maximum_safe_rpm, get_current_rpm(safe_shutdown.rotor))
    end
    @test maximum_safe_rpm ≈ loaded_rpm
    @test get_current_rpm(safe_shutdown.rotor) < loaded_rpm
    @test get_overspeed_fraction(safe_shutdown) == 0.0
    @test !is_damaged(safe_shutdown.overheat)
    @test get_delayed_drive_power(safe_shutdown.delayed_drive) < get_delayed_drive_power(loaded.delayed_drive)

    # Restoring turbine drive and liquid load during the warning band recovers the pump.
    recovery = deepcopy(loaded)
    warning_tick = nothing
    for tick in 1:180
        update_flowbehav!(recovery; tile = tile, rotation = rotation, mna_state = common_cut_mna, derivedmapstate = cold_derived)
        if get_overspeed_fraction(recovery) > 0.0
            warning_tick = tick
            break
        end
    end
    @test warning_tick !== nothing
    @test get_overspeed_fraction(recovery) < 1.0
    recovered = false
    for _ in 1:300
        update_flowbehav!(recovery; tile = tile, rotation = rotation, mna_state = loaded_mna, derivedmapstate = loaded_derived)
        if get_overspeed_fraction(recovery) == 0.0
            recovered = true
            break
        end
    end
    @test recovered
    @test !is_damaged(recovery.overheat)

    # Sustained representative turbine input without liquid load reaches failure.
    no_load = make_turbopump()
    no_load_mna = MNA_State()
    set_node_voltage!(no_load_mna, tile, HexFrame.NODE_S_POS, 40.0; rotation = rotation)
    no_load_damage_tick = nothing
    passed_rated = false
    for tick in 1:180
        update_flowbehav!(no_load; tile = tile, rotation = rotation, mna_state = no_load_mna, derivedmapstate = loaded_derived)
        passed_rated |= get_current_rpm(no_load.rotor) > get_rated_rpm(no_load)
        if is_damaged(no_load.overheat)
            no_load_damage_tick = tick
            break
        end
    end
    @test passed_rated
    @test no_load_damage_tick !== nothing
    @test 1 ≤ no_load_damage_tick ≤ 2 * BASE_UPS

    # A very small turbine input may remain stuck, but remains harmless.
    low_input = make_turbopump()
    low_input_mna = MNA_State()
    set_node_voltage!(low_input_mna, tile, HexFrame.NODE_S_POS, 0.1; rotation = rotation)
    low_input_derived = make_derived_state(tile; rotation = rotation, fluid = HexFluids.MONOPROP_GAS, temperature_k = 800.0)
    for _ in 1:(30 * BASE_UPS)
        update_flowbehav!(low_input; tile = tile, rotation = rotation, mna_state = low_input_mna, derivedmapstate = low_input_derived)
    end
    @test get_current_rpm(low_input.rotor) < get_rated_rpm(low_input)
    @test get_current_rpm(low_input.rotor) < get_failure_rpm(low_input)
    @test !is_damaged(low_input.overheat)

    # Repairing an overspeeding shaft does not reset its mechanical state.
    damaged_rpm = get_current_rpm(no_load.rotor)
    damaged_drive = get_delayed_drive_power(no_load.delayed_drive)
    repair_result = do_action!(no_load, :repair_component)
    @test isvalidrequest(repair_result)
    @test !is_damaged(no_load.overheat)
    @test get_current_rpm(no_load.rotor) == damaged_rpm
    @test get_delayed_drive_power(no_load.delayed_drive) == damaged_drive
    update_flowbehav!(no_load; tile = tile, rotation = rotation, mna_state = common_cut_mna, derivedmapstate = cold_derived)
    @test is_damaged(no_load.overheat)
end

@testset "Turbopump auto-deactivation" begin
    tile = TEST_TILE
    rotation = TEST_ROTATION

    # Negative turbine-shunt voltage (reverse flow into S_POS) causes deactivation.
    reversed_turbine = make_turbopump(current_rpm = 1200.0, rotor_inertia = 6000.0, friction_coefficient = 0.1)
    rev_mna = MNA_State()
    set_node_voltage!(rev_mna, tile, HexFrame.NODE_S_POS, -5.0; rotation = rotation)
    update_flowbehav!(reversed_turbine; tile = tile, rotation = rotation, mna_state = rev_mna, derivedmapstate = make_derived_state())
    @test is_inactive(reversed_turbine.deactivation)
    # RPM decays via friction only after deactivation.
    applied_inertia = reversed_turbine.rotor.rotor_inertia * HexFlowPumpComponents.TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    friction_power = turbopump_friction_power(reversed_turbine, 1200.0)
    @test get_current_rpm(reversed_turbine.rotor) ≈ 1200.0 - friction_power / (applied_inertia * BASE_UPS)

    # Positive pump-source current alone does NOT deactivate the turbopump.
    positive_source = make_turbopump(current_rpm = 1200.0, rotor_inertia = 6000.0, friction_coefficient = 0.1)
    pos_mna = register_vsources!(MNA_State(), tile, 1)
    pos_mna.vsource_currents[ElementID(tile, 1)] = 0.5  # back-drive through pump source
    # No reverse turbine voltage — turbine node at zero.
    update_flowbehav!(positive_source; tile = tile, rotation = rotation, mna_state = pos_mna, derivedmapstate = make_derived_state())
    @test !is_inactive(positive_source.deactivation)

    # Reverse pump current does not contribute to rotor energy (clamp ensures this).
    reverse_pump_energy = make_turbopump(current_rpm = 1500.0, rotor_inertia = 6000.0, friction_coefficient = 0.1)
    rpe_mna = register_vsources!(MNA_State(), tile, 1)
    rpe_mna.vsource_currents[ElementID(tile, 1)] = 2.0  # positive = reverse pump flow
    update_flowbehav!(reverse_pump_energy; tile = tile, rotation = rotation, mna_state = rpe_mna, derivedmapstate = make_derived_state())
    rpe_applied_inertia = reverse_pump_energy.rotor.rotor_inertia * HexFlowPumpComponents.TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    rpe_friction = turbopump_friction_power(reverse_pump_energy, 1500.0)
    # Pump_current clamp yields 0 (max(-2.0, 0) = 0), so pump_power = 0, only friction acts.
    rpe_expected = 1500.0 - rpe_friction / (rpe_applied_inertia * BASE_UPS)
    @test get_current_rpm(reverse_pump_energy.rotor) ≈ rpe_expected

    # Inactive pump: RPM decays via friction only, no further deactivation change.
    inactive_decay = make_turbopump(current_rpm = 800.0, rotor_inertia = 6000.0, friction_coefficient = 0.1, deactivation = AutoDeactivationBehavFrag())
    deactivate!(inactive_decay.deactivation)
    update_flowbehav!(inactive_decay; tile = tile, rotation = rotation, mna_state = MNA_State(), derivedmapstate = make_derived_state())
    id_applied_inertia = inactive_decay.rotor.rotor_inertia * HexFlowPumpComponents.TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    id_friction = turbopump_friction_power(inactive_decay, 800.0)
    @test get_current_rpm(inactive_decay.rotor) ≈ 800.0 - id_friction / (id_applied_inertia * BASE_UPS)
    @test is_inactive(inactive_decay.deactivation)  # stays inactive (reactivation is via scheduler)
end

@testset "Turbopump reactivation probe" begin
    tile = TEST_TILE
    rotation = TEST_ROTATION

    # Active pump: no probe.
    active_comp = make_turbopump(current_rpm = 500.0)
    @test isnothing(get_reactivation_probe(active_comp; tile = tile, rotation = rotation))

    # Inactive pump: three-element probe in correct index order.
    inactive_comp = make_turbopump(current_rpm = 500.0, deactivation = AutoDeactivationBehavFrag())
    deactivate!(inactive_comp.deactivation)
    probe = get_reactivation_probe(inactive_comp; tile = tile, rotation = rotation)
    @test probe isa ReactivationProbe
    @test length(probe.rel_elements) == 3
    @test probe.rel_elements[1].type === CONST_VOLTAGE    # pump source at index 1
    @test probe.rel_elements[2].type === CONST_RESISTOR   # series resistor at index 2
    @test probe.rel_elements[3].type === CONST_RESISTOR   # turbine shunt at index 3
    @test all(elem.active for elem in probe.rel_elements)
    # Probe voltage reflects current RPM.
    @test probe.rel_elements[1].value ≈ inactive_comp.max_pump_voltage * get_rpm_fraction(inactive_comp.rotor)
end

@testset "Turbopump classify_reactivation_probe and commit_reactivation_probe!" begin
    tile = TEST_TILE
    rotation = TEST_ROTATION

    "Build a minimal DerivedMapState with the turbine abs element registered."
    function make_turbine_probe_state(comp::TurboPumpCompBehav; s_pos_voltage::Float64)
        turbine_rel_elem = RelativeElement(
            RelativeElementConnections(HexFrame.NODE_S_POS, HexFrame.GROUND),
            effective_turbine_conductance(comp),
            HexElements.CONST_RESISTOR;
            active = true
        )
        turbine_abs_elem = map_element(turbine_rel_elem, tile, 3, rotation)
        s_pos_node = map_element(HexFrame.NODE_S_POS, tile, rotation)
        mna_state = MNA_State()
        mna_state.node_voltages[s_pos_node] = s_pos_voltage
        derivedmapstate = DerivedMapState(
            filteredelements = [turbine_abs_elem],
            filterednodes = list_nodes([turbine_abs_elem])
        )
        return mna_state, derivedmapstate
    end

    # Positive turbine current (useful flow) → useful.
    comp_accept = make_turbopump(current_rpm = 500.0)
    deactivate!(comp_accept.deactivation)
    mna_pos, dm_pos = make_turbine_probe_state(comp_accept; s_pos_voltage = 5.0)
    @test classify_reactivation_probe(comp_accept; tile = tile, rotation = rotation, derivedmapstate = dm_pos, mna_state = mna_pos) === PROBE_USEFUL
    @test is_inactive(comp_accept.deactivation)
    commit_reactivation_probe!(comp_accept; tile = tile, rotation = rotation, derivedmapstate = dm_pos, mna_state = mna_pos)
    @test !is_inactive(comp_accept.deactivation)

    # Zero turbine current (neutral-ish) → useful at the shared API boundary.
    comp_neutral = make_turbopump(current_rpm = 500.0)
    deactivate!(comp_neutral.deactivation)
    mna_zero, dm_zero = make_turbine_probe_state(comp_neutral; s_pos_voltage = 0.0)
    @test classify_reactivation_probe(comp_neutral; tile = tile, rotation = rotation, derivedmapstate = dm_zero, mna_state = mna_zero) === PROBE_USEFUL
    @test is_inactive(comp_neutral.deactivation)

    # Harmful reverse turbine current → harmful; state unchanged.
    comp_reject = make_turbopump(current_rpm = 500.0)
    deactivate!(comp_reject.deactivation)
    mna_neg, dm_neg = make_turbine_probe_state(comp_reject; s_pos_voltage = -5.0)
    @test classify_reactivation_probe(comp_reject; tile = tile, rotation = rotation, derivedmapstate = dm_neg, mna_state = mna_neg) === PROBE_HARMFUL
    @test is_inactive(comp_reject.deactivation)

    # Pruned turbine element → neutral.
    comp_pruned = make_turbopump(current_rpm = 500.0)
    deactivate!(comp_pruned.deactivation)
    @test classify_reactivation_probe(comp_pruned; tile = tile, rotation = rotation, derivedmapstate = DerivedMapState(), mna_state = MNA_State()) === PROBE_NEUTRAL
    @test is_inactive(comp_pruned.deactivation)

    # Reverse pump-source current does NOT block useful classification.
    comp_revpump = make_turbopump(current_rpm = 500.0)
    deactivate!(comp_revpump.deactivation)
    mna_revpump, dm_revpump = make_turbine_probe_state(comp_revpump; s_pos_voltage = 3.0)
    # Inject a positive (reversing) pump source current into the mock state.
    register_vsources!(mna_revpump, tile, 1)
    mna_revpump.vsource_currents[ElementID(tile, 1)] = 2.0
    @test classify_reactivation_probe(comp_revpump; tile = tile, rotation = rotation, derivedmapstate = dm_revpump, mna_state = mna_revpump) === PROBE_USEFUL
    @test is_inactive(comp_revpump.deactivation)
end

@testset "Variable conductance" begin
    # At 0 RPM: full max_turbine_conductance
    comp_zero = make_turbopump(current_rpm = 0.0)
    @test effective_turbine_conductance(comp_zero) ≈ comp_zero.max_turbine_conductance

    # At half RPM, conductance follows the non-linear exponent curve.
    comp_half = make_turbopump(current_rpm = 1500.0, max_rpm = 3000.0)
    @test effective_turbine_conductance(comp_half) ≈ comp_half.max_turbine_conductance * (1.0 - (1500.0 / 3750.0)^0.7)

    # At rated RPM conductance remains positive.
    comp_rated = make_turbopump(current_rpm = 3000.0, max_rpm = 3000.0)
    @test effective_turbine_conductance(comp_rated) > 0.0

    # At failure RPM conductance is still positive.
    comp_failure = make_turbopump_at_rpm(3600.0; max_rpm = 3000.0)
    @test effective_turbine_conductance(comp_failure) > 0.0

    # Conductance reaches zero at the runaway RPM and stays there above it.
    comp_runaway = make_turbopump_at_rpm(3750.0; max_rpm = 3000.0)
    @test effective_turbine_conductance(comp_runaway) ≈ 0.0
    update_rpm!(comp_runaway.rotor, 1000.0)
    @test effective_turbine_conductance(comp_runaway) ≈ 0.0

    sampled = [effective_turbine_conductance(make_turbopump(current_rpm = rpm)) for rpm in 0.0:250.0:4000.0]
    @test all(diff(sampled) .≤ 0.0)

    # Transient overshoot: pump voltage remains capped while conductance stays positive below runaway.
    overshoot = make_turbopump(current_rpm = 2900.0, max_rpm = 3000.0)
    update_rpm!(overshoot.rotor, 200.0)  # push above max_rpm
    @test get_current_rpm(overshoot.rotor) ≈ 3100.0
    @test get_rpm_fraction(overshoot.rotor) == 1.0
    elems_overshoot = produce_rel_elements(overshoot)
    @test elems_overshoot[1].value ≈ overshoot.max_pump_voltage  # capped at max
    @test elems_overshoot[3].value > 0.0
    @test get_rated_rpm(overshoot) == 3000.0
    @test get_failure_rpm(overshoot) == 3600.0
    @test get_turbine_runaway_rpm(overshoot) == 3750.0
    @test get_overspeed_fraction(make_turbopump(current_rpm = 3000.0)) == 0.0
    @test get_overspeed_fraction(make_turbopump_at_rpm(3300.0)) ≈ 0.5
    @test get_overspeed_fraction(make_turbopump_at_rpm(3600.0)) == 1.0
    @test get_animation_rpm_fraction(make_turbopump_at_rpm(3600.0)) ≈ 1.2
end

@testset "Turbopump render helpers" begin
    base_colour = HexFlowPumpComponents.ColourType(0.4, 0.6, 0.8, 0.5)
    heated = make_turbopump()
    set_component_temperature!(heated.overheat, heated.overheat.limit_temperature_k * 1.2)
    layer_colours = HexFlowPumpComponents.turbopump_render_colours(base_colour, heated.overheat, 0.5)

    @test layer_colours.base == base_colour
    @test layer_colours.genturbine == multiply_colours(base_colour, get_overheat_tint(heated.overheat))
    @test layer_colours.genturbine != base_colour
    @test layer_colours.vibepart == multiply_colours(base_colour, HexFlowPumpComponents.ColourType(1.0, 0.5, 0.5, 1.0))
    @test HexFlowPumpComponents.turbopump_render_colours(base_colour, heated.overheat, 0.0).vibepart == base_colour
    @test HexFlowPumpComponents.turbopump_render_colours(base_colour, heated.overheat, 1.0).vibepart == multiply_colours(base_colour, HexFlowPumpComponents.ColourType(1.0, 0.0, 0.0, 1.0))
end

@testset "Turbopump vibration magnitude" begin
    stationary = make_turbopump()
    @test turbopump_vibe_magnitude(stationary, 0.75) == 0.0

    below_threshold = make_turbopump(current_rpm = 1.0)
    @test turbopump_vibe_magnitude(below_threshold, 0.0) == 0.0

    normal_activity = make_turbopump(current_rpm = 300.0)
    @test turbopump_vibe_magnitude(normal_activity, 0.75) ≈ 1.5

    full_activity = make_turbopump(current_rpm = 750.0)
    @test turbopump_vibe_magnitude(full_activity, 2.0) ≈ 2.0

    overspeed = make_turbopump_at_rpm(3300.0)
    @test turbopump_vibe_magnitude(overspeed, 0.0) ≈ 4.5

    damage!(overspeed.overheat)
    @test turbopump_vibe_magnitude(overspeed, 1.0) == 0.0
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
