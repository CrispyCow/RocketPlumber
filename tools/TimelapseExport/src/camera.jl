struct WorldRect
    x_min::Float64
    y_min::Float64
    x_max::Float64
    y_max::Float64
end

struct CameraViewport
    rect::WorldRect
    view_x::Float32
    view_y::Float32
    zoom::Float32
end

struct KeyframeSchedule
    keyframe_index::Int
    frame_count::Int
    duration_seconds::Float64
    first_output_frame::Int
end

struct FrameSchedule
    keyframes::Vector{KeyframeSchedule}
    total_frames::Int
    duration_seconds::Float64
end

"Display a world rectangle in a compact diagnostic form."
Base.show(io::IO, rect::WorldRect) = print(io, "WorldRect(x=$(rect.x_min), y=$(rect.y_min), xmax=$(rect.x_max), ymax=$(rect.y_max))")

const SHIP_SURFACE_SPRITE_WIDTH_PIXELS = 518.0
const SHIP_SURFACE_SPRITE_HEIGHT_PIXELS = 449.0

"Return the tile-area bounds used by automatic cameras, excluding all render offsets."
function tile_area_bounds(gamemap)::WorldRect
    if isempty(gamemap.surface_shiptags)
        return WorldRect(-5.0, -5.0, 5.0, 5.0)
    end
    bounds = get_cartesian_bounds(gamemap)
    half_width = SHIP_SURFACE_SPRITE_WIDTH_PIXELS / (2.0 * _hex_size_pixels())
    half_height = SHIP_SURFACE_SPRITE_HEIGHT_PIXELS / (2.0 * _hex_size_pixels())
    return WorldRect(
        Float64(bounds.X_NEG) - half_width,
        Float64(bounds.Y_NEG) - half_height,
        Float64(bounds.X_POS) + half_width,
        Float64(bounds.Y_POS) + half_height,
    )
end

function _inflate(rect::WorldRect, x_amount::Float64, y_amount::Float64)
    return WorldRect(rect.x_min - x_amount, rect.y_min - y_amount, rect.x_max + x_amount, rect.y_max + y_amount)
end

function _union(left::WorldRect, right::WorldRect)
    return WorldRect(min(left.x_min, right.x_min), min(left.y_min, right.y_min), max(left.x_max, right.x_max), max(left.y_max, right.y_max))
end

function _contains(outer::WorldRect, inner::WorldRect)
    return inner.x_min >= outer.x_min && inner.x_max <= outer.x_max && inner.y_min >= outer.y_min && inner.y_max <= outer.y_max
end

function _hex_size_pixels()::Float64
    if isdefined(Runtime, :HexFlowRendering)
        return Float64(Runtime.HexFlowRendering.hex_size_pixels)
    end
    # Inspection and pure camera tests fall back to the default pixel scale.
    return 256.0
end

"Apply fractional and absolute per-side padding to a world rectangle."
function padded_bounds(rect::WorldRect, fraction::Float64, minimum::Float64)
    (isfinite(fraction) && fraction >= 0.0) || throw(ArgumentError("padding fraction must be finite and non-negative"))
    (isfinite(minimum) && minimum >= 0.0) || throw(ArgumentError("minimum padding must be finite and non-negative"))
    width = rect.x_max - rect.x_min
    height = rect.y_max - rect.y_min
    return _inflate(rect, max(minimum, fraction * width), max(minimum, fraction * height))
end

"Expand a world rectangle symmetrically until it has the requested pixel aspect ratio."
function aspect_expand(rect::WorldRect, pixel_width::Integer, pixel_height::Integer)::WorldRect
    pixel_width > 0 && pixel_height > 0 || throw(ArgumentError("pixel dimensions must be positive"))
    width = rect.x_max - rect.x_min
    height = rect.y_max - rect.y_min
    width > 0.0 && height > 0.0 || throw(ArgumentError("world rectangle must have positive area"))
    aspect = Float64(pixel_width) / Float64(pixel_height)
    if width / height < aspect
        required_width = aspect * height
        amount = (required_width - width) / 2.0
        return _inflate(rect, amount, 0.0)
    end
    required_height = width / aspect
    amount = (required_height - height) / 2.0
    return _inflate(rect, 0.0, amount)
end

"Build the final camera viewport for a world rectangle."
function camera_viewport(rect::WorldRect, width::Integer, height::Integer)::CameraViewport
    centre_x = (rect.x_min + rect.x_max) / 2.0
    centre_y = (rect.y_min + rect.y_max) / 2.0
    world_width = rect.x_max - rect.x_min
    world_height = rect.y_max - rect.y_min
    hex_size_pixels = _hex_size_pixels()
    zoom = min(width / (hex_size_pixels * world_width), height / (hex_size_pixels * world_height))
    return CameraViewport(rect, Float32(-centre_x), Float32(-centre_y), Float32(zoom))
end

"Build all camera rectangles before rendering so expand mode is complete and non-shrinking."
function build_camera_schedule(entries::AbstractVector{<:TimelineEntry}, options::ExportOptions)::Vector{CameraViewport}
    isempty(entries) && throw(ArgumentError("camera schedule needs at least one keyframe"))
    if options.camera == :manual
        rect = WorldRect(options.viewport...)
        return fill(camera_viewport(aspect_expand(rect, options.width, options.height), options.width, options.height), length(entries))
    end
    unpadded = map(entry -> tile_area_bounds(entry.gamemap), entries)
    if options.camera == :fixed
        union_rect = reduce(_union, unpadded)
        rect = aspect_expand(padded_bounds(union_rect, options.padding, options.min_padding), options.width, options.height)
        viewport = camera_viewport(rect, options.width, options.height)
        return fill(viewport, length(entries))
    end

    viewports = CameraViewport[]
    previous = nothing
    for content in unpadded
        padded = padded_bounds(content, options.padding, options.min_padding)
        if isnothing(previous)
            rect = aspect_expand(padded, options.width, options.height)
            previous = camera_viewport(rect, options.width, options.height)
        elseif _contains(previous.rect, padded)
            # Preserve the exact prior rectangle when no new base tile requires growth.
        else
            rect = aspect_expand(_union(previous.rect, padded), options.width, options.height)
            previous = camera_viewport(rect, options.width, options.height)
        end
        push!(viewports, previous)
    end
    return viewports
end

"Calculate independent per-keyframe frame counts with endpoint holds."
function build_frame_schedule(keyframe_count::Integer, options::ExportOptions)::FrameSchedule
    keyframe_count > 0 || throw(ArgumentError("frame schedule needs at least one keyframe"))
    durations = fill(options.keyframe_seconds, keyframe_count)
    durations[1] += options.start_hold
    durations[end] += options.end_hold
    keyframes = KeyframeSchedule[]
    first_frame = 0
    for (index, duration) in enumerate(durations)
        frame_count = max(1, round(Int, duration * options.fps))
        push!(keyframes, KeyframeSchedule(index, frame_count, duration, first_frame))
        first_frame += frame_count
    end
    return FrameSchedule(keyframes, first_frame, first_frame / options.fps)
end

"Return the deterministic animation tick for a local output frame in a held keyframe."
function animation_tick(gamemap, local_output_frame::Integer, fps::Integer)::Int64
    base_tick = get_simulated_ticks(gamemap)
    return base_tick + Int64(floor(Float64(local_output_frame) * Float64(BASE_UPS) / Float64(fps)))
end

# Names used by the plan and by tests.
expand_camera_rect(rect::WorldRect, width::Integer, height::Integer) = aspect_expand(rect, width, height)
