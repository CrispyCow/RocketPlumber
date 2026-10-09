#=
Scope: In-game CImGui windows for inspection, editing, flight status, and space-map planning
Formatter: Runic
=#

# ===============================================================
# UI Game Windows (Inspector, Timer, Notifications, Properties)
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
using HexFlowTelemetry

const PIPE_TYPES = (
    ("Scrap Pipe", ScrapPipeBehav),
    ("Big Pipe", BigPipeBehav),
)

"Property-panel description for the current placement state."
function placement_state_description(state::AbstractPlacementState)::Union{Nothing, String}
    state isa PlacementReadyState && return nothing
    state isa PlacementPressedState && return "Move pending."
    state isa PlacementMoveState && return "Move active. Drag to place."
    state isa PlacementMovePendingState && return "Applying move."
    state isa PlacementPipeChainState && return "Pipe chain active. Left-click to place or delete."
    state isa PlacementTileState && return "Tile placement active."
    state isa PlacementDeleteState && return "Delete active. Left-click deletes."
    state isa PlacementSurfaceEditState && return "Surface edit active. Left-click toggles surface."
    state isa PlacementRedockState && return "Redock active. Left-click to place ship."

    return nothing
end

"""
Generic tunable editor for the property box.
Handles both scalar `TunableProps` (InputFloat) and `EnumTunableProps` (Combo) entries.
Returns a heterogeneous tuple: scalars as `Cfloat`, enum values as their concrete type.
"""
function edit_tunables!(tunables_tuple)
    N = length(tunables_tuple)
    # Float buffer for all positions — only scalar positions are actually used for pointer writes
    float_buf = fill(Cfloat(0.0), N)
    result = Vector{Any}(undef, N)

    for (index, props) in enumerate(tunables_tuple)
        CImGui.PushID(index)

        if props isa TunableProps
            float_buf[index] = Cfloat(props.current_val)
            CImGui.Text("$(props.type_desc) [$index]")
            CImGui.SetNextItemWidth(100.0)
            @c CImGui.InputFloat(props.unit_desc, pointer(float_buf, index), 0.0, 100.0, "%.3f")
            result[index] = float_buf[index]

        elseif props isa EnumTunableProps
            current_idx = Cint(something(findfirst(==(props.current_val), props.options), 1) - 1)
            CImGui.Text("$(props.type_desc):")
            CImGui.SetNextItemWidth(200.0)
            @cref CImGui.ListBox("##enum_$index", &current_idx, props.option_labels)
            clamped_idx = clamp(Int(current_idx), 0, length(props.options) - 1)
            result[index] = props.options[clamped_idx + 1]

        else
            result[index] = props  # fallback: pass through unchanged
        end

        CImGui.Separator()
        CImGui.PopID()
    end

    return Tuple(result)
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

"Display component tunables in read-only format. Handles both scalar and enum tunable descriptors."
function display_component_values!(tunables_tuple)
    if isempty(tunables_tuple)
        CImGui.Text("No configurable values")
        return nothing
    end

    for (index, props) in enumerate(tunables_tuple)
        CImGui.PushID(index)

        if props isa TunableProps
            CImGui.Text("$(props.type_desc) [$index]")
            CImGui.Text("$(format_value(props.current_val)) $(props.unit_desc)")
        elseif props isa EnumTunableProps
            idx = findfirst(==(props.current_val), props.options)
            val_label = !isnothing(idx) ? props.option_labels[idx] : string(props.current_val)
            CImGui.Text("$(props.type_desc): $(val_label)")
        end
        CImGui.Separator()

        CImGui.PopID()
    end

    return nothing
end

"Display circuit element details in the property inspector."
function display_element_details!(elements::Vector{AbsoluteElement}, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot)
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
inspect_ui!(::Nothing, ::GameMap, ::DerivedMapState, ::MNA_StateSnapshot) = CImGui.Text("Nothing.")

"Inspect a tile coordinate, displaying component values and element details."
function inspect_ui!(tile::TileCoord, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot)
    CImGui.Text("Hex Tile at $(coord_description(tile))")
    for (slot, dir) in ((1, HexFrame.NODE_INTERNAL_1), (2, HexFrame.NODE_INTERNAL_2), (3, HexFrame.NODE_INTERNAL_3))
        internalnode = NodeCoord(tile, dir)
        if haskey(mna_state.node_voltages, internalnode)
            CImGui.Text("Internal Node $slot Voltage: $(format_value(mna_state.node_voltages[internalnode])) V")
        end
    end

    comp = get_component(gamemap, tile)
    if !isnothing(comp)
        tilecomp = comp
        component_temperature = get_component_temperature(tilecomp)
        temperature_str = isnothing(component_temperature) ? "None" : "$(format_value(component_temperature)) K"
        CImGui.Text("Temperature: $(temperature_str)")
        CImGui.Text("Type: $(String(nameof(typeof(tilecomp.component))))")
        CImGui.Text("Ship: $(tilecomp.ship)")

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
function inspect_ui!(vert::VertexCoord, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot)
    CImGui.Text(coord_description(vert))
    node = to_nodecoord(vert)

    # Exit early if node has no voltage defined
    if !haskey(mna_state.node_voltages, node)
        return nothing
    end

    CImGui.Text("Node Voltage: $(format_value(mna_state.node_voltages[node])) V\n")

    fluidtag = get(derivedmapstate.nodeactualfluids, node, nothing)
    fluidstr = !isnothing(fluidtag) ? fluid_type_label(fluidtag) : "None"
    CImGui.Text("Fluid Type: $(fluidstr)")

    region_id = get(derivedmapstate.node_to_region, node, nothing)
    region_str = !isnothing(region_id) ? string(region_id) : "None"
    CImGui.Text("Fluid Region: $(region_str)")

    region_temp = !isnothing(region_id) ? get(derivedmapstate.region_temperatures, region_id, nothing) : nothing
    region_temp_str = !isnothing(region_temp) ? "$(format_value(region_temp)) K" : "None"
    CImGui.Text("Region Temperature: $(region_temp_str)")

    # Display fluid declarations affecting this node
    if haskey(derivedmapstate.node_declarations, node)
        decl = derivedmapstate.node_declarations[node]
        if decl isa HexFluids.FluidSource
            CImGui.Text("Declaration: Source ($(fluid_type_label(decl.fluid_type)), T=$(format_value(decl.temperature)) K)")
        elseif decl isa HexFluids.FluidTypeRule
            CImGui.Text("Declaration: TypeRule ($(fluid_type_label(decl.fluid_type)))")
        elseif decl isa HexFluids.FluidConstraintRule
            CImGui.Text("Declaration: Constraint ($(fluid_constraint_label(decl.constraint)))")
        end
    end

    # Display temperature if available
    temp = get(derivedmapstate.node_temperatures, node, nothing)
    temp_str = !isnothing(temp) ? "$(format_value(temp)) K" : "None"
    CImGui.Text("Node Temperature: $(temp_str)")

    return nothing
end

"Inspect a pipe coordinate, displaying pipe information."
function inspect_ui!(pipe_coord::PipeCoord, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot)
    CImGui.Text("Pipe Between:")
    CImGui.Text("$(coord_description(pipe_coord.v1)) and $(coord_description(pipe_coord.v2))")

    # Check for pipe behaviours
    pipe = get_pipe(gamemap, pipe_coord)
    if !isnothing(pipe)
        pipe_behav = pipe
        CImGui.Text("Type: $(nameof(typeof(pipe_behav.pipe)))")
        CImGui.Text("Ship: $(pipe_behav.ship)")

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
        elements = produce_abs_elements(pipe_behav, pipe_coord)
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

"Update the selected encounter identity, invalidating its preview when it changes."
function set_spacemap_selection!(inputstate::InputState, selected_idx::Int, selected_iteration::Int)
    current_idx = get(inputstate.gui_inputs, :spacemap_selected_idx, 0)::Int
    current_iteration = get(inputstate.gui_inputs, :spacemap_selected_iteration, 0)::Int
    if selected_idx != current_idx || selected_iteration != current_iteration
        pop!(inputstate.gui_inputs, :spacemap_delta_v, nothing)
    end

    inputstate.gui_inputs[:spacemap_selected_idx] = selected_idx
    inputstate.gui_inputs[:spacemap_selected_iteration] = selected_iteration
    return nothing
end

"Clear the current space-map selection and its cached preview state."
clear_spacemap_selection!(inputstate::InputState) = set_spacemap_selection!(inputstate, 0, 0)

"Return the validated selected encounter index, adopting any active manoeuvre target."
function validate_spacemap_selection!(inputstate::InputState, gamemap::GameMap)::Int
    encounter_points = get_encounter_points(gamemap)
    manoeuvre = get_active_manoeuvre(gamemap)
    if !isnothing(manoeuvre)
        target_idx = manoeuvre.target_encounter_index
        if target_idx < 1 || target_idx > length(encounter_points)
            clear_spacemap_selection!(inputstate)
            return 0
        end

        set_spacemap_selection!(inputstate, target_idx, encounter_points[target_idx].iteration)
        return target_idx
    end

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

"Clear uncommitted selections outside the plot's current visible limits."
function validate_spacemap_selection!(inputstate::InputState, gamemap::GameMap, viewport::ImPlot.ImPlotRect)::Int
    encounter_points = get_encounter_points(gamemap)
    selected_idx = validate_spacemap_selection!(inputstate, gamemap)
    (selected_idx == 0 || has_active_manoeuvre(gamemap)) && return selected_idx

    position = get_encounter_position(encounter_points[selected_idx], get_time_years(gamemap)::Float64)
    if !(viewport.X.Min <= position[1] <= viewport.X.Max && viewport.Y.Min <= position[2] <= viewport.Y.Max)
        clear_spacemap_selection!(inputstate)
        return 0
    end

    return selected_idx
end

"Apply an encounter or blank-space click, keeping active manoeuvre targets selected."
function select_spacemap_encounter!(inputstate::InputState, gamemap::GameMap, selected_idx::Int)
    if has_active_manoeuvre(gamemap)
        validate_spacemap_selection!(inputstate, gamemap)
        return nothing
    end

    if selected_idx > 0
        set_spacemap_selection!(inputstate, selected_idx, get_encounter_points(gamemap)[selected_idx].iteration)
    else
        clear_spacemap_selection!(inputstate)
    end

    return nothing
end

"Return the active manoeuvre or calculate a preview for the validated current encounter."
function resolve_spacemap_manoeuvre!(inputstate::InputState, gamemap::GameMap, selected_idx::Int)
    selected_idx == 0 && return nothing
    manoeuvre = get_active_manoeuvre(gamemap)
    !isnothing(manoeuvre) && return manoeuvre

    ep = get_encounter_points(gamemap)[selected_idx]
    player_vel = get_velocity(gamemap)
    min_dv = calculate_minimum_intercept_dv(player_vel, ep.velocity)
    delta_v_slider = get!(inputstate.gui_inputs, :spacemap_delta_v, Cfloat(min_dv))::Cfloat
    total_dv = max(Float64(delta_v_slider), min_dv)  # The Float32 slider may round below the minimum

    return plan_intercept_manoeuvre(get_position(gamemap), player_vel, ep, get_time_years(gamemap)::Float64, total_dv)
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
const SPACEMAP_ESCAPE_PANEL_HEIGHT = 82.0
const SPACEMAP_CLICK_RADIUS_SQ = 400.0   # Squared distance in plot units for click detection

const GALAXY_ESCAPE_BUTTON_COLOUR = ImVec4(0.95, 0.72, 0.14, 1.0)
const GALAXY_ESCAPE_BUTTON_HOVERED_COLOUR = ImVec4(1.0, 0.82, 0.22, 1.0)
const GALAXY_ESCAPE_BUTTON_ACTIVE_COLOUR = ImVec4(0.85, 0.6, 0.08, 1.0)
const GALAXY_ESCAPE_BUTTON_TEXT_COLOUR = ImVec4(0.12, 0.1, 0.04, 1.0)
const GALAXY_ESCAPE_WARNING_BUTTON_COLOUR = ImVec4(0.65, 0.16, 0.12, 1.0)
const GALAXY_ESCAPE_WARNING_BUTTON_HOVERED_COLOUR = ImVec4(0.78, 0.22, 0.16, 1.0)

"Convert a `FluidType` or `nothing` to an `ImVec4` colour for UI display."
function fluid_tag_to_imvec4(fluid::Union{HexFluids.FluidType, Nothing})::ImVec4
    if isnothing(fluid)
        return ImVec4(0.6, 0.6, 0.6, 0.7)
    end
    c = HexFlowRendering.get_fluid_colour(fluid)
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
const DV_COLOUR = ImVec4(1.0, 0.7, 0.2, 1.0)       # amber

"Render the shared simulation speed and pause controls."
function render_simulation_controls!(inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC)
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

    pause_label = is_paused ? "Un-Pause" : "Pause"
    if CImGui.Button(pause_label, ImVec2(CImGui.GetContentRegionAvail().x, 0.0))
        @atomic :monotonic flowcalc_ipc.shared_state.is_paused = !is_paused
    end

    return nothing
end

"Draw and reserve a rocket pointing along non-zero ship-local remaining delta-V."
function _render_required_thrust_rocket!(remaining_dv::SVector{2, Float64})
    magnitude = norm(remaining_dv)
    magnitude <= 1.0e-10 && return nothing  # No required direction when the burn is complete

    cursor = CImGui.GetCursorScreenPos()
    width = CImGui.GetContentRegionAvail().x
    height = 112.0f0
    centre = ImVec2(cursor.x + width * 0.5f0, cursor.y + height * 0.5f0)
    drawlist = CImGui.GetWindowDrawList()

    # Nozzle burn coordinates use +Y down relative to the rendered ship
    forward = SVector(Float32(remaining_dv[1] / magnitude), Float32(remaining_dv[2] / magnitude))
    side = SVector(-forward[2], forward[1])
    point(along, across) = ImVec2(
        centre.x + along * forward[1] + across * side[1],
        centre.y + along * forward[2] + across * side[2],
    )

    # Fixed instrument dial and eight reference notches
    CImGui.AddCircleFilled(drawlist, centre, 44.0f0, CImGui.GetColorU32(ImVec4(0.07, 0.09, 0.11, 1.0)), 64)
    CImGui.AddCircle(drawlist, centre, 44.0f0, CImGui.GetColorU32(ImVec4(0.36, 0.41, 0.46, 1.0)), 64, 1.5f0)
    tick_colour = CImGui.GetColorU32(ImVec4(0.27, 0.31, 0.35, 1.0))
    for index in 0:7
        angle = Float32(index * pi / 4)
        inner_radius = iseven(index) ? 37.0f0 : 39.0f0
        inner = ImVec2(centre.x + inner_radius * cos(angle), centre.y + inner_radius * sin(angle))
        outer = ImVec2(centre.x + 42.0f0 * cos(angle), centre.y + 42.0f0 * sin(angle))
        CImGui.AddLine(drawlist, inner, outer, tick_colour, 1.0f0)
    end

    # Burn-axis signs sit clear of the ring; pixel-aligned bars keep the arms symmetric
    sign_colour = CImGui.GetColorU32(ImVec4(0.65, 0.69, 0.73, 1.0))
    for (x, y, positive) in ((1, 0, true), (0, 1, true), (-1, 0, false), (0, -1, false))
        sign_centre = ImVec2(floor(centre.x + 52.0f0 * x) + 0.5f0, floor(centre.y + 52.0f0 * y) + 0.5f0)
        CImGui.AddRectFilled(drawlist, ImVec2(sign_centre.x - 3.5f0, sign_centre.y - 0.5f0), ImVec2(sign_centre.x + 3.5f0, sign_centre.y + 0.5f0), sign_colour)
        if positive
            CImGui.AddRectFilled(drawlist, ImVec2(sign_centre.x - 0.5f0, sign_centre.y - 3.5f0), ImVec2(sign_centre.x + 0.5f0, sign_centre.y + 3.5f0), sign_colour)
        end
    end

    # Direction notch shares the rocket's transform for precise alignment
    direction_colour = CImGui.GetColorU32(ImVec4(1.0, 0.2, 0.2, 1.0))
    CImGui.AddLine(drawlist, point(37, 0), point(42, 0), direction_colour, 1.5f0)

    # Finless hull, tapered nose and engine bell; nose and rear sit equally far from the pivot
    for (colour, vertices) in (
            (ImVec4(0.48, 0.54, 0.6, 1.0), ((-17, -5), (-17, 5), (-29, 8), (-29, -8))),
            (ImVec4(0.82, 0.87, 0.92, 1.0), ((13, -9), (13, 9), (-17, 9), (-17, -9))),
            (DV_COLOUR, ((29, 0), (13, 9), (13, -9))),
            (ImVec4(0.12, 0.16, 0.2, 1.0), ((-25, -5), (-25, 5), (-28, 5), (-28, -5))),
        )
        CImGui.PathClear(drawlist)
        for (along, across) in vertices
            CImGui.PathLineTo(drawlist, point(along, across))
        end
        CImGui.PathFillConvex(drawlist, CImGui.GetColorU32(colour))
    end

    # Engine mounting collar and a recessed longitudinal hull seam
    detail_colour = CImGui.GetColorU32(ImVec4(0.3, 0.36, 0.42, 1.0))
    CImGui.AddLine(drawlist, point(-12, -9), point(-12, 9), detail_colour, 2.0f0)
    CImGui.AddLine(drawlist, point(-7, 0), point(10, 0), detail_colour, 1.5f0)

    CImGui.Dummy(ImVec2(width, height))
    return nothing
end

"Render ship information and required thrust during manoeuvre burns, or galaxy-escape status."
function ui_velocity_tracker_render!(
        gamestate::GameState, gamemap::GameMap,
        inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC,
    )
    velocity = get_velocity(gamemap)
    vel_mag = norm(velocity)
    accel_mag = norm(gamestate.acceleration_space_map_frame)

    escape_active = is_galaxy_escape_active(gamemap)
    has_manoeuvre = has_active_manoeuvre(gamemap)
    manoeuvre = get_active_manoeuvre(gamemap)

    # Fixed width, with height fitted to the current flight status
    CImGui.SetNextWindowSizeConstraints(ImVec2(VELOCITY_TRACKER_WIDTH, 0.0), ImVec2(VELOCITY_TRACKER_WIDTH, Inf))
    ui_window(
        "Velocity Tracker", (0.0, 0.0), (VELOCITY_TRACKER_WIDTH, 0.0);
        flags = DEFAULT_WINDOW_FLAGS | CImGui.ImGuiWindowFlags_AlwaysAutoResize,
    )

    render_simulation_controls!(inputstate, flowcalc_ipc)

    CImGui.SeparatorText("Ship Info")

    CImGui.Text(@sprintf("Velocity:     %.2f", vel_mag))
    CImGui.Text(@sprintf("Acceleration: %.4f", accel_mag))
    CImGui.Text(@sprintf("Mass:         %.1f", get_mass(gamemap)))
    CImGui.Text(@sprintf("Ship delta-V: %.1f", gamestate.estimated_min_delta_v))

    if escape_active
        progress = get_galaxy_escape_progress(gamemap)::Float64
        tier_number = Int(galaxy_escape_tier(progress))

        CImGui.SeparatorText("Escape Progress")
        CImGui.Text(@sprintf("Achieved delta-V: %.1f", progress))
        if tier_number == 0
            CImGui.TextColored(DV_COLOUR, "Escape not achieved")
        elseif tier_number == 1
            CImGui.TextColored(DV_COLOUR, "Minimum escape achieved - 1 Star")
        elseif tier_number < length(GALAXY_ESCAPE_TIER_DELTA_V)
            CImGui.TextColored(DV_COLOUR, "$tier_number-Star escape achieved")
        else
            CImGui.TextColored(DV_COLOUR, "$tier_number-Star escape achieved (maximum rating)")
        end

        if tier_number < length(GALAXY_ESCAPE_TIER_DELTA_V)
            next_rating = tier_number + 1
            next_rating_label = next_rating == 1 ? "1 Star" : "$next_rating Stars"
            next_threshold = GALAXY_ESCAPE_TIER_DELTA_V[next_rating]
            CImGui.Text(@sprintf("Next Target: %s at %.0f delta-V", next_rating_label, next_threshold))
        else
            CImGui.Text("Next Target: None")
        end

        CImGui.Spacing()
        eligible = can_complete_galaxy_escape(progress)
        if eligible
            CImGui.PushStyleColor(CImGui.ImGuiCol_Text, GALAXY_ESCAPE_BUTTON_TEXT_COLOUR)
            CImGui.PushStyleColor(CImGui.ImGuiCol_Button, GALAXY_ESCAPE_BUTTON_COLOUR)
            CImGui.PushStyleColor(CImGui.ImGuiCol_ButtonHovered, GALAXY_ESCAPE_BUTTON_HOVERED_COLOUR)
        end
        complete_clicked = button_with_disable(
            "Complete Escape", ImVec2(-1.0, 35.0), !eligible;
            tooltip = "Achieve a 1-Star escape before completing the attempt.",
        )
        eligible && CImGui.PopStyleColor(3)
        if complete_clicked
            inputstate.galaxy_escape_completion_requested = true
        end
    elseif has_manoeuvre
        # Manoeuvre status is read-only; all phase transitions happen in the calculator.
        CImGui.SeparatorText("Manoeuvre Info")
        phase = manoeuvre.phase

        if phase == PHASE_APPROACH_BURN || phase == PHASE_CAPTURE_BURN
            rem_dv = manoeuvre.burn_remaining_dv
            table_flags = CImGui.ImGuiTableFlags_SizingStretchSame | CImGui.ImGuiTableFlags_BordersInnerV
            if CImGui.BeginTable("##manoeuvre_burn", 2, table_flags)
                CImGui.TableNextColumn()
                CImGui.TextWrapped(phase_description(phase))
                CImGui.NewLine()
                CImGui.Text("Remaining delta-V:")
                dv_text = @sprintf("(%.2f, %.2f)", rem_dv[1], rem_dv[2])
                column_width = CImGui.GetContentRegionAvail().x
                normal_font_size = CImGui.GetFontSize()
                dv_font_size = 24.0
                dv_font_size > normal_font_size && CImGui.PushFont(UI_VECTOR_FONT, dv_font_size)
                # Keep the value prominent while fitting signed values in the column
                while dv_font_size > normal_font_size && CImGui.CalcTextSize(dv_text).x > column_width
                    CImGui.PopFont()
                    dv_font_size = max(normal_font_size, dv_font_size - 1.0)
                    dv_font_size > normal_font_size && CImGui.PushFont(UI_VECTOR_FONT, dv_font_size)
                end
                CImGui.TextColored(DV_COLOUR, dv_text)
                dv_font_size > normal_font_size && CImGui.PopFont()

                CImGui.TableNextColumn()
                _render_required_thrust_rocket!(rem_dv)
                CImGui.EndTable()
            end

        else
            CImGui.TextWrapped(phase_description(phase))
            CImGui.NewLine()

            if phase == PHASE_COAST
                CImGui.TextWrapped("Open Space Map (M) and progress time until intercept.")
            elseif phase == PHASE_ENCOUNTER_READY
                CImGui.TextWrapped("Encounter triggering...")
            end
        end
    end

    CImGui.End()
    return nothing
end

#= ---------- Explorer Opening Wake ----------- =#

"Render the acknowledgement shown at the start of a new Explorer game."
function ui_explorer_opening_wake_render!(
        gamemap::GameMap,
        inputstate::InputState,
        winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}},
    )
    acknowledged = get(inputstate.gui_inputs, :explorer_opening_wake_acknowledged, false)::Bool
    (is_explorer_opening_capture(gamemap) && !acknowledged) || return nothing

    # Centred window
    width = 540.0
    win_float = to_float(winsize)
    CImGui.SetNextWindowPos(
        ImVec2(win_float.width / 2.0, win_float.height / 2.0),
        CImGui.ImGuiCond_Always,
        ImVec2(0.5, 0.5),
    )
    CImGui.SetNextWindowSizeConstraints(ImVec2(width, 0.0), ImVec2(width, win_float.height))
    flags = CImGui.ImGuiWindowFlags_NoTitleBar | CImGui.ImGuiWindowFlags_NoResize |
        CImGui.ImGuiWindowFlags_NoMove | CImGui.ImGuiWindowFlags_NoCollapse |
        CImGui.ImGuiWindowFlags_NoSavedSettings | CImGui.ImGuiWindowFlags_AlwaysAutoResize
    CImGui.Begin("##explorer_opening_wake", C_NULL, flags)

    # Wake message
    CImGui.PushFont(UI_VECTOR_FONT, 20.0)
    CImGui.PushStyleColor(CImGui.ImGuiCol_Text, ImVec4(1.0, 0.75, 0.25, 1.0))
    CImGui.Text("PROXIMITY ALERT")
    CImGui.PopStyleColor()
    CImGui.PopFont()
    CImGui.Spacing()
    CImGui.TextWrapped("Useful resources detected on nearby ship, intercept planned!")
    CImGui.Spacing()
    CImGui.TextWrapped("Complete the capture burn to match velocity and establish contact.")
    CImGui.Spacing()
    CImGui.TextWrapped("Use the LEARNING HELPER to find more guidance!")
    CImGui.Spacing()

    # Centred acknowledgement
    button_width = 140.0
    CImGui.SetCursorPosX(CImGui.GetCursorPosX() + (CImGui.GetContentRegionAvail().x - button_width) / 2.0)
    if CImGui.Button("Acknowledge", ImVec2(button_width, 36.0))
        inputstate.gui_inputs[:explorer_opening_wake_acknowledged] = true
    end

    CImGui.End()
    return nothing
end

const NOTIFICATION_DURATION = 10.0
const NOTIFICATION_FLASH_DURATION = 0.25

"Render the latest notification with a brief border highlight on each trigger within ui_renderwrap."
function ui_notifications_render!(
        winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}},
        threadsafe_console_see::Function
    )
    message = threadsafe_console_see()
    isnothing(message) && return nothing
    age = Float64(time_ns()) / 1.0e9 - message.timestamp
    age >= NOTIFICATION_DURATION && return nothing
    flashing = age < NOTIFICATION_FLASH_DURATION

    win_float = to_float(winsize)
    margin = 12.0
    width = min(480.0, max(1.0, win_float.width - 2 * margin))
    CImGui.SetNextWindowPos(ImVec2(margin, win_float.height - margin), CImGui.ImGuiCond_Always, ImVec2(0.0, 1.0))
    CImGui.SetNextWindowSize(ImVec2(width, 0.0), CImGui.ImGuiCond_Always)
    CImGui.SetNextWindowBgAlpha(0.95)
    flags = DEFAULT_WINDOW_FLAGS | CImGui.ImGuiWindowFlags_AlwaysAutoResize |
        CImGui.ImGuiWindowFlags_NoCollapse | CImGui.ImGuiWindowFlags_NoSavedSettings |
        CImGui.ImGuiWindowFlags_NoScrollbar | CImGui.ImGuiWindowFlags_NoScrollWithMouse |
        CImGui.ImGuiWindowFlags_NoInputs | CImGui.ImGuiWindowFlags_NoFocusOnAppearing
    CImGui.PushFont(unsafe_load(CImGui.GetIO().FontDefault), 13.0)
    flashing && CImGui.PushStyleColor(CImGui.ImGuiCol_Border, DV_COLOUR)
    CImGui.Begin("##notifications", C_NULL, flags)
    flashing && CImGui.PopStyleColor()

    CImGui.PushFont(UI_VECTOR_FONT, 20.0)
    CImGui.TextColored(DV_COLOUR, "System Message")
    CImGui.PopFont()
    CImGui.Spacing()
    CImGui.PushTextWrapPos(0.0)

    CImGui.TextUnformatted(message.text)

    CImGui.PopTextWrapPos()
    CImGui.End()
    CImGui.PopFont()
    return nothing
end

"""
Renders the property box on the right side of the window.
Must be called within ui_renderwrap.
"""
function ui_propertybox_render!(
        inputstate::InputState, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot,
        winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}}, flowcalc_ipc::FlowCalculatorIPC
    )
    state = placement_state(inputstate)
    win_float = to_float(winsize)

    ui_window("Properties", (win_float.width - propertyboxwidth, 0.0), (propertyboxwidth, win_float.height))

    # Display mode description
    CImGui.PushFont(UI_VECTOR_FONT, 18.0)
    CImGui.Text("PROPERTIES:")
    CImGui.PopFont()
    state_description = placement_state_description(state)
    if !isnothing(state_description)
        CImGui.Text(state_description)
    end
    CImGui.Separator()
    CImGui.NewLine()

    # Tile placement controls
    if state isa PlacementTileState
        CImGui.Text("Tile Tunable Values:")
        CImGui.Separator()
        CImGui.Indent()
        new_tunables = edit_tunables!(get_tunables(state.pendingcomponent))
        state.pendingcomponent = set_tunables(state.pendingcomponent, new_tunables)
        CImGui.Unindent()
    end

    # Pipe placement controls
    if state isa PlacementPipeChainState && editor_capabilities_enabled(inputstate)
        CImGui.Text("Select Pipe Type:")
        for (label, pipe_type) in PIPE_TYPES
            if CImGui.Button(label)
                state.pipe_behavior = pipe_type()
            end
            CImGui.SameLine()
        end
        CImGui.NewLine()
        CImGui.NewLine()

        # Selected pipe properties
        CImGui.Text("Pipe Properties:")
        CImGui.Separator()

        CImGui.Indent()
        new_tunables = edit_tunables!(get_pipe_tunables(state.pipe_behavior))
        state.pipe_behavior = set_pipe_tunables(state.pipe_behavior, new_tunables)
        CImGui.Unindent()
    end

    # Selection inspector
    if state isa PlacementReadyState
        selected_count = selected_element_count(inputstate)

        if selected_count > 1
            CImGui.Text("$selected_count parts selected")
            CImGui.Text("Select one part to inspect its details.")
            CImGui.Separator()
        elseif selected_count == 1
            CImGui.Text("Inspecting selected part...")
            CImGui.Separator()
            CImGui.NewLine()

            component_coords = selected_component_coords(inputstate)
            if !isempty(component_coords)
                selected = first(component_coords)
                comp = get_component(gamemap, selected)
                if isnothing(comp)
                    CImGui.Text("Selected component no longer exists.")
                    clear_selection!(inputstate)
                    CImGui.End()
                    return nothing
                end
                tilecomp = comp
                CImGui.Text("Hex Tile at $(coord_description(selected))")
                CImGui.Text("Type: $(String(nameof(typeof(tilecomp.component))))")
                CImGui.Text("Ship: $(tilecomp.ship)")

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
                inspect_ui!(first(selected_pipe_coords(inputstate)), gamemap, derivedmapstate, mna_state)
            end
        else
            # No right-click selection: show hovered part info
            clicked = get_clicked(inputstate)
            if !(clicked isa VertexCoord)
                cursor_cart = get_cursor_cart(inputstate)
                if !isnothing(cursor_cart)
                    clicked_pipe = get_clicked_pipe(cursor_cart, gamemap)
                    !isnothing(clicked_pipe) && (clicked = clicked_pipe)
                end
            end
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

"Display the centred navigation lock message during the Explorer opening capture."
function render_spacemap_opening_lock_message!(win_float)
    centre_y = win_float.height / 2.0
    text = "Navigation is not yet available."
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
    timewarp_status = can_timewarp(gamemap, gamestate, flowcalc_ipc)

    phase = manoeuvre.phase

    CImGui.TextColored(ImVec4(1.0, 0.7, 0.2, 1.0), "Manoeuvre Active")
    CImGui.Spacing()

    CImGui.Text(phase_description(phase))
    CImGui.Text(@sprintf("Approach Burn delta-V: %.1f", norm(manoeuvre.approach_burn_dv)))
    CImGui.Text(@sprintf("Capture Burn delta-V: %.1f", norm(manoeuvre.capture_burn_dv)))
    CImGui.Spacing()

    # Keep Cancel in place when waiting starts or the capture burn is reached
    wait_status = if phase != PHASE_COAST
        InvalidRequest("Waiting for capture is only available while coasting.")
    elseif time_progressing
        InvalidRequest("Time warp in progress")
    else
        timewarp_status
    end
    if button_with_disable("Wait for Capture Burn", ImVec2(-1, 30), wait_status)
        @atomic :monotonic flowcalc_ipc.shared_state.target_spacemap_time = manoeuvre.intercept_time
    end

    CImGui.Spacing()
    if CImGui.Button("Cancel Manoeuvre", ImVec2(-1, 25))
        modified_map = deepcopy(gamemap)
        clear_active_manoeuvre!(modified_map)
        enqueue_map_override!(flowcalc_ipc, modified_map)
    end

    return nothing
end

"Render read-only information for the validated current encounter."
function render_spacemap_target_info!(gamemap::GameMap, selected_idx::Int)
    encounter_points = get_encounter_points(gamemap)
    player_pos = get_position(gamemap)
    player_vel = get_velocity(gamemap)
    current_time = get_time_years(gamemap)::Float64

    if selected_idx == 0
        CImGui.TextWrapped("Click an encounter point on the map to select it.")
        return nothing
    end

    ep = encounter_points[selected_idx]
    ep_pos = get_encounter_position(ep, current_time)
    distance = norm(ep_pos - player_pos)

    CImGui.TextColored(
        fluid_tag_to_imvec4(ep.fuel_tag),
        "$(encounter_class_label(ep.encounter_class)): $(ep.display_name)"
    )
    fuel_label = fluid_type_label(ep.fuel_tag)
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

    player_vel = get_velocity(gamemap)
    current_time = get_time_years(gamemap)::Float64
    encounter_points = get_encounter_points(gamemap)
    ep = encounter_points[selected_idx]
    min_dv = calculate_minimum_intercept_dv(player_vel, ep.velocity)

    CImGui.TextColored(ImVec4(0.6, 0.8, 1.0, 1.0), "Intercept Calculated")
    CImGui.Spacing()

    delta_v_slider = get!(inputstate.gui_inputs, :spacemap_delta_v, Cfloat(min_dv))::Cfloat
    delta_v_slider = max(delta_v_slider, Cfloat(min_dv))

    CImGui.Text(@sprintf("Min Intercept delta-V: %.1f", min_dv))
    CImGui.Spacing()

    slider_min = Float32(max(min_dv, 1.0))
    slider_max = Float32(max(min_dv * 3.0, 100.0))
    CImGui.SetNextItemWidth(-1)
    @cref CImGui.SliderFloat("##dv_slider", &delta_v_slider, slider_min, slider_max, "delta-V: %.0f")
    inputstate.gui_inputs[:spacemap_delta_v] = delta_v_slider

    preview_manoeuvre = resolve_spacemap_manoeuvre!(inputstate, gamemap, selected_idx)

    if !isnothing(preview_manoeuvre)
        time_to_intercept = preview_manoeuvre.intercept_time - current_time
        CImGui.Text(@sprintf("Time to Intercept: %.3f yr", time_to_intercept))
    end

    CImGui.Spacing()
    can_plan = !isnothing(preview_manoeuvre)

    button_tooltip = !can_plan ? "No manoeuvre preview available" : nothing
    if button_with_disable("Plan Manoeuvre", ImVec2(-1, 35), !can_plan; tooltip = button_tooltip)
        modified_map = deepcopy(gamemap)
        set_target_time!(modified_map, current_time)
        set_active_manoeuvre!(modified_map, preview_manoeuvre)
        enqueue_map_override!(flowcalc_ipc, modified_map)
        @atomic :monotonic flowcalc_ipc.shared_state.target_spacemap_time = current_time
    end

    CImGui.Spacing()
    if CImGui.Button("Deselect", ImVec2(-1, 0))
        clear_spacemap_selection!(inputstate)
    end

    return nothing
end

"Render the prominent galaxy-escape discovery action."
function render_galaxy_escape_discovery!(inputstate::InputState)
    minimum_delta_v = first(GALAXY_ESCAPE_TIER_DELTA_V)
    requirement = @sprintf("Requires %.0f delta-V", minimum_delta_v)

    CImGui.PushFont(UI_VECTOR_FONT, 20.0)
    CImGui.PushStyleColor(CImGui.ImGuiCol_Text, GALAXY_ESCAPE_BUTTON_TEXT_COLOUR)
    CImGui.PushStyleColor(CImGui.ImGuiCol_Button, GALAXY_ESCAPE_BUTTON_COLOUR)
    CImGui.PushStyleColor(CImGui.ImGuiCol_ButtonHovered, GALAXY_ESCAPE_BUTTON_HOVERED_COLOUR)
    CImGui.PushStyleColor(CImGui.ImGuiCol_ButtonActive, GALAXY_ESCAPE_BUTTON_ACTIVE_COLOUR)
    clicked = CImGui.Button("Plan Galactic Escape!", CImGui.GetContentRegionAvail())
    CImGui.PopStyleColor(4)
    CImGui.PopFont()

    CImGui.IsItemHovered() && CImGui.SetTooltip(requirement)

    if clicked
        inputstate.gui_inputs[:galaxy_escape_confirmation] = true
    end

    return nothing
end

"Render the galaxy-departure confirmation window."
function render_galaxy_escape_confirmation!(
        inputstate::InputState,
        flowcalc_ipc::FlowCalculatorIPC,
        snapshot::FlowCalculatorSnapshot,
        winsize::NamedTuple{(:width, :height), Tuple{Int32, Int32}},
    )
    get(inputstate.gui_inputs, :galaxy_escape_confirmation, false)::Bool || return nothing

    minimum_delta_v = first(GALAXY_ESCAPE_TIER_DELTA_V)
    width = 560.0
    win_float = to_float(winsize)
    CImGui.SetNextWindowPos(
        ImVec2(win_float.width / 2.0, win_float.height / 2.0),
        CImGui.ImGuiCond_Always,
        ImVec2(0.5, 0.5),
    )
    CImGui.SetNextWindowSizeConstraints(ImVec2(width, 0.0), ImVec2(width, win_float.height))
    flags = CImGui.ImGuiWindowFlags_NoResize | CImGui.ImGuiWindowFlags_NoMove |
        CImGui.ImGuiWindowFlags_NoCollapse | CImGui.ImGuiWindowFlags_AlwaysAutoResize
    CImGui.Begin("Confirm Galaxy Escape Attempt?", C_NULL, flags)

    CImGui.TextWrapped("Proceeding will plot an escape trajectory out of the galactic plane. If you succeed in this manoeuvre, you win the game!")
    CImGui.Spacing()
    CImGui.TextWrapped(
        string(
            "This requires a minimum delta-V of $minimum_delta_v to reach escape velocity. ",
            "There are no other ships outside the galactic plane to refuel from so ensure you are confident your ship has enough delta-V before departure. ",
            "Remember that the in-game delta-V estimate is just based on fuel inventory and may not be accurate!",
        ),
    )
    CImGui.Spacing()
    CImGui.TextWrapped(
        "Once you start your escape this cannot be undone, however an autosave will be made you can restore from. "
    )

    below_minimum_escape_delta_v = snapshot.gamestate.estimated_min_delta_v < minimum_delta_v
    if below_minimum_escape_delta_v
        CImGui.Spacing()
        CImGui.PushStyleColor(CImGui.ImGuiCol_Text, ImVec4(1.0, 0.35, 0.2, 1.0))
        CImGui.TextWrapped(
            string(
                "WARNING: Your delta-V estimate is below the minimum escape target. ",
                "This attempt is unlikely to succeed and may consume most of your fuel. ",
                "Are you sure you want to proceed?",
            ),
        )
        CImGui.PopStyleColor()
    end

    CImGui.Spacing()
    available_width = CImGui.GetContentRegionAvail().x
    item_spacing = unsafe_load(CImGui.GetStyle().ItemSpacing).x
    button_width = (available_width - item_spacing) / 2.0
    if CImGui.Button("Not Yet", ImVec2(button_width, 40.0))
        inputstate.gui_inputs[:galaxy_escape_confirmation] = false
    end
    CImGui.SameLine()
    begin_label = below_minimum_escape_delta_v ? "Attempt Anyway" : "Begin Final Escape"
    button_colour = below_minimum_escape_delta_v ? GALAXY_ESCAPE_WARNING_BUTTON_COLOUR : GALAXY_ESCAPE_BUTTON_COLOUR
    hovered_colour = below_minimum_escape_delta_v ? GALAXY_ESCAPE_WARNING_BUTTON_HOVERED_COLOUR : GALAXY_ESCAPE_BUTTON_HOVERED_COLOUR
    !below_minimum_escape_delta_v && CImGui.PushStyleColor(CImGui.ImGuiCol_Text, GALAXY_ESCAPE_BUTTON_TEXT_COLOUR)
    CImGui.PushStyleColor(CImGui.ImGuiCol_Button, button_colour)
    CImGui.PushStyleColor(CImGui.ImGuiCol_ButtonHovered, hovered_colour)
    begin_clicked = CImGui.Button(begin_label, ImVec2(button_width, 40.0))
    CImGui.PopStyleColor(below_minimum_escape_delta_v ? 2 : 3)
    if begin_clicked
        command = create_start_galaxy_escape_command(flowcalc_ipc.command_queue)
        if try_enqueue_command!(flowcalc_ipc.command_queue, command)
            inputstate.gui_inputs[:galaxy_escape_confirmation] = false
            inputstate.spacemap_active = false
        else
            flowcalc_ipc.console_push("Could not begin galaxy escape because the command queue is full.")
        end
    end

    CImGui.End()
    return nothing
end

"Render the left control panel for the space-map overlay."
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
    has_manoeuvre = has_active_manoeuvre(gamemap)
    time_progressing = is_time_progressing(gamemap)
    show_galaxy_escape = is_galaxy_escape_unlocked(get_peak_estimated_delta_v(gamemap))

    CImGui.BeginChild("spacemap_left_column", ImVec2(left_width, panel_height), false)

    main_panel_height = show_galaxy_escape ? -SPACEMAP_ESCAPE_PANEL_HEIGHT : 0.0
    CImGui.BeginChild("spacemap_main_panel", ImVec2(0.0, main_panel_height), true)

    #= ---------- Header ----------- =#
    CImGui.PushFont(UI_VECTOR_FONT, 18.0)
    CImGui.TextColored(ImVec4(0.7, 0.9, 1.0, 1.0), "SPACE MAP")
    CImGui.PopFont()
    CImGui.SameLine(left_width - 80.0)
    if CImGui.Button("Close [M]")
        inputstate.spacemap_active = false
    end

    #= ---------- Time section ----------- =#
    CImGui.SeparatorText("TIME")

    CImGui.Text("Current Time:")
    CImGui.PushFont(UI_VECTOR_FONT, 24.0)
    time_colour = time_progressing ? ImVec4(1.0, 0.65, 0.1, 1.0) : ImVec4(0.7, 0.9, 1.0, 1.0)
    CImGui.TextColored(time_colour, @sprintf("%.3f years", current_time))
    CImGui.PopFont()
    CImGui.Spacing()

    timewarp_status = can_timewarp(gamemap, gamestate, flowcalc_ipc)

    # Advance time buttons — always shown, disabled while warping, blocked, or paused
    advance_status = time_progressing ? InvalidRequest("Time warp in progress") : timewarp_status
    CImGui.Text("Advance Time:")
    if CImGui.BeginTable("##advance_time", 3, CImGui.ImGuiTableFlags_SizingStretchSame)
        for (label, dt) in (("0.1 yr", 0.1), ("1 yr", 1.0), ("10 yr", 10.0))
            CImGui.TableNextColumn()
            if button_with_disable(label, ImVec2(-1, 0), advance_status)
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
    CImGui.Text(@sprintf("Ship delta-V: %.1f", gamestate.estimated_min_delta_v))
    CImGui.Spacing()

    selected_idx = validate_spacemap_selection!(inputstate, gamemap)

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

    if show_galaxy_escape
        CImGui.BeginChild("spacemap_escape_panel", ImVec2(0.0, 0.0), true)
        render_galaxy_escape_discovery!(inputstate)
        CImGui.EndChild()
    end

    CImGui.EndChild()
    return nothing
end

"Render committed or previewed intercept trajectories on the space map."
function render_spacemap_trajectory_previews!(inputstate::InputState, gamemap::GameMap, selected_idx::Int)
    selected_idx == 0 && return nothing

    player_pos = get_position(gamemap)
    player_vel = get_velocity(gamemap)
    current_time = get_time_years(gamemap)::Float64
    encounter_points = get_encounter_points(gamemap)
    has_manoeuvre = has_active_manoeuvre(gamemap)
    ep = encounter_points[selected_idx]

    manoeuvre = resolve_spacemap_manoeuvre!(inputstate, gamemap, selected_idx)
    isnothing(manoeuvre) && return nothing

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
    ImPlot.PlotLine(
        "##leg_player_path",
        Float64[player_pos[1], predicted_intercept_position[1]],
        Float64[player_pos[2], predicted_intercept_position[2]];
        spec = ImPlot.ImPlotSpec(LineColor = player_path_colour, LineWeight = line_width),
    )

    # Target trajectory from its current position to the same intercept point.
    ImPlot.PlotLine(
        "##leg_target",
        Float64[target_pos[1], predicted_intercept_position[1]],
        Float64[target_pos[2], predicted_intercept_position[2]];
        spec = ImPlot.ImPlotSpec(LineColor = target_colour, LineWeight = line_width),
    )

    # Mark the shared intercept point.
    burn_marker_colour = has_manoeuvre ? ImVec4(1.0, 0.9, 0.3, 0.9) : ImVec4(1.0, 0.9, 0.3, 0.5)
    ImPlot.PlotScatter(
        "##intercept_marker",
        Float64[predicted_intercept_position[1]],
        Float64[predicted_intercept_position[2]];
        spec = ImPlot.ImPlotSpec(Marker = ImPlot.ImPlotMarker_Asterisk, MarkerSize = 7.0, MarkerFillColor = burn_marker_colour),
    )

    return nothing
end

"Render the encounter plot area for the space-map overlay."
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
        ImPlot.PlotScatter(
            "##player", Float64[player_pos[1]], Float64[player_pos[2]];
            spec = ImPlot.ImPlotSpec(Marker = ImPlot.ImPlotMarker_Diamond, MarkerSize = 8.0, MarkerFillColor = ImVec4(0.8, 0.8, 0.0, 1.0)),
        )

        n_enc = length(encounter_points)
        selected_idx = validate_spacemap_selection!(inputstate, gamemap, ImPlot.GetPlotLimits())
        if n_enc > 0
            enc_cfg = sm.encounter_config
            total_viewport_width = sm.viewport_half_width * 2.0
            min_arrow_len = total_viewport_width * 0.012
            max_arrow_len = total_viewport_width * 0.12
            enc_xs = Vector{Float64}(undef, n_enc)
            enc_ys = Vector{Float64}(undef, n_enc)

            for i in 1:n_enc
                epos = get_encounter_position(encounter_points[i], current_time)
                enc_xs[i] = epos[1]
                enc_ys[i] = epos[2]
            end

            # Resolve clicks before drawing the current target
            if ImPlot.IsPlotHovered() && CImGui.IsMouseClicked(0)
                mouse = ImPlot.GetPlotMousePos()
                viewport = ImPlot.GetPlotLimits()
                best_idx = 0
                best_dist_sq = SPACEMAP_CLICK_RADIUS_SQ
                for i in 1:n_enc
                    if !(viewport.X.Min <= enc_xs[i] <= viewport.X.Max && viewport.Y.Min <= enc_ys[i] <= viewport.Y.Max)
                        continue
                    end
                    dx = enc_xs[i] - mouse.x
                    dy = enc_ys[i] - mouse.y
                    dist_sq = dx * dx + dy * dy
                    if dist_sq < best_dist_sq
                        best_dist_sq = dist_sq
                        best_idx = i
                    end
                end
                select_spacemap_encounter!(inputstate, gamemap, best_idx)
                selected_idx = validate_spacemap_selection!(inputstate, gamemap, viewport)
            end

            # Render velocity vector arrows
            for i in 1:n_enc
                ep = encounter_points[i]
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

                ImPlot.PlotLine(
                    @sprintf("##enc_vel_%d", i),
                    Float64[enc_xs[i], vel_tip[1]],
                    Float64[enc_ys[i], vel_tip[2]];
                    spec = ImPlot.ImPlotSpec(LineColor = line_colour, LineWeight = line_width),
                )

                # Arrow tip: small solid circle at the velocity vector endpoint
                ImPlot.PlotScatter(
                    @sprintf("##enc_tip_%d", i),
                    Float64[vel_tip[1]],
                    Float64[vel_tip[2]];
                    spec = ImPlot.ImPlotSpec(Marker = ImPlot.ImPlotMarker_Circle, MarkerSize = 3.0, MarkerLineColor = line_colour, MarkerFillColor = line_colour, LineWeight = 0.0),
                )
            end

            # Bucket encounters by (class, fuel_tag) for coloured markers.
            # Shape distinguishes class; colour distinguishes fuel type.
            marker_buckets = Dict{Tuple{EncounterClass, Union{HexFluids.FluidType, Nothing}}, Tuple{Vector{Float64}, Vector{Float64}}}()
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
                fuel_label = fluid_type_label(tag)
                label = isnothing(fuel_label) ? encounter_class_label(class) : "$(encounter_class_label(class)) ($fuel_label)"
                ImPlot.PlotScatter(
                    label, xs, ys;
                    spec = ImPlot.ImPlotSpec(Marker = marker, MarkerSize = size, MarkerFillColor = colour),
                )
            end

            # Render selected encounter highlight
            if selected_idx > 0
                ImPlot.PlotScatter(
                    "##selected",
                    Float64[enc_xs[selected_idx]], Float64[enc_ys[selected_idx]];
                    spec = ImPlot.ImPlotSpec(Marker = ImPlot.ImPlotMarker_Diamond, MarkerSize = 9.0, MarkerFillColor = ImVec4(1.0, 0.9, 0.3, 1.0)),
                )
            end
        end

        # Render Trajectory
        render_spacemap_trajectory_previews!(inputstate, gamemap, selected_idx)

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
        inputstate.gui_inputs[:galaxy_escape_confirmation] = false
        return nothing
    end

    gamemap = snapshot.gamemap
    if is_galaxy_escape_active(gamemap)
        inputstate.spacemap_active = false
        inputstate.gui_inputs[:galaxy_escape_confirmation] = false
        return nothing
    end
    win_float = to_float(winsize)

    CImGui.SetNextWindowPos(ImVec2(0.0, 0.0))
    CImGui.SetNextWindowSize(ImVec2(win_float.width, win_float.height))
    flags = CImGui.ImGuiWindowFlags_NoTitleBar | CImGui.ImGuiWindowFlags_NoResize |
        CImGui.ImGuiWindowFlags_NoMove | CImGui.ImGuiWindowFlags_NoScrollbar |
        CImGui.ImGuiWindowFlags_NoBringToFrontOnFocus
    CImGui.PushStyleVar(CImGui.ImGuiStyleVar_WindowBorderSize, 0.0)
    CImGui.PushStyleColor(CImGui.ImGuiCol_WindowBg, ImVec4(0.05, 0.05, 0.1, 0.97))

    CImGui.Begin("##spacemap_overlay", C_NULL, flags)

    if is_explorer_opening_capture(gamemap)
        render_spacemap_opening_lock_message!(win_float)
        CImGui.End()
        CImGui.PopStyleColor()
        CImGui.PopStyleVar()
        return nothing
    end

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

    # Resolve plot limits and selection before offering planning controls
    panel_position = CImGui.GetCursorPos()
    CImGui.SetCursorPos(ImVec2(panel_position.x + left_width + 12.0f0, panel_position.y))
    render_spacemap_plot_area!(inputstate, gamemap, right_width, avail.y)
    CImGui.SetCursorPos(panel_position)
    render_spacemap_left_panel!(inputstate, flowcalc_ipc, gamemap, snapshot.gamestate, left_width, avail.y)

    CImGui.End()
    CImGui.PopStyleColor()
    CImGui.PopStyleVar()

    render_galaxy_escape_confirmation!(inputstate, flowcalc_ipc, snapshot, winsize)

    return nothing
end
