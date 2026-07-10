module HexFlowBasicPipes

using Accessors
using HexFrame, HexElements, HexFluids, HexComponentsAPI, FlowEngine, FlowMap, RenderEngine, HexFlowRendering
using StaticArrays

# PipeBehavior Mandatories
import HexComponentsAPI: get_conductance, get_pipe_tunables, set_pipe_tunables, render_pipe_base!, get_pipe_click_radius
# PipeBehavior Optional
import HexComponentsAPI: render_pipe_map!, can_pipe_be_moved, produce_abs_elements

# Concrete Pipe Behavior Exports
export ScrapPipeBehav, BigPipeBehav

"""
Basic pipe behaviour implementations for pipe segments.

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
get_pipe_click_radius(::ScrapPipeBehav)::Float64 = 0.083984375

function scrap_pipe_sprite(position::PipeCoord)::Symbol
    span_class = pipe_span_class(position)
    if span_class === SIDE_SPAN
        return :ScrapPipes_Side
    elseif span_class === SHORT_DIAGONAL_SPAN
        return :ScrapPipes_ShortDiagonal
    elseif span_class === LONG_DIAGONAL_SPAN
        return :ScrapPipes_LongDiagonal
    else
        error("unknown pipe span class")
    end
end

"Return the fluid-mask and sprite heights for a pipe's deterministic stacking rank."
function pipe_rank_draw_heights(position::PipeCoord, render_height_offset::Integer)::Tuple{Int32, Int32}
    fluidmask_height = Int32(get_stacking_rank(position)) * HexFlowRendering.RENDER_HEIGHT_PIPE_RANK_MULTIPLIER + Int32(render_height_offset)
    pipe_height = fluidmask_height + Int32(1)
    return fluidmask_height, pipe_height
end

function render_pipe_base!(queue::AbstractVector, behav::ScrapPipeBehav; glmap::GLObjectMap, rotation::HexAxis, position::PipeCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    sprite = scrap_pipe_sprite(position)
    _, pipe_height = pipe_rank_draw_heights(position, render_height_offset)

    push!(queue, render_basic_pipe(glmap, sprite, position; scale = scale, transparency = transparency, colour = colour, draw_height = pipe_height, pos_offset = pos_offset))
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
get_pipe_click_radius(::BigPipeBehav)::Float64 = 0.146484375

function big_pipe_sprites(position::PipeCoord)::Tuple{Symbol, Symbol}
    span_class = pipe_span_class(position)
    if span_class === SIDE_SPAN
        return (:BigPipes_Side, :BigPipes_Side_fluidmask)
    elseif span_class === SHORT_DIAGONAL_SPAN
        return (:BigPipes_ShortDiagonal, :BigPipes_ShortDiagonal_fluidmask)
    elseif span_class === LONG_DIAGONAL_SPAN
        return (:BigPipes_LongDiagonal, :BigPipes_LongDiagonal_fluidmask)
    else
        error("unknown pipe span class")
    end
end

function render_pipe_base!(queue::AbstractVector, behav::BigPipeBehav; glmap::GLObjectMap, rotation::HexAxis, position::PipeCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    base_sprite, fluidmask_sprite = big_pipe_sprites(position)
    fluidmask_height, pipe_height = pipe_rank_draw_heights(position, render_height_offset)

    black_colour = DEFAULT_EMPTY_FLUID_COLOUR
    push!(queue, render_basic_pipe(glmap, fluidmask_sprite, position; colour = black_colour, scale = scale, transparency = transparency, draw_height = fluidmask_height, pos_offset = pos_offset))

    push!(queue, render_basic_pipe(glmap, base_sprite, position; scale = scale, transparency = transparency, colour = colour, draw_height = pipe_height, pos_offset = pos_offset))

    return nothing
end

function render_pipe_map!(queue::AbstractVector, behav::BigPipeBehav; glmap::GLObjectMap, rotation::HexAxis, position::PipeCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, derivedmapstate::DerivedMapState, gameticks::Int64 = 0, kwargs...)
    base_sprite, fluidmask_sprite = big_pipe_sprites(position)

    v1_node = to_nodecoord(position.v1)
    v2_node = to_nodecoord(position.v2)
    fluid = get(derivedmapstate.nodeactualfluids, v1_node, get(derivedmapstate.nodeactualfluids, v2_node, nothing))
    fluid_node = haskey(derivedmapstate.nodeactualfluids, v1_node) ? v1_node : v2_node
    temperature = get(derivedmapstate.node_temperatures, fluid_node, HexFluids.THERMAL_AMBIENT_TEMPERATURE_K)

    fluidmask_height, pipe_height = pipe_rank_draw_heights(position, render_height_offset)
    rotation_matrix = get_rotmat(position)'
    position_vec = glvec(position)

    if !isnothing(fluid) && is_liquid(fluid)
        colour = get_fluid_colour(fluid, temperature)
        push!(queue, render_liquid_sprite(glmap, fluidmask_sprite, rotation_matrix, position_vec; colour = colour, scale = scale, transparency = transparency, draw_height = fluidmask_height, gameticks = gameticks, pos_offset = pos_offset))
    elseif !isnothing(fluid) && is_gas(fluid)
        colour = get_fluid_colour(fluid, temperature)
        push!(queue, render_gas_sprite(glmap, fluidmask_sprite, rotation_matrix, position_vec; colour = colour, scale = scale, transparency = transparency, draw_height = fluidmask_height, gameticks = gameticks, pos_offset = pos_offset))
    else
        push!(queue, render_basic_pipe(glmap, fluidmask_sprite, position; colour = DEFAULT_EMPTY_FLUID_COLOUR, scale = scale, transparency = transparency, draw_height = fluidmask_height, pos_offset = pos_offset))
    end

    push!(queue, render_basic_pipe(glmap, base_sprite, position; scale = scale, transparency = transparency, draw_height = pipe_height, pos_offset = pos_offset))

    return nothing
end

end # module HexFlowBasicPipes
