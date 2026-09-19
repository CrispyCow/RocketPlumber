#=
Scope: Turbopump and electric-pump component behaviours with shared pump fragments
Formatter: Runic
=#
"""
Turbopump and electric-pump component behaviours for fluid pressurisation.

Exported concrete `ComponentBehavior` implementations:

- `TurboPumpCompBehav`: Gas-driven turbopump with delayed shaft drive
- `ElectricPumpCompBehav`: Electrically driven pump with energy management
"""
module HexFlowPumpComponents

using ColorSchemes, StaticArrays
using FlowEngine, FlowMap, HexElements, HexFluids, HexFrame
using HexComponentsAPI, HexFlowBasicComponents, HexFlowSwitchComponents
using HexFlowRendering, RenderEngine

# `ComponentBehavior` mandatory methods
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# `ComponentBehavior` optional methods
import HexComponentsAPI: on_click!, update_flowbehav!, render_map_elem!, get_actions, do_action!, produce_rel_fluid_declarations, map_mirroring, get_component_temperature
# Reactivation probe interface
import HexComponentsAPI: get_reactivation_probe, classify_reactivation_probe, commit_reactivation_probe!

# Behaviour Fragment Exports
export PumpBehavFrag, RotorStateBehavFrag, DelayedDriveBehavFrag
# Support Type Exports
export ElectricTurboPump, ElectricTransferPump
# Concrete Component Behaviour Exports
export TurboPumpCompBehav, ElectricPumpCompBehav

# ===============================================================
# Behaviour Fragments
# ===============================================================

#= ---------- PumpBehavFrag ----------- =#

"Encapsulates pump-specific parameters (voltage source only) with the pump's internal voltage."
struct PumpBehavFrag
    pump_voltage::Float64
end

const pump_element_index::Int = 1 # Pump voltage source element index
const turbine_element_index::Int = 3 # Turbine shunt resistor element index
const pump_probe_tol = 1.0e-9 # Tolerance for probe acceptance and deactivation detection

"Return the pump voltage after applying a clamped 0-1 scale factor."
get_scaled_pump_voltage(p::PumpBehavFrag, voltage_scale::Real)::Float64 = p.pump_voltage * clamp(Float64(voltage_scale), 0.0, 1.0)

"Construct the pump's voltage-source element with an externally supplied scale factor."
function make_pump_element(p::PumpBehavFrag, voltage_scale::Real; active::Bool = true)::RelativeElement
    voltage = active ? get_scaled_pump_voltage(p, voltage_scale) : 0.0
    return RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.NODE_Q_POS),
        voltage,
        HexElements.CONST_VOLTAGE;
        active = active
    )
end

function produce_rel_elements(p::PumpBehavFrag, is_pump_powered::Bool)::NTuple{1, RelativeElement}
    return (make_pump_element(p, is_pump_powered ? 1.0 : 0.0; active = true),)
end

function get_tunables(p::PumpBehavFrag)::NTuple{1, TunableProps}
    v = TunableProps(p.pump_voltage, "Pump internal voltage", "V")
    return (v,)
end

function set_tunables(p::PumpBehavFrag, tunables::NTuple{1, T})::PumpBehavFrag where {T <: Real}
    vals = Float64.(tunables)
    return PumpBehavFrag(vals[1])
end

#= ---------- EnergyStoreBehavFrag ----------- =#

"Encapsulates an energy storage system with current energy state and maximum capacity."
struct EnergyStoreBehavFrag
    stored_energy::FloatStateBehavFrag
    max_energy::Float64
end

get_current_energy(frag::EnergyStoreBehavFrag)::Float64 = getstate(frag.stored_energy)

get_max_energy(frag::EnergyStoreBehavFrag)::Float64 = frag.max_energy

"Changes energy by delta, clamped between [0, max_energy]."
function update_energy!(frag::EnergyStoreBehavFrag, delta_energy::Float64)
    setstate!(frag.stored_energy, clamp(getstate(frag.stored_energy) + delta_energy, 0.0, get_max_energy(frag)))
    return nothing
end

#= ---------- RotorStateBehavFrag ----------- =#

"""Encapsulates rotor RPM state and inertial tuning for pump spin-up and spin-down.

For a Turbo Pump, `max_rpm` is the rated RPM used to cap pump output. Stored RPM
may exceed the rated value during an overspeed event."""
struct RotorStateBehavFrag
    rpm::FloatStateBehavFrag
    max_rpm::Float64
    rotor_inertia::Float64
    friction_coefficient::Float64

    function RotorStateBehavFrag(rpm::FloatStateBehavFrag, max_rpm::Float64, rotor_inertia::Float64, friction_coefficient::Float64)
        # clamp above zero to prevent weird edge cases with negative or zero values
        friction_coefficient = max(friction_coefficient, 1.0e-6)
        rotor_inertia = max(rotor_inertia, 1.0e-6)
        max_rpm = max(max_rpm, 1.0e-6)
        setstate!(rpm, max(getstate(rpm), 0.0))

        return new(rpm, max_rpm, rotor_inertia, friction_coefficient)
    end
end

"Construct a rotor fragment with a clamped initial RPM value."
function RotorStateBehavFrag(; current_rpm::Real = 0.0, max_rpm::Real, rotor_inertia::Real, friction_coefficient::Real)
    max_rpm_f = Float64(max_rpm)
    rpm_state = FloatStateBehavFrag(clamp(Float64(current_rpm), 0.0, max_rpm_f))
    return RotorStateBehavFrag(rpm_state, max_rpm_f, Float64(rotor_inertia), Float64(friction_coefficient))
end

get_current_rpm(frag::RotorStateBehavFrag)::Float64 = getstate(frag.rpm)

"Gets the current rotor RPM as a clamped 0-1 fraction of rated RPM."
get_rpm_fraction(frag::RotorStateBehavFrag)::Float64 = clamp(get_current_rpm(frag) / frag.max_rpm, 0.0, 1.0)

"Changes RPM by delta, clamped at zero."
function update_rpm!(frag::RotorStateBehavFrag, delta_rpm::Float64)
    setstate!(frag.rpm, max(get_current_rpm(frag) + delta_rpm, 0.0))
    return nothing
end

#= ---------- DelayedDriveBehavFrag ----------- =#

"Stores turbine-drive power and follows a target through a first-order delay."
struct DelayedDriveBehavFrag
    power::FloatStateBehavFrag
    time_constant::Float64

    function DelayedDriveBehavFrag(power::FloatStateBehavFrag, time_constant::Real)
        setstate!(power, max(getstate(power), 0.0))
        return new(power, max(Float64(time_constant), 1.0 / BASE_UPS))
    end
end

"Rebuild a delayed-drive fragment around an existing mutable power state."
DelayedDriveBehavFrag(power::FloatStateBehavFrag; time_constant::Real = 1.0) = DelayedDriveBehavFrag(power, time_constant)

"Construct a delayed-drive fragment with clamped initial power and time constant."
function DelayedDriveBehavFrag(; current_power::Real = 0.0, time_constant::Real = 1.0)
    return DelayedDriveBehavFrag(FloatStateBehavFrag(Float64(current_power)), time_constant)
end

"Gets the currently filtered turbine-drive power."
get_delayed_drive_power(frag::DelayedDriveBehavFrag)::Float64 = getstate(frag.power)

"Gets the diagnostic energy represented by the delayed-drive state."
get_stored_drive_energy(frag::DelayedDriveBehavFrag)::Float64 = frag.time_constant * get_delayed_drive_power(frag)

"Moves delayed drive exponentially towards a non-negative raw-power target."
function update_delayed_drive!(frag::DelayedDriveBehavFrag, raw_drive_power::Real; dt::Real = 1.0 / BASE_UPS)
    current_power = get_delayed_drive_power(frag)
    target_power = max(Float64(raw_drive_power), 0.0)
    alpha = -expm1(-Float64(dt) / frag.time_constant)
    setstate!(frag.power, max(current_power + alpha * (target_power - current_power), 0.0))
    return nothing
end

# Turbopump tuning, thresholds, and palette
const TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE::Float64 = 1.0e-3
const TURBOPUMP_TURBINE_POWER_SCALING::Float64 = 1.0e-4
const TURBOPUMP_TURBINE_TEMPERATURE_POWER_SCALING::Float64 = 0.45
const TURBOPUMP_RENDER_MAX_ROTATION_SPEED::Float64 = 900.0
const TURBOPUMP_SMOKE_CURRENT_THRESHOLD::Float64 = 0.02
const TURBOPUMP_GENTURBINE_HEIGHT_OFFSET::Int = 5
const TURBOPUMP_VIBE_ACTIVITY_THRESHOLD::Float64 = 1.0e-3
const TURBOPUMP_MIN_ACTIVE_VIBE_MAGNITUDE_PX::Float64 = 0.75
const TURBOPUMP_FAILURE_RPM_RATIO::Float64 = 1.2
const TURBOPUMP_TURBINE_RUNAWAY_RPM_RATIO::Float64 = 1.25
const TURBOPUMP_TURBINE_CONDUCTANCE_EXPONENT::Float64 = 0.7
const TURBOPUMP_LOW_SPEED_DRAG_RPM::Float64 = 300.0
const TURBOPUMP_LOW_SPEED_DRAG_MAX_MULTIPLIER::Float64 = 4.0
const TURBOPUMP_STOP_RPM_THRESHOLD::Float64 = 1.0
const TURBOPUMP_MAX_EXTRA_OVERSPEED_VIBE_PX::Float64 = 10.0
const TURBOPUMP_SPEED_SAFE_COLOUR = ColourType(0.25, 0.8, 0.25, 1.0)
const TURBOPUMP_SPEED_OVERSPEED_COLOUR = ColourType(0.9, 0.55, 0.2, 1.0)
const TURBOPUMP_SPEED_DAMAGED_COLOUR = ColourType(0.8, 0.25, 0.25, 1.0)

"Compute branchless viscous and low-speed shaft drag for a non-negative RPM."
function turbopump_shaft_drag(friction_coefficient::Real, rpm::Real)::Float64
    nonnegative_rpm = max(Float64(rpm), 0.0)
    coefficient = Float64(friction_coefficient)
    normal_drag = coefficient * nonnegative_rpm
    threshold_drag = coefficient * TURBOPUMP_LOW_SPEED_DRAG_RPM
    low_speed_fraction = clamp(1.0 - nonnegative_rpm / TURBOPUMP_LOW_SPEED_DRAG_RPM, 0.0, 1.0)
    low_speed_drag = threshold_drag * (1.0 + (TURBOPUMP_LOW_SPEED_DRAG_MAX_MULTIPLIER - 1.0) * low_speed_fraction)
    return max(normal_drag, low_speed_drag)
end

"Returns the base, generator-tinted, and overspeed-tinted turbopump colours."
function turbopump_render_colours(base_colour::ColourType, overheat::OverheatLimitBehavFrag, overspeed_fraction::Real = 0.0)
    overspeed_tint_fraction = clamp(Float64(overspeed_fraction), 0.0, 1.0)
    overspeed_tint = ColourType(1.0, 1.0 - overspeed_tint_fraction, 1.0 - overspeed_tint_fraction, 1.0)
    return (
        base = base_colour,
        genturbine = multiply_colours(base_colour, get_overheat_tint(overheat)),
        vibepart = multiply_colours(base_colour, overspeed_tint),
    )
end


# ===============================================================
# Concrete Component Behaviours
# ===============================================================

#= ---------- TurboPumpCompBehav ----------- =#

"""
Rocket engine turbopump with variable-conductance turbine and delayed shaft drive.

The turbine conductance follows a decreasing power curve and reaches zero at the
turbine runaway RPM, above the rated and failure speeds. Pump output remains
capped at rated RPM while stored shaft RPM can enter the overspeed band.
"""
struct TurboPumpCompBehav <: ComponentBehavior
    max_pump_voltage::Float64         # pump pressure at full RPM
    series_conductance::Float64       # pump-side Thévenin series conductance
    max_turbine_conductance::Float64  # turbine conductance at 0 RPM (drops to 0 at runaway RPM)
    cycle_efficiency::Float64         # turbine energy conversion factor (0–1)
    delayed_drive::DelayedDriveBehavFrag  # filtered turbine-drive power
    rotor::RotorStateBehavFrag        # RPM state, inertia, viscous drag, rated RPM
    deactivation::AutoDeactivationBehavFrag  # auto-deactivation state (replaces manual stall)
    overheat::OverheatLimitBehavFrag  # turbine thermal state and persistent damage
end

function TurboPumpCompBehav(;
        max_pump_voltage::Real,
        series_conductance::Real,
        max_turbine_conductance::Real = 0.3,
        cycle_efficiency::Real = 0.6,
        current_rpm::Real = 0.0,
        max_rpm::Real = 3000.0,
        rotor_inertia::Real = 50.0,
        friction_coefficient::Real = 0.002,
        current_delayed_drive_power::Real = 0.0,
        drive_time_constant::Real = 1.25,
        deactivation::AutoDeactivationBehavFrag = AutoDeactivationBehavFrag(),
        limit_temperature_k::Float64 = 1500.0,
        thermal_mass::Float64 = 2.0,
        heat_loss_factor::Float64 = 0.05
    )
    rotor = RotorStateBehavFrag(
        current_rpm = current_rpm,
        max_rpm = max_rpm,
        rotor_inertia = rotor_inertia,
        friction_coefficient = friction_coefficient
    )
    delayed_drive = DelayedDriveBehavFrag(current_power = current_delayed_drive_power, time_constant = drive_time_constant)
    overheat = OverheatLimitBehavFrag(
        limit_temperature_k,
        thermal_mass,
        heat_loss_factor;
        temperature = ComponentTemperatureBehavFrag(),
        damage = DamageStateBehavFrag()
    )
    return TurboPumpCompBehav(
        Float64(max_pump_voltage),
        max(Float64(series_conductance), 0.0),
        max(Float64(max_turbine_conductance), 0.0),
        max(Float64(cycle_efficiency), 1.0e-6),
        delayed_drive,
        rotor,
        deactivation,
        overheat
    )
end

get_rated_rpm(comp::TurboPumpCompBehav)::Float64 = comp.rotor.max_rpm

"Return the RPM threshold at which the turbopump is persistently damaged by overspeed."
get_failure_rpm(comp::TurboPumpCompBehav)::Float64 = get_rated_rpm(comp) * TURBOPUMP_FAILURE_RPM_RATIO

"Return the RPM at which turbine conductance falls to zero."
get_turbine_runaway_rpm(comp::TurboPumpCompBehav)::Float64 = get_rated_rpm(comp) * TURBOPUMP_TURBINE_RUNAWAY_RPM_RATIO

"Return the current RPM's fraction through the rated-to-failure overspeed band."
function get_overspeed_fraction(comp::TurboPumpCompBehav)::Float64
    rated_rpm = get_rated_rpm(comp)
    return clamp((get_current_rpm(comp.rotor) - rated_rpm) / (get_failure_rpm(comp) - rated_rpm), 0.0, 1.0)
end

"Return an animation fraction that exposes RPM from zero through the failure threshold."
function get_animation_rpm_fraction(comp::TurboPumpCompBehav)::Float64
    return clamp(get_current_rpm(comp.rotor) / get_rated_rpm(comp), 0.0, TURBOPUMP_FAILURE_RPM_RATIO)
end

"Return the turbopump speed indicator's fill fraction and status colour."
function turbopump_speed_indicator(comp::TurboPumpCompBehav)
    fill_fraction = get_rpm_fraction(comp.rotor)
    colour = if is_damaged(comp.overheat)
        TURBOPUMP_SPEED_DAMAGED_COLOUR
    elseif get_current_rpm(comp.rotor) > get_rated_rpm(comp)
        TURBOPUMP_SPEED_OVERSPEED_COLOUR
    else
        TURBOPUMP_SPEED_SAFE_COLOUR
    end
    return (; fill_fraction, colour)
end

"Compute total turbopump pipework vibration magnitude from the current component state."
function turbopump_vibe_magnitude(comp::TurboPumpCompBehav, pump_flow_fraction::Real)::Float64
    is_damaged(comp.overheat) && return 0.0

    rpm_fraction = get_rpm_fraction(comp.rotor)
    rpm_fraction <= 0.0 && return 0.0
    activity = clamp(max(rpm_fraction, Float64(pump_flow_fraction)), 0.0, 1.0)
    normal_vibe_magnitude = activity <= TURBOPUMP_VIBE_ACTIVITY_THRESHOLD ? 0.0 : max(TURBOPUMP_MIN_ACTIVE_VIBE_MAGNITUDE_PX, 2.0 * activity)

    return normal_vibe_magnitude + TURBOPUMP_MAX_EXTRA_OVERSPEED_VIBE_PX * get_overspeed_fraction(comp)^2
end

"Compute effective turbine conductance at the current RPM."
function effective_turbine_conductance(comp::TurboPumpCompBehav)::Float64
    rpm_fraction = clamp(get_current_rpm(comp.rotor) / get_turbine_runaway_rpm(comp), 0.0, 1.0)
    return comp.max_turbine_conductance * max(1.0 - rpm_fraction^TURBOPUMP_TURBINE_CONDUCTANCE_EXPONENT, 0.0)
end

function produce_rel_elements(comp::TurboPumpCompBehav)::NTuple{3, RelativeElement}
    active = !is_inactive(comp.deactivation) && !is_damaged(comp.overheat)
    rpm_fraction = get_rpm_fraction(comp.rotor)
    pump_voltage = active ? comp.max_pump_voltage * rpm_fraction : 0.0

    pump_source = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.NODE_Q_POS),
        pump_voltage,
        HexElements.CONST_VOLTAGE;
        active = active
    )
    series_resistor = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.NODE_Q_NEG),
        comp.series_conductance,
        HexElements.CONST_RESISTOR;
        active = active
    )
    turbine_resistor = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_S_POS, HexFrame.GROUND),
        effective_turbine_conductance(comp),
        HexElements.CONST_RESISTOR;
        active = active
    )

    return (pump_source, series_resistor, turbine_resistor)
end

function get_tunables(comp::TurboPumpCompBehav)::NTuple{13, TunableProps}
    return (
        TunableProps(comp.max_pump_voltage, "Max pump voltage", "V"),
        TunableProps(comp.series_conductance, "Series conductance", "1/R"),
        TunableProps(comp.max_turbine_conductance, "Max turbine conductance", "1/R"),
        TunableProps(get_current_rpm(comp.rotor), "Current RPM", "RPM"),
        TunableProps(comp.rotor.max_rpm, "Rated RPM", "RPM"),
        TunableProps(comp.rotor.rotor_inertia, "Rotor inertia", ""),
        TunableProps(comp.rotor.friction_coefficient, "Viscous drag coefficient", "power/RPM"),
        TunableProps(comp.cycle_efficiency, "Cycle efficiency", ""),
        TunableProps(get_delayed_drive_power(comp.delayed_drive), "Current delayed drive power", "power"),
        TunableProps(comp.delayed_drive.time_constant, "Drive time constant", "s"),
        get_tunables(comp.overheat)...,
    )
end

function set_tunables(comp::TurboPumpCompBehav, tunables::NTuple{13, T})::TurboPumpCompBehav where {T <: Real}
    vals = Float64.(tunables)
    newrotor = RotorStateBehavFrag(comp.rotor.rpm, vals[5], vals[6], vals[7])
    newdrive = DelayedDriveBehavFrag(comp.delayed_drive.power, vals[10])
    newoverheat = set_tunables(comp.overheat, (vals[11], vals[12], vals[13]))
    comp = TurboPumpCompBehav(
        vals[1],
        max(vals[2], 0.0),
        max(vals[3], 0.0),
        max(vals[8], 1.0e-6),
        newdrive,
        newrotor,
        comp.deactivation,
        newoverheat
    )
    setstate!(comp.rotor.rpm, max(vals[4], 0.0))
    setstate!(comp.delayed_drive.power, max(vals[9], 0.0))
    return comp
end

function produce_rel_fluid_declarations(::TurboPumpCompBehav)
    return (
        RelativeFluidDeclaration(HexFrame.NODE_Q_POS, HexFluids.FluidConstraintRule(HexFluids.IS_LIQUID)),
        RelativeFluidDeclaration(HexFrame.NODE_Q_NEG, HexFluids.FluidConstraintRule(HexFluids.IS_LIQUID)),
        RelativeFluidDeclaration(HexFrame.NODE_S_POS, HexFluids.FluidConstraintRule(HexFluids.IS_GAS)),
    )
end

map_mirroring(::TurboPumpCompBehav, mirrored::Bool) = mirrored

# Auto-deactivation requires no manual reset on click.
on_click!(comp::TurboPumpCompBehav; kwargs...) = nothing
get_component_temperature(comp::TurboPumpCompBehav; kwargs...) = get_component_temperature(comp.overheat)
get_actions(comp::TurboPumpCompBehav; kwargs...) = get_actions(comp.overheat; kwargs...)
do_action!(comp::TurboPumpCompBehav, action_id::Symbol; kwargs...) = do_action!(comp.overheat, action_id; kwargs...)

"""
Update delayed turbine drive, rotor RPM, thermal state, and harmful-flow deactivation.

Turbine drive is filtered before rotor power is integrated against pump load and
shaft drag; reverse turbine flow deactivates the pump, while overspeed damages it
at the failure threshold.
"""
function update_flowbehav!(comp::TurboPumpCompBehav; mna_state::MNA_State, tile::TileCoord, rotation::HexAxis, mirrored::Bool = false, derivedmapstate::DerivedMapState, kwargs...)
    applied_inertia = comp.rotor.rotor_inertia * TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    shaft_drag = turbopump_shaft_drag(comp.rotor.friction_coefficient, get_current_rpm(comp.rotor))
    s_pos_node = map_element(HexFrame.NODE_S_POS, tile, rotation, mirrored)
    s_pos_fluid = get(derivedmapstate.nodeactualfluids, s_pos_node, nothing)
    fluid_temperature_k = get(derivedmapstate.node_temperatures, s_pos_node, THERMAL_AMBIENT_TEMPERATURE_K)
    raw_drive_power = 0.0
    pump_power = 0.0
    mass_flow_rate = 0.0

    if !is_inactive(comp.deactivation) && !is_damaged(comp.overheat)
        # Read turbine shunt current (signed) to detect harmful reverse flow.
        # Turbine element: NODE_S_POS → GROUND, current = V_s_pos × G_turbine.
        s_pos_voltage = get(mna_state.node_voltages, s_pos_node, 0.0)
        turbine_g = effective_turbine_conductance(comp)
        turbine_current = s_pos_voltage * turbine_g  # signed; negative means reverse flow into S_POS

        # Deactivate when reverse flow through the turbine sink exceeds tolerance.
        if turbine_current < -pump_probe_tol
            deactivate!(comp.deactivation)
        else
            # Forward turbine current only contributes to power; reverse current is allowed but yields no energy.
            turbine_current_forward = max(turbine_current, 0.0)
            fluid_density = isnothing(s_pos_fluid) ? 0.0 : something(lookup_fluid_density(s_pos_fluid), 0.0)
            temperature_change_k = max(fluid_temperature_k - THERMAL_AMBIENT_TEMPERATURE_K, 0.0)
            turbine_power = fluid_density * turbine_current_forward * temperature_change_k * TURBOPUMP_TURBINE_TEMPERATURE_POWER_SCALING
            raw_drive_power = comp.cycle_efficiency * turbine_power

            # Pump load — clamp to forward pump current only.
            # Reverse pump current is allowed hydraulically but intentionally excluded from rotor energy
            # integration; the clamp below is what bounds it, not deactivation.
            source_current = get(mna_state.vsource_currents, ElementID(tile, pump_element_index), 0.0)
            pump_current = max(-Float64(source_current), 0.0)
            rpm_fraction = get_rpm_fraction(comp.rotor)
            pump_voltage = comp.max_pump_voltage * rpm_fraction
            pump_power = pump_voltage * pump_current
            mass_flow_rate = turbine_current_forward * fluid_density
        end
    end

    update_delayed_drive!(comp.delayed_drive, raw_drive_power)
    net_shaft_power = get_delayed_drive_power(comp.delayed_drive) - pump_power - shaft_drag
    delta_rpm = net_shaft_power / (applied_inertia * BASE_UPS)
    update_rpm!(comp.rotor, delta_rpm)
    if net_shaft_power <= 0.0 && get_current_rpm(comp.rotor) < TURBOPUMP_STOP_RPM_THRESHOLD
        setstate!(comp.rotor.rpm, 0.0)
    end
    get_current_rpm(comp.rotor) >= get_failure_rpm(comp) && damage!(comp.overheat)

    update_overheat_state!(
        comp.overheat;
        fluid_temperature_k = fluid_temperature_k,
        mass_flow_rate = mass_flow_rate
    )

    return nothing
end

"""Return a three-element probe matching `produce_rel_elements` for the speculative reactivation
scheduler, or `nothing` when the pump is already active. The pump voltage source reflects the
current rotor RPM at the time of probing."""
function get_reactivation_probe(comp::TurboPumpCompBehav; kwargs...)
    is_damaged(comp.overheat) && return nothing
    is_inactive(comp.deactivation) || return nothing
    rpm_fraction = get_rpm_fraction(comp.rotor)
    pump_source = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.NODE_Q_POS),
        comp.max_pump_voltage * rpm_fraction,
        HexElements.CONST_VOLTAGE;
        active = true
    )
    series_resistor = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.NODE_Q_NEG),
        comp.series_conductance,
        HexElements.CONST_RESISTOR;
        active = true
    )
    turbine_resistor = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_S_POS, HexFrame.GROUND),
        effective_turbine_conductance(comp),
        HexElements.CONST_RESISTOR;
        active = true
    )
    return ReactivationProbe((pump_source, series_resistor, turbine_resistor))
end

"""
Classify reactivation when the speculative turbine shunt current is not harmfully reversed.
Useful and neutral turbine flow are both accepted at the shared API boundary, while
harmful reverse flow blocks reactivation. Pruned turbine elements classify neutral.
"""
function classify_reactivation_probe(comp::TurboPumpCompBehav; tile::TileCoord, rotation::HexAxis, mirrored::Bool = false, derivedmapstate::DerivedMapState, mna_state, kwargs...)
    turbine_rel_elem = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_S_POS, HexFrame.GROUND),
        effective_turbine_conductance(comp),
        HexElements.CONST_RESISTOR;
        active = true
    )
    turbine_abs_elem = map_element(turbine_rel_elem, tile, turbine_element_index, rotation, mirrored)
    turbine_current = abs_element_get_current(turbine_abs_elem, derivedmapstate, mna_state)
    isnothing(turbine_current) && return HexComponentsAPI.PROBE_NEUTRAL
    turbine_current < -pump_probe_tol && return HexComponentsAPI.PROBE_HARMFUL
    return HexComponentsAPI.PROBE_USEFUL
end

"Reactivate the pump after the scheduler accepts a useful speculative probe."
function commit_reactivation_probe!(comp::TurboPumpCompBehav; kwargs...)
    reactivate!(comp.deactivation)
    return nothing
end

function render_base_elem!(queue::Vector{<:RenderCommand}, comp::TurboPumpCompBehav; glmap::GLObjectMap, rotation::HexAxis, mirrored::Bool = false, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    fluidmask_colour = DEFAULT_EMPTY_FLUID_COLOUR
    render_colours = turbopump_render_colours(colour, comp.overheat, get_overspeed_fraction(comp))
    speed_indicator = turbopump_speed_indicator(comp)
    genturbine_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + TURBOPUMP_GENTURBINE_HEIGHT_OFFSET + render_height_offset)

    # Fluid mask.
    push!(queue, render_basic_tile(glmap, :TurboPump1_fluidmask, rotation, position; mirrored = mirrored, scale = scale, colour = fluidmask_colour, transparency = transparency, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))
    # Rated-RPM speed mask, including its opaque black empty region.
    push!(queue, render_basic_tile(glmap, :TurboPump1_speedmask, rotation, position; mirrored = mirrored, scale = scale, transparency = transparency, colour = speed_indicator.colour, unclipped_texcoord = SVector(1.0, speed_indicator.fill_fraction), draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 10 + render_height_offset), pos_offset = pos_offset))
    # Rotor.
    push!(queue, render_basic_tile(glmap, :TurboPump1_rotor, rotation, position; mirrored = mirrored, scale = scale, transparency = transparency, colour = render_colours.base, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 10 + render_height_offset), pos_offset = pos_offset))
    # Static housing.
    push!(queue, render_basic_tile(glmap, :TurboPump1_static, rotation, position; mirrored = mirrored, scale = scale, transparency = transparency, colour = render_colours.base, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + render_height_offset), pos_offset = pos_offset))
    # Temperature-reactive generator turbine.
    push!(queue, render_basic_tile(glmap, :TurboPump1_genturbine, rotation, position; mirrored = mirrored, scale = scale, transparency = transparency, colour = render_colours.genturbine, draw_height = genturbine_height, pos_offset = pos_offset))
    # Vibrating pipework.
    push!(queue, render_basic_tile(glmap, :TurboPump1_vibepart, rotation, position; mirrored = mirrored, scale = scale, transparency = transparency, colour = render_colours.vibepart, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + 10 + render_height_offset), pos_offset = pos_offset))

    return nothing
end

function render_map_elem!(queue::Vector{<:RenderCommand}, comp::TurboPumpCompBehav; glmap::GLObjectMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot, gameticks::Int64, rotation::HexAxis, mirrored::Bool = false, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    render_colours = turbopump_render_colours(ColourType(1.0, 1.0, 1.0, 1.0), comp.overheat, get_overspeed_fraction(comp))
    speed_indicator = turbopump_speed_indicator(comp)
    genturbine_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + TURBOPUMP_GENTURBINE_HEIGHT_OFFSET + render_height_offset)

    # Get turbine fluid colour
    turbine_input_node = map_element(HexFrame.NODE_S_POS, position, rotation, mirrored)
    fluid = get(derivedmapstate.nodeactualfluids, turbine_input_node, nothing)
    temperature = get(derivedmapstate.node_temperatures, turbine_input_node, HexFluids.THERMAL_AMBIENT_TEMPERATURE_K)
    fluidmask_colour = !isnothing(fluid) ? get_fluid_colour(fluid, temperature) : DEFAULT_EMPTY_FLUID_COLOUR

    # get turbine state from MNA solution
    source_current = get(mna_state.vsource_currents, ElementID(position, pump_element_index), 0.0)
    pump_flow = max(-Float64(source_current), 0.0)
    s_pos_voltage = get(mna_state.node_voltages, turbine_input_node, 0.0)
    turbine_g = effective_turbine_conductance(comp)
    turbine_current = max(s_pos_voltage * turbine_g, 0.0)
    animation_rpm_fraction = get_animation_rpm_fraction(comp)
    max_pump_flow = max(comp.max_pump_voltage * comp.series_conductance, 1.0e-6)
    pump_flow_fraction = clamp(pump_flow / max_pump_flow, 0.0, 1.0)
    vibe_magnitude = turbopump_vibe_magnitude(comp, pump_flow_fraction)

    smoke_sprites = (:TurboPump1_smoke_1, :TurboPump1_smoke_2, :TurboPump1_smoke_3)

    # Fluid mask.
    push!(queue, render_basic_tile(glmap, :TurboPump1_fluidmask, rotation, position; mirrored = mirrored, colour = fluidmask_colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))
    # Rated-RPM speed mask, including its opaque black empty region.
    push!(queue, render_basic_tile(glmap, :TurboPump1_speedmask, rotation, position; mirrored = mirrored, colour = speed_indicator.colour, unclipped_texcoord = SVector(1.0, speed_indicator.fill_fraction), draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 10 + render_height_offset), pos_offset = pos_offset))

    # Rotor.
    if animation_rpm_fraction > 0.0
        rotor_rotation = animation_rotate(gameticks, TURBOPUMP_RENDER_MAX_ROTATION_SPEED * animation_rpm_fraction)
        push!(queue, render_basic_tile(glmap, :TurboPump1_rotor, rotation, position; mirrored = mirrored, colour = render_colours.base, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100 + render_height_offset), pos_offset = pos_offset, sprite_rotation_tweak_mat = rotor_rotation))
    else
        push!(queue, render_basic_tile(glmap, :TurboPump1_rotor, rotation, position; mirrored = mirrored, colour = render_colours.base, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100 + render_height_offset), pos_offset = pos_offset))
    end

    # Static housing.
    push!(queue, render_basic_tile(glmap, :TurboPump1_static, rotation, position; mirrored = mirrored, colour = render_colours.base, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + render_height_offset), pos_offset = pos_offset))
    push!(queue, render_basic_tile(glmap, :TurboPump1_genturbine, rotation, position; mirrored = mirrored, colour = render_colours.genturbine, draw_height = genturbine_height, pos_offset = pos_offset))

    # Vibrating pipework.
    if vibe_magnitude > 0.0
        vibe_offset = animation_vibe_offset(gameticks; magnitude = vibe_magnitude)
        vibe_offset_vec = SVector{2, Float32}(Float32.(vibe_offset)...)
        push!(queue, render_basic_tile(glmap, :TurboPump1_vibepart, rotation, position; mirrored = mirrored, colour = render_colours.vibepart, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM + render_height_offset), pos_offset = pos_offset, sprite_offset_tweak_px = vibe_offset_vec))
    else
        push!(queue, render_basic_tile(glmap, :TurboPump1_vibepart, rotation, position; mirrored = mirrored, colour = render_colours.vibepart, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM + render_height_offset), pos_offset = pos_offset))
    end

    # Turbine exhaust smoke.
    if turbine_current > TURBOPUMP_SMOKE_CURRENT_THRESHOLD
        smoke_sprite = animation_sprite_picker(smoke_sprites, gameticks, 4)
        push!(queue, render_basic_tile(glmap, smoke_sprite, rotation, position; mirrored = mirrored, colour = fluidmask_colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM) + Int32(10) + Int32(render_height_offset), pos_offset = pos_offset))
    end

    render_map_elem!(queue, comp.overheat; glmap, rotation, position, pos_offset, render_height_offset, kwargs...)

    return nothing
end

#= ---------- ElectricPumpCompBehav ----------- =#

"Abstract type used to label specific ElectricPumpCompBehav types with a type parameter for dispatch traits."
abstract type ElectricPumpType end

"Pump component consisting of a Thévenin pump driven by electrical power from an internal energy store."
struct ElectricPumpCompBehav{T <: ElectricPumpType} <: ComponentBehavior
    pump::PumpBehavFrag
    energy::EnergyStoreBehavFrag
    switch::BoolSwitchBehavFrag
end
function ElectricPumpCompBehav(
        ::Type{T};
        pump_voltage::Float64,
        max_energy::Float64,
        initial_energy::Float64,
        max_conductance::Float64,
        min_conductance::Float64,
        growth_factor::Float64
    ) where {T <: ElectricPumpType}
    @assert initial_energy ≤ max_energy "Initial energy ($initial_energy) exceeds max energy ($max_energy) for ElectricPumpCompBehav"

    pumpfrag = PumpBehavFrag(pump_voltage)
    energystate = FloatStateBehavFrag(initial_energy)
    energyfrag = EnergyStoreBehavFrag(energystate, max_energy)

    # Switch connecting internal to Q_NEG (replacing old series resistor position)
    switch_connection = RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.NODE_Q_NEG)
    switchfrag = BoolSwitchBehavFrag(
        connection = switch_connection,
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        growth_factor = growth_factor,
        target_conductance = min_conductance,
        current_conductance = min_conductance
    )

    return ElectricPumpCompBehav{T}(pumpfrag, energyfrag, switchfrag)
end

function produce_rel_elements(comp::ElectricPumpCompBehav)::NTuple{2, RelativeElement}
    # Pump is powered when there is energy in the store
    has_energy = get_current_energy(comp.energy) > 0.0
    pump_rels = produce_rel_elements(comp.pump, has_energy)
    switch_rels = produce_rel_elements(comp.switch)
    return (pump_rels[1], switch_rels[1])
end

function get_tunables(comp::ElectricPumpCompBehav)::NTuple{5, TunableProps}
    pump_tun = get_tunables(comp.pump)
    switch_tun = get_tunables(comp.switch)
    return (
        pump_tun[1],
        TunableProps(get_current_energy(comp.energy), "Current stored energy", "EU"),
        TunableProps(get_max_energy(comp.energy), "Max stored energy", "EU"),
        switch_tun[1],
        switch_tun[2],
    )
end

function set_tunables(comp::ElectricPumpCompBehav, tunables::NTuple{5, T})::ElectricPumpCompBehav where {T <: Real}
    vals = Float64.(tunables)
    # Preserve parametric type T for ElectricPumpCompBehav{T} to avoid calling default constructor without type parameter
    curtype = typeof(comp)
    newpump = set_tunables(comp.pump, (vals[1],))
    newenergy = EnergyStoreBehavFrag(comp.energy.stored_energy, vals[3])
    switch_tun = get_tunables(comp.switch)
    newswitch = set_tunables(comp.switch, (vals[4], vals[5], switch_tun[3].current_val))
    comp = curtype(newpump, newenergy, newswitch)
    # Set current energy to the specified value, clamped to [0, max]
    setstate!(comp.energy.stored_energy, clamp(vals[2], 0.0, vals[3]))
    return comp
end

function produce_rel_fluid_declarations(::ElectricPumpCompBehav)
    return (
        RelativeFluidDeclaration(HexFrame.NODE_Q_POS, HexFluids.FluidConstraintRule(HexFluids.IS_LIQUID)),
        RelativeFluidDeclaration(HexFrame.NODE_Q_NEG, HexFluids.FluidConstraintRule(HexFluids.IS_LIQUID)),
    )
end

"Updates switch behaviour and consumes energy proportional to pump flow rate."
function update_flowbehav!(comp::ElectricPumpCompBehav; mna_state::MNA_State, tile::TileCoord, kwargs...)
    # Delegate to switch for its behaviour update
    update_flowbehav!(comp.switch; kwargs...)

    # Consume energy proportional to flow rate when pump is running
    has_energy = get_current_energy(comp.energy) > 0.0
    if has_energy
        pump_current = get(mna_state.vsource_currents, ElementID(tile, pump_element_index), 0.0)
        flow_rate = abs(pump_current)
        energy_used = flow_rate * comp.pump.pump_voltage
        update_energy!(comp.energy, -energy_used)
    else
        # Automatically switch off the pump when energy runs out
        set_target_conductance_to_min!(comp.switch)
    end

    return nothing
end

function on_click!(comp::ElectricPumpCompBehav; kwargs...)
    has_energy = get_current_energy(comp.energy) > 0.0
    if has_energy
        on_click!(comp.switch)
    end
    return nothing
end

function get_actions(comp::ElectricPumpCompBehav; kwargs...)
    # Get the switch actions (which would say "Open Valve" / "Close Valve")
    switch_actions = get_actions(comp.switch)

    # Rewrite to pump-appropriate labels
    rewritten = map(switch_actions) do action
        if action.id === :open_valve
            tooltip = action.enabled ? "Activate pump to begin pumping fluid" : "Pump is already on"
            return ActionInfo(
                id = :pump_on,
                label = "Turn Pump On",
                enabled = action.enabled,
                group_enabled = action.group_enabled,
                tooltip = tooltip,
            )
        elseif action.id === :close_valve
            tooltip = action.enabled ? "Deactivate pump" : "Pump is already off"
            return ActionInfo(
                id = :pump_off,
                label = "Turn Pump Off",
                enabled = action.enabled,
                group_enabled = action.group_enabled,
                tooltip = tooltip,
            )
        else
            return action
        end
    end

    return Tuple(rewritten)
end

function do_action!(comp::ElectricPumpCompBehav, action_id::Symbol; kwargs...)
    if action_id === :pump_on
        return do_action!(comp.switch, :open_valve)
    elseif action_id === :pump_off
        return do_action!(comp.switch, :close_valve)
    end
    throw(ArgumentError("Action :$(action_id) not recognised by ElectricPumpCompBehav"))
end

# Electric-pump render traits
"Rendering trait type for electric turbopump variant"
struct ElectricTurboPump <: ElectricPumpType end
chargemask_sprite(::ElectricPumpCompBehav{ElectricTurboPump}) = :ElectroPump1_chargemask
fluidmask_sprite(::ElectricPumpCompBehav{ElectricTurboPump}) = nothing
static_sprite(::ElectricPumpCompBehav{ElectricTurboPump}) = :ElectroPump1_static
vibrating_sprite(::ElectricPumpCompBehav{ElectricTurboPump}) = :ElectroPump1_vibe
rotor_sprite(::ElectricPumpCompBehav{ElectricTurboPump}) = :ElectroPump1_rotor

"Rendering trait type for electric transfer pump variant"
struct ElectricTransferPump <: ElectricPumpType end
chargemask_sprite(::ElectricPumpCompBehav{ElectricTransferPump}) = :ElectroTransferPump_chargemask
fluidmask_sprite(::ElectricPumpCompBehav{ElectricTransferPump}) = :ElectroTransferPump_fluidmask
static_sprite(::ElectricPumpCompBehav{ElectricTransferPump}) = :ElectroTransferPump_static
vibrating_sprite(::ElectricPumpCompBehav{ElectricTransferPump}) = nothing
rotor_sprite(::ElectricPumpCompBehav{ElectricTransferPump}) = :ElectroTransferPump_rotor

# Electric-pump render helpers
function render_static!(queue::Vector{<:RenderCommand}, comp::ElectricPumpCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, fluid::Union{FluidType, Nothing} = nothing, gameticks::Int64 = 0, temperature::Float64 = HexFluids.THERMAL_AMBIENT_TEMPERATURE_K, charge_bar_colour::ColourType = (c = get(ColorSchemes.summer, 0.0); ColourType(c.r, c.g, c.b, 1.0)), pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0)
    # Render charge bar
    energy_frac = get_current_energy(comp.energy) / get_max_energy(comp.energy)
    push!(queue, render_basic_tile(glmap, chargemask_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = charge_bar_colour, unclipped_texcoord = SVector(energy_frac, 1.0), draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))

    # Render fluid mask if it exists
    if !isnothing(fluidmask_sprite(comp))
        if isnothing(fluid)
            push!(queue, render_basic_tile(glmap, fluidmask_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = DEFAULT_EMPTY_FLUID_COLOUR, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))
        elseif is_liquid(fluid)
            fluidmask_colour = get_fluid_colour(fluid, temperature)
            push!(queue, render_liquid_tile(glmap, fluidmask_sprite(comp), rotation, position, gameticks; colour = fluidmask_colour, scale = scale, transparency = transparency, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))
        else
            fluidmask_colour = get_fluid_colour(fluid, temperature)
            push!(queue, render_basic_tile(glmap, fluidmask_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = fluidmask_colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))
        end
    end

    # Render static background
    push!(queue, render_basic_tile(glmap, static_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + render_height_offset), pos_offset = pos_offset))

    return nothing
end

function render_base_elem!(queue::Vector{<:RenderCommand}, comp::ElectricPumpCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    # Render non-animated elements
    render_static!(queue, comp; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, scale = scale, transparency = transparency, colour = colour, render_height_offset = render_height_offset)

    # Render vibrating part above static
    if !isnothing(vibrating_sprite(comp))
        push!(queue, render_basic_tile(glmap, vibrating_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM + render_height_offset), pos_offset = pos_offset))
    end

    # Render rotor above static and vibepart
    push!(queue, render_basic_tile(glmap, rotor_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM + 10 + render_height_offset), pos_offset = pos_offset))

    return nothing
end

function render_map_elem!(queue::Vector{<:RenderCommand}, comp::ElectricPumpCompBehav; glmap::GLObjectMap, mna_state::MNA_StateSnapshot, derivedmapstate::DerivedMapState, gameticks::Int64, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    # Get fluid at pump input node
    pump_input_node = map_element(HexFrame.NODE_Q_NEG, position, rotation)
    fluid = get(derivedmapstate.nodeactualfluids, pump_input_node, nothing)

    # Determine if pump is on
    pump_current = get(mna_state.vsource_currents, ElementID(position, pump_element_index), 0.0)
    non_trivial_current = abs(pump_current) > 0.02
    pump_is_on = get_current_energy(comp.energy) > 0.0 && non_trivial_current

    # Calculate switch percentage and interpolate charge bar colour
    switch_percentage = get_switch_percentage(comp.switch)
    switch_color = get(ColorSchemes.summer, switch_percentage)
    charge_bar_colour = ColourType(switch_color.r, switch_color.g, switch_color.b, 1.0)

    # Always render non-animated elements
    render_static!(queue, comp; glmap = glmap, rotation = rotation, position = position, fluid = fluid, gameticks = gameticks, charge_bar_colour = charge_bar_colour, pos_offset = pos_offset, render_height_offset = render_height_offset)

    # Set animation tweak values if pump is on
    if pump_is_on
        vibe_offset_vec = SVector{2, Float32}(animation_vibe_offset(gameticks)...)
        vibe_anim_args = (; sprite_offset_tweak_px = vibe_offset_vec)
        rotation_mat = animation_rotate(gameticks, 720.0)
        rotor_anim_args = (; sprite_rotation_tweak_mat = rotation_mat)
    else
        vibe_anim_args = (;)
        rotor_anim_args = (;)
    end

    # Render animated parts
    vibe_draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM + render_height_offset)
    rotor_draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM + 10 + render_height_offset)
    if !isnothing(vibrating_sprite(comp))
        push!(queue, render_basic_tile(glmap, vibrating_sprite(comp), rotation, position; draw_height = vibe_draw_height, pos_offset = pos_offset, vibe_anim_args...))
    end
    push!(queue, render_basic_tile(glmap, rotor_sprite(comp), rotation, position; draw_height = rotor_draw_height, pos_offset = pos_offset, rotor_anim_args...))

    return nothing
end

end # module HexFlowPumpComponents
