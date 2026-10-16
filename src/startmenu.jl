#=
Scope: Start-menu pages, actions, and session transitions into the game loop
Formatter: Runic
=#

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
    bundle::GameMapBundle
    initial_active_tutorial_id::Union{Nothing, Symbol}
end

MapSession(bundle::GameMapBundle) = MapSession(bundle, nothing)
MapSession(gamemap::GameMap, initial_active_tutorial_id::Union{Nothing, Symbol} = nothing) =
    MapSession(GameMapBundle(gamemap), initial_active_tutorial_id)

"Sandbox tutorial session with level progression and optional parent explorer map."
struct SandboxSession <: GameSession
    definition::SandboxTutorialDef
    tutorial_id::Symbol
    current_level::Int
    parent_bundle::Union{Nothing, GameMapBundle}
end

# ===============================================================
# State
# ===============================================================

"Mutable state for the start menu loop"
@kwdef mutable struct StartMenuState
    window_mode::WindowModeState = WindowModeState()
    page::StartMenuPage = PAGE_INITIAL
    action::StartMenuAction = ACTION_NONE
    menu_inputs::Dict{Symbol, Any} = Dict{Symbol, Any}()
    last_keystates::Dict{GLFW.Key, Bool} = Dict{GLFW.Key, Bool}()
    selected_tutorial_id::Union{Nothing, Symbol} = nothing
    load_error::String = ""
    sandbox_entries::Vector{LearningEntry} = sort(get_sandbox_learning_entries(); by = entry -> entry.priority)
end

# ===============================================================
# Layout Constants
# ===============================================================

const MENU_BOX_W = 350.0
const MENU_INITIAL_BOX_W = 850.0
const MENU_BOX_H = 420.0
const MENU_INITIAL_BOX_H = 500.0
const MENU_TUTORIAL_BOX_H = 520.0
const MENU_BUTTON_HEIGHT = 50.0
const MENU_BUTTON_PADDING = 40.0
const MENU_BACK_BUTTON_W = 80.0
const MENU_BACK_BUTTON_H = 30.0
const MENU_MUTED_TEXT = ImVec4(0.75, 0.77, 0.8, 1.0)

# ===============================================================
# Page Renderers
# ===============================================================

"Render the initial start-menu page."
function render_page_initial!(state::StartMenuState, box_w::Float64, button_width::Float64, button_height::Float64)
    table_flags = CImGui.ImGuiTableFlags_BordersInnerV | CImGui.ImGuiTableFlags_NoPadOuterX
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_CellPadding, ImVec2(12.0, 0.0))
    table_visible = CImGui.BeginTable("##start_menu_columns", 2, table_flags)
    CImGui.PopStyleVar()
    table_visible || return nothing
    CImGui.TableSetupColumn("Actions", CImGui.ImGuiTableColumnFlags_WidthFixed, box_w + 12.0)
    CImGui.TableSetupColumn("Contact", CImGui.ImGuiTableColumnFlags_WidthStretch)
    CImGui.TableNextColumn()

    # Original game controls in the left column
    CImGui.BeginChild("##start_menu_actions", (box_w, 0.0))
    if isempty(state.load_error)
        CImGui.Dummy((0.0, 20.0))
    else
        CImGui.TextWrapped(state.load_error)
    end

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Launch Teaser", (button_width, button_height))
        @info "Launch Teaser selected"
        state.selected_tutorial_id = :teaser
        state.action = ACTION_LAUNCH_SANDBOX
    end
    if CImGui.IsItemHovered()
        CImGui.SetTooltip("Explore a showcase ship and get a tease of what's possible in Rocket Plumber. A good place to start if you're new to the game!")
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("New Game", (button_width, button_height))
        @info "New Game selected"
        state.page = PAGE_NEW_GAME
    end
    if CImGui.IsItemHovered()
        CImGui.SetTooltip("Start Explorer Mode for the main game, with guidance as you play, or create a blank ship to experiment.")
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
        CImGui.SetTooltip("Replay tutorials and demos at any time outside of Explorer Mode's Learning System.")
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.Dummy((0.0, 10.0))
    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Quit", (button_width, button_height))
        @info "Quit selected"
        state.action = ACTION_QUIT
    end
    CImGui.EndChild()

    # Contact sections in the wider right column
    CImGui.TableNextColumn()
    contact_start_x = CImGui.GetCursorPosX()
    contact_width = CImGui.GetContentRegionAvail().x
    CImGui.Dummy((0.0, 20.0))
    CImGui.PushFont(UI_VECTOR_FONT, 21.0)
    CImGui.SeparatorText("Stay Updated")
    CImGui.PopFont()
    CImGui.Spacing()

    CImGui.PushStyleColor(CImGui.ImGuiCol_Text, MENU_MUTED_TEXT)
    CImGui.TextWrapped("Get game updates, development blog posts, and exclusive content straight to your inbox.")
    CImGui.PopStyleColor()
    CImGui.Dummy((0.0, 20.0))

    CImGui.PushFont(UI_VECTOR_FONT, 18.0)
    mailing_list_label = "Join the Mailing List!"
    CImGui.SetCursorPosX(contact_start_x + (contact_width - CImGui.CalcTextSize(mailing_list_label).x) / 2)
    CImGui.TextLinkOpenURL(mailing_list_label * "##mailing_list", "https://rocketplumbergame.com/mailing-list/")
    CImGui.PopFont()
    CImGui.Dummy((0.0, 56.0))

    CImGui.PushFont(UI_VECTOR_FONT, 21.0)
    CImGui.SeparatorText("Get in Touch")
    CImGui.PopFont()
    CImGui.Dummy((0.0, 8.0))

    CImGui.PushStyleColor(CImGui.ImGuiCol_Text, MENU_MUTED_TEXT)
    CImGui.TextWrapped("Found a bug?\nHave a suggestion?\nWant to show off your ship?\n\nSend me an email, I'm keen to hear what you think!")
    CImGui.PopStyleColor()
    CImGui.Dummy((0.0, 12.0))

    # Reserve the same button width for Copy and Copied! to keep the group centred
    copy_button_width = 65.0
    feedback_width = CImGui.CalcTextSize("feedback@rocketplumbergame.com").x + 10.0 + copy_button_width
    CImGui.SetCursorPosX(contact_start_x + (contact_width - feedback_width) / 2)
    CImGui.AlignTextToFramePadding()
    CImGui.TextLinkOpenURL("feedback@rocketplumbergame.com", "mailto:feedback@rocketplumbergame.com?subject=Rocket%20Plumber%20Feedback")
    CImGui.SameLine(0.0, 10.0)

    copied = CImGui.GetTime() < get(state.menu_inputs, :email_copied_until, 0.0)
    if CImGui.Button(copied ? "Copied!###copy_email" : "Copy###copy_email", (copy_button_width, 22.0))
        CImGui.SetClipboardText("feedback@rocketplumbergame.com")
        state.menu_inputs[:email_copied_until] = CImGui.GetTime() + 2.0
    end
    CImGui.EndTable()

    return nothing
end

"Render the new-game mode selection page."
function render_page_new_game!(state::StartMenuState, box_w::Float64, button_width::Float64, button_height::Float64, escape_rising::Bool)
    if CImGui.Button("< Back", (MENU_BACK_BUTTON_W, MENU_BACK_BUTTON_H)) || escape_rising
        state.page = PAGE_INITIAL
        return nothing
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.TextWrapped("New to Rocket Plumber? Start with Explorer Mode. The Learning System will introduce tips and tutorials as you play.")
    CImGui.Dummy((0.0, 20.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    explorer_clicked = CImGui.Button("##explorer_mode", (button_width, button_height))
    # Centre each line independently over the normal button
    button_min = CImGui.GetItemRectMin()
    button_size = CImGui.GetItemRectSize()
    line_height = CImGui.GetTextLineHeight()
    text_y = button_min.y + (button_size.y - 2 * line_height) / 2
    for (line_index, line) in enumerate(("Explorer Mode", "(Recommended)"))
        text_x = button_min.x + (button_size.x - CImGui.CalcTextSize(line).x) / 2
        CImGui.AddText(CImGui.GetWindowDrawList(), ImVec2(text_x, text_y + (line_index - 1) * line_height), CImGui.GetColorU32(CImGui.ImGuiCol_Text), line)
    end
    if explorer_clicked
        @info "Explorer Mode settings selected"
        state.menu_inputs[:explorer_seed] = rand(RandomDevice(), UInt32)
        state.page = PAGE_EXPLORER_SETTINGS
    end
    if CImGui.IsItemHovered()
        CImGui.SetTooltip("Repair your ship, salvage parts and fuel, and work towards escaping the galaxy.")
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

"Render the explorer-mode settings page."
function render_page_explorer_settings!(state::StartMenuState, box_w::Float64, button_width::Float64, button_height::Float64, escape_rising::Bool)
    if CImGui.Button("< Back", (MENU_BACK_BUTTON_W, MENU_BACK_BUTTON_H)) || escape_rising
        state.page = PAGE_NEW_GAME
        return nothing
    end
    CImGui.Dummy((0.0, 10.0))

    CImGui.TextWrapped("Repair your ship, explore space, and work towards escaping the galaxy.")
    CImGui.Dummy((0.0, 12.0))

    # Explorer parameters
    CImGui.Text("World Seed")
    if CImGui.IsItemHovered()
        CImGui.SetTooltip("Controls the generated starting conditions. Use the same seed to recreate the same world.")
    end
    seed_input_width = CImGui.GetContentRegionAvail().x - 80.0 - 8.0
    CImGui.SetNextItemWidth(seed_input_width)
    seed = UInt32(state.menu_inputs[:explorer_seed])
    @cref CImGui.InputScalar("##explorer_seed", CImGui.ImGuiDataType_U32, &seed)
    state.menu_inputs[:explorer_seed] = seed
    if CImGui.IsItemHovered()
        CImGui.SetTooltip("Controls the generated starting conditions. Use the same seed to recreate the same world.")
    end
    CImGui.SameLine(0.0, 8.0)
    if CImGui.Button("Randomise", (80.0, 0.0))
        state.menu_inputs[:explorer_seed] = rand(RandomDevice(), UInt32)
    end
    CImGui.Dummy((0.0, 16.0))

    learning_enabled = Bool(get!(state.menu_inputs, :explorer_learning_enabled, true))
    @cref CImGui.Checkbox("Enable Learning System", &learning_enabled)
    state.menu_inputs[:explorer_learning_enabled] = learning_enabled
    CImGui.TextWrapped("(Tips and tutorials will appear as you progress through the game, if enabled)")

    CImGui.Dummy((0.0, 16.0))

    CImGui.SetCursorPosX((box_w - button_width) / 2)
    if CImGui.Button("Start Explorer Mode", (button_width, button_height))
        @info "Starting Explorer Mode"
        state.action = ACTION_START_EXPLORER
    end

    return nothing
end

"Render the standalone tutorial and demo selector."
function render_page_tutorial_select!(state::StartMenuState, box_w::Float64, button_width::Float64, button_height::Float64, escape_rising::Bool)
    if CImGui.Button("< Back", (MENU_BACK_BUTTON_W, MENU_BACK_BUTTON_H)) || escape_rising
        state.page = PAGE_INITIAL
        return nothing
    end

    CImGui.Dummy((0.0, 10.0))
    CImGui.TextWrapped("Tutorials are introduced naturally as you progress through Explorer Mode. You don't need to complete them here before starting a game!")
    CImGui.Spacing()
    CImGui.TextWrapped("This page lets you replay individual tutorials and demos whenever you like.")
    CImGui.Dummy((0.0, 4.0))
    CImGui.SeparatorText("Individual Tutorials")
    CImGui.Spacing()

    CImGui.BeginChild("##tutorial_list", (0.0, 0.0))
    list_start_x = CImGui.GetCursorPosX()
    list_width = CImGui.GetContentRegionAvail().x
    tutorial_button_width = min(button_width, list_width)
    for entry in state.sandbox_entries
        def = entry.definition

        CImGui.SetCursorPosX(list_start_x + (list_width - tutorial_button_width) / 2)
        if CImGui.Button(def.title, (tutorial_button_width, 35.0))
            state.selected_tutorial_id = entry.id
            state.action = ACTION_LAUNCH_SANDBOX
        end

        if CImGui.IsItemHovered()
            CImGui.SetTooltip(def.description)
        end
    end
    CImGui.EndChild()

    return nothing
end

# ===============================================================
# Main UI Dispatch
# ===============================================================

"Render the current start-menu page within an active `ui_renderwrap`."
function ui_start_menu_render!(state::StartMenuState, window::GLFW.Window)
    # Centre the menu window
    winsize = GLFW.GetWindowSize(window)
    win_w, win_h = Float64(winsize.width), Float64(winsize.height)
    box_w = state.page == PAGE_INITIAL ? MENU_INITIAL_BOX_W : MENU_BOX_W
    box_h = if state.page == PAGE_INITIAL
        MENU_INITIAL_BOX_H
    elseif state.page == PAGE_TUTORIAL_SELECT
        MENU_TUTORIAL_BOX_H
    else
        MENU_BOX_H
    end
    pos = ((win_w - box_w) / 2, (win_h - box_h) / 2)

    CImGui.SetNextWindowPos(pos, CImGui.ImGuiCond_Always)
    CImGui.SetNextWindowSize((box_w, box_h), CImGui.ImGuiCond_Always)

    flags = CImGui.ImGuiWindowFlags_NoResize |
        CImGui.ImGuiWindowFlags_NoMove |
        CImGui.ImGuiWindowFlags_NoCollapse |
        CImGui.ImGuiWindowFlags_NoTitleBar
    if state.page == PAGE_TUTORIAL_SELECT
        flags |= CImGui.ImGuiWindowFlags_NoScrollbar | CImGui.ImGuiWindowFlags_NoScrollWithMouse
    end

    # Select the page title
    subtitle = if state.page == PAGE_INITIAL
        ""
    elseif state.page == PAGE_NEW_GAME
        "New Game"
    elseif state.page == PAGE_EXPLORER_SETTINGS
        "Explorer Mode"
    elseif state.page == PAGE_TUTORIAL_SELECT
        "Tutorials"
    else
        error("Unhandled start menu page for title: $(state.page)")
    end

    horizontal_padding = state.page == PAGE_INITIAL ? 20.0 : 8.0
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_WindowPadding, ImVec2(horizontal_padding, 18.0))
    CImGui.Begin("Rocket Plumber###start_menu", C_NULL, flags)
    CImGui.PopStyleVar()

    CImGui.PushFont(UI_VECTOR_FONT, 29.0)
    CImGui.SetCursorPosX((box_w - CImGui.CalcTextSize("Rocket Plumber").x) / 2)
    CImGui.TextColored(DV_COLOUR, "Rocket Plumber")
    CImGui.PopFont()
    if !isempty(subtitle)
        CImGui.PushFont(UI_VECTOR_FONT, 16.0)
        CImGui.SetCursorPosX((box_w - CImGui.CalcTextSize(subtitle).x) / 2)
        CImGui.TextColored(MENU_MUTED_TEXT, subtitle)
        CImGui.PopFont()
    end
    CImGui.Spacing()
    CImGui.Separator()
    CImGui.Dummy((0.0, 12.0))

    button_width = MENU_BOX_W - MENU_BUTTON_PADDING
    escape_rising = get_inrising!(state.last_keystates, GLFW.KEY_ESCAPE, window)

    # Render the selected page
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
function run_session(window::GLFW.Window, session::MapSession; window_mode::WindowModeState)::GameLoopResult
    return enter_gameloop(window; initial_bundle = session.bundle, initial_active_tutorial_id = session.initial_active_tutorial_id, window_mode)
end

"Run a sandbox tutorial session for the current level."
function run_session(window::GLFW.Window, session::SandboxSession; window_mode::WindowModeState)::GameLoopResult
    level = session.definition.levels[session.current_level]
    sandbox_map = level.map_generator()
    set_learning_system!(
        sandbox_map,
        SandboxLearningState(tutorial_id = session.tutorial_id, level_index = session.current_level),
    )
    return enter_gameloop(window; initial_bundle = GameMapBundle(sandbox_map), window_mode)
end

"Determine the next session after a map session exits."
function next_session(::MapSession, result::GameLoopResult)::Union{Nothing, GameSession}
    result.exit_reason == EXIT_RESTART && return MapSession(result.saved_bundle)

    if result.exit_reason == EXIT_SANDBOX_STARTED && !isnothing(result.tutorial_id)
        definition = _find_sandbox_definition(result.tutorial_id)
        isnothing(definition) && return nothing
        return SandboxSession(definition, result.tutorial_id, 1, result.saved_bundle)
    end

    return nothing
end

"Determine the next session after a sandbox session exits."
function next_session(session::SandboxSession, result::GameLoopResult)::Union{Nothing, GameSession}
    if result.exit_reason == EXIT_SANDBOX_COMPLETED
        # Advance through multi-level tutorials
        if session.current_level < length(session.definition.levels)
            return SandboxSession(session.definition, session.tutorial_id, session.current_level + 1, session.parent_bundle)
        end

        # Record completion before returning to the parent map
        if !isnothing(session.parent_bundle)
            parent_map = session.parent_bundle.gamemap
            learning_system = get_learning_system(parent_map)
            if learning_system isa LearningProgress
                complete_tutorial!(learning_system, session.tutorial_id)
            end
        end

        return !isnothing(session.parent_bundle) ? MapSession(session.parent_bundle) : nothing
    end

    if result.exit_reason == EXIT_MENU
        return !isnothing(session.parent_bundle) ? MapSession(session.parent_bundle) : nothing
    end

    return nothing
end

"Load a selected map with optional history, leaving the player in the menu on map failure."
function _load_map_session!(state::StartMenuState, save_path::String)::Union{Nothing, MapSession}
    try
        return MapSession(loadmap_bundle(save_path))
    catch e
        e isa InterruptException && rethrow()
        @warn "Selected save could not be loaded." path = save_path exception = (e, catch_backtrace())
        state.load_error = "Could not load the selected save. Please choose another file."
        return nothing
    end
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
        file_path = try
            map_load_dialog()
        catch e
            e isa InterruptException && rethrow()
            @warn "Map load dialog failed" exception = (e, catch_backtrace())
            state.load_error = "Could not open the save-file dialog."
            return nothing
        end
        isnothing(file_path) && return nothing

        @info "Selected file: $file_path"
        return _load_map_session!(state, string(file_path))

    elseif action == ACTION_START_EXPLORER
        seed = UInt32(state.menu_inputs[:explorer_seed])
        learning_enabled = Bool(get(state.menu_inputs, :explorer_learning_enabled, true))
        @info "Generating explorer mode map with seed=$seed"

        blueprint = generate_starter_ship(seed)
        gamemap = GameMap(blueprint)
        initialise_spacemap!(gamemap, seed, encounter_system_config)
        initialise_explorer_opening_capture!(gamemap)
        learning_system = learning_enabled ? LearningProgress(get_explorer_learning_entry_ids()) : NoLearningSystem()
        set_learning_system!(gamemap, learning_system)

        return MapSession(gamemap)

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
Handle a latched start-menu action outside `ui_renderwrap`.

This avoids nested ImGui frames when entering the game loop or file dialogs.
Runs the resulting session state machine until it ends or the window closes.
"""
function handle_start_menu_action!(state::StartMenuState, window::GLFW.Window)
    action = state.action

    action == ACTION_NONE && return nothing
    state.load_error = ""
    state.page = PAGE_INITIAL

    session = _create_session_for_action(state, action, window)
    isnothing(session) && return nothing

    while !isnothing(session) && !GLFW.WindowShouldClose(window)
        result = run_session(window, session; window_mode = state.window_mode)
        session = next_session(session, result)
    end

    return nothing
end

# ===============================================================
# Start Menu Loop
# ===============================================================

"Run the vsynced start menu until the window closes."
function enter_start_menu(window::GLFW.Window)
    state = StartMenuState()
    GLFW.SetWindowTitle(window, "Rocket Plumber")
    GLFW.SwapInterval(1)
    glClearColor(0.2, 0.2, 0.2, 1.0)

    while !GLFW.WindowShouldClose(window)
        GLFW.PollEvents()
        poll_window_mode!(state.window_mode, window)
        fbsize = GLFW.GetFramebufferSize(window)
        glViewport(0, 0, fbsize.width, fbsize.height)
        glClear(GL_COLOR_BUFFER_BIT)

        # Render the frame
        state.action = ACTION_NONE
        ui_renderwrap() do
            ui_start_menu_render!(state, window)
        end

        GLFW.SwapBuffers(window)

        # Snapshot post-poll state for the next frame's rising-edge checks
        update_lastinstate!(state.last_keystates, window)

        # Handle deferred actions outside the CImGui frame
        handle_start_menu_action!(state, window)
    end

    @info "Exiting start menu"
    ui_teardown()
    GLFW.DestroyWindow(window)
    return nothing
end
