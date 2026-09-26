const FFMPEG_TAIL_BYTES = 1024 * 1024

mutable struct FfmpegSession
    process::Base.Process
    stderr_pipe::Pipe
    stderr_task::Task
    tail::Vector{UInt8}
end

function _append_tail!(tail::Vector{UInt8}, chunk::Vector{UInt8})
    append!(tail, chunk)
    overflow = length(tail) - FFMPEG_TAIL_BYTES
    overflow > 0 && deleteat!(tail, 1:overflow)
    return nothing
end

function _drain_stderr!(tail::Vector{UInt8}, pipe::Pipe)
    try
        while true
            chunk = read(pipe.out, 4096)
            isempty(chunk) && break
            _append_tail!(tail, chunk)
        end
    catch
        # Closing a failed process can race the reader; the exit status remains authoritative.
    end
    return nothing
end

function _start_ffmpeg(command)
    stderr_pipe = Pipe()
    tail = UInt8[]
    process = try
        redirect_stderr(stderr_pipe) do
            open(command, "w")
        end
    catch error
        isopen(stderr_pipe.in) && close(stderr_pipe.in)
        throw(OutputError("could not start FFmpeg: $(sprint(showerror, error))"))
    end
    stderr_task = @async _drain_stderr!(tail, stderr_pipe)
    return FfmpegSession(process, stderr_pipe, stderr_task, tail)
end

function _finish_ffmpeg!(session::FfmpegSession, description::AbstractString)
    try
        isopen(session.process.in) && close(session.process.in)
        wait(session.process)
    catch error
        try
            process_exited(session.process) || kill(session.process)
        catch
        end
        error isa InterruptException && rethrow()
        throw(OutputError("FFmpeg failed while $(description): $(sprint(showerror, error))"))
    finally
        try
            isopen(session.stderr_pipe.in) && close(session.stderr_pipe.in)
        catch
        end
        try
            wait(session.stderr_task)
        catch
        end
    end
    session.process.exitcode == 0 || throw(OutputError("FFmpeg exited with status $(session.process.exitcode) while $(description): $(_stderr_tail(session.tail))"))
    return nothing
end

function _abort_ffmpeg!(session::FfmpegSession)
    try
        isopen(session.process.in) && close(session.process.in)
    catch
    end
    try
        process_exited(session.process) || kill(session.process)
    catch
    end
    try
        wait(session.process)
    catch
    end
    try
        isopen(session.stderr_pipe.in) && close(session.stderr_pipe.in)
        wait(session.stderr_task)
    catch
    end
    return nothing
end

function _stderr_tail(tail::Vector{UInt8})
    text = strip(replace(String(tail), '\0' => ' '))
    isempty(text) ? "(no FFmpeg diagnostics)" : text
end

function _mp4_command(options::ExportOptions, output::AbstractString)
    ffmpeg = Runtime.FFMPEG.ffmpeg()
    return `$ffmpeg -y -hide_banner -f rawvideo -pix_fmt rgba -s $(options.width)x$(options.height) -r $(options.fps) -i pipe:0 -vf vflip -threads 4 -c:v libx264 -preset $(options.preset) -crf $(options.crf) -pix_fmt yuv420p -movflags +faststart $(output)`
end

function _palette_command(options::ExportOptions, output::AbstractString)
    ffmpeg = Runtime.FFMPEG.ffmpeg()
    filter = "vflip,palettegen=stats_mode=diff:max_colors=256"
    return `$ffmpeg -y -hide_banner -f rawvideo -pix_fmt rgba -s $(options.width)x$(options.height) -r $(options.fps) -i pipe:0 -vf $filter -frames:v 1 -update 1 $(output)`
end

function _gif_command(options::ExportOptions, palette::AbstractString, output::AbstractString)
    ffmpeg = Runtime.FFMPEG.ffmpeg()
    filter = "[0:v]vflip[video];[video][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle"
    return `$ffmpeg -y -hide_banner -f rawvideo -pix_fmt rgba -s $(options.width)x$(options.height) -r $(options.fps) -i pipe:0 -i $(palette) -lavfi $filter -loop 0 $(output)`
end

"Write one frame, converting an early encoder exit into a diagnostic output failure."
function _write_ffmpeg_frame!(session::FfmpegSession, bytes, description::AbstractString)
    try
        write(session.process.in, bytes)
    catch write_error
        try
            _finish_ffmpeg!(session, description)
        catch finish_error
            finish_error isa InterruptException && rethrow()
            finish_error isa OutputError && throw(finish_error)
            throw(OutputError("FFmpeg failed while $(description): $(sprint(showerror, finish_error))"))
        end
        throw(OutputError(
            "FFmpeg stopped accepting frames while $(description): $(sprint(showerror, write_error)); $(_stderr_tail(session.tail))",
        ))
    end
    return nothing
end

function _stream_frames!(command, description::AbstractString, renderer::ExportRenderer, timeline::TimelinePlan, cameras, schedule::FrameSchedule)
    options = renderer.options
    options.verbose && println("FFmpeg: starting $(description) at $(options.width)x$(options.height), $(options.fps) fps (raw RGBA input)")
    session = _start_ffmpeg(command)
    try
        each_rendered_frame(renderer, timeline, cameras, schedule; label = description) do bytes, _, _, _
            _write_ffmpeg_frame!(session, bytes, description)
        end
        _finish_ffmpeg!(session, description)
    catch
        _abort_ffmpeg!(session)
        rethrow()
    end
    return nothing
end

function encode_export!(temporary_output::AbstractString, options::ExportOptions, timeline::TimelinePlan, cameras, schedule::FrameSchedule, renderer::ExportRenderer)
    if options.format == :mp4
        _stream_frames!(_mp4_command(options, temporary_output), "MP4 encode", renderer, timeline, cameras, schedule)
        return nothing
    end

    palette = joinpath(dirname(temporary_output), "palette.png")
    _stream_frames!(_palette_command(options, palette), "palette pass", renderer, timeline, cameras, schedule)
    isfile(palette) && filesize(palette) > 0 || throw(OutputError("FFmpeg palette pass did not create a non-empty palette"))
    _stream_frames!(_gif_command(options, palette, temporary_output), "GIF encode pass", renderer, timeline, cameras, schedule)
    isfile(palette) && rm(palette; force = true)
    return nothing
end

function _validate_encoded_output(path::AbstractString)
    isfile(path) && filesize(path) > 0 || throw(OutputError("FFmpeg produced no non-empty encoded output"))
    return nothing
end
