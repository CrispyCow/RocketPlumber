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
import HexComponentsAPI: get_fluidtags, update_flowbehav!, on_click!, render_map_elem!, map_rotation, can_be_moved
# Behavior Fragment Dependencies
import HexFlowBasicComponents: stall!, unstall!, is_stalled, StallBehavFrag

# Concrete Component Behavior Exports
export ThevininTankCompBehav, GasTankBehavFrag, LiquidTankBehavFrag

const target_UPS::Float64 = 60.0

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
    delta = current / target_UPS
    prospective_charge = tank.state.charge + delta

    if prospective_charge < 0.0
        stall!(tank.stallstate) # Going negative -> stall the tank and skip the update
        return
    end

    return tank.state.charge = prospective_charge
end

function render_map_elem!(queue::Vector{RenderCommand}, tank::TankBehavFrag; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    render_map_elem!(queue, tank.stallstate; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, render_height_offset = render_height_offset) # Render stall overlay if present (delegates to StallBehavFrag renderer)
    return nothing
end

is_stalled(tank::TankBehavFrag)::Bool = is_stalled(tank.stallstate)
stall!(tank::TankBehavFrag) = stall!(tank.stallstate)
unstall!(tank::TankBehavFrag) = unstall!(tank.stallstate)

function on_click!(tank::TankBehavFrag; kwargs...)
    unstall!(tank) # Clicking the tank un-stalls it
    return nothing
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
render_map_elem!(queue::Vector{RenderCommand}, behav::T; kwargs...) where {T <: AbstractTankBehavFrag} = render_map_elem!(queue, behav.tank; kwargs...)
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
function render_fluid!(queue::Vector{RenderCommand}, behav::GasTankBehavFrag, fluidmask::Symbol, fluid::FluidTags, gameticks::Int; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0)
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
function render_fluid!(queue::Vector{RenderCommand}, behav::LiquidTankBehavFrag, fluidmask::Symbol, fluid::FluidTags, gameticks::Int; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0)
    colour = get_fluid_colour(fluid)
    fill_frac = behav.tank.state.charge / behav.tank.max_charge
    fixed_rotation = HexFrame.Q_POS # Force horizontal for fluid rendering
    return push!(queue, render_liquid_tile(glmap, fluidmask, fixed_rotation, position, gameticks; scale = scale, transparency = transparency, colour = colour, x_unclipped = fill_frac, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset), pos_offset = pos_offset))
end

map_rotation(behav::LiquidTankBehavFrag, rotation::HexAxis) = map_rotation(behav.rotation_behav, rotation)

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

update_flowbehav!(comp::ThevininTankCompBehav; kwargs...) = update_flowbehav!(comp.tank; kwargs...)
on_click!(comp::ThevininTankCompBehav; kwargs...) = on_click!(comp.tank; kwargs...)
is_stalled(comp::ThevininTankCompBehav) = is_stalled(comp.tank)
map_rotation(comp::ThevininTankCompBehav, rotation::HexAxis) = map_rotation(comp.tank, rotation)
can_be_moved(comp::ThevininTankCompBehav; kwargs...) = can_be_moved(comp.tank; kwargs...)

# Rendering traits
tanksprite(::ThevininTankCompBehav{GasTankBehavFrag, 3}) = :GasTank1_base
fluidmask(::ThevininTankCompBehav{GasTankBehavFrag, 3}) = :GasTank1_fluidmask
tanksprite(::ThevininTankCompBehav{LiquidTankBehavFrag, 3}) = :LiquidTank1_base
fluidmask(::ThevininTankCompBehav{LiquidTankBehavFrag, 3}) = :LiquidTank1_fluidmask

function render_base_elem!(queue::Vector{RenderCommand}, comp::ThevininTankCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, gameticks::Int64 = 0, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, kwargs...)
    # Render fluid
    render_fluid!(queue, comp.tank, fluidmask(comp), comp.fluid, gameticks; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, scale = scale, transparency = transparency, render_height_offset = render_height_offset)

    # Render tank base sprite (static)
    push!(queue, render_basic_tile(glmap, tanksprite(comp), rotation, position; scale = scale, transparency = transparency, draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset), pos_offset = pos_offset))
    return nothing
end

function render_map_elem!(queue::Vector{RenderCommand}, comp::ThevininTankCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, gameticks::Int64 = 0, render_height_offset::Integer = 0, kwargs...)
    render_base_elem!(queue, comp; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, gameticks = gameticks, render_height_offset = render_height_offset) # Render tank base
    render_map_elem!(queue, comp.tank; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, render_height_offset = render_height_offset) # Render tank stall overlay by delegating to the tank fragment's renderer (overlay)
    return nothing
end

end # module HexFlowTankComponents
