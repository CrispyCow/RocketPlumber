# ===============================================================
# Start Menu — State Machine, Page Renderers, Action Handling
# ===============================================================

using Random: RandomDevice

# ===============================================================
# Enums
# ===============================================================

"Which page the start menu is currently displaying"
@enum StartMenuPage begin
    PAGE_INITIAL
    PAGE_NEW_GAME
    PAGE_EXPLORER_SETTINGS
end

"Deferred action to execute outside the ImGui frame"
@enum StartMenuAction begin
    ACTION_NONE
    ACTION_NEW_BLANK_MAP
    ACTION_LOAD_MAP
    ACTION_START_DEMO
    ACTION_START_EXPLORER
    ACTION_QUIT
end

# ===============================================================
# State
# ===============================================================

"Mutable state for the start menu loop"
@kwdef mutable struct StartMenuState
    page::StartMenuPage = PAGE_INITIAL
    action::StartMenuAction = ACTION_NONE
    menu_inputs::Dict{Symbol, Any} = Dict{Symbol, Any}()
    last_keystates::Dict{GLFW.Key, Bool} = Dict{GLFW.Key, Bool}()
end

# ===============================================================
# Layout Constants
# ===============================================================

const MENU_BOX_W = 300.0
const MENU_BOX_H = 350.0
const MENU_BUTTON_HEIGHT = 50.0
const MENU_BUTTON_PADDING = 40.0
const MENU_BACK_BUTTON_W = 80.0
const MENU_BACK_BUTTON_H = 30.0

# ===============================================================
# Page Renderers
# ===============================================================

"Render the initial landing page: New Game, Load Game, Demo, Quit"
function render_page_initial!(state::StartMenuState, box_w::Float64, button_width::Float64, button_height::Float64)
    CImGui.Dummy((0.0, 20.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("New Game", (button_width, button_height))
        @info "New Game selected"
        state.page = PAGE_NEW_GAME
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Load Game", (button_width, button_height))
        @info "Load Game selected"
        state.action = ACTION_LOAD_MAP
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Start Demo/Tutorial", (button_width, button_height))
        @info "Demo/Tutorial selected"
        state.action = ACTION_START_DEMO
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.Dummy((0.0, 10.0))
    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Quit", (button_width, button_height))
        @info "Quit selected"
        state.action = ACTION_QUIT
    end

    return nothing
end

"Render the new game page: Explorer Mode, Blank Ship, Back"
function render_page_new_game!(state::StartMenuState, box_w::Float64, button_width::Float64, button_height::Float64, escape_rising::Bool)
    # Small, left-aligned back button
    if CImGui.Button("< Back", (MENU_BACK_BUTTON_W, MENU_BACK_BUTTON_H)) || escape_rising
        state.page = PAGE_INITIAL
        return nothing
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("New Explorer Mode Game", (button_width, button_height))
        @info "Explorer Mode settings selected"
        state.page = PAGE_EXPLORER_SETTINGS
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("New Blank Ship", (button_width, button_height))
        @info "Blank Ship selected"
        state.action = ACTION_NEW_BLANK_MAP
    end

    return nothing
end

"Render the explorer mode settings page: seed input, randomise, start"
function render_page_explorer_settings!(state::StartMenuState, box_w::Float64, button_width::Float64, button_height::Float64, escape_rising::Bool)
    # Small, left-aligned back button
    if CImGui.Button("< Back", (MENU_BACK_BUTTON_W, MENU_BACK_BUTTON_H)) || escape_rising
        state.page = PAGE_NEW_GAME
        return nothing
    end
    CImGui.Dummy((0.0, 10.0))

    # Seed input
    seed_input_width = button_width - 110.0
    CImGui.SetCursorPosX((box_w - button_width) / 2)
    CImGui.SetNextItemWidth(seed_input_width)
    gui_input_u32!(state.menu_inputs, :explorer_seed, "Seed", UInt32(42))
    CImGui.SameLine()
    if CImGui.Button("Randomise", (70.0, 0.0))
        state.menu_inputs[:explorer_seed] = rand(RandomDevice(), UInt32)
    end

    # Spacer for future settings
    CImGui.Dummy((0.0, 80.0))

    # Start button
    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Start Explorer Mode", (button_width, button_height))
        @info "Starting Explorer Mode"
        state.action = ACTION_START_EXPLORER
    end

    return nothing
end

# ===============================================================
# Main UI Dispatch
# ===============================================================

"""
Renders the start menu window, dispatching to the correct page renderer
based on the current state. Must be called within `ui_renderwrap`.
"""
function ui_start_menu_render!(state::StartMenuState, window::GLFW.Window)
    winsize = GLFW.GetWindowSize(window)
    win_w, win_h = Float64(winsize.width), Float64(winsize.height)
    pos = ((win_w - MENU_BOX_W) / 2, (win_h - MENU_BOX_H) / 2)

    CImGui.SetNextWindowPos(pos, CImGui.ImGuiCond_Always)
    CImGui.SetNextWindowSize((MENU_BOX_W, MENU_BOX_H), CImGui.ImGuiCond_Always)

    flags = CImGui.ImGuiWindowFlags_NoResize |
        CImGui.ImGuiWindowFlags_NoMove |
        CImGui.ImGuiWindowFlags_NoCollapse

    # Window title varies by page
    title = if state.page == PAGE_INITIAL
        "Rocket Plumber"
    elseif state.page == PAGE_NEW_GAME
        "Rocket Plumber: New Game"
    elseif state.page == PAGE_EXPLORER_SETTINGS
        "Rocket Plumber: Explorer Mode"
    else
        error("Unhandled start menu page for title: $(state.page)")
    end

    CImGui.Begin(title, C_NULL, flags)

    button_width = MENU_BOX_W - MENU_BUTTON_PADDING
    escape_rising = get_inrising!(state.last_keystates, GLFW.KEY_ESCAPE, window)

    if state.page == PAGE_INITIAL
        render_page_initial!(state, MENU_BOX_W, button_width, MENU_BUTTON_HEIGHT)
    elseif state.page == PAGE_NEW_GAME
        render_page_new_game!(state, MENU_BOX_W, button_width, MENU_BUTTON_HEIGHT, escape_rising)
    elseif state.page == PAGE_EXPLORER_SETTINGS
        render_page_explorer_settings!(state, MENU_BOX_W, button_width, MENU_BUTTON_HEIGHT, escape_rising)
    else
        error("Unhandled start menu page: $(state.page)")
    end

    CImGui.End()

    return nothing
end

# ===============================================================
# Action Handler
# ===============================================================

"""
Handle the latched action from the start menu. Called outside `ui_renderwrap`
to avoid nested ImGui frames when entering the game loop or file dialogs.
Returns `true` if the window should close.
"""
function handle_start_menu_action!(state::StartMenuState, window::GLFW.Window)::Bool
    action = state.action

    # If no action was latched, do nothing
    action == ACTION_NONE && return false

    # if we have an action, reset page to initial for when we return to the start menu
    state.page = PAGE_INITIAL

    # main handler for start menu actions, called after rendering to avoid nested ImGui calls
    if action == ACTION_NEW_BLANK_MAP
        enter_gameloop(window)

    elseif action == ACTION_LOAD_MAP
        maps_path = Path(joinpath(dirname(@__FILE__), "..", "maps"))
        start_dir = isdir(maps_path) ? absolute(maps_path) : Path(homedir())
        file_path = pick_file(start_dir; filterlist = "jld2")
        if !isnothing(file_path)
            @info "Selected file: $file_path"
            enter_gameloop(window, map_source = "$file_path")
        end

    elseif action == ACTION_START_DEMO
        enter_demo(get_demo_vector(), window)

    elseif action == ACTION_START_EXPLORER
        seed = UInt32(get(state.menu_inputs, :explorer_seed, UInt32(42)))
        @info "Generating explorer mode map with seed=$seed"
        ship = generate_starter_ship(seed)
        gamemap = GameMap(ships = Dict(:primary => ship))
        initialise_spacemap!(gamemap, seed, encounter_system_config)
        initialise_encounter_system!(gamemap.space_map)
        enter_gameloop(window, map_source = gamemap)

    elseif action == ACTION_QUIT
        GLFW.SetWindowShouldClose(window, true)
        return true

    else
        error("Unhandled start menu action: $(action)")
    end

    return false
end

# ===============================================================
# Start Menu Loop
# ===============================================================

"""
Enters the start menu loop, rendering the state-machine-driven menu in a 
vsynced loop until window close is requested.
"""
function enter_start_menu(window::GLFW.Window)
    state = StartMenuState()
    GLFW.SetWindowTitle(window, "Rocket Plumber")
    GLFW.SwapInterval(1) # Enable VSync
    glClearColor(0.2, 0.2, 0.2, 1.0) # Set background color to dark gray

    # Main menu loop
    while !GLFW.WindowShouldClose(window)
        GLFW.PollEvents()
        glClear(GL_COLOR_BUFFER_BIT)

        # Render UI and capture action
        state.action = ACTION_NONE
        ui_renderwrap() do
            ui_start_menu_render!(state, window)
        end

        GLFW.SwapBuffers(window)

        # Snapshot post-current-poll state as "last" for next frame's rising-edge checks
        update_lastinstate!(state.last_keystates, window)

        # Handle actions outside ui_renderwrap
        handle_start_menu_action!(state, window)
    end

    @info "Exiting start menu"
    ui_teardown()
    GLFW.DestroyWindow(window)
    return nothing
end
