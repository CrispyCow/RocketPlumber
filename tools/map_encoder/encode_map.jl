#!/usr/bin/env julia

"""
Map Encoder Tool

A standalone script to encode GameMap structures from JLD2 files into human-readable text format
suitable for AI analysis and code generation.

Usage:
    julia --project=. tools/map_encoder/encode_map.jl <map_path> [output_file]

Arguments:
    map_path    - Path to the map file (.jld2). Can be:
                  - Relative path from current directory (e.g., src/demo_maps/basicplumbing.jld2)
                  - Absolute path (e.g., C:/path/to/map.jld2)
                  - Just a name (e.g., autotest1) - will look in maps/ folder for backwards compatibility
    output_file - Optional: Output file path. If not provided, prints to stdout only

Examples:
    julia --project=. tools/map_encoder/encode_map.jl autotest1
    julia --project=. tools/map_encoder/encode_map.jl src/demo_maps/basicplumbing.jld2
    julia --project=. tools/map_encoder/encode_map.jl ../maps/autotest1.jld2 encoded_autotest1.txt

Note: This script must be run from the project root directory with --project=. to access dependencies.
"""

# Import required packages from the main project
using JLD2
using HexFrame, HexElements, HexFluids, HexComponentsAPI, FlowEngine

# Import components to ensure types are available for JLD2 reconstruction
include(joinpath(dirname(@__FILE__), "..", "..", "src", "components.jl"))

# Helper function to resolve map path from various input formats
function resolve_map_path(input::String)
    # If input already has .jld2 extension, treat as path
    if endswith(input, ".jld2")
        # Check if it exists as-is (absolute or relative to cwd)
        if isfile(input)
            return input
        else
            error("Map file not found: $input")
        end
    else
        # No extension - assume it's a map name in the maps/ folder (backwards compatibility)
        map_path = joinpath("maps", "$input.jld2")
        if !isfile(map_path)
            error("Map file not found: $map_path")
        end
        return map_path
    end
end

# Modified loadmap function to accept file paths
function loadmap(map_input::Union{Nothing,String})
    TileDict = Dict{TileCoord,ComponentOnTile}()
    PipeBehaviorDict = Dict{EdgeCoord,PipeBehavior}()
    ShipSurface = Set{TileCoord}()

    if isnothing(map_input)
        @info "No map loaded..."
    else
        map_path = resolve_map_path(map_input)
        @load map_path TileDict PipeBehaviorDict ShipSurface
        @info "Map loaded successfully from: $map_path"
    end

    return GameMap(tiles=TileDict, pipe_behaviors=PipeBehaviorDict, ship_surface=ShipSurface)
end

"""
    encode_map(map_input::String, output_file::Union{String,Nothing}=nothing)

Encode a GameMap from JLD2 format into human-readable text format.

# Arguments
- `map_input`: Path to map file (.jld2) or map name (for maps/ folder)
- `output_file`: Optional output file path. If nothing, prints to stdout only.

# Returns
- `String`: The encoded map content
"""
function encode_map(map_input::String, output_file::Union{String,Nothing}=nothing)
    # Load the map
    gamemap = loadmap(map_input)
    
    # Create formatted output
    lines = String[]
    
    push!(lines, "GameMap(")
    
    # Format tiles dictionary
    push!(lines, "  tiles = Dict{TileCoord, ComponentOnTile}([")
    for (coord, comp_on_tile) in gamemap.tiles
        # Each component on its own line with proper indentation
        comp_str = repr(comp_on_tile)
        push!(lines, "    $coord => $comp_str,")
    end
    push!(lines, "  ]),")
    
    # Format pipe_behaviors dictionary  
    push!(lines, "  pipe_behaviors = Dict{EdgeCoord, PipeBehavior}([")
    for (edge_coord, pipe_behavior) in gamemap.pipe_behaviors
        pipe_str = repr(pipe_behavior)
        push!(lines, "    $edge_coord => $pipe_str,")
    end
    push!(lines, "  ]),")
    
    # Format ship_surface set
    push!(lines, "  ship_surface = Set{TileCoord}([")
    for coord in gamemap.ship_surface
        push!(lines, "    $coord,")
    end
    push!(lines, "  ])")
    
    push!(lines, ")")
    
    # Join all lines
    output_content = join(lines, "\n")
    
    # Print to stdout
    println(output_content)
    
    # Optionally write to file
    if !isnothing(output_file)
        open(output_file, "w") do io
            write(io, output_content)
        end
        @info "Map encoded and written to: $output_file"
    end
    
    return output_content
end

# CLI Interface
function main()
    if length(ARGS) == 0
        println(stderr, "Error: Map path required")
        println(stderr, "Usage: julia --project=. tools/map_encoder/encode_map.jl <map_path> [output_file]")
        exit(1)
    end
    
    map_input = ARGS[1]
    output_file = length(ARGS) >= 2 ? ARGS[2] : nothing
    
    try
        encode_map(map_input, output_file)
    catch e
        println(stderr, "Error: $e")
        exit(1)
    end
end

# Run main if script is executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end