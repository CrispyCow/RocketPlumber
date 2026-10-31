#=
Scope: Canonical Rocket Plumber application module and startup API
Formatter: Runic
=#

module RocketPlumber

# Runtime dependencies
using LinearAlgebra, StaticArrays, GeometryBasics
using ModernGL, GLFW, CSyntax.CRef
using TimerOutputs, Accessors, Printf, CSyntax
using FilePathsBase, NativeFileDialog, FFMPEG
using RelocatableFolders
import Dates
import BaseDirs
import TOML
import CImGui, CImGui.lib
using ImPlot

# Local packages
using HexFrame, HexElements, HexFluids, HexFlowTelemetry
using HexComponentsAPI, FlowEngine, FlowMap, RenderEngine, HexFlowProcGen
using HexFlowControl, HexFlowCalculator, HexFlowRendering
using SquirrelNoise, HexFlowLearningSystem, HexFlowPersistence

# ===============================================================
# Application Output Directories
# ===============================================================

"Resolve an application output directory at runtime, creating it only when requested."
function output_dir(parts::String...; create::Bool = false)::String
    directory = abspath(joinpath(BaseDirs.User.documents("RocketPlumber-saves"), parts...))
    create && mkpath(directory)
    return directory
end

maps_dir(; create::Bool = false) = output_dir("maps"; create)
pictures_dir(; create::Bool = false) = output_dir("pictures"; create)
videos_dir(; create::Bool = false) = output_dir("videos"; create)
telemetry_dir(; create::Bool = false) = output_dir("logs", "telemetry"; create)
crashes_dir(; create::Bool = false) = output_dir("logs", "crashes"; create)

# ===============================================================
# Crash Reporting
# ===============================================================

"Choose a timestamped crash-report path without creating its directory."
function crash_report_path()::String
    timestamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    return joinpath(crashes_dir(), "crash_$(timestamp)_$(time_ns()).txt")
end

"Write a readable crash report from already formatted exception and backtrace text."
function write_crash_report(source::String, trace::String; path::String = crash_report_path())::String
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "Rocket Plumber crash report")
        println(io, "Version: ", Base.pkgversion(@__MODULE__))
        println(io, "Date and time (local): ", Dates.now())
        println(io, "Operating system: ", Sys.KERNEL)
        println(io, "Architecture: ", Sys.ARCH)
        println(io, "Julia version: ", VERSION)
        println(io, "Failure source: ", source)
        println(io)
        println(io, trace)
    end
    @info "Crash report written" path
    return path
end

"Attempt paired calculator reports independently; prefer the text path, or return `nothing` if neither was saved."
function write_game_crash_dump(payload::NamedTuple; report_path::String = crash_report_path())::Union{Nothing, String}
    text_path = try
        write_crash_report("FlowCalculator", payload.exception_backtrace; path = report_path)
    catch err
        @warn "Failed to write crash report" exception = (err, catch_backtrace())
        nothing
    end

    dump_path = splitext(report_path)[1] * ".jld2"
    saved_dump = try
        HexFlowPersistence.write_crash_dump(payload, dump_path; game_version = Base.pkgversion(@__MODULE__))
        @info "Crash dump written" path = dump_path
        dump_path
    catch err
        @warn "Failed to write crash dump" exception = (err, catch_backtrace())
        nothing
    end
    return isnothing(text_path) ? saved_dump : text_path
end

# ===============================================================
# Application Assembly
# ===============================================================

include("window.jl")
include("initial_window_setup.jl")
include("app_state.jl")
include("recording.jl")
include("interactions.jl")
include("components.jl")
include("timelapse.jl")
include("ui_common.jl")
include("ui_game.jl")
include("ui_inspection.jl")
include("ui_galaxy_escape.jl")
include("ui_menus.jl")
include("ui_learning.jl")
include("gameloop.jl")
include(joinpath("demo_maps", "mapgen_basicplumbing.jl"))
include(joinpath("demo_maps", "mapgen_bigpipeplumbing.jl"))
include(joinpath("demo_maps", "mapgen_flowdemo.jl"))
include(joinpath("demo_maps", "mapgen_bipropdemo.jl"))
include(joinpath("demo_maps", "mapgen_pressurefedintro.jl"))
include(joinpath("demo_maps", "mapgen_turbopumpintro2.jl"))
include(joinpath("demo_maps", "mapgen_liquidtransfer.jl"))
include(joinpath("demo_maps", "mapgen_teasership.jl"))
include("tutorials.jl")
include("startmenu.jl")

# ===============================================================
# Application Startup
# ===============================================================

export launch

"Parse the application's optional telemetry and GC logging flags."
function parse_launch_args(args::Vector{String})
    for arg in args
        arg in ("--telemetry", "--gc-log") || throw(ArgumentError("Unrecognised argument: $arg"))
    end
    return (telemetry = "--telemetry" in args, gc_log = "--gc-log" in args)
end

"Configure runtime threading, open the game window, and enter the start menu."
function launch(; telemetry::Bool = false, gc_log::Bool = false)
    GLFW.GetPlatform() == GLFW.PLATFORM_NULL && throw(ArgumentError("Graphical startup requires a display"))
    GC.enable_logging(gc_log)
    configure_threads()
    start_telemetry!(telemetry)
    initialise_app_state!()
    should_save_settings = load_app_settings!()
    window = start_window()
    enter_start_menu(window)
    should_save_settings && save_app_settings()
    finish_telemetry!(; directory = telemetry_dir())
    return nothing
end

"Run the production application and report failures to compiled launchers."
function (@main)(args::Vector{String})::Cint
    try
        launch(; parse_launch_args(args)...)
        return 0
    catch err
        bt = catch_backtrace()
        try
            write_crash_report("Application", sprint(showerror, err, bt))
        catch report_err
            @warn "Failed to write crash report" exception = (report_err, catch_backtrace())
        end
        @error "Rocket Plumber failed" exception = (err, bt)
        return 1
    end
end

"PackageCompiler entry point, sharing the JuliaC startup path."
julia_main()::Cint = main(ARGS)

# ===============================================================
# Precompilation
# ===============================================================

include("precompile_workload.jl")

end # module RocketPlumber
