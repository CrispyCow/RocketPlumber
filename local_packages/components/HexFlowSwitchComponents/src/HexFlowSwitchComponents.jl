#=
Scope: Switch and valve component behaviours for flow control
Formatter: Runic
=#

"""
Switch and valve component behaviours for flow control.

Exported concrete `ComponentBehavior` implementations:

- `StandardValveCompBehav`: Valve parameterised by switch behaviour with a physical size value
"""
module HexFlowSwitchComponents

using Accessors: @set
using StaticArrays
using FlowEngine, FlowMap, HexElements, HexFluids, HexFrame
using HexComponentsAPI, HexFlowBasicComponents
using HexFlowRendering, RenderEngine

# `ComponentBehavior` mandatory methods
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# `ComponentBehavior` optional methods
import HexComponentsAPI: update_flowbehav, on_click, render_map_elem!, get_actions, do_action

# Behaviour Fragment Exports
export AbstractSwitchBehavFrag, BoolSwitchBehavFrag, SteppedSwitchBehavFrag, SwitchBehavFrag
# Helper Function Exports
export calculate_growth_factor, get_switch_percentage, get_target_percentage
export set_target_conductance_to_max, set_target_conductance_to_min, step_conductance_down, step_conductance_up
# Support Type Exports
export ValveSize, TINY_VALVE, LARGE_VALVE
# Concrete Component Behaviour Exports
export StandardValveCompBehav

# ===============================================================
# Behaviour Fragments
# ===============================================================

#= ---------- SwitchBehavFrag ----------- =#

# Minimum practical conductance for exponential growth starting from zero
const MIN_PRACTICAL_CONDUCTANCE = 0.005 # was 0.00025, but made larger to reduce fine valve control

"Immutable state for switch conductance tracking"
struct SwitchState
    target_conductance::Float64
    current_conductance::Float64
end

"Behaviour fragment for shared switch functionality. Missing sprite behaviour and behaviour to set target_conductance."
struct SwitchBehavFrag
    connection::RelativeElementConnections
    max_conductance::Float64
    min_conductance::Float64
    growth_factor::Float64  # Precomputed exponential growth base (k) — must be ≥ 1.0001
    state::SwitchState
end

"Calculate exponential growth_factor (k) from linear change_rate."
function calculate_growth_factor(max_conductance::Float64, min_conductance::Float64, change_rate::Float64)::Float64
    conductance_range = max_conductance - min_conductance
    if conductance_range ≈ 0.0
        return 1.0  # No change possible
    end

    time_linear = conductance_range / change_rate  # Ticks for linear transition
    base = (min_conductance > 0.0) ? min_conductance : MIN_PRACTICAL_CONDUCTANCE
    # k = (max/base)^(1/time_linear)
    growth_factor = (max_conductance / base)^(1.0 / time_linear)

    # Clamp growth_factor to prevent numerical instability
    if growth_factor < 1.0001
        error(
            "change_rate ($change_rate) is too small, resulting in unstable growth_factor. " *
                "Increase change_rate or decrease conductance range."
        )
    end

    return growth_factor
end

"Keyword constructor for switch fragment. Includes bounds checking."
function SwitchBehavFrag(;
        connection::RelativeElementConnections,
        max_conductance::Float64,
        min_conductance::Float64,
        growth_factor::Float64,
        target_conductance::Float64 = min_conductance,
        current_conductance::Float64 = min_conductance
    )
    if !(min_conductance <= current_conductance <= max_conductance)
        throw(
            ArgumentError(
                "current_conductance ($current_conductance) must be between " *
                    "min_conductance ($min_conductance) and max_conductance ($max_conductance)"
            )
        )
    end
    if !(min_conductance <= target_conductance <= max_conductance)
        throw(
            ArgumentError(
                "target_conductance ($target_conductance) must be between " *
                    "min_conductance ($min_conductance) and max_conductance ($max_conductance)"
            )
        )
    end

    growth_factor = max(growth_factor, 1.0001) # Enforce minimum growth factor to prevent instability

    return SwitchBehavFrag(
        connection,
        max_conductance,
        min_conductance,
        growth_factor,
        SwitchState(target_conductance, current_conductance)
    )
end

function produce_rel_elements(switch::SwitchBehavFrag)::NTuple{1, RelativeElement}
    conductance = switch.state.current_conductance
    connection = switch.connection

    rel_elem = RelativeElement(connection, conductance, HexElements.CONST_RESISTOR)
    return (rel_elem,)
end

function get_tunables(switch::SwitchBehavFrag)::NTuple{3, TunableProps}
    max_conductance_props = TunableProps(
        switch.max_conductance,
        "Max Conductance (Fully ON)",
        get_unitstring(HexElements.CONST_RESISTOR)
    )

    min_conductance_props = TunableProps(
        switch.min_conductance,
        "Min Conductance (Fully OFF)",
        get_unitstring(HexElements.CONST_RESISTOR)
    )

    growth_factor_props = TunableProps(
        switch.growth_factor,
        "Growth Factor",
        "Exp base per tick"
    )

    return (max_conductance_props, min_conductance_props, growth_factor_props)
end

"Change configuration, clamping target and current conductance to the new operating bounds."
function set_tunables(switch::SwitchBehavFrag, tunables::NTuple{3, T})::SwitchBehavFrag where {T <: Real}
    float_vals = Float64.(tunables)
    max_conductance = float_vals[1]
    min_conductance = float_vals[2]
    target_conductance = clamp(switch.state.target_conductance, min_conductance, max_conductance)
    current_conductance = clamp(switch.state.current_conductance, min_conductance, max_conductance)

    newswitch = SwitchBehavFrag(
        connection = switch.connection,
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        growth_factor = float_vals[3],
        target_conductance = target_conductance,
        current_conductance = current_conductance
    )
    return newswitch
end

function update_flowbehav(switch::SwitchBehavFrag; kwargs...)
    target = switch.state.target_conductance
    current = switch.state.current_conductance
    min_c = switch.min_conductance
    max_c = switch.max_conductance
    k = switch.growth_factor

    # Handle edge cases
    if max_c ≈ min_c || target ≈ current
        return @set switch.state.current_conductance = target
    end

    increasing = target > current # Determine direction

    if increasing
        # Moving toward higher conductance
        if current ≈ min_c && min_c ≈ 0.0
            new_current = MIN_PRACTICAL_CONDUCTANCE # Jump from zero to a stable minimum value
        else
            new_current = current * k # Exponential growth
        end

        if new_current > target # Don't overshoot target
            new_current = target
        end
    else
        # Moving toward lower conductance - exponential decay
        new_current = current / k

        if new_current < target # Don't undershoot target
            new_current = target
        end

        if new_current < min_c + MIN_PRACTICAL_CONDUCTANCE * 0.1 # Snap to min once we're close to the minimum
            new_current = min_c
        end
    end

    return @set switch.state.current_conductance = clamp(new_current, min_c, max_c)
end

"Set switch target conductance while enforcing min and max bounds."
function set_target_conductance(switch::SwitchBehavFrag, target::T) where {T <: Real}
    float_target = Float64(target)
    max_conductance = switch.max_conductance
    min_conductance = switch.min_conductance

    if float_target > max_conductance
        error("Can't set switch target conductance over its maximum")
    end
    if float_target < min_conductance
        error("Can't set switch target conductance below its minimum")
    end

    return @set switch.state.target_conductance = float_target
end

#= ---------- Exponential Percentage Helpers ----------- =#

"Convert conductance to percentage in exponential space (0.0 = min, 1.0 = max)."
function conductance_to_exp_percentage(conductance::Float64, min_c::Float64, max_c::Float64, growth_factor::Float64)::Float64
    if max_c ≈ min_c
        return 0.0
    end
    if conductance <= min_c
        return 0.0
    end
    if conductance >= max_c
        return 1.0
    end

    k = growth_factor
    base = (min_c > 0.0) ? min_c : MIN_PRACTICAL_CONDUCTANCE

    total_ticks = log(k, max_c / base) # Total ticks needed to go from base to max
    current_ticks = log(k, conductance / base) # Ticks to reach current conductance from base

    percentage = current_ticks / total_ticks # Ratio of current position to total range
    return clamp(percentage, 0.0, 1.0)
end

"Convert percentage to conductance in exponential space."
function exp_percentage_to_conductance(percentage::Float64, min_c::Float64, max_c::Float64, growth_factor::Float64)::Float64
    if max_c ≈ min_c
        return min_c
    end

    percentage = clamp(percentage, 0.0, 1.0)

    if percentage ≈ 0.0
        return min_c
    end
    if percentage ≈ 1.0
        return max_c
    end

    k = growth_factor
    base = (min_c > 0.0) ? min_c : MIN_PRACTICAL_CONDUCTANCE

    total_ticks = log(k, max_c / base) # Total ticks needed to go from base to max
    target_ticks = percentage * total_ticks # Target ticks for this percentage

    conductance = base * k^target_ticks # Conductance at this tick count
    return clamp(conductance, min_c, max_c)
end

"Return the switch percentage in exponential space (0.0 = fully off, 1.0 = fully on)."
function get_switch_percentage(switch::SwitchBehavFrag)::Float64
    return conductance_to_exp_percentage(
        switch.state.current_conductance,
        switch.min_conductance,
        switch.max_conductance,
        switch.growth_factor
    )
end

"Return the target switch percentage in exponential space (0.0 = fully off, 1.0 = fully on)."
function get_target_percentage(switch::SwitchBehavFrag)::Float64
    return conductance_to_exp_percentage(
        switch.state.target_conductance,
        switch.min_conductance,
        switch.max_conductance,
        switch.growth_factor
    )
end

#= ---------- AbstractSwitchBehavFrag ----------- =#

"Abstract parent for switch fragments with shared conductance behaviour."
abstract type AbstractSwitchBehavFrag end

#= ---------- BoolSwitchBehavFrag ----------- =#

"""
Switch fragment with binary behaviour (ON/OFF) that can be clicked to toggle state.
Contains switch logic but no rendering -- purely behavioural.
"""
struct BoolSwitchBehavFrag <: AbstractSwitchBehavFrag
    switch::SwitchBehavFrag
end

"Keyword constructor for BoolSwitchBehavFrag."
function BoolSwitchBehavFrag(;
        connection::RelativeElementConnections,
        max_conductance::Float64,
        min_conductance::Float64,
        growth_factor::Float64,
        target_conductance::Float64 = min_conductance,
        current_conductance::Float64 = min_conductance
    )
    switchfrag = SwitchBehavFrag(
        connection = connection,
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        growth_factor = growth_factor,
        target_conductance = target_conductance,
        current_conductance = current_conductance
    )
    return BoolSwitchBehavFrag(switchfrag)
end

# Delegation methods for BoolSwitchBehavFrag
produce_rel_elements(behav::BoolSwitchBehavFrag) = produce_rel_elements(behav.switch)
get_tunables(behav::BoolSwitchBehavFrag) = get_tunables(behav.switch)
set_tunables(behav::BoolSwitchBehavFrag, tunables::NTuple{3, Real}) = BoolSwitchBehavFrag(set_tunables(behav.switch, tunables))
update_flowbehav(behav::BoolSwitchBehavFrag; kwargs...) = @set behav.switch = update_flowbehav(behav.switch; kwargs...)
get_switch_percentage(behav::BoolSwitchBehavFrag) = get_switch_percentage(behav.switch)
get_target_percentage(behav::BoolSwitchBehavFrag) = get_target_percentage(behav.switch)

function on_click(behav::BoolSwitchBehavFrag; kwargs...)
    target = behav.switch.state.target_conductance
    max_c = behav.switch.max_conductance
    min_c = behav.switch.min_conductance

    if target ≈ max_c
        updated, _ = do_action(behav, :close_valve)
    elseif target ≈ min_c
        updated, _ = do_action(behav, :open_valve)
    else
        error("Bool switch reached invalid target")
    end
    return updated
end

function get_actions(behav::BoolSwitchBehavFrag; kwargs...)
    target = behav.switch.state.target_conductance
    max_c = behav.switch.max_conductance
    min_c = behav.switch.min_conductance

    is_open = target ≈ max_c
    is_closed = target ≈ min_c

    open_tooltip = is_open ? "Valve is already open" : "Open valve to allow flow"
    close_tooltip = is_closed ? "Valve is already closed" : "Close valve to block flow"

    open_action = ActionInfo(
        id = :open_valve,
        label = "Open Valve",
        enabled = !is_open,
        tooltip = open_tooltip,
    )
    close_action = ActionInfo(
        id = :close_valve,
        label = "Close Valve",
        enabled = !is_closed,
        tooltip = close_tooltip,
    )

    return (open_action, close_action)
end

function do_action(behav::BoolSwitchBehavFrag, action_id::Symbol; kwargs...)
    if action_id === :open_valve
        return set_target_conductance_to_max(behav), ValidRequestResult("Valve opened")
    elseif action_id === :close_valve
        return set_target_conductance_to_min(behav), ValidRequestResult("Valve closed")
    end
    throw(ArgumentError("Action :$(action_id) not recognised by BoolSwitchBehavFrag"))
end

"Sets the switch target conductance to its minimum value (OFF state)."
function set_target_conductance_to_min(behav::BoolSwitchBehavFrag)
    return @set behav.switch = set_target_conductance(behav.switch, behav.switch.min_conductance)
end

"Sets the switch target conductance to its maximum value (ON state)."
function set_target_conductance_to_max(behav::BoolSwitchBehavFrag)
    return @set behav.switch = set_target_conductance(behav.switch, behav.switch.max_conductance)
end

#= ---------- SteppedSwitchBehavFrag ----------- =#

"""
Switch fragment with stepped behaviour that can be clicked to adjust conductance in discrete steps.
Steps are in logarithmic/exponential space to match the switching behaviour.
Contains switch logic but no rendering -- purely behavioural.
"""
struct SteppedSwitchBehavFrag <: AbstractSwitchBehavFrag
    switch::SwitchBehavFrag
    percentage_step_size::Float64  # Step size in logarithmic percentage space (0.0 to 1.0)
end

"Keyword constructor for SteppedSwitchBehavFrag."
function SteppedSwitchBehavFrag(;
        connection::RelativeElementConnections,
        max_conductance::Float64,
        min_conductance::Float64,
        growth_factor::Float64,
        percentage_step_size::Float64,
        target_conductance::Float64 = min_conductance,
        current_conductance::Float64 = min_conductance
    )
    switchfrag = SwitchBehavFrag(
        connection = connection,
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        growth_factor = growth_factor,
        target_conductance = target_conductance,
        current_conductance = current_conductance
    )
    return SteppedSwitchBehavFrag(switchfrag, percentage_step_size)
end

# Delegation methods for SteppedSwitchBehavFrag
produce_rel_elements(behav::SteppedSwitchBehavFrag) = produce_rel_elements(behav.switch)
update_flowbehav(behav::SteppedSwitchBehavFrag; kwargs...) = @set behav.switch = update_flowbehav(behav.switch; kwargs...)
get_switch_percentage(behav::SteppedSwitchBehavFrag) = get_switch_percentage(behav.switch)
get_target_percentage(behav::SteppedSwitchBehavFrag) = get_target_percentage(behav.switch)

function get_tunables(behav::SteppedSwitchBehavFrag)::NTuple{4, TunableProps}
    switch_tunables = get_tunables(behav.switch)
    step_size_props = TunableProps(
        behav.percentage_step_size,
        "Percentage Step Size",
        "Log-space percentage per step (0.0-1.0)"
    )
    return (switch_tunables..., step_size_props)
end

function set_tunables(behav::SteppedSwitchBehavFrag, tunables::NTuple{4, Real})
    switch_tunables = (tunables[1], tunables[2], tunables[3])
    new_switch = set_tunables(behav.switch, switch_tunables)
    new_step_size = Float64(tunables[4])
    return SteppedSwitchBehavFrag(new_switch, new_step_size)
end

"Increase the target conductance by one step size in exponential space, clamped to max."
function step_conductance_up(behav::SteppedSwitchBehavFrag)
    sw = behav.switch
    current_target_percentage = get_target_percentage(sw) # Get current target percentage in exponential space

    new_target_percentage = min(current_target_percentage + behav.percentage_step_size, 1.0) # Step up in exponential space

    # Convert back to conductance and set
    new_target_conductance = exp_percentage_to_conductance(new_target_percentage, sw.min_conductance, sw.max_conductance, sw.growth_factor)
    return @set behav.switch = set_target_conductance(sw, new_target_conductance)
end

"Decrease the target conductance by one step size in exponential space, clamped to min."
function step_conductance_down(behav::SteppedSwitchBehavFrag)
    sw = behav.switch
    current_target_percentage = get_target_percentage(sw) # Get current target percentage in exponential space

    new_target_percentage = max(current_target_percentage - behav.percentage_step_size, 0.0) # Step down in exponential space

    # Convert back to conductance and set
    new_target_conductance = exp_percentage_to_conductance(
        new_target_percentage,
        sw.min_conductance,
        sw.max_conductance,
        sw.growth_factor
    )
    return @set behav.switch = set_target_conductance(sw, new_target_conductance)
end

function get_actions(behav::SteppedSwitchBehavFrag; kwargs...)
    target = behav.switch.state.target_conductance
    max_c = behav.switch.max_conductance
    min_c = behav.switch.min_conductance

    at_max = target ≈ max_c
    at_min = target ≈ min_c

    open_tooltip = at_max ? "Valve is already fully open" : "Step valve further open"
    close_tooltip = at_min ? "Valve is already fully closed" : "Step valve further closed"

    open_action = ActionInfo(
        id = :step_valve_open,
        label = "Step Valve Open",
        enabled = !at_max,
        tooltip = open_tooltip,
    )
    close_action = ActionInfo(
        id = :step_valve_close,
        label = "Step Valve Close",
        enabled = !at_min,
        tooltip = close_tooltip,
    )

    return (open_action, close_action)
end

function do_action(behav::SteppedSwitchBehavFrag, action_id::Symbol; kwargs...)
    if action_id === :step_valve_open
        return step_conductance_up(behav), ValidRequestResult("Valve stepped open")
    elseif action_id === :step_valve_close
        return step_conductance_down(behav), ValidRequestResult("Valve stepped closed")
    end
    throw(ArgumentError("Action :$(action_id) not recognised by SteppedSwitchBehavFrag"))
end

# ===============================================================
# Concrete Component Behaviours
# ===============================================================

#= ---------- StandardValveCompBehav{S} ----------- =#

"Physical valve size, selecting sprites and travel distance."
@enum ValveSize::UInt8 begin
    TINY_VALVE
    LARGE_VALVE
end

"Valve with stepped or boolean switching behaviour and a physical size value."
struct StandardValveCompBehav{S <: AbstractSwitchBehavFrag} <: ComponentBehavior
    switch::S
    size::ValveSize
end

"Construct a StandardValveCompBehav with adjustable (stepped) switching."
function StandardValveCompBehav(
        ::Type{SteppedSwitchBehavFrag}, size::ValveSize;
        max_conductance::Float64, min_conductance::Float64 = 0.0, growth_factor::Float64,
        percentage_step_size::Float64 = 0.05, target_conductance::Float64 = min_conductance,
        current_conductance::Float64 = min_conductance
    )
    switchfrag = SteppedSwitchBehavFrag(
        connection = RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG),
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        growth_factor = growth_factor,
        percentage_step_size = percentage_step_size,
        target_conductance = target_conductance,
        current_conductance = current_conductance
    )
    return StandardValveCompBehav(switchfrag, size)
end

"Construct a StandardValveCompBehav with on/off (boolean) switching."
function StandardValveCompBehav(
        ::Type{BoolSwitchBehavFrag}, size::ValveSize;
        max_conductance::Float64, min_conductance::Float64 = 0.0, growth_factor::Float64,
        target_conductance::Float64 = min_conductance,
        current_conductance::Float64 = min_conductance
    )
    switchfrag = BoolSwitchBehavFrag(
        connection = RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG),
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        growth_factor = growth_factor,
        target_conductance = target_conductance,
        current_conductance = current_conductance
    )
    return StandardValveCompBehav(switchfrag, size)
end

#= ---------- Sprite Trait Functions ----------- =#

# Size-dependent sprites (shared between adjustable and on/off)
function fluidmask_sprite(comp::StandardValveCompBehav)
    if comp.size === LARGE_VALVE
        return :Valves_Large_fluidmask
    elseif comp.size === TINY_VALVE
        return :Valves_Tiny_fluidmask
    end
    throw(ArgumentError("Unhandled valve size: $(comp.size)"))
end

function valvebody_sprite(comp::StandardValveCompBehav)
    if comp.size === LARGE_VALVE
        return :Valves_Large_valvebody
    elseif comp.size === TINY_VALVE
        return :Valves_Tiny_valvebody
    end
    throw(ArgumentError("Unhandled valve size: $(comp.size)"))
end

function static_sprite(comp::StandardValveCompBehav)
    if comp.size === LARGE_VALVE
        return :Valves_Large_static
    elseif comp.size === TINY_VALVE
        return :Valves_Tiny_static
    end
    throw(ArgumentError("Unhandled valve size: $(comp.size)"))
end

function valve_travel_px(comp::StandardValveCompBehav)
    if comp.size === LARGE_VALVE
        return 100.0f0
    elseif comp.size === TINY_VALVE
        return 25.0f0
    end
    throw(ArgumentError("Unhandled valve size: $(comp.size)"))
end

# Switch-type-dispatched control box sprite
controlbox_sprite(::StandardValveCompBehav{SteppedSwitchBehavFrag}) = :Valves_Adjustable_controlbox
controlbox_sprite(::StandardValveCompBehav{BoolSwitchBehavFrag}) = :Valves_OnOff_controlbox

#= ---------- Interface Delegation ----------- =#

produce_rel_elements(comp::StandardValveCompBehav) = produce_rel_elements(comp.switch)
update_flowbehav(comp::StandardValveCompBehav; kwargs...) = @set comp.switch = update_flowbehav(comp.switch; kwargs...)

get_tunables(comp::StandardValveCompBehav) = get_tunables(comp.switch)

function set_tunables(comp::StandardValveCompBehav{SteppedSwitchBehavFrag}, tunables::NTuple{4, Real})
    return @set comp.switch = set_tunables(comp.switch, tunables)
end

function set_tunables(comp::StandardValveCompBehav{BoolSwitchBehavFrag}, tunables::NTuple{3, Real})
    return @set comp.switch = set_tunables(comp.switch, tunables)
end

get_actions(comp::StandardValveCompBehav; kwargs...) = get_actions(comp.switch; kwargs...)
function do_action(comp::StandardValveCompBehav, action_id::Symbol; kwargs...)
    updated_switch, result = do_action(comp.switch, action_id; kwargs...)
    return (@set comp.switch = updated_switch), result
end

#= ---------- on_click ----------- =#

function on_click(comp::StandardValveCompBehav{SteppedSwitchBehavFrag}; relative_clicksite = nothing, kwargs...)
    isnothing(relative_clicksite) && return comp

    eps = 1.0e-6
    y = relative_clicksite.y
    if y > eps          # Click above horizontal -- step open
        updated, _ = do_action(comp, :step_valve_open)
        return updated
    elseif y < -eps     # Click below horizontal -- step close
        updated, _ = do_action(comp, :step_valve_close)
        return updated
    end
    return comp
end

function on_click(comp::StandardValveCompBehav{BoolSwitchBehavFrag}; relative_clicksite = nothing, kwargs...)
    isnothing(relative_clicksite) && return comp

    eps = 1.0e-6
    y = relative_clicksite.y
    if y > eps          # Click above horizontal -- open
        updated, _ = do_action(comp, :open_valve)
        return updated
    elseif y < -eps     # Click below horizontal -- close
        updated, _ = do_action(comp, :close_valve)
        return updated
    end
    return comp
end

#= ---------- Rendering ----------- =#

function render_base_elem!(queue::Vector{<:RenderCommand}, comp::StandardValveCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    # Fluid mask (behind layer)
    fluidmask_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, fluidmask_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = fluidmask_height, pos_offset = pos_offset))

    # Valve body
    valve_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, valvebody_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = valve_height, pos_offset = pos_offset))

    # Static housing
    static_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, static_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = static_height, pos_offset = pos_offset))

    # Control box -- dispatched by switch type
    controlbox_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + 50) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, controlbox_sprite(comp), rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = controlbox_height, pos_offset = pos_offset))

    # Act point line indicator
    indicator_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + 100) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :Valves_actpointline, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = indicator_height, pos_offset = pos_offset))

    # Set point arrow indicator
    push!(queue, render_basic_tile(glmap, :Valves_setpointarrow, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = indicator_height, pos_offset = pos_offset))

    return nothing
end

function render_map_elem!(queue::Vector{<:RenderCommand}, comp::StandardValveCompBehav; glmap::GLObjectMap, derivedmapstate::DerivedMapState, gameticks::Int64, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    node_q_pos = map_element(HexFrame.NODE_Q_POS, position, rotation)
    fluid = get(derivedmapstate.nodeactualfluids, node_q_pos, nothing)
    temperature = get(derivedmapstate.node_temperatures, node_q_pos, HexFluids.THERMAL_AMBIENT_TEMPERATURE_K)
    colour = get_fluid_colour(fluid, temperature)

    # Fluid mask -- fluid-type dependent rendering
    fluidmask_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)
    if HexFluids.is_liquid(fluid)
        push!(queue, render_liquid_tile(glmap, fluidmask_sprite(comp), rotation, position, gameticks; colour = colour, draw_height = fluidmask_height, pos_offset = pos_offset))
    elseif HexFluids.is_gas(fluid)
        push!(queue, render_gas_tile(glmap, fluidmask_sprite(comp), rotation, position, gameticks; colour = colour, draw_height = fluidmask_height, pos_offset = pos_offset))
    else
        push!(queue, render_basic_tile(glmap, fluidmask_sprite(comp), rotation, position; colour = colour, draw_height = fluidmask_height, pos_offset = pos_offset))
    end

    # Valve body -- shifted vertically by current valve position
    switch_percentage = get_switch_percentage(comp.switch)
    valve_y_offset = Float32(valve_travel_px(comp)) * Float32(switch_percentage)
    valve_offset = SVector{2, Float32}(0.0f0, valve_y_offset)
    valve_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, valvebody_sprite(comp), rotation, position; sprite_offset_tweak_px = valve_offset, draw_height = valve_height, pos_offset = pos_offset))

    # Static housing
    static_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, static_sprite(comp), rotation, position; draw_height = static_height, pos_offset = pos_offset))

    # Control box - dispatched by switch type
    controlbox_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + 50) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, controlbox_sprite(comp), rotation, position; draw_height = controlbox_height, pos_offset = pos_offset))

    # Act point line - shifted vertically by actual valve position
    actpoint_y_offset = Float32(130.0 * switch_percentage)
    actpoint_offset = SVector{2, Float32}(0.0f0, actpoint_y_offset)
    indicator_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + 100) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :Valves_actpointline, rotation, position; sprite_offset_tweak_px = actpoint_offset, draw_height = indicator_height, pos_offset = pos_offset))

    # Set point arrow - shifted vertically by target set point
    target_percentage = get_target_percentage(comp.switch)
    arrow_y_offset = Float32(130.0 * target_percentage)
    arrow_offset = SVector{2, Float32}(0.0f0, arrow_y_offset)
    push!(queue, render_basic_tile(glmap, :Valves_setpointarrow, rotation, position; sprite_offset_tweak_px = arrow_offset, draw_height = indicator_height, pos_offset = pos_offset))

    return nothing
end

include("precompile_workload.jl")

end # module HexFlowSwitchComponents
