"""
Pump component implementations for fluid pressurization.

This module provides concrete implementations of ComponentBehavior for pumps:
- TurboPumpCompBehav: Gas-driven turbopump for rocket engines
- ElectricPumpCompBehav: Battery-powered pump with energy management

All components follow the ComponentBehavior interface defined in HexComponentsAPI.
"""
module HexFlowPumpComponents

using Accessors
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
const turbopump_turbine_element_index::Int = 3 # Turbopump turbine dependent current source element index

"Produces a single voltage source element for the pump, active only when powered."
function produce_rel_elements(p::PumpBehavFrag, is_pump_powered::Bool)::NTuple{1, RelativeElement}
    voltage = is_pump_powered ? p.pump_voltage : 0.0 # Pump produces no pressure when not powered

    rel1 = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.NODE_Q_POS),
        voltage, HexElements.CONST_VOLTAGE
    )

    return (rel1,)
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

# ===============================================================
# Concrete Component Behaviors
# ===============================================================

#= ---------- TurboPumpCompBehav ----------- =#

"Rocket engine turbopump component behavior, powered by gas flowing through the turbine."
struct TurboPumpCompBehav <: ComponentBehavior
    pump::PumpBehavFrag
    series_conductance::Float64
    turbine_gain::Float64
    stall_state::StallBehavFrag
    turbine_active_state::BinaryStateBehavFrag
end

"Practical keyword based constructor for TurboPumpCompBehav"
function TurboPumpCompBehav(; pump_voltage::Float64, series_conductance::Float64, turbine_gain::Float64)
    pumpfrag = PumpBehavFrag(pump_voltage)
    return TurboPumpCompBehav(pumpfrag, series_conductance, turbine_gain, StallBehavFrag(), BinaryStateBehavFrag(true))
end

"Produces pump voltage source, series resistor, and turbine-dependent current source."
function produce_rel_elements(comp::TurboPumpCompBehav)::NTuple{3, RelativeElement}
    # Pump elements are produced by the pump fragment. The pump is powered when the turbine is active.
    is_pump_powered = getstate(comp.turbine_active_state)
    pump_rels = produce_rel_elements(comp.pump, is_pump_powered)

    # Series resistor connecting internal to Q_NEG
    rel2 = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.NODE_Q_NEG),
        comp.series_conductance, HexElements.CONST_RESISTOR
    )

    # Turbine dependent current source (deactivated if stalled or pruned)
    is_active::Bool = !is_stalled(comp.stall_state)
    rel3 = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_S_POS, HexFrame.GROUND),
        comp.turbine_gain, HexElements.C_DEP_CURRENT; dependent_index = 1, active = is_active
    )

    return (pump_rels[1], rel2, rel3)
end

function get_tunables(comp::TurboPumpCompBehav)::NTuple{3, TunableProps}
    pump_tun = get_tunables(comp.pump)
    return (pump_tun[1], TunableProps(comp.series_conductance, "Series conductance (resistor)", "1/Ω"), TunableProps(comp.turbine_gain, "Turbine gain (dependent current coefficient)", "A/A"))
end

function set_tunables(comp::TurboPumpCompBehav, tunables::NTuple{3, T})::TurboPumpCompBehav where {T <: Real}
    vals = Float64.(tunables)
    comp = @set comp.pump = set_tunables(comp.pump, (vals[1],))
    comp = @set comp.series_conductance = vals[2]
    comp = @set comp.turbine_gain = vals[3]
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

"Updates turbine active state and stalls if turbine input pressure is negative."
function update_flowbehav!(comp::TurboPumpCompBehav; mna_state::MNA_State, tile::TileCoord, rotation::HexAxis, kwargs...)
    # Update turbine active state based on whether it was pruned
    turbine_is_active::Bool = haskey(mna_state.csources, ElementID(tile, turbopump_turbine_element_index))
    turbine_is_active ? settrue!(comp.turbine_active_state) : setfalse!(comp.turbine_active_state)

    # Stall if turbine input pressure is negative (current flows backwards)
    turbine_input_node = map_element(HexFrame.NODE_S_NEG, tile, rotation)
    turbine_input_pressure = get(mna_state.node_voltages, turbine_input_node, 0.0)
    if turbine_input_pressure < 0.0
        stall!(comp.stall_state)
    end

    return nothing
end

"Renders static turbopump elements: fluid mask, rotor, and static parts."
function render_base_elem!(queue::Vector{RenderCommand}, comp::TurboPumpCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    fluidmask_colour = DEFAULT_EMPTY_FLUID_COLOUR
    push!(queue, render_basic_tile(glmap, :TurboPump1_fluidmask, rotation, position; scale = scale, colour = fluidmask_colour, transparency = transparency, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))
    push!(queue, render_basic_tile(glmap, :TurboPump1_rotor, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 10 + render_height_offset), pos_offset = pos_offset))
    push!(queue, render_basic_tile(glmap, :TurboPump1_static, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + render_height_offset), pos_offset = pos_offset))
    push!(queue, render_basic_tile(glmap, :TurboPump1_vibepart, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + 10 + render_height_offset), pos_offset = pos_offset))

    return nothing
end

"Renders turbopump with animations when active: spinning rotor, vibration, and smoke effects."
function render_map_elem!(queue::Vector{RenderCommand}, comp::TurboPumpCompBehav; glmap::GLObjectMap, derivedmapstate::DerivedMapState, mna_state::MNA_State, gameticks::Int64, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    # Determine if turbine is on
    turbine_current = get(mna_state.vsource_currents, ElementID(position, pump_element_index), 0.0)
    non_trivial_current = abs(turbine_current) > 0.02
    turbine_is_on = getstate(comp.turbine_active_state) && non_trivial_current

    # Get turbine fluid colour
    turbine_input_node = map_element(HexFrame.NODE_S_POS, position, rotation)
    fluid = get(derivedmapstate.nodeactualfluids, turbine_input_node, HexFluids.NONE)
    colour = get_fluid_colour(fluid)

    smoke_sprites = (:TurboPump1_smoke_1, :TurboPump1_smoke_2, :TurboPump1_smoke_3)
    if turbine_is_on
        # Render fluid mask with turbine fluid colour
        push!(queue, render_basic_tile(glmap, :TurboPump1_fluidmask, rotation, position; colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + render_height_offset), pos_offset = pos_offset))
        # Render spinning rotor
        rotation_mat = animation_rotate(gameticks, 720.0)
        push!(queue, render_basic_tile(glmap, :TurboPump1_rotor, rotation, position; sprite_rotation_tweak_mat = rotation_mat, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100 + render_height_offset), pos_offset = pos_offset))
        # Render static background
        push!(queue, render_basic_tile(glmap, :TurboPump1_static, rotation, position; draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + render_height_offset), pos_offset = pos_offset))

        # Render vibrating part with offset
        vibe_offset = animation_vibe_offset(gameticks)
        vibe_offset_vec = SVector{2, Float32}(Float32(vibe_offset[1]), Float32(vibe_offset[2]))
        push!(queue, render_basic_tile(glmap, :TurboPump1_vibepart, rotation, position; sprite_offset_tweak_px = vibe_offset_vec, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM + render_height_offset), pos_offset = pos_offset))

        # Render animated smoke effect with fluid colour
        smoke_sprite = animation_sprite_picker(smoke_sprites, gameticks, 4)
        push!(queue, render_basic_tile(glmap, smoke_sprite, rotation, position; colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_ANIM) + Int32(10) + Int32(render_height_offset), pos_offset = pos_offset))
    else
        # Render static base when turbine is off
        render_base_elem!(queue, comp; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, render_height_offset = render_height_offset)
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
        change_rate::Float64
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
        change_rate = change_rate,
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
            tooltip = action.enabled ? "Activate pump to begin pressurising fluid" : "Pump is already on"
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
        queue::Vector{RenderCommand}, comp::ElectricPumpCompBehav;
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
function render_base_elem!(queue::Vector{RenderCommand}, comp::ElectricPumpCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
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
function render_map_elem!(queue::Vector{RenderCommand}, comp::ElectricPumpCompBehav; glmap::GLObjectMap, mna_state::MNA_State, derivedmapstate::DerivedMapState, gameticks::Int64, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
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
