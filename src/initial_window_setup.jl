#=
Scope: Initial window, UI context, input callback, and frame-tracking setup
Formatter: Runic
=#

# ===============================================================
# Initial Setup
# ===============================================================

"Check the Julia thread count and move I/O scheduling to a separate thread."
function configure_threads()
    # Inspect available thread pools
    default_threads = Threads.nthreads(:default)
    interactive_threads = Threads.nthreads(:interactive)
    @info "Julia threads available: default=$(default_threads), interactive=$(interactive_threads)"
    if default_threads < 2
        @warn "Only $(default_threads) default thread(s) available. Consider starting Julia with --threads=2,1 --gcthreads=1,1 for proper FlowCalculator operation"
    end

    Base.Experimental.make_io_thread() # Keep the I/O scheduler clear of blocking OpenGL loops
    return nothing
end

"Global storage for the ImPlot context pointer, managed by `ui_setup` and `ui_teardown`."
const _implot_ctx = Ref{Any}(nothing)

"Perform one-time CImGui and ImPlot context and backend setup."
function ui_setup(window::GLFW.Window)
    # Create shared UI contexts
    CImGui.set_backend(:GlfwOpenGL3)
    ctx = CImGui.CreateContext()
    _implot_ctx[] = ImPlot.CreateContext()
    ImPlot.SetImGuiContext(ctx)
    CImGui.StyleColorsDark()

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
    glClear(GL_COLOR_BUFFER_BIT)

    # Centre loading box in window
    winsize = GLFW.GetWindowSize(window)
    win_w, win_h = Float64(winsize.width), Float64(winsize.height)
    box_w, box_h = 340.0, 110.0
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
        CImGui.Dummy((0.0, 8.0))
        CImGui.Text("Loading...")
        CImGui.Separator()
        CImGui.TextUnformatted(String(status))
        CImGui.End()
    end

    GLFW.SwapBuffers(window)
    GLFW.PollEvents()
    return nothing
end

"Show the loading screen while including a file from this script's directory."
function include_with_loadingscreen(window::GLFW.Window, filename::AbstractString)
    ui_loadingscreen_render(window, "Loading $(basename(filename))")
    return includet(joinpath(dirname(@__FILE__), filename))
end

# ===============================================================
# GLFW Callback and Window Setup
# ===============================================================

const INITIAL_WINDOW_WIDTH = 1920
const INITIAL_WINDOW_HEIGHT = 1080

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
