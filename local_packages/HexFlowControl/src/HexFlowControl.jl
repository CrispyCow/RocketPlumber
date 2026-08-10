module HexFlowControl

using HexFrame, HexComponentsAPI
using StaticArrays, GLFW

# Type exports
export SimSpeed, SIM_1X, SIM_2X, SIM_4X, SIM_MAX
export ExitReason, EXIT_QUIT, EXIT_MENU, EXIT_RESTART, EXIT_SANDBOX_COMPLETED, EXIT_SANDBOX_STARTED
export AbstractPopupTarget, ComponentPopupTarget, ElementGroupPopupTarget, ShipPopupTarget
export AbstractSelectionState, SelectionEmptyState, WorldSelectionState, SelectionState
export AbstractPlacementMoveTarget, TileComponentMoveTarget, PipeMoveTarget, SelectionMoveTarget
export AbstractPlacementState, AbstractEditorPlacementState
export PlacementReadyState, PlacementPressedState, PlacementMoveState, PlacementMovePendingState, PlacementPipeChainState
export PlacementDeleteState, PlacementTileState, PlacementSurfaceEditState, PlacementRedockState
export ActionPopupState, HintData, RedockModeState, InputState, ViewState, GameState
export PlaySessionTiming

# Function exports
export get_viewtransform
export get_lastinstate!, update_lastinstate!, get_instate, get_inrising!, get_infalling!
export placement_state, set_placement_state!, try_enter_placement_state!, clear_placement_pressed_state!, clear_placement_state!
export selection_state, selected_component_coords, selected_pipe_coords
export select_single_component!, select_single_pipe!, select_elements!, toggle_selected_component!, toggle_selected_pipe!, prune_selection!
export clear_selection!, has_selected_component, has_selected_pipe, selected_element_count, translate_selection
export shared_component_actions
export is_standard_family_state, is_active_standard_interaction_state
export dismiss_action_popup!, highlighted_ship, handle_world_escape!
export clear_world_selection!, enter_ready_placement_state!, enter_editor_placement_state!, toggle_editor_placement_state!
export enter_redock_placement_state!, editor_capabilities_enabled
export sim_speed_to_ups, increase_sim_speed, decrease_sim_speed, sim_speed_label
export get_current_play_time_seconds
export GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V, GALAXY_ESCAPE_TIER_DELTA_V
export is_galaxy_escape_unlocked, galaxy_escape_tier, can_complete_galaxy_escape

# ===============================================================
# Galaxy Escape Rules
# ===============================================================

const GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V::Float64 = 600.0
const GALAXY_ESCAPE_TIER_DELTA_V::NTuple{3, Float64} = (2500.0, 4500.0, 5200.0)

"Convert and validate a numeric input used by the fixed galaxy-escape rules."
function _galaxy_escape_rule_value(value::Real)::Float64
    converted = Float64(value)
    isfinite(converted) || throw(ArgumentError("galaxy escape rule input must be finite"))
    return converted
end

"Return whether the historical conservative delta-V peak has unlocked galaxy escape."
is_galaxy_escape_unlocked(peak_estimated_delta_v::Real)::Bool =
    _galaxy_escape_rule_value(peak_estimated_delta_v) >= GALAXY_ESCAPE_UNLOCK_ESTIMATED_DELTA_V

"Return the currently attained galaxy-escape tier from zero through three."
function galaxy_escape_tier(progress::Real)::UInt8
    value = _galaxy_escape_rule_value(progress)
    return UInt8(count(threshold -> value >= threshold, GALAXY_ESCAPE_TIER_DELTA_V))
end

"Return whether current progress is sufficient to complete galaxy escape."
can_complete_galaxy_escape(progress::Real)::Bool = galaxy_escape_tier(progress) > 0x00

# ===============================================================
# Simulation Speed
# ===============================================================

"Simulation speed multiplier. Controls target UPS as a multiple of BASE_UPS."
@enum SimSpeed SIM_1X SIM_2X SIM_4X SIM_MAX

"Convert a SimSpeed to its target UPS value."
function sim_speed_to_ups(speed::SimSpeed)::Float64
    speed === SIM_1X  && return BASE_UPS
    speed === SIM_2X  && return BASE_UPS * 2.0
    speed === SIM_4X  && return BASE_UPS * 4.0
    speed === SIM_MAX && return 1000.0
    return BASE_UPS
end

"Increase SimSpeed by one step, clamped to SIM_MAX."
function increase_sim_speed(speed::SimSpeed)::SimSpeed
    speed === SIM_1X  && return SIM_2X
    speed === SIM_2X  && return SIM_4X
    speed === SIM_4X  && return SIM_MAX
    return SIM_MAX
end

"Decrease SimSpeed by one step, clamped to SIM_1X."
function decrease_sim_speed(speed::SimSpeed)::SimSpeed
    speed === SIM_MAX && return SIM_4X
    speed === SIM_4X  && return SIM_2X
    speed === SIM_2X  && return SIM_1X
    return SIM_1X
end

"Get a short display label for the SimSpeed."
function sim_speed_label(speed::SimSpeed)::String
    speed === SIM_1X  && return "1X"
    speed === SIM_2X  && return "2X"
    speed === SIM_4X  && return "4X"
    speed === SIM_MAX && return "Max"
    return "?"
end

# ===============================================================
# Exit Reason
# ===============================================================

"Reason the game loop exited. Stored on InputState to signal exit intent."
@enum ExitReason begin
    EXIT_QUIT
    EXIT_MENU
    EXIT_RESTART
    EXIT_SANDBOX_COMPLETED
    EXIT_SANDBOX_STARTED
end

"Runtime-only play-session clock; this value is never persisted with a map."
struct PlaySessionTiming
    recorded_play_time_at_start_seconds::Float64
    started_at_ns::UInt64
end

"Start a play-session clock from a validated recorded play-time baseline."
function PlaySessionTiming(recorded_play_time_seconds::Real; started_at_ns::UInt64 = time_ns())
    baseline = Float64(recorded_play_time_seconds)
    (isfinite(baseline) && baseline >= 0.0) || throw(ArgumentError("recorded play time must be finite and non-negative"))
    return PlaySessionTiming(baseline, started_at_ns)
end

"Return the live play time in seconds using an injectable monotonic timestamp."
function get_current_play_time_seconds(timing::PlaySessionTiming; current_time_ns::UInt64 = time_ns())::Float64
    current_time_ns < timing.started_at_ns && throw(ArgumentError("current timestamp precedes session start"))
    elapsed_seconds = Float64(current_time_ns - timing.started_at_ns) / 1.0e9
    return timing.recorded_play_time_at_start_seconds + elapsed_seconds
end

# ===============================================================
# Data Structures
# ===============================================================

"Abstract type for the nested placement-state machine."
abstract type AbstractPlacementState end

"Marker base type for editor-only placement states."
abstract type AbstractEditorPlacementState <: AbstractPlacementState end

"Holds tutorial/hint data for displaying in the hint popup window"
@kwdef mutable struct HintData
    title::String
    hints::Vector{String}
    current_hint_index::Int = 1
    is_visible::Bool = true
end

#= ---------- Selection State Types ----------- =#

"Abstract type for the world-selection state machine."
abstract type AbstractSelectionState end

"World-selection state with no selected targets."
struct SelectionEmptyState <: AbstractSelectionState end

"World-selection state containing components and pipes."
struct WorldSelectionState <: AbstractSelectionState
    component_coords::Set{TileCoord}
    pipe_coords::Set{PipeCoord}

    function WorldSelectionState(component_coords, pipe_coords)
        isempty(component_coords) && isempty(pipe_coords) && throw(ArgumentError("world selection cannot be empty"))
        return new(Set{TileCoord}(component_coords), Set{PipeCoord}(pipe_coords))
    end
end

const SelectionState = Union{SelectionEmptyState, WorldSelectionState}

#= ---------- Action Popup Target Types ----------- =#

"Abstract type for popup-specific data. Concrete subtypes identify the popup target."
abstract type AbstractPopupTarget end

pipe_sort_key(coord::PipeCoord) = (coord.v1.tile.q, coord.v1.tile.r, Int(coord.v1.dir), coord.v2.tile.q, coord.v2.tile.r, Int(coord.v2.dir))

"Popup target for a tile component."
struct ComponentPopupTarget <: AbstractPopupTarget
    coord::TileCoord
end

"Popup target for an ordered group of components and pipes."
struct ElementGroupPopupTarget <: AbstractPopupTarget
    component_coords::Vector{TileCoord}
    pipe_coords::Vector{PipeCoord}

    function ElementGroupPopupTarget(component_coords, pipe_coords)
        length(component_coords) + length(pipe_coords) > 1 ||
            throw(ArgumentError("element group popup requires at least two coordinates"))
        components = sort!(collect(component_coords); by = coord -> (coord.q, coord.r))
        pipes = sort!(collect(pipe_coords); by = pipe_sort_key)
        return new(components, pipes)
    end
end

"Popup target for a ship."
struct ShipPopupTarget <: AbstractPopupTarget
    ship_name::Symbol
end

"State for the world-anchored action popup window, parameterised on popup target type."
@kwdef mutable struct ActionPopupState{T <: AbstractPopupTarget}
    target::T
    world_position::CartesianCoord              # Anchor point in world space
    actions::Tuple                              # Tuple of ActionInfo
    window_title::String                        # ImGui window title
    pending_confirmation::Union{Nothing, ActionInfo} = nothing  # Action awaiting confirmation
end

"""
State for the interactive redock placement state. Entered when the player selects
'Redock' from a ship's right-click menu. Pre-computed tile/node sets are cached on
entry so per-frame validity checking is cheap.
"""
@kwdef mutable struct PlacementRedockState <: AbstractPlacementState
    ship_name::Symbol                           # ship being redocked
    ship_tiles::Set{TileCoord}                  # original surface tiles (green/red ghost)
    exclusion_ring::Set{TileCoord}              # surface and pipe clearance rendered around the ghost
    ship_footprint::Set{TileCoord}              # untranslated surface and pipe clearance for validation
    other_exclusion::Set{TileCoord}             # fixed docking exclusion of all other ships
    original_centre::TileCoord                  # centre tile for computing mouse delta
end

const RedockModeState = PlacementRedockState

# ===============================================================
# Placement State
# ===============================================================

"Abstract type for movable targets inside the placement-state machine."
abstract type AbstractPlacementMoveTarget end

"Move target representing a whole tile component."
struct TileComponentMoveTarget <: AbstractPlacementMoveTarget
    coord::TileCoord
end

"Move target representing a unified pipe segment."
struct PipeMoveTarget <: AbstractPlacementMoveTarget
    coord::PipeCoord
end

const SelectionAnchor = Union{TileCoord, PipeCoord}

"Move target captured from the current world selection."
struct SelectionMoveTarget <: AbstractPlacementMoveTarget
    component_coords::Set{TileCoord}
    pipe_coords::Set{PipeCoord}
    anchor::SelectionAnchor
    press_reference_tile::TileCoord

    function SelectionMoveTarget(
            component_coords, pipe_coords, anchor::SelectionAnchor, press_reference_tile::TileCoord,
        )
        length(component_coords) + length(pipe_coords) > 1 || throw(ArgumentError("selection move target requires at least two elements"))
        anchor_selected = anchor isa TileCoord ? anchor in component_coords : anchor in pipe_coords
        anchor_selected || throw(ArgumentError("selection move anchor must be selected"))
        return new(Set{TileCoord}(component_coords), Set{PipeCoord}(pipe_coords), anchor, press_reference_tile)
    end
end

const PlacementMoveTarget = Union{TileComponentMoveTarget, PipeMoveTarget, SelectionMoveTarget}

"Idle placement state: inspect-hover plus click classification."
struct PlacementReadyState <: AbstractPlacementState end

"Pending placement click state while resolving inspect short-click versus move hold."
@kwdef struct PlacementPressedState <: AbstractPlacementState
    press_started_at::Float64
    press_cursor_cart::CartesianCoord
    click_tile::Union{Nothing, TileCoord} = nothing
    move_target::Union{Nothing, PlacementMoveTarget} = nothing
    move_target_status::Union{Nothing, RequestStatus} = nothing  # `nothing` means no move candidate was captured
    hold_threshold_crossed::Bool = false
end

"Active placement move-drag state."
@kwdef struct PlacementMoveState <: AbstractPlacementState
    move_target::PlacementMoveTarget
    drag_reference_axis::Union{Nothing, HexAxis} = nothing
    toolrotation::HexAxis = HexFrame.Q_POS
    toolmirrored::Bool = false
end

"An enqueued move awaiting its calculator result and committed render snapshot."
@kwdef struct PlacementMovePendingState <: AbstractPlacementState
    response_channel::Channel
    original_selection::SelectionState
    translated_selection::SelectionState
    expected_component_sources::Set{TileCoord}
    expected_component_destinations::Set{TileCoord}
    expected_pipe_sources::Set{PipeCoord}
    expected_pipe_destinations::Set{PipeCoord}
    calculator_applied::Bool = false
end

"Active pipe-chain configuration and pending calculator transaction."
@kwdef mutable struct PlacementPipeChainState <: AbstractPlacementState
    source_node::VertexCoord
    pipe_behavior::PipeBehavior
    pending_next_source_node::Union{Nothing, VertexCoord} = nothing
    #= Stores a calculator response channel without depending on HexFlowCalculator.CommandStatus at the package boundary. =#
    pending_response_channel::Union{Nothing, Channel} = nothing
end

"Editor-only delete placement state."
struct PlacementDeleteState <: AbstractEditorPlacementState end

"Active editor tile-placement configuration. Discarded when tile placement ends."
@kwdef mutable struct PlacementTileState <: AbstractEditorPlacementState
    component_index::Int = 1
    pendingcomponent::ComponentBehavior
    toolrotation::HexAxis = HexFrame.Q_POS
    toolmirrored::Bool = false
end

"Editor-only surface-edit placement state."
struct PlacementSurfaceEditState <: AbstractEditorPlacementState end

const PlacementState = Union{
    PlacementReadyState,
    PlacementPressedState,
    PlacementMoveState,
    PlacementMovePendingState,
    PlacementPipeChainState,
    PlacementDeleteState,
    PlacementTileState,
    PlacementSurfaceEditState,
    PlacementRedockState,
}

# ===============================================================
# Selection State
# ===============================================================

"Input state for placement, selection, and control"
@kwdef mutable struct InputState
    # placement
    cursor_x::Union{Nothing, Float64} = nothing
    cursor_y::Union{Nothing, Float64} = nothing
    placement_state::PlacementState = PlacementReadyState()
    selection_state::SelectionState = SelectionEmptyState()
    gui_inputs::Dict{Symbol, Any} = Dict{Symbol, Any}()  # for storing ImGui input field states
    # last key states
    last_keystates::Dict{GLFW.Key, Bool} = Dict{GLFW.Key, Bool}()
    last_mousestates::Dict{GLFW.MouseButton, Bool} = Dict{GLFW.MouseButton, Bool}()
    # control state
    sim_speed::SimSpeed = SIM_1X
    escape_menu_active::Bool = false
    editor_mode::Bool = false
    dev_utils_menu_active::Bool = false
    spacemap_active::Bool = false
    is_recording::Bool = false
    screenshot_requested::Bool = false
    action_popup::Union{Nothing, ActionPopupState} = nothing
    # loop status
    galaxy_escape_completion_requested::Bool = false
    exit_reason::Union{Nothing, ExitReason} = nothing
    pending_sandbox_id::Union{Nothing, Symbol} = nothing
end

"View state for camera position, zoom, and window dimensions"
@kwdef mutable struct ViewState
    window_width::Int32 = 640
    window_height::Int32 = 480
    fb_width::Int32 = 640
    fb_height::Int32 = 480
    view_x::Float32 = 0.0
    view_y::Float32 = 0.0
    view_zoom::Float32 = 0.5
    ship_bounds::HexFrame.CartesianBounds = (X_POS=5.0, X_NEG=-5.0, Y_POS=5.0, Y_NEG=-5.0)
    frame_count::Int64 = 0
    last_update_time::Float64 = 0.0
    pan_drag_anchor::Union{Nothing, SVector{2, Float64}} = nothing # world-space anchor for middle-click pan
    background_particles::Any = nothing  # ParticleManager - can't type without circular dep
    foreground_particles::Any = nothing  # ParticleManager - can't type without circular dep
end

"""
Game state tracking thrust, acceleration, and simulation ticks.

`acceleration_ship_frame` is thrust/mass in ship-local coordinates (thrust always points +X).
`acceleration_space_map_frame` is the same value rotated into the inertial space-map frame
during manoeuvre burn phases; identical to ship frame when not burning.

`estimated_min_delta_v` is a calculator-owned cached conservative delta-V estimate
that is published to render snapshots on a coarse cadence.
"""
@kwdef mutable struct GameState
    thrust::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    acceleration_ship_frame::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    acceleration_space_map_frame::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    ticks::Int64 = 0
    estimated_min_delta_v::Float64 = 0.0
end

# ===============================================================
# Selection State Helpers
# ===============================================================

"Return the current world-selection state."
selection_state(inputstate::InputState) = inputstate.selection_state

"Return the coordinates of all selected components."
function selected_component_coords(inputstate::InputState)::Set{TileCoord}
    state = selection_state(inputstate)
    state isa WorldSelectionState || return Set{TileCoord}()
    return copy(state.component_coords)
end

"Return the coordinates of all selected pipes."
function selected_pipe_coords(inputstate::InputState)::Set{PipeCoord}
    state = selection_state(inputstate)
    state isa WorldSelectionState || return Set{PipeCoord}()
    return copy(state.pipe_coords)
end

"Replace the current selection with one component."
function select_single_component!(inputstate::InputState, coord::TileCoord)
    inputstate.selection_state = WorldSelectionState(Set((coord,)), Set{PipeCoord}())
    return nothing
end

"Replace the current selection with one pipe."
function select_single_pipe!(inputstate::InputState, coord::PipeCoord)
    inputstate.selection_state = WorldSelectionState(Set{TileCoord}(), Set((coord,)))
    return nothing
end

"Replace the current selection from complete component and pipe coordinate collections."
function select_elements!(inputstate::InputState, component_coords, pipe_coords)
    isempty(component_coords) && isempty(pipe_coords) && return clear_selection!(inputstate)
    inputstate.selection_state = WorldSelectionState(component_coords, pipe_coords)
    return nothing
end

"Toggle one component or pipe coordinate in the current selection."
function toggle_selected_coordinate!(inputstate::InputState, target::Union{TileCoord, PipeCoord})
    state = selection_state(inputstate)
    components = state isa WorldSelectionState ? copy(state.component_coords) : Set{TileCoord}()
    pipes = state isa WorldSelectionState ? copy(state.pipe_coords) : Set{PipeCoord}()

    if target isa TileCoord
        target in components ? delete!(components, target) : push!(components, target)
    else
        target in pipes ? delete!(pipes, target) : push!(pipes, target)
    end

    isempty(components) && isempty(pipes) && return clear_selection!(inputstate)
    inputstate.selection_state = WorldSelectionState(components, pipes)
    return nothing
end

"Toggle one component in the selection."
toggle_selected_component!(inputstate::InputState, coord::TileCoord) = toggle_selected_coordinate!(inputstate, coord)

"Toggle one pipe in the selection."
toggle_selected_pipe!(inputstate::InputState, coord::PipeCoord) = toggle_selected_coordinate!(inputstate, coord)

"Remove selected elements that no longer satisfy their validity predicates."
function prune_selection!(component_is_valid::Function, pipe_is_valid::Function, inputstate::InputState)
    state = selection_state(inputstate)
    state isa WorldSelectionState || return nothing
    components = Set(coord for coord in state.component_coords if component_is_valid(coord))
    pipes = Set(coord for coord in state.pipe_coords if pipe_is_valid(coord))
    isempty(components) && isempty(pipes) && return clear_selection!(inputstate)
    inputstate.selection_state = WorldSelectionState(components, pipes)
    return nothing
end

function selected_element_count(inputstate::InputState)::Int
    state = selection_state(inputstate)
    return state isa WorldSelectionState ? length(state.component_coords) + length(state.pipe_coords) : 0
end

"Translate a complete selection by a whole-tile offset."
function translate_selection(selection::SelectionState, translation::TileCoord)::SelectionState
    selection isa SelectionEmptyState && return selection
    components = Set(coord + translation for coord in selection.component_coords)
    pipes = Set(offset_by_tile(coord, translation) for coord in selection.pipe_coords)
    return WorldSelectionState(components, pipes)
end

"Intersect component actions while preserving the first component's display order."
function shared_component_actions(action_sets)::Tuple
    isempty(action_sets) && return ()
    shared = ActionInfo[]
    for reference_action in first(action_sets)
        matches = [findfirst(action -> action.id === reference_action.id, actions) for actions in action_sets]
        any(isnothing, matches) && continue
        actions = [action_sets[index][match] for (index, match) in enumerate(matches)]
        if any(action -> action.label != reference_action.label ||
                action.confirmation_message != reference_action.confirmation_message, actions)
            @warn "Inconsistent metadata for shared component action" action_id = reference_action.id
        end
        disabled_count = count(!action.enabled for action in actions)
        tooltip = disabled_count == 0 ? reference_action.tooltip :
            "Unavailable for $disabled_count of $(length(actions)) selected components."
        push!(shared, ActionInfo(reference_action.id, reference_action.label, disabled_count == 0, tooltip,
            reference_action.confirmation_message))
    end
    return Tuple(shared)
end

"Clear all selected world targets."
function clear_selection!(inputstate::InputState)
    inputstate.selection_state = SelectionEmptyState()
    return nothing
end

"Return whether a component coordinate is selected."
function has_selected_component(inputstate::InputState, coord::TileCoord)::Bool
    state = selection_state(inputstate)
    return state isa WorldSelectionState && coord in state.component_coords
end

"Return whether a pipe coordinate is selected."
has_selected_pipe(inputstate::InputState, coord::PipeCoord)::Bool =
    (state = selection_state(inputstate); state isa WorldSelectionState && coord in state.pipe_coords)

# ===============================================================
# Placement State Helpers
# ===============================================================

"Return the current nested placement state."
placement_state(inputstate::InputState) = inputstate.placement_state

"Replace the nested placement state."
function set_placement_state!(inputstate::InputState, state::PlacementState)
    inputstate.placement_state = state
    return nothing
end

"Return whether a placement state permits component selection and world popups."
function allows_world_selection(state::AbstractPlacementState)::Bool
    return !(state isa AbstractEditorPlacementState || state isa PlacementRedockState)
end

"Attempt a player-requested placement transition, enforcing destination-state invariants."
function try_enter_placement_state!(inputstate::InputState, state::PlacementState)::Bool
    inputstate.placement_state isa PlacementMovePendingState && return false
    !allows_world_selection(state) && clear_world_selection!(inputstate)
    set_placement_state!(inputstate, state)
    return true
end

"Return `true` when placement is in one of the standard gameplay state-machine states."
function is_standard_family_state(state::AbstractPlacementState)::Bool
    return state isa PlacementReadyState ||
        state isa PlacementPressedState ||
        state isa PlacementMoveState ||
        state isa PlacementMovePendingState ||
        state isa PlacementPipeChainState
end

"Return `true` when a standard gameplay interaction is active beyond ready state."
function is_active_standard_interaction_state(state::AbstractPlacementState)::Bool
    return state isa PlacementPressedState || state isa PlacementMoveState || state isa PlacementPipeChainState
end

"Return whether editor-only capabilities are enabled for the current input state."
editor_capabilities_enabled(inputstate::InputState)::Bool = inputstate.editor_mode

"Dismiss the world action popup without changing element selection."
function dismiss_action_popup!(inputstate::InputState)
    inputstate.action_popup = nothing
    return nothing
end

"Return the ship highlighted by the open ship popup, or `nothing`."
function highlighted_ship(inputstate::InputState)::Union{Nothing, Symbol}
    popup = inputstate.action_popup
    popup === nothing && return nothing
    target = popup.target
    return target isa ShipPopupTarget ? target.ship_name : nothing
end

"Clear popup and selection state without mutating the active placement state."
function clear_world_selection!(inputstate::InputState)
    clear_selection!(inputstate)
    dismiss_action_popup!(inputstate)
    return nothing
end

"Attempt to enter the idle ready placement state."
enter_ready_placement_state!(inputstate::InputState)::Bool = 
    try_enter_placement_state!(inputstate, PlacementReadyState())

"Attempt to enter an editor-only placement state."
enter_editor_placement_state!(inputstate::InputState, state::AbstractEditorPlacementState)::Bool =
    try_enter_placement_state!(inputstate, state)

"Toggle an editor-only placement state, returning to ready when the same tool is selected twice."
function toggle_editor_placement_state!(inputstate::InputState, state::AbstractEditorPlacementState)
    if inputstate.placement_state isa AbstractEditorPlacementState && typeof(inputstate.placement_state) === typeof(state)
        return enter_ready_placement_state!(inputstate)
    end

    return enter_editor_placement_state!(inputstate, state)
end

"Attempt to enter redock placement state."
enter_redock_placement_state!(inputstate::InputState, state::PlacementRedockState)::Bool =
    try_enter_placement_state!(inputstate, state)

"Clear only the pending pressed state when placement has not yet committed to move or pipe behaviour."
function clear_placement_pressed_state!(inputstate::InputState)
    if inputstate.placement_state isa PlacementPressedState
        inputstate.placement_state = PlacementReadyState()
    end
    return nothing
end

"Clear any nested placement state and return to ready state."
clear_placement_state!(inputstate::InputState)::Bool = try_enter_placement_state!(inputstate, PlacementReadyState())

"Handle Escape for world interactions, returning whether the key press was consumed."
function handle_world_escape!(inputstate::InputState)::Bool
    state = placement_state(inputstate)

    # A pending calculator move cannot be cancelled or allow its selection to change.
    state isa PlacementMovePendingState && return true

    if state isa Union{PlacementRedockState, AbstractEditorPlacementState} || is_active_standard_interaction_state(state)
        clear_placement_state!(inputstate)
        return true
    end

    if !isnothing(inputstate.action_popup)
        dismiss_action_popup!(inputstate)
        return true
    end

    selected_element_count(inputstate) == 0 && return false
    clear_selection!(inputstate)
    return true
end

# ===============================================================
# View Transformation
# ===============================================================

"Computes the transformation matrix based on the ViewState"
function get_viewtransform(vs::ViewState)::SMatrix{3, 3, Float32}
    # hex_size_pixels defined in HexFlowRendering - hardcode here to avoid dependency
    hex_size_pixels = 256

    # NOTE: All matrices are transposed as the SMatrix constructor takes row ordered data
    # 1) translate in hex coords
    T = SMatrix{3, 3, Float32}(
        1.0f0, 0.0f0, vs.view_x,
        0.0f0, 1.0f0, vs.view_y,
        0.0f0, 0.0f0, 1.0f0
    )'

    # 2) uniform zoom about panned center
    Z = SMatrix{3, 3, Float32}(
        vs.view_zoom, 0.0f0, 0.0f0,
        0.0f0, vs.view_zoom, 0.0f0,
        0.0f0, 0.0f0, 1.0f0
    )'

    # 3) world → NDC scale
    sx = 2.0f0 * hex_size_pixels / vs.fb_width
    sy = 2.0f0 * hex_size_pixels / vs.fb_height
    S = SMatrix{3, 3, Float32}(
        sx, 0.0f0, 0.0f0,
        0.0f0, sy, 0.0f0,
        0.0f0, 0.0f0, 1.0f0
    )'

    # Compose: world → T → Z → S
    return S * Z * T
end

# ===============================================================
# Input Helper Functions
# ===============================================================

#= ---------- Dict-based core methods ---------- =#

"""
Return the last-tracked state of `key` from a raw state dict.
Keys not yet tracked are inserted as `false` (released) and `false` is returned.
"""
function get_lastinstate!(states::Dict{K, Bool}, key::K)::Bool where {K}
    if !haskey(states, key)
        states[key] = false
    end
    return states[key]
end

"""
Snapshot the current GLFW state of every tracked key into the dict.
Call once at the end of each frame, after all rising-edge checks.
"""
function update_lastinstate!(states::Dict{GLFW.Key, Bool}, window::GLFW.Window)
    for (key, _) in states
        states[key] = GLFW.GetKey(window, key)
    end
    return nothing
end

"""
Snapshot the current GLFW state of every tracked mouse button into the dict.
Call once at the end of each frame, after all rising-edge checks.
"""
function update_lastinstate!(states::Dict{GLFW.MouseButton, Bool}, window::GLFW.Window)
    for (btn, _) in states
        states[btn] = GLFW.GetMouseButton(window, btn)
    end
    return nothing
end

"Returns state of key, true = pressed"
function get_instate(key::GLFW.Key, window::GLFW.Window)::Bool
    return GLFW.GetKey(window, key)
end

"Returns state of mousebutton, true = pressed"
function get_instate(mousebutton::GLFW.MouseButton, window::GLFW.Window)::Bool
    return GLFW.GetMouseButton(window, mousebutton)
end

"""
Returns true on rising edge (pressed this frame, released last frame).
Works on any dict of `{K, Bool}` state tracking.
"""
function get_inrising!(states::Dict{GLFW.Key, Bool}, key::GLFW.Key, window::GLFW.Window)::Bool
    return get_instate(key, window) && !get_lastinstate!(states, key)
end

function get_inrising!(states::Dict{GLFW.MouseButton, Bool}, key::GLFW.MouseButton, window::GLFW.Window)::Bool
    return get_instate(key, window) && !get_lastinstate!(states, key)
end

"Returns true on falling edge (released this frame, pressed last frame)."
function get_infalling!(states::Dict{GLFW.Key, Bool}, key::GLFW.Key, window::GLFW.Window)::Bool
    return !get_instate(key, window) && get_lastinstate!(states, key)
end

function get_infalling!(states::Dict{GLFW.MouseButton, Bool}, key::GLFW.MouseButton, window::GLFW.Window)::Bool
    return !get_instate(key, window) && get_lastinstate!(states, key)
end

#= ---------- InputState convenience methods (delegate to dict core) ---------- =#

"Return the last-tracked state of a key via InputState."
function get_lastinstate!(inputstate::InputState, key::GLFW.Key)::Bool
    return get_lastinstate!(inputstate.last_keystates, key)
end

"Return the last-tracked state of a mouse button via InputState."
function get_lastinstate!(inputstate::InputState, key::GLFW.MouseButton)::Bool
    return get_lastinstate!(inputstate.last_mousestates, key)
end

"Update all tracked keys and mouse buttons from the GLFW window via InputState."
function update_lastinstate!(inputstate::InputState, window::GLFW.Window)
    update_lastinstate!(inputstate.last_keystates, window)
    update_lastinstate!(inputstate.last_mousestates, window)
    return nothing
end

"""
Returns true on rising edge of key or mousebutton state via InputState.
Calling on an untracked key adds it to the dict as released.
"""
function get_inrising!(inputstate::InputState, key::T, window::GLFW.Window)::Bool where {T <: Union{GLFW.Key, GLFW.MouseButton}}
    return get_instate(key, window) && !get_lastinstate!(inputstate, key)
end

"Returns true on falling edge of key or mousebutton state via InputState."
function get_infalling!(inputstate::InputState, key::T, window::GLFW.Window)::Bool where {T <: Union{GLFW.Key, GLFW.MouseButton}}
    return !get_instate(key, window) && get_lastinstate!(inputstate, key)
end

end # module HexFlowControl
