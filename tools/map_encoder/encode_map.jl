#!/usr/bin/env julia

#NOTE/TODO: This code will need to be refactored once GameMap structure changes

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
using HexFrame, HexElements, HexFluids, HexComponentsAPI, FlowMap
# Import HexFlowProcGen because `src/components.jl` references it at top level
# (e.g., `roll_pipe`, `NOZZLE_EDGE_PLACE`, `shipset_*`). This ensures the
# `include("src/components.jl")` call succeeds when run from this script.
using HexFlowProcGen

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

# Modified loadmap function to accept file paths and load multi-ship GameMap
function loadmap(map_input::Union{Nothing,String})
    if isnothing(map_input)
        @info "No map loaded..."
        return GameMap()
    else
        map_path = resolve_map_path(map_input)
        # Open the JLD2 file and look for known top-level keys: `ships` or `stored_gamemap`
        jldopen(map_path, "r") do f
            if haskey(f, "ships")
                ships = read(f, "ships")
                @info "Map loaded successfully from: $map_path (ships)"
                return GameMap(ships = ships)
            elseif haskey(f, "stored_gamemap")
                gm = read(f, "stored_gamemap")
                # If the stored object already reconstructed to GameMap-like, prefer it
                try
                    if hasproperty(gm, :ships)
                        @info "Map loaded successfully from: $map_path (stored_gamemap)"
                        return gm
                    end
                catch
                end

                # If stored_gamemap is an array of Pair{Symbol, ShipMap}, convert
                if isa(gm, Array)
                    d = Dict{Symbol, ShipMap}()
                    for p in gm
                        d[p.first] = p.second
                    end
                    @info "Map loaded successfully from: $map_path (stored_gamemap as array)"
                    return GameMap(ships = d)
                end

                # If it's a dictionary-like structure with :ships key
                if isa(gm, Dict) && haskey(gm, :ships)
                    @info "Map loaded successfully from: $map_path (stored_gamemap as dict)"
                    return GameMap(ships = gm[:ships])
                end

                error("Could not interpret stored_gamemap structure in: $map_path")
            else
                error("Map file does not contain 'ships' or 'stored_gamemap': $map_path")
            end
        end
    end
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
# Note: We do not perform aggressive sanitization here - the agent invoking
# this tool should supply a suitable basename. We will use the file basename (sans
# extension) directly for function naming so it's transparent and editable by the user.
function get_basename(input::String)
    base = basename(input)
    base = replace(base, ".jld2" => "")
    return base
end

function generate_mapgen_code(gamemap::GameMap, funcname::String; mapnote="")
    lines = String[]
    push!(lines, "# Generated map creation function")
    push!(lines, "# Auto-generated by tools/map_encoder/encode_map.jl")
    if !isempty(mapnote)
        push!(lines, "# $mapnote")
    end
    push!(lines, "function $funcname()")
    push!(lines, "    # Construct ShipMaps individually and combine into a GameMap")

    for (ship_name, ship) in gamemap.ships
        # Sanitize ship name for use in a variable and preserve original symbol for map key
        raw_name = string(ship_name)
        var_suffix = lowercase(replace(raw_name, r"[^A-Za-z0-9]" => "_"))
        var_suffix = replace(var_suffix, r"_+" => "_")
        var_suffix = strip(var_suffix, '_')
        ship_var = "ship_" * (isempty(var_suffix) ? "unnamed" : var_suffix)

        push!(lines, "    # Ship: :$ship_name")
        push!(lines, "    $ship_var = ShipMap()")

        # Components
        if !isempty(ship.components)
            push!(lines, "    $ship_var.components = Dict{TileCoord, ComponentOnTile}([")
            for (coord, comp_on_tile) in ship.components
                push!(lines, "        $(repr(coord)) => $(repr(comp_on_tile)),")
            end
            push!(lines, "    ])")
        end

        # Pipes
        if !isempty(ship.pipe_behaviors)
            push!(lines, "    $ship_var.pipe_behaviors = Dict{EdgeCoord, PipeBehavior}([")
            for (edge_coord, pipe_behavior) in ship.pipe_behaviors
                push!(lines, "        $(repr(edge_coord)) => $(repr(pipe_behavior)),")
            end
            push!(lines, "    ])")
        end

        # Ship tiles
        if !isempty(ship.ship_tiles)
            push!(lines, "    $ship_var.ship_tiles = Set{TileCoord}([")
            for coord in ship.ship_tiles
                push!(lines, "        $(repr(coord)),")
            end
            push!(lines, "    ])")
        end

        push!(lines, "")
    end

    push!(lines, "    map = GameMap()")
    for (ship_name, ship) in gamemap.ships
        raw_name = string(ship_name)
        var_suffix = lowercase(replace(raw_name, r"[^A-Za-z0-9]" => "_"))
        var_suffix = replace(var_suffix, r"_+" => "_")
        var_suffix = strip(var_suffix, '_')
        ship_var = "ship_" * (isempty(var_suffix) ? "unnamed" : var_suffix)
        push!(lines, "    map.ships[Symbol(\"$raw_name\")] = $ship_var")
    end

    push!(lines, "    return map")
    push!(lines, "end")

    return join(lines, "\n")
end

function encode_map(map_input::String, output_file::Union{String,Nothing}=nothing)
    # Load the map
    gamemap = loadmap(map_input)
    
    # Create formatted output (human-readable summary)
    lines = String[]
    push!(lines, "GameMap(")

    for (ship_name, ship) in gamemap.ships
        push!(lines, "  Ship( :$(ship_name) )")
        # Format components dictionary for this ship
        push!(lines, "    components = Dict{TileCoord, ComponentOnTile}([")
        for (coord, comp_on_tile) in ship.components
            comp_str = repr(comp_on_tile)
            push!(lines, "      $coord => $comp_str,")
        end
        push!(lines, "    ]),")

        # Format pipe_behaviors dictionary for this ship
        push!(lines, "    pipe_behaviors = Dict{EdgeCoord, PipeBehavior}([")
        for (edge_coord, pipe_behavior) in ship.pipe_behaviors
            pipe_str = repr(pipe_behavior)
            push!(lines, "      $edge_coord => $pipe_str,")
        end
        push!(lines, "    ]),")

        # Format ship_tiles set for this ship
        push!(lines, "    ship_tiles = Set{TileCoord}([")
        for coord in ship.ship_tiles
            push!(lines, "      $coord,")
        end
        push!(lines, "    ])")
        push!(lines, "")
    end

    push!(lines, ")")
    
    # Join all lines
    output_content = join(lines, "\n")
    
    # Print to stdout
    println(output_content)
    
    # Optionally write to file
    if !isnothing(output_file)
        # If user asked for a .jl output, emit a mapgen function instead
        if endswith(lowercase(output_file), ".jl")
            base = get_basename(map_input)
            funcname = "mapgen_" * base
            mapnote = "Generated from $map_input"
            code = generate_mapgen_code(gamemap, funcname; mapnote=mapnote)
            # If user gave a bare filename like "mapgen_xxx.jl", default to src/demo_maps
            dir = dirname(output_file)
            if dir == "." || isempty(dir)
                dir = joinpath("src", "demo_maps")
            else
                mkpath(dir)
            end
            mkpath(dir)
            outpath = abspath(joinpath(dir, basename(output_file)))
            open(outpath, "w") do io
                write(io, code)
            end
            @info "Mapgen function written to: $outpath (function: $funcname)"
        else
            open(output_file, "w") do io
                write(io, output_content)
            end
            @info "Map encoded and written to: $output_file"
        end
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