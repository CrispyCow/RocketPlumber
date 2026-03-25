# ===============================================================
# UI Game Windows (Inspector, Timer, Toolbar, Properties)
# ===============================================================

# Lightweight usings to help editor intellisense
using CImGui
using LinearAlgebra, Printf, StaticArrays
using HexFrame, FlowEngine, FlowMap, HexComponentsAPI
using HexFlowRendering, HexFluids
using ImPlot
using HexFlowProcGen
using HexFlowCalculator
using HexFlowControl


const STANDARD_MODE_CONFIG = (
    (INSPECT, "[1] Inspect"),
    (MOVE, "[2] Move"),
    (PIPE, "[3] Edit Pipes"),
)
const EDITOR_MODE_CONFIG = (
    STANDARD_MODE_CONFIG...,
    (DELETE, "[4] Delete"),
    (TILE, "[5] Create Tile"),
    (SURFACE_EDIT, "[6] Edit Surface"),
)

const PIPE_TYPES = (
    ("Scrap Pipe", ScrapPipeBehav),
    ("Big Pipe", BigPipeBehav),
)

const MODE_DESCRIPTIONS = Dict(
    TILE => "Configuring TILE for placement...",
    PIPE => "Left-click: place pipe. Click existing: delete.\nRight-click: component/ship actions.",
    INSPECT => "Left-click: interact.\nRight-click: component/ship actions.",
    MOVE => "Click a part to select, click to move.\nRight-click: component/ship actions.",
    DELETE => "Click a part to delete it.",
)
mode_description(mode::PlacementModes) = get(MODE_DESCRIPTIONS, mode, "No properties available")

"""
Generic tunable editor for the property box.
Returns a tuple of `Cfloat` values from ImGui input widgets.
"""
function edit_tunables!(tunables_tuple)
    tunables = collect(tunables_tuple)
    cfloat_array = similar(tunables, Cfloat)

    for (index, props) in enumerate(tunables)
        CImGui.PushID(index)
        cfloat_array[index] = Cfloat(props.current_val)

        CImGui.Text("$(props.type_desc) [$index]")
        CImGui.SetNextItemWidth(100.0)
        @c CImGui.InputFloat(props.unit_desc, pointer(cfloat_array, index), 0.0, 100.0, "%.3f")
        CImGui.Separator()
        CImGui.PopID()
    end

    return tuple(cfloat_array...)
end

"Text description for a tile coordinate."
coord_description(tile::TileCoord) = "($(tile.q), $(tile.r))"

"Text description for a vertex coordinate."
function coord_description(vert::VertexCoord)
    direction = if vert.dir == HexFrame.Q_POS
        "Right"
    elseif vert.dir == HexFrame.Q_NEG
        "Left"
    else
        "(ERR: improper vertex)"
    end
    return "$direction node of $(coord_description(vert.tile))"
end

"Display component tunables in read-only format."
function display_component_values!(tunables_tuple::NTuple{N, TunableProps}) where {N}
    if N == 0
        CImGui.Text("No configurable values")
        return nothing
    end

    for (index, props) in enumerate(tunables_tuple)
        CImGui.PushID(index)

        CImGui.Text("$(props.type_desc) [$index]")
        CImGui.Text("$(format_value(props.current_val)) $(props.unit_desc)")
        CImGui.Separator()

        CImGui.PopID()
    end
    return nothing
end

"Display circuit element details in the property inspector."
function display_element_details!(elements::Vector{AbsoluteElement}, derivedmapstate::DerivedMapState, mna_state::MNA_State)
    if isempty(elements)
        CImGui.Text("No elements")
        return nothing
    end

    for (index, element) in enumerate(elements)
        CImGui.PushID(index)

        props = get_tunables(element)

        CImGui.Text("$(props.type_desc) [$index]")
        CImGui.Text("Value: $(format_value(props.current_val)) $(props.unit_desc)")

        current = abs_element_get_current(element, derivedmapstate, mna_state)
        if isnothing(current)
            CImGui.Text("Current: Not Connected")
        else
            CImGui.Text("Current: $(format_value(current)) A")
        end

        CImGui.Separator()
        CImGui.PopID()
    end
    return nothing
end

"Inspect nothing: placeholder text."
inspect_ui!(::Nothing, ::GameMap, ::DerivedMapState, ::MNA_State) = CImGui.Text("Nothing.")

"Inspect a tile coordinate, displaying component values and element details."
function inspect_ui!(tile::TileCoord, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State)
    CImGui.Text("Hex Tile at $(coord_description(tile))")
    internalnode = NodeCoord(tile, HexFrame.NODE_INTERNAL)
    if haskey(mna_state.node_voltages, internalnode)
        CImGui.Text("Internal Node Voltage: $(format_value(mna_state.node_voltages[internalnode])) V")
    end

    found_comp, comp_ship = has_component_any_ship(gamemap, tile)
    if found_comp
        tilecomp, _ = get_component_any_ship(gamemap, tile)
        CImGui.Text("Type: $(String(nameof(typeof(tilecomp.component))))")
        CImGui.Text("Ship: $(comp_ship)")

        # Component Values
        CImGui.Text("\nValues:")
        CImGui.Separator()
        CImGui.Indent()
        tunables = get_tunables(tilecomp)
        display_component_values!(tunables)
        CImGui.Unindent()

        # Element Details
        CImGui.Text("\nDerived Elements:")
        CImGui.Separator()
        CImGui.Indent()
        elements = produce_abs_elements(tilecomp, tile)
        display_element_details!(collect(elements), derivedmapstate, mna_state)
        CImGui.Unindent()
    else
        CImGui.Text("No component on this tile.")
    end

    return nothing
end

"Inspect a vertex coordinate, displaying node voltage and fluid tag."
function inspect_ui!(vert::VertexCoord, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State)
    CImGui.Text(coord_description(vert))
    node = to_nodecoord(vert)

    # Exit early if node has no voltage defined
    if !haskey(mna_state.node_voltages, node)
        return nothing
    end

    CImGui.Text("Node Voltage: $(format_value(mna_state.node_voltages[node])) V\n")

    fluidtag = get(derivedmapstate.nodeactualfluids, node, nothing)
    fluidstr = String(Symbol(fluidtag))
    CImGui.Text("Fluid Tag: $(fluidstr)")

    # Display contributing fluid tags from adjacent tiles (only for axis nodes)
    if HexFrame.is_axis(node.dir)
        CImGui.Text("\nContributing Fluid Tags:")
        CImGui.Separator()
        CImGui.Indent()

        contributing_tags = get_node_fluid_tags(node, gamemap)
        adjacent_tiles_info = HexFrame.get_adjacent_tiles_for_node(node)

        for (idx, ((tile, _), tag)) in enumerate(zip(adjacent_tiles_info, contributing_tags))
            tag_str = String(Symbol(tag))
            CImGui.Text("Tile $(coord_description(tile)): $tag_str")
        end

        CImGui.Unindent()
    end

    return nothing
end

"Inspect an edge coordinate, displaying pipe information."
function inspect_ui!(edge::EdgeCoord, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State)
    CImGui.Text("Pipe Between:")
    CImGui.Text("$(coord_description(edge.v1)) and $(coord_description(edge.v2))")

    # Check for pipe behaviors
    found_pipe, pipe_ship = has_pipe_any_ship(gamemap, edge)
    if found_pipe
        pipe_behav, _ = get_pipe_any_ship(gamemap, edge)
        CImGui.Text("Type: $(nameof(typeof(pipe_behav)))")
        CImGui.Text("Ship: $(pipe_ship)")

        # Pipe Values
        CImGui.Text("\nPipe Values:")
        CImGui.Separator()
        CImGui.Indent()
        tunables = get_pipe_tunables(pipe_behav)
        display_component_values!(tunables)
        CImGui.Unindent()

        # Element Details
        CImGui.Text("\nElement Details:")
        CImGui.Separator()
        CImGui.Indent()
        elements = produce_abs_elements(pipe_behav, edge)
        display_element_details!(collect(elements), derivedmapstate, mna_state)
        CImGui.Unindent()
    else
        CImGui.Text("No pipe at this location.")
    end

    return nothing
end

#= ---------- Helper Functions ---------- =#

"Map an angle in degrees to the nearest `HexAxis` direction (60-degree quantisation)."
function angle_to_hexaxis(angle_deg::Float64)::HexFrame.HexAxis
    a = mod(angle_deg, 360.0)
    idx = round(Int, a / 60.0) % 6
    return (
        HexFrame.Q_POS, HexFrame.S_NEG, HexFrame.R_POS,
        HexFrame.Q_NEG, HexFrame.S_POS, HexFrame.R_NEG,
    )[idx + 1]
end

"Return a normalised vector, or `default` if the input magnitude is near zero."
function normalise_or_default(v::SVector{2, Float64}, default::SVector{2, Float64} = SVector(1.0, 0.0))::SVector{2, Float64}
    mag = norm(v)
    return mag > 1.0e-10 ? v / mag : default
end

"Rotate a 2D vector by `angle_rad` in standard Cartesian coordinates."
function rotate_vec2(v::SVector{2, Float64}, angle_rad::Float64)::SVector{2, Float64}
    c = cos(angle_rad)
    s = sin(angle_rad)
    return SVector(c * v[1] - s * v[2], s * v[1] + c * v[2])
end

"Rotate a ship-space vector into space-map space using the burn direction."
function _ship_to_spacemap(ship_vec::SVector{2, Float64}, burn_dv::SVector{2, Float64})::SVector{2, Float64}
    burn_mag = norm(burn_dv)
    burn_mag < 1.0e-10 && return ship_vec  # No rotation needed
    burn_angle = atan(burn_dv[2], burn_dv[1])
    return rotate_vec2(ship_vec, burn_angle)
end

"Predict player position at `target_time` given current state and pending manoeuvre burns."
function predict_player_position_with_manoeuvre(
        current_pos::SVector{2, Float64},
        current_vel::SVector{2, Float64},
        current_time::Float64,
        target_time::Float64,
        manoeuvre::ManoeuvreData,
    )::SVector{2, Float64}
    target_time <= current_time && return current_pos

    # Collect (event_time, space-map ΔV) pairs for pending burns.
    # approach_burn_dv and capture_burn_dv are already in space-map space;
    # burn_remaining_dv is in ship space and must be rotated back.
    pending_events = Tuple{Float64, SVector{2, Float64}}[]

    if manoeuvre.phase == PHASE_APPROACH_BURN
        remaining_spacemap = _ship_to_spacemap(manoeuvre.burn_remaining_dv, manoeuvre.approach_burn_dv)
        push!(pending_events, (current_time, remaining_spacemap))
        push!(pending_events, (manoeuvre.intercept_time, manoeuvre.capture_burn_dv))

    elseif manoeuvre.phase == PHASE_COAST
        push!(pending_events, (manoeuvre.intercept_time, manoeuvre.capture_burn_dv))

    elseif manoeuvre.phase == PHASE_CAPTURE_BURN
        remaining_spacemap = _ship_to_spacemap(manoeuvre.burn_remaining_dv, manoeuvre.capture_burn_dv)
        push!(pending_events, (current_time, remaining_spacemap))
    end

    sort!(pending_events, by = first)
    pos = current_pos
    vel = current_vel
    t_cursor = current_time

    for (event_time, delta_v) in pending_events
        event_time < t_cursor && continue
        if event_time > target_time
            break
        end

        pos += vel * (event_time - t_cursor)
        vel += delta_v
        t_cursor = event_time
    end

    pos += vel * (target_time - t_cursor)
    return pos
end

"Clear the current space-map selection and its cached preview state."
function clear_spacemap_selection!(inputstate::InputState)
    inputstate.gui_inputs[:spacemap_selected_idx] = 0
    inputstate.gui_inputs[:spacemap_selected_iteration] = 0
    inputstate.gui_inputs[:spacemap_prev_selected_idx] = 0
    inputstate.gui_inputs[:spacemap_prev_selected_iteration] = 0
    return nothing
end

"Return the selected encounter index after validating it against the live encounter list."
function validate_spacemap_selection!(inputstate::InputState, encounter_points)::Int
    selected_idx = get!(inputstate.gui_inputs, :spacemap_selected_idx, 0)::Int
    selected_iteration = get!(inputstate.gui_inputs, :spacemap_selected_iteration, 0)::Int

    selected_idx == 0 && return 0
    if selected_idx < 0 || selected_idx > length(encounter_points)
        clear_spacemap_selection!(inputstate)
        return 0
    end

    if encounter_points[selected_idx].iteration != selected_iteration
        clear_spacemap_selection!(inputstate)
        return 0
    end

    return selected_idx
end

"Reset the preview delta-V slider when the selected encounter changes."
function reset_spacemap_preview_dv!(inputstate::InputState, selected_idx::Int, selected_iteration::Int, min_dv::Float64)
    prev_selected = get!(inputstate.gui_inputs, :spacemap_prev_selected_idx, 0)::Int
    prev_iteration = get!(inputstate.gui_inputs, :spacemap_prev_selected_iteration, 0)::Int

    if selected_idx != prev_selected || selected_iteration != prev_iteration
        inputstate.gui_inputs[:spacemap_delta_v] = Cfloat(min_dv)
        inputstate.gui_inputs[:spacemap_prev_selected_idx] = selected_idx
        inputstate.gui_inputs[:spacemap_prev_selected_iteration] = selected_iteration
    end

    return nothing
end

"Log-scaled encounter arrow length with guaranteed minimum visibility."
function encounter_arrow_length(
        speed::Float64,
        min_speed::Float64,
        max_speed::Float64,
        min_length::Float64,
        max_length::Float64
    )::Float64
    v = clamp(speed, min_speed, max_speed)
    log_min = log1p(min_speed / min_speed)
    log_max = log1p(max_speed / min_speed)
    log_v = log1p(v / min_speed)
    t = (log_v - log_min) / max(log_max - log_min, 1.0e-10)
    return min_length + t * (max_length - min_length)
end

#= ---------- Space Map Constants ---------- =#

const SPACEMAP_LEFT_PANEL_WIDTH = 280.0
const SPACEMAP_CLICK_RADIUS_SQ = 400.0   # Squared distance in plot units for click detection

"Convert a `FluidTags` value to an `ImVec4` colour for UI display."
function fluid_tag_to_imvec4(tag::HexFluids.FluidTags)::ImVec4
    if tag == HexFluids.NONE
        return ImVec4(0.6, 0.6, 0.6, 0.7)
    end
    c = HexFlowRendering.get_fluid_colour(tag)
    return ImVec4(Float64(c[1]), Float64(c[2]), Float64(c[3]), Float64(c[4]))
end

"Human-readable label for an `EncounterClass`."
function encounter_class_label(cls::EncounterClass)::String
    cls == ENCOUNTER_SHIP && return "Jumbled Ship"
    cls == ENCOUNTER_FUEL_CACHE && return "Fuel Cache"
    cls == ENCOUNTER_SCRAP && return "Scrap Clump"
    return "Unknown"
end

#= ---------- Velocity Tracker Constants ---------- =#

const VELOCITY_TRACKER_WIDTH = 300.0
const VELOCITY_TRACKER_MIN_AXIS_RANGE = 0.001    # Minimum axis half-range to avoid degenerate plot

# Mode colours for the ImPlot velocity tracker
const ACCEL_COLOUR = ImVec4(0.4, 1.0, 0.4, 1.0)       # green
const ACCEL_GRID_COLOUR = ImVec4(0.4, 1.0, 0.4, 0.15)      # faint green grid
const DV_COLOUR = ImVec4(1.0, 0.7, 0.2, 1.0)       # amber
const DV_GRID_COLOUR = ImVec4(1.0, 0.7, 0.2, 0.15)      # faint amber grid
const COMPASS_X_COLOUR = ImVec4(1.0, 0.5, 0.3, 0.45)
const COMPASS_Y_COLOUR = ImVec4(0.3, 0.8, 1.0, 0.45)

"""
Render the velocity and manoeuvre tracker in the top-left corner.
Uses ImPlot with axes coloured green (acceleration mode) or amber (manoeuvre/ΔV mode).
Read-only: all phase transitions happen in the calculator.
"""
function ui_velocity_tracker_render(
        gamestate::GameState, gamemap::GameMap,
        inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC,
    )
    velocity = get_velocity(gamemap)
    accel_world = gamestate.acceleration_space_map_frame
    vel_mag = norm(velocity)
    accel_mag = norm(accel_world)

    has_manoeuvre = has_active_manoeuvre(gamemap)
    manoeuvre = get_active_manoeuvre(gamemap)

    # Show ΔV plot only during active burn phases
    show_dv_mode = has_manoeuvre &&
        (manoeuvre.phase == PHASE_APPROACH_BURN || manoeuvre.phase == PHASE_CAPTURE_BURN)

    compass_angle = 0.0
    accel_plot = accel_world
    if show_dv_mode
        # Derive burn direction from the planned space-map ΔV vector
        burn_dv = manoeuvre.phase == PHASE_APPROACH_BURN ? manoeuvre.approach_burn_dv : manoeuvre.capture_burn_dv
        burn_unit = normalise_or_default(burn_dv)
        compass_angle = atan(burn_unit[2], burn_unit[1])

        # Display acceleration in local burn-frame coordinates during burn phases.
        accel_plot = rotate_vec2(accel_world, -compass_angle)
    end

    # Window sizing: taller when manoeuvre text is shown
    base_height = 320.0
    speed_controls_height = 60.0
    manoeuvre_extra = has_manoeuvre ? 110.0 : 0.0
    total_height = base_height + speed_controls_height + manoeuvre_extra

    ui_window("Velocity Tracker", (0.0, 0.0), (VELOCITY_TRACKER_WIDTH, total_height))

    # Speed buttons — greyed out when paused
    is_paused = @atomic :monotonic flowcalc_ipc.shared_state.is_paused
    is_paused && CImGui.BeginDisabled()
    for speed in (SIM_1X, SIM_2X, SIM_4X, SIM_MAX)
        label = sim_speed_label(speed)
        is_current = inputstate.sim_speed === speed
        is_current && CImGui.BeginDisabled()
        if CImGui.Button(label, (60.0, 0.0))
            inputstate.sim_speed = speed
            @atomic :monotonic flowcalc_ipc.shared_state.target_ups = sim_speed_to_ups(speed)
        end
        is_current && CImGui.EndDisabled()
        speed !== SIM_MAX && CImGui.SameLine()
    end
    is_paused && CImGui.EndDisabled()

    # Pause button - full width of content area
    pause_label = is_paused ? "Un-Pause" : "Pause"
    if CImGui.Button(pause_label, ImVec2(CImGui.GetContentRegionAvail().x, 0.0))
        @atomic :monotonic flowcalc_ipc.shared_state.is_paused = !is_paused
    end

    CImGui.SeparatorText("Ship Info")

    CImGui.Text(@sprintf("Velocity:     %.2f", vel_mag))
    CImGui.Text(@sprintf("Acceleration: %.4f", accel_mag))
    CImGui.Text(@sprintf("Mass:         %.1f", get_mass(gamemap)))
    CImGui.Text(@sprintf("Ship delta-V: %.1f", estimate_min_delta_v(gamemap)))

    # Choose axis labels and colours
    if show_dv_mode
        axis_colour = DV_COLOUR
        grid_colour = DV_GRID_COLOUR
        x_label = "delta-V X"
        y_label = "delta-V Y"
    else
        axis_colour = ACCEL_COLOUR
        grid_colour = ACCEL_GRID_COLOUR
        x_label = "Accel X"
        y_label = "Accel Y"
    end

    # Compute symmetric axis range
    max_component = 0.0
    if show_dv_mode
        rem_dv = manoeuvre.burn_remaining_dv
        max_component = max(max_component, abs(rem_dv[1]), abs(rem_dv[2]))
    elseif accel_mag > 1.0e-10
        max_component = max(max_component, abs(accel_plot[1]), abs(accel_plot[2]))
    end
    axis_range = max(max_component * 1.4, VELOCITY_TRACKER_MIN_AXIS_RANGE)

    # Style axes with mode-appropriate colours
    ImPlot.PushStyleColor(ImPlot.ImPlotCol_AxisText, axis_colour)
    ImPlot.PushStyleColor(ImPlot.ImPlotCol_AxisGrid, grid_colour)
    ImPlot.PushStyleColor(ImPlot.ImPlotCol_AxisTick, axis_colour)
    ImPlot.PushStyleColor(ImPlot.ImPlotCol_PlotBg, ImVec4(0.08, 0.08, 0.13, 1.0))

    available_plot_size = CImGui.GetContentRegionAvail()
    plot_size = ImVec2(available_plot_size.x, available_plot_size.y - manoeuvre_extra)

    plot_flags = ImPlot.ImPlotFlags_Equal | ImPlot.ImPlotFlags_NoLegend |
        ImPlot.ImPlotFlags_NoMenus | ImPlot.ImPlotFlags_NoBoxSelect |
        ImPlot.ImPlotFlags_NoTitle | ImPlot.ImPlotFlags_NoMouseText
    ImPlot.SetNextAxesLimits(-axis_range, axis_range, -axis_range, axis_range, CImGui.ImGuiCond_Always)

    if ImPlot.BeginPlot("##velocity_tracker", plot_size, plot_flags)
        axis_flags = ImPlot.ImPlotAxisFlags_NoMenus
        ImPlot.SetupAxes(x_label, y_label, axis_flags, axis_flags)
        if !show_dv_mode
            ImPlot.SetupAxisFormat(ImPlot.ImAxis_X1, "%.2f")
            ImPlot.SetupAxisFormat(ImPlot.ImAxis_Y1, "%.2f")
        end

        # Compass guides: ship-local X/Y axes, rotated during burn phases.
        compass_len = axis_range * 0.9
        x_axis = rotate_vec2(SVector(compass_len, 0.0), compass_angle)
        y_axis = rotate_vec2(SVector(0.0, compass_len), compass_angle)

        ImPlot.SetNextLineStyle(COMPASS_X_COLOUR, 1.0)
        ImPlot.PlotLine(
            "##compass_x",
            Float64[-x_axis[1], x_axis[1]],
            Float64[-x_axis[2], x_axis[2]]
        )
        ImPlot.SetNextLineStyle(COMPASS_Y_COLOUR, 1.0)
        ImPlot.PlotLine(
            "##compass_y",
            Float64[-y_axis[1], y_axis[1]],
            Float64[-y_axis[2], y_axis[2]]
        )

        # Remaining ΔV arrow (amber, only during burn phases)
        if show_dv_mode
            rem_dv = manoeuvre.burn_remaining_dv
            if norm(rem_dv) > 1.0e-10
                ImPlot.SetNextLineStyle(DV_COLOUR, 2.5)
                ImPlot.PlotLine("Remaining ΔV", Float64[0.0, rem_dv[1]], Float64[0.0, rem_dv[2]])
                ImPlot.SetNextMarkerStyle(ImPlot.ImPlotMarker_Circle, 4.0, DV_COLOUR)
                ImPlot.PlotScatter("##dv_tip", Float64[rem_dv[1]], Float64[rem_dv[2]])
            end
        end


        # Acceleration arrow (green line from origin)
        if accel_mag > 1.0e-10
            if show_dv_mode
                accel_dir = accel_plot / max(norm(accel_plot), 1.0e-10)
                accel_display = accel_dir * (axis_range * 0.3)
                ImPlot.SetNextLineStyle(ImVec4(0.4, 1.0, 0.4, 0.5), 4.0)
                ImPlot.PlotLine("##accel_dir", Float64[0.0, accel_display[1]], Float64[0.0, accel_display[2]])
            else
                ImPlot.SetNextLineStyle(ACCEL_COLOUR, 2.5)
                ImPlot.PlotLine("Acceleration", Float64[0.0, accel_plot[1]], Float64[0.0, accel_plot[2]])
                ImPlot.SetNextMarkerStyle(ImPlot.ImPlotMarker_Circle, 5.0, ACCEL_COLOUR)
                ImPlot.PlotScatter("##accel_tip", Float64[accel_plot[1]], Float64[accel_plot[2]])
            end
        end

        # Origin marker (white plus sign)
        ImPlot.SetNextMarkerStyle(ImPlot.ImPlotMarker_Plus, 6.0, ImVec4(1.0, 1.0, 1.0, 0.8))
        ImPlot.PlotScatter("##origin", Float64[0.0], Float64[0.0])

        ImPlot.EndPlot()
    end

    ImPlot.PopStyleColor(4)

    # Manoeuvre phase status (read-only — all transitions in the calculator)
    if has_manoeuvre
        CImGui.SeparatorText("Manoeuvre Info")
        phase = manoeuvre.phase
        CImGui.TextWrapped(phase_description(phase))

        if phase == PHASE_APPROACH_BURN
            rem_dv = manoeuvre.burn_remaining_dv
            CImGui.TextWrapped(@sprintf("Remaining delta-V: (%.2f, %.2f)", rem_dv[1], rem_dv[2]))

        elseif phase == PHASE_COAST
            CImGui.TextWrapped("Open Space Map (M) and progress time until intercept.")

        elseif phase == PHASE_CAPTURE_BURN
            rem_dv = manoeuvre.burn_remaining_dv
            CImGui.TextWrapped(@sprintf("Remaining delta-V: (%.2f, %.2f)", rem_dv[1], rem_dv[2]))

        elseif phase == PHASE_ENCOUNTER_READY
            CImGui.TextWrapped("Encounter triggering...")
        end
    end

    CImGui.End()
    return nothing
end

"""
Renders the toolbar with mode select and terminal on the bottom of the window.
Can mutate inputstate.placementmode based on input from the radio buttons.
Must be called within ui_renderwrap.
"""
function ui_toolbar_render!(
        inputstate::InputState,
        winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}},
        threadsafe_console_see::Function
    )
    win_float = to_float(winsize)

    ui_window("Toolbar", (0.0, win_float.height - toolbarheight), (win_float.width, toolbarheight))
    CImGui.Columns(2)

    # Mode Select
    CImGui.SetColumnWidth(0, 150.0)
    CImGui.Text("Modes:")
    modes_config = inputstate.editor_mode ? EDITOR_MODE_CONFIG : STANDARD_MODE_CONFIG
    for (mode, label) in modes_config
        if CImGui.RadioButton(label, inputstate.placementmode === mode)
            set_placementmode!(inputstate, mode)
        end
    end

    # Terminal
    CImGui.NextColumn()
    CImGui.Text("TERMINAL:")
    CImGui.BeginChild("TerminalLog", (0.0, 0.0), true)
    for message in threadsafe_console_see()
        CImGui.TextUnformatted(message)
    end
    # Auto-scroll to bottom if already at bottom
    if CImGui.GetScrollY() >= (CImGui.GetScrollMaxY() - 1.0)
        CImGui.SetScrollHereY(1.0)
    end
    CImGui.EndChild()

    CImGui.End()
    return nothing
end

"""
Renders the property box on the right side of the window.
Must be called within ui_renderwrap.
"""
function ui_propertybox_render!(
        inputstate::InputState, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_State,
        winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}}, flowcalc_ipc::FlowCalculatorIPC
    )
    pendcomp = inputstate.pendingcomponent
    win_float = to_float(winsize)

    ui_window("Properties", (win_float.width - propertyboxwidth, 0.0), (propertyboxwidth, win_float.height - toolbarheight))

    # Display mode description
    CImGui.Text("PROPERTIES:")
    CImGui.Text(mode_description(inputstate.placementmode))
    CImGui.Separator()
    CImGui.NewLine()

    # TILE mode: edit component tunables
    if inputstate.placementmode == TILE
        CImGui.Text("Tile Tunable Values:")
        CImGui.Separator()
        CImGui.Indent()
        new_tunables = edit_tunables!(get_tunables(pendcomp))
        inputstate.pendingcomponent = set_tunables(pendcomp, new_tunables)
        CImGui.Unindent()
    end

    # PIPE mode: select pipe type and edit tunables
    if inputstate.placementmode == PIPE
        # Show type selection buttons if in editor mode
        if inputstate.editor_mode
            CImGui.Text("Select Pipe Type:")
            for (label, pipe_type) in PIPE_TYPES
                if CImGui.Button(label)
                    inputstate.pendingpipebehavior = pipe_type()
                    println("Set pending pipe to $(nameof(pipe_type))")
                end
                CImGui.SameLine()
            end
            CImGui.NewLine()
            CImGui.NewLine()
        else
            # Can only place scrap pipes outside editor mode
            inputstate.pendingpipebehavior = ScrapPipeBehav()
        end

        # Show tunables for the selected pipe behavior
        CImGui.Text("Pipe Properties:")
        CImGui.Separator()

        CImGui.Indent()
        new_tunables = edit_tunables!(get_pipe_tunables(inputstate.pendingpipebehavior))
        inputstate.pendingpipebehavior = set_pipe_tunables(inputstate.pendingpipebehavior, new_tunables)
        CImGui.Unindent()
    end

    # INSPECT mode: display info about right-click selected or hovered element
    if inputstate.placementmode == INSPECT
        selected = inputstate.rightclick_selectedcoord

        if !isnothing(selected)
            CImGui.Text("Inspecting selected part...")
            CImGui.Separator()
            CImGui.NewLine()

            found_comp, comp_ship = has_component_any_ship(gamemap, selected)
            if found_comp
                tilecomp, _ = get_component_any_ship(gamemap, selected)
                CImGui.Text("Hex Tile at $(coord_description(selected))")
                CImGui.Text("Type: $(String(nameof(typeof(tilecomp.component))))")
                CImGui.Text("Ship: $(comp_ship)")

                # Values section (read-only — actions are in the popup)
                CImGui.NewLine()
                CImGui.Text("Values:")
                CImGui.Separator()
                CImGui.Indent()
                tunables = get_tunables(tilecomp)
                display_component_values!(tunables)
                CImGui.Unindent()

                # Element Details
                CImGui.Text("\nDerived Elements:")
                CImGui.Separator()
                CImGui.Indent()
                elements = produce_abs_elements(tilecomp, selected)
                display_element_details!(collect(elements), derivedmapstate, mna_state)
                CImGui.Unindent()
            else
                CImGui.Text("Selected component no longer exists.")
                inputstate.rightclick_selectedcoord = nothing
            end
        else
            # No right-click selection: show hovered part info
            clicked = get_clicked(inputstate)
            inspect_ui!(clicked, gamemap, derivedmapstate, mna_state)
        end
    end

    CImGui.End()
    return nothing
end


"""
Display a message in the centre of the space map area when no map is available.
Must be called within ui_renderwrap.
"""
function render_spacemap_no_map_message!(win_float)
    centre_y = win_float.height / 2.0
    text = "No space map available — initialise from the developer menu."
    text_size = CImGui.CalcTextSize(text)
    CImGui.SetCursorPos(ImVec2((win_float.width - text_size.x) / 2.0, centre_y))
    CImGui.Text(text)
    return nothing
end

"""
Renders the full-screen encounter planning space map overlay.
Uses ImPlot to show encounter positions in 2D space. Left panel has time controls,
manoeuvre status, and encounter selection. Right area has the scatter plot.
Must be called within ui_renderwrap.
"""
function render_spacemap_active_manoeuvre_panel!(
        flowcalc_ipc::FlowCalculatorIPC,
        gamemap::GameMap,
        gamestate::GameState,
    )
    manoeuvre = get_active_manoeuvre(gamemap)
    time_progressing = is_time_progressing(gamemap)
    timewarp_blocked = is_timewarp_blocked(gamemap, gamestate)

    phase = manoeuvre.phase

    CImGui.TextColored(ImVec4(1.0, 0.7, 0.2, 1.0), "Manoeuvre Active")
    CImGui.Spacing()

    CImGui.Text(phase_description(phase))
    CImGui.Text(@sprintf("Approach Burn delta-V: %.1f", norm(manoeuvre.approach_burn_dv)))
    CImGui.Text(@sprintf("Capture Burn delta-V: %.1f", norm(manoeuvre.capture_burn_dv)))
    CImGui.Spacing()

    if phase == PHASE_COAST && !time_progressing
        if button_with_disable("Wait for Capture Burn", ImVec2(-1, 30), timewarp_blocked)
            @atomic :monotonic flowcalc_ipc.shared_state.target_spacemap_time = manoeuvre.intercept_time
        end
    end

    CImGui.Spacing()
    if CImGui.Button("Cancel Manoeuvre", ImVec2(-1, 25))
        modified_map = deepcopy(gamemap)
        clear_active_manoeuvre!(modified_map)
        enqueue_map_override!(flowcalc_ipc, modified_map)
        @info "Manoeuvre cancelled"
    end

    return nothing
end

"Render read-only information for the selected or targeted encounter."
function render_spacemap_target_info!(gamemap::GameMap, selected_idx::Int)
    encounter_points = get_encounter_points(gamemap)
    player_pos = get_position(gamemap)
    player_vel = get_velocity(gamemap)
    current_time = get_time_years(gamemap)::Float64

    target_idx = selected_idx
    if has_active_manoeuvre(gamemap)
        target_idx = get_active_manoeuvre(gamemap).target_encounter_index
    end

    if target_idx < 1 || target_idx > length(encounter_points)
        CImGui.TextWrapped("Click an encounter point on the map to select it.")
        return nothing
    end

    ep = encounter_points[target_idx]
    ep_pos = get_encounter_position(ep, current_time)
    distance = norm(ep_pos - player_pos)

    CImGui.TextColored(
        fluid_tag_to_imvec4(ep.fuel_tag),
        "$(encounter_class_label(ep.encounter_class)): $(ep.display_name)"
    )
    fuel_label = fluid_tag_label(ep.fuel_tag)
    if !isnothing(fuel_label)
        CImGui.TextColored(fluid_tag_to_imvec4(ep.fuel_tag), "Fuel: $fuel_label")
    end
    CImGui.Text(@sprintf("Richness: %.1f", ep.richness))
    CImGui.Text(@sprintf("Distance: %.0f", distance))
    CImGui.Text(@sprintf("Relative Vel: %.1f", norm(ep.velocity - player_vel)))
    return nothing
end

"Render manoeuvre preview controls for the selected encounter."
function render_spacemap_manoeuvre_planning_panel!(
        inputstate::InputState,
        flowcalc_ipc::FlowCalculatorIPC,
        gamemap::GameMap,
        selected_idx::Int,
    )
    selected_idx == 0 && return nothing

    player_pos = get_position(gamemap)
    player_vel = get_velocity(gamemap)
    current_time = get_time_years(gamemap)::Float64
    encounter_points = get_encounter_points(gamemap)
    selected_iteration = get(inputstate.gui_inputs, :spacemap_selected_iteration, 0)::Int
    ep = encounter_points[selected_idx]
    min_dv = calculate_minimum_intercept_dv(player_vel, ep.velocity) + 1.0

    CImGui.TextColored(ImVec4(0.6, 0.8, 1.0, 1.0), "Intercept Calculated")
    CImGui.Spacing()

    reset_spacemap_preview_dv!(inputstate, selected_idx, selected_iteration, min_dv)

    delta_v_slider = get!(inputstate.gui_inputs, :spacemap_delta_v, Cfloat(min_dv))::Cfloat
    delta_v_slider = max(delta_v_slider, Cfloat(min_dv))

    CImGui.Text(@sprintf("Min Intercept delta-V: %.1f", min_dv))
    CImGui.Spacing()

    slider_min = Float32(max(min_dv, 1.0))
    slider_max = Float32(max(min_dv * 3.0, 100.0))
    CImGui.SetNextItemWidth(-1)
    @cref CImGui.SliderFloat("##dv_slider", &delta_v_slider, slider_min, slider_max, "delta-V: %.0f")
    inputstate.gui_inputs[:spacemap_delta_v] = delta_v_slider
    total_dv = Float64(delta_v_slider)

    preview_manoeuvre = plan_intercept_manoeuvre(
        player_pos, player_vel, ep, current_time, total_dv
    )

    if !isnothing(preview_manoeuvre)
        time_to_intercept = preview_manoeuvre.intercept_time - current_time
        CImGui.Text(@sprintf("Time to Intercept: %.3f yr", time_to_intercept))
    end

    CImGui.Spacing()
    can_plan = !isnothing(preview_manoeuvre)

    button_tooltip = !can_plan ? "No manoeuvre preview available" : nothing
    if button_with_disable("Plan Manoeuvre", ImVec2(-1, 35), !can_plan; tooltip = button_tooltip)
        if !isnothing(preview_manoeuvre)
            modified_map = deepcopy(gamemap)
            set_target_time!(modified_map, current_time)
            set_active_manoeuvre!(modified_map, preview_manoeuvre)
            enqueue_map_override!(flowcalc_ipc, modified_map)
            @atomic :monotonic flowcalc_ipc.shared_state.target_spacemap_time = current_time
            @info "Manoeuvre planned" target = ep.display_name dv = total_dv
        end
    end

    CImGui.Spacing()
    if CImGui.Button("Deselect", ImVec2(-1, 0))
        clear_spacemap_selection!(inputstate)
    end

    return nothing
end

function render_spacemap_left_panel!(
        inputstate::InputState,
        flowcalc_ipc::FlowCalculatorIPC,
        gamemap::GameMap,
        gamestate::GameState,
        left_width::Float32,
        panel_height::Float32,
    )
    player_pos = get_position(gamemap)
    player_vel = get_velocity(gamemap)
    current_time = get_time_years(gamemap)::Float64
    encounter_points = get_encounter_points(gamemap)
    has_manoeuvre = has_active_manoeuvre(gamemap)
    time_progressing = is_time_progressing(gamemap)

    CImGui.BeginChild("spacemap_left_panel", ImVec2(left_width, panel_height), true)

    #= ---------- Header ----------- =#
    CImGui.TextColored(ImVec4(0.7, 0.9, 1.0, 1.0), "SPACE MAP")
    CImGui.SameLine(left_width - 80.0)
    if CImGui.Button("Close [M]")
        inputstate.spacemap_active = false
    end

    #= ---------- Time section ----------- =#
    CImGui.SeparatorText("TIME")

    CImGui.Text("Current Time:")
    CImGui.PushFont(C_NULL, 24.0)
    time_colour = time_progressing ? ImVec4(1.0, 0.65, 0.1, 1.0) : ImVec4(0.7, 0.9, 1.0, 1.0)
    CImGui.TextColored(time_colour, @sprintf("%.3f years", current_time))
    CImGui.PopFont()
    CImGui.Spacing()

    timewarp_blocked = is_timewarp_blocked(gamemap, gamestate)

    # Advance time buttons — always shown, disabled while warping or blocked
    advance_disabled = time_progressing || first(timewarp_blocked)
    CImGui.Text("Advance Time:")
    if CImGui.BeginTable("##advance_time", 3, CImGui.ImGuiTableFlags_SizingStretchSame)
        for (label, dt) in (("0.1 yr", 0.1), ("1 yr", 1.0), ("10 yr", 10.0))
            CImGui.TableNextColumn()
            if button_with_disable(label, ImVec2(-1, 0), advance_disabled)
                @atomic :monotonic flowcalc_ipc.shared_state.target_spacemap_time = current_time + dt
            end
        end
        CImGui.EndTable()
    end

    # "Stop Time Warp" — always visible, disabled unless a warp is active
    if button_with_disable("Stop Time Warp", ImVec2(-1, 0), !time_progressing)
        @atomic :monotonic flowcalc_ipc.shared_state.target_spacemap_time = current_time
    end

    #= ---------- Position & velocity section ----------- =#
    CImGui.SeparatorText("POSITION & VELOCITY")

    CImGui.Text(@sprintf("Position: (%.0f, %.0f)", player_pos[1], player_pos[2]))
    CImGui.Text(@sprintf("Velocity: %.1f", norm(player_vel)))
    CImGui.Text(@sprintf("Ship delta-V: %.1f", estimate_min_delta_v(gamemap)))
    CImGui.Spacing()

    selected_idx = validate_spacemap_selection!(inputstate, encounter_points)

    #= ---------- Target information section ----------- =#
    CImGui.SeparatorText("TARGET INFORMATION")
    render_spacemap_target_info!(gamemap, selected_idx)

    #= ---------- Manoeuvre planning section ----------- =#
    if has_manoeuvre || selected_idx > 0
        CImGui.SeparatorText("MANOEUVRE PLANNING")
        if has_manoeuvre
            render_spacemap_active_manoeuvre_panel!(flowcalc_ipc, gamemap, gamestate)
        else
            render_spacemap_manoeuvre_planning_panel!(inputstate, flowcalc_ipc, gamemap, selected_idx)
        end
    end

    CImGui.EndChild()
    return nothing
end

function render_spacemap_trajectory_previews!(
        inputstate::InputState,
        gamemap::GameMap,
        total_dv::Float64,
    )
    player_pos = get_position(gamemap)
    player_vel = get_velocity(gamemap)
    current_time = get_time_years(gamemap)::Float64
    encounter_points = get_encounter_points(gamemap)
    has_manoeuvre = has_active_manoeuvre(gamemap)
    n_enc = length(encounter_points)

    # Resolve the manoeuvre to draw: committed or preview
    manoeuvre = nothing
    if has_manoeuvre
        manoeuvre = get_active_manoeuvre(gamemap)
    else
        selected_idx = validate_spacemap_selection!(inputstate, encounter_points)
        if selected_idx >= 1 && selected_idx <= n_enc
            ep = encounter_points[selected_idx]
            manoeuvre = plan_intercept_manoeuvre(
                player_pos, player_vel, ep, current_time, total_dv
            )
        end
    end

    isnothing(manoeuvre) && return nothing

    ep_idx = manoeuvre.target_encounter_index
    (ep_idx < 1 || ep_idx > n_enc) && return nothing
    ep = encounter_points[ep_idx]

    predicted_intercept_position = predict_player_position_with_manoeuvre(
        player_pos,
        player_vel,
        current_time,
        manoeuvre.intercept_time,
        manoeuvre,
    )
    target_pos = get_encounter_position(ep, current_time)

    # Line style: committed manoeuvres are thicker and more opaque
    if has_manoeuvre
        player_path_colour = ImVec4(1.0, 0.7, 0.2, 0.8)
        target_colour = ImVec4(1.0, 0.45, 0.35, 0.8)
        line_width = 2.0
    else
        player_path_colour = ImVec4(1.0, 0.7, 0.2, 0.4)
        target_colour = ImVec4(1.0, 0.45, 0.35, 0.4)
        line_width = 1.0
    end

    # Remaining player trajectory from the current state to the predicted intercept point.
    ImPlot.SetNextLineStyle(player_path_colour, line_width)
    ImPlot.PlotLine(
        "##leg_player_path",
        Float64[player_pos[1], predicted_intercept_position[1]],
        Float64[player_pos[2], predicted_intercept_position[2]]
    )

    # Target trajectory from its current position to the same intercept point.
    ImPlot.SetNextLineStyle(target_colour, line_width)
    ImPlot.PlotLine(
        "##leg_target",
        Float64[target_pos[1], predicted_intercept_position[1]],
        Float64[target_pos[2], predicted_intercept_position[2]]
    )

    # Mark the shared intercept point.
    burn_marker_colour = has_manoeuvre ? ImVec4(1.0, 0.9, 0.3, 0.9) : ImVec4(1.0, 0.9, 0.3, 0.5)
    ImPlot.SetNextMarkerStyle(ImPlot.ImPlotMarker_Asterisk, 7.0, burn_marker_colour)
    ImPlot.PlotScatter(
        "##intercept_marker",
        Float64[predicted_intercept_position[1]],
        Float64[predicted_intercept_position[2]]
    )

    return nothing
end

function render_spacemap_plot_area!(
        inputstate::InputState,
        gamemap::GameMap,
        right_width::Float32,
        panel_height::Float32,
    )
    sm = gamemap.space_map::SpaceMapState
    player_pos = get_position(gamemap)
    player_vel = get_velocity(gamemap)
    current_time = get_time_years(gamemap)::Float64
    encounter_points = get_encounter_points(gamemap)

    CImGui.BeginChild("spacemap_plot_area", ImVec2(right_width, panel_height))

    plot_flags = ImPlot.ImPlotFlags_Equal | ImPlot.ImPlotFlags_NoLegend |
        ImPlot.ImPlotFlags_NoTitle | ImPlot.ImPlotFlags_NoMouseText
    axis_flags = ImPlot.ImPlotAxisFlags_NoMenus

    half_w = sm.viewport_half_width
    half_h = sm.viewport_half_height
    ImPlot.SetNextAxesLimits(
        player_pos[1] - half_w, player_pos[1] + half_w,
        player_pos[2] - half_h, player_pos[2] + half_h,
        CImGui.ImGuiCond_Always
    )

    ImPlot.PushStyleColor(ImPlot.ImPlotCol_PlotBg, ImVec4(0.03, 0.03, 0.08, 1.0))

    if ImPlot.BeginPlot("##spacemap_plot", ImVec2(-1, -1), plot_flags)
        ImPlot.SetupAxes("X", "Y", axis_flags, axis_flags)

        # Player marker: yellow diamond
        ImPlot.SetNextMarkerStyle(ImPlot.ImPlotMarker_Diamond, 8.0, ImVec4(0.8, 0.8, 0.0, 1.0))
        ImPlot.PlotScatter("##player", Float64[player_pos[1]], Float64[player_pos[2]])

        n_enc = length(encounter_points)
        selected_idx = validate_spacemap_selection!(inputstate, encounter_points)
        if n_enc > 0
            enc_cfg = sm.encounter_config
            total_viewport_width = sm.viewport_half_width * 2.0
            min_arrow_len = total_viewport_width * 0.012
            max_arrow_len = total_viewport_width * 0.12
            enc_xs = Vector{Float64}(undef, n_enc)
            enc_ys = Vector{Float64}(undef, n_enc)

            # Render velocity vector arrows
            for i in 1:n_enc
                ep = encounter_points[i]
                epos = get_encounter_position(ep, current_time)
                enc_xs[i] = epos[1]
                enc_ys[i] = epos[2]

                rel_vel = ep.velocity - player_vel
                rel_speed = norm(rel_vel)
                arrow_len = encounter_arrow_length(
                    rel_speed,
                    enc_cfg.min_base_velocity,
                    enc_cfg.max_base_velocity,
                    min_arrow_len,
                    max_arrow_len,
                )
                vel_unit = normalise_or_default(rel_vel)
                vel_tip = SVector(enc_xs[i], enc_ys[i]) + vel_unit * arrow_len
                line_colour = i == selected_idx ? ImVec4(1.0, 0.45, 0.35, 0.85) : ImVec4(1.0, 0.4, 0.3, 0.25)
                line_width = i == selected_idx ? 2.0 : 1.0

                ImPlot.SetNextLineStyle(line_colour, line_width)
                ImPlot.PlotLine(
                    @sprintf("##enc_vel_%d", i),
                    Float64[enc_xs[i], vel_tip[1]],
                    Float64[enc_ys[i], vel_tip[2]]
                )

                # Arrow tip: small solid circle at the velocity vector endpoint
                ImPlot.SetNextMarkerStyle(ImPlot.ImPlotMarker_Circle, 3.0, line_colour, 0.0, line_colour)
                ImPlot.PlotScatter(
                    @sprintf("##enc_tip_%d", i),
                    Float64[vel_tip[1]],
                    Float64[vel_tip[2]]
                )
            end

            # Bucket encounters by (class, fuel_tag) for coloured markers.
            # Shape distinguishes class; colour distinguishes fuel type.
            marker_buckets = Dict{Tuple{EncounterClass, HexFluids.FluidTags}, Tuple{Vector{Float64}, Vector{Float64}}}()
            for i in 1:n_enc
                ep = encounter_points[i]
                key = (ep.encounter_class, ep.fuel_tag)
                xs, ys = get!(marker_buckets, key) do
                    (Float64[], Float64[])
                end
                push!(xs, enc_xs[i])
                push!(ys, enc_ys[i])
            end

            for ((class, tag), (xs, ys)) in marker_buckets
                isempty(xs) && continue
                marker, size = if class == ENCOUNTER_SHIP
                    (ImPlot.ImPlotMarker_Circle, 6.0)
                elseif class == ENCOUNTER_FUEL_CACHE
                    (ImPlot.ImPlotMarker_Square, 8.0)
                else
                    (ImPlot.ImPlotMarker_Cross, 7.0)
                end
                colour = fluid_tag_to_imvec4(tag)
                ImPlot.SetNextMarkerStyle(marker, size, colour)
                fuel_label = fluid_tag_label(tag)
                label = isnothing(fuel_label) ? encounter_class_label(class) : "$(encounter_class_label(class)) ($fuel_label)"
                ImPlot.PlotScatter(label, xs, ys, length(xs))
            end

            # Render selected encounter highlight
            if selected_idx >= 1 && selected_idx <= n_enc
                ImPlot.SetNextMarkerStyle(
                    ImPlot.ImPlotMarker_Diamond, 9.0,
                    ImVec4(1.0, 0.9, 0.3, 1.0)
                )
                ImPlot.PlotScatter(
                    "##selected",
                    Float64[enc_xs[selected_idx]], Float64[enc_ys[selected_idx]]
                )
            end

            # Click Detection
            if ImPlot.IsPlotHovered() && CImGui.IsMouseClicked(0)
                mouse = ImPlot.GetPlotMousePos()
                best_idx = 0
                best_dist_sq = SPACEMAP_CLICK_RADIUS_SQ
                for i in 1:n_enc
                    dx = enc_xs[i] - mouse.x
                    dy = enc_ys[i] - mouse.y
                    dist_sq = dx * dx + dy * dy
                    if dist_sq < best_dist_sq
                        best_dist_sq = dist_sq
                        best_idx = i
                    end
                end
                if best_idx > 0
                    inputstate.gui_inputs[:spacemap_selected_idx] = best_idx
                    inputstate.gui_inputs[:spacemap_selected_iteration] = encounter_points[best_idx].iteration
                else
                    clear_spacemap_selection!(inputstate)
                end
            end
        end

        # Render Trajectory
        total_dv = Float64(get(inputstate.gui_inputs, :spacemap_delta_v, Cfloat(50.0))::Cfloat)
        render_spacemap_trajectory_previews!(inputstate, gamemap, total_dv)

        ImPlot.EndPlot()
    end

    ImPlot.PopStyleColor(1)
    CImGui.EndChild()
    return nothing
end

"""
Render the full-screen space map overlay.
Uses ImPlot to show encounters in 2D space. Left panel has time controls,
target information, and manoeuvre planning. Right area has the scatter plot.
Must be called within ui_renderwrap.
"""
function ui_spacemap_render!(
        inputstate::InputState,
        flowcalc_ipc::FlowCalculatorIPC,
        snapshot::FlowCalculatorSnapshot,
        winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}},
        max_view_bounds::Union{HexFrame.CartesianBounds, Nothing}
    )
    if !inputstate.spacemap_active
        return nothing
    end

    gamemap = snapshot.gamemap
    win_float = to_float(winsize)

    CImGui.SetNextWindowPos(ImVec2(0.0, 0.0))
    CImGui.SetNextWindowSize(ImVec2(win_float.width, win_float.height))
    flags = CImGui.ImGuiWindowFlags_NoTitleBar | CImGui.ImGuiWindowFlags_NoResize |
        CImGui.ImGuiWindowFlags_NoMove | CImGui.ImGuiWindowFlags_NoScrollbar |
        CImGui.ImGuiWindowFlags_NoBringToFrontOnFocus
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_WindowBorderSize, 0.0)
    CImGui.PushStyleColor(CImGui.ImGuiCol_WindowBg, ImVec4(0.05, 0.05, 0.1, 0.97))

    CImGui.Begin("##spacemap_overlay", C_NULL, flags)

    if isnothing(get_space_map_seed(gamemap))
        render_spacemap_no_map_message!(win_float)
        CImGui.End()
        CImGui.PopStyleColor()
        CImGui.PopStyleVar()
        return nothing
    end

    inputstate.gui_inputs[:time_progressing] = is_time_progressing(gamemap)

    avail = CImGui.GetContentRegionAvail()
    left_width = Float32(SPACEMAP_LEFT_PANEL_WIDTH)
    right_width = avail.x - left_width - 12.0f0

    render_spacemap_left_panel!(inputstate, flowcalc_ipc, gamemap, snapshot.gamestate, left_width, avail.y)

    CImGui.SameLine()

    render_spacemap_plot_area!(inputstate, gamemap, right_width, avail.y)

    CImGui.End()
    CImGui.PopStyleColor()
    CImGui.PopStyleVar()

    return nothing
end
