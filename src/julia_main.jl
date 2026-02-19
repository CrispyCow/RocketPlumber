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

    JULIAC/PACKAGECOMPILER ENTRY POINT
    
    This script is the production entry point for compilation.
    
    Key differences from repl_launch.jl:
    • Does NOT load Revise (not needed for compiled executables)
    • Loads all source files upfront using include() (no loading screens)
    • Defines @main function for JuliaC/PackageCompiler compatibility
    • Suitable for creating compiled executables with juliac
    
    For interactive development with hot-reloading, use repl_launch.jl instead.
    
    To run directly (testing before compilation):
        julia --project=. --threads=2 src/julia_main.jl
=#

# ===============================================================
# Artifact Verification for Production Build
# ===============================================================

# Verify that required artifacts exist before loading HexFlowRendering
# Artifacts must be created by the build scripts (see build/create_artifacts.jl)
using Pkg
using Pkg.Artifacts

"Verify that all required HexFlow artifacts are available"
function verify_required_artifacts()
    # Locate HexFlowRendering package
    hexflow_rendering_dir = joinpath(dirname(@__FILE__), "..", "local_packages", "HexFlowRendering")
    artifacts_toml = joinpath(hexflow_rendering_dir, "Artifacts.toml")
    
    # Check if Artifacts.toml exists
    if !isfile(artifacts_toml)
        error("""
            Artifacts.toml not found at: $artifacts_toml
            
            Artifacts must be created before running the application.
            Please run one of the following:
            
            • Build with JuliaC:
              julia --project=. --threads=2 build/juliac_build.jl
            
            • Build with PackageCompiler:
              julia --project=. --threads=2 build/packagecompiler_build.jl
            
            • Create artifacts only (no build):
              julia --project=. build/create_artifacts.jl
            """)
    end
    
    # Verify each required artifact
    required_artifacts = ["shaders", "texture_atlas"]
    
    for artifact_name in required_artifacts
        # Check if artifact is defined in Artifacts.toml
        hash = Pkg.Artifacts.artifact_hash(artifact_name, artifacts_toml)
        if hash === nothing
            error("""
                Required artifact '$artifact_name' not found in Artifacts.toml
                
                The Artifacts.toml file exists but is missing the '$artifact_name' artifact.
                This likely means the artifact creation process was interrupted or failed.
                
                Please regenerate artifacts by running:
                  julia --project=. build/create_artifacts.jl
                """)
        end
        
        # Check if artifact is actually installed
        if !Pkg.Artifacts.artifact_exists(hash)
                    error("""
                        Artifact '$artifact_name' is defined but not installed.
                        
                        Hash: $hash
                        Expected location: $(Pkg.Artifacts.artifact_path(hash))
                        
                        The artifact is registered in Artifacts.toml but the files are missing
                        from the Julia artifact cache. This can happen if the cache was cleared.
                        
                        Please regenerate artifacts by running:
                        julia --project=. build/create_artifacts.jl
                        """)
            end
        
        @info "Verified artifact: $artifact_name (hash: $hash)"
    end
    
    @info "All required artifacts verified successfully"
    return true
end

# Verify artifacts before proceeding
verify_required_artifacts()

# ===============================================================
# Project Dependencies (without Revise)
# ===============================================================

# Packages
using LinearAlgebra, StaticArrays, GeometryBasics
using ModernGL, GLFW, JLD2, CSyntax.CRef
using TimerOutputs, Accessors, Printf, CSyntax
using FilePathsBase, NativeFileDialog
import CImGui, CImGui.lib
using ImPlot
# Custom Packages (working title: HexFlow; project: Rocket Plumber)
using HexFrame, HexElements, HexFluids, HexFlowTelemetry
using HexComponentsAPI, FlowEngine, FlowMap, RenderEngine, HexFlowProcGen
using HexFlowControl, HexFlowCalculator, HexFlowRendering
using SquirrelNoise

# ===============================================================
# Load All Source Files Upfront
# ===============================================================

include(joinpath(dirname(@__FILE__), "initial_window_setup.jl"))
include(joinpath(dirname(@__FILE__), "interactions.jl"))
include(joinpath(dirname(@__FILE__), "components.jl"))
include(joinpath(dirname(@__FILE__), "ui_common.jl"))
include(joinpath(dirname(@__FILE__), "ui_game.jl"))
include(joinpath(dirname(@__FILE__), "ui_menus.jl"))
include(joinpath(dirname(@__FILE__), "gameloop.jl"))
include(joinpath(dirname(@__FILE__), "demo.jl"))
include(joinpath(dirname(@__FILE__), "startmenu.jl"))

# ===============================================================
# Main Entry Point for JuliaC
# ===============================================================

# Main entry point for JuliaC compiled executable.
function main(args::Vector{String})::Cint
    try
        configure_threads() # needs minimum of 2 threads to run properly
        window = start_window()
        enter_start_menu(window)
        return 0 # Success
    catch e
        @error "Application error" exception=(e, catch_backtrace())
        return 1 # Error
    end
end

# Compatibility wrapper for PackageCompiler
function main()::Cint
    return main(String[])
end

@main
