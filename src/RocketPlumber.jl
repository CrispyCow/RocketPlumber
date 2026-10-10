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
import BaseDirs
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
# Application Assembly
# ===============================================================

include("initial_window_setup.jl")
include("recording.jl")
include("interactions.jl")
include("components.jl")
include("timelapse.jl")
include("ui_common.jl")
include("ui_game.jl")
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
    window = start_window()
    enter_start_menu(window)
    finish_telemetry!(; directory = telemetry_dir())
    return nothing
end

"Run the production application and report failures to compiled launchers."
function (@main)(args::Vector{String})::Cint
    try
        launch(; parse_launch_args(args)...)
        return 0
    catch err
        @error "Rocket Plumber failed" exception = (err, catch_backtrace())
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
