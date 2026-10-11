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
import HexComponentsAPI: render_map_elem!, map_rotation, get_actions, do_action, get_component_temperature

# Behaviour Fragment Exports
export HorizontalFlipOnlyBehavFrag, NoRotationBehavFrag
export BasicElemBehavFrag
export StallStateBehavFrag, DamageStateBehavFrag, OverheatLimitBehavFrag
# Helper Function Exports
export stall, unstall, is_stalled, damage, undamage, is_damaged
export deactivate, reactivate, is_inactive
export get_component_temperature, set_component_temperature
export get_overheat_limit_temperature, get_overheat_percentage, get_overheat_tint, update_overheat_state
export multiply_colours
# Support Type Exports
export AutoDeactivationState, ComponentTemperatureState
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

#= ---------- StallStateBehavFrag ----------- =#

"Immutable fragment tracking whether a component is stalled. Interact with `stall`, `unstall`, and `is_stalled`."
struct StallStateBehavFrag
    stalled::Bool
end

StallStateBehavFrag() = StallStateBehavFrag(false) # Default constructor: not stalled

stall(frag::StallStateBehavFrag) = @set frag.stalled = true
unstall(frag::StallStateBehavFrag) = @set frag.stalled = false
is_stalled(frag::StallStateBehavFrag)::Bool = frag.stalled

function render_map_elem!(queue::Vector{<:RenderCommand}, behav::StallStateBehavFrag; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    if is_stalled(behav)
        overlay_height = Int32(HexFlowRendering.RENDER_HEIGHT_OVERLAY_BASE) + Int32(render_height_offset)
        push!(queue, render_basic_tile(glmap, :test_stalled, HexFrame.Q_POS, position; draw_height = overlay_height, pos_offset = pos_offset))
    end
    return nothing
end

function get_actions(stall::StallStateBehavFrag; kwargs...)
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

function do_action(stall::StallStateBehavFrag, action_id::Symbol; kwargs...)
    if action_id !== :unstall
        throw(ArgumentError("Action :$(action_id) not recognised by StallStateBehavFrag"))
    end
    if !is_stalled(stall)
        return stall, InvalidRequest("Component is not currently stalled")
    end

    return unstall(stall), ValidRequestResult("Component unstalled")
end

#= ---------- AutoDeactivationState ----------- =#

"""Immutable runtime auto-deactivation state.

Components deactivate automatically on harmful flow conditions and reactivate via the
speculative probe scheduler. Use `deactivate`, `reactivate`, and `is_inactive`.
"""
struct AutoDeactivationState
    inactive::Bool
end

AutoDeactivationState() = AutoDeactivationState(false)

deactivate(state::AutoDeactivationState) = @set state.inactive = true
reactivate(state::AutoDeactivationState) = @set state.inactive = false
is_inactive(state::AutoDeactivationState)::Bool = state.inactive

#= ---------- DamageStateBehavFrag ----------- =#

"Immutable fragment for persistent component damage. Interact with `damage`, `undamage`, and `is_damaged`."
struct DamageStateBehavFrag
    damaged::Bool
end

DamageStateBehavFrag() = DamageStateBehavFrag(false)

damage(frag::DamageStateBehavFrag) = @set frag.damaged = true
undamage(frag::DamageStateBehavFrag) = @set frag.damaged = false
is_damaged(frag::DamageStateBehavFrag)::Bool = frag.damaged

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

function do_action(damage::DamageStateBehavFrag, action_id::Symbol; kwargs...)
    if action_id !== :repair_component
        throw(ArgumentError("Action :$(action_id) not recognised by DamageStateBehavFrag"))
    end
    if !is_damaged(damage)
        return damage, InvalidRequest("Component is not currently damaged")
    end

    return undamage(damage), ValidRequestResult("Component repaired")
end

#= ---------- ComponentTemperatureState ----------- =#

"Immutable runtime component-local temperature in Kelvin."
struct ComponentTemperatureState
    temperature_k::Float64
end

ComponentTemperatureState() = ComponentTemperatureState(300.0)

get_component_temperature(state::ComponentTemperatureState)::Float64 = state.temperature_k
set_component_temperature(state::ComponentTemperatureState, temperature_k::Real) = @set state.temperature_k = Float64(temperature_k)

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
    temperature::ComponentTemperatureState        # Component temperature state
    damage::DamageStateBehavFrag                  # Persistent damage state

    function OverheatLimitBehavFrag(
            limit_temperature_k::Real,
            thermal_mass::Real,
            heat_loss_factor::Real,
            temperature::ComponentTemperatureState,
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
        temperature::ComponentTemperatureState = ComponentTemperatureState(),
        damage::DamageStateBehavFrag = DamageStateBehavFrag()
    )
    return OverheatLimitBehavFrag(limit_temperature_k, thermal_mass, heat_loss_factor, temperature, damage)
end

get_overheat_limit_temperature(frag::OverheatLimitBehavFrag)::Float64 = frag.limit_temperature_k
get_component_temperature(frag::OverheatLimitBehavFrag)::Float64 = get_component_temperature(frag.temperature)
set_component_temperature(frag::OverheatLimitBehavFrag, temperature_k::Real) = @set frag.temperature = set_component_temperature(frag.temperature, temperature_k)
damage(frag::OverheatLimitBehavFrag) = @set frag.damage = damage(frag.damage)
undamage(frag::OverheatLimitBehavFrag) = @set frag.damage = undamage(frag.damage)
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
function update_overheat_state(
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

    frag = set_component_temperature(frag, next_temperature)
    if next_temperature >= frag.limit_temperature_k
        frag = damage(frag)
    end

    return frag
end

render_map_elem!(queue::Vector{<:RenderCommand}, frag::OverheatLimitBehavFrag; kwargs...) = render_map_elem!(queue, frag.damage; kwargs...)
get_actions(frag::OverheatLimitBehavFrag; kwargs...) = get_actions(frag.damage; kwargs...)
function do_action(frag::OverheatLimitBehavFrag, action_id::Symbol; kwargs...)
    updated, result = do_action(frag.damage, action_id; kwargs...)
    return (@set frag.damage = updated), result
end

# ===============================================================
# Concrete Component Behaviours
# ===============================================================

#= ---------- BasicCompBehav ----------- =#

"""
The most basic complete component, with basic elements and a predefined sprite.
Sprite identity is a type parameter; only the circuit elements occupy instance storage.
"""
struct BasicCompBehav{N, SPRITE} <: ComponentBehavior
    elems::BasicElemBehavFrag{N}
end

"Construct a generic component with a descriptive sprite symbol stored in its type."
BasicCompBehav(elems::BasicElemBehavFrag{N}, sprite::Symbol) where {N} = BasicCompBehav{N, sprite}(elems)
BasicCompBehav(; elems::BasicElemBehavFrag, sprite::Symbol) = BasicCompBehav(elems, sprite)

"Recover the generic component's descriptive sprite symbol."
function basic_sprite(::BasicCompBehav{N, SPRITE})::Symbol where {N, SPRITE}
    return SPRITE
end

produce_rel_elements(behav::BasicCompBehav{N}) where {N} = produce_rel_elements(behav.elems)
get_tunables(behav::BasicCompBehav{N}) where {N} = get_tunables(behav.elems)

function set_tunables(behav::BasicCompBehav{N}, tunables::NTuple{N, T})::BasicCompBehav{N} where {N, T <: Real}
    return typeof(behav)(set_tunables(behav.elems, tunables))
end

function render_base_elem!(queue::Vector{<:RenderCommand}, behav::BasicCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    base_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, basic_sprite(behav), rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = base_height, pos_offset = pos_offset))
    return nothing
end

include("precompile_workload.jl")

end # module HexFlowBasicComponents
