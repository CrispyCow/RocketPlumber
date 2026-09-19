#=
Scope: CImGui learning helper, tutorial banner, and detail windows
Formatter: Runic
=#

# ===============================================================
# Learning System UI: Learning Helper and Tutorial Detail
# ===============================================================

const LEARNING_HELPER_WIDTH = 250.0
const LEARNING_HELPER_MIN_HEIGHT = 80.0
const LEARNING_HELPER_MAX_HEIGHT = 400.0
const LEARNING_HINT_PANE_WIDTH = 455.0
const LEARNING_HINT_PANE_MIN_HEIGHT = 180.0

"Get the right-hand gutter for default Learning Helper placement."
get_learning_right_gutter(inputstate::InputState)::Float32 = inputstate.spacemap_active ? 0.0f0 : Float32(propertyboxwidth)

"Determine whether the Learning Helper list itself should be shown."
_should_render_learning_helper(state::LearningSystemState)::Bool = state.learning_helper_visible && !is_sandbox_learning(state)

"Calculate the default Learning Helper position."
function _get_default_helper_pos(inputstate::InputState, win_float::NamedTuple)::NTuple{2, Float32}
    pos_x = Float32(win_float.width) - get_learning_right_gutter(inputstate) - Float32(LEARNING_HELPER_WIDTH)
    return (pos_x, 0.0f0)
end

"Determine which entries to show based on expanded state."
function _get_entries_for_display(state::LearningSystemState)
    entry_items = [(id = entry.id, entry = entry, status = get_tutorial_status(state.map_learning, entry.id)) for entry in state.entries]

    if !state.learning_helper_expanded
        return [(label = nothing, entries = filter(item -> item.status == TUTORIAL_IN_PROGRESS, entry_items))]
    end

    groups = [
        (label = get_progress_display_text(target_status), entries = filter(item -> item.status == target_status, entry_items))
            for target_status in (TUTORIAL_IN_PROGRESS, TUTORIAL_WAITING, TUTORIAL_COMPLETED)
    ]
    return filter(group -> !isempty(group.entries), groups)
end

"Map tutorial status to the user-facing progress label used throughout the UI."
function get_progress_display_text(status::TutorialStatus)::String
    if status == TUTORIAL_COMPLETED
        return "Completed"
    elseif status == TUTORIAL_IN_PROGRESS
        return "Active"
    end
    return "Not Triggered"
end

"Render a consistent tutorial status line."
function _render_progress_status(status::TutorialStatus)
    label = "Status: $(get_progress_display_text(status))"
    if status == TUTORIAL_COMPLETED
        CImGui.TextColored(ImVec4(0.35, 0.85, 0.45, 1.0), label)
    elseif status == TUTORIAL_WAITING
        CImGui.TextColored(ImVec4(0.6, 0.6, 0.6, 1.0), label)
    else
        CImGui.Text(label)
    end
    return nothing
end

"Classify an entry for display with an ASCII-safe status prefix."
function get_entry_status_prefix(state::LearningSystemState, entry::LearningEntry)::String
    tutorial_state = get_current_tutorial_state(state, entry.id)
    isnothing(tutorial_state) && return "?"

    if tutorial_state.status == TUTORIAL_COMPLETED
        return "v"
    elseif tutorial_state.unlocked_step > 1
        return ">"
    else
        return "?"
    end
end

"Render the tutorial banner behind all other UI."
function ui_tutorial_banner_render!(title::String, winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}})
    win_float = to_float(winsize)
    drawlist = CImGui.GetBackgroundDrawList()

    banner_height = 30.0f0
    banner_text = "TUTORIAL: $title"
    text_size = CImGui.CalcTextSize(banner_text)
    text_pos_x = (Float32(win_float.width) - text_size.x) / 2.0f0
    text_pos_y = 7.0f0

    CImGui.AddRectFilled(
        drawlist,
        ImVec2(0.0f0, 0.0f0),
        ImVec2(Float32(win_float.width), banner_height),
        IM_COL32(26, 51, 102, 220),
    )
    CImGui.AddText(drawlist, ImVec2(text_pos_x, text_pos_y), IM_COL32(255, 230, 77, 255), banner_text)
    return nothing
end

"Render the Learning Helper widget and, if selected, the tutorial detail pane."
function ui_learning_system_render!(
        state::LearningSystemState,
        inputstate::InputState,
        winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}}
    )
    # Keep the sandbox tutorial selected
    if state.map_learning isa SandboxLearningState
        state.active_hint_id = state.map_learning.tutorial_id
    end

    if !state.learning_helper_visible && !is_sandbox_learning(state)
        return nothing
    end

    win_float = to_float(winsize)
    _should_render_learning_helper(state) && _render_learning_helper!(state, inputstate, win_float)

    if !isnothing(state.active_hint_id)
        _render_learning_hint_pane!(state, inputstate, win_float)
    end

    return nothing
end

# ===============================================================
# Learning Helper Widget
# ===============================================================

"Render the draggable Learning Helper list."
function _render_learning_helper!(state::LearningSystemState, inputstate::InputState, win_float::NamedTuple)
    if isnothing(state.current_helper_pos)
        CImGui.SetNextWindowPos(_get_default_helper_pos(inputstate, win_float), CImGui.ImGuiCond_Always)
    end

    flags = CImGui.ImGuiWindowFlags_NoResize | CImGui.ImGuiWindowFlags_AlwaysAutoResize
    CImGui.SetNextWindowSizeConstraints(
        (LEARNING_HELPER_WIDTH, LEARNING_HELPER_MIN_HEIGHT),
        (LEARNING_HELPER_WIDTH, LEARNING_HELPER_MAX_HEIGHT),
    )

    CImGui.Begin("Learning Helper", C_NULL, flags)

    helper_pos = CImGui.GetWindowPos()
    state.current_helper_pos = (helper_pos.x, helper_pos.y)

    toggle_label = state.learning_helper_expanded ? "Show Less" : "Show All"
    if CImGui.SmallButton(toggle_label)
        state.learning_helper_expanded = !state.learning_helper_expanded
    end

    CImGui.Separator()

    rendered_any = false
    for (index, group) in enumerate(_get_entries_for_display(state))
        index > 1 && CImGui.Separator()

        if !isnothing(group.label)
            CImGui.TextColored(ImVec4(0.6, 0.6, 0.6, 1.0), group.label)
        end

        for item in group.entries
            rendered_any = true
            _render_learning_list_item!(state, item.id, item.entry, item.status)
        end
    end

    if !rendered_any
        CImGui.TextWrapped("No active tutorials.")
    end

    CImGui.End()
    return nothing
end

"Render one entry in the Learning Helper list."
function _render_learning_list_item!(
        state::LearningSystemState,
        id::Symbol,
        entry::LearningEntry,
        status::TutorialStatus
    )
    is_selected = state.active_hint_id == id
    status_prefix = get_entry_status_prefix(state, entry)
    label = "$status_prefix $(entry.definition.title)##$id"

    if is_selected
        CImGui.PushStyleColor(CImGui.ImGuiCol_Header, CImGui.ImVec4(0.3, 0.5, 0.7, 1.0))
    end

    if CImGui.Selectable(label, is_selected)
        if is_selected && !is_sandbox_learning(state)
            state.active_hint_id = nothing
        else
            state.active_hint_id = id
            state.viewing_step = 1
        end
    end

    if is_selected
        CImGui.PopStyleColor()
    end

    if CImGui.IsItemHovered()
        tooltip = if status == TUTORIAL_COMPLETED
            "Completed: $(entry.definition.description)"
        else
            entry.definition.description
        end
        CImGui.SetTooltip(tooltip)
    end

    return nothing
end

# ===============================================================
# Tutorial Detail Window
# ===============================================================

"Clamp the tutorial detail pane position to the visible window."
function _clamp_learning_hint_pane_pos(pos::NTuple{2, Float32}, win_float::NamedTuple)::NTuple{2, Float32}
    pane_min_height = min(LEARNING_HINT_PANE_MIN_HEIGHT, Float64(win_float.height))
    max_x = Float32(max(0.0, win_float.width - LEARNING_HINT_PANE_WIDTH))
    max_y = Float32(max(0.0, win_float.height - pane_min_height))
    return (clamp(pos[1], 0.0f0, max_x), clamp(pos[2], 0.0f0, max_y))
end

"Calculate the tutorial detail pane position relative to the Learning Helper."
function _get_learning_hint_pane_pos(state::LearningSystemState, inputstate::InputState, win_float::NamedTuple)::NTuple{2, Float32}
    preferred_pos = if !_should_render_learning_helper(state)
        pos_x = Float32(win_float.width) - get_learning_right_gutter(inputstate) - Float32(LEARNING_HINT_PANE_WIDTH)
        (pos_x, 0.0f0)
    else
        helper_pos = isnothing(state.current_helper_pos) ? _get_default_helper_pos(inputstate, win_float) : state.current_helper_pos
        (helper_pos[1] - Float32(LEARNING_HINT_PANE_WIDTH), helper_pos[2])
    end

    return _clamp_learning_hint_pane_pos(preferred_pos, win_float)
end

"Render the selected tutorial detail pane."
function _render_learning_hint_pane!(state::LearningSystemState, inputstate::InputState, win_float::NamedTuple)
    entry = get_active_entry(state)
    isnothing(entry) && return nothing

    pane_pos = _get_learning_hint_pane_pos(state, inputstate, win_float)
    pane_min_height = min(LEARNING_HINT_PANE_MIN_HEIGHT, Float64(win_float.height))
    max_h = max(pane_min_height, win_float.height - Float64(pane_pos[2]))

    flags = CImGui.ImGuiWindowFlags_NoResize | CImGui.ImGuiWindowFlags_AlwaysAutoResize
    show_close_button = !is_sandbox_learning(state)
    p_open = Ref(true)

    CImGui.SetNextWindowPos(pane_pos, CImGui.ImGuiCond_Always)
    CImGui.SetNextWindowSizeConstraints((LEARNING_HINT_PANE_WIDTH, pane_min_height), (LEARNING_HINT_PANE_WIDTH, max_h))
    CImGui.Begin("Tutorial: $(entry.definition.title)", show_close_button ? p_open : C_NULL, flags)

    try
        if entry.definition isa SandboxTutorialDef && !is_sandbox_learning(state)
            _render_sandbox_preview_window!(state, inputstate, entry)
            return nothing
        end

        tutorial_state = get_current_tutorial_state(state, entry.id)
        isnothing(tutorial_state) && return nothing

        steps = get_steps(entry.definition, state.map_learning)
        isempty(steps) && return nothing

        if entry.definition isa SandboxTutorialDef
            _render_sandbox_tutorial_window!(state, inputstate, entry, tutorial_state, steps)
        else
            _render_ingame_tutorial_window!(state, entry, tutorial_state, steps)
        end
    finally
        CImGui.End()
    end

    if show_close_button && !p_open[]
        state.active_hint_id = nothing
        state.viewing_step = 1
    end

    return nothing
end

"Render the preview for a sandbox tutorial before it is launched."
function _render_sandbox_preview_window!(state::LearningSystemState, inputstate::InputState, entry::LearningEntry)
    definition = entry.definition
    definition isa SandboxTutorialDef || return nothing

    tutorial_status = get_tutorial_status(state.map_learning, entry.id)
    num_levels = length(definition.levels)
    button_width = (LEARNING_HINT_PANE_WIDTH - 20.0) / 2.0

    _render_progress_status(tutorial_status)
    CImGui.Text("Levels: $num_levels")

    CImGui.Spacing()
    if CImGui.Button("Play Tutorial", (button_width, 28.0))
        inputstate.pending_sandbox_id = entry.id
        inputstate.exit_reason = EXIT_SANDBOX_STARTED
    end
    if CImGui.IsItemHovered()
        CImGui.SetTooltip("Launch the sandbox tutorial to step through the guided map sequence. Your explorer map will resume afterwards!")
    end

    CImGui.SameLine()

    if CImGui.Button("Skip", (button_width, 28.0))
        complete_tutorial!(state.map_learning, entry.id)
        state.active_hint_id = nothing
        state.viewing_step = 1
    end

    CImGui.Spacing()
    CImGui.Separator()
    CImGui.Spacing()
    CImGui.TextWrapped(definition.body_text)

    return nothing
end

"Render the shared navigation and content for a tutorial's steps."
function render_tutorial_steps_window!(
        entry_id::Symbol,
        steps::Vector{TutorialStep},
        tutorial_state::TutorialState,
        state::LearningSystemState,
        on_complete!::Function
    )
    # viewing_step (UI-only, on LearningSystemState) tracks which step the player is looking at.
    # unlocked_step (persistent, on TutorialState) tracks how far past gated steps they've progressed.
    # The player can browse back to earlier steps, but can only advance past unlocked_step when
    # the current step has no step_blocker (or the blocker has already been satisfied).
    num_steps = length(steps)
    viewing = clamp(state.viewing_step, 1, num_steps)
    unlocked_step = tutorial_state.unlocked_step
    current_step = steps[viewing]
    is_info_step = isnothing(current_step.step_blocker)
    is_last_step = viewing == num_steps
    action_required = tutorial_state.step_blocker

    # Status text
    status_label = "Status: $(get_progress_display_text(tutorial_state.status)), Step $viewing of $num_steps"
    if tutorial_state.status == TUTORIAL_COMPLETED
        CImGui.TextColored(ImVec4(0.35, 0.85, 0.45, 1.0), status_label)
    elseif tutorial_state.status == TUTORIAL_WAITING
        CImGui.TextColored(ImVec4(0.6, 0.6, 0.6, 1.0), status_label)
    else
        CImGui.Text(status_label)
    end

    # Skip button
    CImGui.SameLine()
    skip_width = 45.0f0
    skip_height = 20.0f0
    cursor_x = CImGui.GetCursorPosX()
    avail_width = CImGui.GetContentRegionAvail().x
    CImGui.SetCursorPosX(cursor_x + max(0.0f0, avail_width - skip_width))
    if CImGui.Button("Skip", (skip_width, skip_height))
        on_complete!()
    end

    at_first_step = viewing == 1
    can_proceed = if is_last_step
        if !is_info_step
            unlocked_step > num_steps
        else
            true
        end
    else
        viewing < unlocked_step || is_info_step
    end

    if CImGui.BeginTable("##tutorial_nav", 3, CImGui.ImGuiTableFlags_SizingStretchSame)
        CImGui.TableNextColumn()
        at_first_step && CImGui.BeginDisabled()
        if CImGui.Button("< Previous", ImVec2(-1.0f0, 24.0f0))
            state.viewing_step = max(1, viewing - 1)
        end
        at_first_step && CImGui.EndDisabled()

        CImGui.TableNextColumn()
        step_kind = is_info_step ? "INFO" : "TASK"
        step_kind_colour = is_info_step ? ImVec4(0.4, 0.7, 1.0, 1.0) : ImVec4(1.0, 0.65, 0.1, 1.0)
        text_width = CImGui.CalcTextSize(step_kind).x
        column_width = CImGui.GetContentRegionAvail().x
        if text_width < column_width
            CImGui.SetCursorPosX(CImGui.GetCursorPosX() + (column_width - text_width) * 0.5)
        end
        CImGui.TextColored(step_kind_colour, step_kind)

        CImGui.TableNextColumn()
        !can_proceed && CImGui.BeginDisabled()
        next_label = is_last_step ? "Finish" : "Next >"
        if CImGui.Button(next_label, ImVec2(-1.0f0, 24.0f0))
            if is_last_step
                on_complete!()
            else
                if viewing == unlocked_step && is_info_step
                    unlock_next_step!(state.map_learning, entry_id, num_steps)
                end
                state.viewing_step = min(num_steps, viewing + 1)
            end
        end
        !can_proceed && CImGui.EndDisabled()
        if !can_proceed && !isnothing(action_required)
            if CImGui.IsItemHovered(CImGui.ImGuiHoveredFlags_AllowWhenDisabled)
                CImGui.SetTooltip(action_required)
            end
        end
        CImGui.EndTable()
    end

    CImGui.Spacing()
    if !isempty(current_step.heading)
        CImGui.SeparatorText(current_step.heading)
    else
        CImGui.Separator()
    end
    CImGui.Spacing()
    CImGui.PushTextWrapPos(0.0)
    CImGui.TextUnformatted(current_step.text)
    CImGui.PopTextWrapPos()

    return nothing
end

"Render the in-game tutorial steps."
function _render_ingame_tutorial_window!(
        state::LearningSystemState,
        entry::LearningEntry,
        tutorial_state::TutorialState,
        steps::Vector{TutorialStep}
    )
    render_tutorial_steps_window!(
        entry.id,
        steps,
        tutorial_state,
        state,
        function ()
            complete_tutorial!(state.map_learning, entry.id)
            state.active_hint_id = nothing
            return state.viewing_step = 1
        end,
    )
    return nothing
end

"Render the sandbox tutorial steps."
function _render_sandbox_tutorial_window!(
        state::LearningSystemState,
        inputstate::InputState,
        entry::LearningEntry,
        tutorial_state::TutorialState,
        steps::Vector{TutorialStep}
    )
    render_tutorial_steps_window!(
        entry.id,
        steps,
        tutorial_state,
        state,
        function ()
            complete_tutorial!(state.map_learning, entry.id)
            return inputstate.exit_reason = EXIT_SANDBOX_COMPLETED
        end,
    )
    return nothing
end
