struct TimelineEntry
    gamemap::GameMap
    origin::String
    history_index::Union{Nothing, Int}
    explicit_current::Bool
end

struct TimelinePlan
    candidates::Vector{TimelineEntry}
    frames::Vector{TimelineEntry}
    current_appended::Bool
    current_note::String
end

"Compare persisted render state structurally, including deep-copied mutable behaviour state."
function _render_value_equal(left, right)::Bool
    typeof(left) === typeof(right) || return false
    isequal(left, right) && return true

    if left isa AbstractArray
        axes(left) == axes(right) || return false
        return all(_render_value_equal(left[index], right[index]) for index in eachindex(left, right))
    elseif left isa AbstractDict
        length(left) == length(right) || return false
        return all(haskey(right, key) && _render_value_equal(value, right[key]) for (key, value) in left)
    elseif isstructtype(typeof(left))
        return all(_render_value_equal(getfield(left, index), getfield(right, index)) for index in 1:fieldcount(typeof(left)))
    end

    return false
end

function _render_relevant_equal(left, right)::Bool
    try
        return _render_value_equal(
            (left.surface_shiptags, left.ships, left.components, left.pipe_behaviors),
            (right.surface_shiptags, right.ships, right.components, right.pipe_behaviors),
        )
    catch error
        error isa InterruptException && rethrow()
        # A custom component with opaque equality must never make us discard content.
        return false
    end
end

function _history_entries(history)
    entries = TimelineEntry[]
    for (index, frame) in enumerate(history.frames)
        frame isa GameMap || throw(ValidationError("time-lapse history frame $(index) is not a GameMap"))
        push!(entries, TimelineEntry(frame, "history frame $(index)", index, false))
    end
    return entries
end

"Assemble history frames and apply current-map policy and conservative adjacent deduplication."
function assemble_timeline(bundle, options::ExportOptions)::TimelinePlan
    history = getproperty(bundle, :timelapse)
    isnothing(history) && throw(ValidationError("Input contains no valid time-lapse."))

    candidates = _history_entries(history)
    current_map = getproperty(bundle, :gamemap)
    escape_active = is_galaxy_escape_active(current_map.space_map)
    current_appended = false
    current_note = "current map omitted by policy"

    if options.include_current == :always
        escape_active && throw(ValidationError("authoritative current map is in active galaxy escape; use --include-current=never"))
        push!(candidates, TimelineEntry(current_map, "current", nothing, true))
        current_appended = true
        current_note = "current map appended (always)"
    elseif options.include_current == :auto
        if escape_active
            current_note = "current map omitted because active galaxy escape marks the construction timeline boundary"
        elseif isempty(candidates)
            throw(ValidationError("no historical frames to export"))
        elseif _render_relevant_equal(current_map, candidates[end].gamemap)
            current_note = "current map omitted as visually equivalent to the last history frame"
        else
            push!(candidates, TimelineEntry(current_map, "current", nothing, true))
            current_appended = true
            current_note = "current map appended (auto; visually different)"
        end
    elseif options.include_current == :never
        current_note = "current map omitted by --include-current=never"
    end

    isempty(candidates) && throw(ValidationError("no historical frames to export"))
    retained = options.dedupe ? TimelineEntry[] : copy(candidates)
    if options.dedupe
        for candidate in candidates
            # An explicit --include-current=always is a request to keep the final frame.
            if candidate.explicit_current && options.include_current == :always
                push!(retained, candidate)
            elseif isempty(retained) || !_render_relevant_equal(retained[end].gamemap, candidate.gamemap)
                push!(retained, candidate)
            end
        end
    end
    return TimelinePlan(candidates, retained, current_appended, current_note)
end

function _map_counts(entry::TimelineEntry)
    map = entry.gamemap
    return (ships = length(map.ships), surfaces = length(map.surface_shiptags), components = length(map.components), pipes = length(map.pipe_behaviors))
end

function print_summary(options::ExportOptions, timeline::TimelinePlan, schedule)
    println("Loaded $(length(timeline.candidates)) candidate frames; retained $(length(timeline.frames)) keyframes; $(timeline.current_note).")
    println("Camera: $(options.camera) (base tile coordinates; render offsets ignored).")
    format_name = options.format == :mp4 ? "H.264 MP4" : "palette GIF"
    println("Output: $(options.width)x$(options.height), $(options.fps) fps, $(schedule.total_frames) frames, $(@sprintf("%.2f", schedule.duration_seconds)) seconds, $(format_name).")
end

function print_inspection(options::ExportOptions, bundle, timeline::TimelinePlan, cameras, schedule)
    history = bundle.timelapse
    println("Inspection report")
    println("Input: $(options.input)")
    println("History frame count: $(length(history.frames))")
    println("Current map appended: $(timeline.current_appended) ($(timeline.current_note))")
    println("Candidate keyframes: $(length(timeline.candidates))")
    println("Retained keyframes: $(length(timeline.frames))")
    for (index, entry) in enumerate(timeline.frames)
        counts = _map_counts(entry)
        bounds = tile_area_bounds(entry.gamemap)
        viewport = cameras[index].rect
        println("  $(index): $(entry.origin), ships=$(counts.ships), surface_tiles=$(counts.surfaces), components=$(counts.components), pipes=$(counts.pipes)")
        println("      unpadded base bounds=$(bounds), camera viewport=$(viewport)")
    end
    println("Format: $(options.format), resolution=$(options.width)x$(options.height), fps=$(options.fps), camera=$(options.camera)")
    println("Total encoded frames: $(schedule.total_frames)")
    println("Encoded duration: $(@sprintf("%.6f", schedule.duration_seconds)) seconds")
    println("Camera bounds are based on stored surface-tile coordinates and ignore runtime render offsets.")
    println("No OpenGL context, FFmpeg process, or output file was created (--inspect).")
end
