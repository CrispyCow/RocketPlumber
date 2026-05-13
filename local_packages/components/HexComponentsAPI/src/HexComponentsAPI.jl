module HexComponentsAPI

using HexFrame, HexElements, HexFluids
using StaticArrays, Accessors

# Simulation Constants
export BASE_UPS

# General Exports
export Sprite, Component, ComponentOnTile, PipeOnEdge, TunableProps, EnumTunableProps, AnyTunableProps, ActionInfo

# Tile Component Behavior Exports
export ComponentBehavior
export produce_rel_elements, produce_abs_elements, produce_rel_fluid_declarations
export get_tunables, set_tunables, render_base_elem!, render_map_elem!
export update_flowbehav!, on_click!, get_thrust, get_component_temperature, get_component_mass, map_rotation, can_be_moved, placement_valid
export get_component_dry_mass, get_component_wet_mass
export collect_effect_particles!
export get_actions, do_action!
export get_default_component_mass, set_default_component_mass!
export ReactivationProbe, get_reactivation_probe, accept_reactivation_probe!

# Pipe Behavior Exports
export PipeBehavior
export get_conductance, get_pipe_tunables, set_pipe_tunables, render_pipe_base!, render_pipe_map!
export can_pipe_be_moved, get_tile_pipe_equivalent_frag


# ===============================================================
# Simulation Constants
# ===============================================================

"Number of simulation ticks per simulation-second. All per-tick physics use this as their time base."
const BASE_UPS::Float64 = 60.0

# ===============================================================
# Component Behaviors
# ===============================================================
"""
A ComponentBehavior encapsulates all of a component's behaviour.
This includes its interaction with the flow engine, and its rendering.

A type that subtypes ComponentBehavior must implement all the mandatory functions listed,
and should implement the optional functions if the defaults are unsuitable.
These types have the suffix 'Behav'

A ComponentBehavior can also be built as a composite of other ComponentBehaviors,
with suitable method delegation or output combination applied.

If there is a common subset of functionality, a Behavior Fragment can be created.
This can have some of the required methods included which are relevant and not all.
These should be suffixed with 'BehavFrag', and should not subtype ComponentBehavior.
They can then be composed into a feature complete behaviour.

All concrete ComponentBehavior types T must implement the following 
MANDATORY METHODS:

    produce_rel_elements(behav::T)::NTuple{N, RelativeElement}
    get_tunables(behav::T)::NTuple{N, TunableProps}
    set_tunables(behav::T, tunables::NTuple{N, Real})::T
    render_base_elem!(queue::AbstractVector, behav::T; glmap, rotation, position, scale=1.0, transparency=1.0, render_height_offset::Integer=0, kwargs...)::Nothing

There are suitable defaults, but concrete ComponentBehavior types T can also implement the following 
OPTIONAL METHODS:

    render_map_elem!(queue::AbstractVector, behav::T; glmap, rotation, position, kwargs...)::Nothing
    produce_rel_fluid_declarations(behav::T)::Tuple
    update_flowbehav!(behav::T; kwargs...)::Nothing
    on_click!(behav::T; kwargs...)::Nothing
    get_thrust(behav::T; kwargs...)::SVector{2, Float64}
    get_component_temperature(behav::T; kwargs...)::Union{Nothing, Float64}
    get_component_mass(behav::T; kwargs...)::Float64
    collect_effect_particles!(manager, behav::T; kwargs...)::Nothing
    map_rotation(behav::T, rotation::HexAxis)::HexAxis
    can_be_moved(behav::T; kwargs...)::(Bool, String)
    placement_valid(behav::T, coord::TileCoord, surface; rotation::HexAxis, kwargs...)::(Bool, String)
    
"""
abstract type ComponentBehavior end

# Mandatory Methods Errors

"Error for concrete ComponentBehavior without required method produce_rel_elements"
function produce_rel_elements(behav::T) where {T <: ComponentBehavior}
    error("Required method produce_rel_elements not implemented for $(nameof(T))")
end

"Describes a single action that a component can perform, for display in a popup UI."
struct ActionInfo
    id::Symbol                                  # Unique identifier for this action on this component
    label::String                               # Button text displayed in the UI
    enabled::Bool                               # Whether the action button is currently clickable
    tooltip::String                             # Hover text — explains the action or why it's disabled
    confirmation_message::Union{Nothing, String} # If set, show a confirmation pane before executing
end

"Convenience constructor preserving the existing 4-arg call sites."
ActionInfo(id, label, enabled, tooltip) = ActionInfo(id, label, enabled, tooltip, nothing)

"Tunable descriptor for a scalar (Float64) component parameter."
struct TunableProps
    current_val::Float64
    type_desc::String
    unit_desc::String
end

"""
Tunable descriptor for an enum-backed component parameter.
The UI presents the options as a combo/listbox and returns the selected `T` value via `set_tunables`.
"""
struct EnumTunableProps{T}
    current_val::T
    options::Vector{T}
    option_labels::Vector{String}
    type_desc::String
end

"Union of all tunable property descriptor types. Used for heterogeneous tunable tuples."
const AnyTunableProps = Union{TunableProps, EnumTunableProps}

"Error for concrete ComponentBehavior without required method get_tunables"
function get_tunables(behav::T) where {T <: ComponentBehavior}
    error("Required method get_tunables not implemented for $(nameof(T))")
end

"Error for concrete ComponentBehavior without required method set_tunables"
function set_tunables(behav::T, tunables::Tuple) where {T <: ComponentBehavior}
    error("Required method set_tunables not implemented for $(nameof(T))")
end

"Error for concrete ComponentBehavior without required method render_base_elem! The kwarg `pos_offset` may be any coordinate acceptable to `glvec()` or `nothing` to indicate no offset."
function render_base_elem!(queue::AbstractVector, behav::T; glmap, rotation, position, pos_offset = nothing, scale=1.0, transparency=1.0, render_height_offset::Integer=0, kwargs...) where {T <: ComponentBehavior}
    error("Required method render_base_elem! not implemented for $(nameof(T))")
end


# Optional Method Defaults

"Default optional method: render_map_elem! forwards to render_base_elem! The kwarg `pos_offset` may be any coordinate acceptable to `glvec()` or `nothing` to indicate no offset."
function render_map_elem!(queue::AbstractVector, behav::T; glmap, rotation, position, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...) where {T}
    # Default map-level forwards visual offset and height to base render (avoid leaking unrelated kwargs)
    return render_base_elem!(queue, behav; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, render_height_offset = render_height_offset)
end

"Default produce_rel_fluid_declarations returns empty tuple (no fluid declarations)"
produce_rel_fluid_declarations(behav::T) where {T <: ComponentBehavior} = ()

"Default update does nothing"
update_flowbehav!(behav::T; kwargs...) where {T <: ComponentBehavior} = nothing

"Default on_click does nothing"
on_click!(behav::T; kwargs...) where {T <: ComponentBehavior} = nothing

"Default thrust is zero vector for non-nozzles"
get_thrust(behav::T; kwargs...) where {T <: ComponentBehavior} = SVector{2, Float64}(0.0, 0.0)

"Default component temperature is `nothing`, meaning the component does not expose a component-local temperature."
get_component_temperature(behav::T; kwargs...) where {T <: ComponentBehavior} = nothing

const _default_component_mass = Threads.Atomic{Float64}(20.0)
"Get the default mass assigned to components that don't override `get_component_mass`."
get_default_component_mass()::Float64 = _default_component_mass[]
"Set the default mass assigned to components that don't override `get_component_mass`."
function set_default_component_mass!(value::Float64)
    _default_component_mass[] = value
    return nothing
end

"Dry (structural) mass of a component, excluding any stored fluid. Defaults to the tunable default component mass."
get_component_dry_mass(behav::T; kwargs...) where {T <: ComponentBehavior} = get_default_component_mass()

"Mass of fluid stored in a component. If `fluid` is `nothing`, returns total fluid mass; if a specific FluidType, returns mass of only that fluid. Defaults to 0.0 (no stored fluid)."
get_component_wet_mass(behav::T; fluid::Union{FluidType, Nothing} = nothing, kwargs...) where {T <: ComponentBehavior} = 0.0

"Total mass of a component (dry + wet). Override `get_component_dry_mass` and/or `get_component_wet_mass` rather than this."
get_component_mass(behav::T; kwargs...) where {T <: ComponentBehavior} = get_component_dry_mass(behav) + get_component_wet_mass(behav)

"Default get_actions returns an empty tuple, component has no actions."
get_actions(behav::T; kwargs...) where {T <: ComponentBehavior} = ()

"Default do_action! returns failure, action not implemented for this component type."
function do_action!(behav::T, action_id::Symbol; kwargs...) where {T <: ComponentBehavior}
    return (false, "Action :$(action_id) not implemented for $(nameof(T))")
end

"Default collect_effect_particles! does nothing (component produces no particles)"
collect_effect_particles!(manager, behav::T; kwargs...) where {T <: ComponentBehavior} = nothing

"Default map_rotation does not modify rotation"
map_rotation(behav::T, rotation::HexAxis) where {T <: ComponentBehavior} = rotation

"Default can_be_moved returns true with empty reason, indicating component can be moved"
can_be_moved(behav::T; kwargs...) where {T <: ComponentBehavior} = (true, "")

"""
Default implementation of placement_valid just errors.
Default behaviour should be provided by FlowMap with a concrete surface type GameMap.
"""
function placement_valid(behav::T, coord::TileCoord, surface; kwargs...) where {T <: ComponentBehavior}
    error("placement_valid should be called with GameMap as the surface argument; the method for that is implemented in FlowMap")
end

"A lightweight probe used by the speculative reactivation scheduler"
struct ReactivationProbe{E <: Tuple, D <: Tuple}
    rel_elements::E
    rel_fluid_declarations::D
end

"Convenience constructor for probes that carry only circuit elements."
ReactivationProbe(rel_elements::Tuple) = ReactivationProbe(rel_elements, ())

"""
Return a `ReactivationProbe` describing the speculative inputs to test for this component,
or `nothing` if the component has no pending reactivation request this tick.

Returning a non-`nothing` probe signals to the calculator scheduler that this component
wishes to test whether it can be safely reactivated. The scheduler will run a speculative
solve with the probe's elements appended and then call `accept_reactivation_probe!`.
"""
get_reactivation_probe(behav::T; kwargs...) where {T <: ComponentBehavior} = nothing

"""
Called after a speculative solve completed without errors, using this component's probe inputs.

Should return `true` only if the speculative solve state indicates the reactivation is safe.
May mutate the component on success. Must leave the component unchanged when returning `false`.
"""
accept_reactivation_probe!(behav::T; kwargs...) where {T <: ComponentBehavior} = false

# ===============================================================
# ComponentOnTile Wrapper
# ===============================================================
"""
A wrapper struct for a component that has been placed on the map.
Includes shared placement information: the placed rotation and the owning `ship` tag.
`ship` records which ship in a unified `GameMap` owns the component.
All behavioural methods are delegated to the component.
"""
struct ComponentOnTile{T <: ComponentBehavior}
    component::T
    rotation::HexAxis
    ship::Symbol
end

# ComponentBehavior Method Delegation
produce_rel_elements(comp::ComponentOnTile) = produce_rel_elements(comp.component)
produce_rel_fluid_declarations(comp::ComponentOnTile) = produce_rel_fluid_declarations(comp.component)
get_tunables(comp::ComponentOnTile) = get_tunables(comp.component)
set_tunables(comp::ComponentOnTile, tunables::NTuple{N, Real}) where {N} = set_tunables(comp.component, tunables)
render_map_elem!(queue::AbstractVector, comp::ComponentOnTile; kwargs...) = render_map_elem!(queue, comp.component; rotation = comp.rotation, kwargs...)
render_base_elem!(queue::AbstractVector, comp::ComponentOnTile; kwargs...) = render_base_elem!(queue, comp.component; rotation = comp.rotation, kwargs...)
collect_effect_particles!(manager, comp::ComponentOnTile; kwargs...) = collect_effect_particles!(manager, comp.component; rotation = comp.rotation, kwargs...)
update_flowbehav!(comp::ComponentOnTile; kwargs...) = update_flowbehav!(comp.component; rotation = comp.rotation, kwargs...)
function on_click!(comp::ComponentOnTile; unrotated_clicksite = nothing, kwargs...)
    if unrotated_clicksite !== nothing
        relative_clicksite = hex_rotmats[comp.rotation] * unrotated_clicksite # Transform to tile's local coordinate system
        on_click!(comp.component; relative_clicksite = relative_clicksite, kwargs...) # Forward with the rotated click site
    else
        on_click!(comp.component; kwargs...) # No click site info, just forward everything
    end
    return nothing
end
get_thrust(comp::ComponentOnTile; kwargs...) = get_thrust(comp.component; rotation = comp.rotation, kwargs...)
get_component_temperature(comp::ComponentOnTile; kwargs...) = get_component_temperature(comp.component; kwargs...)
get_component_mass(comp::ComponentOnTile; kwargs...) = get_component_mass(comp.component; kwargs...)
get_component_dry_mass(comp::ComponentOnTile; kwargs...) = get_component_dry_mass(comp.component; kwargs...)
get_component_wet_mass(comp::ComponentOnTile; kwargs...) = get_component_wet_mass(comp.component; kwargs...)
map_rotation(comp::ComponentOnTile, rotation::HexAxis) = map_rotation(comp.component, rotation)
can_be_moved(comp::ComponentOnTile; kwargs...) = can_be_moved(comp.component; kwargs...)
placement_valid(comp::ComponentOnTile, coord, surface; kwargs...) = placement_valid(comp.component, coord, surface; rotation = comp.rotation, kwargs...)
get_actions(comp::ComponentOnTile; kwargs...) = get_actions(comp.component; kwargs...)
do_action!(comp::ComponentOnTile, action_id::Symbol; kwargs...) = do_action!(comp.component, action_id; kwargs...)
get_reactivation_probe(comp::ComponentOnTile; kwargs...) = get_reactivation_probe(comp.component; rotation = comp.rotation, kwargs...)
accept_reactivation_probe!(comp::ComponentOnTile; kwargs...) = accept_reactivation_probe!(comp.component; rotation = comp.rotation, kwargs...)

"General implementation which leverages the existing ComponentBehavior produce_rel_elements function"
function produce_abs_elements(tilecomp::ComponentOnTile, tile::TileCoord)
    rel_elements = produce_rel_elements(tilecomp.component)
    # Maps AbsoluteElement from each RelativeElement in the Component
    # Returns an NTuple to preserve previous API: handles variable-length tuples including zero-length
    return ntuple(i -> map_element(rel_elements[i], tile, i, tilecomp.rotation), length(rel_elements))
end

# ===============================================================
# Pipe Behaviors
# ===============================================================
"""
A PipeBehavior encapsulates all of a pipe's behaviour on edges.
This includes its interaction with the flow engine, and its rendering.

A type that subtypes PipeBehavior must implement all the mandatory functions listed,
and should implement the optional functions if the defaults are unsuitable.
These types have the suffix 'PipeBehav'

A PipeBehavior can also be built as a composite of other PipeBehaviors,
with suitable method delegation or output combination applied.

If there is a common subset of functionality, a Pipe Behavior Fragment can be created.
This can have some of the required methods included which are relevant and not all.
These should be suffixed with 'PipeBehavFrag', and should not subtype PipeBehavior.
They can then be composed into a feature complete behaviour.

All concrete PipeBehavior types T must implement the following 
MANDATORY METHODS:

    get_conductance(behav::T)::Float64
    get_pipe_tunables(behav::T)::NTuple{N, TunableProps}
    set_pipe_tunables(behav::T, tunables::NTuple{N, Real})::T
    render_pipe_base!(queue::AbstractVector, behav::T; glmap, rotation, position, scale=1.0, transparency=1.0, render_height_offset::Integer=0, kwargs...)::Nothing
    

There are suitable defaults, but concrete PipeBehavior types T can also implement the following 
OPTIONAL METHODS:

    render_pipe_map!(queue::AbstractVector, behav::T; glmap, rotation, position, kwargs...)::Nothing
    can_pipe_be_moved(behav::T; kwargs...)::(Bool, String)
    produce_abs_elements(behav::T, edge::EdgeCoord)::NTuple{N, AbsoluteElement}
    get_tile_pipe_equivalent_frag(behav::T)::Union{TilePipeFrag, Nothing}

"""
abstract type PipeBehavior end

# ===============================================================
# PipeOnEdge Wrapper
# ===============================================================

"""
A `PipeBehavior` placed on the map. Carries the owning ship's `Symbol` tag.
All behavioural methods delegate to the inner pipe.
"""
struct PipeOnEdge{T <: PipeBehavior}
    pipe::T
    ship::Symbol
end

get_conductance(p::PipeOnEdge) = get_conductance(p.pipe)
get_pipe_tunables(p::PipeOnEdge) = get_pipe_tunables(p.pipe)
"Return a new `PipeOnEdge` with updated tunables; preserves the ship tag."
set_pipe_tunables(p::PipeOnEdge, tunables::NTuple{N, Real}) where {N} =
    PipeOnEdge(set_pipe_tunables(p.pipe, tunables), p.ship)
render_pipe_base!(queue, p::PipeOnEdge; kwargs...) = render_pipe_base!(queue, p.pipe; kwargs...)
render_pipe_map!(queue, p::PipeOnEdge; kwargs...) = render_pipe_map!(queue, p.pipe; kwargs...)
can_pipe_be_moved(p::PipeOnEdge; kwargs...) = can_pipe_be_moved(p.pipe; kwargs...)
produce_abs_elements(p::PipeOnEdge, edge::EdgeCoord) = produce_abs_elements(p.pipe, edge)
produce_rel_fluid_declarations(p::PipeOnEdge) = produce_rel_fluid_declarations(p.pipe)
get_tile_pipe_equivalent_frag(p::PipeOnEdge) = get_tile_pipe_equivalent_frag(p.pipe)

# Mandatory Methods Errors

"Error for concrete PipeBehavior without required method get_conductance"
function get_conductance(behav::T) where {T <: PipeBehavior}
    error("Required method get_conductance not implemented for $(nameof(T))")
end

"Error for concrete PipeBehavior without required method get_pipe_tunables"
function get_pipe_tunables(behav::T) where {T <: PipeBehavior}
    error("Required method get_pipe_tunables not implemented for $(nameof(T))")
end

"Error for concrete PipeBehavior without required method set_pipe_tunables"
function set_pipe_tunables(behav::T, tunables::NTuple{N, Real}) where {N, T <: PipeBehavior}
    error("Required method set_pipe_tunables not implemented for $(nameof(T))")
end

"Error for concrete PipeBehavior without required method render_pipe_base!"
function render_pipe_base!(queue::AbstractVector, behav::T; kwargs...) where {T <: PipeBehavior}
    error("Required method render_pipe_base! not implemented for $(nameof(T))")
end

# Optional Method Defaults

"Default optional method: render_pipe_map! forwards to render_pipe_base! The kwarg `pos_offset` may be any coordinate acceptable to `glvec()` or `nothing` to indicate no offset."
function render_pipe_map!(queue::AbstractVector, behav::T; glmap, rotation, position, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...) where {T <: PipeBehavior}
    # Default map-level forwards visual offset and height to base render (avoid leaking unrelated kwargs)
    return render_pipe_base!(queue, behav; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, render_height_offset = render_height_offset)
end

"Default can_pipe_be_moved returns true with empty reason, indicating pipe can be moved"
can_pipe_be_moved(behav::T; kwargs...) where {T <: PipeBehavior} = (true, "")

"Default produce_abs_elements creates a resistor element from conductance"
function produce_abs_elements(behav::T, edge::EdgeCoord) where {T <: PipeBehavior}
    connections = AbsoluteElementConnections(to_nodecoord(edge.v1), to_nodecoord(edge.v2))
    conductance = get_conductance(behav)
    absolute_element = AbsoluteElement(connections, conductance, HexElements.CONST_RESISTOR, ElementID(edge))
    return (absolute_element,)
end

"Convenience wrapper allowing set_tunables to be called on PipeBehavior"
set_tunables(behav::T, tunables::NTuple{N, Real}) where {N, T <: PipeBehavior} = set_pipe_tunables(behav, tunables)

"Default get_tile_pipe_equivalent_frag returns nothing, indicating no tile fragment equivalent"
get_tile_pipe_equivalent_frag(behav::T) where {T <: PipeBehavior} = nothing

end # module HexComponentsAPI
