"""
Basic component behavior fragments and compositions.

This module provides fundamental building blocks for component behaviors:
- PlainSpriteBehavFrag: Simple sprite rendering
- BasicElemBehavFrag: Circuit element composition
- FluidTagBehavFrag: Fluid type specification
- BinaryStateBehavFrag/FloatStateBehavFrag: Mutable state tracking
- StallBehavFrag: Stall state management
- BasicCompBehav: Complete basic component composition

All components follow the ComponentBehavior interface defined in HexComponentsAPI.
"""
module HexFlowBasicComponents

using Accessors
using HexFrame, HexElements, HexFluids, HexComponentsAPI, RenderEngine, HexFlowRendering

# ComponentBehavior Mandatories
import HexComponentsAPI: produce_rel_elements, get_tunables, set_tunables, render_base_elem!
# ComponentBehavior Optional
import HexComponentsAPI: get_fluidtags, update_flowbehav!, render_map_elem!, map_rotation, get_actions, do_action!

# Behavior Fragment Exports
export HorizontalFlipOnlyBehavFrag
export PlainSpriteBehavFrag, BasicElemBehavFrag, FluidTagBehavFrag
export BinaryStateBehavFrag, FloatStateBehavFrag
export getstate, settrue!, setfalse!, setstate!
export StallBehavFrag, stall!, unstall!, is_stalled
# Concrete Component Behavior Exports
export BasicCompBehav

# ===============================================================
# Behavior Fragments
# ===============================================================

#= ---------- HorizontalFlipOnlyBehavFrag ----------- =#

"Simple behavior fragment that restricts rotation to horizontal (Q_POS or Q_NEG) only"
struct HorizontalFlipOnlyBehavFrag end

"Maps all positive rotation directions to Q_POS, and all negative to Q_NEG. Makes the component appear to flip on each rotation change"
function map_rotation(::HorizontalFlipOnlyBehavFrag, rotation::HexAxis)::HexAxis
    if rotation in (HexFrame.Q_POS, HexFrame.S_POS, HexFrame.R_POS)
        return HexFrame.Q_POS
    else
        return HexFrame.Q_NEG
    end
end

#= ---------- PlainSpriteBehavFrag ----------- =#

"Simple sprite behavior for a component with a single preselected sprite from the universal spritesheet"
struct PlainSpriteBehavFrag
    sprite::Symbol
end

"Renders the pre-selected atlas sprite at the component position"
function render_base_elem!(queue::Vector{RenderCommand}, behav::PlainSpriteBehavFrag; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, scale::Float64 = 1.0, transparency::Float64 = 1.0, colour::ColourType = ColourType(1.0, 1.0, 1.0, 1.0), render_height_offset::Integer = 0, kwargs...)
    base_height = Int32(HexFlowRendering.RENDER_HEIGHT_COMPONENT_STATIC) + Int32(render_height_offset)
    push!(queue, render_basic_tile(glmap, behav.sprite, rotation, position; scale = scale, transparency = transparency, colour = colour, draw_height = base_height, pos_offset = pos_offset))
    return nothing
end

#= ---------- BasicElemBehavFrag ----------- =#

"""
A basic component with no behavior beyond that of its circuit elements.
Stores relative elements directly with no additional state.
Can have a varying number of elements.
"""
struct BasicElemBehavFrag{N}
    elements::NTuple{N, RelativeElement}
end

"Varargs constructor for BasicElemBehavFrag"
function BasicElemBehavFrag(elms::Vararg{RelativeElement, N}) where {N}
    return BasicElemBehavFrag{N}(elms) # elms is already a NTuple{N,RelativeElement}
end

"Returns the stored relative elements for this basic component"
function produce_rel_elements(comp::BasicElemBehavFrag{N})::NTuple{N, RelativeElement} where {N}
    return ntuple(i -> comp.elements[i], N)
end

"Returns TunableProps for an Element"
function get_tunables(elem::T)::TunableProps where {T <: Element}
    return TunableProps(
        get_value(elem),
        get_typestring(elem),
        get_unitstring(elem)
    )
end

"Returns a tuple of TunableProps for all elements in a BasicElemBehavFrag"
function get_tunables(comp::BasicElemBehavFrag{N})::NTuple{N, TunableProps} where {N}
    return ntuple(i -> get_tunables(comp.elements[i]), N)
end

"Returns a new component with the tunable values updated"
function set_tunables(comp::BasicElemBehavFrag{N}, tunables::NTuple{N, T})::BasicElemBehavFrag{N} where {N, T <: Real}
    new_elements = ntuple(
        i -> begin
            element = comp.elements[i]
            @set element.value = Float64(tunables[i])
        end, N
    )
    return @set comp.elements = new_elements
end

#= ---------- FluidTagBehavFrag ----------- =#

"Simple fluid behavior for a component that allocates fixed fluidtags to its relative nodes"
struct FluidTagBehavFrag
    tags::NodeFluidTags
end

"Returns the stored fluid tags for this component's nodes"
function get_fluidtags(behav::FluidTagBehavFrag)
    return behav.tags
end

#= ---------- BinaryStateBehavFrag ----------- =#

"Behavioral fragment to track a single binary state value. Interact with `getstate`, `settrue!` and `setfalse!` functions"
mutable struct BinaryStateBehavFrag
    state::Bool
end

getstate(frag::BinaryStateBehavFrag)::Bool = frag.state
settrue!(frag::BinaryStateBehavFrag) = (frag.state = true)
setfalse!(frag::BinaryStateBehavFrag) = (frag.state = false)

#= ---------- FloatStateBehavFrag ----------- =#

"Behavioral fragment to track a single floating point state value. Interact with `getstate` and `setstate!` functions"
mutable struct FloatStateBehavFrag
    state::Float64
end

getstate(frag::FloatStateBehavFrag)::Float64 = frag.state
setstate!(frag::FloatStateBehavFrag, new_state::Float64) = (frag.state = new_state)

#= ---------- StallBehavFrag ----------- =#

"Behavioral fragment to track whether a component is stalled. Interact with `stall!`, `unstall!` and `is_stalled` functions"
mutable struct StallBehavFrag
    stall_state::BinaryStateBehavFrag
end

StallBehavFrag() = StallBehavFrag(BinaryStateBehavFrag(false)) # Default constructor: not stalled

stall!(frag::StallBehavFrag) = settrue!(frag.stall_state)
unstall!(frag::StallBehavFrag) = setfalse!(frag.stall_state)
is_stalled(frag::StallBehavFrag)::Bool = getstate(frag.stall_state)

"Renders a stall overlay icon when the component is stalled"
function render_map_elem!(queue::Vector{RenderCommand}, behav::StallBehavFrag; glmap::GLObjectMap, rotation::HexAxis, position::TileCoord, pos_offset = nothing, render_height_offset::Integer = 0, kwargs...)
    if is_stalled(behav)
        overlay_height = Int32(HexFlowRendering.RENDER_HEIGHT_OVERLAY_BASE) + Int32(render_height_offset)
        push!(queue, render_basic_tile(glmap, :test_stalled, HexFrame.Q_POS, position; draw_height = overlay_height, pos_offset = pos_offset))
    end
    return nothing
end

function get_actions(stall::StallBehavFrag; kwargs...)
    stalled = is_stalled(stall)
    tooltip = stalled ? "Try to reactivate stalled component" : "Component is not currently stalled"
    return (ActionInfo(:unstall, "Unstall Component", stalled, tooltip),)
end

function do_action!(stall::StallBehavFrag, action_id::Symbol; kwargs...)
    if action_id === :unstall
        if is_stalled(stall)
            unstall!(stall)
            return (true, "Component unstalled")
        else
            return (false, "Component is not currently stalled")
        end
    end
    return (false, "Action :$(action_id) not recognised by StallBehavFrag")
end

# ===============================================================
# Concrete Component Behaviors
# ===============================================================

#= ---------- BasicCompBehav ----------- =#

"""
The most basic complete component, with basic elements and a predefined sprite.
Composed from a BasicElemBehavFrag and PlainSpriteBehavFrag.
"""
@kwdef struct BasicCompBehav{N} <: ComponentBehavior
    elems::BasicElemBehavFrag{N}
    sprite::PlainSpriteBehavFrag
    fluids::FluidTagBehavFrag = FluidTagBehavFrag(NodeFluidTags())
end

produce_rel_elements(behav::BasicCompBehav{N}) where {N} = produce_rel_elements(behav.elems)
get_tunables(behav::BasicCompBehav{N}) where {N} = get_tunables(behav.elems)
get_fluidtags(behav::BasicCompBehav{N}) where {N} = get_fluidtags(behav.fluids)

function set_tunables(behav::BasicCompBehav{N}, tunables::NTuple{N, T})::BasicCompBehav{N} where {N, T <: Real}
    return @set behav.elems = set_tunables(behav.elems, tunables)
end

function render_base_elem!(queue::Vector{RenderCommand}, behav::BasicCompBehav{N}; kwargs...) where {N}
    return render_base_elem!(queue, behav.sprite; kwargs...) # Delegate to the sprite fragment
end

end # module HexFlowBasicComponents
