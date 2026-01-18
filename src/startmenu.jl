# ===============================================================
# Start Menu UI Helpers
# ===============================================================

@kwdef mutable struct StartMenuState
    action::Symbol = :none
end

"""
Renders the start menu with centered menu box and buttons.
Mutates state.action to indicate what action should be taken:
- :none - continue showing menu
- :new_map - launch new map
- :test_map - launch test map
- :quit - exit application
Must be called within ui_renderwrap.
"""
function ui_start_menu_render!(state::StartMenuState, window::GLFW.Window)
    winsize = GLFW.GetWindowSize(window)
    win_w, win_h = Float64(winsize.width), Float64(winsize.height)

    # Menu box dimensions
    box_w, box_h = 300.0, 350.0
    pos = ((win_w - box_w) / 2, (win_h - box_h) / 2)

    CImGui.SetNextWindowPos(pos, CImGui.ImGuiCond_Always)
    CImGui.SetNextWindowSize((box_w, box_h), CImGui.ImGuiCond_Always)

    flags = CImGui.ImGuiWindowFlags_NoResize |
        CImGui.ImGuiWindowFlags_NoMove |
        CImGui.ImGuiWindowFlags_NoCollapse

    CImGui.Begin("Rocket Plumber: Menu", C_NULL, flags)
    CImGui.Dummy((0.0, 20.0)) # title padding

    # Calculate button width (fill most of window width with padding)
    button_width = box_w - 40.0
    button_height = 50.0

    action = :none

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Open Blank Map", (button_width, button_height))
        @info "New Map selected"
        action = :new_map
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Select Map to Load", (button_width, button_height))
        @info "Load Map selected"
        action = :load_map
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Start Demo/Tutorial", (button_width, button_height))
        @info "Demo/Tutorial selected"
        action = :demo
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.Dummy((0.0, 10.0)) # extra padding before quit button
    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Quit", (button_width, button_height))
        @info "Quit selected"
        action = :quit
    end

    CImGui.End()

    if state.action == :none # prioritises any existing non-none action
        state.action = action
    end
    return nothing
end



# ===============================================================
# Start Menu Loop
# ===============================================================

"""
Enters the start menu loop, rendering the menu in a vsynced loop
until window close is requested.
"""
function enter_start_menu(window::GLFW.Window)
    state = StartMenuState()
    GLFW.SetWindowTitle(window, "Rocket Plumber")
    GLFW.SwapInterval(1) # Enable VSync
    glClearColor(0.2, 0.2, 0.2, 1.0) # Set background color to dark gray

    # Main menu loop
    while !GLFW.WindowShouldClose(window)
        glClear(GL_COLOR_BUFFER_BIT)

        # Render UI and capture action
        state.action = :none
        ui_renderwrap() do
            ui_start_menu_render!(state, window)
        end
        action = state.action

        GLFW.SwapBuffers(window)
        GLFW.PollEvents()

        # Handle actions OUTSIDE of ui_renderwrap to avoid nested ImGui frames
        if action == :new_map
            enter_gameloop(window)

        elseif action == :load_map
            # Check if maps directory exists, fallback to user home directory if not
            maps_path = Path(joinpath(dirname(@__FILE__), "..", "maps"))
            start_dir = isdir(maps_path) ? absolute(maps_path) : Path(homedir())
            
            file_path = pick_file(start_dir; filterlist = "jld2")
            if !isnothing(file_path)
                @info "Selected file: $file_path"
                enter_gameloop(window, map_source = "$file_path")
            end

        elseif action == :demo
            enter_demo(get_demo_vector(), window)

        elseif action == :quit
            GLFW.SetWindowShouldClose(window, true)

        end
    end

    @info "Exiting start menu"
    ui_teardown()
    GLFW.DestroyWindow(window)
    return nothing
end
