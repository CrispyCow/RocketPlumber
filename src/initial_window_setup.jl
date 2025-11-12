# ===============================================================
# Initial Setup
# ===============================================================

"Checks Julia thread count and moves IO to separate thread"
function configure_threads()
    # Check threads (at least 2 required so FlowCalculator can run in background)
    @info "Julia threads available: $(Threads.nthreads())"
    if Threads.nthreads() < 2
        @warn "Only $(Threads.nthreads()) thread(s) available. Consider starting Julia with --threads=auto or --threads=2 for proper FlowCalculator operation"
    end
    Base.Experimental.make_io_thread() # Move scheduler to different thread so it's not blocked by OpenGL loops
    return nothing
end

"Runs one-time minimal CImGui setup (loader path)"
function ui_setup(window::GLFW.Window)
    CImGui.set_backend(:GlfwOpenGL3)
    ctx = CImGui.CreateContext()
    CImGui.StyleColorsDark()
    CImGui.lib.ImGui_ImplGlfw_InitForOpenGL(Ptr{CImGui.lib.GLFWwindow}(window.handle), true)
    CImGui.lib.ImGui_ImplOpenGL3_Init("#version 330")
    return ctx
end

"Runs CImGui cleanup/teardown in the correct order (renderer → platform → context)"
function ui_teardown()
    CImGui.lib.ImGui_ImplOpenGL3_Shutdown()
    CImGui.lib.ImGui_ImplGlfw_Shutdown()
    CImGui.DestroyContext()
    return nothing
end

"Wraps CImGui user code in the required frame context to render"
function ui_renderwrap(usercode::Function)
    CImGui.lib.ImGui_ImplOpenGL3_NewFrame()
    CImGui.lib.ImGui_ImplGlfw_NewFrame()
    CImGui.NewFrame()

    usercode()

    CImGui.Render()
    CImGui.lib.ImGui_ImplOpenGL3_RenderDrawData(Ptr{Cint}(CImGui.GetDrawData()))
    return nothing
end

"""
Renders a single loading frame with centred status text. Safe to call at
checkpoints during startup; assumes ImGui + GL context already initialised.
"""
function ui_loadingscreen_render(window::GLFW.Window, status::AbstractString = "Initialising")
    GLFW.WindowShouldClose(window) && return # Exit early if window close requested
    glClear(GL_COLOR_BUFFER_BIT)

    # Center loading box in window
    winsize = GLFW.GetWindowSize(window)
    win_w, win_h = Float64(winsize.width), Float64(winsize.height)
    box_w, box_h = 340.0, 110.0
    pos = ((win_w - box_w) / 2, (win_h - box_h) / 2)

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

"Helper to show loading screen while including a file from this script's directory"
function include_with_loadingscreen(window::GLFW.Window, filename::AbstractString)
    ui_loadingscreen_render(window, "Loading $(basename(filename))")
    return includet(joinpath(dirname(@__FILE__), filename))
end

# ===============================================================
# GLFW Callback and Window Setup
# ===============================================================

"GLFW error callback for logging"
error_callback(err::GLFW.GLFWError) = @error "GLFW ERROR: code $(err.code) msg: $(err.description)"


"""
Creates a GLFW window and current OpenGL context with minimal setup.
Intentionally defers installing callbacks so that a lightweight loading screen
can be shown before the full game state is loaded.
"""
function startgl_minimal(width, height)
    GLFW.SetErrorCallback(error_callback)

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
    GLFW.SetInputMode(window, GLFW.STICKY_MOUSE_BUTTONS, true)
    GLFW.SetInputMode(window, GLFW.STICKY_KEYS, true)
    # Scroll cannot be polled; keys and sizes are polled
    GLFW.SetScrollCallback(window, scroll_callback)

    # Log GPU capabilities (now that context is current)
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

    "Returns the latest scroll offsets and clears the stored values"
    global function take_scrollstate!()
        x = state.latest_x
        y = state.latest_y
        state.latest_x = 0.0
        state.latest_y = 0.0
        return (x, y)
    end

    "Stores the latest scroll offsets (GLFW callback)"
    global function scroll_callback(window::GLFW.Window, xoffset::Cdouble, yoffset::Cdouble)
        state.latest_x = xoffset
        state.latest_y = yoffset
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

    "Updates FPS counter in window title using exponential moving average"
    global function updatefps(window::GLFW.Window)
        current = time()
        elapsed = current - state.previous

        update_period = 0.1 # Update every 100ms

        if elapsed > update_period && state.frame_count > 0
            measured_fps = state.frame_count / elapsed
            state.smoothed_fps = state.smoothed_fps * 0.5 + measured_fps * 0.5  # Exponential moving average
            GLFW.SetWindowTitle(window, @sprintf("opengl @ fps: %.2f", state.smoothed_fps))

            state.previous = current
            state.frame_count = 0
        end

        state.frame_count += 1
        return nothing
    end
end

#= ---------- Window Creation ---------- =#

"Starts a window, following the required sequence for GLFW + OpenGL + CImGui"
function start_window()
    _window::Union{Nothing, GLFW.Window} = nothing
    @eval CImGui._current_window(::Val{:GlfwOpenGL3}) = _window # Eval executed in global scope
    _window = startgl_minimal(800, 600)  # Temporary size; will sync into g_viewstate later
    window = _window
    GLFW.MakeContextCurrent(window)
    ui_setup(window)

    # Set grey background and enable alpha blending
    glClearColor(0.1, 0.1, 0.1, 1.0)
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

    return window
end
