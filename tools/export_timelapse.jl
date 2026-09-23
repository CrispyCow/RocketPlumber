#!/usr/bin/env julia

let
    # Edit these paths and options for a normal Run File export.
    input = "maps/game1_15_final-prep.jld2"
    output = "recordings/game1_15_final-prep.mp4"
    options = [
        "--camera", "expand",
        "--resolution", "1920x1080",
        "--fps", "30",
    ]

    repository_root = normpath(joinpath(@__DIR__, ".."))
    exporter = joinpath(@__DIR__, "TimelapseExport", "export.jl")

    script_arguments = abspath(PROGRAM_FILE) == abspath((@__FILE__)) ? ARGS : String[]
    arguments = if isempty(script_arguments)
        input_path = isabspath(input) ? input : joinpath(repository_root, input)
        output_path = isabspath(output) ? output : joinpath(repository_root, output)
        [input_path, "--output", output_path, options...]
    else
        copy(script_arguments)
    end

    command = Cmd(vcat(
        Base.julia_cmd().exec,
        ["--startup-file=no", "--project=$(repository_root)", exporter],
        arguments,
    ))
    process = run(pipeline(command, stdin = stdin, stdout = stdout, stderr = stderr); wait = false)
    wait(process)

    if process.exitcode != 0
        isinteractive() && throw(ProcessFailedException(process))
        exit(process.exitcode)
    end
end
