# ===============================================================
# Keyboard Input Polling
# ===============================================================

using FlowMap

# ===============================================================
# Keyboard Input Polling
# ===============================================================

"Poll raw key state and mutate only ViewState (movement + zoom)"
function poll_keys!(viewstate::ViewState, window::GLFW.Window)
    # Skip on first frame (last_update_time not yet initialized)
    if viewstate.last_update_time == 0.0
        viewstate.last_update_time = time()
        return nothing
    end

    # Framerate-independent rates
    pan_rate_per_sec = 7.0f0
    zoom_rate_per_sec = 2.5f0

    # Calculate time delta and update timestamp
    current_time = time()
    delta_time = current_time - viewstate.last_update_time
    viewstate.last_update_time = current_time

    # Calculate framerate-independent scale factors
    pan_amount = pan_rate_per_sec * delta_time / viewstate.view_zoom
    zoom_factor_in = exp(zoom_rate_per_sec * delta_time)
    zoom_factor_out = exp(-zoom_rate_per_sec * delta_time)

    # Movement (pan) - apply before clamping
    get_instate(GLFW.KEY_A, window) && (viewstate.view_x += pan_amount)
    get_instate(GLFW.KEY_D, window) && (viewstate.view_x -= pan_amount)
    get_instate(GLFW.KEY_S, window) && (viewstate.view_y += pan_amount)
    get_instate(GLFW.KEY_W, window) && (viewstate.view_y -= pan_amount)

    # Zoom (exponential scaling) - apply before clamping
    get_instate(GLFW.KEY_Q, window) && (viewstate.view_zoom *= zoom_factor_out)
    get_instate(GLFW.KEY_E, window) && (viewstate.view_zoom *= zoom_factor_in)

    apply_view_limits!(viewstate)

    return nothing
end

"""
Update the ship bounds in ViewState based on the current GameMap.
Expands bounds if necessary to ensure a minimum span of 10 units (symmetric around centre).
"""
function update_ship_bounds!(viewstate::ViewState, gamemap::GameMap)
    # Get raw bounds from map
    raw_bounds = get_cartesian_bounds(gamemap)

    # Calculate centre and span
    centre_x = (raw_bounds.X_POS + raw_bounds.X_NEG) / 2.0
    centre_y = (raw_bounds.Y_POS + raw_bounds.Y_NEG) / 2.0
    span_x = raw_bounds.X_POS - raw_bounds.X_NEG
    span_y = raw_bounds.Y_POS - raw_bounds.Y_NEG

    # Enforce minimum span of 10 units (5 in each direction from centre)
    MIN_SPAN = 10.0
    half_span_x = max(span_x / 2.0, MIN_SPAN / 2.0)
    half_span_y = max(span_y / 2.0, MIN_SPAN / 2.0)

    # Calculate expanded bounds centred on the actual centre
    viewstate.ship_bounds = (
        X_POS = centre_x + half_span_x,
        X_NEG = centre_x - half_span_x,
        Y_POS = centre_y + half_span_y,
        Y_NEG = centre_y - half_span_y,
    )

    return nothing
end

"""
Apply zoom and pan limits based on ship bounds.
- Zoom: Limit so the longer ship axis takes up ~1/3 of screen
- Pan: Ensure at least 5% of ship bounds remains visible on screen
"""
function apply_view_limits!(viewstate::ViewState)
    bounds = viewstate.ship_bounds

    # Calculate ship span in cartesian units
    ship_span_x = bounds.X_POS - bounds.X_NEG
    ship_span_y = bounds.Y_POS - bounds.Y_NEG
    ship_span_max = max(ship_span_x, ship_span_y)

    # Calculate visible area in world units (inverse of zoom)
    # The hex_size_pixels constant is 256 (from get_viewtransform)
    hex_size_pixels = 256.0f0
    visible_width = viewstate.fb_width / (viewstate.view_zoom * hex_size_pixels)
    visible_height = viewstate.fb_height / (viewstate.view_zoom * hex_size_pixels)

    # === Zoom Limit ===
    # Ship should take up at least 1/3 of the smaller screen dimension
    # So visible area should be at most 5x the ship span
    max_visible_span = ship_span_max * 5.0f0

    # Calculate minimum zoom based on screen dimensions
    min_zoom_x = viewstate.fb_width / (max_visible_span * hex_size_pixels)
    min_zoom_y = viewstate.fb_height / (max_visible_span * hex_size_pixels)
    min_zoom = max(min_zoom_x, min_zoom_y)

    # Enforce a reasonable hard minimum zoom to prevent unusable views
    MIN_VIEW_ZOOM = 0.01f0
    min_zoom = max(min_zoom, MIN_VIEW_ZOOM)

    # Clamp zoom (allow zooming in indefinitely, but limit zoom out)
    viewstate.view_zoom = max(viewstate.view_zoom, min_zoom)

    # Recalculate visible area after zoom clamp
    visible_width = viewstate.fb_width / (viewstate.view_zoom * hex_size_pixels)
    visible_height = viewstate.fb_height / (viewstate.view_zoom * hex_size_pixels)

    # === Pan Limit ===
    # Ensure some of ship remains visible
    margin_fraction = 0.1f0  # 10% of ship must stay visible
    margin_x = ship_span_x * margin_fraction
    margin_y = ship_span_y * margin_fraction

    # Calculate bounds centre
    bounds_centre_x = (bounds.X_POS + bounds.X_NEG) / 2.0f0
    bounds_centre_y = (bounds.Y_POS + bounds.Y_NEG) / 2.0f0

    # Calculate pan limits
    # When view_x is 0, camera is at origin. view_x positive = camera moves left (sees right side)
    # We want: camera_centre_x - visible_width/2 < bounds.X_POS - margin (can't pan too far right)
    # And: camera_centre_x + visible_width/2 > bounds.X_NEG + margin (can't pan too far left)
    # camera_centre = -view (since view is offset applied to world)

    max_pan_x = -(bounds.X_NEG + margin_x - visible_width / 2.0f0)
    min_pan_x = -(bounds.X_POS - margin_x + visible_width / 2.0f0)
    max_pan_y = -(bounds.Y_NEG + margin_y - visible_height / 2.0f0)
    min_pan_y = -(bounds.Y_POS - margin_y + visible_height / 2.0f0)

    # Handle case where visible area is larger than ship (can't scroll at all)
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

"""
Calculate the maximum reachable viewport bounds given the current ship bounds and zoom limits.
Returns a HexFrame.CartesianBounds representing the union of all possible viewports the user can pan/zoom to.
"""
function calc_max_reachable_bounds(viewstate::ViewState)
    bounds = viewstate.ship_bounds

    # Calculate limits based on ship span
    ship_span_x = bounds.X_POS - bounds.X_NEG
    ship_span_y = bounds.Y_POS - bounds.Y_NEG
    ship_span_max = max(ship_span_x, ship_span_y)

    # Max visible span allowed by zoom limit
    # Matches constant in apply_view_limits!
    max_visible_span = ship_span_max * 5.0f0

    # Using the same constant as apply_view_limits!
    hex_size_pixels = 256.0f0

    # Calculate minimum zoom based on screen dimensions
    min_zoom_x = viewstate.fb_width / (max_visible_span * hex_size_pixels)
    min_zoom_y = viewstate.fb_height / (max_visible_span * hex_size_pixels)
    min_zoom = max(min_zoom_x, min_zoom_y)

    # Enforce hard minimum
    MIN_VIEW_ZOOM = 0.01f0
    min_zoom = max(min_zoom, MIN_VIEW_ZOOM)

    # Calculate world dimensions at this minimum zoom (max potential view size)
    max_view_width = viewstate.fb_width / (min_zoom * hex_size_pixels)
    max_view_height = viewstate.fb_height / (min_zoom * hex_size_pixels)

    # Pan limits (margin logic) based on current apply_view_limits! implementation
    margin_fraction = 0.1f0
    margin_x = ship_span_x * margin_fraction
    margin_y = ship_span_y * margin_fraction

    # Calculate maximal extents
    # Max right view edge: Ship Right Edge - Margin + Full View Width
    max_right = bounds.X_POS - margin_x + max_view_width
    # Min left view edge: Ship Left Edge + Margin - Full View Width
    min_left = bounds.X_NEG + margin_x - max_view_width

    # Max top view edge: Ship Top Edge - Margin + Full View Height
    max_top = bounds.Y_POS - margin_y + max_view_height
    # Min bottom view edge: Ship Bottom Edge + Margin - Full View Height
    min_bottom = bounds.Y_NEG + margin_y - max_view_height

    return (X_POS = Float64(max_right), X_NEG = Float64(min_left), Y_POS = Float64(max_top), Y_NEG = Float64(min_bottom))
end

"Poll key rising edges and mutate InputState and FlowCalculatorSharedState (tile tool rotation/mirroring, placement state, pause, time warp, exit)"
function poll_keys!(inputstate::InputState, shared_state::FlowCalculatorSharedState, window::GLFW.Window)
    state = placement_state(inputstate)

    # R key for tile-placement rotation
    if state isa PlacementTileState && get_inrising!(inputstate, GLFW.KEY_R, window)
        state.toolrotation = next_enum_val(state.toolrotation)
    end

    # F key for tile-placement and active-move mirroring
    if get_inrising!(inputstate, GLFW.KEY_F, window)
        if state isa PlacementTileState
            state.toolmirrored = !state.toolmirrored
        elseif state isa PlacementMoveState
            set_placement_state!(inputstate, PlacementMoveState(
                move_target = state.move_target,
                drag_reference_axis = state.drag_reference_axis,
                toolrotation = state.toolrotation,
                toolmirrored = !state.toolmirrored,
            ))
            state = placement_state(inputstate)
        end
    end

    # ESC key — cancel redock or editor tool > cancel active standard interaction > dismiss action popup > cancel time warp > toggle pause menu
    if get_inrising!(inputstate, GLFW.KEY_ESCAPE, window)
        if state isa PlacementRedockState || state isa AbstractEditorPlacementState
            enter_ready_placement_state!(inputstate)
        elseif is_active_standard_interaction_state(state)
            clear_placement_state!(inputstate)
        elseif !isnothing(inputstate.action_popup)
            clear_action_popup_selection!(inputstate)
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

    # SPACE key — toggle FlowCalculator pause
    if get_inrising!(inputstate, GLFW.KEY_SPACE, window)
        current_paused = @atomic :monotonic shared_state.is_paused
        @atomic :monotonic shared_state.is_paused = !current_paused
    end

    # \ key to toggle dev utils menu
    get_inrising!(inputstate, GLFW.KEY_BACKSLASH, window) && (inputstate.dev_utils_menu_active = !inputstate.dev_utils_menu_active)
    # M key to toggle space map (blocked during time progression)
    if get_inrising!(inputstate, GLFW.KEY_M, window)
        time_prog = get(inputstate.gui_inputs, :time_progressing, false)::Bool
        if !time_prog
            inputstate.spacemap_active = !inputstate.spacemap_active
        end
    end

    # Number keys 4-6 for editor-only placement states when editor capability is enabled
    if editor_capabilities_enabled(inputstate)
        get_inrising!(inputstate, GLFW.KEY_4, window) && toggle_editor_placement_state!(inputstate, PlacementDeleteState())
        get_inrising!(inputstate, GLFW.KEY_5, window) && toggle_editor_placement_state!(inputstate, inputstate.tile_tool_state)
        get_inrising!(inputstate, GLFW.KEY_6, window) && toggle_editor_placement_state!(inputstate, PlacementSurfaceEditState())
    end

    # ] key — increase sim speed
    if get_inrising!(inputstate, GLFW.KEY_RIGHT_BRACKET, window)
        inputstate.sim_speed = increase_sim_speed(inputstate.sim_speed)
        @atomic :monotonic shared_state.target_ups = sim_speed_to_ups(inputstate.sim_speed)
    end

    # [ key — decrease sim speed
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

    # Toolbar cycling (Z = previous, C = next) — wraps around
    if get_inrising!(inputstate, GLFW.KEY_Z, window)
        inputstate.toolbar = mod1(inputstate.toolbar - 1, length(component_list))
    end
    if get_inrising!(inputstate, GLFW.KEY_C, window)
        inputstate.toolbar = mod1(inputstate.toolbar + 1, length(component_list))
    end

    return nothing
end

"Poll cursor position and transform it to map space, updating inputstate cursor_x/y"
function poll_cursorpos!(inputstate::InputState, viewstate::ViewState, window::GLFW.Window)
    x, y = GLFW.GetCursorPos(window)

    # Convert cursor coordinates from window space to framebuffer space (handles Retina/HiDPI displays)
    fb_scale_x = viewstate.fb_width / viewstate.window_width
    fb_scale_y = viewstate.fb_height / viewstate.window_height
    x_fb = x * fb_scale_x
    y_fb = y * fb_scale_y

    # Flip Y coordinate and center, then transform to map space
    y_origin = viewstate.fb_height - y_fb
    xy = @SVector [(x_fb - viewstate.fb_width / 2), (y_origin - viewstate.fb_height / 2)]
    view_offset = @SVector [viewstate.view_x, viewstate.view_y]
    xy_cartesian = ((xy ./ hex_size_pixels) ./ viewstate.view_zoom) - view_offset
    inputstate.cursor_x = xy_cartesian[1]
    inputstate.cursor_y = xy_cartesian[2]

    return nothing
end

"Convert world-space CartesianCoord to window-space pixel coordinates (inverse of poll_cursorpos!)"
function world_to_screen(world_x::Float64, world_y::Float64, viewstate::ViewState)
    # Apply pan, zoom, and scale to framebuffer pixels (inverse of cursor transform)
    x_fb = (world_x + Float64(viewstate.view_x)) * Float64(viewstate.view_zoom) * hex_size_pixels + Float64(viewstate.fb_width) / 2.0
    y_fb = Float64(viewstate.fb_height) / 2.0 - (world_y + Float64(viewstate.view_y)) * Float64(viewstate.view_zoom) * hex_size_pixels

    # Framebuffer → window coords (handles HiDPI)
    fb_scale_x = Float64(viewstate.fb_width) / Float64(viewstate.window_width)
    fb_scale_y = Float64(viewstate.fb_height) / Float64(viewstate.window_height)
    return (x_fb / fb_scale_x, y_fb / fb_scale_y)
end

"Poll window and framebuffer sizes and update ViewState, adjusting viewport if sizes changed"
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
        ModernGL.glViewport(0, 0, viewstate.fb_width, viewstate.fb_height) # Keep viewport synchronized
    end
    return nothing
end

"Poll scroll wheel deltas and apply cursor-centred zoom to ViewState"
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

"Handle middle-click pan: drag to move the camera, anchoring the world point under the cursor"
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

"""
Unified per-frame input handling. Polls window state, cursor position, view keys, scroll wheel, and action keys.
Order matters: window sizes must be updated before cursor transform.
Accepts optional CImGui IO pointer to guard keyboard input when typing in UI fields.
"""
function handle_inputs!(inputstate::InputState, viewstate::ViewState, shared_state::FlowCalculatorSharedState, window::GLFW.Window, cimgui_io::Union{Nothing, Ptr{CImGui.lib.ImGuiIO}} = nothing)
    poll_windowstate!(viewstate, window) # Window/framebuffer sizes (needed for correct cursor mapping)
    poll_cursorpos!(inputstate, viewstate, window) # Cursor position (uses updated window sizes)
    poll_keys!(viewstate, window) # View keys (WASD pan / QE zoom) — always active
    poll_middleclick_pan!(viewstate, inputstate, window) # Middle-click drag pan — always active
    poll_scrollwheel_zoom!(inputstate, viewstate, cimgui_io) # Scroll wheel zoom (gated by WantCaptureMouse)

    # Action/mode/pause/exit keys — only when not typing in UI
    if isnothing(cimgui_io) || !unsafe_load(cimgui_io.WantCaptureKeyboard)
        poll_keys!(inputstate, shared_state, window)
    end

    return nothing
end

# ===============================================================
# Click Detection and Coordinate Identification
# ===============================================================

"""
Determine what coordinate element (TileCoord, EdgeCoord, or VertexCoord) the cursor is pointing at.
Returns the most specific element: VertexCoord if near a node, EdgeCoord if near a pipe edge,
or TileCoord as a fallback.
"""
function get_clicked(inputstate::InputState)
    # Escape if no cursor location or invalid coordinates
    if isnothing(inputstate.cursor_x) || isnothing(inputstate.cursor_y)
        return nothing
    end
    if !isfinite(inputstate.cursor_x) || !isfinite(inputstate.cursor_y)
        return nothing
    end

    # Get vector perpendicular to the input vector
    perp_vector(v::SVector{2, T}) where {T <: Number} = SVector{2, T}(-v[2], v[1])

    # Detection thresholds (in cartesian space)
    noderange = 0.15 # Acceptable distance to node
    edgerange = 0.15 # Acceptable distance to pipe

    # Calculate nearby coordinates
    cursor_cart = CartesianCoord(inputstate.cursor_x, inputstate.cursor_y)
    close_edge = round_to_edge(cursor_cart)
    v1_cart = to_cartesian(close_edge.v1)
    v2_cart = to_cartesian(close_edge.v2)

    # Check if near nodes
    if norm(cursor_cart .- v1_cart) <= noderange
        return close_edge.v1
    end
    if norm(cursor_cart .- v2_cart) <= noderange
        return close_edge.v2
    end

    # Check if near edge by measuring perpendicular distance to edge
    perp_unit = LinearAlgebra.normalize(perp_vector(v2_cart .- v1_cart))
    dist_to_pipe = norm(dot(cursor_cart .- v1_cart, perp_unit))
    if dist_to_pipe <= edgerange
        return close_edge
    end

    # Fallback: always return the tile containing the cursor
    return round_to_tile(cursor_cart)
end

"Shortest distance from a point to a line segment defined by endpoints a and b"
function point_to_segment_distance(p::CartesianCoord, a::CartesianCoord, b::CartesianCoord)::Float64
    ab = b .- a
    ap = p .- a
    len_sq = ab[1]^2 + ab[2]^2
    len_sq == 0.0 && return norm(ap) # degenerate segment
    t = clamp(dot(ap, ab) / len_sq, 0.0, 1.0)
    closest = a .+ t .* ab
    return norm(p .- closest)
end

# ===============================================================
# Tile-Pipe Axis Helpers
# ===============================================================

"Get the nearest tile-pipe axis (canonical) from cursor position relative to tile centre"
function nearest_tile_pipe_axis(cursor_cart::CartesianCoord, tile_cart::CartesianCoord)::HexAxis
    # Compute relative position in axial space
    dir_axial = to_axial(cursor_cart) - to_axial(tile_cart)

    # Find nearest of the 6 hex directions
    axis = nearest_hex_axis(dir_axial)

    # Canonicalise to Q/R/S
    normalise_tile_pipe_axis(axis)
end

"Get the tile-pipe fragment at a coordinate, or `nothing` if there is no `MultiPipeTileCompBehav` there."
function get_multipipe_tile(gamemap::GameMap, tile::TileCoord)::Union{Nothing, MultiPipeTileCompBehav}
    comp = get_component(gamemap, tile)
    isnothing(comp) && return nothing
    behav = comp.component
    if isa(behav, MultiPipeTileCompBehav)
        return behav
    end
    return nothing
end

"Get the hovered tile-pipe axis for the current cursor position on a tile."
function hovered_tile_pipe_axis(inputstate::InputState, tile::TileCoord)::HexAxis
    cursor_pos = CartesianCoord(inputstate.cursor_x, inputstate.cursor_y)
    tile_centre = to_cartesian(tile)
    return nearest_tile_pipe_axis(cursor_pos, tile_centre)
end

"Get the tile-pipe fragment equivalent for the currently selected pending pipe behaviour."
get_pending_tile_pipe_frag(inputstate::InputState) = get_tile_pipe_equivalent_frag(inputstate.pendingpipebehavior)

"Get the tile-pipe fragment on a tile axis across all ships, or nothing when no multi-pipe exists there."
function get_tile_pipe_frag_any_ship(gamemap::GameMap, tile::TileCoord, axis::HexAxis)
    multi_pipe = get_multipipe_tile(gamemap, tile)
    multi_pipe === nothing && return nothing
    return get_tile_pipe(multi_pipe, axis)
end

"Return whether tile-pipe commands can target this tile without hitting a non-pipe component."
function can_modify_tile_pipe(gamemap::GameMap, tile::TileCoord)::Bool
    ship_name = find_tile_pipe_host_ship(gamemap, tile)
    isnothing(ship_name) && return false
    comp = get_component(gamemap, tile)
    isnothing(comp) && return true   # surface tile with no component is fine
    return isa(comp.component, MultiPipeTileCompBehav)
end

"Return whether a tile-pipe move can target the destination tile-axis."
function can_move_tile_pipe_to(gamemap::GameMap, tile::TileCoord, axis::HexAxis)::Bool
    can_modify_tile_pipe(gamemap, tile) || return false

    existing_frag = get_tile_pipe_frag_any_ship(gamemap, tile, axis)
    return isnothing(existing_frag) || isempty(existing_frag)
end

"Render a single tile-pipe fragment ghost aligned to its axis."
function render_tile_pipe_frag_ghost!(queue::Vector{<:RenderCommand}, glmap::GLObjectMap, tile::TileCoord, axis::HexAxis, frag; transparency::Float64 = 0.5, colour = GHOST_COLOUR_VALID, render_height_offset::Integer = 0)
    isempty(frag) && return nothing

    render_base_elem!(queue, frag; glmap = glmap, rotation = normalise_tile_pipe_axis(axis), position = tile, transparency = transparency, colour = colour, render_height_offset = Int32(render_height_offset))
    return nothing
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

"Return the snapped direction from one vertex to another." 
function vertex_to_vertex_axis(source_vertex::VertexCoord, far_vertex::VertexCoord)::HexAxis
    source_pos = to_cartesian(source_vertex)
    far_pos = to_cartesian(far_vertex)
    return nearest_hex_axis(to_axial(far_pos) - to_axial(source_pos))
end

"Return whether deleting an existing edge pipe is allowed under current off-ship rules."
function can_delete_edge_pipe(edge::EdgeCoord, gamemap::GameMap)::Bool
    v1_on = is_node_on_any_ship_surface(to_nodecoord(edge.v1), gamemap)
    v2_on = is_node_on_any_ship_surface(to_nodecoord(edge.v2), gamemap)
    is_offship = !(v1_on && v2_on)
    return !is_offship || validate_offship_pipe_deletion(edge, gamemap)
end

"Return whether a new edge pipe can be placed under the current on-surface or off-ship rules."
function can_place_edge_pipe(edge::EdgeCoord, gamemap::GameMap)::Bool
    !isnothing(find_ship_containing_edge(gamemap, edge)) && return true
    can_place, _, _ = can_place_pipe_offship(edge, gamemap)
    return can_place
end

"Collect the six concrete PIPE candidates incident to a selected source node." 
function collect_pipe_chain_candidates(source_vertex::VertexCoord, inputstate::InputState, gamemap::GameMap)
    candidates = NamedTuple[]

    # Around a selected node there are always six directional possibilities:
    # three physical edge pipes and three tile-through-pipe equivalents.
    for edge in get_edges(source_vertex)
        far_node = to_proper(edge.v1 == source_vertex ? edge.v2 : edge.v1)
        existing_pipe = get_pipe(gamemap, edge)

        if !isnothing(existing_pipe)
            push!(candidates, (
                kind = :edge,
                direction_axis = vertex_to_vertex_axis(source_vertex, far_node),
                edge = edge,
                tile = nothing,
                axis = nothing,
                far_node = far_node,
                ghost_payload = existing_pipe,
                can_commit = can_delete_edge_pipe(edge, gamemap),
                commit_kind = :delete,
            ))
            continue
        end

        push!(candidates, (
            kind = :edge,
            direction_axis = vertex_to_vertex_axis(source_vertex, far_node),
            edge = edge,
            tile = nothing,
            axis = nothing,
            far_node = far_node,
            ghost_payload = inputstate.pendingpipebehavior,
            can_commit = can_place_edge_pipe(edge, gamemap),
            commit_kind = :place,
        ))
    end

    source_node = to_nodecoord(source_vertex)
    pending_frag = get_pending_tile_pipe_frag(inputstate)

    # `local_dir` identifies which vertex of this adjacent tile is the selected source.
    # Rotating it by 180 degrees gives the outward-facing direction and the far node.
    for (tile, local_dir) in get_adjacent_tiles_for_node(source_node)
        axis = normalise_tile_pipe_axis(local_dir)
        direction_axis = rotate(local_dir, HexFrame.Q_NEG)
        far_node = to_proper(VertexCoord(tile, direction_axis))
        existing_frag = get_tile_pipe_frag_any_ship(gamemap, tile, axis)

        if !isnothing(existing_frag) && !isempty(existing_frag)
            push!(candidates, (
                kind = :tile,
                direction_axis = direction_axis,
                edge = nothing,
                tile = tile,
                axis = axis,
                far_node = far_node,
                ghost_payload = existing_frag,
                can_commit = true,
                commit_kind = :delete,
            ))
            continue
        end

        push!(candidates, (
            kind = :tile,
            direction_axis = direction_axis,
            edge = nothing,
            tile = tile,
            axis = axis,
            far_node = far_node,
            ghost_payload = pending_frag,
            can_commit = !isnothing(pending_frag) && can_modify_tile_pipe(gamemap, tile),
            commit_kind = :place,
        ))
    end

    return candidates
end

"Resolve the currently active PIPE candidate from the cursor direction around the selected source node." 
function get_active_pipe_chain_candidate(source_vertex::VertexCoord, inputstate::InputState, gamemap::GameMap)
    cursor_pos = get_cursor_cart(inputstate)
    cursor_pos === nothing && return nothing

    source_pos = to_cartesian(source_vertex)
    cursor_axis = nearest_hex_axis(to_axial(cursor_pos) - to_axial(source_pos))

    for candidate in collect_pipe_chain_candidates(source_vertex, inputstate, gamemap)
        if candidate.direction_axis == cursor_axis
            return candidate
        end
    end

    return nothing
end

"Advance or clear PIPE chaining state when a queued command reports back from the calculator thread." 
function poll_pipe_chain_response!(inputstate::InputState)
    state = placement_state(inputstate)
    state isa PlacementPipeChainState || return nothing

    channel = state.pending_response_channel
    isnothing(channel) && return nothing
    isready(channel) || return nothing

    status = take!(channel)
    if status == APPLIED
        next_source = something(state.pending_next_source_node, state.source_node)
        set_placement_state!(inputstate, PlacementPipeChainState(source_node = next_source))
    else
        set_placement_state!(inputstate, PlacementPipeChainState(source_node = state.source_node))
    end
    return nothing
end

"Build the map-edit command for the currently active PIPE candidate." 
function create_pipe_chain_command(
        command_queue::CommandQueue,
        inputstate::InputState,
        candidate;
        response_channel::Union{Nothing, Channel} = nothing
    )
    if candidate.kind === :edge
        if candidate.commit_kind === :delete
            return create_delete_command(command_queue, candidate.edge; response_channel = response_channel)
        end

        return create_set_pipe_behavior_command(
            command_queue,
            candidate.edge,
            inputstate.pendingpipebehavior;
            response_channel = response_channel,
        )
    end

    frag = candidate.commit_kind === :delete ? NoPipeBehavFrag() : get_pending_tile_pipe_frag(inputstate)
    frag === nothing && return nothing

    return HexFlowCalculator.ModifyTilePipeCommand(
        id = command_queue.next_command_id(),
        tile = candidate.tile,
        axis = candidate.axis,
        frag = frag,
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
    return CartesianCoord(inputstate.cursor_x, inputstate.cursor_y)
end

"Clear the active world action popup and its selection highlights."
function clear_action_popup_selection!(inputstate::InputState)
    inputstate.action_popup = nothing
    inputstate.rightclick_selectedcoord = nothing
    inputstate.rightclick_selectedship = nothing
    return nothing
end

"Return the snapped hex axis nearest the cursor around a tile centre."
function nearest_tile_rotation_axis(cursor_cart::CartesianCoord, tile::TileCoord)::HexAxis
    tile_centre = to_cartesian(tile)
    direction = to_axial(cursor_cart) - to_axial(tile_centre)
    return nearest_hex_axis(direction)
end

"Resolve the current MOVE hover target under the cursor."
function get_move_hover_target(inputstate::InputState, gamemap::GameMap)
    element = get_clicked(inputstate)
    element === nothing && return nothing
    is_on_offset_ship(element, gamemap) && return nothing

    if element isa TileCoord
        tilecomp = get_component(gamemap, element)
        isnothing(tilecomp) && return nothing

        can_move, reason = can_be_moved(tilecomp)
        if tilecomp.component isa MultiPipeTileCompBehav
            axis = hovered_tile_pipe_axis(inputstate, element)
            frag = get_tile_pipe(tilecomp.component, axis)
            isempty(frag) && return nothing
            return (; coord = element, kind = :tile_pipe, tile_pipe_axis = axis, can_move, reason, frag)
        end

        return (; coord = element, kind = :tile_component, tile_pipe_axis = nothing, can_move, reason, frag = nothing)
    elseif element isa EdgeCoord
        pipe_behav = get_pipe(gamemap, element)
        isnothing(pipe_behav) && return nothing
        can_move, reason = can_pipe_be_moved(pipe_behav)
        return (; coord = element, kind = :edge_pipe, tile_pipe_axis = nothing, can_move, reason, frag = nothing)
    end

    return nothing
end

"Record a pending MOVE hold on the current target and clear any stale popup state."
function set_move_hold_target!(inputstate::InputState, target)::Bool
    cursor_cart = get_cursor_cart(inputstate)
    cursor_cart === nothing && return false
    click_tile = round_to_tile(cursor_cart)

    clear_action_popup_selection!(inputstate)

    move_target = if target.kind === :tile_component
        TileComponentMoveTarget(target.coord)
    elseif target.kind === :tile_pipe
        TilePipeMoveTarget(target.coord, target.tile_pipe_axis)
    else
        EdgePipeMoveTarget(target.coord)
    end

    set_placement_state!(inputstate, PlacementPressedState(
        press_started_at = time(),
        press_cursor_cart = cursor_cart,
        click_tile = click_tile,
        move_target = move_target,
        move_target_valid = target.can_move,
    ))
    return true
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

    set_placement_state!(inputstate, PlacementMoveState(
        move_target = move_target,
        drag_reference_axis = reference_axis,
        toolrotation = HexFrame.Q_POS,
        toolmirrored = false,
    ))
    return nothing
end

"Update MOVE tile rotation from the current cursor position while an active drag is in progress."
function update_active_move_rotation!(inputstate::InputState)
    state = placement_state(inputstate)
    state isa PlacementMoveState || return nothing
    state.move_target isa TileComponentMoveTarget || return nothing
    isnothing(state.drag_reference_axis) && return nothing

    cursor_cart = get_cursor_cart(inputstate)
    cursor_cart === nothing && return nothing

    destination = round_to_tile(cursor_cart)
    current_axis = nearest_tile_rotation_axis(cursor_cart, destination)
    set_placement_state!(inputstate, PlacementMoveState(
        move_target = state.move_target,
        drag_reference_axis = state.drag_reference_axis,
        toolrotation = rotate(current_axis, rotate_reverse(state.drag_reference_axis)),
        toolmirrored = state.toolmirrored,
    ))
    return nothing
end

"Create an INSPECT-style click command from the stored MOVE short-click press site."
function create_move_short_click_command(command_queue::CommandQueue, inputstate::InputState)
    state = placement_state(inputstate)
    state isa PlacementPressedState || return nothing
    hold_coord = state.click_tile
    hold_coord isa TileCoord || return nothing

    tile_center_cart = to_cartesian(hold_coord)
    unrotated_clicksite = state.press_cursor_cart - tile_center_cart
    return create_click_tile_command(command_queue, hold_coord, unrotated_clicksite)
end

"Return whether the active MOVE selection can commit at the current cursor destination."
function can_commit_active_move(inputstate::InputState, gamemap::GameMap)::Bool
    state = placement_state(inputstate)
    state isa PlacementMoveState || return false

    cursor_cart = get_cursor_cart(inputstate)
    cursor_cart === nothing && return false

    if state.move_target isa TilePipeMoveTarget
        selected = state.move_target.coord
        src_axis = state.move_target.axis
        dst_tile = round_to_tile(cursor_cart)
        dst_axis = hovered_tile_pipe_axis(inputstate, dst_tile)

        if dst_tile == selected && dst_axis == src_axis
            return false
        end
        return can_move_tile_pipe_to(gamemap, dst_tile, dst_axis)
    elseif state.move_target isa TileComponentMoveTarget
        selected = state.move_target.coord
        tilecomp = get_component(gamemap, selected)
        isnothing(tilecomp) && return false

        new_rotation = map_rotation(tilecomp, rotate(tilecomp.rotation, state.toolrotation))
        requested_mirror = xor(tilecomp.mirrored, state.toolmirrored)
        new_mirrored = map_mirroring(tilecomp, requested_mirror)
        destination = round_to_tile(cursor_cart)

        if destination == selected
            rotated_comptile = ComponentOnTile(tilecomp.component, new_rotation, new_mirrored, tilecomp.ship)
            is_valid, _ = placement_valid(rotated_comptile, selected, gamemap; ship_name = tilecomp.ship)
            return is_valid
        end

        !isnothing(get_component(gamemap, destination)) && return false
        dest_ship = find_ship_for_placement(
            tilecomp.component, destination, gamemap;
            rotation = new_rotation, mirrored = new_mirrored
        )
        return !isnothing(dest_ship)
    elseif state.move_target isa EdgePipeMoveTarget
        selected = state.move_target.coord
        destination = round_to_edge(cursor_cart)
        destination == selected && return false

        source_pipe = get_pipe(gamemap, selected)
        isnothing(source_pipe) && return false

        src_v1_on = is_node_on_any_ship_surface(to_nodecoord(selected.v1), gamemap)
        src_v2_on = is_node_on_any_ship_surface(to_nodecoord(selected.v2), gamemap)
        source_is_offship = !(src_v1_on && src_v2_on)

        source_is_offship && !validate_offship_pipe_deletion(selected, gamemap) && return false
        has_pipe(gamemap, destination) && return false

        !isnothing(find_ship_containing_edge(gamemap, destination)) && return true
        can_place, _, _ = can_place_pipe_offship(destination, gamemap)
        return can_place
    end

    return false
end

"Build the current active MOVE command, or return `nothing` when the release should cancel."
function create_active_move_command(command_queue::CommandQueue, inputstate::InputState, gamemap::GameMap)
    can_commit_active_move(inputstate, gamemap) || return nothing

    state = placement_state(inputstate)
    state isa PlacementMoveState || return nothing
    cursor_cart = get_cursor_cart(inputstate)
    if cursor_cart === nothing
        return nothing
    end

    if state.move_target isa TilePipeMoveTarget
        selected = state.move_target.coord
        src_axis = state.move_target.axis
        dst_tile = round_to_tile(cursor_cart)
        dst_axis = hovered_tile_pipe_axis(inputstate, dst_tile)
        return HexFlowCalculator.MoveTilePipeCommand(
            id = command_queue.next_command_id(),
            src_tile = selected,
            src_axis = src_axis,
            dst_tile = dst_tile,
            dst_axis = dst_axis,
            response_channel = nothing
        )
    elseif state.move_target isa TileComponentMoveTarget
        selected = state.move_target.coord
        destination = round_to_tile(cursor_cart)
        return create_move_command(command_queue, selected, destination, state.toolrotation, state.toolmirrored)
    elseif state.move_target isa EdgePipeMoveTarget
        selected = state.move_target.coord
        destination = round_to_edge(cursor_cart)
        return create_move_command(command_queue, selected, destination, state.toolrotation, state.toolmirrored)
    end

    return nothing
end

# ===============================================================
# Pending Component Updates
# ===============================================================

"Update pending component type to match current toolbar selection"
function pendingcomponent_typeupdate!(inputstate::InputState)
    toolbar_has_changed = inputstate.last_toolbar != inputstate.toolbar
    inputstate.last_toolbar = inputstate.toolbar

    tile_tool_state = inputstate.tile_tool_state
    if isnothing(tile_tool_state)
        tile_tool_state = PlacementTileState(pendingcomponent = deepcopy(component_list[inputstate.toolbar]))
        inputstate.tile_tool_state = tile_tool_state
    end

    if toolbar_has_changed
        tile_tool_state.pendingcomponent = deepcopy(component_list[inputstate.toolbar])
    end

    if !editor_capabilities_enabled(inputstate)
        inputstate.pendingpipebehavior = ScrapPipeBehav()
    end
    return nothing
end

# ===============================================================
# Cursor Ghost Rendering
# ===============================================================

const GHOST_COLOUR_VALID = SVector{4, Float32}(1.0, 1.0, 1.0, 1.0)
const GHOST_COLOUR_INVALID = SVector{4, Float32}(1.0, 0.4, 0.4, 1.0)
const GHOST_PIPE_COLOUR_INVALID = ColourType(0.6, 0.15, 0.15, 1.0)

"""
Render cursor ghosts for tile/pipe placement and move operations.
Shows semi-transparent previews of where components will be placed/moved.
"""
function render_cursor_ghosts!(queue::Vector{<:RenderCommand}, glmap::GLObjectMap, inputstate::InputState, gamemap::GameMap, gamestate::GameState)
    if inputstate.cursor_x === nothing || inputstate.cursor_y === nothing
        return
    end

    state = placement_state(inputstate)

    # Redock ghost — show ship footprint and exclusion zone following the cursor
    if state isa PlacementRedockState
        _render_redock_ghost!(queue, glmap, inputstate)
        return # suppress all other placement ghosts during redock
    end

    # Render selection circle for right-click selected tile
    if !isnothing(inputstate.rightclick_selectedcoord)
        selected = inputstate.rightclick_selectedcoord
        selection_colour = SVector{4, Float32}(0.3, 1.0, 0.3, 0.4)  # Green, ~60% transparent

        push!(
            queue, render_basic_sprite(
                glmap, :MoveArrow_arrow_start, rotmat_2D(0.0), selected;
                colour = selection_colour, draw_height = Int32(100100), scale = 2.5
            )
        )
    end

    if state isa PlacementTileState
        coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
        component = state.pendingcomponent
        rotation = map_rotation(component, state.toolrotation)
        mirrored = map_mirroring(component, state.toolmirrored)
        target_ship = find_ship_for_placement(component, coord, gamemap; rotation = rotation, mirrored = mirrored)
        ghost_colour = isnothing(target_ship) ? GHOST_COLOUR_INVALID : GHOST_COLOUR_VALID
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

        candidate = get_active_pipe_chain_candidate(source_vertex, inputstate, gamemap)
        if !isnothing(candidate)
            ghost_colour = (candidate.commit_kind === :delete || !candidate.can_commit) ? GHOST_COLOUR_INVALID : GHOST_COLOUR_VALID

            if candidate.kind === :edge
                render_pipe_base!(
                    queue, candidate.ghost_payload;
                    glmap = glmap, rotation = HexFrame.Q_POS, position = candidate.edge,
                    transparency = 0.5, colour = ghost_colour, render_height_offset = Int32(100000),
                )
            elseif !isnothing(candidate.ghost_payload)
                render_tile_pipe_frag_ghost!(
                    queue, glmap, candidate.tile, candidate.axis, candidate.ghost_payload;
                    transparency = 0.5, colour = ghost_colour, render_height_offset = 100000,
                )
            end
        end
    end

    if state isa PlacementPressedState && !isnothing(state.move_target) && state.hold_threshold_crossed
        #= ---------- Move activation indicator ----------- =#
        if state.move_target isa TilePipeMoveTarget
            target_coord = state.move_target.coord
            target_axis = state.move_target.axis
            tilecomp = get_component(gamemap, target_coord)
            if !isnothing(tilecomp) && tilecomp.component isa MultiPipeTileCompBehav
                frag = get_tile_pipe(tilecomp.component, target_axis)
                move_colour = state.move_target_valid ?
                    SVector{4, Float32}(1.0, 0.9, 0.2, 0.75) :
                    SVector{4, Float32}(1.0, 0.4, 0.4, 0.75)
                !isempty(frag) && render_tile_pipe_frag_ghost!(queue, glmap, target_coord, target_axis, frag; transparency = 0.7, colour = move_colour, render_height_offset = 100100)
            end
        elseif state.move_target isa TileComponentMoveTarget
            move_colour = state.move_target_valid ?
                SVector{4, Float32}(1.0, 0.9, 0.2, 0.75) :
                SVector{4, Float32}(1.0, 0.4, 0.4, 0.75)
            push!(
                queue, render_basic_sprite(
                    glmap, :MoveArrow_arrow_start, rotmat_2D(0.0), state.move_target.coord;
                    colour = move_colour, draw_height = Int32(100100), scale = 1.5
                )
            )
        elseif state.move_target isa EdgePipeMoveTarget
            move_colour = state.move_target_valid ? GHOST_COLOUR_VALID : GHOST_PIPE_COLOUR_INVALID
            actual_pipe = get_pipe(gamemap, state.move_target.coord)
            !isnothing(actual_pipe) && render_pipe_base!(
                queue, actual_pipe; glmap = glmap, rotation = HexFrame.Q_POS,
                position = state.move_target.coord, transparency = 0.7, colour = move_colour, render_height_offset = Int32(100100)
            )
        end
    elseif state isa PlacementMoveState
        move_target = state.move_target

        if move_target isa TileComponentMoveTarget
            tilecomp = get_component(gamemap, move_target.coord)
            if !isnothing(tilecomp)
                #= ---------- Tile move ghost ----------- =#
                coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
                rotation = map_rotation(tilecomp, rotate(tilecomp.rotation, state.toolrotation))
                requested_mirror = xor(tilecomp.mirrored, state.toolmirrored)
                mirrored = map_mirroring(tilecomp, requested_mirror)
                ghost_colour = can_commit_active_move(inputstate, gamemap) ? GHOST_COLOUR_VALID : GHOST_COLOUR_INVALID

                render_base_elem!(queue, tilecomp; glmap = glmap, rotation = rotation, mirrored = mirrored, position = coord, transparency = 0.5, colour = ghost_colour, render_height_offset = Int32(100000))

                #= ---------- Move arrow (start circle, end arrowhead, animated dashes) ----------- =#
                render_move_arrow_overlay!(
                    queue, glmap, gamestate.ticks, move_target.coord, coord;
                    draw_start_marker = true,
                    draw_dashes = true,
                    colour = SVector{4, Float32}(0.8, 0.8, 0.2, 1.0),
                    draw_height = Int32(100200),
                    start_marker_scale = 1.0
                )
            end
        elseif move_target isa TilePipeMoveTarget
            tilecomp = get_component(gamemap, move_target.coord)
            if !isnothing(tilecomp) && tilecomp.component isa MultiPipeTileCompBehav
                src_frag = get_tile_pipe(tilecomp.component, move_target.axis)
                if !isempty(src_frag)
                    render_tile_pipe_frag_ghost!(queue, glmap, move_target.coord, move_target.axis, src_frag; transparency = 0.95, colour = SVector{4, Float32}(0.95, 0.85, 0.2, 0.9), render_height_offset = 100120)

                    coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
                    dst_axis = hovered_tile_pipe_axis(inputstate, coord)
                    if !(coord == move_target.coord && dst_axis == move_target.axis)
                        ghost_colour = can_commit_active_move(inputstate, gamemap) ? GHOST_COLOUR_VALID : GHOST_COLOUR_INVALID
                        render_tile_pipe_frag_ghost!(queue, glmap, coord, dst_axis, src_frag; transparency = 0.5, colour = ghost_colour, render_height_offset = 100000)

                        render_move_arrow_overlay!(
                            queue, glmap, gamestate.ticks, move_target.coord, coord;
                            draw_start_marker = false,
                            draw_dashes = true,
                            colour = SVector{4, Float32}(0.8, 0.8, 0.2, 1.0),
                            draw_height = Int32(100200)
                        )
                    end
                end
            end
        elseif move_target isa EdgePipeMoveTarget
            actual_pipe = get_pipe(gamemap, move_target.coord)
            if !isnothing(actual_pipe)
                #= ---------- Pipe move ghost ----------- =#
                ghost_edge = round_to_edge(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
                ghost_colour = can_commit_active_move(inputstate, gamemap) ? GHOST_COLOUR_VALID : GHOST_PIPE_COLOUR_INVALID
                render_pipe_base!(
                    queue, actual_pipe; glmap = glmap, rotation = HexFrame.Q_POS,
                    position = ghost_edge, transparency = 0.5, colour = ghost_colour, render_height_offset = Int32(100000)
                )

                #= ---------- Move arrow (start circle and end arrowhead) ----------- =#
                render_move_arrow_overlay!(
                    queue, glmap, gamestate.ticks, move_target.coord, ghost_edge;
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

        # Check which ship owns this surface, or which ship it would be added to
        existing_ship = get_surface_shiptag(gamemap, coord)
        if !isnothing(existing_ship)
            # Surface exists - show removal ghost
            colour = SVector{4, Float32}(1.0, 0.3, 0.3, 0.5) # Red for removal
        else
            # No surface - check if adjacent to exactly one ship (valid addition)
            adjacent_ships = find_ships_adjacent_to_coord(gamemap, coord)
            if length(adjacent_ships) == 1
                colour = SVector{4, Float32}(0.3, 1.0, 0.3, 0.5) # Green for valid addition
            else
                # Invalid placement (no adjacent or multiple adjacent)
                colour = SVector{4, Float32}(0.5, 0.5, 0.5, 0.3) # Gray for invalid
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
        element = get_clicked(inputstate)
        indicator_position = nothing

        if element isa TileCoord
            # Search all ships for component
            if has_component(gamemap, element)
                indicator_position = element
            end
        elseif element isa EdgeCoord
            # Search all ships for pipe
            if has_pipe(gamemap, element)
                indicator_position = element
            end
        end
        # VertexCoord: no indicator (can't delete nodes)

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
    primary_centroid = get_surface_centroid(gamemap, :primary)
    primary_centroid === nothing && return nothing
    primary_offset = get_ship_render_offset(gamemap, :primary)
    primary_pos = primary_centroid + primary_offset

    for (ship_name, ship) in gamemap.ships
        ship_name == :primary && continue

        ship_centroid = get_surface_centroid(gamemap, ship_name)
        ship_centroid === nothing && continue
        ship_pos = ship_centroid + get_render_offset(ship)

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

        beam_colour === nothing && continue

        # Beam parameter tuning: default num_elements now 50; connected ships have reduced scale and noise
        local_num_elements = 50
        local_noise = 0.1
        local_scale = 1.0f0
        if status isa ConnectedDockStat
            local_scale *= 0.5f0
            local_noise *= 0.25
        end

        render_beam!(
            queue,
            glmap,
            gameticks,
            primary_pos,
            ship_pos;
            num_elements = local_num_elements,
            noise_magnitude = local_noise,
            scale = local_scale,
            colour = beam_colour,
            draw_height = Int32(HexFlowRendering.RENDER_HEIGHT_TRACTOR_BEAM)
        )
    end

    return nothing
end

# ===============================================================
# FlowCalculator Command System Input Handlers
# ===============================================================
# These functions enqueue commands to the FlowCalculator thread
# instead of directly mutating the game map, decoupling UI from
# simulation logic.
# ===============================================================

"Check if clicked coordinate is on a ship with non-zero render position offset (blocks interactions during visual effects)"
function is_on_offset_ship(coord, gamemap::GameMap)::Bool
    if coord isa TileCoord
        # Check if tile is on a ship with offset
        ship_name = get_surface_shiptag(gamemap, coord)
        if isnothing(ship_name)
            # Check if there's a component at this coord
            ship_name = get_component_shiptag(gamemap, coord)
        end
        if !isnothing(ship_name)
            offset = get_ship_render_offset(gamemap, ship_name)
            return offset != AxialCoord(0.0, 0.0)
        end
    elseif coord isa EdgeCoord
        # Check if pipe is on a ship with offset
        ship_name = get_pipe_shiptag(gamemap, coord)
        if !isnothing(ship_name)
            offset = get_ship_render_offset(gamemap, ship_name)
            return offset != AxialCoord(0.0, 0.0)
        end
    elseif coord isa VertexCoord
        # Check node's ship
        node = to_nodecoord(coord)
        ship_name = find_ship_for_node(node, gamemap)
        offset = get_ship_render_offset(gamemap, ship_name)
        return offset != AxialCoord(0.0, 0.0)
    end
    return false
end

"Checks if two commands are trying to do the same thing, by checking for equivalence excluding IDs"
function is_same_command(cmd1::Union{MapEditCommand, Nothing}, cmd2::Union{MapEditCommand, Nothing})::Bool
    if isnothing(cmd1) || isnothing(cmd2)
        return false
    end
    # check equality from all but the ID field by setting IDs equal
    cmd2_with_id_from_cmd1 = @set cmd2.id = cmd1.id
    return cmd1 == cmd2_with_id_from_cmd1
end

"""
Enqueue command if it is not a duplicate of the last command sent, and within a minimum time interval to prevent spamming
Used for commands that may be triggered repeatedly while holding mouse button down (e.g. pipe placement)
"""
function enqueue_if_not_duplicates!(
        command_queue::CommandQueue,
        command::MapEditCommand,
        threadsafe_console_push::Function,
        inputstate::InputState
    )

    threshhold_time = 0.5 # time in seconds to ignore duplicate commands
    time_since_last = time() - inputstate.last_command_time
    enough_time_passed = time_since_last >= threshhold_time

    if !is_same_command(command, command_queue.last_command) || enough_time_passed
        try_enqueue_command!(command_queue, command, threadsafe_console_push)
        inputstate.last_command_time = time()
    end

    return nothing
end

"Enqueue tile placement command when in TILE mode and mouse clicked"
function flowcalc_tileplacer!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        threadsafe_console_push::Function,
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

    # Block interactions on ships with non-zero render offset
    if is_on_offset_ship(coord, gamemap)
        return nothing
    end

    command = create_set_tile_command(command_queue, coord, state.pendingcomponent, state.toolrotation, state.toolmirrored)
    try_enqueue_command!(command_queue, command, threadsafe_console_push)
    return nothing
end

"Drive the unified placement-state machine for STANDARD mode."
function flowcalc_standard_interaction!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        threadsafe_console_push::Function,
        window::GLFW.Window;
        mouse_captured::Bool = false
    )
    state = placement_state(inputstate)
    if !is_standard_family_state(state)
        return nothing
    end

    if !editor_capabilities_enabled(inputstate)
        inputstate.pendingpipebehavior = ScrapPipeBehav()
    end

    poll_pipe_chain_response!(inputstate)

    if is_active_standard_interaction_state(state) && get_inrising!(inputstate, GLFW.MOUSE_BUTTON_RIGHT, window)
        inputstate.gui_inputs[:consume_right_click] = true
        clear_placement_state!(inputstate)
        return nothing
    end

    left_rising = get_inrising!(inputstate, GLFW.MOUSE_BUTTON_LEFT, window)
    left_falling = get_infalling!(inputstate, GLFW.MOUSE_BUTTON_LEFT, window)
    left_held = get_instate(GLFW.MOUSE_BUTTON_LEFT, window)

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

        candidate = get_active_pipe_chain_candidate(source_node, inputstate, gamemap)
        if isnothing(candidate) || !candidate.can_commit
            return nothing
        end

        response_channel = Channel{CommandStatus}(1)
        command = create_pipe_chain_command(command_queue, inputstate, candidate; response_channel = response_channel)
        isnothing(command) && return nothing

        success, _ = try_enqueue_command!(command_queue, command, threadsafe_console_push)
        if success
            set_placement_state!(inputstate, PlacementPipeChainState(
                source_node = source_node,
                pending_next_source_node = candidate.far_node,
                pending_response_channel = response_channel,
            ))
        end
        return nothing
    end

    if mouse_captured
        if !(state isa PlacementReadyState) && !left_held
            clear_placement_state!(inputstate)
        end
        return nothing
    end

    if state isa PlacementMoveState
        update_active_move_rotation!(inputstate)

        if left_falling
            command = create_active_move_command(command_queue, inputstate, gamemap)
            if !isnothing(command)
                try_enqueue_command!(command_queue, command, threadsafe_console_push)
            end
            clear_placement_state!(inputstate)
        end

        return nothing
    end

    if state isa PlacementPressedState
        if !isnothing(state.move_target) && !state.hold_threshold_crossed && time() - state.press_started_at >= 0.5
            if state.move_target_valid
                activate_move_drag!(inputstate)
                return nothing
            end

            set_placement_state!(inputstate, PlacementPressedState(
                press_started_at = state.press_started_at,
                press_cursor_cart = state.press_cursor_cart,
                click_tile = state.click_tile,
                move_target = state.move_target,
                move_target_valid = state.move_target_valid,
                hold_threshold_crossed = true,
            ))
            state = placement_state(inputstate)::PlacementPressedState
        end

        if left_falling
            command = create_move_short_click_command(command_queue, inputstate)
            if !isnothing(command)
                try_enqueue_command!(command_queue, command, threadsafe_console_push)
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

    if !left_rising
        return nothing
    end

    source_node = resolve_pipe_source_node(inputstate)
    if !isnothing(source_node)
        if !is_pipe_source_on_offset_ship(source_node, gamemap)
            clear_action_popup_selection!(inputstate)
            set_placement_state!(inputstate, PlacementPipeChainState(source_node = source_node))
        end
        return nothing
    end

    target = get_move_hover_target(inputstate, gamemap)
    if isnothing(target)
        clear_action_popup_selection!(inputstate)
        pressed_element = get_clicked(inputstate)
        if pressed_element isa TileCoord || pressed_element isa EdgeCoord
            cursor_cart = get_cursor_cart(inputstate)
            if cursor_cart !== nothing
                set_placement_state!(inputstate, PlacementPressedState(
                    press_started_at = time(),
                    press_cursor_cart = cursor_cart,
                    click_tile = round_to_tile(cursor_cart),
                    move_target = nothing,
                    move_target_valid = false,
                ))
            end
        end
        return nothing
    end

    set_move_hold_target!(inputstate, target)
    return nothing
end

"Enqueue delete command when in DELETE mode and mouse clicked"
function flowcalc_deleteplacer!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        threadsafe_console_push::Function,
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

    element = get_clicked(inputstate)

    # Nodes (vertices) cannot be deleted — filter before command creation
    if element isa VertexCoord
        threadsafe_console_push("Cannot delete a node")
        return nothing
    end

    # Block interactions on ships with non-zero render offset
    if is_on_offset_ship(element, gamemap)
        return nothing
    end

    command = create_delete_command(command_queue, element)
    try_enqueue_command!(command_queue, command, threadsafe_console_push)

    return nothing
end

"Enqueue surface tile add/remove command when in SURFACE_EDIT mode and mouse clicked"
function flowcalc_surfaceeditor!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        threadsafe_console_push::Function,
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

    # Block interactions on ships with non-zero render offset
    if is_on_offset_ship(coord, gamemap)
        return nothing
    end

    # Toggle: if surface exists on any ship, remove it; otherwise add it
    foundsurf, _ = is_on_surface_tile_any_ship(coord, gamemap)
    if foundsurf
        command = create_remove_ship_surface_command(command_queue, coord)
    else
        command = create_add_ship_surface_command(command_queue, coord)
    end

    try_enqueue_command!(command_queue, command, threadsafe_console_push)
    return nothing
end

"""
Handle right-click: cancel an active MOVE or PIPE interaction, or open an action popup.
Uses `get_clicked` hit-testing to route precisely. Clicking on a component opens
the component popup, clicking on gaps between components or empty surface opens
the ship popup. Works in all placement modes.
"""
function flowcalc_rightclick_action!(inputstate::InputState, gamemap::GameMap, window::GLFW.Window)
    get(inputstate.gui_inputs, :consume_right_click, false)::Bool && return nothing
    get_inrising!(inputstate, GLFW.MOUSE_BUTTON_RIGHT, window) || return nothing
    state = placement_state(inputstate)
    if !(state isa PlacementReadyState)
        return nothing
    end

    # Need valid cursor position
    isnothing(inputstate.cursor_x) && return nothing
    isnothing(inputstate.cursor_y) && return nothing

    cursor_cart = CartesianCoord(inputstate.cursor_x, inputstate.cursor_y)
    element = get_clicked(inputstate)

    # Clear any previous selection state
    inputstate.rightclick_selectedcoord = nothing
    inputstate.rightclick_selectedship = nothing

    #= ---------- Component target ----------- =#
    if element isa TileCoord
        is_on_offset_ship(element, gamemap) && return nothing
        tilecomp = get_component(gamemap, element)
        if !isnothing(tilecomp)
            actions = get_actions(tilecomp)
            inputstate.rightclick_selectedcoord = element
            inputstate.action_popup = ActionPopupState(
                target = ComponentPopupTarget(element),
                world_position = to_cartesian(element),
                actions = actions,
                window_title = "Actions",
            )
            return nothing
        end
    end

    #= ---------- Ship target (non-component surface) ----------- =#
    tile = round_to_tile(cursor_cart)
    ship_name = get_surface_shiptag(gamemap, tile)
    isnothing(ship_name) && return nothing
    is_on_offset_ship(tile, gamemap) && return nothing

    actions = get_ship_actions(gamemap, ship_name)
    display_name = safe_ship_display_name(ship_name)

    inputstate.rightclick_selectedship = ship_name
    inputstate.action_popup = ActionPopupState(
        target = ShipPopupTarget(ship_name),
        world_position = cursor_cart,
        actions = actions,
        window_title = "Ship: $(display_name)",
    )
    return nothing
end

"""
Build docking action list for a ship. Returns a tuple of `ActionInfo`.
"""
function get_ship_actions(gamemap::GameMap, ship_name::Symbol)::Tuple
    is_primary = (ship_name === :primary)
    status = get_docking_status(gamemap, ship_name)
    is_connected = status isa ConnectedDockStat

    make_primary_action = ActionInfo(
        :make_primary, "Make Primary", !is_primary && is_connected,
        is_primary ? "This is already the primary ship" : (!is_connected ? "Ship is not docked" : "Swap this ship to be your primary"),
        is_primary ? nothing : "Make this your primary ship? The current primary will become a docked ship."
    )

    redock_action = ActionInfo(
        :redock, "Redock", !is_primary && is_connected,
        is_primary ? "Cannot redock the primary ship" : "Choose a new docking position",
    )

    can_depart, depart_reason = if !is_primary && is_connected
        check_departure_pipe_connections(gamemap, ship_name)
    else
        (false, "")
    end
    undock_tooltip = if is_primary
        "Cannot undock the primary ship"
    elseif !is_connected
        "Ship is not docked"
    elseif !can_depart
        depart_reason
    else
        "Undock and depart this ship"
    end
    undock_action = ActionInfo(
        :undock, "Undock", !is_primary && is_connected && can_depart,
        undock_tooltip,
        !is_primary && is_connected && can_depart ? "Undock this ship? It will depart along its docking axis." : nothing
    )

    return (make_primary_action, redock_action, undock_action)
end

"""
Execute a ship-level docking action. Runs on the render thread.
`:redock` enters interactive placement mode; others create commands directly.
"""
function execute_ship_action!(;
        ship_name::Symbol,
        action_id::Symbol,
        flowcalc_ipc::FlowCalculatorIPC,
        viewstate::ViewState,
        inputstate::InputState
    )
    if action_id === :make_primary
        current_map = deepcopy(flowcalc_ipc.get_snapshot().gamemap)
        success, reason = swap_primary!(current_map, ship_name)
        if success
            cmd = create_map_override_command(flowcalc_ipc.command_queue, current_map)
            try_enqueue_command!(flowcalc_ipc.command_queue, cmd, flowcalc_ipc.console_push)
        end
        flowcalc_ipc.console_push(reason)

    elseif action_id === :redock
        _enter_redock_mode!(inputstate, flowcalc_ipc, ship_name)

    elseif action_id === :undock
        current_map = deepcopy(flowcalc_ipc.get_snapshot().gamemap)
        max_bounds = calc_max_reachable_bounds(viewstate)
        success, reason = depart_ship!(current_map, ship_name; max_view_bounds = max_bounds)
        if success
            cmd = create_map_override_command(flowcalc_ipc.command_queue, current_map)
            try_enqueue_command!(flowcalc_ipc.command_queue, cmd, flowcalc_ipc.console_push)
        end
        flowcalc_ipc.console_push(reason)

    else
        flowcalc_ipc.console_push("Unknown ship action: $(action_id)")
    end
    return nothing
end

#= ---------- Redock Placement Mode ----------- =#

const REDOCK_GHOST_VALID   = SVector{4, Float32}(0.3, 1.0, 0.3, 0.6)
const REDOCK_GHOST_INVALID = SVector{4, Float32}(1.0, 0.3, 0.3, 0.6)
const REDOCK_EXCLUSION_COL = SVector{4, Float32}(1.0, 0.78, 0.2, 0.15)

"Render ghost tiles for the ship being repositioned, coloured by placement validity."
function _render_redock_ghost!(queue::Vector{<:RenderCommand}, glmap::GLObjectMap, inputstate::InputState)
    state = placement_state(inputstate)
    state isa PlacementRedockState || return nothing
    rs = state

    cursor_tile = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
    delta = cursor_tile - rs.original_centre
    valid = _check_redock_valid(rs, delta)
    core_colour = valid ? REDOCK_GHOST_VALID : REDOCK_GHOST_INVALID

    ghost_height = Int32(HexFlowRendering.RENDER_HEIGHT_OVERLAY_BASE + 500)

    # Core ship tiles
    for tile in rs.ship_tiles
        push!(queue, render_basic_tile(
            glmap, :ShipSurface_basic, HexFrame.Q_POS, tile + delta;
            colour = core_colour, transparency = 0.5, draw_height = ghost_height,
        ))
    end

    # Exclusion ring (2-tile buffer zone)
    for tile in rs.exclusion_ring
        push!(queue, render_basic_tile(
            glmap, :ShipSurface_basic, HexFrame.Q_POS, tile + delta;
            colour = REDOCK_EXCLUSION_COL, transparency = 0.5, draw_height = ghost_height,
        ))
    end

    return nothing
end

"Enter the interactive redock placement mode, caching tile/node sets for fast per-frame validation."
function _enter_redock_mode!(inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC, ship_name::Symbol)
    gamemap = flowcalc_ipc.get_snapshot().gamemap
    core_tiles = collect_surface_tiles!(Set{TileCoord}(), gamemap; ship_name = ship_name)
    ring1 = expand_tileset!(Set{TileCoord}(), core_tiles)
    ring2 = expand_tileset!(Set{TileCoord}(), ring1)

    ship_elems = FlowEngine.list_elements(gamemap; ship_name = ship_name)
    ship_nodes = Set(keys(FlowEngine.list_nodes(ship_elems)))

    other_tiles = collect_surface_tiles!(Set{TileCoord}(), gamemap; exclude_ship = ship_name)
    other_nodes = Set{NodeCoord}()
    for name in get_all_ship_names(gamemap)
        name === ship_name && continue
        union!(other_nodes, keys(FlowEngine.list_nodes(FlowEngine.list_elements(gamemap; ship_name = name))))
    end

    centroid = get_surface_centroid(gamemap, ship_name)
    original_centre = isnothing(centroid) ? TileCoord(0, 0) : round_to_tile(centroid)

    enter_redock_placement_state!(inputstate, PlacementRedockState(
        ship_name = ship_name,
        ship_tiles = core_tiles,
        exclusion_ring = setdiff(ring2, core_tiles),
        ship_nodes = ship_nodes,
        other_ship_tiles = other_tiles,
        other_ship_nodes = other_nodes,
        original_centre = original_centre,
    ))
    flowcalc_ipc.console_push("Redock mode: click to place $(ship_name), ESC to cancel")
    return nothing
end

"Check whether the given tile offset produces a valid placement for the redocking ship."
function _check_redock_valid(rs::RedockModeState, delta::TileCoord)::Bool
    # Surface exclusion: ship core + 2-ring buffer must not overlap other ships
    for tile in rs.ship_tiles
        (tile + delta) in rs.other_ship_tiles && return false
    end
    for tile in rs.exclusion_ring
        (tile + delta) in rs.other_ship_tiles && return false
    end
    # Node bridge: no circuit node of this ship may coincide with another ship's nodes
    for node in rs.ship_nodes
        NodeCoord(node.tile + delta, node.dir) in rs.other_ship_nodes && return false
    end
    return true
end

"Enqueue a `RedockShipCommand` to relocate the ship after the player confirms placement."
function _execute_redock!(rs::RedockModeState, delta::TileCoord, flowcalc_ipc::FlowCalculatorIPC)
    cmd = create_redock_ship_command(flowcalc_ipc.command_queue, rs.ship_name, delta)
    try_enqueue_command!(flowcalc_ipc.command_queue, cmd, flowcalc_ipc.console_push)
    return nothing
end

"Handle left-click during redock mode: validate placement and enqueue the redock command."
function _handle_redock_click!(inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC, window::GLFW.Window; mouse_captured::Bool = false)
    state = placement_state(inputstate)
    state isa PlacementRedockState || return nothing
    rs = state

    # Right-click cancels redock mode (same as ESC)
    if get_inrising!(inputstate, GLFW.MOUSE_BUTTON_RIGHT, window)
        inputstate.gui_inputs[:consume_right_click] = true
        enter_ready_placement_state!(inputstate)
        flowcalc_ipc.console_push("Redock cancelled")
        return nothing
    end

    mouse_captured && return nothing

    !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left) && return nothing
    (isnothing(inputstate.cursor_x) || isnothing(inputstate.cursor_y)) && return nothing

    cursor_tile = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
    delta = cursor_tile - rs.original_centre

    if !_check_redock_valid(rs, delta)
        flowcalc_ipc.console_push("Invalid redock position, too close to another ship or nodes overlap!")
        return nothing
    end

    _execute_redock!(rs, delta, flowcalc_ipc)
    enter_ready_placement_state!(inputstate)
    return nothing
end
