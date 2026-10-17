#=
Scope: Gas, liquid, and pressure-fed tank component behaviours and storage fragments
Formatter: Runic
=#
"""
Tank component behaviours for gas, liquid, and pressure-fed fluid storage.

Exported concrete `ComponentBehavior` implementations:

- `ThevininTankCompBehav`: Gas or liquid tank with a series resistor
- `PressureFedTankCompBehav`: Coupled liquid and pressurising-gas tank
"""
module HexFlowTankComponents

using Accessors, StaticArrays
using FlowEngine, FlowMap, HexElements, HexFluids, HexFrame
using HexComponentsAPI
using HexFlowBasicComponents
using HexFlowRendering, RenderEngine

# `ComponentBehavior` mandatory methods
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# `ComponentBehavior` optional methods
import HexComponentsAPI: update_flowbehav, render_map_elem!, map_rotation, can_be_moved, get_component_wet_mass, get_actions, do_action, produce_rel_fluid_declarations
# Reactivation probe interface
import HexComponentsAPI: get_reactivation_probe, classify_reactivation_probe, commit_reactivation_probe

# Behaviour Fragment Exports
export TankBehavFrag, GasTankBehavFrag, LiquidTankBehavFrag, PressureFedTankBehavFrag
# Helper Function Exports
export seal, unseal, is_sealed, tank_is_active, tank_is_auto_empty, tank_is_auto_full
export force_reactivate, clear_force_reactivate, is_force_reactivated
export force_liquid_reactivate, clear_force_liquid_reactivate, liquid_is_force_reactivated
export force_gas_reactivate, clear_force_gas_reactivate, gas_is_force_reactivated
export get_stored_fluid, set_stored_fluid, clear_stored_fluid
export liquid_is_sealed, gas_is_sealed
export pressurefed_liquid_is_auto_empty, pressurefed_liquid_is_auto_full
export pressurefed_gas_is_auto_empty, pressurefed_gas_is_auto_full_pressure
export pressurefed_liquid_source_active, pressurefed_gas_source_active, pressurefed_liquid_path_active
export pressurefed_probe_current_class
# Support Type Exports
export SealState, TankState, StoredFluidState, FixedFluid
# Concrete Component Behaviour Exports
export ThevininTankCompBehav, PressureFedTankCompBehav

# ===============================================================
# Behaviour Fragments
# ===============================================================

#= ---------- SealState ----------- =#

"Immutable runtime state recording whether a tank is manually sealed."
struct SealState
    sealed::Bool
end

SealState() = SealState(false)

seal(state::SealState) = @set state.sealed = true
unseal(state::SealState) = @set state.sealed = false
is_sealed(state::SealState)::Bool = state.sealed

#= ---------- TankBehavFrag ----------- =#

"Value state for a tank's charge."
struct TankState
    charge::Float64
end

"Convert a real value to `TankState` by wrapping it in `Float64`."
Base.convert(::Type{TankState}, value::Real) = TankState(Float64(value))

"Shared tank state and transitions; concrete tank fragments provide circuit elements."
struct TankBehavFrag
    connection::RelativeElementConnections
    max_charge::Float64
    max_voltage::Float64
    state::TankState
    sealstate::SealState
    force_reactivate_state::Bool
end

is_sealed(tank::TankBehavFrag)::Bool = is_sealed(tank.sealstate)
is_force_reactivated(tank::TankBehavFrag)::Bool = tank.force_reactivate_state
force_reactivate(tank::TankBehavFrag) = @set tank.force_reactivate_state = true
clear_force_reactivate(tank::TankBehavFrag) = @set tank.force_reactivate_state = false

"True when the tank voltage source is active: unsealed with charge in the open middle range."
tank_is_active(tank::TankBehavFrag) = !is_sealed(tank.sealstate) && (0.0 < tank.state.charge < tank.max_charge || is_force_reactivated(tank))

"True when the tank is automatically disconnected at the empty boundary (not sealed)."
tank_is_auto_empty(tank::TankBehavFrag) = !is_sealed(tank.sealstate) && tank.state.charge <= 0.0

"True when the tank is automatically disconnected at the full boundary (not sealed)."
tank_is_auto_full(tank::TankBehavFrag) = !is_sealed(tank.sealstate) && tank.state.charge >= tank.max_charge

function TankBehavFrag(;
        connection::RelativeElementConnections,
        max_charge::Real,
        max_voltage::Real,
        initial_charge::Real = 0.0,
        sealstate::SealState = SealState()
    )
    max_charge_f = float(max_charge)
    initial_charge_f = float(initial_charge)

    initial_charge_f ≤ max_charge_f || throw(
        ArgumentError(
            "initial_charge ($initial_charge_f) must be ≤ max_charge ($max_charge_f)"
        )
    )

    return TankBehavFrag(
        connection,
        max_charge_f,
        float(max_voltage),
        TankState(initial_charge_f),
        sealstate,
        false
    )
end

const tank_vsource_element_index::Int = 1 # Tank voltage source is always at index 1

function get_tunables(tank::TankBehavFrag)::NTuple{3, TunableProps}
    max_charge_props = TunableProps(
        tank.max_charge,
        "Tank Max Charge",
        "Coulombs (A*tick)"
    )

    max_voltage_props = TunableProps(
        tank.max_voltage,
        "Tank Max Voltage",
        get_unitstring(HexElements.CONST_VOLTAGE)
    )

    tank_state_props = TunableProps(
        tank.state.charge,
        "Current Charge State",
        "Coulombs (A*tick)"
    )

    return (max_charge_props, max_voltage_props, tank_state_props)
end

"Return updated tank values while preserving seal and reactivation state."
function set_tunables(tank::TankBehavFrag, tunables::NTuple{3, T})::TankBehavFrag where {T <: Real}
    float_vals = Float64.(tunables)
    return TankBehavFrag(
        tank.connection,
        float_vals[1], # max_charge
        float_vals[2], # max_voltage
        TankState(float_vals[3]), # current charge state
        tank.sealstate,
        tank.force_reactivate_state
    )
end

function update_flowbehav(tank::TankBehavFrag; tile::TileCoord, mna_state::MNA_State, kwargs...)
    tank = clear_force_reactivate(tank)

    is_sealed(tank.sealstate) && return tank  # Manual seal: ignore stale current until source is dropped

    tank_vsource_element_id = ElementID(tile, tank_vsource_element_index)
    haskey(mna_state.vsources, tank_vsource_element_id) || return tank  # Source was pruned

    current = get(mna_state.vsource_currents, tank_vsource_element_id, 0.0)
    delta = current / BASE_UPS
    prospective_charge = tank.state.charge + delta

    return @set tank.state.charge = clamp(prospective_charge, 0.0, tank.max_charge)
end

function render_map_elem!(queue::Vector{<:RenderCommand}, tank::TankBehavFrag; kwargs...)
    return nothing  # No overlay for Thevinin tanks; indicator is rendered in render_base_elem!
end

function get_actions(tank::TankBehavFrag; kwargs...)
    sealed = is_sealed(tank.sealstate)
    has_fuel = tank.state.charge > 0.0
    vent_tooltip = if !has_fuel
        "Tank is already empty"
    elseif sealed
        "Tank is sealed"
    else
        "Vent all stored fuel and seal the tank"
    end

    # Vent and Seal: empties and seals; only meaningful when unsealed with fuel
    vent_and_seal = ActionInfo(
        id = :vent_and_seal,
        label = "Vent and Seal",
        enabled = !sealed && has_fuel,
        group_enabled = !sealed || !has_fuel,
        tooltip = vent_tooltip,
        confirmation_message = "Are you sure? This will vent all stored fuel.",
    )

    # Seal Tank: seals without venting; only when unsealed
    seal_action = ActionInfo(
        id = :seal_tank,
        label = "Seal Tank",
        enabled = !sealed,
        tooltip = sealed ? "Tank is already sealed" : "Seal the tank to prevent flow",
    )

    # Unseal Tank: reopens a sealed tank
    unseal_action = ActionInfo(
        id = :unseal_tank,
        label = "Unseal Tank",
        enabled = sealed,
        tooltip = sealed ? "Reopen the tank and resume normal flow" : "Tank is not currently sealed",
    )

    return (vent_and_seal, seal_action, unseal_action)
end

function do_action(tank::TankBehavFrag, action_id::Symbol; kwargs...)
    if action_id === :vent_and_seal
        tank = @set tank.state.charge = 0.0
        tank = @set tank.sealstate = seal(tank.sealstate)
        return tank, ValidRequestResult("Tank vented and sealed")
    elseif action_id === :seal_tank
        tank = @set tank.sealstate = seal(tank.sealstate)
        return tank, ValidRequestResult("Tank sealed")
    elseif action_id === :unseal_tank
        tank = @set tank.sealstate = unseal(tank.sealstate)
        return tank, ValidRequestResult("Tank unsealed")
    end
    throw(ArgumentError("Action :$(action_id) not recognised by TankBehavFrag"))
end

function can_be_moved(tank::TankBehavFrag; kwargs...)
    if tank.state.charge <= 0.0
        return ValidRequest()
    else
        return InvalidRequest("empty or vent the tank first")
    end
end

#= ---------- AbstractTankBehavFrag ----------- =#

"Abstract tank fragment interface; subtypes expose a `tank::TankBehavFrag` field for shared-method delegation."
abstract type AbstractTankBehavFrag end

get_tunables(behav::T) where {T <: AbstractTankBehavFrag} = get_tunables(behav.tank)
set_tunables(behav::T, tunables::NTuple{N, Real}) where {N, T <: AbstractTankBehavFrag} = @set behav.tank = set_tunables(behav.tank, tunables)
update_flowbehav(behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = @set behav.tank = update_flowbehav(behav.tank; kwargs...)
get_actions(behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = get_actions(behav.tank; kwargs...)

function do_action(behav::T, action_id::Symbol; kwargs...) where {T <: AbstractTankBehavFrag}
    tank, result = do_action(behav.tank, action_id; kwargs...)
    return (@set behav.tank = tank), result
end

render_map_elem!(queue::Vector{<:RenderCommand}, behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = render_map_elem!(queue, behav.tank; kwargs...)
map_rotation(behav::T, rotation::HexAxis) where {T <: AbstractTankBehavFrag} = rotation # No rotation restriction by default
can_be_moved(behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = can_be_moved(behav.tank; kwargs...)

"""
Return a probe with an active copy of the tank voltage source when auto-disconnected
(empty or full boundary charge, not manually sealed). Returns `nothing` for active
mid-range tanks and for manually sealed tanks.
"""
function get_reactivation_probe(behav::T; kwargs...) where {T <: AbstractTankBehavFrag}
    if is_sealed(behav.tank.sealstate)
        return nothing  # Manually sealed: no probe
    elseif tank_is_active(behav.tank)
        return nothing  # Active mid-range: no probe needed
    end

    (rel_vsource,) = produce_rel_elements(behav)
    active_vsource = @set rel_vsource.active = true
    return ReactivationProbe((active_vsource,))
end

"""
Classify tank reactivation from the speculative current direction:
positive (inflow) is useful for an empty tank, negative (outflow) is useful for a full tank.
Wrong-sign flow is harmful; zero or pruned current is neutral.
"""
function classify_reactivation_probe(behav::T; tile::TileCoord, derivedmapstate::DerivedMapState, mna_state, rotation::HexAxis = HexFrame.Q_POS, kwargs...) where {T <: AbstractTankBehavFrag}
    (rel_vsource,) = produce_rel_elements(behav)
    active_vsource = @set rel_vsource.active = true
    abs_vsource = map_element(active_vsource, tile, tank_vsource_element_index, rotation)

    current = abs_element_get_current(abs_vsource, derivedmapstate, mna_state)
    isnothing(current) && return HexComponentsAPI.PROBE_NEUTRAL  # Pruned from speculative solve

    probe_tol = 1.0e-9
    if tank_is_auto_empty(behav.tank)
        current > probe_tol  && return HexComponentsAPI.PROBE_USEFUL   # Empty: positive inflow is useful
        current < -probe_tol && return HexComponentsAPI.PROBE_HARMFUL  # Empty: negative outflow is harmful
        return HexComponentsAPI.PROBE_NEUTRAL
    elseif tank_is_auto_full(behav.tank)
        current < -probe_tol && return HexComponentsAPI.PROBE_USEFUL   # Full: negative outflow is useful
        current > probe_tol  && return HexComponentsAPI.PROBE_HARMFUL  # Full: positive inflow is harmful
        return HexComponentsAPI.PROBE_NEUTRAL
    else
        error("Tank reactivation probe reached impossible state: tank is neither sealed, active, empty, nor full")
    end
end

"Set the one-shot tank force-reactivation flag after a useful speculative result."
function commit_reactivation_probe(behav::T; kwargs...) where {T <: AbstractTankBehavFrag}
    return @set behav.tank = force_reactivate(behav.tank)
end

#= ---------- GasTankBehavFrag ----------- =#

"Gas tank fragment with a linear charge-voltage relationship."
struct GasTankBehavFrag <: AbstractTankBehavFrag
    tank::TankBehavFrag
end

function produce_rel_elements(behav::GasTankBehavFrag)::NTuple{1, RelativeElement}
    tank = behav.tank
    fill_frac = tank.state.charge / tank.max_charge
    voltage = fill_frac * tank.max_voltage
    rel_element = RelativeElement(tank.connection, voltage, HexElements.CONST_VOLTAGE; active = tank_is_active(tank))
    return (rel_element,)
end

function render_fluid!(queue::Vector{<:RenderCommand}, behav::GasTankBehavFrag, fluidmask::Symbol, fluid::FluidType, gameticks::Int; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0)
    # Render fluidmask in black as background
    black = DEFAULT_EMPTY_FLUID_COLOUR
    push!(queue, render_basic_tile(glmap, fluidmask, rotation, position; scale = scale, transparency = transparency, colour = black, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset), pos_offset = pos_offset))

    # Render fluid mask with fluid colour, and set transparency based on fill fraction
    colour = get_fluid_colour(fluid)
    fill_frac = behav.tank.state.charge / behav.tank.max_charge
    final_transparency = transparency * fill_frac # More transparent when emptier
    push!(queue, render_gas_tile(glmap, fluidmask, rotation, position, gameticks; scale = scale, transparency = final_transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 100) + Int32(render_height_offset), pos_offset = pos_offset))
    return nothing
end

#= ---------- StoredFluidState ----------- =#

"Value state for a refillable tank's runtime liquid identity."
struct StoredFluidState
    fluid_value::FluidType
    has_fluid::Bool
end

StoredFluidState(fluid::FluidType) = StoredFluidState(fluid, true)
StoredFluidState(::Nothing) = StoredFluidState(HexFluids.COLD_GAS, false)  # Unused placeholder when empty

get_stored_fluid(state::StoredFluidState)::Union{FluidType, Nothing} = state.has_fluid ? state.fluid_value : nothing

"Return replacement stored-fluid state with the supplied runtime identity."
set_stored_fluid(state::StoredFluidState, fluid::Union{FluidType, Nothing}) = StoredFluidState(fluid)

"Clear the stored fluid when a tank empties."
clear_stored_fluid(state::StoredFluidState) = set_stored_fluid(state, nothing)

#= ---------- FixedFluid ----------- =#

"Construction-time concrete fluid identity."
struct FixedFluid
    fluid::FluidType
end

"Get the stored fluid from a fixed-fluid configuration."
get_stored_fluid(frag::FixedFluid)::FluidType = frag.fluid

#= ---------- LiquidTankBehavFrag ----------- =#

"Liquid tank fragment with near-constant voltage until charge is close to zero."
struct LiquidTankBehavFrag <: AbstractTankBehavFrag
    tank::TankBehavFrag
    rotation_behav::HorizontalFlipOnlyBehavFrag
    stored_fluid::StoredFluidState  # runtime liquid identity; nothing when empty
end

LiquidTankBehavFrag(tank::TankBehavFrag, initial_fluid::Union{FluidType, Nothing}) =
    LiquidTankBehavFrag(tank, HorizontalFlipOnlyBehavFrag(), StoredFluidState(initial_fluid))

LiquidTankBehavFrag(tank::TankBehavFrag) = LiquidTankBehavFrag(tank, nothing)

function produce_rel_elements(behav::LiquidTankBehavFrag)::NTuple{1, RelativeElement}
    tank = behav.tank
    f(x; steepness = 9.0) = 1 - (1 - x)^steepness
    fill_frac = tank.state.charge / tank.max_charge
    voltage = tank.max_voltage * f(fill_frac)
    rel_element = RelativeElement(tank.connection, voltage, HexElements.CONST_VOLTAGE; active = tank_is_active(tank))
    return (rel_element,)
end

function render_fluid!(queue::Vector{<:RenderCommand}, behav::LiquidTankBehavFrag, fluidmask::Symbol, fluid::Union{FluidType, Nothing}, gameticks::Int; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0)
    black = DEFAULT_EMPTY_FLUID_COLOUR
    fixed_rotation = HexFrame.Q_POS # Force horizontal for fluid rendering
    push!(queue, render_basic_tile(glmap, fluidmask, fixed_rotation, position; scale = scale, transparency = transparency, colour = black, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset), pos_offset = pos_offset))

    colour = get_fluid_colour(fluid)
    fill_frac = behav.tank.state.charge / behav.tank.max_charge
    push!(queue, render_liquid_tile(glmap, fluidmask, fixed_rotation, position, gameticks; scale = scale, transparency = transparency, colour = colour, unclipped_texcoord = SVector(fill_frac, 1.0), draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 100) + Int32(render_height_offset), pos_offset = pos_offset))
    return nothing
end

map_rotation(behav::LiquidTankBehavFrag, rotation::HexAxis) = map_rotation(behav.rotation_behav, rotation)

#= ---------- PressureFedTankBehavFrag ----------- =#

"Pressure-fed tank fragment with coupled liquid and gas charge state."
struct PressureFedTankBehavFrag
    liquid_state::TankState
    gas_state::TankState
    liquid_sealstate::SealState  # manual player seal
    gas_sealstate::SealState     # manual player seal
    force_liquid_reactivate_state::Bool
    force_gas_reactivate_state::Bool
    max_liquid_charge::Float64
    max_gas_pressure::Float64
    gas_node::NodePos
    stored_liquid::StoredFluidState       # runtime liquid identity; nothing when empty
end

function PressureFedTankBehavFrag(;
        initial_liquid_charge::Real,
        initial_gas_charge::Real,
        max_liquid_charge::Real,
        max_gas_pressure::Real,
        gas_node::NodePos,
        initial_liquid_fluid::Union{FluidType, Nothing} = nothing,
        liquid_sealstate::SealState = SealState(),
        gas_sealstate::SealState = SealState()
    )
    max_liquid_charge_f = float(max_liquid_charge)
    max_gas_pressure_f = float(max_gas_pressure)
    initial_liquid_charge_f = float(initial_liquid_charge)
    initial_gas_charge_f = float(initial_gas_charge)

    max_liquid_charge_f > 0.0 || throw(ArgumentError("max_liquid_charge must be positive"))
    max_gas_pressure_f > 0.0 || throw(ArgumentError("max_gas_pressure must be positive"))
    0.0 ≤ initial_liquid_charge_f ≤ max_liquid_charge_f || throw(
        ArgumentError(
            "initial_liquid_charge ($initial_liquid_charge_f) must be between 0.0 and max_liquid_charge ($max_liquid_charge_f)"
        )
    )

    # Seed stored liquid only when the tank starts with liquid; clear it when starting empty
    stored_fluid = initial_liquid_charge_f > 0.0 ? initial_liquid_fluid : nothing

    return PressureFedTankBehavFrag(
        TankState(initial_liquid_charge_f),
        TankState(initial_gas_charge_f),
        liquid_sealstate,
        gas_sealstate,
        false,
        false,
        max_liquid_charge_f,
        max_gas_pressure_f,
        gas_node,
        StoredFluidState(stored_fluid)
    )
end

"True when the liquid side is manually sealed."
liquid_is_sealed(tank::PressureFedTankBehavFrag) = is_sealed(tank.liquid_sealstate)
liquid_is_force_reactivated(tank::PressureFedTankBehavFrag)::Bool = tank.force_liquid_reactivate_state
force_liquid_reactivate(tank::PressureFedTankBehavFrag) = @set tank.force_liquid_reactivate_state = true
clear_force_liquid_reactivate(tank::PressureFedTankBehavFrag) = @set tank.force_liquid_reactivate_state = false

"True when the gas side is manually sealed."
gas_is_sealed(tank::PressureFedTankBehavFrag) = is_sealed(tank.gas_sealstate)
gas_is_force_reactivated(tank::PressureFedTankBehavFrag)::Bool = tank.force_gas_reactivate_state
force_gas_reactivate(tank::PressureFedTankBehavFrag) = @set tank.force_gas_reactivate_state = true
clear_force_gas_reactivate(tank::PressureFedTankBehavFrag) = @set tank.force_gas_reactivate_state = false

"True when the liquid side is automatically disconnected at the empty boundary (not manually sealed)."
pressurefed_liquid_is_auto_empty(tank::PressureFedTankBehavFrag) = !liquid_is_sealed(tank) && tank.liquid_state.charge <= 0.0

"True when the liquid side is automatically disconnected at the full boundary (not manually sealed)."
pressurefed_liquid_is_auto_full(tank::PressureFedTankBehavFrag) = !liquid_is_sealed(tank) && tank.liquid_state.charge >= tank.max_liquid_charge

"True when the gas side is automatically disconnected at the empty boundary (not manually sealed)."
pressurefed_gas_is_auto_empty(tank::PressureFedTankBehavFrag) = !gas_is_sealed(tank) && tank.gas_state.charge <= 0.0

"""True when gas pressure has reached or exceeded the maximum (not manually sealed).
This condition disables both sides unless their reactivation probes approve pressure relief."""
pressurefed_gas_is_auto_full_pressure(tank::PressureFedTankBehavFrag) = !gas_is_sealed(tank) && compute_gas_pressure(tank) >= tank.max_gas_pressure

"True when the liquid voltage source should be active."
function pressurefed_liquid_source_active(tank::PressureFedTankBehavFrag)
    liquid_is_sealed(tank) && return false
    (0.0 < tank.liquid_state.charge < tank.max_liquid_charge || liquid_is_force_reactivated(tank)) || return false
    pressurefed_gas_is_auto_full_pressure(tank) && !liquid_is_force_reactivated(tank) && return false
    return true
end

"True when the gas voltage source should be active."
function pressurefed_gas_source_active(tank::PressureFedTankBehavFrag)
    gas_is_sealed(tank) && return false
    (tank.gas_state.charge > 0.0 || gas_is_force_reactivated(tank)) || return false
    pressurefed_gas_is_auto_full_pressure(tank) && !gas_is_force_reactivated(tank) && return false
    return true
end

"True when the liquid-side resistor path should be active (same gating rule as the liquid source)."
pressurefed_liquid_path_active(tank::PressureFedTankBehavFrag) = pressurefed_liquid_source_active(tank)

const pressurefed_liquid_vsource_index::Int = 1
const pressurefed_gas_vsource_index::Int = 2
const PRESSUREFED_GAS_DISPLACEMENT_RATIO::Float64 = 2.0
const PRESSUREFED_MINIMUM_GAS_HEADSPACE_RATIO::Float64 = 0.05

"Compute the current pressure produced by the coupled gas/liquid state"
function compute_gas_pressure(tank::PressureFedTankBehavFrag)::Float64
    minimum_headspace = PRESSUREFED_MINIMUM_GAS_HEADSPACE_RATIO * tank.max_liquid_charge
    displaced_liquid = tank.max_liquid_charge - tank.liquid_state.charge
    headspace = minimum_headspace + displaced_liquid / PRESSUREFED_GAS_DISPLACEMENT_RATIO
    if headspace <= 0.0
        return 0.0
    end

    pressure = tank.gas_state.charge * tank.max_gas_pressure / headspace
    if tank.gas_state.charge < 0.0
        pressure *= 10.0
    end
    return pressure
end

function produce_rel_elements(tank::PressureFedTankBehavFrag)::NTuple{2, RelativeElement}
    liquid_active = pressurefed_liquid_source_active(tank)
    gas_active = pressurefed_gas_source_active(tank)

    # gas_pressure based from gas charge and headspace
    gas_tank_pressure = compute_gas_pressure(tank)
    # liquid pressure is up to 1% of max gas pressure scaling by fill, to provide some driver for tanks to balance
    liquid_pressure = 0.01 * (tank.liquid_state.charge / tank.max_liquid_charge * tank.max_gas_pressure)
    # liquid tank gets the sum of the pressures. Gas usually dominates but liquid provides some pressure if gas is empty, and forces equalisation
    liquid_tank_pressure = liquid_pressure + gas_tank_pressure

    liquid_vsource = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND),
        liquid_tank_pressure,
        HexElements.CONST_VOLTAGE;
        active = liquid_active
    )
    gas_vsource = RelativeElement(
        RelativeElementConnections(tank.gas_node, HexFrame.GROUND),
        gas_tank_pressure,
        HexElements.CONST_VOLTAGE;
        active = gas_active # gas source handles negative charge with negative pressure ramp
    )
    return (liquid_vsource, gas_vsource)
end

function get_tunables(tank::PressureFedTankBehavFrag)::NTuple{4, TunableProps}
    max_liquid_props = TunableProps(
        tank.max_liquid_charge,
        "Max Liquid Capacity",
        "Coulombs (A*tick)"
    )
    max_gas_props = TunableProps(
        tank.max_gas_pressure,
        "Max Gas Pressure",
        get_unitstring(HexElements.CONST_VOLTAGE)
    )
    liquid_props = TunableProps(
        tank.liquid_state.charge,
        "Liquid Charge",
        "Coulombs (A*tick)"
    )
    gas_props = TunableProps(
        tank.gas_state.charge,
        "Gas Charge",
        "Coulombs (A*tick)"
    )
    return (max_liquid_props, max_gas_props, liquid_props, gas_props)
end

"Return updated tank values while preserving seal state and reactivation flags."
function set_tunables(tank::PressureFedTankBehavFrag, tunables::NTuple{4, T})::PressureFedTankBehavFrag where {T <: Real}
    float_vals = Float64.(tunables)
    new_tank = PressureFedTankBehavFrag(
        initial_liquid_charge = clamp(float_vals[3], 0.0, float_vals[1]),
        initial_gas_charge = float_vals[4],
        max_liquid_charge = float_vals[1],
        max_gas_pressure = float_vals[2],
        gas_node = tank.gas_node,
        initial_liquid_fluid = get_stored_fluid(tank.stored_liquid),
        liquid_sealstate = tank.liquid_sealstate,
        gas_sealstate = tank.gas_sealstate
    )
    new_tank = @set new_tank.force_liquid_reactivate_state = tank.force_liquid_reactivate_state
    new_tank = @set new_tank.force_gas_reactivate_state = tank.force_gas_reactivate_state
    return new_tank
end

function update_flowbehav(tank::PressureFedTankBehavFrag; tile::TileCoord, mna_state::MNA_State, kwargs...)
    tank = clear_force_liquid_reactivate(tank)
    tank = clear_force_gas_reactivate(tank)

    liquid_element_id = ElementID(tile, pressurefed_liquid_vsource_index)
    gas_element_id = ElementID(tile, pressurefed_gas_vsource_index)

    liquid_present = haskey(mna_state.vsources, liquid_element_id)
    gas_present = haskey(mna_state.vsources, gas_element_id)
    (!liquid_present && !gas_present) && return tank

    # Manually sealed sides ignore stale current until update_map! drops the source
    liquid_current = liquid_present && !liquid_is_sealed(tank) ? get(mna_state.vsource_currents, liquid_element_id, 0.0) : 0.0
    gas_current = gas_present && !gas_is_sealed(tank) ? get(mna_state.vsource_currents, gas_element_id, 0.0) : 0.0

    tank = @set tank.liquid_state.charge = clamp(tank.liquid_state.charge + liquid_current / BASE_UPS, 0.0, tank.max_liquid_charge)
    return @set tank.gas_state.charge = max(tank.gas_state.charge + gas_current / BASE_UPS, 0.0)
end

function get_actions(tank::PressureFedTankBehavFrag; kwargs...)
    liq_sealed = liquid_is_sealed(tank)
    gas_sealed = gas_is_sealed(tank)
    has_liquid = tank.liquid_state.charge > 0.0
    has_gas = tank.gas_state.charge > 0.0

    gas_vent_tooltip = if !has_gas
        "Gas chamber is already empty"
    elseif gas_sealed
        "Gas side is already sealed"
    else
        "Vent all pressurising gas and seal the gas side"
    end
    liquid_vent_tooltip = if !has_liquid
        "Liquid chamber is already empty"
    elseif liq_sealed
        "Liquid side is already sealed"
    else
        "Vent all liquid fuel and seal the liquid side"
    end

    vent_and_seal_gas = ActionInfo(
        id = :vent_and_seal_gas,
        label = "Vent and Seal Gas",
        enabled = !gas_sealed && has_gas,
        group_enabled = !gas_sealed || !has_gas,
        tooltip = gas_vent_tooltip,
        confirmation_message = "Are you sure? This will vent all stored pressurising gas.",
    )

    vent_and_seal_liquid = ActionInfo(
        id = :vent_and_seal_liquid,
        label = "Vent and Seal Liquid",
        enabled = !liq_sealed && has_liquid,
        group_enabled = !liq_sealed || !has_liquid,
        tooltip = liquid_vent_tooltip,
        confirmation_message = "Are you sure? This will vent all stored liquid fuel.",
    )

    seal_both = ActionInfo(
        id = :seal_both,
        label = "Seal Both Sides",
        enabled = !liq_sealed || !gas_sealed,
        tooltip = (!liq_sealed || !gas_sealed) ? "Seal both sides to prevent flow" : "Both sides are already sealed",
    )

    unseal_gas = ActionInfo(
        id = :unseal_gas,
        label = "Unseal Gas",
        enabled = gas_sealed,
        tooltip = gas_sealed ? "Reopen the gas side and resume normal flow" : "Gas side is not sealed",
    )

    unseal_liquid = ActionInfo(
        id = :unseal_liquid,
        label = "Unseal Liquid",
        enabled = liq_sealed,
        tooltip = liq_sealed ? "Reopen the liquid side and resume normal flow" : "Liquid side is not sealed",
    )

    return (vent_and_seal_gas, vent_and_seal_liquid, seal_both, unseal_gas, unseal_liquid)
end

function do_action(tank::PressureFedTankBehavFrag, action_id::Symbol; kwargs...)
    if action_id === :vent_and_seal_gas
        tank = @set tank.gas_state.charge = 0.0
        tank = @set tank.gas_sealstate = seal(tank.gas_sealstate)
        return tank, ValidRequestResult("Gas vented and sealed")
    elseif action_id === :vent_and_seal_liquid
        tank = @set tank.liquid_state.charge = 0.0
        tank = @set tank.liquid_sealstate = seal(tank.liquid_sealstate)
        return tank, ValidRequestResult("Liquid vented and sealed")
    elseif action_id === :seal_both
        tank = @set tank.liquid_sealstate = seal(tank.liquid_sealstate)
        tank = @set tank.gas_sealstate = seal(tank.gas_sealstate)
        return tank, ValidRequestResult("Both sides sealed")
    elseif action_id === :unseal_gas
        tank = @set tank.gas_sealstate = unseal(tank.gas_sealstate)
        return tank, ValidRequestResult("Gas side unsealed")
    elseif action_id === :unseal_liquid
        tank = @set tank.liquid_sealstate = unseal(tank.liquid_sealstate)
        return tank, ValidRequestResult("Liquid side unsealed")
    end
    throw(ArgumentError("Action :$(action_id) not recognised by PressureFedTankBehavFrag"))
end

function can_be_moved(tank::PressureFedTankBehavFrag; kwargs...)
    if tank.liquid_state.charge <= 0.0 && tank.gas_state.charge <= 0.0
        return ValidRequest()
    else
        return InvalidRequest("empty or vent the tank first")
    end
end

# ===============================================================
# Concrete Component Behaviours
# ===============================================================

#= ---------- Stored fluid helpers ----------- =#

"""
Adopt the fluid at NODE_INTERNAL_1 into `stored` when a concrete liquid is present.
Used by liquid tank update paths to seed stored identity on refill.
"""
function adopt_stored_liquid_from_internal_node(stored::StoredFluidState, tile::TileCoord, derivedmapstate::DerivedMapState)
    internal_node = NodeCoord(tile, HexFrame.NODE_INTERNAL_1)
    adopted = get(derivedmapstate.nodeactualfluids, internal_node, nothing)
    if adopted isa FluidType && is_liquid(adopted)
        return set_stored_fluid(stored, adopted)
    end
    return stored
end

#= ---------- ThevininTankCompBehav ----------- =#

"Tank component with a series resistor and a plain sprite."
struct ThevininTankCompBehav{T <: AbstractTankBehavFrag, N} <: ComponentBehavior
    tank::T
    out_nodes::NTuple{N, NodePos}
    series_conductance::Float64
    fluid::FluidType
end

function ThevininTankCompBehav(
        ::Type{T}, connection_number::Integer;
        fluid::FluidType,
        max_charge::Real,
        max_voltage::Real,
        initial_charge::Real = 0.0,
        series_conductance::Real,
    ) where {T <: AbstractTankBehavFrag}
    # Determine out nodes based on connection number
    if connection_number == 3
        out_nodes = (HexFrame.NODE_Q_POS, HexFrame.NODE_S_POS, HexFrame.NODE_R_POS)
    else
        throw(ArgumentError("Unsupported connection_number $connection_number for ThevininTankCompBehav; only 3 supported currently"))
    end

    # Tank
    tank_connections = RelativeElementConnections(HexFrame.NODE_INTERNAL_1, HexFrame.GROUND)
    tank_core = TankBehavFrag(
        connection = tank_connections,
        max_charge = max_charge,
        max_voltage = max_voltage,
        initial_charge = initial_charge
    )

    # For liquid tanks, seed stored_fluid from the initial fluid if the tank is non-empty
    tankfrag = if T === LiquidTankBehavFrag
        initial_fluid = float(initial_charge) > 0.0 ? fluid : nothing
        LiquidTankBehavFrag(tank_core, initial_fluid)
    else
        T(tank_core)
    end

    # Build final component
    return ThevininTankCompBehav(tankfrag, out_nodes, float(series_conductance), fluid)
end

# Delegation and adapted element production
"""
Accessor for the runtime liquid identity of a component.
Gas tanks always return `comp.fluid` (their fixed fluid type).
Liquid tanks return the runtime stored-fluid identity (may be `nothing` when empty).
"""
get_stored_fluid(comp::ThevininTankCompBehav) = comp.fluid
get_stored_fluid(comp::ThevininTankCompBehav{LiquidTankBehavFrag}) = get_stored_fluid(comp.tank.stored_fluid)

function produce_rel_elements(comp::ThevininTankCompBehav{T, N}) where {T, N}
    tank_elem = produce_rel_elements(comp.tank) # Tank element first (tank vsource must end up in index 1)

    # Create N resistor RelativeElements on the fly, between INTERNAL and each out_node
    resistors = ntuple(
        i -> RelativeElement(
            connections = RelativeElementConnections(HexFrame.NODE_INTERNAL_1, comp.out_nodes[i]),
            value = comp.series_conductance,
            type = HexElements.CONST_RESISTOR
        ), N
    )

    return (tank_elem..., resistors...)
end

function get_tunables(comp::ThevininTankCompBehav)
    tank_tunables = get_tunables(comp.tank)
    thev_props = TunableProps(
        comp.series_conductance,
        "Series Conductance",
        get_unitstring(HexElements.CONST_RESISTOR)
    )
    return (tank_tunables..., thev_props)
end

function get_tunables(comp::ThevininTankCompBehav{LiquidTankBehavFrag})
    tank_tunables = get_tunables(comp.tank)
    thev_props = TunableProps(
        comp.series_conductance,
        "Series Conductance",
        get_unitstring(HexElements.CONST_RESISTOR)
    )
    stored = get_stored_fluid(comp.tank.stored_fluid)
    # Fall back to comp.fluid (the construction-time fluid) as the display default when empty
    display_fluid = !isnothing(stored) ? stored : comp.fluid
    liquid_types = [HexFluids.MONOPROP_LIQUID, HexFluids.FUEL_LIQUID, HexFluids.OXIDISER_LIQUID]
    fluid_props = EnumTunableProps{FluidType}(
        display_fluid,
        liquid_types,
        [fluid_type_label(f) for f in liquid_types],
        "Stored Liquid"
    )
    return (tank_tunables..., thev_props, fluid_props)
end

function set_tunables(comp::ThevininTankCompBehav{T, N}, tunables::NTuple{4, Tval}) where {Tval <: Real, T <: AbstractTankBehavFrag, N}
    float_vals = Float64.(tunables)
    new_tank_frag = set_tunables(comp.tank, (float_vals[1], float_vals[2], float_vals[3]))
    new_thev = float_vals[4]
    return ThevininTankCompBehav(new_tank_frag, comp.out_nodes, new_thev, comp.fluid)
end

function set_tunables(comp::ThevininTankCompBehav{LiquidTankBehavFrag, N}, tunables::NTuple{5, Any}) where {N}
    float_vals = (Float64(tunables[1]), Float64(tunables[2]), Float64(tunables[3]), Float64(tunables[4]))
    new_fluid = tunables[5]::FluidType
    new_tank_frag = set_tunables(comp.tank, (float_vals[1], float_vals[2], float_vals[3]))
    new_tank_frag = @set new_tank_frag.stored_fluid = set_stored_fluid(new_tank_frag.stored_fluid, new_fluid)
    return ThevininTankCompBehav(new_tank_frag, comp.out_nodes, float_vals[4], comp.fluid)
end

function produce_rel_fluid_declarations(comp::ThevininTankCompBehav)
    temp_val = get_default_temperature(comp.fluid, THERMAL_AMBIENT_TEMPERATURE_K)
    return (RelativeFluidDeclaration(HexFrame.NODE_INTERNAL_1, FluidSource(comp.fluid, temp_val)),)
end

"""
State-dependent fluid declaration for liquid tanks.
Emits a concrete `FluidSource` when filled, or a `FluidConstraintRule(IS_LIQUID)` when empty,
allowing any compatible liquid to refill the tank.
"""
function produce_rel_fluid_declarations(comp::ThevininTankCompBehav{LiquidTankBehavFrag})
    stored = get_stored_fluid(comp.tank.stored_fluid)
    if !isnothing(stored) && comp.tank.tank.state.charge > 0.0
        temp_val = get_default_temperature(stored, THERMAL_AMBIENT_TEMPERATURE_K)
        return (RelativeFluidDeclaration(HexFrame.NODE_INTERNAL_1, FluidSource(stored, temp_val)),)
    else
        # Empty: advertise a liquid constraint so any liquid can flow in and seed refill
        return (RelativeFluidDeclaration(HexFrame.NODE_INTERNAL_1, FluidConstraintRule(HexFluids.IS_LIQUID)),)
    end
end

"Wet mass of a tank: charge x fluid density. Returns 0.0 if the requested fluid doesn't match this tank's fluid."
function get_component_wet_mass(comp::ThevininTankCompBehav; fluid::Union{FluidType, Nothing} = nothing, kwargs...)
    if !isnothing(fluid) && fluid != comp.fluid
        return 0.0
    end
    density = lookup_fluid_density(comp.fluid)
    return isnothing(density) ? 0.0 : comp.tank.tank.state.charge * density
end

"Wet mass for liquid tanks: uses the runtime stored fluid, which may differ from the construction-time fluid."
function get_component_wet_mass(comp::ThevininTankCompBehav{LiquidTankBehavFrag}; fluid::Union{FluidType, Nothing} = nothing, kwargs...)
    stored = get_stored_fluid(comp.tank.stored_fluid)
    isnothing(stored) && return 0.0  # empty tank carries no mass
    !isnothing(fluid) && fluid != stored && return 0.0
    density = lookup_fluid_density(stored)
    return isnothing(density) ? 0.0 : comp.tank.tank.state.charge * density
end

update_flowbehav(comp::ThevininTankCompBehav; kwargs...) = @set comp.tank = update_flowbehav(comp.tank; kwargs...)

"""
Liquid tank update: runs the base charge update, then manages stored fluid identity.
- On empty: clears stored_fluid to `nothing`.
- On refill (was empty, now positive charge): adopts the concrete fluid from NODE_INTERNAL_1.
"""
function update_flowbehav(comp::ThevininTankCompBehav{LiquidTankBehavFrag}; tile::TileCoord, derivedmapstate = nothing, kwargs...)
    was_empty = comp.tank.tank.state.charge <= 0.0

    tank = update_flowbehav(comp.tank; tile = tile, derivedmapstate = derivedmapstate, kwargs...)

    is_empty_now = tank.tank.state.charge <= 0.0

    if is_empty_now && !was_empty
        tank = @set tank.stored_fluid = clear_stored_fluid(tank.stored_fluid)
    elseif was_empty && !is_empty_now && derivedmapstate isa DerivedMapState
        tank = @set tank.stored_fluid = adopt_stored_liquid_from_internal_node(tank.stored_fluid, tile, derivedmapstate)
    end
    return @set comp.tank = tank
end

get_actions(comp::ThevininTankCompBehav; kwargs...) = get_actions(comp.tank; kwargs...)

function do_action(comp::ThevininTankCompBehav, action_id::Symbol; kwargs...)
    tank, result = do_action(comp.tank, action_id; kwargs...)
    return (@set comp.tank = tank), result
end

map_rotation(comp::ThevininTankCompBehav, rotation::HexAxis) = map_rotation(comp.tank, rotation)
can_be_moved(comp::ThevininTankCompBehav; kwargs...) = can_be_moved(comp.tank; kwargs...)
get_reactivation_probe(comp::ThevininTankCompBehav; kwargs...) = get_reactivation_probe(comp.tank; kwargs...)
classify_reactivation_probe(comp::ThevininTankCompBehav; kwargs...) = classify_reactivation_probe(comp.tank; kwargs...)
commit_reactivation_probe(comp::ThevininTankCompBehav; kwargs...) = @set comp.tank = commit_reactivation_probe(comp.tank; kwargs...)

# Rendering traits
const TANK_INDICATOR_GREEN = ColourType(0.2, 0.9, 0.2, 1.0) # Connected and active
const TANK_INDICATOR_RED = ColourType(0.9, 0.15, 0.15, 1.0) # Manually sealed
const RENDER_HEIGHT_TANK_INDICATOR = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + 100)

tanksprite(::ThevininTankCompBehav{GasTankBehavFrag, 3}) = :GasTank1_base
fluidmask(::ThevininTankCompBehav{GasTankBehavFrag, 3}) = :GasTank1_fluidmask
tanksprite(::ThevininTankCompBehav{LiquidTankBehavFrag, 3}) = :LiquidTank1_base
fluidmask(::ThevininTankCompBehav{LiquidTankBehavFrag, 3}) = :LiquidTank1_fluidmask
indicatorsprite(::ThevininTankCompBehav{GasTankBehavFrag, 3}) = :GasTank1_indicator
indicatorsprite(::ThevininTankCompBehav{LiquidTankBehavFrag, 3}) = :LiquidTank1_indicator

function render_base_elem!(queue::Vector{<:RenderCommand}, comp::ThevininTankCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, gameticks::Int64 = 0, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    # Render fluid (pass stored fluid for liquid tanks, comp.fluid for gas tanks)
    render_fluid!(queue, comp.tank, fluidmask(comp), comp.fluid, gameticks; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, scale = scale, transparency = transparency, render_height_offset = render_height_offset)

    # Render tank base sprite (static)
    push!(queue, render_basic_tile(glmap, tanksprite(comp), rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset), pos_offset = pos_offset))

    # Indicator light: green = active, red = manually sealed, absent = auto-disconnected
    tank_frag = comp.tank.tank
    indicator_height = RENDER_HEIGHT_TANK_INDICATOR + Int32(render_height_offset)
    if is_sealed(tank_frag.sealstate)
        push!(queue, render_basic_tile(glmap, indicatorsprite(comp), rotation, position; scale = scale, transparency = transparency, colour = TANK_INDICATOR_RED, draw_height = indicator_height, pos_offset = pos_offset))
    elseif tank_is_active(tank_frag)
        push!(queue, render_basic_tile(glmap, indicatorsprite(comp), rotation, position; scale = scale, transparency = transparency, colour = TANK_INDICATOR_GREEN, draw_height = indicator_height, pos_offset = pos_offset))
    end
    return nothing
end

function render_base_elem!(queue::Vector{<:RenderCommand}, comp::ThevininTankCompBehav{LiquidTankBehavFrag}; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, gameticks::Int64 = 0, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    render_fluid!(queue, comp.tank, fluidmask(comp), get_stored_fluid(comp.tank.stored_fluid), gameticks; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, scale = scale, transparency = transparency, render_height_offset = render_height_offset)

    push!(queue, render_basic_tile(glmap, tanksprite(comp), rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset), pos_offset = pos_offset))

    tank_frag = comp.tank.tank
    indicator_height = RENDER_HEIGHT_TANK_INDICATOR + Int32(render_height_offset)
    if is_sealed(tank_frag.sealstate)
        push!(queue, render_basic_tile(glmap, indicatorsprite(comp), rotation, position; scale = scale, transparency = transparency, colour = TANK_INDICATOR_RED, draw_height = indicator_height, pos_offset = pos_offset))
    elseif tank_is_active(tank_frag)
        push!(queue, render_basic_tile(glmap, indicatorsprite(comp), rotation, position; scale = scale, transparency = transparency, colour = TANK_INDICATOR_GREEN, draw_height = indicator_height, pos_offset = pos_offset))
    end
    return nothing
end

function render_map_elem!(queue::Vector{<:RenderCommand}, comp::ThevininTankCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, gameticks::Int64 = 0, render_height_offset::Integer = 0, kwargs...)
    render_base_elem!(queue, comp; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, gameticks = gameticks, render_height_offset = render_height_offset)
    return nothing
end

#= ---------- PressureFedTankCompBehav ----------- =#

"Two-port pressure-fed tank with liquid output and gas pressurisation input."
struct PressureFedTankCompBehav{N} <: ComponentBehavior
    tank::PressureFedTankBehavFrag
    liquid_nodes::NTuple{N, NodePos}
    series_conductance::Float64
    gas_fluid::FluidType
    rotation_behav::NoRotationBehavFrag
end

function PressureFedTankCompBehav(
        tank::PressureFedTankBehavFrag,
        liquid_nodes::NTuple{N, NodePos},
        series_conductance::Real,
        gas_fluid::FluidType,
        rotation_behav::NoRotationBehavFrag = NoRotationBehavFrag()
    ) where {N}
    return PressureFedTankCompBehav(
        tank,
        liquid_nodes,
        float(series_conductance),
        gas_fluid,
        rotation_behav
    )
end

"""
Runtime liquid identity of a pressure-fed tank.
Returns the stored fluid when filled, or `nothing` when the tank is empty.
"""
get_stored_fluid(comp::PressureFedTankCompBehav) = get_stored_fluid(comp.tank.stored_liquid)

function produce_rel_elements(comp::PressureFedTankCompBehav{N}) where {N}
    tank_elements = produce_rel_elements(comp.tank)
    liquid_path_active = pressurefed_liquid_path_active(comp.tank)
    resistors = ntuple(
        i -> RelativeElement(
            RelativeElementConnections(HexFrame.NODE_INTERNAL_1, comp.liquid_nodes[i]),
            comp.series_conductance,
            HexElements.CONST_RESISTOR;
            active = liquid_path_active
        ), N
    )
    return (tank_elements..., resistors...)
end

function get_tunables(comp::PressureFedTankCompBehav)
    tank_tunables = get_tunables(comp.tank)
    series_props = TunableProps(
        comp.series_conductance,
        "Series Conductance",
        get_unitstring(HexElements.CONST_RESISTOR)
    )
    stored = get_stored_fluid(comp.tank.stored_liquid)
    # Fall back to monoprop as the display default when empty
    display_fluid = !isnothing(stored) ? stored : HexFluids.MONOPROP_LIQUID
    liquid_types = [HexFluids.MONOPROP_LIQUID, HexFluids.FUEL_LIQUID, HexFluids.OXIDISER_LIQUID]
    fluid_props = EnumTunableProps{FluidType}(
        display_fluid,
        liquid_types,
        [fluid_type_label(f) for f in liquid_types],
        "Stored Liquid"
    )
    return (tank_tunables..., series_props, fluid_props)
end

function set_tunables(comp::PressureFedTankCompBehav{N}, tunables::NTuple{6, Any}) where {N}
    float_vals = (Float64(tunables[1]), Float64(tunables[2]), Float64(tunables[3]), Float64(tunables[4]), Float64(tunables[5]))
    new_fluid = tunables[6]::FluidType
    new_tank = set_tunables(comp.tank, (float_vals[1], float_vals[2], float_vals[3], float_vals[4]))
    new_tank = @set new_tank.stored_liquid = set_stored_fluid(new_tank.stored_liquid, new_fluid)
    return PressureFedTankCompBehav(
        new_tank,
        comp.liquid_nodes,
        float_vals[5],
        comp.gas_fluid,
        comp.rotation_behav
    )
end

"""
State-dependent fluid declarations for the pressure-fed liquid side.
Gas side remains a concrete `FluidSource`. Liquid side emits a `FluidSource` when filled,
or `FluidConstraintRule(IS_LIQUID)` when empty — allowing any compatible liquid to refill.
"""
function produce_rel_fluid_declarations(comp::PressureFedTankCompBehav)
    gas_temp = get_default_temperature(comp.gas_fluid, THERMAL_AMBIENT_TEMPERATURE_K)
    gas_decl = RelativeFluidDeclaration(comp.tank.gas_node, FluidSource(comp.gas_fluid, gas_temp))
    stored = get_stored_fluid(comp.tank.stored_liquid)
    if !isnothing(stored) && comp.tank.liquid_state.charge > 0.0
        liq_temp = get_default_temperature(stored, THERMAL_AMBIENT_TEMPERATURE_K)
        return (gas_decl, RelativeFluidDeclaration(HexFrame.NODE_INTERNAL_1, FluidSource(stored, liq_temp)))
    else
        return (gas_decl, RelativeFluidDeclaration(HexFrame.NODE_INTERNAL_1, FluidConstraintRule(HexFluids.IS_LIQUID)))
    end
end

"Wet mass is the combined stored liquid and non-negative stored gas mass. Liquid mass uses the runtime stored fluid identity."
function get_component_wet_mass(comp::PressureFedTankCompBehav; fluid::Union{FluidType, Nothing} = nothing, kwargs...)
    liquid_mass = 0.0
    gas_mass = 0.0

    stored = get_stored_fluid(comp.tank.stored_liquid)
    if !isnothing(stored)
        if isnothing(fluid) || fluid == stored
            liquid_density = lookup_fluid_density(stored)
            if !isnothing(liquid_density)
                liquid_mass = comp.tank.liquid_state.charge * liquid_density
            end
        end
    end

    if isnothing(fluid) || fluid == comp.gas_fluid
        gas_density = lookup_fluid_density(comp.gas_fluid)
        if !isnothing(gas_density)
            gas_mass = max(comp.tank.gas_state.charge, 0.0) * gas_density
        end
    end

    return liquid_mass + gas_mass
end

"""
Pressure-fed component update: integrates charge, then manages stored liquid identity.
- On liquid-side empty: clears stored_liquid to `nothing`.
- On liquid-side refill (was empty, now positive): adopts the fluid at NODE_INTERNAL_1.
"""
function update_flowbehav(comp::PressureFedTankCompBehav; tile::TileCoord, derivedmapstate = nothing, kwargs...)
    was_liquid_empty = comp.tank.liquid_state.charge <= 0.0

    tank = update_flowbehav(comp.tank; tile = tile, kwargs...)

    is_liquid_empty_now = tank.liquid_state.charge <= 0.0

    if is_liquid_empty_now && !was_liquid_empty
        tank = @set tank.stored_liquid = clear_stored_fluid(tank.stored_liquid)
    elseif was_liquid_empty && !is_liquid_empty_now && derivedmapstate isa DerivedMapState
        tank = @set tank.stored_liquid = adopt_stored_liquid_from_internal_node(tank.stored_liquid, tile, derivedmapstate)
    end
    return @set comp.tank = tank
end

get_actions(comp::PressureFedTankCompBehav; kwargs...) = get_actions(comp.tank; kwargs...)

function do_action(comp::PressureFedTankCompBehav, action_id::Symbol; kwargs...)
    tank, result = do_action(comp.tank, action_id; kwargs...)
    return (@set comp.tank = tank), result
end

map_rotation(comp::PressureFedTankCompBehav, rotation::HexAxis) = map_rotation(comp.rotation_behav, rotation)
can_be_moved(comp::PressureFedTankCompBehav; kwargs...) = can_be_moved(comp.tank; kwargs...)

#= ---------- PressureFedTankCompBehav probe methods ----------- =#

"Determine which sides of a pressure-fed tank are requesting reactivation probes and their desired flow directions."
function pressurefed_probe_sides(tank::PressureFedTankBehavFrag)
    gas_auto_full_pressure = pressurefed_gas_is_auto_full_pressure(tank)
    liq_auto_empty = pressurefed_liquid_is_auto_empty(tank)
    liq_auto_full = pressurefed_liquid_is_auto_full(tank)
    gas_auto_empty = pressurefed_gas_is_auto_empty(tank)

    probe_liquid = (liq_auto_empty || liq_auto_full || gas_auto_full_pressure) && !liquid_is_sealed(tank)
    probe_gas = (gas_auto_empty || gas_auto_full_pressure) && !gas_is_sealed(tank)

    # An empty, pressure-limited tank can neither discharge liquid nor accept more
    probe_liquid &= !(liq_auto_empty && gas_auto_full_pressure)

    return (; probe_liquid, probe_gas, gas_auto_full_pressure, liq_auto_empty, liq_auto_full, gas_auto_empty)
end

"""
Return a probe for any automatically disconnected side that is not manually sealed.
The probe tuple always has 2+N elements, matching the component's element ordering:
(liquid_vsource, gas_vsource, liquid_resistors...). Only the sides being tested are set active.
"""
function get_reactivation_probe(comp::PressureFedTankCompBehav{N}; kwargs...) where {N}
    tank = comp.tank
    sides = pressurefed_probe_sides(tank)

    (!sides.probe_liquid && !sides.probe_gas) && return nothing

    (frag_liquid_vsource, frag_gas_vsource) = produce_rel_elements(tank)
    probe_liquid_vsource = @set frag_liquid_vsource.active = sides.probe_liquid
    probe_gas_vsource = @set frag_gas_vsource.active = sides.probe_gas
    probe_resistors = ntuple(
        i -> RelativeElement(
            RelativeElementConnections(HexFrame.NODE_INTERNAL_1, comp.liquid_nodes[i]),
            comp.series_conductance,
            HexElements.CONST_RESISTOR;
            active = sides.probe_liquid
        ), N
    )
    return ReactivationProbe((probe_liquid_vsource, probe_gas_vsource, probe_resistors...))
end

"""
Classify a measured current relative to the desired flow direction.
Returns a `ReactivationProbeOutcome`.
"""
function pressurefed_probe_current_class(current::Float64, desired_direction::Symbol; tol::Float64 = 1.0e-9)::ReactivationProbeOutcome
    if desired_direction === :positive
        current > tol  && return HexComponentsAPI.PROBE_USEFUL
        current < -tol && return HexComponentsAPI.PROBE_HARMFUL
    else
        current < -tol && return HexComponentsAPI.PROBE_USEFUL
        current > tol  && return HexComponentsAPI.PROBE_HARMFUL
    end
    return HexComponentsAPI.PROBE_NEUTRAL
end

"Classify each pressure-fed side using the same speculative currents for acceptance and commit."
function pressurefed_probe_classes(tank::PressureFedTankBehavFrag, sides::NamedTuple; tile::TileCoord, derivedmapstate::DerivedMapState, mna_state, rotation::HexAxis)
    (frag_liquid_vsource, frag_gas_vsource) = produce_rel_elements(tank)
    liquid_class = HexComponentsAPI.PROBE_NEUTRAL
    gas_class = HexComponentsAPI.PROBE_NEUTRAL

    if sides.probe_liquid
        active_vsource = @set frag_liquid_vsource.active = true
        abs_vsource = map_element(active_vsource, tile, pressurefed_liquid_vsource_index, rotation)
        liquid_current = abs_element_get_current(abs_vsource, derivedmapstate, mna_state)
        if !isnothing(liquid_current)
            # Gas overpressure overrides desired direction: want liquid outflow to relieve headspace pressure
            liquid_desired = sides.gas_auto_full_pressure || sides.liq_auto_full ? :negative : :positive
            liquid_class = pressurefed_probe_current_class(liquid_current, liquid_desired)
        end
    end

    if sides.probe_gas
        active_vsource = @set frag_gas_vsource.active = true
        abs_vsource = map_element(active_vsource, tile, pressurefed_gas_vsource_index, rotation)
        gas_current = abs_element_get_current(abs_vsource, derivedmapstate, mna_state)
        if !isnothing(gas_current)
            gas_desired = sides.gas_auto_empty ? :positive : :negative  # empty wants inflow, overpressure wants outflow
            gas_class = pressurefed_probe_current_class(gas_current, gas_desired)
        end
    end

    return liquid_class, gas_class
end

"""
Classify a speculative pressure-fed tank probe as useful when either side has useful flow,
even if the companion side is harmful. Pruned sides are treated as neutral. Useful sides
are committed independently via `commit_reactivation_probe`.
"""
function classify_reactivation_probe(comp::PressureFedTankCompBehav{N}; tile::TileCoord, derivedmapstate::DerivedMapState, mna_state, rotation::HexAxis = HexFrame.Q_POS, kwargs...) where {N}
    tank = comp.tank
    sides = pressurefed_probe_sides(tank)

    (!sides.probe_liquid && !sides.probe_gas) && return HexComponentsAPI.PROBE_HARMFUL

    liquid_class, gas_class = pressurefed_probe_classes(tank, sides; tile, derivedmapstate, mna_state, rotation)
    (liquid_class === HexComponentsAPI.PROBE_USEFUL || gas_class === HexComponentsAPI.PROBE_USEFUL) && return HexComponentsAPI.PROBE_USEFUL
    (liquid_class === HexComponentsAPI.PROBE_HARMFUL || gas_class === HexComponentsAPI.PROBE_HARMFUL) && return HexComponentsAPI.PROBE_HARMFUL
    return HexComponentsAPI.PROBE_NEUTRAL
end

"Set one-shot force-reactivation flags for the useful pressure-fed side or sides."
function commit_reactivation_probe(comp::PressureFedTankCompBehav{N}; tile::TileCoord, derivedmapstate::DerivedMapState, mna_state, rotation::HexAxis = HexFrame.Q_POS, kwargs...) where {N}
    tank = comp.tank
    sides = pressurefed_probe_sides(tank)

    (!sides.probe_liquid && !sides.probe_gas) && return comp

    liquid_class, gas_class = pressurefed_probe_classes(tank, sides; tile, derivedmapstate, mna_state, rotation)
    liquid_class === HexComponentsAPI.PROBE_USEFUL && (tank = force_liquid_reactivate(tank))
    gas_class === HexComponentsAPI.PROBE_USEFUL && (tank = force_gas_reactivate(tank))
    return @set comp.tank = tank
end

#= ---------- PressureFedTankCompBehav rendering ----------- =#

tanksprite(::PressureFedTankCompBehav) = :PressureFedTank1_base
fluidmask(::PressureFedTankCompBehav) = :PressureFedTank1_fluidmask

function render_base_elem!(queue::Vector{<:RenderCommand}, comp::PressureFedTankCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, gameticks::Int64 = 0, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    mask = fluidmask(comp)
    height_offset = Int32(render_height_offset)
    fixed_rotation = HexFrame.Q_POS

    push!(queue, render_basic_tile(glmap, mask, fixed_rotation, position; scale = scale, transparency = transparency, colour = DEFAULT_EMPTY_FLUID_COLOUR, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + height_offset, pos_offset = pos_offset))

    liquid_fill_frac = clamp(comp.tank.liquid_state.charge / comp.tank.max_liquid_charge, 0.0, 1.0)
    headspace = comp.tank.max_liquid_charge - comp.tank.liquid_state.charge
    gas_fill_frac = headspace > 0.0 ? clamp(comp.tank.gas_state.charge / headspace, 0.0, 1.0) : 0.0

    gas_colour = get_fluid_colour(comp.gas_fluid)
    push!(queue, render_gas_tile(glmap, mask, HexFrame.Q_NEG, position, gameticks; scale = scale, transparency = transparency * gas_fill_frac, colour = gas_colour, unclipped_texcoord = SVector(1.0 - liquid_fill_frac, 1.0), draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 50) + height_offset, pos_offset = pos_offset))

    # Use stored runtime liquid identity for colour; renders as empty colour when nothing
    liquid_colour = get_fluid_colour(get_stored_fluid(comp))
    push!(queue, render_liquid_tile(glmap, mask, fixed_rotation, position, gameticks; scale = scale, transparency = transparency, colour = liquid_colour, unclipped_texcoord = SVector(liquid_fill_frac, 1.0), draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 100) + height_offset, pos_offset = pos_offset))

    push!(queue, render_basic_tile(glmap, tanksprite(comp), fixed_rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + height_offset, pos_offset = pos_offset))

    # Per-side indicator lights: green = active, red = manually sealed, absent = auto-disconnected
    indicator_height = RENDER_HEIGHT_TANK_INDICATOR + height_offset
    tank = comp.tank
    if liquid_is_sealed(tank)
        push!(queue, render_basic_tile(glmap, :PressureFedTank1_liquidindicator, fixed_rotation, position; scale = scale, transparency = transparency, colour = TANK_INDICATOR_RED, draw_height = indicator_height, pos_offset = pos_offset))
    elseif pressurefed_liquid_source_active(tank)
        push!(queue, render_basic_tile(glmap, :PressureFedTank1_liquidindicator, fixed_rotation, position; scale = scale, transparency = transparency, colour = TANK_INDICATOR_GREEN, draw_height = indicator_height, pos_offset = pos_offset))
    end
    if gas_is_sealed(tank)
        push!(queue, render_basic_tile(glmap, :PressureFedTank1_gasindicator, fixed_rotation, position; scale = scale, transparency = transparency, colour = TANK_INDICATOR_RED, draw_height = indicator_height, pos_offset = pos_offset))
    elseif pressurefed_gas_source_active(tank)
        push!(queue, render_basic_tile(glmap, :PressureFedTank1_gasindicator, fixed_rotation, position; scale = scale, transparency = transparency, colour = TANK_INDICATOR_GREEN, draw_height = indicator_height, pos_offset = pos_offset))
    end
    return nothing
end

function render_map_elem!(queue::Vector{<:RenderCommand}, comp::PressureFedTankCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, gameticks::Int64 = 0, render_height_offset::Integer = 0, kwargs...)
    render_base_elem!(queue, comp; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, gameticks = gameticks, render_height_offset = render_height_offset)
    return nothing
end

include("precompile_workload.jl")

end # module HexFlowTankComponents
