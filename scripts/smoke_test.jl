#=
Scope: Full-application graphical smoke-test entry point
Formatter: Runic
=#

# This launcher exercises RocketPlumber without requiring Revise.
using RocketPlumber
include(joinpath(@__DIR__, "..", "test", "smoke", "SmokeTestSupport.jl"))

SmokeTestSupport.run_smoke_test(; SmokeTestSupport.parse_smoke_args(ARGS)...) || exit(1)
