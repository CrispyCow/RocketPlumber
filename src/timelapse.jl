#=
Scope: Render-thread time-lapse snapshot history and fixed-interval capture scheduling
Formatter: Runic
=#

# ===============================================================
# Render-Thread Time-Lapse Recording
# ===============================================================

using FlowMap

#= ---------- Recorder State ---------- =#

const TIMELAPSE_FORMAT_VERSION::UInt16 = UInt16(2)
const TIMELAPSE_CAPTURE_INTERVAL_SECONDS::Float64 = 30.0

@kwdef struct TimelapseHistory
    format_version::UInt16 = TIMELAPSE_FORMAT_VERSION
    frames::Vector{GameMap} = GameMap[]
end

"Pair the authoritative current map with its optional render-thread time-lapse history."
@kwdef struct GameMapBundle
    gamemap::GameMap
    timelapse::Union{Nothing, TimelapseHistory} = nothing
end

GameMapBundle(gamemap::GameMap) = GameMapBundle(gamemap = gamemap)

"Render-thread-owned runtime state for fixed-interval time-lapse capture."
mutable struct TimelapseRecorder
    enabled::Bool
    history::Union{Nothing, TimelapseHistory}
    next_capture_time_seconds::Float64
    last_captured_snapshot_timestamp::Union{Nothing, Float64}
end

"Return the monotonic wall-clock time used by recorder deadlines."
_monotonic_time_seconds()::Float64 = Float64(time_ns()) / 1.0e9

"Build recorder state from optionally loaded history and arm the next capture deadline."
function TimelapseRecorder(
        history::Union{Nothing, TimelapseHistory} = nothing;
        now::Real = _monotonic_time_seconds(),
    )
    if !isnothing(history) && history.format_version != TIMELAPSE_FORMAT_VERSION
        throw(ArgumentError("unsupported time-lapse format version $(history.format_version)"))
    end

    current_time = Float64(now)
    enabled = !isnothing(history)
    next_capture_time = enabled ? current_time + TIMELAPSE_CAPTURE_INTERVAL_SECONDS : Inf
    return TimelapseRecorder(enabled, history, next_capture_time, nothing)
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

"Return a shallow snapshot of a history while preserving the identity of every map."
function snapshot_timelapse_history(recorder::TimelapseRecorder)::Union{Nothing, TimelapseHistory}
    history = recorder.history
    isnothing(history) && return nothing
    return TimelapseHistory(format_version = history.format_version, frames = copy(history.frames))
end

"Return the number of retained frames, including zero for an uninitialised recorder."
timelapse_frame_count(recorder::TimelapseRecorder)::Int =
    isnothing(recorder.history) ? 0 : length(recorder.history.frames)

#= ---------- Capture ---------- =#

"Append one detached render map when recording is enabled and the frame is new."
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
        duplicate = !isempty(history.frames) && last(history.frames) === gamemap
        recorder.last_captured_snapshot_timestamp = nothing
        duplicate && return false
    elseif recorder.last_captured_snapshot_timestamp == snapshot_timestamp
        return false
    end

    push!(history.frames, gamemap)
    recorder.last_captured_snapshot_timestamp = snapshot_timestamp
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
    captured && (recorder.next_capture_time_seconds = current_time + TIMELAPSE_CAPTURE_INTERVAL_SECONDS)
    return captured
end
