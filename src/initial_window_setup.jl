#=
Scope: Application thread checks, graphical UI setup, typography, and loading screens
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

#= ---------- Window Creation ---------- =#

"Start a window using the required GLFW, OpenGL, and CImGui setup sequence."
function start_window()
    _window::Union{Nothing, GLFW.Window} = nothing
    @eval CImGui._current_window(::Val{:GlfwOpenGL3}) = _window # Evaluated in global scope

    # Create window and UI contexts
    _window = startgl_minimal(INITIAL_WINDOW_WIDTH, INITIAL_WINDOW_HEIGHT)
    window = _window
    ui_setup(window)

    # Configure rendering defaults
    glClearColor(0.1, 0.1, 0.1, 1.0)
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

    return window
end
