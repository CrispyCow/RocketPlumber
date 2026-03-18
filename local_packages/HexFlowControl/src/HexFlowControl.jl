module HexFlowControl

using HexFrame, HexFluids, HexComponentsAPI
using StaticArrays, GLFW, Dates

# Type exports
export PlacementModes, INSPECT, MOVE, PIPE, DELETE, TILE, SURFACE_EDIT
export SimSpeed, SIM_1X, SIM_2X, SIM_4X, SIM_MAX
export ExitReason, EXIT_QUIT, EXIT_MENU, EXIT_SANDBOX_COMPLETED, EXIT_SANDBOX_STARTED
export AbstractPopupTarget, ComponentPopupTarget, ShipPopupTarget
export ActionPopupState, HintData, InputState, ViewState, GameState

# Function exports
export create_consolebuffer, get_viewtransform
export get_lastinstate!, update_lastinstate!, get_instate, get_inrising!
export set_placementmode!
export sim_speed_to_ups, increase_sim_speed, decrease_sim_speed, sim_speed_label

# ===============================================================
# Placement Modes
# ===============================================================

"Placement mode enum for hex tile placement"
@enum PlacementModes INSPECT MOVE PIPE DELETE TILE SURFACE_EDIT

"Set placement mode, clearing any active selection and action popup."
function set_placementmode!(inputstate, mode::PlacementModes)
    if inputstate.placementmode != mode
        inputstate.selectedcoord = nothing
        inputstate.rightclick_selectedcoord = nothing
        inputstate.rightclick_selectedship = nothing
        inputstate.action_popup = nothing
        inputstate.placementmode = mode
    end
    return nothing
end

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

"Input state for placement, selection, and control"
@kwdef mutable struct InputState
    # placement
    cursor_x::Union{Nothing, Float64} = nothing
    cursor_y::Union{Nothing, Float64} = nothing
    toolbar::Int64 = 1
    last_toolbar::Int64 = 1
    toolrotation::HexAxis = HexFrame.Q_POS
    placementmode::PlacementModes = INSPECT
    pendingcomponent::ComponentBehavior
    pendingpipebehavior::PipeBehavior
    selectedcoord::Union{Nothing, TileCoord, EdgeCoord} = nothing
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

end # module HexFlowControl
