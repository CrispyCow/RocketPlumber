# ===============================================================
# Keyboard Input Polling
# ===============================================================

using FlowMap

"Poll raw key state and mutate only ViewState (movement + zoom)"
function poll_keys!(viewstate::ViewState, window::GLFW.Window)
    # Skip on first frame (last_update_time not yet initialized)
    if viewstate.last_update_time == 0.0
        viewstate.last_update_time = time()
        return nothing
    end

    # Framerate-independent rates
    pan_rate_per_sec = 7.0f0 
    zoom_rate_per_sec = 2.50f0

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

    # === NEW: Apply zoom and pan limits ===
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
        Y_NEG = centre_y - half_span_y
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
function get_max_reachable_bounds(viewstate::ViewState)
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
    
    return (X_POS=Float64(max_right), X_NEG=Float64(min_left), Y_POS=Float64(max_top), Y_NEG=Float64(min_bottom))
end

"Poll key rising edges and mutate only InputState (tool rotation, placement mode, pause, exit)"
function poll_keys!(inputstate::InputState, window::GLFW.Window)
    # R key for tool rotation
    get_inrising!(inputstate, GLFW.KEY_R, window) && (inputstate.toolrotation = next_enum_val(inputstate.toolrotation))

    # ESC key to exit placement mode or toggle pause menu
    if get_inrising!(inputstate, GLFW.KEY_ESCAPE, window)
        if inputstate.spacemap_active
            inputstate.spacemap_active = false
        elseif inputstate.placementmode != INSPECT
            inputstate.placementmode = INSPECT # Escape always returns to inspect mode
        else
            inputstate.escape_menu_active = !inputstate.escape_menu_active # Toggle pause menu when already in inspect mode
            inputstate.selectedcoord = nothing
        end
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

    # Number keys 1-4 for standard placement modes
    get_inrising!(inputstate, GLFW.KEY_1, window) && (inputstate.placementmode = INSPECT)
    get_inrising!(inputstate, GLFW.KEY_2, window) && (inputstate.placementmode = MOVE)
    get_inrising!(inputstate, GLFW.KEY_3, window) && (inputstate.placementmode = PIPE)
    get_inrising!(inputstate, GLFW.KEY_4, window) && (inputstate.placementmode = DELETE)

    # Number keys 5-6 for editor-only placement modes
    if inputstate.editor_mode
        get_inrising!(inputstate, GLFW.KEY_5, window) && (inputstate.placementmode = TILE)
        get_inrising!(inputstate, GLFW.KEY_6, window) && (inputstate.placementmode = SURFACE_EDIT)
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

"Poll scroll wheel deltas and update toolbar index in InputState"
function poll_scrollwheel!(inputstate::InputState)
    if isdefined(Main, :take_scrollstate!)
        xoff, yoff = Main.take_scrollstate!()
        if yoff != 0.0
            tmp_toolbar = inputstate.toolbar + yoff
            inputstate.toolbar = round(clamp(tmp_toolbar, 1, length(component_list)))
        end
    end
    return nothing
end

"""
Unified per-frame input handling. Polls window state, cursor position, view keys, scroll wheel, and action keys.
Order matters: window sizes must be updated before cursor transform.
Accepts optional CImGui IO pointer to guard keyboard input when typing in UI fields.
"""
function handle_inputs!(inputstate::InputState, viewstate::ViewState, window::GLFW.Window, cimgui_io::Union{Nothing, Ptr{CImGui.lib.ImGuiIO}} = nothing)
    poll_windowstate!(viewstate, window) # Window/framebuffer sizes (needed for correct cursor mapping)
    poll_cursorpos!(inputstate, viewstate, window) # Cursor position (uses updated window sizes)
    poll_keys!(viewstate, window) # View keys (pan/zoom) - always active
    poll_scrollwheel!(inputstate) # Scroll wheel -> toolbar
    
    # Action/mode/pause/exit keys - only when not typing in UI
    if isnothing(cimgui_io) || !unsafe_load(cimgui_io.WantCaptureKeyboard)
        poll_keys!(inputstate, window)
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

"""
Render cursor ghosts for tile/pipe placement and move operations.
Shows semi-transparent previews of where components will be placed/moved.
"""
function render_cursor_ghosts!(queue::Vector{RenderCommand}, glmap::GLObjectMap, inputstate::InputState, gamemap::GameMap, gamestate::GameState)
    if inputstate.cursor_x === nothing || inputstate.cursor_y === nothing
        return
    end

    if inputstate.placementmode == TILE
        coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
        component = component_list[inputstate.toolbar]
        rotation = map_rotation(component, inputstate.toolrotation)

        # Check if valid placement on ANY ship (using find_valid_ship_for_placement)
        target_ship = find_valid_ship_for_placement(component, coord, gamemap; rotation = rotation)
        if !isnothing(target_ship)
            render_base_elem!(queue, component; glmap = glmap, rotation = rotation, position = coord, transparency = 0.5, render_height_offset = Int32(100000)) # Tile ghost above everything
        end
    end

    if inputstate.placementmode == PIPE
        # Get clicked element; convert VertexCoord to nearest EdgeCoord
        element = get_clicked(inputstate)
        if element isa VertexCoord
            element = round_to_edge(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
        end

        if element isa EdgeCoord
            edge::EdgeCoord = element
            pipe_behav = inputstate.pendingpipebehavior
            rotation = HexFrame.Q_POS

            # Check if pipe endpoints are on ANY ship's surface
            v1_node = to_nodecoord(edge.v1)
            v2_node = to_nodecoord(edge.v2)
            valid_ship_found = false
            for (ship_name, _) in gamemap.ships
                v1_valid, _ = is_node_on_ship_surface(v1_node, gamemap; ship_name = ship_name)
                v2_valid, _ = is_node_on_ship_surface(v2_node, gamemap; ship_name = ship_name)
                if v1_valid && v2_valid
                    valid_ship_found = true
                    break
                end
            end

            if valid_ship_found
                render_pipe_base!(queue, pipe_behav; glmap = glmap, rotation = rotation, position = edge, transparency = 0.5)
            end
        elseif element isa TileCoord
            tilecoord::TileCoord = element
            component = get_tile_pipe_equivalent(inputstate.pendingpipebehavior)
            if !isnothing(component)
                rotation = map_rotation(component, inputstate.toolrotation)
                target_ship = find_valid_ship_for_placement(component, tilecoord, gamemap; rotation = rotation)
                if !isnothing(target_ship)
                    render_base_elem!(queue, component; glmap = glmap, rotation = rotation, position = tilecoord, transparency = 0.5, render_height_offset = Int32(100000))
                end
            end
        end
    end

    if inputstate.placementmode == MOVE
        # Tile move ghost
        if inputstate.selectedcoord isa TileCoord
            # Search for component in any ship
            source_ship = find_ship_with_component(gamemap, inputstate.selectedcoord)
            if !isnothing(source_ship)
                coord = round_to_tile(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
                tilecomp = get_component(gamemap, inputstate.selectedcoord; ship_name = source_ship)
                rotation = map_rotation(tilecomp, rotate(tilecomp.rotation, inputstate.toolrotation))

                # Check if destination is valid on any ship
                target_ship = find_valid_ship_for_placement(tilecomp.component, coord, gamemap; rotation = rotation)
                if !isnothing(target_ship)
                    render_base_elem!(queue, tilecomp; glmap = glmap, rotation = rotation, position = coord, transparency = 0.5, render_height_offset = Int32(100000))
                end
            end
        end

        # Pipe move ghost
        if inputstate.selectedcoord isa EdgeCoord
            source_ship = find_ship_with_pipe(gamemap, inputstate.selectedcoord)
            if !isnothing(source_ship)
                ghost_pipe = round_to_edge(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
                # Check if ghost position is valid on any ship
                v1_node = to_nodecoord(ghost_pipe.v1)
                v2_node = to_nodecoord(ghost_pipe.v2)
                valid_dest = false
                for (ship_name, _) in gamemap.ships
                    v1_valid, _ = is_node_on_ship_surface(v1_node, gamemap; ship_name = ship_name)
                    v2_valid, _ = is_node_on_ship_surface(v2_node, gamemap; ship_name = ship_name)
                    if v1_valid && v2_valid
                        valid_dest = true
                        break
                    end
                end
                if valid_dest
                    pipe_commands = render_pipe(glmap, ghost_pipe, HexFlowRendering.DEFAULT_PIPE_COLOUR; transparency = 0.5)
                    append!(queue, pipe_commands)
                end
            end
        end

        # Move arrow (start circle, end arrowhead, animated dashes)
        if !isnothing(inputstate.selectedcoord)
            startcoord = inputstate.selectedcoord
            push!(
                queue, render_basic_sprite(
                    glmap, :MoveArrow_arrow_start, rotmat_2D(0.0), startcoord;
                    colour = SVector{4, Float32}(0.8, 0.8, 0.2, 1.0), draw_height = Int32(100200)
                )
            )

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
        existing_ship = find_ship_for_surface(gamemap, coord)
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
            if !isnothing(find_ship_with_component(gamemap, element))
                indicator_position = element
            end
        elseif element isa EdgeCoord
            # Search all ships for pipe
            if !isnothing(find_ship_with_pipe(gamemap, element))
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
function render_docking_beams!(queue::Vector{RenderCommand}, glmap::GLObjectMap, gamemap::GameMap, gameticks::Int64)
    primary_centroid = get_surface_centroid(gamemap, :primary)
    primary_centroid === nothing && return nothing
    primary_offset = get_render_offset(get_ship(gamemap, :primary))
    primary_pos = primary_centroid + primary_offset

    for (ship_name, ship) in gamemap.ships
        ship_name == :primary && continue

        ship_centroid = get_surface_centroid(ship)
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
        ship_name = find_ship_for_surface(gamemap, coord)
        if isnothing(ship_name)
            # Check if there's a component at this coord
            ship_name = find_ship_with_component(gamemap, coord)
        end
        if !isnothing(ship_name)
            offset = get_ship_render_offset(gamemap, ship_name)
            return offset != AxialCoord(0.0, 0.0)
        end
    elseif coord isa EdgeCoord
        # Check if pipe is on a ship with offset
        ship_name = find_ship_with_pipe(gamemap, coord)
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
    
    command = create_set_tile_command(command_queue, coord, inputstate.pendingcomponent, inputstate.toolrotation)
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
        return
    end
    if !CImGui.IsMouseDown(CImGui.lib.ImGuiMouseButton_Left)
        return
    end

    # Get clicked element; convert VertexCoord to nearest EdgeCoord
    element = get_clicked(inputstate)
    if element isa VertexCoord
        element = round_to_edge(CartesianCoord(inputstate.cursor_x, inputstate.cursor_y))
    end
    
    # Block interactions on ships with non-zero render offset
    if is_on_offset_ship(element, gamemap)
        return
    end

    if element isa EdgeCoord
        edge::EdgeCoord = element
        command = create_set_pipe_behavior_command(command_queue, edge, inputstate.pendingpipebehavior)
    elseif element isa TileCoord
        tilecoord::TileCoord = element
        pipecomp = get_tile_pipe_equivalent(inputstate.pendingpipebehavior)
        if pipecomp === nothing
            return
        end
        command = create_set_tile_command(command_queue, tilecoord, pipecomp, inputstate.toolrotation)
    end

    enqueue_if_not_duplicates!(command_queue, command, threadsafe_console_push, inputstate)
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
            found, _ = has_component_any_ship(gamemap, element)
            if !found
                threadsafe_console_push("No component found at $(element)")
                return
            end
            tilecomp, _ = get_component_any_ship(gamemap, element)
            can_move, reason = can_be_moved(tilecomp)
            if !can_move
                threadsafe_console_push("Cannot select component at $(element): $reason")
                return
            end
        elseif element isa EdgeCoord
            foundp, shipp = has_pipe_any_ship(gamemap, element)
            if !foundp
                threadsafe_console_push("No pipe found at $(element)")
                return
            end
        end

        inputstate.selectedcoord = element
        threadsafe_console_push("Selected $(element) for moving")
        return
    end

    # Handle deselection or move
    selected = inputstate.selectedcoord
    if selected == element
        inputstate.selectedcoord = nothing
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
    command = create_move_command(command_queue, source, destination, inputstate.toolrotation)
    try_enqueue_command!(command_queue, command, threadsafe_console_push)

    inputstate.selectedcoord = nothing
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
    
    # Block interactions on ships with non-zero render offset
    if is_on_offset_ship(element, gamemap)
        return
    end
    
    command = create_delete_command(command_queue, element)
    try_enqueue_command!(command_queue, command, threadsafe_console_push)

    return nothing
end

"Enqueue tile click command when in INSPECT mode and mouse clicked"
function flowcalc_interactor!(
        command_queue::CommandQueue,
        inputstate::InputState,
        gamemap::GameMap,
        threadsafe_console_push::Function
    )
    if inputstate.placementmode != INSPECT
        return
    end
    if !CImGui.IsMouseClicked(CImGui.lib.ImGuiMouseButton_Left)
        return
    end
    
    # Get clicked tile and calculate click site relative to tile center
    cursor_cart = CartesianCoord(inputstate.cursor_x, inputstate.cursor_y)
    tile = round_to_tile(cursor_cart)
    
    # Block interactions on ships with non-zero render offset
    if is_on_offset_ship(tile, gamemap)
        return
    end
    
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

"Handle atomic pause toggle for FlowCalculator shared state"
function handle_flowcalc_sharedstate!(
        inputstate::InputState,
        shared_state::FlowCalculatorSharedState,
        window::GLFW.Window,
        threadsafe_console_push::Function
    )
    if get_inrising!(inputstate, GLFW.KEY_SPACE, window)
        # Atomic read-modify-write
        current_paused = @atomic :monotonic shared_state.is_paused
        @atomic :monotonic shared_state.is_paused = !current_paused
        threadsafe_console_push("Requested " * (!current_paused ? "Pause" : "Unpause"))
    end
    return nothing
end
