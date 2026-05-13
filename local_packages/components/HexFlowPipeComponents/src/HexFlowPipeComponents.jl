module HexFlowPipeComponents

using Accessors
using HexFrame, HexElements, HexFluids, HexComponentsAPI, FlowEngine, FlowMap, RenderEngine, HexFlowRendering

# ComponentBehavior Mandatories
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# ComponentBehavior Optional
import HexComponentsAPI: render_map_elem!, map_rotation

# Fragment types
export ScrapTilePipeBehavFrag, BigTilePipeBehavFrag, NoPipeBehavFrag, TilePipeFrag
# Multi-pipe container
export MultiPipeTileCompBehav
# Helper functions
export get_tile_pipe, set_tile_pipe, normalise_tile_pipe_axis, single_tile_pipe, single_tile_pipe_on_tile

"""
Tile-based pipe component implementations.

This module provides fragment and container types for tile-based pipes that can share a tile
across the three straight-through axes.

These are the tile-based equivalents of the edge-based pipes in HexFlowBasicPipes.
"""

const TILE_PIPE_AXES = (HexFrame.Q_POS, HexFrame.R_POS, HexFrame.S_POS)

# ===============================================================
# Tile Pipe Fragments and Multi-Pipe Container
# ===============================================================

#= ---------- Tile Pipe Fragments ----------- =#

"Scrap tile pipe fragment with fixed conductance. Default conductance: 2.0 S"
struct ScrapTilePipeBehavFrag
    conductance::Float64
end

ScrapTilePipeBehavFrag() = ScrapTilePipeBehavFrag(2.0)

"Big tile pipe fragment with fixed conductance. Default conductance: 10.0 S"
struct BigTilePipeBehavFrag
    conductance::Float64
end

BigTilePipeBehavFrag() = BigTilePipeBehavFrag(10.0)

"Sentinel fragment representing an empty tile-pipe axis."
struct NoPipeBehavFrag
end

Base.isempty(::NoPipeBehavFrag) = true
Base.isempty(::Union{ScrapTilePipeBehavFrag, BigTilePipeBehavFrag}) = false

"Union type for tile pipe fragments"
const TilePipeFrag = Union{ScrapTilePipeBehavFrag, BigTilePipeBehavFrag, NoPipeBehavFrag}

#= ---------- Multi-Pipe Container ----------- =#

"Multi-axis tile pipe container. Holds up to one pipe per axis (Q, R, S). Rotationless."
struct MultiPipeTileCompBehav <: ComponentBehavior
    q_pipe::TilePipeFrag
    r_pipe::TilePipeFrag
    s_pipe::TilePipeFrag
end

"Construct an empty multi-pipe tile component"
MultiPipeTileCompBehav() = MultiPipeTileCompBehav(NoPipeBehavFrag(), NoPipeBehavFrag(), NoPipeBehavFrag())

#= ---------- Multi-Pipe Helpers ----------- =#

"""
    get_tile_pipe(behav::MultiPipeTileCompBehav, axis::HexAxis)::TilePipeFrag

Get the pipe fragment at the given axis. Normalises the axis to Q, R, or S.
"""
function get_tile_pipe(behav::MultiPipeTileCompBehav, axis::HexAxis)::TilePipeFrag
    norm_axis = normalise_tile_pipe_axis(axis)
    if norm_axis == HexFrame.Q_POS
        return behav.q_pipe
    elseif norm_axis == HexFrame.R_POS
        return behav.r_pipe
    elseif norm_axis == HexFrame.S_POS
        return behav.s_pipe
    else
        error("Invalid tile-pipe axis: $norm_axis")
    end
end

"""
    set_tile_pipe(behav::MultiPipeTileCompBehav, axis::HexAxis, frag::TilePipeFrag)::MultiPipeTileCompBehav

Return a new instance with the fragment at the given axis updated. Normalises the axis to Q, R, or S.
"""
function set_tile_pipe(behav::MultiPipeTileCompBehav, axis::HexAxis, frag::TilePipeFrag)::MultiPipeTileCompBehav
    norm_axis = normalise_tile_pipe_axis(axis)
    if norm_axis == HexFrame.Q_POS
        return @set behav.q_pipe = frag
    elseif norm_axis == HexFrame.R_POS
        return @set behav.r_pipe = frag
    elseif norm_axis == HexFrame.S_POS
        return @set behav.s_pipe = frag
    else
        error("Invalid tile-pipe axis: $norm_axis")
    end
end

"""
    Base.isempty(behav::MultiPipeTileCompBehav)::Bool

Check if the multi-pipe container is empty (no fragments on any axis).
"""
function Base.isempty(behav::MultiPipeTileCompBehav)::Bool
    return isempty(behav.q_pipe) && isempty(behav.r_pipe) && isempty(behav.s_pipe)
end

"""
    normalise_tile_pipe_axis(axis::HexAxis)::HexAxis

Map any of the 6 hex directions to the 3 tile-pipe axes (Q_POS, R_POS, S_POS).
"""
function normalise_tile_pipe_axis(axis::HexAxis)::HexAxis
    if axis == HexFrame.Q_POS || axis == HexFrame.Q_NEG
        return HexFrame.Q_POS
    elseif axis == HexFrame.R_NEG || axis == HexFrame.R_POS
        return HexFrame.R_POS
    elseif axis == HexFrame.S_POS || axis == HexFrame.S_NEG
        return HexFrame.S_POS
    else
        error("Invalid HexAxis: $axis")
    end
end

"""
    single_tile_pipe(axis::HexAxis, frag::TilePipeFrag)::MultiPipeTileCompBehav

Construct a single-axis multi-pipe container with the given fragment. Normalises the axis.
"""
function single_tile_pipe(axis::HexAxis, frag::TilePipeFrag)::MultiPipeTileCompBehav
    return set_tile_pipe(MultiPipeTileCompBehav(), axis, frag)
end

"""
    single_tile_pipe_on_tile(axis::HexAxis, frag::TilePipeFrag; ship::Symbol = :_blueprint)::ComponentOnTile

Build a `ComponentOnTile` wrapping a single-axis multi-pipe. `MultiPipeTileCompBehav` is
rotationless, so the wrapping rotation is always `Q_POS`.
"""
single_tile_pipe_on_tile(axis::HexAxis, frag::TilePipeFrag; ship::Symbol = :_blueprint)::ComponentOnTile =
    ComponentOnTile(single_tile_pipe(axis, frag), HexFrame.Q_POS, ship)

# ===============================================================
# Fragment Helpers
# ===============================================================

"Rotate the horizontal tile-pipe element connections onto the requested axis."
function _rotated_tile_pipe_connections(rotation::HexAxis)::RelativeElementConnections
    return RelativeElementConnections(
        to_nodepos(HexFrame.rotate(HexFrame.Q_POS, rotation)),
        to_nodepos(HexFrame.rotate(HexFrame.Q_NEG, rotation)),
    )
end

"Build a single-resistor element on the requested tile-pipe axis."
_pipe_element(rotation::HexAxis, conductance::Float64; active::Bool = true) = RelativeElement(_rotated_tile_pipe_connections(rotation), conductance, HexElements.CONST_RESISTOR; active = active)

"Emit a single inactive zero-conductance resistor for an empty tile-pipe axis."
function produce_rel_elements(::NoPipeBehavFrag; rotation::HexAxis = HexFrame.Q_POS)
    return (_pipe_element(rotation, 0.0; active = false),)
end

"Emit a single resistor for a scrap tile-pipe fragment on the requested axis."
function produce_rel_elements(behav::ScrapTilePipeBehavFrag; rotation::HexAxis = HexFrame.Q_POS)
    return (_pipe_element(rotation, behav.conductance),)
end

"Emit a single resistor for a big tile-pipe fragment on the requested axis."
function produce_rel_elements(behav::BigTilePipeBehavFrag; rotation::HexAxis = HexFrame.Q_POS)
    return (_pipe_element(rotation, behav.conductance),)
end

render_base_elem!(queue::Vector{<:RenderCommand}, ::NoPipeBehavFrag; kwargs...) = nothing
render_map_elem!(queue::Vector{<:RenderCommand}, ::NoPipeBehavFrag; kwargs...) = nothing

function render_base_elem!(queue::Vector{<:RenderCommand}, behav::ScrapTilePipeBehavFrag; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    base_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :ScrapPipes_Tile, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = base_height, pos_offset = pos_offset))
    return nothing
end

function render_base_elem!(queue::Vector{<:RenderCommand}, behav::BigTilePipeBehavFrag; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    base_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :BigPipes_Tile, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = base_height, pos_offset = pos_offset))

    fluidmask_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :BigPipes_Tile_fluidmask, rotation, position; colour = DEFAULT_EMPTY_FLUID_COLOUR, scale = scale, transparency = transparency, draw_height = fluidmask_height, pos_offset = pos_offset))
    return nothing
end

render_map_elem!(queue::Vector{<:RenderCommand}, behav::ScrapTilePipeBehavFrag; kwargs...) = render_base_elem!(queue, behav; kwargs...)

function render_map_elem!(queue::Vector{<:RenderCommand}, behav::BigTilePipeBehavFrag; glmap::GLObjectMap, derivedmapstate::DerivedMapState, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, gameticks::Int64 = 0, kwargs...)
    base_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :BigPipes_Tile, rotation, position; scale = scale, transparency = transparency, draw_height = base_height, pos_offset = pos_offset))

    # Get fluid from either connected node (both should agree in a connected region)
    node_q_pos = map_element(HexFrame.NODE_Q_POS, position, rotation)
    node_q_neg = map_element(HexFrame.NODE_Q_NEG, position, rotation)

    fluid = get(derivedmapstate.nodeactualfluids, node_q_pos, get(derivedmapstate.nodeactualfluids, node_q_neg, nothing))
    # Use temperature from the node where the fluid was found, or ambient as fallback
    fluid_node = haskey(derivedmapstate.nodeactualfluids, node_q_pos) ? node_q_pos : node_q_neg
    temperature = get(derivedmapstate.node_temperatures, fluid_node, HexFluids.THERMAL_AMBIENT_TEMPERATURE_K)
    fluidmask_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)

    # Render fluidmask with appropriate renderer based on fluid type
    if !isnothing(fluid) && is_liquid(fluid)
        colour = get_fluid_colour(fluid, temperature)
        push!(queue, render_liquid_tile(glmap, :BigPipes_Tile_fluidmask, rotation, position, gameticks; colour = colour, scale = scale, transparency = transparency, draw_height = fluidmask_height, pos_offset = pos_offset))
    elseif !isnothing(fluid) && is_gas(fluid)
        colour = get_fluid_colour(fluid, temperature)
        push!(queue, render_gas_tile(glmap, :BigPipes_Tile_fluidmask, rotation, position, gameticks; colour = colour, scale = scale, transparency = transparency, draw_height = fluidmask_height, pos_offset = pos_offset))
    else
        push!(queue, render_basic_tile(glmap, :BigPipes_Tile_fluidmask, rotation, position; colour = DEFAULT_EMPTY_FLUID_COLOUR, scale = scale, transparency = transparency, draw_height = fluidmask_height, pos_offset = pos_offset))
    end

    return nothing
end

# ===============================================================
# ComponentBehavior Interface: MultiPipeTileCompBehav
# ===============================================================

"""
    produce_rel_elements(behav::MultiPipeTileCompBehav)

Emit one element per tile-pipe axis in fixed Q, R, S order.
"""
function produce_rel_elements(behav::MultiPipeTileCompBehav)
    return (
        _pipe_element_for_axis(behav.q_pipe, HexFrame.Q_POS),
        _pipe_element_for_axis(behav.r_pipe, HexFrame.R_POS),
        _pipe_element_for_axis(behav.s_pipe, HexFrame.S_POS),
    )
end

_pipe_element_for_axis(::NoPipeBehavFrag, rot::HexAxis) = _pipe_element(rot, 0.0; active = false)
_pipe_element_for_axis(frag::ScrapTilePipeBehavFrag, rot::HexAxis) = _pipe_element(rot, frag.conductance)
_pipe_element_for_axis(frag::BigTilePipeBehavFrag, rot::HexAxis)   = _pipe_element(rot, frag.conductance)

"Multi-pipe tiles have no user-editable tunables"
get_tunables(behav::MultiPipeTileCompBehav) = ()

"Multi-pipe tiles have no tunables to set and only accept the empty tunables tuple."
set_tunables(behav::MultiPipeTileCompBehav, tunables::Tuple{}) = behav

"Multi-pipe tiles are rotationless"
map_rotation(behav::MultiPipeTileCompBehav, rotation::HexAxis) = HexFrame.Q_POS

"Render all tile-pipe axes by delegating to their fragment renderers with axis-specific rotations."
function render_base_elem!(queue::Vector{<:RenderCommand}, behav::MultiPipeTileCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    for axis in TILE_PIPE_AXES
        render_base_elem!(
            queue,
            get_tile_pipe(behav, axis);
            glmap = glmap,
            rotation = HexFrame.rotate(rotation, axis),
            position = position,
            pos_offset = pos_offset,
            scale = scale,
            transparency = transparency,
            colour = colour,
            render_height_offset = render_height_offset,
            kwargs...
        )
    end
    return nothing
end

"Render all tile-pipe axes, including fluid-aware overlays for populated big-pipe fragments."
function render_map_elem!(queue::Vector{<:RenderCommand}, behav::MultiPipeTileCompBehav; glmap::GLObjectMap, derivedmapstate::DerivedMapState, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, gameticks::Int64 = 0, kwargs...)
    for axis in TILE_PIPE_AXES
        render_map_elem!(
            queue,
            get_tile_pipe(behav, axis);
            glmap = glmap,
            derivedmapstate = derivedmapstate,
            rotation = HexFrame.rotate(rotation, axis),
            position = position,
            pos_offset = pos_offset,
            scale = scale,
            transparency = transparency,
            render_height_offset = render_height_offset,
            gameticks = gameticks,
            kwargs...
        )
    end
    return nothing
end

end # module HexFlowPipeComponents
