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
        julia --project=. --threads=2 src/repl_launch.jl
    
    To run from REPL (recommended for development):
        julia> include("src/repl_launch.jl")
        (or use an IDE like VSCode to run this file directly)
=#

# ===============================================================
# Project Dependencies
# ===============================================================

# Start Revise.jl First
using Revise
# Packages
using LinearAlgebra, StaticArrays
using ModernGL, GLFW, JLD2, CSyntax.CRef
using TimerOutputs, Accessors, Printf, CSyntax
using FilePathsBase, NativeFileDialog
import CImGui, CImGui.lib
# Custom Packages (working title: HexFlow; project: Rocket Plumber)
using HexFrame, HexElements, HexFluids, HexFlowTelemetry
using HexComponentsAPI, FlowEngine, RenderEngine, HexFlowProcGen
using HexFlowControl, HexFlowCalculator, HexFlowRendering
using SquirrelNoise

# ===============================================================
# Startup Sequence
# ===============================================================

# minimal load to get a window + ImGui context up quickly
includet(joinpath(dirname(@__FILE__), "initial_window_setup.jl"))
configure_threads() # needs minimum of 2 threads to run properly
window = start_window()
ui_loadingscreen_render(window, "Initialising")

# load the rest of the game code, showing a loading screen at each step.
include_with_loadingscreen(window, "interactions.jl")
include_with_loadingscreen(window, "components.jl")
include_with_loadingscreen(window, "gameloop.jl")
include_with_loadingscreen(window, "demo.jl")

# GAME LAUNCH
include_with_loadingscreen(window, "startmenu.jl")

enter_start_menu(window)
