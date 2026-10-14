#=
Scope: Build a relocatable RocketPlumber distribution
Formatter: Runic
=#

using Dates, JuliaC

const ROOT_DIR = dirname(@__DIR__)
const OUTPUTS_DIR = joinpath(@__DIR__, "outputs")

# Generic code only, keeping the executable and distribution smaller
const CPU_TARGET_SMALL = "generic"
# Generic fallback plus specialised Sandy Bridge and Haswell code variants
const CPU_TARGET_LARGE = "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"

# Prefer smaller builds: the telemetry experiment found no compelling overall speedup
const CPU_TARGET = CPU_TARGET_SMALL

"Build a relocatable distribution with headless compilation and normal graphical startup."
function main()
    # CI supplies the release label; local builds default to a timestamp.
    build_label = get(ENV, "ROCKETPLUMBER_BUILD_LABEL", "")
    if isempty(build_label)
        build_label = "local-" * Dates.format(now(), dateformat"yymmdd-HHMMSS")
    end
    if !occursin(r"\A[A-Za-z0-9][A-Za-z0-9._-]*\z", build_label) || endswith(build_label, ".")
        error("Invalid build label: use letters, numbers, periods, underscores and hyphens; start with a letter or number and do not end with a period.")
    end

    distribution_name = "RocketPlumber-" * build_label
    bundle_dir = joinpath(OUTPUTS_DIR, distribution_name)
    executable_name = Sys.iswindows() ? distribution_name * ".exe" : distribution_name
    if ispath(bundle_dir) || islink(bundle_dir)
        error("Distribution already exists: $bundle_dir. Choose a different ROCKETPLUMBER_BUILD_LABEL or wait for a new timestamp.")
    end
    mkpath(OUTPUTS_DIR)
    mkdir(bundle_dir)

    # Allow GLFW dependencies to load during headless compilation; runtime
    # initialisation still selects the user's real graphical platform.
    # Budget image compilation for 8-core, 32 GB machines with some CPU headroom.
    # Keep package processes serial: each can use all six image threads.
    withenv(
        "JULIA_CPU_TARGET" => CPU_TARGET,
        "JULIA_GLFW_PLATFORM" => "null",
        "JULIA_NUM_PRECOMPILE_TASKS" => "1",
        "JULIA_IMAGE_THREADS" => "6",
    ) do
        JuliaC.main(
            [
                "--output-exe",
                executable_name,
                "--bundle",
                bundle_dir,
                "--jl-option",
                "threads=2,1",
                ROOT_DIR,
            ]
        )
    end

    return nothing
end

main()
