#=
Scope: Galaxy escape victory-screen helpers and the final flight report UI
Formatter: Runic
=#

# ===============================================================
# Galaxy Escape Victory Screen
# ===============================================================

#= ---------- Visual Constants ---------- =#

const GALAXY_ESCAPE_VICTORY_BACKGROUND_TOP = ImVec4(0.025, 0.03, 0.075, 1.0)
const GALAXY_ESCAPE_VICTORY_BACKGROUND_BOTTOM = ImVec4(0.008, 0.01, 0.025, 1.0)
const GALAXY_ESCAPE_VICTORY_PANEL_BACKGROUND = ImVec4(0.055, 0.06, 0.105, 0.98)
const GALAXY_ESCAPE_VICTORY_SECTION_BACKGROUND = ImVec4(0.035, 0.04, 0.075, 0.95)
const GALAXY_ESCAPE_VICTORY_BORDER = ImVec4(0.52, 0.39, 0.12, 0.9)
const GALAXY_ESCAPE_VICTORY_ACCENT = ImVec4(1.0, 0.76, 0.18, 1.0)
const GALAXY_ESCAPE_VICTORY_VALUE = ImVec4(0.9, 0.94, 1.0, 1.0)
const GALAXY_ESCAPE_VICTORY_MUTED = ImVec4(0.67, 0.71, 0.8, 1.0)
const GALAXY_ESCAPE_VICTORY_STAR_EMPTY = ImVec4(0.11, 0.12, 0.17, 1.0)
const GALAXY_ESCAPE_VICTORY_STAR_EMPTY_OUTLINE = ImVec4(0.48, 0.43, 0.3, 1.0)
const GALAXY_ESCAPE_VICTORY_STAR_GLOW = ImVec4(1.0, 0.7, 0.08, 0.13)

const GALAXY_ESCAPE_VICTORY_FLAVOUR_TEXT =
    "You have broken free of the galactic plane. With the final burn complete, your ship is now en route to its " *
    "destination beyond the galaxy."

#= ---------- Escape Save State ---------- =#

"Render-owned pending screenshot and temporary email-copy feedback."
@kwdef mutable struct EscapeSaveState
    pending_path::Union{Nothing, String} = nothing
    email_copied_until::Float64 = 0.0
end

"Choose a paired destination, save the checkpoint, and queue capture for a fresh victory frame."
function request_escape_save!(state::EscapeSaveState, recorder::TimelapseRecorder, gamemap::GameMap, console_push::Function; dialog::Function = save_file)
    isnothing(state.pending_path) || return nothing
    save_path = map_save_dialog(console_push; dialog)
    isnothing(save_path) && return nothing

    screenshot_path = first(splitext(save_path)) * ".png"
    # The map dialog only authorises replacing the ship file
    if lowercase(last(splitext(save_path))) != ".jld2" || ispath(screenshot_path) || islink(screenshot_path)
        console_push("Nothing saved. Choose a .jld2 filename with no matching PNG. Screenshot destination: $screenshot_path")
        return nothing
    end

    try
        save_pre_escape_map(recorder, gamemap, save_path)
    catch e
        e isa InterruptException && rethrow()
        @warn "Pre-escape map save failed" path = save_path exception = (e, catch_backtrace())
        console_push("Ship save failed: $save_path. $(sprint(showerror, e))")
        return nothing
    end
    state.pending_path = save_path
    return nothing
end

"Finish a queued save after a fresh victory frame renders, without replacing an unconfirmed PNG."
function finish_escape_save!(state::EscapeSaveState, capture::Function, console_push::Function)
    isnothing(state.pending_path) && return nothing
    save_path = state.pending_path::String
    screenshot_path = first(splitext(save_path)) * ".png"
    screenshot_saved = false
    temporary_path = nothing
    try
        if ispath(screenshot_path) || islink(screenshot_path)
            throw(ArgumentError("$screenshot_path already exists."))
        end
        temporary_path, temporary_io = mktemp(dirname(screenshot_path))
        close(temporary_io)
        capture(temporary_path)
        if ispath(screenshot_path) || islink(screenshot_path)
            throw(ArgumentError("$screenshot_path already exists."))
        end
        # Publish only a complete image; mv refuses a destination created during capture
        mv(temporary_path, screenshot_path; force = false)
        screenshot_saved = true
    catch e
        e isa InterruptException && rethrow()
        @warn "Escape screenshot save failed" path = screenshot_path exception = (e, catch_backtrace())
    finally
        isnothing(temporary_path) || rm(temporary_path; force = true)
        state.pending_path = nothing
    end

    if screenshot_saved
        console_push("Escape saved! Ship: $save_path; Screenshot: $screenshot_path")
    else
        console_push("Ship saved: $save_path; screenshot failed: $screenshot_path. See the terminal log.")
    end
    return nothing
end

#= ---------- Text Formatting ---------- =#

"Return an integer string grouped with commas for result-screen readability."
function _group_victory_integer_text(raw::AbstractString)::String
    sign = startswith(raw, "-") ? "-" : ""
    digits = isempty(sign) ? String(raw) : String(raw[2:end])
    first_group_length = mod1(length(digits), 3)

    groups = String[String(digits[1:first_group_length])]
    for start_index in (first_group_length + 1):3:length(digits)
        push!(groups, String(digits[start_index:(start_index + 2)]))
    end
    return sign * join(groups, ",")
end

_group_victory_integer_text(value::Integer) = _group_victory_integer_text(string(value))

"Format a finite result-screen number with stable precision and grouped thousands."
function _format_victory_number(value::Real; decimal_places::Int = 1)::String
    converted = Float64(value)
    isfinite(converted) || return string(converted)

    raw = @sprintf("%.*f", decimal_places, converted)
    integer_and_fraction = split(raw, '.'; limit = 2)
    grouped_integer = _group_victory_integer_text(first(integer_and_fraction))
    return length(integer_and_fraction) == 1 ? grouped_integer : "$grouped_integer.$(last(integer_and_fraction))"
end

"Format non-negative elapsed seconds as hours, minutes, and seconds."
function _format_victory_duration(seconds::Real)::String
    total_seconds = round(Int, Float64(seconds))
    hours, remainder = divrem(total_seconds, 3600)
    minutes, final_seconds = divrem(remainder, 60)
    return @sprintf("%d:%02d:%02d", hours, minutes, final_seconds)
end

"Render one centred line at a chosen font size and colour."
function _render_victory_centred_text(text::AbstractString, font_size::Real, colour::ImVec4)
    CImGui.PushFont(UI_VECTOR_FONT, font_size)
    text_width = CImGui.CalcTextSize(text).x
    available_width = CImGui.GetContentRegionAvail().x
    CImGui.SetCursorPosX(CImGui.GetCursorPosX() + max(0.0f0, (available_width - text_width) * 0.5f0))
    CImGui.TextColored(colour, text)
    CImGui.PopFont()
    return nothing
end

#= ---------- Star Rendering ---------- =#

"Append the ten alternating-radius points of a five-pointed star to a draw-list path."
function _build_victory_star_path!(drawlist, centre::ImVec2, outer_radius::Float32)
    inner_radius = outer_radius * 0.45f0
    CImGui.PathClear(drawlist)
    for point_index in 0:9
        radius = iseven(point_index) ? outer_radius : inner_radius
        angle = Float32(-pi / 2 + point_index * pi / 5)
        CImGui.PathLineTo(drawlist, ImVec2(centre.x + radius * cos(angle), centre.y + radius * sin(angle)))
    end
    return nothing
end

"Draw one filled or empty vector star using CImGui draw-list primitives."
function _draw_victory_star!(drawlist, centre::ImVec2, radius::Float32, earned::Bool)
    if earned
        _build_victory_star_path!(drawlist, centre, radius * 1.12f0)
        CImGui.PathFillConcave(drawlist, CImGui.GetColorU32(GALAXY_ESCAPE_VICTORY_STAR_GLOW))
    end

    fill_colour = earned ? GALAXY_ESCAPE_VICTORY_ACCENT : GALAXY_ESCAPE_VICTORY_STAR_EMPTY
    outline_colour = earned ? GALAXY_ESCAPE_VICTORY_VALUE : GALAXY_ESCAPE_VICTORY_STAR_EMPTY_OUTLINE
    _build_victory_star_path!(drawlist, centre, radius)
    CImGui.PathFillConcave(drawlist, CImGui.GetColorU32(fill_colour))
    _build_victory_star_path!(drawlist, centre, radius)
    CImGui.PathStroke(
        drawlist,
        CImGui.GetColorU32(outline_colour),
        earned ? 2.5f0 : 2.0f0,
        CImGui.ImDrawFlags_Closed,
    )
    return nothing
end

"Draw and reserve the responsive row containing the escape-rating stars."
function _render_victory_star_row!(attained_tier::Int)
    star_count = length(GALAXY_ESCAPE_TIER_DELTA_V)
    available_width = CImGui.GetContentRegionAvail().x
    radius = clamp(available_width / 10.0f0, 27.0f0, 41.0f0)
    gap = radius * 0.55f0
    row_width = 2.0f0 * star_count * radius + (star_count - 1) * gap
    row_height = 2.4f0 * radius
    cursor_screen_pos = CImGui.GetCursorScreenPos()
    first_centre_x = cursor_screen_pos.x + max(0.0f0, (available_width - row_width) * 0.5f0) + radius
    centre_y = cursor_screen_pos.y + row_height * 0.5f0
    drawlist = CImGui.GetWindowDrawList()

    for star_index in 1:star_count
        centre_x = first_centre_x + (star_index - 1) * (2.0f0 * radius + gap)
        _draw_victory_star!(drawlist, ImVec2(centre_x, centre_y), radius, star_index <= attained_tier)
    end

    CImGui.Dummy(ImVec2(available_width, row_height))
    return nothing
end

#= ---------- Statistics Rendering ---------- =#

"Render one right-aligned label/value row in the active statistics table."
function _render_victory_statistic_row(label::AbstractString, value::AbstractString; indent::Float32 = 0.0f0)
    CImGui.TableNextRow()
    CImGui.TableSetColumnIndex(0)
    indent > 0.0f0 && CImGui.Indent(indent)
    CImGui.TextUnformatted("$label:")
    indent > 0.0f0 && CImGui.Unindent(indent)

    CImGui.TableSetColumnIndex(1)
    text_width = CImGui.CalcTextSize(value).x
    available_width = CImGui.GetContentRegionAvail().x
    CImGui.SetCursorPosX(CImGui.GetCursorPosX() + max(0.0f0, available_width - text_width))
    CImGui.TextColored(GALAXY_ESCAPE_VICTORY_VALUE, value)
    return nothing
end

"Render a compact two-column group of result-screen statistics."
function _render_victory_statistics_group(heading::AbstractString, rows)
    CImGui.TextColored(GALAXY_ESCAPE_VICTORY_MUTED, heading)
    table_flags = CImGui.ImGuiTableFlags_SizingStretchProp | CImGui.ImGuiTableFlags_PadOuterX
    if CImGui.BeginTable("##victory_statistics_$heading", 2, table_flags)
        CImGui.TableSetupColumn("Statistic", CImGui.ImGuiTableColumnFlags_WidthStretch, 0.66f0)
        CImGui.TableSetupColumn("Value", CImGui.ImGuiTableColumnFlags_WidthStretch, 0.34f0)
        for (label, value, indent) in rows
            _render_victory_statistic_row(label, value; indent)
        end
        CImGui.EndTable()
    end
    return nothing
end

"Render every frozen playthrough statistic included in the final flight report."
function _render_galaxy_escape_victory_statistics!(gamemap::GameMap)
    _render_victory_statistics_group(
        "TIME", (
            ("Galactic time", "$(_format_victory_number(get_time_years(gamemap); decimal_places = 2)) years", 0.0f0),
            ("Play time", _format_victory_duration(get_recorded_play_time_seconds(gamemap)), 0.0f0),
            ("Detailed simulation time", _format_victory_duration(get_simulated_seconds(gamemap)), 0.0f0),
            ("Simulation ticks", _group_victory_integer_text(get_simulated_ticks(gamemap)), 0.0f0),
        )
    )

    CImGui.Spacing()
    _render_victory_statistics_group(
        "FLIGHT", (
            ("Final speed", _format_victory_number(norm(get_velocity(gamemap))), 0.0f0),
            ("Total delta-V produced", _format_victory_number(get_total_delta_v(gamemap)), 0.0f0),
            ("Peak combined thrust", _format_victory_number(get_peak_thrust(gamemap)), 0.0f0),
            ("Peak estimated remaining delta-V", _format_victory_number(get_peak_estimated_delta_v(gamemap)), 0.0f0),
        )
    )

    encounter_rows = Tuple{String, String, Float32}[
        ("Completed encounters", _group_victory_integer_text(get_total_encounter_count(gamemap)), 0.0f0),
    ]
    for encounter_class in instances(EncounterClass)
        push!(
            encounter_rows, (
                encounter_class_label(encounter_class),
                _group_victory_integer_text(get_encounter_count(gamemap, encounter_class)),
                16.0f0,
            )
        )
    end
    CImGui.Spacing()
    _render_victory_statistics_group("ENCOUNTERS", encounter_rows)
    return nothing
end

#= ---------- Final Flight Report ---------- =#

"Render the exclusive final flight report shown after a galaxy escape is completed."
function ui_galaxy_escape_victory_render!(gamemap::GameMap, inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC, timelapse_recorder::TimelapseRecorder, window::GLFW.Window, save_state::EscapeSaveState)
    # Full-screen backdrop
    winsize = to_float(GLFW.GetWindowSize(window))
    CImGui.AddRectFilledMultiColor(
        CImGui.GetBackgroundDrawList(),
        ImVec2(0.0, 0.0),
        ImVec2(winsize.width, winsize.height),
        CImGui.GetColorU32(GALAXY_ESCAPE_VICTORY_BACKGROUND_TOP),
        CImGui.GetColorU32(GALAXY_ESCAPE_VICTORY_BACKGROUND_TOP),
        CImGui.GetColorU32(GALAXY_ESCAPE_VICTORY_BACKGROUND_BOTTOM),
        CImGui.GetColorU32(GALAXY_ESCAPE_VICTORY_BACKGROUND_BOTTOM),
    )

    CImGui.SetNextWindowPos(ImVec2(0.0, 0.0))
    CImGui.SetNextWindowSize(ImVec2(winsize.width, winsize.height))
    flags = CImGui.ImGuiWindowFlags_NoTitleBar | CImGui.ImGuiWindowFlags_NoResize |
        CImGui.ImGuiWindowFlags_NoMove | CImGui.ImGuiWindowFlags_NoCollapse |
        CImGui.ImGuiWindowFlags_NoScrollbar
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_WindowPadding, ImVec2(0.0, 0.0))
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_WindowBorderSize, 0.0)
    CImGui.PushStyleColor(CImGui.ImGuiCol_WindowBg, ImVec4(0.0, 0.0, 0.0, 0.0))
    CImGui.Begin("##galaxy_escape_victory", C_NULL, flags)

    # Main report panel
    panel_width = clamp(winsize.width - 32.0, 1.0, 920.0)
    panel_height = clamp(winsize.height - 32.0, 1.0, 1040.0)
    action_button_height = 45.0
    action_button_gap = 10.0
    footer_height = min(310.0, panel_height * 0.5)
    footer_gap = 10.0
    report_height = max(1.0, panel_height - footer_height - footer_gap)
    panel_pos = ImVec2(
        max(0.0, (winsize.width - panel_width) / 2.0),
        max(0.0, (winsize.height - panel_height) / 2.0),
    )
    CImGui.SetCursorPos(panel_pos)
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_WindowPadding, ImVec2(24.0, 22.0))
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_ChildRounding, 10.0)
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_ChildBorderSize, 1.0)
    CImGui.PushStyleColor(CImGui.ImGuiCol_ChildBg, GALAXY_ESCAPE_VICTORY_PANEL_BACKGROUND)
    CImGui.PushStyleColor(CImGui.ImGuiCol_Border, GALAXY_ESCAPE_VICTORY_BORDER)
    panel_flags = CImGui.ImGuiChildFlags_Borders | CImGui.ImGuiChildFlags_AlwaysUseWindowPadding
    CImGui.BeginChild("##galaxy_escape_victory_content", ImVec2(panel_width, report_height), panel_flags)

    _render_victory_centred_text("GALAXY ESCAPED!", 38.0, GALAXY_ESCAPE_VICTORY_ACCENT)
    CImGui.Spacing()
    CImGui.PushStyleColor(CImGui.ImGuiCol_Text, GALAXY_ESCAPE_VICTORY_MUTED)
    CImGui.PushTextWrapPos(0.0)
    CImGui.TextWrapped(GALAXY_ESCAPE_VICTORY_FLAVOUR_TEXT)
    CImGui.PopTextWrapPos()
    CImGui.PopStyleColor()
    CImGui.Dummy(ImVec2(0.0, 14.0))

    progress = get_galaxy_escape_progress(gamemap)::Float64
    rating = Int(galaxy_escape_tier(progress))
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_WindowPadding, ImVec2(16.0, 14.0))
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_ChildRounding, 7.0)
    CImGui.PushStyleColor(CImGui.ImGuiCol_ChildBg, GALAXY_ESCAPE_VICTORY_SECTION_BACKGROUND)
    CImGui.BeginChild(
        "##galaxy_escape_rating",
        ImVec2(0.0, 194.0),
        CImGui.ImGuiChildFlags_Borders | CImGui.ImGuiChildFlags_AlwaysUseWindowPadding,
    )
    _render_victory_centred_text("ESCAPE RATING", 15.0, GALAXY_ESCAPE_VICTORY_MUTED)
    CImGui.Dummy(ImVec2(0.0, 2.0))
    _render_victory_star_row!(rating)
    _render_victory_centred_text("$rating / $(length(GALAXY_ESCAPE_TIER_DELTA_V)) STAR ESCAPE", 19.0, GALAXY_ESCAPE_VICTORY_VALUE)
    _render_victory_centred_text(
        "Escape delta-V: $(_format_victory_number(progress))",
        15.0,
        GALAXY_ESCAPE_VICTORY_ACCENT,
    )
    CImGui.EndChild()
    CImGui.PopStyleColor()
    CImGui.PopStyleVar(2)

    CImGui.Dummy(ImVec2(0.0, 14.0))
    CImGui.PushFont(UI_VECTOR_FONT, 23.0)
    CImGui.TextColored(GALAXY_ESCAPE_VICTORY_ACCENT, "STATISTICS")
    CImGui.PopFont()
    CImGui.Separator()
    CImGui.Spacing()
    _render_galaxy_escape_victory_statistics!(gamemap)
    CImGui.EndChild()
    CImGui.PopStyleColor(2)
    CImGui.PopStyleVar(3)

    # Action footer
    footer_pos = ImVec2(panel_pos.x, panel_pos.y + report_height + footer_gap)
    CImGui.SetCursorPos(footer_pos)
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_WindowPadding, ImVec2(18.0, 16.0))
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_ChildRounding, 10.0)
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_ChildBorderSize, 1.0)
    CImGui.PushStyleColor(CImGui.ImGuiCol_ChildBg, GALAXY_ESCAPE_VICTORY_PANEL_BACKGROUND)
    CImGui.PushStyleColor(CImGui.ImGuiCol_Border, GALAXY_ESCAPE_VICTORY_BORDER)
    CImGui.BeginChild("##galaxy_escape_victory_actions", ImVec2(panel_width, footer_height), panel_flags)

    footer_content_height = CImGui.GetContentRegionAvail().y
    footer_flags = CImGui.ImGuiTableFlags_SizingStretchProp | CImGui.ImGuiTableFlags_BordersInnerV
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_CellPadding, ImVec2(18.0, 2.0))
    if CImGui.BeginTable("##escape_footer_columns", 2, footer_flags)
        CImGui.TableSetupColumn("Share", CImGui.ImGuiTableColumnFlags_WidthStretch, 0.64f0)
        CImGui.TableSetupColumn("Actions", CImGui.ImGuiTableColumnFlags_WidthStretch, 0.36f0)
        CImGui.TableNextRow(0, footer_content_height - 4.0) # Allow for the row's cell padding
        CImGui.TableSetColumnIndex(0)
        share_start_x = CImGui.GetCursorPosX()
        share_width = CImGui.GetContentRegionAvail().x

        CImGui.PushFont(UI_VECTOR_FONT, 22.0)
        CImGui.TextColored(GALAXY_ESCAPE_VICTORY_ACCENT, "SHARE YOUR ESCAPE")
        CImGui.PopFont()
        CImGui.Spacing()
        CImGui.PushStyleColor(CImGui.ImGuiCol_Text, GALAXY_ESCAPE_VICTORY_VALUE)
        CImGui.TextWrapped("You've escaped the galaxy! Congratulations, you might be one of the first people to pull it off!")
        CImGui.Spacing()
        CImGui.TextWrapped("I'd love to see the ship that got you here.")
        CImGui.Spacing()
        CImGui.TextWrapped("Send me your screenshots, ship, and any feedback or stories from your journey!")
        CImGui.PopStyleColor()
        CImGui.Spacing()
        CImGui.Dummy(ImVec2(0.0, 8.0))

        email = "feedback@rocketplumbergame.com"
        copy_button_width = 65.0
        feedback_gap = 10.0
        CImGui.PushFont(UI_VECTOR_FONT, 16.0)
        email_width = CImGui.CalcTextSize(email).x
        inline_copy = share_width >= email_width + feedback_gap + copy_button_width
        # Scale only the address on narrow windows; Copy moves to its own centred line
        email_size = min(16.0, 16.0 * share_width / email_width)
        CImGui.PopFont()
        CImGui.PushFont(UI_VECTOR_FONT, email_size)
        feedback_width = CImGui.CalcTextSize(email).x + (inline_copy ? feedback_gap + copy_button_width : 0.0)
        CImGui.SetCursorPosX(share_start_x + max(0.0, (share_width - feedback_width) / 2))
        CImGui.AlignTextToFramePadding()
        CImGui.TextLinkOpenURL(email, "mailto:feedback@rocketplumbergame.com?subject=Rocket%20Plumber%20-%20My%20Galactic%20Escape")
        CImGui.PopFont()
        if inline_copy
            CImGui.SameLine(0.0, feedback_gap)
        else
            CImGui.SetCursorPosX(share_start_x + max(0.0, (share_width - copy_button_width) / 2))
        end
        copied = CImGui.GetTime() < save_state.email_copied_until
        if CImGui.Button(copied ? "Copied!###escape_copy_email" : "Copy###escape_copy_email", ImVec2(copy_button_width, 22.0))
            CImGui.SetClipboardText(email)
            save_state.email_copied_until = CImGui.GetTime() + 2.0
        end

        CImGui.Spacing()
        CImGui.Dummy(ImVec2(0.0, 8.0))
        CImGui.PushStyleColor(CImGui.ImGuiCol_Text, GALAXY_ESCAPE_VICTORY_MUTED)
        CImGui.TextWrapped("Tip: If your save is too large put it in a ZIP!")
        CImGui.PopStyleColor()
        CImGui.Spacing()
        CImGui.Dummy(ImVec2(0.0, 8.0))
        CImGui.Separator()
        CImGui.Spacing()
        CImGui.TextColored(GALAXY_ESCAPE_VICTORY_MUTED, "Enjoyed Rocket Plumber?\nWant updates on new features and releases?")
        CImGui.Dummy(ImVec2(0.0, 6.0))
        mailing_list_label = "Join the Mailing List"
        CImGui.SetCursorPosX(share_start_x + max(0.0, (share_width - CImGui.CalcTextSize(mailing_list_label).x) / 2))
        CImGui.TextLinkOpenURL(mailing_list_label, "https://rocketplumbergame.com/mailing-list/")

        CImGui.TableSetColumnIndex(1)
        action_group_height = 3 * action_button_height + 2 * action_button_gap
        action_available_height = footer_content_height - 4.0 # Allow for the row's cell padding
        action_start_y = CImGui.GetCursorPosY() + max(0.0, (action_available_height - action_group_height) / 2)
        CImGui.SetCursorPosY(action_start_y)
        CImGui.BeginDisabled(!isnothing(save_state.pending_path))
        CImGui.PushStyleColor(CImGui.ImGuiCol_Button, ImVec4(0.38, 0.26, 0.065, 1.0))
        CImGui.PushStyleColor(CImGui.ImGuiCol_ButtonHovered, ImVec4(0.52, 0.36, 0.09, 1.0))
        CImGui.PushStyleColor(CImGui.ImGuiCol_Text, GALAXY_ESCAPE_VICTORY_ACCENT)
        save_clicked = CImGui.Button("##escape_save", ImVec2(-1, action_button_height))
        # Centre each line independently over the normal button
        button_min = CImGui.GetItemRectMin()
        button_size = CImGui.GetItemRectSize()
        line_height = CImGui.GetTextLineHeight()
        text_y = button_min.y + (button_size.y - 2 * line_height) / 2
        for (line_index, line) in enumerate(("Save Escape", "Screenshot + Ship"))
            text_x = button_min.x + (button_size.x - CImGui.CalcTextSize(line).x) / 2
            CImGui.AddText(CImGui.GetWindowDrawList(), ImVec2(text_x, text_y + (line_index - 1) * line_height), CImGui.GetColorU32(CImGui.ImGuiCol_Text), line)
        end
        if save_clicked
            request_escape_save!(save_state, timelapse_recorder, gamemap, flowcalc_ipc.console_push)
        end
        CImGui.PopStyleColor(3)

        CImGui.SetCursorPosY(action_start_y + action_button_height + action_button_gap)
        if CImGui.Button("Exit to Main Menu", ImVec2(-1, action_button_height))
            inputstate.exit_reason = EXIT_MENU
        end

        CImGui.SetCursorPosY(action_start_y + 2 * (action_button_height + action_button_gap))
        if CImGui.Button("Exit Game", ImVec2(-1, action_button_height))
            inputstate.exit_reason = EXIT_QUIT
            GLFW.SetWindowShouldClose(window, true)
        end
        CImGui.EndDisabled()
        CImGui.EndTable()
    end
    CImGui.PopStyleVar()

    CImGui.EndChild()
    CImGui.PopStyleColor(2)
    CImGui.PopStyleVar(3)

    CImGui.End()
    CImGui.PopStyleColor()
    CImGui.PopStyleVar(2)
    return nothing
end
