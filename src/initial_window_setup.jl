#=
Scope: Initial window, UI context, input callback, and frame-tracking setup
Formatter: Runic
=#

# ===============================================================
# Initial Setup
# ===============================================================

"Check the Julia thread count required by the calculator."
function configure_threads()
    # Inspect available thread pools
    default_threads = Threads.nthreads(:default)
    interactive_threads = Threads.nthreads(:interactive)
    @info "Julia threads available: default=$(default_threads), interactive=$(interactive_threads)"
    if default_threads < 2
        @warn "Only $(default_threads) default thread(s) available. Consider starting Julia with --threads=2,1 for proper FlowCalculator operation"
    end

    return nothing
end

"Global storage for the ImPlot context pointer, managed by `ui_setup` and `ui_teardown`."
const _implot_ctx = Ref{Any}(nothing)

"Six shared typography and layout scales: 100%, 133⅓%, 166⅔%, 200%, 233⅓% and 266⅔%."
@enum UIScale UIScale100 = 1 UIScale133 UIScale166 UIScale200 UIScale233 UIScale266
@enum UIFontClass FontStandard = 1 FontLarge FontExtraLarge FontDisplay

const UI_MODULE_PIXELS = (3, 4, 5, 6, 7, 8)

"Return the physical pixel size of one logical UI module without a live UI context."
ui_module_size(scale::UIScale) = UI_MODULE_PIXELS[Int(scale)]

"Convert integer logical modules to exact physical-pixel Float64 dimensions without a UI context."
ui_px(modules::Integer, scale::UIScale = current_ui_scale()) = Float64(modules * ui_module_size(scale))

const UI_FONT_SIZES = (
    (12, 16, 20, 24),
    (16, 20, 24, 32),
    (20, 24, 28, 40),
    (24, 28, 32, 48),
    (28, 32, 40, 56),
    (32, 40, 48, 64),
)
const UI_FONT_SOURCES = Dict(12 => 12, 16 => 16, 20 => 20, 24 => 12, 28 => 14, 32 => 16, 40 => 20, 48 => 12, 56 => 14, 64 => 16)
const TAMZEN_NATIVE_SIZES = (12, 14, 16, 20)
const TAMZEN_FONT_DIR = @path joinpath(@__DIR__, "..", "assets", "fonts", "tamzen")

"Resolve a typography class without accessing a live UI context."
ui_font_size(scale::UIScale, class::UIFontClass) = UI_FONT_SIZES[Int(scale)][Int(class)]

"Resolve the native Tamzen design; unsupported effective sizes fail explicitly."
function ui_font_source(size::Int)
    haskey(UI_FONT_SOURCES, size) || throw(ArgumentError("Unsupported UI font size: $size"))
    return UI_FONT_SOURCES[size]
end

"Native Tamzen fonts indexed by design height and Bold flag, owned by the UI context."
const UI_FONTS = Dict{Tuple{Int, Bool}, Ptr{CImGui.ImFont}}()
const UI_FONT_CONTEXT = Ref{Ptr{CImGui.ImGuiContext}}(C_NULL)

"Unscaled style value owned by the font context; captured after theme setup."
const UI_STYLE_BASELINE = Ref{Union{Nothing, CImGui.ImGuiStyle}}(nothing)

"Select the current scale's class and weight; balance with `CImGui.PopFont()`."
function push_ui_font(class::UIFontClass = FontStandard; bold::Bool = false)
    context = CImGui.GetCurrentContext()
    context != C_NULL && context == UI_FONT_CONTEXT[] || error("UI fonts are not initialised in the current ImGui context")
    size = ui_font_size(current_ui_scale(), class)
    CImGui.PushFont(UI_FONTS[(ui_font_source(size), bold)], size)
    return nothing
end

"Invalidate fonts and the style baseline before destroying their owning UI context."
function clear_ui_fonts!()
    empty!(UI_FONTS)
    UI_FONT_CONTEXT[] = C_NULL
    UI_STYLE_BASELINE[] = nothing
    return nothing
end

"Register eight native designs for on-demand integer enlargement; discard the context on failure."
function initialise_ui_fonts!()
    context = CImGui.GetCurrentContext()
    context == C_NULL && error("UI fonts require a current ImGui context")
    context == UI_FONT_CONTEXT[] && return nothing
    clear_ui_fonts!()
    io = CImGui.GetIO()
    atlas = unsafe_load(io.Fonts)
    directory = String(TAMZEN_FONT_DIR)
    config = CImGui.ImFontConfig()
    try
        config.PixelSnapH = true
        config.OversampleH = 1
        config.OversampleV = 1
        config.FontLoaderFlags = CImGui.ImGuiFreeTypeLoaderFlags_NoHinting # Preserve exact pixel outlines
        for native in TAMZEN_NATIVE_SIZES, bold in (false, true)
            weight = bold ? "b" : "r"
            path = joinpath(directory, "Tamzen$(native ÷ 2)x$(native)$(weight).ttf")
            isfile(path) || error("Missing bundled Tamzen font: $path")
            font = CImGui.AddFontFromFileTTF(atlas, path, native, config)
            font == C_NULL && error("Could not load Tamzen font: $path")
            UI_FONTS[(native, bold)] = font
        end
    finally
        CImGui.Destroy(config)
    end
    UI_FONT_CONTEXT[] = context
    UI_STYLE_BASELINE[] = unsafe_load(CImGui.GetStyle())
    apply_ui_scale!(current_ui_scale())
    return nothing
end

"Restore and scale the original layout, selecting registered fonts between ImGui frames."
function apply_ui_scale!(scale::UIScale)
    context = CImGui.GetCurrentContext()
    context != C_NULL && context == UI_FONT_CONTEXT[] || error("UI fonts are not initialised in the current ImGui context")
    style = CImGui.GetStyle()
    baseline = UI_STYLE_BASELINE[]::CImGui.ImGuiStyle
    colours = unsafe_load(style.Colors)
    unsafe_store!(style, baseline) # ScaleAllSizes truncates pixels; never rescale rounded sizes
    unsafe_store!(style.Colors, colours)
    CImGui.ScaleAllSizes(style, ui_module_size(scale) / ui_module_size(UIScale100))
    # Keep fine window and control outlines in physical pixels
    for field in (:WindowBorderSize, :ChildBorderSize, :PopupBorderSize, :FrameBorderSize)
        unsafe_store!(getproperty(style, field), getfield(baseline, field))
    end

    size = ui_font_size(scale, FontStandard)
    CImGui.GetIO().FontDefault = UI_FONTS[(ui_font_source(size), false)]
    style.FontSizeBase = size
    return nothing
end

"Perform one-time CImGui and ImPlot context and backend setup."
function ui_setup(window::GLFW.Window)
    # Create shared UI contexts
    CImGui.set_backend(:GlfwOpenGL3)
    ctx = CImGui.CreateContext()
    CImGui.StyleColorsDark()

    # Keep all typography on native or integer-enlarged Tamzen designs
    try
        initialise_ui_fonts!()
    catch
        clear_ui_fonts!()
        CImGui.DestroyContext(ctx)
        rethrow()
    end

    _implot_ctx[] = ImPlot.CreateContext()
    ImPlot.SetImGuiContext(ctx)

    # Initialise platform and renderer backends
    CImGui.lib.ImGui_ImplGlfw_InitForOpenGL(Ptr{CImGui.lib.GLFWwindow}(window.handle), true)
    CImGui.lib.ImGui_ImplOpenGL3_Init("#version 330")
    return ctx
end

"Tear down the CImGui and ImPlot backends and contexts in dependency order."
function ui_teardown()
    # Shut down renderer and platform backends
    CImGui.lib.ImGui_ImplOpenGL3_Shutdown()
    CImGui.lib.ImGui_ImplGlfw_Shutdown()

    # Destroy plotting and UI contexts
    if !isnothing(_implot_ctx[])
        ImPlot.DestroyContext(_implot_ctx[])
        _implot_ctx[] = nothing
    end
    clear_ui_fonts!()
    CImGui.DestroyContext()
    return nothing
end

"Wrap CImGui user code in the required frame context."
function ui_renderwrap(usercode::Function)
    # Begin UI frame
    CImGui.lib.ImGui_ImplOpenGL3_NewFrame()
    CImGui.lib.ImGui_ImplGlfw_NewFrame()
    CImGui.NewFrame()

    usercode()

    # Render collected draw data
    CImGui.Render()
    CImGui.lib.ImGui_ImplOpenGL3_RenderDrawData(Ptr{Cint}(CImGui.GetDrawData()))
    return nothing
end

"""
Renders a single loading frame with centred status text. Safe to call at
checkpoints during startup; assumes ImGui + GL context already initialised.
"""
function ui_loadingscreen_render(window::GLFW.Window, status::AbstractString = "Initialising")
    GLFW.WindowShouldClose(window) && return # Honour close requests during startup
    fbsize = GLFW.GetFramebufferSize(window)
    glViewport(0, 0, fbsize.width, fbsize.height)
    glClear(GL_COLOR_BUFFER_BIT)

    # Centre loading box in window
    winsize = GLFW.GetWindowSize(window)
    win_w, win_h = Float64(winsize.width), Float64(winsize.height)
    box_w, box_h = ui_px(85), ui_px(28)
    pos = ((win_w - box_w) / 2, (win_h - box_h) / 2)

    # Draw startup status
    ui_renderwrap() do
        CImGui.SetNextWindowPos(pos, CImGui.ImGuiCond_Always)
        CImGui.SetNextWindowSize((box_w, box_h), CImGui.ImGuiCond_Always)
        flags = CImGui.ImGuiWindowFlags_NoResize |
            CImGui.ImGuiWindowFlags_NoMove |
            CImGui.ImGuiWindowFlags_NoCollapse |
            CImGui.ImGuiWindowFlags_NoTitleBar
        CImGui.Begin("LoadingScreen", C_NULL, flags)
        CImGui.Dummy((0.0, ui_px(2)))
        push_ui_font(; bold = true)
        CImGui.Text("Loading...")
        CImGui.PopFont()
        CImGui.Separator()
        CImGui.TextUnformatted(String(status))
        CImGui.End()
    end

    GLFW.SwapBuffers(window)
    apply_pending_settings!(window)
    GLFW.PollEvents()
    poll_application_shortcuts!(window)
    return nothing
end

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

"Return the monitor containing the window's centre, falling back to the primary monitor."
function window_monitor(window::GLFW.Window)
    primary = GLFW.GetPrimaryMonitor()
    platform = GLFW.GetPlatform()
    if platform != GLFW.PLATFORM_WIN32 && platform != GLFW.PLATFORM_X11
        return primary
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

    return primary
end

"Read the actual native fullscreen mode from GLFW rather than caching it."
window_is_fullscreen(window::GLFW.Window) = GLFW.GetWindowMonitor(window).handle != C_NULL

"Apply the configured swap interval to the current OpenGL context."
apply_vsync!(enabled::Bool) = GLFW.SwapInterval(enabled ? 1 : 0)

"Apply native fullscreen, preserving windowed restoration data; return the actual resulting mode."
function apply_fullscreen!(state::WindowModeState, window::GLFW.Window, enabled::Bool)
    window_is_fullscreen(window) == enabled && return enabled

    if enabled
        monitor = window_monitor(window)
        mode = GLFW.GetVideoMode(monitor)
        state.was_maximised = GLFW.GetWindowAttrib(window, GLFW.MAXIMIZED) != 0
        size = GLFW.GetWindowSize(window)
        state.windowed_width, state.windowed_height = size.width, size.height
        # Native Wayland leaves placement to the compositor
        if GLFW.GetPlatform() != GLFW.PLATFORM_WAYLAND
            position = GLFW.GetWindowPos(window)
            state.windowed_x, state.windowed_y = position.x, position.y
        end
    end

    if enabled
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
    @static if Sys.isapple()
        # macOS maximum OpenGL version is 4.1
        VERSION_MAJOR = 4
        VERSION_MINOR = 1
        GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, VERSION_MAJOR)
        GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, VERSION_MINOR)
        GLFW.WindowHint(GLFW.OPENGL_PROFILE, GLFW.OPENGL_CORE_PROFILE)
        GLFW.WindowHint(GLFW.OPENGL_FORWARD_COMPAT, GL_TRUE)
    else
        GLFW.DefaultWindowHints()
    end

    GLFW.WindowHint(GLFW.SAMPLES, 0) # disable MSAA

    @info "Starting GLFW (minimal)..."
    @info GLFW.GetVersionString()

    window = GLFW.CreateWindow(width, height, "Rocket Plumber Loading")
    @assert window != C_NULL "Could not open window with GLFW3"

    GLFW.MakeContextCurrent(window)
    apply_vsync!(app_state().settings.vsync)

    return window
end

"""
Attaches standard callbacks and logs GPU capability information.
Separated from window creation to support staged loading flow.
Safe to call exactly once after `startgl_minimal`.
"""
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

#= ---------- Window Creation ---------- =#

"Start a window using the required GLFW, OpenGL, and CImGui setup sequence."
function start_window()
    _window::Union{Nothing, GLFW.Window} = nothing
    @eval CImGui._current_window(::Val{:GlfwOpenGL3}) = _window # Evaluated in global scope

    # Create window and UI contexts
    _window = startgl_minimal(INITIAL_WINDOW_WIDTH, INITIAL_WINDOW_HEIGHT)
    window = _window
    GLFW.MakeContextCurrent(window)
    ui_setup(window)

    # Configure rendering defaults
    glClearColor(0.1, 0.1, 0.1, 1.0)
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

    return window
end
