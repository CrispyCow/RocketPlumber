#=
Scope: Shared component and pipe behaviour interfaces, request results, and placed wrappers
Formatter: Runic
=#
"""
Shared interfaces for component and pipe behaviours.

This module defines behaviour contracts and defaults, request results, placed
component and pipe wrappers, and reactivation probe hooks for the component
packages.
"""
module HexComponentsAPI

using StaticArrays
using HexElements, HexFluids, HexFrame

# Simulation Constant Exports
export BASE_UPS

# Shared Type Exports
export Sprite, Component, PlacedComponent, PlacedPipe, TunableProps, EnumTunableProps, AnyTunableProps, ActionInfo

# Request Result Exports
export ValidRequest, ValidRequestResult, InvalidRequest, RequestStatus, RequestResult, ExpectedMapValidationError
export isvalidrequest, unwrap, reason

# Component Behaviour Exports
export ComponentBehavior
export produce_rel_elements, produce_abs_elements, produce_rel_fluid_declarations
export get_tunables, set_tunables, render_base_elem!, render_map_elem!
export update_flowbehav!, on_click!, get_thrust, get_component_temperature, get_component_mass, map_rotation, map_mirroring, can_be_moved, placement_valid
export get_component_dry_mass, get_component_wet_mass
export collect_effect_particles!
export get_actions, do_action!
export get_default_component_mass, set_default_component_mass!

# Reactivation Probe Exports
export ReactivationProbe, ReactivationProbeOutcome, PROBE_HARMFUL, PROBE_NEUTRAL, PROBE_USEFUL
export get_reactivation_probe, classify_reactivation_probe, commit_reactivation_probe!

# Pipe Behaviour Exports
export PipeBehavior
export get_conductance, get_pipe_tunables, set_pipe_tunables, render_pipe_base!, render_pipe_map!
export get_pipe_click_radius, can_pipe_be_moved


# ===============================================================
# Simulation Constants
# ===============================================================

"Number of simulation ticks per simulation-second. All per-tick physics use this as their time base."
const BASE_UPS::Float64 = 60.0

# ===============================================================
# Request Result Types
# ===============================================================

"""
Base type for expected domain validation failures caused by supported player map edits.

Concrete subtypes must provide player-suitable `showerror` output. When one
escapes candidate map validation, the edit is rejected and rolled back without
warning-level diagnostics.
"""
abstract type ExpectedMapValidationError <: Exception end

"A successful request that does not produce a result value."
struct ValidRequest end

"A successful request carrying a result value of type `T`."
struct ValidRequestResult{T}
    result::T
end

"A rejected request with a player-facing explanation."
struct InvalidRequest
    reason::String
end

"Construct an invalid request from any string-like value."
InvalidRequest(reason::AbstractString) = InvalidRequest(String(reason))

"Union of request outcomes that do not carry a result value."
const RequestStatus = Union{ValidRequest, InvalidRequest}

"Union of a successful result carrying `T` and an invalid request."
const RequestResult{T} = Union{ValidRequestResult{T}, InvalidRequest}

"Return whether a request completed successfully."
isvalidrequest(::ValidRequest) = true
isvalidrequest(::ValidRequestResult) = true
isvalidrequest(::InvalidRequest) = false

"Return the value carried by a successful request result."
unwrap(request::ValidRequestResult) = request.result
unwrap(request::InvalidRequest) = throw(ArgumentError("cannot unwrap an invalid request: $(request.reason)"))

"Return the failure reason from an invalid request."
reason(request::InvalidRequest) = request.reason
reason(::ValidRequest) = throw(ArgumentError("a valid request has no failure reason"))
reason(::ValidRequestResult) = throw(ArgumentError("a valid request has no failure reason"))

# ===============================================================
# Component Behaviour Interface
# ===============================================================
"""
A ComponentBehavior encapsulates all of a component's behaviour.
This includes its interaction with the flow engine, and its rendering.

A type that subtypes ComponentBehavior must implement all the mandatory functions listed,
and should implement the optional functions if the defaults are unsuitable.
These types have the suffix 'Behav'

A ComponentBehavior can also be built as a composite of other ComponentBehaviors,
with suitable method delegation or output combination applied.

If there is a common subset of functionality, a Behaviour Fragment can be created.
This can have some of the required methods included which are relevant and not all.
These should be suffixed with 'BehavFrag', and should not subtype ComponentBehavior.
They can then be composed into a feature complete behaviour.

All concrete ComponentBehavior types T must implement the following
MANDATORY METHODS:

    produce_rel_elements(behav::T)::NTuple{N, RelativeElement}
    get_tunables(behav::T)::NTuple{N, TunableProps}
    set_tunables(behav::T, tunables::NTuple{N, Real})::T
    render_base_elem!(queue::AbstractVector, behav::T; glmap, rotation, position, pos_offset = nothing, scale = 1.0, transparency = 1.0, render_height_offset::Integer = 0, kwargs...)::Nothing

There are suitable defaults, but concrete ComponentBehavior types T can also implement the following
OPTIONAL METHODS:

    render_map_elem!(queue::AbstractVector, behav::T; glmap, rotation, position, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)::Nothing
    produce_rel_fluid_declarations(behav::T)::Tuple
    update_flowbehav!(behav::T; kwargs...)::Nothing
    on_click!(behav::T; kwargs...)::Nothing
    get_thrust(behav::T; kwargs...)::SVector{2, Float64}
    get_component_temperature(behav::T; kwargs...)::Union{Nothing, Float64}
    get_component_dry_mass(behav::T; kwargs...)::Float64
    get_component_wet_mass(behav::T; fluid::Union{FluidType, Nothing} = nothing, kwargs...)::Float64
    get_component_mass(behav::T; kwargs...)::Float64
    get_actions(behav::T; kwargs...)
    collect_effect_particles!(manager, behav::T; kwargs...)::Nothing
    map_rotation(behav::T, rotation::HexAxis)::HexAxis
    map_mirroring(behav::T, mirrored::Bool)::Bool
    can_be_moved(behav::T; kwargs...)::RequestStatus
    placement_valid(behav::T, coord::TileCoord, surface; rotation::HexAxis, kwargs...)::RequestStatus
    do_action!(behav::T, action_id::Symbol; kwargs...)::RequestResult{String}
    get_reactivation_probe(behav::T; kwargs...)::Union{Nothing, ReactivationProbe}
    classify_reactivation_probe(behav::T; kwargs...)::ReactivationProbeOutcome
    commit_reactivation_probe!(behav::T; kwargs...)::Nothing

"""
abstract type ComponentBehavior end

#= ---------- Actions and tunables ----------- =#

"""
Describes a component action.

`enabled` and `group_enabled` control whether an action is possible and are optionally settable separately,
to allow you to have a behaviour disabled individually without blocking group actions.
A non-nothing `confirmation_message` is shown in a confirmation window before the action executes.
"""
@kwdef struct ActionInfo
    id::Symbol                                  # Unique identifier for this action on this component
    label::String                               # Button text displayed in the UI
    enabled::Bool                               # Whether the action is meaningful for an individual component
    group_enabled::Bool = enabled               # Whether the component permits the action in a group
    tooltip::String                             # Hover text — explains the action or why it's disabled
    confirmation_message::Union{Nothing, String} = nothing # If set, show a confirmation pane before executing
end

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

#= ---------- Mandatory interface stubs ----------- =#

"Error for concrete ComponentBehavior without required method produce_rel_elements"
function produce_rel_elements(behav::T) where {T <: ComponentBehavior}
    error("Required method produce_rel_elements not implemented for $(nameof(T))")
end

"Error for concrete ComponentBehavior without required method get_tunables"
function get_tunables(behav::T) where {T <: ComponentBehavior}
    error("Required method get_tunables not implemented for $(nameof(T))")
end

"Error for concrete ComponentBehavior without required method set_tunables"
function set_tunables(behav::T, tunables::Tuple) where {T <: ComponentBehavior}
    error("Required method set_tunables not implemented for $(nameof(T))")
end

"Error for concrete ComponentBehavior without required method render_base_elem! The kwarg `pos_offset` may be any coordinate acceptable to `glvec()` or `nothing` to indicate no offset."
function render_base_elem!(queue::AbstractVector, behav::T; glmap, rotation, position, pos_offset = nothing, scale = 1.0, transparency = 1.0, render_height_offset::Integer = 0, kwargs...) where {T <: ComponentBehavior}
    error("Required method render_base_elem! not implemented for $(nameof(T))")
end

#= ---------- Optional defaults ----------- =#

"Default optional method: render_map_elem! forwards to render_base_elem! The kwarg `pos_offset` may be any coordinate acceptable to `glvec()` or `nothing` to indicate no offset."
function render_map_elem!(queue::AbstractVector, behav::ComponentBehavior; glmap, rotation, position, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    # Forward visual offset and height without leaking unrelated keywords
    return render_base_elem!(queue, behav; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, render_height_offset = render_height_offset)
end

"Default `produce_rel_fluid_declarations` returns an empty tuple (no fluid declarations)."
produce_rel_fluid_declarations(behav::ComponentBehavior) = ()

"Default `update_flowbehav!` does nothing."
update_flowbehav!(behav::ComponentBehavior; kwargs...) = nothing

"Default `on_click!` does nothing."
on_click!(behav::ComponentBehavior; kwargs...) = nothing

"Default thrust is a zero vector for non-nozzles."
get_thrust(behav::ComponentBehavior; kwargs...) = SVector{2, Float64}(0.0, 0.0)

"Default component temperature is `nothing`, meaning the component does not expose a component-local temperature."
get_component_temperature(behav::ComponentBehavior; kwargs...) = nothing

#= ---------- Mass hooks ----------- =#

const _default_component_mass = Threads.Atomic{Float64}(20.0)
"Get the default mass assigned to components that don't override `get_component_mass`."
get_default_component_mass()::Float64 = _default_component_mass[]
"Set the default mass assigned to components that don't override `get_component_mass`."
function set_default_component_mass!(value::Float64)
    _default_component_mass[] = value
    return nothing
end

"Dry (structural) mass of a component, excluding any stored fluid. Defaults to the tunable default component mass."
get_component_dry_mass(behav::ComponentBehavior; kwargs...) = get_default_component_mass()

"Mass of fluid stored in a component. If `fluid` is `nothing`, returns total fluid mass; if a specific FluidType, returns mass of only that fluid. Defaults to 0.0 (no stored fluid)."
get_component_wet_mass(behav::ComponentBehavior; fluid::Union{FluidType, Nothing} = nothing, kwargs...) = 0.0

"Total mass of a component (dry + wet). Override `get_component_dry_mass` and/or `get_component_wet_mass` rather than this."
get_component_mass(behav::ComponentBehavior; kwargs...) = get_component_dry_mass(behav) + get_component_wet_mass(behav)

"Default `get_actions` returns an empty tuple; the component has no actions."
get_actions(behav::ComponentBehavior; kwargs...) = ()

"Default do_action! rejects unsupported action IDs as programming errors."
function do_action!(behav::T, action_id::Symbol; kwargs...) where {T <: ComponentBehavior}
    throw(ArgumentError("Action :$(action_id) not implemented for $(nameof(T))"))
end

"Default `collect_effect_particles!` does nothing (the component produces no particles)."
collect_effect_particles!(manager, behav::ComponentBehavior; kwargs...) = nothing

"Default `map_rotation` does not modify rotation."
map_rotation(behav::ComponentBehavior, rotation::HexAxis) = rotation

"Default map_mirroring opts components out of functional mirroring."
map_mirroring(behav::ComponentBehavior, mirrored::Bool) = false

"Default can_be_moved returns a valid request, indicating the component can be moved."
can_be_moved(behav::ComponentBehavior; kwargs...) = ValidRequest()

"""
Default implementation of `placement_valid` raises an error.

Default behaviour should be provided by FlowMap with a concrete surface type GameMap.
"""
function placement_valid(behav::ComponentBehavior, coord::TileCoord, surface; kwargs...)
    error("placement_valid should be called with GameMap as the surface argument; the method for that is implemented in FlowMap")
end

#= ---------- Reactivation probes ----------- =#

"A lightweight probe used by the speculative reactivation scheduler"
struct ReactivationProbe{E <: Tuple, D <: Tuple}
    rel_elements::E
    rel_fluid_declarations::D
end

"Shared outcome classification returned by speculative reactivation probe checks."
@enum ReactivationProbeOutcome::UInt8 begin
    PROBE_HARMFUL
    PROBE_NEUTRAL
    PROBE_USEFUL
end

"Convenience constructor for probes that carry only circuit elements."
ReactivationProbe(rel_elements::Tuple) = ReactivationProbe(rel_elements, ())

"""
Return a `ReactivationProbe` describing the speculative inputs to test for this component,
or `nothing` if the component has no pending reactivation request this tick.

Returning a non-`nothing` probe signals to the calculator scheduler that this component
wishes to test whether it can be safely reactivated. The scheduler will run a speculative
solve with the probe's elements appended, classify the result with `classify_reactivation_probe`,
and call `commit_reactivation_probe!` only when the classification is useful.
"""
get_reactivation_probe(behav::ComponentBehavior; kwargs...) = nothing

"""
Classify the outcome of a speculative reactivation probe for this component.

This hook must be pure and must not mutate component state.

Return values:

- `PROBE_USEFUL`: the speculative solve is good enough that the scheduler may commit this component immediately
- `PROBE_NEUTRAL`: the speculative solve is neither useful enough to commit solo nor actively harmful
- `PROBE_HARMFUL`: the speculative solve is actively wrong for this component this tick

Components that treat a neutral-ish speculative state as immediately acceptable should
classify it as `PROBE_USEFUL` at this shared API boundary.
"""
function classify_reactivation_probe(behav::T; kwargs...) where {T <: ComponentBehavior}
    error("classify_reactivation_probe not implemented for $(nameof(T))")
end

"""
Apply the committed effect of a useful speculative reactivation probe.

The scheduler only calls this hook after `classify_reactivation_probe` returned
`PROBE_USEFUL` for the corresponding speculative solve.
"""
commit_reactivation_probe!(behav::ComponentBehavior; kwargs...) = nothing

# ===============================================================
# PlacedComponent Wrapper
# ===============================================================
"""
A wrapper for a component placed on the map.

Includes shared placement information: the placed rotation, mirror state, and
owning `ship` tag. `ship` records which ship in a unified `GameMap` owns the
component. All behavioural methods delegate to the component.
"""
struct PlacedComponent{T <: ComponentBehavior}
    component::T
    rotation::HexAxis
    mirrored::Bool
    ship::Symbol
end

"Convenience constructor for an unmirrored placed component."
PlacedComponent(component::T, rotation::HexAxis, ship::Symbol) where {T <: ComponentBehavior} = PlacedComponent(component, rotation, false, ship)

# Delegated ComponentBehavior methods
# Elements, fluids, and tunables
produce_rel_elements(comp::PlacedComponent) = produce_rel_elements(comp.component)
produce_rel_fluid_declarations(comp::PlacedComponent) = produce_rel_fluid_declarations(comp.component)
get_tunables(comp::PlacedComponent) = get_tunables(comp.component)
set_tunables(comp::PlacedComponent, tunables::NTuple{N, Real}) where {N} = set_tunables(comp.component, tunables)

# Rendering and effects
render_map_elem!(queue::AbstractVector, comp::PlacedComponent; kwargs...) = render_map_elem!(queue, comp.component; rotation = comp.rotation, mirrored = comp.mirrored, kwargs...)
render_base_elem!(queue::AbstractVector, comp::PlacedComponent; kwargs...) = render_base_elem!(queue, comp.component; rotation = comp.rotation, mirrored = comp.mirrored, kwargs...)
collect_effect_particles!(manager, comp::PlacedComponent; kwargs...) = collect_effect_particles!(manager, comp.component; rotation = comp.rotation, mirrored = comp.mirrored, kwargs...)

# Flow and interaction
update_flowbehav!(comp::PlacedComponent; kwargs...) = update_flowbehav!(comp.component; rotation = comp.rotation, mirrored = comp.mirrored, kwargs...)
function on_click!(comp::PlacedComponent; unrotated_clicksite = nothing, kwargs...)
    if !isnothing(unrotated_clicksite)
        relative_clicksite = tile_orientation_matrix(comp.rotation, comp.mirrored) * unrotated_clicksite
        on_click!(comp.component; relative_clicksite = relative_clicksite, kwargs...) # Forward with the rotated click site
    else
        on_click!(comp.component; kwargs...) # No click site info, just forward everything
    end
    return nothing
end
get_thrust(comp::PlacedComponent; kwargs...) = get_thrust(comp.component; rotation = comp.rotation, mirrored = comp.mirrored, kwargs...)
get_component_temperature(comp::PlacedComponent; kwargs...) = get_component_temperature(comp.component; kwargs...)
get_component_mass(comp::PlacedComponent; kwargs...) = get_component_mass(comp.component; kwargs...)
get_component_dry_mass(comp::PlacedComponent; kwargs...) = get_component_dry_mass(comp.component; kwargs...)
get_component_wet_mass(comp::PlacedComponent; kwargs...) = get_component_wet_mass(comp.component; kwargs...)
map_rotation(comp::PlacedComponent, rotation::HexAxis) = map_rotation(comp.component, rotation)
map_mirroring(comp::PlacedComponent, mirrored::Bool) = map_mirroring(comp.component, mirrored)
can_be_moved(comp::PlacedComponent; kwargs...) = can_be_moved(comp.component; kwargs...)
placement_valid(comp::PlacedComponent, coord, surface; kwargs...) = placement_valid(comp.component, coord, surface; rotation = comp.rotation, mirrored = comp.mirrored, kwargs...)
get_actions(comp::PlacedComponent; kwargs...) = get_actions(comp.component; kwargs...)
do_action!(comp::PlacedComponent, action_id::Symbol; kwargs...) = do_action!(comp.component, action_id; kwargs...)

# Reactivation probes
get_reactivation_probe(comp::PlacedComponent; kwargs...) = get_reactivation_probe(comp.component; rotation = comp.rotation, mirrored = comp.mirrored, kwargs...)
classify_reactivation_probe(comp::PlacedComponent; kwargs...) = classify_reactivation_probe(comp.component; rotation = comp.rotation, mirrored = comp.mirrored, kwargs...)
commit_reactivation_probe!(comp::PlacedComponent; kwargs...) = commit_reactivation_probe!(comp.component; rotation = comp.rotation, mirrored = comp.mirrored, kwargs...)

"Map relative component elements to absolute elements."
function produce_abs_elements(tilecomp::PlacedComponent, tile::TileCoord)
    rel_elements = produce_rel_elements(tilecomp.component)
    # Preserve the tuple shape, including zero-length tuples
    return ntuple(i -> map_element(rel_elements[i], tile, i, tilecomp.rotation, tilecomp.mirrored), length(rel_elements))
end

# ===============================================================
# Pipe Behaviour Interface
# ===============================================================
"""
A PipeBehavior encapsulates all of a pipe's behaviour on pipe coordinates.
This includes its interaction with the flow engine, and its rendering.

A type that subtypes PipeBehavior must implement all the mandatory functions listed,
and should implement the optional functions if the defaults are unsuitable.
These types have the suffix 'PipeBehav'

A PipeBehavior can also be built as a composite of other PipeBehaviors,
with suitable method delegation or output combination applied.

If there is a common subset of functionality, a Pipe Behaviour Fragment can be created.
This can have some of the required methods included which are relevant and not all.
These should be suffixed with 'PipeBehavFrag', and should not subtype PipeBehavior.
They can then be composed into a feature complete behaviour.

All concrete PipeBehavior types T must implement the following
MANDATORY METHODS:

    get_conductance(behav::T)::Float64
    get_pipe_tunables(behav::T)::NTuple{N, TunableProps}
    set_pipe_tunables(behav::T, tunables::NTuple{N, Real})::T
    render_pipe_base!(queue::AbstractVector, behav::T; glmap, rotation, position::PipeCoord, pos_offset = nothing, scale = 1.0, transparency = 1.0, render_height_offset::Integer = 0, kwargs...)::Nothing
    get_pipe_click_radius(behav::T)::Float64
There are suitable defaults, but concrete PipeBehavior types T can also implement the following
OPTIONAL METHODS:

    render_pipe_map!(queue::AbstractVector, behav::T; glmap, rotation, position::PipeCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)::Nothing
    can_pipe_be_moved(behav::T; kwargs...)::RequestStatus
    produce_abs_elements(behav::T, coord::PipeCoord)::NTuple{N, AbsoluteElement}

"""
abstract type PipeBehavior end

# ===============================================================
# PlacedPipe Wrapper
# ===============================================================

"""
A `PipeBehavior` placed on the map. Carries the owning ship's `Symbol` tag.
All behavioural methods delegate to the inner pipe.
"""
struct PlacedPipe{T <: PipeBehavior}
    pipe::T
    ship::Symbol
end

get_conductance(p::PlacedPipe) = get_conductance(p.pipe)
get_pipe_tunables(p::PlacedPipe) = get_pipe_tunables(p.pipe)
"Return a new `PlacedPipe` with updated tunables; preserves the ship tag."
set_pipe_tunables(p::PlacedPipe, tunables::NTuple{N, Real}) where {N} =
    PlacedPipe(set_pipe_tunables(p.pipe, tunables), p.ship)

# Delegated PipeBehavior methods
# Rendering and movement
render_pipe_base!(queue, p::PlacedPipe; kwargs...) = render_pipe_base!(queue, p.pipe; kwargs...)
render_pipe_map!(queue, p::PlacedPipe; kwargs...) = render_pipe_map!(queue, p.pipe; kwargs...)
get_pipe_click_radius(p::PlacedPipe) = get_pipe_click_radius(p.pipe)
can_pipe_be_moved(p::PlacedPipe; kwargs...) = can_pipe_be_moved(p.pipe; kwargs...)

# Elements and fluid declarations
produce_abs_elements(p::PlacedPipe, coord::PipeCoord) = produce_abs_elements(p.pipe, coord)
produce_rel_fluid_declarations(p::PlacedPipe) = produce_rel_fluid_declarations(p.pipe)

#= ---------- Mandatory interface stubs ----------- =#

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

"Error for concrete PipeBehavior without required method get_pipe_click_radius"
function get_pipe_click_radius(behav::T) where {T <: PipeBehavior}
    error("Required method get_pipe_click_radius not implemented for $(nameof(T))")
end

#= ---------- Optional defaults ----------- =#

"Default optional method: `render_pipe_map!` forwards to `render_pipe_base!`. The kwarg `pos_offset` may be any coordinate acceptable to `glvec()` or `nothing` to indicate no offset."
function render_pipe_map!(queue::AbstractVector, behav::PipeBehavior; glmap, rotation, position, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    # Forward visual offset and height without leaking unrelated keywords
    return render_pipe_base!(queue, behav; glmap = glmap, rotation = rotation, position = position, pos_offset = pos_offset, render_height_offset = render_height_offset)
end

"Default can_pipe_be_moved returns a valid request, indicating the pipe can be moved."
can_pipe_be_moved(behav::PipeBehavior; kwargs...) = ValidRequest()

"Default `produce_abs_elements` creates a resistor element from conductance."
function produce_abs_elements(behav::PipeBehavior, coord::PipeCoord)
    connections = AbsoluteElementConnections(to_nodecoord(coord.v1), to_nodecoord(coord.v2))
    conductance = get_conductance(behav)
    absolute_element = AbsoluteElement(connections, conductance, HexElements.CONST_RESISTOR, ElementID(coord))
    return (absolute_element,)
end

"Convenience wrapper allowing set_tunables to be called on PipeBehavior"
set_tunables(behav::T, tunables::NTuple{N, Real}) where {N, T <: PipeBehavior} = set_pipe_tunables(behav, tunables)

end # module HexComponentsAPI
