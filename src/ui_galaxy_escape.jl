#= ---------- Galaxy Escape Victory Screen ----------- =#

const GALAXY_ESCAPE_VICTORY_BACKGROUND_TOP = ImVec4(0.025, 0.03, 0.075, 1.0)
const GALAXY_ESCAPE_VICTORY_BACKGROUND_BOTTOM = ImVec4(0.008, 0.01, 0.025, 1.0)
const GALAXY_ESCAPE_VICTORY_PANEL_BACKGROUND = ImVec4(0.055, 0.06, 0.105, 0.98)
const GALAXY_ESCAPE_VICTORY_SECTION_BACKGROUND = ImVec4(0.035, 0.04, 0.075, 0.95)
const GALAXY_ESCAPE_VICTORY_BORDER = ImVec4(0.52, 0.39, 0.12, 0.9)
const GALAXY_ESCAPE_VICTORY_ACCENT = ImVec4(1.0, 0.76, 0.18, 1.0)
const GALAXY_ESCAPE_VICTORY_VALUE = ImVec4(0.90, 0.94, 1.0, 1.0)
const GALAXY_ESCAPE_VICTORY_MUTED = ImVec4(0.67, 0.71, 0.80, 1.0)
const GALAXY_ESCAPE_VICTORY_STAR_EMPTY = ImVec4(0.11, 0.12, 0.17, 1.0)
const GALAXY_ESCAPE_VICTORY_STAR_EMPTY_OUTLINE = ImVec4(0.48, 0.43, 0.30, 1.0)
const GALAXY_ESCAPE_VICTORY_STAR_GLOW = ImVec4(1.0, 0.70, 0.08, 0.13)

const GALAXY_ESCAPE_VICTORY_FLAVOUR_TEXT =
    "You have broken free of the galactic plane. With the final burn complete, your ship is now en route to its " *
    "destination beyond the galaxy."

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
    CImGui.PushFont(C_NULL, font_size)
    text_width = CImGui.CalcTextSize(text).x
    available_width = CImGui.GetContentRegionAvail().x
    CImGui.SetCursorPosX(CImGui.GetCursorPosX() + max(0.0f0, (available_width - text_width) * 0.5f0))
    CImGui.TextColored(colour, text)
    CImGui.PopFont()
    return nothing
end

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
        CImGui.ImDrawFlags_Closed,
        earned ? 2.5f0 : 2.0f0,
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
    _render_victory_statistics_group("TIME", (
        ("Galactic time", "$(_format_victory_number(get_time_years(gamemap); decimal_places = 2)) years", 0.0f0),
        ("Play time", _format_victory_duration(get_recorded_play_time_seconds(gamemap)), 0.0f0),
        ("Detailed simulation time", _format_victory_duration(get_simulated_seconds(gamemap)), 0.0f0),
        ("Simulation ticks", _group_victory_integer_text(get_simulated_ticks(gamemap)), 0.0f0),
    ))

    CImGui.Spacing()
    _render_victory_statistics_group("FLIGHT", (
        ("Final speed", _format_victory_number(norm(get_velocity(gamemap))), 0.0f0),
        ("Total delta-V produced", _format_victory_number(get_total_delta_v(gamemap)), 0.0f0),
        ("Peak combined thrust", _format_victory_number(get_peak_thrust(gamemap)), 0.0f0),
        ("Peak estimated remaining delta-V", _format_victory_number(get_peak_estimated_delta_v(gamemap)), 0.0f0),
    ))

    encounter_rows = Tuple{String, String, Float32}[
        ("Completed encounters", _group_victory_integer_text(get_total_encounter_count(gamemap)), 0.0f0),
    ]
    for encounter_class in instances(EncounterClass)
        push!(encounter_rows, (
            encounter_class_label(encounter_class),
            _group_victory_integer_text(get_encounter_count(gamemap, encounter_class)),
            16.0f0,
        ))
    end
    CImGui.Spacing()
    _render_victory_statistics_group("ENCOUNTERS", encounter_rows)
    return nothing
end

"Render the exclusive final flight report shown after a galaxy escape is completed."
function ui_galaxy_escape_victory_render!(gamemap::GameMap, inputstate::InputState, window::GLFW.Window)
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

    panel_width = clamp(winsize.width - 32.0, 1.0, 720.0)
    panel_height = clamp(winsize.height - 32.0, 1.0, 900.0)
    action_button_height = 45.0
    action_button_gap = 10.0
    action_vertical_margin = 16.0
    action_group_height = 3 * action_button_height + 2 * action_button_gap
    footer_height = action_group_height + 2 * action_vertical_margin
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
    CImGui.PushFont(C_NULL, 23.0)
    CImGui.TextColored(GALAXY_ESCAPE_VICTORY_ACCENT, "STATISTICS")
    CImGui.PopFont()
    CImGui.Separator()
    CImGui.Spacing()
    _render_galaxy_escape_victory_statistics!(gamemap)
    CImGui.EndChild()
    CImGui.PopStyleColor(2)
    CImGui.PopStyleVar(3)

    footer_pos = ImVec2(panel_pos.x, panel_pos.y + report_height + footer_gap)
    CImGui.SetCursorPos(footer_pos)
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_WindowPadding, ImVec2(24.0, 8.0))
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_ChildRounding, 10.0)
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_ChildBorderSize, 1.0)
    CImGui.PushStyleColor(CImGui.ImGuiCol_ChildBg, GALAXY_ESCAPE_VICTORY_PANEL_BACKGROUND)
    CImGui.PushStyleColor(CImGui.ImGuiCol_Border, GALAXY_ESCAPE_VICTORY_BORDER)
    CImGui.BeginChild("##galaxy_escape_victory_actions", ImVec2(panel_width, footer_height), panel_flags)

    action_start_y = CImGui.GetCursorPosY() + max(0.0, (CImGui.GetContentRegionAvail().y - action_group_height) / 2.0)
    CImGui.SetCursorPosY(action_start_y)
    if CImGui.Button("Save Pre-Escape Map", ImVec2(-1, action_button_height))
        save_path = save_file(absolute(Path(joinpath(dirname(@__FILE__), "..", "maps"))); filterlist = "jld2")
        if !isnothing(save_path)
            pre_escape_map = get_pre_escape_map(gamemap)::GameMap
            savemap(pre_escape_map, "$save_path")
        end
    end

    CImGui.SetCursorPosY(action_start_y + action_button_height + action_button_gap)
    if CImGui.Button("Exit to Main Menu", ImVec2(-1, action_button_height))
        inputstate.exit_reason = EXIT_MENU
    end

    CImGui.SetCursorPosY(action_start_y + 2 * (action_button_height + action_button_gap))
    if CImGui.Button("Exit Game", ImVec2(-1, action_button_height))
        inputstate.exit_reason = EXIT_QUIT
        GLFW.SetWindowShouldClose(window, true)
    end
    
    CImGui.EndChild()
    CImGui.PopStyleColor(2)
    CImGui.PopStyleVar(3)

    CImGui.End()
    CImGui.PopStyleColor()
    CImGui.PopStyleVar(2)
    return nothing
end
