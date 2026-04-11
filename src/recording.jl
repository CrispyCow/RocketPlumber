# ===============================================================
# In-Game Screen Recording
# ===============================================================
#
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

"Return the encoded video dimensions after rounding up to H.264-compatible even sizes."
recording_encoded_dims(width::Integer, height::Integer) = (width + width % 2, height + height % 2)

"Return the absolute path to the repository recordings output directory."
capture_output_dir() = abspath(joinpath(dirname(@__FILE__), "..", "recordings"))

"Return the default timestamp suffix for captured output files."
default_capture_timestamp() = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")

"Return the default basename for a captured output file."
function default_capture_basename(kind::Symbol, timestamp::AbstractString)
    if kind == :recording
        return "recording_$(timestamp).mp4"
    elseif kind == :screenshot
        return "screenshot_$(timestamp).png"
    end

    throw(ArgumentError("Unsupported capture kind: $(kind)"))
end

"Return the default absolute path for a captured output file."
default_capture_path(kind::Symbol, timestamp::AbstractString = default_capture_timestamp()) =
    joinpath(capture_output_dir(), default_capture_basename(kind, timestamp))

"Mutable state for an active (or idle) screen recording session."
@kwdef mutable struct RecordingState
    is_recording::Bool = false
    pixel_buffer::Vector{UInt8} = UInt8[]
    screenshot_buffer::Vector{UInt8} = UInt8[]
    buffer_width::Int32 = 0
    buffer_height::Int32 = 0
    ffmpeg_process::Union{Nothing, Base.Process} = nothing
    ffmpeg_stderr_pipe::Union{Nothing, Pipe} = nothing
    ffmpeg_stderr_task::Union{Nothing, Task} = nothing
    ffmpeg_log_tail::Vector{UInt8} = UInt8[]
    accumulator::Float64 = 0.0
    last_frame_time::Float64 = 0.0
    frame_count::Int64 = 0
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
        glReadPixels(GLint(0), GLint(0), GLsizei(width), GLsizei(height),
                     GL_RGBA, GL_UNSIGNED_BYTE, pointer(buffer))
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

"Capture the current framebuffer and save it as a PNG screenshot."
function save_screenshot!(rec::RecordingState, fb_width::Int32, fb_height::Int32, console_push::Function)
    output_dir = capture_output_dir()
    mkpath(output_dir)
    output_path = default_capture_path(:screenshot)

    buffer_size = fb_width * fb_height * 4
    resize!(rec.screenshot_buffer, buffer_size)

    try
        capture_framebuffer!(rec.screenshot_buffer, fb_width, fb_height)
        screenshot_image = framebuffer_rgba_to_image(rec.screenshot_buffer, fb_width, fb_height)
        save_png_screenshot(output_path, screenshot_image)
        console_push("Screenshot saved: $(output_path)")
        @info "Screenshot saved: $(output_path)"
    catch e
        console_push("Screenshot failed while saving to $(output_path): $(string(e))")
        @warn "Screenshot capture failed" output_path = output_path exception = (e, catch_backtrace())
    end

    return nothing
end

# ===============================================================
# FFmpeg Encoder
# ===============================================================

"Start an FFmpeg subprocess that reads raw RGBA frames from stdin and encodes to H.264 MP4."
function start_ffmpeg_encoder(width::Integer, height::Integer, fps::Integer, output_path::String)::Base.Process
    ffmpeg_path = FFMPEG.ffmpeg()
    video_filter = "vflip,pad=ceil(iw/2)*2:ceil(ih/2)*2"
    cmd = `$ffmpeg_path -y
        -f rawvideo -pix_fmt rgba -s $(width)x$(height) -r $fps -i pipe:0
        -threads 4 -c:v libx264 -preset medium -pix_fmt yuv420p -crf 20 -vf $video_filter
        $output_path`
    return open(cmd, "w")
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

# ===============================================================
# Recording Lifecycle
# ===============================================================

"Begin a new recording session: allocate buffer, open FFmpeg, reset timing."
function start_recording!(rec::RecordingState, fb_width::Int32, fb_height::Int32, console_push::Function)::Bool
    output_dir = capture_output_dir()
    mkpath(output_dir)
    rec.output_path = default_capture_path(:recording)
    empty!(rec.ffmpeg_log_tail)
    rec.ffmpeg_stderr_pipe = nothing
    rec.ffmpeg_stderr_task = nothing

    # Allocate or resize pixel buffer
    buffer_size = fb_width * fb_height * 4
    resize!(rec.pixel_buffer, buffer_size)
    rec.buffer_width = fb_width
    rec.buffer_height = fb_height

    try
        rec.ffmpeg_stderr_pipe = Pipe()
        rec.ffmpeg_process = redirect_stderr(rec.ffmpeg_stderr_pipe) do
            start_ffmpeg_encoder(fb_width, fb_height, RECORDING_TARGET_FPS, rec.output_path)
        end
        rec.ffmpeg_stderr_task = @async drain_ffmpeg_stderr!(rec, rec.ffmpeg_stderr_pipe)
    catch e
        rec.ffmpeg_process = nothing
        rec.ffmpeg_stderr_pipe = nothing
        rec.ffmpeg_stderr_task = nothing
        rec.output_path = ""
        console_push("Recording failed: could not start encoder")
        @warn "Recording start failed" exception = (e, catch_backtrace())
        return false
    end

    rec.accumulator = 0.0
    rec.last_frame_time = 0.0
    rec.frame_count = 0
    rec.is_recording = true

    console_push("Recording started: $(rec.output_path) ($(fb_width)×$(fb_height) @ $(RECORDING_TARGET_FPS)fps)")
    encoded_width, encoded_height = recording_encoded_dims(fb_width, fb_height)
    if encoded_width != fb_width || encoded_height != fb_height
        console_push("Recording output padded to $(encoded_width)×$(encoded_height) for H.264 compatibility")
    end
    @info "Recording started: $(rec.output_path)"
    return true
end

"Stop the current recording session: close FFmpeg pipe, finalise video."
function stop_recording!(rec::RecordingState, console_push::Function; stop_message::Union{Nothing, String} = nothing)
    output = rec.output_path
    exit_code = nothing

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

    rec.is_recording = false
    rec.last_frame_time = 0.0
    rec.accumulator = 0.0

    output_exists = isfile(output)
    output_has_data = output_exists && filesize(output) > 0

    if output_exists && !output_has_data
        rm(output; force = true)
        output_exists = false
    end

    if !isnothing(stop_message)
        console_push("Recording stopped: $(stop_message)")
        if isnothing(exit_code) || exit_code == 0
            @info "Recording stopped: $(stop_message)"
        else
            @warn "Recording stopped after FFmpeg exited with code $(exit_code): $(stop_message)"
            captured_log = ffmpeg_log_text(rec)
            isempty(captured_log) || @warn "FFmpeg stderr tail" ffmpeg_log = captured_log
        end
    elseif exit_code == 0 && output_has_data
        console_push("Recording saved: $(output) ($(rec.frame_count) frames)")
        @info "Recording saved: $(output) ($(rec.frame_count) frames)"
    else
        failure_detail = isnothing(exit_code) ? "encoder process unavailable" : "encoder exited with code $(exit_code)"
        console_push("Recording failed: $(failure_detail)")
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
    # Detect start transition
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

    # One-shot screenshot capture when idle
    if inputstate.screenshot_requested
        inputstate.screenshot_requested = false
        if !rec.is_recording
            save_screenshot!(rec, viewstate.fb_width, viewstate.fb_height, console_push)
        end
        return nothing
    end

    # Nothing to do if not recording
    if !rec.is_recording
        return nothing
    end

    # Detect window resize — stop recording if dimensions changed
    fb_size = GLFW.GetFramebufferSize(window)
    if fb_size.width != rec.buffer_width || fb_size.height != rec.buffer_height
        inputstate.is_recording = false
        stop_recording!(rec, console_push; stop_message = "window was resized")
        return nothing
    end

    # Check if we should capture a frame this iteration
    if !should_capture_frame!(rec)
        return nothing
    end

    # Capture and write frame
    try
        capture_framebuffer!(rec.pixel_buffer, rec.buffer_width, rec.buffer_height)
        write(rec.ffmpeg_process.in, rec.pixel_buffer)
        rec.frame_count += 1
    catch e
        @warn "Recording frame write failed, stopping recording" exception = (e, catch_backtrace())
        inputstate.is_recording = false
        stop_recording!(rec, console_push; stop_message = "write error")
    end

    return nothing
end
