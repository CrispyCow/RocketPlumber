#=
Scope: Native GLFW window creation, monitor restoration, fullscreen, input, and title tracking
Formatter: Runic
=#

# ===============================================================
# GLFW Callback and Window Setup
# ===============================================================

const INITIAL_WINDOW_WIDTH = 1920
const INITIAL_WINDOW_HEIGHT = 1080

"Windowed geometry and restoration information, shared for the lifetime of a window."
@kwdef mutable struct WindowModeState
    windowed_x::Int = 0
    windowed_y::Int = 0
    windowed_width::Int = INITIAL_WINDOW_WIDTH
    windowed_height::Int = INITIAL_WINDOW_HEIGHT
    was_maximised::Bool = false
end

"Find the window's monitor; optionally use the primary when its centre cannot be located."
function window_monitor(window::GLFW.Window; fallback_to_primary::Bool = true)
    fallback = fallback_to_primary ? GLFW.GetPrimaryMonitor() : nothing
    platform = GLFW.GetPlatform()
    if platform ∉ (GLFW.PLATFORM_WIN32, GLFW.PLATFORM_X11, GLFW.PLATFORM_COCOA)
        return fallback
    end

    position = GLFW.GetWindowPos(window)
    size = GLFW.GetWindowSize(window)
    centre_x = position.x + size.width / 2
    centre_y = position.y + size.height / 2

    for monitor in GLFW.GetMonitors()
        origin = GLFW.GetMonitorPos(monitor)
        mode = GLFW.GetVideoMode(monitor)
        if origin.x <= centre_x < origin.x + mode.width && origin.y <= centre_y < origin.y + mode.height
            return monitor
        end
    end

    return fallback
end

"Find the saved display, centring the initial window before any fullscreen transition where placement is supported."
function restore_last_monitor!(window::GLFW.Window, name::Union{Nothing, String})
    (isnothing(name) || isempty(name)) && return nothing
    monitor = try
        monitors = GLFW.GetMonitors()
        index = findfirst(monitor -> GLFW.GetMonitorName(monitor) == name, monitors)
        isnothing(index) ? nothing : monitors[index]
    catch err
        err isa InterruptException && rethrow()
        @warn "Could not find the last-used monitor" name exception = (err, catch_backtrace())
        return nothing
    end
    isnothing(monitor) && return nothing

    # Native Wayland leaves window placement to the compositor
    if GLFW.GetPlatform() in (GLFW.PLATFORM_WIN32, GLFW.PLATFORM_X11, GLFW.PLATFORM_COCOA)
        try
            origin = GLFW.GetMonitorPos(monitor)
            mode = GLFW.GetVideoMode(monitor)
            size = GLFW.GetWindowSize(window)
            target_x = origin.x + (mode.width - size.width) ÷ 2
            target_y = origin.y + (mode.height - size.height) ÷ 2
            GLFW.SetWindowPos(window, target_x, target_y)
            # Allow asynchronous window placement to settle before fullscreen captures it
            for _ in 1:10
                position = GLFW.GetWindowPos(window)
                (position.x, position.y) == (target_x, target_y) && break
                GLFW.WaitEvents(0.01)
            end
        catch err
            err isa InterruptException && rethrow()
            @warn "Could not position the window on the last-used monitor" name exception = (err, catch_backtrace())
        end
    end

    return monitor
end

"Remember the display before window destruction, retaining the previous name if detection fails."
function remember_last_monitor!(window::GLFW.Window)
    name = try
        monitor = GLFW.GetWindowMonitor(window)
        if monitor.handle == C_NULL
            monitor = window_monitor(window; fallback_to_primary = false)
        end
        isnothing(monitor) && return nothing
        GLFW.GetMonitorName(monitor)
    catch err
        err isa InterruptException && rethrow()
        @warn "Could not identify the last-used monitor" exception = (err, catch_backtrace())
        return nothing
    end
    isempty(name) && return nothing

    state = app_state()
    settings = state.settings
    state.settings = @set settings.last_monitor = name
    return nothing
end

"Read the actual native fullscreen mode from GLFW rather than caching it."
window_is_fullscreen(window::GLFW.Window) = GLFW.GetWindowMonitor(window).handle != C_NULL

"Apply the configured swap interval to the current OpenGL context."
apply_vsync!(enabled::Bool) = GLFW.SwapInterval(enabled ? 1 : 0)

"Apply native fullscreen, preserving windowed restoration data; return the actual resulting mode."
function apply_fullscreen!(state::WindowModeState, window::GLFW.Window, enabled::Bool, monitor::Union{Nothing, GLFW.Monitor} = nothing)
    window_is_fullscreen(window) == enabled && return enabled

    if enabled
        monitor = isnothing(monitor) ? window_monitor(window) : monitor
        mode = GLFW.GetVideoMode(monitor)
        state.was_maximised = GLFW.GetWindowAttrib(window, GLFW.MAXIMIZED) != 0
        size = GLFW.GetWindowSize(window)
        state.windowed_width, state.windowed_height = size.width, size.height
        # Native Wayland leaves placement to the compositor
        if GLFW.GetPlatform() != GLFW.PLATFORM_WAYLAND
            position = GLFW.GetWindowPos(window)
            state.windowed_x, state.windowed_y = position.x, position.y
        end
        GLFW.SetWindowMonitor(window, monitor, 0, 0, mode.width, mode.height, mode.refreshrate)
    else
        GLFW.SetWindowMonitor(window, GLFW.Monitor(C_NULL), state.windowed_x, state.windowed_y, state.windowed_width, state.windowed_height, GLFW.DONT_CARE)
        if state.was_maximised
            GLFW.MaximizeWindow(window)
        end
    end

    actual = window_is_fullscreen(window)
    if actual != enabled
        @warn "Window mode differs from the fullscreen request" requested = enabled actual
    end
    return actual
end

"Log errors reported through GLFW's callback interface."
error_callback(err::GLFW.GLFWError) = @error "GLFW ERROR: code $(err.code) msg: $(err.description)"

"""
Creates a GLFW window and current OpenGL context with minimal setup.
Intentionally defers installing callbacks so that a lightweight loading screen
can be shown before the full game state is loaded.
"""
function startgl_minimal(width, height)
    GLFW.SetErrorCallback(error_callback)

    # Configure the OpenGL context
    GLFW.DefaultWindowHints()
    @static if Sys.isapple()
        # macOS maximum OpenGL version is 4.1
        VERSION_MAJOR = 4
        VERSION_MINOR = 1
        GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, VERSION_MAJOR)
        GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, VERSION_MINOR)
        GLFW.WindowHint(GLFW.OPENGL_PROFILE, GLFW.OPENGL_CORE_PROFILE)
        GLFW.WindowHint(GLFW.OPENGL_FORWARD_COMPAT, GL_TRUE)
    end

    GLFW.WindowHint(GLFW.SAMPLES, 0) # disable MSAA

    @info "Starting GLFW (minimal)..."
    @info GLFW.GetVersionString()

    window = GLFW.CreateWindow(width, height, "Rocket Plumber Loading")
    @assert window != C_NULL "Could not open window with GLFW3"

    GLFW.MakeContextCurrent(window)
    state = app_state()
    settings = state.settings
    monitor = restore_last_monitor!(window, settings.last_monitor)
    fullscreen = apply_fullscreen!(state.window_mode, window, settings.fullscreen, monitor)
    state.settings = @set settings.fullscreen = fullscreen
    apply_vsync!(settings.vsync)

    return window
end

"Configure input callbacks and log GPU capabilities when entering a gameplay session."
function attach_glfw_callbacks!(window::GLFW.Window)
    # Configure input handling
    GLFW.SetInputMode(window, GLFW.STICKY_MOUSE_BUTTONS, true)
    GLFW.SetInputMode(window, GLFW.STICKY_KEYS, true)
    GLFW.SetScrollCallback(window, scroll_callback) # Scroll cannot be polled

    # Log GPU capabilities
    renderer = unsafe_string(glGetString(GL_RENDERER))
    version = unsafe_string(glGetString(GL_VERSION))
    texsize = GLint(0)
    @cref glGetIntegerv(GL_MAX_TEXTURE_SIZE, &texsize)

    @info "Renderer: $renderer"
    @info "OpenGL version supported: $version"
    @info "Max Texture Size: $texsize"
    return nothing
end

#= ---------- Scroll Tracking ---------- =#

let
    mutable struct ScrollState
        latest_x::Float64
        latest_y::Float64
    end

    state = ScrollState(0.0, 0.0)

    @doc "Return the latest scroll offsets and clear the stored values."
    global function take_scrollstate!()
        x = state.latest_x
        y = state.latest_y
        state.latest_x = 0.0
        state.latest_y = 0.0
        return (x, y)
    end

    @doc "Accumulate scroll offsets and forward them to CImGui."
    global function scroll_callback(window::GLFW.Window, xoffset::Cdouble, yoffset::Cdouble)
        state.latest_x += xoffset # Accumulate to preserve rapid scroll events
        state.latest_y += yoffset

        CImGui.lib.ImGui_ImplGlfw_ScrollCallback(Ptr{CImGui.lib.GLFWwindow}(window.handle), xoffset, yoffset)
        return nothing
    end
end

#= ---------- FPS Tracking ---------- =#

let
    mutable struct FPSState
        previous::Float64
        frame_count::Int
        smoothed_fps::Float64
    end

    state = FPSState(time(), 0, 0.0)

    @doc "Update the window-title FPS counter using an exponential moving average."
    global function updatefps(window::GLFW.Window, suffix::AbstractString)
        current = time()
        elapsed = current - state.previous

        update_period = 0.1 # Update every 100 ms

        if elapsed > update_period && state.frame_count > 0
            measured_fps = state.frame_count / elapsed
            state.smoothed_fps = state.smoothed_fps * 0.5 + measured_fps * 0.5
            GLFW.SetWindowTitle(window, @sprintf("Rocket Plumber @ fps: %.1f %s", state.smoothed_fps, suffix))

            state.previous = current
            state.frame_count = 0
        end

        state.frame_count += 1
        return nothing
    end
end
