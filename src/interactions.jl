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

"Poll key rising edges and mutate InputState and FlowCalculatorSharedState (tool rotation, placement mode, pause, time warp, exit)"
function poll_keys!(inputstate::InputState, shared_state::FlowCalculatorSharedState, window::GLFW.Window)
    # R key for tool rotation
    get_inrising!(inputstate, GLFW.KEY_R, window) && (inputstate.toolrotation = next_enum_val(inputstate.toolrotation))

    # F key for tile-component mirroring
    if inputstate.placementmode == TILE || inputstate.placementmode == MOVE
        get_inrising!(inputstate, GLFW.KEY_F, window) && (inputstate.toolmirrored = !inputstate.toolmirrored)
    end

    # ESC key — cancel redock > dismiss action popup > cancel time warp > close space map > clear selection > exit to inspect mode > toggle pause menu
    if get_inrising!(inputstate, GLFW.KEY_ESCAPE, window)
        if inputstate.placementmode == REDOCK
            set_placementmode!(inputstate, INSPECT)
        elseif !isnothing(inputstate.action_popup)
            inputstate.action_popup = nothing
            inputstate.rightclick_selectedcoord = nothing
            inputstate.rightclick_selectedship = nothing
        elseif inputstate.spacemap_active
            time_prog = get(inputstate.gui_inputs, :time_progressing, false)::Bool
            if time_prog
                current_time = get(inputstate.gui_inputs, :current_spacemap_time, 0.0)::Float64
                @atomic :monotonic shared_state.target_spacemap_time = current_time
            else
                inputstate.spacemap_active = false
            end
        elseif !isnothing(inputstate.selectedcoord)
            inputstate.selectedcoord = nothing
        elseif inputstate.placementmode != INSPECT
            set_placementmode!(inputstate, INSPECT)
        else
            inputstate.escape_menu_active = !inputstate.escape_menu_active
        end
    end

    # SPACE key — toggle FlowCalculator pause
    if get_inrising!(inputstate, GLFW.KEY_SPACE, window)
        current_paused = @atomic :monotonic shared_state.is_paused
        @atomic :monotonic shared_state.is_paused = !current_paused
    end

    # ` key to toggle editor mode
    get_inrising!(inputstate, GLFW.KEY_GRAVE_ACCENT, window) && (inputstate.editor_mode = !inputstate.editor_mode)
    # \ key to toggle dev utils menu
    get_inrising!(inputstate, GLFW.KEY_BACKSLASH, window) && (inputstate.dev_utils_menu_active = !inputstate.dev_utils_menu_active)
    # M key to toggle space map (blocked during time progression)
    if get_inrising!(inputstate, GLFW.KEY_M, window)
        time_prog = get(inputstate.gui_inputs, :time_progressing, false)::Bool
        if !time_prog
            inputstate.spacemap_active = !inputstate.spacemap_active
        end
    end

    # Number keys 1-3 for standard placement modes
    get_inrising!(inputstate, GLFW.KEY_1, window) && set_placementmode!(inputstate, INSPECT)
    get_inrising!(inputstate, GLFW.KEY_2, window) && set_placementmode!(inputstate, MOVE)
    get_inrising!(inputstate, GLFW.KEY_3, window) && set_placementmode!(inputstate, PIPE)

    # Number keys 4-6 for editor-only placement modes
    if inputstate.editor_mode
        get_inrising!(inputstate, GLFW.KEY_4, window) && set_placementmode!(inputstate, DELETE)
        get_inrising!(inputstate, GLFW.KEY_5, window) && set_placementmode!(inputstate, TILE)
        get_inrising!(inputstate, GLFW.KEY_6, window) && set_placementmode!(inputstate, SURFACE_EDIT)
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

# ===============================================================
# Pending Component Updates
# ===============================================================

"Update pending component type to match current toolbar selection"
function pendingcomponent_typeupdate!(inputstate::InputState)
    toolbar_has_changed = inputstate.last_toolbar != inputstate.toolbar
    inputstate.last_toolbar = inputstate.toolbar

    if toolbar_has_changed
        inputstate.pendingcomponent = deepcopy(component_list[inputstate.toolbar])
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

    # Redock ghost — show ship footprint and exclusion zone following the cursor
    if inputstate.placementmode == REDOCK
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
                colour = selection_colour, draw_height = Int32(100100),
                scale = 2.5
            )
        )
    end

    if inputstate.placementmode == TILE
        coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
        component = component_list[inputstate.toolbar]
        rotation = map_rotation(component, inputstate.toolrotation)
        mirrored = map_mirroring(component, inputstate.toolmirrored)
        target_ship = find_ship_for_placement(component, coord, gamemap; rotation = rotation, mirrored = mirrored)
        ghost_colour = isnothing(target_ship) ? GHOST_COLOUR_INVALID : GHOST_COLOUR_VALID
        render_base_elem!(queue, component; glmap = glmap, rotation = rotation, mirrored = mirrored, position = coord, transparency = 0.5, colour = ghost_colour, render_height_offset = Int32(100000))
    end

    if inputstate.placementmode == PIPE
        # Get clicked element; convert VertexCoord to nearest EdgeCoord
        element = get_clicked(inputstate)
        if element isa VertexCoord
            element = round_to_edge(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
        end

        if element isa EdgeCoord
            edge::EdgeCoord = element
            pipe_behav = get_pipe(gamemap, edge)
            existing_pipe = !isnothing(pipe_behav)

            if existing_pipe
                # Hovering over existing pipe — red delete indicator overlay
                render_pipe_base!(
                    queue, pipe_behav; glmap = glmap, rotation = HexFrame.Q_POS,
                    position = edge, transparency = 0.5, colour = GHOST_COLOUR_INVALID, render_height_offset = Int32(100000)
                )
            else
                # Empty edge — show placement ghost with validity colouring
                pipe_behav = inputstate.pendingpipebehavior
                rotation = HexFrame.Q_POS

                # Check if both nodes are on valid ship surfaces, or allow off-ship placement
                valid_placement = !isnothing(find_ship_containing_edge(gamemap, edge))
                if !valid_placement
                    can_place, _, _ = can_place_pipe_offship(edge, gamemap)
                    valid_placement = can_place
                end
                if valid_placement
                    render_pipe_base!(queue, pipe_behav; glmap = glmap, rotation = rotation, position = edge, transparency = 0.5)
                else
                    render_pipe_base!(queue, pipe_behav; glmap = glmap, rotation = rotation, position = edge, transparency = 0.5, colour = GHOST_COLOUR_INVALID)
                end
            end
        elseif element isa TileCoord
            tilecoord::TileCoord = element
            axis = hovered_tile_pipe_axis(inputstate, tilecoord)
            existing_frag = get_tile_pipe_frag_any_ship(gamemap, tilecoord, axis)

            if !isnothing(existing_frag) && !isempty(existing_frag)
                render_tile_pipe_frag_ghost!(queue, glmap, tilecoord, axis, existing_frag; transparency = 0.5, colour = GHOST_COLOUR_INVALID, render_height_offset = 100000)
            else
                frag = get_pending_tile_pipe_frag(inputstate)
                if !isnothing(frag)
                    ghost_colour = can_modify_tile_pipe(gamemap, tilecoord) ? GHOST_COLOUR_VALID : GHOST_COLOUR_INVALID
                    render_tile_pipe_frag_ghost!(queue, glmap, tilecoord, axis, frag; transparency = 0.5, colour = ghost_colour, render_height_offset = 100000)
                end
            end
        end
    end

    if inputstate.placementmode == MOVE
        #= ---------- Move hover indicator (no selection yet) ----------- =#
        if inputstate.selectedcoord === nothing
            element = get_clicked(inputstate)
            hover_target = nothing
            can_move = false

            if element isa TileCoord
                tilecomp = get_component(gamemap, element)
                if !isnothing(tilecomp)
                    can_move_result, _ = can_be_moved(tilecomp)
                    can_move = can_move_result
                    if tilecomp.component isa MultiPipeTileCompBehav
                        axis = hovered_tile_pipe_axis(inputstate, element)
                        frag = get_tile_pipe(tilecomp.component, axis)
                        if !isempty(frag)
                            move_colour = can_move ? SVector{4, Float32}(1.0, 0.9, 0.2, 0.75) : SVector{4, Float32}(1.0, 0.4, 0.4, 0.75)
                            render_tile_pipe_frag_ghost!(queue, glmap, element, axis, frag; transparency = 0.7, colour = move_colour, render_height_offset = 100100)
                        end
                    else
                        hover_target = element
                    end
                end
            elseif element isa EdgeCoord
                pipe_behav = get_pipe(gamemap, element)
                if !isnothing(pipe_behav)
                    hover_target = element
                    can_move_result, _ = can_pipe_be_moved(pipe_behav)
                    can_move = can_move_result
                end
            end

            if !isnothing(hover_target)
                indicator_colour = can_move ?
                    SVector{4, Float32}(1.0, 0.9, 0.2, 0.6) :  # Yellow — valid move target
                    SVector{4, Float32}(1.0, 0.4, 0.4, 0.6)     # Red — cannot move
                push!(
                    queue, render_basic_sprite(
                        glmap, :MoveArrow_arrow_start, rotmat_2D(0.0), hover_target;
                        colour = indicator_colour, draw_height = Int32(100100), scale = 1.5
                    )
                )
            end
        end

        # Tile move ghost
        if inputstate.selectedcoord isa TileCoord
            tilecomp = get_component(gamemap, inputstate.selectedcoord)
            if !isnothing(tilecomp)
                if inputstate.selected_tile_pipe_axis !== nothing && tilecomp.component isa MultiPipeTileCompBehav
                    src_axis = inputstate.selected_tile_pipe_axis
                    src_frag = get_tile_pipe(tilecomp.component, src_axis)
                    if !isempty(src_frag)
                        render_tile_pipe_frag_ghost!(queue, glmap, inputstate.selectedcoord, src_axis, src_frag; transparency = 0.95, colour = SVector{4, Float32}(0.95, 0.85, 0.2, 0.9), render_height_offset = 100120)

                        coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
                        dst_axis = hovered_tile_pipe_axis(inputstate, coord)
                        if !(coord == inputstate.selectedcoord && dst_axis == src_axis)
                            ghost_colour = can_move_tile_pipe_to(gamemap, coord, dst_axis) ? GHOST_COLOUR_VALID : GHOST_COLOUR_INVALID
                            render_tile_pipe_frag_ghost!(queue, glmap, coord, dst_axis, src_frag; transparency = 0.5, colour = ghost_colour, render_height_offset = 100000)
                        end
                    end
                else
                    coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
                    rotation = map_rotation(tilecomp, rotate(tilecomp.rotation, inputstate.toolrotation))
                    requested_mirror = xor(tilecomp.mirrored, inputstate.toolmirrored)
                    mirrored = map_mirroring(tilecomp, requested_mirror)
                    target_ship = find_ship_for_placement(tilecomp.component, coord, gamemap; rotation = rotation, mirrored = mirrored)
                    ghost_colour = isnothing(target_ship) ? GHOST_COLOUR_INVALID : GHOST_COLOUR_VALID
                    render_base_elem!(queue, tilecomp; glmap = glmap, rotation = rotation, mirrored = mirrored, position = coord, transparency = 0.5, colour = ghost_colour, render_height_offset = Int32(100000))
                end
            end
        end

        # Pipe move ghost, uses actual pipe behaviour for correct sprite
        if inputstate.selectedcoord isa EdgeCoord
            actual_pipe = get_pipe(gamemap, inputstate.selectedcoord)
            if !isnothing(actual_pipe)
                ghost_edge = round_to_edge(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))

                # Check if both nodes are on valid ship surfaces, or allow off-ship placement
                valid_dest = !isnothing(find_ship_containing_edge(gamemap, ghost_edge))
                if !valid_dest
                    can_place, _, _ = can_place_pipe_offship(ghost_edge, gamemap)
                    valid_dest = can_place
                end

                ghost_colour = valid_dest ? GHOST_COLOUR_VALID : GHOST_PIPE_COLOUR_INVALID
                render_pipe_base!(
                    queue, actual_pipe; glmap = glmap, rotation = HexFrame.Q_POS,
                    position = ghost_edge, transparency = 0.5, colour = ghost_colour, render_height_offset = Int32(100000)
                )
            end
        end

        # Move arrow (start circle, end arrowhead, animated dashes)
        if !isnothing(inputstate.selectedcoord)
            startcoord = inputstate.selectedcoord
            if !(inputstate.selectedcoord isa TileCoord && inputstate.selected_tile_pipe_axis !== nothing)
                push!(
                    queue, render_basic_sprite(
                        glmap, :MoveArrow_arrow_start, rotmat_2D(0.0), startcoord;
                        colour = SVector{4, Float32}(0.8, 0.8, 0.2, 1.0), draw_height = Int32(100200)
                    )
                )
            end

            # Determine end coordinate based on selected type
            if inputstate.selectedcoord isa TileCoord
                endcoord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
            elseif inputstate.selectedcoord isa EdgeCoord
                endcoord = round_to_edge(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
            else
                return
            end

            # Render arrowhead
            linevec = glvec(endcoord) - glvec(startcoord)
            angle = rad2deg(atan(-linevec[2], linevec[1]))
            push!(
                queue, render_basic_sprite(
                    glmap, :MoveArrow_arrow_head, rotmat_2D(angle), endcoord;
                    colour = SVector{4, Float32}(0.8, 0.8, 0.2, 1.0), draw_height = Int32(100200)
                )
            )

            # Render animated dashes along the line
            dash_spacing = 0.5f0 # Tile units between dash centers
            animation_speed = 0.03f0 # Animation speed multiplier
            end_fade_distance = 0.2f0 # Distance from end where dashes disappear

            # Render line if long enough for meaningful spacing
            line_length = norm(linevec)
            if line_length > dash_spacing * 0.5
                # Calculate animation offset (loops every dash_spacing units)
                anim_offset_units = (gamestate.ticks * animation_speed) % dash_spacing
                anim_offset_param = anim_offset_units / line_length
                dash_step = dash_spacing / line_length # Step size in parameter space
                fade_boundary = 1.0 - (end_fade_distance / line_length) # Fade boundary in parameter space

                # Generate dash positions along the line
                dash_range = anim_offset_param:dash_step:(fade_boundary - dash_step * 0.01)
                for t in dash_range
                    dash_pos_vec = glvec(startcoord) + t * linevec
                    dash_pos = CartesianCoord(dash_pos_vec[1], dash_pos_vec[2])
                    push!(
                        queue, render_basic_sprite(
                            glmap, :MoveArrow_dash, rotmat_2D(angle), dash_pos;
                            colour = SVector{4, Float32}(0.8, 0.8, 0.2, 1.0), draw_height = Int32(100200)
                        )
                    )
                end
            end
        end
    end

    if inputstate.placementmode == SURFACE_EDIT
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

    if inputstate.placementmode == DELETE
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
        threadsafe_console_push::Function
    )
    if inputstate.placementmode != TILE
        return
    end
    if !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left)
        return
    end

    coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))

    # Block interactions on ships with non-zero render offset
    if is_on_offset_ship(coord, gamemap)
        return
    end

    command = create_set_tile_command(command_queue, coord, inputstate.pendingcomponent, inputstate.toolrotation, inputstate.toolmirrored)
    try_enqueue_command!(command_queue, command, threadsafe_console_push)
    return nothing
end

"Enqueue pipe placement command when in PIPE mode and mouse clicked or held"
function flowcalc_pipeplacer!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        threadsafe_console_push::Function
    )
    if inputstate.placementmode != PIPE
        return nothing
    end
    if !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left)
        return nothing
    end

    # Get clicked element; convert VertexCoord to nearest EdgeCoord
    element = get_clicked(inputstate)
    if element isa VertexCoord
        element = round_to_edge(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
    end

    # Block interactions on ships with non-zero render offset
    if is_on_offset_ship(element, gamemap)
        return nothing
    end

    if element isa EdgeCoord
        edge::EdgeCoord = element
        existing = has_pipe(gamemap, edge)
        if existing
            # Delete existing pipe (toggle behaviour)
            command = create_delete_command(command_queue, edge)
        else
            # Place new pipe
            command = create_set_pipe_behavior_command(command_queue, edge, inputstate.pendingpipebehavior)
        end
    elseif element isa TileCoord
        tilecoord::TileCoord = element
        axis = hovered_tile_pipe_axis(inputstate, tilecoord)
        existing_frag = get_tile_pipe_frag_any_ship(gamemap, tilecoord, axis)

        frag = if !isnothing(existing_frag) && !isempty(existing_frag)
            NoPipeBehavFrag()
        else
            get_pending_tile_pipe_frag(inputstate)
        end
        frag === nothing && return nothing

        command = HexFlowCalculator.ModifyTilePipeCommand(
            id = command_queue.next_command_id(),
            tile = tilecoord,
            axis = axis,
            frag = frag,
            response_channel = nothing
        )
    else
        return nothing
    end

    try_enqueue_command!(command_queue, command, threadsafe_console_push)
    return nothing
end

"Enqueue move command when in MOVE mode, handling selection and destination"
function flowcalc_moveplacer!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        threadsafe_console_push::Function
    )
    if inputstate.placementmode != MOVE
        return
    end
    if !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left)
        return
    end

    element = get_clicked(inputstate)
    if element === nothing
        return
    end

    # Block interactions on ships with non-zero render offset
    if is_on_offset_ship(element, gamemap)
        return
    end

    # If no selection yet, set it
    if inputstate.selectedcoord === nothing
        if element isa VertexCoord
            threadsafe_console_push("Can't move a node")
            return
        end

        # Check if something is present at the coordinate
        # NOTE: checks not authoritative here as gamemap may change before command is processed
        if element isa TileCoord
            tilecomp = get_component(gamemap, element)
            if isnothing(tilecomp)
                threadsafe_console_push("No component found at $(element)")
                return
            end
            can_move, reason = can_be_moved(tilecomp)
            if !can_move
                threadsafe_console_push("Cannot select component at $(element): $reason")
                return
            end

            if tilecomp.component isa MultiPipeTileCompBehav
                axis = hovered_tile_pipe_axis(inputstate, element)
                frag = get_tile_pipe(tilecomp.component, axis)
                if isempty(frag)
                    threadsafe_console_push("No tile pipe found on axis $(axis) at $(element)")
                    return
                end

                inputstate.selectedcoord = element
                inputstate.selected_tile_pipe_axis = axis
                inputstate.toolrotation = HexFrame.Q_POS # Reset delta rotation so ghost matches source
                inputstate.toolmirrored = false
                threadsafe_console_push("Selected axis $(axis) on multi-pipe at $(element)")
                return
            end
        elseif element isa EdgeCoord
            if !has_pipe(gamemap, element)
                threadsafe_console_push("No pipe found at $(element)")
                return
            end
        end

        inputstate.selectedcoord = element
        inputstate.selected_tile_pipe_axis = nothing
        inputstate.toolrotation = HexFrame.Q_POS # Reset delta rotation so ghost matches source
        inputstate.toolmirrored = false
        threadsafe_console_push("Selected $(element) for moving")
        return
    end

    # Handle deselection or move
    selected = inputstate.selectedcoord

    if selected isa TileCoord && inputstate.selected_tile_pipe_axis !== nothing
        src_axis = inputstate.selected_tile_pipe_axis
        dst_tile = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
        dst_axis = hovered_tile_pipe_axis(inputstate, dst_tile)

        if dst_tile == selected && dst_axis == src_axis
            inputstate.selectedcoord = nothing
            inputstate.selected_tile_pipe_axis = nothing
            threadsafe_console_push("Deselected multi-pipe axis")
            return
        end

        command = HexFlowCalculator.MoveTilePipeCommand(
            id = command_queue.next_command_id(),
            src_tile = selected,
            src_axis = src_axis,
            dst_tile = dst_tile,
            dst_axis = dst_axis,
            response_channel = nothing
        )
        try_enqueue_command!(command_queue, command, threadsafe_console_push)

        inputstate.selectedcoord = nothing
        inputstate.selected_tile_pipe_axis = nothing
        return
    end

    # Generic tile/edge move logic (non-multi-pipe or edge pipes)
    if selected == element && selected isa EdgeCoord
        # Pipes have no rotation — same-edge click is a no-op, deselect
        inputstate.selectedcoord = nothing
        inputstate.selected_tile_pipe_axis = nothing
        threadsafe_console_push("Deselected $(element)")
        return
    end

    # Create move command
    source = selected
    if source isa TileCoord
        destination = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
    elseif source isa EdgeCoord
        destination = round_to_edge(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
    end
    command = create_move_command(command_queue, source, destination, inputstate.toolrotation, inputstate.toolmirrored)
    try_enqueue_command!(command_queue, command, threadsafe_console_push)

    inputstate.selectedcoord = nothing
    inputstate.selected_tile_pipe_axis = nothing
    return nothing
end

"Enqueue delete command when in DELETE mode and mouse clicked"
function flowcalc_deleteplacer!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        threadsafe_console_push::Function
    )
    if inputstate.placementmode != DELETE
        return
    end
    if !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left)
        return
    end

    element = get_clicked(inputstate)

    # Nodes (vertices) cannot be deleted — filter before command creation
    if element isa VertexCoord
        threadsafe_console_push("Cannot delete a node")
        return
    end

    # Block interactions on ships with non-zero render offset
    if is_on_offset_ship(element, gamemap)
        return
    end

    command = create_delete_command(command_queue, element)
    try_enqueue_command!(command_queue, command, threadsafe_console_push)

    return nothing
end

"Handle click in INSPECT mode: enqueue a ClickTileCommand for on_click! behaviour"
function flowcalc_inspect_click!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        threadsafe_console_push::Function
    )
    inputstate.placementmode != INSPECT && return
    !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left) && return

    cursor_cart = CartesianCoord(inputstate.cursor_x, inputstate.cursor_y)
    tile = round_to_tile(cursor_cart)
    is_on_offset_ship(tile, gamemap) && return # skip if on offset ship to prevent interactions during visual effects

    tile_center_cart = to_cartesian(tile)
    unrotated_clicksite = cursor_cart - tile_center_cart
    command = create_click_tile_command(command_queue, tile, unrotated_clicksite)
    try_enqueue_command!(command_queue, command, threadsafe_console_push)
    return nothing
end

"Enqueue surface tile add/remove command when in SURFACE_EDIT mode and mouse clicked"
function flowcalc_surfaceeditor!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        threadsafe_console_push::Function
    )
    if inputstate.placementmode != SURFACE_EDIT
        return
    end
    if !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left)
        return
    end

    coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))

    # Block interactions on ships with non-zero render offset
    if is_on_offset_ship(coord, gamemap)
        return
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
Handle right-click: open action popup for a component or ship.
Uses `get_clicked` hit-testing to route precisely. Clicking on a component opens
the component popup, clicking on gaps between components or empty surface opens
the ship popup. Works in all placement modes.
"""
function flowcalc_rightclick_action!(inputstate::InputState, gamemap::GameMap, window::GLFW.Window)
    get_inrising!(inputstate, GLFW.MOUSE_BUTTON_RIGHT, window) || return nothing

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
    rs = inputstate.redock_state
    isnothing(rs) && return nothing

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

    set_placementmode!(inputstate, REDOCK)
    inputstate.redock_state = RedockModeState(
        ship_name = ship_name,
        ship_tiles = core_tiles,
        exclusion_ring = setdiff(ring2, core_tiles),
        ship_nodes = ship_nodes,
        other_ship_tiles = other_tiles,
        other_ship_nodes = other_nodes,
        original_centre = original_centre,
    )
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
function _handle_redock_click!(inputstate::InputState, flowcalc_ipc::FlowCalculatorIPC, window::GLFW.Window)
    rs = inputstate.redock_state
    isnothing(rs) && return nothing

    # Right-click cancels redock mode (same as ESC)
    if get_inrising!(inputstate, GLFW.MOUSE_BUTTON_RIGHT, window)
        set_placementmode!(inputstate, INSPECT)
        flowcalc_ipc.console_push("Redock cancelled")
        return nothing
    end

    !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left) && return nothing
    (isnothing(inputstate.cursor_x) || isnothing(inputstate.cursor_y)) && return nothing

    cursor_tile = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
    delta = cursor_tile - rs.original_centre

    if !_check_redock_valid(rs, delta)
        flowcalc_ipc.console_push("Invalid redock position, too close to another ship or nodes overlap!")
        return nothing
    end

    _execute_redock!(rs, delta, flowcalc_ipc)
    set_placementmode!(inputstate, INSPECT)
    return nothing
end
