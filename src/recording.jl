#=
Scope: In-game screenshot capture and asynchronous FFmpeg screen recording
Formatter: Runic
=#

# Captures rendered frames via glReadPixels for two purposes:
# real-time H.264 video encoding through FFmpeg, and one-shot PNG
# screenshots written through Julia's image stack.

using Dates: Dates
using PNGFiles, ColorTypes

# ===============================================================
# Recording State
# ===============================================================

const RECORDING_TARGET_FPS = 30
const RECORDING_FRAME_INTERVAL = 1.0 / RECORDING_TARGET_FPS
const FFMPEG_LOG_TAIL_BYTES = 1024 * 1024 # 1 MB of recent FFmpeg stderr for post-mortem debugging if recording fails
const RECORDING_BUFFER_SLOTS = 2
const RECORDING_PBO_SLOTS = 2
const RECORDING_STOP_SENTINEL_SLOT = 0
const RECORDING_PBO_POLL_TIMEOUT_NS = UInt64(0)
const RECORDING_PBO_FLUSH_TIMEOUT_NS = UInt64(100_000_000)

"Return the encoded video dimensions after rounding up to H.264-compatible even sizes."
recording_encoded_dims(width::Integer, height::Integer) = (width + width % 2, height + height % 2)

"Return the default timestamp suffix for captured output files."
default_capture_timestamp() = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")

"Return the default absolute path for a captured output file."
function default_capture_path(kind::Symbol, timestamp::AbstractString = default_capture_timestamp())
    if kind == :screenshot
        return joinpath(pictures_dir(), "screenshot_$(timestamp).png")
    elseif kind == :recording
        return joinpath(videos_dir(), "recording_$(timestamp).mp4")
    end

    throw(ArgumentError("Unsupported capture kind: $(kind)"))
end

"Captured failure details for recording worker or readback shutdown paths."
struct RecordingFailure
    exception
    backtrace
end

"Mutable state for an active (or idle) screen recording session."
@kwdef mutable struct RecordingState
    is_recording::Bool = false
    recording_buffers::Vector{Vector{UInt8}} = Vector{UInt8}[]
    screenshot_buffer::Vector{UInt8} = UInt8[]
    buffer_width::Int32 = 0
    buffer_height::Int32 = 0
    pbo_ids::Vector{UInt32} = UInt32[]
    pbo_syncs::Vector{Ptr{Nothing}} = Ptr{Nothing}[]
    pbo_buffer_bytes::Int = 0
    next_pbo_issue_slot::Int = 1
    async_readback_enabled::Bool = false
    ffmpeg_process::Union{Nothing, Base.Process} = nothing
    ffmpeg_stderr_pipe::Union{Nothing, Pipe} = nothing
    ffmpeg_stderr_task::Union{Nothing, Task} = nothing
    free_slots::Union{Nothing, Channel{Int}} = nothing
    ready_slots::Union{Nothing, Channel{Int}} = nothing
    writer_task::Union{Nothing, Task} = nothing
    writer_failure_channel::Union{Nothing, Channel{RecordingFailure}} = nothing
    pending_writer_failure::Union{Nothing, RecordingFailure} = nothing
    ffmpeg_log_tail::Vector{UInt8} = UInt8[]
    accumulator::Float64 = 0.0
    last_frame_time::Float64 = 0.0
    frame_count::Int64 = 0
    started_at::Float64 = 0.0
    pbo_skips::Int = 0
    buffer_drops::Int = 0
    output_path::String = ""
end

# ===============================================================
# Framebuffer Capture
# ===============================================================

"Read the entire default framebuffer into a pre-allocated RGBA byte buffer."
function capture_framebuffer!(buffer::Vector{UInt8}, width::Integer, height::Integer)
    expected_size = width * height * 4
    @assert length(buffer) >= expected_size "Pixel buffer too small for $(width)x$(height) framebuffer"
    GC.@preserve buffer begin
        glReadPixels(
            GLint(0), GLint(0), GLsizei(width), GLsizei(height),
            GL_RGBA, GL_UNSIGNED_BYTE, pointer(buffer)
        )
    end
    return nothing
end

"Convert bottom-left-origin RGBA bytes into a top-left-origin image matrix."
function framebuffer_rgba_to_image(buffer::Vector{UInt8}, width::Integer, height::Integer)
    width_int = Int(width)
    height_int = Int(height)
    row_stride = width_int * 4
    image = Matrix{ColorTypes.RGBA{Float32}}(undef, height_int, width_int)

    for output_y in 1:height_int
        source_y = height_int - output_y
        row_offset = source_y * row_stride

        for output_x in 1:width_int
            pixel_offset = row_offset + (output_x - 1) * 4
            red = buffer[pixel_offset + 1] / 255.0f0
            green = buffer[pixel_offset + 2] / 255.0f0
            blue = buffer[pixel_offset + 3] / 255.0f0
            alpha = buffer[pixel_offset + 4] / 255.0f0
            image[output_y, output_x] = ColorTypes.RGBA{Float32}(red, green, blue, alpha)
        end
    end

    return image
end

"Append captured FFmpeg stderr bytes while keeping only the most recent tail."
function append_ffmpeg_log!(rec::RecordingState, chunk::AbstractVector{UInt8})
    isempty(chunk) && return nothing
    append!(rec.ffmpeg_log_tail, chunk)
    overflow = length(rec.ffmpeg_log_tail) - FFMPEG_LOG_TAIL_BYTES
    if overflow > 0
        deleteat!(rec.ffmpeg_log_tail, 1:overflow)
    end
    return nothing
end

"Drain FFmpeg stderr into the recording's bounded log tail."
function drain_ffmpeg_stderr!(rec::RecordingState, stderr_pipe::Pipe)
    stderr_stream = stderr_pipe.out

    try
        while true
            # Blocking read that terminates on EOF: returns an empty Vector at end-of-stream.
            chunk = read(stderr_stream, UInt8, 4096)
            isempty(chunk) && break
            append_ffmpeg_log!(rec, chunk)
        end
    catch e
        @debug "FFmpeg stderr reader stopped" exception = (e, catch_backtrace())
    end

    return nothing
end

"Render the captured FFmpeg stderr tail as text."
function ffmpeg_log_text(rec::RecordingState)
    isempty(rec.ffmpeg_log_tail) && return ""
    return String(copy(rec.ffmpeg_log_tail))
end

"Save a screenshot image using the direct PNG-only runtime path."
function save_png_screenshot(output_path::AbstractString, screenshot_image)
    PNGFiles.save(output_path, screenshot_image)
    return nothing
end

"Capture the current framebuffer as a PNG, propagating failures to the caller."
function capture_screenshot!(rec::RecordingState, fb_width::Int32, fb_height::Int32, output_path::String)
    fb_width > 0 && fb_height > 0 || throw(ArgumentError("The framebuffer has no visible pixels."))
    resize!(rec.screenshot_buffer, Int(fb_width) * Int(fb_height) * 4)
    capture_framebuffer!(rec.screenshot_buffer, fb_width, fb_height)
    screenshot_image = framebuffer_rgba_to_image(rec.screenshot_buffer, fb_width, fb_height)
    save_png_screenshot(output_path, screenshot_image)
    return nothing
end

"Capture the current framebuffer and save it as a PNG screenshot."
function save_screenshot!(rec::RecordingState, fb_width::Int32, fb_height::Int32, console_push::Function)
    output_path = nothing
    try
        output_path = default_capture_path(:screenshot)
        mkpath(dirname(output_path))
        capture_screenshot!(rec, fb_width, fb_height, output_path)
        console_push("Screenshot saved: $(output_path)")
        @info "Screenshot saved: $(output_path)"
    catch e
        e isa InterruptException && rethrow()
        console_push("Screenshot failed; see the terminal log for details")
        @warn "Screenshot capture failed" output_path = output_path exception = (e, catch_backtrace())
    end

    return nothing
end

# ===============================================================
# FFmpeg Encoder
# ===============================================================

"Wrap a blocking pipe handle in an owned stream, using binary mode on Windows."
function recording_pipe_stream(handle::Base.OS_HANDLE)::IOStream
    descriptor = @static if Sys.iswindows()
        ccall(:_open_osfhandle, Cint, (Base.OS_HANDLE, Cint), handle, 0x8000) # _O_BINARY
    else
        Base.cconvert(Cint, handle)
    end
    Base.systemerror("Opening recording pipe", descriptor == -1)
    return Base.fdio(descriptor, true)
end

"Start a subprocess with blocking stdin owned exclusively by the background recording writer."
function start_recording_process(cmd::Cmd)::Base.Process
    #=
    open(cmd, "w") used libuv-managed stdin: large writes depended on I/O event-loop
    progress. Removing the dedicated I/O thread exposed this dependency and caused
    severe recording frame loss. A blocking OS pipe lets the background writer
    transfer frames without libuv servicing those writes; do not replace it with open.
    =#
    read_handle, write_handle = Base.link_pipe(false, false)
    reader = nothing
    writer = nothing
    try
        reader = recording_pipe_stream(read_handle)
        writer = recording_pipe_stream(write_handle)
        process = run(pipeline(cmd; stdin = reader, stdout = devnull, stderr = stderr); wait = false)
        process.in = writer
        return process
    catch
        isnothing(writer) ? Base.close_pipe_sync(write_handle) : close(writer)
        rethrow()
    finally
        isnothing(reader) ? Base.close_pipe_sync(read_handle) : close(reader)
    end
end

"Start an FFmpeg subprocess that reads raw RGBA frames from stdin and encodes to H.264 MP4."
function start_ffmpeg_encoder(width::Integer, height::Integer, fps::Integer, output_path::String)::Base.Process
    ffmpeg_path = FFMPEG.ffmpeg()
    video_filter = "vflip,pad=ceil(iw/2)*2:ceil(ih/2)*2"
    cmd = `$ffmpeg_path -y
        -f rawvideo -pix_fmt rgba -s $(width)x$(height) -r $fps -i pipe:0
        -threads 4 -c:v libx264 -preset medium -pix_fmt yuv420p -crf 20 -vf $video_filter
        $output_path`
    return start_recording_process(cmd)
end

# ===============================================================
# Frame Timing
# ===============================================================

"Advance the recording accumulator and return true if a frame should be captured this iteration."
function should_capture_frame!(rec::RecordingState)::Bool
    current_time = time()
    if rec.last_frame_time == 0.0
        rec.last_frame_time = current_time
        return false
    end
    dt = current_time - rec.last_frame_time
    rec.last_frame_time = current_time
    rec.accumulator += dt
    rec.accumulator = min(rec.accumulator, RECORDING_FRAME_INTERVAL * 5) # cap to prevent spiral-of-death
    if rec.accumulator >= RECORDING_FRAME_INTERVAL
        rec.accumulator -= RECORDING_FRAME_INTERVAL
        return true
    end
    return false
end

"Allocate or resize the ping-pong CPU recording buffers and reset their slot queues."
function initialise_recording_buffers!(rec::RecordingState, fb_width::Int32, fb_height::Int32)
    buffer_size = Int(fb_width) * Int(fb_height) * 4

    if length(rec.recording_buffers) != RECORDING_BUFFER_SLOTS
        rec.recording_buffers = [Vector{UInt8}(undef, buffer_size) for _ in 1:RECORDING_BUFFER_SLOTS]
    else
        for buffer in rec.recording_buffers
            resize!(buffer, buffer_size)
        end
    end

    rec.free_slots = Channel{Int}(RECORDING_BUFFER_SLOTS)
    rec.ready_slots = Channel{Int}(RECORDING_BUFFER_SLOTS + 1)
    rec.writer_failure_channel = Channel{RecordingFailure}(1)
    rec.pending_writer_failure = nothing

    for slot in 1:RECORDING_BUFFER_SLOTS
        put!(rec.free_slots, slot)
    end
    return nothing
end

"Reset all PBO-side recording state after shutdown or fallback."
function reset_recording_pbo_state!(rec::RecordingState)
    rec.pbo_ids = UInt32[]
    rec.pbo_syncs = Ptr{Nothing}[]
    rec.pbo_buffer_bytes = 0
    rec.next_pbo_issue_slot = 1
    rec.async_readback_enabled = false
    return nothing
end

"Return the next slot index in the fixed-size PBO ring."
recording_pbo_next_slot(slot::Integer, slot_count::Integer = RECORDING_PBO_SLOTS) = slot == slot_count ? 1 : slot + 1

"Return true when a PBO sync is still live for the given slot."
function recording_pbo_pending(rec::RecordingState, slot::Integer)::Bool
    isempty(rec.pbo_syncs) && return false
    return rec.pbo_syncs[slot] != C_NULL
end

"Delete a single in-flight fence and clear the slot state."
function delete_recording_sync!(rec::RecordingState, slot::Integer)
    recording_pbo_pending(rec, slot) || return nothing
    glDeleteSync(rec.pbo_syncs[slot])
    rec.pbo_syncs[slot] = C_NULL
    return nothing
end

"Allocate the async readback PBO ring for video recording when supported."
function initialise_recording_pbos!(rec::RecordingState, fb_width::Int32, fb_height::Int32)::Bool
    reset_recording_pbo_state!(rec)

    rec.pbo_buffer_bytes = Int(fb_width) * Int(fb_height) * 4
    rec.pbo_ids = fill(UInt32(0), RECORDING_PBO_SLOTS)
    rec.pbo_syncs = fill(C_NULL, RECORDING_PBO_SLOTS)

    try
        for slot in 1:RECORDING_PBO_SLOTS
            pbo_id = UInt32(0)
            @cref glGenBuffers(1, &pbo_id)
            rec.pbo_ids[slot] = pbo_id

            glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo_id)
            glBufferData(GL_PIXEL_PACK_BUFFER, rec.pbo_buffer_bytes, C_NULL, GL_STREAM_READ)
        end
    catch e
        destroy_recording_pbos!(rec)
        @warn "Async readback PBO initialisation failed; falling back to direct capture" exception = (e, catch_backtrace())
        return false
    finally
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0)
    end

    rec.async_readback_enabled = true
    return true
end

"Delete all PBOs and fences owned by the current recording session."
function destroy_recording_pbos!(rec::RecordingState)
    for slot in eachindex(rec.pbo_syncs)
        delete_recording_sync!(rec, slot)
    end

    for pbo_id in rec.pbo_ids
        pbo_id == 0 && continue
        pbo = pbo_id
        @cref glDeleteBuffers(1, &pbo)
    end

    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0)
    return reset_recording_pbo_state!(rec)
end

"Return a free recording buffer slot without ever blocking the render thread."
function try_take_free_recording_slot!(rec::RecordingState)::Union{Nothing, Int}
    isnothing(rec.free_slots) && return nothing
    isready(rec.free_slots) || return nothing
    return take!(rec.free_slots)
end

"Take a CPU recording buffer slot, blocking until the writer releases one."
function take_free_recording_slot!(rec::RecordingState)::Int
    isnothing(rec.free_slots) && throw(ArgumentError("Recording free-slot queue is not initialised"))
    return take!(rec.free_slots)
end

"Return a buffer slot to the free queue after an aborted capture attempt."
function release_recording_slot!(rec::RecordingState, slot::Integer)
    isnothing(rec.free_slots) && return nothing
    put!(rec.free_slots, Int(slot))
    return nothing
end

"Submit a captured buffer slot to the background FFmpeg writer."
function submit_recording_slot!(rec::RecordingState, slot::Integer)
    isnothing(rec.ready_slots) && throw(ArgumentError("Recording writer queue is not initialised"))
    put!(rec.ready_slots, Int(slot))
    return nothing
end

"Return the first non-`nothing` recording failure from a list of candidates."
function first_recording_failure(failures::Union{Nothing, RecordingFailure}...)::Union{Nothing, RecordingFailure}
    for failure in failures
        !isnothing(failure) && return failure
    end

    return nothing
end

"Drain queued recording buffers into FFmpeg on a background worker thread."
function ffmpeg_writer_loop!(
        rec::RecordingState,
        ffmpeg_input::IO,
        ready_slots::Channel{Int},
        free_slots::Channel{Int},
        failure_channel::Channel{RecordingFailure},
    )
    try
        while true
            slot = take!(ready_slots)
            slot == RECORDING_STOP_SENTINEL_SLOT && break

            buffer = rec.recording_buffers[slot]
            bytes_written = write(ffmpeg_input, buffer)
            bytes_written == length(buffer) || throw(ErrorException("Incomplete recording frame write: $(bytes_written) of $(length(buffer)) bytes"))

            put!(free_slots, slot)
        end
    catch e
        put!(failure_channel, RecordingFailure(e, catch_backtrace()))
    end

    return nothing
end

"Start the background FFmpeg writer that owns stdin writes for recording frames."
function start_ffmpeg_writer!(rec::RecordingState)
    ffmpeg_process = rec.ffmpeg_process
    ready_slots = rec.ready_slots
    free_slots = rec.free_slots
    failure_channel = rec.writer_failure_channel

    isnothing(ffmpeg_process) && throw(ArgumentError("FFmpeg process must be started before the writer task"))
    isnothing(ready_slots) && throw(ArgumentError("Recording writer queue is not initialised"))
    isnothing(free_slots) && throw(ArgumentError("Recording free-slot queue is not initialised"))
    isnothing(failure_channel) && throw(ArgumentError("Recording writer failure channel is not initialised"))

    rec.writer_task = Threads.@spawn ffmpeg_writer_loop!(rec, ffmpeg_process.in, ready_slots, free_slots, failure_channel)
    return nothing
end

"Poll for an asynchronous writer failure without blocking the render thread."
function poll_writer_failure!(rec::RecordingState)::Union{Nothing, RecordingFailure}
    !isnothing(rec.pending_writer_failure) && return rec.pending_writer_failure
    isnothing(rec.writer_failure_channel) && return nothing
    isready(rec.writer_failure_channel) || return nothing
    rec.pending_writer_failure = take!(rec.writer_failure_channel)
    return rec.pending_writer_failure
end

"Drain and stop the background writer, returning any surfaced writer failure."
function shutdown_ffmpeg_writer!(rec::RecordingState)::Union{Nothing, RecordingFailure}
    writer_failure = rec.pending_writer_failure
    isnothing(writer_failure) && (writer_failure = poll_writer_failure!(rec))

    if !isnothing(rec.ready_slots)
        put!(rec.ready_slots, RECORDING_STOP_SENTINEL_SLOT)
    end

    if !isnothing(rec.writer_task)
        wait(rec.writer_task)
    end

    isnothing(writer_failure) && (writer_failure = poll_writer_failure!(rec))

    rec.writer_task = nothing
    rec.free_slots = nothing
    rec.ready_slots = nothing
    rec.writer_failure_channel = nothing
    rec.pending_writer_failure = nothing

    return writer_failure
end

"Copy a completed PBO readback into a CPU buffer owned by the async writer."
function copy_pbo_into_recording_buffer!(rec::RecordingState, pbo_slot::Integer, buffer_slot::Integer)
    buffer = rec.recording_buffers[buffer_slot]

    glBindBuffer(GL_PIXEL_PACK_BUFFER, rec.pbo_ids[pbo_slot])
    mapped_ptr = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, rec.pbo_buffer_bytes, GL_MAP_READ_BIT)

    if mapped_ptr == C_NULL
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0)
        throw(ErrorException("Failed to map recording PBO slot $(pbo_slot)"))
    end

    unmap_ok = try
        GC.@preserve buffer begin
            unsafe_copyto!(pointer(buffer), Ptr{UInt8}(mapped_ptr), rec.pbo_buffer_bytes)
        end
        glUnmapBuffer(GL_PIXEL_PACK_BUFFER)
    finally
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0)
    end

    unmap_ok == GL_FALSE && throw(ErrorException("Failed to unmap recording PBO slot $(pbo_slot)"))
    return nothing
end

"Issue an asynchronous framebuffer readback into the selected PBO slot."
function issue_readback_to_pbo!(rec::RecordingState, pbo_slot::Integer)
    glBindBuffer(GL_PIXEL_PACK_BUFFER, rec.pbo_ids[pbo_slot])

    try
        glReadPixels(
            GLint(0), GLint(0), GLsizei(rec.buffer_width), GLsizei(rec.buffer_height),
            GL_RGBA, GL_UNSIGNED_BYTE, Ptr{Cvoid}(0)
        )
        rec.pbo_syncs[pbo_slot] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0)
        rec.pbo_syncs[pbo_slot] == C_NULL && throw(ErrorException("Failed to create recording PBO fence for slot $(pbo_slot)"))
    finally
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0)
    end

    return nothing
end

"Submit a filled CPU recording buffer to the async writer and count the frame."
function submit_recorded_frame!(rec::RecordingState, buffer_slot::Integer)
    submit_recording_slot!(rec, buffer_slot)
    rec.frame_count += 1
    return nothing
end

"Poll or wait for a completed PBO readback, then enqueue or drop the frame."
function try_collect_completed_pbo!(rec::RecordingState, pbo_slot::Integer; wait::Bool = false)::Bool
    recording_pbo_pending(rec, pbo_slot) || return false

    sync = rec.pbo_syncs[pbo_slot]
    timeout_ns = wait ? RECORDING_PBO_FLUSH_TIMEOUT_NS : RECORDING_PBO_POLL_TIMEOUT_NS

    while true
        wait_status = glClientWaitSync(sync, 0, timeout_ns)

        if wait_status == GL_ALREADY_SIGNALED || wait_status == GL_CONDITION_SATISFIED
            buffer_slot = wait ? take_free_recording_slot!(rec) : try_take_free_recording_slot!(rec)

            if isnothing(buffer_slot)
                rec.buffer_drops += 1
                delete_recording_sync!(rec, pbo_slot)
                return true
            end

            copy_pbo_into_recording_buffer!(rec, pbo_slot, buffer_slot)
            delete_recording_sync!(rec, pbo_slot)
            submit_recorded_frame!(rec, buffer_slot)
            return true
        elseif wait_status == GL_TIMEOUT_EXPIRED
            wait || return false
            yield()
        elseif wait_status == GL_WAIT_FAILED
            throw(ErrorException("Recording PBO fence wait failed for slot $(pbo_slot)"))
        else
            throw(ErrorException("Unexpected recording PBO fence status $(wait_status) for slot $(pbo_slot)"))
        end
    end
    return false
end

"Flush any in-flight PBO readbacks before stopping the writer or deleting GL state."
function flush_pending_pbo_readbacks!(rec::RecordingState; allow_enqueue::Bool = true)
    rec.async_readback_enabled || return nothing

    pbo_slot = rec.next_pbo_issue_slot
    for _ in eachindex(rec.pbo_syncs)
        if recording_pbo_pending(rec, pbo_slot)
            if allow_enqueue
                try_collect_completed_pbo!(rec, pbo_slot; wait = true)
            else
                delete_recording_sync!(rec, pbo_slot)
            end
        end

        pbo_slot = recording_pbo_next_slot(pbo_slot, length(rec.pbo_syncs))
    end

    return nothing
end

"Capture a frame directly into CPU memory when async GPU readback is unavailable."
function capture_frame_direct!(rec::RecordingState)::Bool
    buffer_slot = try_take_free_recording_slot!(rec)
    if isnothing(buffer_slot)
        rec.buffer_drops += 1
        return false
    end

    try
        capture_framebuffer!(rec.recording_buffers[buffer_slot], rec.buffer_width, rec.buffer_height)
    catch
        release_recording_slot!(rec, buffer_slot)
        rethrow()
    end

    submit_recorded_frame!(rec, buffer_slot)
    return true
end

"Flush pending PBO readbacks, always releasing GL resources afterwards."
function teardown_recording_readback!(rec::RecordingState; allow_enqueue::Bool)::Union{Nothing, RecordingFailure}
    try
        if rec.async_readback_enabled
            flush_pending_pbo_readbacks!(rec; allow_enqueue = allow_enqueue)
        end

        return nothing
    catch e
        return RecordingFailure(e, catch_backtrace())
    finally
        destroy_recording_pbos!(rec)
    end
end

"Reclaim the next PBO slot when ready, then issue its replacement readback."
function process_async_readback_tick!(rec::RecordingState)
    pbo_slot = rec.next_pbo_issue_slot
    if recording_pbo_pending(rec, pbo_slot) && !try_collect_completed_pbo!(rec, pbo_slot)
        rec.pbo_skips += 1
        return nothing
    end

    issue_readback_to_pbo!(rec, pbo_slot)
    rec.next_pbo_issue_slot = recording_pbo_next_slot(pbo_slot)
    return nothing
end

# ===============================================================
# Recording Lifecycle
# ===============================================================

"Begin a new recording session: allocate buffer, open FFmpeg, reset timing."
function start_recording!(rec::RecordingState, fb_width::Int32, fb_height::Int32, console_push::Function)::Bool
    # Prepare the output directory before allocating capture or encoder resources
    try
        rec.output_path = default_capture_path(:recording)
        mkpath(dirname(rec.output_path))
    catch e
        rec.output_path = ""
        console_push("Recording failed; see the terminal log for details")
        @warn "Recording start failed" exception = (e, catch_backtrace())
        return false
    end

    # Prepare session state
    empty!(rec.ffmpeg_log_tail)
    rec.ffmpeg_stderr_pipe = nothing
    rec.ffmpeg_stderr_task = nothing
    rec.started_at = 0.0
    rec.pbo_skips = 0
    rec.buffer_drops = 0
    initialise_recording_buffers!(rec, fb_width, fb_height)
    rec.buffer_width = fb_width
    rec.buffer_height = fb_height
    async_readback_started = initialise_recording_pbos!(rec, fb_width, fb_height)

    # Start the encoder pipeline
    try
        rec.ffmpeg_stderr_pipe = Pipe()
        rec.ffmpeg_process = redirect_stderr(rec.ffmpeg_stderr_pipe) do
            start_ffmpeg_encoder(fb_width, fb_height, RECORDING_TARGET_FPS, rec.output_path)
        end
        rec.ffmpeg_stderr_task = @async drain_ffmpeg_stderr!(rec, rec.ffmpeg_stderr_pipe)
        start_ffmpeg_writer!(rec)
    catch e
        if !isnothing(rec.ffmpeg_process)
            try
                isopen(rec.ffmpeg_process.in) && close(rec.ffmpeg_process.in)
                wait(rec.ffmpeg_process)
            catch close_error
                @debug "Error closing FFmpeg process after failed recording start" exception = (close_error, catch_backtrace())
            end
        end

        shutdown_ffmpeg_writer!(rec)
        destroy_recording_pbos!(rec)
        rec.ffmpeg_process = nothing
        rec.ffmpeg_stderr_pipe = nothing
        rec.ffmpeg_stderr_task = nothing
        rec.output_path = ""
        console_push("Recording failed; see the terminal log for details")
        @warn "Recording start failed" exception = (e, catch_backtrace())
        return false
    end

    # Arm capture timing
    rec.accumulator = 0.0
    rec.last_frame_time = 0.0
    rec.frame_count = 0
    rec.started_at = time()
    rec.is_recording = true

    # Report the active capture configuration
    console_push("Recording started: $(rec.output_path)")
    encoded_width, encoded_height = recording_encoded_dims(fb_width, fb_height)
    if encoded_width != fb_width || encoded_height != fb_height
        source_dimensions = (fb_width, fb_height)
        encoded_dimensions = (encoded_width, encoded_height)
        @info "Recording dimensions padded for H.264 compatibility" source_dimensions = source_dimensions encoded_dimensions = encoded_dimensions
    end
    if !async_readback_started
        @warn "Async PBO readback unavailable; recording is using direct framebuffer capture"
    end
    @info "Recording started: $(rec.output_path)"
    return true
end

"Stop the current recording session: close FFmpeg pipe, finalise video."
function stop_recording!(
        rec::RecordingState, console_push::Function;
        stop_message::Union{Nothing, String} = nothing,
        failure_message::Union{Nothing, String} = nothing,
    )
    # Drain queued frames before closing FFmpeg
    capture_seconds = max(0.0, time() - rec.started_at)
    output = rec.output_path
    exit_code = nothing
    writer_failure = poll_writer_failure!(rec)
    readback_failure = teardown_recording_readback!(rec; allow_enqueue = isnothing(writer_failure))

    shutdown_failure = shutdown_ffmpeg_writer!(rec)
    writer_failure = first_recording_failure(writer_failure, shutdown_failure)

    # Close the encoder and its stderr reader
    if !isnothing(rec.ffmpeg_process)
        try
            isopen(rec.ffmpeg_process.in) && close(rec.ffmpeg_process.in)
            wait(rec.ffmpeg_process)
        catch e
            @warn "Error closing FFmpeg process" exception = (e, catch_backtrace())
        end
        exit_code = rec.ffmpeg_process.exitcode
        rec.ffmpeg_process = nothing
    end

    if !isnothing(rec.ffmpeg_stderr_pipe)
        try
            isopen(rec.ffmpeg_stderr_pipe.in) && close(rec.ffmpeg_stderr_pipe.in)
        catch e
            @debug "Error closing FFmpeg stderr pipe" exception = (e, catch_backtrace())
        end
    end

    if !isnothing(rec.ffmpeg_stderr_task)
        try
            wait(rec.ffmpeg_stderr_task)
        catch e
            @debug "Error waiting for FFmpeg stderr reader" exception = (e, catch_backtrace())
        end
        rec.ffmpeg_stderr_task = nothing
    end
    rec.ffmpeg_stderr_pipe = nothing

    # Reset session state and discard empty output
    rec.is_recording = false
    rec.last_frame_time = 0.0
    rec.accumulator = 0.0

    output_exists = isfile(output)
    output_has_data = output_exists && filesize(output) > 0

    if output_exists && !output_has_data
        rm(output; force = true)
        output_exists = false
    end

    # Report the most specific outcome available
    if !isnothing(writer_failure)
        console_push("Recording failed; see the terminal log for details")
        captured_log = ffmpeg_log_text(rec)
        if isempty(captured_log)
            @warn "Recording failed: writer task error" exception = (writer_failure.exception, writer_failure.backtrace)
        else
            @warn "Recording failed: writer task error" exception = (writer_failure.exception, writer_failure.backtrace) ffmpeg_log = captured_log
        end
    elseif !isnothing(readback_failure)
        console_push("Recording failed; see the terminal log for details")
        captured_log = ffmpeg_log_text(rec)
        if isempty(captured_log)
            @warn "Recording failed: readback shutdown error" exception = (readback_failure.exception, readback_failure.backtrace)
        else
            @warn "Recording failed: readback shutdown error" exception = (readback_failure.exception, readback_failure.backtrace) ffmpeg_log = captured_log
        end
    elseif !isnothing(failure_message)
        console_push("Recording failed; see the terminal log for details")
        @warn "Recording stopped after a capture failure" reason = failure_message exit_code = exit_code output_path = output
    elseif !isnothing(stop_message)
        console_push("Recording stopped because $(stop_message)")
        if isnothing(exit_code) || exit_code == 0
            @info "Recording stopped: $(stop_message)"
        else
            @warn "Recording stopped after FFmpeg exited with code $(exit_code): $(stop_message)"
            captured_log = ffmpeg_log_text(rec)
            isempty(captured_log) || @warn "FFmpeg stderr tail" ffmpeg_log = captured_log
        end
    elseif exit_code == 0 && output_has_data
        expected_frames = floor(Int, capture_seconds * RECORDING_TARGET_FPS)
        if capture_seconds >= 3.0 && rec.frame_count < 0.9 * expected_frames
            @warn "Recording below target frame rate; playback will be shorter than the recording period" expected_frames actual_frames = rec.frame_count pbo_skips = rec.pbo_skips buffer_drops = rec.buffer_drops
        end
        console_push("Recording saved: $(output) ($(rec.frame_count) frames)")
        @info "Recording saved: $(output) ($(rec.frame_count) frames)"
    else
        failure_detail = isnothing(exit_code) ? "encoder process unavailable" : "encoder exited with code $(exit_code)"
        console_push("Recording failed; see the terminal log for details")
        captured_log = ffmpeg_log_text(rec)
        if isempty(captured_log)
            @warn "Recording failed: $(failure_detail)"
        else
            @warn "Recording failed: $(failure_detail)" ffmpeg_log = captured_log
        end
    end

    return nothing
end

"""
Per-frame capture tick. Call from the main loop between ui_rendering! and SwapBuffers.

Handles screenshot requests, recording start/stop transitions, window resize detection,
frame timing, pixel readback, and piping to FFmpeg.
"""
function recording_tick!(rec::RecordingState, inputstate, viewstate, window, console_push::Function)
    # Apply capture mode transitions
    if inputstate.is_recording && !rec.is_recording
        if !start_recording!(rec, viewstate.fb_width, viewstate.fb_height, console_push)
            inputstate.is_recording = false
        end
        return nothing
    end

    # Detect stop transition
    if !inputstate.is_recording && rec.is_recording
        stop_recording!(rec, console_push)
        return nothing
    end

    # Handle one-shot screenshots while idle
    if inputstate.screenshot_requested
        inputstate.screenshot_requested = false
        if !rec.is_recording
            save_screenshot!(rec, viewstate.fb_width, viewstate.fb_height, console_push)
        end
        return nothing
    end

    if !rec.is_recording
        return nothing
    end

    # Stop on asynchronous or display failures
    writer_failure = poll_writer_failure!(rec)
    if !isnothing(writer_failure)
        @warn "Recording writer failed, stopping recording" exception = (writer_failure.exception, writer_failure.backtrace)
        inputstate.is_recording = false
        stop_recording!(rec, console_push)
        return nothing
    end

    # Stop recording if dimensions changed
    fb_size = GLFW.GetFramebufferSize(window)
    if fb_size.width != rec.buffer_width || fb_size.height != rec.buffer_height
        inputstate.is_recording = false
        stop_recording!(rec, console_push; stop_message = "window was resized")
        return nothing
    end

    # Capture the next due frame
    if !should_capture_frame!(rec)
        return nothing
    end

    # Capture and enqueue frame
    try
        if rec.async_readback_enabled
            process_async_readback_tick!(rec)
        else
            capture_frame_direct!(rec)
        end
    catch e
        @warn "Recording frame capture failed, stopping recording" exception = (e, catch_backtrace())
        inputstate.is_recording = false
        stop_recording!(rec, console_push; failure_message = "frame capture failed")
    end

    return nothing
end
