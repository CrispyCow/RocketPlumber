#=
Scope: Read-only player readouts and optional technical inspection in all game modes
Formatter: Runic
=#

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
function display_element_details!(elements::Tuple, mna_state::MNA_StateSnapshot)
    if isempty(elements)
        CImGui.Text("No elements")
        return nothing
    end

    for (index, element) in enumerate(elements)
        CImGui.PushID(index)

        props = get_tunables(element)

        CImGui.Text("$(props.type_desc) [$index]")
        CImGui.Text("Value: $(format_value(props.current_val)) $(props.unit_desc)")

        current = solved_element_current(mna_state, element.id)
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

"Inspect a tile coordinate, displaying component values and element details."
function inspect_technical_ui!(tile::TileCoord, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot)
    CImGui.Text("Hex Tile at $(coord_description(tile))")
    for (slot, dir) in ((1, HexFrame.NODE_INTERNAL_1), (2, HexFrame.NODE_INTERNAL_2), (3, HexFrame.NODE_INTERNAL_3))
        internalnode = NodeCoord(tile, dir)
        if haskey(mna_state.node_voltages, internalnode)
            CImGui.Text("Internal Node $slot Voltage: $(format_value(mna_state.node_voltages[internalnode])) V")
        end
    end

    tilecomp = get_component(gamemap, tile)
    if !isnothing(tilecomp)
        component_temperature = get_component_temperature(tilecomp)
        temperature_str = isnothing(component_temperature) ? "None" : "$(format_value(component_temperature)) K"
        CImGui.Text("Temperature: $(temperature_str)")
        CImGui.Text("Type: $(nameof(typeof(tilecomp.component)))")
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
        display_element_details!(elements, mna_state)
        CImGui.Unindent()
    else
        CImGui.Text("No component on this tile.")
    end

    return nothing
end

"Inspect a vertex coordinate, displaying node voltage and fluid tag."
function inspect_technical_ui!(vert::VertexCoord, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot)
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
function inspect_technical_ui!(pipe_coord::PipeCoord, gamemap::GameMap, derivedmapstate::DerivedMapState, mna_state::MNA_StateSnapshot)
    CImGui.Text("Pipe Between:")
    CImGui.Text("$(coord_description(pipe_coord.v1)) and $(coord_description(pipe_coord.v2))")

    # Check for pipe behaviours
    pipe = get_pipe(gamemap, pipe_coord)
    if !isnothing(pipe)
        CImGui.Text("Type: $(nameof(typeof(pipe.pipe)))")
        CImGui.Text("Ship: $(pipe.ship)")

        # Pipe Values
        CImGui.Text("\nPipe Values:")
        CImGui.Separator()
        CImGui.Indent()
        tunables = get_pipe_tunables(pipe)
        display_component_values!(tunables)
        CImGui.Unindent()

        # Element Details
        CImGui.Text("\nElement Details:")
        CImGui.Separator()
        CImGui.Indent()
        elements = produce_abs_elements(pipe, pipe_coord)
        display_element_details!(elements, mna_state)
        CImGui.Unindent()
    else
        CImGui.Text("No pipe at this location.")
    end

    return nothing
end

# ===============================================================
# Player Readouts
# ===============================================================

"Wrap literal readout text without interpreting percent signs as printf directives."
function inspection_text!(text::String)
    CImGui.PushTextWrapPos(0.0)
    CImGui.TextUnformatted(text)
    CImGui.PopTextWrapPos()
    return nothing
end

"Use whole percentages, whole-number K/rpm/N/EU, and readable precision for other units."
function inspection_number(value::Float64, units::String = "")
    isfinite(value) || return "--"
    if units == "%"
        rounded = round(value, RoundNearestTiesAway)
        return iszero(rounded) ? "0" : @sprintf("%.0f", rounded)
    end
    iszero(value) && return "0"

    magnitude = abs(value)
    if magnitude < 1.0e-6 || magnitude >= 1.0e7
        return @sprintf("%.3g", value)
    end
    if units in ("K", "rpm", "N", "EU") && magnitude >= 1.0
        return @sprintf("%.0f", value)
    end

    digits = max(0, 2 - floor(Int, log10(magnitude)))
    reading = @sprintf("%.*f", digits, round(value; sigdigits = 3))
    return digits > 0 ? String(rstrip(rstrip(reading, '0'), '.')) : reading
end

inspection_measurement(value::Float64, units::String) = !isfinite(value) || isempty(units) ? inspection_number(value, units) : string(inspection_number(value, units), units == "%" ? "" : " ", units)
inspection_measurement(::Nothing, ::String) = "--"

"Clamp only the visual fill, including degenerate bounds and non-finite values."
function inspection_fraction(item::InspectionGauge, value::Float64 = item.value)
    span = item.maximum - item.minimum
    isfinite(span) && span > 0.0 || return 0.0f0
    fraction = (value - item.minimum) / span
    isnan(fraction) && return 0.0f0
    return Float32(clamp(fraction, 0.0, 1.0))
end

"Render a consistent pair of wrapped columns at the Property window's width."
function inspection_row!(label::String, value::String; colour::Union{Nothing, ColourType} = nothing)
    if CImGui.BeginTable("##readout", 2, CImGui.ImGuiTableFlags_SizingStretchProp)
        CImGui.TableSetupColumn("Label", CImGui.ImGuiTableColumnFlags_WidthStretch, 0.45f0)
        CImGui.TableSetupColumn("Value", CImGui.ImGuiTableColumnFlags_WidthStretch, 0.55f0)
        CImGui.TableNextColumn()
        inspection_text!(label)
        CImGui.TableNextColumn()
        !isnothing(colour) && CImGui.PushStyleColor(CImGui.ImGuiCol_Text, ImVec4(colour...))
        inspection_text!(value)
        !isnothing(colour) && CImGui.PopStyleColor()
        CImGui.EndTable()
    end
    return nothing
end

render_inspection_item!(item::InspectionValue) = inspection_row!(item.label, inspection_measurement(item.value, item.units))

"Format gauge readings, reserving three digits for targeted percentage controls."
function inspection_gauge_reading(item::InspectionGauge)
    if isnothing(item.target)
        return "$(inspection_number(item.value, item.units)) / $(inspection_measurement(item.maximum, item.units))"
    end
    current = inspection_measurement(item.value, item.units)
    item.units == "%" && (current = lpad(current, 4))
    return "$current (target $(inspection_measurement(item.target, item.units)))"
end

"Map a visually clamped target to the actual bar endpoints."
inspection_target_position(item::InspectionGauge, lower::Real, upper::Real) = lower + inspection_fraction(item, item.target) * (upper - lower)

"Show current and target numerically, retaining the standard progress-bar fill."
function render_inspection_item!(item::InspectionGauge)
    reading = inspection_gauge_reading(item)
    inspection_row!(item.label, reading)

    # Reserve the module-sized pointer above the bar
    has_target = !isnothing(item.target) && isfinite(item.target)
    overhang, pointer_height, pointer_halfwidth = ui_px(1), ui_px(1), ui_px(1)
    if has_target
        CImGui.SetCursorPosY(CImGui.GetCursorPosY() + overhang + pointer_height)
    end
    !isnothing(item.colour) && CImGui.PushStyleColor(CImGui.ImGuiCol_PlotHistogram, ImVec4(item.colour...))
    CImGui.ProgressBar(inspection_fraction(item), ImVec2(-1.0, ui_px(3)), "")
    !isnothing(item.colour) && CImGui.PopStyleColor()
    if has_target
        lower, upper = CImGui.GetItemRectMin(), CImGui.GetItemRectMax()
        thickness = 1.0f0
        x = inspection_target_position(item, lower.x, upper.x)
        top, bottom = ImVec2(x, lower.y - overhang), ImVec2(x, upper.y + overhang)
        left = ImVec2(x - pointer_halfwidth, top.y - pointer_height)
        right = ImVec2(x + pointer_halfwidth, top.y - pointer_height)
        draw = CImGui.GetWindowDrawList()
        colour = CImGui.GetColorU32(CImGui.ImGuiCol_Text)
        outline = CImGui.GetColorU32(CImGui.ImGuiCol_WindowBg)
        CImGui.AddLine(draw, top, bottom, outline, thickness + 2.0f0)
        CImGui.AddLine(draw, top, bottom, colour, thickness)
        CImGui.AddTriangleFilled(draw, left, right, top, colour)
        CImGui.AddTriangle(draw, left, right, top, outline, 1.0f0)
        CImGui.SetCursorPosY(CImGui.GetCursorPosY() + overhang)
    end
    CImGui.Spacing()
    return nothing
end

"Use the active text colour for information and a shared palette for warnings and faults."
function inspection_tone_colour(tone::InspectionTone)
    tone == INSPECTION_ERROR && return ColourType(1.0, 0.35, 0.3, 1.0)
    tone == INSPECTION_WARNING && return ColourType(1.0, 0.75, 0.25, 1.0)
    return nothing
end

"Draw severity icons from geometry so they work with the normal bitmap font."
function render_inspection_item!(item::InspectionAlert)
    colour = inspection_tone_colour(item.tone)
    packed = isnothing(colour) ? CImGui.GetColorU32(CImGui.ImGuiCol_Text) : CImGui.GetColorU32(ImVec4(colour...))
    origin = CImGui.GetCursorScreenPos()
    size = ui_px(4)
    line_height = CImGui.GetTextLineHeight()
    x, y = origin.x + size / 2, origin.y + line_height / 2
    radius = size * 0.4
    # Proportional interior details, with one-pixel strokes and dots
    detail = radius * 0.4
    thickness = 1.0f0
    draw = CImGui.GetWindowDrawList()
    if item.tone == INSPECTION_WARNING
        CImGui.AddTriangle(draw, ImVec2(x, y - radius), ImVec2(x + radius, y + radius), ImVec2(x - radius, y + radius), packed, thickness)
        CImGui.AddLine(draw, ImVec2(x, y - detail), ImVec2(x, y + detail * 0.5), packed, thickness)
        CImGui.AddCircleFilled(draw, ImVec2(x, y + detail * 1.5), 1.0f0, packed)
    else
        CImGui.AddCircle(draw, ImVec2(x, y), radius, packed, 16, thickness)
        if item.tone == INSPECTION_ERROR
            CImGui.AddLine(draw, ImVec2(x - detail, y - detail), ImVec2(x + detail, y + detail), packed, thickness)
            CImGui.AddLine(draw, ImVec2(x + detail, y - detail), ImVec2(x - detail, y + detail), packed, thickness)
        else
            CImGui.AddCircleFilled(draw, ImVec2(x, y - detail), 1.0f0, packed)
            CImGui.AddLine(draw, ImVec2(x, y), ImVec2(x, y + detail * 1.5), packed, thickness)
        end
    end
    CImGui.Dummy(ImVec2(size, line_height))
    CImGui.SameLine(0.0f0, ui_px(1))
    !isnothing(colour) && CImGui.PushStyleColor(CImGui.ImGuiCol_Text, ImVec4(colour...))
    inspection_text!(item.message)
    !isnothing(colour) && CImGui.PopStyleColor()
    return nothing
end

"Render plain and labelled separators using the installed CImGui widgets."
function render_inspection_item!(item::InspectionDivider)
    if isempty(item.label)
        CImGui.Separator()
    else
        CImGui.PushStyleVar(CImGui.ImGuiStyleVar_SeparatorTextBorderSize, 1.0f0)
        CImGui.SeparatorText(item.label)
        CImGui.PopStyleVar()
    end
    return nothing
end

"Resolve status emphasis centrally, retaining the established fluid palette."
function render_inspection_item!(item::InspectionStatus)
    colour = inspection_tone_colour(item.tone)
    if isnothing(colour) && item.value isa FluidType
        colour = get_fluid_colour(item.value)
    end
    value = item.value isa FluidType ? fluid_type_label(item.value) : something(item.value, "--")
    if isempty(item.label)
        CImGui.Spacing()
        !isnothing(colour) && CImGui.PushStyleColor(CImGui.ImGuiCol_Text, ImVec4(colour...))
        inspection_text!(value)
        !isnothing(colour) && CImGui.PopStyleColor()
        CImGui.Spacing()
    else
        inspection_row!(item.label, value; colour)
    end
    return nothing
end

"Render a heterogeneous tuple without retaining any snapshot references."
function render_inspection_items!(items::Tuple)
    for (index, item) in enumerate(items)
        CImGui.PushID(index)
        render_inspection_item!(item)
        CImGui.PopID()
    end
    return nothing
end

const PropertyInspectionTarget = Union{Nothing, TileCoord, PipeCoord, VertexCoord}

valid_property_target(coord::TileCoord, gamemap::GameMap) = has_component(gamemap, coord)
valid_property_target(coord::PipeCoord, gamemap::GameMap) = has_pipe(gamemap, coord)

"A meaningful junction touches ship surface, a component or an actual pipe endpoint."
function valid_property_target(coord::VertexCoord, gamemap::GameMap)
    return any(tile -> !isnothing(get_surface_shiptag(gamemap, tile)) || has_component(gamemap, tile), get_tiles(coord)) ||
        any(pipe -> has_pipe(gamemap, pipe), get_pipe_segments(coord))
end

"Resolve a single selection without ever falling back to a hovered object."
function selected_property_target(inputstate::InputState, gamemap::GameMap)::PropertyInspectionTarget
    selected_element_count(inputstate) == 1 || return nothing
    selected = selection_state(inputstate)
    selected isa WorldSelectionState || return nothing
    target = isempty(selected.component_coords) ? first(selected.pipe_coords) : first(selected.component_coords)
    return valid_property_target(target, gamemap) ? target : nothing
end

"Resolve real world geometry, preferring junctions, then placed pipes of any span, then components."
function hovered_property_target(inputstate::InputState, gamemap::GameMap)::PropertyInspectionTarget
    target = get_clicked(inputstate)
    if target isa VertexCoord && valid_property_target(target, gamemap)
        return target
    end
    cursor = get_cursor_cart(inputstate)
    isnothing(cursor) && return nothing
    pipe = get_clicked_pipe(cursor, gamemap)
    !isnothing(pipe) && return pipe
    tile = round_to_tile(cursor)
    return has_component(gamemap, tile) ? tile : nothing
end

"Resolve Properties from current UI, placement, selection and world hover without retaining targets."
function property_panel_content(inputstate::InputState, gamemap::GameMap; world_hover_allowed::Bool = true)
    if inputstate.ui_hidden || inputstate.spacemap_active
        return (visibility = :hidden, target = nothing)
    end
    if !(placement_state(inputstate) isa PlacementReadyState)
        return (visibility = :interactive, target = nothing)
    end
    if selected_element_count(inputstate) > 0
        return (visibility = :interactive, target = selected_property_target(inputstate, gamemap))
    end
    if world_hover_allowed
        target = hovered_property_target(inputstate, gamemap)
        !isnothing(target) && return (visibility = :preview, target = target)
    end

    return (visibility = :idle, target = nothing)
end

# Component-family headings avoid exposing implementation names or tile coordinates
inspection_heading(::ComponentBehavior) = "Component"
inspection_heading(::BasicNozzleCompBehav) = "Nozzle"
inspection_heading(::SwitchedNozzleCompBehav) = "Switched nozzle"
inspection_heading(::DecompChamberCompBehav) = "Decomposition chamber"
inspection_heading(::BipropChamberCompBehav) = "Combustion chamber"
inspection_heading(::TurboPumpCompBehav) = "Turbopump"
inspection_heading(::ElectricPumpCompBehav) = "Electric pump"
inspection_heading(::StandardValveCompBehav) = "Valve"
inspection_heading(::ThevininTankCompBehav{GasTankBehavFrag}) = "Gas tank"
inspection_heading(::ThevininTankCompBehav{LiquidTankBehavFrag}) = "Liquid tank"
inspection_heading(::PressureFedTankCompBehav) = "Pressure-fed liquid tank"
inspection_heading(::PipeBehavior) = "Pipe"

"Identify the inspected object with a compact Bold heading."
function inspection_heading!(heading::String)
    push_ui_font(; bold = true)
    CImGui.TextUnformatted(heading)
    CImGui.PopFont()
    return nothing
end

"Keep Debug above its details and at the minimum panel's footer when readouts are short."
function inspection_debug_header!(minimum_height::Real)
    style = CImGui.GetStyle()
    footer_y = minimum_height - unsafe_load(style.WindowPadding).y - CImGui.GetFrameHeight()
    CImGui.SetCursorPosY(max(CImGui.GetCursorPosY(), footer_y))
    return CImGui.CollapsingHeader("Technical details (Debug)")
end

"Inspect one component or pipe, offering technical details only for interactive inspection."
function inspect_ui!(coord::Union{TileCoord, PipeCoord}, gamemap::GameMap, derived::DerivedMapState, mna::MNA_StateSnapshot; debug::Bool = true, minimum_height::Real = 0.0)
    object = coord isa TileCoord ? get_component(gamemap, coord) : get_pipe(gamemap, coord)
    if isnothing(object)
        inspection_text!("No part at this location.")
        return nothing
    end

    if coord isa TileCoord
        inspection_heading!(inspection_heading(object.component))
        items = get_inspection_items(object; derivedmapstate = derived, mna_state = mna, tile = coord)
    else
        inspection_heading!(inspection_heading(object.pipe))
        items = get_inspection_items(object; derivedmapstate = derived, mna_state = mna, position = coord)
    end
    if isempty(items)
        inspection_text!("No operating readouts for this part.")
        CImGui.Spacing()
    else
        render_inspection_items!(items)
        CImGui.Separator()
    end

    if debug && inspection_debug_header!(minimum_height)
        inspect_technical_ui!(coord, gamemap, derived, mna)
    end
    return nothing
end

"Keep core junction readings present even when solved data is unavailable."
function junction_inspection_items(coord::VertexCoord, derived::DerivedMapState, mna::MNA_StateSnapshot)
    node = to_nodecoord(coord)
    pressure = get(mna.node_voltages, node, nothing)
    temperature = get(derived.node_temperatures, node, nothing)
    return (
        InspectionDivider("Operation"),
        InspectionStatus("Fluid", get(derived.nodeactualfluids, node, nothing)),
        inspection_pressure_bar("Pressure", pressure),
        InspectionValue("Temperature", temperature; units = "K"),
    )
end

"Show a junction's fluid state and optional read-only circuit diagnostics."
function inspect_ui!(coord::VertexCoord, gamemap::GameMap, derived::DerivedMapState, mna::MNA_StateSnapshot; debug::Bool = true, minimum_height::Real = 0.0)
    inspection_heading!("Junction")
    render_inspection_items!(junction_inspection_items(coord, derived, mna))
    CImGui.Separator()
    if debug && inspection_debug_header!(minimum_height)
        inspect_technical_ui!(coord, gamemap, derived, mna)
    end
    return nothing
end

inspect_ui!(::Nothing, ::GameMap, ::DerivedMapState, ::MNA_StateSnapshot; debug::Bool = true, minimum_height::Real = 0.0) = inspection_text!("Hover over or select a part to inspect it.")
