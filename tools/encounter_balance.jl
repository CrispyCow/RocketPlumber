#!/usr/bin/env julia

let
    # Keep the game project primary and add the plotting project to the load path.
    repository_root = normpath(joinpath(@__DIR__, ".."))
    tool_root = joinpath(@__DIR__, "EncounterBalance")
    entry_point = joinpath(tool_root, "src", "EncounterBalance.jl")
    environment_path = join((repository_root, tool_root, "@stdlib"), Sys.iswindows() ? ';' : ':')
    arguments = abspath(PROGRAM_FILE) == abspath((@__FILE__)) ? ARGS : String[]

    command = `$(Base.julia_cmd()) --startup-file=no --project=$(repository_root) $(entry_point) $(arguments...)`
    run(addenv(command, "JULIA_LOAD_PATH" => environment_path))
end
