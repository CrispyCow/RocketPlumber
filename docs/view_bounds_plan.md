# View Bounds and Zoom/Pan Limiting Implementation Plan

## Overview

Implement logic to limit how far the user can zoom out and pan in the game, based on the extent of elements in the `GameMap`. This improves user experience by preventing users from getting "lost" in empty space and keeping the ship(s) visible.

## Design Decisions

### Coordinate Systems

The game uses two main coordinate systems:
- **Axial Coordinates** (`TileCoord`, `AxialCoord`): Native hex grid coordinates with `q` and `r` components
- **Cartesian Coordinates** (`CartesianCoord`): Screen-space coordinates with `x` and `y` components

The conversion from axial to cartesian is:
```julia
hex_to_pixel_mat = @SMatrix [3/2 0; -sqrt(3)/2 -sqrt(3)]
CartesianCoord = hex_to_pixel_mat * AxialCoord
```

### Bounds Functions

Two bounds functions are needed:

1. **`get_axial_bounds`**: Returns extremes in each of the 6 `HexAxis` directions (Q_POS, R_NEG, S_POS, Q_NEG, R_POS, S_NEG). This is useful for hex-aware calculations and future features.

2. **`get_cartesian_bounds`**: Returns extremes in 4 cartesian directions (X_POS, X_NEG, Y_POS, Y_NEG). This is directly usable for screen-space pan/zoom limiting.

### Bounds Storage and Update

- Store cartesian bounds in `ViewState` (since it's the view that needs bounding)
- Update bounds in `user_handler!` before input polling so bounds are fresh for limit calculations
- Enforce minimum ship span of 10 units (5 in each direction from centre) to handle small/empty maps

### Pan and Zoom Limits

- **Zoom limit**: Prevent zooming out beyond where the longer axis of the ship takes up ~1/3 of the screen
- **Pan limit**: Ensure at least 5% of the ship's bounding box remains visible on screen

---

## Implementation Phases

### Phase 1: FlowEngine - Bounds Calculation Functions

**File**: `local_packages/FlowEngine/src/FlowEngine.jl`

#### 1.1 Add Exports

Add to the export section (around line 26):
```julia
export get_axial_bounds, get_cartesian_bounds
```

#### 1.2 Implement `get_axial_bounds`

Location: Add after `get_all_surfaces_combined` function (around line 525)

```julia
"""
Calculate the axial coordinate extremes for all surface tiles across all ships.
Returns a `HexFrame.AxialBounds` named tuple with the tile coordinate furthest from the origin in each HexAxis direction.
The projection onto each axis uses the dot product with the hex vertex vectors.

Returns: `HexFrame.AxialBounds` (fields: Q_POS, R_NEG, S_POS, Q_NEG, R_POS, S_NEG)
"""
function get_axial_bounds(gamemap::GameMap)::HexFrame.AxialBounds
    combined_surface = get_all_surfaces_combined(gamemap)
    
    # Handle empty map case - return origin for all directions
    if isempty(combined_surface)
        origin = TileCoord(0, 0)
        return (Q_POS=origin, R_NEG=origin, S_POS=origin, Q_NEG=origin, R_POS=origin, S_NEG=origin)
    end
    
    # Initialise tracking for each HexAxis direction
    # Store (max_projection, tile) for each direction
    extremes = Dict{HexFrame.HexAxis, Tuple{Float64, TileCoord}}()
    for axis in instances(HexFrame.HexAxis)
        extremes[axis] = (-Inf, TileCoord(0, 0))
    end
    
    # Single iteration through all surface tiles
    for tile in combined_surface
        tile_axial = AxialCoord(Float64(tile.q), Float64(tile.r))
        
        for axis in instances(HexFrame.HexAxis)
            # Get the unit vector for this axis direction
            axis_vec = HexFrame.hex_vert_vecs[axis]
            # Project tile onto this direction (dot product)
            projection = tile_axial.q * axis_vec.q + tile_axial.r * axis_vec.r
            
            if projection > extremes[axis][1]
                extremes[axis] = (projection, tile)
            end
        end
    end
    
    return (
        Q_POS = extremes[HexFrame.Q_POS][2],
        R_NEG = extremes[HexFrame.R_NEG][2],
        S_POS = extremes[HexFrame.S_POS][2],
        Q_NEG = extremes[HexFrame.Q_NEG][2],
        R_POS = extremes[HexFrame.R_POS][2],
        S_NEG = extremes[HexFrame.S_NEG][2]
    )
end
```

#### 1.3 Implement `get_cartesian_bounds`

Location: Add immediately after `get_axial_bounds`

```julia
"""
Calculate the cartesian coordinate extremes for all surface tiles across all ships.
Returns a `HexFrame.CartesianBounds` named tuple with the cartesian x/y values furthest from the origin in each direction.

Returns: `HexFrame.CartesianBounds` (fields: X_POS, X_NEG, Y_POS, Y_NEG)

Note: Y_POS is the maximum y value (top of screen), Y_NEG is minimum (bottom).
X_POS is maximum x (right), X_NEG is minimum (left).
"""
function get_cartesian_bounds(gamemap::GameMap)::HexFrame.CartesianBounds
    combined_surface = get_all_surfaces_combined(gamemap)
    
    # Handle empty map case - return zeros
    if isempty(combined_surface)
        return (X_POS=0.0, X_NEG=0.0, Y_POS=0.0, Y_NEG=0.0)
    end
    
    # Initialise with first tile
    first_tile = first(combined_surface)
    first_cart = HexFrame.to_cartesian(first_tile)
    x_max, x_min = first_cart.x, first_cart.x
    y_max, y_min = first_cart.y, first_cart.y
    
    # Single iteration through remaining tiles
    for tile in combined_surface
        cart = HexFrame.to_cartesian(tile)
        x_max = max(x_max, cart.x)
        x_min = min(x_min, cart.x)
        y_max = max(y_max, cart.y)
        y_min = min(y_min, cart.y)
    end
    
    return (X_POS=x_max, X_NEG=x_min, Y_POS=y_max, Y_NEG=y_min)
end
```

---

### Phase 2: FlowEngine - Unit Tests

**File**: `local_packages/FlowEngine/test/runtests.jl`

Add the following tests at the end of the file (before any closing statements):

```julia
# -----------------------------
# Phase X: Bounds Calculation Tests
# -----------------------------

@testset "get_axial_bounds" begin
    # Test empty map returns origin for all directions
    empty_map = GameMap()
    delete_surface_tile!(empty_map, TileCoord(0, 0))  # Remove default origin tile
    bounds = get_axial_bounds(empty_map)
    @test bounds.Q_POS == TileCoord(0, 0)
    @test bounds.Q_NEG == TileCoord(0, 0)
    
    # Test single tile at origin
    single_map = GameMap()  # Has origin tile by default
    bounds_single = get_axial_bounds(single_map)
    @test bounds_single.Q_POS == TileCoord(0, 0)
    
    # Test multiple tiles - Q_POS direction should find tile with max q
    multi_map = GameMap()
    set_surface_tile!(multi_map, TileCoord(5, 0))   # Far in Q_POS direction
    set_surface_tile!(multi_map, TileCoord(-3, 0))  # Far in Q_NEG direction
    set_surface_tile!(multi_map, TileCoord(0, 5))   # Far in R_POS direction
    set_surface_tile!(multi_map, TileCoord(0, -3))  # Far in R_NEG direction
    bounds_multi = get_axial_bounds(multi_map)
    
    # Verify directions work (exact tile may vary based on projection math)
    @test bounds_multi.Q_POS.q >= 0  # Should be positive q
    @test bounds_multi.Q_NEG.q <= 0  # Should be negative q
end

@testset "get_cartesian_bounds" begin
    # Test empty map returns zeros
    empty_map = GameMap()
    delete_surface_tile!(empty_map, TileCoord(0, 0))
    bounds = get_cartesian_bounds(empty_map)
    @test bounds.X_POS == 0.0
    @test bounds.X_NEG == 0.0
    @test bounds.Y_POS == 0.0
    @test bounds.Y_NEG == 0.0
    
    # Test single tile at origin
    single_map = GameMap()
    bounds_single = get_cartesian_bounds(single_map)
    @test bounds_single.X_POS == 0.0
    @test bounds_single.X_NEG == 0.0
    
    # Test tiles along q axis (positive q = positive x in cartesian)
    q_map = GameMap()
    set_surface_tile!(q_map, TileCoord(3, 0))
    set_surface_tile!(q_map, TileCoord(-2, 0))
    bounds_q = get_cartesian_bounds(q_map)
    
    # TileCoord(3, 0) -> CartesianCoord(4.5, -sqrt(3)*1.5) approximately
    # TileCoord(-2, 0) -> CartesianCoord(-3.0, sqrt(3)) approximately
    @test bounds_q.X_POS > 0.0
    @test bounds_q.X_NEG < 0.0
    
    # Test multi-ship bounds includes all ships
    multi_ship_map = GameMap()
    set_surface_tile!(multi_ship_map, TileCoord(10, 0))
    add_ship!(multi_ship_map, :second, ShipMap())
    set_surface_tile!(multi_ship_map, TileCoord(-10, 0); ship_name=:second)
    bounds_multi = get_cartesian_bounds(multi_ship_map)
    
    # Bounds should span both ships
    @test bounds_multi.X_POS > 10.0  # Far positive from primary
    @test bounds_multi.X_NEG < -10.0  # Far negative from secondary
end
```

---

### Phase 3: HexFrame - Type Aliases

**File**: `local_packages/HexFrame/src/HexFrame.jl`

#### 3.1 Add Type Aliases and Exports

Add near the top of the file (after the main type declarations) and export them so other packages can reference the named tuple types:

```julia
"Type alias for cartesian bounds tuple"
const CartesianBounds = NamedTuple{(:X_POS, :X_NEG, :Y_POS, :Y_NEG), NTuple{4, Float64}}

"Type alias for axial bounds tuple (tile coordinates for each hex axis direction)"
const AxialBounds = NamedTuple{(:Q_POS, :R_NEG, :S_POS, :Q_NEG, :R_POS, :S_NEG), NTuple{6, TileCoord}}
```

Update `export` list to include `CartesianBounds` and `AxialBounds` so they are available as `HexFrame.CartesianBounds` and `HexFrame.AxialBounds`.

---

### Phase 4: HexFlowControl - ViewState Update

**File**: `local_packages/HexFlowControl/src/HexFlowControl.jl`

#### 4.1 Update ViewState Struct (ship_bounds placement)

Place the `ship_bounds` field directly after `view_zoom` in `ViewState` and initialise it inline (do not create a separate default constant):

```julia
@kwdef mutable struct ViewState
    window_width::Int32 = 640
    window_height::Int32 = 480
    fb_width::Int32 = 640
    fb_height::Int32 = 480
    view_x::Float32 = 0.0
    view_y::Float32 = 0.0
    view_zoom::Float32 = 0.5
    ship_bounds::HexFrame.CartesianBounds = (X_POS=5.0, X_NEG=-5.0, Y_POS=5.0, Y_NEG=-5.0)
    frame_count::Int64 = 0
    last_update_time::Float64 = 0.0
    background_particles::Any = nothing  # ParticleManager - can't type without circular dep
    foreground_particles::Any = nothing  # ParticleManager - can't type without circular dep
end
```

Note: The `ship_bounds` type uses `HexFrame.CartesianBounds` which is exported from the `HexFrame` package.

---

### Phase 5: Interactions - Bounds Update Function

**File**: `src/interactions.jl`

#### 5.1 Add `update_ship_bounds!` Function

Add after the `poll_keys!` functions (around line 75):

```julia
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
    const MIN_SPAN = 10.0
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
```

### Phase 6: Interactions - Update poll_keys! for Limits


**File**: `src/interactions.jl`

#### 5.1 Modify `poll_keys!(viewstate::ViewState, window::GLFW.Window)`

Update the function (starting around line 6) to apply zoom and pan limits:

```julia
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
```

#### 5.2 Add `apply_view_limits!` Helper Function

Add after `poll_keys!`:

```julia
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
    # So visible area should be at most 3x the ship span
    max_visible_span = ship_span_max * 3.0f0
    
    # Calculate minimum zoom based on screen dimensions
    min_zoom_x = viewstate.fb_width / (max_visible_span * hex_size_pixels)
    min_zoom_y = viewstate.fb_height / (max_visible_span * hex_size_pixels)
    min_zoom = max(min_zoom_x, min_zoom_y)

    # Enforce a reasonable hard minimum zoom to prevent unusable views
    const MIN_VIEW_ZOOM = 0.01f0
    min_zoom = max(min_zoom, MIN_VIEW_ZOOM)
    
    # Clamp zoom (allow zooming in indefinitely, but limit zoom out)
    viewstate.view_zoom = max(viewstate.view_zoom, min_zoom)
    
    # Recalculate visible area after zoom clamp
    visible_width = viewstate.fb_width / (viewstate.view_zoom * hex_size_pixels)
    visible_height = viewstate.fb_height / (viewstate.view_zoom * hex_size_pixels)
    
    # === Pan Limit ===
    # Ensure at least 5% of ship bounds remains visible
    # view_x and view_y are in world units and represent the camera offset
    # (positive view_x moves the camera left, showing more positive x world coords)
    
    margin_fraction = 0.05f0  # 5% of ship must stay visible
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
```

---

### Phase 7: Gameloop - Call update_ship_bounds!

**File**: `src/gameloop.jl`

#### 6.1 Update `user_handler!` Function

Modify the function (around line 119) to call `update_ship_bounds!` before `GLFW.PollEvents()`:

```julia
"Handles user inputs and updates inputstate, viewstate, and enqueues commands to flowcalc_ipc"
function user_handler!(
        flowcalc_ipc::FlowCalculatorIPC,
        inputstate::InputState,
        viewstate::ViewState,
        snapshot::FlowCalculatorSnapshot,
        window::GLFW.Window
    )
    # Update ship bounds before input handling so limits are current
    update_ship_bounds!(viewstate, snapshot.gamemap)
    
    GLFW.PollEvents()
    cimgui_io = CImGui.GetIO()
    # ... rest of function unchanged
```

---

## File Change Summary

| File | Changes |
|------|---------|
| `local_packages/FlowEngine/src/FlowEngine.jl` | Add exports, implement `get_axial_bounds`, `get_cartesian_bounds` |
| `local_packages/FlowEngine/test/runtests.jl` | Add unit tests for both bounds functions |
| `local_packages/HexFrame/src/HexFrame.jl` | Add `CartesianBounds` and `AxialBounds` type aliases and export them |
| `local_packages/HexFlowControl/src/HexFlowControl.jl` | Add `ship_bounds` field to `ViewState` (placed directly after `view_zoom`) |
| `src/interactions.jl` | Add `update_ship_bounds!`, add `apply_view_limits!`, modify `poll_keys!` |
| `src/gameloop.jl` | Call `update_ship_bounds!` in `user_handler!` |

---

## Potential Issues and Considerations

### 1. Performance
- `get_cartesian_bounds` iterates over all surface tiles every frame
- For large maps this could become expensive
- **Mitigation**: Could cache bounds and only recompute when map changes (future optimisation)

### 2. Coordinate System Sign Conventions
- The view transform uses `view_x` and `view_y` as offsets applied to world coordinates
- Need to verify the pan clamping logic matches the actual camera behaviour
- **Recommendation**: Test interactively and adjust signs if camera moves opposite to expected

### 3. Multi-Ship Maps
- `get_all_surfaces_combined` already handles multi-ship aggregation
- Bounds will encompass all ships, which may not be ideal if ships are very far apart
- **Future enhancement**: Could add option to focus bounds on a specific ship

### 4. Empty Maps
- Both bounds functions return sensible defaults for empty maps (origin or zeros)
- The minimum span enforcement in `update_ship_bounds!` handles degenerate cases

### 5. Zoom Direction
- The zoom limit only restricts zooming OUT, not zooming IN
- This matches the stated requirement (limit how far you can zoom out)

### 6. Edge Cases for Pan Limits
- When the visible area is larger than the ship bounds, the camera centres on the ship
- This prevents oscillation or undefined behaviour at extreme zoom-out

---

## Testing Plan

### Manual Testing
1. Run the game with various maps (empty, small, large, multi-ship)
2. Verify zoom-out limit prevents losing sight of ships
3. Verify pan limits keep at least part of the ship visible
4. Test edge cases: empty map, single tile, very long/thin ship shapes

### Automated Testing
1. Run FlowEngine tests: `cd local_packages/FlowEngine; julia --project=. -e "using Pkg; Pkg.test()"`
2. Verify both `get_axial_bounds` and `get_cartesian_bounds` pass all tests, and add unit tests to verify:
   - `MIN_VIEW_ZOOM` enforcement via `apply_view_limits!` (zoom never drops below the constant)
   - `HexFrame.CartesianBounds` and `HexFrame.AxialBounds` are exported and usable from other packages

---

## Missing Instructions Identified

1. **Import statement**: The `update_ship_bounds!` function in `interactions.jl` will need `get_cartesian_bounds` from FlowEngine. This should already be available through the existing imports but should be verified.

2. **Initial bounds on map load**: The bounds should be updated when entering the game loop, not just during user input. Call `update_ship_bounds!` in `enter_gameloop` after loading the map.

3. **Scroll wheel zoom**: The `poll_scrollwheel!` function may also affect zoom. If it does, `apply_view_limits!` should be called after it as well, or integrate the limit check into `handle_inputs!` so all input paths are clamped.

4. **Minimum zoom limit**: Add a hard minimum zoom (e.g., `const MIN_VIEW_ZOOM = 0.01f0`) and ensure `apply_view_limits!` enforces `viewstate.view_zoom = max(viewstate.view_zoom, MIN_VIEW_ZOOM)`. Add a unit test to verify zoom never goes below this value when limits are applied.

5. **Export verification**: Ensure `HexFrame` exports `CartesianBounds` and `AxialBounds`. Add a small test in `HexFrame` or FlowEngine tests that references `HexFrame.CartesianBounds` and `HexFrame.AxialBounds` to catch missed exports during refactors.

---

## Questions for Clarification

None identified - the plan appears complete based on the provided requirements. The implementation should be straightforward given the existing codebase patterns.
