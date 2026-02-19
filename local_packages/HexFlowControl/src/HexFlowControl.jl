module HexFlowControl

using HexFrame, HexFluids, HexComponentsAPI
using StaticArrays, GLFW, Dates

# Type exports
export PlacementModes, INSPECT, MOVE, PIPE, DELETE, TILE, SURFACE_EDIT
export HintData, InputState, ViewState, GameState

# Function exports
export create_consolebuffer, get_viewtransform
export get_lastinstate!, update_lastinstate!, get_instate, get_inrising!

# ===============================================================
# Placement Modes
# ===============================================================

"Placement mode enum for hex tile placement"
@enum PlacementModes INSPECT MOVE PIPE DELETE TILE SURFACE_EDIT

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
    last_command_time::Float64 = 0.0
    gui_inputs::Dict{Symbol, Any} = Dict{Symbol, Any}()  # for storing ImGui input field states
    # last key states
    last_keystates::Dict{GLFW.Key, Bool} = Dict{GLFW.Key, Bool}()
    last_mousestates::Dict{GLFW.MouseButton, Bool} = Dict{GLFW.MouseButton, Bool}()
    # control state
    is_paused::Bool = false # FlowCalculator loop pause
    escape_menu_active::Bool = false
    editor_mode::Bool = false
    dev_utils_menu_active::Bool = false
    spacemap_active::Bool = false
    # loop status
    should_exit_gameloop::Bool = false
    return_symbol::Symbol = :default
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
    background_particles::Any = nothing  # ParticleManager - can't type without circular dep
    foreground_particles::Any = nothing  # ParticleManager - can't type without circular dep
end

"Game state tracking thrust, acceleration, and simulation ticks"
@kwdef mutable struct GameState
    thrust::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
    acceleration::SVector{2, Float64} = SVector{2, Float64}(0.0, 0.0)
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

"""
Return the state of the given key at the previous tick. Calling on a key that 
has not yet been tracked will return false and add it to the tracked Dict.
"""
function get_lastinstate!(inputstate::InputState, key::GLFW.Key)::Bool
    # first time this is called for a key, add key to Dict as released
    if !haskey(inputstate.last_keystates, key)
        inputstate.last_keystates[key] = false
    end

    # otherwise return the last state
    return inputstate.last_keystates[key]
end

"""
Return the state of the given mousebutton at the previous tick. Calling on a 
mousebutton that has not yet been tracked will return false and add it to the tracked Dict.
"""
function get_lastinstate!(inputstate::InputState, key::GLFW.MouseButton)::Bool
    # first time this is called for a key, add key to Dict as released
    if !haskey(inputstate.last_mousestates, key)
        inputstate.last_mousestates[key] = false
    end

    # otherwise return the last state
    return inputstate.last_mousestates[key]
end

"""
Updates the last state of all tracked keys. Call after all key checks 
have already been made.
"""
function update_lastinstate!(inputstate::InputState, window::GLFW.Window)
    # update all tracked keys
    for (key, _) in inputstate.last_keystates
        inputstate.last_keystates[key] = GLFW.GetKey(window, key)
    end
    # update all tracked mouse buttons
    for (key, _) in inputstate.last_mousestates
        inputstate.last_mousestates[key] = GLFW.GetMouseButton(window, key)
    end
    return
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
Returns true on rising edge of key or mousebutton state. Calling on a key or mousebutton 
that has not yet been tracked will return false and add it to the tracked Dict
"""
function get_inrising!(inputstate::InputState, key::T, window::GLFW.Window)::Bool where {T <: Union{GLFW.Key, GLFW.MouseButton}}
    # true if currently pressed, but was released last tick
    return get_instate(key, window) && !get_lastinstate!(inputstate, key)
end

end # module HexFlowControl
