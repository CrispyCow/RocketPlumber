#=
Scope: Build a relocatable RocketPlumber distribution
Formatter: Runic
=#

using JuliaC

const ROOT_DIR = dirname(@__DIR__)
const OUTPUTS_DIR = joinpath(@__DIR__, "outputs")
const BUNDLE_DIR = joinpath(OUTPUTS_DIR, "RocketPlumber")

# Generic code only, keeping the executable and distribution smaller
const CPU_TARGET_SMALL = "generic"
# Generic fallback plus specialised Sandy Bridge and Haswell code variants
const CPU_TARGET_LARGE = "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"

# Prefer smaller builds: the telemetry experiment found no compelling overall speedup
const CPU_TARGET = CPU_TARGET_SMALL

"Build a relocatable distribution with headless compilation and normal graphical startup."
function main()
    rm(OUTPUTS_DIR; recursive = true, force = true)

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
                "RocketPlumber",
                "--bundle",
                BUNDLE_DIR,
                "--jl-option",
                "threads=2,1",
                ROOT_DIR,
            ]
        )
    end

    return nothing
end

main()
