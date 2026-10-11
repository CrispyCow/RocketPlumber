#=
Scope: Headless recording pipe progress, frame integrity, and writer failure regression tests
Formatter: Runic
=#

ENV["JULIA_GLFW_PLATFORM"] = "null"
using Test, RocketPlumber
const RP = RocketPlumber

@testset "Recording writer progresses while rendering remains runnable" begin
    frame_bytes = 1920 * 1080 * 4 # Far larger than OS pipe buffering
    frame_count = 8
    consumer = """
    buffer = Vector{UInt8}(undef, parse(Int, ARGS[1]))
    for frame in 1:parse(Int, ARGS[2])
        readbytes!(stdin, buffer, length(buffer)) == length(buffer) || error("Partial raw frame")
        all(==(UInt8(frame)), buffer) || error("Corrupted or reordered raw frame")
    end
    eof(stdin) || error("Unexpected extra frame data")
    """
    command = `$(Base.julia_cmd()) --startup-file=no -e $consumer $frame_bytes $frame_count`
    process = RP.start_recording_process(command)
    rec = RP.RecordingState(ffmpeg_process = process)
    RP.initialise_recording_buffers!(rec, Int32(1920), Int32(1080))
    RP.start_ffmpeg_writer!(rec)
    try
        submitted = 0
        sentinel_sent = false
        deadline = time() + 60.0 # Includes subprocess startup on slower CI runners
        while time() < deadline && !istaskdone(rec.writer_task)
            if submitted < frame_count
                slot = RP.try_take_free_recording_slot!(rec)
                if !isnothing(slot)
                    submitted += 1
                    fill!(rec.recording_buffers[slot], UInt8(submitted))
                    RP.submit_recorded_frame!(rec, slot)
                end
            elseif !sentinel_sent
                # shutdown_ffmpeg_writer! waits, which could mask the libuv dependency.
                RP.submit_recording_slot!(rec, RP.RECORDING_STOP_SENTINEL_SLOT)
                sentinel_sent = true
            end

            # Stand in for rendering work, then yield as the game does. Julia sleep()
            # or wait() would service libuv continuously and hide the original regression.
            render_until = time_ns() + 1_000_000
            while time_ns() < render_until
            end
            yield()
        end
        istaskdone(rec.writer_task) || error("Recording writer did not finish while rendering remained runnable")
        @test isnothing(RP.shutdown_ffmpeg_writer!(rec))
        close(process.in)
        wait(process)
        @test success(process) # The consumer checks every complete frame and EOF
        @test rec.frame_count == frame_count
    finally
        # Kill the consumer first so a blocked write cannot hang failure cleanup.
        process_running(process) && kill(process)
        !isnothing(rec.writer_task) && RP.shutdown_ffmpeg_writer!(rec)
        isopen(process.in) && close(process.in)
        wait(process)
    end
end

struct IncompleteRecordingSink <: IO end
Base.unsafe_write(::IncompleteRecordingSink, ::Ptr{UInt8}, bytes::UInt) = Int(bytes) - 1

@testset "Recording writer surfaces incomplete frames" begin
    rec = RP.RecordingState()
    RP.initialise_recording_buffers!(rec, Int32(2), Int32(2))
    RP.submit_recorded_frame!(rec, RP.take_free_recording_slot!(rec))
    RP.ffmpeg_writer_loop!(rec, IncompleteRecordingSink(), rec.ready_slots, rec.free_slots, rec.writer_failure_channel)
    failure = RP.poll_writer_failure!(rec)
    @test failure isa RP.RecordingFailure
    @test occursin("Incomplete recording frame write", sprint(showerror, failure.exception))
end

@testset "Recording process startup failure" begin
    @test_throws Base.IOError RP.start_recording_process(Cmd([joinpath(tempdir(), "missing-recording-encoder", "ffmpeg")]))
end
