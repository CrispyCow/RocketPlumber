#=
Scope: Player input, world interaction state, cursor previews, and map-edit command dispatch
Formatter: Runic
=#

using FlowMap

# ===============================================================
# View and Input Polling
# ===============================================================

"Poll continuous movement and zoom keys into the view state."
function poll_keys!(viewstate::ViewState, window::GLFW.Window)
    # Establish the frame-time baseline
    if viewstate.last_update_time == 0.0
        viewstate.last_update_time = time()
        return nothing
    end

    # Frame timing and input rates
    pan_rate_per_sec = 7.0f0
    zoom_rate_per_sec = 2.5f0
    current_time = time()
    delta_time = current_time - viewstate.last_update_time
    viewstate.last_update_time = current_time

    # Frame-rate-independent movement scales
    pan_amount = pan_rate_per_sec * delta_time / viewstate.view_zoom
    zoom_factor_in = exp(zoom_rate_per_sec * delta_time)
    zoom_factor_out = exp(-zoom_rate_per_sec * delta_time)

    # Apply pan and exponential zoom before enforcing view limits
    get_instate(GLFW.KEY_A, window) && (viewstate.view_x += pan_amount)
    get_instate(GLFW.KEY_D, window) && (viewstate.view_x -= pan_amount)
    get_instate(GLFW.KEY_S, window) && (viewstate.view_y += pan_amount)
    get_instate(GLFW.KEY_W, window) && (viewstate.view_y -= pan_amount)
    get_instate(GLFW.KEY_Q, window) && (viewstate.view_zoom *= zoom_factor_out)
    get_instate(GLFW.KEY_E, window) && (viewstate.view_zoom *= zoom_factor_in)

    apply_view_limits!(viewstate)

    return nothing
end

"Update view-state ship bounds, expanding each axis symmetrically to at least 10 units."
function update_ship_bounds!(viewstate::ViewState, gamemap::GameMap)
    # Raw map geometry
    raw_bounds = get_cartesian_bounds(gamemap)

    # Minimum viewport footprint, centred on the actual ship bounds
    centre_x = (raw_bounds.X_POS + raw_bounds.X_NEG) / 2.0
    centre_y = (raw_bounds.Y_POS + raw_bounds.Y_NEG) / 2.0
    span_x = raw_bounds.X_POS - raw_bounds.X_NEG
    span_y = raw_bounds.Y_POS - raw_bounds.Y_NEG
    MIN_SPAN = 10.0
    half_span_x = max(span_x / 2.0, MIN_SPAN / 2.0)
    half_span_y = max(span_y / 2.0, MIN_SPAN / 2.0)

    # Expanded view limits
    viewstate.ship_bounds = (
        X_POS = centre_x + half_span_x,
        X_NEG = centre_x - half_span_x,
        Y_POS = centre_y + half_span_y,
        Y_NEG = centre_y - half_span_y,
    )

    return nothing
end

"Constrain zoom and pan so the bounded ship remains meaningfully visible."
function apply_view_limits!(viewstate::ViewState)
    bounds = viewstate.ship_bounds

    # Ship extent in world units
    ship_span_x = bounds.X_POS - bounds.X_NEG
    ship_span_y = bounds.Y_POS - bounds.Y_NEG
    ship_span_max = max(ship_span_x, ship_span_y)
    hex_size_pixels = 256.0f0

    # Minimum zoom keeps the ship within five times its longest span
    max_visible_span = ship_span_max * 5.0f0
    min_zoom_x = viewstate.fb_width / (max_visible_span * hex_size_pixels)
    min_zoom_y = viewstate.fb_height / (max_visible_span * hex_size_pixels)
    min_zoom = max(min_zoom_x, min_zoom_y)
    MIN_VIEW_ZOOM = 0.01f0
    min_zoom = max(min_zoom, MIN_VIEW_ZOOM)
    viewstate.view_zoom = max(viewstate.view_zoom, min_zoom)

    # Visible area and required ship margin after zoom clamping
    visible_width = viewstate.fb_width / (viewstate.view_zoom * hex_size_pixels)
    visible_height = viewstate.fb_height / (viewstate.view_zoom * hex_size_pixels)
    margin_fraction = 0.1f0  # 10% of ship must stay visible
    margin_x = ship_span_x * margin_fraction
    margin_y = ship_span_y * margin_fraction
    bounds_centre_x = (bounds.X_POS + bounds.X_NEG) / 2.0f0
    bounds_centre_y = (bounds.Y_POS + bounds.Y_NEG) / 2.0f0

    # Pan limits; view_x positive moves the camera left, revealing the ship's right side
    # We want: camera_centre_x - visible_width/2 < bounds.X_POS - margin (can't pan too far right)
    # And: camera_centre_x + visible_width/2 > bounds.X_NEG + margin (can't pan too far left)
    # camera_centre = -view (since view is offset applied to world)

    max_pan_x = -(bounds.X_NEG + margin_x - visible_width / 2.0f0)
    min_pan_x = -(bounds.X_POS - margin_x + visible_width / 2.0f0)
    max_pan_y = -(bounds.Y_NEG + margin_y - visible_height / 2.0f0)
    min_pan_y = -(bounds.Y_POS - margin_y + visible_height / 2.0f0)

    # Centre an axis when its visible area exceeds the permitted pan range
    if min_pan_x > max_pan_x
        viewstate.view_x = -bounds_centre_x
    else
        viewstate.view_x = clamp(viewstate.view_x, min_pan_x, max_pan_x)
    end

    if min_pan_y > max_pan_y
        viewstate.view_y = -bounds_centre_y
    else
        viewstate.view_y = clamp(viewstate.view_y, min_pan_y, max_pan_y)
    end

    return nothing
end

"Return the union of viewports reachable within the current ship bounds and zoom limits."
function calc_max_reachable_bounds(viewstate::ViewState)
    bounds = viewstate.ship_bounds

    # Minimum reachable zoom, matching `apply_view_limits!`
    ship_span_x = bounds.X_POS - bounds.X_NEG
    ship_span_y = bounds.Y_POS - bounds.Y_NEG
    ship_span_max = max(ship_span_x, ship_span_y)
    max_visible_span = ship_span_max * 5.0f0
    hex_size_pixels = 256.0f0
    min_zoom_x = viewstate.fb_width / (max_visible_span * hex_size_pixels)
    min_zoom_y = viewstate.fb_height / (max_visible_span * hex_size_pixels)
    min_zoom = max(min_zoom_x, min_zoom_y)
    MIN_VIEW_ZOOM = 0.01f0
    min_zoom = max(min_zoom, MIN_VIEW_ZOOM)

    # Largest viewport at that zoom
    max_view_width = viewstate.fb_width / (min_zoom * hex_size_pixels)
    max_view_height = viewstate.fb_height / (min_zoom * hex_size_pixels)

    # Required ship margin at each pan extreme
    margin_fraction = 0.1f0
    margin_x = ship_span_x * margin_fraction
    margin_y = ship_span_y * margin_fraction

    # Union of the extreme reachable viewport edges
    max_right = bounds.X_POS - margin_x + max_view_width
    min_left = bounds.X_NEG + margin_x - max_view_width
    max_top = bounds.Y_POS - margin_y + max_view_height
    min_bottom = bounds.Y_NEG + margin_y - max_view_height

    return (X_POS = Float64(max_right), X_NEG = Float64(min_left), Y_POS = Float64(max_top), Y_NEG = Float64(min_bottom))
end

"Create a fresh tile-placement session at `component_index`."
function new_tile_placement_state(component_index::Int = 1)::PlacementTileState
    checkbounds(component_list, component_index)
    return PlacementTileState(
        component_index = component_index,
        pendingcomponent = component_list[component_index],
    )
end

"Enter a fresh tile-placement session, or leave the currently active one."
function toggle_tile_placement_state!(inputstate::InputState)::Bool
    placement_state(inputstate) isa PlacementTileState && return enter_ready_placement_state!(inputstate)
    return enter_editor_placement_state!(inputstate, new_tile_placement_state())
end

"Cycle the active tile-placement component while preserving rotation and mirroring."
function cycle_tile_component!(state::PlacementTileState, step::Int)
    index = mod1(state.component_index + step, length(component_list))
    state.component_index = index
    state.pendingcomponent = component_list[index]
    return nothing
end

"Change Editor Mode, restoring normal placement behaviour when disabling it."
function set_editor_mode!(inputstate::InputState, enabled::Bool)
    inputstate.editor_mode = enabled
    if !enabled
        state = placement_state(inputstate)
        if state isa AbstractEditorPlacementState
            enter_ready_placement_state!(inputstate)
        elseif state isa PlacementPipeChainState
            state.pipe_behavior = ScrapPipeBehav()
        end
    end

    return nothing
end

"Handle action-key edges for placement tools, application modes, and simulation controls."
function poll_keys!(inputstate::InputState, shared_state::FlowCalculatorSharedState, window::GLFW.Window)
    state = placement_state(inputstate)

    # Placement-tool rotation and mirroring (R/F)
    if state isa PlacementTileState && get_inrising!(inputstate, GLFW.KEY_R, window)
        state.toolrotation = next_enum_val(state.toolrotation)
    end

    if get_inrising!(inputstate, GLFW.KEY_F, window)
        if state isa PlacementTileState
            state.toolmirrored = !state.toolmirrored
        elseif state isa PlacementMoveState
            set_placement_state!(
                inputstate, PlacementMoveState(
                    move_target = state.move_target,
                    drag_reference_axis = state.drag_reference_axis,
                    toolrotation = state.toolrotation,
                    toolmirrored = !state.toolmirrored,
                )
            )
            state = placement_state(inputstate)
        end
    end

    # Escape prioritises world interactions over application overlays
    if get_inrising!(inputstate, GLFW.KEY_ESCAPE, window)
        if handle_world_escape!(inputstate)
            # World interactions consume Escape before space-map and pause-menu handling.
        elseif inputstate.spacemap_active
            time_prog = get(inputstate.gui_inputs, :time_progressing, false)::Bool
            if time_prog
                current_time = get(inputstate.gui_inputs, :current_spacemap_time, 0.0)::Float64
                @atomic :monotonic shared_state.target_spacemap_time = current_time
            else
                inputstate.spacemap_active = false
            end
        else
            inputstate.escape_menu_active = !inputstate.escape_menu_active
        end
    end

    # Pause, application overlays, and Editor Mode (Space, Backslash, Grave, M)
    if get_inrising!(inputstate, GLFW.KEY_SPACE, window)
        current_paused = @atomic :monotonic shared_state.is_paused
        @atomic :monotonic shared_state.is_paused = !current_paused
    end

    get_inrising!(inputstate, GLFW.KEY_BACKSLASH, window) && (inputstate.dev_utils_menu_active = !inputstate.dev_utils_menu_active)
    get_inrising!(inputstate, GLFW.KEY_GRAVE_ACCENT, window) && set_editor_mode!(inputstate, !inputstate.editor_mode)
    if get_inrising!(inputstate, GLFW.KEY_M, window)
        time_prog = get(inputstate.gui_inputs, :time_progressing, false)::Bool
        galaxy_escape_active = get(inputstate.gui_inputs, :galaxy_escape_active, false)::Bool
        if !time_prog && !galaxy_escape_active
            inputstate.spacemap_active = !inputstate.spacemap_active
        end
    end

    # Editor-only tools (4–6)
    if editor_capabilities_enabled(inputstate)
        get_inrising!(inputstate, GLFW.KEY_4, window) && toggle_editor_placement_state!(inputstate, PlacementDeleteState())
        get_inrising!(inputstate, GLFW.KEY_5, window) && toggle_tile_placement_state!(inputstate)
        get_inrising!(inputstate, GLFW.KEY_6, window) && toggle_editor_placement_state!(inputstate, PlacementSurfaceEditState())
    end

    # Simulation speed ([ and ])
    if get_inrising!(inputstate, GLFW.KEY_RIGHT_BRACKET, window)
        inputstate.sim_speed = increase_sim_speed(inputstate.sim_speed)
        @atomic :monotonic shared_state.target_ups = sim_speed_to_ups(inputstate.sim_speed)
    end

    if get_inrising!(inputstate, GLFW.KEY_LEFT_BRACKET, window)
        inputstate.sim_speed = decrease_sim_speed(inputstate.sim_speed)
        @atomic :monotonic shared_state.target_ups = sim_speed_to_ups(inputstate.sim_speed)
    end

    # F12 capture controls: screenshot when idle, start recording with Shift, stop recording while active
    if get_inrising!(inputstate, GLFW.KEY_F12, window)
        if inputstate.is_recording
            inputstate.is_recording = false
        else
            shift_held = get_instate(GLFW.KEY_LEFT_SHIFT, window) || get_instate(GLFW.KEY_RIGHT_SHIFT, window)
            if shift_held
                inputstate.is_recording = true
            else
                inputstate.screenshot_requested = true
            end
        end
    end

    # Tile component cycling (Z/C) wraps around while the tool is active
    if state isa PlacementTileState
        get_inrising!(inputstate, GLFW.KEY_Z, window) && cycle_tile_component!(state, -1)
        get_inrising!(inputstate, GLFW.KEY_C, window) && cycle_tile_component!(state, 1)
    end

    return nothing
end

"Poll the cursor and update its map-space position."
function poll_cursorpos!(inputstate::InputState, viewstate::ViewState, window::GLFW.Window)
    x, y = GLFW.GetCursorPos(window)

    if !isfinite(x) || !isfinite(y) || viewstate.window_width <= 0 || viewstate.window_height <= 0
        inputstate.cursor_x = nothing
        inputstate.cursor_y = nothing
        return nothing
    end

    # Convert cursor coordinates from window space to framebuffer space (handles Retina/HiDPI displays)
    fb_scale_x = viewstate.fb_width / viewstate.window_width
    fb_scale_y = viewstate.fb_height / viewstate.window_height
    x_fb = x * fb_scale_x
    y_fb = y * fb_scale_y

    # Flip Y coordinate and centre, then transform to map space
    y_origin = viewstate.fb_height - y_fb
    xy = @SVector [(x_fb - viewstate.fb_width / 2), (y_origin - viewstate.fb_height / 2)]
    view_offset = @SVector [viewstate.view_x, viewstate.view_y]
    xy_cartesian = ((xy ./ hex_size_pixels) ./ viewstate.view_zoom) - view_offset

    if !all(isfinite, xy_cartesian)
        inputstate.cursor_x = nothing
        inputstate.cursor_y = nothing
        return nothing
    end

    inputstate.cursor_x = xy_cartesian[1]
    inputstate.cursor_y = xy_cartesian[2]

    return nothing
end

"Convert a world-space position to window-space pixels."
function world_to_screen(world_x::Float64, world_y::Float64, viewstate::ViewState)
    # Apply pan, zoom, and scale to framebuffer pixels (inverse of cursor transform)
    x_fb = (world_x + Float64(viewstate.view_x)) * Float64(viewstate.view_zoom) * hex_size_pixels + Float64(viewstate.fb_width) / 2.0
    y_fb = Float64(viewstate.fb_height) / 2.0 - (world_y + Float64(viewstate.view_y)) * Float64(viewstate.view_zoom) * hex_size_pixels

    # Framebuffer → window coords (handles HiDPI)
    fb_scale_x = Float64(viewstate.fb_width) / Float64(viewstate.window_width)
    fb_scale_y = Float64(viewstate.fb_height) / Float64(viewstate.window_height)
    return (x_fb / fb_scale_x, y_fb / fb_scale_y)
end

"Update window and framebuffer dimensions, including the OpenGL viewport."
function poll_windowstate!(viewstate::ViewState, window::GLFW.Window)
    wsize = GLFW.GetWindowSize(window)
    if viewstate.window_width != wsize.width || viewstate.window_height != wsize.height
        viewstate.window_width = wsize.width
        viewstate.window_height = wsize.height
    end
    fbsize = GLFW.GetFramebufferSize(window)
    if viewstate.fb_width != fbsize.width || viewstate.fb_height != fbsize.height
        viewstate.fb_width = fbsize.width
        viewstate.fb_height = fbsize.height
        ModernGL.glViewport(0, 0, viewstate.fb_width, viewstate.fb_height) # Keep the viewport synchronised
    end
    return nothing
end

"Apply scroll-wheel zoom while keeping the world point beneath the cursor fixed."
function poll_scrollwheel_zoom!(
        inputstate::InputState, viewstate::ViewState,
        cimgui_io::Union{Nothing, Ptr{CImGui.lib.ImGuiIO}} = nothing
    )
    _, yoff = take_scrollstate!()
    yoff == 0.0 && return nothing

    # Don't zoom when mouse is over an ImGui window
    if !isnothing(cimgui_io) && unsafe_load(cimgui_io.WantCaptureMouse)
        return nothing
    end

    # Exponential zoom: scroll up = zoom in, scroll down = zoom out
    scroll_zoom_sensitivity = 0.2
    zoom_old = viewstate.view_zoom
    viewstate.view_zoom *= exp(scroll_zoom_sensitivity * yoff)

    # Clamp zoom before computing cursor-centred offset, so the pan adjustment
    # uses the actual final zoom value (avoids cursor jump at zoom limits)
    apply_view_limits!(viewstate)

    #= Cursor-centred zoom: adjust pan so the world point under the cursor stays stationary.
    From the screen-to-world transform: world = screen / (hsp * zoom) - view_offset
    Invariant: the cursor's world position must be the same before and after zoom.
    Solving: view_new = (zoom_old / zoom_new) * (cursor_world + view_old) - cursor_world =#
    if !isnothing(inputstate.cursor_x) && !isnothing(inputstate.cursor_y)
        ratio = Float64(zoom_old) / Float64(viewstate.view_zoom)
        cursor_wx = Float64(inputstate.cursor_x)
        cursor_wy = Float64(inputstate.cursor_y)
        viewstate.view_x = Float32(ratio * (cursor_wx + Float64(viewstate.view_x)) - cursor_wx)
        viewstate.view_y = Float32(ratio * (cursor_wy + Float64(viewstate.view_y)) - cursor_wy)
    end

    apply_view_limits!(viewstate) # re-apply for the adjusted pan values
    return nothing
end

"Pan with middle-button dragging while anchoring the world point beneath the cursor."
function poll_middleclick_pan!(viewstate::ViewState, inputstate::InputState, window::GLFW.Window)
    middle_pressed = get_instate(GLFW.MOUSE_BUTTON_MIDDLE, window)

    if !middle_pressed
        viewstate.pan_drag_anchor = nothing
        return nothing
    end

    # Start drag: record the world position under the cursor as the anchor
    if isnothing(viewstate.pan_drag_anchor)
        if isnothing(inputstate.cursor_x) || isnothing(inputstate.cursor_y)
            return nothing
        end
        viewstate.pan_drag_anchor = SVector{2, Float64}(inputstate.cursor_x, inputstate.cursor_y)
    end

    #= Recompute view offset so the anchor stays under the cursor (runs on drag-start frame too).
    Uses raw GLFW cursor position to avoid circular dependency with poll_cursorpos!. =#
    x, y = GLFW.GetCursorPos(window)
    if !isfinite(x) || !isfinite(y) || viewstate.window_width <= 0 || viewstate.window_height <= 0
        return nothing
    end

    fb_scale_x = viewstate.fb_width / viewstate.window_width
    fb_scale_y = viewstate.fb_height / viewstate.window_height
    x_fb = x * fb_scale_x
    y_fb = y * fb_scale_y
    y_origin = viewstate.fb_height - y_fb
    screen_x = Float64(x_fb - viewstate.fb_width / 2)
    screen_y = Float64(y_origin - viewstate.fb_height / 2)

    # From: cursor_world = screen / (hsp * zoom) - view_offset
    # Rearranging: view_offset = screen / (hsp * zoom) - anchor
    hex_size_pixels = 256.0
    anchor_x, anchor_y = viewstate.pan_drag_anchor
    viewstate.view_x = Float32(screen_x / (hex_size_pixels * Float64(viewstate.view_zoom)) - anchor_x)
    viewstate.view_y = Float32(screen_y / (hex_size_pixels * Float64(viewstate.view_zoom)) - anchor_y)

    apply_view_limits!(viewstate)
    return nothing
end

"Poll per-frame input in dependency order, respecting CImGui keyboard and mouse capture."
function handle_inputs!(inputstate::InputState, viewstate::ViewState, shared_state::FlowCalculatorSharedState, window::GLFW.Window, cimgui_io::Union{Nothing, Ptr{CImGui.lib.ImGuiIO}} = nothing)
    # View input uses the dimensions and cursor position from this frame
    poll_windowstate!(viewstate, window)
    poll_cursorpos!(inputstate, viewstate, window)
    poll_keys!(viewstate, window)
    poll_middleclick_pan!(viewstate, inputstate, window)
    poll_scrollwheel_zoom!(inputstate, viewstate, cimgui_io)

    # Action/mode/pause/exit keys — only when not typing in UI
    if isnothing(cimgui_io) || !unsafe_load(cimgui_io.WantCaptureKeyboard)
        poll_keys!(inputstate, shared_state, window)
    end

    return nothing
end

# ===============================================================
# Hit Testing and Move Rendering
# ===============================================================

"""
Resolve the most specific coordinate beneath the cursor, preferring vertices and tile-side pipes.

Use `get_clicked_pipe` instead when detecting placed pipes of any span class.
"""
function get_clicked(inputstate::InputState)
    # Reject unavailable or invalid cursor positions
    if isnothing(inputstate.cursor_x) || isnothing(inputstate.cursor_y)
        return nothing
    end
    if !isfinite(inputstate.cursor_x) || !isfinite(inputstate.cursor_y)
        return nothing
    end

    # Prefer small vertex and pipe hit regions over the containing tile
    noderange = 0.15 # Acceptable distance to node
    edgerange = 0.15 # Acceptable distance to pipe

    cursor_cart = CartesianCoord(inputstate.cursor_x, inputstate.cursor_y)
    close_vertex = closest_vertex(cursor_cart)
    vertex_cart = to_cartesian(close_vertex)

    if norm(cursor_cart .- vertex_cart) <= noderange
        return close_vertex
    end

    side = round_to_side_pipe(cursor_cart)
    dist_to_pipe = point_to_segment_distance(cursor_cart, to_cartesian(side.v1), to_cartesian(side.v2))
    if dist_to_pipe <= edgerange
        return side
    end

    # Fall back to the tile containing the cursor
    return round_to_tile(cursor_cart)
end

"Return the shortest distance from a point to a line segment."
function point_to_segment_distance(p::CartesianCoord, a::CartesianCoord, b::CartesianCoord)::Float64
    ab = b .- a
    ap = p .- a
    len_sq = ab[1]^2 + ab[2]^2
    len_sq == 0.0 && return norm(ap) # degenerate segment
    t = clamp(dot(ap, ab) / len_sq, 0.0, 1.0)
    closest = a .+ t .* ab
    return norm(p .- closest)
end

"Render the MOVE overlay path between two coordinates, with optional source marker and dash trail."
function render_move_arrow_overlay!(
        queue::Vector{<:RenderCommand},
        glmap::GLObjectMap,
        gameticks::Int64,
        start_coord,
        end_coord;
        draw_start_marker::Bool = true,
        draw_dashes::Bool = true,
        colour = SVector{4, Float32}(0.8, 0.8, 0.2, 1.0),
        draw_height::Int32 = Int32(100200),
        start_marker_scale::Float64 = 1.0
    )
    start_vec = glvec(start_coord)
    end_vec = glvec(end_coord)
    linevec = end_vec - start_vec
    line_length = norm(linevec)
    angle = line_length == 0 ? 0.0f0 : rad2deg(atan(-linevec[2], linevec[1]))

    if draw_start_marker
        push!(queue, render_basic_sprite(glmap, :MoveArrow_arrow_start, rotmat_2D(0.0), start_coord; colour = colour, draw_height = draw_height, scale = start_marker_scale))
    end

    push!(queue, render_basic_sprite(glmap, :MoveArrow_arrow_head, rotmat_2D(angle), end_coord; colour = colour, draw_height = draw_height))

    dash_spacing = 0.5f0
    animation_speed = 0.03f0
    end_fade_distance = 0.2f0
    if draw_dashes && line_length > dash_spacing * 0.5
        anim_offset_units = (gameticks * animation_speed) % dash_spacing
        anim_offset_param = anim_offset_units / line_length
        dash_step = dash_spacing / line_length
        fade_boundary = 1.0 - (end_fade_distance / line_length)

        for t in anim_offset_param:dash_step:(fade_boundary - dash_step * 0.01)
            dash_pos_vec = start_vec + t * linevec
            dash_pos = CartesianCoord(dash_pos_vec[1], dash_pos_vec[2])
            push!(queue, render_basic_sprite(glmap, :MoveArrow_dash, rotmat_2D(angle), dash_pos; colour = colour, draw_height = draw_height))
        end
    end

    return nothing
end

# ===============================================================
# PIPE Chain Helpers
# ===============================================================

"Resolve a PIPE source node from the current click. Only explicit node clicks start chaining."
function resolve_pipe_source_node(inputstate::InputState)::Union{Nothing, VertexCoord}
    element = get_clicked(inputstate)
    element isa VertexCoord || return nothing
    return to_proper(element)
end

"Return whether a resolved PIPE source node belongs to a ship currently rendered with an offset."
function is_pipe_source_on_offset_ship(source_vertex::VertexCoord, gamemap::GameMap)::Bool
    node = to_nodecoord(source_vertex)
    ship_name = find_ship_for_node(node, gamemap; default = nothing)
    isnothing(ship_name) && return false
    return get_ship_render_offset(gamemap, ship_name) != AxialCoord(0.0, 0.0)
end

"Return whether deleting an existing pipe segment is allowed under current off-ship rules."
function can_delete_pipe_segment(pipe::PipeCoord, gamemap::GameMap)::Bool
    v1_on = is_node_on_any_ship_surface(to_nodecoord(pipe.v1), gamemap)
    v2_on = is_node_on_any_ship_surface(to_nodecoord(pipe.v2), gamemap)
    is_offship = !(v1_on && v2_on)
    return !is_offship || validate_offship_pipe_deletion(pipe, gamemap)
end

"Return a request status indicating whether a new pipe segment can be placed under the current on-surface or off-ship rules."
function can_place_pipe_segment(pipe::PipeCoord, gamemap::GameMap)::RequestStatus
    target_ship = find_ship_containing(pipe, gamemap)
    if !isnothing(target_ship)
        return can_place_pipe_at(pipe, gamemap; ship_name = target_ship)
    end

    offship_result = can_place_pipe_offship(pipe, gamemap)
    isvalidrequest(offship_result) && return ValidRequest()
    return offship_result
end

"Resolve the existing pipe segment currently targeted by the cursor."
function resolve_pipe_target_from_cursor(inputstate::InputState, gamemap::GameMap)::Union{Nothing, PipeCoord}
    cursor_cart = get_cursor_cart(inputstate)
    isnothing(cursor_cart) && return nothing
    return get_clicked_pipe(cursor_cart, gamemap)
end

"Resolve the candidate pipe segment currently targeted by the cursor."
function resolve_pipe_destination_from_cursor(inputstate::InputState)::Union{Nothing, PipeCoord}
    cursor_cart = get_cursor_cart(inputstate)
    isnothing(cursor_cart) && return nothing
    return nearest_pipe_segment_from_vertex(closest_vertex(cursor_cart), cursor_cart)
end

"Collect the twelve concrete PIPE candidates incident to the active source node."
function collect_pipe_chain_candidates(state::PlacementPipeChainState, gamemap::GameMap)
    candidates = NamedTuple[]
    source = to_proper(state.source_node)

    for pipe in get_pipe_segments(source)
        far_node = pipe.v1 == source ? pipe.v2 : pipe.v1
        existing_pipe = get_pipe(gamemap, pipe)

        if !isnothing(existing_pipe)
            push!(
                candidates, (
                    pipe_coord = pipe,
                    far_node = far_node,
                    ghost_payload = existing_pipe,
                    preview_valid = can_delete_pipe_segment(pipe, gamemap),
                    commit_kind = :delete,
                )
            )
            continue
        end

        push!(
            candidates, (
                pipe_coord = pipe,
                far_node = far_node,
                ghost_payload = state.pipe_behavior,
                preview_valid = isvalidrequest(can_place_pipe_segment(pipe, gamemap)),
                commit_kind = :place,
            )
        )
    end

    return candidates
end

"Resolve the currently active PIPE candidate from the cursor direction around the selected source node."
function get_active_pipe_chain_candidate(state::PlacementPipeChainState, inputstate::InputState, gamemap::GameMap)
    cursor_pos = get_cursor_cart(inputstate)
    isnothing(cursor_pos) && return nothing

    target_pipe = nearest_pipe_segment_from_vertex(state.source_node, cursor_pos)

    for candidate in collect_pipe_chain_candidates(state, gamemap)
        if candidate.pipe_coord == target_pipe
            return candidate
        end
    end

    return nothing
end

"Advance or clear PIPE chaining state when the calculator reports a queued command's result."
function poll_pipe_chain_response!(inputstate::InputState)
    state = placement_state(inputstate)
    state isa PlacementPipeChainState || return nothing

    channel = state.pending_response_channel
    isnothing(channel) && return nothing
    isready(channel) || return nothing

    status = take!(channel)
    if status == APPLIED
        next_source = something(state.pending_next_source_node, state.source_node)
        set_placement_state!(
            inputstate, PlacementPipeChainState(
                source_node = next_source,
                pipe_behavior = state.pipe_behavior,
            )
        )
    else
        set_placement_state!(
            inputstate, PlacementPipeChainState(
                source_node = state.source_node,
                pipe_behavior = state.pipe_behavior,
            )
        )
    end
    return nothing
end

"Build the map-edit command for the active PIPE candidate."
function create_pipe_chain_command(
        command_queue::CommandQueue,
        state::PlacementPipeChainState,
        candidate;
        response_channel::Union{Nothing, Channel} = nothing
    )
    if candidate.commit_kind === :delete
        return create_delete_elements_command(command_queue, candidate.pipe_coord; response_channel = response_channel)
    end

    return create_set_pipe_behavior_command(
        command_queue,
        candidate.pipe_coord,
        state.pipe_behavior;
        response_channel = response_channel,
    )
end

# ===============================================================
# MOVE Interaction Helpers
# ===============================================================

"Return the current cursor position as a CartesianCoord, or `nothing` when unavailable."
function get_cursor_cart(inputstate::InputState)::Union{Nothing, CartesianCoord}
    if isnothing(inputstate.cursor_x) || isnothing(inputstate.cursor_y)
        return nothing
    end
    if !isfinite(inputstate.cursor_x) || !isfinite(inputstate.cursor_y)
        return nothing
    end
    return CartesianCoord(inputstate.cursor_x, inputstate.cursor_y)
end

"Resolve the editable map target under the cursor, preferring real pipes over tile components."
function resolve_edit_target_from_cursor(inputstate::InputState, gamemap::GameMap)::Union{Nothing, TileCoord, PipeCoord}
    cursor_cart = get_cursor_cart(inputstate)
    isnothing(cursor_cart) && return nothing

    pipe = get_clicked_pipe(cursor_cart, gamemap)
    !isnothing(pipe) && return pipe

    tile = round_to_tile(cursor_cart)
    has_component(gamemap, tile) || return nothing
    return tile
end

"Return the snapped hex axis nearest the cursor around a tile centre."
function nearest_tile_rotation_axis(cursor_cart::CartesianCoord, tile::TileCoord)::HexAxis
    tile_centre = to_cartesian(tile)
    direction = to_axial(cursor_cart) - to_axial(tile_centre)
    return nearest_hex_axis(direction)
end

"Resolve the current MOVE hover target under the cursor without validating mobility."
function get_move_hover_target(inputstate::InputState, gamemap::GameMap)
    target = resolve_edit_target_from_cursor(inputstate, gamemap)
    isnothing(target) && return nothing
    is_on_offset_ship(target, gamemap) && return nothing

    if target isa TileCoord
        tilecomp = get_component(gamemap, target)
        isnothing(tilecomp) && return nothing
        return (; coord = target, kind = :tile_component)
    end

    pipe_behav = get_pipe(gamemap, target)
    isnothing(pipe_behav) && return nothing
    return (; coord = target, kind = :pipe)
end

"Record a pending MOVE hold on the current target and clear any stale popup state."
function set_move_hold_target!(inputstate::InputState, target)::Bool
    cursor_cart = get_cursor_cart(inputstate)
    isnothing(cursor_cart) && return false
    click_tile = round_to_tile(cursor_cart)

    component_sources = selected_component_coords(inputstate)
    pipe_sources = selected_pipe_coords(inputstate)
    is_selected = target.kind === :tile_component ? target.coord in component_sources : target.coord in pipe_sources
    is_group_move = selected_element_count(inputstate) >= 2 && is_selected

    move_target = if is_group_move
        dismiss_action_popup!(inputstate)
        SelectionMoveTarget(component_sources, pipe_sources, target.coord, round_to_tile(cursor_cart))
    elseif target.kind === :tile_component
        is_selected ? dismiss_action_popup!(inputstate) : clear_world_selection!(inputstate)
        TileComponentMoveTarget(target.coord)
    else
        is_selected ? dismiss_action_popup!(inputstate) : clear_world_selection!(inputstate)
        PipeMoveTarget(target.coord)
    end

    set_placement_state!(
        inputstate, PlacementPressedState(
            press_started_at = time(),
            press_cursor_cart = cursor_cart,
            click_tile = click_tile,
            move_target = move_target,
        )
    )
    return true
end


"Return the group translation implied by the current cursor position."
function selection_move_translation(move_target::SelectionMoveTarget, cursor_cart::CartesianCoord)::TileCoord
    return round_to_tile(cursor_cart) - move_target.press_reference_tile
end

"Promote the pending MOVE hold into an active drag selection."
function activate_move_drag!(inputstate::InputState)
    state = placement_state(inputstate)
    state isa PlacementPressedState || return nothing
    move_target = state.move_target
    isnothing(move_target) && return nothing

    reference_axis = if move_target isa TileComponentMoveTarget
        nearest_tile_rotation_axis(state.press_cursor_cart, move_target.coord)
    else
        nothing
    end

    set_placement_state!(
        inputstate, PlacementMoveState(
            move_target = move_target,
            drag_reference_axis = reference_axis,
            toolrotation = HexFrame.Q_POS,
            toolmirrored = false,
        )
    )
    return nothing
end

"Update MOVE tile rotation from the current cursor position while an active drag is in progress."
function update_active_move_rotation!(inputstate::InputState)
    state = placement_state(inputstate)
    state isa PlacementMoveState || return nothing
    state.move_target isa TileComponentMoveTarget || return nothing
    isnothing(state.drag_reference_axis) && return nothing

    cursor_cart = get_cursor_cart(inputstate)
    isnothing(cursor_cart) && return nothing

    destination = round_to_tile(cursor_cart)
    current_axis = nearest_tile_rotation_axis(cursor_cart, destination)
    set_placement_state!(
        inputstate, PlacementMoveState(
            move_target = state.move_target,
            drag_reference_axis = state.drag_reference_axis,
            toolrotation = rotate(current_axis, rotate_reverse(state.drag_reference_axis)),
            toolmirrored = state.toolmirrored,
        )
    )
    return nothing
end

"Create an INSPECT-style click command from the stored MOVE short-click press site."
function create_move_short_click_command(command_queue::CommandQueue, inputstate::InputState, gamemap::GameMap)
    state = placement_state(inputstate)
    state isa PlacementPressedState || return nothing
    hold_coord = state.click_tile
    hold_coord isa TileCoord || return nothing
    has_component(gamemap, hold_coord) || return nothing

    tile_center_cart = to_cartesian(hold_coord)
    unrotated_clicksite = state.press_cursor_cart - tile_center_cart
    return create_click_tile_command(command_queue, hold_coord, unrotated_clicksite)
end

"""
Return deliberately approximate render-snapshot validity for active MOVE ghost colouring only.

A false result must not prevent the release command from being created or enqueued.
"""
function can_preview_active_move(inputstate::InputState, gamemap::GameMap)::Bool
    state = placement_state(inputstate)
    state isa PlacementMoveState || return false

    cursor_cart = get_cursor_cart(inputstate)
    isnothing(cursor_cart) && return false

    if state.move_target isa TileComponentMoveTarget
        # Tile-component destination and orientation
        selected = state.move_target.coord
        tilecomp = get_component(gamemap, selected)
        isnothing(tilecomp) && return false

        new_rotation = map_rotation(tilecomp, rotate(tilecomp.rotation, state.toolrotation))
        requested_mirror = xor(tilecomp.mirrored, state.toolmirrored)
        new_mirrored = map_mirroring(tilecomp, requested_mirror)
        destination = round_to_tile(cursor_cart)

        if destination == selected
            rotated_comptile = PlacedComponent(tilecomp.component, new_rotation, new_mirrored, tilecomp.ship)
            return isvalidrequest(placement_valid(rotated_comptile, selected, gamemap; ship_name = tilecomp.ship))
        end

        has_component(gamemap, destination) && return false
        has_pipe_component_conflict(destination, gamemap) && return false
        placement = find_ship_for_placement(
            tilecomp.component, destination, gamemap;
            rotation = new_rotation, mirrored = new_mirrored
        )
        return isvalidrequest(placement)
    elseif state.move_target isa PipeMoveTarget
        # Pipe destination and mobility
        selected = state.move_target.coord
        destination = resolve_pipe_destination_from_cursor(inputstate)
        isnothing(destination) && return false
        destination == selected && return false

        source_pipe = get_pipe(gamemap, selected)
        isnothing(source_pipe) && return false
        isvalidrequest(can_pipe_be_moved(source_pipe)) || return false
        has_pipe(gamemap, destination) && return false
        return isvalidrequest(can_place_pipe_segment(destination, gamemap))
    elseif state.move_target isa SelectionMoveTarget
        # Group destinations and collisions
        translation = selection_move_translation(state.move_target, cursor_cart)
        translation == TileCoord(0, 0) && return false

        destinations = Set(source + translation for source in state.move_target.component_coords)
        pipe_destinations = Set(offset_by_tile(source, translation) for source in state.move_target.pipe_coords)
        any(destination -> has_component(gamemap, destination) && destination ∉ state.move_target.component_coords, destinations) && return false
        any(destination -> has_pipe(gamemap, destination) && destination ∉ state.move_target.pipe_coords, pipe_destinations) && return false

        for source in state.move_target.component_coords
            component = get_component(gamemap, source)
            isnothing(component) && return false
            isvalidrequest(can_be_moved(component)) || return false

            destination = source + translation
            for pipe in get_pipe_segments(destination)
                get_tile_containing_pipe(pipe) == destination || continue
                has_pipe(gamemap, pipe) && pipe ∉ state.move_target.pipe_coords && return false
            end
            placement = find_ship_for_placement(
                component.component, destination, gamemap;
                rotation = component.rotation, mirrored = component.mirrored
            )
            isvalidrequest(placement) || return false
        end
        for source in state.move_target.pipe_coords
            pipe = get_pipe(gamemap, source)
            isnothing(pipe) && return false
            isvalidrequest(can_pipe_be_moved(pipe)) || return false
        end
        for destination in pipe_destinations
            tile = get_tile_containing_pipe(destination)
            !isnothing(tile) && (tile in destinations || (has_component(gamemap, tile) && tile ∉ state.move_target.component_coords)) && return false
        end
        return true
    end

    return false
end

"Build the current active MOVE command, or return `nothing` when the release should cancel."
function create_active_move_command(
        command_queue::CommandQueue, inputstate::InputState;
        response_channel::Union{Nothing, Channel} = nothing,
    )
    state = placement_state(inputstate)
    state isa PlacementMoveState || return nothing
    cursor_cart = get_cursor_cart(inputstate)
    if isnothing(cursor_cart)
        return nothing
    end

    if state.move_target isa TileComponentMoveTarget
        selected = state.move_target.coord
        destination = round_to_tile(cursor_cart)
        return create_move_command(
            command_queue, selected, destination, state.toolrotation, state.toolmirrored;
            response_channel = response_channel
        )
    elseif state.move_target isa PipeMoveTarget
        selected = state.move_target.coord
        destination = resolve_pipe_destination_from_cursor(inputstate)
        isnothing(destination) && return nothing
        return create_move_command(
            command_queue, selected, destination, state.toolrotation, state.toolmirrored;
            response_channel = response_channel
        )
    elseif state.move_target isa SelectionMoveTarget
        translation = selection_move_translation(state.move_target, cursor_cart)
        translation == TileCoord(0, 0) && return nothing
        return create_translate_elements_command(
            command_queue, state.move_target.component_coords, state.move_target.pipe_coords, translation;
            response_channel = response_channel
        )
    end

    return nothing
end


"Build the pending placement state for an active move."
function pending_move_state(inputstate::InputState, response_channel::Channel)
    state = placement_state(inputstate)::PlacementMoveState
    move_target = state.move_target
    original_selection = selection_state(inputstate)

    if move_target isa SelectionMoveTarget
        translation = selection_move_translation(move_target, get_cursor_cart(inputstate))
        component_destinations = Set(source + translation for source in move_target.component_coords)
        pipe_destinations = Set(offset_by_tile(source, translation) for source in move_target.pipe_coords)
        return PlacementMovePendingState(
            response_channel = response_channel,
            original_selection = original_selection,
            translated_selection = translate_selection(original_selection, translation),
            expected_component_sources = copy(move_target.component_coords),
            expected_component_destinations = component_destinations,
            expected_pipe_sources = copy(move_target.pipe_coords),
            expected_pipe_destinations = pipe_destinations,
        )
    elseif move_target isa TileComponentMoveTarget
        destination = round_to_tile(get_cursor_cart(inputstate))
        moved_selection = has_selected_component(inputstate, move_target.coord) ?
            WorldSelectionState(Set((destination,)), Set{PipeCoord}()) : SelectionEmptyState()
        return PlacementMovePendingState(
            response_channel = response_channel,
            original_selection = original_selection,
            translated_selection = moved_selection,
            expected_component_sources = Set((move_target.coord,)),
            expected_component_destinations = Set((destination,)),
            expected_pipe_sources = Set{PipeCoord}(),
            expected_pipe_destinations = Set{PipeCoord}(),
        )
    elseif move_target isa PipeMoveTarget
        destination = resolve_pipe_destination_from_cursor(inputstate)
        moved_selection = has_selected_pipe(inputstate, move_target.coord) ?
            WorldSelectionState(Set{TileCoord}(), Set((destination,))) : SelectionEmptyState()
        return PlacementMovePendingState(
            response_channel = response_channel,
            original_selection = original_selection,
            translated_selection = moved_selection,
            expected_component_sources = Set{TileCoord}(),
            expected_component_destinations = Set{TileCoord}(),
            expected_pipe_sources = Set((move_target.coord,)),
            expected_pipe_destinations = Set((destination,)),
        )
    end
    error("Unsupported move target")
end


"Consume calculator move status and apply selection once the committed snapshot is visible."
function poll_move_completion!(inputstate::InputState, gamemap::GameMap)
    state = placement_state(inputstate)
    state isa PlacementMovePendingState || return nothing

    if !state.calculator_applied && isready(state.response_channel)
        status = take!(state.response_channel)
        if status != APPLIED
            inputstate.selection_state = state.original_selection
            set_placement_state!(inputstate, PlacementReadyState())
            return nothing
        end
        state = PlacementMovePendingState(
            response_channel = state.response_channel,
            original_selection = state.original_selection,
            translated_selection = state.translated_selection,
            expected_component_sources = state.expected_component_sources,
            expected_component_destinations = state.expected_component_destinations,
            expected_pipe_sources = state.expected_pipe_sources,
            expected_pipe_destinations = state.expected_pipe_destinations,
            calculator_applied = true,
        )
        set_placement_state!(inputstate, state)
    end

    state.calculator_applied || return nothing
    all(coord -> has_component(gamemap, coord), state.expected_component_destinations) || return nothing
    all(coord -> has_pipe(gamemap, coord), state.expected_pipe_destinations) || return nothing
    all(coord -> coord in state.expected_component_destinations || !has_component(gamemap, coord), state.expected_component_sources) || return nothing
    all(coord -> coord in state.expected_pipe_destinations || !has_pipe(gamemap, coord), state.expected_pipe_sources) || return nothing

    inputstate.selection_state = state.translated_selection
    set_placement_state!(inputstate, PlacementReadyState())
    return nothing
end

# ===============================================================
# Cursor Ghost Rendering
# ===============================================================

const GHOST_COLOUR_VALID = SVector{4, Float32}(1.0, 1.0, 1.0, 1.0)
const GHOST_COLOUR_INVALID = SVector{4, Float32}(1.0, 0.4, 0.4, 1.0)
const GHOST_PIPE_COLOUR_INVALID = ColourType(0.6, 0.15, 0.15, 1.0)
const GHOST_MOVE_SELECTION_COLOUR = SVector{4, Float32}(1.0, 0.9, 0.2, 0.85)
const GHOST_MOVE_SELECTION_HEIGHT_OFFSET = Int32(100100)
const COMPONENT_SELECTION_COLOUR = SVector{4, Float32}(0.3, 1.0, 0.3, 0.4)
const COMPONENT_SELECTION_HEIGHT = Int32(100100)
const COMPONENT_SELECTION_SCALE = 2.5

"Render selection markers and cursor previews for placement, movement, and editing tools."
function render_cursor_ghosts!(queue::Vector{<:RenderCommand}, glmap::GLObjectMap, inputstate::InputState, gamemap::GameMap, gamestate::GameState)
    if isnothing(inputstate.cursor_x) || isnothing(inputstate.cursor_y)
        return nothing
    end

    state = placement_state(inputstate)

    # Redock ghost — show ship footprint and exclusion zone following the cursor
    if state isa PlacementRedockState
        _render_redock_ghost!(queue, glmap, inputstate)
        return nothing # Suppress all other placement ghosts during redock
    end

    # Selected components and pipes
    for selected in selected_component_coords(inputstate)
        push!(
            queue, render_basic_sprite(
                glmap, :MoveArrow_arrow_start, rotmat_2D(0.0), selected;
                colour = COMPONENT_SELECTION_COLOUR, draw_height = COMPONENT_SELECTION_HEIGHT,
                scale = COMPONENT_SELECTION_SCALE,
            )
        )
    end
    for selected in selected_pipe_coords(inputstate)
        pipe = get_pipe(gamemap, selected)
        isnothing(pipe) && continue
        render_pipe_base!(
            queue, pipe; glmap = glmap, rotation = HexFrame.Q_POS, position = selected,
            transparency = 0.6, colour = COMPONENT_SELECTION_COLOUR,
            render_height_offset = COMPONENT_SELECTION_HEIGHT
        )
    end

    if state isa PlacementTileState
        coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
        component = state.pendingcomponent
        rotation = map_rotation(component, state.toolrotation)
        mirrored = map_mirroring(component, state.toolmirrored)
        can_place = !has_component(gamemap, coord) &&
            !has_pipe_component_conflict(coord, gamemap) &&
            isvalidrequest(find_ship_for_placement(component, coord, gamemap; rotation, mirrored))
        ghost_colour = can_place ? GHOST_COLOUR_VALID : GHOST_COLOUR_INVALID
        render_base_elem!(queue, component; glmap = glmap, rotation = rotation, mirrored = mirrored, position = coord, transparency = 0.5, colour = ghost_colour, render_height_offset = Int32(100000))
    end

    if state isa PlacementPipeChainState
        source_vertex = state.source_node

        push!(
            queue, render_basic_sprite(
                glmap, :MoveArrow_arrow_start, rotmat_2D(0.0), source_vertex;
                colour = SVector{4, Float32}(1.0, 0.85, 0.2, 1.0), transparency = 0.5,
                draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_NODE + 50), scale = 0.6,
            )
        )

        candidate = get_active_pipe_chain_candidate(state, inputstate, gamemap)
        if !isnothing(candidate)
            ghost_colour = (candidate.commit_kind === :delete || !candidate.preview_valid) ? GHOST_COLOUR_INVALID : GHOST_COLOUR_VALID
            if !isnothing(candidate.ghost_payload)
                render_pipe_base!(
                    queue, candidate.ghost_payload;
                    glmap = glmap, rotation = HexFrame.Q_POS, position = candidate.pipe_coord,
                    transparency = 0.5, colour = ghost_colour, render_height_offset = Int32(100000),
                )
            end
        end
    end

    if state isa PlacementMoveState
        move_target = state.move_target

        if move_target isa TileComponentMoveTarget
            tilecomp = get_component(gamemap, move_target.coord)
            if !isnothing(tilecomp)
                # Tile-component move ghost
                coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
                rotation = map_rotation(tilecomp, rotate(tilecomp.rotation, state.toolrotation))
                requested_mirror = xor(tilecomp.mirrored, state.toolmirrored)
                mirrored = map_mirroring(tilecomp, requested_mirror)
                ghost_colour = can_preview_active_move(inputstate, gamemap) ? GHOST_COLOUR_VALID : GHOST_COLOUR_INVALID

                render_base_elem!(queue, tilecomp; glmap = glmap, rotation = rotation, mirrored = mirrored, position = coord, transparency = 0.5, colour = ghost_colour, render_height_offset = Int32(100000))

                # Movement path
                render_move_arrow_overlay!(
                    queue, glmap, gamestate.ticks, move_target.coord, coord;
                    draw_start_marker = true,
                    draw_dashes = true,
                    colour = SVector{4, Float32}(0.8, 0.8, 0.2, 1.0),
                    draw_height = Int32(100200),
                    start_marker_scale = 1.0
                )
            end
        elseif move_target isa SelectionMoveTarget
            cursor_cart = get_cursor_cart(inputstate)
            isnothing(cursor_cart) && return nothing
            translation = selection_move_translation(move_target, cursor_cart)
            ghost_colour = can_preview_active_move(inputstate, gamemap) ? GHOST_COLOUR_VALID : GHOST_COLOUR_INVALID

            for source in move_target.component_coords
                component = get_component(gamemap, source)
                isnothing(component) && continue
                render_base_elem!(
                    queue, component;
                    glmap = glmap,
                    rotation = component.rotation,
                    mirrored = component.mirrored,
                    position = source + translation,
                    transparency = 0.5,
                    colour = ghost_colour,
                    render_height_offset = Int32(100000),
                )
            end

            for source in move_target.pipe_coords
                pipe = get_pipe(gamemap, source)
                isnothing(pipe) && continue
                render_pipe_base!(
                    queue, pipe; glmap = glmap, rotation = HexFrame.Q_POS,
                    position = offset_by_tile(source, translation), transparency = 0.5,
                    colour = ghost_colour, render_height_offset = Int32(100000)
                )
            end

            anchor_source = move_target.anchor
            anchor_destination = anchor_source isa TileCoord ?
                anchor_source + translation : offset_by_tile(anchor_source, translation)
            render_move_arrow_overlay!(
                queue, glmap, gamestate.ticks, anchor_source, anchor_destination;
                draw_start_marker = true,
                draw_dashes = true,
                colour = SVector{4, Float32}(0.8, 0.8, 0.2, 1.0),
                draw_height = Int32(100200),
                start_marker_scale = 1.0,
            )
        elseif move_target isa PipeMoveTarget
            actual_pipe = get_pipe(gamemap, move_target.coord)
            if !isnothing(actual_pipe)
                # Pipe move ghost
                ghost_pipe = resolve_pipe_destination_from_cursor(inputstate)
                isnothing(ghost_pipe) && return nothing
                ghost_colour = can_preview_active_move(inputstate, gamemap) ? GHOST_COLOUR_VALID : GHOST_PIPE_COLOUR_INVALID
                render_pipe_base!(
                    queue, actual_pipe; glmap = glmap,
                    rotation = HexFrame.Q_POS, position = ghost_pipe, transparency = 0.5, colour = ghost_colour, render_height_offset = Int32(100000)
                )
                render_pipe_base!(
                    queue, actual_pipe; glmap = glmap,
                    rotation = HexFrame.Q_POS, position = move_target.coord, transparency = 0.75,
                    colour = GHOST_MOVE_SELECTION_COLOUR, render_height_offset = GHOST_MOVE_SELECTION_HEIGHT_OFFSET,
                )

                # Movement path
                render_move_arrow_overlay!(
                    queue, glmap, gamestate.ticks, move_target.coord, ghost_pipe;
                    draw_start_marker = true,
                    draw_dashes = true,
                    colour = SVector{4, Float32}(0.8, 0.8, 0.2, 1.0),
                    draw_height = Int32(100200)
                )
            end
        end
    end

    if state isa PlacementSurfaceEditState
        coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))

        # Surface-edit validity and intent
        existing_ship = get_surface_shiptag(gamemap, coord)
        if !isnothing(existing_ship)
            # Existing surface will be removed
            colour = SVector{4, Float32}(1.0, 0.3, 0.3, 0.5) # Removal
        else
            # New surface must adjoin exactly one ship
            adjacent_ships = find_ships_adjacent_to_coord(gamemap, coord)
            if length(adjacent_ships) == 1
                colour = SVector{4, Float32}(0.3, 1.0, 0.3, 0.5) # Valid addition
            else
                # No adjacent ship or an ambiguous choice
                colour = SVector{4, Float32}(0.5, 0.5, 0.5, 0.3) # Invalid addition
            end
        end

        push!(
            queue, render_basic_tile(
                glmap, :ShipSurface_basic, HexFrame.Q_POS, coord;
                colour = colour,
                transparency = 0.5,
                draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_BACKGROUND + 10)
            )
        )
    end

    if state isa PlacementDeleteState
        indicator_position = resolve_edit_target_from_cursor(inputstate, gamemap)

        if !isnothing(indicator_position)
            push!(
                queue, render_basic_sprite(
                    glmap, :MoveArrow_arrow_start, rotmat_2D(0.0), indicator_position;
                    colour = SVector{4, Float32}(1.0, 0.3, 0.3, 1.0),
                    draw_height = Int32(100200)
                )
            )
        end
    end
    return nothing
end

# ===============================================================
# Docking Beam Rendering
# ===============================================================

"Render tractor beams between the primary ship and other docked ships."
function render_docking_beams!(queue::Vector{<:RenderCommand}, glmap::GLObjectMap, gamemap::GameMap, gameticks::Int64)
    primary_pos = nothing

    for (ship_name, ship) in gamemap.ships
        ship_name == :primary && continue

        status = get_docking_status(ship)

        beam_colour = if status isa ApproachingDockStat
            SVector{4, Float32}(0.2, 0.2, 0.6, 1.0)
        elseif status isa ConnectedDockStat
            SVector{4, Float32}(0.2, 0.6, 0.2, 1.0)
        elseif status isa DepartingDockStat
            SVector{4, Float32}(0.6, 0.2, 0.2, 1.0)
        else
            nothing
        end

        isnothing(beam_colour) && continue

        ship_centroid = get_surface_centroid(gamemap, ship_name)
        isnothing(ship_centroid) && continue
        ship_pos = ship_centroid + get_render_offset(ship)

        if isnothing(primary_pos)
            primary_centroid = get_surface_centroid(gamemap, :primary)
            isnothing(primary_centroid) && return nothing
            primary_pos = primary_centroid + get_ship_render_offset(gamemap, :primary)
        end

        # Connected beams are narrower and steadier
        connected = status isa ConnectedDockStat
        render_beam!(
            queue, glmap, gameticks, primary_pos, ship_pos;
            noise_magnitude = connected ? 0.025 : 0.1,
            scale = connected ? 0.5f0 : 1.0f0,
            colour = beam_colour,
            draw_height = HexFlowRendering.RENDER_HEIGHT_TRACTOR_BEAM
        )
    end

    return nothing
end

# ===============================================================
# Calculator Command Input
# ===============================================================
# These handlers enqueue commands rather than mutating the calculator-owned map.

"Return whether a coordinate belongs to a ship displaced by a visual effect."
function is_on_offset_ship(coord, gamemap::GameMap)::Bool
    if coord isa TileCoord
        ship_name = get_surface_shiptag(gamemap, coord)
        if isnothing(ship_name)
            ship_name = get_component_shiptag(gamemap, coord)
        end
        if !isnothing(ship_name)
            offset = get_ship_render_offset(gamemap, ship_name)
            return offset != AxialCoord(0.0, 0.0)
        end
    elseif coord isa PipeCoord
        ship_name = get_pipe_shiptag(gamemap, coord)
        if !isnothing(ship_name)
            offset = get_ship_render_offset(gamemap, ship_name)
            return offset != AxialCoord(0.0, 0.0)
        end
    elseif coord isa VertexCoord
        node = to_nodecoord(coord)
        ship_name = find_ship_for_node(node, gamemap)
        offset = get_ship_render_offset(gamemap, ship_name)
        return offset != AxialCoord(0.0, 0.0)
    end
    return false
end

"Handle tile-tool cancellation and enqueue requested tile placement."
function flowcalc_tileplacer!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        window::GLFW.Window;
        mouse_captured::Bool = false
    )
    state = placement_state(inputstate)
    state isa PlacementTileState || return nothing

    if get_inrising!(inputstate, GLFW.MOUSE_BUTTON_RIGHT, window)
        inputstate.gui_inputs[:consume_right_click] = true
        enter_ready_placement_state!(inputstate)
        return nothing
    end

    mouse_captured && return nothing

    if !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left)
        return nothing
    end

    coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))

    # Displaced ships are temporarily non-interactive
    if is_on_offset_ship(coord, gamemap)
        return nothing
    end

    command = create_set_tile_command(command_queue, coord, state.pendingcomponent, state.toolrotation, state.toolmirrored)
    try_enqueue_command!(command_queue, command)
    return nothing
end

"Drive the unified placement-state machine for STANDARD mode."
function flowcalc_standard_interaction!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        window::GLFW.Window;
        mouse_captured::Bool = false
    )
    state = placement_state(inputstate)
    if !is_standard_family_state(state)
        return nothing
    end

    poll_pipe_chain_response!(inputstate)

    # A delayed move result must not overwrite a newer selection or gesture.
    state isa PlacementMovePendingState && return nothing

    if is_active_standard_interaction_state(state) && get_inrising!(inputstate, GLFW.MOUSE_BUTTON_RIGHT, window)
        inputstate.gui_inputs[:consume_right_click] = true
        clear_placement_state!(inputstate)
        return nothing
    end

    left_rising = get_inrising!(inputstate, GLFW.MOUSE_BUTTON_LEFT, window)
    left_falling = get_infalling!(inputstate, GLFW.MOUSE_BUTTON_LEFT, window)
    left_held = get_instate(GLFW.MOUSE_BUTTON_LEFT, window)

    shift_held = get_instate(GLFW.KEY_LEFT_SHIFT, window) || get_instate(GLFW.KEY_RIGHT_SHIFT, window)

    # Shift-click selection
    if state isa PlacementReadyState && left_rising && shift_held && !mouse_captured
        dismiss_action_popup!(inputstate)
        cursor_cart = get_cursor_cart(inputstate)
        clicked_pipe = isnothing(cursor_cart) ? nothing : get_clicked_pipe(cursor_cart, gamemap)
        if !isnothing(clicked_pipe) && !is_on_offset_ship(clicked_pipe, gamemap)
            toggle_selected_pipe!(inputstate, clicked_pipe)
            return nothing
        end
        element = get_clicked(inputstate)
        if element isa TileCoord && has_component(gamemap, element) && !is_on_offset_ship(element, gamemap)
            toggle_selected_component!(inputstate, element)
        end
        return nothing
    end

    # Active pipe chain
    if state isa PlacementPipeChainState
        if !isnothing(state.pending_response_channel)
            return nothing
        end

        if mouse_captured || !left_rising
            return nothing
        end

        source_node = state.source_node
        if is_pipe_source_on_offset_ship(source_node, gamemap)
            return nothing
        end

        candidate = get_active_pipe_chain_candidate(state, inputstate, gamemap)
        if isnothing(candidate)
            return nothing
        end

        # Preview validity controls the ghost only. The calculator owns the authoritative
        # rejection and its player-facing feedback against the latest map state.
        response_channel = Channel{CommandStatus}(1)
        command = create_pipe_chain_command(command_queue, state, candidate; response_channel = response_channel)
        isnothing(command) && return nothing

        success = try_enqueue_command!(command_queue, command)
        if success
            set_placement_state!(
                inputstate, PlacementPipeChainState(
                    source_node = source_node,
                    pipe_behavior = state.pipe_behavior,
                    pending_next_source_node = candidate.far_node,
                    pending_response_channel = response_channel,
                )
            )
        end
        return nothing
    end

    # Cancel released gestures when CImGui owns the mouse
    if mouse_captured
        if !(state isa PlacementReadyState) && !left_held
            clear_placement_state!(inputstate)
        end
        return nothing
    end

    # Active or pending move gesture
    if state isa PlacementMoveState
        update_active_move_rotation!(inputstate)

        if left_falling
            response_channel = Channel{CommandStatus}(1)
            command = create_active_move_command(command_queue, inputstate; response_channel = response_channel)
            if !isnothing(command)
                pending_state = pending_move_state(inputstate, response_channel)
                success = try_enqueue_command!(command_queue, command)
                success && set_placement_state!(inputstate, pending_state)
            end
            placement_state(inputstate) isa PlacementMoveState && clear_placement_state!(inputstate)
        end

        return nothing
    end

    if state isa PlacementPressedState
        if !isnothing(state.move_target) && time() - state.press_started_at >= 0.5
            activate_move_drag!(inputstate)
            return nothing
        end

        if left_falling
            command = create_move_short_click_command(command_queue, inputstate, gamemap)
            if !isnothing(command)
                try_enqueue_command!(command_queue, command)
            end
            clear_placement_state!(inputstate)
            return nothing
        end

        if !left_held
            clear_placement_state!(inputstate)
            return nothing
        end

        return nothing
    end

    # Start a pipe chain, move hold, or empty-space press
    if !left_rising
        return nothing
    end

    source_node = resolve_pipe_source_node(inputstate)
    if !isnothing(source_node)
        if !is_pipe_source_on_offset_ship(source_node, gamemap)
            clear_world_selection!(inputstate)
            set_placement_state!(
                inputstate, PlacementPipeChainState(
                    source_node = source_node,
                    pipe_behavior = ScrapPipeBehav(),
                )
            )
        end
        return nothing
    end

    target = get_move_hover_target(inputstate, gamemap)
    if isnothing(target)
        clear_world_selection!(inputstate)
        pressed_element = get_clicked(inputstate)
        if pressed_element isa TileCoord || pressed_element isa PipeCoord
            cursor_cart = get_cursor_cart(inputstate)
            if !isnothing(cursor_cart)
                set_placement_state!(
                    inputstate, PlacementPressedState(
                        press_started_at = time(),
                        press_cursor_cart = cursor_cart,
                        click_tile = round_to_tile(cursor_cart),
                        move_target = nothing,
                    )
                )
            end
        end
        return nothing
    end

    set_move_hold_target!(inputstate, target)
    return nothing
end

"Handle delete-tool cancellation and enqueue the targeted deletion."
function flowcalc_deleteplacer!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        window::GLFW.Window;
        mouse_captured::Bool = false
    )
    state = placement_state(inputstate)
    state isa PlacementDeleteState || return nothing

    if get_inrising!(inputstate, GLFW.MOUSE_BUTTON_RIGHT, window)
        inputstate.gui_inputs[:consume_right_click] = true
        enter_ready_placement_state!(inputstate)
        return nothing
    end

    mouse_captured && return nothing

    if !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left)
        return nothing
    end

    target = resolve_edit_target_from_cursor(inputstate, gamemap)
    isnothing(target) && return nothing

    # Displaced ships are temporarily non-interactive
    if is_on_offset_ship(target, gamemap)
        return nothing
    end

    command = create_delete_elements_command(command_queue, target)
    try_enqueue_command!(command_queue, command)

    return nothing
end

"Handle surface-tool cancellation and enqueue the requested surface edit."
function flowcalc_surfaceeditor!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        window::GLFW.Window;
        mouse_captured::Bool = false
    )
    state = placement_state(inputstate)
    state isa PlacementSurfaceEditState || return nothing

    if get_inrising!(inputstate, GLFW.MOUSE_BUTTON_RIGHT, window)
        inputstate.gui_inputs[:consume_right_click] = true
        enter_ready_placement_state!(inputstate)
        return nothing
    end

    mouse_captured && return nothing

    if !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left)
        return nothing
    end

    coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))

    # Displaced ships are temporarily non-interactive
    if is_on_offset_ship(coord, gamemap)
        return nothing
    end

    # Toggle the surface at the cursor
    foundsurf, _ = is_on_surface_tile_any_ship(coord, gamemap)
    if foundsurf
        command = create_remove_ship_surface_command(command_queue, coord)
    else
        command = create_add_ship_surface_command(command_queue, coord)
    end

    try_enqueue_command!(command_queue, command)
    return nothing
end

# ===============================================================
# Action Popups and Ship Actions
# ===============================================================

"""
Open the action popup for the selected group, component, or ship beneath a right-click.

Node and edge hit regions expose ship actions through gaps between components.
"""
function flowcalc_rightclick_action!(inputstate::InputState, gamemap::GameMap, window::GLFW.Window)
    get(inputstate.gui_inputs, :consume_right_click, false)::Bool && return nothing
    get_inrising!(inputstate, GLFW.MOUSE_BUTTON_RIGHT, window) || return nothing
    state = placement_state(inputstate)
    if !(state isa PlacementReadyState)
        return nothing
    end

    dismiss_action_popup!(inputstate)

    # Resolve the clicked map element
    isnothing(inputstate.cursor_x) && return nothing
    isnothing(inputstate.cursor_y) && return nothing

    cursor_cart = CartesianCoord(inputstate.cursor_x, inputstate.cursor_y)
    element = get_clicked(inputstate)
    tile = round_to_tile(cursor_cart)

    clicked_pipe = get_clicked_pipe(cursor_cart, gamemap)
    if selected_element_count(inputstate) >= 2 && !isnothing(clicked_pipe) && has_selected_pipe(inputstate, clicked_pipe)
        components = selected_component_coords(inputstate)
        pipes = selected_pipe_coords(inputstate)
        inputstate.action_popup = ActionPopupState(
            target = ElementGroupPopupTarget(components, pipes),
            world_position = to_cartesian(clicked_pipe), actions = (),
            window_title = "Actions ($(length(components) + length(pipes)) selected items)",
        )
        return nothing
    end

    # Component or selected-group target
    if element isa TileCoord
        tilecomp = get_component(gamemap, element)
        if !isnothing(tilecomp)
            is_on_offset_ship(element, gamemap) && return nothing
            if has_selected_component(inputstate, element) && selected_element_count(inputstate) > 1
                components = selected_component_coords(inputstate)
                pipes = selected_pipe_coords(inputstate)
                actions = isempty(pipes) ? shared_component_actions(
                        [
                            get_actions(get_component(gamemap, coord))
                            for coord in sort!(collect(components); by = coord -> (coord.q, coord.r))
                        ]
                    ) : ()
                inputstate.action_popup = ActionPopupState(
                    target = ElementGroupPopupTarget(components, pipes),
                    world_position = to_cartesian(element), actions = actions,
                    window_title = "Actions ($(length(components) + length(pipes)) selected items)",
                )
            else
                actions = get_actions(tilecomp)
                select_single_component!(inputstate, element)
                inputstate.action_popup = ActionPopupState(
                    target = ComponentPopupTarget(element), world_position = to_cartesian(element),
                    actions = actions, window_title = "Actions",
                )
            end
            return nothing
        end
    end

    # Ship surface target
    ship_name = get_surface_shiptag(gamemap, tile)
    isnothing(ship_name) && return nothing
    is_on_offset_ship(tile, gamemap) && return nothing

    clear_world_selection!(inputstate)

    actions = get_ship_actions(gamemap, ship_name)
    display_name = safe_ship_display_name(ship_name)

    inputstate.action_popup = ActionPopupState(
        target = ShipPopupTarget(ship_name),
        world_position = cursor_cart,
        actions = actions,
        window_title = "Ship: $(display_name)",
    )
    return nothing
end

"Build the docking actions currently available for a ship."
function get_ship_actions(gamemap::GameMap, ship_name::Symbol)::Tuple
    is_primary = (ship_name === :primary)
    status = get_docking_status(gamemap, ship_name)
    is_connected = status isa ConnectedDockStat

    # Primary-ship and redocking eligibility
    make_primary_action = ActionInfo(
        id = :make_primary,
        label = "Make Primary",
        enabled = !is_primary && is_connected,
        tooltip = is_primary ? "This is already the primary ship" : (!is_connected ? "Ship is not docked" : "Swap this ship to be your primary"),
        confirmation_message = is_primary ? nothing : "Make this your primary ship? The current primary will become a docked ship.",
    )

    redock_action = ActionInfo(
        id = :redock,
        label = "Redock",
        enabled = !is_primary && is_connected,
        tooltip = is_primary ? "Cannot redock the primary ship" : "Choose a new docking position",
    )

    # Departure eligibility and player-facing reason
    departure_status = if !is_primary && is_connected
        check_departure_pipe_connections(gamemap, ship_name)
    else
        nothing
    end
    can_depart = !isnothing(departure_status) && isvalidrequest(departure_status)
    undock_tooltip = if is_primary
        "Cannot undock the primary ship"
    elseif !is_connected
        "Ship is not docked"
    elseif departure_status isa InvalidRequest
        reason(departure_status)
    else
        "Undock and depart this ship"
    end
    undock_action = ActionInfo(
        id = :undock,
        label = "Undock",
        enabled = !is_primary && is_connected && can_depart,
        tooltip = undock_tooltip,
        confirmation_message = !is_primary && is_connected && can_depart ? "Undock this ship? It will depart along its docking axis." : nothing,
    )

    return (make_primary_action, redock_action, undock_action)
end

"Execute a ship action on the render thread, entering redock mode or queuing a map override."
function execute_ship_action!(;
        ship_name::Symbol,
        action_id::Symbol,
        command_queue::CommandQueue,
        gamemap::GameMap,
        viewstate::ViewState,
        inputstate::InputState
    )
    if action_id === :make_primary
        current_map = deepcopy(gamemap)
        success, reason = swap_primary!(current_map, ship_name)
        if success
            cmd = create_map_override_command(command_queue, current_map)
            return try_enqueue_command!(command_queue, cmd)
        else
            snapshot_status = typeof(get_docking_status(current_map, ship_name))
            @warn "Enabled ship action failed" ship_name = ship_name action_id = action_id snapshot_status = snapshot_status reason = reason
            return false
        end

    elseif action_id === :redock
        _enter_redock_mode!(inputstate, gamemap, ship_name)
        return true

    elseif action_id === :undock
        current_map = deepcopy(gamemap)
        max_bounds = calc_max_reachable_bounds(viewstate)
        success, reason = depart_ship!(current_map, ship_name; max_view_bounds = max_bounds)
        if success
            cmd = create_map_override_command(command_queue, current_map)
            return try_enqueue_command!(command_queue, cmd)
        else
            snapshot_status = typeof(get_docking_status(current_map, ship_name))
            @warn "Enabled ship action failed" ship_name = ship_name action_id = action_id snapshot_status = snapshot_status reason = reason
            return false
        end

    else
        @warn "Unknown ship action" ship_name = ship_name action_id = action_id
        return false
    end
end

# ===============================================================
# Redock Placement
# ===============================================================

const REDOCK_GHOST_VALID = SVector{4, Float32}(0.3, 1.0, 0.3, 0.6)
const REDOCK_GHOST_INVALID = SVector{4, Float32}(1.0, 0.3, 0.3, 0.6)
const REDOCK_EXCLUSION_COL = SVector{4, Float32}(1.0, 0.78, 0.2, 0.15)

"Render ghost tiles for the ship being repositioned, coloured by placement validity."
function _render_redock_ghost!(queue::Vector{<:RenderCommand}, glmap::GLObjectMap, inputstate::InputState)
    state = placement_state(inputstate)
    state isa PlacementRedockState || return nothing
    rs = state

    cursor_tile = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
    delta = cursor_tile - rs.original_centre
    valid = is_redock_preview_valid(rs, delta)
    core_colour = valid ? REDOCK_GHOST_VALID : REDOCK_GHOST_INVALID

    ghost_height = Int32(HexFlowRendering.RENDER_HEIGHT_OVERLAY_BASE + 500)

    # Ship footprint
    for tile in rs.ship_tiles
        push!(
            queue, render_basic_tile(
                glmap, :ShipSurface_basic, HexFrame.Q_POS, tile + delta;
                colour = core_colour, transparency = 0.5, draw_height = ghost_height,
            )
        )
    end

    # Surface buffer and pipe-clearance ring
    for tile in rs.exclusion_ring
        push!(
            queue, render_basic_tile(
                glmap, :ShipSurface_basic, HexFrame.Q_POS, tile + delta;
                colour = REDOCK_EXCLUSION_COL, transparency = 0.5, draw_height = ghost_height,
            )
        )
    end

    return nothing
end

"Enter the interactive redock placement mode, caching docking footprints for fast per-frame validation."
function _enter_redock_mode!(inputstate::InputState, gamemap::GameMap, ship_name::Symbol)
    core_tiles = collect_surface_tiles!(Set{TileCoord}(), gamemap; ship_name = ship_name)
    ship_footprint = docking_footprint_including(gamemap, ship_name)
    display_footprint = docking_footprint_including(
        gamemap, ship_name; surface_clearance = DOCKING_SURFACE_CLEARANCE
    )
    other_exclusion = docking_footprint_excluding(
        gamemap, ship_name; surface_clearance = DOCKING_SURFACE_CLEARANCE
    )

    centroid = get_surface_centroid(gamemap, ship_name)
    original_centre = isnothing(centroid) ? TileCoord(0, 0) : round_to_tile(centroid)

    enter_redock_placement_state!(
        inputstate, PlacementRedockState(
            ship_name = ship_name,
            ship_tiles = core_tiles,
            exclusion_ring = setdiff(display_footprint, core_tiles),
            ship_footprint = ship_footprint,
            other_exclusion = other_exclusion,
            original_centre = original_centre,
        )
    )
    return nothing
end

"Check cached redock render data for ghost colouring only."
function is_redock_preview_valid(rs::RedockModeState, delta::TileCoord)::Bool
    return !ship_footprints_overlap(rs.other_exclusion, rs.ship_footprint, delta)
end

"Handle left-click during redock mode and enqueue the authoritative redock command."
function _handle_redock_click!(inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC, window::GLFW.Window; mouse_captured::Bool = false)
    state = placement_state(inputstate)
    state isa PlacementRedockState || return nothing
    rs = state

    # Right-click cancels redock mode, matching Escape
    if get_inrising!(inputstate, GLFW.MOUSE_BUTTON_RIGHT, window)
        inputstate.gui_inputs[:consume_right_click] = true
        enter_ready_placement_state!(inputstate)
        return nothing
    end

    mouse_captured && return nothing

    !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left) && return nothing
    (isnothing(inputstate.cursor_x) || isnothing(inputstate.cursor_y)) && return nothing

    cursor_tile = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
    delta = cursor_tile - rs.original_centre

    command = create_redock_ship_command(flowcalc_ipc.command_queue, rs.ship_name, delta)
    try_enqueue_command!(flowcalc_ipc.command_queue, command) && enter_ready_placement_state!(inputstate)
    return nothing
end
