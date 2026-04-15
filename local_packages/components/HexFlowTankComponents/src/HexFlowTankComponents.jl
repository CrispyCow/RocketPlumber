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
import HexComponentsAPI: get_fluidtags, update_flowbehav!, on_click!, render_map_elem!, map_rotation, can_be_moved, get_component_wet_mass, get_actions, do_action!
# Behavior Fragment Dependencies
import HexFlowBasicComponents: stall!, unstall!, is_stalled, StallBehavFrag

# Concrete Component Behavior Exports
export ThevininTankCompBehav, GasTankBehavFrag, LiquidTankBehavFrag
export PressureFedTankBehavFrag, PressureFedTankCompBehav

# ===============================================================
# Behavior Fragments
# ===============================================================

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
    stallstate::StallBehavFrag
end

"Keyword constructor for tank fragment"
function TankBehavFrag(;
        connection::RelativeElementConnections,
        max_charge::Real,
        max_voltage::Real,
        initial_charge::Real = 0.0,
        stallstate::StallBehavFrag = StallBehavFrag()
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
        stallstate
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
    newtank = TankBehavFrag(
        tank.connection,
        float_vals[1], # max_charge
        float_vals[2], # max_voltage
        float_vals[3],  # current charge state
        tank.stallstate
    )
    return newtank
end

function update_flowbehav!(tank::TankBehavFrag; tile::TileCoord, mna_state::MNA_State, kwargs...)
    tank_vsource_element_id = ElementID(tile, tank_vsource_element_index)

    # Skip update if tank element has been pruned
    if !haskey(mna_state.vsources, tank_vsource_element_id)
        return
    end

    # Update stored charge - if the new charge would go negative, stall instead of updating
    current = get(mna_state.vsource_currents, tank_vsource_element_id, 0.0)
    delta = current / BASE_UPS
    prospective_charge = tank.state.charge + delta

    if prospective_charge < 0.0
        stall!(tank.stallstate) # Going negative -> stall the tank and skip the update
        return
    end

    return tank.state.charge = prospective_charge
end

function render_map_elem!(queue::Vector{<:RenderCommand}, tank::TankBehavFrag; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    render_map_elem!(queue, tank.stallstate; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, render_height_offset = render_height_offset) # Render stall overlay if present (delegates to StallBehavFrag renderer)
    return nothing
end

is_stalled(tank::TankBehavFrag)::Bool = is_stalled(tank.stallstate)
stall!(tank::TankBehavFrag) = stall!(tank.stallstate)
unstall!(tank::TankBehavFrag) = unstall!(tank.stallstate)

function on_click!(tank::TankBehavFrag; kwargs...)
    do_action!(tank.stallstate, :unstall)
    return nothing
end

function get_actions(tank::TankBehavFrag; kwargs...)
    # Vent action
    is_empty = tank.state.charge ≈ 0.0
    vent_tooltip = is_empty ? "Tank already empty" : "Vent tank contents to space. Warning: will lose whatever is stored in this tank"
    vent_action = ActionInfo(:vent_tank, "Vent Tank", !is_empty, vent_tooltip, is_empty ? nothing : "Are you sure? This will lose all fuel in the tank.")

    # Unstall action (delegated to StallBehavFrag)
    unstall_actions = get_actions(tank.stallstate)

    return (vent_action, unstall_actions...)
end

function do_action!(tank::TankBehavFrag, action_id::Symbol; kwargs...)
    if action_id === :vent_tank
        # stalls the tank to seal it
        stall!(tank)

        if tank.state.charge <= 0.0
            return (false, "Tank already empty")
        end
        tank.state.charge = 0.0
        return (true, "Tank vented")
    end
    # Delegate remaining actions to StallBehavFrag
    return do_action!(tank.stallstate, action_id)
end

function can_be_moved(tank::TankBehavFrag; kwargs...)
    # Tank can be moved if it's stalled or has no charge
    if is_stalled(tank) || tank.state.charge <= 0.0
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
# Stall delegations and click handling
is_stalled(behav::T) where {T <: AbstractTankBehavFrag} = is_stalled(behav.tank)
stall!(behav::T) where {T <: AbstractTankBehavFrag} = stall!(behav.tank)
unstall!(behav::T) where {T <: AbstractTankBehavFrag} = unstall!(behav.tank)
on_click!(behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = on_click!(behav.tank; kwargs...)
get_actions(behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = get_actions(behav.tank; kwargs...)
do_action!(behav::T, action_id::Symbol; kwargs...) where {T <: AbstractTankBehavFrag} = do_action!(behav.tank, action_id; kwargs...)
render_map_elem!(queue::Vector{<:RenderCommand}, behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = render_map_elem!(queue, behav.tank; kwargs...)
map_rotation(behav::T, rotation::HexAxis) where {T <: AbstractTankBehavFrag} = rotation # No rotation restriction by default
can_be_moved(behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = can_be_moved(behav.tank; kwargs...)

#= ---------- GasTankBehavFrag ----------- =#

"Gas tank with linear charge-voltage relationship"
struct GasTankBehavFrag <: AbstractTankBehavFrag
    tank::TankBehavFrag
end

function produce_rel_elements(behav::GasTankBehavFrag)::NTuple{1, RelativeElement}
    tank = behav.tank
    max_charge = tank.max_charge
    max_voltage = tank.max_voltage
    charge = tank.state.charge

    # Calculate voltage from charge
    capacitance = max_charge / max_voltage
    voltage = charge / capacitance
    if charge < 0.0 # Ramps more aggressively when charge is negative
        voltage = 10 * voltage
    end

    # Create element
    is_active = !is_stalled(tank)
    rel_element = RelativeElement(tank.connection, voltage, HexElements.CONST_VOLTAGE; active = is_active)
    return (rel_element,)
end

"""
Render gas tank fluid visualization.
Renders a black background fluidmask followed by the fluid-colored mask with transparency
proportional to fill fraction (more transparent when emptier).
"""
function render_fluid!(queue::Vector{<:RenderCommand}, behav::GasTankBehavFrag, fluidmask::Symbol, fluid::FluidTags, gameticks::Int; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0)
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
    max_charge = tank.max_charge
    max_voltage = tank.max_voltage
    charge = tank.state.charge

    # Pure behavior function
    f(x; steepness = 9.0) = 1 - (1 - x)^steepness

    # Scaled behavior
    voltage = 0.99 * max_voltage * f(2 * charge / max_charge)

    # Create element
    is_active = !is_stalled(tank)
    rel_element = RelativeElement(tank.connection, voltage, HexElements.CONST_VOLTAGE; active = is_active)
    return (rel_element,)
end

"""
Render liquid tank fluid visualization.
Renders the fluid-colored mask with horizontal clipping based on fill fraction,
always oriented horizontally (Q_POS) regardless of component rotation.
"""
function render_fluid!(queue::Vector{<:RenderCommand}, behav::LiquidTankBehavFrag, fluidmask::Symbol, fluid::FluidTags, gameticks::Int; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0)
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
    liquid_stallstate::StallBehavFrag
    gas_stallstate::StallBehavFrag
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
        liquid_stallstate::Union{Nothing, StallBehavFrag} = nothing,
    gas_stallstate::StallBehavFrag = StallBehavFrag()
    )
    max_liquid_charge_f = float(max_liquid_charge)
    max_gas_pressure_f = float(max_gas_pressure)
    initial_liquid_charge_f = float(initial_liquid_charge)
    initial_gas_charge_f = float(initial_gas_charge)
    liquid_stallstate_f = something(liquid_stallstate, StallBehavFrag())

    max_liquid_charge_f > 0.0 || throw(ArgumentError("max_liquid_charge must be positive"))
    max_gas_pressure_f > 0.0 || throw(ArgumentError("max_gas_pressure must be positive"))
    0.0 ≤ initial_liquid_charge_f ≤ max_liquid_charge_f || throw(
        ArgumentError(
            "initial_liquid_charge ($initial_liquid_charge_f) must be between 0.0 and max_liquid_charge ($max_liquid_charge_f)"
        )
    )

    if initial_liquid_charge_f ≥ max_liquid_charge_f
        stall!(liquid_stallstate_f)
    end

    return PressureFedTankBehavFrag(
        TankState(initial_liquid_charge_f),
        TankState(initial_gas_charge_f),
        liquid_stallstate_f,
        gas_stallstate,
        max_liquid_charge_f,
        max_gas_pressure_f,
        gas_node
    )
end

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
    liquid_active = !is_stalled(tank.liquid_stallstate)
    gas_active = !is_stalled(tank.gas_stallstate)

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
    liquid_stallstate = tank.liquid_stallstate
    gas_stallstate = tank.gas_stallstate
    if float_vals[3] >= float_vals[1]
        stall!(liquid_stallstate)
    end

    return PressureFedTankBehavFrag(
        initial_liquid_charge = float_vals[3],
        initial_gas_charge = float_vals[4],
        max_liquid_charge = float_vals[1],
        max_gas_pressure = float_vals[2],
        gas_node = tank.gas_node,
        liquid_stallstate = liquid_stallstate,
        gas_stallstate = gas_stallstate
    )
end

stall_liquid!(tank::PressureFedTankBehavFrag) = stall!(tank.liquid_stallstate)
stall_gas!(tank::PressureFedTankBehavFrag) = stall!(tank.gas_stallstate)

function update_flowbehav!(tank::PressureFedTankBehavFrag; tile::TileCoord, mna_state::MNA_State, kwargs...)
    liquid_element_id = ElementID(tile, pressfed_liquid_vsource_index)
    gas_element_id = ElementID(tile, pressfed_gas_vsource_index)

    liquid_present = haskey(mna_state.vsources, liquid_element_id)
    gas_present = haskey(mna_state.vsources, gas_element_id)
    if !liquid_present && !gas_present
        return nothing
    end

    # Stalled sides are sealed; ignore any stale current until update_map! drops their sources.
    liquid_current = liquid_present && !is_stalled(tank.liquid_stallstate) ? get(mna_state.vsource_currents, liquid_element_id, 0.0) : 0.0
    gas_current = gas_present && !is_stalled(tank.gas_stallstate) ? get(mna_state.vsource_currents, gas_element_id, 0.0) : 0.0

    liquid_delta = liquid_current / BASE_UPS
    gas_delta = gas_current / BASE_UPS
    prospective_liquid_charge = tank.liquid_state.charge + liquid_delta
    prospective_gas_charge = tank.gas_state.charge + gas_delta

    if prospective_liquid_charge < 0.0 || prospective_liquid_charge >= tank.max_liquid_charge
        stall_liquid!(tank)
        return nothing
    end

    tank.liquid_state.charge = prospective_liquid_charge

    if prospective_gas_charge < 0.0
        tank.gas_state.charge = 0.0
        stall_gas!(tank)
        return nothing
    end

    tank.gas_state.charge = prospective_gas_charge
    return nothing
end

function render_map_elem!(queue::Vector{<:RenderCommand}, tank::PressureFedTankBehavFrag; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    render_map_elem!(queue, tank.liquid_stallstate; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, render_height_offset = render_height_offset)
    render_map_elem!(queue, tank.gas_stallstate; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, render_height_offset = render_height_offset)
    return nothing
end

is_stalled(tank::PressureFedTankBehavFrag)::Bool = is_stalled(tank.liquid_stallstate) || is_stalled(tank.gas_stallstate)
stall!(tank::PressureFedTankBehavFrag) = (stall_liquid!(tank); stall_gas!(tank))
unstall!(tank::PressureFedTankBehavFrag) = (unstall!(tank.liquid_stallstate); unstall!(tank.gas_stallstate))

function on_click!(tank::PressureFedTankBehavFrag; kwargs...)
    unstall!(tank)
    return nothing
end

function get_actions(tank::PressureFedTankBehavFrag; kwargs...)
    gas_empty = tank.gas_state.charge ≈ 0.0
    vent_gas = ActionInfo(
        :vent_gas,
        "Vent Pressurising Gas",
        !gas_empty,
        gas_empty ? "No pressurising gas to vent" : "Release stored pressurising gas to space",
        gas_empty ? nothing : "Are you sure? The tank will lose all pressure until re-supplied."
    )

    liquid_empty = tank.liquid_state.charge ≈ 0.0
    vent_liquid = ActionInfo(
        :vent_liquid,
        "Vent Liquid Fuel",
        !liquid_empty,
        liquid_empty ? "No liquid fuel to vent" : "Release stored liquid fuel to space",
        liquid_empty ? nothing : "Are you sure? This will lose all liquid fuel in the tank."
    )

    stalled = is_stalled(tank)
    unstall_action = ActionInfo(:unstall, "Unstall Tank", stalled, stalled ? "Reactivate tank" : "Tank is not currently stalled")

    return (vent_gas, vent_liquid, unstall_action)
end

function do_action!(tank::PressureFedTankBehavFrag, action_id::Symbol; kwargs...)
    if action_id === :vent_gas
        if tank.gas_state.charge ≈ 0.0
            return (false, "No pressurising gas to vent")
        end

        stall!(tank)
        tank.gas_state.charge = 0.0
        return (true, "Pressurising gas vented")
    elseif action_id === :vent_liquid
        if tank.liquid_state.charge ≈ 0.0
            return (false, "No liquid fuel to vent")
        end

        stall!(tank)
        tank.liquid_state.charge = 0.0
        return (true, "Liquid fuel vented")
    elseif action_id === :unstall
        if is_stalled(tank)
            unstall!(tank)
            return (true, "Tank unstalled")
        else
            return (false, "Tank is not currently stalled")
        end
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
    fluid::FluidTags
end

"Keyword-based constructor for a Thevinin tank that supports N out nodes"
function ThevininTankCompBehav(
        ::Type{T}, connection_number::Integer;
        fluid::FluidTags,
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

function get_fluidtags(comp::ThevininTankCompBehav)
    return NodeFluidTags(; (Symbol(n) => comp.fluid for n in comp.out_nodes)...)
end

"Wet mass of a tank: charge x fluid density. Returns 0.0 if the requested fluid doesn't match this tank's fluid."
function get_component_wet_mass(comp::ThevininTankCompBehav; fluid::Union{FluidTags, Nothing} = nothing, kwargs...)
    if fluid !== nothing && fluid != comp.fluid
        return 0.0
    end
    density = lookup_fluid_density(comp.fluid)
    return density === nothing ? 0.0 : comp.tank.tank.state.charge * density
end

update_flowbehav!(comp::ThevininTankCompBehav; kwargs...) = update_flowbehav!(comp.tank; kwargs...)
on_click!(comp::ThevininTankCompBehav; kwargs...) = on_click!(comp.tank; kwargs...)
get_actions(comp::ThevininTankCompBehav; kwargs...) = get_actions(comp.tank; kwargs...)
do_action!(comp::ThevininTankCompBehav, action_id::Symbol; kwargs...) = do_action!(comp.tank, action_id; kwargs...)
is_stalled(comp::ThevininTankCompBehav) = is_stalled(comp.tank)
map_rotation(comp::ThevininTankCompBehav, rotation::HexAxis) = map_rotation(comp.tank, rotation)
can_be_moved(comp::ThevininTankCompBehav; kwargs...) = can_be_moved(comp.tank; kwargs...)

# Rendering traits
tanksprite(::ThevininTankCompBehav{GasTankBehavFrag, 3}) = :GasTank1_base
fluidmask(::ThevininTankCompBehav{GasTankBehavFrag, 3}) = :GasTank1_fluidmask
tanksprite(::ThevininTankCompBehav{LiquidTankBehavFrag, 3}) = :LiquidTank1_base
fluidmask(::ThevininTankCompBehav{LiquidTankBehavFrag, 3}) = :LiquidTank1_fluidmask

function render_base_elem!(queue::Vector{<:RenderCommand}, comp::ThevininTankCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, gameticks::Int64 = 0, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    # Render fluid
    render_fluid!(queue, comp.tank, fluidmask(comp), comp.fluid, gameticks; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, scale = scale, transparency = transparency, render_height_offset = render_height_offset)

    # Render tank base sprite (static)
    push!(queue, render_basic_tile(glmap, tanksprite(comp), rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset), pos_offset = pos_offset))
    return nothing
end

function render_map_elem!(queue::Vector{<:RenderCommand}, comp::ThevininTankCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, gameticks::Int64 = 0, render_height_offset::Integer = 0, kwargs...)
    render_base_elem!(queue, comp; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, gameticks = gameticks, render_height_offset = render_height_offset) # Render tank base
    render_map_elem!(queue, comp.tank; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, render_height_offset = render_height_offset) # Render tank stall overlay by delegating to the tank fragment's renderer (overlay)
    return nothing
end

#= ---------- PressureFedTankCompBehav ----------- =#

"Two-port pressure-fed tank with a liquid output and gas pressurisation input"
struct PressureFedTankCompBehav{N} <: ComponentBehavior
    tank::PressureFedTankBehavFrag
    liquid_nodes::NTuple{N, NodePos}
    series_conductance::Float64
    gas_fluid::FluidTags
    liquid_fluid::FluidTags
    rotation_behav::NoRotationBehavFrag
end

function PressureFedTankCompBehav(
        tank::PressureFedTankBehavFrag,
        liquid_nodes::NTuple{N, NodePos},
        series_conductance::Real,
        gas_fluid::FluidTags,
        liquid_fluid::FluidTags,
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
    liquid_active = !is_stalled(comp.tank.liquid_stallstate)
    resistors = ntuple(
        i -> RelativeElement(
            RelativeElementConnections(HexFrame.NODE_INTERNAL, comp.liquid_nodes[i]),
            comp.series_conductance,
            HexElements.CONST_RESISTOR;
            active = liquid_active
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

function get_fluidtags(comp::PressureFedTankCompBehav{N}) where {N}
    all_pairs = (
        Symbol(comp.tank.gas_node) => comp.gas_fluid,
        (Symbol(node) => comp.liquid_fluid for node in comp.liquid_nodes)...
    )
    return NodeFluidTags(; all_pairs...)
end

"Wet mass is the combined stored liquid and non-negative stored gas mass"
function get_component_wet_mass(comp::PressureFedTankCompBehav; fluid::Union{FluidTags, Nothing} = nothing, kwargs...)
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
on_click!(comp::PressureFedTankCompBehav; kwargs...) = on_click!(comp.tank; kwargs...)
get_actions(comp::PressureFedTankCompBehav; kwargs...) = get_actions(comp.tank; kwargs...)
do_action!(comp::PressureFedTankCompBehav, action_id::Symbol; kwargs...) = do_action!(comp.tank, action_id; kwargs...)
map_rotation(comp::PressureFedTankCompBehav, rotation::HexAxis) = map_rotation(comp.rotation_behav, rotation)
can_be_moved(comp::PressureFedTankCompBehav; kwargs...) = can_be_moved(comp.tank; kwargs...)

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
    return nothing
end

function render_map_elem!(queue::Vector{<:RenderCommand}, comp::PressureFedTankCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, gameticks::Int64 = 0, render_height_offset::Integer = 0, kwargs...)
    render_base_elem!(queue, comp; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, gameticks = gameticks, render_height_offset = render_height_offset)
    render_map_elem!(queue, comp.tank; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, render_height_offset = render_height_offset)
    return nothing
end

end # module HexFlowTankComponents
