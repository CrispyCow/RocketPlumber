"""
    Crash Dump Inspector — Rocket Plumber

Summarises the metadata stored in a FlowCalculator crash dump without printing the
full circuit-analysis report.

Outputs:
  - saved dataset keys
  - captured exception message
  - the first N backtrace lines
  - pending command summaries
  - a compact map/valve summary
  - optional component context for a focused tile coordinate

Usage:
    julia --project=. tools/map_diagnostics/inspect_crash_dump.jl <dump-path>
    julia --project=. tools/map_diagnostics/inspect_crash_dump.jl <dump-path> --backtrace-lines <n>
    julia --project=. tools/map_diagnostics/inspect_crash_dump.jl <dump-path> --coord <q> <r>
"""

using JLD2, Accessors

using HexFrame, HexElements, HexFluids, HexFlowTelemetry
using HexComponentsAPI, FlowEngine, FlowMap, HexFlowProcGen
using HexFlowControl, HexFlowCalculator
using SquirrelNoise
using HexFlowBasicComponents, HexFlowTankComponents, HexFlowSwitchComponents
using HexFlowNozzleComponents, HexFlowPumpComponents
using HexFlowBasicPipes

const _src_dir = normpath(joinpath(@__DIR__, "..", "..", "src"))
include(joinpath(_src_dir, "components.jl"))
include(joinpath(_src_dir, "map_loading.jl"))

Base.@kwdef struct InspectOptions
    dump_path::String
    focus_coord::Union{Nothing, TileCoord} = nothing
    backtrace_lines::Int = 40
end

function usage_and_exit(message::Union{Nothing, String} = nothing, code::Int = 1)
    if !isnothing(message)
        println(message)
        println()
    end
    println("Usage:")
    println("  julia --project=. tools/map_diagnostics/inspect_crash_dump.jl <dump-path>")
    println("  julia --project=. tools/map_diagnostics/inspect_crash_dump.jl <dump-path> --backtrace-lines <n>")
    println("  julia --project=. tools/map_diagnostics/inspect_crash_dump.jl <dump-path> --coord <q> <r>")
    exit(code)
end

function parse_args(args::Vector{String})::InspectOptions
    isempty(args) && usage_and_exit("Missing dump path")

    dump_path = args[1]
    focus_coord = nothing
    backtrace_lines = 40

    i = 2
    while i <= length(args)
        arg = args[i]
        if arg == "--coord"
            i + 2 <= length(args) || usage_and_exit("--coord requires <q> <r>")
            focus_coord = TileCoord(parse(Int, args[i + 1]), parse(Int, args[i + 2]))
            i += 3
        elseif arg == "--backtrace-lines"
            i + 1 <= length(args) || usage_and_exit("--backtrace-lines requires <n>")
            backtrace_lines = parse(Int, args[i + 1])
            backtrace_lines > 0 || usage_and_exit("--backtrace-lines must be positive")
            i += 2
        else
            usage_and_exit("Unknown argument: $arg")
        end
    end

    return InspectOptions(dump_path = dump_path, focus_coord = focus_coord, backtrace_lines = backtrace_lines)
end

component_type_name(comp) = replace(string(typeof(comp)), r"^.*\." => "")

function round_or_raw(value; digits::Int = 3)
    value isa Real || return string(value)
    return string(round(Float64(value); digits = digits))
end

function switch_summary(comp)::Union{Nothing, String}
    hasproperty(comp, :switch) || return nothing
    hasproperty(comp.switch, :state) || return nothing
    state = comp.switch.state
    return "switch current=$(round_or_raw(state.current_conductance)) target=$(round_or_raw(state.target_conductance))"
end

function tank_summary(comp)::Union{Nothing, String}
    if comp isa HexFlowTankComponents.PressureFedTankCompBehav
        tank = comp.tank
        return join([
            "liquid=$(round_or_raw(tank.liquid_state.charge))",
            "gas=$(round_or_raw(tank.gas_state.charge))",
            "stored=$(tank.stored_liquid.fluid)",
        ], " ")
    end

    if hasproperty(comp, :tank) && hasproperty(comp.tank, :state)
        return "charge=$(round_or_raw(comp.tank.state.charge))"
    end

    return nothing
end

function component_state_summary(comp)::String
    parts = String[]

    switch_str = switch_summary(comp)
    isnothing(switch_str) || push!(parts, switch_str)

    tank_str = tank_summary(comp)
    isnothing(tank_str) || push!(parts, tank_str)

    return isempty(parts) ? "" : "  " * join(parts, "  ")
end

function command_summary(cmd)::String
    if cmd isa ClickTileCommand
        return "ClickTileCommand id=$(cmd.id) coord=$(cmd.coord) click=$(cmd.unrotated_clicksite)"
    elseif cmd isa DoActionCommand
        return "DoActionCommand id=$(cmd.id) coord=$(cmd.coord) action=$(cmd.action_id)"
    elseif cmd isa DeleteElementsCommand
        return "DeleteElementsCommand id=$(cmd.id) components=$(length(cmd.component_coords)) pipes=$(length(cmd.pipe_coords))"
    elseif cmd isa TranslateElementsCommand
        return "TranslateElementsCommand id=$(cmd.id) components=$(length(cmd.component_coords)) pipes=$(length(cmd.pipe_coords)) translation=$(cmd.translation)"
    elseif cmd isa AddShipSurfaceCommand
        return "AddShipSurfaceCommand id=$(cmd.id) coord=$(cmd.coord)"
    elseif cmd isa RemoveShipSurfaceCommand
        return "RemoveShipSurfaceCommand id=$(cmd.id) coord=$(cmd.coord)"
    elseif cmd isa SetTileCommand
        return "SetTileCommand id=$(cmd.id) coord=$(cmd.coord) component=$(component_type_name(cmd.component)) rot=$(cmd.rotation) mirrored=$(cmd.mirrored)"
    elseif cmd isa SetPipeBehaviorCommand
        pipe_name = replace(string(typeof(cmd.pipe_behavior)), r"^.*\." => "")
        return "SetPipeBehaviorCommand id=$(cmd.id) coord=$(cmd.coord) pipe=$pipe_name"
    elseif cmd isa MapOverrideCommand
        return "MapOverrideCommand id=$(cmd.id)"
    end

    return string(typeof(cmd), " ", repr(cmd))
end

function print_dump_metadata(opts::InspectOptions)
    file = jldopen(opts.dump_path, "r")
    try
        println("===========================================================")
        println("CRASH DUMP METADATA")
        println("===========================================================")
        println("Path: $(opts.dump_path)")
        println("Keys:")
        for key in sort!(collect(String.(keys(file))))
            println("  - $key")
        end

        if haskey(file, "exception_message")
            println("\nException:")
            println(file["exception_message"])
        end

        if haskey(file, "exception_backtrace")
            println("\nBacktrace (first $(opts.backtrace_lines) lines):")
            lines = split(file["exception_backtrace"], "\n")
            for line in Iterators.take(lines, opts.backtrace_lines)
                println(line)
            end
        end

        if haskey(file, "pending_commands")
            commands = file["pending_commands"]
            println("\nPending commands: $(length(commands))")
            for (i, cmd) in enumerate(commands)
                println("  [$i] $(command_summary(cmd))")
            end
        end

        if haskey(file, "node_voltages")
            println("Captured node voltages: $(length(file["node_voltages"]))")
        end
        if haskey(file, "vsource_currents")
            println("Captured voltage-source currents: $(length(file["vsource_currents"]))")
        end
    finally
        close(file)
    end
end

function print_map_summary(gamemap::GameMap)
    println("\n===========================================================")
    println("MAP SUMMARY")
    println("===========================================================")
    ship_names = sort!(collect(keys(gamemap.ships)); by = string)
    println("Ships: $(length(ship_names)) — $ship_names")
    println("Components: $(count_components(gamemap))    Pipes: $(count_pipes(gamemap))    Surface tiles: $(count_surface_tiles(gamemap))")
end

function print_valve_summary(gamemap::GameMap)
    println("\n===========================================================")
    println("VALVE SUMMARY")
    println("===========================================================")

    valve_rows = Tuple{Symbol, TileCoord, String}[]
    for (coord, placed_component) in get_components(gamemap)
        comp = placed_component.component
        comp isa HexFlowSwitchComponents.StandardValveCompBehav || continue
        state = component_state_summary(comp)
        push!(valve_rows, (placed_component.ship, coord, "$(component_type_name(comp))$state"))
    end

    sort!(valve_rows; by = row -> (string(row[1]), row[2].q, row[2].r))
    for (ship_name, coord, desc) in valve_rows
        println("  ship=$(ship_name) coord=$(coord)  $desc")
    end
end

function print_reactivation_candidates(gamemap::GameMap)
    println("\n===========================================================")
    println("REACTIVATION CANDIDATES")
    println("===========================================================")

    candidate_rows = Tuple{Symbol, TileCoord, String}[]
    for (coord, placed_component) in get_components(gamemap)
        isnothing(get_reactivation_probe(placed_component)) && continue
        desc = "$(component_type_name(placed_component.component))$(component_state_summary(placed_component.component))"
        push!(candidate_rows, (placed_component.ship, coord, desc))
    end

    if isempty(candidate_rows)
        println("  <none>")
        return nothing
    end

    sort!(candidate_rows; by = row -> (string(row[1]), row[2].q, row[2].r))
    for (ship_name, coord, desc) in candidate_rows
        println("  ship=$(ship_name) coord=$(coord)  $desc")
    end
    return nothing
end

function print_component_context(gamemap::GameMap, focus_coord::TileCoord)
    println("\n===========================================================")
    println("FOCUS COORD")
    println("===========================================================")
    println("Tile: $(focus_coord)")

    placed_component = get_component(gamemap, focus_coord)
    if isnothing(placed_component)
        println("  No component at focus tile")
    else
        comp = placed_component.component
        println("  Component: $(component_type_name(comp))")
        println("  Ship: $(placed_component.ship)    Rotation: $(placed_component.rotation)    Mirrored: $(placed_component.mirrored)")
        state = component_state_summary(comp)
        isempty(state) || println("  State: $(strip(state))")
    end

    println("\nAdjacent tiles:")
    for adj in get_adjacent_tiles_for_tile(focus_coord)
        adj_comp = get_component(gamemap, adj)
        if isnothing(adj_comp)
            println("  $(adj): <empty>")
        else
            comp = adj_comp.component
            state = component_state_summary(comp)
            println("  $(adj): $(component_type_name(comp)) ship=$(adj_comp.ship)$(state)")
        end
    end
end

function main(args::Vector{String})::Int
    opts = parse_args(args)
    isfile(opts.dump_path) || usage_and_exit("Dump file not found: $(opts.dump_path)")

    print_dump_metadata(opts)

    gamemap = loadmap(opts.dump_path)
    print_map_summary(gamemap)
    print_valve_summary(gamemap)
    print_reactivation_candidates(gamemap)

    if !isnothing(opts.focus_coord)
        print_component_context(gamemap, opts.focus_coord)
    end

    return 0
end

exit(main(ARGS))
