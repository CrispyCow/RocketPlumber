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
    PAGE_TUTORIAL_SELECT
end

"Deferred action to execute outside the ImGui frame"
@enum StartMenuAction begin
    ACTION_NONE
    ACTION_NEW_BLANK_MAP
    ACTION_LOAD_MAP
    ACTION_START_EXPLORER
    ACTION_LAUNCH_SANDBOX
    ACTION_QUIT
end

# ===============================================================
# Session State Machine Types
# ===============================================================

"Abstract session type for the start-menu state machine."
abstract type GameSession end

"Map session for blank maps, loaded maps, and explorer mode."
struct MapSession <: GameSession
    map_source::Union{Nothing, GameMap}
    initial_active_tutorial_id::Union{Nothing, Symbol}
end

MapSession(map_source) = MapSession(map_source, nothing)

"Sandbox tutorial session with level progression and optional parent explorer map."
struct SandboxSession <: GameSession
    definition::SandboxTutorialDef
    tutorial_id::Symbol
    current_level::Int
    parent_map::Union{Nothing, GameMap}
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
    selected_tutorial_id::Union{Nothing, Symbol} = nothing
    sandbox_entries::Vector{LearningEntry} = sort(get_sandbox_learning_entries(); by = entry -> entry.priority)
end

# ===============================================================
# Layout Constants
# ===============================================================

const MENU_BOX_W = 350.0
const MENU_BOX_H = 420.0
const MENU_TUTORIAL_BOX_H = 520.0
const MENU_BUTTON_HEIGHT = 50.0
const MENU_BUTTON_PADDING = 40.0
const MENU_BACK_BUTTON_W = 80.0
const MENU_BACK_BUTTON_H = 30.0

# ===============================================================
# Page Renderers
# ===============================================================

"Render the initial landing page: New Game, Load Game, Tutorials, Quit."
function render_page_initial!(state::StartMenuState, box_w::Float64, button_width::Float64, button_height::Float64)
    CImGui.Dummy((0.0, 20.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Launch Teaser", (button_width, button_height))
        @info "Launch Teaser selected"
        state.selected_tutorial_id = :teaser
        state.action = ACTION_LAUNCH_SANDBOX
    end
    if CImGui.IsItemHovered()
        CImGui.SetTooltip("Launch a teaser map to get a taste for what's possible. Try this first if it's your first time playing.")
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("New Game", (button_width, button_height))
        @info "New Game selected"
        state.page = PAGE_NEW_GAME
    end
    if CImGui.IsItemHovered()
        CImGui.SetTooltip("Create a new game.")
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Load Game", (button_width, button_height))
        @info "Load Game selected"
        state.action = ACTION_LOAD_MAP
    end
    if CImGui.IsItemHovered()
        CImGui.SetTooltip("Load a saved game from a save file.")
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Tutorials", (button_width, button_height))
        @info "Tutorials selected"
        state.page = PAGE_TUTORIAL_SELECT
    end
    if CImGui.IsItemHovered()
        CImGui.SetTooltip("Access the game's tutorials and demos outside of the in-game learning system.")
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
    if CImGui.IsItemHovered()
        CImGui.SetTooltip("Start a new exploration game where you begin in a simple ship you need to repair and navigate through space. RECOMMENDED STARTING POINT")
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("New Blank Ship", (button_width, button_height))
        @info "Blank Ship selected"
        state.action = ACTION_NEW_BLANK_MAP
    end
    if CImGui.IsItemHovered()
        CImGui.SetTooltip("Create a new blank ship with no components on it. Intended for use in creative/editor mode or debugging.")
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

    learning_enabled = Bool(get!(state.menu_inputs, :explorer_learning_enabled, true))
    @cref CImGui.Checkbox("Learning Helper Active", &learning_enabled)
    state.menu_inputs[:explorer_learning_enabled] = learning_enabled

    # Spacer for future settings
    CImGui.Dummy((0.0, 60.0))

    # Start button
    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Start Explorer Mode", (button_width, button_height))
        @info "Starting Explorer Mode"
        state.action = ACTION_START_EXPLORER
    end

    return nothing
end

"Render the tutorial selector page."
function render_page_tutorial_select!(state::StartMenuState, box_w::Float64, button_width::Float64, button_height::Float64, escape_rising::Bool)
    if CImGui.Button("< Back", (MENU_BACK_BUTTON_W, MENU_BACK_BUTTON_H)) || escape_rising
        state.page = PAGE_INITIAL
        return nothing
    end

    CImGui.Dummy((0.0, 10.0))
    CImGui.Text("Tutorials & Demos")
    CImGui.Separator()
    CImGui.Dummy((0.0, 5.0))
    CImGui.Text("Individual Tutorials:")
    CImGui.Dummy((0.0, 5.0))

    for entry in state.sandbox_entries
        def = entry.definition

        CImGui.SetCursorPosX((box_w - button_width) / 2)
        if CImGui.Button(def.title, (button_width, 35.0))
            state.selected_tutorial_id = entry.id
            state.action = ACTION_LAUNCH_SANDBOX
        end

        if CImGui.IsItemHovered()
            CImGui.SetTooltip(def.description)
        end
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
    box_h = state.page == PAGE_TUTORIAL_SELECT ? MENU_TUTORIAL_BOX_H : MENU_BOX_H
    pos = ((win_w - MENU_BOX_W) / 2, (win_h - box_h) / 2)

    CImGui.SetNextWindowPos(pos, CImGui.ImGuiCond_Always)
    CImGui.SetNextWindowSize((MENU_BOX_W, box_h), CImGui.ImGuiCond_Always)

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
    elseif state.page == PAGE_TUTORIAL_SELECT
        "Rocket Plumber: Tutorials"
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
    elseif state.page == PAGE_TUTORIAL_SELECT
        render_page_tutorial_select!(state, MENU_BOX_W, button_width, MENU_BUTTON_HEIGHT, escape_rising)
    else
        error("Unhandled start menu page: $(state.page)")
    end

    CImGui.End()

    return nothing
end

# ===============================================================
# Session Helpers
# ===============================================================

"Look up a sandbox tutorial definition by ID, returning `nothing` when invalid or empty."
function _find_sandbox_definition(id::Symbol)::Union{Nothing, SandboxTutorialDef}
    entries = get_sandbox_learning_entries()
    entry_idx = findfirst(entry -> entry.id == id, entries)
    isnothing(entry_idx) && return nothing

    definition = entries[entry_idx].definition
    definition isa SandboxTutorialDef || return nothing
    isempty(definition.levels) && return nothing
    return definition
end

"Run a map session by entering the main game loop with its map source."
function run_session(window::GLFW.Window, session::MapSession)::GameLoopResult
    return enter_gameloop(window; map_source = session.map_source, initial_active_tutorial_id = session.initial_active_tutorial_id)
end

"Run a sandbox tutorial session for the current level."
function run_session(window::GLFW.Window, session::SandboxSession)::GameLoopResult
    level = session.definition.levels[session.current_level]
    sandbox_map = level.map_generator()
    set_learning_system!(
        sandbox_map,
        SandboxLearningState(tutorial_id = session.tutorial_id, level_index = session.current_level),
    )
    return enter_gameloop(window; map_source = sandbox_map)
end

"Determine the next session after a map session exits."
function next_session(::MapSession, result::GameLoopResult)::Union{Nothing, GameSession}
    result.exit_reason == EXIT_RESTART && return MapSession(result.saved_gamemap)

    if result.exit_reason == EXIT_SANDBOX_STARTED && !isnothing(result.tutorial_id)
        definition = _find_sandbox_definition(result.tutorial_id)
        isnothing(definition) && return nothing
        return SandboxSession(definition, result.tutorial_id, 1, result.saved_gamemap)
    end

    return nothing
end

"Determine the next session after a sandbox session exits."
function next_session(session::SandboxSession, result::GameLoopResult)::Union{Nothing, GameSession}
    if result.exit_reason == EXIT_SANDBOX_COMPLETED
        if session.current_level < length(session.definition.levels)
            return SandboxSession(session.definition, session.tutorial_id, session.current_level + 1, session.parent_map)
        end

        if !isnothing(session.parent_map)
            learning_system = get_learning_system(session.parent_map)
            if learning_system isa LearningProgress
                complete_tutorial!(learning_system, session.tutorial_id)
            end
        end

        return !isnothing(session.parent_map) ? MapSession(session.parent_map) : nothing
    end

    if result.exit_reason == EXIT_MENU
        return !isnothing(session.parent_map) ? MapSession(session.parent_map) : nothing
    end

    return nothing
end

"Create the initial session for a start-menu action."
function _create_session_for_action(state::StartMenuState, action::StartMenuAction, window::GLFW.Window)::Union{Nothing, GameSession}
    if action == ACTION_NEW_BLANK_MAP
        gamemap = GameMap()
        learning_system = LearningProgress(get_blank_map_learning_entry_ids())
        set_learning_system!(gamemap, learning_system)
        activate_tutorial!(learning_system, :editor_intro)
        return MapSession(gamemap, :editor_intro)

    elseif action == ACTION_LOAD_MAP
        maps_path = Path(joinpath(dirname(@__FILE__), "..", "maps"))
        start_dir = isdir(maps_path) ? absolute(maps_path) : Path(homedir())
        file_path = pick_file(start_dir; filterlist = "jld2")
        isnothing(file_path) && return nothing

        @info "Selected file: $file_path"
        return MapSession(loadmap_from_source("$file_path"))

    elseif action == ACTION_START_EXPLORER
        seed = UInt32(get(state.menu_inputs, :explorer_seed, UInt32(42)))
        learning_enabled = Bool(get(state.menu_inputs, :explorer_learning_enabled, true))
        @info "Generating explorer mode map with seed=$seed"

        blueprint = generate_starter_ship(seed)
        gamemap = GameMap(blueprint)
        initialise_spacemap!(gamemap, seed, encounter_system_config)
        initialise_encounter_system!(gamemap.space_map)
        learning_system = learning_enabled ? LearningProgress(get_explorer_learning_entry_ids()) : NoLearningSystem()
        set_learning_system!(gamemap, learning_system)
        if learning_system isa LearningProgress
            activate_tutorial!(learning_system, :welcome_explorer)
        end

        return MapSession(gamemap, :welcome_explorer)

    elseif action == ACTION_LAUNCH_SANDBOX
        id = state.selected_tutorial_id
        isnothing(id) && return nothing

        definition = _find_sandbox_definition(id)
        isnothing(definition) && return nothing
        return SandboxSession(definition, id, 1, nothing)

    elseif action == ACTION_QUIT
        GLFW.SetWindowShouldClose(window, true)
        return nothing
    end

    error("Unhandled start menu action: $(action)")
end

# ===============================================================
# Action Handler
# ===============================================================

"""
Handle the latched action from the start menu. Called outside `ui_renderwrap`
to avoid nested ImGui frames when entering the game loop or file dialogs.

Creates an initial session for the action, then runs the session state machine
until it returns `nothing` or the GLFW window-close flag is set.
"""
function handle_start_menu_action!(state::StartMenuState, window::GLFW.Window)
    action = state.action

    action == ACTION_NONE && return nothing
    state.page = PAGE_INITIAL

    session = _create_session_for_action(state, action, window)
    isnothing(session) && return nothing

    while !isnothing(session) && !GLFW.WindowShouldClose(window)
        result = run_session(window, session)
        session = next_session(session, result)
    end

    return nothing
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
