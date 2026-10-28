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
const GALAXY_ESCAPE_VICTORY_SUBHEADING = ImVec4(0.50, 0.78, 1.0, 1.0)
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
function request_escape_save!(state::EscapeSaveState, recorder::TimelapseRecorder, gamemap::GameMap, console_push::Function; dialog::Function = windowed_save_file)
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

"Measure and centre text using its typography class and weight."
function _render_victory_centred_text(text::AbstractString, class::UIFontClass, colour::ImVec4; bold::Bool = false)
    push_ui_font(class; bold)
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
        earned ? min(2.5f0, radius * 0.1f0) : min(2.0f0, radius * 0.08f0),
        CImGui.ImDrawFlags_Closed,
    )
    return nothing
end

"Draw and reserve the responsive row containing the escape-rating stars."
function _render_victory_star_row!(attained_tier::Int)
    star_count = length(GALAXY_ESCAPE_TIER_DELTA_V)
    available_width = CImGui.GetContentRegionAvail().x
    # Include gaps, glow and stroke mitres, plus two physical pixels of antialiasing per edge
    width_per_radius = 2.0f0 * star_count + 0.55f0 * (star_count - 1) + 0.6f0
    radius_limit = max(0.0f0, (available_width - 4.0f0) / width_per_radius)
    radius = min(radius_limit, clamp(available_width / 10.0f0, Float32(ui_px(6)), Float32(ui_px(8))))
    if radius < 2.0f0
        CImGui.Dummy(ImVec2(max(0.0f0, available_width), 0))
        return nothing
    end

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

"Render a label and right-aligned value in adjacent columns of the current table row."
function _render_victory_statistic_pair(column::Int, label::AbstractString, value::AbstractString)
    CImGui.TableSetColumnIndex(column)
    CImGui.TextUnformatted(label)

    CImGui.TableSetColumnIndex(column + 1)
    text_width = CImGui.CalcTextSize(value).x
    available_width = CImGui.GetContentRegionAvail().x
    CImGui.SetCursorPosX(CImGui.GetCursorPosX() + max(0.0f0, available_width - text_width))
    CImGui.TextColored(GALAXY_ESCAPE_VICTORY_VALUE, value)
    return nothing
end

"Render the frozen flight report as paired statistics and a horizontal encounter summary."
function _render_galaxy_escape_victory_statistics!(gamemap::GameMap)
    table_flags = CImGui.ImGuiTableFlags_SizingStretchProp | CImGui.ImGuiTableFlags_PadOuterX
    if CImGui.BeginTable("##victory_time_flight", 5, table_flags)
        CImGui.TableSetupColumn("Time statistic", CImGui.ImGuiTableColumnFlags_WidthStretch, 2.5f0)
        CImGui.TableSetupColumn("Time value", CImGui.ImGuiTableColumnFlags_WidthStretch, 2.3f0)
        CImGui.TableSetupColumn("##gap", CImGui.ImGuiTableColumnFlags_WidthFixed, ui_px(32))
        CImGui.TableSetupColumn("Flight statistic", CImGui.ImGuiTableColumnFlags_WidthStretch, 3.4f0)
        CImGui.TableSetupColumn("Flight value", CImGui.ImGuiTableColumnFlags_WidthStretch, 2.0f0)
        CImGui.TableNextRow()
        push_ui_font(; bold = true)
        CImGui.TableSetColumnIndex(0)
        CImGui.TextColored(GALAXY_ESCAPE_VICTORY_SUBHEADING, "TIME")
        CImGui.TableSetColumnIndex(3)
        CImGui.TextColored(GALAXY_ESCAPE_VICTORY_SUBHEADING, "FLIGHT")
        CImGui.PopFont()

        CImGui.TableNextRow()
        _render_victory_statistic_pair(0, "Galactic time", "$(_format_victory_number(get_time_years(gamemap); decimal_places = 2)) years")
        _render_victory_statistic_pair(3, "Final speed", _format_victory_number(norm(get_velocity(gamemap))))
        CImGui.TableNextRow()
        _render_victory_statistic_pair(0, "Play time", _format_victory_duration(get_recorded_play_time_seconds(gamemap)))
        _render_victory_statistic_pair(3, "Total delta-V", _format_victory_number(get_total_delta_v(gamemap)))
        CImGui.TableNextRow()
        _render_victory_statistic_pair(0, "Simulation time", _format_victory_duration(get_simulated_seconds(gamemap)))
        _render_victory_statistic_pair(3, "Peak thrust", _format_victory_number(get_peak_thrust(gamemap)))
        CImGui.TableNextRow()
        _render_victory_statistic_pair(0, "Simulation ticks", _group_victory_integer_text(get_simulated_ticks(gamemap)))
        _render_victory_statistic_pair(3, "Peak remaining delta-V", _format_victory_number(get_peak_estimated_delta_v(gamemap)))
        CImGui.EndTable()
    end

    CImGui.Spacing()
    if CImGui.BeginTable("##victory_encounters", 1 + length(instances(EncounterClass)), table_flags)
        CImGui.TableSetupColumn("Completed encounters", CImGui.ImGuiTableColumnFlags_WidthStretch, 1.0f0)
        for encounter_class in instances(EncounterClass)
            CImGui.TableSetupColumn(encounter_class_label(encounter_class), CImGui.ImGuiTableColumnFlags_WidthStretch, 1.0f0)
        end
        CImGui.TableNextRow()
        CImGui.TableSetColumnIndex(0)
        push_ui_font(; bold = true)
        CImGui.TextColored(GALAXY_ESCAPE_VICTORY_SUBHEADING, "ENCOUNTERS")
        CImGui.PopFont()
        CImGui.TableNextRow()
        CImGui.TableSetColumnIndex(0)
        _render_victory_centred_text("Completed encounters", FontStandard, GALAXY_ESCAPE_VICTORY_MUTED)
        for (index, encounter_class) in enumerate(instances(EncounterClass))
            CImGui.TableSetColumnIndex(index)
            _render_victory_centred_text(encounter_class_label(encounter_class), FontStandard, GALAXY_ESCAPE_VICTORY_MUTED)
        end
        CImGui.TableNextRow()
        CImGui.TableSetColumnIndex(0)
        _render_victory_centred_text(_group_victory_integer_text(get_total_encounter_count(gamemap)), FontStandard, GALAXY_ESCAPE_VICTORY_VALUE; bold = true)
        for (index, encounter_class) in enumerate(instances(EncounterClass))
            CImGui.TableSetColumnIndex(index)
            _render_victory_centred_text(_group_victory_integer_text(get_encounter_count(gamemap, encounter_class)), FontStandard, GALAXY_ESCAPE_VICTORY_VALUE; bold = true)
        end
        CImGui.EndTable()
    end
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
    panel_width = clamp(winsize.width - ui_px(8), 1.0, ui_px(230))
    preferred_report_height = ui_px(125)
    preferred_footer_height = ui_px(90)
    footer_gap = ui_px(2)
    panel_height = clamp(winsize.height - ui_px(8), 1.0, preferred_report_height + footer_gap + preferred_footer_height)
    action_button_height = ui_px(12)
    action_button_gap = ui_px(2)
    footer_height = min(preferred_footer_height, panel_height * 0.5)
    report_height = max(1.0, panel_height - footer_height - footer_gap)
    panel_pos = ImVec2(
        max(0.0, (winsize.width - panel_width) / 2.0),
        max(0.0, (winsize.height - panel_height) / 2.0),
    )
    CImGui.SetCursorPos(panel_pos)
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_WindowPadding, ImVec2(ui_px(6), ui_px(4)))
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_ChildRounding, ui_px(2))
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_ChildBorderSize, 1.0)
    CImGui.PushStyleColor(CImGui.ImGuiCol_ChildBg, GALAXY_ESCAPE_VICTORY_PANEL_BACKGROUND)
    CImGui.PushStyleColor(CImGui.ImGuiCol_Border, GALAXY_ESCAPE_VICTORY_BORDER)
    panel_flags = CImGui.ImGuiChildFlags_Borders | CImGui.ImGuiChildFlags_AlwaysUseWindowPadding
    CImGui.BeginChild("##galaxy_escape_victory_content", ImVec2(panel_width, report_height), panel_flags)

    _render_victory_centred_text("GALAXY ESCAPED!", FontDisplay, GALAXY_ESCAPE_VICTORY_ACCENT; bold = true)
    CImGui.PushStyleColor(CImGui.ImGuiCol_Text, GALAXY_ESCAPE_VICTORY_MUTED)
    CImGui.PushTextWrapPos(0.0)
    CImGui.TextWrapped(GALAXY_ESCAPE_VICTORY_FLAVOUR_TEXT)
    CImGui.PopTextWrapPos()
    CImGui.PopStyleColor()
    CImGui.Spacing()

    progress = get_galaxy_escape_progress(gamemap)::Float64
    rating = Int(galaxy_escape_tier(progress))
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_WindowPadding, ImVec2(ui_px(4), ui_px(3)))
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_ChildRounding, ui_px(2))
    CImGui.PushStyleColor(CImGui.ImGuiCol_ChildBg, GALAXY_ESCAPE_VICTORY_SECTION_BACKGROUND)
    CImGui.BeginChild(
        "##galaxy_escape_rating",
        ImVec2(0.0, ui_px(43)),
        CImGui.ImGuiChildFlags_Borders | CImGui.ImGuiChildFlags_AlwaysUseWindowPadding,
    )
    _render_victory_centred_text("ESCAPE RATING", FontStandard, GALAXY_ESCAPE_VICTORY_MUTED; bold = true)
    _render_victory_star_row!(rating)
    _render_victory_centred_text("$rating / $(length(GALAXY_ESCAPE_TIER_DELTA_V)) STAR ESCAPE", FontLarge, GALAXY_ESCAPE_VICTORY_VALUE; bold = true)
    _render_victory_centred_text(
        "Escape delta-V: $(_format_victory_number(progress))",
        FontStandard,
        GALAXY_ESCAPE_VICTORY_ACCENT,
    )
    CImGui.EndChild()
    CImGui.PopStyleColor()
    CImGui.PopStyleVar(2)

    push_ui_font(; bold = true)
    CImGui.TextColored(GALAXY_ESCAPE_VICTORY_ACCENT, "STATISTICS")
    CImGui.PopFont()
    CImGui.Separator()
    _render_galaxy_escape_victory_statistics!(gamemap)
    CImGui.EndChild()
    CImGui.PopStyleColor(2)
    CImGui.PopStyleVar(3)

    # Action footer
    footer_pos = ImVec2(panel_pos.x, panel_pos.y + report_height + footer_gap)
    CImGui.SetCursorPos(footer_pos)
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_WindowPadding, ImVec2(ui_px(5), ui_px(4)))
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_ChildRounding, ui_px(2))
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_ChildBorderSize, 1.0)
    CImGui.PushStyleColor(CImGui.ImGuiCol_ChildBg, GALAXY_ESCAPE_VICTORY_PANEL_BACKGROUND)
    CImGui.PushStyleColor(CImGui.ImGuiCol_Border, GALAXY_ESCAPE_VICTORY_BORDER)
    CImGui.BeginChild("##galaxy_escape_victory_actions", ImVec2(panel_width, footer_height), panel_flags)

    footer_content_height = max(0.0, CImGui.GetContentRegionAvail().y - 2 * ui_px(1)) # Allow for the row's cell padding
    footer_flags = CImGui.ImGuiTableFlags_SizingStretchProp | CImGui.ImGuiTableFlags_BordersInnerV
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_CellPadding, ImVec2(ui_px(5), ui_px(1)))
    if CImGui.BeginTable("##escape_footer_columns", 2, footer_flags)
        CImGui.TableSetupColumn("Share", CImGui.ImGuiTableColumnFlags_WidthStretch, 0.64f0)
        CImGui.TableSetupColumn("Actions", CImGui.ImGuiTableColumnFlags_WidthStretch, 0.36f0)
        CImGui.TableNextRow(0, footer_content_height)
        CImGui.TableSetColumnIndex(0)
        share_start_x = CImGui.GetCursorPosX()
        share_width = CImGui.GetContentRegionAvail().x

        push_ui_font(; bold = true)
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
        CImGui.Dummy(ImVec2(0.0, ui_px(2)))

        email = "feedback@rocketplumbergame.com"
        copy_button_width = ui_px(18)
        feedback_gap = ui_px(2)
        email_width = CImGui.CalcTextSize(email).x
        inline_copy = share_width >= email_width + feedback_gap + copy_button_width
        feedback_width = email_width + (inline_copy ? feedback_gap + copy_button_width : 0.0)
        CImGui.SetCursorPosX(share_start_x + max(0.0, (share_width - feedback_width) / 2))
        CImGui.AlignTextToFramePadding()
        email_url = "mailto:$email?subject=Rocket%20Plumber%20-%20My%20Galactic%20Escape"
        if email_width <= share_width
            CImGui.TextLinkOpenURL(email, email_url)
        else
            # Keep the address legible and clickable when Copy needs its own line.
            local_part, domain = split(email, '@'; limit = 2)
            CImGui.TextLinkOpenURL(local_part * "@", email_url)
            CImGui.TextLinkOpenURL(domain, email_url)
        end
        if inline_copy
            CImGui.SameLine(0.0, feedback_gap)
        else
            CImGui.SetCursorPosX(share_start_x + max(0.0, (share_width - copy_button_width) / 2))
        end
        copied = CImGui.GetTime() < save_state.email_copied_until
        if CImGui.Button(copied ? "Copied!###escape_copy_email" : "Copy###escape_copy_email", ImVec2(copy_button_width, ui_px(6)))
            CImGui.SetClipboardText(email)
            save_state.email_copied_until = CImGui.GetTime() + 2.0
        end

        CImGui.Spacing()
        CImGui.Dummy(ImVec2(0.0, ui_px(2)))
        CImGui.PushStyleColor(CImGui.ImGuiCol_Text, GALAXY_ESCAPE_VICTORY_MUTED)
        CImGui.TextWrapped("Tip: If your save is too large put it in a ZIP!")
        CImGui.PopStyleColor()
        CImGui.Spacing()
        CImGui.Dummy(ImVec2(0.0, ui_px(2)))
        CImGui.Separator()
        CImGui.Spacing()
        CImGui.TextColored(GALAXY_ESCAPE_VICTORY_MUTED, "Enjoyed Rocket Plumber?\nWant updates on new features and releases?")
        CImGui.Dummy(ImVec2(0.0, ui_px(2)))
        push_ui_font(; bold = true)
        mailing_list_label = "Join the Mailing List"
        CImGui.SetCursorPosX(share_start_x + max(0.0, (share_width - CImGui.CalcTextSize(mailing_list_label).x) / 2))
        CImGui.TextLinkOpenURL(mailing_list_label, "https://rocketplumbergame.com/mailing-list/")
        CImGui.PopFont()

        CImGui.TableSetColumnIndex(1)
        action_group_height = 3 * action_button_height + 2 * action_button_gap
        action_start_y = CImGui.GetCursorPosY() + max(0.0, (footer_content_height - action_group_height) / 2)
        CImGui.SetCursorPosY(action_start_y)
        CImGui.PushStyleVarY(CImGui.ImGuiStyleVar_ItemSpacing, action_button_gap)
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

        if CImGui.Button("Exit to Main Menu", ImVec2(-1, action_button_height))
            inputstate.exit_reason = EXIT_MENU
        end

        if CImGui.Button("Exit Game", ImVec2(-1, action_button_height))
            inputstate.exit_reason = EXIT_QUIT
            GLFW.SetWindowShouldClose(window, true)
        end
        CImGui.EndDisabled()
        CImGui.PopStyleVar()
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
