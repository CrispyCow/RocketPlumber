#=
Scope: Interactive development entry point with Revise and staged loading
Formatter: Runic
=#

#=
    ╔════════════════════════════════════════════════════════════════════╗
    ║                                                                    ║
    ║   ██████╗  ██████╗  ██████╗██╗  ██╗███████╗████████╗               ║
    ║   ██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝██╔════╝╚══██╔══╝               ║
    ║   ██████╔╝██║   ██║██║     █████╔╝ █████╗     ██║                  ║
    ║   ██╔══██╗██║   ██║██║     ██╔═██╗ ██╔══╝     ██║                  ║
    ║   ██║  ██║╚██████╔╝╚██████╗██║  ██╗███████╗   ██║                  ║
    ║   ╚═╝  ╚═╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝   ╚═╝                  ║
    ║                                                                    ║
    ║   ██████╗ ██╗     ██╗   ██╗███╗   ███╗██████╗ ███████╗██████╗      ║
    ║   ██╔══██╗██║     ██║   ██║████╗ ████║██╔══██╗██╔════╝██╔══██╗     ║
    ║   ██████╔╝██║     ██║   ██║██╔████╔██║██████╔╝█████╗  ██████╔╝     ║
    ║   ██╔═══╝ ██║     ██║   ██║██║╚██╔╝██║██╔══██╗██╔══╝  ██╔══██╗     ║
    ║   ██║     ███████╗╚██████╔╝██║ ╚═╝ ██║██████╔╝███████╗██║  ██║     ║
    ║   ╚═╝     ╚══════╝ ╚═════╝ ╚═╝     ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝     ║
    ║                                                                    ║
    ║        A circuit-based spacecraft fluid systems simulation         ║
    ║                                   - Created by Christos Lillis     ║
    ╚════════════════════════════════════════════════════════════════════╝

    REPL DEVELOPMENT ENTRY POINT
    
    This script is the recommended entry point for interactive development.
    
    Features:
    • Uses Revise.jl for hot-reloading of code changes during development
    • Shows loading screens during staged file loading (helpful for tracking progress)
    • Intended for use from Julia REPL: include("src/repl_launch.jl")
    
    For creating compiled executables, use julia_main.jl instead.
    
    To run from shell:
        julia --project=. --threads=2,1 --gcthreads=1,1 src/repl_launch.jl
    
    To run from REPL (recommended for development):
        julia> include("src/repl_launch.jl")
        (or use an IDE like VS Code to run this file directly)
=#

# ===============================================================
# Project Dependencies
# ===============================================================

# Start Revise first
using Revise

# External packages
using LinearAlgebra, StaticArrays, GeometryBasics
using ModernGL, GLFW, JLD2, CSyntax.CRef
using TimerOutputs, Accessors, Printf, CSyntax
using FilePathsBase, NativeFileDialog, FFMPEG
import CImGui, CImGui.lib
using ImPlot

# Project packages (working title: HexFlow; project: Rocket Plumber)
using HexFrame, HexElements, HexFluids, HexFlowTelemetry
using HexComponentsAPI, FlowEngine, FlowMap, RenderEngine, HexFlowProcGen
using HexFlowControl, HexFlowCalculator, HexFlowRendering
using SquirrelNoise
using HexFlowLearningSystem

# ===============================================================
# Startup Sequence
# ===============================================================

# Open the window and ImGui context with minimal initial loading
includet(joinpath(dirname(@__FILE__), "initial_window_setup.jl"))
configure_threads()  # Requires at least two threads
window = start_window()
ui_loadingscreen_render(window, "Initialising")

# Load the game with visible loading screens for each stage
include_with_loadingscreen(window, "recording.jl")
include_with_loadingscreen(window, "interactions.jl")
include_with_loadingscreen(window, "components.jl")
include_with_loadingscreen(window, "timelapse.jl")
include_with_loadingscreen(window, "map_loading.jl")
include_with_loadingscreen(window, "gameloop.jl")
include_with_loadingscreen(window, "ui_common.jl")
include_with_loadingscreen(window, "ui_game.jl")
include_with_loadingscreen(window, "ui_galaxy_escape.jl")
include_with_loadingscreen(window, "ui_menus.jl")
include_with_loadingscreen(window, "ui_learning.jl")
include_with_loadingscreen(window, "tutorials.jl")

# Launch the game
include_with_loadingscreen(window, "startmenu.jl")

enter_start_menu(window)
