module HexComponentsAPI

using HexFrame, HexElements, HexFluids
using StaticArrays, Accessors

# General Exports
export Sprite, Component, ComponentOnTile, TunableProps

# Tile Component Behavior Exports
export ComponentBehavior
export produce_rel_elements, produce_abs_elements
export get_tunables, set_tunables, render_base_elem!, render_map_elem!
export get_fluidtags, update_flowbehav!, on_click!, get_thrust, map_rotation, can_be_moved, placement_valid
export collect_effect_particles!

# Pipe Behavior Exports
export PipeBehavior
export get_conductance, get_pipe_tunables, set_pipe_tunables, render_pipe_base!, render_pipe_map!
export get_pipe_fluidtags, can_pipe_be_moved, get_tile_pipe_equivalent


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
    get_fluidtags(behav::T)::NodeFluidTags
    update_flowbehav!(behav::T; kwargs...)::Nothing
    on_click!(behav::T; kwargs...)::Nothing
    get_thrust(behav::T; kwargs...)::SVector{2, Float64}
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

"Struct to pass all needed info about a tunable component parameter to the properties panel"
struct TunableProps
    current_val::Float64
    type_desc::String
    unit_desc::String
end
"Error for concrete ComponentBehavior without required method get_tunables"
function get_tunables(behav::T) where {T <: ComponentBehavior}
    error("Required method get_tunables not implemented for $(nameof(T))")
end

"Error for concrete ComponentBehavior without required method set_tunables"
function set_tunables(behav::T, tunables::NTuple{N, Real}) where {N, T <: ComponentBehavior}
    error("Required method set_tunables not implemented for $(nameof(T))")
end

"Error for concrete ComponentBehavior without required method render_base_elem!"
function render_base_elem!(queue::AbstractVector, behav::T; kwargs...) where {T <: ComponentBehavior}
    error("Required method render_base_elem! not implemented for $(nameof(T))")
end


# Optional Method Defaults

"Default optional method: render_map_elem! forwards to render_base_elem!"
function render_map_elem!(queue::AbstractVector, behav::T; glmap, rotation, position, kwargs...) where {T}
    # Default map-level forwards to base render. Do not pass through extra kwargs;
    # base defaults (scale, transparency) will be used when base is called.
    return render_base_elem!(queue, behav; glmap = glmap, rotation = rotation, position = position)
end

"Default empty fluidtag for components not otherwise specified"
get_fluidtags(behav::T) where {T <: ComponentBehavior} = NodeFluidTags()

"Default update does nothing"
update_flowbehav!(behav::T; kwargs...) where {T <: ComponentBehavior} = nothing

"Default on_click does nothing"
on_click!(behav::T; kwargs...) where {T <: ComponentBehavior} = nothing

"Default thrust is zero vector for non-nozzles"
get_thrust(behav::T; kwargs...) where {T <: ComponentBehavior} = SVector{2, Float64}(0.0, 0.0)

"Default collect_effect_particles! does nothing (component produces no particles)"
collect_effect_particles!(manager, behav::T; kwargs...) where {T <: ComponentBehavior} = nothing

"Default map_rotation does not modify rotation"
map_rotation(behav::T, rotation::HexAxis) where {T <: ComponentBehavior} = rotation

"Default can_be_moved returns true with empty reason, indicating component can be moved"
can_be_moved(behav::T; kwargs...) where {T <: ComponentBehavior} = (true, "")

"""
Default implementation of placement_valid just errors.
Default behavior should be provided by FlowEngine with a concrete surface type GameMap.
"""
function placement_valid(behav::T, coord::TileCoord, surface; kwargs...) where {T <: ComponentBehavior}
    error("placement_valid should be called with GameMap as the surface argument; the method for that is implemented in FlowEngine")
end

# ===============================================================
# ComponentOnTile Wrapper
# ===============================================================
"""
A wrapper struct for a component that has been placed on the map.
Includes shared placement information, currently only the rotation.
All behavioural methods are delegated to the component.
"""
struct ComponentOnTile
    component::ComponentBehavior
    rotation::HexAxis
end

# ComponentBehavior Method Delegation
produce_rel_elements(comp::ComponentOnTile) = produce_rel_elements(comp.component)
get_tunables(comp::ComponentOnTile) = get_tunables(comp.component)
set_tunables(comp::ComponentOnTile, tunables::NTuple{N, Real}) where {N} = set_tunables(comp.component, tunables)
get_fluidtags(comp::ComponentOnTile) = get_fluidtags(comp.component)
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
map_rotation(comp::ComponentOnTile, rotation::HexAxis) = map_rotation(comp.component, rotation)
can_be_moved(comp::ComponentOnTile; kwargs...) = can_be_moved(comp.component; kwargs...)
placement_valid(comp::ComponentOnTile, coord, surface; kwargs...) = placement_valid(comp.component, coord, surface; rotation = comp.rotation, kwargs...)

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
    get_pipe_fluidtags(behav::T)::FluidTags
    can_pipe_be_moved(behav::T; kwargs...)::(Bool, String)
    produce_abs_elements(behav::T, edge::EdgeCoord)::NTuple{N, AbsoluteElement}
    get_tile_pipe_equivalent(behav::T)::Union{ComponentBehavior, Nothing}

"""
abstract type PipeBehavior end

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

"Default optional method: render_pipe_map! forwards to render_pipe_base!"
function render_pipe_map!(queue::AbstractVector, behav::T; glmap, rotation, position, kwargs...) where {T <: PipeBehavior}
    # Default map-level forwards to base render. Do not pass through extra kwargs;
    # base defaults (scale, transparency) will be used when base is called.
    return render_pipe_base!(queue, behav; glmap = glmap, rotation = rotation, position = position)
end

"Default empty fluidtag for pipes not otherwise specified"
get_pipe_fluidtags(behav::T) where {T <: PipeBehavior} = FluidTags()

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

"Default get_tile_pipe_equivalent returns nothing, indicating no tile equivalent"
get_tile_pipe_equivalent(behav::T) where {T <: PipeBehavior} = nothing

end # module HexComponents
