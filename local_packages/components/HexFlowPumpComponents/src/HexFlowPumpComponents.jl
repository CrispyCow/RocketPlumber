"""
Pump component implementations for fluid pressurization.

This module provides concrete implementations of ComponentBehavior for pumps:
- TurboPumpCompBehav: Gas-driven turbopump for rocket engines
- ElectricPumpCompBehav: Battery-powered pump with energy management

All components follow the ComponentBehavior interface defined in HexComponentsAPI.
"""
module HexFlowPumpComponents

using ColorSchemes
using StaticArrays
using HexFrame, HexElements, HexFluids, FlowEngine, FlowMap, HexComponentsAPI, RenderEngine, HexFlowRendering
using HexFlowBasicComponents, HexFlowSwitchComponents

# ComponentBehavior Mandatories
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# ComponentBehavior Optional
import HexComponentsAPI: get_fluidtags, on_click!, update_flowbehav!, render_map_elem!, get_actions, do_action!
# Behavior Fragment Dependencies
import HexFlowBasicComponents: stall!, unstall!, is_stalled
import HexFlowSwitchComponents: set_target_conductance_to_min!, set_target_conductance_to_max!

# Behavior Fragment Exports
export PumpBehavFrag
export RotorStateBehavFrag
# Concrete Component Behavior Exports
export TurboPumpCompBehav
export ElectricPumpCompBehav, ElectricTurboPump, ElectricTransferPump

# ===============================================================
# Behavior Fragments
# ===============================================================

#= ---------- PumpBehavFrag ----------- =#

"Encapsulates pump-specific parameters (voltage source only) with the pump's internal voltage."
struct PumpBehavFrag
    pump_voltage::Float64
end

const pump_element_index::Int = 1 # Pump voltage source element index

"Return the pump voltage after applying a clamped 0-1 scale factor."
get_scaled_pump_voltage(p::PumpBehavFrag, voltage_scale::Real)::Float64 = p.pump_voltage * clamp(Float64(voltage_scale), 0.0, 1.0)

"Construct the pump's voltage-source element with an externally supplied scale factor."
function make_pump_element(p::PumpBehavFrag, voltage_scale::Real; active::Bool = true)::RelativeElement
    voltage = active ? get_scaled_pump_voltage(p, voltage_scale) : 0.0
    return RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.NODE_Q_POS),
        voltage,
        HexElements.CONST_VOLTAGE;
        active = active
    )
end

"Produces a single voltage source element for the pump, active only when powered."
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

"Gets current energy level from state."
get_current_energy(frag::EnergyStoreBehavFrag)::Float64 = getstate(frag.stored_energy)

"Gets maximum energy capacity."
get_max_energy(frag::EnergyStoreBehavFrag)::Float64 = frag.max_energy

"Changes energy by delta, clamped between [0, max_energy]."
function update_energy!(frag::EnergyStoreBehavFrag, delta_energy::Float64)
    setstate!(frag.stored_energy, clamp(getstate(frag.stored_energy) + delta_energy, 0.0, get_max_energy(frag)))
    return nothing
end

#= ---------- RotorStateBehavFrag ----------- =#

"Encapsulates rotor RPM state and inertial tuning for pump spin-up and spin-down."
struct RotorStateBehavFrag
    rpm::FloatStateBehavFrag
    max_rpm::Float64
    rotor_inertia::Float64
    friction_coefficient::Float64

    function RotorStateBehavFrag(rpm::FloatStateBehavFrag, max_rpm::Float64, rotor_inertia::Float64, friction_coefficient::Float64)
        # clamp above zero to prevent weird edge cases with negative or zero values
        friction_coefficient = max(friction_coefficient, 1e-6)
        rotor_inertia = max(rotor_inertia, 1e-6)
        max_rpm = max(max_rpm, 1e-6)
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

"Gets current rotor RPM from state."
get_current_rpm(frag::RotorStateBehavFrag)::Float64 = getstate(frag.rpm)

"Gets the current rotor RPM as a 0-1 fraction of max RPM."
get_rpm_fraction(frag::RotorStateBehavFrag)::Float64 = clamp(get_current_rpm(frag) / frag.max_rpm, 0.0, 1.0)

"Changes RPM by delta, clamped at zero"
function update_rpm!(frag::RotorStateBehavFrag, delta_rpm::Float64)
    setstate!(frag.rpm, max(get_current_rpm(frag) + delta_rpm, 0.0))
    return nothing
end

const TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE::Float64 = 1.0e-3
const TURBOPUMP_TURBINE_POWER_SCALING::Float64 = 1.0e-4
const TURBOPUMP_RENDER_MAX_ROTATION_SPEED::Float64 = 900.0
const TURBOPUMP_SMOKE_CURRENT_THRESHOLD::Float64 = 0.02

# ===============================================================
# Concrete Component Behaviors
# ===============================================================

#= ---------- TurboPumpCompBehav ----------- =#

"""
Rocket engine turbopump with variable-conductance turbine.

The turbine conductance drops linearly with RPM: G(RPM) = max_turbine_conductance x max(1 - RPM/max_rpm, 0).
This gives easy cold-start (high gas flow at low RPM) and natural self-limiting (zero gas flow at max RPM).
"""
struct TurboPumpCompBehav <: ComponentBehavior
    max_pump_voltage::Float64         # pump pressure at full RPM
    series_conductance::Float64       # pump-side Thévenin series conductance
    max_turbine_conductance::Float64  # turbine conductance at 0 RPM (drops to 0 at max_rpm)
    cycle_efficiency::Float64         # turbine energy conversion factor (0–1)
    rotor::RotorStateBehavFrag        # RPM state, inertia, friction, max_rpm
    stall_state::StallBehavFrag       # stall detection and unstall action
end

"Practical keyword-based constructor for TurboPumpCompBehav."
function TurboPumpCompBehav(;
        max_pump_voltage::Real,
        series_conductance::Real,
        max_turbine_conductance::Real = 0.3,
        cycle_efficiency::Real = 0.6,
        current_rpm::Real = 0.0,
        max_rpm::Real = 3000.0,
        rotor_inertia::Real = 100.0,
        friction_coefficient::Real = 0.02,
        stall_state::StallBehavFrag = StallBehavFrag()
    )
    rotor = RotorStateBehavFrag(
        current_rpm = current_rpm,
        max_rpm = max_rpm,
        rotor_inertia = rotor_inertia,
        friction_coefficient = friction_coefficient
    )
    return TurboPumpCompBehav(
        Float64(max_pump_voltage),
        max(Float64(series_conductance), 0.0),
        max(Float64(max_turbine_conductance), 0.0),
        max(Float64(cycle_efficiency), 1e-6),
        rotor,
        stall_state
    )
end

"Compute effective turbine conductance at the current RPM."
function effective_turbine_conductance(comp::TurboPumpCompBehav; exponent::Float64 = 0.7)::Float64
    rpm_frac = clamp(get_current_rpm(comp.rotor) / comp.rotor.max_rpm, 0.0, 1.0)
    return comp.max_turbine_conductance * max(1.0 - rpm_frac^exponent, 0.0)
end

"Produces pump voltage source, series resistor, and variable-conductance turbine resistor."
function produce_rel_elements(comp::TurboPumpCompBehav)::NTuple{3, RelativeElement}
    active = !is_stalled(comp.stall_state)
    rpm_fraction = get_rpm_fraction(comp.rotor)
    pump_voltage = active ? comp.max_pump_voltage * rpm_fraction : 0.0

    pump_source = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.NODE_Q_POS),
        pump_voltage,
        HexElements.CONST_VOLTAGE;
        active = active
    )
    series_resistor = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.NODE_Q_NEG),
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

function get_tunables(comp::TurboPumpCompBehav)::NTuple{8, TunableProps}
    return (
        TunableProps(comp.max_pump_voltage, "Max pump voltage", "V"),
        TunableProps(comp.series_conductance, "Series conductance", "1/R"),
        TunableProps(comp.max_turbine_conductance, "Max turbine conductance", "1/R"),
        TunableProps(get_current_rpm(comp.rotor), "Current RPM", "RPM"),
        TunableProps(comp.rotor.max_rpm, "Max RPM", "RPM"),
        TunableProps(comp.rotor.rotor_inertia, "Rotor inertia", ""),
        TunableProps(comp.rotor.friction_coefficient, "Friction coefficient", "power/RPM"),
        TunableProps(comp.cycle_efficiency, "Cycle efficiency", ""),
    )
end

function set_tunables(comp::TurboPumpCompBehav, tunables::NTuple{8, T})::TurboPumpCompBehav where {T <: Real}
    vals = Float64.(tunables)
    newrotor = RotorStateBehavFrag(comp.rotor.rpm, vals[5], vals[6], vals[7])
    comp = TurboPumpCompBehav(
        vals[1],
        max(vals[2], 0.0),
        max(vals[3], 0.0),
        max(vals[8], 1e-6),
        newrotor,
        comp.stall_state
    )
    setstate!(comp.rotor.rpm, clamp(vals[4], 0.0, comp.rotor.max_rpm))
    return comp
end

function get_fluidtags(::TurboPumpCompBehav)
    return NodeFluidTags(
        NODE_Q_POS = HexFluids.ANY_LIQUID,
        NODE_Q_NEG = HexFluids.ANY_LIQUID,
        NODE_S_POS = HexFluids.ANY_GAS
    )
end

"Clicking the pump un-stalls it."
function on_click!(comp::TurboPumpCompBehav; kwargs...)
    do_action!(comp.stall_state, :unstall)
    return nothing
end

get_actions(comp::TurboPumpCompBehav; kwargs...) = get_actions(comp.stall_state; kwargs...)
do_action!(comp::TurboPumpCompBehav, action_id::Symbol; kwargs...) = do_action!(comp.stall_state, action_id; kwargs...)

"Updates rotor RPM from the previous tick's MNA solution and stalls on pump reversal."
function update_flowbehav!(comp::TurboPumpCompBehav; mna_state::MNA_State, tile::TileCoord, rotation::HexAxis, derivedmapstate::DerivedMapState, kwargs...)
    applied_inertia = comp.rotor.rotor_inertia * TURBOPUMP_ROTOR_INERTIA_APPLICATION_SCALE
    friction_power = comp.rotor.friction_coefficient * (get_current_rpm(comp.rotor) + 200.0) # adds 'static' friction to help rpm get to zero

    # Normal flow is negative, positive means backdrive and should cause a stall
    source_current = get(mna_state.vsource_currents, ElementID(tile, pump_element_index), 0.0)
    if source_current > 0.0
        stall!(comp.stall_state)
    end

    # When stalled, only friction acts (no turbine, no pump load)
    if is_stalled(comp.stall_state)
        delta_rpm = -friction_power / (applied_inertia * BASE_UPS)
        update_rpm!(comp.rotor, delta_rpm)
        return nothing
    end

    # Read turbine flow
    s_pos_node = map_element(HexFrame.NODE_S_POS, tile, rotation)
    s_pos_voltage = get(mna_state.node_voltages, s_pos_node, 0.0)
    turbine_g = effective_turbine_conductance(comp)
    turbine_current = max(s_pos_voltage * turbine_g, 0.0)
    # Look up the fluid at the turbine's input node
    fluid = get(derivedmapstate.nodeactualfluids, s_pos_node, HexFluids.NONE)
    density = something(lookup_fluid_density(fluid), 0.0)
    exhaust_velocity = something(lookup_fluid_exhaust_velocity(fluid), 0.0)
    # compute turbine power
    turbine_power = density * turbine_current * exhaust_velocity^2 * TURBOPUMP_TURBINE_POWER_SCALING

    # Pump load — voltage × current for the pump voltage source
    pump_current = max(-Float64(source_current), 0.0)
    rpm_fraction = get_rpm_fraction(comp.rotor)
    pump_voltage = comp.max_pump_voltage * rpm_fraction
    pump_power = pump_voltage * pump_current

    # RPM integration
    energy_in = comp.cycle_efficiency * turbine_power
    delta_rpm = (energy_in - pump_power - friction_power) / (applied_inertia * BASE_UPS)
    update_rpm!(comp.rotor, delta_rpm)

    return nothing
end

"Renders static turbopump elements: fluid mask, rotor, and static parts."
function render_base_elem!(queue::Vector{<:RenderCommand}, comp::TurboPumpCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    fluidmask_colour = DEFAULT_EMPTY_FLUID_COLOUR

    # Fluid mask.
    push!(queue, render_basic_tile(glmap, :TurboPump1_fluidmask, rotation, position; scale = scale, colour = fluidmask_colour, transparency = transparency, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))
    # Rotor.
    push!(queue, render_basic_tile(glmap, :TurboPump1_rotor, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 10 + render_height_offset), pos_offset = pos_offset))
    # Static housing.
    push!(queue, render_basic_tile(glmap, :TurboPump1_static, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + render_height_offset), pos_offset = pos_offset))
    # Vibrating pipework.
    push!(queue, render_basic_tile(glmap, :TurboPump1_vibepart, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + 10 + render_height_offset), pos_offset = pos_offset))

    return nothing
end

"Renders turbopump with animations when active: spinning rotor, vibration, and smoke effects."
function render_map_elem!(queue::Vector{<:RenderCommand}, comp::TurboPumpCompBehav; glmap::GLObjectMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot, gameticks::Int64, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    # Get turbine fluid colour
    turbine_input_node = map_element(HexFrame.NODE_S_POS, position, rotation)
    fluid = get(derivedmapstate.nodeactualfluids, turbine_input_node, HexFluids.NONE)
    fluidmask_colour = if fluid == HexFluids.NONE
        DEFAULT_EMPTY_FLUID_COLOUR
    else
        get_fluid_colour(fluid)
    end

    # get turbine state from MNA solution
    source_current = get(mna_state.vsource_currents, ElementID(position, pump_element_index), 0.0)
    pump_flow = max(-Float64(source_current), 0.0)
    s_pos_voltage = get(mna_state.node_voltages, turbine_input_node, 0.0)
    turbine_g = effective_turbine_conductance(comp)
    turbine_current = max(s_pos_voltage * turbine_g, 0.0)
    rpm_fraction = get_rpm_fraction(comp.rotor)
    max_pump_flow = max(comp.max_pump_voltage * comp.series_conductance, 1.0e-6)
    pump_flow_fraction = clamp(pump_flow / max_pump_flow, 0.0, 1.0)

    smoke_sprites = (:TurboPump1_smoke_1, :TurboPump1_smoke_2, :TurboPump1_smoke_3)

    # Fluid mask.
    push!(queue, render_basic_tile(glmap, :TurboPump1_fluidmask, rotation, position; colour = fluidmask_colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))

    # Rotor.
    if rpm_fraction > 0.0
        rotor_rotation = animation_rotate(gameticks, TURBOPUMP_RENDER_MAX_ROTATION_SPEED * rpm_fraction)
        push!(queue, render_basic_tile(glmap, :TurboPump1_rotor, rotation, position; draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100 + render_height_offset), pos_offset = pos_offset, sprite_rotation_tweak_mat = rotor_rotation))
    else
        push!(queue, render_basic_tile(glmap, :TurboPump1_rotor, rotation, position; draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100 + render_height_offset), pos_offset = pos_offset))
    end

    # Static housing.
    push!(queue, render_basic_tile(glmap, :TurboPump1_static, rotation, position; draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + render_height_offset), pos_offset = pos_offset))

    # Vibrating pipework.
    if pump_flow_fraction > 0.0
        vibe_offset = animation_vibe_offset(gameticks; magnitude = 2.0 * pump_flow_fraction)
        vibe_offset_vec = SVector{2, Float32}(Float32.(vibe_offset)...)
        push!(queue, render_basic_tile(glmap, :TurboPump1_vibepart, rotation, position; draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM + render_height_offset), pos_offset = pos_offset, sprite_offset_tweak_px = vibe_offset_vec))
    else
        push!(queue, render_basic_tile(glmap, :TurboPump1_vibepart, rotation, position; draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM + render_height_offset), pos_offset = pos_offset))
    end

    # Turbine exhaust smoke.
    if turbine_current > TURBOPUMP_SMOKE_CURRENT_THRESHOLD
        smoke_sprite = animation_sprite_picker(smoke_sprites, gameticks, 4)
        push!(queue, render_basic_tile(glmap, smoke_sprite, rotation, position; colour = fluidmask_colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM) + Int32(10) + Int32(render_height_offset), pos_offset = pos_offset))
    end

    # Render stall overlay
    render_map_elem!(queue, comp.stall_state; glmap = glmap, rotation = rotation, position = position, render_height_offset = render_height_offset)

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
"Practical keyword-based constructor for ElectricPumpCompBehav."
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
    switch_connection = RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.NODE_Q_NEG)
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

"Produces pump voltage source and switch resistor elements."
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

function get_fluidtags(::ElectricPumpCompBehav)
    return NodeFluidTags(
        NODE_Q_POS = HexFluids.ANY_LIQUID,
        NODE_Q_NEG = HexFluids.ANY_LIQUID,
    )
end

"Updates switch behavior and consumes energy proportional to pump flow rate."
function update_flowbehav!(comp::ElectricPumpCompBehav; mna_state::MNA_State, tile::TileCoord, kwargs...)
    # Delegate to switch for its behavior update
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

"Clicking the pump toggles the switch, while there is energy."
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
            label = "Turn Pump On"
            tooltip = action.enabled ? "Activate pump to begin pumping fluid" : "Pump is already on"
            return ActionInfo(:pump_on, label, action.enabled, tooltip)
        elseif action.id === :close_valve
            label = "Turn Pump Off"
            tooltip = action.enabled ? "Deactivate pump" : "Pump is already off"
            return ActionInfo(:pump_off, label, action.enabled, tooltip)
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
    return (false, "Action :$(action_id) not recognised by ElectricPumpCompBehav")
end

# Rendering traits for different electric pump types
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

"Renders static elements of an electric pump: charge bar, fluid mask, and background."
function render_static!(
        queue::Vector{<:RenderCommand}, comp::ElectricPumpCompBehav;
        glmap::GLObjectMap, rotation::HexAxis, position::TileCoord,
        fluid::FluidTags = HexFluids.NONE, gameticks::Int64 = 0,
        charge_bar_colour::ColourType = let c = get(ColorSchemes.summer, 0.0)
            ColourType(c.r, c.g, c.b, 1.0)
        end,
        pos_offset = nothing,
        scale::Float64 = 1.0, transparency::Float64 = 1.0,
        colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0),
        render_height_offset::Integer = 0
    )
    # Render charge bar
    energy_frac = get_current_energy(comp.energy) / get_max_energy(comp.energy)
    push!(queue, render_basic_tile(glmap, chargemask_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = charge_bar_colour, x_unclipped = energy_frac, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))

    # Render fluid mask if it exists
    if !isnothing(fluidmask_sprite(comp))
        fluidmask_colour = get_fluid_colour(fluid)
        if fluid == HexFluids.NONE
            push!(queue, render_basic_tile(glmap, fluidmask_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = fluidmask_colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))
        elseif is_liquid(fluid)
            push!(queue, render_liquid_tile(glmap, fluidmask_sprite(comp), rotation, position, gameticks; colour = fluidmask_colour, scale = scale, transparency = transparency, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))
        end
    end

    # Render static background
    push!(queue, render_basic_tile(glmap, static_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + render_height_offset), pos_offset = pos_offset))

    return nothing
end

"Renders static electric pump elements without animation."
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

"Renders electric pump with animations when running: vibration and rotating rotor."
function render_map_elem!(queue::Vector{<:RenderCommand}, comp::ElectricPumpCompBehav; glmap::GLObjectMap, mna_state::MNA_StateSnapshot, derivedmapstate::DerivedMapState, gameticks::Int64, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    # Get fluid at pump input node
    pump_input_node = map_element(HexFrame.NODE_Q_NEG, position, rotation)
    fluid = get(derivedmapstate.nodeactualfluids, pump_input_node, HexFluids.NONE)

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
