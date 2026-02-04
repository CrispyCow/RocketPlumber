module HexFlowPipeComponents

using Accessors
using HexFrame, HexElements, HexFluids, HexComponentsAPI, FlowEngine, FlowMap, RenderEngine, HexFlowRendering
using HexFlowBasicComponents

# ComponentBehavior Mandatories
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# ComponentBehavior Optional
import HexComponentsAPI: render_map_elem!

# Concrete Component Behavior Exports
export ScrapTilePipeCompBehav, BigTilePipeCompBehav

"""
Tile-based pipe component implementations.

This module provides concrete ComponentBehavior implementations for pipes that occupy tile positions:
- ScrapTilePipeCompBehav: Low conductance pipe component
- BigTilePipeCompBehav: High conductance pipe with fluid-aware rendering

These are the tile-based equivalents of the edge-based pipes in HexFlowBasicPipes.
"""

const horizontal_element = RelativeElementConnections(HexFrame.NODE_Q_POS, HexFrame.NODE_Q_NEG)

# ===============================================================
# Concrete Component Behaviors
# ===============================================================

#= ---------- ScrapTilePipeCompBehav ----------- =#

"Tile-based scrap pipe with basic resistor element. Default conductance: 2.0 S"
struct ScrapTilePipeCompBehav <: ComponentBehavior
    elems::BasicElemBehavFrag{1}
end

function ScrapTilePipeCompBehav(conductance::Float64)
    elem_frag = BasicElemBehavFrag(
        RelativeElement(horizontal_element, conductance, HexElements.CONST_RESISTOR)
    )
    return ScrapTilePipeCompBehav(elem_frag)
end

ScrapTilePipeCompBehav() = ScrapTilePipeCompBehav(2.0)

produce_rel_elements(behav::ScrapTilePipeCompBehav) = produce_rel_elements(behav.elems)
get_tunables(behav::ScrapTilePipeCompBehav) = get_tunables(behav.elems)
set_tunables(behav::ScrapTilePipeCompBehav, tunables::NTuple{1, Real}) = ScrapTilePipeCompBehav(Float64(tunables[1]))

function render_base_elem!(queue::Vector{RenderCommand}, behav::ScrapTilePipeCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, kwargs...)
    base_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :ScrapPipes_Tile, rotation, position; scale = scale, transparency = transparency, draw_height = base_height, pos_offset = pos_offset))
    return nothing
end

#= ---------- BigTilePipeCompBehav ----------- =#

"Tile-based big pipe with fluid-aware rendering. Renders base sprite with colored fluid mask. Default conductance: 10.0 S"
struct BigTilePipeCompBehav <: ComponentBehavior
    elems::BasicElemBehavFrag{1}
end

function BigTilePipeCompBehav(conductance::Float64)
    elem_frag = BasicElemBehavFrag(
        RelativeElement(horizontal_element, conductance, HexElements.CONST_RESISTOR)
    )
    return BigTilePipeCompBehav(elem_frag)
end

BigTilePipeCompBehav() = BigTilePipeCompBehav(10.0)

produce_rel_elements(behav::BigTilePipeCompBehav) = produce_rel_elements(behav.elems)
get_tunables(behav::BigTilePipeCompBehav) = get_tunables(behav.elems)
set_tunables(behav::BigTilePipeCompBehav, tunables::NTuple{1, Real}) = BigTilePipeCompBehav(Float64(tunables[1]))

function render_base_elem!(queue::Vector{RenderCommand}, behav::BigTilePipeCompBehav; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, kwargs...)
    base_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :BigPipes_Tile, rotation, position; scale = scale, transparency = transparency, draw_height = base_height, pos_offset = pos_offset))

    fluidmask_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset) # Under base sprite
    black_colour = DEFAULT_EMPTY_FLUID_COLOUR
    push!(queue, render_basic_tile(glmap, :BigPipes_Tile_fluidmask, rotation, position; colour = black_colour, scale = scale, transparency = transparency, draw_height = fluidmask_height, pos_offset = pos_offset))

    return nothing
end

function render_map_elem!(queue::Vector{RenderCommand}, behav::BigTilePipeCompBehav; glmap::GLObjectMap, derivedmapstate::DerivedMapState, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, render_height_offset::Integer = 0, gameticks::Int64 = 0, kwargs...)
    base_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, :BigPipes_Tile, rotation, position; scale = scale, transparency = transparency, draw_height = base_height, pos_offset = pos_offset))

    # Get fluid from both connected nodes
    node_q_pos = map_element(HexFrame.NODE_Q_POS, position, rotation)
    node_q_neg = map_element(HexFrame.NODE_Q_NEG, position, rotation)

    fluid_q_pos = get(derivedmapstate.nodeactualfluids, node_q_pos, HexFluids.NONE)
    fluid_q_neg = get(derivedmapstate.nodeactualfluids, node_q_neg, HexFluids.NONE)

    combined_fluid = prioritise_fluidtag(fluid_q_pos, fluid_q_neg)
    colour = get_fluid_colour(combined_fluid)

    fluidmask_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_BEHIND) + Int32(render_height_offset)

    # Render fluidmask with appropriate renderer based on fluid type
    if HexFluids.is_liquid(combined_fluid)
        push!(queue, render_liquid_tile(glmap, :BigPipes_Tile_fluidmask, rotation, position, gameticks; colour = colour, scale = scale, transparency = transparency, draw_height = fluidmask_height, pos_offset = pos_offset))
    elseif HexFluids.is_gas(combined_fluid)
        push!(queue, render_gas_tile(glmap, :BigPipes_Tile_fluidmask, rotation, position, gameticks; colour = colour, scale = scale, transparency = transparency, draw_height = fluidmask_height, pos_offset = pos_offset))
    else # No fluid or unknown - use basic sprite in black
        push!(queue, render_basic_tile(glmap, :BigPipes_Tile_fluidmask, rotation, position; colour = colour, scale = scale, transparency = transparency, draw_height = fluidmask_height, pos_offset = pos_offset))
    end

    return nothing
end

end # module HexFlowPipeComponents
