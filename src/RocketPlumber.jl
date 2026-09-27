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
import CImGui, CImGui.lib
using ImPlot

# Local packages
using HexFrame, HexElements, HexFluids, HexFlowTelemetry
using HexComponentsAPI, FlowEngine, FlowMap, RenderEngine, HexFlowProcGen
using HexFlowControl, HexFlowCalculator, HexFlowRendering
using SquirrelNoise, HexFlowLearningSystem, HexFlowPersistence

# Application assembly
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
include(joinpath("demo_maps", "mapgen_controllingcoldgas.jl"))
include(joinpath("demo_maps", "mapgen_pressurefedintro.jl"))
include(joinpath("demo_maps", "mapgen_turbopumpintro2.jl"))
include(joinpath("demo_maps", "mapgen_liquidtransfer.jl"))
include(joinpath("demo_maps", "mapgen_teasership.jl"))
include("tutorials.jl")
include("startmenu.jl")

export launch

"Configure runtime threading, open the game window, and enter the start menu."
function launch()
    GLFW.GetPlatform() == GLFW.PLATFORM_NULL && throw(ArgumentError("Graphical startup requires a display"))
    configure_threads()
    window = start_window()
    enter_start_menu(window)
    return nothing
end

"Run the production application and report failures to compiled launchers."
function (@main)(args::Vector{String})::Cint
    try
        launch()
        return 0
    catch err
        @error "Rocket Plumber failed" exception = (err, catch_backtrace())
        return 1
    end
end

"PackageCompiler entry point, sharing the JuliaC startup path."
julia_main()::Cint = main(ARGS)

end # module RocketPlumber
