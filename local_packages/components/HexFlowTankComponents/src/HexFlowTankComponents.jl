"""
Tank component implementations for fluid storage.

This module provides concrete implementations of ComponentBehavior for tanks:
- ThevininTankCompBehav: Tank with series resistor (gas or liquid variants)
- GasTankBehavFrag: Linear charge-voltage relationship
- LiquidTankBehavFrag: Near-constant voltage until near-empty

All components follow the ComponentBehavior interface defined in HexComponentsAPI.
"""
module HexFlowTankComponents

using Accessors
using HexFrame, HexElements, HexFluids, HexComponentsAPI, FlowEngine, FlowMap, RenderEngine, HexFlowRendering
using HexFlowBasicComponents

# ComponentBehavior Mandatories
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# ComponentBehavior Optional
import HexComponentsAPI: update_flowbehav!, render_map_elem!, map_rotation, can_be_moved, get_component_wet_mass, get_actions, do_action!, produce_rel_fluid_declarations
import HexComponentsAPI: get_reactivation_probe, accept_reactivation_probe!, ReactivationProbe

# Concrete Component Behavior Exports
export ThevininTankCompBehav, GasTankBehavFrag, LiquidTankBehavFrag
export PressureFedTankBehavFrag, PressureFedTankCompBehav
export SealStateBehavFrag, seal!, unseal!, is_sealed
export TankBehavFrag, TankState, tank_is_active, tank_is_auto_empty, tank_is_auto_full
export liquid_is_sealed, gas_is_sealed
export pressurefed_liquid_is_auto_empty, pressurefed_liquid_is_auto_full
export pressurefed_gas_is_auto_empty, pressurefed_gas_is_auto_full_pressure
export pressurefed_liquid_source_active, pressurefed_gas_source_active, pressurefed_liquid_path_active

# ===============================================================
# Behavior Fragments
# ===============================================================

#= ---------- SealStateBehavFrag ----------- =#

"Behavioral fragment to track whether a tank is manually sealed. Interact with `seal!`, `unseal!` and `is_sealed` functions."
mutable struct SealStateBehavFrag
    seal_state::BinaryStateBehavFrag
end

SealStateBehavFrag() = SealStateBehavFrag(BinaryStateBehavFrag(false))

seal!(frag::SealStateBehavFrag) = settrue!(frag.seal_state)
unseal!(frag::SealStateBehavFrag) = setfalse!(frag.seal_state)
is_sealed(frag::SealStateBehavFrag)::Bool = getstate(frag.seal_state)

#= ---------- TankBehavFrag ----------- =#

"Mutable state for tank charge tracking"
mutable struct TankState
    charge::Float64
end

"Convert Real to TankState by wrapping in Float64"
Base.convert(::Type{TankState}, value::Real) = TankState(Float64(value))

"Flow behavior fragment for shared functionality of a tank. Missing produce_rel_elements as this is concrete tank type dependent"
struct TankBehavFrag
    connection::RelativeElementConnections
    max_charge::Float64
    max_voltage::Float64
    state::TankState
    sealstate::SealStateBehavFrag
end

is_sealed(tank::TankBehavFrag)::Bool = is_sealed(tank.sealstate)

"True when the tank voltage source is active: unsealed with charge in the open middle range."
tank_is_active(tank::TankBehavFrag) = !is_sealed(tank.sealstate) && 0.0 < tank.state.charge < tank.max_charge

"True when the tank is automatically disconnected at the empty boundary (not sealed)."
tank_is_auto_empty(tank::TankBehavFrag) = !is_sealed(tank.sealstate) && tank.state.charge <= 0.0

"True when the tank is automatically disconnected at the full boundary (not sealed)."
tank_is_auto_full(tank::TankBehavFrag) = !is_sealed(tank.sealstate) && tank.state.charge >= tank.max_charge

"Keyword constructor for tank fragment"
function TankBehavFrag(;
        connection::RelativeElementConnections,
        max_charge::Real,
        max_voltage::Real,
        initial_charge::Real = 0.0,
        sealstate::SealStateBehavFrag = SealStateBehavFrag()
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
        sealstate
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

function set_tunables(tank::TankBehavFrag, tunables::NTuple{3, T})::TankBehavFrag where {T <: Real}
    float_vals = Float64.(tunables)
    return TankBehavFrag(
        tank.connection,
        float_vals[1], # max_charge
        float_vals[2], # max_voltage
        float_vals[3],  # current charge state
        tank.sealstate
    )
end

function update_flowbehav!(tank::TankBehavFrag; tile::TileCoord, mna_state::MNA_State, kwargs...)
    is_sealed(tank.sealstate) && return  # Manual seal: ignore stale current until source is dropped

    tank_vsource_element_id = ElementID(tile, tank_vsource_element_index)
    haskey(mna_state.vsources, tank_vsource_element_id) || return  # Source was pruned

    current = get(mna_state.vsource_currents, tank_vsource_element_id, 0.0)
    delta = current / BASE_UPS
    prospective_charge = tank.state.charge + delta

    tank.state.charge = clamp(prospective_charge, 0.0, tank.max_charge)
end

function render_map_elem!(queue::Vector{<:RenderCommand}, tank::TankBehavFrag; kwargs...)
    return nothing  # No overlay for Thevinin tanks; indicator is rendered in render_base_elem!
end

function get_actions(tank::TankBehavFrag; kwargs...)
    sealed = is_sealed(tank.sealstate)
    has_fuel = tank.state.charge > 0.0

    # Vent and Seal: empties and seals; only meaningful when unsealed with fuel
    vent_and_seal = ActionInfo(
        :vent_and_seal,
        "Vent and Seal",
        !sealed && has_fuel,
        sealed ? "Tank is sealed" : (has_fuel ? "Vent all stored fuel and seal the tank" : "Tank is already empty"),
        (!sealed && has_fuel) ? "Are you sure? This will vent all stored fuel." : nothing
    )

    # Seal Tank: seals without venting; only when unsealed
    seal_action = ActionInfo(
        :seal_tank,
        "Seal Tank",
        !sealed,
        sealed ? "Tank is already sealed" : "Seal the tank to prevent flow"
    )

    # Unseal Tank: reopens a sealed tank
    unseal_action = ActionInfo(
        :unseal_tank,
        "Unseal Tank",
        sealed,
        sealed ? "Reopen the tank and resume normal flow" : "Tank is not currently sealed"
    )

    return (vent_and_seal, seal_action, unseal_action)
end

function do_action!(tank::TankBehavFrag, action_id::Symbol; kwargs...)
    if action_id === :vent_and_seal
        tank.state.charge = 0.0
        seal!(tank.sealstate)
        return (true, "Tank vented and sealed")
    elseif action_id === :seal_tank
        seal!(tank.sealstate)
        return (true, "Tank sealed")
    elseif action_id === :unseal_tank
        unseal!(tank.sealstate)
        return (true, "Tank unsealed")
    end
    return (false, "Action :$(action_id) not recognised by TankBehavFrag")
end

function can_be_moved(tank::TankBehavFrag; kwargs...)
    if tank.state.charge <= 0.0
        return (true, "")
    else
        return (false, "Tank cannot be moved unless empty")
    end
end

#= ---------- AbstractTankBehavFrag ----------- =#

"""
Method delegation for all AbstractTankBehavFrag fragments.
All subtypes must include a 'tank::TankBehavFrag' field.
"""
abstract type AbstractTankBehavFrag end

get_tunables(behav::T) where {T <: AbstractTankBehavFrag} = get_tunables(behav.tank)
set_tunables(behav::T, tunables::NTuple{N, Real}) where {N, T <: AbstractTankBehavFrag} = @set behav.tank = set_tunables(behav.tank, tunables)
update_flowbehav!(behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = update_flowbehav!(behav.tank; kwargs...)
get_actions(behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = get_actions(behav.tank; kwargs...)
do_action!(behav::T, action_id::Symbol; kwargs...) where {T <: AbstractTankBehavFrag} = do_action!(behav.tank, action_id; kwargs...)
render_map_elem!(queue::Vector{<:RenderCommand}, behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = render_map_elem!(queue, behav.tank; kwargs...)
map_rotation(behav::T, rotation::HexAxis) where {T <: AbstractTankBehavFrag} = rotation # No rotation restriction by default
can_be_moved(behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = can_be_moved(behav.tank; kwargs...)

"""
Return a probe with an active copy of the tank voltage source when auto-disconnected
(empty or full boundary charge, not manually sealed). Returns `nothing` for active
mid-range tanks and for manually sealed tanks.
"""
function get_reactivation_probe(behav::T; kwargs...) where {T <: AbstractTankBehavFrag}
    is_sealed(behav.tank.sealstate) && return nothing
    charge = behav.tank.state.charge
    0.0 < charge < behav.tank.max_charge && return nothing  # Active: no probe needed

    (rel_vsource,) = produce_rel_elements(behav)
    active_vsource = @set rel_vsource.active = true
    return ReactivationProbe((active_vsource,))
end

"""
Accept reactivation only when the speculative current is in the useful direction:
positive (inflow) for an empty tank, negative (outflow) for a full tank.
Does not mutate tank state on acceptance.
"""
function accept_reactivation_probe!(behav::T; tile::TileCoord, derivedmapstate::DerivedMapState, mna_state, rotation::HexAxis = HexFrame.Q_POS, kwargs...) where {T <: AbstractTankBehavFrag}
    (rel_vsource,) = produce_rel_elements(behav)
    active_vsource = @set rel_vsource.active = true
    abs_vsource = map_element(active_vsource, tile, tank_vsource_element_index, rotation)

    current = abs_element_get_current(abs_vsource, derivedmapstate, mna_state)
    isnothing(current) && return false  # Pruned from speculative solve

    probe_tol = 1e-9
    if behav.tank.state.charge <= 0.0
        return current > probe_tol   # Empty: accept only positive inflow
    else
        return current < -probe_tol  # Full: accept only negative outflow
    end
end

#= ---------- GasTankBehavFrag ----------- =#

"Gas tank with linear charge-voltage relationship"
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

"""
Render gas tank fluid visualization.
Renders a black background fluidmask followed by the fluid-colored mask with transparency
proportional to fill fraction (more transparent when emptier).
"""
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

#= ---------- LiquidTankBehavFrag ----------- =#

"Liquid tank with a near constant voltage until charge is close to zero where it ramps down quickly"
struct LiquidTankBehavFrag <: AbstractTankBehavFrag
    tank::TankBehavFrag
    rotation_behav::HorizontalFlipOnlyBehavFrag
end
LiquidTankBehavFrag(tank::TankBehavFrag) = LiquidTankBehavFrag(tank, HorizontalFlipOnlyBehavFrag())

function produce_rel_elements(behav::LiquidTankBehavFrag)::NTuple{1, RelativeElement}
    tank = behav.tank
    f(x; steepness = 9.0) = 1 - (1 - x)^steepness
    fill_frac = tank.state.charge / tank.max_charge
    voltage = tank.max_voltage * f(fill_frac)
    rel_element = RelativeElement(tank.connection, voltage, HexElements.CONST_VOLTAGE; active = tank_is_active(tank))
    return (rel_element,)
end

"""
Render liquid tank fluid visualization.
Renders the fluid-colored mask with horizontal clipping based on fill fraction,
always oriented horizontally (Q_POS) regardless of component rotation.
"""
function render_fluid!(queue::Vector{<:RenderCommand}, behav::LiquidTankBehavFrag, fluidmask::Symbol, fluid::FluidType, gameticks::Int; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0)
    black = DEFAULT_EMPTY_FLUID_COLOUR
    fixed_rotation = HexFrame.Q_POS # Force horizontal for fluid rendering
    push!(queue, render_basic_tile(glmap, fluidmask, fixed_rotation, position; scale = scale, transparency = transparency, colour = black, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset), pos_offset = pos_offset))

    colour = get_fluid_colour(fluid)
    fill_frac = behav.tank.state.charge / behav.tank.max_charge
    push!(queue, render_liquid_tile(glmap, fluidmask, fixed_rotation, position, gameticks; scale = scale, transparency = transparency, colour = colour, x_unclipped = fill_frac, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 100) + Int32(render_height_offset), pos_offset = pos_offset))
    return nothing
end

map_rotation(behav::LiquidTankBehavFrag, rotation::HexAxis) = map_rotation(behav.rotation_behav, rotation)

#= ---------- PressureFedTankBehavFrag ----------- =#

"Pressure-fed tank fragment with coupled liquid and gas charge state"
struct PressureFedTankBehavFrag
    liquid_state::TankState
    gas_state::TankState
    liquid_sealstate::SealStateBehavFrag  # manual player seal
    gas_sealstate::SealStateBehavFrag     # manual player seal
    max_liquid_charge::Float64
    max_gas_pressure::Float64
    gas_node::NodePos
end

function PressureFedTankBehavFrag(;
        initial_liquid_charge::Real,
        initial_gas_charge::Real,
        max_liquid_charge::Real,
        max_gas_pressure::Real,
        gas_node::NodePos,
        liquid_sealstate::SealStateBehavFrag = SealStateBehavFrag(),
        gas_sealstate::SealStateBehavFrag = SealStateBehavFrag()
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

    return PressureFedTankBehavFrag(
        TankState(initial_liquid_charge_f),
        TankState(initial_gas_charge_f),
        liquid_sealstate,
        gas_sealstate,
        max_liquid_charge_f,
        max_gas_pressure_f,
        gas_node
    )
end

"True when the liquid side is manually sealed."
liquid_is_sealed(tank::PressureFedTankBehavFrag) = is_sealed(tank.liquid_sealstate)

"True when the gas side is manually sealed."
gas_is_sealed(tank::PressureFedTankBehavFrag) = is_sealed(tank.gas_sealstate)

"True when the liquid side is automatically disconnected at the empty boundary (not manually sealed)."
pressurefed_liquid_is_auto_empty(tank::PressureFedTankBehavFrag) = !liquid_is_sealed(tank) && tank.liquid_state.charge <= 0.0

"True when the liquid side is automatically disconnected at the full boundary (not manually sealed)."
pressurefed_liquid_is_auto_full(tank::PressureFedTankBehavFrag) = !liquid_is_sealed(tank) && tank.liquid_state.charge >= tank.max_liquid_charge

"True when the gas side is automatically disconnected at the empty boundary (not manually sealed)."
pressurefed_gas_is_auto_empty(tank::PressureFedTankBehavFrag) = !gas_is_sealed(tank) && tank.gas_state.charge <= 0.0

"""True when gas pressure has reached or exceeded the maximum (not manually sealed).
This condition disables both the gas source and the liquid side via cross-side coupling."""
pressurefed_gas_is_auto_full_pressure(tank::PressureFedTankBehavFrag) = !gas_is_sealed(tank) && compute_gas_pressure(tank) >= tank.max_gas_pressure

"True when the liquid voltage source should be active."
function pressurefed_liquid_source_active(tank::PressureFedTankBehavFrag)
    liquid_is_sealed(tank) && return false
    0.0 < tank.liquid_state.charge < tank.max_liquid_charge || return false
    pressurefed_gas_is_auto_full_pressure(tank) && return false
    return true
end

"True when the gas voltage source should be active."
function pressurefed_gas_source_active(tank::PressureFedTankBehavFrag)
    gas_is_sealed(tank) && return false
    tank.gas_state.charge <= 0.0 && return false
    pressurefed_gas_is_auto_full_pressure(tank) && return false
    return true
end

"True when the liquid-side resistor path should be active (same gating rule as the liquid source)."
pressurefed_liquid_path_active(tank::PressureFedTankBehavFrag) = pressurefed_liquid_source_active(tank)

const pressfed_liquid_vsource_index::Int = 1
const pressfed_gas_vsource_index::Int = 2

"Compute the current pressure produced by the coupled gas/liquid state"
function compute_gas_pressure(tank::PressureFedTankBehavFrag)::Float64
    headspace = (1.05 * tank.max_liquid_charge) - tank.liquid_state.charge # always allow 5% headspace for gas
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
    liquid_pressure = 0.01*(tank.liquid_state.charge/tank.max_liquid_charge * tank.max_gas_pressure)
    # liquid tank gets the sum of the pressures. Gas usually dominates but liquid provides some pressure if gas is empty, and forces equalisation
    liquid_tank_pressure = liquid_pressure + gas_tank_pressure

    liquid_vsource = RelativeElement(
        RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.GROUND),
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

function set_tunables(tank::PressureFedTankBehavFrag, tunables::NTuple{4, T})::PressureFedTankBehavFrag where {T <: Real}
    float_vals = Float64.(tunables)
    return PressureFedTankBehavFrag(
        initial_liquid_charge = clamp(float_vals[3], 0.0, float_vals[1]),
        initial_gas_charge = float_vals[4],
        max_liquid_charge = float_vals[1],
        max_gas_pressure = float_vals[2],
        gas_node = tank.gas_node,
        liquid_sealstate = tank.liquid_sealstate,
        gas_sealstate = tank.gas_sealstate
    )
end

function update_flowbehav!(tank::PressureFedTankBehavFrag; tile::TileCoord, mna_state::MNA_State, kwargs...)
    liquid_element_id = ElementID(tile, pressfed_liquid_vsource_index)
    gas_element_id = ElementID(tile, pressfed_gas_vsource_index)

    liquid_present = haskey(mna_state.vsources, liquid_element_id)
    gas_present = haskey(mna_state.vsources, gas_element_id)
    (!liquid_present && !gas_present) && return nothing

    # Manually sealed sides ignore stale current until update_map! drops the source
    liquid_current = liquid_present && !liquid_is_sealed(tank) ? get(mna_state.vsource_currents, liquid_element_id, 0.0) : 0.0
    gas_current = gas_present && !gas_is_sealed(tank) ? get(mna_state.vsource_currents, gas_element_id, 0.0) : 0.0

    tank.liquid_state.charge = clamp(tank.liquid_state.charge + liquid_current / BASE_UPS, 0.0, tank.max_liquid_charge)
    tank.gas_state.charge = max(tank.gas_state.charge + gas_current / BASE_UPS, 0.0)
    return nothing
end

function get_actions(tank::PressureFedTankBehavFrag; kwargs...)
    liq_sealed = liquid_is_sealed(tank)
    gas_sealed = gas_is_sealed(tank)
    has_liquid = tank.liquid_state.charge > 0.0
    has_gas = tank.gas_state.charge > 0.0

    vent_and_seal_gas = ActionInfo(
        :vent_and_seal_gas, "Vent and Seal Gas",
        !gas_sealed,
        gas_sealed ? "Gas side is already sealed" : "Vent all pressurising gas and seal the gas side",
        (!gas_sealed && has_gas) ? "Are you sure? This will vent all stored pressurising gas." : nothing
    )

    vent_and_seal_liquid = ActionInfo(
        :vent_and_seal_liquid, "Vent and Seal Liquid",
        !liq_sealed,
        liq_sealed ? "Liquid side is already sealed" : "Vent all liquid fuel and seal the liquid side",
        (!liq_sealed && has_liquid) ? "Are you sure? This will vent all stored liquid fuel." : nothing
    )

    seal_both = ActionInfo(
        :seal_both, "Seal Both Sides",
        !liq_sealed || !gas_sealed,
        (!liq_sealed || !gas_sealed) ? "Seal both sides to prevent flow" : "Both sides are already sealed"
    )

    unseal_gas = ActionInfo(
        :unseal_gas, "Unseal Gas",
        gas_sealed,
        gas_sealed ? "Reopen the gas side and resume normal flow" : "Gas side is not sealed"
    )

    unseal_liquid = ActionInfo(
        :unseal_liquid, "Unseal Liquid",
        liq_sealed,
        liq_sealed ? "Reopen the liquid side and resume normal flow" : "Liquid side is not sealed"
    )

    return (vent_and_seal_gas, vent_and_seal_liquid, seal_both, unseal_gas, unseal_liquid)
end

function do_action!(tank::PressureFedTankBehavFrag, action_id::Symbol; kwargs...)
    if action_id === :vent_and_seal_gas
        tank.gas_state.charge = 0.0
        seal!(tank.gas_sealstate)
        return (true, "Gas vented and sealed")
    elseif action_id === :vent_and_seal_liquid
        tank.liquid_state.charge = 0.0
        seal!(tank.liquid_sealstate)
        return (true, "Liquid vented and sealed")
    elseif action_id === :seal_both
        seal!(tank.liquid_sealstate)
        seal!(tank.gas_sealstate)
        return (true, "Both sides sealed")
    elseif action_id === :unseal_gas
        unseal!(tank.gas_sealstate)
        return (true, "Gas side unsealed")
    elseif action_id === :unseal_liquid
        unseal!(tank.liquid_sealstate)
        return (true, "Liquid side unsealed")
    end
    return (false, "Action :$(action_id) not recognised by PressureFedTankBehavFrag")
end

function can_be_moved(tank::PressureFedTankBehavFrag; kwargs...)
    if tank.liquid_state.charge <= 0.0 && tank.gas_state.charge <= 0.0
        return (true, "")
    else
        return (false, "Tank cannot be moved while it contains fuel or gas")
    end
end

# ===============================================================
# Concrete Component Behaviors
# ===============================================================

#= ---------- ThevininTankCompBehav ----------- =#

"Any tank with series resistor and a plain sprite"
struct ThevininTankCompBehav{T <: AbstractTankBehavFrag, N} <: ComponentBehavior
    tank::T
    out_nodes::NTuple{N, NodePos}
    series_conductance::Float64
    fluid::FluidType
end

"Keyword-based constructor for a Thevinin tank that supports N out nodes"
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
    tank_connections = RelativeElementConnections(HexFrame.NODE_INTERNAL, HexFrame.GROUND)
    tankfrag = T(
        TankBehavFrag(
            connection = tank_connections,
            max_charge = max_charge,
            max_voltage = max_voltage,
            initial_charge = initial_charge
        )
    )

    # Build final component
    return ThevininTankCompBehav(tankfrag, out_nodes, float(series_conductance), fluid)
end

# Method forwarding and adapted element production
function produce_rel_elements(comp::ThevininTankCompBehav{T, N}) where {T, N}
    tank_elem = produce_rel_elements(comp.tank) # Tank element first (tank vsource must end up in index 1)

    # Create N resistor RelativeElements on the fly, between INTERNAL and each out_node
    resistors = ntuple(
        i -> RelativeElement(
            connections = RelativeElementConnections(HexFrame.NODE_INTERNAL, comp.out_nodes[i]),
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

function set_tunables(comp::ThevininTankCompBehav{T, N}, tunables::NTuple{4, Tval}) where {Tval <: Real, T <: AbstractTankBehavFrag, N}
    float_vals = Float64.(tunables)
    new_tank_frag = set_tunables(comp.tank, (float_vals[1], float_vals[2], float_vals[3])) # Update underlying tank fragment (returns same fragment type T with updated .tank) - tanks have 3 tunables
    new_thev = float_vals[4]
    return ThevininTankCompBehav(new_tank_frag, comp.out_nodes, new_thev, comp.fluid)
end

function produce_rel_fluid_declarations(comp::ThevininTankCompBehav)
    temp = get_default_temperature(Val(comp.fluid))
    temp_val = temp !== nothing ? temp : 300.0
    return (RelativeFluidDeclaration(HexFrame.NODE_INTERNAL, FluidSource(comp.fluid, temp_val)),)
end

"Wet mass of a tank: charge x fluid density. Returns 0.0 if the requested fluid doesn't match this tank's fluid."
function get_component_wet_mass(comp::ThevininTankCompBehav; fluid::Union{FluidType, Nothing} = nothing, kwargs...)
    if fluid !== nothing && fluid != comp.fluid
        return 0.0
    end
    density = lookup_fluid_density(comp.fluid)
    return density === nothing ? 0.0 : comp.tank.tank.state.charge * density
end

update_flowbehav!(comp::ThevininTankCompBehav; kwargs...) = update_flowbehav!(comp.tank; kwargs...)
get_actions(comp::ThevininTankCompBehav; kwargs...) = get_actions(comp.tank; kwargs...)
do_action!(comp::ThevininTankCompBehav, action_id::Symbol; kwargs...) = do_action!(comp.tank, action_id; kwargs...)
map_rotation(comp::ThevininTankCompBehav, rotation::HexAxis) = map_rotation(comp.tank, rotation)
can_be_moved(comp::ThevininTankCompBehav; kwargs...) = can_be_moved(comp.tank; kwargs...)
get_reactivation_probe(comp::ThevininTankCompBehav; kwargs...) = get_reactivation_probe(comp.tank; kwargs...)
accept_reactivation_probe!(comp::ThevininTankCompBehav; kwargs...) = accept_reactivation_probe!(comp.tank; kwargs...)

# Rendering traits
const TANK_INDICATOR_GREEN = ColourType(0.2, 0.9, 0.2, 1.0) # Connected and active
const TANK_INDICATOR_RED   = ColourType(0.9, 0.15, 0.15, 1.0) # Manually sealed
const RENDER_HEIGHT_TANK_INDICATOR = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC + 100)

tanksprite(::ThevininTankCompBehav{GasTankBehavFrag, 3}) = :GasTank1_base
fluidmask(::ThevininTankCompBehav{GasTankBehavFrag, 3}) = :GasTank1_fluidmask
tanksprite(::ThevininTankCompBehav{LiquidTankBehavFrag, 3}) = :LiquidTank1_base
fluidmask(::ThevininTankCompBehav{LiquidTankBehavFrag, 3}) = :LiquidTank1_fluidmask
indicatorsprite(::ThevininTankCompBehav{GasTankBehavFrag, 3}) = :GasTank1_indicator
indicatorsprite(::ThevininTankCompBehav{LiquidTankBehavFrag, 3}) = :LiquidTank1_indicator

function render_base_elem!(queue::Vector{<:RenderCommand}, comp::ThevininTankCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, gameticks::Int64 = 0, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    # Render fluid
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

function render_map_elem!(queue::Vector{<:RenderCommand}, comp::ThevininTankCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, gameticks::Int64 = 0, render_height_offset::Integer = 0, kwargs...)
    render_base_elem!(queue, comp; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, gameticks = gameticks, render_height_offset = render_height_offset)
    return nothing
end

#= ---------- PressureFedTankCompBehav ----------- =#

"Two-port pressure-fed tank with a liquid output and gas pressurisation input"
struct PressureFedTankCompBehav{N} <: ComponentBehavior
    tank::PressureFedTankBehavFrag
    liquid_nodes::NTuple{N, NodePos}
    series_conductance::Float64
    gas_fluid::FluidType
    liquid_fluid::FluidType
    rotation_behav::NoRotationBehavFrag
end

function PressureFedTankCompBehav(
        tank::PressureFedTankBehavFrag,
        liquid_nodes::NTuple{N, NodePos},
        series_conductance::Real,
        gas_fluid::FluidType,
        liquid_fluid::FluidType,
        rotation_behav::NoRotationBehavFrag = NoRotationBehavFrag()
    ) where {N}
    return PressureFedTankCompBehav(
        tank,
        liquid_nodes,
        float(series_conductance),
        gas_fluid,
        liquid_fluid,
        rotation_behav
    )
end

function produce_rel_elements(comp::PressureFedTankCompBehav{N}) where {N}
    tank_elements = produce_rel_elements(comp.tank)
    liquid_path_active = pressurefed_liquid_path_active(comp.tank)
    resistors = ntuple(
        i -> RelativeElement(
            RelativeElementConnections(HexFrame.NODE_INTERNAL, comp.liquid_nodes[i]),
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
    return (tank_tunables..., series_props)
end

function set_tunables(comp::PressureFedTankCompBehav{N}, tunables::NTuple{5, T})::PressureFedTankCompBehav{N} where {N, T <: Real}
    float_vals = Float64.(tunables)
    new_tank = set_tunables(comp.tank, (float_vals[1], float_vals[2], float_vals[3], float_vals[4]))
    return PressureFedTankCompBehav(
        new_tank,
        comp.liquid_nodes,
        float_vals[5],
        comp.gas_fluid,
        comp.liquid_fluid,
        comp.rotation_behav
    )
end

function produce_rel_fluid_declarations(comp::PressureFedTankCompBehav)
    gas_temp = let t = get_default_temperature(Val(comp.gas_fluid)); t !== nothing ? t : 300.0; end
    liq_temp = let t = get_default_temperature(Val(comp.liquid_fluid)); t !== nothing ? t : 300.0; end
    return (
        RelativeFluidDeclaration(comp.tank.gas_node, FluidSource(comp.gas_fluid, gas_temp)),
        RelativeFluidDeclaration(HexFrame.NODE_INTERNAL, FluidSource(comp.liquid_fluid, liq_temp)),
    )
end

"Wet mass is the combined stored liquid and non-negative stored gas mass"
function get_component_wet_mass(comp::PressureFedTankCompBehav; fluid::Union{FluidType, Nothing} = nothing, kwargs...)
    liquid_mass = 0.0
    gas_mass = 0.0

    if fluid === nothing || fluid == comp.liquid_fluid
        liquid_density = lookup_fluid_density(comp.liquid_fluid)
        if liquid_density !== nothing
            liquid_mass = comp.tank.liquid_state.charge * liquid_density
        end
    end

    if fluid === nothing || fluid == comp.gas_fluid
        gas_density = lookup_fluid_density(comp.gas_fluid)
        if gas_density !== nothing
            gas_mass = max(comp.tank.gas_state.charge, 0.0) * gas_density
        end
    end

    return liquid_mass + gas_mass
end

update_flowbehav!(comp::PressureFedTankCompBehav; kwargs...) = update_flowbehav!(comp.tank; kwargs...)
get_actions(comp::PressureFedTankCompBehav; kwargs...) = get_actions(comp.tank; kwargs...)
do_action!(comp::PressureFedTankCompBehav, action_id::Symbol; kwargs...) = do_action!(comp.tank, action_id; kwargs...)
map_rotation(comp::PressureFedTankCompBehav, rotation::HexAxis) = map_rotation(comp.rotation_behav, rotation)
can_be_moved(comp::PressureFedTankCompBehav; kwargs...) = can_be_moved(comp.tank; kwargs...)

#= ---------- PressureFedTankCompBehav probe methods ----------- =#

"""
Return a probe for any automatically disconnected side that is not manually sealed.
The probe tuple always has 2+N elements, matching the component's element ordering:
(liquid_vsource, gas_vsource, liquid_resistors...). Only the sides being tested are set active.
"""
function get_reactivation_probe(comp::PressureFedTankCompBehav{N}; kwargs...) where {N}
    tank = comp.tank

    gas_auto_full_pressure = pressurefed_gas_is_auto_full_pressure(tank)
    liq_auto_empty = pressurefed_liquid_is_auto_empty(tank)
    liq_auto_full = pressurefed_liquid_is_auto_full(tank)
    gas_auto_empty = pressurefed_gas_is_auto_empty(tank)

    probe_liquid = (liq_auto_empty || liq_auto_full || gas_auto_full_pressure) && !liquid_is_sealed(tank)
    probe_gas = (gas_auto_empty || gas_auto_full_pressure) && !gas_is_sealed(tank)

    (!probe_liquid && !probe_gas) && return nothing

    (frag_liquid_vsource, frag_gas_vsource) = produce_rel_elements(tank)
    probe_liquid_vsource = @set frag_liquid_vsource.active = probe_liquid
    probe_gas_vsource = @set frag_gas_vsource.active = probe_gas
    probe_resistors = ntuple(
        i -> RelativeElement(
            RelativeElementConnections(HexFrame.NODE_INTERNAL, comp.liquid_nodes[i]),
            comp.series_conductance,
            HexElements.CONST_RESISTOR;
            active = probe_liquid
        ), N
    )
    return ReactivationProbe((probe_liquid_vsource, probe_gas_vsource, probe_resistors...))
end

"""
Classify a measured current relative to the desired flow direction.
Returns `:useful`, `:harmful`, or `:neutral`.
"""
function pressfed_probe_current_class(current::Float64, desired_direction::Symbol; tol::Float64 = 1e-9)
    if desired_direction === :positive
        current > tol  && return :useful
        current < -tol && return :harmful
    else
        current < -tol && return :useful
        current > tol  && return :harmful
    end
    return :neutral
end

"""
Accept a speculative reactivation probe when at least one probed side has useful flow and
no probed side has harmful flow. Does not mutate charge or seal states.
"""
function accept_reactivation_probe!(comp::PressureFedTankCompBehav{N}; tile::TileCoord, derivedmapstate::DerivedMapState, mna_state, rotation::HexAxis = HexFrame.Q_POS, kwargs...) where {N}
    tank = comp.tank

    gas_auto_full_pressure = pressurefed_gas_is_auto_full_pressure(tank)
    liq_auto_empty = pressurefed_liquid_is_auto_empty(tank)
    liq_auto_full = pressurefed_liquid_is_auto_full(tank)
    gas_auto_empty = pressurefed_gas_is_auto_empty(tank)

    probe_liquid = (liq_auto_empty || liq_auto_full || gas_auto_full_pressure) && !liquid_is_sealed(tank)
    probe_gas = (gas_auto_empty || gas_auto_full_pressure) && !gas_is_sealed(tank)

    (!probe_liquid && !probe_gas) && return false

    (frag_liquid_vsource, frag_gas_vsource) = produce_rel_elements(tank)
    liquid_class = :neutral
    gas_class = :neutral

    if probe_liquid
        active_vsource = @set frag_liquid_vsource.active = true
        abs_vsource = map_element(active_vsource, tile, pressfed_liquid_vsource_index, rotation)
        liquid_current = abs_element_get_current(abs_vsource, derivedmapstate, mna_state)
        isnothing(liquid_current) && return false  # Pruned: reject

        # Gas overpressure overrides desired direction: want liquid outflow to relieve headspace pressure
        liquid_desired = if gas_auto_full_pressure
            :negative
        elseif liq_auto_full
            :negative
        else
            :positive  # auto-empty: want inflow to fill
        end
        liquid_class = pressfed_probe_current_class(liquid_current, liquid_desired)
        liquid_class === :harmful && return false
    end

    if probe_gas
        active_vsource = @set frag_gas_vsource.active = true
        abs_vsource = map_element(active_vsource, tile, pressfed_gas_vsource_index, rotation)
        gas_current = abs_element_get_current(abs_vsource, derivedmapstate, mna_state)
        isnothing(gas_current) && return false  # Pruned: reject

        gas_desired = gas_auto_empty ? :positive : :negative  # empty wants inflow, overpressure wants outflow
        gas_class = pressfed_probe_current_class(gas_current, gas_desired)
        gas_class === :harmful && return false
    end

    return liquid_class === :useful || gas_class === :useful
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
    push!(queue, render_gas_tile(glmap, mask, HexFrame.Q_NEG, position, gameticks; scale = scale, transparency = transparency * gas_fill_frac, colour = gas_colour, x_unclipped = 1.0 - liquid_fill_frac, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 50) + height_offset, pos_offset = pos_offset))

    liquid_colour = get_fluid_colour(comp.liquid_fluid)
    push!(queue, render_liquid_tile(glmap, mask, fixed_rotation, position, gameticks; scale = scale, transparency = transparency, colour = liquid_colour, x_unclipped = liquid_fill_frac, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND + 100) + height_offset, pos_offset = pos_offset))

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

end # module HexFlowTankComponents
