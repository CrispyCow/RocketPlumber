module HexFlowBasicPipes

using Accessors
using HexFrame, HexElements, HexFluids, HexComponentsAPI, FlowEngine, FlowMap, RenderEngine, HexFlowRendering
using StaticArrays
using HexFlowPipeComponents

# PipeBehavior Mandatories
import HexComponentsAPI: get_conductance, get_pipe_tunables, set_pipe_tunables, render_pipe_base!
# PipeBehavior Optional
import HexComponentsAPI: render_pipe_map!, get_pipe_fluidtags, can_pipe_be_moved, produce_abs_elements, get_tile_pipe_equivalent

# Concrete Pipe Behavior Exports
export ScrapPipeBehav, BigPipeBehav

"""
Basic pipe behaviour implementations for edge-based pipes.

This module provides concrete implementations of PipeBehavior for common pipe types:
- ScrapPipeBehav: Low conductance pipe for basic connections
- BigPipeBehav: High conductance pipe for main flow lines with fluid-aware rendering

All pipe behaviours follow the PipeBehavior interface defined in HexComponentsAPI.
"""

# ===============================================================
# Concrete Pipe Behaviors
# ===============================================================

#= ---------- ScrapPipeBehav ----------- =#

"""
ScrapPipeBehav: A basic low-conductance pipe for simple connections.
Default conductance: 2.0 S
"""
struct ScrapPipeBehav <: PipeBehavior
    conductance::Float64
end

ScrapPipeBehav() = ScrapPipeBehav(2.0)

get_conductance(behav::ScrapPipeBehav) = behav.conductance
get_pipe_tunables(behav::ScrapPipeBehav) = (TunableProps(behav.conductance, "Conductance", "S"),)
set_pipe_tunables(behav::ScrapPipeBehav, tunables::NTuple{1, Real}) = ScrapPipeBehav(Float64(tunables[1]))

get_tile_pipe_equivalent(behav::ScrapPipeBehav) = ScrapTilePipeCompBehav(get_conductance(behav))

function render_pipe_base!(queue::AbstractVector, behav::ScrapPipeBehav; glmap::GLObjectMap, rotation::HexAxis, position::EdgeCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    base_height = Int32(HexFlowRendering.RENDER_HEIGHT_PIPE) + Int32(render_height_offset)
    push!(queue, render_basic_pipe(glmap, :ScrapPipes_Edge, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = base_height, pos_offset = pos_offset))
    return nothing
end

#= ---------- BigPipeBehav ----------- =#

"""
BigPipeBehav: A high-conductance pipe for main flow lines with fluid-aware rendering.
Default conductance: 10.0 S
"""
struct BigPipeBehav <: PipeBehavior
    conductance::Float64
end

BigPipeBehav() = BigPipeBehav(10.0)

get_conductance(behav::BigPipeBehav) = behav.conductance
get_pipe_tunables(behav::BigPipeBehav) = (TunableProps(behav.conductance, "Conductance", "S"),)
set_pipe_tunables(behav::BigPipeBehav, tunables::NTuple{1, Real}) = BigPipeBehav(Float64(tunables[1]))

get_tile_pipe_equivalent(behav::BigPipeBehav) = BigTilePipeCompBehav(get_conductance(behav))

function render_pipe_base!(queue::AbstractVector, behav::BigPipeBehav; glmap::GLObjectMap, rotation::HexAxis, position::EdgeCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    # Render black fluidmask at pipe-base height, then pipe sprite at pipe height
    base_height = Int32(HexFlowRendering.RENDER_HEIGHT_PIPE_BASE) + Int32(render_height_offset)
    black_colour = DEFAULT_EMPTY_FLUID_COLOUR
    push!(queue, render_basic_pipe(glmap, :BigPipes_Edge_fluidmask, rotation, position; colour = black_colour, scale = scale, transparency = transparency, draw_height = base_height, pos_offset = pos_offset))

    pipe_height = Int32(HexFlowRendering.RENDER_HEIGHT_PIPE) + Int32(render_height_offset)
    push!(queue, render_basic_pipe(glmap, :BigPipes_Edge, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = pipe_height, pos_offset = pos_offset))

    return nothing
end

function render_pipe_map!(queue::AbstractVector, behav::BigPipeBehav; glmap::GLObjectMap, rotation::HexAxis, position::EdgeCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, derivedmapstate::DerivedMapState, gameticks::Int64 = 0, kwargs...)
    # Get fluid from both connected nodes
    v1_node = to_nodecoord(position.v1)
    v2_node = to_nodecoord(position.v2)
    fluid_v1 = get(derivedmapstate.nodeactualfluids, v1_node, HexFluids.NONE)
    fluid_v2 = get(derivedmapstate.nodeactualfluids, v2_node, HexFluids.NONE)
    combined_fluid = prioritise_fluidtag(fluid_v1, fluid_v2)

    colour = get_fluid_colour(combined_fluid)

    # Render fluidmask with appropriate renderer based on fluid type at base height
    base_height = Int32(HexFlowRendering.RENDER_HEIGHT_PIPE_BASE) + Int32(render_height_offset)
    rotation_matrix = get_rotmat(position)' # Transpose to convert from column-vector to row-vector convention
    position_vec = glvec(position)

    if HexFluids.is_liquid(combined_fluid)
        push!(queue, render_liquid_sprite(glmap, :BigPipes_Edge_fluidmask, rotation_matrix, position_vec; colour = colour, scale = scale, transparency = transparency, draw_height = base_height, gameticks = gameticks, pos_offset = pos_offset))
    elseif HexFluids.is_gas(combined_fluid)
        push!(queue, render_gas_sprite(glmap, :BigPipes_Edge_fluidmask, rotation_matrix, position_vec; colour = colour, scale = scale, transparency = transparency, draw_height = base_height, gameticks = gameticks, pos_offset = pos_offset))
    else
        push!(queue, render_basic_pipe(glmap, :BigPipes_Edge_fluidmask, rotation, position; colour = colour, scale = scale, transparency = transparency, draw_height = base_height, pos_offset = pos_offset))
    end

    # Render pipe sprite at pipe height
    pipe_height = Int32(HexFlowRendering.RENDER_HEIGHT_PIPE) + Int32(render_height_offset)
    push!(queue, render_basic_pipe(glmap, :BigPipes_Edge, rotation, position; scale = scale, transparency = transparency, draw_height = pipe_height, pos_offset = pos_offset))

    return nothing
end

end # module HexFlowBasicPipes
