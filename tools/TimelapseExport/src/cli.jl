# Strict command-line parsing. This file intentionally has no GLFW or renderer dependency.

abstract type ToolError <: Exception end

struct UsageError <: ToolError
    message::String
    code::Int
end
UsageError(message::AbstractString) = UsageError(String(message), 2)

struct ValidationError <: ToolError
    message::String
    code::Int
end
ValidationError(message::AbstractString) = ValidationError(String(message), 3)

struct RenderToolError <: ToolError
    message::String
    code::Int
end
RenderToolError(message::AbstractString) = RenderToolError(String(message), 4)

struct OutputError <: ToolError
    message::String
    code::Int
end
OutputError(message::AbstractString) = OutputError(String(message), 5)

struct ExportOptions
    input::Union{Nothing, String}
    output::Union{Nothing, String}
    format::Symbol
    width::Int
    height::Int
    fps::Int
    crf::Int
    preset::String
    crf_explicit::Bool
    preset_explicit::Bool
    keyframe_seconds::Float64
    start_hold::Float64
    end_hold::Float64
    include_current::Symbol
    dedupe::Bool
    camera::Symbol
    padding::Float64
    min_padding::Float64
    viewport::Union{Nothing, NTuple{4, Float64}}
    background::NTuple{3, UInt8}
    force::Bool
    inspect::Bool
    verbose::Bool
    help::Bool
    repository_root::String
end

const _PRESETS = Set(("ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"))
const _VALUED_OPTIONS = Set((
    "output", "format", "resolution", "fps", "crf", "preset", "keyframe-seconds", "start-hold", "end-hold",
    "include-current", "camera", "padding", "min-padding", "viewport", "background",
))
const _FLAG_OPTIONS = Set(("no-dedupe", "force", "inspect", "verbose", "help"))

function _float_value(name::AbstractString, value::AbstractString; minimum = nothing, minimum_inclusive = true)
    parsed = tryparse(Float64, value)
    parsed === nothing && throw(UsageError("invalid value for --$(name): $(value)"))
    isfinite(parsed) || throw(UsageError("--$(name) must be finite"))
    if !isnothing(minimum)
        valid = minimum_inclusive ? parsed >= minimum : parsed > minimum
        valid || throw(UsageError("--$(name) must be $(minimum_inclusive ? "at least" : "greater than") $(minimum)"))
    end
    return parsed
end

function _int_value(name::AbstractString, value::AbstractString; minimum = nothing, maximum = nothing)
    parsed = tryparse(Int, value)
    parsed === nothing && throw(UsageError("invalid integer for --$(name): $(value)"))
    !isnothing(minimum) && parsed < minimum && throw(UsageError("--$(name) must be at least $(minimum)"))
    !isnothing(maximum) && parsed > maximum && throw(UsageError("--$(name) must be at most $(maximum)"))
    return parsed
end

function _resolution(value::AbstractString)
    match_result = match(r"^([0-9]+)[xX]([0-9]+)$", value)
    isnothing(match_result) && throw(UsageError("resolution must be WIDTHxHEIGHT with positive integer dimensions"))
    width = tryparse(Int, match_result.captures[1])
    height = tryparse(Int, match_result.captures[2])
    (isnothing(width) || isnothing(height) || width <= 0 || height <= 0) &&
        throw(UsageError("resolution dimensions must be positive integers"))
    return width, height
end

function _viewport(value::AbstractString)
    parts = split(value, ',')
    length(parts) == 4 || throw(UsageError("--viewport must contain exactly XMIN,YMIN,XMAX,YMAX"))
    parsed = map(parts) do part
        number = tryparse(Float64, part)
        (number === nothing || !isfinite(number)) && throw(UsageError("--viewport values must be finite numbers"))
        number
    end
    x_min, y_min, x_max, y_max = parsed
    x_min < x_max && y_min < y_max || throw(UsageError("--viewport requires XMIN < XMAX and YMIN < YMAX"))
    return (Float64(x_min), Float64(y_min), Float64(x_max), Float64(y_max))
end

function _background(value::AbstractString)
    text = startswith(value, '#') ? value[2:end] : value
    length(text) == 6 || throw(UsageError("--background must be six hexadecimal RGB digits"))
    all(c -> c in "0123456789abcdefABCDEF", text) || throw(UsageError("--background must be six hexadecimal RGB digits"))
    return (parse(UInt8, text[1:2]; base = 16), parse(UInt8, text[3:4]; base = 16), parse(UInt8, text[5:6]; base = 16))
end

function _option_value(args, index, inline_value, name)
    !isnothing(inline_value) && return inline_value, index
    index == length(args) && throw(UsageError("missing value for --$(name)"))
    return args[index + 1], index + 1
end

"Parse the exporter arguments and validate all option relationships."
function parse_cli(args::Vector{String} = ARGS; repository_root::AbstractString = DEFAULT_REPOSITORY_ROOT)::ExportOptions
    input = nothing
    output = nothing
    supplied_format = nothing
    resolution = nothing
    fps = nothing
    crf = 20
    preset = "medium"
    crf_explicit = false
    preset_explicit = false
    keyframe_seconds = 0.5
    start_hold = 1.0
    end_hold = 2.0
    include_current = :auto
    dedupe = true
    camera = :expand
    padding = 0.12
    min_padding = 2.0
    viewport = nothing
    background = (UInt8(0x1d), UInt8(0x29), UInt8(0x51))
    force = false
    inspect = false
    verbose = false
    help = false
    seen = Set{String}()
    positionals = String[]

    index = 1
    while index <= length(args)
        argument = args[index]
        if argument == "--"
            append!(positionals, args[(index + 1):end])
            break
        elseif startswith(argument, "--")
            body = argument[3:end]
            name, inline_value = if occursin('=', body)
                split_body = split(body, '='; limit = 2)
                split_body[1], split_body[2]
            else
                body, nothing
            end
            (name in _VALUED_OPTIONS || name in _FLAG_OPTIONS) || throw(UsageError("unknown option --$(name)"))
            name in seen && throw(UsageError("option --$(name) was supplied more than once"))
            push!(seen, name)
            if name in _FLAG_OPTIONS
                isnothing(inline_value) || throw(UsageError("flag --$(name) does not take a value"))
                name == "no-dedupe" && (dedupe = false)
                name == "force" && (force = true)
                name == "inspect" && (inspect = true)
                name == "verbose" && (verbose = true)
                name == "help" && (help = true)
            else
                value, index = _option_value(args, index, inline_value, name)
                name == "output" && (output = value)
                name == "format" && (supplied_format = Symbol(lowercase(value)))
                name == "resolution" && (resolution = _resolution(value))
                name == "fps" && (fps = _int_value(name, value; minimum = 1, maximum = 240))
                name == "crf" && (crf = _int_value(name, value; minimum = 0, maximum = 51); crf_explicit = true)
                name == "preset" && (preset = value; preset_explicit = true)
                name == "keyframe-seconds" && (keyframe_seconds = _float_value(name, value; minimum = 0.0, minimum_inclusive = false))
                name == "start-hold" && (start_hold = _float_value(name, value; minimum = 0.0))
                name == "end-hold" && (end_hold = _float_value(name, value; minimum = 0.0))
                name == "include-current" && (include_current = Symbol(lowercase(value)))
                name == "camera" && (camera = Symbol(lowercase(value)))
                name == "padding" && (padding = _float_value(name, value; minimum = 0.0))
                name == "min-padding" && (min_padding = _float_value(name, value; minimum = 0.0))
                name == "viewport" && (viewport = _viewport(value))
                name == "background" && (background = _background(value))
            end
        elseif startswith(argument, "-")
            argument == "-h" || argument == "-o" || throw(UsageError("unknown option $(argument)"))
            argument == "-h" && ("help" in seen) && throw(UsageError("option -h was supplied more than once"))
            argument == "-h" && (push!(seen, "help"); help = true)
            if argument == "-o"
                "output" in seen && throw(UsageError("option -o/--output was supplied more than once"))
                push!(seen, "output")
                index == length(args) && throw(UsageError("missing value for -o"))
                index += 1
                output = args[index]
            end
        else
            push!(positionals, argument)
        end
        index += 1
    end

    help && (!isempty(positionals) || length(seen) > 1) && throw(UsageError("--help does not accept other arguments"))
    help && return ExportOptions(nothing, nothing, :mp4, 1920, 1080, 30, 20, "medium", false, false, 0.5, 1.0, 2.0,
        :auto, true, :expand, 0.12, 2.0, nothing, background, false, false, false, true, String(repository_root))
    length(positionals) == 1 || throw(UsageError("exactly one INPUT positional argument is required"))
    input = abspath(normpath(positionals[1]))
    output = isnothing(output) ? nothing : abspath(normpath(output))

    if !isnothing(supplied_format)
        supplied_format in (:mp4, :gif) || throw(UsageError("--format must be mp4 or gif"))
    end
    inferred_format = if isnothing(output)
        supplied_format === nothing ? :mp4 : supplied_format
    else
        extension = lowercase(splitext(output)[2])
        extension in (".mp4", ".gif") || (isnothing(supplied_format) && throw(UsageError("output extension must be .mp4 or .gif")))
        isnothing(supplied_format) ? Symbol(extension[2:end]) : supplied_format
    end
    if !isnothing(output) && !isnothing(supplied_format)
        extension = lowercase(splitext(output)[2])
        !isempty(extension) && Symbol(extension[2:end]) != supplied_format && throw(UsageError("--format must agree with the output extension"))
    end
    if inferred_format == :gif && (crf_explicit || preset_explicit)
        throw(UsageError("--crf and --preset are valid only for MP4 output"))
    end
    preset in _PRESETS || throw(UsageError("--preset must be one of: $(join(sort!(collect(_PRESETS)), ", "))"))
    isnothing(fps) && (fps = inferred_format == :mp4 ? 30 : 15)
    isnothing(resolution) && (resolution = inferred_format == :mp4 ? (1920, 1080) : (960, 540))
    inferred_format == :mp4 && (resolution[1] % 2 == 0 && resolution[2] % 2 == 0 || throw(UsageError("MP4 width and height must be even")))
    include_current in (:auto, :always, :never) || throw(UsageError("--include-current must be auto, always, or never"))
    camera in (:fixed, :expand, :fit, :smooth, :manual) || throw(UsageError("--camera must be fixed, expand, fit, smooth, or manual"))
    if camera == :manual
        isnothing(viewport) && throw(UsageError("--camera manual requires --viewport"))
        "padding" in seen && throw(UsageError("--padding is invalid with --camera manual"))
        "min-padding" in seen && throw(UsageError("--min-padding is invalid with --camera manual"))
    else
        !isnothing(viewport) && throw(UsageError("--viewport is valid only with --camera manual"))
    end
    return ExportOptions(input, output, inferred_format, resolution[1], resolution[2], fps, crf, preset, crf_explicit, preset_explicit,
        keyframe_seconds, start_hold, end_hold, include_current, dedupe, camera, padding, min_padding, viewport, background,
        force, inspect, verbose, false, String(repository_root))
end

function validate_paths!(options::ExportOptions)
    isnothing(options.input) && return nothing
    isfile(options.input) || throw(ValidationError("input path is not a regular file: $(options.input)"))
    try
        open(options.input, "r") do io
            eof(io) || nothing
        end
    catch error
        throw(ValidationError("input file is not readable: $(options.input) ($(sprint(showerror, error)))"))
    end
    if !isnothing(options.output)
        input_real = realpath(options.input)
        output_real = ispath(options.output) ? realpath(options.output) : abspath(normpath(options.output))
        input_real == output_real && throw(ValidationError("input and output paths must be different"))
    end
    return nothing
end

"Reject destinations that the requested publication policy must not replace."
function _validate_output_destination(output::AbstractString, force::Bool)
    ispath(output) || return nothing
    isfile(output) || throw(OutputError("output destination exists and is not a regular file: $(output)"))
    force || throw(OutputError("output already exists; use --force to replace it: $(output)"))
    return nothing
end

function prepare_output_path!(options::ExportOptions)::String
    isnothing(options.output) && throw(OutputError("--output is required unless --inspect is supplied"))
    output = options.output
    _validate_output_destination(output, options.force)
    try
        mkpath(dirname(output))
    catch error
        throw(OutputError("cannot create output directory $(dirname(output)): $(sprint(showerror, error))"))
    end
    return output
end

"Publish a completed export without replacing directories or no-force race winners."
function _publish_encoded_output!(temporary_output::AbstractString, output::AbstractString, force::Bool)
    _validate_output_destination(output, force)
    if ispath(output)
        try
            rm(output)
        catch error
            throw(OutputError("cannot replace existing output $(output): $(sprint(showerror, error))"))
        end
    end

    try
        mv(temporary_output, output)
    catch error
        throw(OutputError("cannot publish output to $(output): $(sprint(showerror, error))"))
    end
    return nothing
end

function print_help()
    print("""Time-Lapse Export Tool

Usage:
  julia --project=. tools/TimelapseExport/export.jl INPUT --output OUTPUT [options]

Exports construction history as H.264 MP4 (default) or a
palette-optimised animated GIF. The exporter uses a hidden GLFW OpenGL context,
so a working display server and OpenGL driver are required; it is not fully
headless. MP4 is recommended for normal use.

Options:
  -o, --output PATH             Final .mp4 or .gif path (required except --inspect)
                                  --format permits a path without an extension
      --format mp4|gif          Must agree with an output extension when present
      --resolution WxH           Positive integers; 1920x1080 MP4, 960x540 GIF
      --fps INTEGER              1..240; default 30 MP4, 15 GIF
      --crf INTEGER              0..51 MP4 only; default 20
      --preset NAME              H.264 preset list; default medium
      --keyframe-seconds FLOAT   Finite and >0; default 0.5
      --start-hold FLOAT         Finite and >=0; default 1.0
      --end-hold FLOAT           Finite and >=0; default 2.0
      --include-current POLICY   auto (default), always, or never; escape is omitted/rejected
      --no-dedupe                Keep adjacent render-equivalent frames
      --camera MODE               expand (default), fit, smooth, fixed, or manual
      --padding FLOAT             Finite and >=0, automatic cameras only; default 0.12
      --min-padding FLOAT         Finite and >=0, automatic cameras only; default 2.0
      --viewport X1,Y1,X2,Y2      Four finite values with X1<X2,Y1<Y2; manual only
      --background RRGGBB         Six hexadecimal RGB digits; default 1D2951
      --force                     Replace an existing output after success
      --inspect                   Print timeline/camera schedule without GL/output
      --verbose                   Detailed reconstruction, FFmpeg, and progress logs
  -h, --help                     Show this help

Camera bounds use stored base surface-tile coordinates and ignore ship render
offsets. Expand never shrinks; fit independently centres and zooms each keyframe;
smooth plans a continuous, filtered trajectory across the full timeline; and
fixed fits the whole timeline. Manual camera rectangles are aspect-expanded
without automatic padding.
Keyframes receive equal holds; endpoint holds are added independently. Smooth
uses up to the first second and half of the end hold to settle on a tight final
fit, then remains stationary. Example:
  julia --project=. tools/TimelapseExport/export.jl maps/save.jld2 \\
      --output recordings/save.mp4 --camera smooth

Exit codes: 0 success/help/inspection; 2 usage; 3 input/save/timeline; 4
assets/OpenGL/reconstruction/rendering; 5 output/FFmpeg; 130 interruption.
""")
end
