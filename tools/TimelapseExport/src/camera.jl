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

struct CameraState
    centre_x::Float64
    centre_y::Float64
    half_height::Float64
end

struct SmoothCameraPlan
    centre_x_values::Vector{Float64}
    centre_y_values::Vector{Float64}
    half_height_values::Vector{Float64}
    centre_x_slopes::Vector{Float64}
    centre_y_slopes::Vector{Float64}
    half_height_slopes::Vector{Float64}
    required_bounds::Vector{WorldRect}
    aspect::Float64
    width::Int
    height::Int
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

const SMOOTH_FILTER_RADIUS = 12
const SMOOTH_FILTER_SIGMA = 5.0
const SMOOTH_EXPANSION_HALF_LIFE = 20.0
const SMOOTH_CONTRACTION_HALF_LIFE = 40.0
const SMOOTH_FINAL_SETTLE_SECONDS = 1.0

function _camera_state(rect::WorldRect, aspect::Float64)::CameraState
    centre_x = (rect.x_min + rect.x_max) / 2.0
    centre_y = (rect.y_min + rect.y_max) / 2.0
    half_height = max((rect.y_max - rect.y_min) / 2.0, (rect.x_max - rect.x_min) / (2.0 * aspect))
    return CameraState(centre_x, centre_y, half_height)
end

function _required_half_height(rect::WorldRect, centre_x::Float64, centre_y::Float64, aspect::Float64)::Float64
    return max(
        centre_y - rect.y_min,
        rect.y_max - centre_y,
        (centre_x - rect.x_min) / aspect,
        (rect.x_max - centre_x) / aspect,
    )
end

function _containing_state(state::CameraState, rect::WorldRect, aspect::Float64)::CameraState
    half_height = max(state.half_height, _required_half_height(rect, state.centre_x, state.centre_y, aspect))
    return CameraState(state.centre_x, state.centre_y, half_height)
end

function _state_rect(state::CameraState, aspect::Float64)::WorldRect
    half_width = aspect * state.half_height
    return WorldRect(
        state.centre_x - half_width,
        state.centre_y - state.half_height,
        state.centre_x + half_width,
        state.centre_y + state.half_height,
    )
end

"Calculate shape-preserving cubic slopes for equally spaced values."
function _monotone_slopes(values::Vector{Float64})::Vector{Float64}
    length(values) >= 2 || throw(ArgumentError("camera interpolation needs at least two knots"))
    differences = diff(values)
    slopes = zeros(length(values))
    slopes[1] = differences[1]
    slopes[end] = differences[end]
    for index in 2:(length(values) - 1)
        previous = differences[index - 1]
        following = differences[index]
        if previous * following > 0.0
            slopes[index] = 2.0 * previous * following / (previous + following)
        end
    end
    return slopes
end

function _cubic_value(values::Vector{Float64}, slopes::Vector{Float64}, segment::Int, fraction::Float64)::Float64
    fraction_squared = fraction * fraction
    fraction_cubed = fraction_squared * fraction
    return (2.0 * fraction_cubed - 3.0 * fraction_squared + 1.0) * values[segment] +
        (fraction_cubed - 2.0 * fraction_squared + fraction) * slopes[segment] +
        (-2.0 * fraction_cubed + 3.0 * fraction_squared) * values[segment + 1] +
        (fraction_cubed - fraction_squared) * slopes[segment + 1]
end

"Build a filtered, framing-constrained camera trajectory from padded snapshot bounds."
function build_smooth_camera_plan(required_bounds::AbstractVector{WorldRect}, width::Integer, height::Integer)::SmoothCameraPlan
    isempty(required_bounds) && throw(ArgumentError("smooth camera plan needs at least one snapshot"))
    width > 0 && height > 0 || throw(ArgumentError("pixel dimensions must be positive"))
    bounds = collect(required_bounds)
    aspect = Float64(width) / Float64(height)
    fitted = [_camera_state(rect, aspect) for rect in bounds]
    anchors = CameraState[]

    # Gaussian filtering suppresses short-lived translation and scale changes.
    for index in eachindex(bounds)
        first_neighbour = max(firstindex(bounds), index - SMOOTH_FILTER_RADIUS)
        last_neighbour = min(lastindex(bounds), index + SMOOTH_FILTER_RADIUS)
        weight_sum = 0.0
        centre_x = 0.0
        centre_y = 0.0
        log_half_height = 0.0
        for neighbour in first_neighbour:last_neighbour
            offset = Float64(neighbour - index)
            weight = exp(-0.5 * (offset / SMOOTH_FILTER_SIGMA)^2)
            weight_sum += weight
            centre_x += weight * fitted[neighbour].centre_x
            centre_y += weight * fitted[neighbour].centre_y
            log_half_height += weight * log(fitted[neighbour].half_height)
        end
        centre_x /= weight_sum
        centre_y /= weight_sum
        half_height = exp(log_half_height / weight_sum)

        push!(anchors, _containing_state(CameraState(centre_x, centre_y, half_height), bounds[index], aspect))
    end

    # Each transition knot contains both geometries. Any remaining interpolation
    # pressure is handled by the same exact containment constraint at evaluation.
    transition_knots = CameraState[anchors[1]]
    for index in 1:(length(bounds) - 1)
        left = anchors[index]
        right = anchors[index + 1]
        state = CameraState(
            (left.centre_x + right.centre_x) / 2.0,
            (left.centre_y + right.centre_y) / 2.0,
            (left.half_height + right.half_height) / 2.0,
        )
        push!(transition_knots, _containing_state(state, _union(bounds[index], bounds[index + 1]), aspect))
    end
    push!(transition_knots, anchors[end])

    half_heights = [state.half_height for state in transition_knots]
    expansion_decay = exp2(-1.0 / SMOOTH_EXPANSION_HALF_LIFE)
    contraction_decay = exp2(-1.0 / SMOOTH_CONTRACTION_HALF_LIFE)

    # Anticipate future expansion without a hard cutoff
    for index in (length(half_heights) - 1):-1:1
        half_heights[index] = max(half_heights[index], expansion_decay * half_heights[index + 1])
    end

    # Recover more gradually after contraction
    for index in 2:length(half_heights)
        half_heights[index] = max(half_heights[index], contraction_decay * half_heights[index - 1])
    end
    knots = [CameraState(state.centre_x, state.centre_y, half_height) for (state, half_height) in zip(transition_knots, half_heights)]

    # The end hold finishes at a tight final fit after the filtered construction path.
    push!(knots, _camera_state(bounds[end], aspect))

    centre_x_values = [state.centre_x for state in knots]
    centre_y_values = [state.centre_y for state in knots]
    half_height_values = [state.half_height for state in knots]
    centre_x_slopes = _monotone_slopes(centre_x_values)
    centre_y_slopes = _monotone_slopes(centre_y_values)
    half_height_slopes = _monotone_slopes(half_height_values)
    for slopes in (centre_x_slopes, centre_y_slopes, half_height_slopes)
        slopes[1] = 0.0
        slopes[end] = 0.0
    end
    return SmoothCameraPlan(
        centre_x_values,
        centre_y_values,
        half_height_values,
        centre_x_slopes,
        centre_y_slopes,
        half_height_slopes,
        bounds,
        aspect,
        Int(width),
        Int(height),
    )
end

"Evaluate a smooth camera plan in snapshot coordinates while preserving current framing."
function evaluate_camera(plan::SmoothCameraPlan, position::Real; keyframe_index::Union{Nothing, Integer} = nothing)::CameraViewport
    snapshot_count = length(plan.required_bounds)
    segment_count = length(plan.centre_x_values) - 1
    timeline_position = clamp(Float64(position), 0.0, Float64(segment_count))
    segment = min(floor(Int, timeline_position) + 1, segment_count)
    fraction = timeline_position - Float64(segment - 1)

    centre_x = _cubic_value(plan.centre_x_values, plan.centre_x_slopes, segment, fraction)
    centre_y = _cubic_value(plan.centre_y_values, plan.centre_y_slopes, segment, fraction)
    half_height = _cubic_value(plan.half_height_values, plan.half_height_slopes, segment, fraction)
    current_index = isnothing(keyframe_index) ? min(segment, snapshot_count) : clamp(Int(keyframe_index), 1, snapshot_count)
    state = _containing_state(CameraState(centre_x, centre_y, half_height), plan.required_bounds[current_index], plan.aspect)
    return camera_viewport(_state_rect(state, plan.aspect), plan.width, plan.height)
end

"Build the selected camera schedule or offline smooth trajectory before rendering."
function build_camera_schedule(entries::AbstractVector{<:TimelineEntry}, options::ExportOptions)
    isempty(entries) && throw(ArgumentError("camera schedule needs at least one keyframe"))
    if options.camera == :manual
        rect = WorldRect(options.viewport...)
        return fill(camera_viewport(aspect_expand(rect, options.width, options.height), options.width, options.height), length(entries))
    end
    unpadded = map(entry -> tile_area_bounds(entry.gamemap), entries)
    if options.camera == :smooth
        required = [padded_bounds(content, options.padding, options.min_padding) for content in unpadded]
        return build_smooth_camera_plan(required, options.width, options.height)
    end
    if options.camera == :fixed
        union_rect = reduce(_union, unpadded)
        rect = aspect_expand(padded_bounds(union_rect, options.padding, options.min_padding), options.width, options.height)
        viewport = camera_viewport(rect, options.width, options.height)
        return fill(viewport, length(entries))
    elseif options.camera == :fit
        return map(unpadded) do content
            rect = aspect_expand(padded_bounds(content, options.padding, options.min_padding), options.width, options.height)
            return camera_viewport(rect, options.width, options.height)
        end
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

"Map an output frame to the duration-independent smooth-camera timeline."
function camera_timeline_position(frame::KeyframeSchedule, local_frame::Integer, options::ExportOptions)::Float64
    lead_seconds = frame.keyframe_index == 1 ? options.start_hold : 0.0
    local_seconds = Float64(local_frame) / Float64(options.fps)
    fraction = clamp((local_seconds - lead_seconds) / options.keyframe_seconds, 0.0, 1.0)
    return Float64(frame.keyframe_index - 1) + fraction
end

"Extend the final smooth-camera interval through a tight-fit settling segment."
function camera_timeline_position(plan::SmoothCameraPlan, frame::KeyframeSchedule, local_frame::Integer, options::ExportOptions)::Float64
    position = camera_timeline_position(frame, local_frame, options)
    snapshot_count = length(plan.required_bounds)
    frame.keyframe_index == snapshot_count || return position

    lead_seconds = snapshot_count == 1 ? options.start_hold : 0.0
    construction_elapsed = Float64(local_frame) / Float64(options.fps) - lead_seconds
    settle_elapsed = construction_elapsed - options.keyframe_seconds
    settle_seconds = min(SMOOTH_FINAL_SETTLE_SECONDS, options.end_hold / 2.0)
    settle_seconds > 0.0 && settle_elapsed > 0.0 || return position
    return Float64(snapshot_count) + clamp(settle_elapsed / settle_seconds, 0.0, 1.0)
end

camera_for_frame(cameras::AbstractVector{CameraViewport}, frame::KeyframeSchedule, ::Integer, ::ExportOptions) = cameras[frame.keyframe_index]

function camera_for_frame(plan::SmoothCameraPlan, frame::KeyframeSchedule, local_frame::Integer, options::ExportOptions)::CameraViewport
    position = camera_timeline_position(plan, frame, local_frame, options)
    return evaluate_camera(plan, position; keyframe_index = frame.keyframe_index)
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
