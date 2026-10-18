#=
Scope: Render-thread time-lapse snapshot history and fixed-interval capture scheduling
Formatter: Runic
=#

# ===============================================================
# Render-Thread Time-Lapse Recording
# ===============================================================

using FlowMap

#= ---------- Recorder State ---------- =#

const DEFAULT_TIMELAPSE_CAPTURE_INTERVAL_SECONDS::Float64 = 60.0

"Render-thread-owned runtime state for fixed-interval time-lapse capture."
mutable struct TimelapseRecorder
    enabled::Bool
    history::Union{Nothing, TimelapseHistory}
    capture_interval_seconds::Float64
    next_capture_time_seconds::Float64
    last_captured_snapshot_timestamp::Union{Nothing, Float64}
    last_captured_source::WeakRef  # Track identity without retaining a snapshot buffer
end

"Return the monotonic wall-clock time used by recorder deadlines."
_monotonic_time_seconds()::Float64 = Float64(time_ns()) / 1.0e9

"Build recorder state from optionally loaded history and arm the next capture deadline."
function TimelapseRecorder(
        history::Union{Nothing, TimelapseHistory} = nothing;
        now::Real = _monotonic_time_seconds(),
    )
    current_time = Float64(now)
    capture_interval = DEFAULT_TIMELAPSE_CAPTURE_INTERVAL_SECONDS
    next_capture_time = current_time + capture_interval
    last_source = isnothing(history) || isempty(history.frames) ? nothing : last(history.frames)
    return TimelapseRecorder(true, history, capture_interval, next_capture_time, nothing, WeakRef(last_source))
end

"Enable or disable recording without changing the retained history."
function set_timelapse_enabled!(recorder::TimelapseRecorder, enabled::Bool; now::Real = _monotonic_time_seconds())::TimelapseRecorder
    recorder.enabled == enabled && return recorder

    recorder.enabled = enabled
    if enabled
        recorder.next_capture_time_seconds = Float64(now)
    end
    return recorder
end

"Return a shallow history snapshot sharing the independently owned recorded maps."
function snapshot_timelapse_history(recorder::TimelapseRecorder)::Union{Nothing, TimelapseHistory}
    history = recorder.history
    isnothing(history) && return nothing
    return TimelapseHistory(frames = copy(history.frames))
end

"Return the number of retained frames, including zero for an uninitialised recorder."
timelapse_frame_count(recorder::TimelapseRecorder)::Int =
    isnothing(recorder.history) ? 0 : length(recorder.history.frames)

#= ---------- Capture ---------- =#

"Append a deep copy of the source map when recording is enabled and the frame is new."
function capture_timelapse_frame!(
        recorder::TimelapseRecorder, gamemap::GameMap;
        snapshot_timestamp::Union{Nothing, Float64} = nothing,
    )::Bool
    recorder.enabled || return false

    if isnothing(recorder.history)
        recorder.history = TimelapseHistory()
    end
    history = recorder.history::TimelapseHistory

    if isnothing(snapshot_timestamp)
        duplicate = recorder.last_captured_source.value === gamemap
        recorder.last_captured_snapshot_timestamp = nothing
        duplicate && return false
    elseif recorder.last_captured_snapshot_timestamp == snapshot_timestamp
        return false
    end

    push!(history.frames, deepcopy(gamemap))
    recorder.last_captured_snapshot_timestamp = snapshot_timestamp
    recorder.last_captured_source = WeakRef(gamemap)
    return true
end

"Capture the current published snapshot when its fixed interval is due."
function maybe_capture_timelapse!(
        recorder::TimelapseRecorder, snapshot;
        capture_suppressed::Bool = false,
        now::Real = _monotonic_time_seconds(),
    )::Bool
    recorder.enabled || return false
    capture_suppressed && return false

    current_time = Float64(now)
    current_time < recorder.next_capture_time_seconds && return false

    captured = capture_timelapse_frame!(recorder, snapshot.gamemap; snapshot_timestamp = snapshot.timestamp)
    captured && (recorder.next_capture_time_seconds = current_time + recorder.capture_interval_seconds)
    return captured
end
