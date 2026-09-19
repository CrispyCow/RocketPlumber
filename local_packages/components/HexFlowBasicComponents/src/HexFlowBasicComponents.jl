#=
Scope: Shared basic component behaviour fragments and simple component compositions
Formatter: Runic
=#
"""
Basic component behaviour fragments and compositions.

This module provides fundamental building blocks for component behaviours and
the basic component composition.

Exported concrete `ComponentBehavior` implementations:

- `BasicCompBehav`: Basic circuit-element component with a predefined sprite
"""
module HexFlowBasicComponents

using Accessors
using HexElements, HexFluids, HexFrame
using HexComponentsAPI
using HexFlowRendering, RenderEngine

# `ComponentBehavior` mandatory methods
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# `ComponentBehavior` optional methods
import HexComponentsAPI: render_map_elem!, map_rotation, get_actions, do_action!, get_component_temperature

# Behaviour Fragment Exports
export HorizontalFlipOnlyBehavFrag, NoRotationBehavFrag
export PlainSpriteBehavFrag, BasicElemBehavFrag
export BinaryStateBehavFrag, FloatStateBehavFrag
export getstate, settrue!, setfalse!, setstate!
export StallBehavFrag, stall!, unstall!, is_stalled
export AutoDeactivationBehavFrag, deactivate!, reactivate!, is_inactive
export DamageStateBehavFrag, damage!, undamage!, is_damaged
export ComponentTemperatureBehavFrag, get_component_temperature, set_component_temperature!
export OverheatLimitBehavFrag, get_overheat_limit_temperature, get_overheat_percentage, get_overheat_tint, update_overheat_state!
# Helper Function Exports
export multiply_colours
# Concrete Component Behaviour Exports
export BasicCompBehav

# ===============================================================
# Behaviour Fragments
# ===============================================================

#= ---------- HorizontalFlipOnlyBehavFrag ----------- =#

"Simple fragment that restricts rotation to horizontal (Q_POS or Q_NEG) only"
struct HorizontalFlipOnlyBehavFrag end

function map_rotation(::HorizontalFlipOnlyBehavFrag, rotation::HexAxis)::HexAxis
    if rotation in (HexFrame.Q_POS, HexFrame.S_POS, HexFrame.R_POS)
        return HexFrame.Q_POS
    else
        return HexFrame.Q_NEG
    end
end

#= ---------- NoRotationBehavFrag ----------- =#

"Fragment that locks rotation to Q_POS regardless of input"
struct NoRotationBehavFrag end

map_rotation(::NoRotationBehavFrag, rotation::HexAxis)::HexAxis = HexFrame.Q_POS

#= ---------- PlainSpriteBehavFrag ----------- =#

"Simple sprite fragment for a component with one preselected sprite from the universal spritesheet"
struct PlainSpriteBehavFrag
    sprite::Symbol
end

function render_base_elem!(queue::Vector{<:RenderCommand}, behav::PlainSpriteBehavFrag; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    base_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, behav.sprite, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = base_height, pos_offset = pos_offset))
    return nothing
end

#= ---------- BasicElemBehavFrag ----------- =#

"""
A basic behaviour fragment with no behaviour beyond that of its circuit
elements.
Stores relative elements directly with no additional state.
Can have a varying number of elements.
"""
struct BasicElemBehavFrag{N}
    elements::NTuple{N, RelativeElement}
end

function BasicElemBehavFrag(elms::Vararg{RelativeElement, N}) where {N}
    return BasicElemBehavFrag{N}(elms) # `elms` is already an `NTuple{N, RelativeElement}`
end

function produce_rel_elements(comp::BasicElemBehavFrag{N})::NTuple{N, RelativeElement} where {N}
    return ntuple(i -> comp.elements[i], N)
end

function get_tunables(elem::T)::TunableProps where {T <: Element}
    return TunableProps(
        get_value(elem),
        get_typestring(elem),
        get_unitstring(elem)
    )
end

function get_tunables(comp::BasicElemBehavFrag{N})::NTuple{N, TunableProps} where {N}
    return ntuple(i -> get_tunables(comp.elements[i]), N)
end

function set_tunables(comp::BasicElemBehavFrag{N}, tunables::NTuple{N, T})::BasicElemBehavFrag{N} where {N, T <: Real}
    new_elements = ntuple(
        i -> begin
            element = comp.elements[i]
            @set element.value = Float64(tunables[i])
        end, N
    )
    return @set comp.elements = new_elements
end

#= ---------- BinaryStateBehavFrag ----------- =#

"Mutable fragment for a single boolean state. Interact with `getstate`, `settrue!`, and `setfalse!`."
mutable struct BinaryStateBehavFrag
    state::Bool
end

getstate(frag::BinaryStateBehavFrag)::Bool = frag.state
settrue!(frag::BinaryStateBehavFrag) = (frag.state = true)
setfalse!(frag::BinaryStateBehavFrag) = (frag.state = false)

#= ---------- FloatStateBehavFrag ----------- =#

"Mutable fragment for a single floating-point state. Interact with `getstate` and `setstate!`."
mutable struct FloatStateBehavFrag
    state::Float64
end

getstate(frag::FloatStateBehavFrag)::Float64 = frag.state
setstate!(frag::FloatStateBehavFrag, new_state::Float64) = (frag.state = new_state)

#= ---------- StallBehavFrag ----------- =#

"Mutable fragment tracking whether a component is stalled. Interact with `stall!`, `unstall!`, and `is_stalled`."
mutable struct StallBehavFrag
    stall_state::BinaryStateBehavFrag
end

StallBehavFrag() = StallBehavFrag(BinaryStateBehavFrag(false)) # Default constructor: not stalled

stall!(frag::StallBehavFrag) = settrue!(frag.stall_state)
unstall!(frag::StallBehavFrag) = setfalse!(frag.stall_state)
is_stalled(frag::StallBehavFrag)::Bool = getstate(frag.stall_state)

function render_map_elem!(queue::Vector{<:RenderCommand}, behav::StallBehavFrag; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    if is_stalled(behav)
        overlay_height = Int32(HexFlowRendering.RENDER_HEIGHT_OVERLAY_BASE) + Int32(render_height_offset)
        push!(queue, render_basic_tile(glmap, :test_stalled, HexFrame.Q_POS, position; draw_height = overlay_height, pos_offset = pos_offset))
    end
    return nothing
end

function get_actions(stall::StallBehavFrag; kwargs...)
    stalled = is_stalled(stall)
    tooltip = stalled ? "Try to reactivate stalled component" : "Component is not currently stalled"
    return (
        ActionInfo(
            id = :unstall,
            label = "Unstall Component",
            enabled = stalled,
            tooltip = tooltip,
        ),
    )
end

function do_action!(stall::StallBehavFrag, action_id::Symbol; kwargs...)
    if action_id === :unstall
        if is_stalled(stall)
            unstall!(stall)
            return ValidRequestResult("Component unstalled")
        else
            return InvalidRequest("Component is not currently stalled")
        end
    end
    throw(ArgumentError("Action :$(action_id) not recognised by StallBehavFrag"))
end

#= ---------- AutoDeactivationBehavFrag ----------- =#

"""Mutable fragment for auto-deactivation state.

Components deactivate automatically on harmful flow conditions and reactivate via the
speculative probe scheduler. Use `deactivate!`, `reactivate!`, and `is_inactive`.
"""
mutable struct AutoDeactivationBehavFrag
    inactive_state::BinaryStateBehavFrag
end

AutoDeactivationBehavFrag() = AutoDeactivationBehavFrag(BinaryStateBehavFrag(false))

deactivate!(frag::AutoDeactivationBehavFrag) = settrue!(frag.inactive_state)
reactivate!(frag::AutoDeactivationBehavFrag) = setfalse!(frag.inactive_state)
is_inactive(frag::AutoDeactivationBehavFrag)::Bool = getstate(frag.inactive_state)

#= ---------- DamageStateBehavFrag ----------- =#

"Mutable fragment for persistent component damage. Interact with `damage!`, `undamage!`, and `is_damaged`."
mutable struct DamageStateBehavFrag
    damage_state::BinaryStateBehavFrag
end

DamageStateBehavFrag() = DamageStateBehavFrag(BinaryStateBehavFrag(false))

damage!(frag::DamageStateBehavFrag) = settrue!(frag.damage_state)
undamage!(frag::DamageStateBehavFrag) = setfalse!(frag.damage_state)
is_damaged(frag::DamageStateBehavFrag)::Bool = getstate(frag.damage_state)

function render_map_elem!(queue::Vector{<:RenderCommand}, behav::DamageStateBehavFrag; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    if is_damaged(behav)
        overlay_height = Int32(HexFlowRendering.RENDER_HEIGHT_OVERLAY_BASE) + Int32(render_height_offset)
        push!(queue, render_basic_tile(glmap, :test_damaged, HexFrame.Q_POS, position; draw_height = overlay_height, pos_offset = pos_offset)) # Temporary damaged overlay sprite.
    end
    return nothing
end

function get_actions(damage::DamageStateBehavFrag; kwargs...)
    damaged = is_damaged(damage)
    tooltip = damaged ? "Temporarily repair this damaged component" : "Component is not currently damaged"
    return (
        ActionInfo(
            id = :repair_component,
            label = "Repair Component",
            enabled = damaged,
            tooltip = tooltip,
        ),
    )
end

function do_action!(damage::DamageStateBehavFrag, action_id::Symbol; kwargs...)
    if action_id === :repair_component
        if is_damaged(damage)
            undamage!(damage) # Temporary direct repair path until dedicated repair gameplay exists.
            return ValidRequestResult("Component repaired")
        else
            return InvalidRequest("Component is not currently damaged")
        end
    end
    throw(ArgumentError("Action :$(action_id) not recognised by DamageStateBehavFrag"))
end

#= ---------- ComponentTemperatureBehavFrag ----------- =#

"Mutable fragment tracking component-local temperature in Kelvin."
mutable struct ComponentTemperatureBehavFrag
    temperature_state::FloatStateBehavFrag
end

ComponentTemperatureBehavFrag() = ComponentTemperatureBehavFrag(FloatStateBehavFrag(300.0))
ComponentTemperatureBehavFrag(temperature_k::Real) = ComponentTemperatureBehavFrag(FloatStateBehavFrag(Float64(temperature_k)))

get_component_temperature(frag::ComponentTemperatureBehavFrag)::Float64 = getstate(frag.temperature_state)
set_component_temperature!(frag::ComponentTemperatureBehavFrag, temperature_k::Real) = setstate!(frag.temperature_state, Float64(temperature_k))

"Multiply a base colour by a tint colour component-wise."
multiply_colours(base::ColourType, tint::ColourType)::ColourType = ColourType((base .* tint)...)

#= ---------- OverheatLimitBehavFrag ----------- =#

const THERMAL_FLUID_COUPLING_SCALE = 1.0
const THERMAL_HEAT_LOSS_SCALE = 1.0

"Reusable overheating fragment with local temperature state, persistent damage, and configurable heat-balance parameters"
struct OverheatLimitBehavFrag
    limit_temperature_k::Float64                  # Damage threshold
    thermal_mass::Float64                         # Heat capacity scale
    heat_loss_factor::Float64                     # Passive cooling strength
    temperature::ComponentTemperatureBehavFrag    # Mutable temperature state
    damage::DamageStateBehavFrag                  # Persistent damage state

    function OverheatLimitBehavFrag(
            limit_temperature_k::Real,
            thermal_mass::Real,
            heat_loss_factor::Real,
            temperature::ComponentTemperatureBehavFrag,
            damage::DamageStateBehavFrag
        )
        limit_temperature_f = max(Float64(limit_temperature_k), THERMAL_AMBIENT_TEMPERATURE_K + 1.0)
        thermal_mass_f = max(Float64(thermal_mass), 1.0e-6)
        heat_loss_factor_f = max(Float64(heat_loss_factor), 0.0)

        return new(limit_temperature_f, thermal_mass_f, heat_loss_factor_f, temperature, damage)
    end
end

function OverheatLimitBehavFrag(
        limit_temperature_k::Real,
        thermal_mass::Real,
        heat_loss_factor::Real;
        temperature::ComponentTemperatureBehavFrag = ComponentTemperatureBehavFrag(),
        damage::DamageStateBehavFrag = DamageStateBehavFrag()
    )
    return OverheatLimitBehavFrag(limit_temperature_k, thermal_mass, heat_loss_factor, temperature, damage)
end

get_overheat_limit_temperature(frag::OverheatLimitBehavFrag)::Float64 = frag.limit_temperature_k
get_component_temperature(frag::OverheatLimitBehavFrag)::Float64 = get_component_temperature(frag.temperature)
set_component_temperature!(frag::OverheatLimitBehavFrag, temperature_k::Real) = set_component_temperature!(frag.temperature, temperature_k)
damage!(frag::OverheatLimitBehavFrag) = damage!(frag.damage)
undamage!(frag::OverheatLimitBehavFrag) = undamage!(frag.damage)
is_damaged(frag::OverheatLimitBehavFrag)::Bool = is_damaged(frag.damage)

function get_tunables(frag::OverheatLimitBehavFrag)::NTuple{3, TunableProps}
    return (
        TunableProps(frag.limit_temperature_k, "Temperature Limit", "K"),
        TunableProps(frag.thermal_mass, "Thermal Mass", "thermal units"),
        TunableProps(frag.heat_loss_factor, "Heat Loss Factor", "1/K-units"),
    )
end

function set_tunables(frag::OverheatLimitBehavFrag, tunables::NTuple{3, T})::OverheatLimitBehavFrag where {T <: Real}
    return OverheatLimitBehavFrag(
        tunables[1],
        tunables[2],
        tunables[3],
        frag.temperature,
        frag.damage
    )
end

"Return the current temperature as a fraction of the ambient-to-limit overheat range."
function get_overheat_percentage(frag::OverheatLimitBehavFrag)::Float64
    current_temperature = get_component_temperature(frag)
    if current_temperature <= THERMAL_AMBIENT_TEMPERATURE_K
        return 0.0
    elseif current_temperature >= frag.limit_temperature_k
        return 1.0
    end

    temperature_span = frag.limit_temperature_k - THERMAL_AMBIENT_TEMPERATURE_K
    return (current_temperature - THERMAL_AMBIENT_TEMPERATURE_K) / temperature_span
end

"Return the display tint for the current overheat percentage."
function get_overheat_tint(frag::OverheatLimitBehavFrag)::ColourType
    overheat_percentage = get_overheat_percentage(frag)
    green_blue = 1.0 - overheat_percentage
    return ColourType(1.0, green_blue, green_blue, 1.0)
end

"Advance component temperature toward the fluid and ambient heat balance, damaging the fragment if it overheats"
function update_overheat_state!(
        frag::OverheatLimitBehavFrag;
        fluid_temperature_k::Real = THERMAL_AMBIENT_TEMPERATURE_K,
        mass_flow_rate::Real = 0.0,
        dt::Real = 1 / BASE_UPS
    )
    current_temperature = get_component_temperature(frag)
    fluid_temperature_f = Float64(fluid_temperature_k)
    mass_flow_rate_f = max(Float64(mass_flow_rate), 0.0)
    dt_f = Float64(dt)

    fluid_heat_flow = THERMAL_FLUID_COUPLING_SCALE * mass_flow_rate_f * (fluid_temperature_f - current_temperature)
    heat_loss_flow = THERMAL_HEAT_LOSS_SCALE * frag.heat_loss_factor * (THERMAL_AMBIENT_TEMPERATURE_K - current_temperature)
    net_heat_flow = fluid_heat_flow + heat_loss_flow
    next_temperature = current_temperature + net_heat_flow * dt_f / frag.thermal_mass

    set_component_temperature!(frag, next_temperature)
    if next_temperature >= frag.limit_temperature_k
        damage!(frag)
    end

    return next_temperature
end

render_map_elem!(queue::Vector{<:RenderCommand}, frag::OverheatLimitBehavFrag; kwargs...) = render_map_elem!(queue, frag.damage; kwargs...)
get_actions(frag::OverheatLimitBehavFrag; kwargs...) = get_actions(frag.damage; kwargs...)
do_action!(frag::OverheatLimitBehavFrag, action_id::Symbol; kwargs...) = do_action!(frag.damage, action_id; kwargs...)

# ===============================================================
# Concrete Component Behaviours
# ===============================================================

#= ---------- BasicCompBehav ----------- =#

"""
The most basic complete component, with basic elements and a predefined sprite.
Composed from a BasicElemBehavFrag and PlainSpriteBehavFrag.
"""
@kwdef struct BasicCompBehav{N} <: ComponentBehavior
    elems::BasicElemBehavFrag{N}
    sprite::PlainSpriteBehavFrag
end

produce_rel_elements(behav::BasicCompBehav{N}) where {N} = produce_rel_elements(behav.elems)
get_tunables(behav::BasicCompBehav{N}) where {N} = get_tunables(behav.elems)

function set_tunables(behav::BasicCompBehav{N}, tunables::NTuple{N, T})::BasicCompBehav{N} where {N, T <: Real}
    return @set behav.elems = set_tunables(behav.elems, tunables)
end

function render_base_elem!(queue::Vector{<:RenderCommand}, behav::BasicCompBehav{N}; kwargs...) where {N}
    return render_base_elem!(queue, behav.sprite; kwargs...) # Delegate to the sprite fragment
end

end # module HexFlowBasicComponents
