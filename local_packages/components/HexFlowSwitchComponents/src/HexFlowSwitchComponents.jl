"""
Switch and valve component implementations for flow control.

This module provides concrete implementations of ComponentBehavior for switches and valves:
- BoolSwitchCompBehav: Binary ON/OFF switch
- BigAdjustableValveCompBehav: Stepped adjustable valve with visual feedback

All components follow the ComponentBehavior interface defined in HexComponentsAPI.
"""
module HexFlowSwitchComponents

using Accessors
using HexFrame, HexElements, HexFluids, HexComponentsAPI, FlowEngine, RenderEngine, HexFlowRendering
using StaticArrays
using HexFlowBasicComponents

# ComponentBehavior Mandatories
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# ComponentBehavior Optional
import HexComponentsAPI: get_fluidtags, update_flowbehav!, on_click!, render_map_elem!

# Behavior Fragment Exports
export SwitchBehavFrag, get_switch_percentage, get_target_percentage
export BoolSwitchBehavFrag, set_target_conductance_to_min!, set_target_conductance_to_max!
export SteppedSwitchBehavFrag, step_conductance_up!, step_conductance_down!
# Concrete Component Behavior Exports
export BoolSwitchCompBehav
export BigAdjustableValveCompBehav

# ===============================================================
# Behavior Fragments
# ===============================================================

#= ---------- SwitchBehavFrag ----------- =#

# Minimum practical conductance for exponential growth starting from zero
const MIN_PRACTICAL_CONDUCTANCE = 0.005 # was 0.00025, but made larger to reduce fine valve control

# TODO: Next time making breaking changes to component structs, cache jump_value and growth_factor
# as fields in SwitchBehavFrag to avoid recomputing growth_factor on every update. Could even replace change_rate with growth_factor directly.
# For now, prioritizing backward compatibility with saved maps.

"Mutable state for switch conductance tracking"
mutable struct SwitchState
    target_conductance::Float64
    current_conductance::Float64
end

"Behavior fragment for shared switch functionality. Missing sprite behavior and behavior to set target_conductance."
struct SwitchBehavFrag
    connection::RelativeElementConnections
    max_conductance::Float64
    min_conductance::Float64
    change_rate::Float64 # Change rate in linear conductance per tick (used to calculate growth_factor)
    state::SwitchState
end

# Temporary alias for backward compatibility with old JLD2 files
const SwitchBehaviorFrag = SwitchBehavFrag

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
        change_rate::Float64,
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

    # Validate that growth_factor will be stable (calculates it to check)
    calculate_growth_factor(max_conductance, min_conductance, change_rate)

    return SwitchBehavFrag(
        connection,
        max_conductance,
        min_conductance,
        change_rate,
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

    change_rate_props = TunableProps(
        switch.change_rate,
        "Switch Change Rate",
        "Conductance per Tick (1/R)/tick"
    )

    return (max_conductance_props, min_conductance_props, change_rate_props)
end

function set_tunables(switch::SwitchBehavFrag, tunables::NTuple{3, T})::SwitchBehavFrag where {T <: Real}
    float_vals = Float64.(tunables)

    # Reconstruct with new tunables (growth_factor will be recalculated when needed)
    newswitch = SwitchBehavFrag(
        connection = switch.connection,
        max_conductance = float_vals[1],
        min_conductance = float_vals[2],
        change_rate = float_vals[3],
        target_conductance = switch.state.target_conductance,
        current_conductance = switch.state.current_conductance
    )
    return newswitch
end

function update_flowbehav!(switch::SwitchBehavFrag; kwargs...)
    target = switch.state.target_conductance
    current = switch.state.current_conductance
    min_c = switch.min_conductance
    max_c = switch.max_conductance
    k = calculate_growth_factor(max_c, min_c, switch.change_rate)
    jump = MIN_PRACTICAL_CONDUCTANCE

    # Handle edge cases
    if max_c ≈ min_c || target ≈ current
        switch.state.current_conductance = target
        return
    end

    increasing = target > current # Determine direction

    if increasing
        # Moving toward higher conductance
        if current ≈ min_c && min_c ≈ 0.0
            new_current = jump # Jump from zero to jump_value
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

        if new_current < min_c + jump * 0.1 # Snap to min if we're within a fraction of jump, adds pseudo-hysteresis
            new_current = min_c
        end
    end

    return switch.state.current_conductance = clamp(new_current, min_c, max_c) # Clamp and assign
end

"Set switch target conductance while enforcing min and max bounds."
function set_target_conductance!(switch::SwitchBehavFrag, target::T) where {T <: Real}
    float_target = Float64(target)
    max_conductance = switch.max_conductance
    min_conductance = switch.min_conductance

    if float_target > max_conductance
        error("Can't set switch target conductance over its maximum")
    end
    if float_target < min_conductance
        error("Can't set switch target conductance below its minimum")
    end

    return switch.state.target_conductance = float_target # Bounds checks passed, assign new target
end

# ===============================================================
# Helper Functions for Exponential Space Percentage Mapping
# ===============================================================

"Convert conductance to percentage in exponential space (0.0 = min, 1.0 = max)."
function conductance_to_exp_percentage(conductance::Float64, min_c::Float64, max_c::Float64, change_rate::Float64)::Float64
    if max_c ≈ min_c
        return 0.0
    end
    if conductance <= min_c
        return 0.0
    end
    if conductance >= max_c
        return 1.0
    end

    k = calculate_growth_factor(max_c, min_c, change_rate)
    base = (min_c > 0.0) ? min_c : MIN_PRACTICAL_CONDUCTANCE

    total_ticks = log(k, max_c / base) # Total ticks needed to go from base to max
    current_ticks = log(k, conductance / base) # Ticks to reach current conductance from base

    percentage = current_ticks / total_ticks # Ratio of current position to total range
    return clamp(percentage, 0.0, 1.0)
end

"Convert percentage to conductance in exponential space."
function exp_percentage_to_conductance(percentage::Float64, min_c::Float64, max_c::Float64, change_rate::Float64)::Float64
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

    k = calculate_growth_factor(max_c, min_c, change_rate)
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
        switch.change_rate
    )
end

"Return the target switch percentage in exponential space (0.0 = fully off, 1.0 = fully on)."
function get_target_percentage(switch::SwitchBehavFrag)::Float64
    return conductance_to_exp_percentage(
        switch.state.target_conductance,
        switch.min_conductance,
        switch.max_conductance,
        switch.change_rate
    )
end

"Abstract type for component behaviors that delegate to a SwitchBehavFrag"
abstract type AbstractSwitchBehavior <: ComponentBehavior end
produce_rel_elements(behav::T) where {T <: AbstractSwitchBehavior} = produce_rel_elements(behav.switch)
get_tunables(behav::T) where {T <: AbstractSwitchBehavior} = get_tunables(behav.switch)
set_tunables(behav::T, tunables::NTuple{N, Real}) where {N, T <: AbstractSwitchBehavior} = @set behav.switch = set_tunables(behav.switch, tunables)
update_flowbehav!(behav::T; kwargs...) where {T <: AbstractSwitchBehavior} = update_flowbehav!(behav.switch; kwargs...)

#= ---------- BoolSwitchBehavFrag ----------- =#

"""
Switch fragment with binary behavior (ON/OFF) that can be clicked to toggle state.
Contains switch logic but no rendering - purely behavioral.
"""
struct BoolSwitchBehavFrag
    switch::SwitchBehavFrag
end

"Keyword constructor for BoolSwitchBehavFrag."
function BoolSwitchBehavFrag(;
        connection::RelativeElementConnections,
        max_conductance::Float64,
        min_conductance::Float64,
        change_rate::Float64,
        target_conductance::Float64 = min_conductance,
        current_conductance::Float64 = min_conductance
    )
    switchfrag = SwitchBehavFrag(
        connection = connection,
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        change_rate = change_rate,
        target_conductance = target_conductance,
        current_conductance = current_conductance
    )
    return BoolSwitchBehavFrag(switchfrag)
end

# Delegation methods for BoolSwitchBehavFrag
produce_rel_elements(behav::BoolSwitchBehavFrag) = produce_rel_elements(behav.switch)
get_tunables(behav::BoolSwitchBehavFrag) = get_tunables(behav.switch)
set_tunables(behav::BoolSwitchBehavFrag, tunables::NTuple{3, Real}) = BoolSwitchBehavFrag(set_tunables(behav.switch, tunables))
update_flowbehav!(behav::BoolSwitchBehavFrag; kwargs...) = update_flowbehav!(behav.switch; kwargs...)
get_switch_percentage(behav::BoolSwitchBehavFrag) = get_switch_percentage(behav.switch)


function on_click!(behav::BoolSwitchBehavFrag; kwargs...)
    max_conductance = behav.switch.max_conductance
    min_conductance = behav.switch.min_conductance
    target_conductance = behav.switch.state.target_conductance

    return if target_conductance ≈ max_conductance # Toggle target conductance between on and off
        set_target_conductance_to_min!(behav)
    elseif target_conductance ≈ min_conductance
        set_target_conductance_to_max!(behav)
    else
        error("Bool switch reached invalid target")
    end
end

"Sets the switch target conductance to its minimum value (OFF state)."
function set_target_conductance_to_min!(behav::BoolSwitchBehavFrag)
    return set_target_conductance!(behav.switch, behav.switch.min_conductance)
end

"Sets the switch target conductance to its maximum value (ON state)."
function set_target_conductance_to_max!(behav::BoolSwitchBehavFrag)
    return set_target_conductance!(behav.switch, behav.switch.max_conductance)
end

#= ---------- SteppedSwitchBehavFrag ----------- =#

"""
Switch fragment with stepped behavior that can be clicked to adjust conductance in discrete steps.
Steps are in logarithmic/exponential space to match the switching behavior.
Contains switch logic but no rendering - purely behavioral.
"""
struct SteppedSwitchBehavFrag
    switch::SwitchBehavFrag
    percentage_step_size::Float64  # Step size in logarithmic percentage space (0.0 to 1.0)
end

"Keyword constructor for SteppedSwitchBehavFrag."
function SteppedSwitchBehavFrag(;
        connection::RelativeElementConnections,
        max_conductance::Float64,
        min_conductance::Float64,
        change_rate::Float64,
        percentage_step_size::Float64,
        target_conductance::Float64 = min_conductance,
        current_conductance::Float64 = min_conductance
    )
    switchfrag = SwitchBehavFrag(
        connection = connection,
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        change_rate = change_rate,
        target_conductance = target_conductance,
        current_conductance = current_conductance
    )
    return SteppedSwitchBehavFrag(switchfrag, percentage_step_size)
end

# Delegation methods for SteppedSwitchBehavFrag
produce_rel_elements(behav::SteppedSwitchBehavFrag) = produce_rel_elements(behav.switch)
update_flowbehav!(behav::SteppedSwitchBehavFrag; kwargs...) = update_flowbehav!(behav.switch; kwargs...)
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
function step_conductance_up!(behav::SteppedSwitchBehavFrag)
    sw = behav.switch
    current_target_percentage = get_target_percentage(sw) # Get current target percentage in exponential space

    new_target_percentage = min(current_target_percentage + behav.percentage_step_size, 1.0) # Step up in exponential space

    # Convert back to conductance and set
    new_target_conductance = exp_percentage_to_conductance(new_target_percentage, sw.min_conductance, sw.max_conductance, sw.change_rate)
    return set_target_conductance!(sw, new_target_conductance)
end

"Decrease the target conductance by one step size in exponential space, clamped to min."
function step_conductance_down!(behav::SteppedSwitchBehavFrag)
    sw = behav.switch
    current_target_percentage = get_target_percentage(sw) # Get current target percentage in exponential space

    new_target_percentage = max(current_target_percentage - behav.percentage_step_size, 0.0) # Step down in exponential space

    # Convert back to conductance and set
    new_target_conductance = exp_percentage_to_conductance(
        new_target_percentage,
        sw.min_conductance,
        sw.max_conductance,
        sw.change_rate
    )
    return set_target_conductance!(sw, new_target_conductance)
end

# ===============================================================
# Concrete Component Behaviors
# ===============================================================

#= ---------- BoolSwitchCompBehav ----------- =#

"""
Switch which can be switched between ON and OFF.
Conductance changes at a set rate adding some delay.
A different sprite dispatches based on switch state.
"""
struct BoolSwitchCompBehav <: ComponentBehavior
    switch::BoolSwitchBehavFrag
    on_sprite::Symbol
    off_sprite::Symbol
end

"Keyword constructor for BoolSwitchCompBehav."
function BoolSwitchCompBehav(;
        connection::RelativeElementConnections,
        max_conductance::Float64,
        min_conductance::Float64,
        change_rate::Float64,
        target_conductance::Float64 = min_conductance,
        current_conductance::Float64 = min_conductance,
        on_sprite::Symbol,
        off_sprite::Symbol
    )
    switchfrag = BoolSwitchBehavFrag(
        connection = connection,
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        change_rate = change_rate,
        target_conductance = target_conductance,
        current_conductance = current_conductance
    )

    return BoolSwitchCompBehav(switchfrag, on_sprite, off_sprite)
end

# Delegation methods
produce_rel_elements(comp::BoolSwitchCompBehav) = produce_rel_elements(comp.switch)
get_tunables(comp::BoolSwitchCompBehav) = get_tunables(comp.switch)
set_tunables(comp::BoolSwitchCompBehav, tunables::NTuple{3, Real}) = @set comp.switch = set_tunables(comp.switch, tunables)
update_flowbehav!(comp::BoolSwitchCompBehav; kwargs...) = update_flowbehav!(comp.switch; kwargs...)
on_click!(comp::BoolSwitchCompBehav; kwargs...) = on_click!(comp.switch; kwargs...)

function render_base_elem!(queue::Vector{RenderCommand}, comp::BoolSwitchCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, kwargs...)
    max_conductance = comp.switch.switch.max_conductance
    min_conductance = comp.switch.switch.min_conductance
    current_conductance = comp.switch.switch.state.current_conductance
    midpoint = (min_conductance + max_conductance) / 2
    sprite = current_conductance < midpoint ? comp.off_sprite : comp.on_sprite
    push!(queue, render_basic_tile(glmap, sprite, rotation, position, scale = scale, transparency = transparency, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)))
    return nothing
end

#= ---------- BigAdjustableValveCompBehav ----------- =#

"""
Adjustable valve component that can be clicked at different positions to step conductance up or down.
Visual feedback shows both current valve position and target setpoint arrows.
"""
struct BigAdjustableValveCompBehav <: ComponentBehavior
    switch::SteppedSwitchBehavFrag
end

"Keyword constructor for BigAdjustableValveCompBehav."
function BigAdjustableValveCompBehav(;
        max_conductance::Float64,
        min_conductance::Float64,
        change_rate::Float64,
        percentage_step_size::Float64,
        target_conductance::Float64 = min_conductance,
        current_conductance::Float64 = min_conductance
    )
    switchfrag = SteppedSwitchBehavFrag(
        connection = RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG),
        max_conductance = max_conductance,
        min_conductance = min_conductance,
        change_rate = change_rate,
        percentage_step_size = percentage_step_size,
        target_conductance = target_conductance,
        current_conductance = current_conductance
    )
    return BigAdjustableValveCompBehav(switchfrag)
end

# Delegation methods
produce_rel_elements(comp::BigAdjustableValveCompBehav) = produce_rel_elements(comp.switch)
get_tunables(comp::BigAdjustableValveCompBehav) = get_tunables(comp.switch)
set_tunables(comp::BigAdjustableValveCompBehav, tunables::NTuple{4, Real}) = @set comp.switch = set_tunables(comp.switch, tunables)
update_flowbehav!(comp::BigAdjustableValveCompBehav; kwargs...) = update_flowbehav!(comp.switch; kwargs...)

function get_fluidtags(::BigAdjustableValveCompBehav)
    # Valve is liquid only - prevents placement in turbine arm of turbopump where zero conductance would cause singularity
    return NodeFluidTags(
        NODE_Q_POS = HexFluids.ANY_LIQUID,
        NODE_Q_NEG = HexFluids.ANY_LIQUID
    )
end

function on_click!(comp::BigAdjustableValveCompBehav; relative_clicksite = nothing, kwargs...)
    return if relative_clicksite !== nothing
        eps = 1.0e-6 # Small deadzone to avoid toggle due to tiny floating point jitter
        y = relative_clicksite.y
        if y > eps # Click above horizontal - step up
            step_conductance_up!(comp.switch)
        elseif y < -eps # Click below horizontal - step down
            step_conductance_down!(comp.switch)
        end
        # If exactly on horizontal (y ≈ 0), do nothing
    end
end

function render_base_elem!(queue::Vector{RenderCommand}, comp::BigAdjustableValveCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, kwargs...)
    valve_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :BigAdjustableValve_valvebody, rotation, position, scale = scale, transparency = transparency, draw_height = valve_height))

    static_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :BigAdjustableValve_static, rotation, position, scale = scale, transparency = transparency, draw_height = static_height))

    return nothing
end

function render_map_elem!(queue::Vector{RenderCommand}, comp::BigAdjustableValveCompBehav; glmap::GLObjectMap, derivedmapstate::DerivedMapState, gameticks::Int64, rotation::HexAxis, position::TileCoord, render_height_offset::Integer = 0, kwargs...)
    node_q_pos = map_element(HexFrame.NODE_Q_POS, position, rotation)
    fluid = get(derivedmapstate.nodeactualfluids, node_q_pos, HexFluids.NONE)
    colour = get_fluid_colour(fluid)

    fluidmask_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)

    if HexFluids.is_liquid(fluid)
        push!(queue, render_liquid_tile(glmap, :BigAdjustableValve_fluidmask, rotation, position, gameticks, colour = colour, draw_height = fluidmask_height))
    elseif HexFluids.is_gas(fluid)
        push!(queue, render_gas_tile(glmap, :BigAdjustableValve_fluidmask, rotation, position, gameticks, colour = colour, draw_height = fluidmask_height))
    else
        push!(queue, render_basic_tile(glmap, :BigAdjustableValve_fluidmask, rotation, position, colour = colour, draw_height = fluidmask_height))
    end

    switch_percentage = get_switch_percentage(comp.switch)
    valve_y_offset = 100.0 * switch_percentage
    valve_offset = SVector{2, Float32}(0.0, valve_y_offset)
    valve_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC - 100) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :BigAdjustableValve_valvebody, rotation, position, sprite_offset_tweak_px = valve_offset, draw_height = valve_height))

    static_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :BigAdjustableValve_static, rotation, position, draw_height = static_height))

    target_percentage = get_target_percentage(comp.switch)
    arrow_y_offset = 100.0 * target_percentage
    arrow_offset = SVector{2, Float32}(0.0, arrow_y_offset)
    arrow_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + 100) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :BigAdjustableValve_setpointarrows, rotation, position, sprite_offset_tweak_px = arrow_offset, draw_height = arrow_height))

    return nothing
end

end # module HexFlowSwitchComponents
