#=
Scope: Interactive development entry point for the RocketPlumber package
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

    This script loads Revise before the RocketPlumber package and starts the
    game through RocketPlumber.launch(). Package source is tracked by Revise.

    To run from shell:
        julia --project=dev --threads=2,1 --gcthreads=1,1 scripts/repl_launch.jl

    To run from a REPL started in the development environment:
        julia> include("scripts/repl_launch.jl")
        (or use an IDE like VS Code to run this file directly)
=#

# Revise must load before the package so it tracks RocketPlumber source.
using Revise
using RocketPlumber

RocketPlumber.launch()
