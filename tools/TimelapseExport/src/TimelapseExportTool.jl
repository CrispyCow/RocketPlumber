module TimelapseExportTool

using Printf
using ModernGL
using CSyntax.CRef
using StaticArrays
using FlowMap
using HexFrame
using HexComponentsAPI

export main, parse_cli, print_help
export ExportOptions, WorldRect, CameraViewport, TimelineEntry, TimelinePlan, FrameSchedule
export assemble_timeline, build_camera_schedule, build_frame_schedule
export tile_area_bounds, padded_bounds, aspect_expand, expand_camera_rect, camera_viewport, animation_tick
export ToolError, UsageError, ValidationError, RenderToolError, OutputError

const DEFAULT_REPOSITORY_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))

include("cli.jl")
include("timeline.jl")
include("camera.jl")
include("reconstruction.jl")
include("renderer.jl")
include("encoder.jl")

# The exporter loads graphical and video packages only for a render. Save loading is
# separate so help, argument validation, and pure tests avoid persistence imports.
module Runtime end
const _runtime_loaded = Ref(false)

module Persistence end
const _persistence_loaded = Ref(false)

"Load save support after help and argument validation."
function load_persistence!()
    _persistence_loaded[] && return nothing
    @eval Persistence using HexFlowPersistence
    _persistence_loaded[] = true
    return nothing
end

"Load rendering and encoding dependencies only for a real export."
function load_runtime!()
    _runtime_loaded[] && return nothing
    try
        @eval Runtime begin
            using FFMPEG, GLFW
            using FlowEngine, RenderEngine
            using HexFlowControl, HexFlowCalculator, HexFlowRendering
        end
        _runtime_loaded[] = true
    catch error
        error isa InterruptException && rethrow()
        throw(RenderToolError("Cannot initialise the exporter game dependencies. A working display server and OpenGL driver are required ($(sprint(showerror, error)))."))
    end
    return nothing
end

"Run the time-lapse exporter and return the documented process exit code."
function main(args::Vector{String} = ARGS; repository_root::AbstractString = DEFAULT_REPOSITORY_ROOT)::Int
    options = try
        parse_cli(args; repository_root = repository_root)
    catch error
        return _report_error(error)
    end

    options.help && (print_help(); return 0)
    return _run(options)
end

"Run an already parsed export request and return the documented process exit code."
function _run(options::ExportOptions)::Int
    try
        validate_paths!(options)
        load_persistence!()
        return Base.invokelatest(_run_with_persistence, options)
    catch error
        return _report_error(error)
    end
end

"Load and plan the saved time lapse before starting the graphical runtime."
function _run_with_persistence(options::ExportOptions)::Int
    println("Loading time-lapse save: $(options.input)")
    bundle = Persistence.HexFlowPersistence.loadmap_bundle(options.input)
    timeline = assemble_timeline(bundle, options)
    cameras = build_camera_schedule(timeline.frames, options)
    schedule = build_frame_schedule(length(timeline.frames), options)

    print_summary(options, timeline, schedule)
    if options.inspect
        print_inspection(options, bundle, timeline, cameras, schedule)
        return 0
    end

    load_runtime!()
    return Base.invokelatest(_render_export, options, timeline, cameras, schedule)
end

"Render and publish an export after its graphical dependencies have loaded."
function _render_export(options::ExportOptions, timeline::TimelinePlan, cameras, schedule::FrameSchedule)::Int
    validate_render_assets!()
    output_path = prepare_output_path!(options)
    temp_directory = try
        mktempdir(dirname(output_path); prefix = ".timelapse-export-")
    catch error
        throw(OutputError("cannot create temporary export directory beside $(output_path): $(sprint(showerror, error))"))
    end
    try
        temporary_output = joinpath(temp_directory, "encoded$(options.format == :mp4 ? ".mp4" : ".gif")")
        renderer = create_renderer(options)
        try
            encode_export!(temporary_output, options, timeline, cameras, schedule, renderer)
            _validate_encoded_output(temporary_output)
        finally
            destroy_renderer!(renderer)
        end
        _publish_encoded_output!(temporary_output, output_path, options.force)
    finally
        isdir(temp_directory) && rm(temp_directory; recursive = true, force = true)
    end

    println("Exported $(schedule.total_frames) frames ($(@sprintf("%.2f", schedule.duration_seconds)) seconds) to $(output_path)")
    println("Final file size: $(filesize(output_path)) bytes")
    return 0
end

function _report_error(error)::Int
    if error isa ToolError
        println(stderr, error.message)
        return error.code
    elseif error isa InterruptException
        println(stderr, "Time-lapse export interrupted.")
        return 130
    end

    showerror(stderr, error)
    println(stderr)
    return 4
end

end
