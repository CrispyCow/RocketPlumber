module HexFlowControl

using HexFrame, HexComponentsAPI
using StaticArrays, GLFW, Dates

# Type exports
export SimSpeed, SIM_1X, SIM_2X, SIM_4X, SIM_MAX
export ExitReason, EXIT_QUIT, EXIT_MENU, EXIT_SANDBOX_COMPLETED, EXIT_SANDBOX_STARTED
export AbstractPopupTarget, ComponentPopupTarget, ShipPopupTarget
export AbstractPlacementMoveTarget, TileComponentMoveTarget, TilePipeMoveTarget, EdgePipeMoveTarget
export AbstractPlacementState, AbstractEditorPlacementState
export PlacementReadyState, PlacementPressedState, PlacementMoveState, PlacementPipeChainState
export PlacementDeleteState, PlacementTileState, PlacementSurfaceEditState, PlacementRedockState
export ActionPopupState, HintData, RedockModeState, InputState, ViewState, GameState

# Function exports
export create_consolebuffer, get_viewtransform
export get_lastinstate!, update_lastinstate!, get_instate, get_inrising!, get_infalling!
export placement_state, set_placement_state!, clear_placement_pressed_state!, clear_placement_state!
export is_standard_family_state, is_active_standard_interaction_state
export clear_world_selection!, enter_ready_placement_state!, enter_editor_placement_state!, toggle_editor_placement_state!
export enter_redock_placement_state!, editor_capabilities_enabled
export sim_speed_to_ups, increase_sim_speed, decrease_sim_speed, sim_speed_label

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
    EXIT_SANDBOX_COMPLETED
    EXIT_SANDBOX_STARTED
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

#= ---------- Action Popup Target Types ----------- =#

"Abstract type for popup-specific data. Concrete subtypes identify the popup target."
abstract type AbstractPopupTarget end

"Popup target for a tile component."
struct ComponentPopupTarget <: AbstractPopupTarget
    coord::TileCoord
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
    exclusion_ring::Set{TileCoord}              # combined 2-ring expansion minus core (grey ghost)
    ship_nodes::Set{NodeCoord}                  # circuit nodes of this ship (pipe bridge check)
    other_ship_tiles::Set{TileCoord}            # combined surfaces of all other ships
    other_ship_nodes::Set{NodeCoord}            # combined nodes of all other ships
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

"Move target representing a single tile-pipe fragment on a tile axis."
struct TilePipeMoveTarget <: AbstractPlacementMoveTarget
    coord::TileCoord
    axis::HexAxis
end

"Move target representing an edge pipe."
struct EdgePipeMoveTarget <: AbstractPlacementMoveTarget
    coord::EdgeCoord
end

const PlacementMoveTarget = Union{TileComponentMoveTarget, TilePipeMoveTarget, EdgePipeMoveTarget}

"Idle placement state: inspect-hover plus click classification."
struct PlacementReadyState <: AbstractPlacementState end

"Pending placement click state while resolving inspect short-click versus move hold."
@kwdef struct PlacementPressedState <: AbstractPlacementState
    press_started_at::Float64
    press_cursor_cart::CartesianCoord
    click_tile::Union{Nothing, TileCoord} = nothing
    move_target::Union{Nothing, PlacementMoveTarget} = nothing
    move_target_valid::Bool = false
    hold_threshold_crossed::Bool = false
end

"Active placement move-drag state."
@kwdef struct PlacementMoveState <: AbstractPlacementState
    move_target::PlacementMoveTarget
    drag_reference_axis::Union{Nothing, HexAxis} = nothing
    toolrotation::HexAxis = HexFrame.Q_POS
    toolmirrored::Bool = false
end

"Active placement pipe-chain state." 
@kwdef struct PlacementPipeChainState <: AbstractPlacementState
    source_node::VertexCoord
    pending_next_source_node::Union{Nothing, VertexCoord} = nothing
    #= Stores a calculator response channel without depending on HexFlowCalculator.CommandStatus at the package boundary. =#
    pending_response_channel::Union{Nothing, Channel} = nothing
end

"Editor-only delete placement state."
struct PlacementDeleteState <: AbstractEditorPlacementState end

"Editor-only tile placement state."
@kwdef mutable struct PlacementTileState <: AbstractEditorPlacementState
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
    PlacementPipeChainState,
    PlacementDeleteState,
    PlacementTileState,
    PlacementSurfaceEditState,
    PlacementRedockState,
}

"Input state for placement, selection, and control"
@kwdef mutable struct InputState
    # placement
    cursor_x::Union{Nothing, Float64} = nothing
    cursor_y::Union{Nothing, Float64} = nothing
    toolbar::Int64 = 1
    last_toolbar::Int64 = 1
    pendingpipebehavior::PipeBehavior
    tile_tool_state::Union{Nothing, PlacementTileState} = nothing
    placement_state::PlacementState = PlacementReadyState()
    rightclick_selectedcoord::Union{Nothing, TileCoord} = nothing
    rightclick_selectedship::Union{Nothing, Symbol} = nothing
    last_command_time::Float64 = 0.0
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
"""
@kwdef mutable struct GameState
    thrust::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    acceleration_ship_frame::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    acceleration_space_map_frame::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    ticks::Int64 = 0
end

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

"Return `true` when placement is in one of the standard gameplay state-machine states."
function is_standard_family_state(state::AbstractPlacementState)::Bool
    return state isa PlacementReadyState ||
        state isa PlacementPressedState ||
        state isa PlacementMoveState ||
        state isa PlacementPipeChainState
end

"Return `true` when a standard gameplay interaction is active beyond ready state."
function is_active_standard_interaction_state(state::AbstractPlacementState)::Bool
    return state isa PlacementPressedState || state isa PlacementMoveState || state isa PlacementPipeChainState
end

"Return whether editor-only capabilities are enabled for the current input state."
editor_capabilities_enabled(inputstate::InputState)::Bool = inputstate.editor_mode

"Clear popup and selection state without mutating the active placement state."
function clear_world_selection!(inputstate::InputState)
    inputstate.rightclick_selectedcoord = nothing
    inputstate.rightclick_selectedship = nothing
    inputstate.action_popup = nothing
    return nothing
end

"Enter the idle ready placement state and clear world-selection UI state."
function enter_ready_placement_state!(inputstate::InputState)
    clear_world_selection!(inputstate)
    inputstate.placement_state = PlacementReadyState()
    return nothing
end

"Enter an editor-only placement state, clearing world-selection UI state first."
function enter_editor_placement_state!(inputstate::InputState, state::AbstractEditorPlacementState)
    clear_world_selection!(inputstate)
    inputstate.placement_state = state
    return nothing
end

"Toggle an editor-only placement state, returning to ready when the same tool is selected twice."
function toggle_editor_placement_state!(inputstate::InputState, state::AbstractEditorPlacementState)
    if inputstate.placement_state isa AbstractEditorPlacementState && typeof(inputstate.placement_state) === typeof(state)
        return enter_ready_placement_state!(inputstate)
    end

    return enter_editor_placement_state!(inputstate, state)
end

"Enter redock placement state, clearing world-selection UI state first."
function enter_redock_placement_state!(inputstate::InputState, state::PlacementRedockState)
    clear_world_selection!(inputstate)
    inputstate.placement_state = state
    return nothing
end

"Clear only the pending pressed state when placement has not yet committed to move or pipe behaviour."
function clear_placement_pressed_state!(inputstate::InputState)
    if inputstate.placement_state isa PlacementPressedState
        inputstate.placement_state = PlacementReadyState()
    end
    return nothing
end

"Clear any nested placement state and return to ready state."
function clear_placement_state!(inputstate::InputState)
    inputstate.placement_state = PlacementReadyState()
    return nothing
end

# ===============================================================
# Console Buffer
# ===============================================================

"Creates a timestamped console message buffer, returning push and iterator functions for the hidden buffer"
function create_consolebuffer(Length::Int)
    # check length bounds
    if Length < 1
        error("Invalid Length of Console Buffer (must be more than 1)")
    end

    # internal variables
    msg_buffer = String[]

    "Closure function to add a message string to the internal message buffer"
    push_message = (msg::String) -> begin
        timestamp = Dates.format(now(), "HH:MM:SS")
        stamped_msg = "[$timestamp]: $msg"
        push!(msg_buffer, stamped_msg)
        if length(msg_buffer) > Length
            popfirst!(msg_buffer)
        end
    end

    "Closure function which returns a shallow copy of the internal message buffer"
    see_messages = () -> begin
        copy(msg_buffer)
    end

    return push_message, see_messages
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
